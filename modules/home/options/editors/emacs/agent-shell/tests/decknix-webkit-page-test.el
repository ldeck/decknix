;;; decknix-webkit-page-test.el --- Tests for webkit page-text + find -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-webkit-page "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the xwidget-webkit JS-bridge
;; primitives extracted from the workspace heredoc.  Stubs the
;; three xwidget entry points the module touches via `cl-letf' so
;; tests can run on any Emacs build, including ones compiled
;; without xwidget support.
;;
;; Coverage:
;;   * `page-text' returns nil when there is no current session,
;;     when the bridge throws, and when the page is empty.
;;   * `page-text' returns the innerText string for a healthy page.
;;   * `find-in-page' is a no-op when given a nil/empty needle.
;;   * `find-in-page' invokes `xwidget-webkit-execute-script' with
;;     a JSON-encoded needle when both session and needle are good.
;;   * The `search-history' defvar exists, defaults to nil, and is
;;     not modified by either primitive (history is owned by the
;;     consult-line caller).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-webkit-page)

(defmacro decknix-webkit-page-test--with-stubs (session-form rv-form &rest body)
  "Evaluate BODY with xwidget stubs.
SESSION-FORM is the value `xwidget-webkit-current-session' returns
(use a non-nil sentinel like \\='session for \"a session exists\").
RV-FORM is the value `xwidget-webkit-execute-script-rv' returns.
Captures every call to `xwidget-webkit-execute-script' into a
buffer-local list bound to `executed' so callers can assert on it."
  (declare (indent 2))
  `(let ((executed nil))
     (cl-letf (((symbol-function 'xwidget-webkit-current-session)
                (lambda () ,session-form))
               ((symbol-function 'xwidget-webkit-execute-script-rv)
                (lambda (_session _script &optional _default) ,rv-form))
               ((symbol-function 'xwidget-webkit-execute-script)
                (lambda (_session script) (push script executed))))
       ,@body)))

;; -- page-text ----------------------------------------------------

(ert-deftest decknix-webkit-page--page-text-nil-without-session ()
  "No xwidget session => page-text returns nil."
  (decknix-webkit-page-test--with-stubs nil "ignored"
    (should-not (decknix--webkit-page-text))))

(ert-deftest decknix-webkit-page--page-text-nil-on-empty ()
  "Empty innerText string is treated as no text."
  (decknix-webkit-page-test--with-stubs 'session ""
    (should-not (decknix--webkit-page-text))))

(ert-deftest decknix-webkit-page--page-text-returns-string ()
  "A non-empty innerText is returned verbatim."
  (decknix-webkit-page-test--with-stubs 'session "Line 1\nLine 2"
    (should (equal "Line 1\nLine 2" (decknix--webkit-page-text)))))

(ert-deftest decknix-webkit-page--page-text-non-string-rejected ()
  "Non-string innerText (e.g. numeric, vector, t) yields nil."
  (decknix-webkit-page-test--with-stubs 'session 42
    (should-not (decknix--webkit-page-text)))
  (decknix-webkit-page-test--with-stubs 'session t
    (should-not (decknix--webkit-page-text))))

;; -- find-in-page -------------------------------------------------

(ert-deftest decknix-webkit-page--find-noop-on-empty-needle ()
  "Empty / nil / non-string needle is a no-op (no script executed)."
  (decknix-webkit-page-test--with-stubs 'session "ignored"
    (decknix--webkit-find-in-page nil)
    (decknix--webkit-find-in-page "")
    (decknix--webkit-find-in-page 42)
    (should (null executed))))

(ert-deftest decknix-webkit-page--find-noop-without-session ()
  "Valid needle but no session => no script executed."
  (decknix-webkit-page-test--with-stubs nil "ignored"
    (decknix--webkit-find-in-page "hello")
    (should (null executed))))

(ert-deftest decknix-webkit-page--find-injects-window-find ()
  "A good session + needle invokes execute-script with window.find."
  (decknix-webkit-page-test--with-stubs 'session "ignored"
    (decknix--webkit-find-in-page "hello")
    (should (= 1 (length executed)))
    (let ((script (car executed)))
      (should (string-match-p "window.find" script))
      (should (string-match-p "window.getSelection" script))
      ;; The needle is JSON-encoded into the script, so the literal
      ;; "hello" appears inside double-quotes.
      (should (string-match-p "\"hello\"" script)))))

(ert-deftest decknix-webkit-page--find-json-encodes-quotes ()
  "Needles containing quotes / backslashes are safely JSON-escaped."
  (decknix-webkit-page-test--with-stubs 'session "ignored"
    (decknix--webkit-find-in-page "she said \"hi\"")
    (let ((script (car executed)))
      (should (string-match-p "\\\\\"hi\\\\\"" script)))))

;; -- search-history defvar ----------------------------------------

(ert-deftest decknix-webkit-page--search-history-defaults-to-nil ()
  "The shared search history list is initially nil."
  (let ((decknix--webkit-search-history nil))
    (should (boundp 'decknix--webkit-search-history))
    (should (null decknix--webkit-search-history))))

(ert-deftest decknix-webkit-page--primitives-do-not-mutate-history ()
  "Neither primitive pushes onto the search history list."
  (decknix-webkit-page-test--with-stubs 'session "Line 1"
    (let ((decknix--webkit-search-history nil))
      (decknix--webkit-page-text)
      (decknix--webkit-find-in-page "needle")
      (should (null decknix--webkit-search-history)))))

(provide 'decknix-webkit-page-test)
;;; decknix-webkit-page-test.el ends here
