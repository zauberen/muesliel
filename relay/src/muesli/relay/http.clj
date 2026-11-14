(ns muesli.relay.http
  "JSON request/response helpers shared by the APIs."
  (:require [jsonista.core :as json]
            [malli.core :as m]
            [malli.error :as me])
  (:import (java.io ByteArrayOutputStream InputStream)))

(defn json-response [status body]
  {:status status
   :headers {"Content-Type" "application/json; charset=utf-8"
             "Cache-Control" "no-store"}
   :body (json/write-value-as-string body)})

(defn ok [body] (json-response 200 body))

(defn error
  ([status code message] (error status code message nil))
  ([status code message extra]
   (json-response status {:error (merge {:code code :message message} extra)})))

(def max-json-bytes (* 256 1024))

(defn read-body-bytes
  "Read at most LIMIT bytes of the request body; nil if it is larger."
  [req limit]
  (when-let [^InputStream in (:body req)]
    (let [out (ByteArrayOutputStream.)
          buf (byte-array 8192)]
      (loop [total 0]
        (let [n (.read in buf)]
          (cond
            (neg? n) (.toByteArray out)
            (> (+ total n) limit) nil
            :else (do (.write out buf 0 n) (recur (+ total n)))))))))

(defn read-json
  "Parse the JSON body of REQ against malli SCHEMA.
  Returns [value nil] or [nil error-response]."
  [req schema]
  (let [bs (read-body-bytes req max-json-bytes)]
    (if (nil? bs)
      [nil (error 413 "too_large" "Request body too large")]
      (let [v (try (if (zero? (alength ^bytes bs))
                     {}
                     (json/read-value bs json/keyword-keys-object-mapper))
                   (catch Exception _ ::bad))]
        (cond
          (= v ::bad) [nil (error 400 "bad_json" "Body is not valid JSON")]
          (not (m/validate schema v))
          [nil (error 422 "invalid" "Request does not match the expected shape"
                      {:details (me/humanize (m/explain schema v))})]
          :else [v nil])))))

(def uuid-re #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

(defn valid-id? [s] (boolean (and (string? s) (re-matches uuid-re s))))
