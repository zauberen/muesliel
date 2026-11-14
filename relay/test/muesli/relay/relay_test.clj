(ns muesli.relay.relay-test
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing use-fixtures]]
            [jsonista.core :as json]
            [muesli.relay.auth :as auth]
            [muesli.relay.config :as config]
            [muesli.relay.db :as db]
            [muesli.relay.handler :as handler]
            [muesli.relay.keys :as keys]
            [muesli.relay.sweeper :as sweeper]
            [ring.mock.request :as mock])
  (:import (java.io File)
           (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)
           (java.security MessageDigest)))

;;;; Fixture

(def ^:dynamic *ctx* nil)
(def ^:dynamic *app* nil)

(defn- temp-dir ^File []
  (.toFile (Files/createTempDirectory "relay-test" (into-array FileAttribute []))))

(defn- rm-rf [^File f]
  (doseq [^File x (reverse (file-seq f))] (.delete x)))

(defn with-system [f]
  (let [dir (temp-dir)
        cfg (config/load-config {:db {:file (str (io/file dir "relay.sqlite"))}
                                 :storage {:dir (str (io/file dir "audio"))
                                           :max-part-bytes 1024
                                           :max-recording-bytes 4096}
                                 :session {:secret "test-secret"}
                                 :base-url "http://localhost:8787"
                                 :behind-proxy false
                                 :signup-enabled false})
        ds (db/datasource (get-in cfg [:db :file]))
        ctx {:cfg cfg :ds ds}]
    (auth/clear-all-attempts!)
    (try
      (binding [*ctx* ctx *app* (handler/handler ctx)]
        (f))
      (finally (rm-rf dir)))))

(use-fixtures :each with-system)

;;;; Helpers

(defn- sha256 [^bytes bs]
  (keys/hex (.digest (MessageDigest/getInstance "SHA-256") bs)))

(defn- body-str [r]
  (let [b (:body r)]
    (cond (string? b) b
          (instance? File b) (slurp b)
          (nil? b) ""
          :else (slurp b))))

(defn- body-bytes ^bytes [r]
  (let [b (:body r)]
    (with-open [in (io/input-stream (if (string? b) (.getBytes ^String b) b))]
      (.readAllBytes in))))

(defn- json-body [r] (json/read-value (body-str r) json/keyword-keys-object-mapper))

(defn add-user! [username password & [admin?]]
  (db/create-user! (:ds *ctx*) {:username username :password-hash (auth/hash-password password)
                                :admin? admin?}))

