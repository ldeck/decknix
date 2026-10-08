;;; decknix-sidebar-layout-render-test.el --- Tests for the layout render -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The render is mostly `insert', so what is worth pinning is the part that
;; can silently change meaning: the feed items the Reviews section folds in.
;;
;; Requests used to be its own section behind four visibility filters.
;; Folding it into Reviews without reapplying them would re-show every
;; draft, conflicted and already-reviewed PR those filters exist to hide --
;; a regression that looks like a feature ("more rows!") and would be hard
;; to attribute later.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-sidebar-layout-render)

;; The hub bulk module owns the real special variable, but the isolated
;; layout-render package tests do not load it. A value is required here:
;; a bare `(defvar decknix--hub-reviews)' is only a compiler hint, so the
;; lexical `let' fixtures would never reach the renderer's dynamic read.
(defvar decknix--hub-reviews nil)

(ert-deftest decknix-layout-render--feed-items-obey-the-request-filters ()
  "Every item passes through all five filters, not none of them."
  (let ((decknix--hub-reviews
         '((items . (((repo . "o/a") (number . 1))
                     ((repo . "o/b") (number . 2))
                     ((repo . "o/c") (number . 3)))))))
    (cl-letf (((symbol-function 'decknix--hub-requests-attention-visible-p)
               (lambda (i) (not (equal 1 (alist-get 'number i)))))
              ((symbol-function 'decknix--hub-requests-reviewed-visible-p)
               (lambda (i) (not (equal 2 (alist-get 'number i)))))
              ((symbol-function 'decknix--hub-requests-draft-visible-p)
               (lambda (_i) t))
              ((symbol-function 'decknix--hub-requests-conflict-visible-p)
               (lambda (_i) t))
              ((symbol-function 'decknix--hub-requests-not-mine-visible-p)
               (lambda (_i) t)))
      (should (equal '(3) (mapcar (lambda (i) (alist-get 'number i))
                                  (decknix--layout-feed-items)))))))

(ert-deftest decknix-layout-render--every-filter-is-consulted ()
  "A filter left out of the conjunction is a silent regression; assert each
one can veto on its own."
  (dolist (vetoer '(decknix--hub-requests-attention-visible-p
                    decknix--hub-requests-reviewed-visible-p
                    decknix--hub-requests-draft-visible-p
                    decknix--hub-requests-conflict-visible-p
                    decknix--hub-requests-not-mine-visible-p))
    (let ((decknix--hub-reviews '((items . (((repo . "o/a") (number . 1)))))))
      (cl-letf (((symbol-function 'decknix--hub-requests-attention-visible-p)
                 (lambda (_i) t))
                ((symbol-function 'decknix--hub-requests-reviewed-visible-p)
                 (lambda (_i) t))
                ((symbol-function 'decknix--hub-requests-draft-visible-p)
                 (lambda (_i) t))
                ((symbol-function 'decknix--hub-requests-conflict-visible-p)
                 (lambda (_i) t))
                ((symbol-function 'decknix--hub-requests-not-mine-visible-p)
                 (lambda (_i) t)))
        (should (= 1 (length (decknix--layout-feed-items))))
        (cl-letf (((symbol-function vetoer) (lambda (_i) nil)))
          (should-not (decknix--layout-feed-items)))))))

(ert-deftest decknix-layout-render--no-feed-is-empty-not-an-error ()
  "The sidebar renders before the first hub poll returns."
  (let ((decknix--hub-reviews nil))
    (should-not (decknix--layout-feed-items))))

;; --- expansion state --------------------------------------------------

(ert-deftest decknix-layout-render--expansion-round-trips-through-a-file ()
  "Expansion has to survive a restart, like the other sidebar toggles."
  (let* ((tmp (make-temp-file "decknix-layout" nil ".el"))
         (decknix--layout-state-file tmp)
         (decknix--layout-expanded (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (puthash "upside" t decknix--layout-expanded)
          (puthash "metabase" t decknix--layout-expanded)
          (decknix--layout-save-state)
          (clrhash decknix--layout-expanded)
          (should-not (decknix--layout-expanded-p "upside"))
          (decknix--layout-load-state)
          (should (decknix--layout-expanded-p "upside"))
          (should (decknix--layout-expanded-p "metabase"))
          (should-not (decknix--layout-expanded-p "never-expanded")))
      (delete-file tmp))))

(ert-deftest decknix-layout-render--collapsed-repos-are-not-persisted ()
  "Only the expanded set is written, so a collapse actually sticks."
  (let* ((tmp (make-temp-file "decknix-layout" nil ".el"))
         (decknix--layout-state-file tmp)
         (decknix--layout-expanded (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (puthash "upside" t decknix--layout-expanded)
          (remhash "upside" decknix--layout-expanded)
          (decknix--layout-save-state)
          (decknix--layout-load-state)
          (should-not (decknix--layout-expanded-p "upside")))
      (delete-file tmp))))

(ert-deftest decknix-layout-render--missing-state-file-is-harmless ()
  (let ((decknix--layout-state-file "/nonexistent/dir/state.el")
        (decknix--layout-expanded (make-hash-table :test 'equal)))
    (should-not (decknix--layout-load-state))
    (should-not (decknix--layout-expanded-p "upside"))))

;; --- session name shortening ------------------------------------------

(ert-deftest decknix-layout-render--strips-the-agent-wrapper ()
  "Row width is 48 columns; `*Claude: ' is nine of them spent on nothing."
  (should (equal "decknix/nurturecloud"
                 (decknix--layout-short-name "*Claude: decknix/nurturecloud*")))
  (should (equal "pilot/us" (decknix--layout-short-name "*Pi: pilot/us*")))
  (should (equal "" (decknix--layout-short-name nil))))


