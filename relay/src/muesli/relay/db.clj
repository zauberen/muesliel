(ns muesli.relay.db
  "SQLite storage.  Migrations follow the same rule as muesli-db.el: a
  vector of [VERSION statements], current version in PRAGMA user_version,
  released entries are never edited."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [jsonista.core :as json]
            [next.jdbc :as jdbc]
            [next.jdbc.result-set :as rs]))

(def migrations
  [[1
    ["CREATE TABLE users (
        id            TEXT PRIMARY KEY,
        username      TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        is_admin      INTEGER NOT NULL DEFAULT 0,
        disabled      INTEGER NOT NULL DEFAULT 0,
        created_at    INTEGER NOT NULL)"
     "CREATE TABLE api_keys (
        id           TEXT PRIMARY KEY,
        user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        name         TEXT NOT NULL,
        prefix       TEXT NOT NULL,
        key_hash     TEXT NOT NULL UNIQUE,
        created_at   INTEGER NOT NULL,
        last_used_at INTEGER,
        revoked_at   INTEGER)"
     "CREATE TABLE clients (
        id           TEXT PRIMARY KEY,
        user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        api_key_id   TEXT NOT NULL UNIQUE REFERENCES api_keys(id) ON DELETE CASCADE,
        name         TEXT NOT NULL,
        profiles     TEXT NOT NULL,
        emacs_info   TEXT,
        linked_at    INTEGER NOT NULL,
        last_seen_at INTEGER)"
     "CREATE TABLE recordings (
        id            TEXT PRIMARY KEY,
        user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        client_id     TEXT REFERENCES clients(id) ON DELETE SET NULL,
        profile       TEXT NOT NULL,
        title         TEXT,
        notes         TEXT,
        mime_type     TEXT NOT NULL,
        status        TEXT NOT NULL,
        reject_reason TEXT,
        started_at    INTEGER NOT NULL,
        ended_at      INTEGER,
        duration_ms   INTEGER,
        part_count    INTEGER,
        bytes         INTEGER NOT NULL DEFAULT 0,
        sha256        TEXT,
        delivered_at  INTEGER,
        meeting_id    TEXT,
        audio_deleted INTEGER NOT NULL DEFAULT 0,
        last_part_at  INTEGER,
        created_at    INTEGER NOT NULL)"
     "CREATE TABLE recording_parts (
        recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
        seq          INTEGER NOT NULL,
        bytes        INTEGER NOT NULL,
        sha256       TEXT NOT NULL,
        received_at  INTEGER NOT NULL,
        PRIMARY KEY (recording_id, seq))"
     "CREATE INDEX recordings_client_status ON recordings(client_id, status)"
     "CREATE INDEX recordings_user_created ON recordings(user_id, created_at)"]]])

(def ^:private opts {:builder-fn rs/as-unqualified-lower-maps})

(defn now [] (System/currentTimeMillis))
(defn new-id [] (str (random-uuid)))

(defn q [ds sqlv] (jdbc/execute! ds sqlv opts))
(defn q1 [ds sqlv] (jdbc/execute-one! ds sqlv opts))
(defn exec! [ds sqlv] (:next.jdbc/update-count (jdbc/execute-one! ds sqlv)))

(defn version [ds]
  (:user_version (q1 ds ["PRAGMA user_version"])))

(defn latest-version [] (first (last migrations)))

(defn migrate!
  "Bring DS up to the latest schema version and return it."
  [ds]
  (let [current (version ds)]
    (when (> current (latest-version))
      (throw (ex-info (format "Database schema version %d is newer than this relay supports (%d)"
                              current (latest-version)) {})))
    (doseq [[v stmts] migrations
            :when (> v current)]
      (jdbc/with-transaction [tx ds]
        (doseq [s stmts] (jdbc/execute! tx [s]))
        ;; PRAGMA takes no bound parameters; V is an integer literal.
        (jdbc/execute! tx [(str "PRAGMA user_version = " (long v))])))
    (version ds)))

