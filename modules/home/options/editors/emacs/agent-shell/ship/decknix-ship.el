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
;; A repo can also ship several ways at once, each a "shipper" with its
;; own ordered stages and a region label: TeamCity environments for one
;; region, Kargo stages for another (`decknix-ship-repo-shippers', or one
;; regional entry per shipper in kargo-stages.json).  Such a PR is shipped
;; only when every shipper's last stage is verified; the furthest-behind
;; shipper leads its label and its current and next lines.
;;
;; A ship-progress file written by the /ship workflow, when present, is a
;; stronger signal than either deploy feed and wins over both.  With
;; several shippers it updates the one whose stages name its stage.
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

(defcustom decknix-ship-repo-shippers nil
  "Alist of (REGEXP . SHIPPERS) for repos that ship more than one way.
REGEXP matches `owner/repo', case-insensitively; the first match wins
over `decknix-ship-repo-kinds'.  SHIPPERS is a list of plists, one per
independent deploy path:

  (:kind teamcity :region \"AU\" :stages (\"development\" \"production\"))
  (:kind gitops :region \"US\")

A `teamcity' shipper follows only its :stages, in that order, and is done
once the last of them holds the merge.  A `gitops' shipper reads the
kargo-stages.json entry whose `region' matches its :region (configure the
repo once per region in the hub); its :stages are shown until that entry
exists.  :region labels the shipper in the sidebar.  The PR is shipped
only when every shipper is done."
  :type '(alist :key-type regexp :value-type (repeat plist))
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

