;;; decknix-hub-wip-terminal-filter-test.el --- Tests for WIP hide-terminal toggle -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-wip-terminal-filter "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the WIP "hide terminal" toggle
;; cluster (#137).  Mirrors the shape of
;; `decknix-hub-wip-link-filter-test' since the two carved modules
;; share the same hide/show + sidebar-refresh-guard contract.
;; Covers:
;;
;; - documented default (`t' -- on, hide MERGED/CLOSED rows)
;; - predicate semantics across OPEN / DRAFT / MERGED / CLOSED /
;;   missing-state
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
(require 'decknix-hub-wip-terminal-filter)

;; -- Defaults ----------------------------------------------------

(ert-deftest decknix-hub-wip-terminal-filter--default-on ()
  "Documented default is `t' -- on -- so terminal-state PRs are hidden."
  (should (eq decknix--hub-wip-hide-terminal t)))

;; -- Predicate ---------------------------------------------------

(ert-deftest decknix-hub-wip-terminal-filter--predicate-hides-merged ()
  "When toggle is on, a MERGED PR is filtered out."
  (let ((decknix--hub-wip-hide-terminal t))
    (should-not (decknix--hub-wip-terminal-visible-p
                 '((state . "MERGED"))))))

(ert-deftest decknix-hub-wip-terminal-filter--predicate-hides-closed ()
  "When toggle is on, a CLOSED PR is filtered out."
  (let ((decknix--hub-wip-hide-terminal t))
    (should-not (decknix--hub-wip-terminal-visible-p
                 '((state . "CLOSED"))))))

(ert-deftest decknix-hub-wip-terminal-filter--predicate-keeps-open ()
  "When toggle is on, OPEN PRs remain visible."
  (let ((decknix--hub-wip-hide-terminal t))
    (should (decknix--hub-wip-terminal-visible-p
             '((state . "OPEN"))))))

(ert-deftest decknix-hub-wip-terminal-filter--predicate-keeps-draft ()
  "When toggle is on, DRAFT PRs remain visible."
  (let ((decknix--hub-wip-hide-terminal t))
    (should (decknix--hub-wip-terminal-visible-p
             '((state . "DRAFT"))))))

(ert-deftest decknix-hub-wip-terminal-filter--predicate-defaults-missing-state-to-open ()
  "Rows lacking an explicit `state' field are treated as OPEN."
  (let ((decknix--hub-wip-hide-terminal t))
    (should (decknix--hub-wip-terminal-visible-p
             '((number . 42) (title . "no state field"))))))

(ert-deftest decknix-hub-wip-terminal-filter--predicate-toggle-off-shows-everything ()
  "When toggle is off, MERGED and CLOSED PRs are visible too."
  (let ((decknix--hub-wip-hide-terminal nil))
    (should (decknix--hub-wip-terminal-visible-p '((state . "MERGED"))))
    (should (decknix--hub-wip-terminal-visible-p '((state . "CLOSED"))))
    (should (decknix--hub-wip-terminal-visible-p '((state . "OPEN"))))))

;; -- Pure terminal-state predicate (#138 stale badge) ------------

(ert-deftest decknix-hub-wip-terminal-filter--terminal-p-merged ()
  "MERGED is terminal regardless of the toggle."
  (let ((decknix--hub-wip-hide-terminal nil))
    (should (decknix--hub-wip-pr-terminal-p '((state . "MERGED")))))
  (let ((decknix--hub-wip-hide-terminal t))
    (should (decknix--hub-wip-pr-terminal-p '((state . "MERGED"))))))

(ert-deftest decknix-hub-wip-terminal-filter--terminal-p-closed ()
  "CLOSED is terminal regardless of the toggle."
  (let ((decknix--hub-wip-hide-terminal nil))
    (should (decknix--hub-wip-pr-terminal-p '((state . "CLOSED")))))
  (let ((decknix--hub-wip-hide-terminal t))
    (should (decknix--hub-wip-pr-terminal-p '((state . "CLOSED"))))))

(ert-deftest decknix-hub-wip-terminal-filter--terminal-p-open-not-terminal ()
  "OPEN PRs are not terminal."
  (should-not (decknix--hub-wip-pr-terminal-p '((state . "OPEN")))))

(ert-deftest decknix-hub-wip-terminal-filter--terminal-p-draft-not-terminal ()
  "DRAFT PRs are not terminal -- they remain actionable."
  (should-not (decknix--hub-wip-pr-terminal-p '((state . "DRAFT")))))

(ert-deftest decknix-hub-wip-terminal-filter--terminal-p-missing-state-not-terminal ()
  "Rows lacking an explicit `state' field default to OPEN, hence non-terminal.
Mirrors `decknix--hub-wip-terminal-visible-p' so the two
predicates only ever disagree across the toggle."
  (should-not (decknix--hub-wip-pr-terminal-p
               '((number . 42) (title . "no state field")))))

;; -- Toggle ------------------------------------------------------

(ert-deftest decknix-hub-wip-terminal-filter--toggle-on-to-off ()
  "Toggle flips an `on' value to `nil'."
  (let ((decknix--hub-wip-hide-terminal t))
    (call-interactively #'decknix--hub-toggle-wip-hide-terminal)
    (should (null decknix--hub-wip-hide-terminal))))

(ert-deftest decknix-hub-wip-terminal-filter--toggle-off-to-on ()
  "Toggle flips a `nil' value to `t'."
  (let ((decknix--hub-wip-hide-terminal nil))
    (call-interactively #'decknix--hub-toggle-wip-hide-terminal)
    (should (eq decknix--hub-wip-hide-terminal t))))

(ert-deftest decknix-hub-wip-terminal-filter--toggle-round-trip ()
  "Two flips return to the original state."
  (let ((decknix--hub-wip-hide-terminal t))
    (call-interactively #'decknix--hub-toggle-wip-hide-terminal)
    (call-interactively #'decknix--hub-toggle-wip-hide-terminal)
    (should (eq decknix--hub-wip-hide-terminal t))))

(ert-deftest decknix-hub-wip-terminal-filter--toggle-no-sidebar-buffer-noop ()
  "Calling the toggle without the sidebar buffer does not error.
The `get-buffer' guard ensures the upstream refresh call is
skipped when the sidebar is not yet open."
  (let ((decknix--hub-wip-hide-terminal nil))
    (should-not (get-buffer "*Agent Sidebar*"))
    ;; Should complete without error.
    (call-interactively #'decknix--hub-toggle-wip-hide-terminal)
    (should (eq decknix--hub-wip-hide-terminal t))))

(provide 'decknix-hub-wip-terminal-filter-test)
;;; decknix-hub-wip-terminal-filter-test.el ends here
