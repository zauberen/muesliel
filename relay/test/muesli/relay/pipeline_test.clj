(ns muesli.relay.pipeline-test
  "Server-side transcription with real ffmpeg and real WebM/Opus audio
  cut into parts at arbitrary byte boundaries (as MediaRecorder slices
  are).  Speech to text and diarization are faked."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing use-fixtures]]
            [muesli.relay.auth :as auth]
            [muesli.relay.config :as config]
            [muesli.relay.db :as db]
            [muesli.relay.handler :as handler]
            [muesli.relay.pipeline :as pipeline]
            [muesli.relay.relay-test :as rt]
            [muesli.relay.stt :as stt])
  (:import (java.io File)
           (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

;;;; Fixture

(def ^:dynamic *dir* nil)

(def fake-turns
  "Speaker A for the first 12 s, B afterwards."
  [["A" 0 12000] ["B" 12000 1000000]])

(defn- fake-stt [^File f]
  ;; Each chunk says one thing at 0.5-2.0 s, with word timestamps.
  [:ok {:text "x"
        :segments [{:start 0.5 :end 2.0 :text (str "said in " (.getName f))
                    :words [{:word "said" :start 0.5 :end 1.0}
                            {:word "in" :start 1.0 :end 1.5}
                            {:word (.getName f) :start 1.5 :end 2.0}]}]}])

(def ^:dynamic *stt* fake-stt)
(def ^:dynamic *diarize* (fn [_ _] [:ok fake-turns]))

(defn- ctx-with-pipeline [dir overrides]
  (let [cfg (config/load-config
             (merge-with merge
                         {:db {:file (str (io/file dir "relay.sqlite"))}
                          :storage {:dir (str (io/file dir "audio"))
                                    :max-part-bytes 1048576 :max-recording-bytes 104857600}
                          :session {:secret "test-secret"}
                          :base-url "http://localhost:8787"
                          :behind-proxy false
                          :transcription {:chunk-seconds 10 :concurrency 2 :max-attempts 2
                                          :retry-delay-seconds 0}
                          :diarization {:backend :localai :split-threshold 0.3}
                          :recording {:phone-gone-seconds 60}}
                         overrides))
        ds (db/datasource (get-in cfg [:db :file]))]
    {:cfg cfg :ds ds
     :pipeline (pipeline/state {:sync? true
                                :stt-fn #(*stt* %)
                                :diarize-fn #(*diarize* %1 %2)})}))

(defn with-pipeline [f]
  (let [dir (.toFile (Files/createTempDirectory "relay-pipe" (into-array FileAttribute [])))
        ctx (ctx-with-pipeline dir {})]
    (auth/clear-all-attempts!)
    (try
      (binding [rt/*ctx* ctx rt/*app* (handler/handler ctx) *dir* dir]
        (f))
      (finally
        (doseq [[_ seg] @(get-in ctx [:pipeline :segmenters])]
          (.destroyForcibly ^Process (:proc seg)))
        (doseq [^File x (reverse (file-seq dir))] (.delete x))))))

(use-fixtures :each with-pipeline)

;;;; Helpers

(defn- webm-parts
  "SECONDS of a tone as WebM/Opus, cut into byte slices of about N bytes."
  [seconds n]
  (let [f (io/file *dir* (str "tone-" seconds ".webm"))
        p (.start (ProcessBuilder. ^java.util.List
                                   ["ffmpeg" "-hide_banner" "-loglevel" "error" "-y" "-f" "lavfi"
                                    "-i" (str "sine=frequency=440:duration=" seconds)
                                    "-c:a" "libopus" "-b:a" "32k" (str f)]))]
    (is (zero? (.waitFor p)) "ffmpeg can make test audio")
    (let [bs (Files/readAllBytes (.toPath f))]
      (mapv #(java.util.Arrays/copyOfRange bs (int %) (int (min (alength bs) (+ % n))))
            (range 0 (alength bs) n)))))

(defn- put-part! [s id i ^bytes p]
  (rt/app-req s :put (str "/app/api/recordings/" id "/parts/" i) p {"x-part-sha256" (@#'rt/sha256 p)}))

(defn- json [r] (@#'rt/json-body r))

(defn- tick-until
  "Run pipeline ticks until (PRED) or N ticks; return (PRED)."
  [pred & [n]]
  (loop [i 0]
    (cond (pred) (pred)
          (>= i (or n 50)) (pred)
          :else (do (pipeline/tick! rt/*ctx*) (Thread/sleep 20) (recur (inc i))))))

(defn- status-of [k id]
  (json (rt/client-req k :get (str "/api/v1/client/recordings/" id))))

(defn- finish! [s id n]
  (rt/app-req s :post (str "/app/api/recordings/" id "/finish")
              {:part_count n :ended_at 1700000060000 :duration_ms 25000 :notes "phone notes"}))

(defn- about=
  "XS and YS are equal within 100 ms each."
  [xs ys]
  (and (= (count xs) (count ys))
       (every? true? (map #(<= (abs (- %1 %2)) 100) xs ys))))

;;;; Unit tests

(deftest parse-transcription-shapes
  (is (= [{:start_ms 0 :end_ms 3000 :text "hello" :words []}]
         (stt/parse-transcription "hello" 3000)))
  (is (= [{:start_ms 0 :end_ms 3000 :text "hi there" :words [[0 500 "hi"] [500 900 "there"]]}]
         (stt/parse-transcription {:text " hi there " :words [{:word "hi" :start 0 :end 0.5}
                                                              {:word "there" :start 0.5 :end 0.9}]}
                                  3000)))
  (testing "top-level words go to the segment they fall in; empty text is dropped"
    (is (= [{:start_ms 0 :end_ms 1000 :text "a" :words [[100 200 "a"]]}
            {:start_ms 1000 :end_ms 2000 :text "b" :words [[1100 1200 "b"]]}]
           (stt/parse-transcription {:segments [{:start 0 :end 1 :text "a"}
                                                {:start 1 :end 2 :text "b"}
                                                {:start 2 :end 3 :text "  "}]
                                     :words [{:word "a" :start 0.1 :end 0.2}
                                             {:word "b" :start 1.1 :end 1.2}]}
                                    3000)))))

(deftest speaker-assignment
  (let [turns [["mic:A" 0 1000] ["mic:B" 1000 2000]]]
    (testing "a segment inside one turn"
      (is (= ["mic:A"] (map :speaker (stt/assign-segment {:start_ms 100 :end_ms 800 :text "x" :words []}
                                                          turns 0.3)))))
    (testing "a straddling segment is split at words"
      (is (= [["mic:A" "one two"] ["mic:B" "three"]]
             (map (juxt :speaker :text)
                  (stt/assign-segment {:chunk_no 0 :start_ms 200 :end_ms 1800 :text "one two three"
                                       :words [[200 500 "one"] [500 900 "two"] [1100 1800 "three"]]}
                                      turns 0.3)))))
    (testing "outside every turn: the nearest one"
      (is (= ["mic:B"] (map :speaker (stt/assign-segment {:start_ms 2500 :end_ms 2600 :text "x"} turns 0.3)))))
    (is (= [["S1" 0 1500]] (stt/parse-turns {:segments [{:speaker "S1" :start 0 :end 1.5}
                                                             {:start 3 :end 4}]})))))

;;;; End to end through the HTTP API

(deftest phone-recording-is-transcribed-live
  (let [{:keys [s k client-id]} (rt/setup!)
        parts (webm-parts 25 3000)
        id (str (random-uuid))]
    (is (= 200 (:status (rt/app-req s :put (str "/app/api/recordings/" id)
                                    {:client_id client-id :profile "standup" :title "Standup"
                                     :mime_type "audio/webm;codecs=opus" :started_at 1700000000000}))))
    (testing "chunks are transcribed while the phone is still recording"
      (doseq [[i p] (map-indexed vector parts)]
        (is (= 200 (:status (put-part! s id i p)))))
      (is (tick-until #(pos? (get-in (status-of k id) [:chunks :done] 0))))
      (let [st (status-of k id)]
        (is (= "recording" (:status st)))
        (is (pos? (:segments st)))
        (is (= "said in mic-00000.wav"
               (:text (first (json (rt/client-req k :get (str "/api/v1/client/recordings/" id "/segments")))))))))
    (testing "after finish: all chunks, diarized, transcribed"
      (is (= 200 (:status (finish! s id (count parts)))))
      (is (= "transcribed" (tick-until #(#{"transcribed" "failed"} (:status (status-of k id))))))
      (let [st (status-of k id)
            segs (json (rt/client-req k :get (str "/api/v1/client/recordings/" id "/segments")))]
        (is (= {:done 3 :failed 0 :pending 0 :uploading 0 :total 3} (:chunks st)))
        (is (= [["mic:A" "said in mic-00000.wav"]
                ["mic:A" "said in mic-00001.wav"]
                ["mic:B" "said in mic-00002.wav"]]
               (map (juxt :speaker :text) segs)))
        (testing "times are shifted by the real chunk offsets (Opus frames make them ~10.01 s)"
          (is (about= [500 10500 20500] (map :start_ms segs)))
          (is (about= [20500 21000] (take 2 (first (:words (last segs)))))))
        (testing "after=N returns only newer segments"
          (is (= 1 (count (json (rt/client-req k :get (str "/api/v1/client/recordings/" id
                                                           "/segments?after=" (:id (second segs))))))))))
      (is (= [id] (map :id (json (rt/client-req k :get "/api/v1/client/recordings")))))
      (is (= 1 (:pending (json (rt/client-req k :get "/api/v1/client/ping"))))))
    (testing "the assembled audio is downloadable until ack"
      (let [r (rt/client-req k :get (str "/api/v1/client/recordings/" id "/audio"))]
        (is (= 200 (:status r)))
        (is (= (reduce + (map alength parts)) (alength (@#'rt/body-bytes r))))))
    (testing "ack deletes audio, chunks and transcript"
      (is (= 200 (:status (rt/client-req k :post (str "/api/v1/client/recordings/" id "/ack") {:meeting_id "m"}))))
      (is (empty? (json (rt/client-req k :get (str "/api/v1/client/recordings/" id "/segments")))))
      (is (empty? (filter #(.isFile ^File %) (file-seq (io/file *dir* "audio"))))))))

(deftest emacs-started-meeting
  (let [{:keys [s k]} (rt/setup!)
        parts (webm-parts 12 3000)
        id (str (random-uuid))]
    (testing "Emacs creates a waiting recording; the phone sees it"
      (let [r (rt/client-req k :post "/api/v1/client/recordings" {:id id :title "Standup" :speakers 2})]
        (is (= 200 (:status r)))
        (is (= "waiting" (:status (json r)))))
      (is (= 200 (:status (rt/client-req k :post "/api/v1/client/recordings" {:id id :title "Standup"}))))
      (is (= [{:id id :client_name "laptop" :title "Standup"}]
             (map #(select-keys % [:id :client_name :title])
                  (json (rt/app-req s :get "/app/api/sessions"))))))
    (testing "the phone claims it with the same PUT it uses to create"
      (let [r (rt/app-req s :put (str "/app/api/recordings/" id)
                          {:mime_type "audio/webm;codecs=opus" :started_at 1700000000000})]
        (is (= 200 (:status r)))
        (is (= "recording" (:status (json r)))))
      (is (empty? (json (rt/app-req s :get "/app/api/sessions"))))
      (is (= "recording" (:status (status-of k id)))))
    (testing "Emacs asks to stop; the phone learns it from the next part reply"
      (is (= 200 (:status (put-part! s id 0 (first parts)))))
      (let [st (json (rt/client-req k :post (str "/api/v1/client/recordings/" id "/stop") {}))]
        (is (= "recording" (:status st)))
        (is (true? (:stop_requested st))))
      (is (true? (:stop_requested (json (put-part! s id 1 (second parts)))))))
    (testing "the phone finishes; the relay transcribes with the speaker hint"
      (doseq [[i p] (drop 2 (map-indexed vector parts))] (put-part! s id i p))
      (let [hint (atom nil)]
        (binding [*diarize* (fn [_ n] (reset! hint n) [:ok fake-turns])]
          (is (= 200 (:status (finish! s id (count parts)))))
          (is (= "transcribed" (tick-until #(#{"transcribed" "failed"} (:status (status-of k id)))))))
        (is (= 2 @hint)))
      (is (= ["mic:A" "mic:A"]
             (map :speaker (json (rt/client-req k :get (str "/api/v1/client/recordings/" id "/segments")))))))
    (testing "Emacs-origin recordings do not count as pending imports"
      (is (zero? (:pending (json (rt/client-req k :get "/api/v1/client/ping"))))))))

(deftest stop-when-the-phone-is-gone
  (let [{:keys [s k]} (rt/setup!)
        parts (webm-parts 12 3000)
        id (str (random-uuid))]
    (rt/client-req k :post "/api/v1/client/recordings" {:id id :title "Gone"})
    (rt/app-req s :put (str "/app/api/recordings/" id) {:mime_type "audio/webm" :started_at 1})
    (doseq [i (range 3)] (put-part! s id i (nth parts i)))
    (db/update-recording! (:ds rt/*ctx*) id {:last_part_at 1})
    (testing "stop finishes at once with the parts received"
      (let [st (json (rt/client-req k :post (str "/api/v1/client/recordings/" id "/stop") {}))]
        (is (= "processing" (:status st)))
        (is (= 3 (:part_count (db/recording (:ds rt/*ctx*) id))))))
    (testing "late parts and a late finish from the phone are accepted and dropped"
      (is (:ignored (json (put-part! s id 3 (nth parts 3)))))
      (is (= 200 (:status (finish! s id (count parts)))))
      (is (= "phone notes" (:notes (db/recording (:ds rt/*ctx*) id)))))
    (is (= "transcribed" (tick-until #(#{"transcribed" "failed"} (:status (status-of k id))))))))

(deftest waiting-meeting-cancelled
  (let [{:keys [s k]} (rt/setup!)
        id (str (random-uuid))]
    (rt/client-req k :post "/api/v1/client/recordings" {:id id :title "Never"})
    (is (= "abandoned" (:status (json (rt/client-req k :post (str "/api/v1/client/recordings/" id "/stop") {})))))
    (is (= 410 (:status (rt/app-req s :put (str "/app/api/recordings/" id)
                                    {:mime_type "audio/webm" :started_at 1}))))
    (testing "abort deletes it"
      (is (= 200 (:status (rt/client-req k :delete (str "/api/v1/client/recordings/" id)))))
      (is (nil? (db/recording (:ds rt/*ctx*) id))))))

(deftest failures-and-retry
  (let [{:keys [s k]} (rt/setup!)
        parts (webm-parts 15 3000)
        run! (fn [id]
               (rt/client-req k :post "/api/v1/client/recordings" {:id id})
               (rt/app-req s :put (str "/app/api/recordings/" id) {:mime_type "audio/webm" :started_at 1})
               (doseq [[i p] (map-indexed vector parts)] (put-part! s id i p))
               (finish! s id (count parts)))]
    (testing "a chunk that keeps failing fails the recording; retry with skip goes on without it"
      (let [id (str (random-uuid))]
        (binding [*stt* (fn [^File f] (if (str/includes? (.getName f) "00001")
                                        [:error "HTTP 500: boom"]
                                        (fake-stt f)))]
          (run! id)
          (is (= "failed" (tick-until #(#{"transcribed" "failed"} (:status (status-of k id))))))
          (let [st (status-of k id)]
            (is (= "transcribing" (:failed_step st)))
            (is (str/includes? (:error st) "boom"))
            (is (= 1 (get-in st [:chunks :failed]))))
          (is (= "processing" (:status (json (rt/client-req k :post (str "/api/v1/client/recordings/" id "/retry")
                                                            {:skip true})))))
          (is (= "transcribed" (tick-until #(#{"transcribed" "failed"} (:status (status-of k id)))))))
        (is (= 1 (count (json (rt/client-req k :get (str "/api/v1/client/recordings/" id "/segments"))))))))
    (testing "a diarization error; plain retry runs it again"
      (let [id (str (random-uuid))
            calls (atom 0)]
        (binding [*diarize* (fn [_ _] (if (= 1 (swap! calls inc)) [:error "no model"] [:ok fake-turns]))]
          (run! id)
          (is (= "failed" (tick-until #(#{"transcribed" "failed"} (:status (status-of k id))))))
          (is (= "diarizing" (:failed_step (status-of k id))))
          (rt/client-req k :post (str "/api/v1/client/recordings/" id "/retry") {})
          (is (= "transcribed" (tick-until #(#{"transcribed" "failed"} (:status (status-of k id))))))
          (is (= 2 @calls)))))
    (testing "undecodable audio fails clearly"
      (let [id (str (random-uuid))]
        (rt/client-req k :post "/api/v1/client/recordings" {:id id})
        (rt/app-req s :put (str "/app/api/recordings/" id) {:mime_type "audio/webm" :started_at 1})
        (put-part! s id 0 (.getBytes "definitely not audio"))
        (finish! s id 1)
        (is (= "failed" (tick-until #(#{"transcribed" "failed"} (:status (status-of k id))))))
        (is (str/includes? (:error (status-of k id)) "ffmpeg"))))))

(deftest restart-rebuilds-the-segmenter
  (let [{:keys [s k]} (rt/setup!)
        parts (webm-parts 25 3000)
        id (str (random-uuid))
        half (quot (count parts) 2)]
    (rt/client-req k :post "/api/v1/client/recordings" {:id id})
    (rt/app-req s :put (str "/app/api/recordings/" id) {:mime_type "audio/webm" :started_at 1})
    (doseq [i (range half)] (put-part! s id i (nth parts i)))
    (tick-until #(pos? (get-in (status-of k id) [:chunks :total] 0)))
    (testing "losing the in-memory segmenter (a relay restart) loses nothing"
      (pipeline/drop-recording! rt/*ctx* id)
      (doseq [i (range half (count parts))] (put-part! s id i (nth parts i)))
      (finish! s id (count parts))
      (is (= "transcribed" (tick-until #(#{"transcribed" "failed"} (:status (status-of k id))))))
      (is (about= [0 10000 20000]
             (map :offset_ms (db/q (:ds rt/*ctx*) ["SELECT offset_ms FROM chunks WHERE recording_id = ?
                                                     ORDER BY chunk_no" id])))))))
