;;; decknix-session-board-model-test.el --- Tests for Session Board lanes -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The board's value is entirely in the lanes being right, because `C' then
;; `k' bulk-kills two of them.  A session misfiled into `orphaned' or
;; `not-mine' is work destroyed, so each boundary is pinned here.
;;
;; Classification takes its predicates as arguments so the whole thing stays
;; pure: no hub, no feed, no buffers.

;;; Code:

(require 'ert)
(require 'decknix-session-board-model)

(defun decknix-sb-test--session (name state prs &optional tags ws)
  (list name (or tags '("t")) prs state ws))

;; Feed items keyed the way the board keys them.
(defconst decknix-sb-test--items
  '(("upside#100" . ((repo . "UpsideRealty/upside") (number . 100)
                     (author . "alice") (author_kind . "human")))
    ("upside#200" . ((repo . "UpsideRealty/upside") (number . 200)
                     (author . "dependabot[bot]") (author_kind . "bot")))
    ("upside#300" . ((repo . "UpsideRealty/upside") (number . 300)
                     (author . "bob") (author_kind . "human")))))

(defun decknix-sb-test--item (key) (alist-get key decknix-sb-test--items nil nil #'equal))
(defun decknix-sb-test--mine (item) (not (equal 300 (alist-get 'number item))))
(defun decknix-sb-test--bot (item) (equal "bot" (alist-get 'author_kind item)))

(defun decknix-sb-test--classify (session)
  (decknix-session-board-classify session
                                  #'decknix-sb-test--item
                                  #'decknix-sb-test--mine
                                  #'decknix-sb-test--bot))

;; --- lane boundaries --------------------------------------------------

(ert-deftest decknix-sb--no-review-pr-is-wip ()
  "My own session: nothing to review, so it is work in progress."
  (should (eq 'wip (decknix-sb-test--classify
                    (decknix-sb-test--session "*Claude: mine*" "working" nil)))))

(ert-deftest decknix-sb--human-pr-is-a-human-review ()
  (should (eq 'human-review
             (decknix-sb-test--classify
              (decknix-sb-test--session "*C: a*" "asking" '("upside#100"))))))

(ert-deftest decknix-sb--bot-pr-is-a-bot-review ()
  (should (eq 'bot-review
             (decknix-sb-test--classify
              (decknix-sb-test--session "*C: b*" "asking" '("upside#200"))))))

(ert-deftest decknix-sb--pr-naming-others-is-not-mine ()
  "The case that put five agents on PRs nobody had asked me for."
  (should (eq 'not-mine
             (decknix-sb-test--classify
              (decknix-sb-test--session "*C: c*" "asking" '("upside#300"))))))

(ert-deftest decknix-sb--pr-absent-from-the-feed-is-orphaned ()
  "16 sessions were reviewing PRs that had left both hub queries."
  (should (eq 'orphaned
             (decknix-sb-test--classify
              (decknix-sb-test--session "*C: d*" "ready" '("upside#99999"))))))

(ert-deftest decknix-sb--absent-pr-is-orphaned-before-anything-else ()
  "Every other test needs an item to inspect, so a missing one must be
caught first rather than crashing the predicates."
  (let ((boom (lambda (_i) (error "must not be called"))))
    (should (eq 'orphaned
                (decknix-session-board-classify
                 (decknix-sb-test--session "*C: e*" "ready" '("gone#1"))
                 (lambda (_k) nil) boom boom)))))

(ert-deftest decknix-sb--a-grouped-session-is-classified-once ()
  "A session covering several PRs of one repo is ONE piece of work.
Splitting it across lanes would offer to kill half of it."
  (should (eq 'human-review
             (decknix-sb-test--classify
              (decknix-sb-test--session "*C: group*" "working"
                                        '("upside#100" "upside#200"))))))

;; --- grouping ---------------------------------------------------------

(defconst decknix-sb-test--fleet
  (list (decknix-sb-test--session "*C: human*" "asking" '("upside#100"))
        (decknix-sb-test--session "*C: bot*" "ready" '("upside#200"))
        (decknix-sb-test--session "*C: notmine*" "asking" '("upside#300"))
        (decknix-sb-test--session "*C: orphan*" "ready" '("upside#99999"))
        (decknix-sb-test--session "*C: mine*" "working" nil)))

(defun decknix-sb-test--groups ()
  (decknix-session-board-group decknix-sb-test--fleet
                               #'decknix-sb-test--item
                               #'decknix-sb-test--mine
                               #'decknix-sb-test--bot))

(ert-deftest decknix-sb--lanes-render-work-before-cleanup ()
  "`not-mine' and `orphaned' are last because they are the kill
