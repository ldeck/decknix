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
  "Run BODY in a temp buffer with sample sidebar rows.
Line 1: Saved Session (`*-saved-session'=\"sid1\", `*-saved-conv-key'=\"ck1\")
Line 2: Previous Session (`decknix-previous-session'=( (session-id . \"sid2\") (conv-key . \"ck2\") ))
Line 3: Live Session (has `decknix-sidebar-saved-live'=t)
Line 4: No properties (e.g. header)
Point starts on line 1."
  (declare (indent 0))
  `(with-temp-buffer
     (insert (propertize "  ▷ saved-session\n"
                         'decknix-sidebar-saved-session "sid1"
                         'decknix-sidebar-saved-conv-key "ck1"))
     (insert (propertize "  ○ previous-session\n"
                         'decknix-previous-session '((session-id . "sid2")
                                                     (conv-key . "ck2"))))
     (insert (propertize "  ◐ live-session\n"
                         'decknix-sidebar-saved-session "sid3"
                         'decknix-sidebar-saved-conv-key "ck3"
                         'decknix-sidebar-saved-live t))
     (insert "  (header row, no properties)\n")
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
      (should (equal '("ck1" t)
                     (decknix-test-stub-call-args
                      'decknix--agent-conversation-set-hidden)))
      (should (= 1 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

(ert-deftest decknix-sidebar-row-actions/hide-at-point-on-non-saved-row ()
  (decknix-test-with-sidebar-rows
    (forward-line 3)
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
      (should (equal '("ck1" nil)
                     (decknix-test-stub-call-args
                      'decknix--agent-conversation-set-hidden)))
      (should (= 1 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

(ert-deftest decknix-sidebar-row-actions/unhide-at-point-on-non-saved-row ()
  (decknix-test-with-sidebar-rows
    (forward-line 3)
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
      (should (equal '("ck1" nil)
                     (decknix-test-stub-call-args
                      'decknix--agent-conversation-set-hidden 0)))
      (should (equal '("ck1" t)
                     (decknix-test-stub-call-args
                      'decknix--agent-conversation-set-hidden 1))))))


;; -- decknix--session-delete-by-id --------------------------------
;; Pin the shared deletion core used by both the sidebar command and
;; the session-picker C-d action.

(ert-deftest decknix-sidebar-row-actions/session-delete-by-id--deletes-file ()
  "Core deletion removes the JSON file when it exists."
  (let ((decknix-test--stub-calls nil)
        (fake-store (make-hash-table :test 'equal))
        (fake-convs (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'decknix--agent-session-file) (lambda (_) "/tmp/s1.json"))
              ((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'delete-file) (lambda (f) (push (list 'delete-file f) decknix-test--stub-calls)))
              ((symbol-function 'decknix--agent-tags-read) (lambda () fake-store))
              ((symbol-function 'decknix--agent-tags-write) (lambda (_) nil))
              ((symbol-function 'decknix--agent-tags-conversations) (lambda (_) fake-convs))
              ((symbol-function 'decknix--live-sessions-forget) (lambda (_ _2) nil)))
      (decknix--session-delete-by-id "s1" "ck1")
      (should (equal '(delete-file "/tmp/s1.json")
                     (car decknix-test--stub-calls))))))

(ert-deftest decknix-sidebar-row-actions/session-delete-by-id--no-error-if-file-missing ()
  "Core deletion does not error when the JSON file is absent (only warns)."
  (let ((fake-store (make-hash-table :test 'equal))
        (fake-convs (make-hash-table :test 'equal))
        (reached nil))
    (cl-letf (((symbol-function 'decknix--agent-session-file) (lambda (_) "/tmp/s1.json"))
              ((symbol-function 'file-exists-p) (lambda (_) nil))
              ((symbol-function 'delete-file) (lambda (_) (error "Should not be called")))
              ((symbol-function 'decknix--agent-tags-read) (lambda () fake-store))
              ((symbol-function 'decknix--agent-tags-write) (lambda (_) nil))
              ((symbol-function 'decknix--agent-tags-conversations) (lambda (_) fake-convs))
              ((symbol-function 'decknix--live-sessions-forget) (lambda (_ _2) nil)))
      ;; If an error escapes, the `setq' below never runs and the test fails.
      (decknix--session-delete-by-id "s1" "ck1")
      (setq reached t))
    (should reached)))