(defn- set-cookie [r]
  (some->> (get-in r [:headers "Set-Cookie"]) first (re-find #"relay-session=[^;]*")))

(defn- csrf [r]
  (let [b (body-str r)]
    (or (second (re-find #"name=\"csrf-token\" content=\"([^\"]+)\"" b))
        (second (re-find #"content=\"([^\"]+)\" name=\"csrf-token\"" b)))))

(defn login
  "Log in through the form.  Returns a session {:cookie :csrf}."
  [username password]
  (let [r1 (*app* (mock/request :get "/login"))
        cookie (set-cookie r1)
        token (csrf r1)
        r2 (*app* (-> (mock/request :post "/login" {:username username :password password
                                                     :__anti-forgery-token token})
                      (mock/header "cookie" cookie)))
        cookie2 (or (set-cookie r2) cookie)
        r3 (*app* (-> (mock/request :get "/") (mock/header "cookie" cookie2)))]
    {:status (:status r2) :cookie (or (set-cookie r3) cookie2) :csrf (csrf r3) :home r3}))

(defn app-req
  "A PWA API request with session S."
  [s method path & [body headers]]
  (*app* (cond-> (-> (mock/request method path)
                     (mock/header "cookie" (:cookie s))
                     (mock/header "x-csrf-token" (:csrf s)))
           (map? body) (-> (mock/content-type "application/json")
                           (mock/body (json/write-value-as-string body)))
           (bytes? body) (-> (mock/content-type "application/octet-stream") (mock/body body))
           headers ((fn [r] (reduce (fn [r [k v]] (mock/header r k v)) r headers))))))

(defn new-key!
  "Create an API key through the web page and return the full key."
  [s]
  (let [r (*app* (-> (mock/request :post "/keys" {:name "laptop" :__anti-forgery-token (:csrf s)})
                     (mock/header "cookie" (:cookie s))))]
    (second (re-find #"<pre id=\"newkey\">(msl_[a-z2-7]+)</pre>" (body-str r)))))

(defn client-req [k method path & [body headers]]
  (*app* (cond-> (-> (mock/request method path)
                     (mock/header "authorization" (str "Bearer " k)))
           body (-> (mock/content-type "application/json")
                    (mock/body (json/write-value-as-string body)))
           headers ((fn [r] (reduce (fn [r [kk v]] (mock/header r kk v)) r headers))))))

(def profiles [{:name "default" :label "Meeting"}
               {:name "standup" :label "Daily standup" :description "room · work"}])

(defn link! [k]
  (json-body (client-req k :post "/api/v1/client/link"
                         {:name "laptop" :profiles profiles :emacs {:version "30.1"}})))

(defn rec-id [] (str (random-uuid)))

(defn upload!
  "Create a recording and upload PARTS (byte arrays).  Returns the id."
  [s client-id parts & [{:keys [finish?] :or {finish? true}}]]
  (let [id (rec-id)]
    (is (= 200 (:status (app-req s :put (str "/app/api/recordings/" id)
                                 {:client_id client-id :profile "standup" :title "Standup"
                                  :mime_type "audio/webm;codecs=opus" :started_at 1700000000000}))))
    (doseq [[i p] (map-indexed vector parts)]
      (is (= 200 (:status (app-req s :put (str "/app/api/recordings/" id "/parts/" i) p
                                   {"x-part-sha256" (sha256 p)})))))
    (when finish?
      (is (= 200 (:status (app-req s :post (str "/app/api/recordings/" id "/finish")
                                   {:part_count (count parts) :ended_at 1700000060000
                                    :duration_ms 60000 :notes "phone notes"})))))
    id))

(defn setup!
  "User alice with a linked key.  Returns {:s session :k key :client-id id}."
  []
  (add-user! "alice" "correct horse battery")
  (let [s (login "alice" "correct horse battery")
        k (new-key! s)
        linked (link! k)]
    {:s s :k k :client-id (:client_id linked)}))

;;;; Tests

(defn http-id? [s] (boolean (re-matches #"[0-9a-f-]{36}" (str s))))


(deftest keys-are-well-formed
  (let [{:keys [key prefix hash]} (keys/generate)]
    (is (keys/well-formed? key))
    (is (= prefix (subs key 4 12)))
    (is (= hash (keys/sha256-hex key)))
    (is (= "mzxw6ytboi" (keys/base32 (.getBytes "foobar"))))))

(deftest migrations-are-idempotent
  (is (= 1 (db/migrate! (:ds *ctx*))))
  (is (= 1 (db/version (:ds *ctx*)))))

(deftest login-and-pages
  (add-user! "alice" "correct horse battery")
  (testing "pages need a login"
    (is (= 303 (:status (*app* (mock/request :get "/keys"))))))
  (testing "wrong password"
    (is (= 401 (:status (login "alice" "nope")))))
  (testing "right password"
    (let [s (login "alice" "correct horse battery")]
      (is (= 303 (:status s)))
      (is (str/includes? (body-str (:home s)) "/js/main.js"))
      (is (= 200 (:status (*app* (-> (mock/request :get "/recordings") (mock/header "cookie" (:cookie s)))))))
      (is (get-in (:home s) [:headers "Content-Security-Policy"]))))
  (testing "forms without the CSRF token are refused"
    (let [s (login "alice" "correct horse battery")]
      (is (= 403 (:status (*app* (-> (mock/request :post "/keys" {:name "x"})
                                     (mock/header "cookie" (:cookie s))))))))))

(deftest login-rate-limit
  (add-user! "bob" "correct horse battery")
  (dotimes [_ auth/max-attempts] (login "bob" "wrong"))
  (is (= 401 (:status (login "bob" "correct horse battery")))))

(deftest api-key-auth-and-link
  (let [{:keys [k client-id]} (setup!)]
    (is (http-id? client-id))
    (testing "bad keys"
      (is (= 401 (:status (client-req "msl_nope" :get "/api/v1/client/ping"))))
      (is (= 401 (:status (*app* (mock/request :get "/api/v1/client/ping"))))))
    (testing "ping"
      (let [r (json-body (client-req k :get "/api/v1/client/ping"))]
        (is (= {:client_id client-id :user "alice" :pending 0} r))))
    (testing "relink keeps the id and updates profiles"
      (let [r (json-body (client-req k :post "/api/v1/client/link"
                                     {:name "laptop2" :profiles [{:name "default"}]}))]
        (is (= client-id (:client_id r)))
        (is (= 1 (:profiles r)))))
    (testing "invalid link body"
      (is (= 422 (:status (client-req k :post "/api/v1/client/link" {:name "x" :profiles [{:name "bad name!"}]})))))))

(deftest unlinked-key-cannot-list
  (add-user! "alice" "correct horse battery")
  (let [s (login "alice" "correct horse battery")
        k (new-key! s)]
    (is (= 412 (:status (client-req k :get "/api/v1/client/recordings"))))))

(deftest record-and-hand-off
  (let [{:keys [s k client-id]} (setup!)
        parts [(.getBytes "AAAA") (.getBytes "BBBBBB") (.getBytes "CC")]
        clients (json-body (app-req s :get "/app/api/clients"))]
    (is (= ["default" "standup"] (map :name (:profiles (first clients)))))
    (let [id (upload! s client-id parts)
          listed (json-body (client-req k :get "/api/v1/client/recordings"))
          rec (first listed)]
      (testing "listed for Emacs with metadata"
        (is (= 1 (count listed)))
        (is (= id (:id rec)))
        (is (= "standup" (:profile rec)))
        (is (= "phone notes" (:notes rec)))
        (is (= 12 (:bytes rec)))
        (is (= (sha256 (.getBytes "AAAABBBBBBCC")) (:sha256 rec))))
      (testing "full download"
        (let [r (client-req k :get (str "/api/v1/client/recordings/" id "/audio"))]
          (is (= 200 (:status r)))
          (is (= "AAAABBBBBBCC" (String. (body-bytes r))))))
      (testing "range download"
        (let [r (client-req k :get (str "/api/v1/client/recordings/" id "/audio") nil {"range" "bytes=4-"})]
          (is (= 206 (:status r)))
          (is (= "bytes 4-11/12" (get-in r [:headers "Content-Range"])))
          (is (= "BBBBBBCC" (String. (body-bytes r)))))
        (is (= 416 (:status (client-req k :get (str "/api/v1/client/recordings/" id "/audio")
                                        nil {"range" "bytes=50-"})))))
      (testing "re-uploading a part after finish is idempotent"
        (is (= 200 (:status (app-req s :put (str "/app/api/recordings/" id "/parts/0") (first parts)
                                     {"x-part-sha256" (sha256 (first parts))})))))
      (testing "ack delivers and deletes the audio"
        (is (= 200 (:status (client-req k :post (str "/api/v1/client/recordings/" id "/ack") {:meeting_id "m-1"}))))
        (is (= 200 (:status (client-req k :post (str "/api/v1/client/recordings/" id "/ack") {:meeting_id "m-1"}))))
        (is (empty? (json-body (client-req k :get "/api/v1/client/recordings"))))
        (is (= 404 (:status (client-req k :get (str "/api/v1/client/recordings/" id "/audio")))))
        (is (= "delivered" (:status (first (json-body (app-req s :get "/app/api/recordings"))))))))))

(deftest missing-parts-and-checksums
  (let [{:keys [s client-id]} (setup!)
        id (rec-id)
        p (.getBytes "hello")]
    (app-req s :put (str "/app/api/recordings/" id)
             {:client_id client-id :profile "default" :mime_type "audio/mp4" :started_at 1})
    (testing "wrong checksum"
      (is (= 400 (:status (app-req s :put (str "/app/api/recordings/" id "/parts/0") p
                                   {"x-part-sha256" (sha256 (.getBytes "other"))})))))
    (testing "conflicting content for the same seq"
      (is (= 200 (:status (app-req s :put (str "/app/api/recordings/" id "/parts/0") p
                                   {"x-part-sha256" (sha256 p)}))))
      (is (= 409 (:status (app-req s :put (str "/app/api/recordings/" id "/parts/0") (.getBytes "x")
                                   {"x-part-sha256" (sha256 (.getBytes "x"))})))))
    (testing "too large part"
      (let [big (byte-array 2000)]
        (is (= 413 (:status (app-req s :put (str "/app/api/recordings/" id "/parts/1") big
                                     {"x-part-sha256" (sha256 big)}))))))
    (testing "finish reports missing seqs"
      (let [r (app-req s :post (str "/app/api/recordings/" id "/finish") {:part_count 3})]
        (is (= 409 (:status r)))
        (is (= [1 2] (get-in (json-body r) [:error :missing])))))
    (testing "unknown profile and type are refused at create"
      (is (= 422 (:status (app-req s :put (str "/app/api/recordings/" (rec-id))
                                   {:client_id client-id :profile "nope" :mime_type "audio/mp4" :started_at 1}))))
      (is (= 415 (:status (app-req s :put (str "/app/api/recordings/" (rec-id))
                                   {:client_id client-id :profile "default" :mime_type "video/x-evil" :started_at 1})))))
    (testing "CSRF header is required for the PWA API"
      (is (= 403 (:status (*app* (-> (mock/request :delete (str "/app/api/recordings/" id))
                                     (mock/header "cookie" (:cookie s))))))))))

(deftest reject-hides-until-reassigned
  (let [{:keys [s k client-id]} (setup!)
        id (upload! s client-id [(.getBytes "abc")])]
    (is (= 200 (:status (client-req k :post (str "/api/v1/client/recordings/" id "/reject")
                                    {:reason "unknown profile standup"}))))
    (is (empty? (json-body (client-req k :get "/api/v1/client/recordings"))))
    (is (= "unknown profile standup" (:reject_reason (first (json-body (app-req s :get "/app/api/recordings"))))))
    (is (= 200 (:status (app-req s :patch (str "/app/api/recordings/" id) {:profile "default"}))))
    (is (= "default" (:profile (first (json-body (client-req k :get "/api/v1/client/recordings"))))))))

(deftest users-are-isolated
  (let [{:keys [s client-id]} (setup!)
        id (upload! s client-id [(.getBytes "abc")])]
    (add-user! "mallory" "correct horse battery")
    (let [m (login "mallory" "correct horse battery")
          mk (new-key! m)]
      (link! mk)
      (is (empty? (json-body (client-req mk :get "/api/v1/client/recordings"))))
      (is (= 404 (:status (client-req mk :get (str "/api/v1/client/recordings/" id "/audio")))))
      (is (= 404 (:status (client-req mk :post (str "/api/v1/client/recordings/" id "/ack") {}))))
      (is (empty? (json-body (app-req m :get "/app/api/recordings"))))
      (is (= 409 (:status (app-req m :put (str "/app/api/recordings/" id)
                                   {:client_id client-id :profile "default" :mime_type "audio/mp4" :started_at 1}))))
      (is (= 404 (:status (app-req m :delete (str "/app/api/recordings/" id))))))))

(deftest revoked-key-is-cut-off
  (let [{:keys [s k]} (setup!)
        key-id (:id (first (db/keys-for-user (:ds *ctx*) (:id (db/user-by-name (:ds *ctx*) "alice")))))]
    (*app* (-> (mock/request :post (str "/keys/" key-id "/revoke") {:__anti-forgery-token (:csrf s)})
               (mock/header "cookie" (:cookie s))))
    (is (= 401 (:status (client-req k :get "/api/v1/client/ping"))))
    (is (empty? (json-body (app-req s :get "/app/api/clients"))))))

(deftest sweeper-abandons-and-purges
  (let [{:keys [s client-id]} (setup!)
        id (upload! s client-id [(.getBytes "abc")] {:finish? false})
        day (* 24 3600 1000)
        now (db/now)]
    (is (= 1 (:abandoned (sweeper/sweep! *ctx* (+ now (* 2 day))))))
    (is (= "abandoned" (:status (db/recording (:ds *ctx*) id))))
    (testing "an abandoned recording can still be finished"
      (is (= 200 (:status (app-req s :post (str "/app/api/recordings/" id "/finish") {:part_count 1})))))
    (let [id2 (upload! s client-id [(.getBytes "abc")] {:finish? false})]
      (sweeper/sweep! *ctx* (+ now (* 2 day)))
      (is (= 1 (:purged (sweeper/sweep! *ctx* (+ now (* 30 day))))))
      (is (nil? (db/recording (:ds *ctx*) id2))))))
