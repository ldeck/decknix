;;; decknix-hub-icons.el --- Hub PR review/activity icons + age formatter -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, format, icons

;;; Commentary:
;;
;; Pure formatters + propertize-only icon helpers extracted from the
;; agent-shell heredoc.  Five symbols across two clusters that share
;; the `decknix--hub-icon' emoji-shim from `decknix-hub-ci' for
;; consistent line-height across mixed glyph rendering:
;;
;; -- age formatter --
;;
;;   `decknix--hub-format-age'         (ISO -> compact "Nd" / "Nh" /
;;                                      "Nm" / "now" / "?")
;;
;; -- icon decoders --
;;
;;   `decknix--hub-review-icon'        (item -> review state glyph
;;                                      for PRs I am reviewing)
;;   `decknix--hub-wip-review-icon'    (pr -> review-decision glyph
;;                                      for PRs I authored)
;;   `decknix--hub-activity-icons'     (pr -> 🤖 / 💬 / ↩ stack
;;                                      based on bot/needs-reply/
;;                                      replies-to-me flags)
;;   `decknix--hub-wip-reply-icon'     (defalias-style shim
;;                                      preserving the legacy name)
;;
;; All five take alists and return strings (possibly with text
;; properties); no I/O, no global state.  `format-age' reads
;; `(current-time)' for the delta — tests stub it via `cl-letf'.

;;; Code:

(require 'iso8601)
(require 'decknix-hub-ci)

(defun decknix--hub-format-age (iso-time)
  "Format an ISO timestamp as a compact age string (e.g. 3d, 5h, 12m)."
  (if (and iso-time (stringp iso-time))
      (let* ((then (condition-case nil
                       (encode-time (iso8601-parse iso-time))
                     (error nil)))
             (secs (when then
                     (float-time (time-subtract (current-time) then)))))
        (cond
         ((null secs) "?")
         ((>= secs 86400) (format "%dd" (truncate (/ secs 86400))))
         ((>= secs 3600) (format "%dh" (truncate (/ secs 3600))))
         ((>= secs 60) (format "%dm" (truncate (/ secs 60))))
         (t "now")))
    "?"))

(defun decknix--hub-review-icon (item)
  "Return a review state icon for ITEM, or empty string if none.
Shows whether the current user has already responded to this PR.
  ◐ = commented (cyan), ● = approved (green), ◐ = changes requested (red)."
  (let ((state (alist-get 'my_review item)))
    (pcase state
      ("APPROVED"          (decknix--hub-icon "●" 'success))
      ("CHANGES_REQUESTED" (decknix--hub-icon "◐" 'error))
      ("COMMENTED"         (decknix--hub-icon "◐" '(:foreground "cyan" :weight bold)))
      ("DISMISSED"         (decknix--hub-icon "−" 'shadow))
      ("PENDING"           (decknix--hub-icon "…" 'warning))
      (_ ""))))

(defun decknix--hub-wip-review-icon (pr)
  "Return a review decision icon for a WIP PR, or empty string.
Shows the overall review status of the user's own PR:
  ● = approved (green), ◐ = changes requested (red),
  ◐ = review required (yellow), (none) = no review policy."
  (let ((decision (alist-get 'review_decision pr)))
    (pcase decision
      ("APPROVED"          (decknix--hub-icon "●" 'success))
      ("CHANGES_REQUESTED" (decknix--hub-icon "◐" 'error))
      ("REVIEW_REQUIRED"   (decknix--hub-icon "◐" 'warning))
      (_ ""))))

(defun decknix--hub-primary-status-icon (item kind)
  "Return a primary status icon for ITEM of KIND.
KIND is one of 'wip, 'review, 'placeholder, or 'done.
Follows the shape-family system: ○ ★ ◐ ● ▣ ■."
  (let* ((state (alist-get 'state item))
         (draft (eq (alist-get 'draft item) t))
         (ci (alist-get 'ci item))
         (classified (decknix--hub-ci-classify ci))
         (decision (cond ((eq kind 'wip) (alist-get 'review_decision item))
                         ((eq kind 'review) (alist-get 'my_review item))
                         (t nil))))
    (cond
     ((eq kind 'placeholder)
      (decknix--hub-icon "○" 'shadow))
     ((string= state "MERGED")
      (decknix--hub-icon "■" 'success))
     ((string= state "CLOSED")
      (decknix--hub-icon "■" 'shadow))
     (draft
      (let ((face (pcase classified
                    ("pass"      'success)
                    ("running"   'warning)
                    ("fail"      'error)
                    ("soft_fail" '(:foreground "orange" :weight bold))
                    (_           'shadow))))
        (decknix--hub-icon "★" face)))
     ((equal decision "APPROVED")
      (decknix--hub-icon "●" 'success))
     ((member decision '("CHANGES_REQUESTED" "REVIEW_REQUIRED" "COMMENTED"))
      (let ((face (cond ((equal decision "CHANGES_REQUESTED") 'error)
                        ((equal decision "COMMENTED")         '(:foreground "cyan" :weight bold))
                        (t                                    'warning))))
        (decknix--hub-icon "◐" face)))
     (t
      ;; Open PR, no decision yet
      (decknix--hub-icon "◐" 'shadow)))))

(defun decknix--hub-activity-icons (pr)
  "Return concatenated attention icons for PR.

Shows, in order:
- 🤖 (bot-pending) when the latest comment/review is from a bot —
  supersedes 💬 so the two aren't shown together for the same event.
- 💬 (needs-reply) when the latest non-bot activity is from someone
  else and no bot posted after them.
- ↩ (replies-to-me) when a human posted after one of my own comments
  or reviews; co-exists with 🤖/💬 because it is a distinct signal
  about a thread I participated in."
  (let ((needs-reply   (eq (alist-get 'needs_reply pr) t))
        (bot-pending   (eq (alist-get 'bot_pending pr) t))
        (replies-to-me (eq (alist-get 'replies_to_me pr) t)))
    (concat
     (cond
      (bot-pending
       (decknix--hub-icon "🤖" '(:foreground "#af5f87")))
      (needs-reply
       (decknix--hub-icon "💬" '(:foreground "#d7af5f")))
      (t ""))
     (if replies-to-me
         (decknix--hub-icon "↩" '(:foreground "#87d7af" :weight bold))
       ""))))

(defun decknix--hub-wip-reply-icon (pr)
  "Back-compat shim: return `decknix--hub-activity-icons' for PR."
  (decknix--hub-activity-icons pr))

(provide 'decknix-hub-icons)
;;; decknix-hub-icons.el ends here
