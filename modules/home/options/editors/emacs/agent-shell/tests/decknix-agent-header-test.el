;;; decknix-agent-header-test.el --- Tests for header-line builder -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-header "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Characterisation tests for the unified header-line builder.
;; The pure helpers (status icon / face tables, status detection,
;; tags lookup, workspace abbreviation, build composition) are
;; exercised directly; the timer + buffer-local update are tested
;; via stubbed `run-with-timer' and `cancel-timer' so the suite
;; never touches a live timer queue.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-header)

;; Carved module forward-declares these as `defvar'-without-value
;; (compiler hint only).  The let-binding pattern in the tests
;; needs the variable globally bound, so re-declare with an
;; initialiser here.  See AGENTS.md "Lexical-binding tests,
;; dynamic free vars".
(defvar decknix--agent-conv-key nil)
(defvar decknix--agent-auggie-session-id nil)
(defvar decknix--agent-session-workspace nil)
(defvar shell-maker--busy nil)

;; -- Status detection --------------------------------------------

(ert-deftest decknix-header-detect-status--prefers-workspace-detection ()
  "When `agent-shell-workspace--buffer-status' is bound, dispatches
to it instead of the shell-maker fallback."
  (cl-letf (((symbol-function 'agent-shell-workspace--buffer-status)
             (lambda (_buf) "waiting")))
    (with-temp-buffer
      (should (equal (decknix--header-detect-status) "waiting")))))

