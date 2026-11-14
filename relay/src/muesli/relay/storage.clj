(ns muesli.relay.storage
  "Audio files on disk: <dir>/<user-id>/<recording-id>/parts/<seq>.bin
  while recording, <dir>/<user-id>/<recording-id>/audio.<ext> once
  finished.  Paths are only ever built from UUIDs and integers."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [muesli.relay.keys :as keys])
  (:import (java.io File InputStream)
           (java.nio.file Files StandardCopyOption CopyOption)
           (java.security MessageDigest)))

(def mime-types
  "Accepted recording MIME types (base type) and the file extension used."
  {"audio/webm" "webm"
   "audio/ogg" "ogg"
   "audio/mp4" "m4a"
   "audio/mpeg" "mp3"
   "audio/wav" "wav"})

(defn base-mime [mime]
  (str/trim (first (str/split (str/lower-case (str mime)) #";"))))

(defn allowed-mime? [mime]
  (contains? mime-types (base-mime mime)))

(defn extension [mime]
  (get mime-types (base-mime mime) "bin"))

(defn recording-dir ^File [root user-id recording-id]
  (io/file root user-id recording-id))

(defn part-file ^File [root user-id recording-id seq-no]
  (io/file (recording-dir root user-id recording-id) "parts" (str seq-no ".bin")))

(defn audio-file ^File [root {:keys [user_id id mime_type]}]
  (io/file (recording-dir root user_id id) (str "audio." (extension mime_type))))

(defn- move! [^File from ^File to]
  (Files/move (.toPath from) (.toPath to)
              (into-array CopyOption [StandardCopyOption/REPLACE_EXISTING
                                      StandardCopyOption/ATOMIC_MOVE])))

(defn write-part!
  "Stream IN to a temp file, at most LIMIT bytes.  Returns
  {:file tmp :bytes n :sha256 hex} or {:error :too-large}.  The caller
  moves the temp file into place with `commit-part!` or deletes it."
  [root user-id recording-id ^InputStream in limit]
  (let [dir (io/file (recording-dir root user-id recording-id) "parts")
        _ (.mkdirs dir)
        tmp (File/createTempFile "part-" ".tmp" dir)
        md (MessageDigest/getInstance "SHA-256")
        buf (byte-array 65536)]
    (try
      (with-open [out (io/output-stream tmp)]
        (loop [total 0]
          (let [n (if in (.read in buf) -1)]
            (cond
              (neg? n) {:file tmp :bytes total :sha256 (keys/hex (.digest md))}
              (> (+ total n) limit) (do (.delete tmp) {:error :too-large})
              :else (do (.write out buf 0 n)
                        (.update md buf 0 n)
                        (recur (+ total n)))))))
      (catch Exception e
        (.delete tmp)
        (throw e)))))

(defn commit-part! [root user-id recording-id seq-no ^File tmp]
  (move! tmp (part-file root user-id recording-id seq-no)))

(defn assemble!
  "Concatenate parts 0..N-1 into the recording's audio file.
  Returns {:bytes n :sha256 hex}.  Parts are deleted afterwards."
  [root rec n]
  (let [out-file (audio-file root rec)
        tmp (io/file (.getParentFile out-file) "audio.tmp")
        md (MessageDigest/getInstance "SHA-256")
        buf (byte-array 65536)
        total (with-open [out (io/output-stream tmp)]
                (reduce (fn [total i]
                          (with-open [in (io/input-stream (part-file root (:user_id rec) (:id rec) i))]
                            (loop [total total]
                              (let [k (.read in buf)]
                                (if (neg? k)
                                  total
                                  (do (.write out buf 0 k)
                                      (.update md buf 0 k)
                                      (recur (+ total k))))))))
                        0 (range n)))]
    (move! tmp out-file)
    (doseq [f (.listFiles (io/file (recording-dir root (:user_id rec) (:id rec)) "parts"))]
      (.delete ^File f))
    (.delete (io/file (recording-dir root (:user_id rec) (:id rec)) "parts"))
    {:bytes total :sha256 (keys/hex (.digest md))}))

(defn delete-recording-files! [root user-id recording-id]
  (let [dir (recording-dir root user-id recording-id)]
    (when (.exists dir)
      (doseq [^File f (reverse (file-seq dir))]
        (.delete f)))))
