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

;; Links this Emacs to a muesli-relay server (see relay/,
;; docs/muesli-relay-spec.md and docs/muesli-relay-transcription-spec.md)
;; so meetings can be recorded on a phone.  The relay records,
;; transcribes and diarizes; this Emacs only names speakers, summarizes
;; with your notes and writes the org heading.  No ffmpeg, audio device
;; or speech server is needed here, which is what makes muesli work on
;; Windows.
;;
;;   1. Create an API key in the relay's web UI and store it in
;;      auth-source:  machine relay.example login muesli password msl_...
;;   2. Set `muesli-relay-url' (and `muesli-relay-profiles' for
;;      recordings started on the phone).
;;   3. M-x muesli-relay-link     register this Emacs and its profiles
;;   4. Either start a meeting here with `muesli-recording-source' set to
;;      `phone' (or C-u C-u M-x muesli-start) and tap Record on the
;;      phone, or record on the phone first and M-x muesli-relay-fetch.
;;
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
  :attendees    list of names; becomes the ATTENDEES property and
                tells the relay's diarization how many speakers to expect
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

(defcustom muesli-relay-live-interval 5
  "Seconds between polls of the relay during a phone meeting.
While recording this pulls the live transcript; afterwards it waits
for the relay to finish transcribing."
  :type 'integer
  :group 'muesli)

(defcustom muesli-relay-default-category "Phone recordings"
  "Category used for imported meetings whose profile sets none."
  :type 'string
  :group 'muesli)

(defcustom muesli-relay-default-title "Phone recording %F %R"
  "Title template for recordings without a title or a profile :title."
  :type 'string
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
      (description . ,desc)
      ,@(when-let* ((a (plist-get plist :attendees))) `((speakers . ,(length a)))))))

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
                       (muesli . "relay-2"))))
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

;;;; Segments from the relay

(defun muesli-relay--words (words)
  "Turn relay WORDS, a list of (START-MS END-MS WORD), into triples."
  (mapcar (lambda (w) (list (nth 0 w) (nth 1 w) (nth 2 w))) words))

(defun muesli-relay--store-segments (id segments)
  "Insert relay SEGMENTS (a list of alists) into meeting ID on track mic."
  (dolist (seg segments)
    (muesli-db-segment-add id "mic" (alist-get 'chunk_no seg)
                           (alist-get 'start_ms seg) (alist-get 'end_ms seg)
                           (alist-get 'text seg) (alist-get 'speaker seg)
                           (muesli-relay--words (alist-get 'words seg)))))

(defun muesli-relay--replace-segments (id segments)
  "Replace meeting ID's transcript and speakers with relay SEGMENTS."
  (muesli-db-with-transaction
    (muesli-db--execute "DELETE FROM segments WHERE meeting_id = ?" (list id))
    (muesli-db--execute "DELETE FROM speakers WHERE meeting_id = ?" (list id))
    (muesli-relay--store-segments id segments)
    (dolist (label (delete-dups (delq nil (mapcar (lambda (s) (alist-get 'speaker s))
                                                  segments))))
      (muesli-db-speaker-add id label))))

;;;; Watching meetings on the relay

(defvar muesli-relay--watched (make-hash-table :test #'equal)
  "Meeting id -> plist (:remote ID :after N :busy BOOL :await BOOL).
:after is the last relay segment id stored during the live phase;
:await is set once the pipeline waits for the final transcript.")

(defvar muesli-relay--live-timer nil
  "Timer polling watched meetings, or nil.")

(defun muesli-relay--uuid ()
  "Return a random lowercase UUID."
  (downcase (org-id-uuid)))

(defun muesli-relay--watch (id remote)
  "Start polling the relay for meeting ID, recording REMOTE."
  (unless (gethash id muesli-relay--watched)
    (puthash id (list :remote remote :after 0) muesli-relay--watched))
  (unless (timerp muesli-relay--live-timer)
    (setq muesli-relay--live-timer
          (run-at-time muesli-relay-live-interval muesli-relay-live-interval
                       #'muesli-relay--poll-live))))

(defun muesli-relay--unwatch (id)
  "Stop polling for meeting ID."
  (remhash id muesli-relay--watched)
  (when (and (zerop (hash-table-count muesli-relay--watched))
             (timerp muesli-relay--live-timer))
    (cancel-timer muesli-relay--live-timer)
    (setq muesli-relay--live-timer nil)))

(defun muesli-relay--watch-put (id key value)
  "Set KEY to VALUE in the watch state of meeting ID."
  (when-let* ((w (gethash id muesli-relay--watched)))
    (puthash id (plist-put w key value) muesli-relay--watched)))

(defun muesli-relay--poll-live ()
  "Timer function: poll every watched meeting that is not busy."
  (maphash (lambda (id w)
             (unless (plist-get w :busy)
               (condition-case err
                   (muesli-relay--poll-meeting id)
                 (error (muesli-relay--watch-put id :busy nil)
                        (muesli--log "relay poll of %s: %s" id (error-message-string err))))))
           muesli-relay--watched))

(defun muesli-relay--recording-p (id)
  "Return non-nil if meeting ID is the active (phone) recording."
  (and muesli--recording (equal (plist-get muesli--recording :id) id)))

(defun muesli-relay--poll-meeting (id)
  "Ask the relay about meeting ID and act on the answer."
  (let ((remote (plist-get (gethash id muesli-relay--watched) :remote)))
    (muesli-relay--watch-put id :busy t)
    (muesli-relay--request
     :method "GET" :path (format "/recordings/%s" remote)
     :callback
     (lambda (result)
       (condition-case err
           (pcase result
             (`(:ok ,st) (muesli-relay--handle-status id remote st))
             (`(:error ,msg)
              (muesli-relay--watch-put id :busy nil)
              (if (string-match-p "\\`HTTP 404" msg)
                  (muesli-relay--lost id)
                (muesli--log "relay status of %s: %s" id msg))))
         (error (muesli-relay--watch-put id :busy nil)
                (muesli--log "relay status of %s: %s" id (error-message-string err))))))))

