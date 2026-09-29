;;; decknix-repo-sync-test.el --- Tests for repo-sync problem surfacing -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The sweep reported a flat "3 errors" every run for at least twelve runs, so
;; `upside' sat on an abandoned index.lock for 61 consecutive runs -- two weeks
;; with no updates -- without the number moving.  These pin the classification
;; that turns that tally into rows a user can act on.
;;
;; The fixture is copied from a REAL report (~/.config/decknix/repo-sync.json,
;; 60 repos), including the exact `detail' wording, because every
;; classification below keys off that wording and a CLI phrasing change must
;; fail here rather than silently reporting health.

;;; Code:

(require 'ert)
(require 'decknix-repo-sync)

(defconst decknix-repo-sync-test--report
  "{\"updated\": 1790695875, \"repos\": [
     {\"org\":\"nurturecloud\",\"path\":\"/w/nc/web\",\"defaultBranch\":\"main\",
      \"outcome\":\"fetched\",\"detail\":\"up to date\",\"error\":false},
     {\"org\":\"nurturecloud\",\"path\":\"/w/nc/upside\",\"defaultBranch\":\"development\",
      \"outcome\":\"error-lock\",
      \"detail\":\"index.lock blocks fast-forward of development (+204); clear it if stale\",
      \"error\":true},
     {\"org\":\"nurturecloud\",\"path\":\"/w/nc/experiment-noser-go\",\"defaultBranch\":\"main\",
      \"outcome\":\"error\",
      \"detail\":\"fetch failed: git fetch --prune --quiet origin: ERROR: Repository not found\",
      \"error\":true},
     {\"org\":\"nurturecloud\",\"path\":\"/w/nc/nct-public-api\",\"defaultBranch\":\"main\",
      \"outcome\":\"skipped\",
      \"detail\":\"fetched; main behind +102 but working tree dirty\",\"error\":false},
     {\"org\":\"nurturecloud\",\"path\":\"/w/nc/helix\",\"defaultBranch\":\"main\",
      \"outcome\":\"skipped\",
      \"detail\":\"fetched; main behind +44 but working tree dirty\",\"error\":false},
     {\"org\":\"nurturecloud\",\"path\":\"/w/nc/decknix-config\",\"defaultBranch\":\"main\",
      \"outcome\":\"skipped\",
      \"detail\":\"fetched; main diverged (+126/-6)\",\"error\":false},
     {\"org\":\"nurturecloud\",\"path\":\"/w/nc/proptrack-dashboard\",\"defaultBranch\":\"\",
      \"outcome\":\"no-origin\",\"detail\":\"no 'origin' remote\",\"error\":false},
     {\"org\":\"ldeck\",\"path\":\"/w/ldeck/decknix\",\"defaultBranch\":\"main\",
      \"outcome\":\"fetched\",\"detail\":\"fetched (main ahead +269)\",\"error\":false}]}"
  "A report in the real shape: one of each outcome the CLI actually emits.")

(defun decknix-repo-sync-test--problems ()
  (plist-get (decknix--repo-sync-parse decknix-repo-sync-test--report) :problems))

(defun decknix-repo-sync-test--kind (name)
  (plist-get (seq-find (lambda (p) (equal name (plist-get p :name)))
                       (decknix-repo-sync-test--problems))
             :kind))

;; --- classification ---------------------------------------------------

(ert-deftest decknix-repo-sync--lock-is-its-own-kind ()
  "A lock must be distinguishable from any other failure: it is the one with
a mechanical remedy, and conflating it is why it went unnoticed for 61 runs."
  (should (eq 'lock (decknix-repo-sync-test--kind "upside"))))

(ert-deftest decknix-repo-sync--other-fetch-failures-are-failed ()
  "A missing repo needs a human, not a lock-clearing keypress."
  (should (eq 'failed (decknix-repo-sync-test--kind "experiment-noser-go"))))

(ert-deftest decknix-repo-sync--dirty-skip-is-reported-with-its-backlog ()
  (let ((p (seq-find (lambda (p) (equal "nct-public-api" (plist-get p :name)))
                     (decknix-repo-sync-test--problems))))
    (should (eq 'dirty (plist-get p :kind)))
    (should (equal 102 (plist-get p :behind)))))

(ert-deftest decknix-repo-sync--diverged-needs-no-behind-count ()
  "`main diverged (+126/-6)' carries NO `behind +N', so requiring one dropped
every diverged repo silently -- exactly the class of bug being fixed."
  (should (eq 'diverged (decknix-repo-sync-test--kind "decknix-config"))))

(ert-deftest decknix-repo-sync--healthy-repos-are-not-problems ()
  "Up to date, ahead, and local-only clones are all fine.  A row per healthy
repo would bury the handful that need something."
  (dolist (name '("web" "decknix" "proptrack-dashboard"))
    (should-not (decknix-repo-sync-test--kind name))))

(ert-deftest decknix-repo-sync--ahead-is-not-diverged ()
  "`fetched (main ahead +269)' is decknix's normal unpushed state, not a
problem.  The word `ahead' must not trip the diverged match."
  (should-not (decknix--repo-sync-classify
               '((outcome . "fetched") (detail . "fetched (main ahead +269)")))))

;; --- ordering ---------------------------------------------------------

(ert-deftest decknix-repo-sync--actionable-rows-sort-first ()
  "A one-keypress fix must not sit below a row needing a decision."
  (should (eq 'lock (plist-get (car (decknix-repo-sync-test--problems)) :kind))))

(ert-deftest decknix-repo-sync--furthest-behind-first-within-a-kind ()
  "+102 is closer to a painful merge than +44."
  (let ((dirty (seq-filter (lambda (p) (eq 'dirty (plist-get p :kind)))
                           (decknix-repo-sync-test--problems))))
    (should (equal '(102 44) (mapcar (lambda (p) (plist-get p :behind)) dirty)))))

;; --- parsing robustness -----------------------------------------------

(ert-deftest decknix-repo-sync--garbage-is-no-report-not-no-problems ()
  "Reporting health from an unreadable file recreates the original bug."
  (should-not (decknix--repo-sync-parse "not json"))
  (should-not (decknix--repo-sync-parse ""))
  (should-not (decknix--repo-sync-parse "{}")))

(ert-deftest decknix-repo-sync--an-all-healthy-report-parses-to-no-problems ()
  "Distinct from an unreadable one: this says so positively."
  (let ((parsed (decknix--repo-sync-parse
                 "{\"updated\":1,\"repos\":[{\"path\":\"/w/a\",\"outcome\":\"fetched\",
                   \"detail\":\"up to date\",\"error\":false}]}")))
    (should parsed)
    (should-not (plist-get parsed :problems))))

;; --- report staleness -------------------------------------------------

(ert-deftest decknix-repo-sync--one-missed-run-is-tolerated ()
  "The sweep runs 3-hourly; a single skipped run is normal (sleep, reboot)."
  (should-not (decknix--repo-sync-stale-report-p 1000 (+ 1000 10800))))

(ert-deftest decknix-repo-sync--two-missed-runs-is-stale ()
  "A report that stopped being written is its own failure; without this the
sidebar renders week-old problems as current."
  (should (decknix--repo-sync-stale-report-p 1000 (+ 1000 (* 3 10800)))))

(ert-deftest decknix-repo-sync--a-missing-timestamp-is-stale ()
  (should (decknix--repo-sync-stale-report-p nil 5000))
  (should (decknix--repo-sync-stale-report-p "junk" 5000)))

;; --- presentation -----------------------------------------------------

(ert-deftest decknix-repo-sync--labels-name-the-remedy-not-the-internals ()
  (should (string-match-p "stale lock"
                          (decknix--repo-sync-row-label '(:kind lock :name "upside"))))
  (should (string-match-p "102 behind"
                          (decknix--repo-sync-row-label
                           '(:kind dirty :name "nct-public-api" :behind 102))))
  (should (string-match-p "diverged from origin"
                          (decknix--repo-sync-row-label
                           '(:kind diverged :name "decknix-config")))))

(ert-deftest decknix-repo-sync--summary-counts-every-kind-present ()
  (let ((s (decknix--repo-sync-summary (decknix-repo-sync-test--problems))))
    (should (string-match-p "1 lock" s))
    (should (string-match-p "2 dirty" s))
    (should (string-match-p "1 diverged" s))
    (should (string-match-p "1 failed" s)))
  (should-not (decknix--repo-sync-summary nil)))

(ert-deftest decknix-repo-sync--hiding-behind-keeps-the-failures ()
  "Turning off the backlog rows must never hide something broken."
  (let ((decknix-repo-sync-show-behind nil))
    (let ((visible (seq-filter #'decknix--repo-sync-visible-p
                               (decknix-repo-sync-test--problems))))
      (should (equal '(lock failed)
                     (mapcar (lambda (p) (plist-get p :kind)) visible))))))

(provide 'decknix-repo-sync-test)
;;; decknix-repo-sync-test.el ends here