(ert-deftest decknix-sidebar-row-actions/session-delete-by-id--removes-from-previous ()
  "Core deletion removes the entry from decknix--sidebar-previous-sessions."
  (let ((decknix--sidebar-previous-sessions
         (list '((session-id . "s1") (conv-key . "ck1"))
               '((session-id . "s2") (conv-key . "ck2"))))
        (fake-store (make-hash-table :test 'equal))
        (fake-convs (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'decknix--agent-session-file) (lambda (_) "/tmp/s1.json"))
              ((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'delete-file) (lambda (_) nil))
              ((symbol-function 'decknix--agent-tags-read) (lambda () fake-store))
              ((symbol-function 'decknix--agent-tags-write) (lambda (_) nil))
              ((symbol-function 'decknix--agent-tags-conversations) (lambda (_) fake-convs))
              ((symbol-function 'decknix--live-sessions-forget) (lambda (_ _2) nil)))
      (decknix--session-delete-by-id "s1" "ck1")
      ;; s1 removed; s2 remains
      (should (= 1 (length decknix--sidebar-previous-sessions)))
      (should (equal "s2" (alist-get 'session-id
                                     (car decknix--sidebar-previous-sessions)))))))

(ert-deftest decknix-sidebar-row-actions/session-delete-by-id--calls-live-sessions-forget ()
  "Core deletion calls decknix--live-sessions-forget with the correct args."
  (let ((decknix-test--stub-calls nil)
        (fake-store (make-hash-table :test 'equal))
        (fake-convs (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'decknix--agent-session-file) (lambda (_) "/tmp/s1.json"))
              ((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'delete-file) (lambda (_) nil))
              ((symbol-function 'decknix--agent-tags-read) (lambda () fake-store))
              ((symbol-function 'decknix--agent-tags-write) (lambda (_) nil))
              ((symbol-function 'decknix--agent-tags-conversations) (lambda (_) fake-convs))
              ((symbol-function 'decknix--live-sessions-forget)
               (lambda (ck sid) (push (list 'forget ck sid) decknix-test--stub-calls))))
      (decknix--session-delete-by-id "s1" "ck1")
      (should (equal '(forget "ck1" "s1") (car decknix-test--stub-calls))))))

(ert-deftest decknix-sidebar-row-actions/session-delete-by-id--invalidates-cache ()
  "Core deletion resets the session metadata cache."
  (let ((decknix--agent-session-cache '("some" "data"))
        (decknix--agent-session-cache-time 999)
        (fake-store (make-hash-table :test 'equal))
        (fake-convs (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'decknix--agent-session-file) (lambda (_) "/tmp/s1.json"))
              ((symbol-function 'file-exists-p) (lambda (_) t))
              ((symbol-function 'delete-file) (lambda (_) nil))
              ((symbol-function 'decknix--agent-tags-read) (lambda () fake-store))
              ((symbol-function 'decknix--agent-tags-write) (lambda (_) nil))
              ((symbol-function 'decknix--agent-tags-conversations) (lambda (_) fake-convs))
              ((symbol-function 'decknix--live-sessions-forget) (lambda (_ _2) nil)))
      (decknix--session-delete-by-id "s1" "ck1")
      (should (null decknix--agent-session-cache))
      (should (= 0 decknix--agent-session-cache-time)))))

;; -- delete-killed ------------------------------------------------

(ert-deftest decknix-sidebar-row-actions/delete-killed--saved-row ()
  "Verification of deleting a row with Saved Session properties."
  (decknix-test-with-sidebar-rows
    (let ((decknix-test--stub-calls nil)
          (decknix--sidebar-previous-sessions (list '((session-id . "sid1") (conv-key . "ck1"))))
          (decknix--agent-session-cache '("fake"))
          (decknix--agent-session-cache-time 123)
          (fake-store (make-hash-table :test 'equal))
          (fake-convs (make-hash-table :test 'equal)))
      (puthash "ck1" '((tags . ("test"))) fake-convs)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'decknix--agent-session-file) (lambda (_) "/tmp/sid1.json"))
                ((symbol-function 'delete-file) (lambda (f) (push (list 'delete-file f) decknix-test--stub-calls)))
                ((symbol-function 'decknix--agent-tags-read) (lambda () fake-store))
                ((symbol-function 'decknix--agent-tags-write) (lambda (s) (push (list 'decknix--agent-tags-write s) decknix-test--stub-calls)))
                ((symbol-function 'decknix--agent-tags-conversations) (lambda (_) fake-convs))
                ((symbol-function 'decknix--live-sessions-forget) (lambda (ck sid) (push (list 'decknix--live-sessions-forget ck sid) decknix-test--stub-calls)))
                ((symbol-function 'agent-shell-workspace-sidebar-refresh) (lambda () (push (list 'agent-shell-workspace-sidebar-refresh) decknix-test--stub-calls)))
                ((symbol-function 'file-exists-p) (lambda (_) t)))
        (agent-shell-workspace-sidebar-delete-killed)
        ;; Assertions
        (should (equal '("/tmp/sid1.json") (cdr (assoc 'delete-file decknix-test--stub-calls))))
        (should (assoc 'decknix--agent-tags-write decknix-test--stub-calls))
        (should (equal '("ck1" "sid1") (cdr (assoc 'decknix--live-sessions-forget decknix-test--stub-calls))))
        (should (assoc 'agent-shell-workspace-sidebar-refresh decknix-test--stub-calls))
        (should (null decknix--sidebar-previous-sessions))
        (should (null decknix--agent-session-cache))
        (should (= 0 decknix--agent-session-cache-time))))))

(ert-deftest decknix-sidebar-row-actions/delete-killed--previous-row ()
  "Verification of deleting a row with Previous Session alist property."
  (decknix-test-with-sidebar-rows
    (forward-line 1) ;; Previous session row
    (let ((decknix-test--stub-calls nil)
          (decknix--sidebar-previous-sessions (list '((session-id . "sid2") (conv-key . "ck2"))))
          (fake-store (make-hash-table :test 'equal))
          (fake-convs (make-hash-table :test 'equal)))
      (puthash "ck2" '((tags . ("test"))) fake-convs)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'decknix--agent-session-file) (lambda (_) "/tmp/sid2.json"))
                ((symbol-function 'delete-file) (lambda (f) (push (list 'delete-file f) decknix-test--stub-calls)))
                ((symbol-function 'decknix--agent-tags-read) (lambda () fake-store))
                ((symbol-function 'decknix--agent-tags-write) (lambda (_) nil))
                ((symbol-function 'decknix--agent-tags-conversations) (lambda (_) fake-convs))
                ((symbol-function 'decknix--live-sessions-forget) (lambda (ck sid) (push (list 'decknix--live-sessions-forget ck sid) decknix-test--stub-calls)))
                ((symbol-function 'agent-shell-workspace-sidebar-refresh) (lambda () nil))
                ((symbol-function 'file-exists-p) (lambda (_) t)))
        (agent-shell-workspace-sidebar-delete-killed)
        (should (equal '("/tmp/sid2.json") (cdr (assoc 'delete-file decknix-test--stub-calls))))
        (should (equal '("ck2" "sid2") (cdr (assoc 'decknix--live-sessions-forget decknix-test--stub-calls))))
        (should (null decknix--sidebar-previous-sessions))))))

(ert-deftest decknix-sidebar-row-actions/delete-killed--aborts-if-live ()
  (decknix-test-with-sidebar-rows
    (forward-line 2) ;; Live session row
    (let ((decknix-test--stub-calls nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Should not prompt"))))
        (should-error (agent-shell-workspace-sidebar-delete-killed)
                      :type 'user-error)))))

(ert-deftest decknix-sidebar-row-actions/delete-killed--aborts-if-no-sid ()
  (decknix-test-with-sidebar-rows
    (forward-line 3) ;; Header row
    (let ((decknix-test--stub-calls nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Should not prompt"))))
        (agent-shell-workspace-sidebar-delete-killed)))))

(ert-deftest decknix-sidebar-row-actions/delete-killed--no-if-refused ()
  (decknix-test-with-sidebar-rows
    (let ((decknix-test--stub-calls nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                ((symbol-function 'delete-file) (lambda (_) (error "Should not delete"))))
        (agent-shell-workspace-sidebar-delete-killed)))))

(provide 'decknix-sidebar-row-actions-test)
;;; decknix-sidebar-row-actions-test.el ends here