(defun muesli-relay--lost (id)
  "The relay no longer knows meeting ID's recording."
  (muesli-relay--unwatch id)
  (when (muesli-relay--recording-p id)
    (muesli-relay--clear-recording))
  (unless (equal (plist-get (muesli-db-meeting id) :status) "done")
    (muesli--fail id "transcribing" "The relay no longer has this recording")))

(defun muesli-relay--clear-recording ()
  "Drop the active recording state without processing."
  (setq muesli--recording nil)
  (when (timerp muesli--mode-line-timer) (cancel-timer muesli--mode-line-timer))
  (force-mode-line-update t))

(defun muesli-relay--handle-status (id remote st)
  "Act on relay status ST (an alist) of meeting ID, recording REMOTE."
  (let ((status (alist-get 'status st)))
    (when (muesli-relay--recording-p id)
      (setq muesli--recording (plist-put muesli--recording :waiting (equal status "waiting")))
      (when (and (equal status "recording") (alist-get 'started_at st)
                 (not (plist-get muesli--recording :phone-started)))
        (setq muesli--recording
              (plist-put (plist-put muesli--recording :phone-started t)
                         :started (/ (alist-get 'started_at st) 1000.0)))
        (muesli-db-meeting-update id :started_at (truncate (alist-get 'started_at st) 1000))
        (muesli--message "The phone started recording \"%s\"" (plist-get muesli--recording :title))))
    (pcase status
      ((or "waiting" "recording" "processing")
       (when (and (member status '("processing")) (muesli-relay--recording-p id))
         (muesli-relay--phone-finished id))
       (muesli-relay--pull-live id remote st))
      ("transcribed"
       (when (muesli-relay--recording-p id) (muesli-relay--phone-finished id))
       (if (plist-get (gethash id muesli-relay--watched) :await)
           (muesli-relay--final-pull id remote st)
         (muesli-relay--pull-live id remote st)))
      ("failed"
       (when (muesli-relay--recording-p id) (muesli-relay--phone-finished id))
       (if (plist-get (gethash id muesli-relay--watched) :await)
           (muesli-relay--ask-failed id remote st)
         (muesli-relay--watch-put id :busy nil)))
      ("delivered"
       (muesli-relay--watch-put id :busy nil)
       (when (plist-get (gethash id muesli-relay--watched) :await)
         ;; Acked before a crash: the transcript is already here.
         (muesli-relay--unwatch id)
         (muesli--after-diarize id (muesli--meeting-attendees id))))
      ("abandoned"
       (muesli-relay--unwatch id)
       (when (muesli-relay--recording-p id)
         (muesli-relay--clear-recording)
         (ignore-errors (muesli--with-heading id (muesli--set-tag muesli-recording-tag nil))))
       (muesli--fail id "recording" "No phone recorded this meeting (the relay gave up waiting)"))
      (_ (muesli-relay--watch-put id :busy nil)))))

(defun muesli-relay--phone-finished (id)
  "The phone stopped recording meeting ID: run the normal stop path."
  (when (muesli-relay--recording-p id)
    (setq muesli--recording (plist-put muesli--recording :exited t))
    (if-let* ((k (plist-get muesli--recording :on-exit)))
        (funcall k)
      (muesli--stop-recording))))

(defun muesli-relay--pull-live (id remote st)
  "Store new segments of meeting ID (recording REMOTE, status ST)."
  (let ((after (or (plist-get (gethash id muesli-relay--watched) :after) 0)))
    (if (<= (or (alist-get 'segments st) 0) 0)
        (muesli-relay--watch-put id :busy nil)
      (muesli-relay--request
       :method "GET" :path (format "/recordings/%s/segments?after=%d" remote after)
       :callback
       (lambda (result)
         (muesli-relay--watch-put id :busy nil)
         (pcase result
           (`(:ok ,segs)
            (when (and segs (gethash id muesli-relay--watched))
              (muesli-relay--store-segments id segs)
              (muesli-relay--watch-put id :after
                                       (apply #'max after (mapcar (lambda (s) (alist-get 'id s)) segs)))
              (muesli--refresh-transcript id)))
           (`(:error ,msg) (muesli--log "relay segments of %s: %s" id msg))))))))

(defun muesli-relay--append-phone-notes (id notes)
  "Add NOTES typed on the phone to the end of meeting ID's heading body."
  (when (and notes (not (string-empty-p (string-trim notes))))
    (ignore-errors
      (muesli--with-heading id
        (let ((body (muesli-org-body)))
          (unless (string-search (string-trim notes) body)
            (muesli-org-replace-body
             (concat (string-trim-right body) (if (string-empty-p (string-trim body)) "" "\n\n")
                     "Notes from the phone:\n" (string-trim notes)))))))))

(defun muesli-relay--final-pull (id remote st)
  "Fetch the final transcript of meeting ID (REMOTE, status ST), ack, go on."
  (muesli-relay--request
   :method "GET" :path (format "/recordings/%s/segments" remote)
   :callback
   (lambda (result)
     (pcase result
       (`(:error ,msg)
        (muesli-relay--watch-put id :busy nil)
        (muesli--log "relay transcript of %s: %s" id msg))
       (`(:ok ,segs)
        (condition-case err
            (progn
              (muesli-relay--replace-segments id segs)
              (when-let* ((d (alist-get 'duration_ms st))
                          (m (muesli-db-meeting id)))
                (muesli-db-meeting-update id :ended_at (+ (truncate (plist-get m :started_at))
                                                          (truncate d 1000))))
              (muesli-relay--append-phone-notes id (alist-get 'notes st))
              (muesli-relay--unwatch id)
              (muesli--refresh-transcript id)
              (muesli-relay--ack remote id #'ignore)
              (muesli--message "Transcript of \"%s\" is in (%d segments)"
                               (plist-get (muesli-db-meeting id) :title) (length segs))
              (muesli--after-diarize id (muesli--meeting-attendees id)))
          (error (muesli--fail id "transcribing" (error-message-string err)))))))))

(defun muesli-relay--ask-failed (id remote st)
  "Ask what to do about meeting ID whose recording REMOTE failed (status ST)."
  (unless (plist-get (gethash id muesli-relay--watched) :asking)
    (muesli-relay--watch-put id :asking t)
    (let ((step (or (alist-get 'failed_step st) "transcribing"))
          (err (or (alist-get 'error st) "unknown error")))
      (muesli--when-idle
       (lambda ()
         (let ((choice (car (read-multiple-choice
                             (format "muesli: the relay failed while %s \"%s\": %s.  "
                                     step (plist-get (muesli-db-meeting id) :title) err)
                             '((?r "retry" "Try the failed step again")
                               (?p "proceed" "Continue without it")
                               (?l "later" "Stop here; `muesli-resume' continues later"))))))
           (muesli-relay--watch-put id :asking nil)
           (if (memq choice '(?r ?p))
               (muesli-relay--request
                :method "POST" :path (format "/recordings/%s/retry" remote)
                :json `((skip . ,(if (eq choice ?p) t :false)))
                :callback (lambda (r)
                            (muesli-relay--watch-put id :busy nil)
                            (when (eq (car r) :error)
                              (muesli--log "relay retry of %s: %s" id (cadr r)))))
             (muesli-relay--unwatch id)
             (muesli--fail id step (format "Relay: %s" err)))))))))

;;;; Starting, stopping and resuming phone meetings

(defun muesli-relay-check-linked ()
  "Signal a `user-error' unless this Emacs is linked to the relay."
  (muesli-relay--linked-state)
  (muesli-relay--api-key)
  t)

(defun muesli-relay-start-meeting (id info file)
  "Create meeting ID (heading INFO in FILE) to be recorded on a phone.
Registers a waiting recording on the relay and returns the state plist
for `muesli--recording'."
  (let* ((state (muesli-relay--linked-state))
         (remote (muesli-relay--uuid))
         (title (plist-get info :title))
         (attendees (plist-get info :attendees))
         (now (float-time)))
    (muesli-db-with-transaction
      (muesli-db-meeting-create
       id :file file :title title :category (plist-get info :category) :mode "room"
       :started_at (truncate now) :status "recording")
      (muesli-db-relay-import-add remote id (plist-get state :url) ""))
    (muesli-relay--create-remote id remote)
    (muesli-relay--watch id remote)
    (ignore attendees)
    (list :id id :title title :mode 'room :remote remote :started now :waiting t
          :stop (lambda (&optional how) (muesli-relay--stop-remote id remote how))
          :watch-stop #'ignore)))

(defun muesli-relay--create-remote (id remote)
  "Register the waiting relay recording REMOTE for meeting ID."
  (let* ((m (muesli-db-meeting id))
         (attendees (muesli--meeting-attendees id)))
    (muesli-relay--request
     :method "POST" :path "/recordings"
     :json `((id . ,remote) (title . ,(plist-get m :title))
             (speakers . ,(if attendees (length attendees) :null))
             (started_at . ,(* 1000 (plist-get m :started_at))))
     :callback (lambda (result)
                 (pcase result
                   (`(:error ,msg)
                    (display-warning
                     'muesli
                     (format "Could not register \"%s\" with the relay: %s.  muesli keeps retrying; \\[muesli-abort] cancels."
                             (plist-get m :title) msg)
                     :warning)))))))

(defun muesli-relay--stop-remote (id remote how)
  "Ask the relay to stop REMOTE (meeting ID); HOW `kill' discards it."
  (if (eq how 'kill)
      (progn
        (muesli-relay--unwatch id)
        (muesli-relay--request :method "DELETE" :path (format "/recordings/%s" remote)
                               :callback #'ignore))
    (muesli--message "Asking the phone to stop; waiting for its last upload…")
    (muesli-relay--request
     :method "POST" :path (format "/recordings/%s/stop" remote)
     :json '((reason . "emacs"))
     :callback (lambda (result)
                 (pcase result
                   (`(:ok ,st)
                    (when (equal (alist-get 'status st) "abandoned")
                      ;; No phone ever picked it up.
                      (muesli-relay--handle-status id remote st)))
                   (`(:error ,msg) (muesli--log "relay stop of %s: %s" id msg)))))
    (muesli-relay--poll-soon id)))

(defun muesli-relay--poll-soon (id)
  "Poll meeting ID right away instead of at the next tick."
  (run-at-time 0.5 nil (lambda ()
                         (when-let* ((w (gethash id muesli-relay--watched)))
                           (unless (plist-get w :busy) (muesli-relay--poll-meeting id))))))

(defun muesli-relay-await-transcript (id)
  "Pipeline step for phone meeting ID: wait for the relay's transcript."
  (let ((row (muesli-db-relay-import-for-meeting id)))
    (muesli-relay--watch id (plist-get row :remote_id))
    (muesli-relay--watch-put id :await t)
    (muesli-relay--poll-soon id)))

(defun muesli-relay-resume (id &optional skip)
  "Continue phone meeting ID after an interruption.
SKIP non-nil continues without a step that failed on the relay."
  (let* ((meeting (muesli-db-meeting id))
         (row (muesli-db-relay-import-for-meeting id))
         (remote (plist-get row :remote_id)))
    (muesli-relay--linked-state)
    (if (and (equal (plist-get meeting :status) "recording") (null muesli--recording))
        ;; Maybe still recording on the phone: become the recorder again.
        (progn
          (setq muesli--recording
                (list :id id :title (plist-get meeting :title) :mode 'room :remote remote
                      :started (float-time) :waiting t
                      :stop (lambda (&optional how) (muesli-relay--stop-remote id remote how))
                      :watch-stop #'ignore))
          (muesli--start-recording-ui id)
          (muesli-relay--watch id remote)
          (muesli-relay--poll-soon id)
          (muesli--message "Reattached to phone meeting \"%s\"" (plist-get meeting :title)))
      (let ((go (lambda ()
                  (muesli--message "Resuming \"%s\" at transcribing" (plist-get meeting :title))
                  (muesli--advance id "transcribing"))))
        (if (and skip (equal (plist-get meeting :status) "failed"))
            (muesli-relay--request
             :method "POST" :path (format "/recordings/%s/retry" remote) :json '((skip . t))
             :callback (lambda (_) (funcall go)))
          (funcall go))))))

;;;; Importing phone-started recordings

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

(defun muesli-relay--import (rec callback)
  "Import transcribed relay recording REC (an alist), then call CALLBACK.
CALLBACK receives a symbol: `imported', `acked' (seen before),
`rejected', `skipped' (an Emacs-started one) or `failed'."
  (let* ((remote-id (alist-get 'id rec))
         (profile-name (alist-get 'profile rec))
         (profile (muesli-relay--profile profile-name))
         (seen (muesli-db-relay-import remote-id)))
    (cond
     (seen
      ;; Ours already; the watcher of an unfinished meeting takes it from here.
      (if (member (plist-get (muesli-db-meeting (plist-get seen :meeting_id)) :status)
                  '("recording" "transcribing" "failed"))
          (funcall callback 'skipped)
        (muesli-relay--ack remote-id (plist-get seen :meeting_id)
                           (lambda () (funcall callback 'acked)))))
     ((equal (alist-get 'origin rec) "emacs")
      (funcall callback 'skipped))
     ((null profile)
      (muesli-relay--reject remote-id
                            (format "Emacs \"%s\" has no profile \"%s\" (run muesli-relay-link after changing profiles)"
                                    muesli-relay-client-name profile-name)
                            (lambda () (funcall callback 'rejected))))
     (t
      (let ((id (org-id-new)))
        (condition-case e
            (progn
              (muesli-relay--create-meeting id rec profile-name profile)
              (muesli-relay--start-pipeline id profile)
              (funcall callback 'imported))
          (error
           (muesli--message "Could not import phone recording %s: %s" remote-id
                            (error-message-string e))
           (funcall callback 'failed))))))))

(defun muesli-relay--create-meeting (id rec profile-name profile)
  "Create meeting ID for relay recording REC.
PROFILE-NAME and PROFILE (a plist) say how.  Writes the org heading,
the meeting row and the import row."
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
       :started_at (truncate started) :ended_at (truncate ended) :status "transcribing")
      (muesli-db-relay-import-add (alist-get 'id rec) id (plist-get muesli-relay--state :url)
                                  profile-name))))

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
  "Import recordings started on the phone that the relay has transcribed.
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
           :method "GET" :path "/recordings?status=transcribed"
           :callback
           (lambda (result)
             (pcase result
               (`(:error ,msg) (funcall done (format "fetch failed: %s" msg)))
               (`(:ok ,recs)
                (if (null (seq-remove (lambda (r) (equal (alist-get 'origin r) "emacs")) recs))
                    (funcall done "nothing waiting")
                  (let ((counts (list (cons 'imported 0) (cons 'acked 0)
                                      (cons 'rejected 0) (cons 'failed 0)
                                      (cons 'skipped 0))))
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
