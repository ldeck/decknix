;;; decknix-agent-session-bulk-send-test.el --- Tests for session-bulk-send planner -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-session-bulk-send'.
;; Verifies the partition logic (idle → :send-now, busy → :enqueue)
;; without touching real buffers, timers, or network calls.

;;; Code:

(require 'ert)
(require 'decknix-agent-session-bulk-send)

;; Helper macro: creates real (live) buffers for each binding, runs
;; BODY with a mock busy-fn, then kills the buffers unconditionally.
(defmacro decknix-bulk-send-test--with-buffers (bindings &rest body)
  "Execute BODY with mock buffers bound per BINDINGS.
Each binding is (VAR BUSY-P) where VAR is bound to a fresh live buffer
and BUSY-P is what the mock busy predicate returns for that buffer."
  (declare (indent 1))
  `(let* ,(mapcar (lambda (b)
                    `(,(car b) (generate-new-buffer " *test-bulk-buf*")))
                  bindings)
     (unwind-protect
         (let ((busy-fn
                (lambda (buf)
                  (cond
                   ,@(mapcar (lambda (b)
                               `((eq buf ,(car b)) ,(cadr b)))
                             bindings)
                   (t nil)))))
           ,@body)
       ,@(mapcar (lambda (b) `(when (buffer-live-p ,(car b))
                                (kill-buffer ,(car b))))
                 bindings))))

(ert-deftest decknix-session-bulk-send--all-idle ()
  "All idle buffers go to :send-now; :enqueue is empty."
  (decknix-bulk-send-test--with-buffers ((a nil) (b nil))
    (let ((plan (decknix--session-bulk-send-plan (list a b) busy-fn)))
      (should (equal (list a b) (plist-get plan :send-now)))
      (should (null (plist-get plan :enqueue))))))

(ert-deftest decknix-session-bulk-send--all-busy ()
  "All busy buffers go to :enqueue; :send-now is empty."
  (decknix-bulk-send-test--with-buffers ((a t) (b t))
    (let ((plan (decknix--session-bulk-send-plan (list a b) busy-fn)))
      (should (null (plist-get plan :send-now)))
      (should (equal (list a b) (plist-get plan :enqueue))))))

(ert-deftest decknix-session-bulk-send--mixed ()
  "Mixed busy/idle buffers are partitioned correctly."
  (decknix-bulk-send-test--with-buffers ((a nil) (b t) (c nil))
    (let ((plan (decknix--session-bulk-send-plan (list a b c) busy-fn)))
      (should (equal (list a c) (plist-get plan :send-now)))
      (should (equal (list b)   (plist-get plan :enqueue))))))

(ert-deftest decknix-session-bulk-send--dead-buffers-dropped ()
  "Dead buffers are silently excluded from both lists."
  (decknix-bulk-send-test--with-buffers ((a nil))
    (let ((dead (generate-new-buffer " *test-dead*")))
      (kill-buffer dead)
      (let ((plan (decknix--session-bulk-send-plan (list a dead) busy-fn)))
        (should (equal (list a) (plist-get plan :send-now)))
        (should (null (plist-get plan :enqueue)))))))

(ert-deftest decknix-session-bulk-send--empty-input ()
  "Empty buffer list returns empty lists."
  (let ((plan (decknix--session-bulk-send-plan '() (lambda (_) nil))))
    (should (null (plist-get plan :send-now)))
    (should (null (plist-get plan :enqueue)))))

(ert-deftest decknix-session-bulk-send--preserves-order ()
  "Insertion order is preserved in both result lists."
  (decknix-bulk-send-test--with-buffers ((a nil) (b nil) (c nil))
    (let ((plan (decknix--session-bulk-send-plan (list c a b) busy-fn)))
      (should (equal (list c a b) (plist-get plan :send-now))))))

(ert-deftest decknix-session-bulk-send--busy-preserves-order ()
  "Insertion order is preserved in the :enqueue list."
  (decknix-bulk-send-test--with-buffers ((a t) (b t) (c t))
    (let ((plan (decknix--session-bulk-send-plan (list c a b) busy-fn)))
      (should (equal (list c a b) (plist-get plan :enqueue))))))

(provide 'decknix-agent-session-bulk-send-test)
;;; decknix-agent-session-bulk-send-test.el ends here
