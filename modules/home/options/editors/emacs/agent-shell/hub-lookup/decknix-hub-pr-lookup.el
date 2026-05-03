;;; decknix-hub-pr-lookup.el --- Lookup PR status from hub data structures -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, lookup

;;; Commentary:
;;
;; One pure data-accessor extracted from the agent-shell heredoc:
;;
;;   `decknix--hub-pr-status-from-hub'  (URL -> normalised alist | nil)
;;
;; Walks two heredoc-resident defvars (`decknix--hub-wip',
;; `decknix--hub-reviews') and returns a flat status alist with
;; consistent shape across both source files (WIP PRs that I
;; authored vs. PRs that have requested my review).
;;
;; The function is pure given its inputs — it reads the two globals
;; via dynamic resolution, never writes them, and never performs I/O.
;; Tests bind those two globals via `let' to drive every code path.
;;
;; Returned alist always carries:
;;   kind (wip | review), state (always uppercase), draft (eq-t),
;;   ci-status, checks, updated_at, needs_reply, bot_pending,
;;   replies_to_me, title, mergeable.
;;
;; WIP variant additionally carries: merged_at, branch, review_decision.
;; Review variant additionally carries: my_review.

;;; Code:

(require 'decknix-agent-url-parse)

;; Forward declarations for the two heredoc-resident hub data globals.
(defvar decknix--hub-wip)
(defvar decknix--hub-reviews)

(defun decknix--hub-pr-status-from-hub (url)
  "Look up PR status from hub WIP and Reviews data only.
Returns an alist or nil if not found."
  (let ((parsed (decknix--agent-pr-parse-url url)))
    (when parsed
      (let ((full-repo (format "%s/%s" (nth 0 parsed) (nth 1 parsed)))
            (number (nth 2 parsed)))
        (catch 'found
          ;; Search WIP repos
          (dolist (repo-group (when decknix--hub-wip
                                (alist-get 'repos decknix--hub-wip)))
            (when (equal (alist-get 'repo repo-group) full-repo)
              (dolist (pr (alist-get 'prs repo-group))
                (when (equal (alist-get 'number pr) number)
                  (let* ((ci (alist-get 'ci pr))
                         (hub-checks (alist-get 'checks ci)))
                    (throw 'found
                           (list
                            ;; Origin file — lets callers distinguish
                            ;; PRs I authored (wip) from PRs I review (review).
                            (cons 'kind 'wip)
                            ;; Upcase state — hub JSON uses lowercase
                            ;; ("open") but display code expects "OPEN"
                            (cons 'state (upcase (or (alist-get 'state pr) "OPEN")))
                            ;; `draft' is orthogonal to `state' — GitHub
                            ;; models draft PRs as state=OPEN with a
                            ;; separate isDraft flag.  We preserve that
                            ;; so downstream state checks (deploys, CI
                            ;; gating) keep working, while renderers can
                            ;; surface the draft distinction.
                            (cons 'draft (eq (alist-get 'draft pr) t))
                            (cons 'ci-status (alist-get 'status ci))
                            (cons 'checks hub-checks)
                            (cons 'merged_at (alist-get 'merged_at pr))
                            (cons 'updated_at (alist-get 'updated pr))
                            (cons 'review_decision
                                  (alist-get 'review_decision pr))
                            (cons 'needs_reply (alist-get 'needs_reply pr))
                            (cons 'bot_pending (alist-get 'bot_pending pr))
                            (cons 'replies_to_me (alist-get 'replies_to_me pr))
                            (cons 'title (alist-get 'title pr))
                            (cons 'branch (alist-get 'branch pr))
                            (cons 'mergeable (alist-get 'mergeable pr)))))))))
          ;; Also search review requests (for subject PRs)
          (dolist (item (when decknix--hub-reviews
                          (alist-get 'items decknix--hub-reviews)))
            (when (and (equal (alist-get 'repo item) full-repo)
                       (equal (alist-get 'number item) number))
              (let* ((ci (alist-get 'ci item))
                     (hub-checks (alist-get 'checks ci)))
                (throw 'found
                       (list
                        (cons 'kind 'review)
                        (cons 'state "OPEN")
                        (cons 'draft (eq (alist-get 'draft item) t))
                        (cons 'ci-status (alist-get 'status ci))
                        (cons 'checks hub-checks)
                        (cons 'updated_at (alist-get 'created item))
                        (cons 'my_review (alist-get 'my_review item))
                        (cons 'needs_reply (alist-get 'needs_reply item))
                        (cons 'bot_pending (alist-get 'bot_pending item))
                        (cons 'replies_to_me (alist-get 'replies_to_me item))
                        (cons 'title (alist-get 'title item))
                        (cons 'mergeable (alist-get 'mergeable item)))))))
          nil)))))

(provide 'decknix-hub-pr-lookup)
;;; decknix-hub-pr-lookup.el ends here
