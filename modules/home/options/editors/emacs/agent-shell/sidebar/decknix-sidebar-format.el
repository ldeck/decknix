;;; decknix-sidebar-format.el --- Sidebar pure display helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, sidebar, format

;;; Commentary:
;;
;; Two pure display helpers extracted from the agent-shell heredoc:
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
;; The age-visible predicate references the
;; `decknix--sidebar-sessions-age-filter' global via dynamic
;; resolution (the heredoc owns the binding).

;;; Code:

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

(provide 'decknix-sidebar-format)
;;; decknix-sidebar-format.el ends here
