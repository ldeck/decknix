;;; decknix-agent-review-submit.el --- Review buffer route handlers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-review-format "0.1"))
;; Keywords: agent, review, submit, decknix

;;; Commentary:
;;
;; The submit/route layer of `decknix-agent-review-mode' carved out
;; of `decknix-agent-shell-main' (main-bulk) into the existing
;; `agent-shell/review/' cluster.  Owns one defvar + five route
;; helpers; the interactive entry point
;; `decknix-agent-review-submit' (bound to `C-c C-c' in
;; review-mode) stays in main-bulk and dispatches into this module.
;;
;;   `decknix-agent-review-jira-drafts-dir'
;;       Directory the `j' route writes Jira draft markdown files
;;       to.  Defaults to `~/.config/decknix/review-jira-drafts/'.
;;
;;   `decknix--agent-review-content-for-route'
;;       Pure transform: returns the review buffer content shaped
;;       for ROUTE.  The agent route strips the `🧭 review meta'
;;       header (the agent already has the raw exchange in its
;;       history); other routes return the full buffer.
;;
;;   `decknix--agent-review-submit-to-agent'
;;       Sends CONTENT back to the source agent-shell as a new
;;       prompt.  Reuses the compose editor's busy-prompt dance —
;;       prompts for [i]nterrupt / [q]ueue / [c]ancel when the
;;       agent process is mid-turn.
;;
;;   `decknix--agent-review-submit-pr'
;;       Copies CONTENT to the kill-ring for pasting into a GitHub
;;       PR review comment.
;;
;;   `decknix--agent-review-submit-jira'
;;       Writes CONTENT to a fresh markdown file under
;;       `decknix-agent-review-jira-drafts-dir', creating the dir
;;       on demand.  Filename format: `review-YYYYMMDD-HHMMSS.md'.
;;
;;   `decknix--agent-review-submit-file'
;;       Prompts for a path and writes CONTENT to it.

;;; Code:

(require 'decknix-agent-review-format)

;; Buffer-local source-buffer pointer set by `decknix-agent-review'
;; in main-bulk; the carved code only reads it.
(defvar decknix--agent-review-source-buffer)

;; External (shell-maker / agent-shell / compose) -- forward declared
;; so byte-compile stays warning-clean.  All of these resolve at
;; runtime in the daemon's load-path.
(declare-function shell-maker-submit "ext:shell-maker" (&rest args))
(defvar shell-maker--busy)
(declare-function agent-shell-interrupt "ext:agent-shell" ())
(defvar agent-shell-confirm-interrupt)
(declare-function decknix--compose-enqueue-prompt
                  "decknix-agent-shell-main" (target content))

(defvar decknix-agent-review-jira-drafts-dir
  (expand-file-name "~/.config/decknix/review-jira-drafts")
  "Directory where the `j' route writes Jira draft markdown files.")

(defun decknix--agent-review-content-for-route (route)
  "Return the review buffer content appropriate for ROUTE.
ROUTE is one of `agent', `pr', `jira', `file'."
  (let ((raw (buffer-string)))
    (pcase route
      ('agent
       ;; Agent already has the raw exchange in its history — strip
       ;; the review-meta header but keep the instructions block
       ;; (it tells the agent how to respond).
       (decknix--agent-review-strip-meta raw))
      (_
       ;; Other routes want the full buffer (meta + instructions +
       ;; annotations) for human consumption.
       raw))))

(defun decknix--agent-review-submit-to-agent (content)
  "Send CONTENT to the source agent-shell as a new prompt.
Handles the busy-prompt dance the same way the compose editor does."
  (let ((target decknix--agent-review-source-buffer)
        (action 'submit))
    (unless (buffer-live-p target)
      (user-error "Source agent-shell buffer is gone"))
    (unless (and (get-buffer-process target)
                 (process-live-p (get-buffer-process target)))
      (user-error "Agent process not running — restart with C-c A a"))
    (when (with-current-buffer target
            (bound-and-true-p shell-maker--busy))
      (let ((choice (read-char-choice
                     "Agent busy: [i]nterrupt & submit  [q]ueue  [c]ancel "
                     '(?i ?q ?c))))
        (pcase choice
          (?c (user-error "Submit cancelled"))
          (?q (setq action 'queue))
          (?i
           (with-current-buffer target
             (when (fboundp 'agent-shell-interrupt)
               (let ((agent-shell-confirm-interrupt nil))
                 (agent-shell-interrupt))))
           (sit-for 0.3)))))
    (pcase action
      ('queue
       (when (fboundp 'decknix--compose-enqueue-prompt)
         (decknix--compose-enqueue-prompt target content))
       (message "Queued review for agent"))
      ('submit
       (with-current-buffer target
         (goto-char (point-max))
         (shell-maker-submit :input content))
       (pop-to-buffer target)
       (message "Review sent to %s" (buffer-name target))))))

(defun decknix--agent-review-submit-pr (content)
  "Copy CONTENT to the kill-ring for pasting into a PR comment."
  (kill-new content)
  (message "Review copied to kill-ring (%d chars)" (length content)))

(defun decknix--agent-review-submit-jira (content)
  "Save CONTENT as a Jira draft markdown file."
  (make-directory decknix-agent-review-jira-drafts-dir t)
  (let* ((id (format-time-string "%Y%m%d-%H%M%S"))
         (file (expand-file-name
                (format "review-%s.md" id)
                decknix-agent-review-jira-drafts-dir)))
    (with-temp-file file
      (insert content))
    (message "Jira draft written: %s" (abbreviate-file-name file))))

(defun decknix--agent-review-submit-file (content)
  "Save CONTENT to a user-chosen file."
  (let ((file (read-file-name "Save review to: ")))
    (when (and file (not (string-empty-p file)))
      (with-temp-file file
        (insert content))
      (message "Review saved: %s" (abbreviate-file-name file)))))

(provide 'decknix-agent-review-submit)
;;; decknix-agent-review-submit.el ends here
