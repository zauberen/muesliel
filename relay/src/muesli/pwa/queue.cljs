(ns muesli.pwa.queue
  "Durable upload queue.  Every slice is in IndexedDB before an upload is
  tried; a recording leaves IndexedDB only after `finish` succeeded.
  `kick!` is safe to call any time: only one drain runs at once."
  (:require [muesli.pwa.api :as api]
            [muesli.pwa.idb :as idb]))

(defonce state (atom {:running false :again false :backoff 1000 :timer nil
                      :progress {} :error nil :login-required false}))

(defonce listeners (atom #{}))

(defn on-change! [f] (swap! listeners conj f))
(defn- notify! [] (doseq [f @listeners] (f @state)))

(defn- set-progress! [rid m]
  (swap! state update-in [:progress rid] merge m)
  (notify!))

(defn hex [^js buf]
  (let [bytes (js/Uint8Array. buf)]
    (.join (.map (js/Array.from bytes) (fn [b] (.padStart (.toString b 16) 2 "0"))) "")))

(defn sha256 [^js blob]
  (-> (.arrayBuffer blob)
      (.then #(js/crypto.subtle.digest "SHA-256" %))
      (.then hex)))

(defn- fail! [status]
  (throw (ex-info "upload failed" {:status status})))

(defn- ensure-created [^js rec]
  (if (.-created rec)
    (js/Promise.resolve rec)
    (-> (api/request "PUT" (str "/app/api/recordings/" (.-id rec))
                     {:client_id (.-client_id rec) :profile (.-profile rec)
                      :title (.-title rec) :mime_type (.-mime_type rec)
                      :started_at (.-started_at rec)})
        (.then (fn [{:keys [status body]}]
                 (if (= 200 status)
                   (do (set! (.-created rec) true)
                       (.then (idb/put! "recordings" rec) (constantly rec)))
                   (if (#{415 422} status)
                     ;; Not retryable: keep the audio, show the reason.
                     (do (set-progress! (.-id rec) {:error (get-in body [:error :message])})
                         (fail! status))
                     (fail! status))))))))

(defn- upload-part [^js rec ^js part]
  (-> (api/request "PUT" (str "/app/api/recordings/" (.-id rec) "/parts/" (.-seq part))
                   (.-blob part) {"X-Part-SHA256" (.-sha part)})
      (.then (fn [{:keys [status]}]
               (if (= 200 status)
                 (do (set! (.-uploaded part) true)
                     (idb/put! "parts" part))
                 (fail! status))))))

(defn- upload-parts
  "Upload pending PARTS two at a time."
  [rec parts]
  (let [pending (filterv #(not (.-uploaded ^js %)) parts)
        total (count parts)
        done (atom (- total (count pending)))
        queue (atom pending)
        worker (fn worker []
                 (if-let [p (first @queue)]
                   (do (swap! queue rest)
                       (-> (upload-part rec p)
                           (.then (fn []
                                    (swap! done inc)
                                    (set-progress! (.-id rec) {:uploaded @done :total total})
                                    (worker)))))
                   (js/Promise.resolve nil)))]
    (set-progress! (.-id rec) {:uploaded @done :total total})
    (js/Promise.all #js [(worker) (worker)])))

(defn- finish [^js rec parts]
  (-> (api/request "POST" (str "/app/api/recordings/" (.-id rec) "/finish")
                   {:part_count (.-part_count rec) :ended_at (.-ended_at rec)
                    :duration_ms (.-duration_ms rec) :notes (.-notes rec)})
      (.then (fn [{:keys [status body]}]
               (case status
                 200 (-> (idb/delete-recording! (.-id rec))
                         (.then (fn []
                                  (swap! state update :progress dissoc (.-id rec))
                                  (swap! state assoc :last-finished (.-id rec))
                                  (notify!))))
                 409 (if-let [missing (seq (get-in body [:error :missing]))]
                       ;; The server lost or never got some parts: send them again.
                       (let [m (set missing)]
                         (-> (js/Promise.all
                              (into-array (for [^js p parts :when (m (.-seq p))]
                                            (do (set! (.-uploaded p) false)
                                                (idb/put! "parts" p)))))
                             (.then #(fail! :retry))))
                       (fail! status))
                 (fail! status))))))

(defn- process [^js rec]
  (-> (ensure-created rec)
      (.then #(idb/parts-for (.-id rec)))
      (.then (fn [parts] (.then (upload-parts rec parts) (constantly parts))))
      (.then (fn [parts]
               (when (and (.-stopped rec) (= (count parts) (.-part_count rec)))
                 (finish rec parts))))))

(declare kick!)

(defn- schedule-retry! []
  (let [{:keys [backoff timer]} @state]
    (when timer (js/clearTimeout timer))
    (swap! state assoc
           :backoff (min 60000 (* 2 backoff))
           :timer (js/setTimeout kick! backoff))))

(defn- drain []
  (-> (idb/get-all "recordings")
      (.then (fn [recs]
               (reduce (fn [p rec]
                         (.then p #(-> (process rec)
                                       (.catch (fn [e]
                                                 ;; A refused recording keeps its audio and
                                                 ;; shows its error, but does not block others.
                                                 (when-not (#{415 422} (:status (ex-data e)))
                                                   (throw e)))))))
                       (js/Promise.resolve nil)
                       (sort-by #(.-started_at ^js %) recs))))))

(defn kick!
  "Start draining the queue now (or right after the current drain)."
  []
  (if (:running @state)
    (swap! state assoc :again true)
    (do
      (swap! state assoc :running true :again false)
      (-> (drain)
          (.then (fn []
                   (swap! state assoc :backoff 1000 :error nil :login-required false)))
          (.catch (fn [e]
                    (let [status (:status (ex-data e))]
                      (cond
                        (= 401 status) (swap! state assoc :login-required true)
                        (= 403 status) (api/refresh-csrf!)
                        :else nil)
                      (swap! state assoc :error (if (number? status) (str "HTTP " status) "offline"))
                      (when (not= 401 status) (schedule-retry!)))))
          (.finally (fn []
                      (swap! state assoc :running false)
                      (notify!)
                      (when (:again @state) (kick!))))))))

(defn add-part!
  "Store slice BLOB as part SEQ of recording RID, then kick the queue."
  [rid seq blob]
  (-> (sha256 blob)
      (.then (fn [sha]
               (idb/put! "parts" #js {:rid rid :seq seq :blob blob :sha sha :uploaded false})))
      (.then kick!)))
