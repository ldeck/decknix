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
  (should (equal nil (default-value 'decknix--hub-show-saved-sessions)))
  (should (equal 'A  (default-value 'decknix--hub-display-mode))))

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

(ert-deftest decknix-sidebar-toggles/cycle-requests-display-mode-cycles ()
  "Five-way cycle: inherit → A → B → C → D → inherit."
  (let ((decknix--sidebar-requests-display-mode nil))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-cycle-requests-display-mode)
      (should (equal 'A decknix--sidebar-requests-display-mode))
      (decknix-sidebar-cycle-requests-display-mode)
      (should (equal 'B decknix--sidebar-requests-display-mode))
      (decknix-sidebar-cycle-requests-display-mode)
      (should (equal 'C decknix--sidebar-requests-display-mode))
      (decknix-sidebar-cycle-requests-display-mode)
      (should (equal 'D decknix--sidebar-requests-display-mode))
      (decknix-sidebar-cycle-requests-display-mode)
      (should (equal nil decknix--sidebar-requests-display-mode))
      (should (= 5 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

(ert-deftest decknix-sidebar-toggles/cycle-wip-display-mode-cycles ()
  "Five-way cycle: inherit → A → B → C → D → inherit."
  (let ((decknix--sidebar-wip-display-mode nil))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-cycle-wip-display-mode)
      (should (equal 'A decknix--sidebar-wip-display-mode))
      (decknix-sidebar-cycle-wip-display-mode)
      (should (equal 'B decknix--sidebar-wip-display-mode))
      (decknix-sidebar-cycle-wip-display-mode)
      (should (equal 'C decknix--sidebar-wip-display-mode))
      (decknix-sidebar-cycle-wip-display-mode)
      (should (equal 'D decknix--sidebar-wip-display-mode))
      (decknix-sidebar-cycle-wip-display-mode)
      (should (equal nil decknix--sidebar-wip-display-mode))
      (should (= 5 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

(ert-deftest decknix-sidebar-toggles/cycle-live-display-mode-cycles ()
  "Five-way cycle: inherit → A → B → C → D → inherit."
  (let ((decknix--sidebar-live-display-mode nil))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-cycle-live-display-mode)
      (should (equal 'A decknix--sidebar-live-display-mode))
      (decknix-sidebar-cycle-live-display-mode)
      (should (equal 'B decknix--sidebar-live-display-mode))
      (decknix-sidebar-cycle-live-display-mode)
      (should (equal 'C decknix--sidebar-live-display-mode))
      (decknix-sidebar-cycle-live-display-mode)
      (should (equal 'D decknix--sidebar-live-display-mode))
      (decknix-sidebar-cycle-live-display-mode)
      (should (equal nil decknix--sidebar-live-display-mode))
      (should (= 5 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

(ert-deftest decknix-sidebar-toggles/cycle-sessions-display-mode-cycles ()
  "Three-way cycle: name → tags → both → name."
  (let ((decknix--sidebar-sessions-display-mode 'name))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-cycle-sessions-display-mode)
      (should (equal 'tags decknix--sidebar-sessions-display-mode))
      (decknix-sidebar-cycle-sessions-display-mode)
      (should (equal 'both decknix--sidebar-sessions-display-mode))
      (decknix-sidebar-cycle-sessions-display-mode)
      (should (equal 'name decknix--sidebar-sessions-display-mode))
      (should (= 3 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

(ert-deftest decknix-sidebar-toggles/toggle-hub-display-mode-cycles ()
  (let ((decknix--hub-display-mode 'A))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-toggle-hub-display-mode)
      (should (equal 'B decknix--hub-display-mode))
      (decknix-sidebar-toggle-hub-display-mode)
      (should (equal 'C decknix--hub-display-mode))
      (decknix-sidebar-toggle-hub-display-mode)
      (should (equal 'D decknix--hub-display-mode))
      (decknix-sidebar-toggle-hub-display-mode)
      (should (equal 'A decknix--hub-display-mode))
      (should (= 4 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- toggle-wip-group-mode ----------------------------------------

(ert-deftest decknix-sidebar-toggles/toggle-wip-group-mode-cycles ()
  "Three-way cycle: repo → workspace → worktree → repo."
  (let ((decknix--sidebar-wip-group-mode 'repo))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-toggle-wip-group-mode)
      (should (equal 'workspace decknix--sidebar-wip-group-mode))
      (decknix-sidebar-toggle-wip-group-mode)
      (should (equal 'worktree decknix--sidebar-wip-group-mode))
      (decknix-sidebar-toggle-wip-group-mode)
      (should (equal 'repo decknix--sidebar-wip-group-mode))
      (should (= 3 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- decknix--sidebar-refresh-now ------------------------------------

(ert-deftest decknix-sidebar-toggles/refresh-now-bypasses-suspend ()
  "refresh-now calls through even when suspension flag is set."
  (let ((decknix--sidebar-refresh-suspended t))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      ;; refresh-now let-binds the flag to nil, so the stub IS reached.
      (decknix--sidebar-refresh-now)
      (should (= 1 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

(ert-deftest decknix-sidebar-toggles/refresh-now-calls-when-not-suspended ()
  "refresh-now calls through when suspension flag is nil."
  (let ((decknix--sidebar-refresh-suspended nil))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix--sidebar-refresh-now)
      (should (= 1 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- cycle-live-view-mode -----------------------------------------

(ert-deftest decknix-sidebar-toggles/cycle-live-view-mode-cycles ()
  "Five-way cycle: flat → workspace → path → tags → tree → flat."
  (let ((decknix--sidebar-live-view-mode 'flat)
        (decknix--sidebar-refresh-suspended nil))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-cycle-live-view-mode)
      (should (equal 'workspace decknix--sidebar-live-view-mode))
      (decknix-sidebar-cycle-live-view-mode)
      (should (equal 'path decknix--sidebar-live-view-mode))
      (decknix-sidebar-cycle-live-view-mode)
      (should (equal 'tags decknix--sidebar-live-view-mode))
      (decknix-sidebar-cycle-live-view-mode)
      (should (equal 'tree decknix--sidebar-live-view-mode))
      (decknix-sidebar-cycle-live-view-mode)
      (should (equal 'flat decknix--sidebar-live-view-mode))
      (should (= 5 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- view-mode (support mode) -------------------------------------

(ert-deftest decknix-sidebar-toggles/cycle-view-mode-cycles ()
  "Three-way cycle: standard -> support -> hybrid -> standard, refreshing each."
  (let ((decknix--sidebar-view-mode 'standard)
        (decknix--sidebar-refresh-suspended nil))
    (decknix-test-with-stubbed-deps (agent-shell-workspace-sidebar-refresh)
      (decknix-sidebar-cycle-view-mode)
      (should (equal 'support decknix--sidebar-view-mode))
      (decknix-sidebar-cycle-view-mode)
      (should (equal 'hybrid decknix--sidebar-view-mode))
      (decknix-sidebar-cycle-view-mode)
      (should (equal 'standard decknix--sidebar-view-mode))
      (should (= 3 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

(ert-deftest decknix-sidebar-toggles/section-visible-p-per-mode ()
  "The pure predicate gates sections by mode from the section map."
  ;; standard: developer sections, no support section
  (should (decknix--sidebar-section-visible-p 'requests 'standard))
  (should (decknix--sidebar-section-visible-p 'wip 'standard))
  (should-not (decknix--sidebar-section-visible-p 'support 'standard))
  ;; support: Support + Live only; developer sections suppressed
  (should (decknix--sidebar-section-visible-p 'support 'support))
  (should (decknix--sidebar-section-visible-p 'live 'support))
  (should-not (decknix--sidebar-section-visible-p 'requests 'support))
  (should-not (decknix--sidebar-section-visible-p 'wip 'support))
  ;; hybrid: everything
  (should (decknix--sidebar-section-visible-p 'support 'hybrid))
  (should (decknix--sidebar-section-visible-p 'requests 'hybrid)))

(ert-deftest decknix-sidebar-toggles/section-visible-p-defaults-to-current-mode ()
  "Omitting MODE consults `decknix--sidebar-view-mode'."
  (let ((decknix--sidebar-view-mode 'support))
    (should (decknix--sidebar-section-visible-p 'support))
    (should-not (decknix--sidebar-section-visible-p 'requests))))

(ert-deftest decknix-sidebar-toggles/section-visible-p-unknown-mode-fails-safe ()
  "An unknown mode hides every section rather than rendering a broken view."
  (should-not (decknix--sidebar-section-visible-p 'live 'bogus))
  (should-not (decknix--sidebar-section-visible-p 'support 'bogus)))

(provide 'decknix-sidebar-toggles-test)
;;; decknix-sidebar-toggles-test.el ends here
