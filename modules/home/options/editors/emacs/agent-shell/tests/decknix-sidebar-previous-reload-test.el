;;; decknix-sidebar-previous-reload-test.el --- Previous-sessions reload persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-previous "0.1") (decknix-agent-live-sessions "0.1") (decknix-agent-shell-workspace "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Integration regression test for Previous-Sessions persistence across
;; a hot-reload.  The snapshot/restore/save entry points under test
;; (`decknix--sidebar-snapshot-previous-from-live',
;; `decknix--sidebar-previous-sessions-restore') live in
;; `decknix-agent-shell-workspace' and span the live-sessions file
;; (`decknix-agent-live-sessions') and the in-memory list defvars
;; (`decknix-sidebar-previous').  It therefore lives with the
;; workspace package rather than the leaf sidebar widget so the
;; build's `packageRequires' layering stays acyclic.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-sidebar-previous)
(require 'decknix-agent-live-sessions)
(require 'decknix-agent-shell-workspace)

(ert-deftest decknix-sidebar-previous--reload-wipe-regression ()
  "Reproduce the issue where previous sessions are lost after a reload.
This test demonstrates that once the live file is truncated at startup,
a subsequent reload (which resets the in-memory variable) can now
recover the sessions from the dedicated previous-sessions file."
  (let* ((tmp-dir (make-temp-file "decknix-sidebar-test-" t))
         (live-file (expand-file-name "agent-live-sessions.el" tmp-dir))
         (prev-file (expand-file-name "agent-previous-sessions.el" tmp-dir))
         ;; Shadow the file variables to our tmp-dir
         (decknix--live-sessions-file live-file)
         (decknix--sidebar-previous-sessions-file prev-file)
         (decknix--live-sessions-dismissed-file (expand-file-name "dismissed.el" tmp-dir))
         (decknix--sidebar-state-file (expand-file-name "sidebar-state.el" tmp-dir))
         (sessions '(((session-id . "s1") (name . "n1") (conv-key . "ck1"))))
         ;; Ensure the variable is clean
         (decknix--sidebar-previous-sessions nil))
    (unwind-protect
        (progn
          ;; 1. Setup: write a live session file as if from a prior run
          (decknix--live-sessions-write sessions)
          (should (file-exists-p live-file))

          ;; 2. Simulate startup snapshot: reads live -> populates var -> truncates live
          ;; AND now writes to the previous-sessions file.
          (decknix--sidebar-snapshot-previous-from-live)
          (should (equal decknix--sidebar-previous-sessions sessions))
          (should (null (decknix--live-sessions-read))) ; Verified truncated
          (should (file-exists-p prev-file)) ; Verified persisted

          ;; 3. Simulate reload: the feature unload/reload resets the defvar to nil
          (setq decknix--sidebar-previous-sessions nil)
          (should (null decknix--sidebar-previous-sessions))

          ;; 4. Verify we can now RESTORE from the previous-sessions file
          (decknix--sidebar-previous-sessions-restore)
          (should (equal decknix--sidebar-previous-sessions sessions)))
      (delete-directory tmp-dir t))))

(provide 'decknix-sidebar-previous-reload-test)
;;; decknix-sidebar-previous-reload-test.el ends here
