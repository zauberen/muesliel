;;; e2e.el --- Drive muesli-relay from batch Emacs for relay/e2e/run.sh  -*- lexical-binding: t; -*-

;;; Commentary:

;; emacs -Q --batch -L <repo> -l e2e.el --eval '(muesli-e2e "link")'
;; Environment: RELAY_URL, RELAY_KEY, E2E_DIR.  The summary is faked;
;; transcription happens on the relay (against e2e/fake_stt.py).  This
;; Emacs never runs ffmpeg: `muesli-ffmpeg-command' points nowhere.

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
         (muesli-ffmpeg-command "/nonexistent/ffmpeg")
         (muesli-relay-live-interval 1)
         (muesli-skip-naming t)
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
                  (segs (muesli-db-segments (plist-get m :id))))
             (princ (format "MEETING %s %S segments=%d speakers=%S duration=%ss\n"
                            (plist-get m :status) (plist-get m :title) (length segs)
                            (delete-dups (mapcar (lambda (s) (plist-get s :speaker)) segs))
                            (- (plist-get m :ended_at) (plist-get m :started_at))))
             (unless (and (>= (length segs) 2)
                          (seq-every-p (lambda (s) (string-prefix-p "heard mic-" (plist-get s :text))) segs)
                          (seq-every-p (lambda (s) (equal (plist-get s :speaker) "mic:SPEAKER_00")) segs))
               (muesli-e2e--die "expected several diarized relay segments, got %S" segs))))
         (princ "ORG\n")
         (with-current-buffer (find-buffer-visiting muesli-meetings-file)
           (princ (buffer-string))
           (unless (= (length (muesli-db-meetings))
                      (cl-count-if (lambda (_) t)
                                   (split-string (buffer-string) "Recorded on the phone\\." t)
                                   :start 1))
             (muesli-e2e--die "summary not applied to the heading"))))
        ("meeting"
         ;; Spec 3: start the meeting here, record on the phone.
         (muesli-relay--load-state)
         (with-temp-file muesli-meetings-file
           (insert "* Meetings\n** Work\n*** [2026-11-14 Sat] Standup from Emacs\n"
                   ":PROPERTIES:\n:ATTENDEES: Ann, Bob\n:END:\n- typed in Emacs\n"))
         (with-current-buffer (find-file-noselect muesli-meetings-file)
           (goto-char (point-min))
           (re-search-forward "Standup from Emacs")
           (let ((muesli-recording-source 'phone)) (muesli-start)))
         (let ((id (plist-get muesli--recording :id)))
           (princ (format "WAITING %s\n" (muesli--mode-line-string)))
           (unless (muesli-e2e--wait (lambda () (not (plist-get muesli--recording :waiting))) 90)
             (muesli-e2e--die "no phone picked up the meeting"))
           (princ "PHONE STARTED\n")
           ;; Live transcript: at least two 5 s chunks while still recording.
           (unless (muesli-e2e--wait (lambda () (>= (length (muesli-db-segments id)) 2)) 90)
             (muesli-e2e--die "no live segments: %s"
                              (with-current-buffer (get-buffer-create "*muesli-log*") (buffer-string))))
           (princ (format "LIVE %d segments while recording; %s\n"
                          (length (muesli-db-segments id)) (muesli--mode-line-string)))
           (muesli-stop)
           (unless (muesli-e2e--wait
                    (lambda () (equal (plist-get (muesli-db-meeting id) :status) "done")) 180)
             (muesli-e2e--die "meeting did not finish: %S\n%s" (muesli-db-meeting id)
                              (with-current-buffer (get-buffer-create "*muesli-log*") (buffer-string))))
           (let ((m (muesli-db-meeting id))
                 (segs (muesli-db-segments id)))
             (princ (format "MEETING %s segments=%d speakers=%S\n" (plist-get m :status) (length segs)
                            (mapcar (lambda (s) (plist-get s :label)) (muesli-db-speakers id))))
             (unless (string-search "Phone-side note." (plist-get m :notes_raw))
               (muesli-e2e--die "phone notes missing from %S" (plist-get m :notes_raw)))
             (unless (equal (mapcar (lambda (s) (plist-get s :label)) (muesli-db-speakers id))
                            '("mic:SPEAKER_00"))
               (muesli-e2e--die "expected the relay's speaker labels")))
           (with-current-buffer (find-buffer-visiting muesli-meetings-file)
             (princ (buffer-string))
             (unless (string-search "Recorded on the phone." (buffer-string))
               (muesli-e2e--die "summary not applied")))))))))

;;; e2e.el ends here
