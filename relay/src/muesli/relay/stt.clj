(ns muesli.relay.stt
  "Speech-to-text and diarization over the OpenAI-compatible HTTP APIs
  muesli already uses (`/audio/transcriptions`, LocalAI's
  `/audio/diarization`), plus the response parsing ported from
  muesli-stt.el and muesli-diarize.el."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [jsonista.core :as json])
  (:import (java.io ByteArrayOutputStream File)
           (java.net URI)
           (java.net.http HttpClient HttpClient$Redirect HttpRequest HttpRequest$BodyPublishers
                          HttpResponse$BodyHandlers)
           (java.nio.file Files)
           (java.time Duration)))

;;;; HTTP

(defonce ^:private client
  (delay (-> (HttpClient/newBuilder)
             (.connectTimeout (Duration/ofSeconds 20))
             (.followRedirects HttpClient$Redirect/NORMAL)
             (.build))))

(defn- multipart
  "Return [content-type body-bytes] for FIELDS (map of name to string)
  and one FILE sent as field \"file\"."
  [fields ^File file]
  (let [boundary (str "----muesli" (random-uuid))
        out (ByteArrayOutputStream.)
        w (fn [^String s] (.write out (.getBytes s "UTF-8")))]
    (doseq [[k v] fields :when (some? v)]
      (w (str "--" boundary "\r\nContent-Disposition: form-data; name=\"" (name k) "\"\r\n\r\n"
              v "\r\n")))
    (w (str "--" boundary "\r\nContent-Disposition: form-data; name=\"file\"; filename=\""
            (.getName file) "\"\r\nContent-Type: application/octet-stream\r\n\r\n"))
    (.write out (Files/readAllBytes (.toPath file)))
    (w (str "\r\n--" boundary "--\r\n"))
    [(str "multipart/form-data; boundary=" boundary) (.toByteArray out)]))

(defn post-file
  "POST FILE with FIELDS to URL.  Returns [:ok parsed-json-or-string] or
  [:error message]."
  [{:keys [url api-key fields file timeout-seconds]}]
  (try
    (let [[ctype body] (multipart fields file)
          req (cond-> (HttpRequest/newBuilder (URI/create url))
                true (.timeout (Duration/ofSeconds (or timeout-seconds 600)))
                true (.header "Content-Type" ctype)
                (not (str/blank? api-key)) (.header "Authorization" (str "Bearer " api-key))
                true (.POST (HttpRequest$BodyPublishers/ofByteArray body)))
          resp (.send ^HttpClient @client (.build req) (HttpResponse$BodyHandlers/ofString))
          status (.statusCode resp)
          text (str (.body resp))]
      (if (<= 200 status 299)
        [:ok (try (json/read-value text json/keyword-keys-object-mapper)
                  (catch Exception _ (str/trim text)))]
        [:error (format "HTTP %d: %s" status (subs text 0 (min 500 (count text))))]))
    (catch java.net.http.HttpTimeoutException _ [:error "timed out"])
    (catch java.net.ConnectException e [:error (str "cannot connect: " (or (.getMessage e) url))])
    (catch Exception e [:error (str (.getSimpleName (class e)) ": " (.getMessage e))])))

