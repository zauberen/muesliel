(ns muesli.relay.test-runner
  (:require [clojure.test :as t]
            [muesli.relay.relay-test]))

(defn -main [& _]
  (let [{:keys [fail error]} (t/run-tests 'muesli.relay.relay-test)]
    (shutdown-agents)
    (System/exit (if (zero? (+ fail error)) 0 1))))
