;;; decknix-ship.el --- Where a merged PR is on its way to production -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, deploy

;;; Commentary:
;;
;; Pure stage model for my merged PRs, read by the sidebar to keep a merged
;; PR under the session that raised it until its last stage is verified,
;; then show it dimmed as shipped for `decknix-sidebar-shipped-retention',
;; then drop it.
;;
;; A repo ships one of four ways, and the kind decides what "done" means:
;;
;;   gitops    ordered deploy stages (Kargo), from the hub's kargo-stages.json
;;   teamcity  ordered environments, from the hub's teamcity-deploys.json
;;   ci        nothing deploys; done once the merge's own build is green
;;   none      nothing deploys or builds; merged is done
;;
;; A ship-progress file written by the /ship workflow, when present, is a
;; stronger signal than either deploy feed and wins over both.
;;
;; Everything is read from memory the hub watcher already parsed, so a
;; status costs alist lookups and a timestamp compare: no I/O, safe on the
;; paint path.  The sidebar memoises statuses per PR object as well.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup decknix-ship nil
  "Deploy stages of merged PRs in the sidebar."
  :group 'tools)

(defcustom decknix-sidebar-shipped-retention 86400
  "Seconds a PR whose last stage is verified stays listed, dimmed, as shipped.
0 drops it the moment it ships.  Set from the sidebar toggles transient."
  :type 'integer
  :group 'decknix-ship)

(defconst decknix-ship-retention-choices
  '(("0" . 0) ("10m" . 600) ("20m" . 1200) ("30m" . 1800)
    ("1h" . 3600) ("2h" . 7200) ("1d" . 86400))
  "Preset values offered for `decknix-sidebar-shipped-retention'.")

(defcustom decknix-ship-repo-kinds nil
  "Alist of (REGEXP . KIND) forcing how a repo ships.
REGEXP matches `owner/repo', case-insensitively; the first match wins.
KIND is one of `gitops', `teamcity', `ci' or `none'.  Without a match the
kind is inferred: deploy data for the repo means `gitops' or `teamcity', a
dependency-bump title means `ci', anything else `none'."
  :type '(alist :key-type regexp
                :value-type (choice (const gitops) (const teamcity)
                                    (const ci) (const none)))
  :group 'decknix-ship)

