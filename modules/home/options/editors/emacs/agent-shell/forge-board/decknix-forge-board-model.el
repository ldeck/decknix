;;; decknix-forge-board-model.el --- Forge Board grouping -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: git, repos, board

;;; Commentary:
;;
;; Pure model for the Forge Board: every repo the sweep found a problem with,
;; placed in exactly one lane so a sweep's worth of them can be acted on in
;; bulk.
;;
;; The board exists because the sidebar's row menu is one repo at a time.  A
;; sweep that cannot reach the network fails every repo at once -- measured 11
;; at once -- and clearing those through a per-row prompt is 11 interactions
;; for one cause.
;;
;; Lanes, in render order, which is mechanically-fixable first:
;;
;;   lock      an abandoned index.lock -- the one kind with a mechanical remedy
;;   failed    the sync errored; a retry may well be all it needs
;;   diverged  local and origin have both moved; only a human can choose
;;   dirty     uncommitted work; only a human can decide what to keep
;;
;; `lock' and `failed' lead because a bulk verb can finish them.  `diverged'
;; and `dirty' are last for the same reason the Session Board puts cleanup
;; last: everything above can be resolved from here, everything below needs
;; you to go and look.
;;
;; Side-effecting render, marks and the bulk verbs live in the board layer
;; per AGENTS.md Rule 2.

;;; Code:

(require 'seq)
(require 'subr-x)

(defconst decknix-forge-board-lanes '(lock failed diverged dirty)
  "Lanes in render order, mechanically-fixable first.")

(defconst decknix-forge-board-lane-titles
  '((lock     . "Stale Locks")
    (failed   . "Sync Failed")
    (diverged . "Diverged")
    (dirty    . "Dirty"))
  "Human-readable lane titles.")

(defconst decknix-forge-board-lane-hints
  '((lock     . "abandoned index.lock -- clearable from here")
    (failed   . "sync errored -- a retry may be enough")
    (diverged . "local and origin both moved -- your call")
    (dirty    . "uncommitted work -- nothing here will touch it"))
  "One-line explanation per lane, shown beside the count.

Carried here rather than in the render because a lane the user cannot
explain is a lane they will not trust enough to run a bulk verb from.
The `dirty' hint states what the board will NOT do, since that is the
lane where a destructive verb would be most tempting and most costly.")

(defun decknix-forge-board-lane-title (lane)
  "Return the display title for LANE."
  (or (alist-get lane decknix-forge-board-lane-titles) (format "%s" lane)))

(defun decknix-forge-board-lane-hint (lane)
  "Return the one-line hint for LANE."
  (or (alist-get lane decknix-forge-board-lane-hints) ""))

;; --- which lanes a bulk verb may touch -------------------------------

(defconst decknix-forge-board-clearable-lanes '(lock)
  "Lanes whose rows `clear locks' may act on.

Only `lock'.  Clearing is the remedy for an abandoned lock and nothing
else: offering it on a dirty repo would imply deleting a lock recovers
uncommitted work, and on a failed row there is usually no lock at all.")

(defconst decknix-forge-board-retryable-lanes '(lock failed diverged dirty)
  "Lanes whose rows `retry sync' may act on.

Every lane: a re-sync is read-only with respect to local work -- the
sweep never force-updates a dirty or diverged repo, it only fetches --
so retrying one can correct a stale row without risking anything.")

(defun decknix-forge-board-clearable-p (row)
  "Return non-nil when `clear lock' applies to ROW."
  (and (memq (plist-get row :kind) decknix-forge-board-clearable-lanes) t))

(defun decknix-forge-board-retryable-p (row)
  "Return non-nil when `retry sync' applies to ROW."
  (and (memq (plist-get row :kind) decknix-forge-board-retryable-lanes) t))

(defun decknix-forge-board-filter-clearable (rows)
  "Return the subset of ROWS `clear lock' applies to."
  (seq-filter #'decknix-forge-board-clearable-p rows))

;; --- rows -------------------------------------------------------------

(defun decknix-forge-board-row (problem)
  "Return a board row plist for PROBLEM, one entry of the sweep report."
  (list :kind (plist-get problem :kind)
        :name (plist-get problem :name)
        :path (plist-get problem :path)
        :detail (plist-get problem :detail)
        :problem problem))

(defun decknix-forge-board-row-key (row)
  "Return a stable identity for ROW.

The repo PATH, not its name: two clones of the same repo in different
worktree directories share a name, and a mark keyed on the name would
act on whichever the re-render happened to order first."
  (plist-get row :path))

(defun decknix-forge-board-group (problems)
  "Return (LANE . ROWS) pairs for PROBLEMS, in lane order.

Lanes with no repos are omitted: an empty heading is noise in a board
whose whole purpose is to show what is there."
  (let ((by-lane (make-hash-table :test 'eq)))
    (dolist (p problems)
      (let ((kind (plist-get p :kind)))
        (when (memq kind decknix-forge-board-lanes)
          (puthash kind
                   (cons (decknix-forge-board-row p) (gethash kind by-lane))
                   by-lane))))
    (delq nil
          (mapcar (lambda (lane)
                    (when-let ((rows (gethash lane by-lane)))
                      (cons lane (decknix-forge-board-sort-rows rows))))
                  decknix-forge-board-lanes))))

(defun decknix-forge-board-sort-rows (rows)
  "Return ROWS by name, so a re-render cannot reorder under a mark."
  (sort (copy-sequence rows)
        (lambda (a b) (string< (or (plist-get a :name) "")
                               (or (plist-get b :name) "")))))

;; --- labels -----------------------------------------------------------

(defun decknix-forge-board-row-label (row marked-p width)
  "Return the rendered line for ROW, padded to exactly WIDTH.

The detail is truncated rather than allowed to push the name off the
end: the name is what a bulk verb will report acting on, so it is the
part that must survive a narrow window."
  (let* ((name (or (plist-get row :name) "?"))
         (detail (or (plist-get row :detail) ""))
         ;; 2 for the mark, 2 for the gap before the detail.
         (room (max 1 (- width 2 (string-width name) 2)))
         (detail (if (> (string-width detail) room)
                     (concat (truncate-string-to-width detail (max 1 (1- room)))
                             "…")
                   detail))
         (left (format "%s %s" (if marked-p "*" " ") name))
         (pad (max 1 (- width (string-width left) (string-width detail)))))
    (concat left (make-string pad ?\s) detail)))

(defun decknix-forge-board-lane-header (lane rows width)
  "Return the heading line for LANE holding ROWS, padded to WIDTH."
  (let* ((left (format " %s (%d)" (decknix-forge-board-lane-title lane)
                        (length rows)))
         (right (decknix-forge-board-lane-hint lane))
         (pad (max 1 (- width (string-width left) (string-width right)))))
    (concat left (make-string pad ?\s) right)))

(defun decknix-forge-board-summary (groups)
  "Return a one-line tally across GROUPS, or nil when there are none."
  (when groups
    (string-join
     (mapcar (lambda (g)
               (format "%d %s" (length (cdr g))
                       (decknix-forge-board-lane-title (car g))))
             groups)
     " · ")))

(provide 'decknix-forge-board-model)
;;; decknix-forge-board-model.el ends here
