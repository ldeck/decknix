;;; decknix-hub-ci-test.el --- Tests for hub CI classification + icons -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-ci "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the current behaviour of the CI helpers extracted
;; from the agent-shell heredoc.  Groups:
;;
;;   * `decknix--hub-ci-check-soft-p' — substring + case sensitivity.
;;   * `decknix--hub-ci-check-soft-p-for-repo' — per-repo extensions.
;;   * `decknix--hub-ci-classify' — branches over status + check
;;     conclusions (no-ci, no-checks, all-soft, all-hard, mixed).
;;     Includes partial_fail (some soft + some hard) and repo arg.
;;   * `decknix--hub-icon' — emoji-vs-text display-height heuristic
;;     at codepoint range boundaries.
;;   * `decknix--hub-ci-icon' — glyph + face per classification, plus
;;     CONFLICTING merge-indicator append rule.

;;; Code:

(require 'ert)
(require 'decknix-test-helpers)
(require 'decknix-hub-ci)

;; -- Test helpers -------------------------------------------------

(defun decknix-test--icon-glyph (icon)
  "Return the underlying string of the propertized ICON."
  (substring-no-properties icon))

(defun decknix-test--icon-face (icon)
  "Return the `face' text-property of ICON at position 0."
  (get-text-property 0 'face icon))

(defun decknix-test--icon-display (icon)
  "Return the `display' text-property of ICON at position 0."
  (get-text-property 0 'display icon))

(defun decknix-test--make-ci (status &optional checks)
  "Build a CI alist with STATUS and optional CHECKS list."
  (let ((alist (list (cons 'status status))))
    (when checks
      (setq alist (append alist (list (cons 'checks checks)))))
    alist))

(defun decknix-test--make-check (name conclusion)
  "Build a single check alist with NAME and CONCLUSION."
  `((name . ,name) (conclusion . ,conclusion)))

;; -- Soft pattern matching ----------------------------------------

(ert-deftest decknix-hub-ci/check-soft-p-matches-codacy ()
  (should (decknix--hub-ci-check-soft-p "codacy")))

(ert-deftest decknix-hub-ci/check-soft-p-is-case-insensitive ()
  ;; downcase shim normalises name before regexp-quote substring match.
  (should (decknix--hub-ci-check-soft-p "Codacy/Production"))
  (should (decknix--hub-ci-check-soft-p "SonarCloud Analysis"))
  (should (decknix--hub-ci-check-soft-p "LINT")))

(ert-deftest decknix-hub-ci/check-soft-p-substring-anywhere ()
  ;; Pattern is substring (no anchors) — matches mid-string.
  (should (decknix--hub-ci-check-soft-p "frontend-lint"))
  (should (decknix--hub-ci-check-soft-p "ci/sonarqube/scan")))

(ert-deftest decknix-hub-ci/check-soft-p-rejects-non-soft ()
  (should-not (decknix--hub-ci-check-soft-p "build"))
  (should-not (decknix--hub-ci-check-soft-p "test"))
  (should-not (decknix--hub-ci-check-soft-p "deploy")))

(ert-deftest decknix-hub-ci/check-soft-p-handles-nil ()
  ;; (or nil "") -> "" -> downcase -> no match.
  (should-not (decknix--hub-ci-check-soft-p nil)))

(ert-deftest decknix-hub-ci/check-soft-p-handles-empty ()
  (should-not (decknix--hub-ci-check-soft-p "")))

;; -- Classify -----------------------------------------------------

(ert-deftest decknix-hub-ci/classify-nil-is-unknown ()
  (should (equal "unknown" (decknix--hub-ci-classify nil))))

(ert-deftest decknix-hub-ci/classify-no-status-is-unknown ()
  ;; alist-get returns nil when 'status is missing -> falls through (or nil "unknown").
  (should (equal "unknown" (decknix--hub-ci-classify '((checks . nil))))))

(ert-deftest decknix-hub-ci/classify-pass-pass-through ()
  (should (equal "pass" (decknix--hub-ci-classify (decknix-test--make-ci "pass")))))

(ert-deftest decknix-hub-ci/classify-running-pass-through ()
  (should (equal "running" (decknix--hub-ci-classify (decknix-test--make-ci "running")))))

(ert-deftest decknix-hub-ci/classify-fail-without-checks-stays-fail ()
  ;; No `checks' detail -> conservative hard-fail classification.
  (should (equal "fail" (decknix--hub-ci-classify (decknix-test--make-ci "fail")))))

(ert-deftest decknix-hub-ci/classify-fail-with-no-failing-checks-stays-fail ()
  ;; All checks SUCCESS but top-level status is "fail" — `failing' is nil,
  ;; so `(and failing ...)' short-circuits to nil -> hard fail.
  (let ((ci (decknix-test--make-ci
             "fail"
             (list (decknix-test--make-check "build" "SUCCESS")
                   (decknix-test--make-check "test" "SUCCESS")))))
    (should (equal "fail" (decknix--hub-ci-classify ci)))))

(ert-deftest decknix-hub-ci/classify-fail-all-soft-becomes-soft-fail ()
  (let ((ci (decknix-test--make-ci
             "fail"
             (list (decknix-test--make-check "codacy" "FAILURE")
                   (decknix-test--make-check "lint-frontend" "FAILURE")
                   (decknix-test--make-check "build" "SUCCESS")))))
    (should (equal "soft_fail" (decknix--hub-ci-classify ci)))))

(ert-deftest decknix-hub-ci/classify-fail-all-hard-stays-fail ()
  (let ((ci (decknix-test--make-ci
             "fail"
             (list (decknix-test--make-check "build" "FAILURE")
                   (decknix-test--make-check "test" "ERROR")))))
    (should (equal "fail" (decknix--hub-ci-classify ci)))))

(ert-deftest decknix-hub-ci/classify-fail-mixed-soft-and-hard-is-partial-fail ()
  ;; Mixed soft + hard failures → partial_fail (not "fail").
  (let ((ci (decknix-test--make-ci
             "fail"
             (list (decknix-test--make-check "codacy" "FAILURE")
                   (decknix-test--make-check "build" "FAILURE")))))
    (should (equal "partial_fail" (decknix--hub-ci-classify ci)))))

(ert-deftest decknix-hub-ci/classify-fail-mixed-multiple-soft-one-hard ()
  ;; Two soft checks + one hard → partial_fail.
  (let ((ci (decknix-test--make-ci
             "fail"
             (list (decknix-test--make-check "codacy" "FAILURE")
                   (decknix-test--make-check "lint-frontend" "FAILURE")
                   (decknix-test--make-check "build" "FAILURE")))))
    (should (equal "partial_fail" (decknix--hub-ci-classify ci)))))

;; -- Repo-specific soft patterns ----------------------------------

(ert-deftest decknix-hub-ci/check-soft-p-for-repo-global-pattern-without-repo ()
  ;; Global patterns work even without a repo arg.
  (should (decknix--hub-ci-check-soft-p-for-repo "codacy" nil))
  (should-not (decknix--hub-ci-check-soft-p-for-repo "build" nil)))

(ert-deftest decknix-hub-ci/check-soft-p-for-repo-extra-pattern-matched ()
  ;; Per-repo extra pattern matches when repo is provided.
  (should (decknix--hub-ci-check-soft-p-for-repo
           "e2e-suite" "nurturecloud/upside"))
  (should (decknix--hub-ci-check-soft-p-for-repo
           "integration-tests" "nurturecloud/upside")))

(ert-deftest decknix-hub-ci/check-soft-p-for-repo-extra-pattern-not-global ()
  ;; Extra pattern is repo-scoped: no match for a different repo.
  (should-not (decknix--hub-ci-check-soft-p-for-repo
               "e2e-suite" "another-org/another-repo")))

(ert-deftest decknix-hub-ci/classify-partial-becomes-soft-with-repo ()
  ;; With the repo arg, an e2e failure (repo-soft) + codacy (global-soft)
  ;; = all soft → soft_fail, not partial_fail.
  (let ((ci (decknix-test--make-ci
             "fail"
             (list (decknix-test--make-check "codacy" "FAILURE")
                   (decknix-test--make-check "e2e-suite" "FAILURE")))))
    (should (equal "soft_fail"
                   (decknix--hub-ci-classify ci "nurturecloud/upside")))))

(ert-deftest decknix-hub-ci/classify-partial-repo-soft-plus-hard-still-partial ()
  ;; Even with repo patterns, a hard build failure keeps partial_fail.
  (let ((ci (decknix-test--make-ci
             "fail"
             (list (decknix-test--make-check "e2e-suite" "FAILURE")
                   (decknix-test--make-check "build" "FAILURE")))))
    (should (equal "partial_fail"
                   (decknix--hub-ci-classify ci "nurturecloud/upside")))))

(ert-deftest decknix-hub-ci/classify-fail-honours-all-failure-conclusions ()
  ;; FAILURE / ERROR / TIMED_OUT / CANCELLED / ACTION_REQUIRED all count.
  (dolist (conc '("FAILURE" "ERROR" "TIMED_OUT" "CANCELLED" "ACTION_REQUIRED"))
    (let ((ci (decknix-test--make-ci
               "fail"
               (list (decknix-test--make-check "build" conc)))))
      (should (equal "fail" (decknix--hub-ci-classify ci))))))

;; -- decknix--hub-icon: emoji-vs-text heuristic -------------------

(ert-deftest decknix-hub-ci/icon-emoji-gets-display-height ()
  ;; 📥 = #x1F4E5 (Misc Symbols & Pictographs range).
  (let ((icon (decknix--hub-icon "📥" 'success)))
    (should (equal '(height 0.7) (decknix-test--icon-display icon)))
    (should (eq 'success (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-ci/icon-text-symbol-no-display-height ()
  ;; ⟳ = #x27F3 — outside both 2600-27BF and 1F300-1F9FF ranges.
  (let ((icon (decknix--hub-icon "⟳" 'warning)))
    (should-not (decknix-test--icon-display icon))
    (should (eq 'warning (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-ci/icon-ascii-no-display-height ()
  ;; @ = #x40 — well below any emoji range.
  (let ((icon (decknix--hub-icon "@" 'default)))
    (should-not (decknix-test--icon-display icon))))

(ert-deftest decknix-hub-ci/icon-codepoint-range-boundaries ()
  ;; Lower edge of 2600-27BF (Misc Symbols + Dingbats).
  (should (equal '(height 0.7)
                 (decknix-test--icon-display
                  (decknix--hub-icon (string #x2600) 'default))))
  ;; Upper edge of 2600-27BF.
  (should (equal '(height 0.7)
                 (decknix-test--icon-display
                  (decknix--hub-icon (string #x27BF) 'default))))
  ;; Just above 27BF — no longer matched.
  (should-not (decknix-test--icon-display
               (decknix--hub-icon (string #x27C0) 'default)))
  ;; Lower edge of 1F300-1F9FF.
  (should (equal '(height 0.7)
                 (decknix-test--icon-display
                  (decknix--hub-icon (string #x1F300) 'default))))
  ;; Upper edge of 1F300-1F9FF.
  (should (equal '(height 0.7)
                 (decknix-test--icon-display
                  (decknix--hub-icon (string #x1F9FF) 'default)))))

(ert-deftest decknix-hub-ci/icon-empty-string-propertizes-without-display ()
  ;; ch is nil -> emoji-p false -> no display, but face still applied.
  (let ((icon (decknix--hub-icon "" 'success)))
    (should (equal "" (decknix-test--icon-glyph icon)))
    (should-not (decknix-test--icon-display icon))))

;; -- decknix--hub-ci-icon: glyph + face per classification --------

(ert-deftest decknix-hub-ci/ci-icon-pass-is-circle-success ()
  (let ((icon (decknix--hub-ci-icon (decknix-test--make-ci "pass"))))
    (should (equal "●" (decknix-test--icon-glyph icon)))
    (should (eq 'success (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-ci/ci-icon-soft-fail-is-circle-warning ()
  (let* ((ci (decknix-test--make-ci
              "fail"
              (list (decknix-test--make-check "codacy" "FAILURE"))))
         (icon (decknix--hub-ci-icon ci)))
    (should (equal "●" (decknix-test--icon-glyph icon)))
    (should (equal '(:foreground "orange" :weight bold) (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-ci/ci-icon-partial-fail-is-right-half-circle-orange ()
  ;; Mixed soft+hard → partial_fail → ◑ with orange (no :weight bold).
  (let* ((ci (decknix-test--make-ci
              "fail"
              (list (decknix-test--make-check "codacy" "FAILURE")
                    (decknix-test--make-check "build" "FAILURE"))))
         (icon (decknix--hub-ci-icon ci)))
    (should (equal "◑" (decknix-test--icon-glyph icon)))
    (should (equal '(:foreground "orange") (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-ci/ci-icon-fail-is-circle-error ()
  (let* ((ci (decknix-test--make-ci
              "fail"
              (list (decknix-test--make-check "build" "FAILURE"))))
         (icon (decknix--hub-ci-icon ci)))
    (should (equal "●" (decknix-test--icon-glyph icon)))
    (should (eq 'error (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-ci/ci-icon-repo-arg-upgrades-partial-to-soft ()
  ;; When repo arg makes all failing checks soft, icon should be soft_fail.
  (let* ((ci (decknix-test--make-ci
              "fail"
              (list (decknix-test--make-check "codacy" "FAILURE")
                    (decknix-test--make-check "e2e-suite" "FAILURE"))))
         (icon (decknix--hub-ci-icon ci nil "nurturecloud/upside")))
    ;; All soft (codacy=global-soft, e2e=repo-soft) → soft_fail → ●+orange+bold.
    (should (equal "●" (decknix-test--icon-glyph icon)))
    (should (equal '(:foreground "orange" :weight bold)
                   (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-ci/ci-icon-running-is-half-circle-warning ()
  (let ((icon (decknix--hub-ci-icon (decknix-test--make-ci "running"))))
    (should (equal "◐" (decknix-test--icon-glyph icon)))
    (should (eq 'warning (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-ci/ci-icon-unknown-is-hollow-circle-shadow ()
  ;; nil ci -> classify=unknown -> ○ glyph + shadow face.
  (let ((icon (decknix--hub-ci-icon nil)))
    (should (equal "○" (decknix-test--icon-glyph icon)))
    (should (eq 'shadow (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-ci/ci-icon-conflicting-appends-merge-glyph ()
  (let ((icon (decknix--hub-ci-icon (decknix-test--make-ci "pass") "CONFLICTING")))
    ;; Concatenated string: ● then ▣ (shape-family conflict glyph)
    (should (equal "●▣" (decknix-test--icon-glyph icon)))
    ;; First char keeps success face, second is error.
    (should (eq 'success (get-text-property 0 'face icon)))
    (should (eq 'error (get-text-property 1 'face icon)))))

(ert-deftest decknix-hub-ci/ci-icon-non-conflicting-mergeable-no-append ()
  ;; Anything other than the literal "CONFLICTING" string is ignored.
  (let ((icon (decknix--hub-ci-icon (decknix-test--make-ci "pass") "MERGEABLE")))
    (should (equal "●" (decknix-test--icon-glyph icon))))
  (let ((icon (decknix--hub-ci-icon (decknix-test--make-ci "pass") nil)))
    (should (equal "●" (decknix-test--icon-glyph icon)))))

(provide 'decknix-hub-ci-test)
;;; decknix-hub-ci-test.el ends here
