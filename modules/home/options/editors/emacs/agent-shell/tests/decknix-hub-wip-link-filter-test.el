;;; decknix-hub-wip-link-filter-test.el --- Tests for WIP hide-linked toggle -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-wip-link-filter "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the WIP "hide linked" toggle
;; cluster extracted from hub-bulk.  Covers:
;;
;; - documented default (`t' -- on, hide live-session-linked PRs)
;; - the toggle's flip semantics (idempotent two-flip = identity)
;; - safe-to-call-without-sidebar guard via `get-buffer'
;;
;; The interactive cycler's
;; `agent-shell-workspace-sidebar-refresh' callback is guarded by
;; `(get-buffer agent-shell-workspace-sidebar-buffer-name)' in the
;; module (the upstream buffer name is "*Agent Sidebar*"), so simply
;; running tests in a fresh batch Emacs (where that buffer never
;; exists) suffices to skip the call.

;;; Code:

(require 'ert)
(require 'decknix-hub-wip-link-filter)

;; -- Defaults ----------------------------------------------------

(ert-deftest decknix-hub-wip-link-filter--default-on ()
  "Documented default is `t' -- on -- so live-linked PRs are hidden."
  (should (eq decknix--hub-wip-hide-linked t)))

;; -- Toggle ------------------------------------------------------

(ert-deftest decknix-hub-wip-link-filter--toggle-on-to-off ()
  "Toggle flips an `on' value to `nil'."
  (let ((decknix--hub-wip-hide-linked t))
    (call-interactively #'decknix--hub-toggle-wip-hide-linked)
    (should (null decknix--hub-wip-hide-linked))))

(ert-deftest decknix-hub-wip-link-filter--toggle-off-to-on ()
  "Toggle flips a `nil' value to `t'."
  (let ((decknix--hub-wip-hide-linked nil))
    (call-interactively #'decknix--hub-toggle-wip-hide-linked)
    (should (eq decknix--hub-wip-hide-linked t))))

(ert-deftest decknix-hub-wip-link-filter--toggle-round-trip ()
  "Two flips return to the original state."
  (let ((decknix--hub-wip-hide-linked t))
    (call-interactively #'decknix--hub-toggle-wip-hide-linked)
    (call-interactively #'decknix--hub-toggle-wip-hide-linked)
    (should (eq decknix--hub-wip-hide-linked t))))

(ert-deftest decknix-hub-wip-link-filter--toggle-no-sidebar-buffer-noop ()
  "Calling the toggle without the sidebar buffer does not error.
The `get-buffer' guard ensures the upstream refresh call is
skipped when the sidebar is not yet open."
  (let ((decknix--hub-wip-hide-linked nil))
    (should-not (get-buffer "*Agent Sidebar*"))
    ;; Should complete without error.
    (call-interactively #'decknix--hub-toggle-wip-hide-linked)
    (should (eq decknix--hub-wip-hide-linked t))))

(provide 'decknix-hub-wip-link-filter-test)
;;; decknix-hub-wip-link-filter-test.el ends here
