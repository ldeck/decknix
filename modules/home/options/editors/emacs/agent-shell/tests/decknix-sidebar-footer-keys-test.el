;;; decknix-sidebar-footer-keys-test.el --- Tests for footer key alists -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-footer-keys "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the two footer key-alist
;; builders.  The footer rendering side-effect (which consumes
;; these alists via `decknix--sidebar-render-key-group') is owned
;; by workspace-bulk and is out of scope for this suite -- only
;; the data shape and the one conditional inclusion of `p' / `P'
;; under `decknix--sidebar-previous-sessions' are pinned here.

;;; Code:

(require 'ert)
(require 'decknix-sidebar-footer-keys)

;; Promote the free var the module reads so tests can `let'-bind
;; it dynamically -- mirrors the pattern in
;; `decknix-test-helpers.el' (defvar with nil initialiser, as a
;; bare `(defvar X)' would only be a compiler hint and the let
;; would bind lexically).
(defvar decknix--sidebar-previous-sessions nil)

;; -- Quick keys (constant) ---------------------------------------

(ert-deftest decknix-sidebar-footer-keys--quick-keys-shape ()
  "Quick alist returns the canonical entries in label-sorted order.
The `H' / hygiene… entry sits between `actions…' and `new', matching
the alphabetical-by-label ordering the footer advertises."
  (should (equal
           '(("a"   . "actions…")
             ("H"   . "hygiene…")
             ("c"   . "new")
             ("RET" . "open")
             ("q"   . "quit")
             ("g"   . "refresh")
             ("T"   . "toggles"))
           (decknix--sidebar-footer-quick-keys))))

(ert-deftest decknix-sidebar-footer-keys--quick-keys-pure ()
  "Quick alist is a pure constant -- two calls are `equal'."
  (should (equal (decknix--sidebar-footer-quick-keys)
                 (decknix--sidebar-footer-quick-keys))))

;; -- Nav keys (conditional on previous-sessions) -----------------

(ert-deftest decknix-sidebar-footer-keys--nav-keys-no-previous ()
  "Without previous sessions, nav alist omits `p' / `P'."
  (let ((decknix--sidebar-previous-sessions nil))
    (should (equal
             '(("r" . "requests")
               ("w" . "wip")
               ("l" . "live")
               ("s" . "sessions…"))
             (decknix--sidebar-footer-nav-keys)))))

(ert-deftest decknix-sidebar-footer-keys--nav-keys-with-previous ()
  "With previous sessions, nav alist inserts `p' / `P' before `s'."
  (let ((decknix--sidebar-previous-sessions '(:dummy)))
    (should (equal
             '(("r" . "requests")
               ("w" . "wip")
               ("l" . "live")
               ("p" . "restore…")
               ("P" . "restore all")
               ("s" . "sessions…"))
             (decknix--sidebar-footer-nav-keys)))))

(ert-deftest decknix-sidebar-footer-keys--nav-keys-keys-are-strings ()
  "Each entry is a (STRING . STRING) cons."
  (let ((decknix--sidebar-previous-sessions nil))
    (dolist (cell (decknix--sidebar-footer-nav-keys))
      (should (stringp (car cell)))
      (should (stringp (cdr cell))))))

(ert-deftest decknix-sidebar-footer-keys--nav-keys-restore-positioned ()
  "Restore entries (when present) sit immediately before `s'."
  (let ((decknix--sidebar-previous-sessions '(:any)))
    (let* ((alist (decknix--sidebar-footer-nav-keys))
           (keys (mapcar #'car alist))
           (s-pos (cl-position "s" keys :test #'string=))
           (p-pos (cl-position "p" keys :test #'string=))
           (P-pos (cl-position "P" keys :test #'string=)))
      (should (and s-pos p-pos P-pos))
      (should (= p-pos (- s-pos 2)))
      (should (= P-pos (- s-pos 1))))))

(ert-deftest decknix-sidebar-footer-keys--nav-keys-suffix-is-sessions ()
  "Sessions entry is always the final element, regardless of branch."
  (let ((decknix--sidebar-previous-sessions nil))
    (should (equal '("s" . "sessions…")
                   (car (last (decknix--sidebar-footer-nav-keys))))))
  (let ((decknix--sidebar-previous-sessions '(:any)))
    (should (equal '("s" . "sessions…")
                   (car (last (decknix--sidebar-footer-nav-keys)))))))

(provide 'decknix-sidebar-footer-keys-test)
;;; decknix-sidebar-footer-keys-test.el ends here
