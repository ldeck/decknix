;;; decknix-agent-compose-busy-test.el --- Tests for compose busy dispatch -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-compose-busy "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Characterisation tests for `decknix--compose-busy-action'.
;; The function is pure modulo `read-char-choice'; tests stub the
;; prompt via `cl-letf' so each branch exercises in <1ms and the
;; suite never blocks on the minibuffer.
;;
;; Regression context: this dispatch was previously inlined inside
;; `decknix-agent-compose-submit' as a `pcase' with `cl-return-from'
;; on the queue branch, which silently broke when the surrounding
;; function was not `cl-defun' (no implicit `cl-block', so the
;; throw bubbled up as `No catch for tag').  Carving the dispatch
;; out + pinning every branch here means a future refactor that
;; reintroduces the same shape-mismatch will fail the build before
;; it ever reaches a user.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-compose-busy)

(defmacro decknix-compose-busy-test--with-choice (char &rest body)
  "Stub `read-char-choice' to return CHAR while BODY runs.
Asserts that the prompt passed to `read-char-choice' matches the
production prompt verbatim and that the chars list is exactly
`(?i ?q ?c)' -- the busy-prompt contract is part of the carved
package's public surface."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'read-char-choice)
              (lambda (prompt chars &rest _)
                (should (equal prompt decknix--compose-busy-prompt))
                (should (equal chars '(?i ?q ?c)))
                ,char)))
     ,@body))

;; -- not-busy fast path --------------------------------------------

(ert-deftest decknix-agent-compose-busy/not-busy-returns-submit ()
  "When BUSY-P is nil the function returns `submit' immediately
without prompting (read-char-choice would fail the suite if
called)."
  (cl-letf (((symbol-function 'read-char-choice)
             (lambda (&rest _)
               (error "read-char-choice should not be called when idle"))))
    (should (eq (decknix--compose-busy-action nil) 'submit))))

;; -- busy + each user choice ---------------------------------------

(ert-deftest decknix-agent-compose-busy/busy-i-returns-interrupt-submit ()
  "User pressing `?i' returns `interrupt-submit'."
  (decknix-compose-busy-test--with-choice ?i
    (should (eq (decknix--compose-busy-action t) 'interrupt-submit))))

(ert-deftest decknix-agent-compose-busy/busy-q-returns-queue ()
  "User pressing `?q' returns `queue' (regression: this branch
used to call `cl-return-from' inside a plain `defun', producing
`No catch for tag: --cl-block-decknix-agent-compose-submit--')."
  (decknix-compose-busy-test--with-choice ?q
    (should (eq (decknix--compose-busy-action t) 'queue))))

(ert-deftest decknix-agent-compose-busy/busy-c-returns-cancel ()
  "User pressing `?c' returns `cancel'."
  (decknix-compose-busy-test--with-choice ?c
    (should (eq (decknix--compose-busy-action t) 'cancel))))

;; -- prompt contract -----------------------------------------------

(ert-deftest decknix-agent-compose-busy/prompt-mentions-three-actions ()
  "Prompt string advertises all three actions (i/q/c) so the user
can read the menu without consulting docs.  The `[X]name' shape
(brackets around the keyboard char) is the contract -- callers
of `read-char-choice' rely on this convention to mean `the
bracketed letter is the key to press'."
  (should (string-match-p "\\[i\\]nterrupt" decknix--compose-busy-prompt))
  (should (string-match-p "\\[q\\]ueue" decknix--compose-busy-prompt))
  (should (string-match-p "\\[c\\]ancel" decknix--compose-busy-prompt)))

(ert-deftest decknix-agent-compose-busy/all-actions-are-distinct-symbols ()
  "All four return symbols are distinct -- `pcase' on the result
in the caller can't accidentally collapse two cases."
  (let ((actions (list
                  (decknix--compose-busy-action nil)
                  (decknix-compose-busy-test--with-choice ?i
                    (decknix--compose-busy-action t))
                  (decknix-compose-busy-test--with-choice ?q
                    (decknix--compose-busy-action t))
                  (decknix-compose-busy-test--with-choice ?c
                    (decknix--compose-busy-action t)))))
    (should (= (length actions) (length (cl-remove-duplicates actions))))
    (should (member 'submit actions))
    (should (member 'interrupt-submit actions))
    (should (member 'queue actions))
    (should (member 'cancel actions))))

(provide 'decknix-agent-compose-busy-test)
;;; decknix-agent-compose-busy-test.el ends here
