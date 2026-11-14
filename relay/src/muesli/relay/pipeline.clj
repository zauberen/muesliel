(ns muesli.relay.pipeline
  "Server-side transcription (Spec 3 §4.4).

  - A *segmenter* per recording that is receiving parts: one ffmpeg
    process reading the parts in order on stdin and writing
    `chunk-seconds` WAV chunks, exactly like `muesli-record-ffmpeg`.
  - A tick (every second) that transcribes pending chunks, finalizes
    finished recordings, diarizes them and marks them `transcribed`.

  All state that matters is in the database; the segmenters are in
  memory and rebuilt from the part files after a restart."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.tools.logging :as log]
            [muesli.relay.db :as db]
            [muesli.relay.storage :as storage]
            [muesli.relay.stt :as stt])
  (:import (java.io File IOException OutputStream)
           (java.lang ProcessBuilder$Redirect)
           (java.util.concurrent ExecutorService Executors ScheduledExecutorService TimeUnit)))

;;;; State

(defn state
  "Create pipeline state.  OPTS: :sync? runs work inline (tests),
  :stt-fn (fn [file] [:ok response]) and :diarize-fn
  (fn [file speakers] [:ok turns]) replace the HTTP calls."
  [opts]
  (merge {:segmenters (atom {})
          :busy (atom #{})
          :active (atom 0)
          :pool (when-not (:sync? opts) (Executors/newCachedThreadPool))}
         opts))

(defn- cfg [ctx k] (get-in ctx [:cfg k]))
(defn- root [ctx] (get-in ctx [:cfg :storage :dir]))
(defn- ffmpeg [ctx] (or (cfg ctx :ffmpeg) "ffmpeg"))

(defn- submit! [ctx f]
  (if-let [^ExecutorService pool (get-in ctx [:pipeline :pool])]
    (.submit pool ^Runnable f)
    (f)))

(defn- run-exclusive!
  "Run F for recording ID unless work on it is already running."
  [ctx id f]
  (let [busy (get-in ctx [:pipeline :busy])]
    (when (= ::claimed (locking busy
                         (when-not (@busy id) (swap! busy conj id) ::claimed)))
      (submit! ctx (fn []
                     (try (f)
                          (catch Throwable t (log/error t "pipeline work failed for" id))
                          (finally (swap! busy disj id))))))))

(defn- fail! [ctx id step msg]
  (log/warn "recording" id "failed while" step ":" msg)
  (db/update-recording! (:ds ctx) id {:status "failed" :failed_step step :error (str msg)}))

;;;; WAV

(defn wav-duration-ms
  "Duration of the PCM WAV FILE from its header and size, or nil.  A data
  size of 0 or one past the end (a header ffmpeg has not finalized yet)
  falls back to the file size."
  [^File file]
  (try
    (let [bs (java.nio.file.Files/readAllBytes (.toPath file))
          buf (doto (java.nio.ByteBuffer/wrap bs) (.order java.nio.ByteOrder/LITTLE_ENDIAN))
          len (alength bs)
          tag (fn [at] (String. bs (int at) 4 "US-ASCII"))]
      (when (and (>= len 12) (= "RIFF" (tag 0)) (= "WAVE" (tag 8)))
        (loop [at 12 rate nil align nil]
          (when (<= (+ at 8) len)
            (let [id (tag at)
                  size (bit-and (.getInt buf (int (+ at 4))) 0xffffffff)
                  body (+ at 8)]
              (case id
                "fmt " (recur (+ body size (mod size 2))
                              (.getInt buf (int (+ body 4)))
                              (bit-and (.getShort buf (int (+ body 12))) 0xffff))
                "data" (when (and rate align (pos? rate) (pos? align))
                         (let [avail (- len body)
                               bytes (if (or (zero? size) (> size avail)) avail size)]
                           (quot (* 1000 bytes) (* rate align))))
                (recur (+ body size (mod size 2)) rate align)))))))
    (catch Exception _ nil)))

;;;; Segmenter

(defn- chunk-files
  "[[chunk-no file] ...] of the chunk WAVs in DIR, in order."
  [^File dir]
  (->> (.listFiles dir)
       (keep (fn [^File f]
               (when-let [[_ n] (re-matches #"mic-(\d{5})\.wav" (.getName f))]
                 [(parse-long n) f])))
       (sort-by first)
       vec))

(defn- start-segmenter!
  [ctx rec]
  (let [dir (io/file (storage/recording-dir (root ctx) (:user_id rec) (:id rec))
                     (str "chunks-" (System/currentTimeMillis)))
        secs (get-in ctx [:cfg :transcription :chunk-seconds] 30)
        cmd [(ffmpeg ctx) "-hide_banner" "-nostats" "-loglevel" "error" "-y"
             "-i" "pipe:0" "-map" "0:a:0" "-ac" "1" "-ar" "16000" "-c:a" "pcm_s16le"
             "-f" "segment" "-segment_time" (str secs) "-segment_format" "wav"
             "-reset_timestamps" "1" (str (io/file dir "mic-%05d.wav"))]]
    (.mkdirs dir)
    (let [p (-> (ProcessBuilder. ^java.util.List cmd)
                (.redirectOutput ProcessBuilder$Redirect/DISCARD)
                (.redirectError (io/file dir "ffmpeg.log"))
                (.start))]
      (log/info "segmenter started for" (:id rec) "in" (.getName dir))
      {:proc p :in (.getOutputStream p) :dir dir :lock (Object.)
       :next-seq (atom 0) :closed (atom false) :broken (atom nil)})))

(defn- segmenter! [ctx rec]
  (let [segs (get-in ctx [:pipeline :segmenters])]
    (locking segs
      (or (get @segs (:id rec))
          (let [s (start-segmenter! ctx rec)]
            (swap! segs assoc (:id rec) s)
            s)))))

(defn- ffmpeg-log [seg]
  (let [f (io/file (:dir seg) "ffmpeg.log")]
    (if (.isFile f) (str/trim (slurp f)) "")))

(defn- register-chunks!
  "Add a chunks row for every complete chunk of SEG not yet known."
  [ctx rec seg]
  (locking (:lock seg)
    (let [ds (:ds ctx)
          id (:id rec)
          files (chunk-files (:dir seg))
          exited (not (.isAlive ^Process (:proc seg)))
          complete (if exited files (butlast files))
          known (db/chunk-numbers ds id)]
      (doseq [[n ^File f] complete :when (not (known n))]
        (let [prev (when (pos? n) (db/chunk ds id (dec n)))
              offset (if prev (+ (:offset_ms prev) (:duration_ms prev)) 0)
              duration (or (wav-duration-ms f) 0)]
          (if (and (pos? n) (nil? prev))
            (log/warn "chunk" n "of" id "has no predecessor; skipping registration")
            (db/add-chunk! ds {:recording-id id :chunk-no n :path (str f)
                               :status (if (< duration 200) "done" "pending")
                               :offset-ms offset :duration-ms duration})))))))

(defn feed!
  "Write the parts of REC that are on disk and not yet fed to its
  segmenter, in order, then register finished chunks."
  [ctx rec]
  (when (:pipeline ctx)
    (let [seg (segmenter! ctx rec)]
      (locking (:lock seg)
        (loop []
          (let [n @(:next-seq seg)
                f (storage/part-file (root ctx) (:user_id rec) (:id rec) n)]
            (when (and (nil? @(:broken seg)) (not @(:closed seg)) (.isFile f))
              (try
                (with-open [in (io/input-stream f)]
                  (io/copy in ^OutputStream (:in seg)))
                (.flush ^OutputStream (:in seg))
                (swap! (:next-seq seg) inc)
                (catch IOException e
                  (reset! (:broken seg) (or (.getMessage e) "ffmpeg stopped reading"))
                  (log/warn "segmenter for" (:id rec) "broke:" (.getMessage e))))
              (recur)))))
      (register-chunks! ctx rec seg)
      seg)))

(defn drop-recording!
  "Stop any segmenter of recording ID (discard, delete)."
  [ctx id]
  (when-let [segs (get-in ctx [:pipeline :segmenters])]
    (when-let [seg (get @segs id)]
      (swap! segs dissoc id)
      (.destroyForcibly ^Process (:proc seg)))))

;;;; Finishing

(defn finish-with-parts!
  "Finish recording R with the contiguous parts received so far (the
  phone is gone).  Used by `stop` and the tick."
  [ctx r]
  (let [have (set (db/part-seqs (:ds ctx) (:id r)))
        n (count (take-while have (range)))]
    (log/info "finishing" (:id r) "without the phone after" n "parts")
    (db/update-recording! (:ds ctx) (:id r)
                          {:status "processing" :part_count n :ended_at (db/now)})))

(defn- finalize!
  "Close the segmenter of processing recording R, register its last
  chunks, assemble the audio file and set chunks_complete."
  [ctx r]
  (let [ds (:ds ctx)
        id (:id r)
        n (or (:part_count r) 0)
        audio (storage/audio-file (root ctx) r)
        parts-dir (io/file (storage/recording-dir (root ctx) (:user_id r) id) "parts")]
    (cond
      (zero? n)
      (db/update-recording! ds id {:chunks_complete 1})

      ;; Assembled before a crash: the chunks were complete by then.
      (and (.isFile audio) (empty? (.listFiles parts-dir)))
      (db/update-recording! ds id {:chunks_complete 1})

      :else
      (let [seg (feed! ctx r)]
        (locking (:lock seg)
          (reset! (:closed seg) true)
          (try (.close ^OutputStream (:in seg)) (catch IOException _ nil)))
        (let [^Process p (:proc seg)]
          (when-not (.waitFor p 10 TimeUnit/MINUTES)
            (.destroyForcibly p))
          (register-chunks! ctx r seg)
          (swap! (get-in ctx [:pipeline :segmenters]) dissoc id)
          (cond
            (< @(:next-seq seg) n)
            (fail! ctx id "transcribing" (format "only %d of %d parts are on the relay" @(:next-seq seg) n))

            (empty? (db/chunk-numbers ds id))
            (fail! ctx id "transcribing"
                   (str "ffmpeg could not decode the recording"
                        (let [l (ffmpeg-log seg)] (when (seq l) (str ": " (subs l 0 (min 300 (count l))))))))

            :else
            (let [{:keys [bytes sha256]} (storage/assemble! (root ctx) r n)]
              (db/update-recording! ds id {:chunks_complete 1 :bytes bytes :sha256 sha256}))))))))

;;;; Transcribing

(defn- transcribe-chunk! [ctx c]
  (let [ds (:ds ctx)
        tcfg (get-in ctx [:cfg :transcription])
        stt-fn (or (get-in ctx [:pipeline :stt-fn]) #(stt/transcribe tcfg %))
        {:keys [recording_id chunk_no attempts offset_ms duration_ms]} c
        [tag v] (try (stt-fn (io/file (:path c)))
                     (catch Throwable t [:error (str t)]))]
    (if (= tag :ok)
      (let [segs (mapv (fn [s] (-> s (update :start_ms + offset_ms) (update :end_ms + offset_ms)
                                   (update :words (fn [ws] (mapv (fn [[a b w]] [(+ a offset_ms) (+ b offset_ms) w]) ws)))))
                       (stt/parse-transcription v duration_ms))]
        (db/chunk-transcribed! ds recording_id chunk_no segs))
      (let [max-attempts (:max-attempts tcfg 4)
            delay-ms (* 1000 (:retry-delay-seconds tcfg 5) (bit-shift-left 1 (max 0 (dec attempts))))]
        (log/warn "chunk" chunk_no "of" recording_id "attempt" attempts "failed:" v)
        (db/update-chunk! ds recording_id chunk_no
                          (if (>= attempts max-attempts)
                            {:status "failed" :error (str v)}
                            {:status "pending" :error (str v) :not_before (+ (db/now) delay-ms)}))))))

(defn- decode-wav!
  "Decode the assembled audio of R to a 16 kHz mono WAV.  Returns the file."
  ^File [ctx r]
  (let [audio (storage/audio-file (root ctx) r)
        out (io/file (.getParentFile audio) "diarize.wav")
        p (-> (ProcessBuilder. ^java.util.List
                               [(ffmpeg ctx) "-hide_banner" "-nostats" "-loglevel" "error" "-y"
                                "-i" (str audio) "-map" "0:a:0" "-ac" "1" "-ar" "16000"
                                "-c:a" "pcm_s16le" (str out)])
              (.redirectErrorStream true)
              (.start))
        log-text (slurp (.getInputStream p))]
    (when-not (and (zero? (.waitFor p)) (.isFile out))
      (throw (ex-info (str "ffmpeg could not decode the audio: " (str/trim log-text)) {})))
    out))

(defn- complete!
  "All chunks of processing recording R are settled: fail, or diarize and
  mark it transcribed."
  [ctx r]
  (let [ds (:ds ctx)
        id (:id r)
        counts (db/chunk-counts ds id)
        dcfg (get-in ctx [:cfg :diarization])
        backend (keyword (or (:backend dcfg) :none))
        diarize-fn (or (get-in ctx [:pipeline :diarize-fn])
                       #(stt/diarize dcfg (get-in ctx [:cfg :transcription]) %1 %2))
        segs (db/segments ds id)
        last-chunk (db/last-chunk ds id)]
    (if (pos? (:failed counts))
      (fail! ctx id "transcribing"
             (format "%d chunk(s) failed to transcribe: %s" (:failed counts)
                     (or (:error (db/q1 ds ["SELECT error FROM chunks WHERE recording_id = ? AND status = 'failed'
                                              ORDER BY chunk_no LIMIT 1" id]))
                         "unknown error")))
      (let [diarized
            (if (or (= backend :none) (empty? segs))
              [:ok nil]
              (let [wav (try (decode-wav! ctx r) (catch Exception e e))]
                (if (instance? Exception wav)
                  [:error (.getMessage ^Exception wav)]
                  (try
                    (let [[tag turns :as res] (diarize-fn wav (:speakers r))]
                      (if (= tag :ok)
                        [:ok (stt/assign-speakers segs turns (:split-threshold dcfg 0.3))]
                        res))
                    (finally (.delete ^File wav))))))]
        (if (= :error (first diarized))
          (fail! ctx id "diarizing" (second diarized))
          (do (when-let [labelled (second diarized)]
                (db/replace-all-segments! ds id labelled))
              (db/update-recording! ds id
                                    (cond-> {:status "transcribed" :failed_step nil :error nil}
                                      (and (nil? (:duration_ms r)) last-chunk)
                                      (assoc :duration_ms (+ (:offset_ms last-chunk) (:duration_ms last-chunk)))))
              (log/info "recording" id "transcribed:" (db/segment-count ds id) "segments")))))))

;;;; Tick

(defn tick!
  "One pass: phone-gone stops, chunk registration, finalizing,
  completion and STT uploads."
  [ctx]
  (let [ds (:ds ctx)
        p (:pipeline ctx)
        now (db/now)
        gone-ms (* 1000 (get-in ctx [:cfg :recording :phone-gone-seconds] 60))]
    (doseq [r (db/recordings-in ds ["recording"])
            :when (and (= 1 (:stop_requested r)) (< (or (:last_part_at r) 0) (- now gone-ms)))]
      (drop-recording! ctx (:id r))
      (finish-with-parts! ctx r))
    (doseq [[id seg] @(:segmenters p)]
      (when-let [r (db/recording ds id)]
        (register-chunks! ctx r seg)))
    (doseq [r (db/recordings-in ds ["processing"])]
      (if (zero? (:chunks_complete r))
        (run-exclusive! ctx (:id r) #(finalize! ctx (db/recording ds (:id r))))
        (let [{:keys [pending uploading]} (db/chunk-counts ds (:id r))]
          (when (zero? (+ pending uploading))
            (run-exclusive! ctx (:id r) #(complete! ctx (db/recording ds (:id r))))))))
    (let [free (- (max 1 (get-in ctx [:cfg :transcription :concurrency] 1)) @(:active p))]
      (when (pos? free)
        (doseq [c (db/claim-chunks! ds free now)]
          (swap! (:active p) inc)
          (submit! ctx (fn []
                         (try (transcribe-chunk! ctx c)
                              (catch Throwable t (log/error t "transcription task failed"))
                              (finally (swap! (:active p) dec))))))))))

(defn start
  "Start the tick for CTX (which must hold :pipeline).  Returns the
  scheduler."
  ^ScheduledExecutorService [ctx]
  (db/reset-uploading-chunks! (:ds ctx))
  (let [ex (Executors/newSingleThreadScheduledExecutor)]
    (.scheduleWithFixedDelay ex
                             (fn [] (try (tick! ctx)
                                         (catch Throwable t (log/error t "pipeline tick failed"))))
                             1 1 TimeUnit/SECONDS)
    ex))

(defn stop [ctx ^ScheduledExecutorService ex]
  (.shutdownNow ex)
  (when-let [^ExecutorService pool (get-in ctx [:pipeline :pool])] (.shutdownNow pool))
  (doseq [[_ seg] @(get-in ctx [:pipeline :segmenters])]
    (.destroyForcibly ^Process (:proc seg))))
