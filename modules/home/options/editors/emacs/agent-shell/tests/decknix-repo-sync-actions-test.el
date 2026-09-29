;;; decknix-repo-sync-actions-test.el --- Tests for repo-sync remedies -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The remedies are mostly process spawns, so what is worth pinning is which
;; remedy is OFFERED for which problem, the cache's failure behaviour, and the
;; argv handed to the CLI.
;;
;; The offering matters most: `clear lock' must never appear on a dirty repo.
;; Suggesting that deleting a lock fixes uncommitted work would be worse than
;; offering nothing, and the guard that makes lock-clearing safe lives in the
;; CLI, so the client side has to be equally careful about when it asks.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-repo-sync-actions)

;; --- which remedies are offered ---------------------------------------

(ert-deftest decknix-repo-sync-actions--only-a-lock-offers-clearing ()
  "`[c]lear' is for the one kind with a mechanical remedy."
  (should (string-match-p "\\[c\\]lear"
                          (alist-get 'lock decknix--repo-sync-action-prompts)))
  (dolist (kind '(dirty diverged failed))
    (should-not (string-match-p
                 "\\[c\\]lear"
                 (alist-get kind decknix--repo-sync-action-prompts)))))

(ert-deftest decknix-repo-sync-actions--every-kind-has-a-prompt ()
  "A kind with no prompt falls back to a generic one; better to notice here."
  (dolist (kind decknix-repo-sync-kinds)
    (should (alist-get kind decknix--repo-sync-action-prompts))))

(ert-deftest decknix-repo-sync-actions--every-prompt-offers-visit-and-quit ()
  "Visiting is always available: every kind ultimately wants a human eye, and
quitting must always be possible from a `read-char-choice'."
  (dolist (kind decknix-repo-sync-kinds)
    (let ((p (alist-get kind decknix--repo-sync-action-prompts)))
      (should (string-match-p "\\[v\\]isit" p))
      (should (string-match-p "\\[q\\]uit" p)))))

;; --- faces ------------------------------------------------------------

(ert-deftest decknix-repo-sync-actions--severity-is-visible ()
  "A failure needing a human must not look like a backlog row."
  (should (eq 'decknix-repo-sync-lock-face (decknix--repo-sync-face 'lock)))
  (should (eq 'decknix-repo-sync-failed-face (decknix--repo-sync-face 'failed)))
  (should (eq 'font-lock-comment-face (decknix--repo-sync-face 'dirty)))
  (should (eq 'font-lock-comment-face (decknix--repo-sync-face 'diverged))))

;; --- cache ------------------------------------------------------------

(ert-deftest decknix-repo-sync-actions--no-cache-means-no-problems ()
  "Before the first read the section must render nothing rather than error."
  (let ((decknix--repo-sync-cache nil))
    (should-not (decknix-repo-sync-problems))
    (should-not (decknix-repo-sync-summary))))

(ert-deftest decknix-repo-sync-actions--an-absent-report-reads-as-stale ()
  "Nothing has written a report, so a refresh should be attempted."
  (let ((decknix--repo-sync-cache nil))
    (should (decknix-repo-sync-report-stale-p))))

(ert-deftest decknix-repo-sync-actions--a-failed-read-keeps-the-old-cache ()
  "Replacing a good cache with nil would render as \"no problems\" -- the
exact false-health signal this feature exists to remove."
  (let* ((kept '(:updated 1 :problems ((:kind lock :name "upside"))))
         (decknix--repo-sync-cache kept)
         (decknix--repo-sync-read-pending nil)
         (decknix-repo-sync-report "/nonexistent/repo-sync.json"))
    (decknix-repo-sync-refresh)
    ;; The refresh defers via `run-at-time' 0; drain the timer queue.
    (sit-for 0.05)
    (should (equal kept decknix--repo-sync-cache))))

;; --- argv handed to the CLI -------------------------------------------

(ert-deftest decknix-repo-sync-actions--retry-is-scoped-to-one-repo ()
  "An unscoped retry would re-sweep 60 clones and, worse, overwrite the full
report with a single row."
  (let (captured)
    (cl-letf (((symbol-function 'decknix--repo-sync-run)
               (lambda (args _name _on-done) (setq captured args))))
      (decknix-repo-sync-retry '(:name "upside" :path "/w/nc/upside"))
      (should (equal '("repos" "sync" "--only" "upside") captured)))))

(ert-deftest decknix-repo-sync-actions--clear-lock-asks-the-guarded-verb ()
  "Clearing goes through `repos fix-lock', never a bare file delete: the
age-and-not-held guard lives there."
  (let (captured)
    (cl-letf (((symbol-function 'decknix--repo-sync-run)
               (lambda (args _name _on-done) (setq captured args))))
      (decknix-repo-sync-clear-lock '(:name "upside" :path "/w/nc/upside"))
      (should (equal '("repos" "fix-lock" "/w/nc/upside" "--json") captured)))))

(ert-deftest decknix-repo-sync-actions--clear-lock-refuses-without-a-path ()
  "With no path there is nothing safe to act on."
  (should-error (decknix-repo-sync-clear-lock '(:name "upside"))
                :type 'user-error))

(provide 'decknix-repo-sync-actions-test)
;;; decknix-repo-sync-actions-test.el ends here
