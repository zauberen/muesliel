;;; muesli-db.el --- SQLite storage for muesli  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Schema, migrations and queries.  Rows are returned as plists whose
;; keys are the column names as keywords, e.g. (:id "..." :title "...").

;;; Code:

(require 'muesli-core)

(declare-function sqlite-open "sqlite.c")
(declare-function sqlite-close "sqlite.c")
(declare-function sqlite-execute "sqlite.c")
(declare-function sqlite-select "sqlite.c")
(declare-function sqlite-transaction "sqlite.c")
(declare-function sqlite-commit "sqlite.c")
(declare-function sqlite-rollback "sqlite.c")
(declare-function sqlite-available-p "sqlite.c")

(defcustom muesli-database-file
  (expand-file-name "muesli.sqlite" muesli-data-directory)
  "SQLite database holding meetings, chunks, segments and speakers."
  :type 'file
  :group 'muesli)

(defvar muesli-db--connection nil
  "Open database connection, or nil.")

(defvar muesli-db--connection-file nil
  "File that `muesli-db--connection' was opened on.")

(defconst muesli-db--migrations
  '((1
     "CREATE TABLE meetings (
        id            TEXT PRIMARY KEY,
        file          TEXT,
        title         TEXT,
        category      TEXT,
        mode          TEXT NOT NULL,
        started_at    INTEGER NOT NULL,
        ended_at      INTEGER,
        status        TEXT NOT NULL,
        error         TEXT,
        failed_step   TEXT,
        notes_raw     TEXT,
        summary       TEXT,
        audio_dir     TEXT,
        chunk_seconds INTEGER NOT NULL DEFAULT 30)"
     "CREATE TABLE chunks (
        meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        track       TEXT NOT NULL,
        chunk_no    INTEGER NOT NULL,
        path        TEXT NOT NULL,
        status      TEXT NOT NULL,
        attempts    INTEGER NOT NULL DEFAULT 0,
        offset_ms   INTEGER,
        duration_ms INTEGER,
        PRIMARY KEY (meeting_id, track, chunk_no))"
     "CREATE TABLE segments (
        id          INTEGER PRIMARY KEY,
        meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        track       TEXT NOT NULL,
        chunk_no    INTEGER NOT NULL,
        start_ms    INTEGER NOT NULL,
        end_ms      INTEGER NOT NULL,
        speaker     TEXT,
        text        TEXT NOT NULL,
        words       TEXT)"
     "CREATE INDEX segments_meeting_time ON segments(meeting_id, start_ms)"
     "CREATE TABLE speakers (
        meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        label       TEXT NOT NULL,
        name        TEXT,
        PRIMARY KEY (meeting_id, label))"))
  "Schema migrations as (VERSION SQL...) in ascending order.
Each entry upgrades the schema from VERSION - 1 to VERSION.  The
current version lives in PRAGMA user_version.  Never edit a released
entry; append a new one instead.")

(defun muesli-db--latest-version ()
  "Return the schema version the migrations lead to."
  (car (car (last muesli-db--migrations))))

(defun muesli-db--version (db)
  "Return DB's schema version."
  (caar (sqlite-select db "PRAGMA user_version")))

(defun muesli-db-migrate (db)
  "Bring DB up to the latest schema version.  Return the new version."
  (let ((current (muesli-db--version db)))
    (when (> current (muesli-db--latest-version))
      (error "Muesli database %s has schema version %d, newer than this package supports (%d)"
             muesli-database-file current (muesli-db--latest-version)))
    (dolist (migration muesli-db--migrations)
      (let ((version (car migration)))
        (when (> version current)
          (sqlite-transaction db)
          (condition-case err
              (progn
                (dolist (sql (cdr migration))
                  (sqlite-execute db sql))
                ;; PRAGMA takes no bound parameters; VERSION is an integer.
                (sqlite-execute db (format "PRAGMA user_version = %d" version))
                (sqlite-commit db))
            (error (sqlite-rollback db)
                   (signal (car err) (cdr err))))
          (setq current version))))
    current))

(defun muesli-db ()
  "Return an open, migrated connection to `muesli-database-file'."
  (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (user-error "Muesli needs Emacs built with SQLite support"))
  (unless (and muesli-db--connection
               (equal muesli-db--connection-file muesli-database-file))
    (muesli-db-close)
    (make-directory (file-name-directory muesli-database-file) t)
    (let ((db (sqlite-open muesli-database-file)))
      (sqlite-execute db "PRAGMA foreign_keys = ON")
      (muesli-db-migrate db)
      (setq muesli-db--connection db
            muesli-db--connection-file muesli-database-file)))
  muesli-db--connection)

