(ns build
  "clojure -T:build uber   builds the PWA (npx shadow-cljs release) and
  target/muesli-relay.jar."
  (:require [clojure.java.process :as process]
            [clojure.tools.build.api :as b]))

(def class-dir "target/classes")
(def uber-file "target/muesli-relay.jar")

(defn clean [_] (b/delete {:path "target"}))

(defn pwa [_]
  (let [p (process/start {:out :inherit :err :inherit} "npx" "shadow-cljs" "release" "app" "sw")]
    (when-not (zero? @(process/exit-ref p))
      (throw (ex-info "PWA build failed" {})))))

(defn uber [_]
  (clean nil)
  (pwa nil)
  (let [basis (b/create-basis {:project "deps.edn"})]
    (b/copy-dir {:src-dirs ["src" "resources"] :target-dir class-dir
                 :ignores [#".*\.cljs$" #"manifest\.edn$"]})
    (b/compile-clj {:basis basis :ns-compile '[muesli.relay.main] :class-dir class-dir})
    (b/uber {:class-dir class-dir :uber-file uber-file :basis basis
             :main 'muesli.relay.main})
    (println "Built" uber-file)))
