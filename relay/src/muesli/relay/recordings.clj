(ns muesli.relay.recordings
  "Recording lifecycle shared by the PWA API, the web pages and the
  Emacs-facing API (Spec 3 §4.3).  Functions return [:ok value] or
  [:error status code message extra]."
  (:require [clojure.java.io :as io]
            [muesli.relay.db :as db]
            [muesli.relay.pipeline :as pipeline]
            [muesli.relay.storage :as storage]))

(def max-seq 100000)

(def finished-statuses #{"processing" "transcribed" "failed" "delivered"})

(defn- storage-dir [ctx] (get-in ctx [:cfg :storage :dir]))

(defn public
  "The fields of recording R shown to the PWA and web pages."
  [r]
  (select-keys r [:id :client_id :client_name :profile :title :mime_type :status :origin
                  :reject_reason :started_at :ended_at :duration_ms :part_count
                  :bytes :delivered_at :created_at :audio_deleted :error :failed_step]))

(defn for-client
  "The fields of recording R sent to Emacs in listings."
  [r]
  (select-keys r [:id :origin :status :profile :title :notes :mime_type :duration_ms :bytes
                  :started_at :ended_at :speakers :failed_step :error]))

(defn status-for-client
  "Detailed status of R for the Emacs poller."
  [{:keys [ds]} r]
  (let [counts (db/chunk-counts ds (:id r))
        parts (count (db/part-seqs ds (:id r)))]
    (assoc (for-client r)
           :stop_requested (= 1 (:stop_requested r))
           :last_part_at (:last_part_at r)
           :server_time (db/now)
           :parts parts
           :duration_ms (or (:duration_ms r)
                            (when (= "recording" (:status r))
                              (when-let [c (db/last-chunk ds (:id r))]
                                (+ (:offset_ms c) (:duration_ms c)))))
           :chunks (select-keys counts [:pending :uploading :done :failed :total])
           :segments (db/segment-count ds (:id r)))))

(defn profile-names [client]
  (set (map :name (:profiles client))))

;;;; Creating

(defn create-for-emacs!
  "Create the waiting recording ID for CLIENT-ID (Emacs-origin).
  Idempotent for the same client."
  [{:keys [ds]} key-info {:keys [id title speakers started_at]}]
  (let [existing (db/recording ds id)]
    (cond
      (and existing (not= (:client_id existing) (:client_id key-info)))
      [:error 409 "conflict" "Recording id already in use"]

      existing [:ok existing]

      :else
      (do (db/create-recording! ds {:id id :user-id (:user_id key-info)
                                    :client-id (:client_id key-info) :profile ""
                                    :title title :origin "emacs" :speakers speakers
                                    :started-at started_at})
          [:ok (db/recording ds id)]))))

(defn create!
  "Create recording ID for USER from the phone, or claim the waiting
  Emacs-origin recording ID (idempotent for the same user)."
  [{:keys [ds]} user {:keys [id client_id profile title mime_type started_at]}]
  (let [existing (db/recording ds id)
        client (when client_id (db/client ds (:id user) client_id))]
    (cond
      (and existing (not= (:user_id existing) (:id user)))
      [:error 409 "conflict" "Recording id already in use"]

      (not (storage/allowed-mime? mime_type))
      [:error 415 "unsupported_type" (str "Unsupported audio type " mime_type)]

      (and existing (= "waiting" (:status existing)))
      (do (db/update-recording! ds id {:status "recording" :mime_type mime_type
                                       :started_at started_at :last_part_at (db/now)})
          [:ok (db/recording ds id)])

      (and existing (= "abandoned" (:status existing)) (= "emacs" (:origin existing))
           (zero? (count (db/part-seqs ds id))))
      [:error 410 "gone" "Emacs stopped waiting for this recording"]

      existing [:ok existing]

      (nil? client) [:error 422 "unknown_client" "No such linked Emacs"]

      (not (contains? (profile-names client) profile))
      [:error 422 "unknown_profile" (str "This Emacs has no profile named " profile)]

      :else
      (do (db/create-recording! ds {:id id :user-id (:id user) :client-id client_id
                                    :profile profile :title title :mime-type mime_type
                                    :started-at started_at})
          [:ok (db/recording ds id)]))))

;;;; Parts and finish

(defn- part-reply [r m]
  (assoc m :stop_requested (= 1 (:stop_requested r))))

(defn put-part!
  "Store part SEQ-NO of recording ID streamed from IN, expected SHA."
  [{:keys [ds cfg] :as ctx} user id seq-no sha in]
  (let [r (db/user-recording ds (:id user) id)
        limit (get-in cfg [:storage :max-part-bytes])]
    (cond
      (nil? r) [:error 404 "not_found" "No such recording"]

      (not (#{"recording" "abandoned"} (:status r)))
      (cond
        (when-let [p (db/part ds id seq-no)] (= (:sha256 p) sha))
        [:ok (part-reply r {:seq seq-no :duplicate true})]

        (db/part ds id seq-no)
        [:error 409 "part_conflict" "This part was already received with different content"]

        ;; Finished without the phone (Emacs asked to stop and the phone
        ;; was gone): late parts are accepted and dropped.
        (= 1 (:stop_requested r))
        [:ok (part-reply r {:seq seq-no :ignored true})]

        :else [:error 409 "finished" "Recording is already finished"])

      :else
      (let [{:keys [error file bytes sha256]} (storage/write-part! (storage-dir ctx) (:id user) id in limit)]
        (cond
          error [:error 413 "too_large" "Part is too large"]

          (not= sha256 sha)
          (do (io/delete-file file true)
              [:error 400 "checksum" "Part checksum does not match X-Part-SHA256"])

          :else
          (if-let [p (db/part ds id seq-no)]
            (do (io/delete-file file true)
                (if (= (:sha256 p) sha)
                  [:ok (part-reply r {:seq seq-no :duplicate true})]
                  [:error 409 "part_conflict" "This part was already received with different content"]))
            (if (> (+ (:bytes r) bytes) (get-in cfg [:storage :max-recording-bytes]))
              (do (io/delete-file file true)
                  [:error 413 "too_large" "Recording exceeds the size limit"])
              (do (storage/commit-part! (storage-dir ctx) (:id user) id seq-no file)
                  (try (db/add-part! ds id seq-no bytes sha256)
                       (catch Exception e
                         ;; A concurrent upload of the same part won the race.
                         (if (db/part ds id seq-no)
                           nil
                           (throw e))))
                  (pipeline/feed! ctx r)
                  [:ok (part-reply r {:seq seq-no})]))))))))

(defn finish!
  [{:keys [ds] :as ctx} user id {:keys [part_count ended_at duration_ms notes]}]
  (let [r (db/user-recording ds (:id user) id)]
    (cond
      (nil? r) [:error 404 "not_found" "No such recording"]

      (finished-statuses (:status r))
      (cond
        (= part_count (:part_count r)) [:ok (public r)]
        ;; Finished by the relay after Emacs asked to stop: keep the notes.
        (= 1 (:stop_requested r))
        (do (when (and notes (nil? (:notes r)))
              (db/update-recording! ds id {:notes notes}))
            [:ok (public (db/recording ds id))])
        :else [:error 409 "finished" "Recording was finished with a different part count"])

      (= "waiting" (:status r))
      [:error 409 "not_started" "Recording has not started"]

      :else
      (let [have (set (db/part-seqs ds id))
            missing (vec (remove have (range part_count)))]
        (if (seq missing)
          [:error 409 "missing_parts" "Some parts have not been received"
           {:missing (vec (take 1000 missing))}]
          (do
            ;; The pipeline finishes the chunks and assembles the file.
            (db/update-recording! ds id {:status "processing" :part_count part_count
                                         :ended_at ended_at :duration_ms duration_ms
                                         :notes notes})
            (pipeline/feed! ctx (db/recording ds id))
            [:ok (public (db/recording ds id))]))))))

;;;; Emacs actions

(defn- client-recording [ds client-id id]
  (let [r (db/recording ds id)]
    (when (and r (= client-id (:client_id r))) r)))

(defn stop!
  "Emacs asks to stop recording ID."
  [{:keys [ds cfg] :as ctx} client-id id]
  (if-let [r (client-recording ds client-id id)]
    (do
      (case (:status r)
        "waiting" (db/update-recording! ds id {:status "abandoned" :stop_requested 1})
        "recording"
        (let [gone-ms (* 1000 (get-in cfg [:recording :phone-gone-seconds] 60))]
          (db/update-recording! ds id {:stop_requested 1})
          (when (< (or (:last_part_at r) 0) (- (db/now) gone-ms))
            (pipeline/drop-recording! ctx id)
            (pipeline/finish-with-parts! ctx r)))
        nil)
      [:ok (status-for-client ctx (db/recording ds id))])
    [:error 404 "not_found" "No such recording for this client"]))

(defn retry!
  "Retry a failed recording; with SKIP, continue without the failed step."
  [{:keys [ds] :as ctx} client-id id skip]
  (let [r (client-recording ds client-id id)]
    (cond
      (nil? r) [:error 404 "not_found" "No such recording for this client"]
      (not= "failed" (:status r)) [:error 409 "not_failed" "Recording has not failed"]
      :else
      (do
        (case [(:failed_step r) (boolean skip)]
          ["transcribing" true]
          (db/exec! ds ["UPDATE chunks SET status = 'done' WHERE recording_id = ? AND status = 'failed'" id])
          ["transcribing" false]
          (db/exec! ds ["UPDATE chunks SET status = 'pending', attempts = 0, not_before = 0
                          WHERE recording_id = ? AND status = 'failed'" id])
          nil)
        (db/update-recording! ds id (if (and skip (= "diarizing" (:failed_step r)))
                                      {:status "transcribed" :failed_step nil :error nil}
                                      {:status "processing" :failed_step nil :error nil}))
        [:ok (status-for-client ctx (db/recording ds id))]))))

(defn delete-audio! [ctx r]
  (pipeline/drop-recording! ctx (:id r))
  (storage/delete-recording-files! (storage-dir ctx) (:user_id r) (:id r))
  (db/delete-transcript! (:ds ctx) (:id r))
  (db/update-recording! (:ds ctx) (:id r) {:audio_deleted 1}))

(defn ack!
  [{:keys [ds cfg] :as ctx} client-id id meeting-id]
  (let [r (client-recording ds client-id id)]
    (cond
      (nil? r) [:error 404 "not_found" "No such recording for this client"]

      (= "delivered" (:status r)) [:ok {:id id :status "delivered"}]

      (not= "transcribed" (:status r))
      [:error 409 "not_ready" "Recording is not transcribed yet"]

      :else
      (do (db/update-recording! ds id {:status "delivered" :delivered_at (db/now)
                                       :meeting_id meeting-id :reject_reason nil})
          (when (zero? (get-in cfg [:retention :after-ack-hours] 0))
            (delete-audio! ctx r))
          [:ok {:id id :status "delivered"}]))))

(defn reject!
  [{:keys [ds]} client-id id reason]
  (let [r (client-recording ds client-id id)]
    (cond
      (nil? r) [:error 404 "not_found" "No such recording for this client"]
      (not= "transcribed" (:status r)) [:error 409 "not_ready" "Recording is not transcribed yet"]
      :else (do (db/update-recording! ds id {:reject_reason (subs reason 0 (min 500 (count reason)))})
                [:ok {:id id :status (:status r) :reject_reason reason}]))))

;;;; PWA and web actions

(defn reassign!
  "Change client, profile or title of an undelivered phone recording."
  [{:keys [ds]} user id {:keys [client_id profile title] :as changes}]
  (let [r (db/user-recording ds (:id user) id)
        client-id (or client_id (:client_id r))
        profile (or profile (:profile r))
        client (when client-id (db/client ds (:id user) client-id))]
    (cond
      (nil? r) [:error 404 "not_found" "No such recording"]
      (= "delivered" (:status r)) [:error 409 "delivered" "Recording was already delivered"]
      (= "emacs" (:origin r)) [:error 409 "bound" "This recording belongs to a meeting started in Emacs"]
      (nil? client) [:error 422 "unknown_client" "No such linked Emacs"]
      (not (contains? (profile-names client) profile))
      [:error 422 "unknown_profile" (str "That Emacs has no profile named " profile)]
      :else
      (do (db/update-recording! ds id (cond-> {:client_id client-id :profile profile :reject_reason nil}
                                        (contains? changes :title) (assoc :title title)))
          [:ok (public (db/recording ds id))]))))

(defn- discard [ctx r]
  (pipeline/drop-recording! ctx (:id r))
  (storage/delete-recording-files! (storage-dir ctx) (:user_id r) (:id r))
  (db/delete-recording! (:ds ctx) (:id r))
  [:ok {:id (:id r) :deleted true}])

(defn discard!
  [{:keys [ds] :as ctx} user id]
  (let [r (db/user-recording ds (:id user) id)]
    (cond
      (nil? r) [:error 404 "not_found" "No such recording"]
      (= "delivered" (:status r)) [:error 409 "delivered" "Recording was already delivered"]
      :else (discard ctx r))))

(defn discard-for-client!
  "Emacs aborted the meeting: drop recording ID whatever its state."
  [{:keys [ds] :as ctx} client-id id]
  (if-let [r (client-recording ds client-id id)]
    (discard ctx r)
    [:ok {:id id :deleted true}]))

(defn audio-file
  "The assembled audio file of R, if it is on disk."
  [ctx r]
  (let [f (storage/audio-file (storage-dir ctx) r)]
    (when (.isFile f) f)))
