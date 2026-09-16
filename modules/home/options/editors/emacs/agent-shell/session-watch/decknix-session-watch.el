;;; decknix-session-watch.el --- Watch a condition, notify when it fires -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, watch, ci

;;; Commentary:
;;
;; A session that says "I'll report when the build lands" cannot: an agent
;; does nothing between turns.  So the session sits at `ready' while a
;; condition it is supposedly watching goes unobserved, and a session that
;; promised to follow up is the one most likely to be forgotten.
;;
;; This makes the promise the system's, not the agent's.  You register a
;; watch against a PR's CI, the hub tick (already running) evaluates it,
;; and when CI reaches a terminal state the watch NOTIFIES you and clears
;; itself.  The session carries a `watching' status meanwhile, distinct
;; from `ready', so the display stops lying about what it is doing.
;;
;; This file is the pure core (spec sequencing steps 1-2, notify only):
;; the watch record, the `checks-complete' condition, the fire decision,
;; and the `watching' status refinement.  Persistence and the tick wiring
;; sit on top; the re-prompt (spending a model turn unasked) is a later
;; step, deliberately not here.
;;
;; Every decision is a pure function over a watch record plus feed data,
;; so the loop is testable without a live session or a hub file.

;;; Code:

(require 'cl-lib)

(defconst decknix-session-watch-terminal-ci-states
  '("pass" "soft_fail" "partial_fail" "fail")
  "CI states that mean checks have FINISHED, pass or fail.

The complement -- `running', `none', nil -- means still in flight.  A
`checks-complete' watch fires on the transition INTO this set, never
while a PR is still building.  Mirrors `decknix--hub-ci-filter-order'.")

(defun decknix-session-watch-ci-terminal-p (ci-status)
  "Non-nil when CI-STATUS is a finished state (pass or fail)."
  (and (stringp ci-status)
       (member ci-status decknix-session-watch-terminal-ci-states)
       t))

