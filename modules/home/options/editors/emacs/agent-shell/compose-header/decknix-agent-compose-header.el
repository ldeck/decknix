;;; decknix-agent-compose-header.el --- Compose header-line builder -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, compose

;;; Commentary:
;;
;; Pure builder for the compose-buffer header-line (PR B.74),
;; carved out of main-bulk so the propertized list of segments
;; can be exercised in ERT against an explicit STICKY input.
;;
;; The compose-mode header is intentionally separate from the
;; unified `decknix--header-build' (PR B.65) used for agent-shell
;; buffers -- it advertises compose-mode-local keys (M-p / M-n
;; cycle, M-r search, C-c actions) rather than busy-state /
;; tags / workspace.
;;
;; Public surface:
;;
;;   `decknix--compose-build-header-line' STICKY -> propertized list
;;
;; The interactive `decknix--compose-update-header-line' wrapper
;; that calls `setq-local' on the result stays in main-bulk per
;; AGENTS.md Rule 2.

;;; Code:

(defun decknix--compose-build-header-line (sticky)
  "Build the propertized header-line list for a compose buffer.
STICKY is a boolean: when non-nil the header shows the sticky
state with the constant face; otherwise it shows the inactive
state with the comment face.  Always advertises the C-c action
prefix and the M-p/M-n/M-r history keys."
  (list
   (propertize
    (if sticky " ● Compose [sticky]" " ○ Compose")
    'font-lock-face (if sticky
                        'font-lock-constant-face
                      'font-lock-comment-face))
   (propertize "  " 'font-lock-face 'font-lock-comment-face)
   (propertize "C-c" 'font-lock-face 'font-lock-keyword-face)
   (propertize " actions  " 'font-lock-face 'font-lock-comment-face)
   (propertize "M-p" 'font-lock-face 'font-lock-keyword-face)
   (propertize "/" 'font-lock-face 'font-lock-comment-face)
   (propertize "M-n" 'font-lock-face 'font-lock-keyword-face)
   (propertize " cycle  " 'font-lock-face 'font-lock-comment-face)
   (propertize "M-r" 'font-lock-face 'font-lock-keyword-face)
   (propertize " search" 'font-lock-face 'font-lock-comment-face)))

(provide 'decknix-agent-compose-header)

;;; decknix-agent-compose-header.el ends here
