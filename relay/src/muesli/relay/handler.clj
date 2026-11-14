(ns muesli.relay.handler
  "Ring handler: routing, sessions, CSRF, static files, error handling."
  (:require [clojure.string :as str]
            [clojure.tools.logging :as log]
            [muesli.relay.api.app :as app]
            [muesli.relay.api.client :as client]
            [muesli.relay.auth :as auth]
            [muesli.relay.config :as config]
            [muesli.relay.http :as http]
            [muesli.relay.web.pages :as pages]
            [reitit.ring :as ring]
            [ring.middleware.anti-forgery :as af]
            [ring.middleware.keyword-params :refer [wrap-keyword-params]]
            [ring.middleware.not-modified :refer [wrap-not-modified]]
            [ring.middleware.params :refer [wrap-params]]
            [ring.middleware.session :refer [wrap-session]]
            [ring.middleware.session.cookie :refer [cookie-store]]
            [ring.util.mime-type :as mime]
            [ring.util.response :as resp]))

(def csp
  (str "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
       "media-src 'self' blob:; connect-src 'self'; worker-src 'self'; manifest-src 'self'; "
       "frame-ancestors 'none'; base-uri 'none'; form-action 'self'"))

(defn wrap-security-headers [handler]
  (fn [req]
    (when-let [r (handler req)]
      (update r :headers #(merge {"X-Content-Type-Options" "nosniff"
                                  "Content-Security-Policy" csp
                                  "Permissions-Policy" "microphone=(self), camera=(), geolocation=()"}
                                 %)))))

(defn wrap-proxy
  "Behind a reverse proxy, take the scheme and client address from
  X-Forwarded-Proto / X-Forwarded-For."
  [handler behind-proxy?]
  (if-not behind-proxy?
    handler
    (fn [req]
      (let [proto (some-> (get-in req [:headers "x-forwarded-proto"]) str/lower-case)
            ip (some-> (get-in req [:headers "x-forwarded-for"]) (str/split #",") first str/trim)]
        (handler (cond-> req
                   (#{"http" "https"} proto) (assoc :scheme (keyword proto))
                   ip (assoc :relay/remote-addr ip)))))))

(defn wrap-errors [handler]
  (fn [req]
    (try (handler req)
         (catch Exception e
           (log/error e "Unhandled error on" (:request-method req) (:uri req))
           (http/error 500 "internal" "Internal error")))))

(def mime-types
  {"webmanifest" "application/manifest+json"
   "js" "text/javascript; charset=utf-8"
   "css" "text/css; charset=utf-8"
   "svg" "image/svg+xml"})

(defn static-handler
  "Serve files from resources/public.  Everything is revalidated on each
  load so a new deploy (and service worker) is picked up promptly."
  [req]
  (when (#{:get :head} (:request-method req))
    (when-let [r (resp/resource-response (:uri req) {:root "public"})]
      (-> r
          (resp/content-type (or (mime/ext-mime-type (:uri req) mime-types) "application/octet-stream"))
          (resp/header "Cache-Control" "no-cache")))))

(defn- csrf-error [req]
  (if (str/starts-with? (:uri req) "/app/api")
    (http/error 403 "csrf" "Missing or stale CSRF token; reload the page")
    (pages/html-response 403 "<p>This form expired.  Go back, reload the page and try again.</p>")))

(defn handler [{:keys [cfg ds] :as ctx}]
  (let [session-mw (fn [h]
                     (wrap-session h {:store (cookie-store {:key (config/session-key cfg)})
                                      :cookie-name "relay-session"
                                      :cookie-attrs {:http-only true :same-site :lax :path "/"
                                                     :secure (config/https? cfg)}}))
        web-mw [session-mw wrap-params wrap-keyword-params
                [auth/wrap-current-user ds]
                [af/wrap-anti-forgery {:error-handler csrf-error}]]]
    (ring/ring-handler
     (ring/router
      [(client/routes ctx)
       ["" {:middleware web-mw}
        (pages/routes ctx)
        (app/routes ctx)]]
      {:conflicts nil})
     (ring/routes
      (wrap-not-modified static-handler)
      (ring/create-default-handler
       {:not-found (fn [req]
                     (if (str/starts-with? (:uri req) "/api/")
                       (http/error 404 "not_found" "No such endpoint")
                       {:status 404 :headers {"Content-Type" "text/plain"} :body "Not found"}))
        :method-not-allowed (fn [_] (http/error 405 "method_not_allowed" "Method not allowed"))}))
     {:middleware [[wrap-proxy (:behind-proxy cfg)] wrap-security-headers wrap-errors]})))
