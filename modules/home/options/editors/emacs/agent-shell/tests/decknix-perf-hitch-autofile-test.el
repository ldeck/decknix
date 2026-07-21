;;; decknix-perf-hitch-autofile-test.el --- Tests for hitch auto-file -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Pure-helper tests for the recurring-outlier auto-filer: the two-bar
;; outlier predicate, the self-exclusion guard (no feedback loop), and the
;; task description builder.  The timer + async `task add' are exercised
;; live; only the decision layer is unit-tested here.

;;; Code:

(require 'ert)
(require 'decknix-perf-hitch-autofile)

(ert-deftest decknix-hitch-autofile--outlier-needs-both-bars ()
  "Both recurrence AND severity bars must be met."
  (should      (decknix--perf-hitch-outlier-p 30 400 25 300))   ; both
  (should-not  (decknix--perf-hitch-outlier-p 10 400 25 300))   ; too few
  (should-not  (decknix--perf-hitch-outlier-p 30 100 25 300))   ; too small
  (should-not  (decknix--perf-hitch-outlier-p 10 100 25 300)))  ; neither

(ert-deftest decknix-hitch-autofile--boundary-inclusive ()
  "Exactly meeting both thresholds qualifies."
  (should (decknix--perf-hitch-outlier-p 25 300 25 300)))

(ert-deftest decknix-hitch-autofile--excludes-own-machinery ()
  "The profiler's own functions are never filed (no feedback loop)."
  (should (decknix--perf-hitch-autofile-self-p "TIMER decknix--perf-hitch-autofile-scan"))
  (should (decknix--perf-hitch-autofile-self-p "CMD decknix-perf-hitch-report"))
  (should-not (decknix--perf-hitch-autofile-self-p "TIMER decknix--sidebar-paint-tick"))
  (should-not (decknix--perf-hitch-autofile-self-p "CMD self-insert-command")))

(ert-deftest decknix-hitch-autofile--task-desc ()
  "Description carries the label, count, and max-ms."
  (let ((d (decknix--perf-hitch-autofile-task-desc "TIMER foo" 42 1365)))
    (should (string-match-p "TIMER foo" d))
    (should (string-match-p "42x" d))
    (should (string-match-p "1365ms" d))))

(ert-deftest decknix-hitch-autofile--issue-tag-stable-and-safe ()
  "The issue tag is deterministic per label and a safe taskwarrior tag."
  (let ((a (decknix--perf-hitch-autofile-issue-tag "TIMER decknix--sidebar-paint-tick"))
        (b (decknix--perf-hitch-autofile-issue-tag "TIMER decknix--sidebar-paint-tick"))
        (c (decknix--perf-hitch-autofile-issue-tag "CMD self-insert-command")))
    (should (equal a b))                    ; same label -> same tag (dedup key)
    (should-not (equal a c))                ; different label -> different tag
    (should (string-match-p "\\`h[0-9a-f]+\\'" a))  ; alnum tag, no shell metachars
    ;; Gibberish/bytecode labels still yield a safe tag.
    (should (string-match-p "\\`h[0-9a-f]+\\'"
                            (decknix--perf-hitch-autofile-issue-tag
                             "TIMER #[0 \"\\301\\242\\203$ ...")))))

(ert-deftest decknix-hitch-autofile--priority-escalates-by-severity ()
  "Priority climbs with the spike size so multi-second freezes rank highest."
  (should (equal "H" (decknix--perf-hitch-autofile-priority 3000)))
  (should (equal "H" (decknix--perf-hitch-autofile-priority 1500)))
  (should (equal "M" (decknix--perf-hitch-autofile-priority 600)))
  (should (equal "L" (decknix--perf-hitch-autofile-priority 350))))

(provide 'decknix-perf-hitch-autofile-test)
;;; decknix-perf-hitch-autofile-test.el ends here
