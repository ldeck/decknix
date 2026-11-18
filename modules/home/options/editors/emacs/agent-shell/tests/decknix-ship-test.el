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
  `((repos . (((repo . "o/upside")
               (branches . (((branch . "__default__") (environments . ,envs)))))))))

(ert-deftest decknix-ship--an-open-pr-has-no-status ()
  (should-not (decknix-ship-status "o/x" '((number . 1) (state . "OPEN")) '(()) '(())))
  (should (decknix-ship-merged-p '((state . "merged")))))

(ert-deftest decknix-ship--teamcity-in-flight-names-current-and-next ()
  (let* ((deploys (decknix-ship-test--deploys
                   (decknix-ship-test--env "development" "SUCCESS" "2026-11-19T01:10:00Z")
                   (decknix-ship-test--env "testing" "SUCCESS" "2026-11-18T01:10:00Z" "running")
                   (decknix-ship-test--env "production" "SUCCESS" "2026-11-17T00:00:00Z")))
         (s (decknix-ship-status "o/upside" (decknix-ship-test--pr) deploys '(()))))
    (should (eq (plist-get s :kind) 'teamcity))
    (should (equal (plist-get s :current) "development"))
    (should (equal (plist-get s :next) "testing"))
    (should (eq (plist-get s :state) 'deploying))))

(ert-deftest decknix-ship--teamcity-a-deploy-before-the-merge-does-not-count ()
  (let* ((deploys (decknix-ship-test--deploys
                   (decknix-ship-test--env "development" "SUCCESS" "2026-11-18T00:00:00Z")))
         (s (decknix-ship-status "o/upside" (decknix-ship-test--pr) deploys '(()))))
    (should-not (plist-get s :current))
    (should (eq (plist-get s :state) 'pending))))

(ert-deftest decknix-ship--teamcity-done-needs-every-final-environment ()
  (let* ((envs (list (decknix-ship-test--env "development" "SUCCESS" "2026-11-19T01:10:00Z")
                     (decknix-ship-test--env "production" "SUCCESS" "2026-11-19T02:00:00Z")
                     (decknix-ship-test--env "uk_production" "SUCCESS" "2026-11-18T00:00:00Z")))
         (s (decknix-ship-status "o/upside" (decknix-ship-test--pr)
                                 (apply #'decknix-ship-test--deploys envs) '(()))))
    (should-not (eq (plist-get s :state) 'done))
    (setf (alist-get 'finished (nth 2 envs)) "2026-11-19T03:00:00Z")
    (let ((s (decknix-ship-status "o/upside" (decknix-ship-test--pr)
                                  (apply #'decknix-ship-test--deploys envs) '(()))))
      (should (eq (plist-get s :state) 'done))
      (should (= (plist-get s :done-at)
                 (float-time (date-to-time "2026-11-19T03:00:00Z")))))))

(ert-deftest decknix-ship--teamcity-a-failed-next-stage-is-failed ()
  (let ((s (decknix-ship-status
            "o/upside" (decknix-ship-test--pr)
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
  (let ((decknix-ship-repo-kinds '(("/upside\\'" . none))))
    (should (eq 'none (decknix-ship-kind "o/upside" nil
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
                   '(:state pending :current "in us-stg" :next "promote us-prd")))
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

;;; decknix-ship-test.el ends here
