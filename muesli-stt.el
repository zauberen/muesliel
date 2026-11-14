;;; muesli-stt.el --- Speech-to-text queue for muesli  -*- lexical-binding: t; -*-

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

;; The `chunks' table is the transcription queue: pending -> uploading
;; -> done | failed.  Uploads go to an OpenAI-compatible
;; /audio/transcriptions endpoint through curl, at most
;; `muesli-stt-concurrency' at a time.  Failed uploads are retried with
;; exponential backoff up to `muesli-stt-max-attempts' times.

;;; Code:

(require 'muesli-core)
(require 'muesli-db)

(defcustom muesli-stt-base-url "http://localhost:8080/v1"
  "Base URL of the OpenAI-compatible speech-to-text server."
  :type 'string
  :group 'muesli)

(defcustom muesli-stt-model "parakeet-tdt-0.6b-v3"
  "Transcription model name sent to the server."
  :type 'string
  :group 'muesli)

(defcustom muesli-stt-api-key nil
  "API key for the speech-to-text server.
A string, nil, or a function returning a string (for `auth-source')."
  :type '(choice (const :tag "None" nil) string function)
  :group 'muesli)

(defcustom muesli-stt-language nil
  "Language code passed to the transcription server, or nil to auto-detect."
  :type '(choice (const :tag "Auto" nil) string)
  :group 'muesli)

(defcustom muesli-stt-concurrency 1
  "Maximum number of chunks uploaded at the same time."
  :type 'integer
  :group 'muesli)

(defcustom muesli-stt-max-attempts 4
  "Number of times a chunk upload is tried before it counts as failed."
  :type 'integer
  :group 'muesli)

(defcustom muesli-stt-retry-delay 5
  "Base delay in seconds before retrying; doubles with every attempt."
  :type 'number
  :group 'muesli)

(defcustom muesli-stt-timeout 600
  "Maximum seconds a single transcription request may take."
  :type 'integer
  :group 'muesli)

(defcustom muesli-stt-extra-fields
  '(("timestamp_granularities[]" . "segment")
    ("timestamp_granularities[]" . "word"))
  "Additional multipart form fields sent with each transcription request.
An alist of (NAME . VALUE) strings.  Servers ignore fields they do
not understand; remove these if yours rejects them."
  :type '(alist :key-type string :value-type string)
  :group 'muesli)

(defcustom muesli-stt-transcribe-function #'muesli-stt-transcribe-http
  "Function that transcribes one audio file.
Called with (FILE CALLBACK); CALLBACK receives (:ok RESPONSE) where
RESPONSE is the parsed JSON (an alist) or a plain string, or
\(:error MESSAGE).  Tests substitute a fake here."
  :type 'function
  :group 'muesli)

(defvar muesli-stt-chunk-done-functions nil
  "Abnormal hook run after a chunk finishes or fails.
Each function receives (MEETING-ID TRACK CHUNK-NO STATUS).")

(defvar muesli-stt--active 0
  "Number of uploads in flight.")

(defvar muesli-stt--not-before (make-hash-table :test #'equal)
  "Map from (MEETING-ID TRACK CHUNK-NO) to the earliest retry time.")

(defvar muesli-stt--retry-timer nil
  "Timer that re-runs the queue when a backoff expires.")

;;;; HTTP transport

(defun muesli-stt-transcribe-http (file callback)
  "Send FILE to `muesli-stt-base-url' and call CALLBACK with the result."
  (muesli--curl
   :name "stt"
   :url (concat (string-remove-suffix "/" muesli-stt-base-url) "/audio/transcriptions")
   :bearer (muesli--resolve-secret muesli-stt-api-key)
   :timeout muesli-stt-timeout
   :form-files (list (cons "file" file))
   :form-fields (append
                 (list (cons "model" muesli-stt-model)
                       (cons "response_format" "verbose_json"))
                 (when muesli-stt-language
                   (list (cons "language" muesli-stt-language)))
                 muesli-stt-extra-fields)
   :callback
   (lambda (result)
     (funcall callback
              (pcase result
                (`(:ok ,body)
                 (list :ok (condition-case nil
                               (muesli--json-parse body)
                             (error (string-trim body)))))
                (_ result))))))

;;;; Response parsing

(defun muesli-stt--words (list)
  "Turn a JSON word LIST into (START-MS END-MS WORD) triples."
  (delq nil
        (mapcar (lambda (w)
                  (let ((text (or (alist-get 'word w) (alist-get 'text w))))
                    (when (and text (alist-get 'start w))
                      (list (muesli--seconds-to-ms (alist-get 'start w))
                            (muesli--seconds-to-ms (or (alist-get 'end w)
                                                       (alist-get 'start w)))
                            (string-trim text)))))
                list)))

(defun muesli-stt-parse-response (response duration-ms)
  "Parse transcription RESPONSE into segments relative to the chunk.
RESPONSE is a parsed JSON alist or a plain string.  DURATION-MS is the
chunk length, used when the server returns no timestamps.  Returns a
list of plists (:start-ms :end-ms :text :words), dropping empty text."
  (let* ((alist (and (consp response) response))
         (segments (and alist (alist-get 'segments alist)))
         (words (and alist (muesli-stt--words (alist-get 'words alist))))
         (result
          (if segments
              (mapcar
               (lambda (s)
                 (let* ((start (muesli--seconds-to-ms (alist-get 'start s)))
                        (end (muesli--seconds-to-ms (alist-get 'end s)))
                        (own (muesli-stt--words (alist-get 'words s))))
                   (list :start-ms start
                         :end-ms (max end start)
                         :text (string-trim (or (alist-get 'text s) ""))
                         ;; Top-level words are distributed by time.
                         :words (or own
                                    (seq-filter
                                     (lambda (w)
                                       (let ((mid (/ (+ (car w) (nth 1 w)) 2)))
                                         (and (>= mid start) (< mid (max end (1+ start))))))
                                     words)))))
               segments)
            (let ((text (string-trim (cond ((stringp response) response)
                                           (alist (or (alist-get 'text alist) ""))
                                           (t "")))))
              (list (list :start-ms 0
                          :end-ms (or duration-ms 0)
                          :text text
                          :words words))))))
    (seq-remove (lambda (s) (string-empty-p (plist-get s :text))) result)))

;;;; Queue

(defun muesli-stt--next-pending ()
  "Return the oldest pending chunk whose backoff has expired, or nil."
  (let ((now (float-time)))
    (seq-find (lambda (c)
                (<= (gethash (list (plist-get c :meeting_id) (plist-get c :track)
                                   (plist-get c :chunk_no))
                             muesli-stt--not-before 0)
                    now))
              (muesli-db--select
               "SELECT c.* FROM chunks c JOIN meetings m ON m.id = c.meeting_id
                 WHERE c.status = 'pending'
                 ORDER BY m.started_at, c.chunk_no, c.track"))))

(defun muesli-stt-run-queue ()
  "Start uploads for pending chunks while there is spare concurrency."
  (let (chunk)
    (while (and (< muesli-stt--active (max 1 muesli-stt-concurrency))
                (setq chunk (muesli-stt--next-pending)))
      (muesli-stt--upload chunk)))
  (muesli-stt--schedule-retry))

(defun muesli-stt--schedule-retry ()
  "Arrange for the queue to run again when the earliest backoff ends."
  (let ((earliest nil))
    (maphash (lambda (_k v) (when (or (null earliest) (< v earliest)) (setq earliest v)))
             muesli-stt--not-before)
    (when (timerp muesli-stt--retry-timer)
      (cancel-timer muesli-stt--retry-timer))
    (setq muesli-stt--retry-timer
          (when earliest
            (run-at-time (max 0.1 (- earliest (float-time))) nil
                         #'muesli-stt-run-queue)))))

(defun muesli-stt--upload (chunk)
  "Upload CHUNK (a row plist) and record the outcome."
  (let* ((id (plist-get chunk :meeting_id))
         (track (plist-get chunk :track))
         (no (plist-get chunk :chunk_no))
         (path (plist-get chunk :path))
         (attempts (1+ (plist-get chunk :attempts))))
    (cl-incf muesli-stt--active)
    (remhash (list id track no) muesli-stt--not-before)
    (muesli-db-chunk-update id track no :status "uploading" :attempts attempts)
    (let ((done nil))
      (condition-case err
          (funcall muesli-stt-transcribe-function path
                   (lambda (result)
                     (unless done
                       (setq done t)
                       (cl-decf muesli-stt--active)
                       (condition-case err
                           (muesli-stt--handle-result chunk attempts result)
                         (error (muesli--log "STT result handling: %S" err)))
                       (muesli-stt-run-queue))))
        (error
         (setq done t)
         (cl-decf muesli-stt--active)
         (muesli-stt--handle-result chunk attempts
                                    (list :error (error-message-string err))))))))

(defun muesli-stt--handle-result (chunk attempts result)
  "Store RESULT for CHUNK after ATTEMPTS tries."
  (let* ((id (plist-get chunk :meeting_id))
         (track (plist-get chunk :track))
         (no (plist-get chunk :chunk_no))
         (meeting (muesli-db-meeting id)))
    (cond
     ;; Meeting aborted while the upload was in flight.
     ((null meeting) nil)
     ((eq (car result) :ok)
      (let* ((chunk-seconds (or (plist-get meeting :chunk_seconds) 30))
             (offset (or (plist-get chunk :offset_ms) (* no chunk-seconds 1000)))
             (duration (or (plist-get chunk :duration_ms) (* chunk-seconds 1000))))
        (muesli-db-segments-clear-chunk id track no)
        (dolist (s (muesli-stt-parse-response (cadr result) duration))
          (muesli-db-segment-add
           id track no
           (+ offset (plist-get s :start-ms))
           (+ offset (plist-get s :end-ms))
           (plist-get s :text)
           nil
           (mapcar (lambda (w) (list (+ offset (car w)) (+ offset (nth 1 w)) (nth 2 w)))
                   (plist-get s :words))))
        (muesli-db-chunk-update id track no :status "done")
        (run-hook-with-args 'muesli-stt-chunk-done-functions id track no "done")))
     ((< attempts muesli-stt-max-attempts)
      (let ((delay (* muesli-stt-retry-delay (expt 2 (1- attempts)))))
        (muesli--log "Chunk %s-%05d failed (%s), retrying in %ss"
                     track no (cadr result) delay)
        (puthash (list id track no) (+ (float-time) delay) muesli-stt--not-before)
        (muesli-db-chunk-update id track no :status "pending")))
     (t
      (muesli--message "Chunk %s-%05d failed after %d attempts: %s"
                       track no attempts (cadr result))
      (muesli-db-chunk-update id track no :status "failed")
      (run-hook-with-args 'muesli-stt-chunk-done-functions id track no "failed")))))

(defun muesli-stt-retry-failed (meeting-id)
  "Reset MEETING-ID's failed chunks to pending and restart the queue."
  (muesli-db--execute
   "UPDATE chunks SET status = 'pending', attempts = 0
     WHERE meeting_id = ? AND status = 'failed'"
   (list meeting-id))
  (muesli-stt-run-queue))

(defun muesli-stt-counts (meeting-id)
  "Return an alist of (STATUS . COUNT) for MEETING-ID's chunks."
  (mapcar (lambda (row) (cons (car row) (cadr row)))
          (sqlite-select (muesli-db)
                         "SELECT status, COUNT(*) FROM chunks WHERE meeting_id = ? GROUP BY status"
                         (list meeting-id))))

(defun muesli-stt-forget (meeting-id)
  "Drop in-memory retry state for MEETING-ID."
  (maphash (lambda (k _v) (when (equal (car k) meeting-id)
                            (remhash k muesli-stt--not-before)))
           muesli-stt--not-before))

(provide 'muesli-stt)
;;; muesli-stt.el ends here
