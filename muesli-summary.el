;;; muesli-summary.el --- Summaries and org body replacement for muesli  -*- lexical-binding: t; -*-

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

;; Builds the summarization prompt from the user's notes and the
;; transcript, sends it to a backend, sanitizes the org text that comes
;; back, and provides the helpers that read and replace a heading body.
;;
;; Every backend has the same contract: (PROMPT CALLBACK), asynchronous,
;; CALLBACK called exactly once with (:ok STRING) or (:error MESSAGE).
;; Backends only ever return text; muesli does the buffer edit itself.

;;; Code:

(require 'org)
(require 'format-spec)
(require 'muesli-core)
(require 'muesli-db)
(require 'muesli-diarize)

(defcustom muesli-summary-backend 'openai
  "Backend used to turn notes and transcript into org notes.
`openai'      POST /chat/completions on `muesli-llm-base-url' (works
              with Ollama, llama.cpp, LocalAI, vLLM, ...).
`claude-code' the claude CLI in print mode with tools disabled.
`agent-shell' an agent-shell agent through ACP (needs agent-shell).
A function    (PROMPT CALLBACK); CALLBACK gets (:ok TEXT) or
              \(:error MESSAGE)."
  :type '(choice (const :tag "OpenAI-compatible chat" openai)
                 (const :tag "Claude Code CLI" claude-code)
                 (const :tag "agent-shell (ACP)" agent-shell)
                 (function :tag "Custom function"))
  :group 'muesli)

(defcustom muesli-llm-base-url "http://localhost:11434/v1"
  "Base URL of the OpenAI-compatible chat completions server."
  :type 'string
  :group 'muesli)

(defcustom muesli-llm-model "qwen3:14b"
  "Model name for the `openai' summary backend."
  :type 'string
  :group 'muesli)

(defcustom muesli-llm-api-key nil
  "API key for the chat server: nil, a string, or a function returning one."
  :type '(choice (const :tag "None" nil) string function)
  :group 'muesli)

(defcustom muesli-llm-extra-parameters nil
  "Extra top-level fields for the chat completions request body.
An alist such as ((temperature . 0.2) (max_tokens . 4096))."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'muesli)

(defcustom muesli-claude-command "claude"
  "Name or path of the Claude Code CLI."
  :type 'string
  :group 'muesli)

(defcustom muesli-claude-arguments
  '("-p" "--tools" "" "--no-session-persistence" "--strict-mcp-config"
    "--setting-sources" "" "--output-format" "text")
  "Arguments for the claude CLI.
The defaults run print mode with every tool disabled, no MCP
servers, no settings files and no saved session, so the CLI only
produces text.  The prompt is sent on stdin."
  :type '(repeat string)
  :group 'muesli)

(defcustom muesli-claude-model nil
  "Model passed to the claude CLI with --model, or nil for its default."
  :type '(choice (const :tag "Default" nil) string)
  :group 'muesli)

(defcustom muesli-agent-shell-config nil
  "Which agent-shell agent the `agent-shell' backend talks to.
nil uses `agent-shell-preferred-agent-config', falling back to
`claude-code'.  Otherwise an agent identifier symbol such as
`claude-code' or `gemini-cli', or a function returning a config."
  :type '(choice (const :tag "Preferred agent" nil) symbol function)
  :group 'muesli)

(defcustom muesli-summary-timeout 1800
  "Maximum seconds a summary request may take."
  :type 'integer
  :group 'muesli)

(defcustom muesli-summary-max-chars 60000
  "Prompt size above which the transcript is summarized in sections first."
  :type 'integer
  :group 'muesli)

(defcustom muesli-action-item-style 'checkbox
  "How action items are written in generated notes.
`checkbox' gives \"- [ ] Owner: task\" list items, `todo' gives TODO
headings."
  :type '(choice (const :tag "Checkboxes" checkbox) (const :tag "TODO headings" todo))
  :group 'muesli)

(defcustom muesli-summary-prompt
  "You are turning a meeting's rough notes and transcript into clean meeting notes in Emacs org-mode syntax.

Meeting: %t
Category: %c
Date: %d
Duration: %D
Attendees: %a

Rules:
- The user's own notes are the authority on what mattered and on who said or owns what. Keep every point they made. Use the transcript to fill in detail and to catch things the notes missed.
- Speaker labels in the transcript are approximate, especially when one microphone recorded the whole room. Attribute a statement, decision or action item to a person only when the notes or the content of the transcript make it clear; otherwise leave it unattributed.
- Do not invent facts, names, numbers or dates. If something is unclear, leave it out or list it as an open question.
- Preserve verbatim any links, code, commands, numbers and quoted wording the user typed.
- If the transcript is empty or too short to be useful, say so in one line and return the user's notes cleaned up and organized.
- Output org-mode syntax only: no Markdown, no code fences, no introduction or closing remarks.
- Every heading must start with exactly %L stars (level %l); sub-points under a heading are plain org lists, or headings with more stars.

Structure, omitting any section that would be empty:
%S Participants
An org description list with one item per person who spoke, in the form \"- Name :: one short sentence on what they talked about\". Use the speaker names from the transcript; when a label is generic (\"Speaker 2\") keep it unless the notes or the conversation make clear who it is. If the transcript has no speaker labels, list only people the notes or the conversation identify as speaking. Do not list attendees who did not speak, and do not invent people.
%S Summary
A short paragraph.
%S Key points
%S Decisions
%S Action items
%A
%S Open questions

The user's notes:
#+begin_notes
%n
#+end_notes

Transcript (\"[mm:ss] Speaker: text\"):
#+begin_transcript
%T
#+end_transcript
"
  "Template for the summarization prompt.
Format codes: %t title, %c category, %d date, %D duration, %a
attendees, %n the user's notes, %T transcript, %l heading level
number, %L that many stars as text, %S the stars themselves (for
headings in the requested structure), %A instructions for action
items."
  :type 'string
  :group 'muesli)

(defcustom muesli-section-summary-prompt
  "Below is one part (%p) of a meeting transcript. Speaker labels are approximate.
Summarize it as a plain list of the points discussed, decisions, commitments and open questions, in time order. Keep names, numbers and technical terms exactly. Do not invent anything. Plain text only.

%T
"
  "Template for summarizing one section of a long transcript.
%p is the section description and %T the transcript section."
  :type 'string
  :group 'muesli)

(defcustom muesli-summary-function-override nil
  "When non-nil, a function used instead of the configured backend.
Mainly for tests; it has the backend contract (PROMPT CALLBACK)."
  :type '(choice (const nil) function)
  :group 'muesli)

;;;; Transcript assembly

(defcustom muesli-transcript-coalesce-chars 1200
  "Longest line produced by merging consecutive segments of one speaker."
  :type 'integer
  :group 'muesli)

(defun muesli-summary-transcript-entries (segments names)
  "Merge SEGMENTS into transcript entries with display names from NAMES.
SEGMENTS are database row plists from any number of tracks.  NAMES
is a hash table from speaker labels to names.  Entries are sorted by
time; consecutive segments by the same speaker are coalesced.
Returns a list of (START-MS SPEAKER-NAME-OR-NIL TEXT)."
  (let ((sorted (sort (copy-sequence segments)
                      (lambda (a b) (< (plist-get a :start_ms) (plist-get b :start_ms)))))
        (entries '()))
    (dolist (s sorted)
      (let* ((label (plist-get s :speaker))
             (name (and label (gethash label names label)))
             (text (string-trim (plist-get s :text)))
             (last (car entries)))
        (if (and last
                 (equal (nth 1 last) name)
                 (< (+ (length (nth 2 last)) (length text)) muesli-transcript-coalesce-chars))
            (setcar entries (list (nth 0 last) name (concat (nth 2 last) " " text)))
          (push (list (plist-get s :start_ms) name text) entries))))
    (nreverse entries)))

(defun muesli-summary-format-entry (entry)
  "Format transcript ENTRY as a \"[mm:ss] Speaker: text\" line."
  (if (nth 1 entry)
      (format "[%s] %s: %s" (muesli--format-clock (nth 0 entry)) (nth 1 entry) (nth 2 entry))
    (format "[%s] %s" (muesli--format-clock (nth 0 entry)) (nth 2 entry))))

(defun muesli-summary-transcript (meeting-id)
  "Return MEETING-ID's transcript as text, one line per entry."
  (mapconcat #'muesli-summary-format-entry
             (muesli-summary-transcript-entries (muesli-db-segments meeting-id)
                                                (muesli-speaker-names meeting-id))
             "\n"))

;;;; Prompt

(defun muesli-summary--action-instructions (level)
  "Return action item instructions for headings at LEVEL."
  (pcase muesli-action-item-style
    ('todo (format "Write each action item as its own heading with %d stars and the TODO keyword, e.g. \"%s TODO Owner: task\"."
                   (1+ level) (make-string (1+ level) ?*)))
    (_ "Write action items as org checkboxes, e.g. \"- [ ] Owner: task\" (omit the owner when it is not clear).")))

(defun muesli-summary-build-prompt (info notes transcript)
  "Fill `muesli-summary-prompt' with INFO, NOTES and TRANSCRIPT.
INFO is a plist with :title, :category, :date, :duration, :attendees
\(a list of names) and :level (the heading level for the output)."
  (let ((level (plist-get info :level)))
    (format-spec
     muesli-summary-prompt
     `((?t . ,(or (plist-get info :title) "Untitled"))
       (?c . ,(or (plist-get info :category) "-"))
       (?d . ,(or (plist-get info :date) "-"))
       (?D . ,(or (plist-get info :duration) "-"))
       (?a . ,(if (plist-get info :attendees)
                  (string-join (plist-get info :attendees) ", ")
                "unknown"))
       (?n . ,(let ((n (string-trim (or notes ""))))
                (if (string-empty-p n) "(no notes)" n)))
       (?T . ,(let ((tr (string-trim (or transcript ""))))
                (if (string-empty-p tr) "(empty transcript)" tr)))
       (?l . ,(number-to-string level))
       (?L . ,(number-to-string level))
       (?S . ,(make-string level ?*))
       (?A . ,(muesli-summary--action-instructions level))))))

(defun muesli-summary-split-transcript (transcript max-chars)
  "Split TRANSCRIPT into chunks of whole lines of at most MAX-CHARS each."
  (let ((sections '()) (current '()) (size 0))
    (dolist (line (split-string transcript "\n" t))
      (when (and current (> (+ size (length line) 1) max-chars))
        (push (string-join (nreverse current) "\n") sections)
        (setq current nil size 0))
      (push line current)
      (setq size (+ size (length line) 1)))
    (when current (push (string-join (nreverse current) "\n") sections))
    (nreverse sections)))

;;;; Backends

(defun muesli-summary--call-once (callback)
  "Wrap CALLBACK so it runs at most once."
  (let ((called nil))
    (lambda (result)
      (unless called
        (setq called t)
        (funcall callback result)))))

(defun muesli-summary-call (prompt callback)
  "Send PROMPT to the configured backend; CALLBACK gets (:ok TEXT) or (:error MSG)."
  (let ((callback (muesli-summary--call-once callback))
        (fn (or muesli-summary-function-override
                (pcase muesli-summary-backend
                  ('openai #'muesli-summary-openai)
                  ('claude-code #'muesli-summary-claude-code)
                  ('agent-shell #'muesli-summary-agent-shell)
                  ((pred functionp) muesli-summary-backend)
                  (other (user-error "Unknown `muesli-summary-backend': %S" other))))))
    (condition-case err
        (funcall fn prompt callback)
      (error (funcall callback (list :error (error-message-string err)))))))

(defun muesli-summary-openai (prompt callback)
  "Send PROMPT to an OpenAI-compatible chat endpoint and call CALLBACK."
  (muesli--curl
   :name "llm"
   :url (concat (string-remove-suffix "/" muesli-llm-base-url) "/chat/completions")
   :bearer (muesli--resolve-secret muesli-llm-api-key)
   :timeout muesli-summary-timeout
   :json-body (muesli--json-encode
               `((model . ,muesli-llm-model)
                 (stream . :false)
                 (messages . [((role . "user") (content . ,prompt))])
                 ,@muesli-llm-extra-parameters))
   :callback
   (lambda (result)
     (funcall callback
              (pcase result
                (`(:ok ,body)
                 (condition-case nil
                     (let* ((json (muesli--json-parse body))
                            (content (alist-get 'content
                                                (alist-get 'message
                                                           (car (alist-get 'choices json))))))
                       (if (stringp content)
                           (list :ok content)
                         (list :error (format "No message content in response: %s"
                                              (truncate-string-to-width body 300)))))
                   (error (list :error (format "Invalid JSON from chat server: %s"
                                               (truncate-string-to-width body 300))))))
                (_ result))))))

(defun muesli-summary-claude-code (prompt callback)
  "Run PROMPT through the claude CLI in print mode and call CALLBACK."
  (muesli--require-executable muesli-claude-command "the claude-code summary backend")
  (let ((dir (make-temp-file "muesli-claude-" t)))
    (muesli--run
     :name "claude"
     :directory (file-name-as-directory dir)
     :command (append (list muesli-claude-command)
                      muesli-claude-arguments
                      (when muesli-claude-model (list "--model" muesli-claude-model)))
     :stdin prompt
     :callback (lambda (code out err)
                 (ignore-errors (delete-directory dir t))
                 (funcall callback
                          (if (and (= code 0) (not (string-blank-p out)))
                              (list :ok out)
                            (list :error (format "claude exited with %d: %s" code
                                                 (string-trim (concat err "\n" out))))))))))

;;;;; agent-shell / ACP

(defvar agent-shell-preferred-agent-config)
(declare-function acp-make-initialize-request "acp")
(declare-function acp-make-authenticate-request "acp")
(declare-function acp-make-session-new-request "acp")
(declare-function acp-make-session-prompt-request "acp")
(declare-function acp-make-session-request-permission-response "acp")
(declare-function acp-make-error "acp")
(declare-function acp-send-request "acp")
(declare-function acp-send-response "acp")
(declare-function acp-shutdown "acp")
(declare-function acp-subscribe-to-notifications "acp")
(declare-function acp-subscribe-to-requests "acp")
(declare-function acp-subscribe-to-errors "acp")
(declare-function agent-shell--resolved-agent-configs "agent-shell")
(declare-function agent-shell-anthropic-make-claude-code-config "agent-shell-anthropic")

(defun muesli-summary--agent-config ()
  "Return the agent-shell config alist to use for summaries."
  (unless (and (require 'acp nil t) (require 'agent-shell nil t))
    (user-error "The agent-shell summary backend needs the agent-shell and acp packages"))
  (let* ((spec (or muesli-agent-shell-config
                   (let ((p (and (boundp 'agent-shell-preferred-agent-config)
                                 agent-shell-preferred-agent-config)))
                     (if (and (consp p) (eq (car p) 'preselect)) (cdr p) p))
                   'claude-code)))
    (cond
     ((functionp spec) (funcall spec))
     ((and (consp spec) (assq :client-maker spec)) spec)
     ((symbolp spec)
      (or (and (fboundp 'agent-shell--resolved-agent-configs)
               (seq-find (lambda (c) (eq (alist-get :identifier c) spec))
                         (agent-shell--resolved-agent-configs)))
          (and (eq spec 'claude-code)
               (require 'agent-shell-anthropic nil t)
               (agent-shell-anthropic-make-claude-code-config))
          (user-error "No agent-shell config with identifier %s" spec)))
     (t (user-error "Invalid `muesli-agent-shell-config': %S" spec)))))

(defun muesli-summary-agent-shell (prompt callback)
  "Send PROMPT to an agent-shell agent over ACP and call CALLBACK.
agent-shell has no stable non-interactive prompt API, so this talks
to the agent through acp.el directly, reusing agent-shell's agent
configuration (command, authentication).  The session runs in an
empty temporary directory and every permission request is refused,
so the agent can only answer with text."
  (let* ((config (muesli-summary--agent-config))
         (buffer (generate-new-buffer " *muesli-acp*"))
         (client (funcall (alist-get :client-maker config) buffer))
         (dir (make-temp-file "muesli-acp-" t))
         (chunks '())
         (finished nil)
         (timer nil))
    (cl-labels
        ((finish (result)
           (unless finished
             (setq finished t)
             (when timer (cancel-timer timer))
             (ignore-errors (acp-shutdown :client client))
             (ignore-errors (delete-directory dir t))
             (when (buffer-live-p buffer) (kill-buffer buffer))
             (funcall callback result)))
         (fail (what err)
           (finish (list :error (format "%s failed: %S" what err))))
         (send (request what on-success)
           (acp-send-request :client client :request request :buffer buffer
                             :on-success on-success
                             :on-failure (lambda (err &rest _) (fail what err)))))
      (setq timer (run-at-time muesli-summary-timeout nil
                               (lambda () (finish (list :error "Agent timed out")))))
      (acp-subscribe-to-notifications
       :client client :buffer buffer
       :on-notification
       (lambda (n)
         (when (and (equal (alist-get 'method n) "session/update")
                    (equal (map-nested-elt n '(params update sessionUpdate))
                           "agent_message_chunk"))
           (when-let* ((text (map-nested-elt n '(params update content text))))
             (push text chunks)))))
      (acp-subscribe-to-requests
       :client client :buffer buffer
       :on-request
       (lambda (r)
         (let ((id (alist-get 'id r)))
           (acp-send-response
            :client client
            :response (if (equal (alist-get 'method r) "session/request_permission")
                          (acp-make-session-request-permission-response
                           :request-id id :cancelled t)
                        `((:request-id . ,id)
                          (:error . ,(acp-make-error
                                      :code -32601
                                      :message "Not available to muesli summaries"))))))))
      (acp-subscribe-to-errors
       :client client :buffer buffer
       :on-error (lambda (err) (fail "Agent" err)))
      (let ((start-session
             (lambda ()
               (send (acp-make-session-new-request :cwd dir) "session/new"
                     (lambda (resp)
                       (send (acp-make-session-prompt-request
                              :session-id (alist-get 'sessionId resp)
                              :prompt (list `((type . "text") (text . ,prompt))))
                             "session/prompt"
                             (lambda (_resp)
                               (let ((text (apply #'concat (reverse chunks))))
                                 (finish (if (string-blank-p text)
                                             (list :error "Agent returned no text")
                                           (list :ok text)))))))))))
        (send (acp-make-initialize-request
               :protocol-version 1
               :client-info '((name . "muesli") (title . "muesli") (version . "0.1")))
              "initialize"
              (lambda (_resp)
                (if (and (alist-get :needs-authentication config)
                         (alist-get :authenticate-request-maker config))
                    (send (funcall (alist-get :authenticate-request-maker config))
                          "authenticate" (lambda (_) (funcall start-session)))
                  (funcall start-session))))))))

;;;; Orchestration

(defun muesli-summary-generate (info notes transcript callback)
  "Summarize NOTES and TRANSCRIPT for a meeting described by INFO.
Long inputs are summarized in time-ordered sections first.  CALLBACK
gets (:ok ORG-TEXT) with sanitized text, or (:error MESSAGE)."
  (let* ((level (plist-get info :level))
         (prompt (muesli-summary-build-prompt info notes transcript))
         (finish (lambda (result)
                   (funcall callback
                            (pcase result
                              (`(:ok ,text) (list :ok (muesli-summary-sanitize text level)))
                              (_ result))))))
    (if (<= (length prompt) muesli-summary-max-chars)
        (muesli-summary-call prompt finish)
      (let* ((budget (max 2000 (- muesli-summary-max-chars
                                  (length (muesli-summary-build-prompt info notes ""))
                                  2000)))
             (sections (muesli-summary-split-transcript transcript budget))
             (total (length sections))
             (results '()))
        (muesli--message "Long meeting: summarizing the transcript in %d sections" total)
        (cl-labels
            ((next (i rest)
               (if (null rest)
                   (muesli-summary-call
                    (muesli-summary-build-prompt
                     info notes
                     (concat "(The transcript was too long and has been condensed into section summaries.)\n\n"
                             (string-join (nreverse results) "\n\n")))
                    finish)
                 (let* ((section (car rest))
                        (first (and (string-match "\\`\\[\\([0-9:]+\\)\\]" section)
                                    (match-string 1 section)))
                        (desc (format "section %d of %d, starting at %s" i total (or first "?"))))
                   (muesli-summary-call
                    (format-spec muesli-section-summary-prompt `((?p . ,desc) (?T . ,section)))
                    (lambda (result)
                      (pcase result
                        (`(:ok ,text)
                         (push (format "Section %d (from %s):\n%s" i (or first "?")
                                       (string-trim text))
                               results)
                         (next (1+ i) (cdr rest)))
                        (_ (funcall callback result)))))))))
          (next 1 sections))))))

;;;; Sanitizing

(defconst muesli-summary--preamble-regexp
  (concat "\\`[ \t]*\\(?:"
          "\\(?:here\\|below\\)[^\n]*:[ \t]*\\'"
          "\\|\\(?:sure\\|certainly\\|okay\\|ok\\|of course\\|absolutely\\)[,.!:][^\n]*"
          "\\)")
  "Matches a chatty first line that is not part of the notes.")

(defun muesli-summary--block-lines (lines)
  "Return a list parallel to LINES, non-nil where a line is inside a block."
  (let ((in nil))
    (mapcar (lambda (line)
              (cond
               ((string-match-p "\\`[ \t]*#\\+begin_" (downcase line)) (setq in t) nil)
               ((string-match-p "\\`[ \t]*#\\+end_" (downcase line)) (prog1 in (setq in nil)))
               (t in)))
            lines)))

(defun muesli-summary-sanitize (text level)
  "Clean model output TEXT into org text whose top headings are at LEVEL.
Removes reasoning blocks, code fences and chatty preambles, converts
Markdown headings when the text has no org headings, shifts headings
so the shallowest is exactly LEVEL, and ensures a trailing newline."
  (let* ((text (replace-regexp-in-string "<think>\\(?:.\\|\n\\)*?</think>" "" text))
         (lines (split-string text "\n"))
         (lines (seq-remove (lambda (l) (string-match-p "\\`[ \t]*```" l)) lines)))
    ;; Leading blank lines and a chatty preamble.
    (while (and lines (string-blank-p (car lines))) (pop lines))
    (when (and lines (string-match-p muesli-summary--preamble-regexp (downcase (car lines))))
      (pop lines)
      (while (and lines (string-blank-p (car lines))) (pop lines)))
    ;; Markdown headings, only when there are no org headings at all.
    (unless (seq-some (lambda (l) (string-match-p "\\`\\*+ " l)) lines)
      (setq lines (mapcar (lambda (l)
                            (if (string-match "\\`\\(#\\{1,6\\}\\) +\\(.*\\)" l)
                                (concat (make-string (length (match-string 1 l)) ?*)
                                        " " (match-string 2 l))
                              l))
                          lines)))
    ;; Heading levels, ignoring lines inside #+begin/#+end blocks.
    (let* ((in-block (muesli-summary--block-lines lines))
           (levels (delq nil (cl-mapcar (lambda (l b)
                                          (and (not b) (string-match "\\`\\(\\*+\\) " l)
                                               (length (match-string 1 l))))
                                        lines in-block))))
      (when levels
        (let ((shift (- level (apply #'min levels))))
          (unless (= shift 0)
            (setq lines (cl-mapcar
                         (lambda (l b)
                           (if (and (not b) (string-match "\\`\\(\\*+\\) " l))
                               (concat (make-string (max level (+ (length (match-string 1 l)) shift)) ?*)
                                       (substring l (match-end 1)))
                             l))
                         lines in-block))))))
    (let ((result (string-trim-right (string-join lines "\n"))))
      (if (string-empty-p result) "" (concat result "\n")))))

;;;; Org body helpers

(defun muesli-org-body-bounds ()
  "Return (BEG . END) of the body of the heading at point.
The body is everything after the heading line and its metadata
\(planning line, property drawer, logbook) through the end of the
subtree, including sub-headings."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t)
                               (point))))
      (forward-line 1)
      (when (> (point) end) (goto-char end))
      (org-back-to-heading t)
      (org-end-of-meta-data t)
      (cons (min (point) end) end))))

(defun muesli-org-body ()
  "Return the body text of the heading at point."
  (let ((b (muesli-org-body-bounds)))
    (buffer-substring-no-properties (car b) (cdr b))))

(defun muesli-org-replace-body (text)
  "Replace the body of the heading at point with TEXT as one undoable change."
  (let* ((b (muesli-org-body-bounds))
         (text (if (or (string-empty-p text) (string-suffix-p "\n" text))
                   text
                 (concat text "\n"))))
    (save-excursion
      (atomic-change-group
        (goto-char (car b))
        (delete-region (car b) (cdr b))
        (unless (bolp) (insert "\n"))
        (insert text)))))

(defun muesli-summary-transcript-drawer (meeting-id)
  "Return MEETING-ID's transcript wrapped in a :TRANSCRIPT: drawer."
  (let ((body (muesli-summary-transcript meeting-id)))
    (concat ":TRANSCRIPT:\n"
            ;; Escape lines that org would read as headings or drawer ends.
            (replace-regexp-in-string "^\\(\\*\\|:END:\\)" ",\\1" body)
            (if (string-empty-p body) "" "\n")
            ":END:\n")))

(provide 'muesli-summary)
;;; muesli-summary.el ends here
