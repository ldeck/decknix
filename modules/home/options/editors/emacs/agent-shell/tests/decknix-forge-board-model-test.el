;;; decknix-forge-board-model-test.el --- Forge Board grouping -*- lexical-binding: t -*-

;;; Commentary:
;;
;; What is pinned here is which lanes each bulk verb may touch, because that
;; is the part where a mistake acts on many repos at once.
;;
;; `clear lock' must stay confined to the `lock' lane: on a dirty repo it
;; would imply that deleting a lock recovers uncommitted work, and on a
;; failed row there is usually no lock to delete.

;;; Code:

(require 'ert)
(require 'decknix-forge-board-model)

(defun decknix-fb-test--p (kind name &optional path)
  (list :kind kind :name name :path (or path (concat "/repos/" name))
        :detail (format "%s detail" kind)))

;; --- lane placement ---------------------------------------------------

(ert-deftest decknix-fb--lanes-render-mechanically-fixable-first ()
  "`lock' and `failed' lead because a bulk verb can finish them; the other
two need the user to go and look."
  (should (equal '(lock failed diverged dirty) decknix-forge-board-lanes)))

(ert-deftest decknix-fb--groups-in-lane-order-not-input-order ()
  (let ((groups (decknix-forge-board-group
                 (list (decknix-fb-test--p 'dirty "d")
                       (decknix-fb-test--p 'lock "a")
                       (decknix-fb-test--p 'failed "b")))))
    (should (equal '(lock failed dirty) (mapcar #'car groups)))))

(ert-deftest decknix-fb--empty-lanes-are-omitted ()
  "An empty heading is noise in a board that exists to show what is there."
  (let ((groups (decknix-forge-board-group
                 (list (decknix-fb-test--p 'lock "a")))))
    (should (equal '(lock) (mapcar #'car groups)))))

(ert-deftest decknix-fb--no-problems-is-no-groups ()
  (should-not (decknix-forge-board-group nil)))

(ert-deftest decknix-fb--an-unknown-kind-is-dropped-not-crashed ()
  "The report is written by a separate binary that can gain outcomes."
  (should-not (decknix-forge-board-group
               (list (decknix-fb-test--p 'something-new "x")))))

;; --- which verb may touch which lane ----------------------------------

(ert-deftest decknix-fb--clearing-is-confined-to-the-lock-lane ()
  "On a dirty repo this would suggest deleting a lock recovers uncommitted
work; on a failed row there is usually no lock at all."
  (should (decknix-forge-board-clearable-p (decknix-fb-test--p 'lock "a")))
  (dolist (kind '(failed diverged dirty))
    (should-not (decknix-forge-board-clearable-p
                 (decknix-fb-test--p kind "a")))))

(ert-deftest decknix-fb--retry-is-safe-on-every-lane ()
  "A re-sync only fetches and never force-updates a dirty or diverged
repo, so it can correct a stale row without risking local work."
  (dolist (kind '(lock failed diverged dirty))
    (should (decknix-forge-board-retryable-p (decknix-fb-test--p kind "a")))))

(ert-deftest decknix-fb--filter-clearable-keeps-only-locks ()
  "A mark spanning a whole sweep must not have to be pruned by hand
before the one verb that applies to part of it will run."
  (let ((rows (list (decknix-fb-test--p 'lock "a")
                    (decknix-fb-test--p 'dirty "b")
                    (decknix-fb-test--p 'lock "c")
                    (decknix-fb-test--p 'failed "d"))))
    (should (equal '("a" "c")
                   (mapcar (lambda (r) (plist-get r :name))
                           (decknix-forge-board-filter-clearable rows))))))

;; --- marks must survive a re-render -----------------------------------

(ert-deftest decknix-fb--rows-are-keyed-on-path-not-name ()
  "Two clones of one repo in different worktree directories share a name;
a mark keyed on the name would act on whichever the re-render ordered
first."
  (let ((a (decknix-forge-board-row (decknix-fb-test--p 'lock "upside" "/one/upside")))
        (b (decknix-forge-board-row (decknix-fb-test--p 'lock "upside" "/two/upside"))))
    (should-not (equal (decknix-forge-board-row-key a)
                       (decknix-forge-board-row-key b)))))

(ert-deftest decknix-fb--row-order-is-stable ()
  "A refresh lands between marking and acting; if the order moved, a mark
would shift onto a different repo."
  (let* ((ps (list (decknix-fb-test--p 'lock "zz")
                   (decknix-fb-test--p 'lock "aa")
                   (decknix-fb-test--p 'lock "mm")))
         (first (mapcar (lambda (r) (plist-get r :name))
                        (cdr (car (decknix-forge-board-group ps)))))
         (again (mapcar (lambda (r) (plist-get r :name))
                        (cdr (car (decknix-forge-board-group (reverse ps)))))))
    (should (equal '("aa" "mm" "zz") first))
    (should (equal first again))))

;; --- labels -----------------------------------------------------------

(ert-deftest decknix-fb--row-label-is-exactly-the-width ()
  (let ((row (decknix-forge-board-row (decknix-fb-test--p 'lock "upside"))))
    (dolist (w '(40 60 76))
      (should (= w (string-width (decknix-forge-board-row-label row nil w)))))))

(ert-deftest decknix-fb--a-long-detail-never-pushes-out-the-name ()
  "The name is what a bulk verb reports acting on, so it must survive."
  (let* ((p (list :kind 'failed :name "upside" :path "/p"
                  :detail (make-string 400 ?x)))
         (row (decknix-forge-board-row p))
         (label (decknix-forge-board-row-label row nil 40)))
    (should (= 40 (string-width label)))
    (should (string-match-p "upside" label))))

(ert-deftest decknix-fb--the-mark-is-visible-in-the-label ()
  (let ((row (decknix-forge-board-row (decknix-fb-test--p 'lock "a"))))
    (should (string-prefix-p "*" (decknix-forge-board-row-label row t 40)))
    (should (string-prefix-p " " (decknix-forge-board-row-label row nil 40)))))

(ert-deftest decknix-fb--the-dirty-hint-names-its-verb-and-that-it-is-safe ()
  "That lane is where the user has most reason to hesitate, so the hint
has to say both what clears it and that the work comes back."
  (let ((hint (decknix-forge-board-lane-hint 'dirty)))
    ;; Rendered as "[s]tash" -- the key is part of the hint, so match the
    ;; bracketed form rather than the bare word.
    (should (string-match-p "\\[s\\]tash" hint))
    (should (string-match-p "recoverab" hint))))

;; --- stashing ---------------------------------------------------------

(ert-deftest decknix-fb--stashing-is-confined-to-the-dirty-lane ()
  "There is nothing to stash in a clean tree, and on a diverged repo it
would stash nothing while implying the divergence was dealt with."
  (should (decknix-forge-board-stashable-p (decknix-fb-test--p 'dirty "a")))
  (dolist (kind '(lock failed diverged))
    (should-not (decknix-forge-board-stashable-p
                 (decknix-fb-test--p kind "a")))))

(ert-deftest decknix-fb--filter-stashable-keeps-only-dirty ()
  (let ((rows (list (decknix-fb-test--p 'dirty "a")
                    (decknix-fb-test--p 'lock "b")
                    (decknix-fb-test--p 'dirty "c"))))
    (should (equal '("a" "c")
                   (mapcar (lambda (r) (plist-get r :name))
                           (decknix-forge-board-filter-stashable rows))))))

(ert-deftest decknix-fb--clear-and-stash-lanes-do-not-overlap ()
  "A row must not accept both verbs: they are remedies for different
faults, and a mark spanning both lanes should route each row once."
  (dolist (kind decknix-forge-board-lanes)
    (let ((row (decknix-fb-test--p kind "a")))
      (should-not (and (decknix-forge-board-clearable-p row)
                       (decknix-forge-board-stashable-p row))))))

;; --- grouping by org --------------------------------------------------

(ert-deftest decknix-fb--org-grouping-splits-by-org ()
  (let ((groups (decknix-forge-board-group-by-org
                 (list (append (decknix-fb-test--p 'dirty "a") '(:org "one"))
                       (append (decknix-fb-test--p 'lock "b") '(:org "two"))
                       (append (decknix-fb-test--p 'lock "c") '(:org "one"))))))
    (should (equal '("one" "two") (mapcar #'car groups)))
    (should (= 2 (length (cdr (assoc "one" groups)))))))

(ert-deftest decknix-fb--org-grouping-with-one-org-is-a-single-heading ()
  "Measured 59 of 60 rows in one org and all 8 problem rows in that one,
so this axis separates nothing today.  Pinned so the behaviour is not
mistaken for a bug."
  (let ((groups (decknix-forge-board-group-by-org
                 (list (append (decknix-fb-test--p 'dirty "a") '(:org "nc"))
                       (append (decknix-fb-test--p 'lock "b") '(:org "nc"))))))
    (should (= 1 (length groups)))))

(ert-deftest decknix-fb--org-grouping-handles-a-missing-org ()
  (let ((groups (decknix-forge-board-group-by-org
                 (list (decknix-fb-test--p 'dirty "a")))))
    (should (equal '("?") (mapcar #'car groups)))))

(ert-deftest decknix-fb--summary-counts-every-lane ()
  (let ((groups (decknix-forge-board-group
                 (list (decknix-fb-test--p 'lock "a")
                       (decknix-fb-test--p 'failed "b")
                       (decknix-fb-test--p 'failed "c")))))
    (should (string-match-p "1 Stale Locks" (decknix-forge-board-summary groups)))
    (should (string-match-p "2 Sync Failed" (decknix-forge-board-summary groups)))))

(ert-deftest decknix-fb--summary-of-nothing-is-nil ()
  (should-not (decknix-forge-board-summary nil)))

(provide 'decknix-forge-board-model-test)
;;; decknix-forge-board-model-test.el ends here
