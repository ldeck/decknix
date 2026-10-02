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


;; --- the irreversible verb is gated harder ---------------------------

(ert-deftest decknix-fbb--reset-requires-a-typed-confirmation ()
  "A `y' sits next to the keys just pressed; this verb must not be
reachable by muscle memory."
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups
         (list (cons 'dirty (list (decknix-fbb-test--row 'dirty "a")))))
        (reset nil))
    (puthash "/repos/a" t decknix-forge-board--marks)
    (cl-letf (((symbol-function 'decknix-repo-sync-read-reset-target)
               (lambda (&rest _) 'local))
              ((symbol-function 'read-string) (lambda (&rest _) "y"))
              ((symbol-function 'decknix-repo-sync-reset-hard)
               (lambda (&rest _) (setq reset t))))
      (decknix-forge-board-reset-hard)
      (should-not reset))))

(ert-deftest decknix-fbb--reset-proceeds-on-the-exact-word ()
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups
         (list (cons 'dirty (list (decknix-fbb-test--row 'dirty "a")))))
        (reset 0))
    (puthash "/repos/a" t decknix-forge-board--marks)
    (cl-letf (((symbol-function 'decknix-repo-sync-read-reset-target)
               (lambda (&rest _) 'local))
              ((symbol-function 'read-string) (lambda (&rest _) "reset"))
              ((symbol-function 'decknix-repo-sync-refresh)
               (lambda (&optional cb) (when cb (funcall cb))))
              ((symbol-function 'decknix-repo-sync-reset-hard)
               (lambda (&rest _) (setq reset (1+ reset)))))
      (decknix-forge-board-reset-hard)
      (should (= 1 reset)))))

(ert-deftest decknix-fbb--reset-names-the-repos-in-the-prompt ()
  "Acting on marks means the user cannot see from the cursor what is about
to be destroyed."
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups
         (list (cons 'dirty (list (decknix-fbb-test--row 'dirty "alpha")
                                  (decknix-fbb-test--row 'dirty "beta")))))
        (prompt ""))
    (puthash "/repos/alpha" t decknix-forge-board--marks)
    (puthash "/repos/beta" t decknix-forge-board--marks)
    (cl-letf (((symbol-function 'decknix-repo-sync-read-reset-target)
               (lambda (&rest _) 'local))
              ((symbol-function 'read-string)
               (lambda (p &rest _) (setq prompt p) "no")))
      (decknix-forge-board-reset-hard)
      (should (string-match-p "alpha" prompt))
      (should (string-match-p "beta" prompt)))))

(ert-deftest decknix-fbb--reset-refuses-when-nothing-is-resettable ()
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups
         (list (cons 'diverged (list (decknix-fbb-test--row 'diverged "a"))))))
    (puthash "/repos/a" t decknix-forge-board--marks)
    (should-error (decknix-forge-board-reset-hard) :type 'user-error)))


(ert-deftest decknix-fbb--declining-the-target-aborts-the-reset ()
  "Quitting the ref prompt must not fall through to a default and destroy
work the user was in the middle of deciding about."
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups
         (list (cons 'dirty (list (decknix-fbb-test--row 'dirty "a")))))
        (reset nil))
    (puthash "/repos/a" t decknix-forge-board--marks)
    (cl-letf (((symbol-function 'decknix-repo-sync-read-reset-target)
               (lambda (&rest _) nil))
              ((symbol-function 'read-string)
               (lambda (&rest _) (error "must not reach the confirm")))
              ((symbol-function 'decknix-repo-sync-reset-hard)
               (lambda (&rest _) (setq reset t))))
      (decknix-forge-board-reset-hard)
      (should-not reset))))

(ert-deftest decknix-fbb--the-chosen-target-reaches-the-verb ()
  "Choosing origin must actually reset to origin; passing `local' anyway
would silently keep commits the user asked to discard."
  (let ((decknix-forge-board--marks (make-hash-table :test 'equal))
        (decknix-forge-board--groups
         (list (cons 'dirty (list (decknix-fbb-test--row 'dirty "a")))))
        (got nil))
    (puthash "/repos/a" t decknix-forge-board--marks)
    (cl-letf (((symbol-function 'decknix-repo-sync-read-reset-target)
               (lambda (&rest _) 'origin))
              ((symbol-function 'read-string) (lambda (&rest _) "reset"))
              ((symbol-function 'decknix-repo-sync-refresh)
               (lambda (&optional cb) (when cb (funcall cb))))
              ((symbol-function 'decknix-repo-sync-reset-hard)
               (lambda (_p _d target) (setq got target))))
      (decknix-forge-board-reset-hard)
      (should (eq 'origin got)))))

(provide 'decknix-forge-board-test)
;;; decknix-forge-board-test.el ends here
