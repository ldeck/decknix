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

(provide 'decknix-agent-session-lifecycle-test)
;;; decknix-agent-session-lifecycle-test.el ends here
