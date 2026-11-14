(ns muesli.pwa.core
  "Recorder UI.  The DOM is built once; `render!` only updates text,
  classes and option lists so inputs keep focus while recording."
  (:require [clojure.string :as str]
            [muesli.pwa.api :as api]
            [muesli.pwa.idb :as idb]
            [muesli.pwa.queue :as queue]
            [muesli.pwa.recorder :as recorder]))

;;;; Tiny DOM helper

(defn el
  "Create element TAG with ATTRS (:on-* keys become listeners) and CHILDREN."
  [tag attrs & children]
  (let [e (js/document.createElement (name tag))]
    (doseq [[k v] attrs :when (some? v)]
      (let [k (name k)]
        (if (str/starts-with? k "on-")
          (.addEventListener e (subs k 3) v)
          (.setAttribute e k (if (true? v) "" (str v))))))
    (doseq [c (flatten children) :when (some? c)]
      (.append e (if (string? c) (js/document.createTextNode c) c)))
    e))

(defn- text! [^js e s] (when (not= (.-textContent e) s) (set! (.-textContent e) s)))
(defn- show! [^js e on?] (set! (.-hidden e) (not on?)))
(defn- clear! [^js e] (set! (.-textContent e) ""))

(defn- store-get [k] (try (js/localStorage.getItem k) (catch :default _ nil)))
(defn- store-set! [k v] (try (js/localStorage.setItem k v) (catch :default _ nil)))

;;;; State

(defonce app (atom {:clients [] :history [] :tab :record :unfinished [] :message nil}))

