(ns muesli.relay.recordings
  "Recording lifecycle shared by the PWA API, the web pages and the
  Emacs-facing API.  Functions return [:ok value] or [:error status code
  message extra]."
  (:require [clojure.java.io :as io]
            [muesli.relay.db :as db]
            [muesli.relay.storage :as storage]))

(def max-seq 100000)

(defn- storage-dir [ctx] (get-in ctx [:cfg :storage :dir]))

(defn public
  "The fields of recording R shown to the PWA and web pages."
  [r]
  (select-keys r [:id :client_id :client_name :profile :title :mime_type :status
                  :reject_reason :started_at :ended_at :duration_ms :part_count
                  :bytes :delivered_at :created_at :audio_deleted]))

(defn for-client
  "The fields of recording R sent to Emacs."
  [r]
  (select-keys r [:id :profile :title :notes :mime_type :duration_ms :bytes :sha256
                  :started_at :ended_at]))

(defn profile-names [client]
  (set (map :name (:profiles client))))

(defn create!
  "Create recording ID for USER (idempotent for the same user)."
  [{:keys [ds]} user {:keys [id client_id profile title mime_type started_at]}]
  (let [existing (db/recording ds id)
        client (db/client ds (:id user) client_id)]
    (cond
      (and existing (not= (:user_id existing) (:id user)))
      [:error 409 "conflict" "Recording id already in use"]

      existing [:ok existing]

      (nil? client) [:error 422 "unknown_client" "No such linked Emacs"]

      (not (contains? (profile-names client) profile))
      [:error 422 "unknown_profile" (str "This Emacs has no profile named " profile)]

      (not (storage/allowed-mime? mime_type))
      [:error 415 "unsupported_type" (str "Unsupported audio type " mime_type)]

      :else
      (do (db/create-recording! ds {:id id :user-id (:id user) :client-id client_id
                                    :profile profile :title title :mime-type mime_type
                                    :started-at started_at})
          [:ok (db/recording ds id)]))))

(defn put-part!
  "Store part SEQ-NO of recording ID streamed from IN, expected SHA."
  [{:keys [ds cfg] :as ctx} user id seq-no sha in]
  (let [r (db/user-recording ds (:id user) id)
        limit (get-in cfg [:storage :max-part-bytes])]
    (cond
      (nil? r) [:error 404 "not_found" "No such recording"]
      (not (#{"recording" "abandoned"} (:status r)))
      (if-let [p (db/part ds id seq-no)]
        (if (= (:sha256 p) sha) [:ok {:seq seq-no :duplicate true}]
            [:error 409 "part_conflict" "This part was already received with different content"])
        [:error 409 "finished" "Recording is already finished"])
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
                  [:ok {:seq seq-no :duplicate true}]
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
                  [:ok {:seq seq-no}]))))))))

(defn finish!
  [{:keys [ds] :as ctx} user id {:keys [part_count ended_at duration_ms notes]}]
  (let [r (db/user-recording ds (:id user) id)]
    (cond
      (nil? r) [:error 404 "not_found" "No such recording"]

      (#{"ready" "delivered"} (:status r))
      (if (= part_count (:part_count r))
        [:ok (public r)]
        [:error 409 "finished" "Recording was finished with a different part count"])

      :else
      (let [have (set (db/part-seqs ds id))
            missing (vec (remove have (range part_count)))]
        (if (seq missing)
          [:error 409 "missing_parts" "Some parts have not been received"
           {:missing (vec (take 1000 missing))}]
          (let [{:keys [bytes sha256]} (storage/assemble! (storage-dir ctx) r part_count)]
            ;; Part rows stay (they are tiny) so a late retry of a part
            ;; is still recognised as a duplicate.
            (db/update-recording! ds id {:status "ready" :part_count part_count
                                         :ended_at ended_at :duration_ms duration_ms
                                         :notes notes :bytes bytes :sha256 sha256})
            [:ok (public (db/recording ds id))]))))))

(defn delete-audio! [ctx r]
  (storage/delete-recording-files! (storage-dir ctx) (:user_id r) (:id r))
  (db/update-recording! (:ds ctx) (:id r) {:audio_deleted 1}))

(defn ack!
  [{:keys [ds cfg] :as ctx} client-id id meeting-id]
  (let [r (db/recording ds id)]
    (cond
      (or (nil? r) (not= client-id (:client_id r)))
      [:error 404 "not_found" "No such recording for this client"]

      (= "delivered" (:status r)) [:ok {:id id :status "delivered"}]

      (not= "ready" (:status r))
      [:error 409 "not_ready" "Recording is not ready"]

      :else
      (do (db/update-recording! ds id {:status "delivered" :delivered_at (db/now)
                                       :meeting_id meeting-id :reject_reason nil})
          (when (zero? (get-in cfg [:retention :after-ack-hours] 0))
            (delete-audio! ctx r))
          [:ok {:id id :status "delivered"}]))))

(defn reject!
  [{:keys [ds]} client-id id reason]
  (let [r (db/recording ds id)]
    (cond
      (or (nil? r) (not= client-id (:client_id r)))
      [:error 404 "not_found" "No such recording for this client"]
      (not= "ready" (:status r)) [:error 409 "not_ready" "Recording is not ready"]
      :else (do (db/update-recording! ds id {:reject_reason (subs reason 0 (min 500 (count reason)))})
                [:ok {:id id :status "ready" :reject_reason reason}]))))

(defn reassign!
  "Change client, profile or title of an undelivered recording."
  [{:keys [ds]} user id {:keys [client_id profile title] :as changes}]
  (let [r (db/user-recording ds (:id user) id)
        client-id (or client_id (:client_id r))
        profile (or profile (:profile r))
        client (when client-id (db/client ds (:id user) client-id))]
    (cond
      (nil? r) [:error 404 "not_found" "No such recording"]
      (= "delivered" (:status r)) [:error 409 "delivered" "Recording was already delivered"]
      (nil? client) [:error 422 "unknown_client" "No such linked Emacs"]
      (not (contains? (profile-names client) profile))
      [:error 422 "unknown_profile" (str "That Emacs has no profile named " profile)]
      :else
      (do (db/update-recording! ds id (cond-> {:client_id client-id :profile profile :reject_reason nil}
                                        (contains? changes :title) (assoc :title title)))
          [:ok (public (db/recording ds id))]))))

(defn discard!
  [{:keys [ds] :as ctx} user id]
  (let [r (db/user-recording ds (:id user) id)]
    (cond
      (nil? r) [:error 404 "not_found" "No such recording"]
      (= "delivered" (:status r)) [:error 409 "delivered" "Recording was already delivered"]
      :else (do (storage/delete-recording-files! (storage-dir ctx) (:user_id r) id)
                (db/delete-recording! ds id)
                [:ok {:id id :deleted true}]))))

(defn audio-file
  "The assembled audio file of R, if it is still on disk."
  [ctx r]
  (let [f (storage/audio-file (storage-dir ctx) r)]
    (when (and (#{"ready" "delivered"} (:status r)) (.isFile f)) f)))
