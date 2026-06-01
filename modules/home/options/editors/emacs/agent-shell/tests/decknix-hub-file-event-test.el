;;; decknix-hub-file-event-test.el --- Tests for hub file-event helper -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-file-event "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the contract of `decknix--hub-event-filename'.
;;
;; Rationale: the hub daemon writes JSON atomically (`*.tmp' →
;; `rename') so the file-notify event's source slot carries the tmp
;; name and the target slot carries the final name.  Before this
;; helper, the watcher inspected only the source slot and silently
;; dropped every atomic write.  These tests pin the resolution rules
;; (target-wins, `.tmp'-stripping, basename-only) so regressions there
;; are caught at build time.

;;; Code:

(require 'ert)
(require 'decknix-hub-file-event)

;; -- created / changed events: only the source slot is populated ---

(ert-deftest decknix-hub-file-event/created-returns-source-basename ()
  (should (equal "github-wip.json"
                 (decknix--hub-event-filename
                  '(123 created "/home/u/.config/decknix/hub/github-wip.json")))))

(ert-deftest decknix-hub-file-event/changed-returns-source-basename ()
  (should (equal "meta.json"
                 (decknix--hub-event-filename
                  '(123 changed "/home/u/.config/decknix/hub/meta.json")))))

(ert-deftest decknix-hub-file-event/deleted-returns-source-basename ()
  (should (equal "github-reviews.json"
                 (decknix--hub-event-filename
                  '(123 deleted "/home/u/.config/decknix/hub/github-reviews.json")))))

;; -- renamed events: source carries `.tmp', target carries final ---

(ert-deftest decknix-hub-file-event/renamed-prefers-target-over-tmp-source ()
  (should (equal "github-wip.json"
                 (decknix--hub-event-filename
                  '(123 renamed
                        "/home/u/.config/decknix/hub/github-wip.json.tmp"
                        "/home/u/.config/decknix/hub/github-wip.json")))))

(ert-deftest decknix-hub-file-event/renamed-resolves-teamcity-deploys ()
  (should (equal "teamcity-deploys.json"
                 (decknix--hub-event-filename
                  '(456 renamed
                        "/home/u/.config/decknix/hub/teamcity-deploys.json.tmp"
                        "/home/u/.config/decknix/hub/teamcity-deploys.json")))))

(ert-deftest decknix-hub-file-event/renamed-resolves-jira-tasks ()
  (should (equal "jira-tasks.json"
                 (decknix--hub-event-filename
                  '(789 renamed
                        "/home/u/.config/decknix/hub/jira-tasks.json.tmp"
                        "/home/u/.config/decknix/hub/jira-tasks.json")))))

;; -- half-state: a stray event names only the tmp sibling ----------
;;
;; Some kqueue backends fire a `created' event on the `.tmp' file
;; before the rename completes.  Stripping the suffix lets the caller
;; still match a canonical JSON name (the subsequent rename event is
;; idempotent so a duplicate refresh is harmless).

(ert-deftest decknix-hub-file-event/created-strips-tmp-suffix ()
  (should (equal "github-wip.json"
                 (decknix--hub-event-filename
                  '(123 created "/home/u/.config/decknix/hub/github-wip.json.tmp")))))

(ert-deftest decknix-hub-file-event/renamed-strips-tmp-when-no-target ()
  (should (equal "github-wip.json"
                 (decknix--hub-event-filename
                  '(123 renamed "/home/u/.config/decknix/hub/github-wip.json.tmp" nil)))))

;; -- edge cases ----------------------------------------------------

(ert-deftest decknix-hub-file-event/nil-source-and-target-returns-nil ()
  (should (null (decknix--hub-event-filename '(123 changed nil)))))

(ert-deftest decknix-hub-file-event/empty-target-falls-back-to-source ()
  (should (equal "github-wip.json"
                 (decknix--hub-event-filename
                  '(123 renamed "/home/u/.config/decknix/hub/github-wip.json" "")))))

(ert-deftest decknix-hub-file-event/non-tmp-source-returned-verbatim ()
  ;; A file whose canonical name happens to be unknown to the hub
  ;; should still pass through; the caller's `pcase' is responsible
  ;; for filtering noise.
  (should (equal "stray.txt"
                 (decknix--hub-event-filename
                  '(123 changed "/home/u/.config/decknix/hub/stray.txt")))))

(provide 'decknix-hub-file-event-test)

;;; decknix-hub-file-event-test.el ends here
