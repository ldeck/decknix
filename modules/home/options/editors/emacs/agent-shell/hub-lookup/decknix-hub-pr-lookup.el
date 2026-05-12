;;; decknix-hub-pr-lookup.el --- Lookup PR status from hub data structures -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, lookup

;;; Commentary:
;;
;; Two pure data-accessors extracted from the agent-shell heredoc:
;;
;;   `decknix--hub-pr-status-from-hub'  (URL -> normalised alist | nil)
;;   `decknix--hub-pr-cache-get'        (URL -> cached alist + (stale . t)
;;                                        marker on TTL miss | nil)
;;
;; The first walks `decknix--hub-wip' / `decknix--hub-reviews' (live
;; hub data); the second walks `decknix--hub-pr-cache' (the offline
;; mirror used when the daemon hasn't yet fetched a per-PR view).
;; Both are side-effect free by design — TTL-triggered refresh is
;; the responsibility of the heredoc-resident `decknix--hub-pr-status'
;; orchestrator, not of these accessors.
;;
;; status-from-hub returned alist always carries:
;;   kind (wip | review), state (always uppercase), draft (eq-t),
;;   ci-status, checks, updated_at, needs_reply, bot_pending,
;;   replies_to_me, total_threads, unresolved_threads, title, mergeable.
;; WIP variant additionally carries: merged_at, branch, review_decision.
;; Review variant additionally carries: my_review.
;;
;; cache-get returns the cached alist verbatim when fresh, or the
;; same alist with `(stale . t)' appended when older than TTL.

;;; Code:

(require 'decknix-agent-url-parse)

;; Forward declarations for the heredoc-resident hub data globals.
(defvar decknix--hub-wip)
(defvar decknix--hub-reviews)
(defvar decknix--hub-pr-cache)
(defvar decknix--hub-pr-cache-ttl)

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
                            (cons 'total_threads (alist-get 'total_threads pr))
                            (cons 'unresolved_threads
                                  (alist-get 'unresolved_threads pr))
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
                        (cons 'total_threads (alist-get 'total_threads item))
                        (cons 'unresolved_threads
                              (alist-get 'unresolved_threads item))
                        (cons 'title (alist-get 'title item))
                        (cons 'mergeable (alist-get 'mergeable item)))))))
          nil)))))

(defun decknix--hub-pr-cache-get (url)
  "Return cached status for URL if still valid, else nil.
When the entry is stale (older than TTL) returns the cached data with
a `(stale . t)' marker appended so callers can show the old data with
a refresh indicator instead of a bare loading spinner.

This function is side-effect free by design.  Staleness-triggered
background refresh is the responsibility of `decknix--hub-pr-status'
(which TTL-gates its self-heal branch) so that callers invoking
`decknix--hub-pr-cache-get' from hot paths — e.g. sort predicates in
`decknix--hub-render-session-prs' — do not schedule O(N log N) async
fetches per render (see commit message for #hub-loop)."
  (let ((entry (gethash url decknix--hub-pr-cache)))
    (when entry
      (let ((ts (car entry))
            (status (cdr entry)))
        (if (< (- (float-time) ts) decknix--hub-pr-cache-ttl)
            status
          (append status '((stale . t))))))))

(provide 'decknix-hub-pr-lookup)
;;; decknix-hub-pr-lookup.el ends here
