;;; decknix-session-board-test.el --- Tests for the Session Board buffer -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The render is `insert', so what is pinned here is what decides WHICH
;; sessions an action hits: the marked-set-versus-point rule, and the
;; bot/human split that puts a session in a lane.
;;
;; `k' terminates agents, so marks-win-over-point is not cosmetic.  Falling
;; back to point while marks exist would kill one session when the user had
;; selected several, or the wrong one if the cursor moved after marking.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-session-board)

(defvar decknix--hub-reviews nil)

(defun decknix-sbb-test--row (name lane &optional state)
  (list :lane lane :buffer name :state (or state "ready") :prs nil))

;; --- which rows an action applies to ----------------------------------

(ert-deftest decknix-sbb--marks-win-over-point ()
  "`k' ends agents: acting on point while marks exist would kill one session
when several were selected."
  (let ((decknix-session-board--marks (make-hash-table :test 'equal))
        (decknix-session-board--groups
         (list (cons 'wip (list (decknix-sbb-test--row "*a*" 'wip)
                                (decknix-sbb-test--row "*b*" 'wip))))))
    (puthash "*b*" t decknix-session-board--marks)
    (cl-letf (((symbol-function 'decknix-session-board--row-at-point)
               (lambda () (decknix-sbb-test--row "*a*" 'wip))))
      (should (equal '("*b*")
                     (mapcar (lambda (r) (plist-get r :buffer))
                             (decknix-session-board--targets)))))))

(ert-deftest decknix-sbb--point-is-used-when-nothing-is-marked ()
  (let ((decknix-session-board--marks (make-hash-table :test 'equal))
        (decknix-session-board--groups
         (list (cons 'wip (list (decknix-sbb-test--row "*a*" 'wip))))))
    (cl-letf (((symbol-function 'decknix-session-board--row-at-point)
               (lambda () (decknix-sbb-test--row "*a*" 'wip))))
      (should (equal '("*a*")
                     (mapcar (lambda (r) (plist-get r :buffer))
                             (decknix-session-board--targets)))))))

(ert-deftest decknix-sbb--nothing-marked-and-not-on-a-row-is-no-targets ()
  "An action must refuse rather than guess."
  (let ((decknix-session-board--marks (make-hash-table :test 'equal))
        (decknix-session-board--groups nil))
    (cl-letf (((symbol-function 'decknix-session-board--row-at-point)
               (lambda () nil)))
      (should-not (decknix-session-board--targets)))))

(ert-deftest decknix-sbb--marked-rows-come-from-the-rendered-set ()
  "A mark for a session that is no longer rendered must not resurrect it --
the session may have exited since."
  (let ((decknix-session-board--marks (make-hash-table :test 'equal))
        (decknix-session-board--groups
         (list (cons 'wip (list (decknix-sbb-test--row "*a*" 'wip))))))
    (puthash "*gone*" t decknix-session-board--marks)
    (should-not (decknix-session-board--marked-rows))))

;; --- the item table ---------------------------------------------------

(ert-deftest decknix-sbb--item-table-keys-match-session-pr-keys ()
  "Sessions record `upside#100'; the feed carries `UpsideRealty/upside'.
If these do not meet, every session reads as orphaned and the board offers
to kill the lot."
  (let ((decknix--hub-reviews
         '((items . (((repo . "UpsideRealty/upside") (number . 100)))))))
    (should (gethash "upside#100" (decknix-session-board--item-table)))))

(ert-deftest decknix-sbb--item-table-is-empty-before-the-first-poll ()
  (let ((decknix--hub-reviews nil))
    (should (= 0 (hash-table-count (decknix-session-board--item-table))))))

;; --- lane colouring ---------------------------------------------------

(ert-deftest decknix-sbb--cleanup-lanes-are-the-only-highlighted-ones ()
  "The warning face on a lane heading is the signal that bulk-killing it is
expected; it must not appear on lanes holding real work."
  (dolist (lane '(stale not-mine orphaned))
    (should (memq lane (decknix-session-board-killable-lanes))))
  (dolist (lane '(human-review bot-review wip))
    (should-not (memq lane (decknix-session-board-killable-lanes)))))


;; --- purging obsolete sessions ---------------------------------------

(ert-deftest decknix-sbb--obsolete-rows-are-exactly-the-cleanup-lanes ()
  "Shared with the board rather than re-derived, so a one-shot purge and
the board can never disagree about what is obsolete."
  (cl-letf (((symbol-function 'decknix-session-board--compute)
             (lambda ()
               (list (cons 'human-review (list (decknix-sbb-test--row "*h*" 'human-review)))
                     (cons 'wip (list (decknix-sbb-test--row "*w*" 'wip)))
                     (cons 'stale (list (decknix-sbb-test--row "*s*" 'stale)))
                     (cons 'orphaned (list (decknix-sbb-test--row "*o*" 'orphaned)))))))
    (should (equal '("*s*" "*o*")
                   (mapcar (lambda (r) (plist-get r :buffer))
                           (decknix-session-board-obsolete-rows))))))

(ert-deftest decknix-sbb--real-work-is-never-obsolete ()
  "The lanes above cleanup are work; purging them would end sessions the
user is relying on."
  (cl-letf (((symbol-function 'decknix-session-board--compute)
             (lambda ()
               (list (cons 'human-review (list (decknix-sbb-test--row "*h*" 'human-review)))
                     (cons 'bot-review (list (decknix-sbb-test--row "*b*" 'bot-review)))
                     (cons 'wip (list (decknix-sbb-test--row "*w*" 'wip)))))))
    (should-not (decknix-session-board-obsolete-rows))))

(ert-deftest decknix-sbb--purge-declined-ends-nothing ()
  "The prompt is the last gate before ending sessions the user is not
looking at."
  (let ((ended nil))
    (cl-letf (((symbol-function 'decknix-session-board--compute)
               (lambda () (list (cons 'orphaned
                                      (list (decknix-sbb-test--row "*o*" 'orphaned))))))
              ((symbol-function 'with-help-window) (lambda (&rest _) nil))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
              ((symbol-function 'decknix-session-lifecycle-quit)
               (lambda (&rest _) (setq ended t))))
      (decknix-session-purge-obsolete)
      (should-not ended))))

(ert-deftest decknix-sbb--purge-with-nothing-obsolete-does-not-prompt ()
  "A prompt offering to end zero sessions trains the user to confirm
without reading."
  (cl-letf (((symbol-function 'decknix-session-board--compute) (lambda () nil))
            ((symbol-function 'yes-or-no-p)
             (lambda (&rest _) (error "must not prompt"))))
    (decknix-session-purge-obsolete)))

(ert-deftest decknix-sbb--purge-summary-tallies-each-lane ()
  (let ((rows (list (decknix-sbb-test--row "*a*" 'orphaned)
                    (decknix-sbb-test--row "*b*" 'orphaned)
                    (decknix-sbb-test--row "*c*" 'stale))))
    (let ((summary (decknix-session-board--obsolete-summary rows)))
      (should (string-match-p "1 stale" summary))
      (should (string-match-p "2 orphaned" summary)))))

(provide 'decknix-session-board-test)
;;; decknix-session-board-test.el ends here
