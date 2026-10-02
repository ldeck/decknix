;;; decknix-session-assoc.el --- What a session is actually working on -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, sessions, worktrees

;;; Commentary:
;;
;; Associates a session with the WORKTREES it is working in, observed from the
;; file paths its tool calls touch, rather than inferred from its name.
;;
;; The sidebar previously guessed from session tags: a tag naming a repo
;; claimed that repo's worktrees and PRs.  Two things were wrong with that.
;; It is repo-granular, so it cannot express "this session is on two
;; worktrees of one repo and one of another"; and it is a name, so it claims
;; work the session never touched while missing work it did.  Measured on a
;; live session tagged `helix/nix/rea-integration': it had edited files in 39
;; worktrees across FOUR repos, and the tag named one of them.  The
;; platform-cli PR it was actually working on appeared nowhere.
;;
;; Observation alone is not enough either, and the same measurement shows
;; why: a session alive for two months touches everything eventually.  39
;; worktrees is as useless as one wrong one.  So the set is RECENCY-BOUNDED,
;; counted in turns:
;;
;;     last  20 turns ->  2 worktrees   <- the work in hand
;;     last  80 turns ->  7
;;     last 160 turns -> 20
;;
;; Turns rather than wall-clock because a session idle overnight has not
;; changed what it is working on, and a busy hour can move through several
;; worktrees.
;;
;; Paths resolve to the LONGEST matching known worktree, so a file inside
;; `platform-cli-worktrees/CONN-1040' is attributed to that worktree and not
;; to `platform-cli' -- which is the whole point of being worktree-granular.
;;
;; Pure here; capture at notification time and persistence live in the
;; wiring layer per AGENTS.md Rule 2.

;;; Code:

(require 'seq)
(require 'subr-x)

(defcustom decknix-session-assoc-window 20
  "How many turns back a session's worktree association reaches.

Measured on a live two-month-old session: 20 turns yielded the 2
worktrees it was actually working in, 80 yielded 7, and 160 yielded 20.
The whole history yielded 39 across four repos, which is no more useful
than the wrong single repo the tag named."
  :type 'integer
  :group 'decknix)

;; --- path -> worktree -------------------------------------------------

(defun decknix-session-assoc-resolve (path roots)
  "Return the entry of ROOTS that PATH lies within, or nil.

ROOTS is a list of directory paths.  The LONGEST match wins: a file in
`platform-cli-worktrees/CONN-1040' must attribute to that worktree rather
than to `platform-cli', and a plain prefix test would pick whichever came
first in the list."
  (when (and (stringp path) roots)
    (let ((best nil) (best-len -1))
      (dolist (root roots)
        (when (and (stringp root) (not (string-empty-p root)))
          (let* ((dir (file-name-as-directory root))
                 (len (length dir)))
            (when (and (> len best-len) (string-prefix-p dir path))
              (setq best root best-len len)))))
      best)))

(defun decknix-session-assoc-paths-of (update)
  "Return the file paths an ACP session UPDATE reports touching.

Reads `locations', which is where `tool_call' and `tool_call_update'
carry them."
  (let ((locs (alist-get 'locations update)))
    (delq nil
          (mapcar (lambda (loc)
                    (and (listp loc)
                         (let ((p (alist-get 'path loc)))
                           (and (stringp p) (not (string-empty-p p)) p))))
                  (if (listp locs) locs nil)))))

;; --- the recency-bounded set ------------------------------------------

(defun decknix-session-assoc-touch (assoc root turn)
  "Return ASSOC with ROOT recorded as touched at TURN.

ASSOC is an alist of (ROOT . LAST-TURN).  Only the most recent turn per
root is kept: the count of touches is not interesting, and keeping a list
of them would grow without bound in exactly the long-lived sessions this
exists to handle."
  (if (null root)
      assoc
    (cons (cons root turn)
          (seq-remove (lambda (cell) (equal (car cell) root)) assoc))))

(defun decknix-session-assoc-active (assoc turn &optional window)
  "Return the roots in ASSOC touched within WINDOW turns of TURN.

Sorted most-recent first, so the sidebar shows the work in hand at the
top of a session's subtree."
  (let ((window (or window decknix-session-assoc-window)))
    (mapcar #'car
            (sort (seq-filter (lambda (cell) (> (cdr cell) (- turn window)))
                              (copy-sequence assoc))
                  (lambda (a b) (> (cdr a) (cdr b)))))))

(defun decknix-session-assoc-prune (assoc turn &optional window)
  "Return ASSOC without roots older than WINDOW turns before TURN.

Applied before persisting, so a session's stored association cannot grow
to the 39 entries the full history produced."
  (let ((window (or window decknix-session-assoc-window)))
    (seq-filter (lambda (cell) (> (cdr cell) (- turn window)))
                (copy-sequence assoc))))

;; --- claims -----------------------------------------------------------

(defun decknix-session-assoc-claims-wt-p (roots wt-path)
  "Return non-nil when WT-PATH is one of ROOTS.

Compared as directories: the worktree audit writes some paths with a
trailing slash and some without, which is the normalisation bug that once
hid `decknix-config' from the worktree picker."
  (and wt-path
       (seq-some (lambda (r)
                   (and r (string= (file-name-as-directory r)
                                   (file-name-as-directory wt-path))))
                 roots)
       t))

(defun decknix-session-assoc-claims-branch-p (roots branch wt-for-root)
  "Return non-nil when a root in ROOTS is the worktree for BRANCH.

WT-FOR-ROOT maps a root path to its checked-out branch.  This is how a PR
is claimed: by the branch of a worktree the session is working in, which
is precise, rather than by its repo, which is not."
  (and branch
       (seq-some (lambda (r)
                   (equal branch (funcall wt-for-root r)))
                 roots)
       t))

(provide 'decknix-session-assoc)
;;; decknix-session-assoc.el ends here
