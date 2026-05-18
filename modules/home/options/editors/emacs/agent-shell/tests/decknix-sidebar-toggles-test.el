;;; decknix-sidebar-toggles-test.el --- Characterisation tests for sidebar toggles -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-toggles "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the current behaviour of the sidebar visibility
;; and filter toggles extracted from the agent-shell heredoc.  Each
;; toggle is verified to flip its backing defvar, invoke the
;; sidebar-refresh (stubbed via `decknix-test-with-stubbed-deps'),
;; and round-trip on a second call.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-sidebar-toggles)

;; Make `decknix--hub-age-presets' globally special so let-bindings in
;; tests are dynamic (not lexical).  Mirrors the helper-file convention
;; for hub-data forward decls.
(defvar decknix--hub-age-presets nil)

;; -- Defvar defaults ----------------------------------------------

(ert-deftest decknix-sidebar-toggles/defvar-defaults ()
  (should (equal t   (default-value 'decknix--sidebar-show-keys)))
  (should (equal nil (default-value 'decknix--sidebar-show-hidden)))
  (should (equal nil (default-value 'decknix--sidebar-sessions-hide-live)))
  (should (equal nil (default-value 'decknix--sidebar-sessions-age-filter)))
  (should (equal nil (default-value 'decknix--sidebar-sessions-hide-unknown)))
  (should (equal t   (default-value 'decknix--hub-show-saved-sessions))))

;; -- toggle-keys --------------------------------------------------

(ert-deftest decknix-sidebar-toggles/toggle-keys-flips-and-refreshes ()
  (let ((decknix--sidebar-show-keys t))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-toggle-keys)
      (should (equal nil decknix--sidebar-show-keys))
      (should (= 1 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh)))
      (decknix-sidebar-toggle-keys)
      (should (equal t decknix--sidebar-show-keys))
      (should (= 2 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- toggle-hidden ------------------------------------------------

(ert-deftest decknix-sidebar-toggles/toggle-hidden-flips-and-refreshes ()
  (let ((decknix--sidebar-show-hidden nil))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-toggle-hidden)
      (should (equal t decknix--sidebar-show-hidden))
      (should (= 1 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh)))
      (decknix-sidebar-toggle-hidden)
      (should (equal nil decknix--sidebar-show-hidden))
      (should (= 2 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- toggle-sessions-hide-live ------------------------------------

(ert-deftest decknix-sidebar-toggles/toggle-sessions-hide-live-flips-and-refreshes ()
  (let ((decknix--sidebar-sessions-hide-live nil))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-toggle-sessions-hide-live)
      (should (equal t decknix--sidebar-sessions-hide-live))
      (should (= 1 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh)))
      (decknix-sidebar-toggle-sessions-hide-live)
      (should (equal nil decknix--sidebar-sessions-hide-live))
      (should (= 2 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- toggle-sessions-hide-unknown ---------------------------------

(ert-deftest decknix-sidebar-toggles/toggle-sessions-hide-unknown-flips-and-refreshes ()
  (let ((decknix--sidebar-sessions-hide-unknown nil))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-toggle-sessions-hide-unknown)
      (should (equal t decknix--sidebar-sessions-hide-unknown))
      (should (= 1 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh)))
      (decknix-sidebar-toggle-sessions-hide-unknown)
      (should (equal nil decknix--sidebar-sessions-hide-unknown))
      (should (= 2 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- session-workspace-visible-p (#139) ---------------------------

(ert-deftest decknix-sidebar-toggles/workspace-visible-toggle-off-shows-everything ()
  "When toggle is off, every workspace passes -- including nil + missing dirs."
  (let ((decknix--sidebar-sessions-hide-unknown nil))
    (should (decknix--sidebar-session-workspace-visible-p nil))
    (should (decknix--sidebar-session-workspace-visible-p "/no/such/dir/anywhere"))
    (should (decknix--sidebar-session-workspace-visible-p
             temporary-file-directory))))

(ert-deftest decknix-sidebar-toggles/workspace-visible-toggle-on-hides-nil ()
  "When toggle is on, nil workspace (unresolved) is dropped."
  (let ((decknix--sidebar-sessions-hide-unknown t))
    (should-not (decknix--sidebar-session-workspace-visible-p nil))))

(ert-deftest decknix-sidebar-toggles/workspace-visible-toggle-on-hides-vanished ()
  "When toggle is on, a workspace path that no longer exists is dropped (#139)."
  (let* ((decknix--sidebar-sessions-hide-unknown t)
         (gone (make-temp-file "decknix-vanished-ws" t)))
    ;; Tear down so the path resolves to a non-existent directory.
    (delete-directory gone t)
    (should-not (decknix--sidebar-session-workspace-visible-p gone))))

(ert-deftest decknix-sidebar-toggles/workspace-visible-toggle-on-keeps-existing ()
  "When toggle is on, an existing directory is kept."
  (let ((decknix--sidebar-sessions-hide-unknown t))
    (should (decknix--sidebar-session-workspace-visible-p
             temporary-file-directory))))

;; -- toggle-saved-sessions ----------------------------------------

(ert-deftest decknix-sidebar-toggles/toggle-saved-sessions-flips-and-refreshes ()
  (let ((decknix--hub-show-saved-sessions t))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-toggle-saved-sessions)
      (should (equal nil decknix--hub-show-saved-sessions))
      (should (= 1 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh)))
      (decknix-sidebar-toggle-saved-sessions)
      (should (equal t decknix--hub-show-saved-sessions))
      (should (= 2 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- sessions-age-label -------------------------------------------

(ert-deftest decknix-sidebar-toggles/age-label-falls-back-when-presets-unbound ()
  ;; presets defvared at top of this file with nil, so boundp is t but
  ;; alist-get on nil/nil returns nil and the helper falls back to "all".
  (let ((decknix--hub-age-presets nil)
        (decknix--sidebar-sessions-age-filter 86400))
    (should (equal "all" (decknix--sidebar-sessions-age-label)))))

(ert-deftest decknix-sidebar-toggles/age-label-resolves-from-presets ()
  (let ((decknix--hub-age-presets '((nil . "all") (86400 . "1d") (259200 . "3d")))
        (decknix--sidebar-sessions-age-filter 86400))
    (should (equal "1d" (decknix--sidebar-sessions-age-label))))
  (let ((decknix--hub-age-presets '((nil . "all") (86400 . "1d") (259200 . "3d")))
        (decknix--sidebar-sessions-age-filter nil))
    (should (equal "all" (decknix--sidebar-sessions-age-label)))))

;; -- cycle-sessions-age-filter ------------------------------------

(ert-deftest decknix-sidebar-toggles/cycle-advances-and-wraps ()
  (let ((decknix--hub-age-presets '((nil . "all") (86400 . "1d") (259200 . "3d")))
        (decknix--sidebar-sessions-age-filter nil))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-cycle-sessions-age-filter)
      (should (equal 86400 decknix--sidebar-sessions-age-filter))
      (decknix-sidebar-cycle-sessions-age-filter)
      (should (equal 259200 decknix--sidebar-sessions-age-filter))
      (decknix-sidebar-cycle-sessions-age-filter)
      (should (equal nil decknix--sidebar-sessions-age-filter))
      (should (= 3 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

(ert-deftest decknix-sidebar-toggles/cycle-handles-unknown-current-value ()
  ;; When the current value isn't in `keys', `cl-position' returns nil
  ;; and the helper falls back to (1+ 0) = pos 1.
  (let ((decknix--hub-age-presets '((nil . "all") (86400 . "1d") (259200 . "3d")))
        (decknix--sidebar-sessions-age-filter 9999))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-cycle-sessions-age-filter)
      (should (equal 86400 decknix--sidebar-sessions-age-filter)))))

(provide 'decknix-sidebar-toggles-test)
;;; decknix-sidebar-toggles-test.el ends here
