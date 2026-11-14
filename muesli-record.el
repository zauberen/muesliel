;;; muesli-record.el --- Audio recording for muesli  -*- lexical-binding: t; -*-

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

;; Records one or two tracks with a single ffmpeg process using the
;; segment muxer, so tracks stay time-aligned and stop together.  Each
;; track is written as 16 kHz mono 16-bit WAV chunks named
;; TRACK-NNNNN.wav.  A timer watches the directory: chunk N is complete
;; once chunk N+1 of the same track exists or the recorder has exited.
;;
;; Chunking strategy seam: `muesli-record--complete-chunks' is the only
;; place that decides which files are finished; `muesli-record-chunk-
;; offset-ms' the only place that maps a chunk to a meeting offset.  An
;; overlap or VAD based strategy would replace those two.
;;
;; The recorder itself is pluggable through `muesli-recorder-function'
;; so tests can drop pre-made WAV files into the directory instead.

;;; Code:

(require 'muesli-core)

(defcustom muesli-audio-directory
  (expand-file-name "audio" muesli-data-directory)
  "Directory under which each meeting gets its own audio directory."
  :type 'directory
  :group 'muesli)

(defcustom muesli-keep-audio nil
  "When nil, delete a meeting's audio after a successful summary."
  :type 'boolean
  :group 'muesli)

(defcustom muesli-chunk-seconds 30
  "Length in seconds of each recorded chunk sent for transcription."
  :type 'integer
  :group 'muesli)

(defcustom muesli-input-device "default"
  "Microphone source for recording.
A source name as listed by \"pactl list short sources\", or
\"default\".  May also be an alist mapping capture modes (`room',
`call', `hybrid', or t as fallback) to source names, e.g.

  ((room . \"alsa_input.usb-My_Omni_Mic-00.mono-fallback\")
   (t . \"default\"))"
  :type '(choice (string :tag "Source")
                 (alist :tag "Per mode" :key-type symbol :value-type string))
  :group 'muesli)

(defcustom muesli-system-device nil
  "Source capturing system audio (other call participants).
nil means the monitor source of the default output sink, resolved
when recording starts.  May be an alist per capture mode like
`muesli-input-device'."
  :type '(choice (const :tag "Monitor of default sink" nil)
                 (string :tag "Source")
                 (alist :tag "Per mode" :key-type symbol
                        :value-type (choice (const nil) string)))
  :group 'muesli)

(defcustom muesli-recorder-command
  '((gnu/linux . ("-f" "pulse" "-i" "%s")))
  "Per-platform ffmpeg input arguments, keyed by `system-type'.
Each value is a list of arguments that open one input; \"%s\" is
replaced by the device name.  The output side (16 kHz mono WAV
segments) is the same on every platform.  Add presets for
`darwin' (avfoundation) or `windows-nt' (dshow) here."
  :type '(alist :key-type symbol :value-type (repeat string))
  :group 'muesli)

(defcustom muesli-recorder-function #'muesli-record-ffmpeg
  "Function that starts a recorder.
Called with keyword arguments :directory, :tracks (a list of
\(TRACK-NAME . DEVICE)), :chunk-seconds and :on-exit (a function of
one argument, the exit description).  Must return a function that
stops the recorder when called with no argument, or kills it when
called with the argument `kill'.  Chunk files must be written into
the directory as TRACK-NNNNN.wav."
  :type 'function
  :group 'muesli)

(defcustom muesli-recorder-stop-timeout 10
  "Seconds to wait for the recorder to finish before killing it."
  :type 'integer
  :group 'muesli)

(defconst muesli-record--chunk-regexp
  "\\`\\([a-z]+\\)-\\([0-9]+\\)\\.wav\\'"
  "Matches chunk file names, capturing the track and chunk number.")

;;;; Devices

(defun muesli-record--pactl (&rest args)
  "Run pactl with ARGS and return its output lines, or nil on failure."
  (when (executable-find "pactl")
    (ignore-errors (apply #'process-lines "pactl" args))))

(defun muesli-record-default-monitor ()
  "Return the monitor source of the default output sink, or nil."
  (when-let* ((sink (car (muesli-record--pactl "get-default-sink"))))
    (concat (string-trim sink) ".monitor")))

(defun muesli-record-source-muted-p (device)
  "Return non-nil if PulseAudio/PipeWire source DEVICE is muted.
DEVICE \"default\" means the default source.  Returns nil when pactl
is unavailable or the answer is unknown."
  (let ((line (car (muesli-record--pactl
                    "get-source-mute"
                    (if (member device '(nil "default")) "@DEFAULT_SOURCE@" device)))))
    (and line (string-match-p "\\`Mute: *yes" (string-trim line)))))

(defun muesli-record-describe-device (device)
  "Return DEVICE with the actual default source name when it is \"default\"."
  (if (member device '(nil "default"))
      (format "default (%s)"
              (or (car (muesli-record--pactl "get-default-source")) "unknown"))
    device))

(defcustom muesli-silence-threshold-db -50
  "Peak level in dB below which a recorded chunk counts as silent.
The first chunk of each track is checked; a silent one triggers a
warning, which usually means a muted or wrong input device."
  :type 'number
  :group 'muesli)

(defun muesli-record-peak-db (file callback)
  "Measure the peak level of FILE with ffmpeg and call CALLBACK.
CALLBACK receives the max volume in dB as a number, or nil if it
could not be measured.  Runs asynchronously."
  (muesli--run
   :name "volumedetect"
   :command (list muesli-ffmpeg-command "-hide_banner" "-nostats" "-i" file
                  "-af" "volumedetect" "-f" "null" "-")
   :callback (lambda (_code _out err)
               (funcall callback
                        (cond
                         ((string-match "max_volume: *\\(-?[0-9.]+\\) dB" err)
                          (string-to-number (match-string 1 err)))
                         ((string-match-p "max_volume: *-inf" err) -1000)
                         (t nil))))))

(defun muesli-record-sources ()
  "Return the names of available PulseAudio/PipeWire sources."
  (delq nil (mapcar (lambda (line) (nth 1 (split-string line "\t")))
                    (muesli-record--pactl "list" "short" "sources"))))

(defun muesli-record-resolve-devices (mode)
  "Return the alist of (TRACK . DEVICE) to record for capture MODE."
  (let ((mic (or (muesli--mode-value muesli-input-device mode) "default")))
    (if (eq mode 'room)
        (list (cons "mic" mic))
      (let ((system (or (muesli--mode-value muesli-system-device mode)
                        (muesli-record-default-monitor)
                        (user-error "Cannot find the system audio monitor; set `muesli-system-device'"))))
        (list (cons "mic" mic) (cons "system" system))))))

;;;###autoload
(defun muesli-select-device (which &optional mode)
  "Choose the recording source for WHICH track, `mic' or `system'.
With a prefix argument, set it only for capture MODE.  The choice
is saved with `customize-save-variable'."
  (interactive
   (list (intern (completing-read "Track: " '("mic" "system") nil t nil nil "mic"))
         (when current-prefix-arg
           (intern (completing-read "Mode: " '("room" "call" "hybrid") nil t)))))
  (let* ((var (if (eq which 'system) 'muesli-system-device 'muesli-input-device))
         (sources (muesli-record-sources))
         (device (completing-read (format "Source for %s: " which)
                                  (cons "default" sources) nil nil))
         (old (symbol-value var))
         (value (if mode
                    (let ((alist (if (and (consp old) (consp (car old)))
                                     (copy-alist old)
                                   (list (cons t old)))))
                      (setf (alist-get mode alist) device)
                      alist)
                  device)))
    (customize-save-variable var value)
    (message "muesli: %s set to %S" var value)))

;;;; ffmpeg recorder

(defun muesli-record-ffmpeg-command (tracks chunk-seconds)
  "Return the ffmpeg command line recording TRACKS in CHUNK-SECONDS chunks.
TRACKS is a list of (TRACK-NAME . DEVICE)."
  (let ((input-args (or (alist-get system-type muesli-recorder-command)
                        (user-error "No recorder preset for %s in `muesli-recorder-command'"
                                    system-type)))
        (i -1))
    (append
     (list muesli-ffmpeg-command "-hide_banner" "-nostats" "-loglevel" "warning")
     (mapcan (lambda (track)
               (mapcar (lambda (a) (if (equal a "%s") (cdr track) a)) input-args))
             tracks)
     (mapcan (lambda (track)
               (setq i (1+ i))
               (list "-map" (format "%d:a" i)
                     "-ac" "1" "-ar" "16000" "-c:a" "pcm_s16le"
                     "-f" "segment"
                     "-segment_time" (number-to-string chunk-seconds)
                     "-segment_format" "wav"
                     "-reset_timestamps" "1"
                     (format "%s-%%05d.wav" (car track))))
             tracks))))

(cl-defun muesli-record-ffmpeg (&key directory tracks chunk-seconds on-exit)
  "Start ffmpeg recording TRACKS into DIRECTORY.
See `muesli-recorder-function' for CHUNK-SECONDS, ON-EXIT and the
return value."
  (muesli--require-executable muesli-ffmpeg-command "recording audio")
  (let* ((default-directory (file-name-as-directory directory))
         (log (get-buffer-create " *muesli-ffmpeg*"))
         (proc (make-process
                :name "muesli-ffmpeg"
                :command (muesli-record-ffmpeg-command tracks chunk-seconds)
                :buffer log
                :connection-type 'pipe
                :noquery t
                :sentinel (lambda (p event)
                            (unless (process-live-p p)
                              (muesli--log "ffmpeg %s" (string-trim event))
                              (funcall on-exit (string-trim event)))))))
    (with-current-buffer log (erase-buffer))
    (lambda (&optional how)
      (when (process-live-p proc)
        (if (eq how 'kill)
            (kill-process proc)
          ;; SIGINT lets ffmpeg finalize the last chunk.
          (interrupt-process proc)
          (run-at-time muesli-recorder-stop-timeout nil
                       (lambda ()
                         (when (process-live-p proc)
                           (muesli--log "ffmpeg did not stop, killing it")
                           (kill-process proc)))))))))

;;;; Chunk files

(defun muesli-record-parse-chunk-name (file)
  "Return (TRACK . CHUNK-NO) for chunk FILE name, or nil."
  (let ((name (file-name-nondirectory file)))
    (when (string-match muesli-record--chunk-regexp name)
      (cons (match-string 1 name) (string-to-number (match-string 2 name))))))

(defun muesli-record-chunk-files (directory)
  "Return chunk files in DIRECTORY as a list of (TRACK CHUNK-NO PATH).
Sorted by track then chunk number."
  (when (file-directory-p directory)
    (sort (delq nil
                (mapcar (lambda (f)
                          (when-let* ((p (muesli-record-parse-chunk-name f)))
                            (list (car p) (cdr p) (expand-file-name f directory))))
                        (directory-files directory nil "\\.wav\\'")))
          (lambda (a b) (if (equal (car a) (car b))
                            (< (nth 1 a) (nth 1 b))
                          (string< (car a) (car b)))))))

(defun muesli-record--complete-chunks (files finished)
  "Return the entries of FILES (see `muesli-record-chunk-files') that are complete.
A chunk is complete when a later chunk of the same track exists, or
when FINISHED is non-nil (the recorder has exited)."
  (if finished
      files
    (let ((max (make-hash-table :test #'equal)))
      (dolist (f files)
        (puthash (car f) (max (nth 1 f) (gethash (car f) max -1)) max))
      (seq-filter (lambda (f) (< (nth 1 f) (gethash (car f) max))) files))))

(defun muesli-record-wav-duration-ms (file)
  "Return the duration of WAV FILE in milliseconds, or nil if unreadable."
  (ignore-errors
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file nil 0 4096)
      (let ((u32 (lambda (pos)
                   (+ (char-after pos) (ash (char-after (+ pos 1)) 8)
                      (ash (char-after (+ pos 2)) 16) (ash (char-after (+ pos 3)) 24))))
            (byte-rate nil) (data-size nil) (data-start nil))
        (goto-char (point-min))
        (when (search-forward "fmt " nil t)
          (setq byte-rate (funcall u32 (+ (point) 12))))
        (goto-char (point-min))
        (when (search-forward "data" nil t)
          (setq data-start (+ (point) 3)
                data-size (funcall u32 (point))))
        (when (and byte-rate (> byte-rate 0) data-start)
          (let ((actual (- (file-attribute-size (file-attributes file)) data-start)))
            ;; Unfinalized headers carry 0 or 0xFFFFFFFF.
            (when (or (null data-size) (<= data-size 0) (> data-size actual))
              (setq data-size actual))
            (round (* 1000.0 data-size) byte-rate)))))))

(defun muesli-record-chunk-offset-ms (chunk-no chunk-seconds &optional previous-end-ms)
  "Return the meeting offset in ms of chunk CHUNK-NO.
PREVIOUS-END-MS, when known, is where the previous chunk of the same
track ended (its offset plus measured duration), which is more
accurate than the nominal CHUNK-NO * CHUNK-SECONDS because ffmpeg
cuts segments at packet boundaries."
  (or previous-end-ms (* chunk-no chunk-seconds 1000)))

;;;; Watching a recording

(cl-defun muesli-record-watch (&key directory on-chunk finished-p (interval 1))
  "Watch DIRECTORY and call ON-CHUNK for each newly completed chunk.
ON-CHUNK receives (TRACK CHUNK-NO PATH).  FINISHED-P is a function
returning non-nil once the recorder has exited, after which the
remaining chunks count as complete.  Returns a function that, when
called, stops the watcher after one last scan.  INTERVAL is the poll
period in seconds."
  (let* ((seen (make-hash-table :test #'equal))
         (scan (lambda (finished)
                 (dolist (f (muesli-record--complete-chunks
                             (muesli-record-chunk-files directory) finished))
                   (let ((key (cons (car f) (nth 1 f))))
                     (unless (gethash key seen)
                       (puthash key t seen)
                       (apply on-chunk f))))))
         (timer (run-at-time interval interval
                             (lambda ()
                               (condition-case err
                                   (funcall scan (funcall finished-p))
                                 (error (muesli--log "chunk watcher: %S" err)))))))
    (lambda ()
      (cancel-timer timer)
      (funcall scan t))))

;;;; Concatenation

(defun muesli-record-concat (directory track callback)
  "Concatenate TRACK's chunks in DIRECTORY into TRACK-full.wav.
CALLBACK receives (:ok PATH) or (:error MESSAGE)."
  (let* ((files (seq-filter (lambda (f) (equal (car f) track))
                            (muesli-record-chunk-files directory)))
         (out (expand-file-name (format "%s-full.wav" track) directory))
         (list-file (expand-file-name (format "%s-concat.txt" track) directory)))
    (if (null files)
        (funcall callback (list :error (format "No %s chunks to concatenate" track)))
      (with-temp-file list-file
        (dolist (f files)
          (insert (format "file '%s'\n"
                          (replace-regexp-in-string "'" "'\\\\''" (nth 2 f))))))
      (muesli--require-executable muesli-ffmpeg-command "concatenating audio")
      (muesli--run
       :name "concat"
       :command (list muesli-ffmpeg-command "-hide_banner" "-loglevel" "error" "-y"
                      "-f" "concat" "-safe" "0" "-i" list-file "-c" "copy" out)
       :callback (lambda (code _out err)
                   (ignore-errors (delete-file list-file))
                   (funcall callback
                            (if (= code 0)
                                (list :ok out)
                              (list :error (format "ffmpeg concat failed: %s"
                                                   (string-trim err))))))))))

(provide 'muesli-record)
;;; muesli-record.el ends here
