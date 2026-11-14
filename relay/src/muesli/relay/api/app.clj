(ns muesli.relay.api.app
  "PWA-facing JSON API under /app/api (session cookie + CSRF header)."
  (:require [muesli.relay.auth :as auth]
            [muesli.relay.db :as db]
            [muesli.relay.http :as http]
            [muesli.relay.recordings :as recs]
            [ring.middleware.anti-forgery]))

(def CreateBody
  "Creates a phone recording, or claims a waiting one (then client_id and
  profile may be left out)."
  [:map
   [:client_id {:optional true} [:maybe [:re http/uuid-re]]]
   [:profile {:optional true} [:maybe [:string {:min 1 :max 64}]]]
   [:title {:optional true} [:maybe [:string {:max 300}]]]
   [:mime_type [:string {:min 1 :max 100}]]
   [:started_at :int]])

(def FinishBody
  [:map
   [:part_count [:int {:min 1 :max recs/max-seq}]]
   [:ended_at {:optional true} [:maybe :int]]
   [:duration_ms {:optional true} [:maybe [:int {:min 0}]]]
   [:notes {:optional true} [:maybe [:string {:max 100000}]]]])

(def PatchBody
  [:map
   [:client_id {:optional true} [:re http/uuid-re]]
   [:profile {:optional true} [:string {:min 1 :max 64}]]
   [:title {:optional true} [:maybe [:string {:max 300}]]]])

(defn- result [[tag & more]]
  (if (= tag :ok)
    (http/ok (first more))
    (let [[status code message extra] more]
      (http/error status code message extra))))

(defn- user [req] (:relay/user req))

(defn- with-id [handler]
  (fn [req]
    (if (http/valid-id? (get-in req [:path-params :id]))
      (handler req)
      (http/error 400 "bad_id" "Recording ids are lowercase UUIDs"))))

(defn clients [{:keys [ds]} req]
  (http/ok (mapv #(select-keys % [:id :name :profiles :last_seen_at])
                 (db/clients-for-user ds (:id (user req))))))

(defn sessions [{:keys [ds]} req]
  (http/ok (db/waiting-for-user ds (:id (user req)))))

(defn me [_ req]
  (http/ok {:username (:username (user req))
            :csrf (str ring.middleware.anti-forgery/*anti-forgery-token*)}))

(defn create [ctx req]
  (let [[body err] (http/read-json req CreateBody)]
    (or err
        (result (update (recs/create! ctx (user req) (assoc body :id (get-in req [:path-params :id])))
                        1 #(if (map? %) (recs/public %) %))))))

(defn part [ctx req]
  (let [seq-no (parse-long (get-in req [:path-params :seq]))
        sha (some-> (get-in req [:headers "x-part-sha256"]) .toLowerCase)]
    (cond
      (or (nil? seq-no) (neg? seq-no) (>= seq-no recs/max-seq))
      (http/error 400 "bad_seq" "Part number out of range")
      (not (and sha (re-matches #"[0-9a-f]{64}" sha)))
      (http/error 400 "checksum" "X-Part-SHA256 header with the hex SHA-256 is required")
      :else
      (result (recs/put-part! ctx (user req) (get-in req [:path-params :id]) seq-no sha (:body req))))))

(defn finish [ctx req]
  (let [[body err] (http/read-json req FinishBody)]
    (or err (result (recs/finish! ctx (user req) (get-in req [:path-params :id]) body)))))

(defn history [{:keys [ds]} req]
  (http/ok (mapv recs/public (db/recordings-for-user ds (:id (user req)) 50))))

(defn patch [ctx req]
  (let [[body err] (http/read-json req PatchBody)]
    (or err (result (recs/reassign! ctx (user req) (get-in req [:path-params :id]) body)))))

(defn discard [ctx req]
  (result (recs/discard! ctx (user req) (get-in req [:path-params :id]))))

(defn routes [ctx]
  ["/app/api" {:middleware [auth/require-user-json]}
   ["/me" {:get #(me ctx %)}]
   ["/clients" {:get #(clients ctx %)}]
   ["/sessions" {:get #(sessions ctx %)}]
   ["/recordings" {:get #(history ctx %)}]
   ["/recordings/:id" {:middleware [with-id]
                       :put #(create ctx %)
                       :patch #(patch ctx %)
                       :delete #(discard ctx %)}]
   ["/recordings/:id/parts/:seq" {:middleware [with-id] :put #(part ctx %)}]
   ["/recordings/:id/finish" {:middleware [with-id] :post #(finish ctx %)}]])
