;;; decknix-sidebar-format.el --- Sidebar pure display helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, sidebar, format

;;; Commentary:
;;
;; Pure display helpers extracted from the agent-shell heredoc:
;;
;;   `decknix--sidebar-abbreviate-workspace'
;;     (path -> compact string for sidebar display: applies
;;      `abbreviate-file-name' then keeps only the last path
;;      component when it can match `/(...)/?$', falls back to the
;;      abbreviated form otherwise; nil becomes "?")
;;
;;   `decknix--sidebar-session-age-visible-p'
;;     (modified-iso-string -> non-nil when the entry passes the
;;      sessions age filter.  The filter is gated by the global
;;      `decknix--sidebar-sessions-age-filter' (seconds; nil = off).
;;      Malformed timestamps that error during parse default to t,
;;      keeping the entry visible — the filter is intentionally
;;      lenient to avoid hiding sessions over a parsing glitch.)
;;
;;   `decknix--sidebar-render-section-header'
;;     (TITLE [SECTION-ID] -> insert " TITLE\n" with `bold' applied
;;      and an optional `decknix-sidebar-section' text property over
;;      the visible span.  Composed via `add-face-text-property' so
;;      callers can pre-propertize sub-regions of TITLE — e.g. a
;;      coloured age badge — and the bold layer doesn't wipe them.)
;;
;;   `decknix--sidebar-render-key-group'
;;     (LABEL KEYS-alist -> insert a vertical key/desc table headed
;;      by LABEL.  Keys take `font-lock-keyword-face', descriptions
;;      take `font-lock-comment-face', LABEL takes `bold'.)
;;
;;   `decknix--sidebar-render-key-group-inline'
;;     (LABEL KEYS-alist -> same as above but on a single line, with
;;      `·' separators between key·desc pairs.)
;;
;;   `decknix--sidebar-render-key-groups-side-by-side'
;;     (LEFT-LABEL LEFT-KEYS RIGHT-LABEL RIGHT-KEYS COL-WIDTH ->
;;      render two key groups in two columns, each COL-WIDTH chars
;;      wide.  Pads the shorter group with empty rows so both
;;      headers line up at the top.)
;;
;; The age-visible predicate references the
;; `decknix--sidebar-sessions-age-filter' global via dynamic
;; resolution (the heredoc owns the binding).
;;
;; The render helpers all `insert' into the current buffer; tests
;; capture output via `with-temp-buffer' and assert both the visible
;; text (via `buffer-substring-no-properties') and selected face
;; spans (via `get-text-property').

;;; Code:

(require 'cl-lib)
(require 'iso8601)

;; Forward declaration for the heredoc-resident toggle global.
(defvar decknix--sidebar-sessions-age-filter)

(defun decknix--sidebar-abbreviate-workspace (path)
  "Abbreviate PATH for sidebar display."
  (if (null path) "?"
    (let ((abbr (abbreviate-file-name path)))
      ;; Extract last path component for compact display
      (if (string-match "/\\([^/]+\\)/?$" abbr)
          (match-string 1 abbr)
        abbr))))

(defun decknix--sidebar-session-age-visible-p (modified)
  "Return non-nil if MODIFIED passes the sessions age filter.
Always t when the filter is nil (show all).  MODIFIED may be nil
\(e.g. malformed session files); such entries are kept when the
filter is off and dropped when a cutoff is active."
  (cond
   ((null decknix--sidebar-sessions-age-filter) t)
   ((null modified) nil)
   (t (condition-case nil
          (let* ((then (encode-time (iso8601-parse modified)))
                 (age (float-time (time-subtract (current-time) then))))
            (<= age decknix--sidebar-sessions-age-filter))
        (error t)))))

;; -- Sidebar render: section headers + key-help groups --

(defun decknix--sidebar-render-section-header (title &optional section-id)
  "Insert a section header TITLE into the sidebar.
Composes `bold' with any inner face properties on TITLE so callers
can propertize sub-regions (e.g. a coloured age badge) without the
header's bold wiping them.
SECTION-ID, when non-nil, is attached as the `decknix-sidebar-section'
text property over the visible header span so the unified sidebar
dispatcher (specs/sidebar-ret.md §3.4) can route RET to the matching
picker / transient."
  (let ((start (point)))
    (insert " " title "\n")
    ;; (1- (point)) excludes the trailing newline from the face span
    (add-face-text-property start (1- (point)) 'bold)
    (when section-id
      (put-text-property start (1- (point))
                         'decknix-sidebar-section section-id))))

(defun decknix--sidebar-render-key-group (label keys)
  "Insert a group LABEL header and KEYS alist as vertical key lines."
  (insert (propertize (format " %s" label) 'face 'bold) "\n")
  (dolist (kv keys)
    (insert (propertize (format " %3s " (car kv))
                        'face 'font-lock-keyword-face)
            (propertize (cdr kv)
                        'face 'font-lock-comment-face)
            "\n")))

(defun decknix--sidebar-render-key-group-inline (label keys)
  "Insert group LABEL then KEYS alist as a compact horizontal line.
Format: LABEL  k·desc  k·desc  k·desc"
  (insert (propertize (format " %s " label) 'face 'bold))
  (let ((first t))
    (dolist (kv keys)
      (unless first (insert " "))
      (setq first nil)
      (insert (propertize (car kv) 'face 'font-lock-keyword-face)
              (propertize "·" 'face 'font-lock-comment-face)
              (propertize (cdr kv) 'face 'font-lock-comment-face))))
  (insert "\n"))

(defun decknix--sidebar-render-key-groups-side-by-side (left-label left-keys
                                                         right-label right-keys
                                                         col-width)
  "Render LEFT and RIGHT key groups in two columns.
Each column is COL-WIDTH chars wide.  LEFT group is padded on the right
so RIGHT group starts at column COL-WIDTH."
  ;; Build lists of formatted lines for each group
  ;; N.B. must use let* — max-rows depends on left-lines and right-lines
  (let* ((left-lines
          (cons (propertize (format " %s" left-label) 'face 'bold)
                (mapcar (lambda (kv)
                          (concat
                           (propertize (format " %3s " (car kv))
                                       'face 'font-lock-keyword-face)
                           (propertize (cdr kv)
                                       'face 'font-lock-comment-face)))
                        left-keys)))
         (right-lines
          (cons (propertize (format " %s" right-label) 'face 'bold)
                (mapcar (lambda (kv)
                          (concat
                           (propertize (format " %3s " (car kv))
                                       'face 'font-lock-keyword-face)
                           (propertize (cdr kv)
                                       'face 'font-lock-comment-face)))
                        right-keys)))
         (max-rows (max (length left-lines) (length right-lines))))
    ;; Pad shorter list
    (while (< (length left-lines) max-rows)
      (setq left-lines (append left-lines (list ""))))
    (while (< (length right-lines) max-rows)
      (setq right-lines (append right-lines (list ""))))
    ;; Render side by side
    (cl-mapc
     (lambda (l r)
       (let* ((l-visible (length (substring-no-properties l)))
              (pad (max 1 (- col-width l-visible))))
         (insert l (make-string pad ?\s) r "\n")))
     left-lines right-lines)))

(provide 'decknix-sidebar-format)
;;; decknix-sidebar-format.el ends here
