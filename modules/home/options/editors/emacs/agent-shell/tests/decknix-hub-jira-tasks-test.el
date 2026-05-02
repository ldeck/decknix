;;; decknix-hub-jira-tasks-test.el --- Tests for hub Jira task helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-jira-tasks "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the current behaviour of `decknix--hub-task-status-icon'
;; extracted from the agent-shell heredoc.  Covers the four named status
;; mappings (with their exact face spec and glyph), the unknown / empty /
;; nil fallback, and case-insensitivity.

;;; Code:

(require 'ert)
(require 'decknix-test-helpers)
(require 'decknix-hub-jira-tasks)

;; -- Helpers ------------------------------------------------------

(defun decknix-test--icon-glyph (icon)
  "Return the underlying string of the propertized ICON."
  (substring-no-properties icon))

(defun decknix-test--icon-face (icon)
  "Return the `face' text-property of ICON at position 0."
  (get-text-property 0 'face icon))

;; -- Named statuses -----------------------------------------------

(ert-deftest decknix-hub-jira-tasks/status-icon-in-progress ()
  (let ((icon (decknix--hub-task-status-icon "In Progress")))
    (should (equal "●" (decknix-test--icon-glyph icon)))
    (should (equal '(:foreground "#61afef") (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-jira-tasks/status-icon-code-review ()
  (let ((icon (decknix--hub-task-status-icon "Code Review")))
    (should (equal "◐" (decknix-test--icon-glyph icon)))
    (should (equal '(:foreground "#c678dd") (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-jira-tasks/status-icon-blocked ()
  (let ((icon (decknix--hub-task-status-icon "Blocked")))
    (should (equal "✕" (decknix-test--icon-glyph icon)))
    (should (equal '(:foreground "#e06c75") (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-jira-tasks/status-icon-ready ()
  (let ((icon (decknix--hub-task-status-icon "Ready")))
    (should (equal "○" (decknix-test--icon-glyph icon)))
    (should (equal '(:foreground "#98c379") (decknix-test--icon-face icon)))))

;; -- Fallback / case-insensitivity --------------------------------

(ert-deftest decknix-hub-jira-tasks/status-icon-unknown-falls-back ()
  (let ((icon (decknix--hub-task-status-icon "To Do")))
    (should (equal "·" (decknix-test--icon-glyph icon)))
    (should (eq 'font-lock-comment-face (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-jira-tasks/status-icon-empty-falls-back ()
  (let ((icon (decknix--hub-task-status-icon "")))
    (should (equal "·" (decknix-test--icon-glyph icon)))
    (should (eq 'font-lock-comment-face (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-jira-tasks/status-icon-nil-falls-back ()
  ;; The function coerces nil -> "" via `(or status "")' and then
  ;; downcases, so the unknown branch fires.
  (let ((icon (decknix--hub-task-status-icon nil)))
    (should (equal "·" (decknix-test--icon-glyph icon)))
    (should (eq 'font-lock-comment-face (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-jira-tasks/status-icon-is-case-insensitive ()
  ;; pcase compares against `(downcase status)' so any casing of the
  ;; named statuses must hit the same branch.
  (should (equal "●" (decknix-test--icon-glyph
                      (decknix--hub-task-status-icon "in progress"))))
  (should (equal "●" (decknix-test--icon-glyph
                      (decknix--hub-task-status-icon "IN PROGRESS"))))
  (should (equal "◐" (decknix-test--icon-glyph
                      (decknix--hub-task-status-icon "code review"))))
  (should (equal "✕" (decknix-test--icon-glyph
                      (decknix--hub-task-status-icon "BLOCKED"))))
  (should (equal "○" (decknix-test--icon-glyph
                      (decknix--hub-task-status-icon "ready")))))

(provide 'decknix-hub-jira-tasks-test)
;;; decknix-hub-jira-tasks-test.el ends here
