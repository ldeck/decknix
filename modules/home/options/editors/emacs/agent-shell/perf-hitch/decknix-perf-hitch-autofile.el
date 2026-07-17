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

(defvar decknix--perf-hitch-autofile-seen (make-hash-table :test 'equal)
  "Labels already filed this session (in-memory dedup).")

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

;; -- Orchestration --------------------------------------------------

(defun decknix--perf-hitch-autofile-add-task (label count max-ms)
  "Add a taskwarrior task for a recurring hitch LABEL (async)."
  (let ((desc (decknix--perf-hitch-autofile-task-desc label count max-ms)))
    (ignore-errors
      (make-process
       :name "decknix-hitch-autofile"
       :buffer nil
       :connection-type 'pipe
       :command (list "task" "add" desc
                      (concat "project:" decknix-perf-hitch-autofile-project)
                      "+perf" "+autofiled")
       :sentinel
       (lambda (p _e)
         (when (and (eq (process-status p) 'exit)
                    (= 0 (process-exit-status p)))
           (message "decknix: auto-filed perf task for %s" label)))))))

(defun decknix--perf-hitch-autofile-scan ()
  "Scan the hitch tally and file any new recurring outliers."
  (when (fboundp 'decknix--perf-hitch-tally)
    (dolist (row (decknix--perf-hitch-tally))
      (let* ((label (car row))
             (v (cdr row))
             (count (nth 0 v))
             (max-ms (nth 2 v)))
        (when (and (not (gethash label decknix--perf-hitch-autofile-seen))
                   (not (decknix--perf-hitch-autofile-self-p label))
                   (decknix--perf-hitch-outlier-p
                    count max-ms
                    decknix-perf-hitch-autofile-min-count
                    decknix-perf-hitch-autofile-min-max-ms))
          (puthash label t decknix--perf-hitch-autofile-seen)
          (decknix--perf-hitch-autofile-add-task label count max-ms))))))

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
