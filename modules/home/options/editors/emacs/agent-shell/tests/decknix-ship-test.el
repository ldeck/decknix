;;; decknix-ship-test.el --- Tests for the merged-PR stage model -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The sidebar keeps a merged PR under its session until its last stage is
;; verified, shows it as shipped for a retention window, then drops it.
;; These pin what "last stage verified" means for each kind of repo.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-ship)

(defconst decknix-ship-test--merged "2026-11-19T01:00:00Z")

(defun decknix-ship-test--pr (&rest kv)
  "A merged WIP PR alist with KV overrides."
  (append (cl-loop for (k v) on kv by #'cddr collect (cons k v))
          `((number . 7) (title . "HX-1610 add a thing") (state . "MERGED")
            (branch . "hx-1610-thing") (merged_at . ,decknix-ship-test--merged))))

(defun decknix-ship-test--env (env status &optional finished state)
  `((env . ,env) (status . ,status) (finished . ,finished) (state . ,(or state "finished"))))

(defun decknix-ship-test--deploys (&rest envs)
  `((repos . (((repo . "o/mono")
               (branches . (((branch . "__default__") (environments . ,envs)))))))))

(ert-deftest decknix-ship--an-open-pr-has-no-status ()
  (should-not (decknix-ship-status "o/x" '((number . 1) (state . "OPEN")) '(()) '(())))
  (should (decknix-ship-merged-p '((state . "merged")))))

(ert-deftest decknix-ship--teamcity-in-flight-names-current-and-next ()
  (let* ((deploys (decknix-ship-test--deploys
                   (decknix-ship-test--env "development" "SUCCESS" "2026-11-19T01:10:00Z")
                   (decknix-ship-test--env "testing" "SUCCESS" "2026-11-18T01:10:00Z" "running")
                   (decknix-ship-test--env "production" "SUCCESS" "2026-11-17T00:00:00Z")))
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr) deploys '(()))))
    (should (eq (plist-get s :kind) 'teamcity))
    (should (equal (plist-get s :current) "development"))
    (should (equal (plist-get s :next) "testing"))
    (should (eq (plist-get s :state) 'deploying))))

(ert-deftest decknix-ship--teamcity-a-deploy-before-the-merge-does-not-count ()
  (let* ((deploys (decknix-ship-test--deploys
                   (decknix-ship-test--env "development" "SUCCESS" "2026-11-18T00:00:00Z")))
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr) deploys '(()))))
    (should-not (plist-get s :current))
    (should (eq (plist-get s :state) 'pending))))

(ert-deftest decknix-ship--teamcity-done-needs-every-final-environment ()
  (let* ((envs (list (decknix-ship-test--env "development" "SUCCESS" "2026-11-19T01:10:00Z")
                     (decknix-ship-test--env "production" "SUCCESS" "2026-11-19T02:00:00Z")
                     (decknix-ship-test--env "uk_production" "SUCCESS" "2026-11-18T00:00:00Z")))
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr)
                                 (apply #'decknix-ship-test--deploys envs) '(()))))
    (should-not (eq (plist-get s :state) 'done))
    (setf (alist-get 'finished (nth 2 envs)) "2026-11-19T03:00:00Z")
    (let ((s (decknix-ship-status "o/mono" (decknix-ship-test--pr)
                                  (apply #'decknix-ship-test--deploys envs) '(()))))
      (should (eq (plist-get s :state) 'done))
      (should (= (plist-get s :done-at)
                 (float-time (date-to-time "2026-11-19T03:00:00Z")))))))

(ert-deftest decknix-ship--teamcity-a-failed-next-stage-is-failed ()
  (let ((s (decknix-ship-status
            "o/mono" (decknix-ship-test--pr)
            (decknix-ship-test--deploys
             (decknix-ship-test--env "development" "FAILURE" "2026-11-19T01:10:00Z"))
            '(()))))
    (should (eq (plist-get s :state) 'failed))
    (should (equal (plist-get s :next) "development"))))

(ert-deftest decknix-ship--no-deploy-data-means-merged-is-done ()
  (let ((s (decknix-ship-status "o/docs" (decknix-ship-test--pr) '(()) '(()))))
    (should (eq (plist-get s :kind) 'none))
    (should (eq (plist-get s :state) 'done))
    (should (= (plist-get s :done-at)
               (float-time (date-to-time decknix-ship-test--merged))))))

(ert-deftest decknix-ship--a-dependency-bump-is-ci-only ()
  (let ((s (decknix-ship-status "o/lib" (decknix-ship-test--pr
                                         'title "build(deps): bump x"
                                         'ci '((status . "pending")))
                                '(()) '(()))))
    (should (eq (plist-get s :kind) 'ci))
    (should (eq (plist-get s :state) 'deploying))))

(ert-deftest decknix-ship--a-forced-kind-wins ()
  (let ((decknix-ship-repo-kinds '(("/mono\\'" . none))))
    (should (eq 'none (decknix-ship-kind "o/mono" nil
                                         (decknix-ship-test--deploys
                                          (decknix-ship-test--env "testing" "SUCCESS"))
                                         nil)))))

(ert-deftest decknix-ship--kargo-entry-gives-the-stages ()
  (let* ((kargo '((repos . ("o/fub"))
                  (prs . (((repo . "o/fub") (number . 7)
                           (stages . ("us-dev" "us-stg" "us-prd"))
                           (reached . ("us-dev")) (promoting . ("us-stg")))))))
         (s (decknix-ship-status "o/fub" (decknix-ship-test--pr) '(()) kargo)))
    (should (eq (plist-get s :kind) 'gitops))
    (should (equal (plist-get s :current) "us-dev"))
    (should (equal (plist-get s :next) "us-stg"))
    (should (eq (plist-get s :state) 'deploying))))

(ert-deftest decknix-ship--a-gitops-repo-without-an-entry-yet-is-pending ()
  (let ((s (decknix-ship-status "o/fub" (decknix-ship-test--pr) '(())
                                '((repos . ("o/fub")) (prs . nil)))))
    (should (eq (plist-get s :state) 'pending))))

(ert-deftest decknix-ship--ship-progress-beats-the-deploy-feed ()
  (let* ((kargo '((repos . ("o/fub"))
                  (prs . (((repo . "o/fub") (number . 7)
                           (stages . ("us-dev" "us-stg" "us-prd"))
                           (reached . ("us-dev")))))))
         (s (decknix-ship-status "o/fub" (decknix-ship-test--pr) '(()) kargo
                                 '((stage . "us-prd") (status . "verified")
                                   (verified_at . "2026-11-19T05:00:00Z")))))
    (should (eq (plist-get s :state) 'done))
    (should (eq (plist-get s :source) 'ship))
    (should (equal (plist-get s :current) "us-prd"))))

(ert-deftest decknix-ship--visibility-follows-the-retention-window ()
  (let ((done (list :state 'done :done-at 1000.0)))
    (should (eq 'shipping (decknix-ship-visibility '(:state pending) 5000)))
    (should (eq 'shipped (decknix-ship-visibility done 1500 600)))
    (should-not (decknix-ship-visibility done 1700 600))
    (should-not (decknix-ship-visibility done 1000 0))))

(ert-deftest decknix-ship--label-is-compact-and-coloured-by-state ()
  (should (equal "→stg" (substring-no-properties
                         (decknix-ship-label '(:state deploying :next "stable")))))
  (should (equal "✓prd" (substring-no-properties
                         (decknix-ship-label '(:state done :current "production" :kind teamcity)))))
  (should (equal "merged" (substring-no-properties (decknix-ship-label '(:state done :kind none)))))
  (should (equal '(:foreground "#ff5f5f" :weight bold)
                 (get-text-property 0 'face (decknix-ship-label '(:state failed :next "testing"))))))

(ert-deftest decknix-ship--lines-end-with-closing-the-ticket ()
  (let ((decknix-ship-ticket-open-function (lambda (k) (equal k "HX-1610"))))
    (should (equal (decknix-ship-lines '(:state pending :current "us-stg" :next "us-prd"
                                        :stages ("us-dev" "us-stg" "us-prd"))
                                       "HX-1610")
                   '(:state pending :current "in us-stg" :next "promote us-prd" :restates t)))
    (should (equal (plist-get (decknix-ship-lines '(:state done :current "us-prd") "HX-1610")
                              :next)
                   "close HX-1610"))
    (should-not (plist-get (decknix-ship-lines '(:state done :current "us-prd") "HX-1")
                           :next))))

(ert-deftest decknix-ship--ticket-key-from-title-or-branch ()
  (should (equal "HX-1610" (decknix-ship-ticket-key '((title . "HX-1610 thing")))))
  (should (equal "CONN-9" (decknix-ship-ticket-key '((title . "thing") (branch . "conn-9-x")))))
  (should-not (decknix-ship-ticket-key '((title . "thing")))))

(ert-deftest decknix-ship--durations-parse-and-print ()
  (should (= 600 (decknix-ship-parse-duration "10m")))
  (should (= 7200 (decknix-ship-parse-duration " 2h ")))
  (should (= 172800 (decknix-ship-parse-duration "2d")))
  (should (= 2700 (decknix-ship-parse-duration "45")))
  (should-not (decknix-ship-parse-duration "soon"))
  (should (equal "1d" (decknix-ship-retention-label 86400)))
  (should (equal "20m" (decknix-ship-retention-label 1200)))
  (should (equal "0" (decknix-ship-retention-label 0))))

(ert-deftest decknix-ship--set-retention-runs-the-hook ()
  (let ((decknix-sidebar-shipped-retention 1) (ran nil))
    (let ((decknix-ship-retention-changed-hook (list (lambda () (setq ran t)))))
      (decknix-ship-set-retention 3600))
    (should ran)
    (should (= 3600 decknix-sidebar-shipped-retention))))

;; --- several shippers per repo ------------------------------------------

(defconst decknix-ship-test--shippers
  '(("/mono\\'" (:kind teamcity :region "AU"
                   :stages ("development" "testing" "stable" "production"))
                  (:kind teamcity :region "UK" :stages ("uk_production"))
                  (:kind gitops :region "US")))
  "A monolith shipped by TeamCity in two regions and Kargo in a third.")

(defun decknix-ship-test--kargo-us (reached &rest kv)
  "kargo-stages.json with o/mono#7's US entry having REACHED, plus KV."
  `((repos . ("o/mono"))
    (prs . (((repo . "o/mono") (number . 7) (region . "US")
             (stages . ("us-dev" "us-stg" "us-prd")) (reached . ,reached)
             ,@(cl-loop for (k v) on kv by #'cddr collect (cons k v)))))))

(defun decknix-ship-test--tc (&rest done)
  "TeamCity deploys for o/mono: every env after the merge when in DONE."
  (apply #'decknix-ship-test--deploys
         (mapcar (lambda (env)
                   (decknix-ship-test--env env "SUCCESS"
                                           (if (member env done)
                                               "2026-11-19T02:00:00Z"
                                             "2026-11-18T00:00:00Z")))
                 '("development" "testing" "production" "uk_production"))))

(ert-deftest decknix-ship--shippers-progress-separately-furthest-behind-first ()
  (let* ((decknix-ship-repo-shippers decknix-ship-test--shippers)
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr)
                                 (decknix-ship-test--tc "development" "testing" "production"
                                                        "uk_production")
                                 (decknix-ship-test--kargo-us '("us-dev") 'promoting '("us-stg")))))
    (should (eq (plist-get s :kind) 'multi))
    (should (eq (plist-get s :state) 'deploying))
    (should (equal (mapcar (lambda (x) (plist-get x :region)) (plist-get s :shippers))
                   '("US" "AU" "UK")))
    (should (equal (plist-get s :current) "us-dev"))
    (should (equal "US→stg +2✓" (substring-no-properties (decknix-ship-label s))))
    (should (equal "US→stg AU✓prd UK✓prd"
                   (substring-no-properties (decknix-ship-label-full s))))))

(ert-deftest decknix-ship--a-teamcity-shipper-follows-only-its-environments ()
  (let* ((decknix-ship-repo-shippers decknix-ship-test--shippers)
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr)
                                 (decknix-ship-test--tc "development" "testing" "production")
                                 (decknix-ship-test--kargo-us '("us-dev" "us-stg" "us-prd")
                                                              'verified_at "2026-11-19T04:00:00Z"))))
    (should-not (eq (plist-get s :state) 'done))
    (should (equal (plist-get (car (plist-get s :shippers)) :region) "UK"))
    (should (equal (plist-get s :next) "uk_production"))
    (should (equal "UK·prd +2✓" (substring-no-properties (decknix-ship-label s))))
    (should (equal "UK·prd AU✓prd US✓prd" (substring-no-properties (decknix-ship-label-full s))))))

(ert-deftest decknix-ship--shipped-only-when-every-shipper-is-done ()
  (let* ((decknix-ship-repo-shippers decknix-ship-test--shippers)
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr)
                                 (decknix-ship-test--tc "development" "testing" "production"
                                                        "uk_production")
                                 (decknix-ship-test--kargo-us '("us-dev" "us-stg" "us-prd")
                                                              'verified_at "2026-11-19T04:00:00Z"))))
    (should (eq (plist-get s :state) 'done))
    (should (= (plist-get s :done-at) (float-time (date-to-time "2026-11-19T04:00:00Z"))))
    (should (equal (plist-get (decknix-ship-lines s) :current) "shipped to AU, UK, US"))))

(ert-deftest decknix-ship--a-failed-shipper-leads-and-fails-the-pr ()
  (let* ((decknix-ship-repo-shippers decknix-ship-test--shippers)
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr)
                                 (decknix-ship-test--tc "development")
                                 (decknix-ship-test--kargo-us '("us-dev" "us-stg")
                                                              'failed '("us-prd")))))
    (should (eq (plist-get s :state) 'failed))
    (should (equal (plist-get (car (plist-get s :shippers)) :region) "US"))
    (should (equal (decknix-ship-lines s)
                   '(:state failed :current "US: failed in prd"
                     :next "US: fix and redeploy prd" :restates t)))
    (should (= 0 (decknix-ship-severity s)))))

(ert-deftest decknix-ship--lines-come-from-the-furthest-behind-shipper ()
  (let* ((decknix-ship-repo-shippers decknix-ship-test--shippers)
         (decknix-ship-ticket-open-function (lambda (_k) t))
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr)
                                 (decknix-ship-test--tc "development" "testing" "production"
                                                        "uk_production")
                                 (decknix-ship-test--kargo-us '("us-dev" "us-stg")))))
    (should (equal (decknix-ship-lines s "HX-1610")
                   '(:state pending :current "US: in stg" :next "US: promote prd"
                     :restates t)))))

(ert-deftest decknix-ship--a-missing-regional-entry-is-pending-with-configured-stages ()
  (let* ((decknix-ship-repo-shippers
          '(("/mono\\'" (:kind teamcity :region "AU" :stages ("production"))
                          (:kind gitops :region "US" :stages ("us-dev" "us-prd")))))
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr)
                                 (decknix-ship-test--tc "production")
                                 '((repos . ("o/mono")) (prs . nil)))))
    (should (eq (plist-get s :state) 'pending))
    (should (equal "US·dev +1✓" (substring-no-properties (decknix-ship-label s))))))

(ert-deftest decknix-ship--regional-kargo-entries-without-config-are-shippers ()
  (let* ((kargo `((repos . ("o/fub"))
                  (prs . (((repo . "o/fub") (number . 7) (region . "UK")
                           (stages . ("uk-dev" "uk-prd")) (reached . ("uk-dev" "uk-prd")))
                          ((repo . "o/fub") (number . 7) (region . "US")
                           (stages . ("us-dev" "us-prd")) (reached . nil))))))
         (s (decknix-ship-status "o/fub" (decknix-ship-test--pr) '(()) kargo)))
    (should (eq (plist-get s :kind) 'multi))
    (should (equal "US·dev +1✓" (substring-no-properties (decknix-ship-label s))))))

(ert-deftest decknix-ship--ship-progress-updates-the-shipper-holding-its-stage ()
  (let* ((decknix-ship-repo-shippers decknix-ship-test--shippers)
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr)
                                 (decknix-ship-test--tc "development" "testing" "production"
                                                        "uk_production")
                                 (decknix-ship-test--kargo-us '("us-dev"))
                                 '((stage . "us-prd") (status . "verified")
                                   (verified_at . "2026-11-19T05:00:00Z")))))
    (should (eq (plist-get s :state) 'done))
    (should (equal "AU✓prd +2✓" (substring-no-properties (decknix-ship-label s))))
    (should (equal "AU✓prd UK✓prd US✓prd" (substring-no-properties (decknix-ship-label-full s))))))

(ert-deftest decknix-ship--one-shipper-without-a-region-is-the-old-status ()
  (let* ((decknix-ship-repo-shippers '(("/fub\\'" (:kind gitops))))
         (kargo '((repos . ("o/fub"))
                  (prs . (((repo . "o/fub") (number . 7)
                           (stages . ("us-dev" "us-stg")) (reached . ("us-dev")))))))
         (s (decknix-ship-status "o/fub" (decknix-ship-test--pr) '(()) kargo)))
    (should (eq (plist-get s :kind) 'gitops))
    (should (equal "·us-stg" (substring-no-properties (decknix-ship-label s))))))

;; --- verifying, manual stages, regions in one entry, TeamCity wording -------

(defconst decknix-ship-test--web-entry
  '((repo . "o/web") (number . 7) (merge_commit . "m")
    (stages . ("uk-dev" "us-dev" "uk-stg" "us-stg" "uk-prd" "us-prd"))
    (reached . ("uk-dev" "us-dev" "us-stg" "us-prd"))
    (manual . ("uk-stg" "us-stg" "uk-prd")))
  "Shaped like the live web entry: two regions interleaved, no region key.")

(ert-deftest decknix-ship--regions-interleaved-in-one-entry-become-shippers ()
  "The bug: badge `·uk-stg' with no region, over `in us-dev' and
`promote uk-stg', because six stages of two regions read as one pipeline."
  (let* ((kargo `((repos . ("o/web")) (prs . (,decknix-ship-test--web-entry))))
         (s (decknix-ship-status "o/web" (decknix-ship-test--pr) '(()) kargo)))
    (should (eq (plist-get s :kind) 'multi))
    (should (equal '("UK" "US") (mapcar (lambda (x) (plist-get x :region))
                                        (plist-get s :shippers))))
    (should (equal "UK⇢stg +1✓" (substring-no-properties (decknix-ship-label s))))
    (let ((lines (decknix-ship-lines s)))
      (should (equal (plist-get lines :current) "UK: ready to promote stg"))
      (should-not (plist-get lines :next)))
    (should (= 1 (decknix-ship-severity s)))))

(ert-deftest decknix-ship--a-region-keyed-or-single-region-entry-is-not-split ()
  (should (= 1 (length (decknix-ship-split-regions
                        '((region . "US") (stages . ("us-dev" "uk-dev")))))))
  (should (= 1 (length (decknix-ship-split-regions '((stages . ("us-dev" "us-prd"))))))))

(ert-deftest decknix-ship--verifying-is-not-deploying ()
  (let* ((kargo '((repos . ("o/fub"))
                  (prs . (((repo . "o/fub") (number . 7)
                           (stages . ("us-dev" "us-stg" "us-prd"))
                           (reached . ("us-dev" "us-stg")) (verifying . ("us-prd"))
                           (manual . nil))))))
         (s (decknix-ship-status "o/fub" (decknix-ship-test--pr) '(()) kargo))
         (lines (decknix-ship-lines s)))
    (should (eq (plist-get s :state) 'verifying))
    (should (equal (plist-get lines :current) "verifying us-prd"))
    (should-not (plist-get lines :restates))
    (should-not (plist-get lines :next))))

(ert-deftest decknix-ship--an-auto-stage-waits-without-asking-anyone ()
  "us-prd promotes itself: nothing for a person to do, so no next step."
  (let* ((kargo '((repos . ("o/fub"))
                  (prs . (((repo . "o/fub") (number . 7) (region . "US")
                           (stages . ("us-dev" "us-stg" "us-prd"))
                           (reached . ("us-dev" "us-stg")) (manual . nil))))))
         (lines (decknix-ship-lines
                 (decknix-ship-status "o/fub" (decknix-ship-test--pr) '(()) kargo))))
    (should (eq (plist-get lines :state) 'pending))
    (should (equal (plist-get lines :current) "US: in stg, prd follows"))
    (should-not (plist-get lines :next))))

(ert-deftest decknix-ship--teamcity-deploys-rather-than-promotes ()
  (let* ((decknix-ship-repo-shippers decknix-ship-test--shippers)
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr)
                                 (decknix-ship-test--tc "production")
                                 (decknix-ship-test--kargo-us '("us-dev" "us-stg" "us-prd")
                                                              'verified_at "2026-11-19T04:00:00Z"))))
    (should (equal (plist-get (decknix-ship-lines s) :next) "UK: deploy prd"))))

(ert-deftest decknix-ship--teamcity-compares-times-not-strings ()
  "11:30+11:00 is 00:30Z, before the 01:00Z merge, though it sorts after."
  (let* ((deploys (decknix-ship-test--deploys
                   (decknix-ship-test--env "development" "SUCCESS" "2026-11-19T11:30:00+11:00")))
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr) deploys '(()))))
    (should-not (plist-get s :current))))

(ert-deftest decknix-ship--times-parse-once-and-reject-junk ()
  (let ((decknix-ship--time-cache (make-hash-table :test 'equal)))
    (should (= (decknix-ship--time "2026-11-19T04:00:00Z")
               (float-time (date-to-time "2026-11-19T04:00:00Z"))))
    (should (= 1 (hash-table-count decknix-ship--time-cache)))
    (should (decknix-ship--time "2026-11-19T04:00:00Z"))
    (should (= 1 (hash-table-count decknix-ship--time-cache)))
    (should-not (decknix-ship--time "not a time"))
    (should-not (decknix-ship--time ""))
    (should-not (decknix-ship--time nil))))

;; --- stale or missing deploy data ----------------------------------------

(defun decknix-ship-test--kargo-one (entry &rest kv)
  "kargo-stages.json for o/svc holding ENTRY (nil for none), plus top-level KV."
  (append (cl-loop for (k v) on kv by #'cddr collect (cons k v))
          `((repos . ("o/svc"))
            (prs . ,(and entry
                         (list (append entry
                                       '((repo . "o/svc") (number . 7)
                                         (stages . ("uk-dev" "uk-stg" "uk-prd"))))))))))

(ert-deftest decknix-ship--a-stale-entry-short-of-done-is-unknown-not-undeployed ()
  "During a Kargo login expiry every merge read `merged, not deployed'."
  (let* ((kargo (decknix-ship-test--kargo-one '((region . "UK") (reached . ("uk-dev")) (stale . t))))
         (s (decknix-ship-status "o/svc" (decknix-ship-test--pr) '(()) kargo))
         (lines (decknix-ship-lines s)))
    (should (eq (plist-get s :state) 'unknown))
    (should (equal (plist-get lines :current) "UK: stage unknown (Kargo unavailable)"))
    (should-not (plist-get lines :next))
    (should-not (string-match-p "not deployed" (plist-get lines :current)))
    (should (equal (substring-no-properties (decknix-ship-label s)) "UK?"))
    (should (eq (get-text-property 0 'face (decknix-ship-label s)) 'shadow))
    (should (= (decknix-ship-severity s) 4))))

(ert-deftest decknix-ship--a-stale-entry-that-had-shipped-stays-shipped ()
  (let* ((kargo (decknix-ship-test--kargo-one
                 '((reached . ("uk-dev" "uk-stg" "uk-prd")) (stale . t)
                   (verified_at . "2026-11-19T03:00:00Z"))))
         (s (decknix-ship-status "o/svc" (decknix-ship-test--pr) '(()) kargo)))
    (should (eq (plist-get s :state) 'done))))

(ert-deftest decknix-ship--no-entry-for-a-repo-kargo-cannot-read-is-unknown ()
  (let* ((kargo (decknix-ship-test--kargo-one
                 nil 'stale '(((repo . "o/svc") (error . "login expired")))))
         (s (decknix-ship-status "o/svc" (decknix-ship-test--pr) '(()) kargo)))
    (should (eq (plist-get s :state) 'unknown))
    (should (equal (plist-get (decknix-ship-lines s) :current)
                   "stage unknown (Kargo unavailable)"))))

(ert-deftest decknix-ship--a-stale-teamcity-repo-is-unknown-unless-done ()
  (let* ((deploys `((repos . (((repo . "o/mono") (stale . t)
                               (branches . (((branch . "__default__")
                                             (environments . (,(decknix-ship-test--env
                                                                "development" "SUCCESS"
                                                                "2026-11-18T00:00:00Z")))))))))))
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr) deploys '(()))))
    (should (eq (plist-get s :state) 'unknown))
    (should (equal (plist-get (decknix-ship-lines s) :current)
                   "stage unknown (TeamCity unavailable)"))))

(ert-deftest decknix-ship--an-unknown-shipper-never-hides-a-known-one ()
  "A US stage nobody can read must not stand in front of AU waiting on you."
  (let* ((decknix-ship-repo-shippers decknix-ship-test--shippers)
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr)
                                 (decknix-ship-test--tc "development" "testing")
                                 (decknix-ship-test--kargo-us '("us-dev") 'stale t))))
    (should-not (eq (plist-get s :state) 'unknown))
    (should-not (equal (plist-get (car (plist-get s :shippers)) :region) "US"))
    (should (memq 'unknown (mapcar (lambda (x) (plist-get x :state)) (plist-get s :shippers))))))

;; --- no deploy needed --------------------------------------------------

(ert-deftest decknix-ship--a-merge-changing-no-runtime-file-is-done-without-a-deploy ()
  "nc-helix/go-links#7 added a Nix flake and read `next: promote' for days."
  (let* ((kargo (decknix-ship-test--kargo-one
                 '((reached . ()) (no_deploy . "no runtime files changed")
                   (verified_at . "2026-11-19T01:00:00Z"))))
         (s (decknix-ship-status "o/svc" (decknix-ship-test--pr) '(()) kargo))
         (lines (decknix-ship-lines s)))
    (should (eq (plist-get s :state) 'done))
    (should (equal (plist-get s :no-deploy) "no runtime files changed"))
    (should (= (plist-get s :done-at) (decknix-ship--time "2026-11-19T01:00:00Z")))
    (should (equal (plist-get lines :current) "no deploy needed"))
    (should-not (plist-get lines :next))
    (should (equal (substring-no-properties (decknix-ship-label s)) "✓none"))))

;; --- no repetition --------------------------------------------------------

(ert-deftest decknix-ship--ready-to-promote-is-not-followed-by-next-promote ()
  "`UK: ready to promote prd' over `next: UK: promote prd' said it twice."
  (let ((lines (decknix-ship-lines '(:kind gitops :region "UK" :state ready :current "uk-stg"
                                     :next "uk-prd" :stages ("uk-dev" "uk-stg" "uk-prd")
                                     :manual ("uk-prd")))))
    (should (equal (plist-get lines :current) "UK: ready to promote prd"))
    (should-not (plist-get lines :next))))

(ert-deftest decknix-ship--a-stale-known-failure-stays-failed-marked-stale ()
  "Kargo going quiet must not hide a stage that had failed: it still wants you."
  (let* ((kargo (decknix-ship-test--kargo-one
                 '((region . "UK") (reached . ("uk-dev")) (failed . ("uk-stg"))
                   (stale . t) (as_of . "2026-11-24T01:00:00Z"))))
         (s (decknix-ship-status "o/svc" (decknix-ship-test--pr) '(()) kargo))
         (label (decknix-ship-label s)))
    (should (eq (plist-get s :state) 'failed))
    (should (equal (plist-get s :stale) "Kargo"))
    (should (= (plist-get s :as-of) (float-time (date-to-time "2026-11-24T01:00:00Z"))))
    (should (equal (substring-no-properties label) "UK✗stg?"))
    (should (eq (get-text-property (1- (length label)) 'face label) 'shadow))
    (should (equal (plist-get (decknix-ship-lines s) :current) "UK: failed in stg"))
    (should (= (decknix-ship-severity s) 0))))

(ert-deftest decknix-ship--a-stale-known-ready-stage-stays-ready ()
  (let* ((kargo (decknix-ship-test--kargo-one
                 '((region . "UK") (reached . ("uk-dev" "uk-stg")) (manual . ("uk-prd"))
                   (stale . t) (as_of . "2026-11-24T01:00:00Z"))))
         (s (decknix-ship-status "o/svc" (decknix-ship-test--pr) '(()) kargo)))
    (should (eq (plist-get s :state) 'ready))
    (should (equal (substring-no-properties (decknix-ship-label s)) "UK⇢prd?"))
    (should (= (decknix-ship-severity s) 1))))

(ert-deftest decknix-ship--a-stale-known-stage-in-flight-keeps-its-stage ()
  (let* ((kargo (decknix-ship-test--kargo-one
                 '((region . "UK") (reached . ("uk-dev")) (promoting . ("uk-stg"))
                   (stale . t) (as_of . "2026-11-24T01:00:00Z"))))
         (s (decknix-ship-status "o/svc" (decknix-ship-test--pr) '(()) kargo)))
    (should (eq (plist-get s :state) 'deploying))
    (should (equal (substring-no-properties (decknix-ship-label s)) "UK→stg?"))))

(ert-deftest decknix-ship--a-stale-teamcity-failure-it-had-read-stays-failed ()
  (let* ((deploys `((repos . (((repo . "o/mono") (stale . t) (as_of . "2026-11-24T01:00:00Z")
                               (branches . (((branch . "__default__")
                                             (environments . (,(decknix-ship-test--env
                                                                "development" "FAILURE"
                                                                "2026-11-19T02:00:00Z")))))))))))
         (s (decknix-ship-status "o/mono" (decknix-ship-test--pr) deploys '(()))))
    (should (eq (plist-get s :state) 'failed))
    (should (equal (decknix-ship-stale s)
                   (cons "TeamCity" (float-time (date-to-time "2026-11-24T01:00:00Z")))))))

(ert-deftest decknix-ship--stale-names-the-oldest-stale-shipper ()
  (let ((s (list :kind 'multi :state 'failed
                 :shippers (list '(:state failed :stale "Kargo" :as-of 200.0)
                                 '(:state ready :stale "TeamCity" :as-of 100.0)
                                 '(:state done)))))
    (should (equal (decknix-ship-stale s) '("TeamCity" . 100.0)))
    (should-not (decknix-ship-stale '(:state failed)))))

;;; decknix-ship-test.el ends here
