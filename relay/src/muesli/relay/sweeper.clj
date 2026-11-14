(ns muesli.relay.sweeper
  "Periodic cleanup: delete delivered audio after the retention period,
  mark stalled recordings abandoned, purge old abandoned ones."
  (:require [clojure.tools.logging :as log]
            [muesli.relay.db :as db]
            [muesli.relay.recordings :as recs]
            [muesli.relay.storage :as storage])
  (:import (java.util.concurrent Executors ScheduledExecutorService TimeUnit)))

(def ^:private hour (* 3600 1000))

(defn sweep!
  "Run one cleanup pass as of NOW (ms).  Returns counts for logging/tests."
  [{:keys [ds cfg] :as ctx} now]
  (let [{:keys [after-ack-hours abandon-after-hours purge-abandoned-days]} (:retention cfg)
        delivered (db/q ds ["SELECT * FROM recordings WHERE status = 'delivered' AND audio_deleted = 0
                              AND delivered_at < ?" (- now (* hour after-ack-hours))])
        stalled (db/q ds ["SELECT id FROM recordings WHERE status = 'recording' AND last_part_at < ?"
                          (- now (* hour abandon-after-hours))])
        purge (db/q ds ["SELECT * FROM recordings WHERE status = 'abandoned' AND last_part_at < ?"
                        (- now (* 24 hour purge-abandoned-days))])]
    (doseq [r delivered] (recs/delete-audio! ctx r))
    (doseq [{:keys [id]} stalled] (db/update-recording! ds id {:status "abandoned"}))
    (doseq [r purge]
      (storage/delete-recording-files! (get-in cfg [:storage :dir]) (:user_id r) (:id r))
      (db/delete-recording! ds (:id r)))
    {:deleted-audio (count delivered) :abandoned (count stalled) :purged (count purge)}))

(defn start ^ScheduledExecutorService [ctx]
  (let [minutes (get-in ctx [:cfg :retention :sweep-minutes] 10)
        ex (Executors/newSingleThreadScheduledExecutor)]
    (.scheduleWithFixedDelay ex
                             (fn []
                               (try
                                 (let [r (sweep! ctx (db/now))]
                                   (when (some pos? (vals r)) (log/info "sweep" r)))
                                 (catch Throwable t (log/error t "sweep failed"))))
                             1 (* 60 minutes) TimeUnit/SECONDS)
    ex))
