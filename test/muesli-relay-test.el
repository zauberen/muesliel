;;; muesli-relay-test.el --- ERT tests for muesli-relay  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded after muesli-test.el (it reuses its fixtures).  The relay is
;; replaced by an in-memory fake through `muesli-relay-request-function';
;; relay/test covers the server itself, relay/e2e.sh both together.

;;; Code:

(require 'ert)
(require 'muesli-relay)

;;;; Fake relay

(defvar muesli-relay-test--log nil
  "Requests seen by the fake relay, newest first, as (METHOD PATH JSON).")

(defvar muesli-relay-test--recs nil
  "The fake relay's recordings: hash of id -> alist.")

(defvar muesli-relay-test--opts nil
  "Plist of fake relay behaviour: :fail-ack t makes ack fail.")

(defun muesli-relay-test--rec (id)
  "Return the fake relay recording ID."
  (gethash id muesli-relay-test--recs))

(defun muesli-relay-test--set (id &rest pairs)
  "Set PAIRS (KEY VALUE ...) on fake relay recording ID."
  (let ((r (muesli-relay-test--rec id)))
    (cl-loop for (k v) on pairs by #'cddr
             do (setf (alist-get k r) v))
    (puthash id r muesli-relay-test--recs)))

(defun muesli-relay-test--add (rec)
  "Add recording REC (an alist with at least id) to the fake relay."
  ;; Deep copy: `muesli-relay-test--set' mutates conses, and callers pass
  ;; (back)quoted literals.
  (puthash (alist-get 'id rec)
           (copy-tree (append rec '((segs . nil) (stop_requested . nil) (next . 1))))
           muesli-relay-test--recs))

(defun muesli-relay-test--say (id text start end &optional speaker)
  "The relay transcribed TEXT from START to END ms in recording ID."
  (let* ((r (muesli-relay-test--rec id))
         (n (alist-get 'next r)))
    (muesli-relay-test--set
     id 'next (1+ n)
     'segs (append (alist-get 'segs r)
                   (list `((id . ,n) (chunk_no . ,(/ start 30000)) (start_ms . ,start)
                           (end_ms . ,end) (speaker . ,speaker) (text . ,text)
                           (words . ((,start ,end ,text)))))))))

(defun muesli-relay-test--status (r)
  "The status reply for fake recording R."
  `((id . ,(alist-get 'id r)) (status . ,(alist-get 'status r))
    (origin . ,(alist-get 'origin r)) (title . ,(alist-get 'title r))
    (started_at . ,(alist-get 'started_at r)) (duration_ms . ,(alist-get 'duration_ms r))
    (notes . ,(alist-get 'notes r)) (failed_step . ,(alist-get 'failed_step r))
    (error . ,(alist-get 'error r)) (stop_requested . ,(alist-get 'stop_requested r))
    (segments . ,(length (alist-get 'segs r)))))

(defun muesli-relay-test--reply (method path json)
  "Compute the fake relay's reply to METHOD PATH with body JSON."
  (cond
   ((equal path "/link")
    (list :ok '((client_id . "client-1") (user . "alice") (profiles . 2))))
   ((equal path "/ping") (list :ok '((pending . 0) (user . "alice"))))
   ((string-match "\\`/recordings\\?status=\\(.*\\)\\'" path)
    (let ((want (match-string 1 path)) (out '()))
      (maphash (lambda (_ r) (when (equal (alist-get 'status r) want)
                               (push (muesli-relay-test--status (append r nil)) out)))
               muesli-relay-test--recs)
      (list :ok (mapcar (lambda (st)
                          (let ((r (muesli-relay-test--rec (alist-get 'id st))))
                            (append st `((profile . ,(alist-get 'profile r))
                                         (ended_at . ,(alist-get 'ended_at r))))))
                        out))))
   ((and (equal path "/recordings") (equal method "POST"))
    (let ((id (alist-get 'id json)))
      (unless (muesli-relay-test--rec id)
        (muesli-relay-test--add `((id . ,id) (status . "waiting") (origin . "emacs")
                                  (title . ,(alist-get 'title json))
                                  (speakers . ,(alist-get 'speakers json)) (profile . "")
                                  (started_at . ,(alist-get 'started_at json)))))
      (list :ok (muesli-relay-test--status (muesli-relay-test--rec id)))))
   ((string-match "\\`/recordings/\\([^/?]+\\)\\(?:/\\([a-z]+\\)\\)?\\(?:\\?after=\\([0-9]+\\)\\)?\\'" path)
    (let* ((id (match-string 1 path))
           (what (match-string 2 path))
           (after (string-to-number (or (match-string 3 path) "0")))
           (r (muesli-relay-test--rec id)))
      (cond
       ((null r) (list :error "HTTP 404: no such recording"))
       ((and (null what) (equal method "DELETE"))
        (remhash id muesli-relay-test--recs) (list :ok '((deleted . t))))
       ((null what) (list :ok (muesli-relay-test--status r)))
       ((equal what "segments")
        (list :ok (seq-filter (lambda (s) (> (alist-get 'id s) after)) (alist-get 'segs r))))
       ((equal what "stop")
        (if (equal (alist-get 'status r) "waiting")
            (muesli-relay-test--set id 'status "abandoned")
          (muesli-relay-test--set id 'stop_requested t))
        (list :ok (muesli-relay-test--status (muesli-relay-test--rec id))))
       ((equal what "retry")
        (muesli-relay-test--set id 'status "processing" 'failed_step nil 'error nil)
        (list :ok (muesli-relay-test--status (muesli-relay-test--rec id))))
       ((equal what "ack")
        (if (plist-get muesli-relay-test--opts :fail-ack)
            (list :error "HTTP 502: bad gateway")
          (muesli-relay-test--set id 'status "delivered" 'segs nil)
          (list :ok `((id . ,id) (status . "delivered")))))
       ((equal what "reject")
        (muesli-relay-test--set id 'status "rejected") (list :ok nil))
       (t (list :error (format "HTTP 404: %s" path))))))
   (t (list :error (format "HTTP 404: %s" path)))))

(cl-defun muesli-relay-test--fake (&key method path json _output-file _timeout callback)
  "Fake `muesli-relay-request-function': answer METHOD PATH JSON via CALLBACK."
  (push (list method path json) muesli-relay-test--log)
  (let ((reply (muesli-relay-test--reply method path json)))
    (run-at-time 0.01 nil callback reply)))

(defun muesli-relay-test--requests (re &optional method)
  "Return logged requests whose path matches RE (and METHOD, if given)."
  (seq-filter (lambda (r) (and (string-match-p re (nth 1 r))
                               (or (null method) (equal method (car r)))))
              muesli-relay-test--log))

(defmacro muesli-relay-test--with-env (&rest body)
  "Run BODY with a fresh database, meetings file and relay state."
  (declare (indent 0) (debug t))
  `(muesli-test-with-db
     (let* ((tmp (make-temp-file "muesli-relay-test-" t))
            (muesli-data-directory tmp)
            (muesli-meetings-file (expand-file-name "meetings.org" tmp))
            (org-id-locations-file (expand-file-name "ids" tmp))
            (org-id-locations (make-hash-table :test #'equal))
            (org-id-files nil)
            (org-id-track-globally t)
            (muesli-relay-url "https://relay.example")
            (muesli-relay-api-key "msl_test")
            (muesli-relay-client-name "laptop")
            (muesli-relay-poll-interval nil)
            (muesli-relay--state nil)
            (muesli-relay--fetching nil)
            (muesli-relay--timer nil)
            (muesli-relay-test--log nil)
            (muesli-relay-test--recs (make-hash-table :test #'equal))
            (muesli-relay-test--opts nil)
            (muesli-relay--watched (make-hash-table :test #'equal))
            (muesli-relay--live-timer nil)
            (muesli-relay-live-interval 0.1)
            (muesli-ffmpeg-command "/nonexistent/ffmpeg")
            (muesli--mode-line-timer nil)
            (muesli-relay-profiles
             '((default :label "Meeting")
               (standup :label "Daily standup" :category "Work" :title "Standup %F"
                        :attendees ("Ann" "Bob"))))
            (muesli-stt-transcribe-function #'muesli-test-fake-stt)
            (muesli-diarization-backend 'none)
            (muesli-skip-naming t)
            (muesli-chunk-seconds 1)
            (muesli-keep-audio nil)
            (muesli-summary-function-override
             (lambda (_p cb) (run-at-time 0.01 nil cb '(:ok "* Summary\nPhone meeting."))))
            (muesli-relay-request-function #'muesli-relay-test--fake))
       (unwind-protect
           (cl-letf (((symbol-function 'display-warning) #'ignore)
                     ((symbol-function 'muesli--when-idle) #'funcall))
             ,@body)
         (when (timerp muesli-relay--live-timer) (cancel-timer muesli-relay--live-timer))
         (when (timerp muesli--mode-line-timer) (cancel-timer muesli--mode-line-timer))
         (when-let* ((b (find-buffer-visiting muesli-meetings-file)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b))
         (delete-directory tmp t)))))

(defun muesli-relay-test--link ()
  "Link through the fake relay and wait for it."
  (muesli-relay-link)
  (muesli-test-wait (lambda () muesli-relay--state) 5))

(defun muesli-relay-test--fetch ()
  "Fetch and wait until the fetch finished."
  (muesli-relay-fetch)
  (muesli-test-wait (lambda () (not muesli-relay--fetching)) 30))

(defun muesli-relay-test--phone-recording (id &rest extra)
  "A transcribed phone-started recording ID on the fake relay, plus EXTRA."
  (muesli-relay-test--add
   (append extra
           `((id . ,id) (origin . "phone") (status . "transcribed") (profile . "standup")
             (title . nil) (notes . "typed on the phone") (duration_ms . 3500)
             (started_at . 1763042400000) (ended_at . 1763042403500))))
  (muesli-relay-test--say id "Morning everyone." 0 1500 "mic:SPEAKER_00")
  (muesli-relay-test--say id "Hi Ann." 1500 3000 "mic:SPEAKER_01"))

(defun muesli-relay-test--meetings-file (content)
  "Write CONTENT to the meetings file and return its buffer at point-min."
  (with-temp-file muesli-meetings-file (insert content))
  (let ((buf (find-file-noselect muesli-meetings-file)))
    (with-current-buffer buf (goto-char (point-min)))
    buf))

(defun muesli-relay-test--start-phone-meeting ()
  "Start a phone meeting on a fresh heading.  Return (MEETING-ID . REMOTE-ID)."
  (with-current-buffer
      (muesli-relay-test--meetings-file
       "* Meetings\n** Work\n*** [2026-11-14 Sat] Standup\n:PROPERTIES:\n:ATTENDEES: Ann, Bob\n:END:\n- my notes\n")
    (re-search-forward "Standup")
    (let ((muesli-recording-source 'phone))
      (muesli-start)))
  (let ((id (plist-get muesli--recording :id))
        (remote (plist-get muesli--recording :remote)))
    (should (muesli-test-wait (lambda () (muesli-relay-test--rec remote)) 5))
    (cons id remote)))

;;;; Tests

(ert-deftest muesli-relay-profile-json ()
  (let ((muesli-relay-profiles '((standup :label "Daily" :category "Work") (bare))))
    (should (equal (muesli-relay--profile-json (car muesli-relay-profiles))
                   '((name . "standup") (label . "Daily") (description . "room · Work"))))
    (let ((muesli-relay-profiles '((s :attendees ("A" "B" "C")))))
      (should (equal (alist-get 'speakers (muesli-relay--profile-json (car muesli-relay-profiles))) 3)))
    (should (equal (alist-get 'label (muesli-relay--profile-json (cadr muesli-relay-profiles))) "bare"))
    (should (equal (muesli-relay--profile "bare") '(:label "bare")))
    (should-not (muesli-relay--profile "nope"))))

(ert-deftest muesli-relay-curl-method-and-output ()
  (let ((captured nil))
    (cl-letf (((symbol-function 'muesli--run)
               (lambda (&rest args) (setq captured (plist-get args :command)))))
      (muesli--curl :url "http://x/y" :method "GET" :output-file "/tmp/out.bin" :callback #'ignore))
    (should (equal (cadr (member "-X" captured)) "GET"))
    (should (equal (cadr (member "-o" captured)) "/tmp/out.bin"))
    (should-not (member "--data-binary" captured))))

(ert-deftest muesli-relay-insert-heading-layout ()
  (muesli-relay-test--with-env
    (with-temp-file muesli-meetings-file
      (insert "#+title: Meetings\n* Meetings\n** Work\n*** [2026-11-01 Sun] Old\nold body\n** Other\n*** x\n* Elsewhere\n"))
    (let ((muesli-recording-tag nil))
      (muesli-relay--insert-heading muesli-meetings-file "Work" "New one" 1763042400 "notes\n"
                                    '(("ID" . "id-1")))
      (muesli-relay--insert-heading muesli-meetings-file "Fresh" "Other one" 1763042400 nil
                                    '(("ID" . "id-2"))))
    (let ((text (with-temp-buffer (insert-file-contents muesli-meetings-file) (buffer-string))))
      (should (string-match-p
               (concat "\\*\\* Work\n\\*\\*\\* \\[2026-11-01 Sun\\] Old\nold body\n"
                       "\\*\\*\\* \\[2025-11-13 Thu\\] New one\n:PROPERTIES:\n:ID: +id-1\n:END:\nnotes\n"
                       "\\*\\* Other\n")
               text))
      (should (string-match-p "\\*\\*\\* x\n\\*\\* Fresh\n\\*\\*\\* \\[2025-11-13 Thu\\] Other one\n" text))
      (should (string-suffix-p "* Elsewhere\n" text)))))

(ert-deftest muesli-relay-link-stores-state ()
  (muesli-relay-test--with-env
    (muesli-relay-test--link)
    (should (equal (plist-get muesli-relay--state :client-id) "client-1"))
    (should (file-exists-p (muesli-relay--state-file)))
    (let* ((req (car (muesli-relay-test--requests "\\`/link\\'")))
           (profiles (alist-get 'profiles (nth 2 req))))
      (should (equal (seq-map (lambda (p) (alist-get 'name p)) profiles) '("default" "standup"))))
    (setq muesli-relay--state nil)
    (should (equal (plist-get (muesli-relay--load-state) :url) "https://relay.example"))
    (let ((muesli-relay-url "https://other.example"))
      (should-error (muesli-relay-fetch) :type 'user-error))))

(ert-deftest muesli-relay-fetch-imports-phone-recordings ()
  (muesli-relay-test--with-env
    (muesli-relay-test--phone-recording "rec-1")
    (muesli-relay-test--link)
    (muesli-relay-test--fetch)
    (should (equal muesli-relay--last-result "imported 1 recording"))
    (let* ((import (muesli-db-relay-import "rec-1"))
           (id (plist-get import :meeting_id)))
      (should import)
      (should (muesli-test-wait
               (lambda () (equal (plist-get (muesli-db-meeting id) :status) "done")) 10))
      (should (plist-get (muesli-db-relay-import "rec-1") :acked_at))
      (should (equal (nth 2 (car (muesli-relay-test--requests "/ack\\'")))
                     `((meeting_id . ,id))))
      (let ((m (muesli-db-meeting id)))
        (should (equal (plist-get m :mode) "room"))
        (should (equal (plist-get m :category) "Work"))
        (should (equal (plist-get m :title) "Standup 2025-11-13"))
        (should (equal (plist-get m :notes_raw) "typed on the phone\n"))
        (should-not (plist-get m :audio_dir)))
      (should (equal (mapcar (lambda (s) (list (plist-get s :speaker) (plist-get s :text)
                                               (plist-get s :words)))
                             (muesli-db-segments id))
                     '(("mic:SPEAKER_00" "Morning everyone." ((0 1500 "Morning everyone.")))
                       ("mic:SPEAKER_01" "Hi Ann." ((1500 3000 "Hi Ann."))))))
      (should (equal (mapcar (lambda (s) (plist-get s :label)) (muesli-db-speakers id))
                     '("mic:SPEAKER_00" "mic:SPEAKER_01")))
      (with-current-buffer (find-buffer-visiting muesli-meetings-file)
        (goto-char (point-min))
        (should (re-search-forward "^\\*\\*\\* \\[2025-11-13 Thu\\] Standup 2025-11-13" nil t))
        (should (equal (org-entry-get nil "ID") id))
        (should (equal (org-entry-get nil "ATTENDEES") "Ann, Bob"))
        (should-not (member "recording" (org-get-tags nil t)))
        (should (string-search "Phone meeting." (muesli-org-body)))))
    ;; Nothing left to fetch.
    (muesli-relay-test--fetch)
    (should (equal muesli-relay--last-result "nothing waiting"))))

(ert-deftest muesli-relay-failed-ack-is-retried-without-reimport ()
  (muesli-relay-test--with-env
    (muesli-relay-test--phone-recording "rec-2" '(title . "Planning"))
    (setq muesli-relay-test--opts '(:fail-ack t))
    (muesli-relay-test--link)
    (muesli-relay-test--fetch)
    (should (equal muesli-relay--last-result "imported 1 recording"))
    (let ((id (plist-get (muesli-db-relay-import "rec-2") :meeting_id)))
      (should (muesli-test-wait
               (lambda () (equal (plist-get (muesli-db-meeting id) :status) "done")) 10)))
    (should-not (plist-get (muesli-db-relay-import "rec-2") :acked_at))
    ;; The relay still lists it; the second fetch only acks again.
    (setq muesli-relay-test--opts nil)
    (muesli-relay-test--fetch)
    (should (equal muesli-relay--last-result "1 already imported"))
    (should (= 1 (length (muesli-db-meetings))))
    (should (equal (plist-get (car (muesli-db-meetings)) :title) "Planning"))
    (should (plist-get (muesli-db-relay-import "rec-2") :acked_at))))

(ert-deftest muesli-relay-unknown-profile-is-rejected ()
  (muesli-relay-test--with-env
    (muesli-relay-test--phone-recording "rec-3" '(profile . "retro"))
    (muesli-relay-test--link)
    (muesli-relay-test--fetch)
    (should (equal muesli-relay--last-result "1 rejected (unknown profile)"))
    (should (string-search "retro" (alist-get 'reason (nth 2 (car (muesli-relay-test--requests "/reject\\'"))))))
    (should-not (muesli-db-meetings))))

(ert-deftest muesli-relay-phone-meeting-started-in-emacs ()
  (muesli-relay-test--with-env
    (muesli-relay-test--link)
    (pcase-let ((`(,id . ,remote) (muesli-relay-test--start-phone-meeting)))
      ;; Emacs registered a waiting meeting with the speaker hint.
      (let ((create (nth 2 (car (muesli-relay-test--requests "\\`/recordings\\'" "POST")))))
        (should (equal (alist-get 'title create) "Standup"))
        (should (equal (alist-get 'speakers create) 2)))
      (should (plist-get muesli--recording :waiting))
      (should (string-search "waiting for phone" (muesli--mode-line-string)))
      (should (equal (plist-get (muesli-db-meeting id) :status) "recording"))
      ;; The phone starts; the relay transcribes as it goes.
      (muesli-relay-test--set remote 'status "recording" 'started_at (* 1000 (- (float-time) 60)))
      (muesli-relay-test--say remote "Let's start." 0 2000)
      (should (muesli-test-wait (lambda () (= 1 (length (muesli-db-segments id)))) 5))
      (should-not (plist-get muesli--recording :waiting))
      (should (string-match-p "REC [0:]*01:0[0-9]" (muesli--mode-line-string)))
      (muesli-relay-test--say remote "First item." 30000 32000)
      (should (muesli-test-wait (lambda () (= 2 (length (muesli-db-segments id)))) 5))
      ;; Stop from Emacs: the relay is asked, the phone finishes.
      (muesli-stop)
      (should (muesli-relay-test--requests "/stop\\'" "POST"))
      (should (alist-get 'stop_requested (muesli-relay-test--rec remote)))
      (muesli-relay-test--set remote 'status "processing" 'notes "phone side note")
      (should (muesli-test-wait (lambda () (null muesli--recording)) 5))
      (should (equal (gethash id muesli--pipelines) "transcribing"))
      ;; The relay finishes with diarized, re-split segments.
      (muesli-relay-test--set remote 'segs nil 'duration_ms 62000)
      (muesli-relay-test--say remote "Let's start." 0 2000 "mic:SPEAKER_00")
      (muesli-relay-test--say remote "First" 30000 31000 "mic:SPEAKER_00")
      (muesli-relay-test--say remote "item." 31000 32000 "mic:SPEAKER_01")
      (muesli-relay-test--set remote 'status "transcribed")
      (should (muesli-test-wait
               (lambda () (equal (plist-get (muesli-db-meeting id) :status) "done")) 10))
      (should (equal (mapcar (lambda (s) (plist-get s :speaker)) (muesli-db-segments id))
                     '("mic:SPEAKER_00" "mic:SPEAKER_00" "mic:SPEAKER_01")))
      (should (= 2 (length (muesli-db-speakers id))))
      (should (equal (alist-get 'status (muesli-relay-test--rec remote)) "delivered"))
      (should (= 62 (- (plist-get (muesli-db-meeting id) :ended_at)
                       (plist-get (muesli-db-meeting id) :started_at))))
      (let ((m (muesli-db-meeting id)))
        (should (string-search "- my notes" (plist-get m :notes_raw)))
        (should (string-search "phone side note" (plist-get m :notes_raw))))
      (with-current-buffer (find-buffer-visiting muesli-meetings-file)
        (goto-char (point-min))
        (re-search-forward "Standup")
        (should (string-search "Phone meeting." (muesli-org-body)))
        (should-not (member "recording" (org-get-tags nil t))))
      (should-not muesli-relay--live-timer))))

(ert-deftest muesli-relay-phone-stops-by-itself ()
  (muesli-relay-test--with-env
    (muesli-relay-test--link)
    (pcase-let ((`(,id . ,remote) (muesli-relay-test--start-phone-meeting)))
      (muesli-relay-test--set remote 'status "recording" 'started_at (* 1000 (float-time)))
      (muesli-relay-test--set remote 'status "processing")
      (should (muesli-test-wait (lambda () (null muesli--recording)) 5))
      (should (equal (gethash id muesli--pipelines) "transcribing"))
      (should-not (muesli-relay-test--requests "/stop\\'")))))

(ert-deftest muesli-relay-relay-failure-asks ()
  (muesli-relay-test--with-env
    (muesli-relay-test--link)
    (pcase-let ((`(,id . ,remote) (muesli-relay-test--start-phone-meeting)))
      (muesli-relay-test--set remote 'status "recording" 'started_at (* 1000 (float-time)))
      (muesli-relay-test--set remote 'status "failed" 'failed_step "diarizing" 'error "no model")
      (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?p "proceed"))))
        (should (muesli-test-wait (lambda () (muesli-relay-test--requests "/retry\\'")) 5)))
      (should (eq t (alist-get 'skip (nth 2 (car (muesli-relay-test--requests "/retry\\'"))))))
      (muesli-relay-test--say remote "Hello." 0 1000)
      (muesli-relay-test--set remote 'status "transcribed")
      (should (muesli-test-wait
               (lambda () (equal (plist-get (muesli-db-meeting id) :status) "done")) 10)))))

(ert-deftest muesli-relay-later-fails-locally-and-resumes ()
  (muesli-relay-test--with-env
    (muesli-relay-test--link)
    (pcase-let ((`(,id . ,remote) (muesli-relay-test--start-phone-meeting)))
      (muesli-relay-test--set remote 'status "failed" 'failed_step "transcribing" 'error "STT down")
      (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?l "later"))))
        (should (muesli-test-wait
                 (lambda () (equal (plist-get (muesli-db-meeting id) :status) "failed")) 5)))
      (should (equal (plist-get (muesli-db-meeting id) :failed_step) "transcribing"))
      (should-not (gethash id muesli-relay--watched))
      ;; C-u M-x muesli-resume: skip the failed chunks on the relay.
      (muesli-resume id t)
      (should (muesli-test-wait (lambda () (muesli-relay-test--requests "/retry\\'")) 5))
      (muesli-relay-test--say remote "Hello." 0 1000)
      (muesli-relay-test--set remote 'status "transcribed")
      (should (muesli-test-wait
               (lambda () (equal (plist-get (muesli-db-meeting id) :status) "done")) 10)))))

(ert-deftest muesli-relay-abort-deletes-remote ()
  (muesli-relay-test--with-env
    (muesli-relay-test--link)
    (pcase-let ((`(,id . ,remote) (muesli-relay-test--start-phone-meeting)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (muesli-abort))
      (should (muesli-test-wait (lambda () (null (muesli-relay-test--rec remote))) 5))
      (should-not (muesli-db-meeting id))
      (should-not muesli--recording)
      (should-not (gethash id muesli-relay--watched)))))

(ert-deftest muesli-relay-stop-before-the-phone-started ()
  (muesli-relay-test--with-env
    (muesli-relay-test--link)
    (pcase-let ((`(,id . ,_remote) (muesli-relay-test--start-phone-meeting)))
      (muesli-stop)
      (should (muesli-test-wait
               (lambda () (equal (plist-get (muesli-db-meeting id) :status) "failed")) 5))
      (should-not muesli--recording)
      (should (string-search "No phone" (plist-get (muesli-db-meeting id) :error))))))

(ert-deftest muesli-relay-resume-reattaches-after-restart ()
  (muesli-relay-test--with-env
    (muesli-relay-test--link)
    (pcase-let ((`(,id . ,remote) (muesli-relay-test--start-phone-meeting)))
      (muesli-relay-test--set remote 'status "recording" 'started_at (* 1000 (float-time)))
      ;; Emacs dies: all in-memory state is gone.
      (cancel-timer muesli--mode-line-timer)
      (setq muesli--recording nil)
      (clrhash muesli-relay--watched)
      (muesli-resume id)
      (should (equal (plist-get muesli--recording :remote) remote))
      (muesli-relay-test--say remote "Still here." 0 1000)
      (should (muesli-test-wait (lambda () (muesli-db-segments id)) 5))
      (muesli-relay-test--set remote 'status "transcribed")
      (should (muesli-test-wait
               (lambda () (equal (plist-get (muesli-db-meeting id) :status) "done")) 10)))))

(ert-deftest muesli-relay-start-requires-a-link ()
  (muesli-relay-test--with-env
    (with-current-buffer (muesli-relay-test--meetings-file "* Meetings\n*** M\n")
      (re-search-forward "M$")
      (let ((muesli-recording-source 'phone))
        (should-error (muesli-start) :type 'user-error))
      (should-not (muesli-db-meetings)))))

(provide 'muesli-relay-test)
;;; muesli-relay-test.el ends here
