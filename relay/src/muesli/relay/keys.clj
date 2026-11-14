(ns muesli.relay.keys
  "API key generation and hashing.  A key is msl_ followed by 32 random
  bytes in lowercase base32; only its SHA-256 is stored."
  (:import (java.security MessageDigest SecureRandom)))

(def ^:private alphabet "abcdefghijklmnopqrstuvwxyz234567")

(defn base32
  "Unpadded lowercase RFC 4648 base32 of byte array BS."
  [^bytes bs]
  (let [sb (StringBuilder.)]
    (loop [i 0 buffer 0 bits 0]
      (if (< i (alength bs))
        (let [buffer (bit-or (bit-shift-left buffer 8) (bit-and 0xff (aget bs i)))
              bits (+ bits 8)
              [buffer bits] (loop [buffer buffer bits bits]
                              (if (>= bits 5)
                                (do (.append sb (.charAt ^String alphabet
                                                         (bit-and 31 (bit-shift-right buffer (- bits 5)))))
                                    (recur buffer (- bits 5)))
                                [(bit-and buffer (dec (bit-shift-left 1 bits))) bits]))]
          (recur (inc i) buffer bits))
        (when (pos? bits)
          (.append sb (.charAt ^String alphabet (bit-and 31 (bit-shift-left buffer (- 5 bits))))))))
    (str sb)))

(defn hex [^bytes bs]
  (let [sb (StringBuilder.)]
    (doseq [b bs] (.append sb (format "%02x" (bit-and 0xff b))))
    (str sb)))

(defn sha256-hex [^String s]
  (hex (.digest (MessageDigest/getInstance "SHA-256") (.getBytes s "UTF-8"))))

(defn generate
  "Return {:key full-key :prefix display-prefix :hash sha256-hex}."
  []
  (let [b (byte-array 32)
        _ (.nextBytes (SecureRandom.) b)
        k (str "msl_" (base32 b))]
    {:key k :prefix (subs k 4 12) :hash (sha256-hex k)}))

(defn well-formed? [s]
  (boolean (and (string? s) (re-matches #"msl_[a-z2-7]{52}" s))))
