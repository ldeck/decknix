;;; decknix-sidebar-previous-test.el --- Tests for previous-sessions dedupe -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-previous "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--sidebar-previous-dedupe',
;; the pure list -> list dedupe used to collapse parallel
;; session-id snapshots of the same conversation down to one row in
;; the sidebar Previous Sessions section.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-sidebar-previous)
(require 'decknix-agent-live-sessions)
(require 'decknix-agent-shell-workspace)

(defun decknix-sidebar-previous-test--entry (sid ck &optional name)
  "Build a Previous-Sessions alist with SID and CK."
  (list (cons 'session-id sid)
        (cons 'name (or name sid))
        (cons 'workspace "/tmp")
        (cons 'conv-key ck)
        (cons 'tags nil)))

;; -- empty / single ------------------------------------------------

(ert-deftest decknix-sidebar-previous-dedupe--empty ()
  "Empty input returns empty list."
  (should (null (decknix--sidebar-previous-dedupe nil)))
  (should (null (decknix--sidebar-previous-dedupe '()))))

(ert-deftest decknix-sidebar-previous-dedupe--single-entry-passthrough ()
  "A single entry survives untouched."
  (let* ((e (decknix-sidebar-previous-test--entry "s1" "ck-a"))
         (result (decknix--sidebar-previous-dedupe (list e))))
    (should (= (length result) 1))
    (should (equal (alist-get 'session-id (car result)) "s1"))
    (should (equal (alist-get 'conv-key (car result)) "ck-a"))))

;; -- conv-key collapsing ------------------------------------------

(ert-deftest decknix-sidebar-previous-dedupe--collapses-by-conv-key ()
  "Two entries with the same conv-key collapse to the first."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a" "first"))
         (e2 (decknix-sidebar-previous-test--entry "s2" "ck-a" "second"))
         (result (decknix--sidebar-previous-dedupe (list e1 e2))))
    (should (= (length result) 1))
    ;; First occurrence wins (input order).
    (should (equal (alist-get 'session-id (car result)) "s1"))
    (should (equal (alist-get 'name (car result)) "first"))))

(ert-deftest decknix-sidebar-previous-dedupe--preserves-order ()
  "Distinct conv-keys all kept, in original order."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a"))
         (e2 (decknix-sidebar-previous-test--entry "s2" "ck-b"))
         (e3 (decknix-sidebar-previous-test--entry "s3" "ck-c"))
         (result (decknix--sidebar-previous-dedupe (list e1 e2 e3))))
    (should (= (length result) 3))
    (should (equal (mapcar (lambda (e) (alist-get 'session-id e)) result)
                   '("s1" "s2" "s3")))))

(ert-deftest decknix-sidebar-previous-dedupe--three-share-one-key ()
  "Three entries sharing a conv-key collapse to one (the first)."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a" "alpha"))
         (e2 (decknix-sidebar-previous-test--entry "s2" "ck-a" "beta"))
         (e3 (decknix-sidebar-previous-test--entry "s3" "ck-a" "gamma"))
         (result (decknix--sidebar-previous-dedupe (list e1 e2 e3))))
    (should (= (length result) 1))
    (should (equal (alist-get 'name (car result)) "alpha"))))

;; -- nil conv-key fallback ---------------------------------------

(ert-deftest decknix-sidebar-previous-dedupe--nil-conv-key-uses-sid ()
  "Entries with no conv-key dedupe by session-id instead."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" nil))
         (e2 (decknix-sidebar-previous-test--entry "s1" nil))
         (e3 (decknix-sidebar-previous-test--entry "s2" nil))
         (result (decknix--sidebar-previous-dedupe (list e1 e2 e3))))
    (should (= (length result) 2))
    (should (equal (mapcar (lambda (e) (alist-get 'session-id e)) result)
                   '("s1" "s2")))))

(ert-deftest decknix-sidebar-previous-dedupe--mixed-nil-and-conv-key ()
  "An entry with nil conv-key and an entry with the same sid but a
conv-key are treated as distinct keys (the conv-key entry uses ck,
the no-conv-key entry uses (sid . SID))."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a" "with-ck"))
         (e2 (decknix-sidebar-previous-test--entry "s1" nil "no-ck"))
         (result (decknix--sidebar-previous-dedupe (list e1 e2))))
    (should (= (length result) 2))
    (should (equal (alist-get 'name (nth 0 result)) "with-ck"))
    (should (equal (alist-get 'name (nth 1 result)) "no-ck"))))

(ert-deftest decknix-sidebar-previous-dedupe--input-not-mutated ()
  "Dedupe does not destructively modify the input list."
  (let* ((e1 (decknix-sidebar-previous-test--entry "s1" "ck-a"))
         (e2 (decknix-sidebar-previous-test--entry "s2" "ck-a"))
         (input (list e1 e2))
         (input-copy (copy-tree input)))
    (decknix--sidebar-previous-dedupe input)
    (should (equal input input-copy))))

;; -- reload / persistence -----------------------------------------

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

(provide 'decknix-sidebar-previous-test)
;;; decknix-sidebar-previous-test.el ends here
