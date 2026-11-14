(ns muesli.relay.web.pages
  "Server-rendered pages: login, API keys, clients, recordings, admin,
  and the shell that loads the recorder PWA."
  (:require [clojure.string :as str]
            [hiccup2.core :as h]
            [muesli.relay.api.client :as client-api]
            [muesli.relay.auth :as auth]
            [muesli.relay.db :as db]
            [muesli.relay.keys :as keys]
            [muesli.relay.recordings :as recs]
            [ring.middleware.anti-forgery :as af])
  (:import (java.time Instant ZoneId)
           (java.time.format DateTimeFormatter)))

(def ^:private fmt (DateTimeFormatter/ofPattern "yyyy-MM-dd HH:mm"))

(defn- when-str [ms]
  (if ms (.format fmt (.atZone (Instant/ofEpochMilli ms) (ZoneId/systemDefault))) "—"))

(defn- clock [ms]
  (if-not ms "—"
          (let [s (quot ms 1000) h (quot s 3600) m (quot (mod s 3600) 60) s (mod s 60)]
            (if (pos? h) (format "%d:%02d:%02d" h m s) (format "%d:%02d" m s)))))

(defn- size [b]
  (cond (nil? b) "—"
        (< b 1024) (str b " B")
        (< b (* 1024 1024)) (format "%.0f KB" (/ b 1024.0))
        :else (format "%.1f MB" (/ b 1048576.0))))

