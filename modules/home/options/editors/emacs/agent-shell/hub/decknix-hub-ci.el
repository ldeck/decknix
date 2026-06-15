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
;;   * `decknix--hub-ci-soft-patterns' — global case-insensitive substrings
;;     identifying lint/analysis checks (Codacy, Sonar, lint, etc.).
;;   * `decknix--hub-ci-repo-soft-patterns' — per-repo extra soft patterns.
;;   * `decknix--hub-ci-check-soft-p' — single-check predicate (global).
;;   * `decknix--hub-ci-check-soft-p-for-repo' — single-check predicate with
;;     per-repo extension.
;;   * `decknix--hub-ci-classify' — refines a CI status alist into
;;     "pass" / "running" / "fail" / "soft_fail" / "partial_fail" / "unknown"
;;     by inspecting individual check conclusions.  Accepts an optional REPO
;;     argument for per-repo soft-pattern matching.
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

(defvar decknix--hub-ci-repo-soft-patterns
  '(("nurturecloud/upside" . ("e2e" "integration" "canary" "infra"
                              "smoke" "performance" "staging" "stress")))
  "Per-repo extra soft patterns for CI classification.
Alist of REPO-FULL-NAME (\"owner/repo\") → extra soft-pattern strings.
Each extra pattern is a case-insensitive substring, same convention as
`decknix--hub-ci-soft-patterns'.  Combined with the global patterns when
classifying a check from that repository.")

(defun decknix--hub-ci-check-soft-p (check-name)
  "Return non-nil if CHECK-NAME matches a global soft/lint pattern."
  (let ((name (downcase (or check-name ""))))
    (cl-some (lambda (pat) (string-match-p (regexp-quote pat) name))
             decknix--hub-ci-soft-patterns)))

(defun decknix--hub-ci-check-soft-p-for-repo (check-name repo)
  "Return non-nil if CHECK-NAME is soft globally or via per-REPO patterns.
REPO is the full repository name (e.g. \"nurturecloud/upside\")."
  (or (decknix--hub-ci-check-soft-p check-name)
      (when repo
        (let* ((extra (cdr (assoc repo decknix--hub-ci-repo-soft-patterns)))
               (name (downcase (or check-name ""))))
          (cl-some (lambda (pat) (string-match-p (regexp-quote pat) name))
                   extra)))))

(defun decknix--hub-ci-classify (ci &optional repo)
  "Classify a CI status alist into a refined status string.
Returns \"pass\", \"running\", \"fail\", \"soft_fail\",
\"partial_fail\", or \"unknown\".

\"soft_fail\"    — ALL failing checks are lint/analysis (global or
                  per-REPO patterns).
\"partial_fail\" — SOME failing checks are soft, others are hard.
\"fail\"         — ALL failing checks are hard (no soft match).

REPO is the full repository name (e.g. \"nurturecloud/upside\"); when
provided, `decknix--hub-ci-repo-soft-patterns' is consulted for extra
per-repo soft patterns in addition to the global list."
  (if (not ci)
      "unknown"
    (let ((status (or (alist-get 'status ci) "unknown")))
      (if (not (string= status "fail"))
          status
        ;; It's a fail — classify by how many failures are soft.
        (let ((checks (alist-get 'checks ci)))
          (if (not checks)
              "fail" ; no check detail → conservative hard-fail
            (let* ((failing (seq-filter
                             (lambda (c)
                               (let ((conc (alist-get 'conclusion c)))
                                 (member conc '("FAILURE" "ERROR" "TIMED_OUT"
                                                "CANCELLED" "ACTION_REQUIRED"))))
                             checks))
                   (n-failing (length failing))
                   (n-soft (cl-count-if
                             (lambda (c)
                               (decknix--hub-ci-check-soft-p-for-repo
                                (alist-get 'name c) repo))
                             failing)))
              (cond
               ((= n-failing 0) "fail")          ; no failing checks → hard
               ((= n-soft n-failing) "soft_fail") ; all soft
               ((> n-soft 0) "partial_fail")      ; mixed soft + hard
               (t "fail")))))))))                  ; all hard

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

(defun decknix--hub-ci-icon (ci &optional mergeable repo)
  "Return a short icon string for a CI status alist.
Uses individual check details to distinguish soft from hard failures.
REPO (full owner/repo string) is forwarded to `decknix--hub-ci-classify'
for per-repo soft-pattern matching so the icon stays consistent with
the filter predicate.
When MERGEABLE is \"CONFLICTING\", appends a conflict indicator."
  (let* ((classified (decknix--hub-ci-classify ci repo))
         (ci-icon (pcase classified
                    ("pass"         (decknix--hub-icon "●" 'success))
                    ("soft_fail"    (decknix--hub-icon "●" '(:foreground "orange" :weight bold)))
                    ("partial_fail" (decknix--hub-icon "◑" '(:foreground "orange")))
                    ("fail"         (decknix--hub-icon "●" 'error))
                    ("running"      (decknix--hub-icon "◐" 'warning))
                    (_              (decknix--hub-icon "○" 'shadow))))
         (merge-icon (when (equal mergeable "CONFLICTING")
                       (decknix--hub-icon "▣" 'error))))
    (if merge-icon
        (concat ci-icon merge-icon)
      ci-icon)))

(provide 'decknix-hub-ci)
;;; decknix-hub-ci.el ends here
