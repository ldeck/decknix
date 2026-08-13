;;; decknix-hub-people-test.el --- Tests for hub PR people helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-people "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the pure lookup + formatter behind the sidebar "People"
;; row action.

;;; Code:

(require 'ert)
(require 'decknix-hub-people)

;; -- find-item -----------------------------------------------------

(defun decknix-people-test--reviews ()
  "A couple of Reviews items."
  (list '((repo . "o/a") (number . 1) (title . "A"))
        '((repo . "o/b") (number . 2) (title . "B"))))

(defun decknix-people-test--wip ()
  "A WIP repos list."
  (list '((repo . "o/c")
          (prs . (((number . 7) (title . "C7"))
                  ((number . 8) (title . "C8")))))))

(ert-deftest decknix-people/find--in-reviews ()
  (let ((it (decknix--hub-people-find-item
             "o/b" 2 (decknix-people-test--reviews) (decknix-people-test--wip))))
    (should (equal (alist-get 'title it) "B"))))

(ert-deftest decknix-people/find--in-wip ()
  (let ((it (decknix--hub-people-find-item
             "o/c" 8 (decknix-people-test--reviews) (decknix-people-test--wip))))
    (should (equal (alist-get 'title it) "C8"))))

(ert-deftest decknix-people/find--absent ()
  (should (null (decknix--hub-people-find-item
                 "o/z" 99 (decknix-people-test--reviews) (decknix-people-test--wip))))
  ;; right repo, wrong number
  (should (null (decknix--hub-people-find-item
                 "o/c" 99 (decknix-people-test--reviews) (decknix-people-test--wip)))))

;; -- as-list normalisation -----------------------------------------

(ert-deftest decknix-people/as-list ()
  (should (equal (decknix--hub-people--as-list nil) nil))
  (should (equal (decknix--hub-people--as-list "x") '("x")))
  (should (equal (decknix--hub-people--as-list ["a" "b"]) '("a" "b")))
  (should (equal (decknix--hub-people--as-list '("a" "b")) '("a" "b"))))

;; -- render --------------------------------------------------------

(ert-deftest decknix-people/render ()
  (should (equal (decknix--hub-people--render nil) "—"))
  (should (equal (decknix--hub-people--render '("alice" "bob"))
                 "@alice  @bob"))
  ;; team entries render specially
  (should (equal (decknix--hub-people--render '("alice" "team:nc-platform"))
                 "@alice  @nc-platform (team)")))

;; -- lines ---------------------------------------------------------

(ert-deftest decknix-people/lines--full ()
  (let* ((item '((repo . "o/r") (number . 42) (title . "T")
                 (authors . ["alice" "bob"])
                 (requested_reviewers . ["carol" "team:plat"])
                 (approvers . ["dave"])
                 (blockers . ["erin"])))
         (lines (decknix--hub-people-lines item)))
    (should (equal (nth 0 lines) "o/r#42  T"))
    (should (equal (nth 1 lines) "  authors:    @alice  @bob"))
    (should (equal (nth 2 lines) "  requested:  @carol  @plat (team)"))
    (should (equal (nth 3 lines) "  approved:   @dave"))
    (should (equal (nth 4 lines) "  blocking:   @erin"))))

(ert-deftest decknix-people/lines--falls-back-to-singular-author ()
  "Old data without `authors' uses the singular `author'."
  (let ((lines (decknix--hub-people-lines
                '((repo . "o/r") (number . 1) (author . "solo")))))
    (should (equal (nth 1 lines) "  authors:    @solo"))
    ;; empty reviewer sets render as em-dash
    (should (equal (nth 2 lines) "  requested:  —"))
    (should (equal (nth 3 lines) "  approved:   —"))
    (should (equal (nth 4 lines) "  blocking:   —"))))

(ert-deftest decknix-people/lines--nil-item ()
  (should (null (decknix--hub-people-lines nil))))

(provide 'decknix-hub-people-test)
;;; decknix-hub-people-test.el ends here