(defn- clock [ms]
  (let [s (js/Math.floor (/ (or ms 0) 1000))
        h (js/Math.floor (/ s 3600))
        m (js/Math.floor (/ (mod s 3600) 60))
        s (mod s 60)
        pad #(.padStart (str %) 2 "0")]
    (if (pos? h) (str h ":" (pad m) ":" (pad s)) (str (pad m) ":" (pad s)))))

(defn- when-str [ms]
  (when ms (.toLocaleString (js/Date. ms) js/undefined
                            #js {:month "short" :day "numeric" :hour "2-digit" :minute "2-digit"})))

;;;; Elements (created in `build!`)

(defonce ui (atom {}))

(defn- selected-client []
  (let [id (.-value (:client @ui))]
    (first (filter #(= id (:id %)) (:clients @app)))))

(defn- fill-profiles! []
  (let [sel (:profile @ui)
        c (selected-client)
        want (store-get "profile")]
    (clear! sel)
    (doseq [p (:profiles c)]
      (.append sel (el :option {:value (:name p)} (or (:label p) (:name p)))))
    (when (some #(= want (:name %)) (:profiles c)) (set! (.-value sel) want))
    (text! (:profile-desc @ui)
           (or (:description (first (filter #(= (.-value sel) (:name %)) (:profiles c)))) ""))))

(defn- fill-clients! []
  (let [sel (:client @ui)
        want (store-get "client")]
    (clear! sel)
    (doseq [c (:clients @app)]
      (.append sel (el :option {:value (:id c)} (:name c))))
    (when (some #(= want (:id %)) (:clients @app)) (set! (.-value sel) want))
    (fill-profiles!)))

(defn- message! [s] (swap! app assoc :message s))

;;;; Loading

(defn load-clients! []
  (-> (api/request "GET" "/app/api/clients")
      (.then (fn [{:keys [status body]}]
               (case status
                 200 (do (swap! app assoc :clients (vec body) :offline false) (fill-clients!))
                 401 (swap! app assoc :login-required true)
                 nil)))
      (.catch (fn [_] (swap! app assoc :offline true)))))

(defn load-history! []
  (-> (js/Promise.all
       #js [(-> (api/request "GET" "/app/api/recordings")
                (.then (fn [{:keys [status body]}] (if (= 200 status) (vec body) (:history @app)))))
            (idb/get-all "recordings")])
      (.then (fn [[server local]]
               (swap! app assoc :history server :local (vec local))))
      (.catch (fn [_] (swap! app assoc :offline true)))))

(defn find-unfinished!
  "Recordings left in IndexedDB unstopped by a killed page."
  []
  (-> (idb/get-all "recordings")
      (.then (fn [recs]
               (swap! app assoc :unfinished
                      (vec (filter #(and (not (.-stopped ^js %))
                                         (not= (.-id ^js %) (recorder/current-id)))
                                   recs)))))))

(defn- recover! [^js rec]
  (-> (idb/parts-for (.-id rec))
      (.then (fn [parts]
               (let [n (count (take-while true? (map-indexed #(= %1 (.-seq ^js %2)) parts)))]
                 (idb/update-recording! (.-id rec)
                                        #js {:stopped true :part_count n
                                             :ended_at (+ (.-started_at rec) (* n recorder/slice-ms))
                                             :duration_ms (* n recorder/slice-ms)}))))
      (.then (fn [] (queue/kick!) (find-unfinished!)))))

(defn- discard-local! [^js rec]
  (when (js/confirm "Discard this unfinished recording?")
    (-> (idb/delete-recording! (.-id rec))
        (.then (fn []
                 (when (.-created rec)
                   (api/request "DELETE" (str "/app/api/recordings/" (.-id rec))))
                 (find-unfinished!))))))

;;;; Actions

(defn- start! []
  (let [c (selected-client)
        profile (.-value (:profile @ui))]
    (cond
      (not (recorder/supported?)) (message! "This browser cannot record audio.")
      (nil? c) (message! "Link an Emacs first.")
      :else
      (-> (recorder/start! {:client_id (:id c) :profile profile
                            :title (not-empty (str/trim (.-value (:title @ui))))})
          (.then (fn [_] (message! nil)
                   (when (exists? js/navigator.storage.persist) (.persist js/navigator.storage))))
          (.catch (fn [e] (message! (str "Microphone unavailable: " (.-message e)))))))))

(defn- stop! []
  (-> (recorder/stop! (not-empty (.-value (:notes @ui))))
      (.then (fn [_]
               (set! (.-value (:notes @ui)) "")
               (set! (.-value (:title @ui)) "")
               (message! "Saved.  Uploading…")
               (load-history!)))))

(defn- toggle-pause! []
  (if (recorder/paused?) (recorder/resume!) (recorder/pause!)))

;;;; Rendering

(defn- progress-text [{:keys [progress error login-required running]}]
  (cond
    login-required "Logged out — log in again to keep uploading."
    (and error (seq progress)) (str "Waiting to upload (" error "); retrying…")
    (seq progress) (let [{:keys [uploaded total]} (reduce (fn [a [_ p]] (merge-with + a (select-keys p [:uploaded :total])))
                                                          {:uploaded 0 :total 0} progress)]
                     (str "Uploading " uploaded "/" total " slices" (when running "…")))
    :else nil))

(defn- status-label [r]
  (cond (:reject_reason r) "rejected"
        (= "ready" (:status r)) "waiting for Emacs"
        :else (:status r)))

(defn- history-row [r clients]
  (let [chip (status-label r)
        undelivered (not= "delivered" (:status r))
        assign (when (and undelivered (seq clients))
                 (let [sel (el :select {:aria-label "Assign to"}
                               (for [c clients p (:profiles c)]
                                 (let [v (str (:id c) "|" (:name p))]
                                   (el :option (cond-> {:value v}
                                                 (= v (str (:client_id r) "|" (:profile r))) (assoc :selected true))
                                       (str (:name c) " · " (or (:label p) (:name p)))))))]
                   (.addEventListener sel "change"
                                      (fn [_]
                                        (let [[cid p] (str/split (.-value sel) #"\|" 2)]
                                          (-> (api/request "PATCH" (str "/app/api/recordings/" (:id r))
                                                           {:client_id cid :profile p})
                                              (.then load-history!)))))
                   sel))]
    (el :li {:class "hist"}
        (el :div {:class "hist-main"}
            (el :strong {} (or (:title r) "Untitled"))
            (el :span {:class "muted"} " " (when-str (:started_at r)) " · " (clock (:duration_ms r))
                " · " (or (:client_name r) "unassigned") " / " (:profile r)))
        (el :div {:class "hist-side"}
            (el :span {:class (str "chip " (str/replace chip #" .*" ""))} chip)
            (when (:reject_reason r) (el :div {:class "muted small"} (:reject_reason r)))
            assign
            (when undelivered
              (el :button {:class "link"
                           :on-click (fn [_]
                                       (when (js/confirm "Delete this recording for good?")
                                         (-> (api/request "DELETE" (str "/app/api/recordings/" (:id r)))
                                             (.then load-history!))))}
                  "Discard"))))))

(defn- render-history! []
  (let [list-el (:history-list @ui)
        {:keys [history local clients]} @app
        server-ids (set (map :id history))
        pending (remove #(server-ids (.-id ^js %)) local)
        progress (:progress @queue/state)]
    (clear! list-el)
    (doseq [^js r local
            :let [p (get progress (.-id r))]]
      (.append list-el
               (el :li {:class "hist"}
                   (el :div {:class "hist-main"}
                       (el :strong {} (or (.-title r) "Untitled"))
                       (el :span {:class "muted"} " " (when-str (.-started_at r)) " · on this phone"))
                   (el :div {:class "hist-side"}
                       (el :span {:class "chip uploading"}
                           (cond (:error p) "refused"
                                 p (str "uploading " (:uploaded p) "/" (:total p))
                                 (.-stopped r) "queued"
                                 :else "recording"))
                       (when (:error p) (el :div {:class "muted small"} (:error p)))))))
    (doseq [r (remove #(some (fn [^js l] (= (.-id l) (:id %))) local) history)]
      (.append list-el (history-row r clients)))
    (when (and (empty? history) (empty? pending) (empty? local))
      (.append list-el (el :li {:class "muted"} "No recordings yet.")))))

(defn- render-unfinished! []
  (let [box (:unfinished @ui)]
    (clear! box)
    (doseq [^js r (:unfinished @app)]
      (.append box
               (el :div {:class "banner"}
                   (el :span {} "Unfinished recording from " (when-str (.-started_at r))
                       (when (.-title r) (str " — " (.-title r))))
                   (el :span {:class "banner-actions"}
                       (el :button {:class "primary small" :on-click #(recover! r)} "Upload & finish")
                       (el :button {:class "link" :on-click #(discard-local! r)} "Discard")))))))

(defn render! []
  (let [{:keys [clients tab message login-required offline]} @app
        u @ui
        rec? (recorder/recording?)
        paused? (recorder/paused?)]
    (show! (:empty u) (and (empty? clients) (not offline)))
    (show! (:form u) (seq clients))
    (set! (.-disabled (:client u)) rec?)
    (set! (.-disabled (:profile u)) rec?)
    (set! (.-className (:record-btn u)) (str "record " (cond paused? "paused" rec? "on" :else "off")))
    (.setAttribute (:record-btn u) "aria-label" (if rec? "Stop recording" "Start recording"))
    (text! (:record-label u) (if rec? "Stop" "Record"))
    (show! (:pause-btn u) rec?)
    (text! (:pause-btn u) (if paused? "Resume" "Pause"))
    (show! (:notes-wrap u) rec?)
    (show! (:lock-hint u) rec?)
    (text! (:timer u) (clock (or (recorder/elapsed-ms) 0)))
    (text! (:status u) (or message (progress-text @queue/state)
                           (when login-required "Logged out — log in again.")
                           (when offline "Offline — recordings are kept on this phone.")
                           ""))
    (show! (:login-link u) (or login-required (:login-required @queue/state)))
    (doseq [[k v] {:record :record-tab :history :history-tab}]
      (show! (get u k) (= tab k))
      (.toggle (.-classList (get u v)) "active" (= tab k)))
    (render-unfinished!)
    (when (= tab :history) (render-history!))))

(defn- meter-loop []
  (when-let [m (:meter @ui)]
    (set! (.. m -style -transform) (str "scaleX(" (if (recorder/recording?) (recorder/level) 0) ")"))
    (text! (:timer @ui) (clock (or (recorder/elapsed-ms) 0))))
  (js/requestAnimationFrame meter-loop))

;;;; Build

(defn build! [^js root]
  (let [client (el :select {:id "client" :on-change (fn [e] (store-set! "client" (.. e -target -value))
                                                       (fill-profiles!))})
        profile (el :select {:id "profile" :on-change (fn [e] (store-set! "profile" (.. e -target -value))
                                                        (fill-profiles!))})
        profile-desc (el :span {:class "muted small"})
        title (el :input {:id "title" :placeholder "Title (optional)" :maxlength 300 :autocomplete "off"})
        notes (el :textarea {:id "notes" :rows 4 :placeholder "Notes typed here go into the meeting's raw notes"})
        record-label (el :span {:class "record-label"} "Record")
        record-btn (el :button {:class "record off" :on-click #(if (recorder/recording?) (stop!) (start!))}
                       (el :span {:class "record-dot"}) record-label)
        pause-btn (el :button {:class "secondary" :hidden true :on-click toggle-pause!} "Pause")
        timer (el :div {:class "timer" :aria-live "off"} "00:00")
        meter (el :div {:class "meter-fill"})
        status (el :p {:class "status" :aria-live "polite"})
        login-link (el :a {:href "/login" :hidden true :class "primary button"} "Log in")
        record-tab (el :button {:class "tab active" :on-click #(do (swap! app assoc :tab :record) (render!))} "Record")
        history-tab (el :button {:class "tab" :on-click #(do (swap! app assoc :tab :history)
                                                              (load-history!))} "History")
        history-list (el :ul {:class "history"})
        unfinished (el :div {})
        notes-wrap (el :label {:hidden true} "Notes" notes)
        lock-hint (el :p {:class "muted small" :hidden true}
                      "Keep this screen open. Locking the phone or switching apps can stop the recording.")
        empty (el :div {:class "card" :hidden true}
                  (el :h2 {} "No Emacs linked yet")
                  (el :p {} "Create an API key, add it to Emacs, then run "
                      (el :code {} "M-x muesli-relay-link") ".")
                  (el :a {:href "/keys" :class "primary button"} "Create an API key"))
        form (el :div {:class "card recorder"}
                 (el :div {:class "pickers"}
                     (el :label {} "Emacs" client)
                     (el :label {} "Profile" profile profile-desc))
                 title
                 (el :div {:class "stage"}
                     timer
                     (el :div {:class "meter"} meter)
                     (el :div {:class "controls"} record-btn pause-btn))
                 lock-hint
                 notes-wrap)
        record-view (el :section {} unfinished empty form)
        history-view (el :section {:hidden true} (el :div {:class "card"} history-list))]
    (reset! ui {:client client :profile profile :profile-desc profile-desc :title title :notes notes
                :record-btn record-btn :record-label record-label :pause-btn pause-btn :timer timer
                :meter meter :status status :login-link login-link :record-tab record-tab
                :history-tab history-tab :history-list history-list :unfinished unfinished
                :notes-wrap notes-wrap :lock-hint lock-hint :empty empty :form form
                :record record-view :history history-view})
    (clear! root)
    (.append root
             (el :div {:class "tabs" :role "tablist"} record-tab history-tab)
             status login-link
             record-view history-view)))

(defn- register-sw! []
  (when (exists? js/navigator.serviceWorker)
    (-> (.register js/navigator.serviceWorker "/sw.js" #js {:scope "/"})
        (.catch (fn [e] (js/console.warn "service worker" e))))))

(defn init []
  (when-let [root (js/document.getElementById "app")]
    (build! root)
    (add-watch app ::render (fn [_ _ _ _] (render!)))
    (queue/on-change! (fn [s]
                        (when (:last-finished s)
                          (swap! queue/state dissoc :last-finished)
                          (message! "Uploaded — waiting for Emacs to fetch it.")
                          (load-history!))
                        (render!)))
    (js/window.addEventListener "online" (fn [_] (swap! app assoc :offline false)
                                           (load-clients!) (queue/kick!)))
    (js/window.addEventListener "offline" (fn [_] (swap! app assoc :offline true)))
    (js/window.addEventListener "beforeunload"
                                (fn [^js e] (when (recorder/recording?) (.preventDefault e) (set! (.-returnValue e) ""))))
    (js/setInterval queue/kick! 15000)
    (register-sw!)
    (render!)
    (meter-loop)
    (load-clients!)
    (find-unfinished!)
    (queue/kick!)))
