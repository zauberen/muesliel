;;; muesli-relay.el --- Fetch phone recordings from a muesli relay  -*- lexical-binding: t; -*-

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

;; Links this Emacs to a muesli-relay server (see relay/ and
;; docs/muesli-relay-spec.md) so meetings recorded on a phone come back
;; here and run through the normal pipeline.
;;
;;   1. Create an API key in the relay's web UI and store it in
;;      auth-source:  machine relay.example login muesli password msl_...
;;   2. Set `muesli-relay-url' and `muesli-relay-profiles'.
;;   3. M-x muesli-relay-link     register this Emacs and its profiles
;;   4. Record on the phone, then M-x muesli-relay-fetch (or set
;;      `muesli-relay-poll-interval').
;;
;; Each fetched recording becomes a meeting heading under "* Meetings"
;; in `muesli-meetings-file', is cut into `muesli-chunk-seconds' WAV
;; chunks on the "mic" track (room mode) and enters the pipeline at
;; "transcribing", exactly like a local recording after `muesli-stop'.
;; Emacs only makes outbound requests, so the relay can live anywhere.

;;; Code:

(require 'auth-source)
(require 'url-parse)
(require 'muesli)

(defcustom muesli-relay-url nil
  "Base URL of the muesli-relay server, e.g. \"https://relay.example\"."
  :type '(choice (const :tag "Not set" nil) string)
  :group 'muesli)

(defcustom muesli-relay-api-key #'muesli-relay-auth-source-key
  "API key for the relay: a string, or a function returning one.
Resolved with `muesli--resolve-secret'.  The default looks up login
\"muesli\" for the relay's host in `auth-source'."
  :type '(choice string function)
  :group 'muesli)

(defcustom muesli-relay-client-name (system-name)
  "Name this Emacs shows up under in the phone app."
  :type 'string
  :group 'muesli)

(defcustom muesli-relay-profiles
  '((default :label "Meeting"))
  "Setups offered to the phone.  Each entry is (NAME . PLIST).
NAME is a symbol.  Recognized keys:

  :label        name shown on the phone
  :description  shown under the label; derived from :category if unset
  :category     level 2 heading under \"* Meetings\" (default
                \"Phone recordings\")
  :title        `format-time-string' template used when the phone sends
                no title, applied to the recording's start time
  :attendees    list of names; becomes the ATTENDEES property, which
                also tells diarization how many speakers to expect
  :file         org file to capture into instead of `muesli-meetings-file'
  :hook         function called with the new meeting id after import"
  :type '(alist :key-type symbol :value-type plist)
  :group 'muesli)

(defcustom muesli-relay-poll-interval nil
  "Seconds between automatic fetches, or nil to fetch only on command.
The timer starts when this Emacs is linked (or when muesli-relay is
loaded and already linked)."
  :type '(choice (const :tag "Only on command" nil) integer)
  :group 'muesli)

(defcustom muesli-relay-keep-original nil
  "When non-nil, keep the downloaded file next to the chunks."
  :type 'boolean
  :group 'muesli)

(defcustom muesli-relay-default-category "Phone recordings"
  "Category used for imported meetings whose profile sets none."
  :type 'string
  :group 'muesli)

(defcustom muesli-relay-default-title "Phone recording %F %R"
  "Title template for recordings without a title or a profile :title."
  :type 'string
  :group 'muesli)

(defcustom muesli-relay-download-timeout 3600
  "Maximum seconds for downloading one recording."
  :type 'integer
  :group 'muesli)

(defvar muesli-relay--state nil
  "Link state: plist with :url :client-id :user :linked-at, or nil.")

(defvar muesli-relay--fetching nil
  "Non-nil while a fetch is running.")

(defvar muesli-relay--timer nil
  "Poll timer, or nil.")

(defvar muesli-relay--last-result nil
  "Summary string of the last fetch.")

(defvar muesli-relay-request-function #'muesli-relay--curl-request
  "Function performing relay requests; replaced in tests.
Called like `muesli-relay--curl-request'.")

;;;; State

(defun muesli-relay--state-file ()
  "Return the file holding the link state."
  (expand-file-name "relay.eld" muesli-data-directory))

(defun muesli-relay--load-state ()
  "Load and return the link state from disk."
  (setq muesli-relay--state
        (let ((f (muesli-relay--state-file)))
          (when (file-readable-p f)
            (ignore-errors
              (with-temp-buffer
                (insert-file-contents f)
                (read (current-buffer))))))))

(defun muesli-relay--save-state (state)
  "Store STATE as the link state."
  (setq muesli-relay--state state)
  (let ((f (muesli-relay--state-file)))
    (make-directory (file-name-directory f) t)
    (with-temp-file f
      (insert ";; muesli-relay link state -*- lisp-data -*-\n")
      (prin1 state (current-buffer))
      (insert "\n"))))

(defun muesli-relay--base-url ()
  "Return `muesli-relay-url' without trailing slashes, or signal."
  (unless (and (stringp muesli-relay-url) (not (string-empty-p muesli-relay-url)))
    (user-error "Set `muesli-relay-url' to your relay's address first"))
  (string-trim-right muesli-relay-url "/+"))

(defun muesli-relay-auth-source-key ()
  "Return the relay API key stored in auth-source, or nil."
  (when-let* ((url muesli-relay-url)
              (host (url-host (url-generic-parse-url url))))
    (auth-source-pick-first-password :host host :user "muesli")))

(defun muesli-relay--api-key ()
  "Return the resolved API key or signal a `user-error'."
  (or (muesli--resolve-secret muesli-relay-api-key)
      (user-error "No relay API key: add \"machine %s login muesli password msl_...\" to your authinfo, or set `muesli-relay-api-key'"
                  (or (ignore-errors (url-host (url-generic-parse-url muesli-relay-url))) "HOST"))))

(defun muesli-relay--linked-state ()
  "Return the link state for the current URL or signal a `user-error'."
  (let ((state (or muesli-relay--state (muesli-relay--load-state)))
        (url (muesli-relay--base-url)))
    (unless (and state (equal (plist-get state :url) url))
      (user-error "This Emacs is not linked to %s; run `muesli-relay-link'" url))
    state))

;;;; HTTP

(cl-defun muesli-relay--curl-request (&key method path json output-file timeout callback)
  "Call the client API at PATH with METHOD through curl.
JSON is an object encoded as the body.  OUTPUT-FILE receives the
body instead.  TIMEOUT is in seconds.  CALLBACK receives (:ok VALUE)
where VALUE is the parsed JSON (nil for downloads) or (:error MSG)."
  (muesli--curl
   :name "relay"
   :method method
   :url (concat (muesli-relay--base-url) "/api/v1/client" path)
   :bearer (muesli-relay--api-key)
   :json-body (when json (muesli--json-encode json))
   :output-file output-file
   :timeout (or timeout 60)
   :callback
   (lambda (result)
     (funcall callback
              (pcase result
                (`(:ok ,body)
                 (if (or output-file (string-empty-p (string-trim body)))
                     (list :ok nil)
                   (condition-case nil
                       (list :ok (muesli--json-parse body))
                     (error (list :error (format "Unexpected reply from relay: %s"
                                                 (truncate-string-to-width body 200)))))))
                (_ result))))))

(defun muesli-relay--request (&rest args)
  "Make a relay request with keyword ARGS; see `muesli-relay--curl-request'."
  (apply muesli-relay-request-function args))

;;;; Profiles

(defun muesli-relay--profile-json (entry)
  "Return the JSON object describing profile ENTRY for the relay."
  (let* ((name (symbol-name (car entry)))
         (plist (cdr entry))
         (category (plist-get plist :category))
         (desc (or (plist-get plist :description)
                   (concat "room · " (or category muesli-relay-default-category)))))
    `((name . ,name)
      (label . ,(or (plist-get plist :label) name))
      (description . ,desc))))

(defun muesli-relay--profile (name)
  "Return the plist of profile NAME (a string), or nil if unknown."
  (when-let* ((entry (seq-find (lambda (e) (equal (symbol-name (car e)) name))
                               muesli-relay-profiles)))
    (or (cdr entry) (list :label name))))

;;;; Link

(defun muesli-relay--start-timer ()
  "Start or restart the poll timer according to `muesli-relay-poll-interval'."
  (when (timerp muesli-relay--timer) (cancel-timer muesli-relay--timer))
  (setq muesli-relay--timer
        (when (and (integerp muesli-relay-poll-interval) (> muesli-relay-poll-interval 0))
          (run-at-time muesli-relay-poll-interval muesli-relay-poll-interval
                       #'muesli-relay--poll))))

(defun muesli-relay--poll ()
  "Timer function: fetch quietly when linked and idle."
  (when (and muesli-relay--state (not muesli-relay--fetching))
    (condition-case err
        (muesli-relay-fetch t)
      (error (muesli--log "relay poll: %s" (error-message-string err))))))

;;;###autoload
(defun muesli-relay-link ()
  "Register this Emacs and `muesli-relay-profiles' with the relay.
Safe to run again after changing profiles: the link is updated."
  (interactive)
  (let ((url (muesli-relay--base-url)))
    (muesli-relay--api-key)
    (unless muesli-relay-profiles
      (user-error "`muesli-relay-profiles' is empty; define at least one profile"))
    (muesli-relay--request
     :method "POST" :path "/link"
     :json `((name . ,muesli-relay-client-name)
             (profiles . ,(vconcat (mapcar #'muesli-relay--profile-json muesli-relay-profiles)))
             (emacs . ((version . ,emacs-version)
                       (muesli . "relay-1"))))
     :callback
     (lambda (result)
       (pcase result
         (`(:ok ,reply)
          (muesli-relay--save-state
           (list :url url :client-id (alist-get 'client_id reply)
                 :user (alist-get 'user reply) :linked-at (truncate (float-time))))
          (muesli-relay--start-timer)
          (muesli--message "Linked \"%s\" to %s as %s (%d profile%s)"
                           muesli-relay-client-name (url-host (url-generic-parse-url url))
                           (alist-get 'user reply) (length muesli-relay-profiles)
                           (if (= 1 (length muesli-relay-profiles)) "" "s")))
         (`(:error ,msg)
          (muesli--message "Linking to %s failed: %s" url msg)))))))

;;;###autoload
(defun muesli-relay-unlink ()
  "Forget the relay link and stop polling.
Revoke the API key in the relay's web UI to cut access completely."
  (interactive)
  (when (timerp muesli-relay--timer) (cancel-timer muesli-relay--timer))
  (setq muesli-relay--timer nil
        muesli-relay--state nil)
  (ignore-errors (delete-file (muesli-relay--state-file)))
  (message "muesli: relay link forgotten"))

;;;###autoload
(defun muesli-relay-status ()
  "Show the relay link and how many recordings are waiting."
  (interactive)
  (let ((state (muesli-relay--linked-state)))
    (muesli-relay--request
     :method "GET" :path "/ping"
     :callback
     (lambda (result)
       (pcase result
         (`(:ok ,reply)
          (message "muesli: linked to %s as %s; %d recording%s waiting%s%s"
                   (plist-get state :url) (alist-get 'user reply)
                   (alist-get 'pending reply)
                   (if (= 1 (alist-get 'pending reply)) "" "s")
                   (if muesli-relay--timer
                       (format "; polling every %ds" muesli-relay-poll-interval)
                     "")
                   (if muesli-relay--last-result
                       (format "; last fetch: %s" muesli-relay--last-result)
                     "")))
         (`(:error ,msg)
          (message "muesli: relay %s unreachable: %s" (plist-get state :url) msg)))))))

;;;; Heading

(defun muesli-relay--insert-heading (file category title time body properties)
  "Append a meeting heading to FILE under \"* Meetings\" / CATEGORY.
TITLE and TIME (seconds) form the headline; BODY (string or nil) is
its text.  PROPERTIES is an alist of (NAME . VALUE) set on it; it
must include \"ID\".  The layout matches `muesli-capture'."
  (with-current-buffer (find-file-noselect file)
    (unless (derived-mode-p 'org-mode) (org-mode))
    (org-with-wide-buffer
     (goto-char (point-min))
     (unless (re-search-forward "^\\* +Meetings\\b" nil t)
       (goto-char (point-max))
       (unless (bolp) (insert "\n"))
       (insert "* Meetings\n")
       (forward-line -1))
     (org-back-to-heading t)
     (let ((meetings-end (save-excursion (org-end-of-subtree t t) (point-marker)))
           (cat-re (concat "^\\*\\* +" (regexp-quote category) "[ \t]*$")))
       (if (re-search-forward cat-re meetings-end t)
           (progn (org-back-to-heading t) (org-end-of-subtree t t))
         (goto-char meetings-end)
         (unless (bolp) (insert "\n"))
         (insert "** " category "\n"))
       (unless (bolp) (insert "\n"))
       (let ((start (point)))
         (insert "*** " (format-time-string (org-time-stamp-format nil t) time)
                 " " title "\n")
         (when (and body (not (string-empty-p (string-trim body))))
           (insert (string-trim-right body) "\n"))
         (goto-char start)
         (dolist (p properties)
           (org-entry-put nil (car p) (cdr p)))
         (muesli--set-tag muesli-recording-tag t))
       (set-marker meetings-end nil)))
    (save-buffer)
    (org-id-add-location (cdr (assoc "ID" properties)) (buffer-file-name))))

;;;; Import

(defun muesli-relay--file-sha256 (file)
  "Return the hex SHA-256 of FILE's bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun muesli-relay--extension (mime)
  "Return a file extension for MIME type."
  (pcase (car (split-string (downcase (or mime "")) ";"))
    ("audio/webm" "webm") ("audio/ogg" "ogg") ("audio/mp4" "m4a")
    ("audio/mpeg" "mp3") ("audio/wav" "wav") (_ "bin")))

(defun muesli-relay-segment-command (source directory chunk-seconds)
  "Return the ffmpeg command cutting SOURCE into DIRECTORY/mic-NNNNN.wav.
Chunks are CHUNK-SECONDS long, 16 kHz mono 16-bit, the same format
`muesli-record-ffmpeg' writes."
  (list muesli-ffmpeg-command "-hide_banner" "-nostats" "-loglevel" "error" "-y"
        "-i" source "-map" "0:a:0"
        "-ac" "1" "-ar" "16000" "-c:a" "pcm_s16le"
        "-f" "segment" "-segment_time" (number-to-string chunk-seconds)
        "-segment_format" "wav" "-reset_timestamps" "1"
        (expand-file-name "mic-%05d.wav" directory)))

(defun muesli-relay--segment (source directory chunk-seconds callback)
  "Cut SOURCE into chunks in DIRECTORY, then call CALLBACK.
CALLBACK receives nil on success or an error message.  CHUNK-SECONDS
is the chunk length."
  (muesli--require-executable muesli-ffmpeg-command "splitting phone recordings")
  (muesli--run
   :name "relay-segment"
   :command (muesli-relay-segment-command source directory chunk-seconds)
   :callback (lambda (code _out err)
               (funcall callback
                        (unless (and (= code 0) (muesli-record-chunk-files directory))
                          (format "ffmpeg could not split the recording: %s"
                                  (if (string-empty-p (string-trim err))
                                      "no audio found" (string-trim err))))))))

(defun muesli-relay--ack (remote-id meeting-id callback)
  "Confirm REMOTE-ID as imported into MEETING-ID, then call CALLBACK."
  (muesli-relay--request
   :method "POST" :path (format "/recordings/%s/ack" remote-id)
   :json `((meeting_id . ,meeting-id))
   :callback (lambda (result)
               (if (eq (car result) :ok)
                   (muesli-db-relay-import-mark-acked remote-id)
                 (muesli--log "relay ack of %s failed: %s" remote-id (cadr result)))
               (funcall callback))))

(defun muesli-relay--reject (remote-id reason callback)
  "Tell the relay REMOTE-ID cannot be imported for REASON, then CALLBACK."
  (muesli-relay--request
   :method "POST" :path (format "/recordings/%s/reject" remote-id)
   :json `((reason . ,reason))
   :callback (lambda (_) (funcall callback))))

(defun muesli-relay--download (rec file callback &optional retried)
  "Download recording REC to FILE and verify it, then call CALLBACK.
CALLBACK receives nil on success or an error message.  RETRIED is
non-nil on the second attempt after a checksum mismatch."
  (let ((id (alist-get 'id rec)))
    (muesli-relay--request
     :method "GET" :path (format "/recordings/%s/audio" id)
     :output-file file :timeout muesli-relay-download-timeout
     :callback
     (lambda (result)
       (pcase result
         (`(:error ,msg) (funcall callback (format "download failed: %s" msg)))
         (_
          (let ((size (file-attribute-size (file-attributes file)))
                (want-size (alist-get 'bytes rec))
                (want-sha (alist-get 'sha256 rec)))
            (cond
             ((and (or (not want-size) (eql size want-size))
                   (or (not want-sha) (equal (muesli-relay--file-sha256 file) want-sha)))
              (funcall callback nil))
             (retried
              (ignore-errors (delete-file file))
              (funcall callback "downloaded file does not match its checksum"))
             (t
              (ignore-errors (delete-file file))
              (muesli-relay--download rec file callback t))))))))))

(defun muesli-relay--import (rec callback)
  "Import relay recording REC (an alist), then call CALLBACK.
CALLBACK receives a symbol: `imported', `acked' (seen before),
`rejected' or `failed'."
  (let* ((remote-id (alist-get 'id rec))
         (profile-name (alist-get 'profile rec))
         (profile (muesli-relay--profile profile-name))
         (seen (muesli-db-relay-import remote-id)))
    (cond
     (seen
      (muesli-relay--ack remote-id (plist-get seen :meeting_id)
                         (lambda () (funcall callback 'acked))))
     ((null profile)
      (muesli-relay--reject remote-id
                            (format "Emacs \"%s\" has no profile \"%s\" (run muesli-relay-link after changing profiles)"
                                    muesli-relay-client-name profile-name)
                            (lambda () (funcall callback 'rejected))))
     (t
      (let* ((id (org-id-new))
             (dir (expand-file-name (muesli--file-safe id) muesli-audio-directory))
             (source (expand-file-name
                      (concat "relay-source." (muesli-relay--extension (alist-get 'mime_type rec)))
                      dir))
             (fail (lambda (msg)
                     (muesli--message "Could not import phone recording %s: %s" remote-id msg)
                     (ignore-errors (delete-directory dir t))
                     (funcall callback 'failed))))
        (make-directory dir t)
        (muesli-relay--download
         rec source
         (lambda (err)
           (if err
               (funcall fail err)
             (muesli-relay--segment
              source dir muesli-chunk-seconds
              (lambda (err)
                (if err
                    (funcall fail err)
                  (unless muesli-relay-keep-original
                    (ignore-errors (delete-file source)))
                  (let ((err (condition-case e
                                 (progn (muesli-relay--create-meeting id dir rec profile-name profile)
                                        nil)
                               (error (error-message-string e)))))
                    (if (and err (not (muesli-db-relay-import remote-id)))
                        (funcall fail err)
                      ;; Once the import row exists the meeting is ours: a
                      ;; later problem is for `muesli-resume', not a re-import.
                      (when err (muesli--log "relay import of %s: %s" remote-id err))
                      (muesli-relay--ack
                       remote-id id
                       (lambda ()
                         (muesli-relay--start-pipeline id profile)
                         (funcall callback 'imported))))))))))))))))

(defun muesli-relay--create-meeting (id dir rec profile-name profile)
  "Create meeting ID for REC with audio in DIR.
PROFILE-NAME and PROFILE (a plist) say how.  Writes the org heading,
the meeting row, the import row and the chunks."
  (let* ((started (/ (or (alist-get 'started_at rec) (* 1000 (float-time))) 1000.0))
         (ended (if-let* ((e (alist-get 'ended_at rec))) (/ e 1000.0)
                  (+ started (/ (or (alist-get 'duration_ms rec) 0) 1000.0))))
         (title (or (let ((tt (alist-get 'title rec)))
                      (and tt (not (string-empty-p (string-trim tt))) (string-trim tt)))
                    (format-time-string (or (plist-get profile :title) muesli-relay-default-title)
                                        started)))
         (category (or (plist-get profile :category) muesli-relay-default-category))
         (file (expand-file-name (or (plist-get profile :file) muesli-meetings-file)))
         (attendees (plist-get profile :attendees)))
    (muesli-relay--insert-heading
     file category title started (alist-get 'notes rec)
     (append `(("ID" . ,id) ("MUESLI_MODE" . "room"))
             (when attendees `(("ATTENDEES" . ,(string-join attendees ", "))))))
    (muesli-db-with-transaction
      (muesli-db-meeting-create
       id :file file :title title :category category :mode "room"
       :started_at (truncate started) :ended_at (truncate ended)
       :status "recording" :audio_dir dir :chunk_seconds muesli-chunk-seconds)
      (muesli-db-relay-import-add (alist-get 'id rec) id (plist-get muesli-relay--state :url)
                                  profile-name))
    (muesli--register-chunks-from-disk id)))

(defun muesli-relay--start-pipeline (id profile)
  "Move imported meeting ID into the pipeline and run PROFILE's hook."
  (muesli--mode-line-setup)
  (muesli--advance id "transcribing")
  (when-let* ((hook (plist-get profile :hook)))
    (condition-case err
        (funcall hook id)
      (error (muesli--log "relay profile hook failed: %S" err)))))

;;;###autoload
(defun muesli-relay-fetch (&optional quiet)
  "Fetch recordings waiting on the relay and import them.
With QUIET (used by the poll timer), say nothing when there is
nothing to fetch."
  (interactive)
  (muesli-relay--linked-state)
  (if muesli-relay--fetching
      (unless quiet (message "muesli: a relay fetch is already running"))
    (setq muesli-relay--fetching t)
    (let ((done (lambda (summary)
                  (setq muesli-relay--fetching nil
                        muesli-relay--last-result summary)
                  (when (or (not quiet) (not (equal summary "nothing waiting")))
                    (muesli--message "Relay: %s" summary)))))
      (condition-case err
          (muesli-relay--request
           :method "GET" :path "/recordings?status=ready"
           :callback
           (lambda (result)
             (pcase result
               (`(:error ,msg) (funcall done (format "fetch failed: %s" msg)))
               (`(:ok ,recs)
                (if (null recs)
                    (funcall done "nothing waiting")
                  (let ((counts (list (cons 'imported 0) (cons 'acked 0)
                                      (cons 'rejected 0) (cons 'failed 0))))
                    (cl-labels
                        ((next (rest)
                           (if (null rest)
                               (funcall done (muesli-relay--summary counts))
                             (condition-case e
                                 (muesli-relay--import
                                  (car rest)
                                  (lambda (outcome)
                                    (cl-incf (alist-get outcome counts))
                                    (next (cdr rest))))
                               (error
                                (muesli--log "relay import: %s" (error-message-string e))
                                (cl-incf (alist-get 'failed counts))
                                (next (cdr rest)))))))
                      (next recs))))))))
        (error (setq muesli-relay--fetching nil)
               (signal (car err) (cdr err)))))))

(defun muesli-relay--summary (counts)
  "Describe fetch COUNTS, an alist of outcome to number."
  (let ((parts (delq nil
                     (list (let ((n (alist-get 'imported counts)))
                             (when (> n 0) (format "imported %d recording%s" n (if (= n 1) "" "s"))))
                           (let ((n (alist-get 'acked counts)))
                             (when (> n 0) (format "%d already imported" n)))
                           (let ((n (alist-get 'rejected counts)))
                             (when (> n 0) (format "%d rejected (unknown profile)" n)))
                           (let ((n (alist-get 'failed counts)))
                             (when (> n 0) (format "%d failed (see *muesli-log*)" n)))))))
    (if parts (string-join parts "; ") "nothing to do")))

;; Pick up an existing link (and its poll timer) when loaded.
(when (and (muesli-relay--load-state) muesli-relay-poll-interval)
  (muesli-relay--start-timer))

(provide 'muesli-relay)
;;; muesli-relay.el ends here
