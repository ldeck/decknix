;;; decknix-hub-teamcity.el --- TeamCity build + deploy pipeline indicators -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, teamcity, ci

;;; Commentary:
;;
;; TeamCity-side rendering helpers for the workspace sidebar:
;;
;;   * `decknix--hub-tc-build-for-branch' — alist lookup against the
;;     parsed `teamcity-builds.json' (`decknix--hub-teamcity-builds').
;;   * `decknix--hub-tc-icon' — single-glyph CI status badge.
;;   * `decknix--hub-deploy-indicator' — "DTSP" deploy pipeline rollup
;;     for a (repo, branch), with optional merged-at staleness logic.
;;
;; All three are pure functions over hub-data shaped alists.  The data
;; itself lives in two free defvars populated by the heredoc's hub
;; refresh code (`decknix--hub-teamcity-builds', `decknix--hub-deploys')
;; and a UI flag (`decknix--hub-show-deploys').  These are forward-
;; declared below so the byte-compiler stays clean while the runtime
;; load order — heredoc defvars first, then this module via
;; `(require ...)' — provides the actual bindings.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;; -- Forward declarations: defined elsewhere in agent-shell config --
(defvar decknix--hub-teamcity-builds)
(defvar decknix--hub-deploys)
(defvar decknix--hub-show-deploys)

;; -- TeamCity build status helpers --
(defun decknix--hub-tc-build-for-branch (branch)
  "Find the TeamCity build for BRANCH from hub data.
Returns nil if no match or no TC data."
  (when (and branch decknix--hub-teamcity-builds)
    (let ((builds (alist-get 'builds decknix--hub-teamcity-builds)))
      (seq-find (lambda (b)
                  (string= (or (alist-get 'branch b) "") branch))
                builds))))

(defun decknix--hub-tc-icon (build)
  "Return a TeamCity CI icon string for BUILD."
  (if (not build) ""
    (let ((state (or (alist-get 'state build) ""))
          (status (or (alist-get 'status build) "")))
      (cond
       ((string= state "running")
        (let ((pct (alist-get 'progress_pct build)))
          (propertize (if pct (format "◐%d%%" pct) "◐")
                      'face 'warning)))
       ((string= state "queued")
        (propertize "○" 'face 'shadow))
       ((string= status "SUCCESS")
        (propertize "●" 'face 'success))
       ((string= status "FAILURE")
        (propertize "●" 'face 'error))
       ((string= status "ERROR")
        (propertize "●" 'face 'error))
       (t (propertize "○" 'face 'shadow))))))

;; -- Deploy pipeline lookup + production-reached predicate --
(defun decknix--hub-deploy-environments (repo-full branch deploys)
  "Return the environments list for (REPO-FULL, BRANCH) in DEPLOYS, or nil.
DEPLOYS is a parsed `teamcity-deploys.json' alist.  Pure lookup shared by
`decknix--hub-deploy-indicator' and `decknix--hub-deployed-to-prod-p'."
  (let* ((repos (alist-get 'repos deploys))
         (repo-entry (seq-find
                      (lambda (r)
                        (string= (or (alist-get 'repo r) "") repo-full))
                      repos))
         (branches (when repo-entry (alist-get 'branches repo-entry)))
         (branch-entry (when branches
                         (seq-find
                          (lambda (b)
                            (string= (or (alist-get 'branch b) "") branch))
                          branches))))
    (when branch-entry (alist-get 'environments branch-entry))))

(defun decknix--hub-deployed-to-prod-p (repo-full merged-at deploys &optional branch)
  "Return non-nil when REPO-FULL has reached production after MERGED-AT.
Pure over DEPLOYS (parsed `teamcity-deploys.json' alist).  True when the
`production' environment for (REPO-FULL, BRANCH) has status SUCCESS and a
`finished' timestamp at or after MERGED-AT -- i.e. a production deploy
that positively contains the merged code.

BRANCH defaults to \"__default__\", where a merged PR's post-merge deploys
are recorded by the hub daemon (a merge lands on the repo's default
branch).  MERGED-AT and the env `finished' are ISO-8601 UTC strings,
which order correctly under `string<'.

Returns nil when MERGED-AT is missing, the repo/branch has no tracked
pipeline, or production has not yet succeeded post-merge -- so a merged
PR is treated as \"still deploying\" (kept visible) until production is
positively confirmed."
  (and (stringp merged-at)
       (not (string-empty-p merged-at))
       (let ((envs (decknix--hub-deploy-environments
                    repo-full (or branch "__default__") deploys)))
         (and envs
              (seq-some
               (lambda (e)
                 (and (string= (or (alist-get 'env e) "") "production")
                      (string= (or (alist-get 'status e) "") "SUCCESS")
                      (let ((finished (alist-get 'finished e)))
                        (and (stringp finished)
                             ;; finished >= merged-at (deploy contains the merge)
                             (not (string< finished merged-at))))))
               envs)
              t))))

;; -- Deploy pipeline indicator (DTSP) --
(defun decknix--hub-deploy-indicator (repo-full branch &optional merged-at)
  "Return colored DTSP deploy indicator for REPO-FULL and BRANCH.
Each letter represents an environment:
  D=Development T=Testing S=Stable P=Production
Green=success, Red=failure, Yellow=running, Grey=not deployed.

When MERGED-AT (ISO-8601 UTC timestamp) is non-nil and an environment's
deploy finished BEFORE the PR merged, render that env as grey — the
deployed artefact predates the merge so it cannot contain this PR."
  (if (or (not decknix--hub-show-deploys)
          (not decknix--hub-deploys))
      ""
    (let ((envs (decknix--hub-deploy-environments
                 repo-full branch decknix--hub-deploys)))
      (if (not envs)
          ""
        ;; Build the indicator string
        (let ((letters nil))
          (dolist (env-entry envs)
            (let* ((env (or (alist-get 'env env-entry) ""))
                   (status (or (alist-get 'status env-entry) ""))
                   (state (or (alist-get 'state env-entry) ""))
                   (finished (alist-get 'finished env-entry))
                   ;; Deploy predates merge — this env does not
                   ;; yet contain the PR's code.  ISO-8601 UTC
                   ;; timestamps compare correctly as strings.
                   (stale (and merged-at finished
                               (stringp merged-at) (stringp finished)
                               (string< finished merged-at)))
                   (letter (cond
                            ((string= env "development") "D")
                            ((string= env "testing") "T")
                            ((string= env "stable") "S")
                            ((string= env "production") "P")
                            ((string= env "uk_production") "U")
                            (t nil)))
                   (face (cond
                          (stale 'font-lock-comment-face)
                          ((string= state "running")
                           '(:foreground "#e5c07b" :weight bold))
                          ((string= state "queued")
                           '(:foreground "#abb2bf"))
                          ((string= status "SUCCESS")
                           '(:foreground "#98c379" :weight bold))
                          ((member status '("FAILURE" "ERROR"))
                           '(:foreground "#e06c75" :weight bold))
                          (t 'font-lock-comment-face))))
              (when letter
                (push (propertize letter 'face face) letters))))
          (if letters
              (concat " " (apply #'concat (nreverse letters)))
            ""))))))

(provide 'decknix-hub-teamcity)
;;; decknix-hub-teamcity.el ends here