(defcustom decknix-ship-ci-only-title-regexp
  "\\`\\(?:build(deps\\|chore(deps\\|fix(deps\\|[Bb]ump \\)"
  "Title of a dependency bump, which in a repo with no deploy data is CI-only."
  :type 'regexp
  :group 'decknix-ship)

(defcustom decknix-ship-teamcity-envs
  '("development" "testing" "stable" "production" "uk_production")
  "TeamCity environments in promotion order."
  :type '(repeat string)
  :group 'decknix-ship)

(defcustom decknix-ship-teamcity-final-envs '("production" "uk_production")
  "TeamCity environments that must all contain a merge for it to be shipped.
Only those a repo actually deploys to count."
  :type '(repeat string)
  :group 'decknix-ship)

(defconst decknix-ship-short-names
  '(("development" . "dev") ("testing" . "test") ("stable" . "stg")
    ("production" . "prd") ("uk_production" . "uk-prd"))
  "Compact names for TeamCity environments.")

(defvar decknix-ship-teamcity-deploys-function
  (lambda () (bound-and-true-p decknix--hub-deploys))
  "Return the parsed teamcity-deploys.json alist, or nil.")

(defvar decknix-ship-kargo-function
  (lambda () (bound-and-true-p decknix--hub-kargo-stages))
  "Return the parsed kargo-stages.json alist, or nil.")

(defvar decknix-ship-progress-function #'ignore
  "Function of (REPO NUMBER) returning a /ship progress alist, or nil.")

(defvar decknix-ship-progress-generation 0
  "Bumped whenever the data behind `decknix-ship-progress-function' changes.
Memoised statuses compare it, as they compare the deploy feeds by identity.")

(defvar decknix-ship-ticket-open-function
  (lambda (key)
    (seq-some (lambda (item)
                (and (equal (alist-get 'key item) key)
                     (not (equal (alist-get 'status_category item) "done"))))
              (alist-get 'items (bound-and-true-p decknix--hub-jira-tasks))))
  "Function of a Jira KEY: non-nil when that ticket is known and not Done.")

(defvar decknix--hub-deploys)
(defvar decknix--hub-kargo-stages)
(defvar decknix--hub-jira-tasks)

;; --- small helpers ------------------------------------------------------

(defun decknix-ship--time (iso)
  "Return ISO as a float time, or nil."
  (and (stringp iso) (not (string-empty-p iso))
       (ignore-errors (float-time (date-to-time iso)))))

(defun decknix-ship-merged-p (pr)
  "Return non-nil when hub WIP PR alist PR has merged."
  (or (equal (upcase (or (alist-get 'state pr) "")) "MERGED")
      (and (decknix-ship--time (alist-get 'merged_at pr)) t)))

(defun decknix-ship-short-name (stage)
  "Return the compact display name of STAGE."
  (or (cdr (assoc stage decknix-ship-short-names)) stage))

(defun decknix-ship--repo-match (repo alist)
  "Return the value in ALIST whose regexp key matches REPO."
  (let ((case-fold-search t))
    (cdr (seq-find (lambda (cell) (string-match-p (car cell) (or repo ""))) alist))))

(defun decknix-ship--teamcity-envs (repo deploys)
  "Return REPO's default-branch environments in DEPLOYS, or nil."
  (let* ((entry (seq-find (lambda (r) (string-equal-ignore-case
                                       (or (alist-get 'repo r) "") (or repo "")))
                          (alist-get 'repos deploys)))
         (branch (seq-find (lambda (b) (equal (alist-get 'branch b) "__default__"))
                           (alist-get 'branches entry))))
    (alist-get 'environments branch)))

(defun decknix-ship--kargo-entry (repo number kargo)
  "Return KARGO's entry for REPO#NUMBER, or nil."
  (seq-find (lambda (p) (and (equal (alist-get 'number p) number)
                             (string-equal-ignore-case (or (alist-get 'repo p) "")
                                                       (or repo ""))))
            (alist-get 'prs kargo)))

(defun decknix-ship--kargo-repo-p (repo kargo)
  "Return non-nil when KARGO tracks REPO at all."
  (seq-some (lambda (r) (string-equal-ignore-case r (or repo "")))
            (alist-get 'repos kargo)))

(defun decknix-ship-kind (repo pr &optional deploys kargo)
  "Return how REPO ships PR: `gitops', `teamcity', `ci' or `none'."
  (or (decknix-ship--repo-match repo decknix-ship-repo-kinds)
      (and kargo (decknix-ship--kargo-repo-p repo kargo) 'gitops)
      (and deploys (decknix-ship--teamcity-envs repo deploys) 'teamcity)
      (and (string-match-p decknix-ship-ci-only-title-regexp
                           (or (alist-get 'title pr) ""))
           'ci)
      'none))

;; --- per-kind status -----------------------------------------------------
;;
;; Every status is a plist:
;;
;;   :kind     the kind above
;;   :stages   stage names in promotion order (may be nil)
;;   :current  the last stage containing the merge, or nil
;;   :next     the first later stage not yet containing it, or nil
;;   :state    `pending' (waiting to be promoted), `deploying', `failed'
;;             or `done'
;;   :done-at  float time the last stage was verified, when `done'

(defun decknix-ship--ordered (stages contains running failed)
  "Build a status from STAGES and the predicates CONTAINS, RUNNING, FAILED.
Each predicate takes a stage name."
  (let* ((reached (seq-filter contains stages))
         (current (car (last reached)))
         (after (if current (cdr (member current stages)) stages))
         (next (seq-find (lambda (s) (not (funcall contains s))) after))
         (state (cond ((null next) 'done)
                      ((funcall failed next) 'failed)
                      ((funcall running next) 'deploying)
                      (t 'pending))))
    (list :stages stages :current current :next next :state state)))

(defun decknix-ship-teamcity-status (merged-at envs)
  "Return the status of a merge at MERGED-AT through TeamCity ENVS."
  (let* ((by-name (mapcar (lambda (e) (cons (alist-get 'env e) e)) envs))
         (stages (seq-filter (lambda (n) (assoc n by-name)) decknix-ship-teamcity-envs))
         (finals (seq-filter (lambda (n) (member n decknix-ship-teamcity-final-envs)) stages))
         (after-merge (lambda (e) (let ((f (alist-get 'finished e)))
                                    (and (stringp f) (stringp merged-at)
                                         (not (string< f merged-at))))))
         (contains (lambda (n) (let ((e (cdr (assoc n by-name))))
                                 (and (equal (alist-get 'status e) "SUCCESS")
                                      (funcall after-merge e)))))
         (running (lambda (n) (member (alist-get 'state (cdr (assoc n by-name)))
                                      '("running" "queued"))))
         (failed (lambda (n) (let ((e (cdr (assoc n by-name))))
                               (and (member (alist-get 'status e) '("FAILURE" "ERROR"))
                                    (funcall after-merge e)))))
         (status (decknix-ship--ordered stages contains running failed))
         ;; Done means every final environment, not only the last listed:
         ;; a UK production deploy can trail the AU one.
         (done (and finals (seq-every-p contains finals))))
    (append (list :kind 'teamcity
                  :state (if done 'done
                           (if (eq (plist-get status :state) 'done) 'pending
                             (plist-get status :state)))
                  :done-at (and done
                                (apply #'max (mapcar (lambda (n)
                                                       (or (decknix-ship--time
                                                            (alist-get 'finished
                                                                       (cdr (assoc n by-name))))
                                                           0))
                                                     finals))))
            status)))

(defun decknix-ship-kargo-status (entry)
  "Return the status of a PR from its kargo-stages.json ENTRY.
ENTRY carries `stages' (ordered names), `reached' (names whose current
freight contains the merge, verified), and optionally `failed' and
`promoting' stage names and `verified_at' for the last stage."
  (let* ((stages (alist-get 'stages entry))
         (reached (alist-get 'reached entry))
         (status (decknix-ship--ordered
                  stages
                  (lambda (s) (member s reached))
                  (lambda (s) (member s (alist-get 'promoting entry)))
                  (lambda (s) (member s (alist-get 'failed entry))))))
    (append (list :kind 'gitops
                  :done-at (and (eq (plist-get status :state) 'done)
                                (or (decknix-ship--time (alist-get 'verified_at entry))
                                    (float-time))))
            status)))

(defun decknix-ship-progress-status (progress kind stages)
  "Return the status recorded by /ship in PROGRESS, for a KIND repo.
STAGES, when known, gives the order; PROGRESS names the `stage' reached
and its `status' (`verified', `promoting', `failed', `done')."
  (let* ((stage (alist-get 'stage progress))
         (pstatus (alist-get 'status progress))
         (stages (or stages (and stage (list stage))))
         (pos (and stage (seq-position stages stage)))
         (verified (member pstatus '("verified" "done")))
         (current (cond (verified stage)
                        ((and pos (> pos 0)) (nth (1- pos) stages))))
         (next (cond ((not verified) stage)
                     (pos (nth (1+ pos) stages))))
         (done (or (equal pstatus "done") (and verified (null next)))))
    (list :kind kind :stages stages :current current :next (and (not done) next)
          :state (cond (done 'done)
                       ((equal pstatus "failed") 'failed)
                       ((equal pstatus "promoting") 'deploying)
                       (t 'pending))
          :done-at (and done (or (decknix-ship--time (alist-get 'verified_at progress))
                                 (float-time)))
          :source 'ship)))

(defun decknix-ship-status (repo pr &optional deploys kargo progress)
  "Return the ship status plist of REPO's PR, or nil when PR is not merged.
DEPLOYS, KARGO and PROGRESS default to the in-memory hub data."
  (when (decknix-ship-merged-p pr)
    (let* ((deploys (or deploys (funcall decknix-ship-teamcity-deploys-function)))
           (kargo (or kargo (funcall decknix-ship-kargo-function)))
           (number (alist-get 'number pr))
           (progress (or progress (funcall decknix-ship-progress-function repo number)))
           (kind (decknix-ship-kind repo pr deploys kargo))
           (merged-at (alist-get 'merged_at pr))
           (status
            (pcase kind
              ('teamcity
               (decknix-ship-teamcity-status merged-at
                                             (decknix-ship--teamcity-envs repo deploys)))
              ('gitops
               (let ((entry (decknix-ship--kargo-entry repo number kargo)))
                 (if entry
                     (decknix-ship-kargo-status entry)
                   (list :kind 'gitops :state 'pending :stages nil
                         :current nil :next nil))))
              ('ci
               (let ((ci (alist-get 'status (alist-get 'ci pr))))
                 (list :kind 'ci :stages '("ci")
                       :current (and (equal ci "pass") "ci")
                       :next (and (not (equal ci "pass")) "ci")
                       :state (pcase ci ("pass" 'done) ("fail" 'failed)
                                (_ 'deploying))
                       :done-at (and (equal ci "pass")
                                     (decknix-ship--time merged-at)))))
              (_ (list :kind 'none :state 'done :stages nil :current nil :next nil
                       :done-at (decknix-ship--time merged-at))))))
      ;; /ship's record is the stronger signal: it is what a human (or an
      ;; agent) verified, not what a deploy feed inferred.
      (if progress
          (decknix-ship-progress-status progress kind (plist-get status :stages))
        status))))

;; --- what the sidebar shows ---------------------------------------------

(defun decknix-ship-visibility (status now &optional retention)
  "Return how a merged PR with STATUS shows at NOW.
`shipping' while any stage is outstanding, `shipped' for RETENTION seconds
\(default `decknix-sidebar-shipped-retention') after the last stage was
verified, nil once that has passed.  A done status with no time is
treated as shipped just now, so it is seen at least once."
  (let ((retention (or retention decknix-sidebar-shipped-retention)))
    (if (not (eq (plist-get status :state) 'done))
        'shipping
      (let ((at (or (plist-get status :done-at) now)))
        (and (< (- now at) retention) 'shipped)))))

(defun decknix-ship-label (status)
  "Return the compact stage token for STATUS, propertized.

  ✓prd    shipped (green)        →stg   promoting to stg (amber)
  ✗test   failed at test (red)   ·dev   waiting for dev (amber)
  merged  nothing to deploy (green)"
  (let* ((state (plist-get status :state))
         (next (plist-get status :next))
         (current (plist-get status :current))
         (kind (plist-get status :kind)))
    (pcase state
      ('done (propertize (if (memq kind '(none ci))
                             (if (eq kind 'ci) "✓ci" "merged")
                           (concat "✓" (decknix-ship-short-name (or current "done"))))
                         'face '(:foreground "#87af87")))
      ('failed (propertize (concat "✗" (decknix-ship-short-name (or next "deploy")))
                           'face '(:foreground "#ff5f5f" :weight bold)))
      ('deploying (propertize (concat "→" (decknix-ship-short-name (or next "deploy")))
                              'face '(:foreground "#d7af5f")))
      (_ (propertize (concat "·" (decknix-ship-short-name (or next "deploy")))
                     'face '(:foreground "#d7af5f"))))))

(defun decknix-ship-severity (status)
  "Return the sidebar severity rank of a merged PR with STATUS (low is worse)."
  (pcase (plist-get status :state)
    ('failed 0)
    ('done 4)
    (_ 2)))

(defun decknix-ship-ticket-key (pr)
  "Return the Jira key named in PR's title or branch, or nil."
  (let ((case-fold-search nil))
    (seq-some (lambda (s)
                (and (stringp s)
                     (string-match "\\b\\([A-Z][A-Z0-9]+-[0-9]+\\)\\b" s)
                     (match-string 1 s)))
              (list (alist-get 'title pr)
                    (and (alist-get 'branch pr) (upcase (alist-get 'branch pr)))))))

(defun decknix-ship-lines (status &optional key)
  "Return (:current TEXT :next TEXT :state STATE) for STATUS.
KEY is a linked Jira key: once the last stage is done the next step is
closing it, when `decknix-ship-ticket-open-function' says it is open."
  (let* ((state (plist-get status :state))
         (current (plist-get status :current))
         (next (plist-get status :next))
         (after-next (cadr (member next (plist-get status :stages))))
         (close (and key (funcall decknix-ship-ticket-open-function key)
                     (concat "close " key))))
    (list :state state
          :current (pcase state
                     ('done (if current (concat "shipped to " current) "merged"))
                     ('failed (concat "failed in " (or next "deploy")))
                     ('deploying (concat "deploying " (or next "")))
                     (_ (if current (concat "in " current) "merged, not deployed")))
          :next (pcase state
                  ('done close)
                  ('failed (concat "fix and redeploy " (or next "")))
                  ('deploying (if after-next (concat "promote " after-next) close))
                  (_ (if next (concat "promote " next) close))))))

;; --- retention setting ---------------------------------------------------

(defun decknix-ship-parse-duration (text)
  "Return TEXT (\"45\", \"10m\", \"2h\", \"1d\", \"90s\") as seconds, or nil."
  (when (and (stringp text)
             (string-match "\\`[[:space:]]*\\([0-9]+\\)[[:space:]]*\\([smhd]?\\)[[:space:]]*\\'"
                           text))
    (* (string-to-number (match-string 1 text))
       (pcase (match-string 2 text)
         ("" 60) ("s" 1) ("m" 60) ("h" 3600) ("d" 86400)))))

(defun decknix-ship-retention-label (seconds)
  "Return SECONDS as the shortest of 0, Ns, Nm, Nh or Nd."
  (cond ((or (null seconds) (<= seconds 0)) "0")
        ((zerop (% seconds 86400)) (format "%dd" (/ seconds 86400)))
        ((zerop (% seconds 3600)) (format "%dh" (/ seconds 3600)))
        ((zerop (% seconds 60)) (format "%dm" (/ seconds 60)))
        (t (format "%ds" seconds))))

(defvar decknix-ship-retention-changed-hook nil
  "Run after `decknix-sidebar-shipped-retention' is set interactively.")

(defun decknix-ship-set-retention (seconds)
  "Set how long a shipped PR stays listed to SECONDS.
Interactively, choose a preset or `custom' to type a duration (10m, 2h, 3d)."
  (interactive
   (let* ((names (append (mapcar #'car decknix-ship-retention-choices) '("custom")))
          (pick (completing-read
                 (format "Keep shipped PRs for (now %s): "
                         (decknix-ship-retention-label decknix-sidebar-shipped-retention))
                 names nil t)))
     (list (if (equal pick "custom")
               (or (decknix-ship-parse-duration
                    (read-string "Duration (e.g. 45m, 3h, 2d): "))
                   (user-error "Not a duration"))
             (cdr (assoc pick decknix-ship-retention-choices))))))
  (setq decknix-sidebar-shipped-retention seconds)
  (run-hooks 'decknix-ship-retention-changed-hook)
  (message "Shipped PRs kept for %s" (decknix-ship-retention-label seconds)))

(provide 'decknix-ship)
;;; decknix-ship.el ends here
