;;; decknix-auto-review-test.el --- Tests for decknix-auto-review -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-auto-review "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the intended behaviour of the pure helper layer in
;; `decknix-auto-review' — the 4-state cycle, the state labels, the
;; per-item dispatch-action classifier (state x bot x mentioned), the
;; per-workspace command resolver, and the dedup-key helpers.  These are
;; specification-first tests: they describe the contract the dispatch
;; side-effects (wired in the heredoc) rely on.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-auto-review)

;; -- State cycle ----------------------------------------------------

(ert-deftest decknix-auto-review/next-state-cycles-all-four ()
  "`next-state' walks off -> bot -> human -> any -> off."
  (should (eq 'bot   (decknix-auto-review-next-state 'off)))
  (should (eq 'human (decknix-auto-review-next-state 'bot)))
  (should (eq 'any   (decknix-auto-review-next-state 'human)))
  (should (eq 'off   (decknix-auto-review-next-state 'any))))

(ert-deftest decknix-auto-review/next-state-unknown-resets-to-off ()
  "An unrecognised state resets the cycle to `off'."
  (should (eq 'off (decknix-auto-review-next-state 'garbage)))
  (should (eq 'off (decknix-auto-review-next-state nil))))

;; -- State labels ---------------------------------------------------

(ert-deftest decknix-auto-review/state-label-per-state ()
  "Each state has a stable short label; the mention qualifier is
visible on every active state."
  (should (string= "off"      (decknix-auto-review-state-label 'off)))
  (should (string= "bot+@"    (decknix-auto-review-state-label 'bot)))
  (should (string= "human+@"  (decknix-auto-review-state-label 'human)))
  (should (string= "any+@"    (decknix-auto-review-state-label 'any))))

;; -- Item action classifier ----------------------------------------
;;
;; Contract: every active state requires MENTIONED-P; bots map to
;; `ship', humans map to `review', `off' and not-mentioned map to nil.

(ert-deftest decknix-auto-review/action-off-is-always-nil ()
  "`off' never dispatches regardless of bot/mention."
  (should-not (decknix-auto-review-item-action 'off t   t))
  (should-not (decknix-auto-review-item-action 'off nil t))
  (should-not (decknix-auto-review-item-action 'off t   nil)))

(ert-deftest decknix-auto-review/action-requires-mention ()
  "No active state dispatches a PR that does not mention me."
  (should-not (decknix-auto-review-item-action 'bot   t   nil))
  (should-not (decknix-auto-review-item-action 'human nil nil))
  (should-not (decknix-auto-review-item-action 'any   t   nil))
  (should-not (decknix-auto-review-item-action 'any   nil nil)))

(ert-deftest decknix-auto-review/action-bot-state ()
  "`bot' dispatches only bot-authored mentioned PRs, as `ship'."
  (should (eq 'ship (decknix-auto-review-item-action 'bot t t)))
  (should-not      (decknix-auto-review-item-action 'bot nil t)))

(ert-deftest decknix-auto-review/action-human-state ()
  "`human' dispatches only human-authored mentioned PRs, as `review'."
  (should (eq 'review (decknix-auto-review-item-action 'human nil t)))
  (should-not        (decknix-auto-review-item-action 'human t   t)))

(ert-deftest decknix-auto-review/action-any-state ()
  "`any' dispatches both: bots as `ship', humans as `review'."
  (should (eq 'ship   (decknix-auto-review-item-action 'any t   t)))
  (should (eq 'review (decknix-auto-review-item-action 'any nil t))))

;; -- Command resolution --------------------------------------------

(ert-deftest decknix-auto-review/resolve-command-defaults ()
  "With no per-workspace overrides the global defaults are returned."
  (let ((decknix-auto-review-commands nil)
        (decknix-auto-review-default-review-command "/review-service-pr-factory")
        (decknix-auto-review-default-ship-command "/review-and-ship-bot-pr"))
    (should (string= "/review-service-pr-factory"
                     (decknix-auto-review-resolve-command 'review "/ws/a")))
    (should (string= "/review-and-ship-bot-pr"
                     (decknix-auto-review-resolve-command 'ship "/ws/a")))))

(ert-deftest decknix-auto-review/resolve-command-workspace-override ()
  "A matching workspace entry's :review / :ship overrides the default."
  (let ((decknix-auto-review-commands
         '(("/ws/proj" . (:review "/proj-review" :ship "/proj-ship"))))
        (decknix-auto-review-default-review-command "/review-service-pr-factory")
        (decknix-auto-review-default-ship-command "/review-and-ship-bot-pr"))
    (should (string= "/proj-review"
                     (decknix-auto-review-resolve-command 'review "/ws/proj")))
    (should (string= "/proj-ship"
                     (decknix-auto-review-resolve-command 'ship "/ws/proj")))
    ;; A non-matching workspace still falls back to the default.
    (should (string= "/review-service-pr-factory"
                     (decknix-auto-review-resolve-command 'review "/ws/other")))))

(ert-deftest decknix-auto-review/resolve-command-partial-override-falls-back ()
  "An entry that sets only :ship still falls back to default :review."
  (let ((decknix-auto-review-commands
         '(("/ws/proj" . (:ship "/proj-ship"))))
        (decknix-auto-review-default-review-command "/review-service-pr-factory")
        (decknix-auto-review-default-ship-command "/review-and-ship-bot-pr"))
    (should (string= "/review-service-pr-factory"
                     (decknix-auto-review-resolve-command 'review "/ws/proj")))
    (should (string= "/proj-ship"
                     (decknix-auto-review-resolve-command 'ship "/ws/proj")))))

(ert-deftest decknix-auto-review/resolve-command-normalises-paths ()
  "Workspace matching is path-normalised (trailing slash equivalence)."
  (let ((decknix-auto-review-commands
         '(("/ws/proj/" . (:review "/proj-review"))))
        (decknix-auto-review-default-review-command "/d"))
    (should (string= "/proj-review"
                     (decknix-auto-review-resolve-command 'review "/ws/proj")))))

;; -- Dedup keys -----------------------------------------------------

(ert-deftest decknix-auto-review/dispatch-key-normalises-number ()
  "Dedup key is stable whether NUMBER is an int or a string."
  (should (string= (decknix-auto-review-dispatch-key "owner/repo" 42)
                   (decknix-auto-review-dispatch-key "owner/repo" "42"))))

(ert-deftest decknix-auto-review/dispatched-roundtrip ()
  "Marking a key makes `dispatched-p' return non-nil for it only."
  (let ((decknix-auto-review--dispatched (make-hash-table :test 'equal)))
    (should-not (decknix-auto-review-dispatched-p "k1"))
    (decknix-auto-review-mark-dispatched "k1")
    (should (decknix-auto-review-dispatched-p "k1"))
    (should-not (decknix-auto-review-dispatched-p "k2"))))

(provide 'decknix-auto-review-test)
;;; decknix-auto-review-test.el ends here