;; --- row width and colour --------------------------------------------

(ert-deftest decknix-layout-render--width-comes-from-the-sidebar-window ()
  "`window-width' with no argument answers for whichever window is selected
when the render runs.  Measured 95 against the sidebar's 48, which padded
every row 47 columns too wide and pushed its right-hand value out of view."
  (let ((buf (generate-new-buffer " sb")))
    (unwind-protect
        (with-current-buffer buf
          (let ((win (display-buffer-in-side-window buf '((side . left)))))
            (should (window-live-p win))
            (with-selected-window win
              (ignore-errors (window-resize win (- 40 (window-width win)) t t)))
            ;; Selected window is NOT the sidebar here, which is the case
            ;; that broke: the bare call would answer for the other one.
            (should (= (window-width win) (decknix--layout-sidebar-width)))))
      (ignore-errors (delete-window (get-buffer-window buf)))
      (kill-buffer buf))))

(ert-deftest decknix-layout-render--width-falls-back-when-undisplayed ()
  "A render into a buffer no window is showing must not error."
  (with-temp-buffer
    (should (integerp (decknix--layout-sidebar-width)))))

(ert-deftest decknix-layout-render--pr-row-is-not-one-uniform-face ()
  "The whole row used to be painted a single severity face, which is what
made draft-versus-conflicting and human-versus-bot unreadable without
decoding the glyph shapes."
  (let* ((pr (list :number 240 :repo "upside" :branch "b"
                   :pr '((title . "ship scenario spec") (draft . t)
                         (author_kind . "human")
                         (ci . ((status . "pass"))))))
         (row (decknix--layout-pr-row pr 48))
         (faces (let (acc (i 0))
                  (while (< i (length row))
                    (push (get-text-property i 'face row) acc)
                    (setq i (1+ i)))
                  (delete-dups acc))))
    (should (> (length faces) 1))))

(ert-deftest decknix-layout-render--pr-row-prefers-the-title-over-the-branch ()
  (let ((pr (list :number 240 :branch "enhancement/HX-1039-envelope"
                  :pr '((title . "ship scenario spec")))))
    (should (string-match-p "ship scenario spec"
                            (decknix--layout-pr-row pr 60)))))

(ert-deftest decknix-layout-render--pr-row-falls-back-to-the-branch ()
  "A feed item with no title must still identify its row."
  (let ((pr (list :number 240 :branch "my-branch" :pr nil)))
    (should (string-match-p "my-branch" (decknix--layout-pr-row pr 60)))))

(ert-deftest decknix-layout-render--pr-row-never-exceeds-its-width ()
  "The glyphs are the part worth keeping when space runs out, so the title
truncates rather than pushing them off the end."
  (let ((pr (list :number 12345 :branch "b"
                  :pr (list (cons 'title (make-string 300 ?x))))))
    (dolist (w '(24 32 48 80))
      (should (<= (string-width (decknix--layout-pr-row pr w)) w)))))

(ert-deftest decknix-layout-render--a-worktree-is-a-hollow-shape ()
  "Hollow, because a worktree is the stage before a PR.  Dotted while
nothing is known about its build -- which is every worktree today, since
the audit records no build status at all."
  (should (equal "◌" (substring-no-properties
                      (decknix--layout-wt-glyph '(:branch "b"))))))

(ert-deftest decknix-layout-render--a-worktree-is-grey-until-a-build-is-known ()
  "Grey means nothing reported, which is honest: nothing runs or records
a per-worktree build."
  (should (eq 'shadow (get-text-property
                       0 'face (decknix--layout-wt-glyph '(:branch "b"))))))

(ert-deftest decknix-layout-render--a-merged-worktree-is-a-square ()
  (should (equal "■" (substring-no-properties
                      (decknix--layout-wt-glyph '(:merged t))))))

(ert-deftest decknix-layout-render--dirty-and-orphan-are-markers-not-the-shape ()
  "Both can be true at once.  As a single glyph one hid the other, and
uncommitted work is the state here that can actually be lost; as separate
markers both are visible."
  (let ((m (substring-no-properties
            (decknix--layout-wt-markers '(:dirty t :orphan t)))))
    (should (string-match-p "✎" m))
    (should (string-match-p "⑂" m))))

(ert-deftest decknix-layout-render--a-clean-worktree-has-no-markers ()
  (should (equal "" (substring-no-properties
                     (decknix--layout-wt-markers '(:branch "b"))))))

(ert-deftest decknix-layout-render--dirty-is-amber-and-orphan-is-red ()
  "They mean different things and must not read alike."
  (let ((d (decknix--layout-wt-markers '(:dirty t)))
        (o (decknix--layout-wt-markers '(:orphan t))))
    (should (eq 'warning (get-text-property 0 'face d)))
    (should (eq 'error (get-text-property 0 'face o)))))

;; --- the unattended section's summary rows ---------------------------
;;
;; The repo rows this section replaced carried NO text property, so RET on
;; one did nothing.  A count row that cannot reach its own remedy repeats
;; that in a smaller space, which is why the property is pinned here.

(defun decknix-lr-test--render-dormant (dormant)
  "Return the rendered Unattended section for DORMANT."
  (with-temp-buffer
    (cl-letf (((symbol-function 'decknix--sidebar-render-section-header)
               (lambda (title &rest _) (insert title "\n"))))
      (decknix--layout-render-dormant 0 48 dormant))
    (buffer-string)))

(ert-deftest decknix-layout-render--orphan-count-can-reach-its-remedy ()
  (let* ((out (decknix-lr-test--render-dormant
               (list :worktrees (list (list :branch "a" :orphan t)))))
         (pos (string-match "orphaned" out)))
    (should pos)
    (should (get-text-property pos 'decknix-layout-orphan-prune out))))

(ert-deftest decknix-layout-render--a-clean-worktree-gets-no-row ()
  "Only the counted summary, so the section cannot fill up with rows that
hold no decision."
  (let ((out (decknix-lr-test--render-dormant
              (list :worktrees (list (list :branch "quiet-branch"))))))
    (should-not (string-match-p "quiet-branch" out))
    (should (string-match-p "1 quiet" out))))

(ert-deftest decknix-layout-render--a-dirty-worktree-is-named ()
  "Uncommitted work is the one thing here that can be lost, so it is never
reduced to a count."
  (let ((out (decknix-lr-test--render-dormant
              (list :worktrees (list (list :branch "has-work" :dirty t))))))
    (should (string-match-p "has-work" out))))

(ert-deftest decknix-layout-render--nothing-unattended-renders-nothing ()
  (should (equal "" (decknix-lr-test--render-dormant nil))))

(ert-deftest decknix-layout-render--the-limit-bounds-rows-and-names-the-tail ()
  (let* ((decknix-sidebar-layout-dormant-limit 2)
         (out (decknix-lr-test--render-dormant
               (list :worktrees (list (list :branch "w1" :dirty t)
                                      (list :branch "w2" :dirty t)
                                      (list :branch "w3" :dirty t))))))
    (should (string-match-p "w1" out))
    (should-not (string-match-p "w3" out))
    (should (string-match-p "1 more over the limit" out))))

(provide 'decknix-sidebar-layout-render-test)
;;; decknix-sidebar-layout-render-test.el ends here
