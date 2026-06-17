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
(require 'decknix-hub-mention-bot)

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
  ◐ = review required (green), (none) = no review policy."
  (let ((decision (alist-get 'review_decision pr)))
    (pcase decision
      ("APPROVED"          (decknix--hub-icon "●" 'success))
      ("CHANGES_REQUESTED" (decknix--hub-icon "◐" 'error))
      ("REVIEW_REQUIRED"   (decknix--hub-icon "◐" 'success))
      (_ ""))))

(defun decknix--hub-primary-status-icon (item kind &optional tc-status)
  "Return a primary status icon for ITEM of KIND.
KIND is one of `wip', `review', `placeholder', or `done'.
OPTIONAL TC-STATUS is a TeamCity build alist.
Follows the shape-family system: ○ ★ ◐ ● ▣ ■ plus bot icon π.
Incorporates CI and mergeable status into the primary signal to
reduce sidebar duplication."
  (let* ((state (alist-get 'state item))
         (author (alist-get 'author item))
         (is-bot (decknix--hub-bot-author-p author))
         (draft (eq (alist-get 'draft item) t))
         (ci (alist-get 'ci item))
         (mergeable (alist-get 'mergeable item))
         (conflicting (equal mergeable "CONFLICTING"))
         (classified (decknix--hub-ci-classify ci))
         (tc-fail (member (alist-get 'status tc-status) '("FAILURE" "ERROR")))
         (tc-running (string= (alist-get 'state tc-status) "running"))
         (decision (cond ((eq kind 'wip) (alist-get 'review_decision item))
                         ((eq kind 'review) (alist-get 'my_review item))
                         (t nil))))
    (cond
     (is-bot
      (decknix--hub-icon "π" '(:foreground "#af5f87"))) ;; Bot author (pinkish)
     ((eq kind 'placeholder)
      (decknix--hub-icon "○" 'shadow))
     ((string= state "MERGED")
      (decknix--hub-icon "■" 'success))
     ((string= state "CLOSED")
      (decknix--hub-icon "■" 'shadow))
     (conflicting
      (decknix--hub-icon "▣" 'error))
     (draft
      (let ((face (pcase classified
                    ("pass"      'success)
                    ("running"   'warning)
                    ("fail"      'error)
                    ("soft_fail" '(:foreground "orange" :weight bold))
                    (_           'shadow))))
        (decknix--hub-icon "★" face)))
     (t
      ;; Open PR: combine CI and Review status
      (let* ((approved (equal decision "APPROVED"))
             (blocked (or (equal decision "CHANGES_REQUESTED")
                          (equal classified "fail")
                          tc-fail))
             (ci-running (or (equal classified "running")
                             tc-running))
             ;; Phase 2.1: REVIEW_REQUIRED is green if everything else is green
             ;; (i.e. not blocked and not running CI).
             (awaiting (equal decision "REVIEW_REQUIRED"))
             (face (cond (blocked    'error)
                         (ci-running 'warning)
                         (approved   'success)
                         (awaiting   'success)
                         ((equal decision "COMMENTED") '(:foreground "cyan" :weight bold))
                         (t          'shadow)))
             (glyph (if approved "●" "◐")))
        (decknix--hub-icon glyph face))))))

(defun decknix--hub-activity-icons (pr)
  "Return concatenated attention icons for PR.

Indicates two families of signals (Human and Bot).
Human family (left slot):
- 📬 (replies-to-me) when a human posted after one of my own comments.
- 💬 (needs-reply) when the latest activity is a human and not me.
Bot family (right slot):
- 👽 (bot-replies-to-me) when a bot replied after my comment.
- 🤖 (bot-pending) when the latest activity is a bot.

Activity icons are suppressed for APPROVED PRs.

Thread-aware Tier 1 suppression: when `total_threads' is present and
greater than zero, human icons (📬/💬) are suppressed if `unresolved_threads'
equals zero (all threads resolved). Bot icons (👽/🤖) are not suppressed.

Returns a string of length 2 (padded with spaces) if any activity is present,
else an empty string."
  (let* ((needs-reply       (eq (alist-get 'needs_reply pr) t))
         (bot-pending       (eq (alist-get 'bot_pending pr) t))
         (replies-to-me     (eq (alist-get 'replies_to_me pr) t))
         (bot-replies-to-me (eq (alist-get 'bot_replies_to_me pr) t))
         ;; Use both possible decision fields
         (decision          (or (alist-get 'review_decision pr)
                                (alist-get 'my_review pr)))
         (approved          (equal decision "APPROVED"))
         ;; Thread-aware suppression: suppress human 📬/💬 when all inline
         ;; threads are resolved.  Only applies when total_threads > 0
         ;; so PRs with only PR-level comments fall back to stream logic.
         (total-threads     (alist-get 'total_threads pr))
         (unresolved        (alist-get 'unresolved_threads pr))
         (all-resolved      (and total-threads
                                 (> total-threads 0)
                                 unresolved
                                 (= unresolved 0))))
    (if approved
        ""
      (let ((h (if all-resolved
                   ""
                 (cond (replies-to-me (decknix--hub-icon "📬" '(:foreground "#87d7af" :weight bold)))
                       ((and needs-reply (not bot-pending)) (decknix--hub-icon "💬" '(:foreground "#d7af5f")))
                       (t ""))))
            (b (cond (bot-replies-to-me (decknix--hub-icon "👽" '(:foreground "#af5f87" :weight bold)))
                     (bot-pending (decknix--hub-icon "🤖" '(:foreground "#af5f87")))
                     (t ""))))
        (if (and (string-empty-p h) (string-empty-p b))
            ""
          (concat (if (string-empty-p h) " " h)
                  (if (string-empty-p b) " " b)))))))

(defun decknix--hub-wip-reply-icon (pr)
  "Back-compat shim: return `decknix--hub-activity-icons' for PR."
  (decknix--hub-activity-icons pr))

(defun decknix--hub-format-row-label (pr &optional tc-status)
  "Return a human-readable state label for PR.
OPTIONAL TC-STATUS is a TeamCity build alist."
  (let* ((state (alist-get 'state pr))
         (draft (eq (alist-get 'draft pr) t))
         (ci (alist-get 'ci pr))
         (mergeable (alist-get 'mergeable pr))
         (classified (decknix--hub-ci-classify ci))
         (decision (or (alist-get 'review_decision pr)
                       (alist-get 'my_review pr)))
         (tc-fail (member (alist-get 'status tc-status) '("FAILURE" "ERROR")))
         (tc-running (string= (alist-get 'state tc-status) "running")))
    (cond
     ((string= state "MERGED") "merged")
     ((string= state "CLOSED") "closed")
     ((equal mergeable "CONFLICTING") "merge conflict")
     (draft "drafting")
     ((or tc-fail (equal classified "fail")) "CI failing")
     ((or tc-running (equal classified "running")) "CI running")
     ((equal decision "CHANGES_REQUESTED") "changes requested")
     ((equal decision "APPROVED") "approved")
     ((equal decision "REVIEW_REQUIRED") "awaiting review")
     (t "open"))))

(provide 'decknix-hub-icons)
;;; decknix-hub-icons.el ends here
