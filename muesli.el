;;; muesli.el --- Local meeting notes: record, transcribe, summarize into org  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: zauberen
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Keywords: outlines, multimedia, convenience
;; URL: https://github.com/zauberen/muesliel

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

;; muesli records a meeting while you type rough notes under an org
;; heading, transcribes the audio through a local OpenAI-compatible
;; speech-to-text server, optionally separates speakers, and finally
;; replaces the heading body with LLM-enhanced notes.  Your original
;; notes are kept and can be restored with `muesli-restore-notes'.
;;
;; Typical flow:
;;
;;   M-x muesli-capture     create the meeting heading
;;   M-x muesli-start       start recording (point in the heading)
;;   ... type notes ...
;;   M-x muesli-stop        transcribe, diarize, summarize, replace body
;;
;; After stop, a meeting goes through recording -> transcribing ->
;; diarizing -> summarizing -> done (or failed).  The state is stored in
;; SQLite so `muesli-resume' can retry a failed step without redoing
;; the earlier ones.  See README.org for setup.

;;; Code:

(require 'org)
(require 'org-id)
(require 'muesli-core)
(require 'muesli-db)
(require 'muesli-capture)
(require 'muesli-record)
(require 'muesli-stt)
(require 'muesli-diarize)
(require 'muesli-summary)

(defcustom muesli-default-mode 'room
  "Capture mode used by `muesli-start' without a prefix argument.
`room'   one microphone, everyone in the room (multi-speaker).
`call'   microphone (you) plus system audio (everyone else).
`hybrid' microphone and system audio, both multi-speaker.
A MUESLI_MODE property on the heading overrides this."
  :type '(choice (const room) (const call) (const hybrid))
  :group 'muesli)

(defcustom muesli-recording-source
  (if (eq system-type 'windows-nt) 'phone 'local)
  "Where `muesli-start' records.
`local' records on this machine with ffmpeg (`muesli-recorder-command').
`phone' records on a phone through the muesli relay, which also
transcribes; this Emacs then only needs curl and an LLM (see
`muesli-relay-url').  The default is `phone' on Windows.  With two
prefix arguments, `muesli-start' uses the other source once."
  :type '(choice (const :tag "This machine (ffmpeg)" local)
                 (const :tag "A phone through the relay" phone))
  :group 'muesli)

(defcustom muesli-mode-line-recording-format "• REC %s"
  "Mode line text while recording; %s is replaced by the elapsed time.
The default uses U+2022 BULLET, which most fonts center at text
height; U+25CF BLACK CIRCLE sits on the baseline in many fonts."
  :type 'string
  :group 'muesli)

(defcustom muesli-recording-tag "recording"
  "Tag added to a meeting heading while it is being recorded."
  :type 'string
  :group 'muesli)

(defcustom muesli-done-tag nil
  "Tag added to a meeting heading once its notes were generated, or nil."
  :type '(choice (const :tag "None" nil) string)
  :group 'muesli)

(defcustom muesli-append-transcript nil
  "When non-nil, append the transcript in a :TRANSCRIPT: drawer."
  :type 'boolean
  :group 'muesli)

(defcustom muesli-max-reruns 3
  "How often summarization reruns because the notes changed meanwhile."
  :type 'integer
  :group 'muesli)

(defcustom muesli-check-orphans-on-load t
  "When non-nil, offer to resume interrupted meetings when muesli loads."
  :type 'boolean
  :group 'muesli)

(defvar muesli--recording nil
  "Plist describing the active recording, or nil.
Keys: :id :title :mode :stop :watch-stop :started :dir :exited
:stopping :on-exit.  Phone meetings (see `muesli-relay-start-meeting')
also have :remote (the relay recording id) and :waiting (no phone has
started yet).")

(defvar muesli--pipelines (make-hash-table :test #'equal)
  "Map from meeting ID to the pipeline step currently running in this Emacs.")

(defvar muesli--mode-line-timer nil
  "Timer refreshing the mode line while recording.")

(defconst muesli--steps '("transcribing" "diarizing" "summarizing" "done")
  "Pipeline steps after recording, in order.")

;;;; Mode line

(defun muesli--mode-line-string ()
  "Return the mode line text for muesli's state."
  (let ((parts '()))
    (when muesli--recording
      (push (propertize
             (format muesli-mode-line-recording-format
                     (if (plist-get muesli--recording :waiting)
                         "waiting for phone"
                       (muesli--format-clock
                        (* 1000 (max 0 (- (float-time) (plist-get muesli--recording :started)))))))
             'face 'error
             'help-echo (format "muesli: recording %s"
                                (plist-get muesli--recording :title)))
            parts))
    (maphash (lambda (_id step) (push (format "muesli:%s" step) parts)) muesli--pipelines)
    (when parts (concat " " (string-join (nreverse parts) " ") " "))))

(defvar muesli-mode-line '(:eval (muesli--mode-line-string))
  "Mode line construct showing muesli's state.")
(put 'muesli-mode-line 'risky-local-variable t)

(defun muesli--mode-line-setup ()
  "Make sure `muesli-mode-line' is in `global-mode-string'."
  (unless (memq 'muesli-mode-line global-mode-string)
    (setq global-mode-string (append (or global-mode-string '("")) '(muesli-mode-line)))))

(defun muesli--set-step (id step)
  "Record that meeting ID is at pipeline STEP, or finished if STEP is nil."
  (if step (puthash id step muesli--pipelines) (remhash id muesli--pipelines))
  (when step (muesli-db-meeting-update id :status step))
  (force-mode-line-update t))

;;;; Headings

(defun muesli--heading-marker (id)
  "Return a marker at the heading with ID, or nil if it cannot be found.
Never guesses: the heading must carry ID."
  (or (ignore-errors (org-id-find id 'marker))
      (when-let* ((meeting (muesli-db-meeting id))
                  (file (plist-get meeting :file))
                  ((file-exists-p file))
                  (where (ignore-errors (org-id-find-id-in-file id file 'marker))))
        where)))

(defmacro muesli--with-heading (id &rest body)
  "Run BODY with point at the heading with ID.
Signal a `user-error' when the heading cannot be found."
  (declare (indent 1) (debug t))
  (let ((m (make-symbol "marker")))
    `(let ((,m (muesli--heading-marker ,id)))
       (unless ,m
         (user-error "Cannot find the meeting heading with ID %s" ,id))
       (with-current-buffer (marker-buffer ,m)
         (org-with-wide-buffer
          (goto-char ,m)
          (org-back-to-heading t)
          ,@body)))))

(defun muesli--strip-timestamp (heading)
  "Return HEADING without a leading org timestamp."
  (string-trim
   (replace-regexp-in-string
    (concat "\\`[ \t]*\\(?:" org-ts-regexp-both "\\)[ \t]*") "" heading)))

(defun muesli--heading-info ()
  "Return a plist describing the meeting heading at point."
  (save-excursion
    (org-back-to-heading t)
    (let* ((raw (org-get-heading t t t t))
           (level (org-current-level))
           (attendees (when-let* ((a (org-entry-get nil "ATTENDEES")))
                        (seq-remove #'string-empty-p
                                    (mapcar #'string-trim (split-string a "," t)))))
           (date (when (string-match org-ts-regexp-both raw)
                   (match-string 0 raw)))
           (category (save-excursion
                       (when (org-up-heading-safe)
                         (muesli--strip-timestamp (org-get-heading t t t t))))))
      (list :title (muesli--strip-timestamp raw)
            :category category
            :date date
            :level level
            :attendees attendees
            :mode (when-let* ((m (org-entry-get nil "MUESLI_MODE")))
                    (intern (string-trim m)))))))

(defun muesli--set-tag (tag on)
  "Add TAG to the heading at point when ON, remove it otherwise."
  (when (and tag (not (string-empty-p tag)))
    (org-toggle-tag tag (if on 'on 'off))))

(defun muesli--meeting-id-at-point ()
  "Return the ID of the muesli meeting containing point, or nil."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (unless (org-before-first-heading-p)
        (org-back-to-heading t)
        (let ((found nil))
          (while (and (not found)
                      (progn
                        (let ((id (org-entry-get nil "ID")))
                          (when (and id (muesli-db-meeting id)) (setq found id)))
                        (and (not found) (org-up-heading-safe)))))
          found)))))

(defun muesli--read-meeting (prompt &optional statuses)
  "Read a meeting ID with PROMPT, offering meetings in STATUSES."
  (let* ((meetings (muesli-db-meetings statuses))
         (table (mapcar (lambda (m)
                          (cons (format "%s  %s  [%s]"
                                        (format-time-string "%F %R" (plist-get m :started_at))
                                        (or (plist-get m :title) (plist-get m :id))
                                        (plist-get m :status))
                                (plist-get m :id)))
                        meetings)))
    (unless table (user-error "No matching meetings"))
    (cdr (assoc (completing-read prompt table nil t) table))))

(defun muesli--meeting-id (prompt &optional statuses)
  "Return the meeting at point, the recording one, or read one with PROMPT.
STATUSES limits the candidates offered when reading."
  (or (muesli--meeting-id-at-point)
      (plist-get muesli--recording :id)
      (muesli--read-meeting prompt statuses)))

(defun muesli--when-idle (fn)
  "Call FN once the user pauses typing, to avoid hijacking keystrokes."
  (let ((idle (current-idle-time)))
    (if (and idle (> (float-time idle) 0.5))
        (run-at-time 0 nil fn)
      (run-with-idle-timer 0.5 nil fn))))

;;;; Start

(defun muesli--read-mode ()
  "Prompt for a capture mode."
  (intern (completing-read "Capture mode: " '("room" "call" "hybrid") nil t nil nil
                           (symbol-name muesli-default-mode))))

;;;###autoload
(declare-function muesli-relay-start-meeting "muesli-relay" (id info file))
(declare-function muesli-relay-check-linked "muesli-relay" ())
(declare-function muesli-relay-await-transcript "muesli-relay" (id))
(declare-function muesli-relay-resume "muesli-relay" (id &optional skip))

(defun muesli--relay-meeting-p (id)
  "Return non-nil if meeting ID is recorded and transcribed by the relay."
  (and id (muesli-db-relay-import-for-meeting id) t))

(defun muesli--recording-source (arg)
  "Return the recording source for `muesli-start' prefix ARG."
  (if (equal arg '(16))
      (if (eq muesli-recording-source 'phone) 'local 'phone)
    muesli-recording-source))

;;;###autoload
(defun muesli-start (&optional arg)
  "Start recording the meeting whose heading contains point.
With one prefix ARG (\[universal-argument]), prompt for the capture mode.
With two (\[universal-argument] \[universal-argument]), use the other
`muesli-recording-source' for this meeting.  Works from an org buffer
or an active capture buffer."
  (interactive "P")
  (when muesli--recording
    (user-error "Already recording \"%s\"; stop it with `muesli-stop' first"
                (plist-get muesli--recording :title)))
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org buffer"))
  (when (org-before-first-heading-p)
    (user-error "Point is not in a meeting heading"))
  (let ((source (muesli--recording-source arg)))
    (if (eq source 'phone)
        (progn (require 'muesli-relay) (muesli-relay-check-linked))
      (muesli--require-executable muesli-ffmpeg-command "recording audio"))
    (muesli--start source (equal arg '(4)))))

(defun muesli--start (source ask-mode)
  "Start recording the meeting at point from SOURCE (`local' or `phone').
ASK-MODE non-nil prompts for the capture mode (local recordings only)."
  (save-excursion
    (org-back-to-heading t)
    (let* ((id (org-id-get-create))
           (info (muesli--heading-info))
           (mode (cond ((eq source 'phone) 'room)
                       (ask-mode (muesli--read-mode))
                       ((memq (plist-get info :mode) '(room call hybrid)) (plist-get info :mode))
                       (t muesli-default-mode)))
           (existing (muesli-db-meeting id)))
      (when existing
        (when (gethash id muesli--pipelines)
          (user-error "This meeting is still being processed (%s)" (gethash id muesli--pipelines)))
        (unless (yes-or-no-p (format "This meeting already has a %s recording.  Discard it and record again? "
                                     (plist-get existing :status)))
          (user-error "Aborted"))
        (muesli--delete-data id))
      (if (eq source 'phone)
          (muesli--start-phone id info)
        (muesli--start-local id info mode)))))

(defun muesli--start-recording-ui (&optional id)
  "Show that a meeting is being recorded.
The tag goes on the heading at point, or on meeting ID's heading."
  (if id
      (ignore-errors (muesli--with-heading id (muesli--set-tag muesli-recording-tag t)))
    (muesli--set-tag muesli-recording-tag t))
  (muesli--mode-line-setup)
  ;; Refresh every window's mode line, not just the current buffer's.
  (setq muesli--mode-line-timer
        (run-at-time 1 1 (lambda () (force-mode-line-update t)))))

(defun muesli--start-phone (id info)
  "Start meeting ID (heading INFO) recorded on a phone through the relay."
  (setq muesli--recording
        (muesli-relay-start-meeting id info (buffer-file-name (buffer-base-buffer))))
  (muesli--start-recording-ui)
  (muesli--message "\"%s\" is waiting for the phone: open the muesli relay app and tap Record"
                   (plist-get info :title)))

(defun muesli--start-local (id info mode)
  "Start recording meeting ID (heading INFO) on this machine in MODE."
  (when (and (memq mode '(room hybrid)) (eq muesli-diarization-backend 'none))
    (display-warning 'muesli
                     (format "Recording in %s mode without a diarization backend: the transcript will have no speaker labels.  Set `muesli-diarization-backend' to fix this."
                             mode)
                     :warning))
  (let* ((tracks (muesli-record-resolve-devices mode))
         (dir (expand-file-name (muesli--file-safe id) muesli-audio-directory)))
    (make-directory dir t)
    (dolist (f (muesli-record-chunk-files dir)) (delete-file (nth 2 f)))
    (muesli-db-meeting-create
     id :file (buffer-file-name (buffer-base-buffer)) :title (plist-get info :title)
     :category (plist-get info :category) :mode (symbol-name mode)
     :started_at (truncate (float-time)) :status "recording"
     :audio_dir dir :chunk_seconds muesli-chunk-seconds)
    (let* ((state (list :id id :title (plist-get info :title) :mode mode
                        :started (float-time) :dir dir :tracks tracks))
           (stop (funcall muesli-recorder-function
                          :directory dir :tracks tracks
                          :chunk-seconds muesli-chunk-seconds
                          :on-exit (lambda (event) (muesli--recorder-exited id event)))))
      (setq state (plist-put state :stop stop))
      (setq muesli--recording state)
      (setq muesli--recording
            (plist-put muesli--recording :watch-stop
                       (muesli-record-watch
                        :directory dir
                        :finished-p (lambda () (and muesli--recording
                                                    (plist-get muesli--recording :exited)))
                        :on-chunk (lambda (track no path)
                                    (muesli--on-chunk id track no path))))))
    (muesli--start-recording-ui)
    (muesli--message "Recording \"%s\" (%s mode: %s)" (plist-get info :title) mode
                     (mapconcat (lambda (tr) (format "%s=%s" (car tr)
                                                     (muesli-record-describe-device (cdr tr))))
                                tracks ", "))
    (dolist (tr tracks)
      (when (muesli-record-source-muted-p (cdr tr))
        (display-warning
         'muesli
         (format "The %s input %s is MUTED; the recording will be silent.  Unmute it, or pick another source with `muesli-select-device'."
                 (car tr) (muesli-record-describe-device (cdr tr)))
         :error)))))

(defun muesli--check-chunk-level (id track path)
  "Warn if the first chunk of TRACK at PATH in meeting ID is silent."
  (muesli-record-peak-db
   path
   (lambda (db)
     (when (and db (< db muesli-silence-threshold-db)
                (equal (plist-get muesli--recording :id) id))
       (display-warning
        'muesli
        (format "The first %ds of the %s track are silent (peak %s dB).  Check that the input is not muted and is the microphone you are using (`muesli-select-device')."
                (/ (or (muesli-record-wav-duration-ms path) 0) 1000) track
                (if (<= db -1000) "-inf" (number-to-string db)))
        :warning)))))

(defun muesli--on-chunk (id track no path)
  "Register finished chunk NO of TRACK at PATH for meeting ID and queue it."
  (when (muesli-db-meeting id)
    (let* ((meeting (muesli-db-meeting id))
           (chunk-seconds (or (plist-get meeting :chunk_seconds) muesli-chunk-seconds))
           (prev (and (> no 0) (muesli-db-chunk id track (1- no))))
           (prev-end (and prev (plist-get prev :offset_ms) (plist-get prev :duration_ms)
                          (+ (plist-get prev :offset_ms) (plist-get prev :duration_ms))))
           (offset (muesli-record-chunk-offset-ms no chunk-seconds prev-end))
           (duration (muesli-record-wav-duration-ms path)))
      (if (and duration (< duration 200))
          (muesli--log "Skipping near-empty chunk %s" path)
        (when (muesli-db-chunk-add id track no path offset duration)
          (when (= no 0)
            (ignore-errors (muesli--check-chunk-level id track path)))
          (muesli-stt-run-queue))))))

(defun muesli--recorder-exited (id event)
  "Handle the recorder of meeting ID exiting with EVENT."
  (when (and muesli--recording (equal (plist-get muesli--recording :id) id))
    (setq muesli--recording (plist-put muesli--recording :exited t))
    (if-let* ((k (plist-get muesli--recording :on-exit)))
        (funcall k)
      (display-warning 'muesli
                       (format "The recorder stopped unexpectedly (%s).  Run `muesli-stop' to process what was recorded."
                               event)
                       :error))))

;;;; Stop

;;;###autoload
(defun muesli-stop ()
  "Stop recording and turn the meeting into notes.
Works from anywhere: the heading is located by its ID."
  (interactive)
  (cond
   ((null muesli--recording)
    (if (muesli-db-meetings '("recording"))
        (call-interactively #'muesli-resume)
      (user-error "Not recording")))
   ((plist-get muesli--recording :stopping)
    (user-error "Already stopping"))
   (t (muesli--stop-recording))))

(defun muesli--stop-recording ()
  "Stop the active recording and start the post-stop pipeline."
  (let* ((rec muesli--recording)
         (id (plist-get rec :id))
         (finish (lambda ()
                   (funcall (plist-get rec :watch-stop))
                   (setq muesli--recording nil)
                   (when (timerp muesli--mode-line-timer)
                     (cancel-timer muesli--mode-line-timer))
                   (muesli-db-meeting-update id :ended_at (truncate (float-time)))
                   (muesli--message "Recording stopped; processing \"%s\"" (plist-get rec :title))
                   (muesli--advance id "transcribing"))))
    (setq muesli--recording (plist-put rec :stopping t))
    (if (plist-get rec :exited)
        (funcall finish)
      (setq muesli--recording (plist-put muesli--recording :on-exit finish))
      (funcall (plist-get rec :stop)))))

;;;; Abort and deletion

(defun muesli--delete-data (id)
  "Delete the database rows and audio of meeting ID."
  (let ((meeting (muesli-db-meeting id)))
    (muesli-stt-forget id)
    (when-let* ((dir (plist-get meeting :audio_dir)))
      (when (file-directory-p dir) (delete-directory dir t)))
    (muesli-db-meeting-delete id)
    (remhash id muesli--pipelines)
    (muesli--refresh-transcript id)))

;;;###autoload
(defun muesli-abort ()
  "Stop recording and discard the audio and transcript of the meeting."
  (interactive)
  (unless muesli--recording (user-error "Not recording"))
  (let* ((rec muesli--recording)
         (id (plist-get rec :id)))
    (unless (yes-or-no-p (format "Discard the recording of \"%s\"? " (plist-get rec :title)))
      (user-error "Aborted"))
    (setq muesli--recording nil)
    (when (timerp muesli--mode-line-timer) (cancel-timer muesli--mode-line-timer))
    (ignore-errors (funcall (plist-get rec :watch-stop)))
    (ignore-errors (funcall (plist-get rec :stop) 'kill))
    (ignore-errors (muesli--with-heading id (muesli--set-tag muesli-recording-tag nil)))
    (muesli--delete-data id)
    (force-mode-line-update t)
    (muesli--message "Recording discarded")))

;;;###autoload
(defun muesli-delete-meeting-data (id)
  "Delete everything muesli stored for meeting ID (rows and audio).
The org heading itself is left alone."
  (interactive (list (muesli--meeting-id "Delete data of meeting: ")))
  (when (equal id (plist-get muesli--recording :id))
    (user-error "This meeting is being recorded; use `muesli-abort'"))
  (when (yes-or-no-p "Delete muesli's transcript, summary and audio for this meeting? ")
    (muesli--delete-data id)
    (message "muesli: meeting data deleted")))

;;;; Pipeline

(defun muesli--fail (id step err)
  "Mark meeting ID failed at STEP with ERR and tell the user."
  (muesli--set-step id nil)
  (muesli-db-meeting-update id :status "failed" :failed_step step :error err)
  (display-warning 'muesli
                   (format "Meeting \"%s\" failed while %s: %s\nRun `muesli-resume' to retry, or C-u M-x muesli-resume to skip this step."
                           (plist-get (muesli-db-meeting id) :title) step err)
                   :error))

(defun muesli--next-step (step)
  "Return the pipeline step after STEP."
  (cadr (member step muesli--steps)))

(defun muesli--advance (id step &rest args)
  "Run pipeline STEP for meeting ID.  ARGS go to the step function."
  (condition-case err
      (pcase step
        ("transcribing" (muesli--step-transcribe id))
        ("diarizing" (muesli--step-diarize id))
        ("summarizing" (apply #'muesli--step-summarize id args))
        ("done" (muesli--step-done id)))
    ((debug error)
     (muesli--fail id step (error-message-string err)))))

;;;;; Transcribing

(defun muesli--step-transcribe (id)
  "Wait until all chunks of meeting ID are transcribed.
For a phone meeting the relay transcribes and diarizes; wait for it."
  (muesli--set-step id "transcribing")
  (if (muesli--relay-meeting-p id)
      (progn (require 'muesli-relay)
             (muesli-relay-await-transcript id))
    (muesli-stt-run-queue)
    (muesli--check-transcribed id)))

(defun muesli--check-transcribed (id)
  "Move meeting ID on once no chunk is pending or uploading."
  (when (equal (gethash id muesli--pipelines) "transcribing")
    (let* ((counts (muesli-stt-counts id))
           (busy (+ (alist-get "pending" counts 0 nil #'equal)
                    (alist-get "uploading" counts 0 nil #'equal)))
           (failed (alist-get "failed" counts 0 nil #'equal)))
      (cond
       ((> busy 0) nil)                ; wait for `muesli-stt-chunk-done-functions'
       ((> failed 0)
        (muesli--when-idle
         (lambda ()
           (pcase (car (read-multiple-choice
                        (format "muesli: %d chunk(s) failed to transcribe.  " failed)
                        '((?r "retry" "Upload the failed chunks again")
                          (?p "proceed" "Continue without them")
                          (?l "later" "Stop here; `muesli-resume' continues later"))))
             (?r (muesli-stt-retry-failed id))
             (?p (muesli--advance id "diarizing"))
             (_ (muesli--fail id "transcribing"
                              (format "%d chunk(s) failed to transcribe" failed)))))))
       (t (muesli--advance id "diarizing"))))))

(defun muesli--on-chunk-done (id _track _no _status)
  "Hook function: update the transcript view and pipeline for meeting ID."
  (muesli--refresh-transcript id)
  (muesli--check-transcribed id))

(add-hook 'muesli-stt-chunk-done-functions #'muesli--on-chunk-done)

;;;;; Diarizing

(defun muesli--track-kinds (mode)
  "Return ((TRACK . KIND) ...) for capture MODE.
KIND is `single' (one known speaker) or `multi'."
  (pcase mode
    ("call" '(("mic" . single) ("system" . multi)))
    ("hybrid" '(("mic" . multi) ("system" . multi)))
    (_ '(("mic" . multi)))))

(defun muesli--speaker-hint (mode track attendees)
  "Return the expected speaker count on TRACK for MODE given ATTENDEES."
  (when attendees
    (pcase mode
      ("room" (length attendees))
      ("call" (when (equal track "system")
                (let ((n (length (remove muesli-user-name attendees))))
                  (and (> n 0) n))))
      (_ nil))))

(defun muesli--meeting-attendees (id)
  "Return the ATTENDEES of meeting ID's heading, or nil."
  (ignore-errors (muesli--with-heading id (plist-get (muesli--heading-info) :attendees))))

(defun muesli--step-diarize (id)
  "Assign speakers for meeting ID, then run the naming step."
  (muesli--set-step id "diarizing")
  (muesli-db-speakers-clear id)
  (let* ((meeting (muesli-db-meeting id))
         (mode (plist-get meeting :mode))
         (dir (plist-get meeting :audio_dir))
         (adapter (muesli-diarize-adapter))
         (attendees (muesli--meeting-attendees id))
         (tracks (seq-filter (lambda (tk) (muesli-db-segments id (car tk)))
                             (muesli--track-kinds mode))))
    (cl-labels
        ((next (rest)
           (if (null rest)
               (muesli--after-diarize id attendees)
             (let ((track (car (car rest)))
                   (kind (cdr (car rest))))
               (cond
                ((eq kind 'single)
                 (muesli-diarize-label-track id track (concat track ":user") muesli-user-name)
                 (next (cdr rest)))
                ((null adapter)
                 (pcase (list mode track)
                   ('("call" "system") (muesli-diarize-label-track id track "system:others" "Others"))
                   ('("hybrid" "mic") (muesli-diarize-label-track id track "mic:room" "In the room"))
                   ('("hybrid" "system") (muesli-diarize-label-track id track "system:remote" "Remote")))
                 (next (cdr rest)))
                (t
                 (muesli-record-concat
                  dir track
                  (lambda (result)
                    (pcase result
                      (`(:ok ,file)
                       (muesli--log "Diarizing %s" file)
                       (funcall adapter file (muesli--speaker-hint mode track attendees)
                                (muesli-summary--call-once
                                 (lambda (r)
                                   (condition-case err
                                       (pcase r
                                         (`(:ok ,turns)
                                          (muesli-diarize-apply id track turns)
                                          (next (cdr rest)))
                                         (`(:error ,msg) (muesli--fail id "diarizing" msg)))
                                     (error (muesli--fail id "diarizing"
                                                          (error-message-string err))))))))
                      (`(:error ,msg) (muesli--fail id "diarizing" msg)))))))))))
      (next tracks))))

(defun muesli--needs-naming-p (id)
  "Return non-nil if meeting ID has diarized speakers without names."
  (seq-some (lambda (sp) (null (plist-get sp :name))) (muesli-db-speakers id)))

(defun muesli--after-diarize (id attendees)
  "Run the speaker naming step for meeting ID, then summarize.
ATTENDEES are offered as names."
  (if (or muesli-skip-naming (not (muesli--needs-naming-p id)))
      (muesli--advance id "summarizing")
    (muesli--when-idle
     (lambda ()
       (condition-case nil
           (muesli-diarize-name-speakers id attendees)
         (quit (message "muesli: naming skipped")))
       (muesli--advance id "summarizing")))))

;;;;; Summarizing

(defun muesli--duration-string (meeting)
  "Return MEETING's duration as H:MM:SS, or nil."
  (when-let* ((start (plist-get meeting :started_at))
              (end (plist-get meeting :ended_at)))
    (let ((s (max 0 (- end start))))
      (format "%d:%02d:%02d" (/ s 3600) (/ (% s 3600) 60) (% s 60)))))

(defun muesli--step-summarize (id &optional regenerate reruns)
  "Summarize meeting ID and replace its heading body.
REGENERATE non-nil means start from the stored original notes.
RERUNS counts restarts caused by notes edited during summarization."
  (muesli--set-step id "summarizing")
  (let* ((meeting (muesli-db-meeting id))
         (stored (plist-get meeting :notes_raw))
         (snapshot nil) (info nil))
    (muesli--with-heading id
      (setq snapshot (muesli-org-body)
            info (muesli--heading-info)))
    (let* ((notes (if stored stored snapshot))
           (notes (muesli--strip-transcript-drawer notes))
           (transcript (muesli-summary-transcript id))
           (info (append (list :level (1+ (plist-get info :level))
                               :duration (muesli--duration-string meeting)
                               :date (or (plist-get info :date)
                                         (format-time-string "%F %a" (plist-get meeting :started_at))))
                         info)))
      (muesli--log "Summarizing \"%s\" (%d chars of notes, %d of transcript)"
                   (plist-get info :title) (length notes) (length transcript))
      (when (and (string-empty-p transcript) (muesli-db-chunks id))
        (display-warning
         'muesli
         (format "No speech was transcribed from %d recorded chunk(s) of \"%s\"; the notes will be based on your typed notes only.  The input may have been muted or the wrong device (see *muesli-log*).  Set `muesli-keep-audio' to keep the audio for checking."
                 (length (muesli-db-chunks id)) (plist-get info :title))
         :warning))
      (muesli-summary-generate
       info notes transcript
       (lambda (result)
         (condition-case err
             (pcase result
               (`(:ok ,text)
                (muesli-db-meeting-update id :summary text)
                (muesli--apply-summary id text snapshot (or regenerate stored) (or reruns 0)))
               (`(:error ,msg) (muesli--fail id "summarizing" msg)))
           (error (muesli--fail id "summarizing" (error-message-string err)))))))))

(defun muesli--strip-transcript-drawer (notes)
  "Remove a muesli :TRANSCRIPT: drawer from NOTES."
  (string-trim-right
   (replace-regexp-in-string "^:TRANSCRIPT:\n\\(?:.*\n\\)*?:END:\n?" "" notes)))

(defun muesli--apply-summary (id text snapshot from-stored reruns)
  "Write summary TEXT into meeting ID's heading.
SNAPSHOT is the body when summarization started.  FROM-STORED means
the notes came from notes_raw (regenerate).  RERUNS counts restarts."
  (let ((marker (muesli--heading-marker id)))
    (if (null marker)
        (muesli--fail id "applying"
                      "The meeting heading cannot be found; the summary is saved in the database (`muesli-resume' applies it once the heading is back)")
      (let ((current (muesli--with-heading id (muesli-org-body))))
        (cond
         ;; The user kept typing while we summarized.
         ((and (not (equal current snapshot)) (not from-stored)
               (< reruns muesli-max-reruns))
          (muesli--message "Notes changed during summarization; summarizing again")
          (muesli--advance id "summarizing" nil (1+ reruns)))
         ((and (not (equal current snapshot))
               (not (muesli--confirm-overwrite)))
          (muesli--fail id "applying" "Notes changed during summarization; not replaced (summary saved)"))
         (t
          (muesli--with-heading id
            (unless (plist-get (muesli-db-meeting id) :notes_raw)
              (muesli-db-meeting-update id :notes_raw current))
            (muesli-org-replace-body
             (concat text
                     (when muesli-append-transcript
                       (concat (if (string-empty-p text) "" "\n")
                               (muesli-summary-transcript-drawer id)))))
            (muesli--set-tag muesli-recording-tag nil)
            (muesli--set-tag muesli-done-tag t)
            (when-let* ((d (muesli--duration-string (muesli-db-meeting id))))
              (org-entry-put nil "MUESLI_DURATION" d)))
          (muesli--advance id "done")))))))

(defun muesli--confirm-overwrite ()
  "Ask whether to replace a heading body that changed meanwhile."
  (y-or-n-p "The meeting notes changed while the summary was generated.  Replace them anyway (undo restores them)? "))

(defun muesli--step-done (id)
  "Finish meeting ID."
  (muesli--set-step id nil)
  (muesli-db-meeting-update id :status "done" :error nil :failed_step nil)
  (let ((meeting (muesli-db-meeting id)))
    (unless muesli-keep-audio
      (when-let* ((dir (plist-get meeting :audio_dir)))
        (when (file-directory-p dir) (delete-directory dir t))))
    (muesli--message "Notes for \"%s\" are ready" (plist-get meeting :title))))

;;;; Resume, regenerate, restore, naming

(defun muesli--register-chunks-from-disk (id)
  "Register every chunk file of meeting ID found on disk."
  (let ((dir (plist-get (muesli-db-meeting id) :audio_dir)))
    (dolist (f (muesli-record-chunk-files dir))
      (apply #'muesli--on-chunk id f))))

;;;###autoload
(defun muesli-resume (id &optional skip)
  "Continue processing meeting ID from where it stopped.
With prefix argument SKIP, skip the step that failed."
  (interactive
   (list (muesli--read-meeting "Resume meeting: "
                               '("recording" "transcribing" "diarizing" "summarizing" "failed"))
         current-prefix-arg))
  (when (equal id (plist-get muesli--recording :id))
    (user-error "This meeting is still recording; use `muesli-stop'"))
  (when (gethash id muesli--pipelines)
    (user-error "This meeting is already being processed"))
  (let* ((meeting (muesli-db-meeting id))
         (status (plist-get meeting :status))
         (step (if (equal status "failed") (plist-get meeting :failed_step) status)))
    (if (and (member step '("recording" "transcribing" "diarizing"))
             (muesli--relay-meeting-p id))
        (progn (require 'muesli-relay)
               (muesli-relay-resume id skip))
      (muesli--resume-local id meeting status step skip))))

(defun muesli--resume-local (id meeting status step skip)
  "Resume meeting ID (row MEETING, STATUS) at STEP; SKIP skips it."
  (when (equal status "recording")
    (muesli--register-chunks-from-disk id)
    (unless (plist-get meeting :ended_at)
      (muesli-db-meeting-update
       id :ended_at (truncate (or (when-let* ((f (car (last (muesli-record-chunk-files
                                                             (plist-get meeting :audio_dir))))))
                                    (float-time (file-attribute-modification-time
                                                 (file-attributes (nth 2 f)))))
                                  (float-time)))))
    (setq step "transcribing"))
  (muesli-db-chunks-reset-uploading)
  (when (equal step "transcribing")
    (muesli-stt-retry-failed id))
  (when (equal step "applying")
    (if skip (setq step "done")
      (let ((summary (plist-get meeting :summary)))
        (muesli--set-step id "summarizing")
        (setq step nil)
        (muesli--apply-summary id summary
                               (muesli--with-heading id (muesli-org-body))
                               t 0))))
  (when (and skip step) (setq step (muesli--next-step step)))
  (when step
    (muesli--message "Resuming \"%s\" at %s" (plist-get meeting :title) step)
    (muesli--advance id step)))

;;;###autoload
(defun muesli-regenerate (id)
  "Summarize meeting ID again from the stored notes and transcript."
  (interactive (list (muesli--meeting-id "Regenerate meeting: " '("done" "failed"))))
  (when (gethash id muesli--pipelines)
    (user-error "This meeting is already being processed"))
  (muesli--advance id "summarizing" t))

;;;###autoload
(defun muesli-restore-notes (id)
  "Put the original manual notes of meeting ID back in its heading."
  (interactive (list (muesli--meeting-id "Restore notes of meeting: ")))
  (let ((raw (plist-get (muesli-db-meeting id) :notes_raw)))
    (unless raw (user-error "No original notes stored for this meeting"))
    (muesli--with-heading id (muesli-org-replace-body raw))
    (message "muesli: original notes restored (undo to get the summary back)")))

;;;###autoload
(defun muesli-name-speakers (id)
  "Name the speakers of meeting ID, then offer to regenerate its notes."
  (interactive (list (muesli--meeting-id "Name speakers of meeting: ")))
  (unless (muesli-db-speakers id)
    (user-error "This meeting has no detected speakers"))
  (muesli-diarize-name-speakers id (muesli--meeting-attendees id))
  (when (and (equal (plist-get (muesli-db-meeting id) :status) "done")
             (y-or-n-p "Regenerate the notes with these names? "))
    (muesli-regenerate id)))

;;;; Transcript buffer

(defvar-local muesli--transcript-id nil
  "Meeting ID shown in this transcript buffer.")

(define-derived-mode muesli-transcript-mode special-mode "muesli-transcript"
  "Major mode for viewing a meeting transcript."
  (setq-local truncate-lines nil)
  (visual-line-mode 1))

(defun muesli--transcript-buffer-name (id)
  "Return the transcript buffer name for meeting ID."
  (format "*muesli transcript: %s*"
          (or (plist-get (muesli-db-meeting id) :title) id)))

(defun muesli--render-transcript (id)
  "Fill the current buffer with meeting ID's transcript."
  (let ((inhibit-read-only t)
        (at-end (eobp))
        (pos (point)))
    (erase-buffer)
    (let ((entries (muesli-summary-transcript-entries (muesli-db-segments id)
                                                      (muesli-speaker-names id))))
      (if (null entries)
          (insert (propertize "No transcript yet.\n" 'face 'shadow))
        (dolist (e entries)
          (insert (propertize (format "[%s] " (muesli--format-clock (nth 0 e))) 'face 'shadow)
                  (if (nth 1 e) (propertize (concat (nth 1 e) ": ") 'face 'bold) "")
                  (nth 2 e) "\n"))))
    (goto-char (if at-end (point-max) (min pos (point-max))))))

(defun muesli--refresh-transcript (id)
  "Refresh any buffer showing meeting ID's transcript."
  (dolist (buf (buffer-list))
    (when (equal (buffer-local-value 'muesli--transcript-id buf) id)
      (with-current-buffer buf
        (if (muesli-db-meeting id)
            (progn
              (muesli--render-transcript id)
              (dolist (win (get-buffer-window-list buf nil t))
                (when (= (window-point win) (point-max))
                  (set-window-point win (point-max)))))
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert "Meeting data deleted.\n")))))))

;;;###autoload
(defun muesli-show-transcript (id)
  "Show the live transcript of meeting ID (defaults to the current one)."
  (interactive (list (or (plist-get muesli--recording :id)
                         (muesli--meeting-id "Transcript of meeting: "))))
  (let ((buf (get-buffer-create (muesli--transcript-buffer-name id))))
    (with-current-buffer buf
      (muesli-transcript-mode)
      (setq muesli--transcript-id id)
      (goto-char (point-max))
      (muesli--render-transcript id))
    (display-buffer buf)))

;;;; Orphans

(defun muesli--check-orphans ()
  "Offer to resume meetings interrupted by a previous Emacs session."
  (condition-case err
      (progn
        (muesli-db-chunks-reset-uploading)
        (dolist (m (muesli-db-meetings '("recording" "transcribing" "diarizing" "summarizing")))
          (let ((id (plist-get m :id)))
            (unless (or (gethash id muesli--pipelines)
                        (equal id (plist-get muesli--recording :id)))
              (when (y-or-n-p (format "muesli: \"%s\" was interrupted while %s.  Resume processing it now? "
                                      (plist-get m :title) (plist-get m :status)))
                (muesli-resume id))))))
    (error (muesli--log "Orphan check failed: %S" err))))

(when muesli-check-orphans-on-load
  (run-with-idle-timer 2 nil #'muesli--check-orphans))

(provide 'muesli)
;;; muesli.el ends here
