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

;; Forward declarations for cross-module symbols the tests `let`-bind
;; or `cl-letf` at runtime.  `defvar' with an initial value ensures the
;; binding is dynamic (per Emacs AGENTS.md §Tests rule 2).
(defvar decknix--agent-tags-cache-mtime nil)
(defvar decknix--hub-worktree-from-sessions-cache nil)
(declare-function decknix--hub-worktree-discover-from-sessions
                  "decknix-agent-shell-hub")
(declare-function decknix--hub-worktree-discover-from-sessions--compute
                  "decknix-agent-shell-hub" (&optional store))
(declare-function decknix--agent-tags-read
                  "ext:decknix-agent-tags-store")

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

(ert-deftest decknix-hub-worktree-cache--slow-compute-still-memoises ()
  "Compute slower than the TTL must not invalidate its own memo.
Regression: the wrapper used to capture `float-time' BEFORE the
compute, so a 7 s compute against a 5 s TTL stored a memo stamped 7 s
in the past.  The very next caller then saw (delta > TTL) and
recomputed, doubling the render cost (15 s toggle observed against
a 46-row sidebar).  The timestamp must reflect when the compute
finished, not when it started."
  (let ((calls 0)
        (decknix--hub-worktree-clones-cache nil)
        (fake-clock 100.0))
    (cl-letf (((symbol-function 'float-time)
               (lambda (&rest _) fake-clock))
              ((symbol-function 'decknix--hub-worktree-discover-clones--compute)
               (lambda ()
                 (cl-incf calls)
                 ;; Advance the fake clock past the TTL window to
                 ;; simulate a slow compute.
                 (cl-incf fake-clock 7.0)
                 '(("o/r" . "/tmp/r")))))
      (let ((decknix-hub-worktree-clones-cache-ttl 5))
        ;; First call: cache empty -> compute runs; clock advances to
        ;; 107.  Naive impl stamps memo with ts=100 (pre-compute).
        ;; Correct impl stamps memo with ts=107 (post-compute).
        (decknix--hub-worktree-discover-clones)
        ;; Second call at t=107.  Naive: (107-100)=7 > 5 -> RECOMPUTE.
        ;; Correct: (107-107)=0 < 5 -> hit.
        (decknix--hub-worktree-discover-clones)
        (should (= 1 calls))))))

(defmacro decknix-hub-cache-test--with-from-sessions-stub
    (counter-var result &rest body)
  "Stub `discover-from-sessions--compute' to return RESULT and count calls.
Also resets the mtime-keyed memo and neutralises `agent-tags-read'
so the wrapper touches only the memo state."
  (declare (indent 2))
  `(let ((,counter-var 0)
         (decknix--hub-worktree-from-sessions-cache nil))
     (cl-letf (((symbol-function 'decknix--hub-worktree-discover-from-sessions--compute)
                (lambda (&optional _store) (cl-incf ,counter-var) ,result))
               ((symbol-function 'decknix--agent-tags-read)
                (lambda () nil)))
       ,@body)))

(ert-deftest decknix-hub-worktree-from-sessions-cache--reuses-when-mtime-unchanged ()
  "Repeat calls skip the compute when the tag-store mtime hasn't moved."
  (decknix-hub-cache-test--with-from-sessions-stub calls '(("o/r" . "/tmp/r"))
    (let ((decknix--agent-tags-cache-mtime '(1000 0 0 0)))
      (dotimes (_ 20)
        (should (equal '(("o/r" . "/tmp/r"))
                       (decknix--hub-worktree-discover-from-sessions))))
      (should (= 1 calls)))))

(ert-deftest decknix-hub-worktree-from-sessions-cache--recomputes-on-mtime-change ()
  "A tag-store mtime change forces the next call to recompute."
  (decknix-hub-cache-test--with-from-sessions-stub calls '(("o/r" . "/tmp/r"))
    (let ((decknix--agent-tags-cache-mtime '(1000 0 0 0)))
      (decknix--hub-worktree-discover-from-sessions)
      (setq decknix--agent-tags-cache-mtime '(1000 5 0 0))
      (decknix--hub-worktree-discover-from-sessions)
      (should (= 2 calls)))))

(ert-deftest decknix-hub-worktree-from-sessions-cache--nil-mtime-never-caches ()
  "When mtime is nil (e.g. tag store missing) the wrapper never caches.
Otherwise a first nil-mtime compute would poison the memo for the
rest of the session."
  (decknix-hub-cache-test--with-from-sessions-stub calls nil
    (let ((decknix--agent-tags-cache-mtime nil))
      (dotimes (_ 3)
        (decknix--hub-worktree-discover-from-sessions))
      (should (= 3 calls)))))

;; -- Path-facts sweep continuation -------------------------------------

(ert-deftest decknix-hub-path-facts-refresh-all/continues-a-sweep-that-ran-out ()
  "A sweep that spent its slice arms one idle continuation."
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-path-facts-continuation nil)
        (armed nil))
    (cl-letf (((symbol-function 'decknix--hub-path-facts-refresh)
               (lambda (&rest _) 'more))
              ((symbol-function 'run-with-idle-timer)
               (lambda (_secs _rep fn &rest _) (setq armed fn) 'cont)))
      (decknix--hub-path-facts-refresh-all)
      (should (eq armed #'decknix--hub-path-facts-refresh-all))
      (should (eq 'cont decknix--hub-path-facts-continuation)))))

(ert-deftest decknix-hub-path-facts-refresh-all/a-finished-sweep-arms-nothing ()
  (let ((decknix--hub-worktree-cache (make-hash-table :test 'equal))
        (decknix--hub-path-facts-continuation 'stale))
    (cl-letf (((symbol-function 'decknix--hub-path-facts-refresh) #'ignore)
              ((symbol-function 'run-with-idle-timer)
               (lambda (&rest _) (error "No continuation for a finished sweep"))))
      (decknix--hub-path-facts-refresh-all)
      (should-not decknix--hub-path-facts-continuation))))

;; -- Hub directory events ---------------------------------------------

(defvar agent-shell-workspace-sidebar-buffer-name "*Agent Sidebar*")

(defun decknix-hub-file-event-test--paints-for (name)
  "Return non-nil when a hub event for NAME schedules a sidebar paint."
  (let ((painted nil)
        (sidebar (get-buffer-create agent-shell-workspace-sidebar-buffer-name)))
    (unwind-protect
        (cl-letf (((symbol-function 'decknix--hub-event-filename) (lambda (_e) name))
                  ((symbol-function 'decknix--hub-refresh-wip) #'ignore)
                  ((symbol-function 'decknix--sidebar-schedule-paint)
                   (lambda (&rest _) (setq painted t))))
          (decknix--hub-on-file-change '(desc changed "ignored"))
          painted)
      (kill-buffer sidebar))))

(ert-deftest decknix-hub-on-file-change/a-daemon-file-repaints ()
  (should (decknix-hub-file-event-test--paints-for "github-wip.json")))

(ert-deftest decknix-hub-on-file-change/emacs-own-writes-do-not-repaint ()
  "A paint writes linked-prs.json; repainting on it made paints self-sustaining."
  (should-not (decknix-hub-file-event-test--paints-for "linked-prs.json"))
  (should-not (decknix-hub-file-event-test--paints-for "pr-cache.el"))
  (should-not (decknix-hub-file-event-test--paints-for ".cache-write-abc")))

(ert-deftest decknix-hub-write-linked-prs/an-unchanged-file-is-not-rewritten ()
  (let* ((dir (make-temp-file "hub-linked-" t))
         (decknix--hub-dir dir)
         (decknix--hub-cache-write-digests (make-hash-table :test 'equal))
         (writes 0))
    (unwind-protect
        (cl-letf* (((symbol-function 'agent-shell-buffers) (lambda () nil))
                   (orig (symbol-function 'write-region))
                   ((symbol-function 'write-region)
                    (lambda (&rest args) (cl-incf writes) (apply orig args))))
          (decknix--hub-write-linked-prs)
          (decknix--hub-write-linked-prs)
          (should (= 1 writes))
          (should (file-exists-p (expand-file-name "linked-prs.json" dir))))
      (delete-directory dir t))))

(provide 'decknix-hub-worktree-cache-test)
;;; decknix-hub-worktree-cache-test.el ends here
