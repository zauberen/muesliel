(ns muesli.relay.api.client
  "Emacs-facing API under /api/v1/client, authenticated by API key."
  (:require [clojure.string]
            [muesli.relay.auth :as auth]
            [muesli.relay.db :as db]
            [muesli.relay.http :as http]
            [muesli.relay.recordings :as recs]
            [ring.middleware.params :refer [wrap-params]])
  (:import (java.io File RandomAccessFile InputStream)))

(def Profile
  [:map
   [:name [:re #"^[A-Za-z0-9_.-]{1,64}$"]]
   [:label {:optional true} [:maybe [:string {:max 200}]]]
   [:description {:optional true} [:maybe [:string {:max 500}]]]
   [:speakers {:optional true} [:maybe [:int {:min 1 :max 50}]]]])

(def LinkBody
  [:map
   [:name [:string {:min 1 :max 100}]]
   [:profiles [:vector {:min 1 :max 50} Profile]]
   [:emacs {:optional true} [:maybe [:map-of :keyword [:maybe [:string {:max 100}]]]]]])

(def CreateBody
  [:map
   [:id [:re http/uuid-re]]
   [:title {:optional true} [:maybe [:string {:max 300}]]]
   [:speakers {:optional true} [:maybe [:int {:min 1 :max 50}]]]
   [:started_at {:optional true} [:maybe :int]]])

(def RetryBody [:map [:skip {:optional true} [:maybe :boolean]]])

(def AckBody [:map [:meeting_id {:optional true} [:maybe [:string {:max 200}]]]])
(def RejectBody [:map [:reason [:string {:min 1 :max 500}]]])

(defn- result [[tag & more]]
  (if (= tag :ok)
    (http/ok (first more))
    (let [[status code message extra] more]
      (http/error status code message extra))))

(defn- client-id [req] (get-in req [:relay/key :client_id]))

(defn- require-linked [handler]
  (fn [req]
    (if (client-id req)
      (handler req)
      (http/error 412 "not_linked" "Run M-x muesli-relay-link first"))))

(defn link [{:keys [ds]} req]
  (let [[body err] (http/read-json req LinkBody)]
    (or err
        (let [k (:relay/key req)
              profiles (->> (:profiles body)
                            (map #(select-keys % [:name :label :description :speakers]))
                            (reduce (fn [acc p] (if (some #(= (:name %) (:name p)) acc) acc (conj acc p))) []))
              id (db/upsert-client! ds {:key-id (:key_id k) :user-id (:user_id k)
                                        :name (:name body) :profiles profiles
                                        :emacs (:emacs body)})]
          (http/ok {:client_id id :user (:username k) :profiles (count profiles)})))))

(defn ping [{:keys [ds]} req]
  (http/ok {:client_id (client-id req)
            :user (get-in req [:relay/key :username])
            :pending (count (filter #(= "phone" (:origin %))
                                    (db/recordings-for-client ds (client-id req) "transcribed")))}))

(def listable #{"waiting" "recording" "processing" "transcribed" "failed" "delivered"})

(defn list-recordings [{:keys [ds]} req]
  (let [status (get-in req [:query-params "status"] "transcribed")]
    (if-not (listable status)
      (http/error 422 "invalid" (str "status must be one of " (clojure.string/join ", " (sort listable))))
      (http/ok (mapv recs/for-client (db/recordings-for-client ds (client-id req) status))))))

(defn- path-id [req] (get-in req [:path-params :id]))

(defn- with-id [handler]
  (fn [req]
    (if (http/valid-id? (path-id req))
      (handler req)
      (http/error 400 "bad_id" "Recording ids are lowercase UUIDs"))))

(defn create [ctx req]
  (let [[body err] (http/read-json req CreateBody)]
    (or err
        (result (update (recs/create-for-emacs! ctx (:relay/key req) body)
                        1 #(if (map? %) (recs/status-for-client ctx %) %))))))

(defn status [{:keys [ds] :as ctx} req]
  (let [r (db/recording ds (path-id req))]
    (if (and r (= (client-id req) (:client_id r)))
      (http/ok (recs/status-for-client ctx r))
      (http/error 404 "not_found" "No such recording for this client"))))

(defn segments [{:keys [ds]} req]
  (let [r (db/recording ds (path-id req))
        after (or (some-> (get-in req [:query-params "after"]) parse-long) 0)]
    (if (and r (= (client-id req) (:client_id r)))
      (http/ok (db/segments ds (:id r) after))
      (http/error 404 "not_found" "No such recording for this client"))))

(defn stop [ctx req] (result (recs/stop! ctx (client-id req) (path-id req))))

(defn retry [ctx req]
  (let [[body err] (http/read-json req RetryBody)]
    (or err (result (recs/retry! ctx (client-id req) (path-id req) (:skip body))))))

(defn discard [ctx req] (result (recs/discard-for-client! ctx (client-id req) (path-id req))))

(defn- parse-range
  "Parse a single bytes=START-END range for a file of LENGTH bytes."
  [header length]
  (when-let [[_ s e] (and header (re-matches #"bytes=(\d*)-(\d*)" header))]
    (let [[start end] (cond
                        (and (seq s) (seq e)) [(parse-long s) (parse-long e)]
                        (seq s) [(parse-long s) (dec length)]
                        (seq e) [(max 0 (- length (parse-long e))) (dec length)]
                        :else nil)]
      (when start
        (if (or (> start end) (>= start length))
          :unsatisfiable
          [start (min end (dec length))])))))

(defn- ranged-stream ^InputStream [^File f start len]
  (let [raf (RandomAccessFile. f "r")]
    (.seek raf start)
    (let [remaining (volatile! len)]
      (proxy [InputStream] []
        (read
          ([] (if (pos? @remaining)
                (let [b (.read raf)] (vswap! remaining dec) b)
                -1))
          ([^bytes buf off n]
           (if (pos? @remaining)
             (let [k (.read raf buf off (int (min n @remaining)))]
               (when (pos? k) (vswap! remaining - k))
               k)
             -1)))
        (close [] (.close raf))))))

(defn file-response
  "Serve F honoring a Range header.  Used by Emacs and the web download."
  [req ^File f mime filename]
  (let [length (.length f)
        rng (parse-range (get-in req [:headers "range"]) length)
        base {"Content-Type" mime
              "Accept-Ranges" "bytes"
              "Cache-Control" "no-store"
              "Content-Disposition" (str "attachment; filename=\"" filename "\"")}]
    (cond
      (= rng :unsatisfiable)
      {:status 416 :headers (assoc base "Content-Range" (str "bytes */" length)) :body ""}

      rng
      (let [[start end] rng
            len (inc (- end start))]
        {:status 206
         :headers (assoc base "Content-Range" (format "bytes %d-%d/%d" start end length)
                         "Content-Length" (str len))
         :body (ranged-stream f start len)})

      :else
      {:status 200 :headers (assoc base "Content-Length" (str length)) :body f})))

(defn audio [{:keys [ds] :as ctx} req]
  (let [id (get-in req [:path-params :id])
        r (when (http/valid-id? id) (db/recording ds id))
        f (when (and r (= (client-id req) (:client_id r))) (recs/audio-file ctx r))]
    (if f
      (file-response req f (:mime_type r) (.getName f))
      (http/error 404 "not_found" "No audio for this recording"))))

(defn ack [ctx req]
  (let [[body err] (http/read-json req AckBody)]
    (or err (result (recs/ack! ctx (client-id req) (get-in req [:path-params :id]) (:meeting_id body))))))

(defn reject [ctx req]
  (let [[body err] (http/read-json req RejectBody)]
    (or err (result (recs/reject! ctx (client-id req) (get-in req [:path-params :id]) (:reason body))))))

(defn routes [{:keys [ds] :as ctx}]
  ["/api/v1/client" {:middleware [wrap-params [auth/wrap-api-key ds]]}
   ["/link" {:post #(link ctx %)}]
   ["" {:middleware [require-linked]}
    ["/ping" {:get #(ping ctx %)}]
    ["/recordings" {:get #(list-recordings ctx %) :post #(create ctx %)}]
    ["/recordings/:id" {:middleware [with-id] :get #(status ctx %) :delete #(discard ctx %)}]
    ["/recordings/:id/segments" {:middleware [with-id] :get #(segments ctx %)}]
    ["/recordings/:id/stop" {:middleware [with-id] :post #(stop ctx %)}]
    ["/recordings/:id/retry" {:middleware [with-id] :post #(retry ctx %)}]
    ["/recordings/:id/audio" {:middleware [with-id] :get #(audio ctx %)}]
    ["/recordings/:id/ack" {:middleware [with-id] :post #(ack ctx %)}]
    ["/recordings/:id/reject" {:middleware [with-id] :post #(reject ctx %)}]]])
