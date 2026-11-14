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

(defun muesli-relay-test--fake (recordings &optional opts)
  "Return a fake request function serving RECORDINGS.
Each recording is an alist as the relay sends it plus (file . PATH)
naming the audio to serve.  OPTS is a plist: :fail-ack t makes ack
fail, :corrupt t serves the wrong bytes."
  (let ((acked '()))
    (cl-function
     (lambda (&key method path json output-file _timeout callback)
       (push (list method path json) muesli-relay-test--log)
       (let ((reply
              (cond
               ((equal path "/link")
                (list :ok '((client_id . "client-1") (user . "alice") (profiles . 2))))
               ((equal path "/ping") (list :ok '((pending . 0) (user . "alice"))))
               ((string-prefix-p "/recordings?" path)
                (list :ok (mapcar (lambda (r) (assq-delete-all 'file (copy-alist r)))
                                  (seq-remove (lambda (r) (member (alist-get 'id r) acked))
                                              recordings))))
               ((string-match "\\`/recordings/\\([^/]+\\)/\\(audio\\|ack\\|reject\\)\\'" path)
                (let* ((id (match-string 1 path))
                       (what (match-string 2 path))
                       (r (seq-find (lambda (x) (equal (alist-get 'id x) id)) recordings)))
                  (pcase what
                    ("audio"
                     (if (plist-get opts :corrupt)
                         (with-temp-file output-file (insert "garbage"))
                       (copy-file (alist-get 'file r) output-file t))
                     (list :ok nil))
                    ("ack" (if (plist-get opts :fail-ack)
                               (list :error "HTTP 502: bad gateway")
                             (push id acked)
                             (list :ok `((id . ,id) (status . "delivered")))))
                    ("reject" (push id acked) (list :ok nil)))))
               (t (list :error (format "HTTP 404: %s" path))))))
         (run-at-time 0.01 nil callback reply))))))

(defun muesli-relay-test--requests (re)
  "Return logged requests whose path matches RE."
  (seq-filter (lambda (r) (string-match-p re (nth 1 r))) muesli-relay-test--log))

(defun muesli-relay-test--make-audio (file seconds)
  "Write SECONDS of a test tone to FILE (webm/opus) with ffmpeg."
  (call-process (executable-find "ffmpeg") nil nil nil "-hide_banner" "-loglevel" "error" "-y"
                "-f" "lavfi" "-i" (format "sine=frequency=440:duration=%s" seconds)
                "-c:a" "libopus" "-b:a" "32k" file))

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
            (muesli-relay-request-function (muesli-relay-test--fake nil)))
       (unwind-protect
           (cl-letf (((symbol-function 'display-warning) #'ignore))
             ,@body)
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

(defun muesli-relay-test--recording (id file &rest extra)
  "A relay recording alist with ID serving FILE, plus EXTRA pairs."
  (append extra
          `((id . ,id) (profile . "standup") (title . nil) (notes . "typed on the phone")
            (mime_type . "audio/webm;codecs=opus") (duration_ms . 3500)
            (bytes . ,(file-attribute-size (file-attributes file)))
            (sha256 . ,(muesli-relay--file-sha256 file))
            (started_at . 1763042400000) (ended_at . 1763042403500)
            (file . ,file))))

;;;; Tests

(ert-deftest muesli-relay-profile-json ()
  (let ((muesli-relay-profiles '((standup :label "Daily" :category "Work") (bare))))
    (should (equal (muesli-relay--profile-json (car muesli-relay-profiles))
                   '((name . "standup") (label . "Daily") (description . "room · Work"))))
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

(ert-deftest muesli-relay-fetch-imports-and-runs-pipeline ()
  (skip-unless (executable-find "ffmpeg"))
  (muesli-relay-test--with-env
    (let* ((audio (expand-file-name "phone.webm" muesli-data-directory))
           (_ (muesli-relay-test--make-audio audio 3.5))
           (rec (muesli-relay-test--recording "rec-1" audio))
           (muesli-relay-request-function (muesli-relay-test--fake (list rec))))
      (muesli-relay-test--link)
      (muesli-relay-test--fetch)
      (should (equal muesli-relay--last-result "imported 1 recording"))
      (let* ((import (muesli-db-relay-import "rec-1"))
             (id (plist-get import :meeting_id)))
        (should import)
        (should (plist-get import :acked_at))
        (should (equal (nth 2 (car (muesli-relay-test--requests "/ack\\'")))
                       `((meeting_id . ,id))))
        (should (muesli-test-wait
                 (lambda () (equal (plist-get (muesli-db-meeting id) :status) "done")) 30))
        (let ((m (muesli-db-meeting id)))
          (should (equal (plist-get m :mode) "room"))
          (should (equal (plist-get m :category) "Work"))
          (should (equal (plist-get m :title) "Standup 2025-11-13"))
          (should (equal (plist-get m :notes_raw) "typed on the phone\n"))
          (should (= (- (plist-get m :ended_at) (plist-get m :started_at)) 3)))
        (with-current-buffer (find-buffer-visiting muesli-meetings-file)
          (goto-char (point-min))
          (should (re-search-forward "^\\*\\*\\* \\[2025-11-13 Thu\\] Standup 2025-11-13" nil t))
          (should (equal (org-entry-get nil "ID") id))
          (should (equal (org-entry-get nil "ATTENDEES") "Ann, Bob"))
          (should-not (member "recording" (org-get-tags nil t)))
          (should (string-search "Phone meeting." (muesli-org-body))))
        ;; Four 1 s chunks of a 3.5 s recording, all transcribed.
        (should (>= (length (muesli-db-segments id)) 6)))
      ;; Nothing left to fetch.
      (muesli-relay-test--fetch)
      (should (equal muesli-relay--last-result "nothing waiting")))))

(ert-deftest muesli-relay-failed-ack-is-retried-without-reimport ()
  (skip-unless (executable-find "ffmpeg"))
  (muesli-relay-test--with-env
    (let* ((audio (expand-file-name "phone.webm" muesli-data-directory))
           (_ (muesli-relay-test--make-audio audio 1.5))
           (rec (muesli-relay-test--recording "rec-2" audio '(title . "Planning")))
           (muesli-relay-request-function (muesli-relay-test--fake (list rec) '(:fail-ack t))))
      (muesli-relay-test--link)
      (muesli-relay-test--fetch)
      (should (equal muesli-relay--last-result "imported 1 recording"))
      (should-not (plist-get (muesli-db-relay-import "rec-2") :acked_at))
      ;; The relay still lists it; the second fetch only acks again.
      (muesli-relay-test--fetch)
      (should (equal muesli-relay--last-result "1 already imported"))
      (should (= 1 (length (muesli-db-meetings))))
      (should (equal (plist-get (car (muesli-db-meetings)) :title) "Planning"))
      (should (= 2 (length (muesli-relay-test--requests "/ack\\'")))))))

(ert-deftest muesli-relay-unknown-profile-is-rejected ()
  (muesli-relay-test--with-env
    (let* ((audio (expand-file-name "x.webm" muesli-data-directory))
           (_ (with-temp-file audio (insert "x")))
           (rec (muesli-relay-test--recording "rec-3" audio '(profile . "retro")))
           (muesli-relay-request-function (muesli-relay-test--fake (list rec))))
      (muesli-relay-test--link)
      (muesli-relay-test--fetch)
      (should (equal muesli-relay--last-result "1 rejected (unknown profile)"))
      (should (string-search "retro" (alist-get 'reason (nth 2 (car (muesli-relay-test--requests "/reject\\'"))))))
      (should-not (muesli-db-meetings))
      (should-not (muesli-relay-test--requests "/audio\\'")))))

(ert-deftest muesli-relay-checksum-mismatch-fails-cleanly ()
  (muesli-relay-test--with-env
    (let* ((audio (expand-file-name "x.webm" muesli-data-directory))
           (_ (with-temp-file audio (insert "real audio bytes")))
           (rec (muesli-relay-test--recording "rec-4" audio))
           (muesli-relay-request-function (muesli-relay-test--fake (list rec) '(:corrupt t))))
      (muesli-relay-test--link)
      (muesli-relay-test--fetch)
      (should (equal muesli-relay--last-result "1 failed (see *muesli-log*)"))
      ;; Downloaded twice (one retry), nothing imported, nothing acked.
      (should (= 2 (length (muesli-relay-test--requests "/audio\\'"))))
      (should-not (muesli-db-meetings))
      (should-not (muesli-relay-test--requests "/ack\\'"))
      (should-not (directory-files muesli-audio-directory nil "\\`[^.]")))))

(provide 'muesli-relay-test)
;;; muesli-relay-test.el ends here
