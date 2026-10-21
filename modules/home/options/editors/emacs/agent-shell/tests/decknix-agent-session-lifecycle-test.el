;;; decknix-agent-session-lifecycle-test.el --- Tests for bulk quit/detach -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The broker rule is the part worth pinning.  Under brokering a buffer's
;; process is only the socat client, so `kill-buffer' DETACHES and leaves the
;; agent running -- one was found alive two hours after its buffer closed.
;; Quitting must therefore stop the broker, but ONLY when no surviving
;; session is attached to it: stopping a shared broker kills a session the
;; user did not select.
;;
;; That decision is pure here precisely so it can be tested without
;; processes, which is the only way to test "would this have killed the
;; wrong agent".

;;; Code:

(require 'ert)
(require 'decknix-agent-session-lifecycle)

(ert-deftest decknix-lifecycle--a-broker-only-the-doomed-hold-is-stoppable ()
  "Nothing survives holding `k1', so it is safe to stop."
  (let ((a (generate-new-buffer " a")) (b (generate-new-buffer " b")))
    (unwind-protect
        (should-not (member "k1" (decknix-session-lifecycle-surviving-keys
                                  (list a b)
                                  (list (cons a "k1") (cons b "k1")))))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest decknix-lifecycle--a-shared-broker-survives ()
  "`b' is NOT being quit and holds the same broker, so stopping it would
kill a session the user did not select."
  (let ((a (generate-new-buffer " a")) (b (generate-new-buffer " b")))
    (unwind-protect
        (should (member "k1" (decknix-session-lifecycle-surviving-keys
                              (list a)
                              (list (cons a "k1") (cons b "k1")))))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest decknix-lifecycle--unrelated-brokers-are-reported-as-surviving ()
  (let ((a (generate-new-buffer " a")) (b (generate-new-buffer " b")))
    (unwind-protect
        (should (equal '("k2") (decknix-session-lifecycle-surviving-keys
                                (list a)
                                (list (cons a "k1") (cons b "k2")))))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest decknix-lifecycle--nil-keys-are-dropped ()
  "A session with no broker contributes no claim, and a nil left in the
list would be compared against by the stop predicate."
  (let ((a (generate-new-buffer " a")) (b (generate-new-buffer " b")))
    (unwind-protect
        (should-not (memq nil (decknix-session-lifecycle-surviving-keys
                               (list a)
                               (list (cons a "k1") (cons b nil)))))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest decknix-lifecycle--keys-are-deduplicated ()
  (let ((a (generate-new-buffer " a")) (b (generate-new-buffer " b")))
    (unwind-protect
        (should (equal '("k1") (decknix-session-lifecycle-surviving-keys
                                nil
                                (list (cons a "k1") (cons b "k1")))))
      (kill-buffer a) (kill-buffer b))))

;; --- quit and detach --------------------------------------------------

(ert-deftest decknix-lifecycle--quit-declined-returns-nil-not-zero ()
  "A caller must be able to tell a refusal from an empty selection; zero
would read as \"nothing was there\" and report success."
  (let ((buf (generate-new-buffer " q")))
    (unwind-protect
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
          (should-not (decknix-session-lifecycle-quit (list buf)))
          (should (buffer-live-p buf)))
      (ignore-errors (kill-buffer buf)))))

(ert-deftest decknix-lifecycle--quit-kills-on-confirmation ()
  (let ((buf (generate-new-buffer " q2")))
    (unwind-protect
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'agent-shell-buffers) (lambda () nil)))
          (should (= 1 (decknix-session-lifecycle-quit (list buf))))
          (should-not (buffer-live-p buf)))
      (ignore-errors (kill-buffer buf)))))

(ert-deftest decknix-lifecycle--noconfirm-skips-the-prompt ()
  "The Session Board confirms itself, naming the lanes, so it must be able
to suppress the second prompt."
  (let ((buf (generate-new-buffer " q3")))
    (unwind-protect
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (&rest _) (error "must not prompt")))
                  ((symbol-function 'agent-shell-buffers) (lambda () nil)))
          (should (= 1 (decknix-session-lifecycle-quit (list buf) t))))
      (ignore-errors (kill-buffer buf)))))

(ert-deftest decknix-lifecycle--dead-buffers-are-not-counted ()
  "A session that exited between render and action must not inflate the
count the user is shown."
  (let ((live (generate-new-buffer " l")) (dead (generate-new-buffer " d")))
    (kill-buffer dead)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-buffers) (lambda () nil)))
          (should (= 1 (decknix-session-lifecycle-quit (list live dead) t))))
      (ignore-errors (kill-buffer live)))))

(ert-deftest decknix-lifecycle--quitting-nothing-is-nil ()
  (cl-letf (((symbol-function 'yes-or-no-p)
             (lambda (&rest _) (error "must not prompt"))))
    (should-not (decknix-session-lifecycle-quit nil))))

(ert-deftest decknix-lifecycle--detach-never-prompts ()
  "Detaching is reversible and the agent keeps working; a prompt there
would train the user to confirm without reading."
  (let ((buf (generate-new-buffer " dt")))
    (unwind-protect
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (&rest _) (error "must not prompt"))))
          (should (= 1 (decknix-session-lifecycle-detach (list buf))))
          (should-not (buffer-live-p buf)))
      (ignore-errors (kill-buffer buf)))))

