;;; decknix-agent-review-capture.el --- Review exchange capture -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, review

;;; Commentary:
;;
;; Capture-exchange helper for the inline review buffer (PR B.73),
;; carved out of main-bulk so the buffer-resolution + history-
;; extractor wiring can be exercised in ERT against a stubbed
;; session id.
;;
;; Public surface:
;;
;;   `decknix--agent-review-capture-exchange'  source-buf x N
;;     -> oldest-first list of (USER-MSG . ASSISTANT-RESP), or nil.
;;
;; The interactive `decknix-agent-review' / `-cancel' /
;; `-flag-followup' / `-list-followups' / `-add-collaborator' entry
;; points stay in main-bulk per AGENTS.md Rule 2 -- they own
;; minor-mode setup, kill-buffer ops, and the read-only preamble
;; insertion.

;;; Code:

;; Forward declarations -- carved siblings.
(declare-function decknix--agent-buffer-session-id
                  "decknix-agent-buffer-lookup")
(declare-function decknix--agent-session-extract-history
                  "decknix-agent-session-history" (sid n))

(defun decknix--agent-review-capture-exchange (source-buffer n)
  "Return the last N exchanges from SOURCE-BUFFER's session, oldest first.
Each exchange is (USER-MSG . ASSISTANT-RESP).  Returns nil on failure."
  (with-current-buffer source-buffer
    (when-let ((sid (decknix--agent-buffer-session-id)))
      (decknix--agent-session-extract-history sid n))))

(provide 'decknix-agent-review-capture)

;;; decknix-agent-review-capture.el ends here
