;;; decknix-hub-wt-stale.el --- Worktree staleness facts for the sidebar -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, worktree

;;; Commentary:
;;
;; `decknix wt audit --json' computes `merged' and `orphan' per worktree from
;; git alone, with no network call.  The sidebar could not reach it: placeholder
;; rows come from the worktree registry, which carries no such flags, and the
;; placeholder render path is deliberately disk-free so it cannot shell out per
;; row.
;;
;; So the audit is cached like every other hub fact, and read from the cache on
;; the render path.  Nil means "unknown", never "not stale", so a row is shown
;; until something proves it can be hidden.
;;
;; Two guards exist because either would lose work: a DIRTY worktree is never
;; stale even when merged, and a worktree with an ACTIVE session is never stale
;; whatever its PR state.

;;; Code:

(require 'json)
(require 'subr-x)

(defcustom decknix-hub-wt-hide-stale t
  "When non-nil, omit provably stale worktrees from the sidebar.
Stale means merged or orphaned per `decknix wt audit', with no live session
and no uncommitted changes."
  :type 'boolean
  :group 'decknix)

(defcustom decknix-hub-wt-audit-ttl 300
  "Seconds before the cached worktree audit is refreshed."
  :type 'integer
  :group 'decknix)

(defvar decknix--hub-wt-facts (make-hash-table :test 'equal)
  "Absolute worktree path -> plist (:merged :orphan :active :dirty).")

(defvar decknix--hub-wt-facts-ts nil
  "`float-time' of the last completed audit, or nil.")

(defvar decknix--hub-wt-audit-pending nil
  "Non-nil while an audit subprocess is in flight.")


;; --- pure layers ------------------------------------------------------

(defun decknix--hub-wt-stale-p (facts)
  "Return non-nil when FACTS describe a worktree safe to hide.

Nil for nil FACTS: an unknown worktree is shown, because a row the user can
see is recoverable and a silently dropped one looks already pruned.

A dirty worktree is never stale even when merged -- hiding uncommitted work
is how it gets lost -- and a worktree with a live session is never stale
whatever its PR state, because the session is the reason it exists."
  (and facts
       (not (plist-get facts :dirty))
       (not (plist-get facts :active))
       (or (plist-get facts :merged)
           (plist-get facts :orphan))
       t))

(defun decknix--hub-wt-parse-audit (json-string)
  "Return ((ABS-PATH . FACTS) ...) parsed from JSON-STRING.

Returns nil when the payload cannot be parsed or carries no repos, which is
treated as \"no facts yet\" rather than \"nothing is stale\".  Primary
checkouts are skipped: they are not worktrees to prune, and a repo reports
its own primary alongside them."
  (let ((report (ignore-errors
                  (json-parse-string json-string
                                     :object-type 'alist
                                     :array-type 'list
                                     :null-object nil
                                     :false-object nil))))
    (when (listp report)
      (let (out)
        (dolist (repo report)
          (let ((primary (alist-get 'primary repo)))
            (dolist (wt (alist-get 'worktrees repo))
              (let ((path (alist-get 'path wt)))
                (when (and path
                           (not (and primary
                                     (string=
                                      (file-name-as-directory
                                       (expand-file-name path))
                                      (file-name-as-directory
                                       (expand-file-name primary))))))
                  (push (cons (expand-file-name path)
                              (list :merged (and (alist-get 'merged wt) t)
                                    :orphan (and (alist-get 'orphan wt) t)
                                    :active (and (alist-get 'active wt) t)
                                    :dirty (and (alist-get 'dirty wt) t)
                                    :repo (alist-get 'repo repo)
                                    :branch (alist-get 'branch wt)
                                    :path path
                                    :age (alist-get 'age_days wt)))
                        out))))))
        (nreverse out)))))


;; --- cache ------------------------------------------------------------

(defun decknix--hub-wt-facts-for (path)
  "Return cached staleness facts for PATH, or nil when unknown."
  (and path (gethash (expand-file-name path) decknix--hub-wt-facts)))

(defun decknix--hub-wt-hidden-p (path)
  "Return non-nil when PATH should be omitted from the sidebar."
  (and decknix-hub-wt-hide-stale
       (decknix--hub-wt-stale-p (decknix--hub-wt-facts-for path))))

(defun decknix--hub-wt-facts-stale-cache-p ()
  "Return non-nil when the cached audit is older than its TTL."
  (or (null decknix--hub-wt-facts-ts)
      (> (- (float-time) decknix--hub-wt-facts-ts)
         decknix-hub-wt-audit-ttl)))

(defun decknix--hub-wt-audit-refresh (&optional on-done)
  "Refresh the worktree audit cache asynchronously.
Calls ON-DONE with the number of worktrees recorded, if supplied.  A second
call while one is in flight is a no-op, so a busy render cannot queue a
subprocess per paint."
  (unless decknix--hub-wt-audit-pending
    (setq decknix--hub-wt-audit-pending t)
    (let ((buffer (generate-new-buffer " *decknix-wt-audit*")))
      (make-process
       :name "decknix-wt-audit"
       :buffer buffer
       :noquery t
       :command '("decknix" "wt" "audit" "--json")
       :sentinel
       (lambda (_proc event)
         (when (string-match-p "\\`\\(finished\\|exited\\|deleted\\|failed\\)" event)
           (setq decknix--hub-wt-audit-pending nil)
           (let ((recorded 0))
             (when (buffer-live-p buffer)
               (let ((facts (decknix--hub-wt-parse-audit
                             (with-current-buffer buffer (buffer-string)))))
                 (when facts
                   (clrhash decknix--hub-wt-facts)
                   (dolist (entry facts)
                     (puthash (car entry) (cdr entry) decknix--hub-wt-facts)
                     (setq recorded (1+ recorded)))
                   (setq decknix--hub-wt-facts-ts (float-time))))
               (kill-buffer buffer))
             (when on-done (funcall on-done recorded)))))))))

(defun decknix--hub-wt-audit-refresh-if-stale ()
  "Kick off an audit refresh when the cache has aged out."
  (when (decknix--hub-wt-facts-stale-cache-p)
    (decknix--hub-wt-audit-refresh)))

(defun decknix-hub-wt-stale-paths ()
  "Return the absolute paths of every cached worktree that is stale."
  (let (paths)
    (maphash (lambda (path facts)
               (when (decknix--hub-wt-stale-p facts) (push path paths)))
             decknix--hub-wt-facts)
    (sort paths #'string<)))

(defun decknix-hub-wt-rows ()
  "Return every cached worktree record, newest audit first.

The picker renders from this rather than shelling out: a synchronous
`decknix wt audit --json' per paint froze Emacs, and every filter toggle
calls `revert-buffer', so each keystroke paid for a fresh subprocess."
  (let (rows)
    (maphash (lambda (_path facts) (push facts rows)) decknix--hub-wt-facts)
    rows))

(defun decknix-hub-wt-cache-ready-p ()
  "Return non-nil when an audit has completed at least once."
  (and decknix--hub-wt-facts-ts
       (> (hash-table-count decknix--hub-wt-facts) 0)))

(defun decknix-hub-wt-toggle-hide-stale ()
  "Toggle whether provably stale worktrees are hidden from the sidebar."
  (interactive)
  (setq decknix-hub-wt-hide-stale (not decknix-hub-wt-hide-stale))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (ignore-errors (agent-shell-workspace-sidebar-refresh)))
  (message "Hide stale worktrees: %s (%d currently stale)"
           (if decknix-hub-wt-hide-stale "on" "off")
           (length (decknix-hub-wt-stale-paths))))

(provide 'decknix-hub-wt-stale)
;;; decknix-hub-wt-stale.el ends here