(defun decknix-session-watch-make (conv-key pr-key condition baseline-ci now)
  "Return a watch record.  Pure.

CONV-KEY identifies the session, PR-KEY its `repo#number', CONDITION the
symbol (`checks-complete' for now), BASELINE-CI the PR's CI status AT
REGISTRATION, and NOW the registration time (a float-time).

The baseline is load-bearing: `checks-complete' compares against it so a
PR already green when the watch is set does NOT fire immediately -- the
watch means \"tell me when THIS finishes\", relative to when you asked."
  (list (cons 'conv-key conv-key)
        (cons 'pr-key pr-key)
        (cons 'condition condition)
        (cons 'baseline-terminal (decknix-session-watch-ci-terminal-p baseline-ci))
        (cons 'registered now)))

(defun decknix-session-watch-fired-p (watch current-ci)
  "Non-nil when WATCH's condition holds given CURRENT-CI.  Pure.

For `checks-complete': CI is terminal NOW and was NOT terminal at the
baseline.  A watch whose PR was already finished when registered waits
for the NEXT transition rather than firing on the state it was born into."
  (pcase (alist-get 'condition watch)
    ('checks-complete
     (and (decknix-session-watch-ci-terminal-p current-ci)
          (not (alist-get 'baseline-terminal watch))))
    (_ nil)))

(defun decknix-session-watch-expired-p (watch now ttl live-conv-keys)
  "Non-nil when WATCH should be reaped.  Pure.

Reaped when its session is gone (its CONV-KEY is not in LIVE-CONV-KEYS)
or it is older than TTL seconds.  Anything registered and never cleaned
up leaks -- the orphaned brokers ran for hours because nothing reaped
them, and a watch is the same shape of hazard."
  (or (not (member (alist-get 'conv-key watch) live-conv-keys))
      (> (- now (or (alist-get 'registered watch) 0)) ttl)))

(defun decknix-session-watch-partition (watches ci-fn now ttl live-conv-keys)
  "Return (FIRED KEPT) from WATCHES.  Pure.

CI-FN maps a watch's `pr-key' to its current CI status.  FIRED are
watches whose condition holds (to notify and drop -- one-shot).  KEPT are
the survivors, minus any that expired.  Expiry is checked first so a
dead-session watch is dropped rather than fired into a session that is
gone."
  (let (fired kept)
    (dolist (w watches)
      (cond
       ((decknix-session-watch-expired-p w now ttl live-conv-keys) nil)
       ((decknix-session-watch-fired-p w (funcall ci-fn (alist-get 'pr-key w)))
        (push w fired))
       (t (push w kept))))
    (list (nreverse fired) (nreverse kept))))

(defun decknix-session-watch-status (raw-status has-watch)
  "Refine RAW-STATUS to `watching' when HAS-WATCH and the turn is settled.

Only a `ready' or `finished' session becomes `watching': a `working' or
`asking' session is doing or wanting something more specific, and a watch
does not override that.  So `watching' reads exactly as intended -- idle
for input, AND holding a registered promise -- and never masks a live or
blocked turn."
  (if (and has-watch (member raw-status '("ready" "finished")))
      "watching"
    raw-status))

(defvar decknix-session-watches nil
  "The live list of watch records (see `decknix-session-watch-make').
Loaded from disk at startup and rewritten on every change, so a watch
survives a restart -- otherwise it would break exactly when a
long-running condition was about to fire.")

(defcustom decknix-session-watch-file
  (expand-file-name "~/.config/decknix/session-watches.el")
  "Where the watch list is persisted.  A plain readable form, like the
sibling dismissed-sessions and live-sessions stores."
  :type 'file :group 'decknix)

(defcustom decknix-session-watch-ttl 86400
  "Seconds after which an un-fired watch is reaped even if its session
lives.  A day: long enough for any CI, short enough that a forgotten
watch does not linger indefinitely."
  :type 'integer :group 'decknix)

(defun decknix-session-watch-read ()
  "Return the persisted watch list, or nil.  Tolerates an absent or
unreadable file rather than erroring at startup."
  (when (file-exists-p decknix-session-watch-file)
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents decknix-session-watch-file)
        (let ((data (read (current-buffer))))
          (and (listp data) data))))))

(defun decknix-session-watch-write (watches)
  "Persist WATCHES atomically to `decknix-session-watch-file'."
  (let ((dir (file-name-directory decknix-session-watch-file)))
    (unless (file-directory-p dir) (make-directory dir t)))
  (let ((tmp (make-temp-file "session-watches-")))
    (with-temp-file tmp
      (insert ";; Auto-generated by decknix-session-watch -- do not edit\n")
      (prin1 watches (current-buffer)))
    (rename-file tmp decknix-session-watch-file t)))

(defun decknix-session-watch-load ()
  "Load persisted watches into `decknix-session-watches'."
  (setq decknix-session-watches (decknix-session-watch-read)))

(defun decknix-session-watch-add (conv-key pr-key condition baseline-ci)
  "Register a watch and persist.  Replaces any prior watch on the same
CONV-KEY+PR-KEY so a re-watch resets the baseline rather than stacking."
  (let ((now (float-time))
        (others (seq-remove
                 (lambda (w) (and (equal (alist-get 'conv-key w) conv-key)
                                  (equal (alist-get 'pr-key w) pr-key)))
                 decknix-session-watches)))
    (setq decknix-session-watches
          (cons (decknix-session-watch-make conv-key pr-key condition baseline-ci now)
                others))
    (decknix-session-watch-write decknix-session-watches)
    decknix-session-watches))

(defun decknix-session-watch-remove (conv-key)
  "Drop every watch on CONV-KEY and persist."
  (setq decknix-session-watches
        (seq-remove (lambda (w) (equal (alist-get 'conv-key w) conv-key))
                    decknix-session-watches))
  (decknix-session-watch-write decknix-session-watches))

(defun decknix-session-watch-for-conv-key (conv-key)
  "Return non-nil when CONV-KEY has a live watch."
  (seq-some (lambda (w) (equal (alist-get 'conv-key w) conv-key))
            decknix-session-watches))

(defun decknix-session-watch-evaluate (ci-fn live-conv-keys notify-fn)
  "Fire and reap watches.  Returns the number fired.

CI-FN maps a `pr-key' to its current CI status; LIVE-CONV-KEYS are the
conv-keys of sessions still alive; NOTIFY-FN is called with each fired
watch (side effect: message, sidebar ping).  Fired and expired watches
are dropped, survivors persisted.  The partition itself is pure
\(`decknix-session-watch-partition'); this is the thin side-effecting
shell the hub tick calls."
  (let* ((parts (decknix-session-watch-partition
                 decknix-session-watches ci-fn (float-time)
                 decknix-session-watch-ttl live-conv-keys))
         (fired (nth 0 parts))
         (kept (nth 1 parts)))
    (dolist (w fired) (ignore-errors (funcall notify-fn w)))
    (unless (equal kept decknix-session-watches)
      (setq decknix-session-watches kept)
      (decknix-session-watch-write decknix-session-watches))
    (length fired)))

(provide 'decknix-session-watch)
;;; decknix-session-watch.el ends here