(ert-deftest decknix-header-detect-status--falls-back-to-shell-maker-busy ()
  "Without the workspace helper, `shell-maker--busy' = t -> working."
  (cl-letf (((symbol-function 'agent-shell-workspace--buffer-status) nil))
    (fmakunbound 'agent-shell-workspace--buffer-status)
    (with-temp-buffer
      (let ((shell-maker--busy t))
        (should (equal (decknix--header-detect-status) "working"))))))

(ert-deftest decknix-header-detect-status--killed-when-no-process ()
  "No live process and no busy flag -> killed."
  (cl-letf (((symbol-function 'agent-shell-workspace--buffer-status) nil))
    (fmakunbound 'agent-shell-workspace--buffer-status)
    (with-temp-buffer
      (let ((shell-maker--busy nil))
        (should (equal (decknix--header-detect-status) "killed"))))))

;; -- Icon / face tables ------------------------------------------

(ert-deftest decknix-header-status-icon--every-state-has-distinct-icon ()
  "All seven canonical states get a distinct icon, plus the `?'
fallback for unknown."
  (let ((icons (mapcar #'decknix--header-status-icon
                       '("ready" "finished" "working" "waiting"
                         "initializing" "killed"))))
    (should (= (length icons) (length (cl-remove-duplicates icons :test #'equal))))
    (should (equal (decknix--header-status-icon "garbage") "?"))))

(ert-deftest decknix-header-status-face--every-state-has-distinct-face ()
  "Every canonical state maps to a distinct face spec."
  (let ((faces (mapcar #'decknix--header-status-face
                       '("ready" "finished" "working" "waiting"
                         "initializing" "killed"))))
    (should (= (length faces) (length (cl-remove-duplicates faces :test #'equal))))
    (should (eq (decknix--header-status-face "garbage") 'shadow))))

;; -- Tags lookup -------------------------------------------------

(ert-deftest decknix-header-tags--prefers-conv-key-fast-path ()
  "When `decknix--agent-conv-key' is set, dispatches to
`-tags-for-conv-key' and bypasses the slow session-id path."
  (cl-letf (((symbol-function 'decknix--agent-tags-for-conv-key)
             (lambda (k)
               (should (equal k "ck-1"))
               '("foo" "bar")))
            ((symbol-function 'decknix--agent-tags-for-session)
             (lambda (_) (error "Should not fall through to slow path"))))
    (let ((decknix--agent-conv-key "ck-1"))
      (should (equal (decknix--header-tags) '("foo" "bar"))))))

(ert-deftest decknix-header-tags--falls-back-to-session-id ()
  "Without conv-key, dispatches to `-tags-for-session'."
  (cl-letf (((symbol-function 'decknix--agent-tags-for-conv-key)
             (lambda (_) nil))
            ((symbol-function 'decknix--agent-tags-for-session)
             (lambda (sid)
               (should (equal sid "sid-7"))
               '("baz"))))
    (let ((decknix--agent-conv-key nil)
          (decknix--agent-auggie-session-id "sid-7"))
      (should (equal (decknix--header-tags) '("baz"))))))

(ert-deftest decknix-header-tags--nil-when-no-identity ()
  "Returns nil when neither identifier is set."
  (let ((decknix--agent-conv-key nil)
        (decknix--agent-auggie-session-id nil))
    (should (null (decknix--header-tags)))))

;; -- Workspace abbreviation --------------------------------------

(ert-deftest decknix-header-workspace-short--abbreviates-home-paths ()
  "Returns the workspace path with `abbreviate-file-name' applied."
  (let* ((home (expand-file-name "~"))
         (decknix--agent-session-workspace
          (concat home "/code/decknix")))
    (should (equal (decknix--header-workspace-short)
                   "~/code/decknix"))))

(ert-deftest decknix-header-workspace-short--nil-when-empty ()
  "Returns nil for nil or empty workspace."
  (let ((decknix--agent-session-workspace nil))
    (should (null (decknix--header-workspace-short))))
  (let ((decknix--agent-session-workspace ""))
    (should (null (decknix--header-workspace-short)))))

;; -- Header build ------------------------------------------------

(ert-deftest decknix-header-build--includes-status-and-tags ()
  "Build string includes the status word + tag tokens."
  (cl-letf (((symbol-function 'decknix--header-detect-status)
             (lambda () "ready"))
            ((symbol-function 'decknix--header-upstream)
             (lambda () nil))
            ((symbol-function 'decknix--header-tags)
             (lambda () '("foo" "bar"))))
    (let ((out (decknix--header-build)))
      (should (string-match-p "ready" out))
      (should (string-match-p "#foo" out))
      (should (string-match-p "#bar" out)))))

(ert-deftest decknix-header-build--working-then-ready-renders-finished ()
  "After `working' the next `ready' tick renders as `finished'
until the user views the buffer.  This is the entire reason the
prev-status memo exists."
  (cl-letf (((symbol-function 'decknix--header-detect-status)
             (lambda () "ready"))
            ((symbol-function 'decknix--header-upstream)
             (lambda () nil))
            ((symbol-function 'decknix--header-tags)
             (lambda () nil)))
    (with-temp-buffer
      (setq-local decknix--header-prev-status "working")
      ;; Buffer is not the selected-window's buffer, so the
      ;; "clear finished on view" branch does NOT fire.
      (let ((out (decknix--header-build)))
        (should (string-match-p "finished" out))))))

;; -- Timer plumbing ----------------------------------------------

(ert-deftest decknix-header-stop-timer--clears-buffer-local-timer ()
  "Stop cancels the timer and nils the buffer-local var."
  (let ((cancel-called nil))
    (cl-letf (((symbol-function 'cancel-timer)
               (lambda (_) (setq cancel-called t))))
      (with-temp-buffer
        (setq-local decknix--header-timer 'fake-timer)
        (decknix--header-stop-timer)
        (should cancel-called)
        (should (null decknix--header-timer))))))

(ert-deftest decknix-header-stop-timer--noop-when-no-timer ()
  "Stop is a no-op when no timer is set."
  (cl-letf (((symbol-function 'cancel-timer)
             (lambda (_) (error "Should not be called"))))
    (with-temp-buffer
      (setq-local decknix--header-timer nil)
      (decknix--header-stop-timer)
      (should (null decknix--header-timer)))))

(provide 'decknix-agent-header-test)
;;; decknix-agent-header-test.el ends here
