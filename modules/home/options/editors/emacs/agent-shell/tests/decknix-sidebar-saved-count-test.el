;;; decknix-sidebar-saved-count-test.el --- Saved-count stays off the redisplay path -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-shell-workspace "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; The sidebar header-line `:eval' calls `decknix--sidebar-saved-count'
;; on every redisplay.  The underlying grouping chain fires O(N)
;; `file-attributes' stat syscalls, so it must NEVER run inline on the
;; redisplay path — doing so stalls the first frame after selecting the
;; sidebar window (the "arrow key locks up for a beat" report).
;;
;; These tests pin the contract:
;;   1. The getter never invokes the expensive grouping fn inline; it
;;      only reads the cached scalar (0 before the first recompute).
;;   2. The recompute (fired off the redisplay path by an idle timer)
;;      is what actually computes and refreshes the cache.
;;   3. A warm, in-TTL cache neither recomputes nor re-schedules.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-shell-workspace)

(defmacro decknix-saved-count-test--with-env (&rest body)
  "Run BODY with saved-count cache state reset and grouping stubbed.
Binds `decknix-saved-count-test--group-calls' to the number of times
the expensive grouping chain was invoked, and makes the grouping
return a fixed 3-element list so the count is deterministic."
  (declare (indent 0))
  `(let ((decknix--sidebar-saved-count-cache nil)
         (decknix--sidebar-saved-count-cache-time 0.0)
         (decknix--sidebar-saved-count-refresh-timer nil)
         (decknix-saved-count-test--group-calls 0))
     (cl-letf (((symbol-function 'decknix--agent-session-list)
                (lambda (&rest _) '(a b c)))
               ((symbol-function 'decknix--agent-session-group-by-conversation)
                (lambda (&rest _)
                  (setq decknix-saved-count-test--group-calls
                        (1+ decknix-saved-count-test--group-calls))
                  '(g1 g2 g3)))
               ;; Neutralise the real timer + redisplay side effects.
               ((symbol-function 'run-with-idle-timer)
                (lambda (&rest _) 'stub-timer))
               ((symbol-function 'force-mode-line-update) #'ignore))
       ,@body)))

(defvar decknix-saved-count-test--group-calls 0)

(ert-deftest decknix-sidebar-saved-count/getter-never-computes-inline ()
  "Cold-cache getter returns 0 and defers — it must not group inline."
  (decknix-saved-count-test--with-env
    (should (= 0 (decknix--sidebar-saved-count)))
    ;; The expensive chain was NOT run on the redisplay path.
    (should (= 0 decknix-saved-count-test--group-calls))
    ;; A recompute was scheduled (stub timer stored).
    (should (eq 'stub-timer decknix--sidebar-saved-count-refresh-timer))))

(ert-deftest decknix-sidebar-saved-count/getter-schedules-once ()
  "Repeated stale reads coalesce to a single pending recompute."
  (decknix-saved-count-test--with-env
    (let ((calls 0))
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (&rest _) (setq calls (1+ calls)) 'stub-timer)))
        (decknix--sidebar-saved-count)
        (decknix--sidebar-saved-count)
        (decknix--sidebar-saved-count)
        ;; Only the first stale read schedules; the pending timer gates
        ;; the rest.
        (should (= 1 calls))))))

(ert-deftest decknix-sidebar-saved-count/recompute-updates-cache ()
  "The off-redisplay recompute is what actually runs the grouping."
  (decknix-saved-count-test--with-env
    (decknix--sidebar-saved-count-recompute)
    (should (= 1 decknix-saved-count-test--group-calls))
    (should (= 3 decknix--sidebar-saved-count-cache))
    (should (null decknix--sidebar-saved-count-refresh-timer))
    ;; Now the getter serves the warm value with no further grouping
    ;; and no new timer.
    (should (= 3 (decknix--sidebar-saved-count)))
    (should (= 1 decknix-saved-count-test--group-calls))
    (should (null decknix--sidebar-saved-count-refresh-timer))))

(ert-deftest decknix-sidebar-saved-count/warm-cache-no-work ()
  "A fresh in-TTL cache neither recomputes nor schedules."
  (decknix-saved-count-test--with-env
    (setq decknix--sidebar-saved-count-cache 7
          decknix--sidebar-saved-count-cache-time (float-time))
    (should (= 7 (decknix--sidebar-saved-count)))
    (should (= 0 decknix-saved-count-test--group-calls))
    (should (null decknix--sidebar-saved-count-refresh-timer))))

(provide 'decknix-sidebar-saved-count-test)
;;; decknix-sidebar-saved-count-test.el ends here