(defn- base-url [cfg] (str/replace (str (:base-url cfg)) #"/+$" ""))

;;;; Transcription

(defn- seconds->ms [x] (when (number? x) (Math/round (* 1000.0 (double x)))))

(defn- parse-words [ws]
  (vec (keep (fn [w]
               (let [text (or (:word w) (:text w))]
                 (when (and text (number? (:start w)))
                   [(seconds->ms (:start w)) (seconds->ms (or (:end w) (:start w))) (str/trim text)])))
             ws)))

(defn parse-transcription
  "Parse a transcription RESPONSE (a map or a plain string) into segments
  relative to the chunk: [{:start_ms :end_ms :text :words}], dropping empty
  text.  DURATION-MS is used when the server returns no timestamps.  Same
  rules as `muesli-stt-parse-response`."
  [response duration-ms]
  (let [m (when (map? response) response)
        top-words (parse-words (:words m))
        segs (if (seq (:segments m))
               (for [s (:segments m)
                     :let [start (or (seconds->ms (:start s)) 0)
                           end (max start (or (seconds->ms (:end s)) start))
                           own (parse-words (:words s))]]
                 {:start_ms start :end_ms end
                  :text (str/trim (str (:text s)))
                  :words (if (seq own)
                           own
                           (filterv (fn [[ws we]]
                                      (let [mid (quot (+ ws we) 2)]
                                        (and (>= mid start) (< mid (max end (inc start))))))
                                    top-words))})
               [{:start_ms 0 :end_ms (or duration-ms 0)
                 :text (str/trim (cond (string? response) response
                                       m (str (:text m))
                                       :else ""))
                 :words top-words}])]
    (vec (remove #(str/blank? (:text %)) segs))))

(defn transcribe
  "Transcribe WAV FILE with the :transcription config CFG.
  Returns [:ok response] or [:error message]."
  [cfg ^File file]
  (post-file {:url (str (base-url cfg) "/audio/transcriptions")
              :api-key (:api-key cfg)
              :timeout-seconds (:timeout-seconds cfg)
              :file file
              :fields (merge {"model" (:model cfg) "response_format" "verbose_json"}
                             (when-not (str/blank? (:language cfg)) {"language" (:language cfg)})
                             (update-keys (or (:extra-fields cfg) {}) name))}))

;;;; Diarization

(defn parse-turns
  "Return [[label start-ms end-ms] ...] sorted by start from a diarization
  RESPONSE (LocalAI or OpenAI diarized_json: `segments` with `speaker`,
  `start`, `end` in seconds)."
  [response]
  (->> (:segments (when (map? response) response))
       (keep (fn [s]
               (let [speaker (or (:speaker s) (:label s))]
                 (when (and (some? speaker) (number? (:start s)) (number? (:end s)))
                   [(str speaker) (seconds->ms (:start s)) (seconds->ms (:end s))]))))
       (sort-by second)
       vec))

(defn diarize
  "Diarize WAV FILE with the :diarization config DCFG (falling back to the
  :transcription config TCFG for URL and key).  SPEAKERS is the expected
  count or nil.  Returns [:ok turns] or [:error message]."
  [dcfg tcfg ^File file speakers]
  (let [url (base-url (if (str/blank? (:base-url dcfg)) tcfg dcfg))
        key (if (str/blank? (:api-key dcfg)) (:api-key tcfg) (:api-key dcfg))
        [path fields] (case (keyword (:backend dcfg))
                        :localai ["/audio/diarization"
                                  (cond-> {"model" (:model dcfg) "response_format" "json"}
                                    speakers (assoc "num_speakers" (str speakers)))]
                        :diarized-json ["/audio/transcriptions"
                                        {"model" (:model dcfg) "response_format" "diarized_json"
                                         "chunking_strategy" "auto"}])
        [tag v] (post-file {:url (str url path) :api-key key :fields fields :file file
                            :timeout-seconds (:timeout-seconds dcfg 3600)})]
    (if (= tag :ok)
      (try [:ok (parse-turns v)]
           (catch Exception e [:error (str "Cannot parse diarization response: " (.getMessage e))]))
      [tag v])))

;;;; Assigning speakers (muesli-diarize-assign-segment)

(defn- overlap [a1 a2 b1 b2] (max 0 (- (min a2 b2) (max a1 b1))))

(defn- overlaps
  "[[label ms] ...] of how much each label in TURNS overlaps START..END,
  largest first."
  [start end turns]
  (->> turns
       (reduce (fn [acc [label ts te]]
                 (let [o (overlap start end ts te)]
                   (if (pos? o) (update acc label (fnil + 0) o) acc)))
               (array-map))
       (sort-by (comp - val))
       (mapv (fn [[k v]] [k v]))))

(defn- nearest [start end turns]
  (first (first (sort-by second (map (fn [[label ts te]] [label (max 0 (- ts end) (- start te))])
                                     turns)))))

(defn- label-at [start end turns]
  (or (ffirst (overlaps start (max end (inc start)) turns))
      (nearest start end turns)))

(defn assign-segment
  "Return the pieces of SEG ({:start_ms :end_ms :text :words}) with
  :speaker set from TURNS.  A segment that substantially straddles two
  speakers is split at word boundaries when word timestamps allow it."
  [seg turns split-threshold]
  (let [{:keys [start_ms end_ms words]} seg
        ov (overlaps start_ms end_ms turns)
        duration (max 1 (- end_ms start_ms))
        whole (fn [label] [(assoc seg :speaker label)])]
    (cond
      (empty? turns) (whole nil)
      (empty? ov) (whole (nearest start_ms end_ms turns))
      (and (> (count ov) 1)
           (>= (second (second ov)) (* split-threshold duration))
           (> (count words) 1))
      (let [pieces (reduce (fn [acc [ws we :as w]]
                             (let [label (label-at ws we turns)
                                   cur (peek acc)]
                               (if (and cur (= (:speaker cur) label))
                                 (conj (pop acc) (-> cur (assoc :end_ms we) (update :words conj w)))
                                 (conj acc {:speaker label :start_ms ws :end_ms we :words [w]}))))
                           [] words)]
        (if (> (count pieces) 1)
          (mapv #(assoc % :chunk_no (:chunk_no seg)
                        :text (str/join " " (map (fn [w] (nth w 2)) (:words %))))
                pieces)
          (whole (ffirst ov))))
      :else (whole (ffirst ov)))))

(defn assign-speakers
  "Label SEGMENTS (with :chunk_no) from TURNS, prefixing labels with
  \"mic:\" like `muesli-diarize-apply`."
  [segments turns split-threshold]
  (let [turns (mapv (fn [[l s e]] [(str "mic:" l) s e]) turns)]
    (vec (mapcat #(assign-segment % turns split-threshold) segments))))
