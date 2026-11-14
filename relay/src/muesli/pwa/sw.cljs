(ns muesli.pwa.sw
  "Service worker: keeps the app shell available offline.  The recorder
  page is network-first (it carries the session's CSRF token), static
  assets are stale-while-revalidate, API calls are never cached.")

(def cache-name "muesli-relay-v1")
(def shell ["/" "/style.css" "/site.js" "/js/main.js" "/manifest.webmanifest" "/icons/icon.svg"])

(defn- cache-put! [^js req ^js resp]
  (when (and (.-ok resp) (= "basic" (.-type resp)) (not (.-redirected resp)))
    (let [copy (.clone resp)]
      (-> (js/caches.open cache-name) (.then #(.put % req copy)))))
  resp)

(defn- network-first [^js req]
  (-> (js/fetch req)
      (.then #(cache-put! req %))
      (.catch (fn [_] (.then (js/caches.match req) #(or % (js/caches.match "/")))))))

(defn- stale-while-revalidate [^js req]
  (.then (js/caches.match req)
         (fn [cached]
           (let [fresh (-> (js/fetch req) (.then #(cache-put! req %)))]
             (if cached
               (do (.catch fresh (fn [_] nil)) cached)
               fresh)))))

(defn- on-fetch [^js e]
  (let [req (.-request e)
        url (js/URL. (.-url req))]
    (when (and (= "GET" (.-method req))
               (= (.-origin url) js/self.location.origin)
               (not (.startsWith (.-pathname url) "/app/api"))
               (not (.startsWith (.-pathname url) "/api/")))
      (cond
        (= "/" (.-pathname url)) (.respondWith e (network-first req))
        (some #(= % (.-pathname url)) shell) (.respondWith e (stale-while-revalidate req))
        :else nil))))

(defn init []
  (js/self.addEventListener
   "install"
   (fn [^js e]
     (.waitUntil e (-> (js/caches.open cache-name)
                       (.then #(.addAll % (clj->js (rest shell))))
                       (.then #(js/self.skipWaiting))))))
  (js/self.addEventListener
   "activate"
   (fn [^js e]
     (.waitUntil e (-> (js/caches.keys)
                       (.then (fn [ks] (js/Promise.all (.map ks #(when (not= % cache-name) (js/caches.delete %))))))
                       (.then #(js/self.clients.claim))))))
  (js/self.addEventListener "fetch" on-fetch))
