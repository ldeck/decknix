;;; decknix-perf-hitch-autofile.el --- Auto-file recurring hitch outliers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-perf-hitch "0.1"))
;; Keywords: decknix, performance, profiling, taskwarrior

;;; Commentary:
;;
;; Turns the background hitch profiler into a live task list.  A slow
;; function that keeps recurring is a standing optimisation target, not a
;; one-off; this scans the profiler's tally on a timer and, when a
;; function recurs enough (>= `decknix-perf-hitch-autofile-min-count'
;; occurrences) with a real spike (>= `decknix-perf-hitch-autofile-min-
;; max-ms'), files a taskwarrior task once -- so a performance-inhibiting
;; function surfaces as tracked work automatically rather than being lost
;; in the log.  Complements the manual `decknix-capture' quick-capture.
;;
;; Conservative by design: only genuine recurring outliers file, its own
;; machinery is excluded (no feedback loop), and each label files once per
;; session (in-memory dedup; a daemon restart may re-file an unresolved
;; outlier, which the user can merge).  Default-on
;; (`decknix-perf-hitch-autofile-enable'); the pure outlier predicate and
;; description builder are ERT-tested.

;;; Code:

(require 'decknix-perf-hitch)

(defgroup decknix-perf-hitch-autofile nil
  "Auto-file recurring hitch-profiler outliers as tasks."
  :group 'decknix)

(defcustom decknix-perf-hitch-autofile-enable t
  "When non-nil, periodically file recurring hitch outliers to taskwarrior."
  :type 'boolean :group 'decknix-perf-hitch-autofile)

(defcustom decknix-perf-hitch-autofile-min-count 25
  "Minimum occurrences before a hitching function is filed as a task."
  :type 'integer :group 'decknix-perf-hitch-autofile)

(defcustom decknix-perf-hitch-autofile-min-max-ms 300
  "Minimum single-hitch max (ms) before a function is filed as a task."
  :type 'integer :group 'decknix-perf-hitch-autofile)

(defcustom decknix-perf-hitch-autofile-interval 900
  "Seconds between auto-file scans of the hitch tally."
  :type 'integer :group 'decknix-perf-hitch-autofile)

(defcustom decknix-perf-hitch-autofile-project "decknix.perf"
  "Taskwarrior project for auto-filed perf tasks."
  :type 'string :group 'decknix-perf-hitch-autofile)

(defvar decknix--perf-hitch-autofile-last (make-hash-table :test 'equal)
  "Label -> occurrence count at its last file/annotate.
Throttles how often a still-hitching label is re-annotated within a session
\(annotate again only after it accrues another `min-count' hits).  Lost on
restart, which is harmless: taskwarrior itself is the persistent dedup store
\(one task per issue tag), so a restart never re-adds a duplicate task.")

(defvar decknix--perf-hitch-autofile-timer nil)

(declare-function decknix--perf-hitch-tally "decknix-perf-hitch")

;; -- Pure helpers (ERT-tested) --------------------------------------

(defun decknix--perf-hitch-outlier-p (count max-ms min-count min-max-ms)
  "Return non-nil when (COUNT, MAX-MS) is a recurring slow outlier.
Both the recurrence bar (COUNT >= MIN-COUNT) and the severity bar
(MAX-MS >= MIN-MAX-MS) must be met, so neither a rare big spike nor a
frequent trivial one files on its own."
  (and (>= count min-count) (>= max-ms min-max-ms)))

(defun decknix--perf-hitch-autofile-self-p (label)
  "Return non-nil when LABEL is the profiler's own machinery.
Excluded to avoid a feedback loop (the scan/tally themselves hitching)."
  (and (stringp label)
       (string-match-p "decknix-perf-hitch\\|decknix--perf-hitch" label)))

(defun decknix--perf-hitch-autofile-task-desc (label count max-ms)
  "Build the taskwarrior description for a recurring hitch LABEL."
  (format "perf: %s hitch (%dx, max %dms) — investigate/optimise"
          label count max-ms))

(defun decknix--perf-hitch-autofile-issue-tag (label)
  "Return a stable taskwarrior tag identifying the hitch issue for LABEL.
A short hash so the (possibly gibberish/bytecode) label maps to one durable
tag — this is how the same issue is deduped across daemon restarts (query the
tag; if a task exists, update it instead of adding a second).  Pure."
  (concat "h" (substring (secure-hash 'md5 (or label "")) 0 10)))

(defun decknix--perf-hitch-autofile-priority (max-ms)
  "Return the taskwarrior priority (\"H\"/\"M\"/\"L\") for a MAX-MS spike.
Severity escalates the priority so the worst blockers (multi-second freezes)
rank highest.  Pure."
  (cond ((>= max-ms 1500) "H")
        ((>= max-ms 600)  "M")
        (t                "L")))

;; -- Orchestration --------------------------------------------------

(defun decknix--perf-hitch-autofile-upsert-task (label count max-ms)
  "File-or-update the taskwarrior task for recurring hitch LABEL (async).
Uses taskwarrior as the persistent store: query the issue's stable tag; if a
pending task exists, annotate it with the fresh evidence and (re)set its
priority by severity — so a recurring bottleneck accrues evidence and escalates
rather than spawning duplicates.  If none exists, add it.  Survives restarts."
  (let* ((tag  (decknix--perf-hitch-autofile-issue-tag label))
         (prio (decknix--perf-hitch-autofile-priority max-ms))
         (desc (decknix--perf-hitch-autofile-task-desc label count max-ms))
         (annot (format "still hitching: %dx, max %dms" count max-ms))
         (proj decknix-perf-hitch-autofile-project)
         (cmd (format
               (concat
                "u=$(task rc.verbose=nothing rc.confirmation=off +%s status:pending _uuid 2>/dev/null | head -1); "
                "if [ -n \"$u\" ]; then "
                "  task rc.verbose=nothing rc.confirmation=off \"$u\" annotate %s >/dev/null 2>&1; "
                "  task rc.verbose=nothing rc.confirmation=off \"$u\" modify priority:%s >/dev/null 2>&1; "
                "else "
                "  task rc.verbose=nothing rc.confirmation=off add %s project:%s +perf +autofiled +%s priority:%s >/dev/null 2>&1; "
                "fi")
               tag (shell-quote-argument annot) prio
               (shell-quote-argument desc) proj tag prio)))
    (ignore-errors
      (make-process
       :name "decknix-hitch-autofile"
       :buffer nil
       :connection-type 'pipe
       :command (list "sh" "-c" cmd)
       :sentinel
       (lambda (p _e)
         (when (and (eq (process-status p) 'exit)
                    (= 0 (process-exit-status p)))
           (message "decknix: tracked perf hitch %s (%dx, max %dms, prio %s)"
                    label count max-ms prio)))))))

(defun decknix--perf-hitch-autofile-scan ()
  "Scan the hitch tally; file new recurring outliers and update recurring ones.
An outlier files once (deduped by its issue tag in taskwarrior, so a restart
never duplicates it), then re-annotates + re-prioritises each time it accrues
another `min-count' hits — so a persistent bottleneck accumulates evidence and
climbs in priority automatically."
  (when (fboundp 'decknix--perf-hitch-tally)
    (dolist (row (decknix--perf-hitch-tally))
      (let* ((label (car row))
             (v (cdr row))
             (count (nth 0 v))
             (max-ms (nth 2 v))
             (last (gethash label decknix--perf-hitch-autofile-last 0)))
        (when (and (not (decknix--perf-hitch-autofile-self-p label))
                   (decknix--perf-hitch-outlier-p
                    count max-ms
                    decknix-perf-hitch-autofile-min-count
                    decknix-perf-hitch-autofile-min-max-ms)
                   ;; File first time; then re-update only after another batch
                   ;; of hits, so a persistent hitch escalates without spamming.
                   (>= (- count last) decknix-perf-hitch-autofile-min-count))
          (puthash label count decknix--perf-hitch-autofile-last)
          (decknix--perf-hitch-autofile-upsert-task label count max-ms))))))

(defun decknix-perf-hitch-autofile-start ()
  "Arm the periodic auto-file scan (idempotent across hot-reloads)."
  (when (timerp decknix--perf-hitch-autofile-timer)
    (cancel-timer decknix--perf-hitch-autofile-timer))
  (setq decknix--perf-hitch-autofile-timer
        (run-with-timer decknix-perf-hitch-autofile-interval
                        decknix-perf-hitch-autofile-interval
                        #'decknix--perf-hitch-autofile-scan)))

(defun decknix-perf-hitch-autofile-stop ()
  "Stop the periodic auto-file scan."
  (interactive)
  (when (timerp decknix--perf-hitch-autofile-timer)
    (cancel-timer decknix--perf-hitch-autofile-timer))
  (setq decknix--perf-hitch-autofile-timer nil))

(provide 'decknix-perf-hitch-autofile)
;;; decknix-perf-hitch-autofile.el ends here
