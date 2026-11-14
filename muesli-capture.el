;;; muesli-capture.el --- Capture template and target for muesli  -*- lexical-binding: t; -*-

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

;; The meeting capture template and its `file+function' target.
;; Meetings live under a top-level "* Meetings" heading, grouped by
;; category (level 2), one meeting per level 3 heading:
;;
;;   * Meetings
;;   ** Team Sync
;;   *** [2026-11-13 Fri] Weekly planning
;;
;; `muesli-capture' let-binds its own `org-capture-templates', so the
;; user's global templates are never modified.

;;; Code:

(require 'org)
(require 'org-capture)
(require 'org-id)
(require 'muesli-core)

(defcustom muesli-meetings-file
  (expand-file-name "meetings.org" org-directory)
  "Org file that meeting headings are captured into."
  :type 'file
  :group 'muesli)

(defcustom muesli-capture-template
  "*** %u %(org-capture-get :meeting-title)\n%?"
  "Body of the meeting capture template (a `plain' template).
The title chosen in the prompt is available as
%(org-capture-get :meeting-title).  The heading gets an :ID:
automatically; there is no need to add one here."
  :type 'string
  :group 'muesli)

(defcustom muesli-capture-template-properties nil
  "Extra properties for the meeting capture template.
A plist such as (:empty-lines-after 1), appended to the template
entry as described in `org-capture-templates'."
  :type '(plist :value-type sexp)
  :group 'muesli)

(defcustom muesli-auto-start nil
  "When non-nil, start recording as soon as a meeting capture is finalized."
  :type 'boolean
  :group 'muesli)

(declare-function muesli-start "muesli")

(defun muesli-capture-find-category ()
  "Locate category, prompt for title, and position point at the end of it.
This is the `file+function' target of the meeting template.  It
prompts for a category (level 2 under \"* Meetings\") and a title,
stores the title as :meeting-title for the template, and leaves
point where the new entry belongs."
  (widen)
  (goto-char (point-min))

  ;; 1. Ensure top-level '* Meetings' exists
  (unless (re-search-forward "^\\* +Meetings\\b" nil t)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert "* Meetings\n")
    (goto-char (point-min))
    (re-search-forward "^\\* +Meetings\\b" nil t))

  ;; Record where the '* Meetings' block ends
  (org-back-to-heading t)
  ;; A marker, so it stays correct after a new category is inserted at
  ;; the end of '* Meetings' (a plain position would go stale there and
  ;; make the bounded searches below fail).
  (let ((meetings-end (copy-marker (save-excursion (org-end-of-subtree t t)) t))
        (categories '()))

    ;; 2. Collect existing Level 2 subheadings under '* Meetings'
    (save-excursion
      (while (re-search-forward "^\\*\\* +\\(.+\\)$" meetings-end t)
        (push (org-trim (match-string-no-properties 1)) categories)))
    (setq categories (nreverse categories))

    ;; 3. Prompt for category
    (let* ((choice (completing-read
                    "Meeting category: "
                    categories nil nil nil nil
                    (or (car categories) "Unsorted Meetings")))
           (target-cat (if (string-blank-p choice) "Unsorted Meetings" choice)))

      ;; 4. Move to or create the Level 2 category
      (goto-char (point-min))
      (re-search-forward "^\\* +Meetings\\b" nil t)
      (let ((pattern (concat "^\\*\\* +" (regexp-quote target-cat) "[ \t]*$")))
        (if (re-search-forward pattern meetings-end t)
            (org-back-to-heading t)
          ;; Missing: insert at the very end of '* Meetings'
          (goto-char meetings-end)
          (unless (bolp) (insert "\n"))
          (insert "** " target-cat "\n")
          (forward-line -1)
          (org-back-to-heading t)))

      ;; 5. Collect existing Level 3 titles under THIS category
      (let* ((cat-end (save-excursion
                        (forward-line 1)
                        ;; Find boundary: the next ** heading or the end
                        ;; of * Meetings.
                        (if (re-search-forward "^\\*\\*? " meetings-end t)
                            (match-beginning 0)
                          meetings-end)))
             (titles '()))
        (save-excursion
          (while (re-search-forward "^\\*\\*\\* +\\(?:\\[[^]]+\\] +\\)?\\(.+\\)$" cat-end t)
            (push (org-trim (match-string-no-properties 1)) titles)))
        (setq titles (delete-dups (nreverse titles)))

        ;; 6. Prompt for Title
        (let ((chosen-title (completing-read "Meeting Title: " titles nil nil nil nil nil)))
          (org-capture-put :meeting-title chosen-title))

        ;; 7. Land point right before next heading, cleanly after existing notes
        (goto-char cat-end)
        (skip-chars-backward " \t\n")
        (insert "\n\n")))))

(defun muesli-capture--ensure-id ()
  "Give the meeting heading in the capture buffer an :ID:."
  (save-excursion
    (goto-char (point-min))
    (when (or (org-at-heading-p)
              (re-search-forward org-heading-regexp nil t))
      (org-back-to-heading t)
      (org-id-get-create))))

(defun muesli-capture--after-finalize ()
  "Start recording the captured meeting when `muesli-auto-start' is set."
  (when (and muesli-auto-start
             (not org-note-abort)
             (marker-buffer org-capture-last-stored-marker))
    (with-current-buffer (marker-buffer org-capture-last-stored-marker)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char org-capture-last-stored-marker)
          (muesli-start))))))

(defun muesli-capture-templates ()
  "Return the capture template list used by `muesli-capture'."
  `(("m" "Meeting" plain
     (file+function muesli-meetings-file muesli-capture-find-category)
     ,muesli-capture-template
     :hook muesli-capture--ensure-id
     :after-finalize muesli-capture--after-finalize
     ,@muesli-capture-template-properties)))

;;;###autoload
(defun muesli-capture ()
  "Capture a new meeting heading into `muesli-meetings-file'."
  (interactive)
  (let ((org-capture-templates (muesli-capture-templates))
        (org-capture-templates-contexts nil))
    (org-capture nil "m")))

(provide 'muesli-capture)
;;; muesli-capture.el ends here
