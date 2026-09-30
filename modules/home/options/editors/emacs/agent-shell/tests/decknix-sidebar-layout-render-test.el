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

(provide 'decknix-sidebar-layout-render-test)
;;; decknix-sidebar-layout-render-test.el ends here
