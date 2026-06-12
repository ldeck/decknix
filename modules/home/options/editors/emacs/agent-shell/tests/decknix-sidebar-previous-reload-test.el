;;; decknix-sidebar-previous-reload-test.el --- Previous-sessions reload persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-previous "0.1") (decknix-agent-live-sessions "0.1") (decknix-agent-shell-workspace "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Integration regression tests for Previous-Sessions persistence.
;; Covers:
;;
;; 1. Hot-reload wipe regression — `decknix--sidebar-snapshot-previous-from-live'
;;    writes to `decknix--sidebar-previous-sessions-file' so a subsequent
;;    `decknix--sidebar-previous-sessions-restore' (fired by the post-reload
;;    hook) can recover the list after an unload reset it to nil.
;;
;; 2. Nil-live-file fallback — when the live file is empty at startup
;;    (the previous run recorded no sessions), the snapshot function must
;;    NOT clobber `decknix--sidebar-previous-sessions' with nil.
;;    The already-restored value from `agent-previous-sessions.el'
;;    must be preserved so the Previous section stays non-empty.
;;
;; 3. History ring — `decknix--sidebar-previous-history-record' prepends
;;    a new entry; save/restore round-trips correctly.
;;
;; All tests live here (workspace package) rather than the leaf sidebar
;; widget package so `packageRequires' layering stays acyclic.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-sidebar-previous)
(require 'decknix-agent-live-sessions)
(require 'decknix-agent-shell-workspace)

;; -- Shared fixture --------------------------------------------------

(defmacro decknix-prev-test--with-tmp (&rest body)
  "Run BODY with all persistence file vars redirected to a tmp dir.
Cleans up on exit."
  (declare (indent 0))
  `(let* ((tmp-dir (make-temp-file "decknix-sidebar-test-" t))
          (decknix--live-sessions-file
           (expand-file-name "agent-live-sessions.el" tmp-dir))
          (decknix--sidebar-previous-sessions-file
           (expand-file-name "agent-previous-sessions.el" tmp-dir))
          (decknix--sidebar-previous-history-file
           (expand-file-name "agent-previous-history.el" tmp-dir))
          (decknix--live-sessions-dismissed-file
           (expand-file-name "dismissed.el" tmp-dir))
          (decknix--sidebar-state-file
           (expand-file-name "sidebar-state.el" tmp-dir))
          (decknix--live-sessions-suppress-write nil)
          (decknix--sidebar-previous-sessions nil)
          (decknix--sidebar-previous-history nil))
     (unwind-protect
         (progn ,@body)
       (delete-directory tmp-dir t))))

;; -- Test 1: hot-reload recovery (existing regression) ---------------

(ert-deftest decknix-sidebar-previous--reload-wipe-regression ()
  "Previous sessions survive a hot-reload via dedicated file.
Snapshot populates and saves the list; after in-memory reset (simulating
`unload-feature'), restore recovers it."
  (decknix-prev-test--with-tmp
    (let ((sessions '(((session-id . "s1") (name . "n1") (conv-key . "ck1")))))
      ;; Setup: prior run's live file
      (decknix--live-sessions-write sessions)
      ;; Startup snapshot
      (decknix--sidebar-snapshot-previous-from-live)
      (should (equal decknix--sidebar-previous-sessions sessions))
      (should (null (decknix--live-sessions-read))) ; truncated
      ;; Hot-reload resets in-memory var to nil
      (setq decknix--sidebar-previous-sessions nil)
      ;; Post-reload restore recovers from file
      (decknix--sidebar-previous-sessions-restore)
      (should (equal decknix--sidebar-previous-sessions sessions)))))

;; -- Test 2: nil-live-file fallback ----------------------------------

(ert-deftest decknix-sidebar-previous--nil-live-preserves-restore ()
  "Snapshot with empty live file does NOT wipe previously-restored list.
Simulates: user runs Emacs, never opens sessions, does kickstart.
Next daemon start: live file is empty, but `agent-previous-sessions.el'
has data from the run before that.  The restore (priority 90) sets the
var; the snapshot (priority 100) must leave it intact."
  (decknix-prev-test--with-tmp
    (let ((old-sessions '(((session-id . "s-old") (name . "old") (conv-key . "ck-old")))))
      ;; Simulate the restore from a previous run's saved file:
      ;; write old sessions directly to the previous file and restore.
      (decknix--live-sessions--write-file
       decknix--sidebar-previous-sessions-file
       old-sessions
       ";; test\n")
      (decknix--sidebar-previous-sessions-restore)
      (should (equal decknix--sidebar-previous-sessions old-sessions))

      ;; Live file is empty (no sessions were recorded in the last run)
      ;; — snapshot-and-truncate returns nil.
      (should (null (decknix--live-sessions-read)))

      ;; Snapshot: live is nil → must preserve the restored value
      (decknix--sidebar-snapshot-previous-from-live)
      (should (equal decknix--sidebar-previous-sessions old-sessions)
              ))))

;; -- Test 3: history ring --------------------------------------------

(ert-deftest decknix-sidebar-previous--history-record-and-roundtrip ()
  "History ring grows and survives a save/restore cycle."
  (decknix-prev-test--with-tmp
    (let* ((s1 '(((session-id . "sa") (conv-key . "ka"))))
           (s2 '(((session-id . "sb") (conv-key . "kb")))))
      ;; Initially empty
      (should (null decknix--sidebar-previous-history))

      ;; Record two snapshots
      (decknix--sidebar-previous-history-record s1)
      (should (= 1 (length decknix--sidebar-previous-history)))
      (should (equal s1 (alist-get 'sessions (car decknix--sidebar-previous-history))))

      (decknix--sidebar-previous-history-record s2)
      (should (= 2 (length decknix--sidebar-previous-history)))
      ;; Newest first
      (should (equal s2 (alist-get 'sessions (car decknix--sidebar-previous-history))))
      (should (equal s1 (alist-get 'sessions (cadr decknix--sidebar-previous-history))))

      ;; Save and restore round-trip
      (decknix--sidebar-previous-history-save)
      (setq decknix--sidebar-previous-history nil)
      (decknix--sidebar-previous-history-restore)
      (should (= 2 (length decknix--sidebar-previous-history)))
      (should (equal s2 (alist-get 'sessions (car decknix--sidebar-previous-history)))))))

(ert-deftest decknix-sidebar-previous--history-capped-at-depth ()
  "History ring is capped at `decknix--sidebar-previous-history-depth'."
  (decknix-prev-test--with-tmp
    (let ((decknix--sidebar-previous-history-depth 3))
      (decknix--sidebar-previous-history-record '(((session-id . "s1"))))
      (decknix--sidebar-previous-history-record '(((session-id . "s2"))))
      (decknix--sidebar-previous-history-record '(((session-id . "s3"))))
      (decknix--sidebar-previous-history-record '(((session-id . "s4"))))
      ;; Still 3 entries, oldest (s1) dropped
      (should (= 3 (length decknix--sidebar-previous-history)))
      (let ((ids (mapcar (lambda (e)
                           (alist-get 'session-id
                                      (car (alist-get 'sessions e))))
                         decknix--sidebar-previous-history)))
        (should (equal ids '("s4" "s3" "s2")))))))

(provide 'decknix-sidebar-previous-reload-test)
;;; decknix-sidebar-previous-reload-test.el ends here
