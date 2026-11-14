(ns muesli.pwa.recorder
  "MediaRecorder capture in 5 s slices, wake lock, and a level meter.
  The slices form one continuous stream: concatenated in order on the
  server they make a valid file."
  (:require [muesli.pwa.idb :as idb]
            [muesli.pwa.queue :as queue]))

(def slice-ms 5000)

(def candidate-types
  ["audio/webm;codecs=opus" "audio/mp4;codecs=mp4a.40.2" "audio/mp4" "audio/ogg;codecs=opus"])

(defn supported? []
  (and (exists? js/MediaRecorder)
       (exists? js/navigator.mediaDevices)
       (exists? js/navigator.mediaDevices.getUserMedia)))

(defn pick-type []
  (or (first (filter #(.isTypeSupported js/MediaRecorder %) candidate-types)) ""))

;; :rec MediaRecorder, :stream, :id, :seq, :started (ms), :elapsed (ms
;; before the current run), :run-start, :paused, :wake, :audio-ctx, :analyser
(defonce current (atom nil))

(defn elapsed-ms []
  (when-let [{:keys [elapsed run-start paused]} @current]
    (+ elapsed (if paused 0 (- (js/Date.now) run-start)))))

(defn- request-wake-lock! []
  (when (exists? js/navigator.wakeLock)
    (-> (.request js/navigator.wakeLock "screen")
        (.then #(swap! current (fn [c] (when c (assoc c :wake %)))))
        (.catch (fn [_] nil)))))

(defn- on-visibility []
  (when (and @current (= "visible" js/document.visibilityState))
    (request-wake-lock!)))

(defonce _vis (js/document.addEventListener "visibilitychange" on-visibility))

(defn level
  "Current input level 0..1 (RMS), or 0."
  []
  (if-let [^js an (:analyser @current)]
    (let [buf (js/Float32Array. (.-fftSize an))]
      (.getFloatTimeDomainData an buf)
      (let [sum (areduce buf i acc 0.0 (+ acc (* (aget buf i) (aget buf i))))]
        (min 1 (* 3 (js/Math.sqrt (/ sum (.-length buf)))))))
    0))

(defn- setup-meter [stream]
  (try
    (let [Ctx (or js/window.AudioContext js/window.webkitAudioContext)
          ctx (Ctx.)
          src (.createMediaStreamSource ctx stream)
          an (.createAnalyser ctx)]
      (set! (.-fftSize an) 1024)
      (.connect src an)
      ;; Created after an await, so some browsers start it suspended.
      (when (= "suspended" (.-state ctx)) (.catch (.resume ctx) (fn [_] nil)))
      [ctx an])
    (catch :default _ [nil nil])))

(defn start!
  "Ask for the mic and start recording into a new recording with META
  {:client_id :profile :title}.  Resolves to the recording id."
  [{:keys [client_id profile title]}]
  (-> (js/navigator.mediaDevices.getUserMedia
       #js {:audio #js {:echoCancellation false :noiseSuppression false
                        :autoGainControl true :channelCount 1}})
      (.then
       (fn [stream]
         (let [mime (pick-type)
               rec (js/MediaRecorder. stream (clj->js (cond-> {:audioBitsPerSecond 32000}
                                                        (seq mime) (assoc :mimeType mime))))
               id (str (random-uuid))
               now (js/Date.now)
               [actx an] (setup-meter stream)]
           (reset! current {:rec rec :stream stream :id id :seq 0 :started now
                            :elapsed 0 :run-start now :paused false
                            :audio-ctx actx :analyser an})
           (set! (.-ondataavailable rec)
                 (fn [^js e]
                   (when (pos? (.-size (.-data e)))
                     (let [n (:seq @current)]
                       (swap! current update :seq inc)
                       (queue/add-part! id n (.-data e))))))
           (.start rec slice-ms)
           (request-wake-lock!)
           (-> (idb/put! "recordings"
                         #js {:id id :client_id client_id :profile profile :title title
                              :mime_type (or (not-empty (.-mimeType rec)) mime "audio/webm")
                              :started_at now :created false :stopped false})
               (.then (fn [] (queue/kick!) id))))))))

(defn pause! []
  (when-let [{:keys [^js rec paused elapsed run-start]} @current]
    (when-not paused
      (.pause rec)
      (swap! current assoc :paused true :elapsed (+ elapsed (- (js/Date.now) run-start))))))

(defn resume! []
  (when-let [{:keys [^js rec paused]} @current]
    (when paused
      (.resume rec)
      (swap! current assoc :paused false :run-start (js/Date.now)))))

(defn stop!
  "Stop recording, flush the last slice and mark the recording finished
  locally with NOTES.  Resolves once that is stored."
  [notes]
  (if-let [{:keys [^js rec ^js stream id ^js wake ^js audio-ctx stopping]} @current]
    (if stopping
      (js/Promise.resolve nil)
    (js/Promise.
     (fn [resolve _]
       (let [duration (elapsed-ms)]
         (set! (.-onstop rec)
               (fn []
                 ;; ondataavailable for the last slice fires before onstop;
                 ;; give its IndexedDB write a moment to start.
                 (js/setTimeout
                  (fn []
                    (let [n (:seq @current)]
                      (doseq [t (.getTracks stream)] (.stop t))
                      (when wake (.catch (.release wake) (fn [_] nil)))
                      (when audio-ctx (.catch (.close audio-ctx) (fn [_] nil)))
                      (reset! current nil)
                      (-> (idb/update-recording! id #js {:stopped true :part_count n
                                                         :ended_at (js/Date.now)
                                                         :duration_ms duration
                                                         :notes notes})
                          (.then (fn [] (queue/kick!) (resolve id))))))
                  300)))
         (swap! current assoc :stopping true)
         (.stop rec)))))
    (js/Promise.resolve nil)))

(defn recording? [] (some? @current))
(defn paused? [] (boolean (:paused @current)))
(defn current-id [] (:id @current))
