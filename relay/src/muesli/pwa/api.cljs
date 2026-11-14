(ns muesli.pwa.api
  "fetch wrapper for /app/api with the CSRF header.")

(defonce csrf (atom (some-> (js/document.querySelector "meta[name=csrf-token]")
                            (.getAttribute "content"))))

(defn request
  "Fetch PATH.  Resolves to {:status n :body parsed-json-or-nil}; rejects
  only on network failure."
  ([method path] (request method path nil nil))
  ([method path body] (request method path body nil))
  ([method path body headers]
   (let [json? (and body (not (instance? js/Blob body)))
         h (js/Object.assign #js {"X-CSRF-Token" (or @csrf "")}
                             (if json? #js {"Content-Type" "application/json"}
                                 (if body #js {"Content-Type" "application/octet-stream"} #js {}))
                             (clj->js (or headers {})))]
     (-> (js/fetch path #js {:method method
                             :headers h
                             :credentials "same-origin"
                             :cache "no-store"
                             :body (cond json? (js/JSON.stringify (clj->js body))
                                         body body
                                         :else js/undefined)})
         (.then (fn [^js resp]
                  (-> (.text resp)
                      (.then (fn [t]
                               {:status (.-status resp)
                                :body (when (seq t)
                                        (try (js->clj (js/JSON.parse t) :keywordize-keys true)
                                             (catch :default _ nil)))})))))))))

(defn refresh-csrf!
  "Fetch a fresh CSRF token (e.g. after the page was served from cache)."
  []
  (-> (request "GET" "/app/api/me")
      (.then (fn [{:keys [status body]}]
               (when (= 200 status) (reset! csrf (:csrf body)))
               status))))
