(ns muesli.pwa.idb
  "Promise wrapper over IndexedDB.  Two stores:
  recordings  {id client_id profile title mime_type started_at ended_at
               duration_ms notes created stopped part_count}
  parts       {rid seq blob sha uploaded} keyed by [rid seq]")

(def db-name "muesli-relay")
(def ^:private conn (atom nil))

(defn- req->promise [^js r]
  (js/Promise. (fn [resolve reject]
                 (set! (.-onsuccess r) #(resolve (.-result r)))
                 (set! (.-onerror r) #(reject (.-error r))))))

(defn open []
  (or @conn
      (reset! conn
              (js/Promise.
               (fn [resolve reject]
                 (let [r (.open js/indexedDB db-name 1)]
                   (set! (.-onupgradeneeded r)
                         (fn [_]
                           (let [db (.-result r)]
                             (.createObjectStore db "recordings" #js {:keyPath "id"})
                             (let [parts (.createObjectStore db "parts" #js {:keyPath #js ["rid" "seq"]})]
                               (.createIndex parts "rid" "rid")))))
                   (set! (.-onsuccess r) #(resolve (.-result r)))
                   (set! (.-onerror r) #(reject (.-error r)))))))))

(defn- store [db name mode]
  (.objectStore (.transaction db #js [name] mode) name))

(defn put! [store-name obj]
  (-> (open) (.then #(req->promise (.put (store % store-name "readwrite") obj)))))

(defn get-one [store-name key]
  (-> (open) (.then #(req->promise (.get (store % store-name "readonly") key)))))

(defn get-all [store-name]
  (-> (open) (.then #(req->promise (.getAll (store % store-name "readonly"))))))

(defn delete! [store-name key]
  (-> (open) (.then #(req->promise (.delete (store % store-name "readwrite") key)))))

(defn parts-for
  "All parts of recording RID sorted by seq."
  [rid]
  (-> (open)
      (.then #(req->promise (.getAll (.index (store % "parts" "readonly") "rid") rid)))
      (.then (fn [^js arr] (.sort arr (fn [^js a ^js b] (- (.-seq a) (.-seq b))))))))

(defn delete-recording!
  "Remove recording RID and all of its parts."
  [rid]
  (-> (parts-for rid)
      (.then (fn [parts]
               (js/Promise.all
                (into-array (concat (map (fn [^js p] (delete! "parts" #js [rid (.-seq p)])) parts)
                                    [(delete! "recordings" rid)])))))))

(defn update-recording!
  "Merge the JS object CHANGES into recording RID."
  [rid changes]
  (-> (get-one "recordings" rid)
      (.then (fn [r] (when r (put! "recordings" (js/Object.assign r changes)))))))
