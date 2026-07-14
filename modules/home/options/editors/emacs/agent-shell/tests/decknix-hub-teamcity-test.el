;;; decknix-hub-teamcity-test.el --- Tests for hub TeamCity helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-teamcity "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the current behaviour of the TeamCity build /
;; deploy indicator helpers extracted from the agent-shell heredoc.
;; First real consumer of the TC fixture builders defined in
;; `decknix-test-helpers.el' (`decknix-test-make-teamcity-build',
;; `decknix-test-make-teamcity-env', `decknix-test-make-teamcity-deploys').
;;
;; Faces are propertized into the result strings; tests assert on
;; both the glyph and the face spec to lock the visual contract
;; the sidebar relies on.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-hub-teamcity)

(defun decknix-test--face-at (str pos)
  "Return the `face' text-property of STR at POS."
  (get-text-property pos 'face str))

;; -- decknix--hub-tc-build-for-branch -----------------------------

(ert-deftest decknix-hub-tc/build-for-branch-nil-when-no-branch ()
  (let ((decknix--hub-teamcity-builds
         `((builds . (,(decknix-test-make-teamcity-build :branch "main"))))))
    (should (null (decknix--hub-tc-build-for-branch nil)))))

(ert-deftest decknix-hub-tc/build-for-branch-nil-when-no-data ()
  (let ((decknix--hub-teamcity-builds nil))
    (should (null (decknix--hub-tc-build-for-branch "main")))))

(ert-deftest decknix-hub-tc/build-for-branch-finds-match ()
  (let* ((b (decknix-test-make-teamcity-build :branch "feature/foo" :status "FAILURE"))
         (decknix--hub-teamcity-builds
          `((builds . (,(decknix-test-make-teamcity-build :branch "main")
                       ,b
                       ,(decknix-test-make-teamcity-build :branch "release"))))))
    (should (eq b (decknix--hub-tc-build-for-branch "feature/foo")))))

(ert-deftest decknix-hub-tc/build-for-branch-nil-on-no-match ()
  (let ((decknix--hub-teamcity-builds
         `((builds . (,(decknix-test-make-teamcity-build :branch "main"))))))
    (should (null (decknix--hub-tc-build-for-branch "missing")))))

;; -- decknix--hub-tc-icon -----------------------------------------

(ert-deftest decknix-hub-tc/icon-empty-when-build-nil ()
  (should (string= "" (decknix--hub-tc-icon nil))))

(ert-deftest decknix-hub-tc/icon-running-shows-pct-when-set ()
  (let* ((build (decknix-test-make-teamcity-build
                 :state "running" :status "" :progress-pct 42))
         (icon (decknix--hub-tc-icon build)))
    (should (string-match-p "◐42%" icon))
    (should (eq 'warning (decknix-test--face-at icon 0)))))

(ert-deftest decknix-hub-tc/icon-running-without-pct ()
  (let* ((build (decknix-test-make-teamcity-build
                 :state "running" :status "" :progress-pct nil))
         (icon (decknix--hub-tc-icon build)))
    (should (string= "◐" (substring-no-properties icon)))))

(ert-deftest decknix-hub-tc/icon-queued ()
  (let* ((build (decknix-test-make-teamcity-build :state "queued" :status ""))
         (icon (decknix--hub-tc-icon build)))
    (should (string= "○" (substring-no-properties icon)))
    (should (eq 'shadow (decknix-test--face-at icon 0)))))

(ert-deftest decknix-hub-tc/icon-success ()
  (let* ((build (decknix-test-make-teamcity-build :status "SUCCESS"))
         (icon (decknix--hub-tc-icon build)))
    (should (string= "●" (substring-no-properties icon)))
    (should (eq 'success (decknix-test--face-at icon 0)))))

(ert-deftest decknix-hub-tc/icon-failure ()
  (let* ((build (decknix-test-make-teamcity-build :status "FAILURE"))
         (icon (decknix--hub-tc-icon build)))
    (should (string= "●" (substring-no-properties icon)))
    (should (eq 'error (decknix-test--face-at icon 0)))))

(ert-deftest decknix-hub-tc/icon-error-shares-failure-color ()
  (let* ((build (decknix-test-make-teamcity-build :status "ERROR"))
         (icon (decknix--hub-tc-icon build)))
    (should (string= "●" (substring-no-properties icon)))
    (should (eq 'error (decknix-test--face-at icon 0)))))

(ert-deftest decknix-hub-tc/icon-unknown-status-falls-back-to-question-mark ()
  (let* ((build (decknix-test-make-teamcity-build :status "WEIRD"))
         (icon (decknix--hub-tc-icon build)))
    (should (string= "○" (substring-no-properties icon)))
    (should (eq 'shadow (decknix-test--face-at icon 0)))))

;; -- decknix--hub-deploy-indicator --------------------------------

(ert-deftest decknix-hub-deploy/empty-when-toggle-off ()
  (let ((decknix--hub-show-deploys nil)
        (decknix--hub-deploys
         (decknix-test-make-teamcity-deploys
          '(("o/r" "main" ((env . "stable") (status . "SUCCESS") (state . "finished")))))))
    (should (string= "" (decknix--hub-deploy-indicator "o/r" "main")))))

(ert-deftest decknix-hub-deploy/empty-when-no-data ()
  (let ((decknix--hub-show-deploys t)
        (decknix--hub-deploys nil))
    (should (string= "" (decknix--hub-deploy-indicator "o/r" "main")))))

(ert-deftest decknix-hub-deploy/empty-when-repo-not-found ()
  (let ((decknix--hub-show-deploys t)
        (decknix--hub-deploys
         (decknix-test-make-teamcity-deploys
          `(("o/r" "main" ,(decknix-test-make-teamcity-env :env "stable"))))))
    (should (string= "" (decknix--hub-deploy-indicator "missing/repo" "main")))))

(ert-deftest decknix-hub-deploy/empty-when-branch-not-found ()
  (let ((decknix--hub-show-deploys t)
        (decknix--hub-deploys
         (decknix-test-make-teamcity-deploys
          `(("o/r" "main" ,(decknix-test-make-teamcity-env :env "stable"))))))
    (should (string= "" (decknix--hub-deploy-indicator "o/r" "feature/foo")))))

(ert-deftest decknix-hub-deploy/maps-env-names-to-letters ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env :env "development")
              ,(decknix-test-make-teamcity-env :env "testing")
              ,(decknix-test-make-teamcity-env :env "stable")
              ,(decknix-test-make-teamcity-env :env "production")
              ,(decknix-test-make-teamcity-env :env "uk_production")))))
         (out (decknix--hub-deploy-indicator "o/r" "main")))
    ;; Leading space precedes the indicator block when any letters
    ;; render — keeps it visually separated from the preceding column.
    (should (string= " DTSPU" (substring-no-properties out)))))

(ert-deftest decknix-hub-deploy/skips-unknown-env-names ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env :env "development")
              ,(decknix-test-make-teamcity-env :env "weird-env")
              ,(decknix-test-make-teamcity-env :env "stable")))))
         (out (decknix--hub-deploy-indicator "o/r" "main")))
    (should (string= " DS" (substring-no-properties out)))))

(ert-deftest decknix-hub-deploy/empty-when-only-unknown-envs ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env :env "weird-env"))))))
    (should (string= "" (decknix--hub-deploy-indicator "o/r" "main")))))

(ert-deftest decknix-hub-deploy/face-success-bold-green ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env
                :env "stable" :status "SUCCESS" :state "finished")))))
         (out (decknix--hub-deploy-indicator "o/r" "main")))
    ;; Position 0 is the leading space; position 1 is the first letter.
    (should (equal '(:foreground "#98c379" :weight bold)
                   (decknix-test--face-at out 1)))))

(ert-deftest decknix-hub-deploy/face-failure-bold-red ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env
                :env "stable" :status "FAILURE" :state "finished")))))
         (out (decknix--hub-deploy-indicator "o/r" "main")))
    (should (equal '(:foreground "#e06c75" :weight bold)
                   (decknix-test--face-at out 1)))))

(ert-deftest decknix-hub-deploy/face-error-shares-failure-color ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env
                :env "stable" :status "ERROR" :state "finished")))))
         (out (decknix--hub-deploy-indicator "o/r" "main")))
    (should (equal '(:foreground "#e06c75" :weight bold)
                   (decknix-test--face-at out 1)))))

(ert-deftest decknix-hub-deploy/face-running-bold-yellow ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env
                :env "stable" :state "running" :status "")))))
         (out (decknix--hub-deploy-indicator "o/r" "main")))
    (should (equal '(:foreground "#e5c07b" :weight bold)
                   (decknix-test--face-at out 1)))))

(ert-deftest decknix-hub-deploy/face-queued-grey ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env
                :env "stable" :state "queued" :status "")))))
         (out (decknix--hub-deploy-indicator "o/r" "main")))
    (should (equal '(:foreground "#abb2bf")
                   (decknix-test--face-at out 1)))))

(ert-deftest decknix-hub-deploy/face-unknown-falls-back-to-comment ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env
                :env "stable" :state "" :status "WEIRD")))))
         (out (decknix--hub-deploy-indicator "o/r" "main")))
    (should (eq 'font-lock-comment-face (decknix-test--face-at out 1)))))

;; -- Stale (merged-at) handling -----------------------------------

(ert-deftest decknix-hub-deploy/stale-when-deploy-finished-before-merge ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env
                :env "stable"
                :status "SUCCESS"
                :state "finished"
                :finished "2026-04-30T10:00:00Z")))))
         (out (decknix--hub-deploy-indicator
               "o/r" "main" "2026-05-01T10:00:00Z")))
    ;; Deploy finished a day before the merge — render greyed out
    ;; even though status is SUCCESS.
    (should (eq 'font-lock-comment-face (decknix-test--face-at out 1)))))

(ert-deftest decknix-hub-deploy/not-stale-when-deploy-finished-after-merge ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env
                :env "stable"
                :status "SUCCESS"
                :state "finished"
                :finished "2026-05-02T10:00:00Z")))))
         (out (decknix--hub-deploy-indicator
               "o/r" "main" "2026-05-01T10:00:00Z")))
    (should (equal '(:foreground "#98c379" :weight bold)
                   (decknix-test--face-at out 1)))))

(ert-deftest decknix-hub-deploy/not-stale-when-finished-missing ()
  (let* ((decknix--hub-show-deploys t)
         (decknix--hub-deploys
          (decknix-test-make-teamcity-deploys
           `(("o/r" "main"
              ,(decknix-test-make-teamcity-env
                :env "stable"
                :status "SUCCESS"
                :state "finished"
                :finished nil)))))
         (out (decknix--hub-deploy-indicator
               "o/r" "main" "2026-05-01T10:00:00Z")))
    (should (equal '(:foreground "#98c379" :weight bold)
                   (decknix-test--face-at out 1)))))

;; -- Production-reached predicate (deploy-gated WIP cleanup, #137) --

(ert-deftest decknix-hub-deployed-to-prod/true-when-prod-success-after-merge ()
  "Production SUCCESS finishing at/after merge -> reached production."
  (let ((deploys (decknix-test-make-teamcity-deploys
                  `(("o/r" "__default__"
                     ,(decknix-test-make-teamcity-env
                       :env "production" :status "SUCCESS"
                       :finished "2026-05-01T12:00:00Z"))))))
    (should (decknix--hub-deployed-to-prod-p
             "o/r" "2026-05-01T10:00:00Z" deploys))))

(ert-deftest decknix-hub-deployed-to-prod/nil-when-prod-predates-merge ()
  "Production deploy that finished BEFORE the merge does not count."
  (let ((deploys (decknix-test-make-teamcity-deploys
                  `(("o/r" "__default__"
                     ,(decknix-test-make-teamcity-env
                       :env "production" :status "SUCCESS"
                       :finished "2026-05-01T08:00:00Z"))))))
    (should-not (decknix--hub-deployed-to-prod-p
                 "o/r" "2026-05-01T10:00:00Z" deploys))))

(ert-deftest decknix-hub-deployed-to-prod/nil-when-prod-not-success ()
  "A failed/running production deploy is not \"reached production\"."
  (let ((deploys (decknix-test-make-teamcity-deploys
                  `(("o/r" "__default__"
                     ,(decknix-test-make-teamcity-env
                       :env "production" :status "FAILURE"
                       :finished "2026-05-01T12:00:00Z"))))))
    (should-not (decknix--hub-deployed-to-prod-p
                 "o/r" "2026-05-01T10:00:00Z" deploys))))

(ert-deftest decknix-hub-deployed-to-prod/nil-when-no-prod-env ()
  "A repo tracked only up to `stable' has not reached production."
  (let ((deploys (decknix-test-make-teamcity-deploys
                  `(("o/r" "__default__"
                     ,(decknix-test-make-teamcity-env
                       :env "stable" :status "SUCCESS"
                       :finished "2026-05-01T12:00:00Z"))))))
    (should-not (decknix--hub-deployed-to-prod-p
                 "o/r" "2026-05-01T10:00:00Z" deploys))))

(ert-deftest decknix-hub-deployed-to-prod/nil-when-merged-at-missing ()
  "No merge timestamp -> cannot confirm; treat as not-yet-deployed."
  (let ((deploys (decknix-test-make-teamcity-deploys
                  `(("o/r" "__default__"
                     ,(decknix-test-make-teamcity-env
                       :env "production" :status "SUCCESS"
                       :finished "2026-05-01T12:00:00Z"))))))
    (should-not (decknix--hub-deployed-to-prod-p "o/r" nil deploys))
    (should-not (decknix--hub-deployed-to-prod-p "o/r" "" deploys))))

(ert-deftest decknix-hub-deployed-to-prod/nil-when-repo-untracked ()
  "A repo with no deploy pipeline entry is not-yet-deployed (kept visible)."
  (let ((deploys (decknix-test-make-teamcity-deploys
                  `(("other/repo" "__default__"
                     ,(decknix-test-make-teamcity-env
                       :env "production" :status "SUCCESS"
                       :finished "2026-05-01T12:00:00Z"))))))
    (should-not (decknix--hub-deployed-to-prod-p
                 "o/r" "2026-05-01T10:00:00Z" deploys))))

(ert-deftest decknix-hub-deployed-to-prod/honours-explicit-branch ()
  "The optional BRANCH arg overrides the `__default__' lookup."
  (let ((deploys (decknix-test-make-teamcity-deploys
                  `(("o/r" "release/1.2"
                     ,(decknix-test-make-teamcity-env
                       :env "production" :status "SUCCESS"
                       :finished "2026-05-01T12:00:00Z"))))))
    (should (decknix--hub-deployed-to-prod-p
             "o/r" "2026-05-01T10:00:00Z" deploys "release/1.2"))
    ;; default branch lookup misses the release branch
    (should-not (decknix--hub-deployed-to-prod-p
                 "o/r" "2026-05-01T10:00:00Z" deploys))))

(provide 'decknix-hub-teamcity-test)
;;; decknix-hub-teamcity-test.el ends here
