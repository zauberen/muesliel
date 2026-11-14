(ns muesli.relay.auth
  "Passwords, login rate limiting, API key and session middleware."
  (:require [buddy.hashers :as hashers]
            [clojure.string :as str]
            [muesli.relay.db :as db]
            [muesli.relay.http :as http]
            [muesli.relay.keys :as keys]))

(defn hash-password [pw]
  (hashers/derive pw {:alg :argon2id}))

(def ^:private dummy-hash (delay (hash-password "not-a-real-password")))

(defn check-login
  "Return the user for USERNAME/PASSWORD, or nil.  Always runs one hash
  check so unknown users and wrong passwords take the same time."
  [ds username password]
  (let [user (when (string? username) (db/user-by-name ds username))
        ok? (try (:valid (hashers/verify (str password)
                                         (or (:password_hash user) @dummy-hash)))
                 (catch Exception _ false))]
    (when (and user ok? (zero? (:disabled user)))
      user)))

;;;; Rate limiting (in memory, per IP and per username)

(def ^:private attempts (atom {}))

(def window-ms (* 15 60 1000))
(def max-attempts 10)

(defn- prune [ts now] (filterv #(> % (- now window-ms)) ts))

(defn rate-limited?
  "Return true if any of KS has used up its login attempts."
  [ks]
  (let [now (db/now)]
    (boolean (some #(>= (count (prune (get @attempts %) now)) max-attempts) ks))))

(defn record-failure! [ks]
  (let [now (db/now)]
    (swap! attempts (fn [m] (reduce #(update %1 %2 (fnil (fn [ts] (conj (prune ts now) now)) [])) m ks)))))

(defn reset-attempts! [ks]
  (swap! attempts #(apply dissoc % ks)))

(defn clear-all-attempts! [] (reset! attempts {}))

;;;; API key middleware for /api/v1/client

(defn bearer-token [req]
  (when-let [h (get-in req [:headers "authorization"])]
    (when-let [[_ t] (re-matches #"(?i)Bearer\s+(\S+)" (str/trim h))]
      t)))

(defn wrap-api-key
  "Authenticate with the bearer API key.  Adds :relay/key to the request
  (key_id, user_id, username, client_id)."
  [handler ds]
  (fn [req]
    (let [token (bearer-token req)
          k (when (keys/well-formed? token)
              (db/active-key-by-hash ds (keys/sha256-hex token)))]
      (if-not k
        (http/error 401 "unauthorized" "Missing, unknown or revoked API key")
        (do (db/touch-key! ds (:key_id k) (:client_id k))
            (handler (assoc req :relay/key k)))))))

;;;; Session user

(defn wrap-current-user
  "Load the session's user into :relay/user (nil if not logged in)."
  [handler ds]
  (fn [req]
    (let [uid (get-in req [:session :user-id])
          user (when uid (db/user-by-id ds uid))
          user (when (and user (zero? (:disabled user))) user)]
      (handler (assoc req :relay/user user)))))

(defn require-user-json [handler]
  (fn [req]
    (if (:relay/user req)
      (handler req)
      (http/error 401 "login_required" "Log in again"))))

(defn require-user-page [handler]
  (fn [req]
    (if (:relay/user req)
      (handler req)
      {:status 303 :headers {"Location" (str "/login?next=" (java.net.URLEncoder/encode (:uri req) "UTF-8"))}
       :body ""})))

(defn require-admin [handler]
  (fn [req]
    (if (= 1 (:is_admin (:relay/user req)))
      (handler req)
      (http/error 403 "forbidden" "Admins only"))))