(defn- csrf-field []
  [:input {:type "hidden" :name "__anti-forgery-token" :value (str af/*anti-forgery-token*)}])

(defn- post-form [action label & [{:keys [confirm class]}]]
  [:form.inline {:method "post" :action action
                 :data-confirm confirm}
   (csrf-field)
   [:button {:class (or class "link")} label]])

(defn html-response [status body]
  {:status status
   :headers {"Content-Type" "text/html; charset=utf-8"
             "Cache-Control" "no-store"
             "X-Frame-Options" "DENY"
             "Referrer-Policy" "same-origin"}
   :body (str "<!doctype html>" body)})

(defn layout [req title & content]
  (let [user (:relay/user req)]
    (h/html
     [:html {:lang "en"}
      [:head
       [:meta {:charset "utf-8"}]
       [:meta {:name "viewport" :content "width=device-width, initial-scale=1, viewport-fit=cover"}]
       [:meta {:name "theme-color" :content "#1f2a24"}]
       [:meta {:name "csrf-token" :content (str af/*anti-forgery-token*)}]
       [:title (str title " · muesli relay")]
       [:link {:rel "manifest" :href "/manifest.webmanifest"}]
       [:link {:rel "icon" :href "/icons/icon.svg" :type "image/svg+xml"}]
       [:link {:rel "apple-touch-icon" :href "/icons/icon-192.png"}]
       [:link {:rel "stylesheet" :href "/style.css"}]
       [:script {:src "/site.js" :defer true}]]
      [:body
       [:header.top
        [:a.brand {:href "/"} [:span.dot] "muesli relay"]
        (when user
          [:nav
           [:a {:href "/"} "Record"]
           [:a {:href "/recordings"} "Recordings"]
           [:a {:href "/clients"} "Emacs"]
           [:a {:href "/keys"} "API keys"]
           (when (= 1 (:is_admin user)) [:a {:href "/admin/users"} "Users"])
           (post-form "/logout" "Log out")])]
       [:main content]]])))

(defn page [req title & content]
  (html-response 200 (apply layout req title content)))

(defn- redirect [to] {:status 303 :headers {"Location" to} :body ""})

(defn- safe-next [n]
  (if (and (string? n) (re-matches #"/[A-Za-z0-9/_-]*" n)) n "/"))

(defn- client-ip [req]
  (or (:relay/remote-addr req) (:remote-addr req)))

;;;; Login

(defn login-page [ctx req & [error]]
  (html-response
   (if error 401 200)
   (layout req "Log in"
           [:section.card.narrow
            [:h1 "Log in"]
            (when error [:p.error error])
            [:form {:method "post" :action "/login"}
             (csrf-field)
             [:input {:type "hidden" :name "next" :value (safe-next (get-in req [:params :next]))}]
             [:label "Username" [:input {:name "username" :autocomplete "username" :required true
                                         :autocapitalize "none" :autofocus true}]]
             [:label "Password" [:input {:name "password" :type "password" :required true
                                         :autocomplete "current-password"}]]
             [:button.primary "Log in"]]
            (when (get-in ctx [:cfg :signup-enabled])
              [:p.muted "No account? " [:a {:href "/signup"} "Sign up"]])])))

(defn login [{:keys [ds] :as ctx} req]
  (let [{:keys [username password next]} (:params req)
        ks [(str "ip:" (client-ip req)) (str "user:" username)]]
    (if (auth/rate-limited? ks)
      (login-page ctx req "Too many attempts.  Try again in a few minutes.")
      (if-let [user (auth/check-login ds username password)]
        (do (auth/reset-attempts! [(str "user:" username)])
            (assoc (redirect (safe-next next))
                   :session {:user-id (:id user)}
                   :session-cookie-attrs {:max-age (* 86400 (get-in ctx [:cfg :session :max-age-days] 30))}))
        (do (auth/record-failure! ks)
            (login-page ctx req "Wrong username or password."))))))

(defn logout [_ _]
  (assoc (redirect "/login") :session nil))

(defn signup-page [ctx req & [error]]
  (if-not (get-in ctx [:cfg :signup-enabled])
    (redirect "/login")
    (html-response
     (if error 422 200)
     (layout req "Sign up"
             [:section.card.narrow
              [:h1 "Create an account"]
              (when error [:p.error error])
              [:form {:method "post" :action "/signup"}
               (csrf-field)
               [:label "Username" [:input {:name "username" :required true :autocapitalize "none"
                                           :pattern "[a-z0-9_.-]{2,40}"}]]
               [:label "Password (12+ characters)"
                [:input {:name "password" :type "password" :required true :minlength 12
                         :autocomplete "new-password"}]]
               [:button.primary "Create account"]]]))))

(def username-re #"[a-z0-9_.-]{2,40}")

(defn signup [{:keys [ds] :as ctx} req]
  (let [{:keys [username password]} (:params req)]
    (cond
      (not (get-in ctx [:cfg :signup-enabled])) (redirect "/login")
      (auth/rate-limited? [(str "ip:" (client-ip req))]) (signup-page ctx req "Too many attempts.")
      (not (and (string? username) (re-matches username-re username)))
      (signup-page ctx req "Usernames are 2–40 lowercase letters, digits, . _ or -.")
      (< (count (str password)) 12) (signup-page ctx req "Passwords need at least 12 characters.")
      (db/user-by-name ds username) (do (auth/record-failure! [(str "ip:" (client-ip req))])
                                        (signup-page ctx req "That username is taken."))
      :else (let [id (db/create-user! ds {:username username :password-hash (auth/hash-password password)})]
              (assoc (redirect "/keys") :session {:user-id id})))))

;;;; Recorder shell

(defn home [_ req]
  (html-response
   200
   (layout req "Record"
           [:div#app {:data-user (:username (:relay/user req))}
            [:noscript "The recorder needs JavaScript."]]
           [:script {:src "/js/main.js" :defer true}])))

;;;; API keys

(defn keys-page [{:keys [ds]} req & [{:keys [new-key error]}]]
  (let [user (:relay/user req)
        ks (db/keys-for-user ds (:id user))]
    (page req "API keys"
          [:section.card
           [:h1 "API keys"]
           [:p.muted "Each key links one Emacs.  Put it in "
            [:code "~/.authinfo.gpg"] " and run " [:code "M-x muesli-relay-link"] "."]
           (when error [:p.error error])
           (when new-key
             [:div.newkey
              [:p [:strong "Copy this key now — it will not be shown again."]]
              [:pre#newkey (:key new-key)]
              [:p.muted "authinfo line:"]
              [:pre (str "machine " (:host new-key) " login muesli password " (:key new-key))]])
           [:form.row {:method "post" :action "/keys"}
            (csrf-field)
            [:input {:name "name" :placeholder "Name, e.g. laptop" :required true :maxlength 100}]
            [:button.primary "Create key"]]]
          [:section.card
           (if (empty? ks)
             [:p.muted "No keys yet."]
             [:table
              [:thead [:tr [:th "Name"] [:th "Key"] [:th "Linked Emacs"] [:th "Created"] [:th "Last used"] [:th]]]
              [:tbody
               (for [k ks]
                 [:tr {:class (when (:revoked_at k) "revoked")}
                  [:td (:name k)]
                  [:td [:code (str "msl_" (:prefix k) "…")]]
                  [:td (or (:client_name k) [:span.muted "not linked"])]
                  [:td (when-str (:created_at k))]
                  [:td (when-str (:last_used_at k))]
                  [:td (if (:revoked_at k)
                         [:span.muted "revoked"]
                         (post-form (str "/keys/" (:id k) "/revoke") "Revoke"
                                    {:confirm "Revoke this key? Its Emacs will be cut off."}))]])]])])))

(defn create-key [{:keys [ds cfg] :as ctx} req]
  (let [name (str/trim (str (get-in req [:params :name])))]
    (if (or (str/blank? name) (> (count name) 100))
      (keys-page ctx req {:error "Give the key a name (up to 100 characters)."})
      (let [k (keys/generate)
            host (try (.getHost (java.net.URI. (:base-url cfg))) (catch Exception _ "relay.example"))]
        (db/create-key! ds {:user-id (:id (:relay/user req)) :name name :prefix (:prefix k) :key-hash (:hash k)})
        (keys-page ctx req {:new-key (assoc k :host host)})))))

(defn revoke-key [{:keys [ds]} req]
  (db/revoke-key! ds (:id (:relay/user req)) (get-in req [:path-params :id]))
  (redirect "/keys"))

;;;; Clients

(defn clients-page [{:keys [ds]} req]
  (let [cs (db/clients-for-user ds (:id (:relay/user req)))]
    (page req "Linked Emacs"
          [:section.card
           [:h1 "Linked Emacs"]
           (if (empty? cs)
             [:p.muted "Nothing linked yet.  Create an API key, then run "
              [:code "M-x muesli-relay-link"] " in Emacs."]
             (for [c cs]
               [:div.client
                [:div.client-head
                 [:h2 (:name c)]
                 [:span.muted "linked " (when-str (:linked_at c)) " · seen " (when-str (:last_seen_at c))
                  (when-let [v (get-in c [:emacs_info :version])] (str " · Emacs " v))]]
                [:ul.profiles
                 (for [p (:profiles c)]
                   [:li [:strong (or (:label p) (:name p))] " "
                    [:code (:name p)] (when (:description p) [:span.muted " — " (:description p)])])]
                [:form.row {:method "post" :action (str "/clients/" (:id c) "/rename")}
                 (csrf-field)
                 [:input {:name "name" :value (:name c) :maxlength 100 :required true}]
                 [:button "Rename"]]
                (post-form (str "/clients/" (:id c) "/unlink") "Unlink"
                           {:confirm "Unlink this Emacs? Its key stays valid and can link again."})]))])))

(defn rename-client [{:keys [ds]} req]
  (let [n (str/trim (str (get-in req [:params :name])))]
    (when (<= 1 (count n) 100)
      (db/rename-client! ds (:id (:relay/user req)) (get-in req [:path-params :id]) n))
    (redirect "/clients")))

(defn unlink-client [{:keys [ds]} req]
  (db/delete-client! ds (:id (:relay/user req)) (get-in req [:path-params :id]))
  (redirect "/clients"))

;;;; Recordings

(defn- status-chip [r]
  (let [s (cond (:reject_reason r) "rejected"
                (= "ready" (:status r)) "waiting"
                :else (:status r))]
    [:span {:class (str "chip " s)}
     (case s
       "waiting" "waiting for Emacs"
       "rejected" "rejected"
       s)]))

(defn recordings-page [{:keys [ds] :as ctx} req]
  (let [user (:relay/user req)
        rs (db/recordings-for-user ds (:id user) 200)
        cs (db/clients-for-user ds (:id user))]
    (page req "Recordings"
          [:section.card
           [:h1 "Recordings"]
           (if (empty? rs)
             [:p.muted "No recordings yet."]
             [:table
              [:thead [:tr [:th "Started"] [:th "Title"] [:th "Emacs / profile"] [:th "Length"] [:th "Size"] [:th "Status"] [:th]]]
              [:tbody
               (for [r rs]
                 [:tr
                  [:td (when-str (:started_at r))]
                  [:td (or (:title r) [:span.muted "untitled"])]
                  [:td (or (:client_name r) [:span.muted "unassigned"]) " · " [:code (:profile r)]]
                  [:td (clock (:duration_ms r))]
                  [:td (size (:bytes r))]
                  [:td (status-chip r) (when (:reject_reason r) [:div.muted.small (:reject_reason r)])]
                  [:td.actions
                   (when (recs/audio-file ctx r)
                     [:a {:href (str "/recordings/" (:id r) "/audio")} "Download"])
                   (when (and (not= "delivered" (:status r)) (seq cs))
                     [:form.inline {:method "post" :action (str "/recordings/" (:id r) "/assign")}
                      (csrf-field)
                      [:select {:name "target"}
                       (for [c cs p (:profiles c)]
                         (let [v (str (:id c) "|" (:name p))]
                           [:option {:value v :selected (= v (str (:client_id r) "|" (:profile r)))}
                            (str (:name c) " · " (or (:label p) (:name p)))]))]
                      [:button.link "Assign"]])
                   (when (not= "delivered" (:status r))
                     (post-form (str "/recordings/" (:id r) "/discard") "Discard"
                                {:confirm "Delete this recording for good?"}))]])]])])))

(defn download [{:keys [ds] :as ctx} req]
  (let [id (get-in req [:path-params :id])
        r (db/user-recording ds (:id (:relay/user req)) id)
        f (when r (recs/audio-file ctx r))]
    (if f
      (client-api/file-response req f (:mime_type r) (.getName ^java.io.File f))
      (html-response 404 (layout req "Not found" [:p "No audio for that recording."])))))

(defn assign [ctx req]
  (let [[cid profile] (str/split (str (get-in req [:params :target])) #"\|" 2)]
    (recs/reassign! ctx (:relay/user req) (get-in req [:path-params :id]) {:client_id cid :profile profile})
    (redirect "/recordings")))

(defn discard [ctx req]
  (recs/discard! ctx (:relay/user req) (get-in req [:path-params :id]))
  (redirect "/recordings"))

;;;; Admin

(defn users-page [{:keys [ds]} req & [msg]]
  (page req "Users"
        [:section.card
         [:h1 "Users"]
         (when msg [:p.error msg])
         [:table
          [:thead [:tr [:th "Username"] [:th "Role"] [:th "Created"] [:th]]]
          [:tbody
           (for [u (db/users ds)]
             [:tr {:class (when (= 1 (:disabled u)) "revoked")}
              [:td (:username u)]
              [:td (if (= 1 (:is_admin u)) "admin" "user")]
              [:td (when-str (:created_at u))]
              [:td (when (not= (:id u) (:id (:relay/user req)))
                     (post-form (str "/admin/users/" (:id u) (if (= 1 (:disabled u)) "/enable" "/disable"))
                                (if (= 1 (:disabled u)) "Enable" "Disable")))]])]]
         [:h2 "Add user"]
         [:form.row {:method "post" :action "/admin/users"}
          (csrf-field)
          [:input {:name "username" :placeholder "username" :required true :autocapitalize "none"}]
          [:input {:name "password" :type "password" :placeholder "password (12+)" :required true :minlength 12}]
          [:label.check [:input {:type "checkbox" :name "admin" :value "1"}] "admin"]
          [:button.primary "Add"]]]))

(defn add-user [{:keys [ds] :as ctx} req]
  (let [{:keys [username password admin]} (:params req)]
    (cond
      (not (and (string? username) (re-matches username-re username)))
      (users-page ctx req "Usernames are 2–40 lowercase letters, digits, . _ or -.")
      (< (count (str password)) 12) (users-page ctx req "Passwords need at least 12 characters.")
      (db/user-by-name ds username) (users-page ctx req "That username is taken.")
      :else (do (db/create-user! ds {:username username :password-hash (auth/hash-password password)
                                     :admin? (= admin "1")})
                (redirect "/admin/users")))))

(defn set-disabled [{:keys [ds]} disabled? req]
  (let [id (get-in req [:path-params :id])]
    (when (not= id (:id (:relay/user req)))
      (db/set-disabled! ds id disabled?))
    (redirect "/admin/users")))

(defn routes [ctx]
  [""
   ["/login" {:get #(login-page ctx %) :post #(login ctx %)}]
   ["/signup" {:get #(signup-page ctx %) :post #(signup ctx %)}]
   ["/logout" {:post #(logout ctx %)}]
   ["" {:middleware [auth/require-user-page]}
    ["/" {:get #(home ctx %)}]
    ["/keys" {:get #(keys-page ctx %) :post #(create-key ctx %)}]
    ["/keys/:id/revoke" {:post #(revoke-key ctx %)}]
    ["/clients" {:get #(clients-page ctx %)}]
    ["/clients/:id/rename" {:post #(rename-client ctx %)}]
    ["/clients/:id/unlink" {:post #(unlink-client ctx %)}]
    ["/recordings" {:get #(recordings-page ctx %)}]
    ["/recordings/:id/audio" {:get #(download ctx %)}]
    ["/recordings/:id/assign" {:post #(assign ctx %)}]
    ["/recordings/:id/discard" {:post #(discard ctx %)}]
    ["/admin" {:middleware [auth/require-admin]}
     ["/users" {:get #(users-page ctx %) :post #(add-user ctx %)}]
     ["/users/:id/disable" {:post #(set-disabled ctx true %)}]
     ["/users/:id/enable" {:post #(set-disabled ctx false %)}]]]])
