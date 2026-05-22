;;; decknix-hub-ci.el --- Hub CI classification + icon helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, ci

;;; Commentary:
;;
;; Pure helpers for CI status classification and sidebar icon
;; rendering used by the hub Requests / WIP sections.
;;
;;   * `decknix--hub-ci-soft-patterns' — case-insensitive substrings
;;     identifying lint/analysis checks (Codacy, Sonar, lint, etc.).
;;   * `decknix--hub-ci-check-soft-p' — single-check predicate.
;;   * `decknix--hub-ci-classify' — refines a CI status alist into
;;     "pass" / "running" / "fail" / "soft_fail" / "unknown" by
;;     inspecting individual check conclusions.
;;   * `decknix--hub-icon' — emoji-vs-text aware propertize that
;;     applies a display height shim only to true emoji codepoints,
;;     keeping plain symbols (✓, ?, @, ⟳) at normal line height.
;;   * `decknix--hub-ci-icon' — short glyph for a CI status, with an
;;     optional CONFLICTING merge indicator appended.
;;
;; All functions are pure: no buffer I/O, no global state mutation,
;; no async work.  Heredoc-side renderers (column inserters, transient
;; suffixes) call into these and remain in agent-shell.nix.

;;; Code:

(require 'cl-lib)

(defvar decknix--hub-ci-soft-patterns
  '("codacy" "sonarcloud" "sonarqube" "lint" "style" "format"
    "codecov" "coveralls" "snyk" "dependabot" "renovate")
  "Check name patterns considered \"soft\" (lint/analysis, not build).
A CI failure is classified as soft_fail when ALL failing checks
match one of these patterns (case-insensitive substring match).")

(defun decknix--hub-ci-check-soft-p (check-name)
  "Return non-nil if CHECK-NAME matches a soft/lint pattern."
  (let ((name (downcase (or check-name ""))))
    (cl-some (lambda (pat) (string-match-p (regexp-quote pat) name))
             decknix--hub-ci-soft-patterns)))

(defun decknix--hub-ci-classify (ci)
  "Classify a CI status alist into a refined status string.
Returns \"pass\", \"running\", \"fail\", \"soft_fail\", or \"unknown\".
\"soft_fail\" means all failing checks are lint/analysis (not build)."
  (if (not ci)
      "unknown"
    (let ((status (or (alist-get 'status ci) "unknown")))
      (if (not (string= status "fail"))
          status
        ;; It's a fail — check if ALL failures are soft
        (let ((checks (alist-get 'checks ci)))
          (if (not checks)
              "fail" ; no detail → assume hard fail
            (let* ((failing (seq-filter
                            (lambda (c)
                              (let ((conc (alist-get 'conclusion c)))
                                (member conc '("FAILURE" "ERROR" "TIMED_OUT"
                                               "CANCELLED" "ACTION_REQUIRED"))))
                            checks))
                   (all-soft (and failing
                                 (cl-every
                                  (lambda (c)
                                    (decknix--hub-ci-check-soft-p
                                     (alist-get 'name c)))
                                  failing))))
              (if all-soft "soft_fail" "fail"))))))))

(defun decknix--hub-icon (str face)
  "Create a sidebar icon from STR with FACE.
Only applies a display height property for emoji characters to prevent
them from stretching line height.  Plain text symbols (✓, ✗, @, ⟳, etc.)
are left at normal size for readability."
  (let* ((ch (and (> (length str) 0) (aref str 0)))
         (emoji-p (and ch (or
                           ;; Miscellaneous Symbols & Pictographs
                           (and (>= ch #x1F300) (<= ch #x1F9FF))
                           ;; Emoticons, Transport, Supplemental
                           (and (>= ch #x2600) (<= ch #x27BF))
                           ;; Dingbats
                           (and (>= ch #x2700) (<= ch #x27BF))))))
    (if emoji-p
        (propertize str 'face face 'display '(height 0.7))
      (propertize str 'face face))))

(defun decknix--hub-ci-icon (ci &optional mergeable)
  "Return a short icon string for a CI status alist.
Uses individual check details to distinguish soft from hard failures.
When MERGEABLE is \"CONFLICTING\", appends a conflict indicator."
  (let* ((classified (decknix--hub-ci-classify ci))
         (ci-icon (pcase classified
                    ("pass"      (decknix--hub-icon "●" 'success))
                    ("soft_fail" (decknix--hub-icon "●" '(:foreground "orange" :weight bold)))
                    ("fail"      (decknix--hub-icon "●" 'error))
                    ("running"   (decknix--hub-icon "◐" 'warning))
                    (_           (decknix--hub-icon "○" 'shadow))))
         (merge-icon (when (equal mergeable "CONFLICTING")
                       (decknix--hub-icon "▣" 'error))))
    (if merge-icon
        (concat ci-icon merge-icon)
      ci-icon)))

(provide 'decknix-hub-ci)
;;; decknix-hub-ci.el ends here
