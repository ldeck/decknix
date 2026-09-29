;;; decknix-auto-review-test.el --- Tests for decknix-auto-review -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-auto-review "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the intended behaviour of the pure helper layer in
;; `decknix-auto-review' — the 4-state cycle, the state labels, the
;; per-item dispatch-action classifier (state x bot x mentioned x
;; draft x conflicting), the per-workspace command resolver, and the
;; dedup-key helpers.  These are specification-first tests: they
;; describe the contract the dispatch side-effects (wired in the
;; heredoc) rely on.
;;
;; The `--dispatch-item' suite at the end is the regression net for the
;; not-review-ready guard: it stubs the hub / spawn collaborators so the
;; wiring — not just the pure classifier — is pinned.  Auto-review read
;; the raw hub feed and dispatched draft and merge-conflicting PRs the
;; sidebar's own Requests list hides by default.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-auto-review)
;; Grouped dispatch records PR coordinates through this layer.
(require 'decknix-hub-review-identity nil t)

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

;; -- Not-review-ready guard (draft / conflicting) -------------------
;;
;; Contract: a PR the sidebar's Requests list would itself hide is never
;; auto-dispatched.  A draft is explicitly marked not-ready by its
;; author; a CONFLICTING PR's diff is against a stale base, so its line
;; anchors and "is this still referenced" checks are unreliable.  Both
;; waste a dispatch.

(ert-deftest decknix-auto-review/action-skips-draft ()
  "A draft PR never dispatches, whatever the state or author kind."
  (should-not (decknix-auto-review-item-action 'human nil t t nil))
  (should-not (decknix-auto-review-item-action 'any   nil t t nil))
  (should-not (decknix-auto-review-item-action 'bot   t   t t nil))
  (should-not (decknix-auto-review-item-action 'any   t   t t nil)))

(ert-deftest decknix-auto-review/action-skips-conflicting ()
  "A merge-conflicting PR never dispatches, whatever the state."
  (should-not (decknix-auto-review-item-action 'human nil t nil t))
  (should-not (decknix-auto-review-item-action 'any   nil t nil t))
  (should-not (decknix-auto-review-item-action 'bot   t   t nil t))
  (should-not (decknix-auto-review-item-action 'any   t   t nil t)))

(ert-deftest decknix-auto-review/action-allows-review-ready ()
  "Explicitly non-draft, non-conflicting PRs dispatch as normal."
  (should (eq 'review (decknix-auto-review-item-action 'human nil t nil nil)))
  (should (eq 'ship   (decknix-auto-review-item-action 'bot   t   t nil nil)))
  (should (eq 'review (decknix-auto-review-item-action 'any   nil t nil nil)))
  (should (eq 'ship   (decknix-auto-review-item-action 'any   t   t nil nil))))

(ert-deftest decknix-auto-review/action-readiness-args-are-optional ()
  "Omitting the readiness args keeps the 3-arg call site working."
  (should (eq 'review (decknix-auto-review-item-action 'human nil t)))
  (should (eq 'ship   (decknix-auto-review-item-action 'bot   t   t))))

;; -- Command resolution --------------------------------------------

(ert-deftest decknix-auto-review/resolve-command-defaults ()
  "With no per-workspace overrides the global defaults are returned."
  (let ((decknix-auto-review-commands nil)
        (decknix-auto-review-default-review-command "/review-service-pr")
        (decknix-auto-review-default-ship-command "/review-and-ship-bot-pr"))
    (should (string= "/review-service-pr"
                     (decknix-auto-review-resolve-command 'review "/ws/a")))
    (should (string= "/review-and-ship-bot-pr"
                     (decknix-auto-review-resolve-command 'ship "/ws/a")))))

(ert-deftest decknix-auto-review/resolve-command-workspace-override ()
  "A matching workspace entry's :review / :ship overrides the default."
  (let ((decknix-auto-review-commands
         '(("/ws/proj" . (:review "/proj-review" :ship "/proj-ship"))))
        (decknix-auto-review-default-review-command "/review-service-pr")
        (decknix-auto-review-default-ship-command "/review-and-ship-bot-pr"))
    (should (string= "/proj-review"
                     (decknix-auto-review-resolve-command 'review "/ws/proj")))
    (should (string= "/proj-ship"
                     (decknix-auto-review-resolve-command 'ship "/ws/proj")))
    ;; A non-matching workspace still falls back to the default.
    (should (string= "/review-service-pr"
                     (decknix-auto-review-resolve-command 'review "/ws/other")))))

(ert-deftest decknix-auto-review/resolve-command-partial-override-falls-back ()
  "An entry that sets only :ship still falls back to default :review."
  (let ((decknix-auto-review-commands
         '(("/ws/proj" . (:ship "/proj-ship"))))
        (decknix-auto-review-default-review-command "/review-service-pr")
        (decknix-auto-review-default-ship-command "/review-and-ship-bot-pr"))
    (should (string= "/review-service-pr"
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

;; -- Dispatch wiring -----------------------------------------------
;;
;; `--dispatch-item' is the impure glue, but it is where the guard has
;; to bite: the pure classifier can only refuse what it is told about.
;; These stub the hub / spawn collaborators so the derivation of the
;; readiness booleans from the sidebar's own visibility predicates is
;; pinned, not just the classifier downstream of it.

(cl-defun decknix-auto-review-test--dispatch
    (&key (bot nil) (mentioned t) (draft nil) (conflicting nil)
          (live-session nil))
  "Run the eligibility + dispatch path with collaborators stubbed.
Returns a cons of (ACTION . SPAWN-COUNT) so a test can assert both that
no action was chosen and that nothing was enqueued."
  (let ((decknix-auto-review--dispatched (make-hash-table :test 'equal))
        (spawned 0))
    (cl-letf (((symbol-function 'decknix--hub-bot-author-p)
               (lambda (&rest _) bot))
              ((symbol-function 'decknix--hub-item-mentioned-p)
               (lambda (&rest _) mentioned))
              ;; Draft and conflicting are now read off the ITEM, because a
              ;; display filter must not decide a dispatch (attom#296). These
              ;; stubs stay, set to "visible", so a regression back to the
              ;; visibility predicates cannot pass by accident.
              ((symbol-function 'decknix--hub-requests-draft-visible-p)
               (lambda (&rest _) t))
              ((symbol-function 'decknix--hub-requests-conflict-visible-p)
               (lambda (&rest _) t))
              ((symbol-function 'decknix--hub-request-has-live-session-p)
               (lambda (&rest _) live-session))
              ((symbol-function 'decknix--agent-pr-detect-workspace)
               (lambda (&rest _) "/ws/upside"))
              ((symbol-function 'decknix-agent-purpose-resolve)
               (lambda (&rest _) '(:model "m" :provider "p" :mode "auto")))
              ((symbol-function 'decknix-agent-spawn-enqueue)
               (lambda (&rest _) (setq spawned (1+ spawned)))))
      ;; Mirrors the driver: decide eligibility, then dispatch a unit.
      ;; Pointed at the live path deliberately -- the guards moved to
      ;; `--eligible-action' when grouping landed, and a regression net
      ;; aimed at the old entry point would have kept passing while the
      ;; real one went unguarded.
      (let* ((item (append
                    (when draft '((draft . t)))
                    (when conflicting '((mergeable . "CONFLICTING")))
                    '((repo   . "UpsideRealty/upside")
                      (number . 20612)
                      (url    . "https://github.com/UpsideRealty/upside/pull/20612")
                      (author . "abatten187"))))
             (action (decknix-auto-review--eligible-action item)))
        (when action
          (decknix-auto-review--dispatch-unit
           (list action "upside" (alist-get 'author item) (list item))))
        (cons action spawned)))))

(ert-deftest decknix-auto-review/dispatch-skips-draft-pr ()
  "A draft PR is never auto-dispatched, whatever the sidebar shows.
The visibility stubs report \"visible\" in this helper, so this passes only
because the item's own `draft' flag is read."
  (let ((decknix-auto-review-mode 'human))
    (should (equal '(nil . 0)
                   (decknix-auto-review-test--dispatch :draft t))))
  (let ((decknix-auto-review-mode 'any))
    (should (equal '(nil . 0)
                   (decknix-auto-review-test--dispatch :draft t)))))

(ert-deftest decknix-auto-review/dispatch-skips-conflicting-pr ()
  "A conflicting PR is never auto-dispatched, whatever the sidebar shows."
  (let ((decknix-auto-review-mode 'human))
    (should (equal '(nil . 0)
                   (decknix-auto-review-test--dispatch :conflicting t))))
  (let ((decknix-auto-review-mode 'any))
    (should (equal '(nil . 0)
                   (decknix-auto-review-test--dispatch :conflicting t)))))

(ert-deftest decknix-auto-review/dispatch-review-ready-pr ()
  "A mentioned, non-draft, non-conflicting human PR still dispatches."
  (let ((decknix-auto-review-mode 'human))
    (should (equal '(review . 1) (decknix-auto-review-test--dispatch)))))

(ert-deftest decknix-auto-review/dispatch-still-honours-mention-guard ()
  "The readiness guard is additive — the mention guard is unchanged."
  (let ((decknix-auto-review-mode 'human))
    (should (equal '(nil . 0)
                   (decknix-auto-review-test--dispatch :mentioned nil)))))

;; -- team-requested reviews count as mine -----------------------------
;;
;; `attom-integration' and `followupboss-integration' never assign individual
;; reviewers; CODEOWNERS tags the team. Their PRs arrive with `mentioned' nil
;; and `team_requested' t, so eligibility keyed on `mentioned' alone dispatched
;; nothing. Observed on attom #294-#297, all four from jonathan-lo.

(ert-deftest decknix-auto-review-requested--individual-request-counts ()
  "A direct request is still eligible."
  (should (decknix-auto-review--requested-of-me-p '((mentioned . t)))))

(ert-deftest decknix-auto-review-requested--team-request-counts ()
  "A team-only request is eligible, which is the reported gap."
  (should (decknix-auto-review--requested-of-me-p
           '((mentioned . nil) (team_requested . t)))))

(ert-deftest decknix-auto-review-requested--neither-is-not-eligible ()
  "A PR that asks nothing of me must not dispatch a session."
  (should-not (decknix-auto-review--requested-of-me-p
               '((mentioned . nil) (team_requested . nil))))
  (should-not (decknix-auto-review--requested-of-me-p '())))

(ert-deftest decknix-auto-review-requested--opt-out-restores-old-behaviour ()
  "With the option off, a team request is ignored again.
Wanted where a team carries more PRs than the viewer intends to review."
  (let ((decknix-auto-review-include-team-requests nil))
    (should-not (decknix-auto-review--requested-of-me-p
                 '((mentioned . nil) (team_requested . t))))
    (should (decknix-auto-review--requested-of-me-p '((mentioned . t))))))


;; -- draft and conflict gates read the PR, not the view ----------------
;;
;; These used to derive from the sidebar's visibility predicates, whose first
;; clause is `(not decknix--hub-requests-hide-draft)'. With drafts VISIBLE that
;; returned t for a draft, so suppression vanished: attom#296 is a draft on
;; GitHub and in the feed and was dispatched anyway.

(ert-deftest decknix-auto-review-draft--reads-the-prs-own-flag ()
  "A draft is a draft whatever the sidebar is showing."
  (should (decknix-auto-review--draft-p '((draft . t))))
  (should-not (decknix-auto-review--draft-p '((draft . nil))))
  (should-not (decknix-auto-review--draft-p '())))

(ert-deftest decknix-auto-review-draft--ignores-the-visibility-toggle ()
  "Making drafts visible must not make them dispatchable.
This is the attom#296 case: the toggle changed a display preference and
silently disabled a dispatch guard."
  (let ((decknix--hub-requests-hide-draft nil))
    (should (decknix-auto-review--draft-p '((draft . t))))))

(ert-deftest decknix-auto-review-conflict--reads-mergeable ()
  "A conflicting diff is detected from the PR, not from the filter."
  (should (decknix-auto-review--conflicting-p '((mergeable . "CONFLICTING"))))
  (should-not (decknix-auto-review--conflicting-p '((mergeable . "MERGEABLE"))))
  (should-not (decknix-auto-review--conflicting-p '()))
  (let ((decknix--hub-requests-hide-conflict nil))
    (should (decknix-auto-review--conflicting-p '((mergeable . "CONFLICTING"))))))

(ert-deftest decknix-auto-review-draft--suppresses-dispatch-for-attom-296 ()
  "The reported item yields no action even though the team was requested."
  (should-not (decknix-auto-review-item-action
               'any nil
               (decknix-auto-review--requested-of-me-p
                '((mentioned . nil) (team_requested . t)))
               (decknix-auto-review--draft-p '((draft . t)))
               nil)))



;; -- follow-up rows are not dispatch targets ---------------------------
;;
;; Requests now also carries PRs recovered by the hub\'s `--reviewed-by=@me\'
;; source.  They exist so a human reply I owe is visible; dispatching a review
;; session at one would re-review work already reviewed, unprompted.

(ert-deftest decknix-auto-review--follow-up-row-is-not-requested-of-me ()
  (should-not (decknix-auto-review--requested-of-me-p
               '((mentioned . t) (review_requested_of_me . :json-false)))))

(ert-deftest decknix-auto-review--follow-up-team-row-is-not-requested-of-me ()
  "The hub already forces `team_requested' false on a follow-up row; this
pins the client-side gate so both layers have to fail before a session runs."
  (let ((decknix-auto-review-include-team-requests t))
    (should-not (decknix-auto-review--requested-of-me-p
                 '((team_requested . t)
                   (review_requested_of_me . :json-false))))))

(ert-deftest decknix-auto-review--standing-request-still-dispatches ()
  (should (decknix-auto-review--requested-of-me-p
           '((mentioned . t) (review_requested_of_me . t))))
  (should (decknix-auto-review--requested-of-me-p '((mentioned . t)))))

(provide 'decknix-auto-review-test)
;;; decknix-auto-review-test.el ends here
