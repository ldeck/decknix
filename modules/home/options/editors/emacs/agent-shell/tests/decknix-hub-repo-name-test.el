;;; decknix-hub-repo-name-test.el --- Tests for hub repo-name cap -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-repo-name "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the hub repo-name cap cluster
;; extracted from the hub heredoc.  Covers:
;;
;; - the documented default cap (`short')
;; - the pure truncator under each of the three caps + the
;;   defensive fallback when the defvar is set to an unknown
;;   symbol
;; - the cycler's three-step round-trip (short -> medium -> none
;;   -> short) and its no-op behaviour when the sidebar buffer is
;;   absent.
;;
;; The interactive cycler's `agent-shell-workspace-sidebar-refresh'
;; callback is guarded by
;; `(get-buffer agent-shell-workspace-sidebar-buffer-name)' (the
;; upstream buffer name is "*Agent Sidebar*")
;; in the module, so simply running tests in a fresh batch Emacs
;; (where that buffer never exists) suffices to skip the call.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-repo-name)

;; -- defaults -----------------------------------------------------

(ert-deftest decknix-hub-repo-name--default-is-short ()
  "Documented default cap matches the constant at module load."
  (should (eq decknix--hub-repo-name-cap 'short)))

;; -- apply --------------------------------------------------------

(ert-deftest decknix-hub-repo-name--apply-short-truncates-at-12 ()
  "`short' cap truncates strings longer than 12 chars."
  (let ((decknix--hub-repo-name-cap 'short))
    (should (equal "exact-twelve"
                   (decknix--hub-repo-name-apply "exact-twelve")))
    ;; "thirteenchars" is 13 chars; truncated to first 12 = "thirteenchar".
    (should (equal "thirteenchar"
                   (decknix--hub-repo-name-apply "thirteenchars")))))

(ert-deftest decknix-hub-repo-name--apply-short-passes-through-shorter ()
  "Strings <= 12 chars are returned unchanged under `short'."
  (let ((decknix--hub-repo-name-cap 'short))
    (should (equal "abc"  (decknix--hub-repo-name-apply "abc")))
    (should (equal ""     (decknix--hub-repo-name-apply "")))
    (should (equal "abcdefghijkl"  ; exactly 12
                   (decknix--hub-repo-name-apply "abcdefghijkl")))))

(ert-deftest decknix-hub-repo-name--apply-medium-truncates-at-20 ()
  "`medium' cap truncates strings longer than 20 chars."
  (let ((decknix--hub-repo-name-cap 'medium))
    (should (equal "twentycharsexactly00"
                   (decknix--hub-repo-name-apply "twentycharsexactly00")))
    (should (equal "twentyonecharsxxxxxx"
                   (decknix--hub-repo-name-apply "twentyonecharsxxxxxxY")))))

(ert-deftest decknix-hub-repo-name--apply-none-never-truncates ()
  "`none' cap returns the input unchanged regardless of length."
  (let ((decknix--hub-repo-name-cap 'none)
        (long (make-string 500 ?x)))
    (should (equal long (decknix--hub-repo-name-apply long)))))

(ert-deftest decknix-hub-repo-name--apply-unknown-falls-back-to-12 ()
  "Unknown cap symbols fall back to the `short' (12-char) limit."
  (let ((decknix--hub-repo-name-cap 'bogus))
    (should (equal "thirteenchar"
                   (decknix--hub-repo-name-apply "thirteenchars")))))

;; -- cycle --------------------------------------------------------

(ert-deftest decknix-hub-repo-name--cycle-short-to-medium ()
  "`short' -> `medium'."
  (let ((decknix--hub-repo-name-cap 'short))
    (call-interactively #'decknix--hub-cycle-repo-name-cap)
    (should (eq decknix--hub-repo-name-cap 'medium))))

(ert-deftest decknix-hub-repo-name--cycle-medium-to-none ()
  "`medium' -> `none'."
  (let ((decknix--hub-repo-name-cap 'medium))
    (call-interactively #'decknix--hub-cycle-repo-name-cap)
    (should (eq decknix--hub-repo-name-cap 'none))))

(ert-deftest decknix-hub-repo-name--cycle-none-to-short ()
  "`none' -> `short' (closes the loop)."
  (let ((decknix--hub-repo-name-cap 'none))
    (call-interactively #'decknix--hub-cycle-repo-name-cap)
    (should (eq decknix--hub-repo-name-cap 'short))))

(ert-deftest decknix-hub-repo-name--cycle-unknown-falls-back-to-short ()
  "Unknown cap symbols cycle to `short' (defensive fallback)."
  (let ((decknix--hub-repo-name-cap 'bogus))
    (call-interactively #'decknix--hub-cycle-repo-name-cap)
    (should (eq decknix--hub-repo-name-cap 'short))))

(ert-deftest decknix-hub-repo-name--cycle-round-trip ()
  "Three cycles return to the original state."
  (let ((decknix--hub-repo-name-cap 'short))
    (dotimes (_ 3)
      (call-interactively #'decknix--hub-cycle-repo-name-cap))
    (should (eq decknix--hub-repo-name-cap 'short))))

(provide 'decknix-hub-repo-name-test)
;;; decknix-hub-repo-name-test.el ends here
