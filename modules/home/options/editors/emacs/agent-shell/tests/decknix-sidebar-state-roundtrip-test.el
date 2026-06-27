;;; decknix-sidebar-state-roundtrip-test.el --- Hub toggle persistence round-trip -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-shell-workspace "0.1") (decknix-hub-ci-filter "0.1") (decknix-hub-mention-bot "0.1") (decknix-hub-age-presets "0.1") (decknix-auto-review "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Regression test for Requests-section hub toggles (CI, bots, mention,
;; age) reverting to defaults after a `decknix switch' reload.
;;
;; The reload cycle force-unloads every `decknix-*' feature, which
;; re-runs the `defvar' forms and resets these toggles to their
;; defaults.  `deckmacs-reload' restores them afterwards from
;; `decknix--sidebar-state-file' via `decknix--sidebar-state-restore',
;; but that recovery is only lossless if the matching
;; `decknix--sidebar-state-save' captured the user's current values
;; *before* the unload (see the `deckmacs-pre-reload-hook' wiring in
;; agent-shell.nix).
;;
;; This test pins the save/restore contract that the pre-reload save
;; depends on: a save → reset-to-defaults → restore cycle must recover
;; each toggle exactly.  If a toggle is added to the saver but not the
;; restorer (or vice versa), this goes red before a full build cycle.

;;; Code:

(require 'ert)
(require 'decknix-agent-shell-workspace)
(require 'decknix-hub-ci-filter)
(require 'decknix-hub-mention-bot)
(require 'decknix-hub-age-presets)
(require 'decknix-auto-review)

;; `decknix--sidebar-state-save' reads the width-state var unconditionally
;; (no `boundp' guard).  Its defining package (`decknix-sidebar-width') is
;; outside this test's dependency closure and the value is irrelevant to
;; the hub-toggle assertions, so declare it here as a bound special var —
;; matching the real default — purely so the saver does not signal
;; `void-variable'.  At daemon load the real defvar runs first; this test
;; file never ships (test files stay out of `installPhase').
(defvar decknix--sidebar-width-state 'default)

(ert-deftest decknix-sidebar-state--hub-toggles-roundtrip ()
  "Requests hub toggles survive a save → reset → restore cycle.
Models the reload sequence: the user's non-default toggle states are
persisted, the `defvar' reset (force-unload) reverts the in-memory
vars to defaults, and the post-reload restore must recover the
persisted states rather than leaving the defaults in place."
  (let* ((tmp-dir (make-temp-file "decknix-state-test-" t))
         (decknix--sidebar-state-file
          (expand-file-name "sidebar-state.el" tmp-dir))
         ;; Snapshot the live globals so the test cannot leak into the
         ;; running daemon's state when run interactively.
         (orig-ci decknix--hub-ci-filter)
         (orig-mention decknix--hub-mention-filter)
         (orig-bots decknix--hub-show-bots)
         (orig-age decknix--hub-age-filter)
         (orig-auto-review decknix-auto-review-mode))
    (unwind-protect
        (progn
          ;; 1. User sets non-default toggle states.
          (setq decknix--hub-ci-filter '("fail")
                decknix--hub-mention-filter 'me
                decknix--hub-show-bots 'show
                decknix--hub-age-filter 259200
                decknix-auto-review-mode 'any)
          ;; 2. Pre-reload save captures the current values.
          (decknix--sidebar-state-save)
          (should (file-exists-p decknix--sidebar-state-file))
          ;; 3. Force-unload reset: defvar forms revert to defaults.
          (setq decknix--hub-ci-filter
                '("pass" "fail" "soft_fail" "running" "unknown")
                decknix--hub-mention-filter nil
                decknix--hub-show-bots nil
                decknix--hub-age-filter nil
                decknix-auto-review-mode 'off)
          ;; 4. Post-reload restore recovers the persisted values.
          (decknix--sidebar-state-restore)
          ;; 5. Each toggle must match what the user had, not the default.
          (should (equal decknix--hub-ci-filter '("fail")))
          (should (eq decknix--hub-mention-filter 'me))
          (should (eq decknix--hub-show-bots 'show))
          (should (equal decknix--hub-age-filter 259200))
          (should (eq decknix-auto-review-mode 'any)))
      (setq decknix--hub-ci-filter orig-ci
            decknix--hub-mention-filter orig-mention
            decknix--hub-show-bots orig-bots
            decknix--hub-age-filter orig-age
            decknix-auto-review-mode orig-auto-review)
      (delete-directory tmp-dir t))))

(provide 'decknix-sidebar-state-roundtrip-test)
;;; decknix-sidebar-state-roundtrip-test.el ends here
