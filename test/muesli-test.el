;;; muesli-test.el --- ERT tests for muesli  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:  make test
;; or:        emacs -Q --batch -L . -L test -l test/muesli-test.el -f ert-run-tests-batch-and-exit
;;
;; No audio hardware or network is needed; recorder, STT, diarization
;; and summary backends are replaced by fakes.  Set
;; MUESLI_TEST_STT_URL (e.g. http://localhost:8080/v1) and optionally
;; MUESLI_TEST_STT_MODEL to also run one test against a real server.

;;; Code:

(require 'ert)
(setq muesli-check-orphans-on-load nil)
(require 'muesli)

;;;; Fixtures

(defmacro muesli-test-with-db (&rest body)
  "Run BODY with a fresh temporary database and audio directory."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "muesli-test-" t))
          (muesli-database-file (expand-file-name "test.sqlite" dir))
          (muesli-audio-directory (expand-file-name "audio" dir))
          (muesli--pipelines (make-hash-table :test #'equal))
          (muesli--recording nil)
          (muesli-stt--active 0)
          (muesli-stt--not-before (make-hash-table :test #'equal)))
     (unwind-protect
         (progn ,@body)
       (muesli-db-close)
       (delete-directory dir t))))

(defmacro muesli-test-with-org (content &rest body)
  "Run BODY in an org buffer visiting a temp file holding CONTENT."
  (declare (indent 1) (debug t))
  `(let* ((file (make-temp-file "muesli-test-" nil ".org" ,content))
          (org-id-locations-file (make-temp-file "muesli-ids-"))
          (org-id-locations (make-hash-table :test #'equal))
          (org-id-files nil)
          (org-id-track-globally t)
          (buf (find-file-noselect file)))
     (unwind-protect
         (with-current-buffer buf
           (org-mode)
           (goto-char (point-min))
           ,@body)
       (with-current-buffer buf (set-buffer-modified-p nil))
       (kill-buffer buf)
       (delete-file file)
       (delete-file org-id-locations-file))))

(defun muesli-test-write-wav (file ms)
  "Write MS milliseconds of 16 kHz mono 16-bit silence to FILE."
  (let* ((bytes (* 32 ms))
         (u32 (lambda (n) (unibyte-string (logand n 255) (logand (ash n -8) 255)
                                          (logand (ash n -16) 255) (logand (ash n -24) 255))))
         (u16 (lambda (n) (unibyte-string (logand n 255) (logand (ash n -8) 255)))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert "RIFF" (funcall u32 (+ 36 bytes)) "WAVE"
              "fmt " (funcall u32 16) (funcall u16 1) (funcall u16 1)
              (funcall u32 16000) (funcall u32 32000) (funcall u16 2) (funcall u16 16)
              "data" (funcall u32 bytes)
              (make-string bytes 0))
      (let ((coding-system-for-write 'binary))
        (write-region nil nil file nil 'silent)))))

(defun muesli-test-wait (pred &optional timeout)
  "Process events until PRED returns non-nil or TIMEOUT seconds pass."
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

;;;; Capture target

(defun muesli-test-capture (content category title)
  "Run the capture target on CONTENT answering CATEGORY and TITLE.
Return (BUFFER-STRING POINT CATEGORY-CANDIDATES TITLE-CANDIDATES
STORED-TITLE)."
  (let ((answers (list category title))
        (seen '())
        (org-capture-plist nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (push collection seen)
                 (pop answers))))
      (with-temp-buffer
        (org-mode)
        (insert content)
        (muesli-capture-find-category)
        (list (buffer-string) (point)
              (nth 1 seen) (nth 0 seen)
              (plist-get org-capture-plist :meeting-title))))))

(ert-deftest muesli-capture-creates-meetings-heading ()
  (pcase-let ((`(,text ,pos ,cats ,_ ,title)
               (muesli-test-capture "* Inbox\n" "Team" "Kickoff")))
    (should (equal cats nil))
    (should (equal title "Kickoff"))
    (should (string-match-p "\\* Inbox\n\\* Meetings\n\\*\\* Team\n" text))
    ;; Point sits on the blank line the target opens for the entry.
    (should (= pos (length text)))))

(ert-deftest muesli-capture-existing-category-and-titles ()
  (let ((content "* Meetings\n** Team\n*** [2026-11-01 Sun] Weekly\nnotes\n*** [2026-11-08 Sun] Weekly\n*** Retro\n** Clients\n*** Acme\n"))
    (pcase-let ((`(,text ,pos ,cats ,titles ,title)
                 (muesli-test-capture content "Team" "Weekly")))
      (should (equal cats '("Team" "Clients")))
      (should (equal titles '("Weekly" "Retro")))
      (should (equal title "Weekly"))
      ;; Point lands after Team's last entry, before ** Clients.
      (should (string-prefix-p "\n** Clients" (substring text (1- pos))))
      (should (string-match-p "\\*\\*\\* Retro\n\n\n\\*\\* Clients" text)))))

(ert-deftest muesli-capture-new-category ()
  (pcase-let ((`(,text ,_ ,cats ,titles ,_)
               (muesli-test-capture "* Meetings\n** Team\n*** A\n* Other\n" "Board" "Q4")))
    (should (equal cats '("Team")))
    (should (equal titles nil))
    (should (string-match-p "\\*\\*\\* A\n\\*\\* Board\n" text))
    (should (string-match-p "\\* Other" text))))

(ert-deftest muesli-capture-does-not-touch-global-templates ()
  (let ((org-capture-templates '(("x" "Mine" entry (file "x.org") "* %?")))
        (seen nil))
    (cl-letf (((symbol-function 'org-capture)
               (lambda (&rest _) (setq seen org-capture-templates))))
      (muesli-capture))
    (should (equal (caar seen) "m"))
    (should (equal org-capture-templates '(("x" "Mine" entry (file "x.org") "* %?"))))))

;;;; Database

(ert-deftest muesli-db-round-trip-and-migration ()
  (muesli-test-with-db
    (should (= (muesli-db--version (muesli-db)) (muesli-db--latest-version)))
    ;; Migrating an up-to-date database is a no-op.
    (should (= (muesli-db-migrate (muesli-db)) (muesli-db--latest-version)))
    (muesli-db-meeting-create "m1" :title "T" :mode "room" :started_at 100 :status "recording")
    (should (equal (plist-get (muesli-db-meeting "m1") :title) "T"))
    (muesli-db-meeting-update "m1" :status "done" :summary "S")
    (should (equal (plist-get (muesli-db-meeting "m1") :status) "done"))
    (should (muesli-db-chunk-add "m1" "mic" 0 "/a" 0 30000))
    (should-not (muesli-db-chunk-add "m1" "mic" 0 "/a"))
    (muesli-db-segment-add "m1" "mic" 0 10 20 "hi" nil '((10 20 "hi")))
    (should (equal (plist-get (car (muesli-db-segments "m1")) :words) '((10 20 "hi"))))
    (muesli-db-speaker-add "m1" "mic:A" "Ann")
    (muesli-db-speaker-add "m1" "mic:A")
    (should (equal (plist-get (car (muesli-db-speakers "m1")) :name) "Ann"))
    ;; Cascading delete.
    (muesli-db-meeting-delete "m1")
    (should-not (muesli-db-segments "m1"))
    (should-not (muesli-db-chunks "m1"))
    (should-not (muesli-db-speakers "m1"))))

(ert-deftest muesli-db-migrates-from-empty-file ()
  (muesli-test-with-db
    (let ((db (sqlite-open muesli-database-file)))
      (should (= (muesli-db--version db) 0))
      (sqlite-close db))
    (should (muesli-db))
    (should (= (muesli-db--version (muesli-db)) (muesli-db--latest-version)))))

;;;; Recording helpers

(ert-deftest muesli-record-ffmpeg-command-two-tracks ()
  (let ((system-type 'gnu/linux))
    (let ((cmd (muesli-record-ffmpeg-command '(("mic" . "default") ("system" . "sink.monitor")) 30)))
      (should (equal (seq-take cmd 1) (list muesli-ffmpeg-command)))
      (should (member "sink.monitor" cmd))
      (should (member "mic-%05d.wav" cmd))
      (should (member "system-%05d.wav" cmd))
      (should (member "1:a" cmd)))))

(defun muesli-test-nth-2 (x) "Return the third element of X." (nth 2 x))

(ert-deftest muesli-record-complete-chunks-rule ()
  (let ((files '(("mic" 0 "a") ("mic" 1 "b") ("mic" 2 "c") ("system" 0 "d") ("system" 1 "e"))))
    (should (equal (mapcar #'muesli-test-nth-2 (muesli-record--complete-chunks files nil))
                   '("a" "b" "d")))
    (should (equal (length (muesli-record--complete-chunks files t)) 5))))

(ert-deftest muesli-record-wav-duration ()
  (let ((f (make-temp-file "muesli-" nil ".wav")))
    (unwind-protect
        (progn (muesli-test-write-wav f 1500)
               (should (= (muesli-record-wav-duration-ms f) 1500)))
      (delete-file f))))

(ert-deftest muesli-record-chunk-names ()
  (should (equal (muesli-record-parse-chunk-name "/x/mic-00042.wav") '("mic" . 42)))
  (should (equal (muesli-record-parse-chunk-name "system-00001.wav") '("system" . 1)))
  (should-not (muesli-record-parse-chunk-name "mic-full.wav")))

;;;; Levels and duration

(ert-deftest muesli-peak-db-detects-silence-and-sound ()
  (skip-unless (executable-find "ffmpeg"))
  (let ((silent (make-temp-file "muesli-" nil ".wav"))
        (tone (make-temp-file "muesli-" nil ".wav"))
        (results '()))
    (unwind-protect
        (progn
          (muesli-test-write-wav silent 1000)
          (call-process "ffmpeg" nil nil nil "-v" "error" "-y" "-f" "lavfi"
                        "-i" "sine=frequency=440:duration=1" "-ar" "16000" "-ac" "1" tone)
          (muesli-record-peak-db silent (lambda (db) (push (cons 'silent db) results)))
          (muesli-record-peak-db tone (lambda (db) (push (cons 'tone db) results)))
          (should (muesli-test-wait (lambda () (= (length results) 2)) 10))
          (should (< (alist-get 'silent results) muesli-silence-threshold-db))
          (should (> (alist-get 'tone results) muesli-silence-threshold-db)))
      (delete-file silent)
      (delete-file tone))))

(ert-deftest muesli-duration-has-seconds ()
  (should (equal (muesli--duration-string '(:started_at 100 :ended_at 247)) "0:02:27"))
  (should (equal (muesli--duration-string '(:started_at 0 :ended_at 3725)) "1:02:05")))

;;;; Transcription

(ert-deftest muesli-stt-parse-segments-and-fallback ()
  (let ((parsed (muesli-stt-parse-response
                 '((text . "Hello there. Bye.")
                   (segments . (((start . 0.5) (end . 2.0) (text . " Hello there."))
                                ((start . 2.0) (end . 3.0) (text . " "))
                                ((start . 3.0) (end . 4.25) (text . "Bye."))))
                   (words . (((word . "Hello") (start . 0.5) (end . 1.0))
                             ((word . "Bye.") (start . 3.0) (end . 4.2)))))
                 30000)))
    (should (equal (mapcar (lambda (s) (plist-get s :text)) parsed) '("Hello there." "Bye.")))
    (should (equal (plist-get (car parsed) :start-ms) 500))
    (should (equal (plist-get (cadr parsed) :end-ms) 4250))
    (should (equal (plist-get (car parsed) :words) '((500 1000 "Hello")))))
  ;; No segments: one segment spanning the chunk.
  (should (equal (muesli-stt-parse-response '((text . "just text")) 30000)
                 '((:start-ms 0 :end-ms 30000 :text "just text" :words nil))))
  (should (equal (muesli-stt-parse-response "plain" 1000)
                 '((:start-ms 0 :end-ms 1000 :text "plain" :words nil))))
  (should-not (muesli-stt-parse-response '((text . "  ")) 1000)))

(ert-deftest muesli-stt-absolute-timestamps-and-retry ()
  (muesli-test-with-db
    (muesli-db-meeting-create "m" :mode "room" :started_at 1 :status "recording" :chunk_seconds 30)
    (muesli-db-chunk-add "m" "mic" 0 "/c0")
    (muesli-db-chunk-add "m" "mic" 2 "/c2" 60120 29800)
    (let* ((calls 0)
           (muesli-stt-retry-delay 0.01)
           (muesli-stt-transcribe-function
            (lambda (file cb)
              (cl-incf calls)
              (if (and (equal file "/c2") (< calls 3))
                  (funcall cb '(:error "boom"))
                (funcall cb `(:ok ((segments . (((start . 1.5) (end . 2.0) (text . ,file)))))))))))
      (muesli-stt-run-queue)
      (should (muesli-test-wait (lambda () (null (muesli-db-chunks "m" '("pending" "uploading")))) 5))
      (let ((segs (muesli-db-segments "m")))
        ;; Chunk 0 without measured offset: chunk_no * chunk_seconds.
        (should (equal (mapcar (lambda (s) (list (plist-get s :start_ms) (plist-get s :text))) segs)
                       '((1500 "/c0") (61620 "/c2")))))
      (should (equal (plist-get (muesli-db-chunk "m" "mic" 2) :attempts) 2)))))

(ert-deftest muesli-stt-gives-up-after-max-attempts ()
  (muesli-test-with-db
    (muesli-db-meeting-create "m" :mode "room" :started_at 1 :status "recording")
    (muesli-db-chunk-add "m" "mic" 0 "/c0")
    (let ((muesli-stt-retry-delay 0.01)
          (muesli-stt-max-attempts 2)
          (muesli-stt-transcribe-function (lambda (_f cb) (funcall cb '(:error "down")))))
      (muesli-stt-run-queue)
      (should (muesli-test-wait (lambda () (muesli-db-chunks "m" '("failed"))) 5))
      (muesli-stt-retry-failed "m")
      (should (muesli-test-wait (lambda () (muesli-db-chunks "m" '("failed"))) 5)))))

(ert-deftest muesli-curl-never-puts-key-on-command-line ()
  (let ((captured nil))
    (cl-letf (((symbol-function 'muesli--run)
               (lambda (&rest args) (setq captured (plist-get args :command)))))
      (muesli--curl :url "http://x/y" :bearer "SECRET-KEY" :form-fields '(("model" . "m"))
                    :callback #'ignore))
    (should captured)
    (should-not (seq-some (lambda (a) (string-search "SECRET-KEY" a)) captured))
    (should (member "-K" captured))
    (should (member "--form-string" captured))
    (let ((conf (cadr (member "-K" captured))))
      (should (string-search "SECRET-KEY" (with-temp-buffer (insert-file-contents conf) (buffer-string))))
      (delete-file conf))))

(ert-deftest muesli-curl-result-parsing ()
  (should (equal (muesli--curl-result 0 (concat "{}" muesli--http-marker "200") "") '(:ok "{}")))
  (should (eq (car (muesli--curl-result 0 (concat "nope" muesli--http-marker "500") "")) :error))
  (should (eq (car (muesli--curl-result 7 "" "refused")) :error)))

;;;; Diarization

(ert-deftest muesli-diarize-majority-overlap ()
  (let ((turns '(("A" 0 5000) ("B" 5000 10000))))
    (should (equal (plist-get (car (muesli-diarize-assign-segment
                                    '(:start-ms 1000 :end-ms 5500 :text "x") turns))
                              :speaker)
                   "A"))
    ;; No overlap: nearest turn.
    (should (equal (plist-get (car (muesli-diarize-assign-segment
                                    '(:start-ms 12000 :end-ms 13000 :text "x") turns))
                              :speaker)
                   "B"))
    ;; Straddling without words: majority speaker, not split.
    (let ((pieces (muesli-diarize-assign-segment '(:start-ms 3000 :end-ms 8000 :text "x y") turns)))
      (should (= (length pieces) 1))
      (should (equal (plist-get (car pieces) :speaker) "B")))))

(ert-deftest muesli-diarize-split-with-words ()
  (let* ((turns '(("A" 0 5000) ("B" 5000 10000)))
         (pieces (muesli-diarize-assign-segment
                  '(:start-ms 3000 :end-ms 8000 :text "one two three four"
                              :words ((3000 3500 "one") (3600 4500 "two")
                                      (5200 6000 "three") (6100 7900 "four")))
                  turns)))
    (should (equal (mapcar (lambda (p) (list (plist-get p :speaker) (plist-get p :text)
                                             (plist-get p :start-ms) (plist-get p :end-ms)))
                           pieces)
                   '(("A" "one two" 3000 4500) ("B" "three four" 5200 7900))))))

(ert-deftest muesli-diarize-apply-namespaces-labels ()
  (muesli-test-with-db
    (muesli-db-meeting-create "m" :mode "room" :started_at 1 :status "diarizing")
    (muesli-db-segment-add "m" "mic" 0 0 1000 "hello")
    (muesli-db-segment-add "m" "mic" 0 3000 8000 "one two three four" nil
                           '((3000 3500 "one") (3600 4500 "two") (5200 6000 "three") (6100 7900 "four")))
    (muesli-diarize-apply "m" "mic" '(("SPEAKER_00" 0 5000) ("SPEAKER_01" 5000 10000)))
    (should (equal (mapcar (lambda (s) (list (plist-get s :speaker) (plist-get s :text)))
                           (muesli-db-segments "m"))
                   '(("mic:SPEAKER_00" "hello") ("mic:SPEAKER_00" "one two")
                     ("mic:SPEAKER_01" "three four"))))
    (should (equal (mapcar (lambda (s) (plist-get s :label)) (muesli-db-speakers "m"))
                   '("mic:SPEAKER_00" "mic:SPEAKER_01")))
    (let ((names (muesli-speaker-names "m")))
      (should (equal (gethash "mic:SPEAKER_01" names) "Speaker 2")))))

(ert-deftest muesli-diarize-parse-localai-response ()
  (should (equal (muesli-diarize-parse-turns
                  (muesli--json-parse
                   "{\"task\":\"diarize\",\"segments\":[{\"id\":1,\"speaker\":\"SPEAKER_01\",\"label\":\"1\",\"start\":2.34,\"end\":4.1},{\"id\":0,\"speaker\":\"SPEAKER_00\",\"label\":\"0\",\"start\":0.0,\"end\":2.34}]}"))
                 '(("SPEAKER_00" 0 2340) ("SPEAKER_01" 2340 4100)))))

;;;; Transcript assembly

(ert-deftest muesli-transcript-merge-and-coalesce ()
  (let ((names (make-hash-table :test #'equal)))
    (puthash "mic:user" "Me" names)
    (puthash "system:S0" "Bob" names)
    (let ((entries (muesli-summary-transcript-entries
                    (list '(:start_ms 5000 :speaker "system:S0" :text "Second.")
                          '(:start_ms 0 :speaker "mic:user" :text "Hi all.")
                          '(:start_ms 2000 :speaker "mic:user" :text "Let's start.")
                          '(:start_ms 7000 :speaker "system:S0" :text "Third.")
                          '(:start_ms 65000 :speaker "mic:user" :text "Done."))
                    names)))
      (should (equal (mapcar #'muesli-summary-format-entry entries)
                     '("[00:00] Me: Hi all. Let's start."
                       "[00:05] Bob: Second. Third."
                       "[01:05] Me: Done."))))))

(ert-deftest muesli-transcript-without-speakers ()
  (should (equal (mapcar #'muesli-summary-format-entry
                         (muesli-summary-transcript-entries
                          (list '(:start_ms 0 :speaker nil :text "a")
                                '(:start_ms 1000 :speaker nil :text "b"))
                          (make-hash-table)))
                 '("[00:00] a b"))))

(ert-deftest muesli-summary-prompt-contents ()
  (let ((p (muesli-summary-build-prompt '(:title "Sync" :level 4 :attendees ("A" "B"))
                                        "my notes 100%" "[00:00] A: hi")))
    (should (string-search "my notes 100%" p))
    (should (string-search "A, B" p))
    (should (string-search "**** Summary" p))
    (should (string-search "[00:00] A: hi" p))))

(ert-deftest muesli-summary-long-meeting-sections ()
  (let* ((muesli-summary-max-chars 6000)
         (prompts '())
         (muesli-summary-function-override
          (lambda (prompt cb) (push prompt prompts) (funcall cb (list :ok "* Summary\nok"))))
         (transcript (mapconcat (lambda (i) (format "[%02d:00] A: %s" i (make-string 300 ?x)))
                                (number-sequence 0 59) "\n"))
         (result nil))
    (muesli-summary-generate '(:title "T" :level 2) "notes" transcript
                             (lambda (r) (setq result r)))
    (should (equal result '(:ok "** Summary\nok\n")))
    (should (> (length prompts) 2))
    (should (string-search "section summaries" (car prompts)))
    (should (< (length (car prompts)) (* 2 muesli-summary-max-chars)))))

;;;; Sanitizing

(ert-deftest muesli-sanitize-fences-and-preamble ()
  (should (equal (muesli-summary-sanitize "Here are the notes:\n\n```org\n* Summary\nText\n```\n" 2)
                 "** Summary\nText\n"))
  (should (equal (muesli-summary-sanitize "<think>hmm</think>\nSure! Here you go.\n** A\n" 3)
                 "*** A\n")))

(ert-deftest muesli-sanitize-heading-levels ()
  (dolist (level '(1 2 3 5))
    (let ((out (muesli-summary-sanitize "** Summary\n*** Detail\n** Actions\n- [ ] x" level)))
      (should (equal out (format "%s Summary\n%s Detail\n%s Actions\n- [ ] x\n"
                                 (make-string level ?*) (make-string (1+ level) ?*)
                                 (make-string level ?*)))))))

(ert-deftest muesli-sanitize-top-level-heading-is-demoted ()
  (should (equal (muesli-summary-sanitize "* Meeting notes\n** Summary\ntext\n" 4)
                 "**** Meeting notes\n***** Summary\ntext\n")))

(ert-deftest muesli-sanitize-markdown-and-blocks ()
  (should (equal (muesli-summary-sanitize "## Summary\ntext\n### Sub" 3)
                 "*** Summary\ntext\n**** Sub\n"))
  ;; Lines inside blocks are not treated as headings.
  (should (equal (muesli-summary-sanitize "* A\n#+begin_example\n* not a heading\n#+end_example" 2)
                 "** A\n#+begin_example\n* not a heading\n#+end_example\n")))

;;;; Body replacement

(defconst muesli-test-org
  "* Meetings
** Team
*** [2026-11-13 Fri] Weekly :work:
SCHEDULED: <2026-11-13 Fri 10:00>
:PROPERTIES:
:ID: meeting-1
:ATTENDEES: Ann, Bob
:END:
my rough notes
- point one
**** my sub heading
detail
*** [2026-11-14 Sat] Sibling
sibling body
")

(ert-deftest muesli-body-bounds-and-replace ()
  (muesli-test-with-org muesli-test-org
    (re-search-forward "Weekly")
    (should (equal (muesli-org-body)
                   "my rough notes\n- point one\n**** my sub heading\ndetail\n"))
    (buffer-enable-undo)
    (undo-boundary)
    (muesli-org-replace-body "**** Summary\nnew\n")
    (should (equal (buffer-string)
                   (replace-regexp-in-string
                    "my rough notes\n- point one\n\\*\\*\\*\\* my sub heading\ndetail\n"
                    "**** Summary\nnew\n" muesli-test-org t t)))
    ;; One undo group restores the original.
    (undo-boundary)
    (primitive-undo 1 (cdr buffer-undo-list))
    (should (equal (buffer-string) muesli-test-org))))

(ert-deftest muesli-body-of-empty-heading ()
  (muesli-test-with-org "* A\n:PROPERTIES:\n:ID: x\n:END:\n* B\nb\n"
    (should (equal (muesli-org-body) ""))
    (muesli-org-replace-body "** S\n")
    (should (equal (buffer-string) "* A\n:PROPERTIES:\n:ID: x\n:END:\n** S\n* B\nb\n"))))

(ert-deftest muesli-body-of-last-heading-without-newline ()
  (muesli-test-with-org "* A\nnotes"
    (should (equal (muesli-org-body) "notes"))
    (muesli-org-replace-body "** S")
    (should (equal (buffer-string) "* A\n** S\n"))))

;;;; End to end

(defun muesli-test-fake-recorder (wav-ms)
  "Return a fake recorder that writes chunks of WAV-MS milliseconds."
  (cl-function
   (lambda (&key directory tracks _chunk-seconds on-exit)
     (let ((n 0) (timer nil))
       (setq timer (run-at-time 0 0.2
                                (lambda ()
                                  (dolist (tr tracks)
                                    (muesli-test-write-wav
                                     (expand-file-name (format "%s-%05d.wav" (car tr) n) directory)
                                     wav-ms))
                                  (cl-incf n))))
       (lambda (&optional _how)
         (cancel-timer timer)
         (run-at-time 0.1 nil on-exit "finished"))))))

(defun muesli-test-fake-stt (file cb)
  "Fake transcription of FILE calling CB with canned JSON."
  (let ((name (file-name-base file)))
    (run-at-time 0.01 nil cb
                 `(:ok ((text . ,name)
                        (segments . (((start . 0.0) (end . 0.4) (text . ,(concat "first " name)))
                                     ((start . 0.5) (end . 0.9) (text . ,(concat "second " name))))))))))

(ert-deftest muesli-end-to-end-room ()
  (muesli-test-with-db
    (muesli-test-with-org muesli-test-org
      (let* ((muesli-recorder-function (muesli-test-fake-recorder 1000))
             (muesli-stt-transcribe-function #'muesli-test-fake-stt)
             (muesli-diarization-backend
              (lambda (file hint cb)
                (should (string-suffix-p "mic-full.wav" file))
                (should (equal hint 2))
                (run-at-time 0.01 nil cb '(:ok (("SPEAKER_00" 0 500) ("SPEAKER_01" 500 100000))))))
             (muesli-skip-naming t)
             (muesli-chunk-seconds 1)
             (muesli-append-transcript t)
             (muesli-keep-audio nil)
             (muesli-done-tag "muesli")
             (prompt nil)
             (muesli-summary-function-override
              (lambda (p cb) (setq prompt p)
                (run-at-time 0.01 nil cb '(:ok "```org\n* Summary\nAll good.\n```"))))
             (muesli-ffmpeg-command (or (executable-find "ffmpeg") "true")))
        (re-search-forward "Weekly")
        (cl-letf (((symbol-function 'muesli--require-executable) #'ignore)
                  ((symbol-function 'display-warning) #'ignore))
          (muesli-start)
          (should (member "recording" (org-get-tags nil t)))
          (should (string-search "REC" (muesli--mode-line-string)))
          (muesli-test-wait (lambda () (>= (length (muesli-db-chunks "meeting-1")) 3)) 10)
          (muesli-stop)
          (should (muesli-test-wait
                   (lambda () (equal (plist-get (muesli-db-meeting "meeting-1") :status) "done"))
                   30)))
        (let ((meeting (muesli-db-meeting "meeting-1")))
          (should (equal (plist-get meeting :notes_raw)
                         "my rough notes\n- point one\n**** my sub heading\ndetail\n"))
          (should (equal (plist-get meeting :summary) "**** Summary\nAll good.\n"))
          (should-not (file-exists-p (plist-get meeting :audio_dir))))
        (should (string-search "my rough notes" prompt))
        (should (string-search "Speaker 1: first mic-00000" prompt))
        (goto-char (point-min))
        (re-search-forward "Weekly")
        (should (equal (org-get-tags nil t) '("work" "muesli")))
        (should (string-match-p "\\`0:00:[0-9][0-9]\\'" (org-entry-get nil "MUESLI_DURATION")))
        (let ((body (muesli-org-body)))
          (should (string-prefix-p "**** Summary\nAll good.\n\n:TRANSCRIPT:\n" body))
          (should (string-search "Speaker 2: second mic-00000" body)))
        ;; Sibling untouched.
        (should (string-search "*** [2026-11-14 Sat] Sibling\nsibling body\n" (buffer-string)))
        ;; Regenerate keeps notes_raw and uses it.
        (setq muesli-summary-function-override
              (lambda (p cb) (setq prompt p) (funcall cb '(:ok "* Summary\nSecond take."))))
        (muesli-regenerate "meeting-1")
        (should (equal (plist-get (muesli-db-meeting "meeting-1") :notes_raw)
                       "my rough notes\n- point one\n**** my sub heading\ndetail\n"))
        (should (string-search "my rough notes" prompt))
        (should-not (string-search "TRANSCRIPT" prompt))
        (should (string-search "Second take." (muesli-org-body)))
        ;; Restore brings back the exact original body; siblings untouched.
        (muesli-restore-notes "meeting-1")
        (should (equal (muesli-org-body)
                       "my rough notes\n- point one\n**** my sub heading\ndetail\n"))
        (should (string-search "*** [2026-11-14 Sat] Sibling\nsibling body\n" (buffer-string)))
        (should (string-search "SCHEDULED: <2026-11-13 Fri 10:00>" (buffer-string)))))))

(ert-deftest muesli-end-to-end-call-mode ()
  (muesli-test-with-db
    (muesli-test-with-org muesli-test-org
      (let* ((muesli-recorder-function (muesli-test-fake-recorder 1000))
             (muesli-stt-transcribe-function #'muesli-test-fake-stt)
             (muesli-diarization-backend 'none)
             (muesli-user-name "Me")
             (muesli-chunk-seconds 1)
             (prompt nil)
             (seen-tracks nil)
             (muesli-summary-function-override
              (lambda (p cb) (setq prompt p) (funcall cb '(:ok "* Summary\nok")))))
        (re-search-forward "Weekly")
        (org-entry-put nil "MUESLI_MODE" "call")
        (cl-letf (((symbol-function 'muesli--require-executable) #'ignore)
                  ((symbol-function 'muesli-record-default-monitor) (lambda () "sink.monitor"))
                  ((symbol-function 'display-warning) #'ignore))
          (let ((orig muesli-recorder-function))
            (setq muesli-recorder-function
                  (lambda (&rest args)
                    (setq seen-tracks (plist-get args :tracks))
                    (apply orig args))))
          (muesli-start)
          (muesli-test-wait (lambda () (>= (length (muesli-db-chunks "meeting-1")) 2)) 10)
          (muesli-stop)
          (should (muesli-test-wait
                   (lambda () (equal (plist-get (muesli-db-meeting "meeting-1") :status) "done"))
                   30)))
        (should (equal (mapcar #'car seen-tracks) '("mic" "system")))
        (should (equal (mapcar (lambda (s) (list (plist-get s :label) (plist-get s :name)))
                               (muesli-db-speakers "meeting-1"))
                       '(("mic:user" "Me") ("system:others" "Others"))))
        (should (string-search "Me: first mic-00000" prompt))
        (should (string-search "Others: first system-00000" prompt))))))

(ert-deftest muesli-notes-edited-during-summary-rerun ()
  (muesli-test-with-db
    (muesli-test-with-org muesli-test-org
      (re-search-forward "Weekly")
      (muesli-db-meeting-create "meeting-1" :mode "room" :started_at 0 :ended_at 60
                                :status "summarizing")
      (let* ((calls 0)
             (buf (current-buffer))
             (muesli-summary-function-override
              (lambda (p cb)
                (cl-incf calls)
                (when (= calls 1)
                  ;; The user types while the first summary runs.
                  (with-current-buffer buf
                    (save-excursion (goto-char (point-min)) (search-forward "- point one")
                                    (insert " (edited)"))))
                (funcall cb (list :ok (if (string-search "(edited)" p) "* Final" "* Stale"))))))
        (muesli--advance "meeting-1" "summarizing")
        (should (= calls 2))
        (should (equal (muesli-org-body) "**** Final\n"))
        (should (string-search "(edited)" (plist-get (muesli-db-meeting "meeting-1") :notes_raw)))))))

(ert-deftest muesli-missing-heading-keeps-summary ()
  (muesli-test-with-db
    (muesli-db-meeting-create "gone" :mode "room" :started_at 0 :status "summarizing")
    (cl-letf (((symbol-function 'display-warning) #'ignore))
      (muesli--advance "gone" "summarizing"))
    (should (equal (plist-get (muesli-db-meeting "gone") :status) "failed"))
    (should (equal (plist-get (muesli-db-meeting "gone") :failed_step) "summarizing"))))

(ert-deftest muesli-start-refuses-second-recording ()
  (let ((muesli--recording '(:id "x" :title "Other")))
    (should-error (muesli-start) :type 'user-error)))

;;;; Optional integration test

(ert-deftest muesli-integration-real-stt ()
  (skip-unless (getenv "MUESLI_TEST_STT_URL"))
  (let* ((muesli-stt-base-url (getenv "MUESLI_TEST_STT_URL"))
         (muesli-stt-model (or (getenv "MUESLI_TEST_STT_MODEL") muesli-stt-model))
         (f (make-temp-file "muesli-" nil ".wav"))
         (result nil))
    (unwind-protect
        (progn
          (muesli-test-write-wav f 1000)
          (muesli-stt-transcribe-http f (lambda (r) (setq result r)))
          (should (muesli-test-wait (lambda () result) 120))
          (should (eq (car result) :ok)))
      (delete-file f))))

(provide 'muesli-test)
;;; muesli-test.el ends here
