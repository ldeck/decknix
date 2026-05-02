;;; decknix-sidebar-row-actions-test.el --- Tests for sidebar row actions -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-row-actions "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the current behaviour of the sidebar row-action
;; commands (`decknix-sidebar-hide-at-point' and -unhide-at-point)
;; extracted from the agent-shell heredoc.  Each command is verified
;; to:
;;   * read the `decknix-sidebar-saved-conv-key' text property at
;;     `line-beginning-position',
;;   * call `decknix--agent-conversation-set-hidden' with the
;;     correct conv-key and hidden flag,
;;   * trigger `agent-shell-workspace-sidebar-refresh' exactly once,
;;   * no-op (no set-hidden, no refresh) when point is on a row
;;     without the saved-conv-key property.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-sidebar-row-actions)

;; -- Fixture helper -----------------------------------------------

(defmacro decknix-test-with-sidebar-rows (&rest body)
  "Run BODY in a temp buffer with two sample sidebar rows.
Line 1 has `decknix-sidebar-saved-conv-key' = \"abc123\"; line 2
has no such property.  Point starts on line 1.  Used by the row
action tests so each scenario can `(forward-line N)' to position
on a row with or without the conv-key property."
  (declare (indent 0))
  `(with-temp-buffer
     (insert (propertize "  ▷ session-one\n"
                         'decknix-sidebar-saved-conv-key "abc123"))
     (insert "  (header row, no conv-key)\n")
     (goto-char (point-min))
     ,@body))

;; -- hide-at-point ------------------------------------------------

(ert-deftest decknix-sidebar-row-actions/hide-at-point-on-saved-row ()
  (decknix-test-with-sidebar-rows
    (decknix-test-with-stubbed-deps
        (decknix--agent-conversation-set-hidden
         agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-hide-at-point)
      (should (= 1 (decknix-test-stub-call-count
                    'decknix--agent-conversation-set-hidden)))
      (should (equal '("abc123" t)
                     (decknix-test-stub-call-args
                      'decknix--agent-conversation-set-hidden)))
      (should (= 1 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

(ert-deftest decknix-sidebar-row-actions/hide-at-point-on-non-saved-row ()
  (decknix-test-with-sidebar-rows
    (forward-line 1)
    (decknix-test-with-stubbed-deps
        (decknix--agent-conversation-set-hidden
         agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-hide-at-point)
      (should (= 0 (decknix-test-stub-call-count
                    'decknix--agent-conversation-set-hidden)))
      (should (= 0 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- unhide-at-point ----------------------------------------------

(ert-deftest decknix-sidebar-row-actions/unhide-at-point-on-saved-row ()
  (decknix-test-with-sidebar-rows
    (decknix-test-with-stubbed-deps
        (decknix--agent-conversation-set-hidden
         agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-unhide-at-point)
      (should (= 1 (decknix-test-stub-call-count
                    'decknix--agent-conversation-set-hidden)))
      (should (equal '("abc123" nil)
                     (decknix-test-stub-call-args
                      'decknix--agent-conversation-set-hidden)))
      (should (= 1 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

(ert-deftest decknix-sidebar-row-actions/unhide-at-point-on-non-saved-row ()
  (decknix-test-with-sidebar-rows
    (forward-line 1)
    (decknix-test-with-stubbed-deps
        (decknix--agent-conversation-set-hidden
         agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-unhide-at-point)
      (should (= 0 (decknix-test-stub-call-count
                    'decknix--agent-conversation-set-hidden)))
      (should (= 0 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- conv-key forwarding spot-check -------------------------------
;; Pin that hide and unhide pass DIFFERENT hidden flags (t vs nil)
;; so a future "tidy up the boolean" refactor can't silently swap
;; them and pass the per-command tests above (which look at each
;; in isolation).

(ert-deftest decknix-sidebar-row-actions/hide-and-unhide-pass-opposite-flags ()
  (decknix-test-with-sidebar-rows
    (decknix-test-with-stubbed-deps
        (decknix--agent-conversation-set-hidden
         agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-hide-at-point)
      (decknix-sidebar-unhide-at-point)
      (should (= 2 (decknix-test-stub-call-count
                    'decknix--agent-conversation-set-hidden)))
      ;; Most recent first: unhide -> nil, then hide -> t.
      (should (equal '("abc123" nil)
                     (decknix-test-stub-call-args
                      'decknix--agent-conversation-set-hidden 0)))
      (should (equal '("abc123" t)
                     (decknix-test-stub-call-args
                      'decknix--agent-conversation-set-hidden 1))))))

(provide 'decknix-sidebar-row-actions-test)
;;; decknix-sidebar-row-actions-test.el ends here