candidates: everything above is work, everything below is cleanup."
  (should (equal '(human-review bot-review wip not-mine orphaned)
                 (mapcar #'car (decknix-sb-test--groups)))))

(ert-deftest decknix-sb--empty-lanes-are-omitted ()
  "An empty heading is noise on a board meant to show what is there."
  (let ((groups (decknix-session-board-group
                 (list (decknix-sb-test--session "*C: only*" "working" nil))
                 #'decknix-sb-test--item #'decknix-sb-test--mine
                 #'decknix-sb-test--bot)))
    (should (equal '(wip) (mapcar #'car groups)))))

(ert-deftest decknix-sb--no-sessions-is-no-groups ()
  (should-not (decknix-session-board-group nil #'decknix-sb-test--item
                                           #'decknix-sb-test--mine
                                           #'decknix-sb-test--bot)))

(ert-deftest decknix-sb--rows-sort-urgent-first-within-a-lane ()
  (let* ((rows (decknix-session-board-sort-rows
                (list (decknix-session-board-row
                       (decknix-sb-test--session "*b*" "ready" nil) 'wip)
                      (decknix-session-board-row
                       (decknix-sb-test--session "*a*" "asking" nil) 'wip)
                      (decknix-session-board-row
                       (decknix-sb-test--session "*c*" "netfail" nil) 'wip)))))
    (should (equal '("*c*" "*a*" "*b*")
                   (mapcar (lambda (r) (plist-get r :buffer)) rows)))))

(ert-deftest decknix-sb--unknown-state-sorts-last ()
  (should (> (decknix-session-board-state-rank "banana")
             (decknix-session-board-state-rank "closing"))))

;; --- identity and marks ----------------------------------------------

(ert-deftest decknix-sb--row-key-is-the-buffer-name ()
  "Marks are keyed on it, so a refresh between marking and killing must not
shift a mark onto a different session."
  (let ((row (decknix-session-board-row
              (decknix-sb-test--session "*C: x*" "ready" '("upside#100")) 'human-review)))
    (should (equal "*C: x*" (decknix-session-board-row-key row)))))

;; --- cleanup lanes ----------------------------------------------------

(ert-deftest decknix-sb--only-not-mine-and-orphaned-are-cleanup ()
  "`C' marks these for bulk kill, so the set must not creep."
  (should (equal '(not-mine orphaned) (decknix-session-board-killable-lanes)))
  (dolist (lane '(human-review bot-review wip))
    (should-not (decknix-session-board-killable-p (list :lane lane))))
  (dolist (lane '(not-mine orphaned))
    (should (decknix-session-board-killable-p (list :lane lane)))))

;; --- labels -----------------------------------------------------------

(ert-deftest decknix-sb--row-shows-the-pr-not-the-buffer-name ()
  "For a review session the PR IS the identity; the buffer naming convention
has changed twice."
  (let ((row (decknix-session-board-row
              (decknix-sb-test--session "*Claude: auto/#100/upside/review*"
                                        "asking" '("upside#100"))
              'human-review)))
    (should (string-match-p "upside#100"
                            (decknix-session-board-row-label row nil 60)))))

(ert-deftest decknix-sb--wip-row-shows-the-stripped-session-name ()
  (let ((row (decknix-session-board-row
              (decknix-sb-test--session "*Claude: decknix/nurturecloud*" "working" nil)
              'wip)))
    (should (string-match-p "decknix/nurturecloud"
                            (decknix-session-board-row-label row nil 60)))
    (should-not (string-match-p "Claude"
                                (decknix-session-board-row-label row nil 60)))))

(ert-deftest decknix-sb--mark-is-visible-in-the-label ()
  (let ((row (decknix-session-board-row
              (decknix-sb-test--session "*C: x*" "ready" nil) 'wip)))
    (should (string-prefix-p "*" (decknix-session-board-row-label row t 60)))
    (should (string-prefix-p " " (decknix-session-board-row-label row nil 60)))))

(ert-deftest decknix-sb--labels-fit-the-given-width ()
  "A wrapped row breaks the one-line-per-session property marking relies on."
  (dolist (w '(40 60 100))
    (dolist (row (decknix-sb-test--all-rows))
      (should (= w (string-width (decknix-session-board-row-label row nil w)))))))

(defun decknix-sb-test--all-rows ()
  (apply #'append (mapcar #'cdr (decknix-sb-test--groups))))

(ert-deftest decknix-sb--lane-header-fits-and-names-the-lane ()
  (let* ((g (car (decknix-sb-test--groups)))
         (h (decknix-session-board-lane-header (car g) (cdr g) 70)))
    (should (= 70 (string-width h)))
    (should (string-match-p "Human Reviews" h))))

(ert-deftest decknix-sb--every-lane-has-a-title-and-a-hint ()
  "A lane the user cannot explain is one they will not trust enough to
bulk-kill from."
  (dolist (lane decknix-session-board-lanes)
    (should (stringp (decknix-session-board-lane-title lane)))
    (should (not (string-empty-p (decknix-session-board-lane-hint lane))))))

(ert-deftest decknix-sb--summary-counts-each-lane ()
  (let ((s (decknix-session-board-summary (decknix-sb-test--groups))))
    (should (string-match-p "1 Human Reviews" s))
    (should (string-match-p "1 Orphaned" s)))
  (should-not (decknix-session-board-summary nil)))

(provide 'decknix-session-board-model-test)
;;; decknix-session-board-model-test.el ends here
