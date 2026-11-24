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
;; A feed that could not be read is never taken to mean "not deployed".
;; The hub marks such data `stale': carried from its last good poll, dated
;; by `as_of', or never read at all.  A carried status keeps its state with
;; `:stale' naming the feed and `:as-of' its age, and its badge gains a grey
;; `?': a stage last seen failed or waiting for you still wants you, and
;; hiding it behind "stage unknown" while a login was expired lost exactly
;; the stages that mattered.  Only data never read is `unknown', shown dim
;; as "stage unknown (Kargo unavailable)".  A stale status that had already
;; shipped stays shipped: a stage does not un-deploy a merge because its
;; feed went quiet.
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

(defun decknix-ship--teamcity-entry (repo deploys)
  "Return REPO's entry in DEPLOYS, or nil."
  (seq-find (lambda (r) (string-equal-ignore-case (or (alist-get 'repo r) "") (or repo "")))
            (alist-get 'repos deploys)))

(defun decknix-ship--teamcity-envs (repo deploys)
  "Return REPO's default-branch environments in DEPLOYS, or nil."
  (let ((branch (seq-find (lambda (b) (equal (alist-get 'branch b) "__default__"))
                          (alist-get 'branches (decknix-ship--teamcity-entry repo deploys)))))
    (alist-get 'environments branch)))

(defun decknix-ship--feed-stale-p (repo feed)
  "Return non-nil when FEED (a parsed hub file) lists REPO as unreadable."
  (seq-some (lambda (s) (string-equal-ignore-case (or (alist-get 'repo s) "") (or repo "")))
            (alist-get 'stale feed)))

(defun decknix-ship--teamcity-stale-p (repo deploys)
  "Return non-nil when DEPLOYS' data for REPO is not from the latest poll."
  (or (eq (alist-get 'stale (decknix-ship--teamcity-entry repo deploys)) t)
      (decknix-ship--feed-stale-p repo deploys)))

(defun decknix-ship--stale (status source as-of)
  "Return STATUS from a feed SOURCE could not read this poll.
AS-OF is when its data was last read, or nil when it never was: then
STATUS is `unknown' unless done.  Otherwise it keeps its state, marked."
  (cond ((eq (plist-get status :state) 'done) status)
        (as-of (append (list :stale source :as-of as-of) status))
        (t (append (list :state 'unknown :unknown-source source) status))))

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
;;   :state    `pending'    waiting for :next, which follows by itself
;;             `ready'      waiting for a person to promote :next
;;             `deploying'  a promotion into :next is running
;;             `verifying'  :next holds the merge, its verification pending
;;             `failed'     :next failed to promote or verify
;;             `unknown'    the deploy feed has never been read (stale)
;;             `done'       every stage holds the merge
;;   :manual   stages a person promotes, or t when that is unknown
;;   :done-at  float time the last stage was verified, when `done'
;;   :stale    the feed ("Kargo") this poll could not read; the state is
;;             what it last read, at :as-of (float time)

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
         (merged (decknix-ship--time merged-at))
         ;; As times, not strings: a string compare holds only while both
         ;; sides happen to be UTC with the same precision.
         (after-merge (lambda (e) (let ((f (decknix-ship--time (alist-get 'finished e))))
                                    (and f merged (>= f merged)))))
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
ENTRY carries `stages' (ordered names), `reached' (names whose freight
holds the merge, verified), and optionally `promoting', `verifying',
`failed' and `manual' stage names and `verified_at' for the last stage.

A next stage only waiting is `ready' when a person promotes it and
`pending' when it follows by itself.  Without `manual' that is unknown,
which `:manual' t records so the lines can say so."
  (let* ((stages (alist-get 'stages entry))
         (reached (alist-get 'reached entry))
         (manual (if (assq 'manual entry) (alist-get 'manual entry) t))
         (status (decknix-ship--ordered
                  stages
                  (lambda (s) (member s reached))
                  (lambda (s) (member s (alist-get 'promoting entry)))
                  (lambda (s) (member s (alist-get 'failed entry)))))
         (next (plist-get status :next)))
    (when (eq (plist-get status :state) 'pending)
      (plist-put status :state
                 (cond ((member next (alist-get 'verifying entry)) 'verifying)
                       ((and (listp manual) (member next manual)) 'ready)
                       (t 'pending))))
    ;; The hub found nothing in the merge that the repo deploys, so no
    ;; freight will ever hold it; it dates such an entry by the merge.
    (when (and (alist-get 'no_deploy entry) (not (eq (plist-get status :state) 'done)))
      (setq status (append (list :state 'done :no-deploy (alist-get 'no_deploy entry)
                                 :next nil)
                           status)))
    (let ((out (append (list :kind 'gitops
                             :region (alist-get 'region entry)
                             :manual manual
                             :done-at (and (eq (plist-get status :state) 'done)
                                           (or (decknix-ship--time (alist-get 'verified_at entry))
                                               (float-time))))
                       status)))
      (if (eq (alist-get 'stale entry) t)
          (decknix-ship--stale out "Kargo" (decknix-ship--time (alist-get 'as_of entry)))
        out))))

(defun decknix-ship--kargo-missing (repo stages kargo)
  "Return the status of a merge KARGO has no entry for in REPO.
Pending while the feed reads REPO fine; unknown when it cannot."
  (let ((status (list :kind 'gitops :state 'pending :stages stages
                      :current nil :next (car stages))))
    (if (decknix-ship--feed-stale-p repo kargo)
        (decknix-ship--stale status "Kargo" nil)
      status)))

(defun decknix-ship--teamcity-checked (status repo deploys)
  "Return TeamCity STATUS for REPO, marked stale when DEPLOYS could not read it."
  (if (decknix-ship--teamcity-stale-p repo deploys)
      (decknix-ship--stale status "TeamCity"
                           (decknix-ship--time
                            (alist-get 'as_of (decknix-ship--teamcity-entry repo deploys))))
    status))

(defun decknix-ship--stage-region (stage)
  "Return the region prefix of STAGE (`uk' of `uk-stg'), or nil."
  (and (stringp stage) (string-match "\\`\\([a-z]\\{2,3\\}\\)-" stage)
       (match-string 1 stage)))

(defun decknix-ship-split-regions (entry)
  "Return ENTRY as one Kargo entry per region its stage names carry.
A repo configured once with every region's stages interleaved
\(`uk-dev us-dev uk-stg ...') is several independent deploy paths, and
read as one pipeline its `current' and `next' came from different regions:
`in us-dev' beside `promote uk-stg', under a badge with no region.  An
entry with a region, or whose stages name fewer than two, is returned
whole, in a list."
  (let ((regions (delete-dups (delq nil (mapcar #'decknix-ship--stage-region
                                                (alist-get 'stages entry))))))
    (if (or (alist-get 'region entry) (< (length regions) 2))
        (list entry)
      (mapcar
       (lambda (region)
         (let ((mine (lambda (names)
                       (seq-filter (lambda (s) (equal region (decknix-ship--stage-region s)))
                                   names))))
           (append
            (list (cons 'region (upcase region)))
            (mapcar (lambda (cell)
                      (if (memq (car cell) '(stages reached promoting verifying failed manual))
                          (cons (car cell) (funcall mine (cdr cell)))
                        cell))
                    entry))))
       regions))))

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
        (decknix-ship--teamcity-checked
         (decknix-ship-teamcity-status (alist-get 'merged_at pr)
                                       (decknix-ship--teamcity-envs repo deploys)
                                       stages (and stages (last stages)))
         repo deploys))
       ('gitops
        (let ((entry (decknix-ship--kargo-entry repo (alist-get 'number pr) kargo region)))
          (if entry
              (decknix-ship-kargo-status entry)
            (decknix-ship--kargo-missing repo stages kargo))))
       (_ (list :kind 'none :state 'done :stages nil :current nil :next nil
                :done-at (decknix-ship--time (alist-get 'merged_at pr)))))
     region)))

(defun decknix-ship--kind-statuses (kind repo pr deploys kargo)
  "Return the statuses of REPO's PR for a repo that ships as KIND.
One per regional Kargo entry for `gitops', else a single status."
  (let ((merged-at (alist-get 'merged_at pr)))
    (pcase kind
      ('teamcity
       (list (decknix-ship--teamcity-checked
              (decknix-ship-teamcity-status merged-at (decknix-ship--teamcity-envs repo deploys))
              repo deploys)))
      ('gitops
       (or (mapcar #'decknix-ship-kargo-status
                   (mapcan #'decknix-ship-split-regions
                           (decknix-ship--kargo-entries repo (alist-get 'number pr) kargo)))
           (list (decknix-ship--kargo-missing repo nil kargo))))
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
  "Return how far behind STATUS is: -1 failed, else the share of stages done.
An unknown status ranks just ahead of done, so a shipper whose feed is
unreadable never stands in front of one that is known to want something."
  (let ((stages (plist-get status :stages))
        (current (plist-get status :current)))
    (pcase (plist-get status :state)
      ('failed -1.0)
      ('done 1.0)
      ('unknown 0.999)
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

;; Glyph per state for the stage token.  `ready' has its own, because it is
;; the one state asking something of the reader.
(defconst decknix-ship-state-tokens
  '((done      . ("✓" . (:foreground "#87af87")))
    (failed    . ("✗" . (:foreground "#ff5f5f" :weight bold)))
    (ready     . ("⇢" . (:foreground "#ffaf5f" :weight bold)))
    (deploying . ("→" . default))
    (verifying . ("→" . default))
    (pending   . ("·" . default))
    (unknown   . ("?" . shadow)))
  "Glyph and face per ship state: red failed, amber waiting on you,
green done, grey unknown, plain moving on its own.")

(defun decknix-ship--token (status)
  "Return STATUS's stage token, prefixed by its region, propertized."
  (let* ((state (plist-get status :state))
         (kind (plist-get status :kind))
         (region (plist-get status :region))
         (cell (or (alist-get state decknix-ship-state-tokens)
                   (alist-get 'pending decknix-ship-state-tokens)))
         (stage (if (eq state 'done) (plist-get status :current) (plist-get status :next)))
         (text (cond ((and (eq state 'done) (eq kind 'ci)) "✓ci")
                     ((and (eq state 'done) (eq kind 'none)) "merged")
                     ((and (eq state 'done) (plist-get status :no-deploy)) "✓none")
                     ((eq state 'unknown) "?")
                     (t (concat (car cell)
                                (if stage (decknix-ship--display stage region)
                                  (if (eq state 'done) "done" "deploy")))))))
    (concat (propertize (concat region text) 'face (cdr cell))
            (if (plist-get status :stale) (propertize "?" 'face 'shadow) ""))))

(defun decknix-ship-stale (status)
  "Return (SOURCE . AS-OF) when STATUS shows data a feed could not refresh.
With several shippers, the oldest.  Nil when every shipper is current."
  (let ((stale (seq-filter (lambda (s) (plist-get s :stale))
                           (or (plist-get status :shippers) (list status)))))
    (when stale
      (let ((oldest (car (sort (copy-sequence stale)
                               (lambda (a b) (< (plist-get a :as-of) (plist-get b :as-of)))))))
        (cons (plist-get oldest :stale) (plist-get oldest :as-of))))))

(defun decknix-ship-label (status)
  "Return the compact stage token for STATUS, propertized.

  ✓prd    shipped (green)          →stg   deploying or verifying stg (plain)
  ✗test   failed at test (red)     ·dev   waiting for dev to follow (plain)
  ⇢prd    ready for you to promote merged  nothing to deploy (green)
  ?       stage unknown: the deploy feed has never been read (grey)
  ✗stg?   as last read, but the feed is stale now (grey ?)
  ✓none   no deploy needed: the merge changes no runtime file (green)

A PR with several shippers shows the furthest-behind one and how many
others are done: `US→prd +2✓'.  Every shipper's token is in
`decknix-ship-label-full', for help text: listing them all in the row
pushed the title out of a 48-column sidebar."
  (if (eq (plist-get status :kind) 'multi)
      (let* ((shippers (plist-get status :shippers))
             (done (seq-count (lambda (s) (eq (plist-get s :state) 'done)) (cdr shippers))))
        (concat (decknix-ship--token (car shippers))
                (if (> done 0)
                    (propertize (format " +%d✓" done) 'face '(:foreground "#87af87"))
                  "")))
    (decknix-ship--token status)))

(defun decknix-ship-label-full (status)
  "Return every shipper's token for STATUS, furthest behind first."
  (if (eq (plist-get status :kind) 'multi)
      (mapconcat #'decknix-ship--token (plist-get status :shippers) " ")
    (decknix-ship--token status)))

(defun decknix-ship-severity (status)
  "Return the sidebar severity rank of a merged PR with STATUS (low is worse).
`ready' ranks as wanting the reader: nothing moves until someone promotes."
  (pcase (plist-get status :state)
    ('failed 0)
    ('ready 1)
    ((or 'done 'unknown) 4)
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

(defun decknix-ship--verb (status stage)
  "Return the verb for what a person does to move STATUS into STAGE, or nil.
TeamCity deploys an environment; Kargo promotes a stage, and a stage
known to promote by itself needs nobody, so it has none."
  (let ((manual (plist-get status :manual)))
    (cond ((null stage) nil)
          ((eq (plist-get status :kind) 'teamcity) "deploy")
          ((and (eq (plist-get status :kind) 'gitops) (listp manual)
                (not (member stage manual)))
           nil)
          (t "promote"))))

(defun decknix-ship--lines-1 (status close)
  "Return (:current TEXT :next TEXT) for one shipper's STATUS.
CLOSE is the step after the last stage, or nil.  A regional status names
its region first and its stages without the region they repeat."
  (let* ((region (plist-get status :region))
         (name (lambda (s) (if (and s region) (decknix-ship--display s region) s)))
         (state (plist-get status :state))
         (raw-next (plist-get status :next))
         (raw-after (cadr (member raw-next (plist-get status :stages))))
         (current (funcall name (plist-get status :current)))
         (next (funcall name raw-next))
         (action (lambda (raw) (let ((verb (decknix-ship--verb status raw)))
                                 (and verb (concat verb " " (funcall name raw))))))
         (tag (lambda (text) (and text (if region (concat region ": " text) text)))))
    (list :current (funcall tag
                            (pcase state
                              ('done (cond ((plist-get status :no-deploy) "no deploy needed")
                                           (current (concat "shipped to " current))
                                           (t "merged")))
                              ('failed (concat "failed in " (or next "deploy")))
                              ('deploying (concat "deploying " (or next "")))
                              ('verifying (concat "verifying " (or next "")))
                              ('ready (concat "ready to promote " (or next "")))
                              ('unknown (format "stage unknown (%s unavailable)"
                                                (or (plist-get status :unknown-source) "deploy feed")))
                              (_ (cond ((null current) "merged, not deployed")
                                       ((and (eq (plist-get status :kind) 'gitops)
                                             (listp (plist-get status :manual)))
                                        (concat "in " current ", " next " follows"))
                                       (t (concat "in " current))))))
          ;; `ready to promote prd' already says what to do, as does its ⇢
          ;; badge; `next: promote prd' beneath it said it a third time.
          :next (pcase state
                  ('done close)
                  ((or 'unknown 'ready) nil)
                  ('failed (funcall tag (concat "fix and redeploy " (or next ""))))
                  ((or 'deploying 'verifying) (funcall tag (funcall action raw-after)))
                  (_ (funcall tag (funcall action raw-next)))))))

(defun decknix-ship-lines (status &optional key)
  "Return (:state STATE :current TEXT :next TEXT :restates BOOL) for STATUS.
KEY is a linked Jira key: once the last stage is done the next step is
closing it, when `decknix-ship-ticket-open-function' says it is open.

With several shippers the furthest-behind one speaks for both lines, as
it does for the badge: the next line had fallen back to another shipper,
so a row could read `in us-dev' over `promote uk-stg'.

:restates is non-nil when the current line says no more than the badge,
so the sidebar can leave it out; only `verifying' adds something, since
its badge is the same arrow as a running promotion."
  (let* ((state (plist-get status :state))
         (close (and key (funcall decknix-ship-ticket-open-function key)
                     (concat "close " key)))
         (shippers (plist-get status :shippers))
         (lines (cond
                 ((null shippers) (decknix-ship--lines-1 status close))
                 ((eq state 'done)
                  (list :current (concat "shipped to "
                                         (mapconcat (lambda (s) (or (plist-get s :region) "?"))
                                                    shippers ", "))
                        :next close))
                 (t (decknix-ship--lines-1 (car shippers) nil)))))
    (append (list :state state) lines
            (list :restates (not (eq (plist-get (or (car shippers) status) :state)
                                     'verifying))))))

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
