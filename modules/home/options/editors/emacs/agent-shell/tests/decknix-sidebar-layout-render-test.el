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
  "Every item passes through all four filters, not none of them."
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
               (lambda (_i) t)))
      (should (equal '(3) (mapcar (lambda (i) (alist-get 'number i))
                                  (decknix--layout-feed-items)))))))

(ert-deftest decknix-layout-render--every-filter-is-consulted ()
  "A filter left out of the conjunction is a silent regression; assert each
one can veto on its own."
  (dolist (vetoer '(decknix--hub-requests-attention-visible-p
                    decknix--hub-requests-reviewed-visible-p
                    decknix--hub-requests-draft-visible-p
                    decknix--hub-requests-conflict-visible-p))
    (let ((decknix--hub-reviews '((items . (((repo . "o/a") (number . 1)))))))
      (cl-letf (((symbol-function 'decknix--hub-requests-attention-visible-p)
                 (lambda (_i) t))
                ((symbol-function 'decknix--hub-requests-reviewed-visible-p)
                 (lambda (_i) t))
                ((symbol-function 'decknix--hub-requests-draft-visible-p)
                 (lambda (_i) t))
                ((symbol-function 'decknix--hub-requests-conflict-visible-p)
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

(ert-deftest decknix-layout-render--worktree-glyph-carries-its-own-face ()
  "Dirty must be distinguishable from orphaned by colour, not only shape."
  (let ((dirty (decknix--layout-wt-glyph '(:dirty t)))
        (orphan (decknix--layout-wt-glyph '(:orphan t))))
    (should (eq 'warning (get-text-property 0 'face dirty)))
    (should (eq 'error (get-text-property 0 'face orphan)))))

(ert-deftest decknix-layout-render--dirty-outranks-every-other-condition ()
  "Uncommitted work is the only state here that can be lost."
  (should (eq 'dirty (decknix--layout-wt-condition
                      '(:dirty t :merged t :orphan t :active t)))))

(provide 'decknix-sidebar-layout-render-test)
;;; decknix-sidebar-layout-render-test.el ends here
