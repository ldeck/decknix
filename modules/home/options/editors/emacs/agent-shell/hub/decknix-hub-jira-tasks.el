;;; decknix-hub-jira-tasks.el --- Hub Jira task rendering helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, jira

;;; Commentary:
;;
;; Pure helpers for the Tasks (Jira) hub sidebar section.
;;
;;   * `decknix--hub-task-status-icon' — single-glyph status badge for
;;     Jira workflow states.  Maps `In Progress' / `Code Review' /
;;     `Blocked' / `Ready' to coloured propertized strings; anything
;;     else falls through to a dim middle-dot.
;;
;; The full `decknix--hub-render-tasks' renderer (which inserts text
;; into the sidebar buffer and is therefore impure / heredoc-bound)
;; stays in the heredoc.  This module is intentionally tiny so the
;; status-icon mapping can be characterised in isolation before the
;; renderer itself is touched.

;;; Code:

(defun decknix--hub-task-status-icon (status)
  "Return an icon string for Jira STATUS."
  (pcase (downcase (or status ""))
    ("in progress"
     (propertize "●" 'face '(:foreground "#61afef")))
    ("code review"
     (propertize "◐" 'face '(:foreground "#c678dd")))
    ("blocked"
     (propertize "✕" 'face '(:foreground "#e06c75")))
    ("ready"
     (propertize "○" 'face '(:foreground "#98c379")))
    (_
     (propertize "·" 'face 'font-lock-comment-face))))

(provide 'decknix-hub-jira-tasks)
;;; decknix-hub-jira-tasks.el ends here
