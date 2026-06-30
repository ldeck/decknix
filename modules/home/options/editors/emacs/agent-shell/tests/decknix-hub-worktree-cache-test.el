;;; decknix-hub-worktree-cache-test.el --- Cache for discover-clones -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1") (decknix-agent-shell-hub "0.1"))

;;; Commentary:
;;
;; Pins the short-TTL memoisation contract for
;; `decknix--hub-worktree-discover-clones'.  The function used to run
;; in full on every call -- ~290 ms per invocation under the load that
;; fired during a single sidebar render -- which produced an N+1
;; burst of ~50 calls per toggle and a 15 s freeze (the row-badge
;; helper calls `worktree-primary' which in turn calls `discover-clones'
;; once per row when the registry's `:primary' is missing).  The cache
;; coalesces a single render's worth of calls into one compute, and
;; expires shortly after so that genuine state changes (new clone added,
;; cache primary updated by an async probe) are picked up on the next
;; render pass.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-shell-hub)

(defmacro decknix-hub-cache-test--with-stub (counter-var result &rest body)
  "Stub the compute helper to return RESULT and increment COUNTER-VAR."
  (declare (indent 2))
  `(let ((,counter-var 0)
         (decknix--hub-worktree-clones-cache nil))
     (cl-letf (((symbol-function 'decknix--hub-worktree-discover-clones--compute)
                (lambda () (cl-incf ,counter-var) ,result)))
       ,@body)))

(ert-deftest decknix-hub-worktree-cache--coalesces-render-burst ()
  "Many calls within TTL hit the cache; compute runs exactly once."
  (decknix-hub-cache-test--with-stub calls '(("o/r" . "/tmp/r"))
    (let ((decknix-hub-worktree-clones-cache-ttl 5))
      (dotimes (_ 50)
        (should (equal '(("o/r" . "/tmp/r"))
                       (decknix--hub-worktree-discover-clones))))
      (should (= 1 calls)))))

(ert-deftest decknix-hub-worktree-cache--expires-past-ttl ()
  "After TTL elapses the next call recomputes."
  (decknix-hub-cache-test--with-stub calls '(("o/r" . "/tmp/r"))
    (let ((decknix-hub-worktree-clones-cache-ttl 5))
      (decknix--hub-worktree-discover-clones)
      ;; Backdate the cache timestamp past the TTL window.
      (setq decknix--hub-worktree-clones-cache
            (cons (- (float-time) 10)
                  (cdr decknix--hub-worktree-clones-cache)))
      (decknix--hub-worktree-discover-clones)
      (should (= 2 calls)))))

(ert-deftest decknix-hub-worktree-cache--ttl-zero-disables ()
  "A TTL of 0 bypasses the cache so every call recomputes."
  (decknix-hub-cache-test--with-stub calls nil
    (let ((decknix-hub-worktree-clones-cache-ttl 0))
      (dotimes (_ 3)
        (decknix--hub-worktree-discover-clones))
      (should (= 3 calls)))))

(ert-deftest decknix-hub-worktree-cache--invalidate-drops-cache ()
  "`decknix-hub-worktree-clones-cache-invalidate' forces the next call to recompute."
  (decknix-hub-cache-test--with-stub calls nil
    (let ((decknix-hub-worktree-clones-cache-ttl 60))
      (decknix--hub-worktree-discover-clones)
      (decknix-hub-worktree-clones-cache-invalidate)
      (should (null decknix--hub-worktree-clones-cache))
      (decknix--hub-worktree-discover-clones)
      (should (= 2 calls)))))

(provide 'decknix-hub-worktree-cache-test)
;;; decknix-hub-worktree-cache-test.el ends here
