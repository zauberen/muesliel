;;; muesli-diarize.el --- Speaker diarization and naming for muesli  -*- lexical-binding: t; -*-

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

;; Diarization is not standardized across OpenAI-compatible servers, so
;; it sits behind an adapter: a function (FILE NUM-SPEAKERS CALLBACK)
;; that calls CALLBACK once with (:ok TURNS) or (:error MESSAGE), where
;; TURNS is a list of (SPEAKER-LABEL START-MS END-MS).
;;
;; Diarization runs once per multi-speaker track on the concatenated
;; full-length file, then every transcript segment is given the speaker
;; whose turns overlap it most (split by word timestamps when a segment
;; straddles two speakers).  Labels are namespaced by track, e.g.
;; "mic:SPEAKER_00".

;;; Code:

(require 'muesli-core)
(require 'muesli-db)

(defcustom muesli-diarization-backend 'none
  "How speakers are separated within a multi-speaker track.
`none'          no model diarization; speakers come from the track only.
`localai'       LocalAI's POST /audio/diarization endpoint.
`diarized-json' POST /audio/transcriptions with
                response_format=diarized_json (OpenAI style).
A function      a custom adapter (FILE NUM-SPEAKERS CALLBACK); see
                the commentary of muesli-diarize.el."
  :type '(choice (const :tag "None" none)
                 (const :tag "LocalAI /audio/diarization" localai)
                 (const :tag "diarized_json transcriptions" diarized-json)
                 (function :tag "Custom adapter"))
  :group 'muesli)

(defcustom muesli-diarization-base-url nil
  "Base URL of the diarization server; nil means `muesli-stt-base-url'."
  :type '(choice (const :tag "Same as speech-to-text" nil) string)
  :group 'muesli)

(defcustom muesli-diarization-model "parakeet-cpp-nemotron-3-diarization"
  "Diarization model name sent to the server."
  :type 'string
  :group 'muesli)

(defcustom muesli-diarization-api-key nil
  "API key for the diarization server; nil means `muesli-stt-api-key'."
  :type '(choice (const :tag "Same as speech-to-text" nil) string function)
  :group 'muesli)

(defcustom muesli-diarization-timeout 3600
  "Maximum seconds one diarization request may take."
  :type 'integer
  :group 'muesli)

(defcustom muesli-diarization-split-threshold 0.3
  "Share of a segment a second speaker must cover for the segment to split.
Splitting needs word timestamps; without them the majority speaker wins."
  :type 'number
  :group 'muesli)

(defcustom muesli-skip-naming nil
  "When non-nil, do not prompt for speaker names after diarization."
  :type 'boolean
  :group 'muesli)

(defcustom muesli-user-name user-full-name
  "Your name, used for the microphone track in `call' mode."
  :type 'string
  :group 'muesli)

(defcustom muesli-naming-samples 3
  "Number of sample utterances shown per speaker when naming speakers."
  :type 'integer
  :group 'muesli)

(defvar muesli-stt-base-url)
(defvar muesli-stt-api-key)

;;;; Adapters

(defun muesli-diarize--base-url ()
  "Return the diarization base URL without a trailing slash."
  (string-remove-suffix "/" (or muesli-diarization-base-url muesli-stt-base-url)))

(defun muesli-diarize--api-key ()
  "Return the diarization API key, if any."
  (muesli--resolve-secret (or muesli-diarization-api-key muesli-stt-api-key)))

(defun muesli-diarize-parse-turns (response)
  "Return (LABEL START-MS END-MS) turns from a JSON RESPONSE alist.
Understands the LocalAI and OpenAI diarized_json shapes: a `segments'
array whose items carry `speaker', `start' and `end' in seconds."
  (sort
   (delq nil
         (mapcar (lambda (s)
                   (let ((speaker (or (alist-get 'speaker s) (alist-get 'label s))))
                     (when (and speaker (alist-get 'start s) (alist-get 'end s))
                       (list (format "%s" speaker)
                             (muesli--seconds-to-ms (alist-get 'start s))
                             (muesli--seconds-to-ms (alist-get 'end s))))))
                 (alist-get 'segments response)))
   (lambda (a b) (< (nth 1 a) (nth 1 b)))))

(defun muesli-diarize--http (path fields file callback)
  "POST FILE with FIELDS to the diarization server at PATH.
CALLBACK receives (:ok TURNS) or (:error MESSAGE)."
  (muesli--curl
   :name "diarize"
   :url (concat (muesli-diarize--base-url) path)
   :bearer (muesli-diarize--api-key)
   :timeout muesli-diarization-timeout
   :form-files (list (cons "file" file))
   :form-fields fields
   :callback
   (lambda (result)
     (funcall callback
              (pcase result
                (`(:ok ,body)
                 (condition-case err
                     (list :ok (muesli-diarize-parse-turns (muesli--json-parse body)))
                   (error (list :error (format "Cannot parse diarization response: %s"
                                               (error-message-string err))))))
                (_ result))))))

(defun muesli-diarize-localai (file num-speakers callback)
  "Diarize FILE with LocalAI's /audio/diarization endpoint.
NUM-SPEAKERS, when non-nil, is the expected number of speakers.
CALLBACK receives (:ok TURNS) or (:error MESSAGE)."
  (muesli-diarize--http
   "/audio/diarization"
   (append (list (cons "model" muesli-diarization-model)
                 (cons "response_format" "json"))
           (when num-speakers
             (list (cons "num_speakers" (number-to-string num-speakers)))))
   file callback))

(defun muesli-diarize-diarized-json (file num-speakers callback)
  "Diarize FILE through /audio/transcriptions with diarized_json output.
NUM-SPEAKERS is ignored; this API takes no speaker count.  CALLBACK
receives (:ok TURNS) or (:error MESSAGE)."
  (ignore num-speakers)
  (muesli-diarize--http
   "/audio/transcriptions"
   (list (cons "model" muesli-diarization-model)
         (cons "response_format" "diarized_json")
         (cons "chunking_strategy" "auto"))
   file callback))

(defun muesli-diarize-adapter ()
  "Return the adapter function for `muesli-diarization-backend', or nil."
  (pcase muesli-diarization-backend
    ('none nil)
    ('localai #'muesli-diarize-localai)
    ('diarized-json #'muesli-diarize-diarized-json)
    ((pred functionp) muesli-diarization-backend)
    (other (user-error "Unknown `muesli-diarization-backend': %S" other))))

;;;; Assigning speakers to segments

(defun muesli-diarize--overlap (a1 a2 b1 b2)
  "Return the overlap in ms of intervals [A1, A2) and [B1, B2)."
  (max 0 (- (min a2 b2) (max a1 b1))))

(defun muesli-diarize--overlaps (start end turns)
  "Return ((LABEL . MS) ...) of how much each label in TURNS overlaps START to END.
Sorted by decreasing overlap."
  (let ((acc '()))
    (dolist (turn turns)
      (let ((o (muesli-diarize--overlap start end (nth 1 turn) (nth 2 turn))))
        (when (> o 0)
          (setf (alist-get (car turn) acc nil nil #'equal)
                (+ o (alist-get (car turn) acc 0 nil #'equal))))))
    (sort acc (lambda (a b) (> (cdr a) (cdr b))))))

(defun muesli-diarize--nearest (start end turns)
  "Return the label of the turn in TURNS closest to START to END, or nil."
  (car (car (sort (mapcar (lambda (turn)
                            (cons (car turn)
                                  (max 0 (- (nth 1 turn) end) (- start (nth 2 turn)))))
                          turns)
                  (lambda (a b) (< (cdr a) (cdr b)))))))

(defun muesli-diarize--label-at (start end turns)
  "Return the best label in TURNS for the interval from START to END."
  (or (car (car (muesli-diarize--overlaps start (max end (1+ start)) turns)))
      (muesli-diarize--nearest start end turns)))

(defun muesli-diarize-assign-segment (segment turns)
  "Return the pieces of SEGMENT with speakers assigned from TURNS.
SEGMENT is a plist with :start-ms, :end-ms, :text and :words (a list
of (START-MS END-MS WORD)).  The result is a list of such plists with
an added :speaker.  It has one element unless SEGMENT straddles two
speakers substantially and word timestamps allow splitting it."
  (let* ((start (plist-get segment :start-ms))
         (end (plist-get segment :end-ms))
         (words (plist-get segment :words))
         (overlaps (muesli-diarize--overlaps start end turns))
         (duration (max 1 (- end start)))
         (whole (lambda (label) (list (append (list :speaker label) segment)))))
    (cond
     ((null turns) (funcall whole nil))
     ((null overlaps) (funcall whole (muesli-diarize--nearest start end turns)))
     ((and (cdr overlaps)
           (>= (cdr (cadr overlaps)) (* muesli-diarization-split-threshold duration))
           (cdr words))
      (let ((pieces '()) (current nil))
        (dolist (w words)
          (let ((label (muesli-diarize--label-at (car w) (nth 1 w) turns)))
            (if (and current (equal (plist-get current :speaker) label))
                (setq current (plist-put (plist-put current :end-ms (nth 1 w))
                                         :words (cons w (plist-get current :words))))
              (when current (push current pieces))
              (setq current (list :speaker label :start-ms (car w) :end-ms (nth 1 w)
                                  :words (list w))))))
        (push current pieces)
        (if (cdr pieces)
            (nreverse
             (mapcar (lambda (p)
                       (let ((ws (reverse (plist-get p :words))))
                         (plist-put (plist-put p :words ws)
                                    :text (mapconcat (lambda (w) (nth 2 w)) ws " "))))
                     pieces))
          (funcall whole (car (car overlaps))))))
     (t (funcall whole (car (car overlaps)))))))

(defun muesli-diarize-apply (meeting-id track turns)
  "Label MEETING-ID's segments on TRACK using diarization TURNS.
Labels are prefixed with TRACK and registered in the speakers table."
  (let ((turns (mapcar (lambda (turn) (cons (concat track ":" (car turn)) (cdr turn)))
                       turns)))
    (dolist (seg (muesli-db-segments meeting-id track))
      (let* ((input (list :start-ms (plist-get seg :start_ms)
                          :end-ms (plist-get seg :end_ms)
                          :text (plist-get seg :text)
                          :words (plist-get seg :words)))
             (pieces (muesli-diarize-assign-segment input turns)))
        (if (null (cdr pieces))
            (muesli-db-segment-set-speaker (plist-get seg :id)
                                           (plist-get (car pieces) :speaker))
          (muesli-db-segment-delete (plist-get seg :id))
          (dolist (p pieces)
            (muesli-db-segment-add meeting-id track (plist-get seg :chunk_no)
                                   (plist-get p :start-ms) (plist-get p :end-ms)
                                   (plist-get p :text) (plist-get p :speaker)
                                   (plist-get p :words))))))
    (dolist (label (delete-dups
                    (delq nil (mapcar (lambda (s) (plist-get s :speaker))
                                      (muesli-db-segments meeting-id track)))))
      (muesli-db-speaker-add meeting-id label))))

(defun muesli-diarize-label-track (meeting-id track label &optional name)
  "Give every segment of TRACK in MEETING-ID the speaker LABEL.
Used for single-speaker tracks.  NAME is the speaker's display name."
  (muesli-db--execute "UPDATE segments SET speaker = ? WHERE meeting_id = ? AND track = ?"
                      (list label meeting-id track))
  (muesli-db-speaker-add meeting-id label name))

;;;; Display names

(defun muesli-speaker-names (meeting-id)
  "Return a hash table mapping MEETING-ID's speaker labels to display names.
Unnamed speakers become \"Speaker 1\", \"Speaker 2\"... in order of
first appearance."
  (let ((table (make-hash-table :test #'equal))
        (n 0))
    (dolist (sp (muesli-db-speakers meeting-id))
      (puthash (plist-get sp :label)
               (or (plist-get sp :name) (format "Speaker %d" (cl-incf n)))
               table))
    table))

;;;; Naming step

(defun muesli-diarize--samples (meeting-id label)
  "Return up to `muesli-naming-samples' utterance strings by LABEL in MEETING-ID."
  (mapcar (lambda (row)
            (format "[%s] %s" (muesli--format-clock (nth 0 row)) (nth 1 row)))
          (sqlite-select
           (muesli-db)
           "SELECT start_ms, text FROM segments WHERE meeting_id = ? AND speaker = ?
             ORDER BY length(text) DESC LIMIT ?"
           (list meeting-id label muesli-naming-samples))))

(defun muesli-diarize-name-speakers (meeting-id &optional attendees)
  "Prompt for a name for each speaker detected in MEETING-ID.
ATTENDEES is a list of names offered for completion, along with
names used in earlier meetings.  Empty input keeps the generic label.
Returns non-nil if any speakers were prompted for."
  (let* ((speakers (muesli-db-speakers meeting-id))
         (generic (muesli-speaker-names meeting-id))
         (candidates (delete-dups (append (copy-sequence attendees)
                                          (muesli-db-known-speaker-names))))
         (buffer (get-buffer-create "*muesli speakers*")))
    (when speakers
      (unwind-protect
          (dolist (sp speakers)
            (let ((label (plist-get sp :label)))
              (with-current-buffer buffer
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (insert (propertize (format "%s  (%s)\n\n" (gethash label generic) label)
                                      'face 'bold))
                  (dolist (s (muesli-diarize--samples meeting-id label))
                    (insert s "\n\n"))
                  (goto-char (point-min))
                  (special-mode)))
              (display-buffer buffer '((display-buffer-reuse-window
                                        display-buffer-below-selected)
                                       (window-height . fit-window-to-buffer)))
              (let ((name (string-trim
                           (completing-read
                            (format "Name for %s (empty keeps generic): "
                                    (gethash label generic))
                            candidates nil nil nil nil (plist-get sp :name)))))
                (muesli-db-speaker-rename meeting-id label
                                          (unless (string-empty-p name) name))
                (unless (string-empty-p name)
                  (setq candidates (delete name candidates))))))
        (when-let* ((win (get-buffer-window buffer)))
          (quit-window t win)))
      t)))

(provide 'muesli-diarize)
;;; muesli-diarize.el ends here
