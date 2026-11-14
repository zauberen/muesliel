(ns muesli.relay.main
  "Entry point: `serve` (default) or `user add|passwd|disable|enable|list`."
  (:gen-class)
  (:require [clojure.string :as str]
            [clojure.tools.logging :as log]
            [integrant.core :as ig]
            [muesli.relay.auth :as auth]
            [muesli.relay.config :as config]
            [muesli.relay.db :as db]
            [muesli.relay.handler :as handler]
            [muesli.relay.pipeline :as pipeline]
            [muesli.relay.sweeper :as sweeper]
            [ring.adapter.jetty :as jetty]))

;;;; System

(defmethod ig/init-key :relay/db [_ {:keys [cfg]}]
  (db/datasource (get-in cfg [:db :file])))

(defmethod ig/init-key :relay/pipeline-state [_ _] (pipeline/state {}))

(defmethod ig/init-key :relay/ctx [_ ctx] ctx)

(defmethod ig/init-key :relay/pipeline [_ {:keys [ctx]}]
  (log/info (format "transcribing with %s (%s), diarization %s"
                    (get-in ctx [:cfg :transcription :base-url])
                    (get-in ctx [:cfg :transcription :model])
                    (name (get-in ctx [:cfg :diarization :backend] :none))))
  {:ctx ctx :scheduler (pipeline/start ctx)})

(defmethod ig/halt-key! :relay/pipeline [_ {:keys [ctx scheduler]}]
  (pipeline/stop ctx scheduler))

(defmethod ig/init-key :relay/server [_ {:keys [ctx]}]
  (let [{:keys [host port]} (get-in ctx [:cfg :http])
        server (jetty/run-jetty (handler/handler ctx)
                                {:host host :port port :join? false
                                 :send-server-version? false})]
    (log/info (format "muesli-relay listening on http://%s:%d (public URL %s)"
                      host port (get-in ctx [:cfg :base-url])))
    server))

(defmethod ig/halt-key! :relay/server [_ server] (.stop server))

(defmethod ig/init-key :relay/sweeper [_ {:keys [ctx]}] (sweeper/start ctx))
(defmethod ig/halt-key! :relay/sweeper [_ ex] (.shutdownNow ex))

(defn system-config [cfg]
  {:relay/db {:cfg cfg}
   :relay/pipeline-state {}
   :relay/ctx {:cfg cfg :ds (ig/ref :relay/db) :pipeline (ig/ref :relay/pipeline-state)}
   :relay/pipeline {:ctx (ig/ref :relay/ctx)}
   :relay/server {:ctx (ig/ref :relay/ctx)}
   :relay/sweeper {:ctx (ig/ref :relay/ctx)}})

(defn start
  ([] (start (config/load-config)))
  ([cfg] (ig/init (system-config cfg))))

(defn stop [system] (ig/halt! system))

;;;; CLI

(defn- read-password [prompt]
  (if-let [c (System/console)]
    (let [a (String. (.readPassword c "%s" (into-array Object [prompt])))
          b (String. (.readPassword c "%s" (into-array Object ["Repeat: "])))]
      (if (= a b) a (do (println "Passwords differ.") (System/exit 1))))
    ;; Non-interactive: first line of stdin.
    (or (read-line) "")))

(defn- die [& msg] (binding [*out* *err*] (apply println msg)) (System/exit 1))

(defn user-cmd [ds [cmd username & flags]]
  (let [user (when username (db/user-by-name ds username))]
    (case cmd
      "list" (doseq [u (db/users ds)]
               (println (format "%-24s %s%s" (:username u)
                                (if (= 1 (:is_admin u)) "admin" "user")
                                (if (= 1 (:disabled u)) " (disabled)" ""))))
      "add" (cond
              (not (and username (re-matches #"[a-z0-9_.-]{2,40}" username)))
              (die "Usernames are 2-40 lowercase letters, digits, . _ or -")
              user (die "User exists:" username)
              :else (let [pw (read-password "Password: ")]
                      (when (< (count pw) 12) (die "Passwords need at least 12 characters"))
                      (db/create-user! ds {:username username :password-hash (auth/hash-password pw)
                                           :admin? (some #{"--admin"} flags)})
                      (println "Created" username)))
      "passwd" (if-not user (die "No such user:" username)
                       (let [pw (read-password "New password: ")]
                         (when (< (count pw) 12) (die "Passwords need at least 12 characters"))
                         (db/set-password! ds (:id user) (auth/hash-password pw))
                         (println "Password changed for" username)))
      "disable" (if user (do (db/set-disabled! ds (:id user) true) (println "Disabled" username))
                    (die "No such user:" username))
      "enable" (if user (do (db/set-disabled! ds (:id user) false) (println "Enabled" username))
                   (die "No such user:" username))
      (die "Usage: relay user add NAME [--admin] | passwd NAME | disable NAME | enable NAME | list"))))

(defn -main [& args]
  (let [cfg (config/load-config)]
    (case (first args)
      (nil "serve") (let [system (start cfg)]
                      (.addShutdownHook (Runtime/getRuntime) (Thread. #(stop system))))
      "user" (do (user-cmd (db/datasource (get-in cfg [:db :file])) (rest args))
                 (shutdown-agents))
      (die "Usage: relay [serve] | relay user ..."))))
