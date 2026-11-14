;;; muesli-core.el --- Shared helpers for muesli  -*- lexical-binding: t; -*-

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

;; Customization group, logging, process helpers and the curl wrapper
;; shared by all muesli modules.  Nothing in here knows about meetings.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'map)
(require 'subr-x)

(defgroup muesli nil
  "Local meeting notes: record, transcribe and summarize into org."
  :group 'org
  :prefix "muesli-")

(defcustom muesli-curl-command "curl"
  "Name or path of the curl executable."
  :type 'string
  :group 'muesli)

(defcustom muesli-ffmpeg-command "ffmpeg"
  "Name or path of the ffmpeg executable."
  :type 'string
  :group 'muesli)

(defcustom muesli-data-directory
  (let ((xdg (getenv "XDG_DATA_HOME")))
    (if (and xdg (not (string-empty-p xdg)))
        (expand-file-name "muesli" xdg)
      (locate-user-emacs-file "muesli")))
  "Directory holding muesli's database and audio by default."
  :type 'directory
  :group 'muesli)

;;;; Logging

(defconst muesli--log-buffer "*muesli-log*"
  "Name of the buffer receiving muesli's diagnostic log.")

(defun muesli--log (format-string &rest args)
  "Append a line built from FORMAT-STRING and ARGS to the muesli log."
  (let ((line (apply #'format format-string args)))
    (with-current-buffer (get-buffer-create muesli--log-buffer)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format-time-string "%F %T ") line "\n")))
    line))

(defun muesli--message (format-string &rest args)
  "Show and log a message built from FORMAT-STRING and ARGS."
  (let ((line (apply #'muesli--log format-string args)))
    (message "muesli: %s" line)))

;;;; Small utilities

(defun muesli--require-executable (program what)
  "Signal a `user-error' unless PROGRAM is on the variable `exec-path'.
WHAT describes what PROGRAM is needed for."
  (or (executable-find program)
      (user-error "Muesli needs `%s' for %s, but it is not installed or not on exec-path"
                  program what)))

(defun muesli--resolve-secret (value)
  "Return VALUE as a secret string.
VALUE may be nil, a string, or a function of no arguments returning
either.  A function lets `auth-source' lookups happen lazily."
  (let ((v (if (functionp value) (funcall value) value)))
    (and (stringp v) (not (string-empty-p v)) v)))

(defun muesli--mode-value (value mode)
  "Resolve VALUE for capture MODE.
VALUE is either a plain value or an alist whose keys are mode symbols
\(`room', `call', `hybrid') or t for the fallback.  Strings, nil and
other atoms are returned as is."
  (if (and (consp value) (consp (car value))
           (symbolp (caar value)))
      (cdr (or (assq mode value) (assq t value)))
    value))

(defun muesli--json-parse (string)
  "Parse JSON STRING into alists and lists, nil for null and false."
  (json-parse-string string :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun muesli--json-encode (object)
  "Encode OBJECT (alists, vectors, strings, numbers) as JSON."
  (json-serialize object :null-object :null :false-object :false))

(defun muesli--seconds-to-ms (s)
  "Convert S seconds (number or nil) to integer milliseconds."
  (if (numberp s) (round (* 1000 s)) 0))

(defun muesli--format-clock (ms)
  "Format MS milliseconds as mm:ss, or h:mm:ss past one hour."
  (let* ((total (/ (max 0 (truncate ms)) 1000))
         (h (/ total 3600))
         (m (/ (% total 3600) 60))
         (s (% total 60)))
    (if (> h 0)
        (format "%d:%02d:%02d" h m s)
      (format "%02d:%02d" m s))))

(defun muesli--file-safe (string)
  "Turn STRING into something safe to use as a file name component."
  (replace-regexp-in-string "[^[:alnum:]_.-]" "_" string))

;;;; Asynchronous processes

(cl-defun muesli--run (&key name command stdin directory callback)
  "Run COMMAND (a list) asynchronously and report its output.
NAME labels the process.  STDIN, when non-nil, is a string sent to
the process followed by EOF.  DIRECTORY is the working directory.
CALLBACK receives (EXIT-CODE STDOUT STDERR) exactly once."
  (let* ((default-directory (or directory default-directory))
         (out (generate-new-buffer (format " *muesli-%s-out*" name)))
         (err (generate-new-buffer (format " *muesli-%s-err*" name)))
         (stderr-proc (make-pipe-process
                       :name (format "muesli-%s-stderr" name)
                       :buffer err :noquery t
                       :sentinel #'ignore))
         (proc
          (make-process
           :name (format "muesli-%s" name)
           :command command
           :buffer out
           :stderr stderr-proc
           :connection-type 'pipe
           :coding 'utf-8
           :noquery t
           :sentinel
           (lambda (p _event)
             (unless (process-live-p p)
               ;; Let the stderr pipe drain before reading it.
               (when (process-live-p stderr-proc)
                 (accept-process-output stderr-proc 0.05))
               (let ((code (process-exit-status p))
                     (stdout (with-current-buffer out (buffer-string)))
                     (stderr (with-current-buffer err (buffer-string))))
                 (when (process-live-p stderr-proc)
                   (delete-process stderr-proc))
                 (kill-buffer out)
                 (kill-buffer err)
                 (funcall callback code stdout stderr)))))))
    (when stdin
      (process-send-string proc stdin))
    (process-send-eof proc)
    proc))

(defun muesli--curl-quote (string)
  "Quote STRING for a curl config file value."
  (concat "\""
          (replace-regexp-in-string
           "[\"\\\n\r\t]"
           (lambda (c)
             (pcase c
               ("\"" "\\\"") ("\\" "\\\\")
               ("\n" "\\n") ("\r" "\\r") ("\t" "\\t")))
           string t t)
          "\""))

(defconst muesli--http-marker "\n__MUESLI_HTTP_STATUS__:"
  "Marker curl appends before the HTTP status code.")

(cl-defun muesli--curl (&key name url bearer form-fields form-files
                             json-body timeout callback)
  "Send an HTTP POST to URL with curl and call CALLBACK with the result.
NAME labels the process.  BEARER, if non-nil, is an API token sent as
an Authorization header through a private config file, never on the
command line.  FORM-FIELDS is an alist of (NAME . VALUE) strings sent
as multipart text fields (`--form-string', so values are not
interpreted).  FORM-FILES is an alist of (NAME . PATH) file uploads.
JSON-BODY is a string sent on stdin as the request body.  TIMEOUT is
the maximum time in seconds.  CALLBACK receives (:ok BODY) or
\(:error MESSAGE)."
  (muesli--require-executable muesli-curl-command "HTTP requests")
  (let* ((config (when bearer
                   (with-file-modes #o600
                     (make-temp-file "muesli-curl-" nil ".conf"
                                     (format "header = %s\n"
                                             (muesli--curl-quote
                                              (concat "Authorization: Bearer "
                                                      bearer)))))))
         (args (append
                (list muesli-curl-command "-sS" "-X" "POST"
                      "-w" (concat muesli--http-marker "%{http_code}"))
                (when timeout (list "--max-time" (number-to-string timeout)))
                (when config (list "-K" config))
                (mapcan (lambda (f)
                          (list "--form-string" (format "%s=%s" (car f) (cdr f))))
                        form-fields)
                (mapcan (lambda (f)
                          (list "-F" (format "%s=@%s" (car f)
                                             (expand-file-name (cdr f)))))
                        form-files)
                (when json-body
                  (list "-H" "Content-Type: application/json"
                        "--data-binary" "@-"))
                (list url))))
    (muesli--run
     :name (or name "curl")
     :command args
     :stdin json-body
     :callback
     (lambda (code stdout stderr)
       (when config (ignore-errors (delete-file config)))
       (funcall callback (muesli--curl-result code stdout stderr))))))

(defun muesli--curl-result (code stdout stderr)
  "Turn curl's exit CODE, STDOUT and STDERR into (:ok BODY) or (:error MSG)."
  (let* ((pos (string-search muesli--http-marker stdout))
         (body (if pos (substring stdout 0 pos) stdout))
         (status (and pos (string-to-number
                           (substring stdout (+ pos (length muesli--http-marker)))))))
    (cond
     ((/= code 0)
      (list :error (format "curl exited with %d: %s" code (string-trim stderr))))
     ((or (null status) (>= status 400) (= status 0))
      (list :error (format "HTTP %s: %s" status
                           (truncate-string-to-width (string-trim body) 500))))
     (t (list :ok body)))))

(provide 'muesli-core)
;;; muesli-core.el ends here
