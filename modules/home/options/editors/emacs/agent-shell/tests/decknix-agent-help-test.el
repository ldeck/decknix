;;; decknix-agent-help-test.el --- Tests for help renderers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-help "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-help'.  The four
;; rendering functions are pure modulo `display-buffer' /
;; `special-mode' (the help-buffer popup) and the upstream auggie
;; helpers (welcome path).  Tests stub the popup so the suite
;; never touches a live frame and stub the upstream + carved
;; sibling deps so we can exercise the welcome / functions paths
;; end-to-end without their real implementations.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-help)

;; `decknix-agent-help' forward-declares `yas-snippet-dirs' via
;; `defvar' without a value (compiler hint only).  Tests need to
;; `let'-bind it via `symbol-value' / `cl-letf', which requires
;; the variable to be globally bound.  `defvar' WITH an
;; initialiser establishes the binding.  See AGENTS.md
;; "Lexical-binding tests, dynamic free vars".
(defvar yas-snippet-dirs nil)

(defmacro decknix-help-test--capture (call &rest body)
  "Stub `display-buffer' to capture the buffer's contents and run BODY.
The captured contents are bound to the symbol `captured' inside
BODY; the call to CALL drives the side-effect path that pops the
help buffer.  Asserts the buffer is in `special-mode' (read-only
+ q-to-quit binding) so the contract about `q' as the dismiss key
holds across all three help variants."
  (declare (indent 1))
  `(let ((captured nil)
         (captured-major-mode nil))
     (cl-letf (((symbol-function 'display-buffer)
                (lambda (buf &rest _)
                  (with-current-buffer buf
                    (setq captured (buffer-string))
                    (setq captured-major-mode major-mode))
                  buf)))
       ,call
       (should (stringp captured))
       (should (eq captured-major-mode 'special-mode))
       ,@body)))

;; -- decknix--agent-help-show ------------------------------------

(ert-deftest decknix-agent-help-show--inserts-content-in-named-buffer ()
  "Pops a buffer with the given NAME and inserts CONTENT verbatim."
  (decknix-help-test--capture
      (decknix--agent-help-show "*Agent Help Probe*" "hello world")
    (should (equal captured "hello world"))
    (should (get-buffer "*Agent Help Probe*"))
    (kill-buffer "*Agent Help Probe*")))

(ert-deftest decknix-agent-help-show--erases-existing-content ()
  "Reusing the same buffer name erases prior content first."
  (let ((display-buffer-overriding-action
         '((lambda (buf &rest _) buf))))
    (decknix--agent-help-show "*Agent Help Probe*" "first")
    (decknix--agent-help-show "*Agent Help Probe*" "second")
    (with-current-buffer "*Agent Help Probe*"
      (should (equal (buffer-string) "second")))
    (kill-buffer "*Agent Help Probe*")))

;; -- decknix-agent-help-keys -------------------------------------

(ert-deftest decknix-agent-help-keys--shows-keybinding-reference ()
  "Pops the keybinding reference buffer with header + footer."
  (decknix-help-test--capture
      (decknix-agent-help-keys)
    (should (string-match-p "Agent Shell — Keybinding Reference"
                            captured))
    (should (string-match-p "Press q to close this buffer"
                            captured))
    (kill-buffer "*Agent Keys*")))

(ert-deftest decknix-agent-help-keys--lists-major-prefix-sections ()
  "Reference advertises the canonical prefix groupings so users
can navigate by prefix family without hunting through the body."
  (decknix-help-test--capture
      (decknix-agent-help-keys)
    (dolist (section '("Sessions  (C-c s …)"
                       "Templates  (C-c t …)"
                       "Commands  (C-c c …)"
                       "Tags — session  (C-c T …)"
                       "Tags — global  (C-c A T …)"
                       "Context  (C-c i …)"
                       "Global  (C-c A …)"))
      (should (string-match-p (regexp-quote section) captured)))
    (kill-buffer "*Agent Keys*")))

;; -- decknix-agent-help-tutorial ---------------------------------

(ert-deftest decknix-agent-help-tutorial--shows-numbered-sections ()
  "Tutorial enumerates six sections in fixed order."
  (decknix-help-test--capture
      (decknix-agent-help-tutorial)
    (should (string-match-p "Agent Shell — Tutorial" captured))
    (dolist (section '("1. Getting Started"
                       "2. Sessions"
                       "3. Templates & Commands"
                       "4. Tags & Organisation"
                       "5. Context Awareness"
                       "6. Multi-Session Workflow"))
      (should (string-match-p (regexp-quote section) captured)))
    (kill-buffer "*Agent Tutorial*")))

;; -- decknix-agent-help-functions --------------------------------

(ert-deftest decknix-agent-help-functions--reports-no-commands-when-empty ()
  "When `decknix--agent-command-files' returns nil the slash commands
section reads `(none defined)'."
  (cl-letf (((symbol-function 'decknix--agent-command-files)
             (lambda () nil))
            ((symbol-function 'decknix--agent-command-description)
             (lambda (_) ""))
            ;; yas not loaded path
            ((symbol-value 'yas-snippet-dirs) nil))
    (decknix-help-test--capture
        (decknix-agent-help-functions)
      (should (string-match-p "Slash Commands" captured))
      (should (string-match-p "(none defined)" captured))
      (kill-buffer "*Agent Functions*"))))

(ert-deftest decknix-agent-help-functions--lists-discovered-commands ()
  "Commands surfaced by the discover module are rendered as
/<name>  <description> rows."
  (cl-letf (((symbol-function 'decknix--agent-command-files)
             (lambda () '("/tmp/foo.md" "/tmp/bar.md")))
            ((symbol-function 'decknix--agent-command-description)
             (lambda (file)
               (if (string-match-p "foo" file) "describes foo" "describes bar")))
            ((symbol-value 'yas-snippet-dirs) nil))
    (decknix-help-test--capture
        (decknix-agent-help-functions)
      (should (string-match-p "/foo" captured))
      (should (string-match-p "describes foo" captured))
      (should (string-match-p "/bar" captured))
      (should (string-match-p "describes bar" captured))
      (kill-buffer "*Agent Functions*"))))

;; -- decknix--agent-welcome-message ------------------------------

(ert-deftest decknix-agent-welcome-message--appends-key-hint ()
  "Welcome string ends with the discoverability hint listing
C-c ? k, C-c ? t, and C-c e."
  (cl-letf (((symbol-function 'agent-shell--indent-string)
             (lambda (_n s) s))
            ((symbol-function 'agent-shell-auggie--ascii-art)
             (lambda () "ART"))
            ((symbol-function 'shell-maker-welcome-message)
             (lambda (_config) "BASE")))
    (let ((out (decknix--agent-welcome-message 'fake-config)))
      (should (string-match-p "ART" out))
      (should (string-match-p "BASE" out))
      (should (string-match-p "C-c \\? k" out))
      (should (string-match-p "C-c \\? t" out))
      (should (string-match-p "C-c e" out))
      (should (string-match-p "keybindings" out))
      (should (string-match-p "tutorial" out))
      (should (string-match-p "compose" out)))))

(provide 'decknix-agent-help-test)
;;; decknix-agent-help-test.el ends here