(ert-deftest decknix-lifecycle--detach-does-not-stop-brokers ()
  "The whole point: the agent survives."
  (let ((buf (generate-new-buffer " dt2"))
        (stopped nil))
    (unwind-protect
        (cl-letf (((symbol-function 'decknix-agent-broker-stop)
                   (lambda (k) (push k stopped))))
          (decknix-session-lifecycle-detach (list buf))
          (should-not stopped))
      (ignore-errors (kill-buffer buf)))))

(ert-deftest decknix-lifecycle--prompt-is-singular-for-one ()
  (should (string-match-p "1 session " (decknix-session-lifecycle-prompt 1)))
  (should (string-match-p "3 sessions " (decknix-session-lifecycle-prompt 3))))

(ert-deftest decknix-lifecycle--a-buffer-with-no-broker-key-is-nil-not-an-error ()
  "`buffer-local-value' SIGNALS void-variable when nothing has defined the
variable.  In an isolated package build nothing has, so this read was an
error rather than a nil -- which the full suite hid, because there other
modules had loaded the broker layer."
  (let ((buf (generate-new-buffer " nokey")))
    (unwind-protect
        (should-not (decknix-session-lifecycle--broker-key buf))
      (kill-buffer buf))))

(ert-deftest decknix-lifecycle--a-dead-buffer-has-no-broker-key ()
  (let ((buf (generate-new-buffer " dead")))
    (kill-buffer buf)
    (should-not (decknix-session-lifecycle--broker-key buf))))

;; --- discard ----------------------------------------------------------

(defmacro decknix-lifecycle-test--with-brokered (bindings &rest body)
  "Run BODY with BINDINGS (VAR KEY) as live buffers carrying broker KEY.
`decknix-agent-broker-stop' is stubbed to record into `stopped'."
  (declare (indent 1))
  `(let* (,@(mapcar (lambda (b) `(,(car b) (generate-new-buffer " brokered"))) bindings)
          (stopped nil))
     ,@(mapcar (lambda (b)
                 `(with-current-buffer ,(car b)
                    (setq-local decknix--agent-broker-key ,(cadr b))))
               bindings)
     (unwind-protect
         (cl-letf (((symbol-function 'decknix-agent-broker-stop)
                    (lambda (k) (push k stopped)))
                   ((symbol-function 'decknix--agent-broker-stop-p)
                    (lambda (k others) (and k (not (member k others)))))
                   ((symbol-function 'agent-shell-buffers)
                    (lambda () (list ,@(mapcar #'car bindings)))))
           ,@body)
       (dolist (b (list ,@(mapcar #'car bindings)))
         (ignore-errors (kill-buffer b))))))

(ert-deftest decknix-lifecycle--discard-stops-the-broker-and-kills ()
  "The reason it exists: a plain kill leaves the broker to be reattached
on the next start, which is how five killed reviews came back."
  (decknix-lifecycle-test--with-brokered ((a "k1"))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (= 1 (decknix-session-lifecycle-discard (list a))))
      (should (equal '("k1") stopped))
      (should-not (buffer-live-p a)))))

(ert-deftest decknix-lifecycle--discard-declined-touches-nothing ()
  (decknix-lifecycle-test--with-brokered ((a "k1"))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (should-not (decknix-session-lifecycle-discard (list a)))
      (should-not stopped)
      (should (buffer-live-p a)))))

(ert-deftest decknix-lifecycle--discard-spares-a-broker-another-session-holds ()
  (decknix-lifecycle-test--with-brokered ((a "k1") (b "k1"))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (decknix-session-lifecycle-discard (list a))
      (should-not stopped)
      (should (buffer-live-p b)))))

(ert-deftest decknix-lifecycle--sidebar-discard-takes-the-row-at-point ()
  (decknix-lifecycle-test--with-brokered ((a "k1"))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'agent-shell-workspace-sidebar--buffer-at-point)
               (lambda () a)))
      (decknix-sidebar-discard-at-point)
      (should (equal '("k1") stopped))
      (should-not (buffer-live-p a)))))

(ert-deftest decknix-lifecycle--sidebar-discard-on-an-empty-row-is-a-user-error ()
  (cl-letf (((symbol-function 'agent-shell-workspace-sidebar--buffer-at-point)
             (lambda () nil)))
    (should-error (decknix-sidebar-discard-at-point) :type 'user-error)))

(ert-deftest decknix-lifecycle--discard-prompt-names-one-and-counts-many ()
  (let ((a (generate-new-buffer "*Claude: one*")) (b (generate-new-buffer " b")))
    (unwind-protect
        (progn
          (should (string-match-p "Discard \\*Claude: one\\*\\?"
                                  (decknix-session-lifecycle-discard-prompt (list a))))
          (should (string-match-p "Discard 2 sessions\\?"
                                  (decknix-session-lifecycle-discard-prompt (list a b))))
          (should (string-match-p "will not reattach"
                                  (decknix-session-lifecycle-discard-prompt (list a)))))
      (kill-buffer a) (kill-buffer b))))

(provide 'decknix-agent-session-lifecycle-test)
;;; decknix-agent-session-lifecycle-test.el ends here