(defun muesli-db-close ()
  "Close the database connection if one is open."
  (when muesli-db--connection
    (ignore-errors (sqlite-close muesli-db--connection))
    (setq muesli-db--connection nil
          muesli-db--connection-file nil)))

;;;; Generic helpers

(defun muesli-db--select (sql &optional values)
  "Run SQL with VALUES and return the rows as plists."
  (let* ((result (sqlite-select (muesli-db) sql values 'full))
         (keys (mapcar (lambda (c) (intern (concat ":" c))) (car result))))
    (mapcar (lambda (row) (cl-mapcan #'list keys row)) (cdr result))))

(defun muesli-db--execute (sql &optional values)
  "Run SQL with VALUES for its side effects."
  (sqlite-execute (muesli-db) sql values))

(defun muesli-db--column-name (key)
  "Turn keyword KEY into a column name, checking it is a plain word."
  (let ((name (substring (symbol-name key) 1)))
    (unless (string-match-p "\\`[a-z_]+\\'" name)
      (error "Invalid column name %S" key))
    name))

;;;; Meetings

(defun muesli-db-meeting-create (id &rest props)
  "Insert or replace meeting ID with column values from PROPS."
  (let* ((props (plist-put (copy-sequence props) :id id))
         (cols '()) (vals '()))
    (cl-loop for (k v) on props by #'cddr
             do (push (muesli-db--column-name k) cols)
             (push v vals))
    (muesli-db--execute
     (format "INSERT OR REPLACE INTO meetings (%s) VALUES (%s)"
             (string-join (nreverse cols) ", ")
             (string-join (make-list (length vals) "?") ", "))
     (nreverse vals))))

(defun muesli-db-meeting (id)
  "Return the meeting row for ID as a plist, or nil."
  (car (muesli-db--select "SELECT * FROM meetings WHERE id = ?" (list id))))

(defun muesli-db-meeting-update (id &rest props)
  "Set the columns given in PROPS on meeting ID."
  (let ((sets '()) (vals '()))
    (cl-loop for (k v) on props by #'cddr
             do (push (format "%s = ?" (muesli-db--column-name k)) sets)
             (push v vals))
    (when sets
      (muesli-db--execute
       (format "UPDATE meetings SET %s WHERE id = ?"
               (string-join (nreverse sets) ", "))
       (append (nreverse vals) (list id))))))

(defun muesli-db-meetings (&optional statuses)
  "Return all meetings, newest first, optionally only those in STATUSES."
  (if statuses
      (muesli-db--select
       (format "SELECT * FROM meetings WHERE status IN (%s) ORDER BY started_at DESC"
               (string-join (make-list (length statuses) "?") ", "))
       statuses)
    (muesli-db--select "SELECT * FROM meetings ORDER BY started_at DESC")))

(defun muesli-db-meeting-delete (id)
  "Delete meeting ID and, through cascading, all its rows."
  (muesli-db--execute "DELETE FROM meetings WHERE id = ?" (list id)))

;;;; Chunks

(defun muesli-db-chunk-add (meeting-id track chunk-no path
                                       &optional offset-ms duration-ms)
  "Register chunk CHUNK-NO of TRACK for MEETING-ID at PATH.
OFFSET-MS is where the chunk starts relative to the meeting start and
DURATION-MS its length, when known.  Return non-nil if the chunk was
new."
  (unless (muesli-db-chunk meeting-id track chunk-no)
    (muesli-db--execute
     "INSERT INTO chunks (meeting_id, track, chunk_no, path, status, offset_ms, duration_ms)
      VALUES (?, ?, ?, ?, 'pending', ?, ?)"
     (list meeting-id track chunk-no path offset-ms duration-ms))
    t))

(defun muesli-db-chunk (meeting-id track chunk-no)
  "Return chunk CHUNK-NO of TRACK in MEETING-ID, or nil."
  (car (muesli-db--select
        "SELECT * FROM chunks WHERE meeting_id = ? AND track = ? AND chunk_no = ?"
        (list meeting-id track chunk-no))))

(defun muesli-db-chunk-update (meeting-id track chunk-no &rest props)
  "Set PROPS columns on chunk CHUNK-NO of TRACK in MEETING-ID."
  (let ((sets '()) (vals '()))
    (cl-loop for (k v) on props by #'cddr
             do (push (format "%s = ?" (muesli-db--column-name k)) sets)
             (push v vals))
    (muesli-db--execute
     (format "UPDATE chunks SET %s WHERE meeting_id = ? AND track = ? AND chunk_no = ?"
             (string-join (nreverse sets) ", "))
     (append (nreverse vals) (list meeting-id track chunk-no)))))

(defun muesli-db-chunks (meeting-id &optional statuses)
  "Return chunks of MEETING-ID in recording order, optionally in STATUSES."
  (muesli-db--select
   (concat "SELECT * FROM chunks WHERE meeting_id = ?"
           (if statuses
               (format " AND status IN (%s)"
                       (string-join (make-list (length statuses) "?") ", "))
             "")
           " ORDER BY chunk_no, track")
   (cons meeting-id statuses)))

(defun muesli-db-chunks-reset-uploading ()
  "Mark chunks left in `uploading' by a dead Emacs as `pending' again."
  (muesli-db--execute "UPDATE chunks SET status = 'pending' WHERE status = 'uploading'"))

;;;; Segments

(defun muesli-db-segment-add (meeting-id track chunk-no start-ms end-ms text
                                         &optional speaker words)
  "Store a transcript segment for MEETING-ID.
TRACK, CHUNK-NO, START-MS, END-MS and TEXT describe the segment.
SPEAKER is a label or nil.  WORDS is a list of (START-MS END-MS WORD)."
  (muesli-db--execute
   "INSERT INTO segments (meeting_id, track, chunk_no, start_ms, end_ms, speaker, text, words)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
   (list meeting-id track chunk-no start-ms end-ms speaker text
         (when words (prin1-to-string words)))))

(defun muesli-db-segments (meeting-id &optional track)
  "Return segments of MEETING-ID in time order, optionally only TRACK.
The :words value is decoded back into a list."
  (mapcar (lambda (row)
            (let ((w (plist-get row :words)))
              (plist-put row :words (and w (car (read-from-string w))))))
          (muesli-db--select
           (concat "SELECT * FROM segments WHERE meeting_id = ?"
                   (if track " AND track = ?" "")
                   " ORDER BY start_ms, id")
           (if track (list meeting-id track) (list meeting-id)))))

(defun muesli-db-segment-set-speaker (segment-id speaker)
  "Set the speaker label of SEGMENT-ID to SPEAKER."
  (muesli-db--execute "UPDATE segments SET speaker = ? WHERE id = ?"
                      (list speaker segment-id)))

(defun muesli-db-segment-delete (segment-id)
  "Delete SEGMENT-ID."
  (muesli-db--execute "DELETE FROM segments WHERE id = ?" (list segment-id)))

(defun muesli-db-segments-clear-chunk (meeting-id track chunk-no)
  "Delete segments from CHUNK-NO of TRACK in MEETING-ID (before a retry)."
  (muesli-db--execute
   "DELETE FROM segments WHERE meeting_id = ? AND track = ? AND chunk_no = ?"
   (list meeting-id track chunk-no)))

;;;; Speakers

(defun muesli-db-speaker-add (meeting-id label &optional name)
  "Register speaker LABEL for MEETING-ID, keeping any existing name.
NAME is used only when the speaker is new or has no name yet."
  (muesli-db--execute
   "INSERT INTO speakers (meeting_id, label, name) VALUES (?, ?, ?)
    ON CONFLICT (meeting_id, label) DO UPDATE SET name = COALESCE(speakers.name, excluded.name)"
   (list meeting-id label name)))

(defun muesli-db-speaker-rename (meeting-id label name)
  "Set the display NAME of speaker LABEL in MEETING-ID (nil clears it)."
  (muesli-db--execute
   "UPDATE speakers SET name = ? WHERE meeting_id = ? AND label = ?"
   (list name meeting-id label)))

(defun muesli-db-speakers (meeting-id)
  "Return the speakers of MEETING-ID ordered by their first utterance."
  (muesli-db--select
   "SELECT sp.label, sp.name,
           (SELECT MIN(start_ms) FROM segments s
             WHERE s.meeting_id = sp.meeting_id AND s.speaker = sp.label) AS first_ms
      FROM speakers sp
     WHERE sp.meeting_id = ?
     ORDER BY first_ms IS NULL, first_ms, sp.label"
   (list meeting-id)))

(defun muesli-db-speakers-clear (meeting-id)
  "Remove speakers of MEETING-ID and reset segment labels."
  (muesli-db--execute "DELETE FROM speakers WHERE meeting_id = ?" (list meeting-id))
  (muesli-db--execute "UPDATE segments SET speaker = NULL WHERE meeting_id = ?"
                      (list meeting-id)))

(defun muesli-db-known-speaker-names ()
  "Return all distinct speaker names used in past meetings."
  (mapcar #'car (sqlite-select (muesli-db)
                               "SELECT DISTINCT name FROM speakers WHERE name IS NOT NULL ORDER BY name")))

(provide 'muesli-db)
;;; muesli-db.el ends here