(defn datasource
  "Open (creating if needed) the SQLite database FILE and migrate it."
  [file]
  (io/make-parents (io/file file))
  (let [ds (jdbc/get-datasource
            {:jdbcUrl (str "jdbc:sqlite:" file
                           "?foreign_keys=true&busy_timeout=10000&journal_mode=WAL")})]
    (migrate! ds)
    ds))

;;;; Users

(defn user-by-name [ds username]
  (q1 ds ["SELECT * FROM users WHERE username = ?" username]))

(defn user-by-id [ds id]
  (q1 ds ["SELECT * FROM users WHERE id = ?" id]))

(defn users [ds]
  (q ds ["SELECT id, username, is_admin, disabled, created_at FROM users ORDER BY username"]))

(defn create-user! [ds {:keys [username password-hash admin?]}]
  (let [id (new-id)]
    (exec! ds ["INSERT INTO users (id, username, password_hash, is_admin, created_at)
                VALUES (?, ?, ?, ?, ?)" id username password-hash (if admin? 1 0) (now)])
    id))

(defn set-password! [ds user-id password-hash]
  (exec! ds ["UPDATE users SET password_hash = ? WHERE id = ?" password-hash user-id]))

(defn set-disabled! [ds user-id disabled?]
  (exec! ds ["UPDATE users SET disabled = ? WHERE id = ?" (if disabled? 1 0) user-id]))

;;;; API keys

(defn create-key! [ds {:keys [user-id name prefix key-hash]}]
  (let [id (new-id)]
    (exec! ds ["INSERT INTO api_keys (id, user_id, name, prefix, key_hash, created_at)
                VALUES (?, ?, ?, ?, ?, ?)" id user-id name prefix key-hash (now)])
    id))

(defn keys-for-user [ds user-id]
  (q ds ["SELECT k.*, c.name AS client_name, c.id AS client_id
            FROM api_keys k LEFT JOIN clients c ON c.api_key_id = k.id
           WHERE k.user_id = ? ORDER BY k.created_at DESC" user-id]))

(defn active-key-by-hash
  "Return the non-revoked key with KEY-HASH of an enabled user, joined with
  its user and client (both may be nil for client)."
  [ds key-hash]
  (q1 ds ["SELECT k.id AS key_id, k.user_id, u.username, c.id AS client_id
             FROM api_keys k
             JOIN users u ON u.id = k.user_id
             LEFT JOIN clients c ON c.api_key_id = k.id
            WHERE k.key_hash = ? AND k.revoked_at IS NULL AND u.disabled = 0" key-hash]))

(defn touch-key! [ds key-id client-id]
  (let [t (now)]
    (exec! ds ["UPDATE api_keys SET last_used_at = ? WHERE id = ?" t key-id])
    (when client-id
      (exec! ds ["UPDATE clients SET last_seen_at = ? WHERE id = ?" t client-id]))))

(defn revoke-key! [ds user-id key-id]
  (exec! ds ["UPDATE api_keys SET revoked_at = ? WHERE id = ? AND user_id = ? AND revoked_at IS NULL"
             (now) key-id user-id]))

;;;; Clients

(defn- decode-client [c]
  (when c
    (-> c
        (update :profiles #(json/read-value % json/keyword-keys-object-mapper))
        (update :emacs_info #(some-> % (json/read-value json/keyword-keys-object-mapper))))))

(defn upsert-client!
  "Create or update the client bound to KEY-ID.  Return its id."
  [ds {:keys [key-id user-id name profiles emacs]}]
  (let [t (now)
        p (json/write-value-as-string profiles)
        e (some-> emacs json/write-value-as-string)]
    (if-let [existing (q1 ds ["SELECT id FROM clients WHERE api_key_id = ?" key-id])]
      (do (exec! ds ["UPDATE clients SET name = ?, profiles = ?, emacs_info = ?, last_seen_at = ?
                      WHERE id = ?" name p e t (:id existing)])
          (:id existing))
      (let [id (new-id)]
        (exec! ds ["INSERT INTO clients (id, user_id, api_key_id, name, profiles, emacs_info, linked_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)" id user-id key-id name p e t t])
        id))))

(defn clients-for-user
  "Clients of USER-ID whose key is still active."
  [ds user-id]
  (mapv decode-client
        (q ds ["SELECT c.* FROM clients c JOIN api_keys k ON k.id = c.api_key_id
                 WHERE c.user_id = ? AND k.revoked_at IS NULL ORDER BY c.name" user-id])))

(defn client [ds user-id client-id]
  (decode-client
   (q1 ds ["SELECT c.* FROM clients c JOIN api_keys k ON k.id = c.api_key_id
             WHERE c.user_id = ? AND c.id = ? AND k.revoked_at IS NULL" user-id client-id])))

(defn rename-client! [ds user-id client-id name]
  (exec! ds ["UPDATE clients SET name = ? WHERE id = ? AND user_id = ?" name client-id user-id]))

(defn delete-client! [ds user-id client-id]
  (exec! ds ["DELETE FROM clients WHERE id = ? AND user_id = ?" client-id user-id]))

;;;; Recordings

(defn recording [ds id]
  (q1 ds ["SELECT * FROM recordings WHERE id = ?" id]))

(defn user-recording [ds user-id id]
  (q1 ds ["SELECT * FROM recordings WHERE id = ? AND user_id = ?" id user-id]))

(defn create-recording! [ds {:keys [id user-id client-id profile title mime-type started-at]}]
  (let [t (now)]
    (exec! ds ["INSERT INTO recordings (id, user_id, client_id, profile, title, mime_type, status,
                                        started_at, last_part_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, 'recording', ?, ?, ?)"
               id user-id client-id profile title mime-type started-at t t])))

(defn recordings-for-user [ds user-id limit]
  (q ds ["SELECT r.*, c.name AS client_name FROM recordings r
            LEFT JOIN clients c ON c.id = r.client_id
           WHERE r.user_id = ? ORDER BY r.created_at DESC LIMIT ?" user-id limit]))

(defn recordings-for-client
  "Recordings assigned to CLIENT-ID in STATUS.  Rejected ready ones are
  left out so Emacs does not reject them again on every fetch."
  [ds client-id status]
  (q ds [(str "SELECT * FROM recordings WHERE client_id = ? AND status = ?"
              (when (= status "ready") " AND reject_reason IS NULL")
              " ORDER BY started_at")
         client-id status]))

(defn update-recording! [ds id m]
  (when (seq m)
    (let [cols (keys m)]
      (doseq [c cols]
        (when-not (re-matches #"[a-z_][a-z0-9_]*" (name c))
          (throw (ex-info "bad column" {:column c}))))
      (exec! ds (into [(str "UPDATE recordings SET "
                            (str/join ", " (map #(str (name %) " = ?") cols))
                            " WHERE id = ?")]
                      (concat (vals m) [id]))))))

(defn delete-recording! [ds id]
  (exec! ds ["DELETE FROM recordings WHERE id = ?" id]))

(defn part [ds recording-id seq-no]
  (q1 ds ["SELECT * FROM recording_parts WHERE recording_id = ? AND seq = ?" recording-id seq-no]))

(defn add-part!
  "Record a new part and bump the recording's byte count."
  [ds recording-id seq-no bytes sha]
  (jdbc/with-transaction [tx ds]
    (let [t (now)]
      (jdbc/execute! tx ["INSERT INTO recording_parts (recording_id, seq, bytes, sha256, received_at)
                          VALUES (?, ?, ?, ?, ?)" recording-id seq-no bytes sha t])
      (jdbc/execute! tx ["UPDATE recordings SET bytes = bytes + ?, last_part_at = ?,
                                 status = CASE status WHEN 'abandoned' THEN 'recording' ELSE status END
                          WHERE id = ?" bytes t recording-id]))))

(defn part-seqs [ds recording-id]
  (mapv :seq (q ds ["SELECT seq FROM recording_parts WHERE recording_id = ? ORDER BY seq" recording-id])))

(defn delete-parts! [ds recording-id]
  (exec! ds ["DELETE FROM recording_parts WHERE recording_id = ?" recording-id]))
