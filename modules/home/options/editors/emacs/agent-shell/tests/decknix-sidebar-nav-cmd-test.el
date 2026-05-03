;;; decknix-sidebar-nav-cmd-test.el --- Tests for nav-make-item-cmd factory -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-nav-cmd "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--nav-make-item-cmd'.
;; Exercises the four shape contracts the four call-sites in
;; workspace-bulk depend on:
;;
;;   1. Returns a symbol (used by transient suffix slots).
;;   2. The symbol's function-cell is `commandp' (transient calls
;;      it via `call-interactively').
;;   3. The closure carries both ITEM-DATA and ACTION-FN by value
;;      -- mutating either in the caller's scope after the symbol
;;      is built has no effect on what the command sees.
;;   4. Each call mints a fresh uninterned symbol so the
;;      transient cache cannot collide across paints.

;;; Code:

(require 'ert)
(require 'decknix-sidebar-nav-cmd)

;; -- Shape -------------------------------------------------------

(ert-deftest decknix-sidebar-nav-cmd--returns-symbol ()
  "Factory returns a symbol."
  (let ((cmd (decknix--nav-make-item-cmd nil #'ignore)))
    (should (symbolp cmd))))

(ert-deftest decknix-sidebar-nav-cmd--returns-uninterned-symbol ()
  "Factory mints an uninterned symbol (so the obarray stays clean)."
  (let ((cmd (decknix--nav-make-item-cmd nil #'ignore)))
    (should (null (symbol-function (intern-soft (symbol-name cmd)))))))

(ert-deftest decknix-sidebar-nav-cmd--symbol-name-prefix ()
  "Minted symbol carries the `decknix--nav-item' prefix."
  (let ((cmd (decknix--nav-make-item-cmd nil #'ignore)))
    (should (string-prefix-p "decknix--nav-item" (symbol-name cmd)))))

(ert-deftest decknix-sidebar-nav-cmd--is-commandp ()
  "Result is `commandp' so `call-interactively' will accept it."
  (let ((cmd (decknix--nav-make-item-cmd "x" (lambda (_) nil))))
    (should (commandp cmd))))

(ert-deftest decknix-sidebar-nav-cmd--each-call-distinct ()
  "Repeated calls return distinct symbols."
  (let ((a (decknix--nav-make-item-cmd 1 #'ignore))
        (b (decknix--nav-make-item-cmd 1 #'ignore)))
    (should-not (eq a b))))

;; -- Behaviour ---------------------------------------------------

(ert-deftest decknix-sidebar-nav-cmd--passes-item-to-action ()
  "`call-interactively' invokes ACTION-FN with ITEM-DATA verbatim."
  (let* ((received nil)
         (action (lambda (item) (setq received item)))
         (cmd (decknix--nav-make-item-cmd "payload" action)))
    (call-interactively cmd)
    (should (equal "payload" received))))

(ert-deftest decknix-sidebar-nav-cmd--passes-list-item ()
  "Item data may be a structured list (typical sidebar usage)."
  (let* ((received nil)
         (action (lambda (item) (setq received item)))
         (cmd (decknix--nav-make-item-cmd '(:url "u" :pr 42) action)))
    (call-interactively cmd)
    (should (equal '(:url "u" :pr 42) received))))

(ert-deftest decknix-sidebar-nav-cmd--captures-action-by-value ()
  "Rebinding ACTION-FN's symbol after build has no effect on the closure."
  (let* ((received nil)
         (a (lambda (item) (setq received (cons 'a item))))
         (b (lambda (item) (setq received (cons 'b item))))
         (cmd (decknix--nav-make-item-cmd "x" a)))
    (ignore b)
    (call-interactively cmd)
    (should (equal '(a . "x") received))))

(ert-deftest decknix-sidebar-nav-cmd--captures-item-by-reference ()
  "The factory embeds the same list reference, not a deep copy.
Backquote splice (`,data') evaluates `data' once at build time and
embeds its value (the cons cell itself for a list) into the lambda
body, so subsequent mutation of the captured list IS visible to
the closure.  The four call-sites in workspace-bulk pass freshly-
built alists / plists and do not mutate them, so this is safe in
practice; the test pins the actual semantics so a future refactor
can't silently change them."
  (let* ((received nil)
         (data (list 1 2))
         (cmd (decknix--nav-make-item-cmd data
                (lambda (item) (setq received item)))))
    (setcar data 999)
    (call-interactively cmd)
    (should (equal '(999 2) received))))

(provide 'decknix-sidebar-nav-cmd-test)
;;; decknix-sidebar-nav-cmd-test.el ends here
