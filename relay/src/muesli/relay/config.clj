(ns muesli.relay.config
  "Loads config.edn (or the file named by RELAY_CONFIG) with aero."
  (:require [aero.core :as aero]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import (java.security SecureRandom MessageDigest)
           (java.util Base64)))

(defn load-config
  "Read the configuration.  OVERRIDES is deep-merged on top (used by tests)."
  ([] (load-config nil))
  ([overrides]
   (let [src (if-let [f (System/getenv "RELAY_CONFIG")]
               (io/file f)
               (io/resource "config.edn"))
         cfg (aero/read-config src)]
     (merge-with (fn [a b] (if (and (map? a) (map? b)) (merge a b) b))
                 cfg overrides))))

(defn https? [cfg]
  (str/starts-with? (str (:base-url cfg)) "https://"))

(defn- sha256 ^bytes [^String s]
  (.digest (MessageDigest/getInstance "SHA-256") (.getBytes s "UTF-8")))

(defn session-key
  "Return the 16-byte cookie-store key.  Derived from :session :secret when
  set, otherwise from a random secret persisted next to the database."
  ^bytes [cfg]
  (let [secret (or (not-empty (get-in cfg [:session :secret]))
                   (let [f (io/file (.getParentFile (.getAbsoluteFile (io/file (get-in cfg [:db :file]))))
                                    "session.key")]
                     (if (.exists f)
                       (str/trim (slurp f))
                       (let [b (byte-array 32)]
                         (.nextBytes (SecureRandom.) b)
                         (io/make-parents f)
                         (let [s (.encodeToString (Base64/getEncoder) b)]
                           (spit f s)
                           (.setReadable f false false)
                           (.setReadable f true true)
                           s)))))]
    (java.util.Arrays/copyOf (sha256 secret) 16)))
