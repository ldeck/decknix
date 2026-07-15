;;; decknix-perf-hitch.el --- Background hitch profiler -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: decknix, performance, profiling

;;; Commentary:
;;
;; A lightweight, always-on "hitch" profiler.  As decknix/deckmacs grows,
;; a single slow timer or command can freeze the single-threaded editor
;; for hundreds of ms to seconds (a real example: a header-line counter
;; that did a synchronous filesystem scan on a 2s timer, freezing Emacs
;; for 21s).  This watches for exactly that: it times every `timer-event-
;; handler' invocation and every interactive command, and logs any that
;; exceed `decknix-perf-hitch-threshold' to `*decknix-hitches*' with the
;; responsible function's name.  `decknix-perf-hitch-report' then tallies
;; the log into the worst offenders, so a performance-inhibiting function
;; is named rather than guessed at.
;;
;; Default-on (`decknix-perf-hitch-enable') but cheap -- it only records
;; on the slow tail, and never serializes a closure's captured state
;; (that once produced multi-KB log lines): function labels are bounded.
;; Toggle at runtime with `decknix-perf-hitch-toggle'.

;;; Code:

(defgroup decknix-perf-hitch nil
  "Background hitch profiler for decknix."
  :group 'decknix)

(defcustom decknix-perf-hitch-enable t
  "When non-nil, run the background hitch profiler.
Set to nil (and reload / restart) to disable, or toggle at runtime with
`decknix-perf-hitch-toggle'."
  :type 'boolean
  :group 'decknix-perf-hitch)

(defcustom decknix-perf-hitch-threshold 0.05
  "Log timers/commands that take at least this many seconds.
Low enough to catch a felt hitch (~50ms), high enough that ordinary
work is not recorded."
  :type 'number
  :group 'decknix-perf-hitch)

(defcustom decknix-perf-hitch-keep-lines 800
  "Trim `*decknix-hitches*' back to about this many lines when it grows."
  :type 'integer
  :group 'decknix-perf-hitch)

(defvar decknix--perf-hitch-cmd-start nil)
(defvar decknix--perf-hitch-active nil
  "Non-nil while the profiler's advice/hooks are installed.")

(defun decknix--perf-hitch-fn-label (fn)
  "Return a compact, SAFE label for FN (never serialises a closure).
A symbol yields its name; anything else is printed with `print-length'
and `print-level' bound low and truncated, so a timer whose function is
a closure capturing large state cannot produce a multi-KB log line."
  (cond ((null fn) "nil")
        ((symbolp fn) (symbol-name fn))
        (t (let ((print-length 3) (print-level 2))
             (truncate-string-to-width
              (condition-case nil (format "%S" fn) (error "closure"))
              70 nil nil "…")))))

(defun decknix--perf-hitch-log (label ms)
  "Append a hitch of MS milliseconds for LABEL to `*decknix-hitches*'."
  (with-current-buffer (get-buffer-create "*decknix-hitches*")
    (goto-char (point-max))
    (insert (format "%s %6.0fms  %s\n"
                    (format-time-string "%H:%M:%S.%3N") ms label))
    (when (> (line-number-at-pos) (+ decknix-perf-hitch-keep-lines 200))
      (goto-char (point-min))
      (forward-line 200)
      (delete-region (point-min) (point)))))

(defun decknix--perf-hitch-timer-advice (orig &rest args)
  "Around-advice for `timer-event-handler' that logs slow timers."
  (let ((t0 (float-time)))
    (unwind-protect (apply orig args)
      (let ((ms (* 1000 (- (float-time) t0))))
        (when (>= ms (* 1000 decknix-perf-hitch-threshold))
          (decknix--perf-hitch-log
           (format "TIMER %s"
                   (decknix--perf-hitch-fn-label
                    (ignore-errors (timer--function (car args)))))
           ms))))))

(defun decknix--perf-hitch-pre ()
  (setq decknix--perf-hitch-cmd-start (float-time)))

(defun decknix--perf-hitch-post ()
  (when decknix--perf-hitch-cmd-start
    (let ((ms (* 1000 (- (float-time) decknix--perf-hitch-cmd-start))))
      (when (>= ms (* 1000 decknix-perf-hitch-threshold))
        (decknix--perf-hitch-log
         (format "CMD %s" (decknix--perf-hitch-fn-label this-command)) ms)))))

(defun decknix-perf-hitch-start ()
  "Start the background hitch profiler (idempotent)."
  (interactive)
  (unless decknix--perf-hitch-active
    (advice-add 'timer-event-handler :around #'decknix--perf-hitch-timer-advice)
    (add-hook 'pre-command-hook #'decknix--perf-hitch-pre)
    (add-hook 'post-command-hook #'decknix--perf-hitch-post)
    (setq decknix--perf-hitch-active t))
  (when (called-interactively-p 'interactive)
    (message "decknix hitch profiler ON (threshold %.0fms → *decknix-hitches*)"
             (* 1000 decknix-perf-hitch-threshold))))

(defun decknix-perf-hitch-stop ()
  "Stop the background hitch profiler."
  (interactive)
  (advice-remove 'timer-event-handler #'decknix--perf-hitch-timer-advice)
  (remove-hook 'pre-command-hook #'decknix--perf-hitch-pre)
  (remove-hook 'post-command-hook #'decknix--perf-hitch-post)
  (setq decknix--perf-hitch-active nil)
  (when (called-interactively-p 'interactive)
    (message "decknix hitch profiler OFF")))

(defun decknix-perf-hitch-toggle ()
  "Toggle the background hitch profiler."
  (interactive)
  (if decknix--perf-hitch-active
      (decknix-perf-hitch-stop)
    (decknix-perf-hitch-start))
  (message "decknix hitch profiler %s" (if decknix--perf-hitch-active "ON" "OFF")))

(defun decknix--perf-hitch-tally ()
  "Return an alist (LABEL . (COUNT TOTAL-MS MAX-MS)) from the hitch log."
  (let ((counts (make-hash-table :test 'equal)))
    (when (get-buffer "*decknix-hitches*")
      (with-current-buffer "*decknix-hitches*"
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (let ((l (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position))))
              (when (string-match "\\([0-9]+\\)ms  \\(.*\\)\\'" l)
                (let* ((ms (string-to-number (match-string 1 l)))
                       (k (match-string 2 l))
                       (v (gethash k counts (list 0 0 0))))
                  (puthash k (list (1+ (nth 0 v))
                                   (+ (nth 1 v) ms)
                                   (max (nth 2 v) ms))
                           counts))))
            (forward-line 1)))))
    (let (rows)
      (maphash (lambda (k v) (push (cons k v) rows)) counts)
      rows)))

(defun decknix-perf-hitch-report ()
  "Show the worst hitches (by total time) in `*decknix-hitch-report*'."
  (interactive)
  (let ((rows (sort (decknix--perf-hitch-tally)
                    (lambda (a b) (> (nth 1 (cdr a)) (nth 1 (cdr b)))))))
    (with-current-buffer (get-buffer-create "*decknix-hitch-report*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%-8s %-5s %-8s  %s\n" "total" "n" "max" "function")
                (format "%-8s %-5s %-8s  %s\n" "-----" "-" "---" "--------"))
        (if (null rows)
            (insert "(no hitches recorded yet)\n")
          (dolist (r rows)
            (insert (format "%-6dms %-5d %-6dms  %s\n"
                            (nth 1 (cdr r)) (nth 0 (cdr r)) (nth 2 (cdr r))
                            (car r))))))
      (special-mode)
      (display-buffer (current-buffer)))))

(provide 'decknix-perf-hitch)
;;; decknix-perf-hitch.el ends here
