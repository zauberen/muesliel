;;; e2e.el --- Drive muesli-relay from batch Emacs for relay/e2e/run.sh  -*- lexical-binding: t; -*-

;;; Commentary:

;; emacs -Q --batch -L <repo> -l e2e.el --eval '(muesli-e2e "link")'
;; Environment: RELAY_URL, RELAY_KEY, E2E_DIR.  Transcription and
;; summary are faked; everything else (HTTP, ffmpeg, SQLite, org) is real.

;;; Code:

(setq muesli-check-orphans-on-load nil)
(require 'muesli-relay)

(defun muesli-e2e--wait (pred timeout)
  "Process events until PRED is non-nil or TIMEOUT seconds pass."
  (let ((deadline (+ (float-time) timeout)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (funcall pred)))

(defun muesli-e2e--die (fmt &rest args)
  "Print FMT with ARGS and exit with status 1."
  (princ (concat "E2E FAIL: " (apply #'format fmt args) "\n"))
  (kill-emacs 1))

(defun muesli-e2e (action)
  "Run ACTION, \"link\" or \"fetch\", against the relay in the environment."
  (let* ((dir (getenv "E2E_DIR"))
         (muesli-data-directory (expand-file-name "emacs" dir))
         (muesli-database-file (expand-file-name "muesli.sqlite" muesli-data-directory))
         (muesli-audio-directory (expand-file-name "audio" muesli-data-directory))
         (muesli-meetings-file (expand-file-name "meetings.org" muesli-data-directory))
         (org-id-locations-file (expand-file-name "ids" muesli-data-directory))
         (muesli-relay-url (getenv "RELAY_URL"))
         (muesli-relay-api-key (getenv "RELAY_KEY"))
         (muesli-relay-client-name "e2e-emacs")
         (muesli-relay-profiles '((default :label "Meeting")
                                  (standup :label "Daily standup" :category "Work"
                                           :attendees ("Ann" "Bob"))))
         (muesli-chunk-seconds 5)
         (muesli-keep-audio t)
         (muesli-skip-naming t)
         (muesli-diarization-backend 'none)
         (muesli-stt-transcribe-function
          (lambda (file cb)
            (run-at-time 0.01 nil cb
                         `(:ok ((text . ,(file-name-base file))
                                (segments . (((start . 0.0) (end . 1.0)
                                              (text . ,(concat "heard " (file-name-base file)))))))))))
         (muesli-summary-function-override
          (lambda (_prompt cb) (run-at-time 0.01 nil cb '(:ok "* Summary\nRecorded on the phone.")))))
    (make-directory muesli-data-directory t)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest args) (princ (format "warning: %S\n" args)))))
      (pcase action
        ("link"
         (muesli-relay-link)
         (unless (muesli-e2e--wait (lambda () muesli-relay--state) 20)
           (muesli-e2e--die "link did not complete: %s"
                            (with-current-buffer (get-buffer-create "*muesli-log*") (buffer-string))))
         (princ (format "LINKED %S\n" muesli-relay--state)))
        ("fetch"
         (muesli-relay--load-state)
         (muesli-relay-fetch)
         (muesli-e2e--wait (lambda () (not muesli-relay--fetching)) 120)
         (princ (format "FETCH %s\n" muesli-relay--last-result))
         (unless (string-prefix-p "imported" (or muesli-relay--last-result ""))
           (muesli-e2e--die "nothing imported: %s"
                            (with-current-buffer (get-buffer-create "*muesli-log*") (buffer-string))))
         (let ((want (string-to-number (or (getenv "E2E_EXPECT") "1"))))
           (unless (= want (length (muesli-db-meetings)))
             (muesli-e2e--die "expected %d meetings, got %d" want (length (muesli-db-meetings)))))
         (dolist (m (muesli-db-meetings))
           (unless (muesli-e2e--wait
                    (lambda () (equal (plist-get (muesli-db-meeting (plist-get m :id)) :status) "done"))
                    120)
             (muesli-e2e--die "pipeline did not finish: %S" (muesli-db-meeting (plist-get m :id))))
           (let* ((m (muesli-db-meeting (plist-get m :id)))
                  (chunks (muesli-db-chunks (plist-get m :id))))
             (princ (format "MEETING %s %S chunks=%d duration=%ss\n"
                            (plist-get m :status) (plist-get m :title) (length chunks)
                            (- (plist-get m :ended_at) (plist-get m :started_at))))
             (when (< (length chunks) 2)
               (muesli-e2e--die "expected several chunks, got %d" (length chunks)))))
         (princ "ORG\n")
         (with-current-buffer (find-buffer-visiting muesli-meetings-file)
           (princ (buffer-string))
           (unless (= (length (muesli-db-meetings))
                      (cl-count-if (lambda (_) t)
                                   (split-string (buffer-string) "Recorded on the phone\\." t)
                                   :start 1))
             (muesli-e2e--die "summary not applied to the heading"))))))))

;;; e2e.el ends here
