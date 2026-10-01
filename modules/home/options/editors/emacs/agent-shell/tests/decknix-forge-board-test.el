;;; decknix-forge-board-test.el --- Forge Board actions -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The render is `insert', so what is pinned here is what decides WHICH
;; repos a verb hits: the marked-set-versus-point rule, and the lane
;; confinement of `clear locks'.
;;
;; Marks-win-over-point is not cosmetic.  These verbs run against every
;; marked row at once, so falling back to point while marks exist would act
;; on one repo when several were selected, or on the wrong one if the cursor
;; moved after marking.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-forge-board)

(defun decknix-fbb-test--row (kind name &optional path)
  (decknix-forge-board-row
   (list :kind kind :name name :path (or path (concat "/repos/" name))
         :detail "d")))

;; --- which rows a verb applies to -------------------------------------

(ert-deftest decknix-fbb--marks-win-over-point ()
  "Acting on point while marks exist would clear one lock when several
repos were selected."
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups
         (list (cons 'lock (list (decknix-fbb-test--row 'lock "a")
                                 (decknix-fbb-test--row 'lock "b"))))))
    (puthash "/repos/b" t decknix-forge-board--marks)
    (cl-letf (((symbol-function 'decknix-forge-board--row-at-point)
               (lambda () (decknix-fbb-test--row 'lock "a"))))
      (should (equal '("b")
                     (mapcar (lambda (r) (plist-get r :name))
                             (decknix-forge-board--targets)))))))

(ert-deftest decknix-fbb--point-is-used-when-nothing-is-marked ()
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups
         (list (cons 'lock (list (decknix-fbb-test--row 'lock "a"))))))
    (cl-letf (((symbol-function 'decknix-forge-board--row-at-point)
               (lambda () (decknix-fbb-test--row 'lock "a"))))
      (should (equal '("a")
                     (mapcar (lambda (r) (plist-get r :name))
                             (decknix-forge-board--targets)))))))

(ert-deftest decknix-fbb--nothing-marked-and-not-on-a-row-is-no-targets ()
  "A verb must refuse rather than guess."
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups nil))
    (cl-letf (((symbol-function 'decknix-forge-board--row-at-point)
               (lambda () nil)))
      (should-not (decknix-forge-board--targets)))))

(ert-deftest decknix-fbb--a-mark-on-a-fixed-repo-does-not-resurrect-it ()
  "Marks are resolved against the RENDERED set: the repo may have been
fixed by an earlier verb in the same session."
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups
         (list (cons 'lock (list (decknix-fbb-test--row 'lock "a"))))))
    (puthash "/repos/gone" t decknix-forge-board--marks)
    (should-not (decknix-forge-board--marked-rows))))

(ert-deftest decknix-fbb--marks-are-keyed-on-path ()
  "Same repo name, two worktree directories: a name key would act on
whichever the re-render ordered first."
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups
         (list (cons 'lock (list (decknix-fbb-test--row 'lock "upside" "/one/upside")
                                 (decknix-fbb-test--row 'lock "upside" "/two/upside"))))))
    (puthash "/two/upside" t decknix-forge-board--marks)
    (should (equal '("/two/upside")
                   (mapcar (lambda (r) (plist-get r :path))
                           (decknix-forge-board--marked-rows))))))

;; --- lane confinement -------------------------------------------------

(ert-deftest decknix-fbb--clearing-skips-non-lock-rows-rather-than-refusing ()
  "A mark spanning a whole sweep should not have to be pruned by hand
before the one verb that applies to part of it will run."
  (let ((rows (list (decknix-fbb-test--row 'lock "a")
                    (decknix-fbb-test--row 'dirty "b")
                    (decknix-fbb-test--row 'failed "c"))))
    (should (equal '("a")
                   (mapcar (lambda (r) (plist-get r :name))
                           (decknix-forge-board-filter-clearable rows))))))

(ert-deftest decknix-fbb--clearing-nothing-clearable-is-an-error-not-a-noop ()
  "A silent no-op would read as \"the locks were cleared\"."
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups
         (list (cons 'dirty (list (decknix-fbb-test--row 'dirty "b"))))))
    (puthash "/repos/b" t decknix-forge-board--marks)
    (should-error (decknix-forge-board-clear-locks) :type 'user-error)))

;; --- completion callback ----------------------------------------------

(ert-deftest decknix-fbb--reports-once-not-once-per-repo ()
  "Each verb is async per repo; reporting per completion would print ten
messages for one action."
  (let* ((refreshed 0)
         (done nil))
    (cl-letf (((symbol-function 'decknix-repo-sync-refresh)
               (lambda (&optional cb) (setq refreshed (1+ refreshed))
                 (when cb (funcall cb)))))
      (setq done (decknix-forge-board--after-each 3 "test"))
      (funcall done)
      (should (= 0 refreshed))
      (funcall done)
      (should (= 0 refreshed))
      (funcall done)
      (should (= 1 refreshed)))))

(provide 'decknix-forge-board-test)
;;; decknix-forge-board-test.el ends here