(defvar decknix-ship--time-cache (make-hash-table :test 'equal)
  "ISO timestamp -> float time.  Parsing dominated a status rebuild once a
PR had a shipper per region, and the feeds repeat the same few stamps.")

(defun decknix-ship--time (iso)
  "Return ISO as a float time, or nil."
  (and (stringp iso) (not (string-empty-p iso))
       (let ((hit (gethash iso decknix-ship--time-cache 'miss)))
         (if (not (eq hit 'miss))
             hit
           (when (> (hash-table-count decknix-ship--time-cache) 2000)
             (clrhash decknix-ship--time-cache))
           (puthash iso (ignore-errors (float-time (date-to-time iso)))
                    decknix-ship--time-cache)))))

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

(defun decknix-ship--kargo-entries (repo number kargo)
  "Return KARGO's entries for REPO#NUMBER, one per region it ships to."
  (seq-filter (lambda (p) (and (equal (alist-get 'number p) number)
                               (string-equal-ignore-case (or (alist-get 'repo p) "")
                                                         (or repo ""))))
              (alist-get 'prs kargo)))

(defun decknix-ship--kargo-entry (repo number kargo &optional region)
  "Return KARGO's entry for REPO#NUMBER in REGION (any region when nil)."
  (seq-find (lambda (p) (or (null region)
                            (string-equal-ignore-case (or (alist-get 'region p) "") region)))
            (decknix-ship--kargo-entries repo number kargo)))

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

(defun decknix-ship-teamcity-status (merged-at envs &optional order finals)
  "Return the status of a merge at MERGED-AT through TeamCity ENVS.
ORDER lists the environments to follow (default `decknix-ship-teamcity-envs')
and FINALS those that must all hold the merge; by default the final
environments the repo deploys to."
  (let* ((by-name (mapcar (lambda (e) (cons (alist-get 'env e) e)) envs))
         (stages (seq-filter (lambda (n) (assoc n by-name))
                             (or order decknix-ship-teamcity-envs)))
         (finals (or finals
                     (seq-filter (lambda (n) (member n decknix-ship-teamcity-final-envs))
                                 stages)))
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
                  :region (alist-get 'region entry)
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

(defun decknix-ship--regioned (status region)
  "Return STATUS labelled with REGION, when there is one."
  (if region (append (list :region region) status) status))

(defun decknix-ship--shipper-status (shipper repo pr deploys kargo)
  "Return the status of REPO's PR through SHIPPER, a plist of
`decknix-ship-repo-shippers'."
  (let ((region (plist-get shipper :region))
        (stages (plist-get shipper :stages)))
    (decknix-ship--regioned
     (pcase (plist-get shipper :kind)
       ('teamcity
        (decknix-ship-teamcity-status (alist-get 'merged_at pr)
                                      (decknix-ship--teamcity-envs repo deploys)
                                      stages (and stages (last stages))))
       ('gitops
        (let ((entry (decknix-ship--kargo-entry repo (alist-get 'number pr) kargo region)))
          (if entry
              (decknix-ship-kargo-status entry)
            (list :kind 'gitops :state 'pending :stages stages
                  :current nil :next (car stages)))))
       (_ (list :kind 'none :state 'done :stages nil :current nil :next nil
                :done-at (decknix-ship--time (alist-get 'merged_at pr)))))
     region)))

(defun decknix-ship--kind-statuses (kind repo pr deploys kargo)
  "Return the statuses of REPO's PR for a repo that ships as KIND.
One per regional Kargo entry for `gitops', else a single status."
  (let ((merged-at (alist-get 'merged_at pr)))
    (pcase kind
      ('teamcity
       (list (decknix-ship-teamcity-status merged-at
                                           (decknix-ship--teamcity-envs repo deploys))))
      ('gitops
       (or (mapcar #'decknix-ship-kargo-status
                   (decknix-ship--kargo-entries repo (alist-get 'number pr) kargo))
           (list (list :kind 'gitops :state 'pending :stages nil :current nil :next nil))))
      ('ci
       (let ((ci (alist-get 'status (alist-get 'ci pr))))
         (list (list :kind 'ci :stages '("ci")
                     :current (and (equal ci "pass") "ci")
                     :next (and (not (equal ci "pass")) "ci")
                     :state (pcase ci ("pass" 'done) ("fail" 'failed) (_ 'deploying))
                     :done-at (and (equal ci "pass") (decknix-ship--time merged-at))))))
      (_ (list (list :kind 'none :state 'done :stages nil :current nil :next nil
                     :done-at (decknix-ship--time merged-at)))))))

(defun decknix-ship--apply-progress (statuses progress)
  "Return STATUSES with the /ship record PROGRESS applied.
It replaces a lone status outright, as before shippers existed; among
several it replaces the one whose stages name its stage, if any."
  (cond
   ((null progress) statuses)
   ((null (cdr statuses))
    (let ((s (car statuses)))
      (list (decknix-ship--regioned
             (decknix-ship-progress-status progress (plist-get s :kind) (plist-get s :stages))
             (plist-get s :region)))))
   (t (let ((stage (alist-get 'stage progress)) hit)
        (mapcar (lambda (s)
                  (if (or hit (not (member stage (plist-get s :stages))))
                      s
                    (setq hit t)
                    (decknix-ship--regioned
                     (decknix-ship-progress-status progress (plist-get s :kind)
                                                   (plist-get s :stages))
                     (plist-get s :region))))
                statuses)))))

(defun decknix-ship--behind-rank (status)
  "Return how far behind STATUS is: -1 failed, else the share of stages done."
  (let ((stages (plist-get status :stages))
        (current (plist-get status :current)))
    (pcase (plist-get status :state)
      ('failed -1.0)
      ('done 1.0)
      (_ (if (and stages current (member current stages))
             (/ (float (1+ (seq-position stages current))) (1+ (length stages)))
           0.0)))))

(defun decknix-ship-combine (statuses)
  "Return one status for a PR shipping through every one of STATUSES.
A single status is returned as is.  Several make a `multi' status whose
`:shippers' are ordered furthest-behind first (failed, then least of
their stages done); the leader supplies `:current', `:next' and `:stages',
and the PR is `done' only when every shipper is."
  (if (null (cdr statuses))
      (car statuses)
    (let* ((ordered (sort (copy-sequence statuses)
                          (lambda (a b) (< (decknix-ship--behind-rank a)
                                           (decknix-ship--behind-rank b)))))
           (lead (car ordered))
           (done (seq-every-p (lambda (s) (eq (plist-get s :state) 'done)) statuses))
           (done-at (and done (apply #'max (mapcar (lambda (s) (or (plist-get s :done-at) 0))
                                                   statuses)))))
      (list :kind 'multi :shippers ordered
            :region (plist-get lead :region)
            :stages (plist-get lead :stages)
            :current (plist-get lead :current)
            :next (plist-get lead :next)
            :state (if done 'done (plist-get lead :state))
            :done-at (and done-at (> done-at 0) done-at)
            :source (plist-get lead :source)))))

(defun decknix-ship-status (repo pr &optional deploys kargo progress)
  "Return the ship status plist of REPO's PR, or nil when PR is not merged.
DEPLOYS, KARGO and PROGRESS default to the in-memory hub data."
  (when (decknix-ship-merged-p pr)
    (let* ((deploys (or deploys (funcall decknix-ship-teamcity-deploys-function)))
           (kargo (or kargo (funcall decknix-ship-kargo-function)))
           (progress (or progress (funcall decknix-ship-progress-function
                                           repo (alist-get 'number pr))))
           (shippers (decknix-ship--repo-match repo decknix-ship-repo-shippers))
           (statuses (if shippers
                         (mapcar (lambda (sh)
                                   (decknix-ship--shipper-status sh repo pr deploys kargo))
                                 shippers)
                       (decknix-ship--kind-statuses (decknix-ship-kind repo pr deploys kargo)
                                                    repo pr deploys kargo))))
      ;; /ship's record is the stronger signal: it is what a human (or an
      ;; agent) verified, not what a deploy feed inferred.
      (decknix-ship-combine (decknix-ship--apply-progress statuses progress)))))

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

(defun decknix-ship--display (stage region)
  "Return STAGE's compact name, without a leading REGION it repeats."
  (let ((name (decknix-ship-short-name stage))
        (case-fold-search t))
    (if (and region (stringp name)
             (string-match (concat "\\`" (regexp-quote region) "[-_]") name))
        (substring name (match-end 0))
      name)))

(defun decknix-ship--token (status)
  "Return STATUS's stage token, prefixed by its region, propertized."
  (let* ((state (plist-get status :state))
         (kind (plist-get status :kind))
         (region (plist-get status :region))
         (name (lambda (s fallback) (if s (decknix-ship--display s region) fallback))))
    (pcase-let ((`(,text . ,face)
                 (pcase state
                   ('done (cons (if (memq kind '(none ci))
                                    (if (eq kind 'ci) "✓ci" "merged")
                                  (concat "✓" (funcall name (plist-get status :current) "done")))
                                '(:foreground "#87af87")))
                   ('failed (cons (concat "✗" (funcall name (plist-get status :next) "deploy"))
                                  '(:foreground "#ff5f5f" :weight bold)))
                   ('deploying (cons (concat "→" (funcall name (plist-get status :next) "deploy"))
                                     '(:foreground "#d7af5f")))
                   (_ (cons (concat "·" (funcall name (plist-get status :next) "deploy"))
                            '(:foreground "#d7af5f"))))))
      (propertize (concat region text) 'face face))))

(defun decknix-ship-label (status)
  "Return the compact stage token for STATUS, propertized.

  ✓prd    shipped (green)        →stg   promoting to stg (amber)
  ✗test   failed at test (red)   ·dev   waiting for dev (amber)
  merged  nothing to deploy (green)

A PR with several shippers shows one region-prefixed token per shipper,
furthest behind first: `US→stg AU✓prd UK✓prd'."
  (if (eq (plist-get status :kind) 'multi)
      (mapconcat #'decknix-ship--token (plist-get status :shippers) " ")
    (decknix-ship--token status)))

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

(defun decknix-ship--lines-1 (status close)
  "Return (:current TEXT :next TEXT) for one shipper's STATUS.
CLOSE is the step after the last stage, or nil.  A regional status names
its region first and its stages without the region they repeat."
  (let* ((region (plist-get status :region))
         (name (lambda (s) (if (and s region) (decknix-ship--display s region) s)))
         (state (plist-get status :state))
         (current (funcall name (plist-get status :current)))
         (next (funcall name (plist-get status :next)))
         (after-next (funcall name (cadr (member (plist-get status :next)
                                                 (plist-get status :stages)))))
         (tag (lambda (text) (and text (if region (concat region ": " text) text)))))
    (list :current (funcall tag
                            (pcase state
                              ('done (if current (concat "shipped to " current) "merged"))
                              ('failed (concat "failed in " (or next "deploy")))
                              ('deploying (concat "deploying " (or next "")))
                              (_ (if current (concat "in " current) "merged, not deployed"))))
          :next (pcase state
                  ('done close)
                  ('failed (funcall tag (concat "fix and redeploy " (or next ""))))
                  ('deploying (if after-next (funcall tag (concat "promote " after-next)) close))
                  (_ (if next (funcall tag (concat "promote " next)) close))))))

(defun decknix-ship-lines (status &optional key)
  "Return (:current TEXT :next TEXT :state STATE) for STATUS.
KEY is a linked Jira key: once the last stage is done the next step is
closing it, when `decknix-ship-ticket-open-function' says it is open.
With several shippers the furthest-behind one speaks; when it has nothing
left to promote, the next one still shipping supplies the next step."
  (let* ((state (plist-get status :state))
         (close (and key (funcall decknix-ship-ticket-open-function key)
                     (concat "close " key)))
         (shippers (plist-get status :shippers)))
    (cons :state
          (cons state
                (cond
                 ((null shippers) (decknix-ship--lines-1 status close))
                 ((eq state 'done)
                  (list :current (concat "shipped to "
                                         (mapconcat (lambda (s) (or (plist-get s :region) "?"))
                                                    shippers ", "))
                        :next close))
                 (t
                  (let* ((lead (decknix-ship--lines-1 (car shippers) nil))
                         (other (seq-find (lambda (s) (not (eq (plist-get s :state) 'done)))
                                          (cdr shippers))))
                    (list :current (plist-get lead :current)
                          :next (or (plist-get lead :next)
                                    (and other
                                         (let ((o (decknix-ship--lines-1 other nil)))
                                           (or (plist-get o :next) (plist-get o :current))))
                                    close)))))))))

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
