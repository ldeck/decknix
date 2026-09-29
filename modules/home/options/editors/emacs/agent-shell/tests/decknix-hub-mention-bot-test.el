;;; decknix-hub-mention-bot-test.el --- Tests for hub mention-filter + bot helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-mention-bot "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of the visibility-filter
;; helpers extracted from the agent-shell heredoc.  Two clusters in
;; one suite mirror the module layout: mention-filter (normalize +
;; label + item predicates + visible-p truth table) and bot filter
;; (regex predicate + visible-p with override flag).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-hub-mention-bot)

;; -- Inline fixtures ----------------------------------------------

(defun decknix-test--make-hub-item (&rest props)
  "Build a hub PR item alist from PROPS (plist)."
  (let ((author (plist-get props :author))
        (mentioned (plist-get props :mentioned))
        (team (plist-get props :team-requested))
        (others (plist-get props :others-requested))
        (my-review (plist-get props :my-review)))
    `((author . ,author)
      (mentioned . ,mentioned)
      (team_requested . ,team)
      (others_requested . ,others)
      (my_review . ,my-review))))

(defun decknix-test--make-hub-reviews-with-viewer (viewer)
  "Build a `decknix--hub-reviews'-shaped alist exposing VIEWER."
  `((viewer . ,viewer)
    (items . nil)))

;; -- decknix--hub-mention-filter-normalize -------------------------

(ert-deftest decknix-hub-mention-bot/normalize-passes-valid-symbols ()
  (should (eq nil      (decknix--hub-mention-filter-normalize nil)))
  (should (eq 'me      (decknix--hub-mention-filter-normalize 'me)))
  (should (eq 'team    (decknix--hub-mention-filter-normalize 'team)))
  (should (eq 'me+team (decknix--hub-mention-filter-normalize 'me+team))))

(ert-deftest decknix-hub-mention-bot/normalize-migrates-legacy-t-to-me ()
  (should (eq 'me (decknix--hub-mention-filter-normalize t))))

(ert-deftest decknix-hub-mention-bot/normalize-coerces-garbage-to-nil ()
  (should (eq nil (decknix--hub-mention-filter-normalize 'bogus)))
  (should (eq nil (decknix--hub-mention-filter-normalize "me")))
  (should (eq nil (decknix--hub-mention-filter-normalize 42)))
  (should (eq nil (decknix--hub-mention-filter-normalize '(me)))))

;; -- decknix--hub-mention-filter-label -----------------------------

(ert-deftest decknix-hub-mention-bot/label-pcase-known-states ()
  (let ((decknix--hub-mention-filter 'me))
    (should (string= "me" (decknix--hub-mention-filter-label))))
  (let ((decknix--hub-mention-filter 'team))
    (should (string= "team" (decknix--hub-mention-filter-label))))
  (let ((decknix--hub-mention-filter 'me+team))
    (should (string= "me+team" (decknix--hub-mention-filter-label)))))

(ert-deftest decknix-hub-mention-bot/label-default-off-for-nil-and-other ()
  (let ((decknix--hub-mention-filter nil))
    (should (string= "off" (decknix--hub-mention-filter-label))))
  (let ((decknix--hub-mention-filter 'unknown))
    (should (string= "off" (decknix--hub-mention-filter-label)))))

;; -- decknix--hub-item-author-p ------------------------------------

(ert-deftest decknix-hub-mention-bot/item-author-p-matches-viewer-case-insensitive ()
  (let ((decknix--hub-reviews
         (decknix-test--make-hub-reviews-with-viewer "alice")))
    (should (decknix--hub-item-author-p
             (decknix-test--make-hub-item :author "alice")))
    (should (decknix--hub-item-author-p
             (decknix-test--make-hub-item :author "ALICE")))
    (should (decknix--hub-item-author-p
             (decknix-test--make-hub-item :author "Alice")))))

(ert-deftest decknix-hub-mention-bot/item-author-p-rejects-other-author ()
  (let ((decknix--hub-reviews
         (decknix-test--make-hub-reviews-with-viewer "alice")))
    (should-not (decknix--hub-item-author-p
                 (decknix-test--make-hub-item :author "bob")))))

(ert-deftest decknix-hub-mention-bot/item-author-p-permissive-when-viewer-missing ()
  ;; No reviews data at all.
  (let ((decknix--hub-reviews nil))
    (should-not (decknix--hub-item-author-p
                 (decknix-test--make-hub-item :author "alice"))))
  ;; Reviews data present but no `viewer' field (older hub version).
  (let ((decknix--hub-reviews '((items . nil))))
    (should-not (decknix--hub-item-author-p
                 (decknix-test--make-hub-item :author "alice")))))

(ert-deftest decknix-hub-mention-bot/item-author-p-rejects-when-author-missing ()
  (let ((decknix--hub-reviews
         (decknix-test--make-hub-reviews-with-viewer "alice")))
    (should-not (decknix--hub-item-author-p
                 (decknix-test--make-hub-item)))))

;; -- decknix--hub-item-mentioned-p ---------------------------------

(ert-deftest decknix-hub-mention-bot/item-mentioned-p-strict-eq-t ()
  (should (decknix--hub-item-mentioned-p
           (decknix-test--make-hub-item :mentioned t)))
  (should-not (decknix--hub-item-mentioned-p
               (decknix-test--make-hub-item :mentioned nil)))
  (should-not (decknix--hub-item-mentioned-p
               (decknix-test--make-hub-item)))
  ;; Only literal `t' counts — JSON booleans must be normalised by
  ;; the parser before reaching this predicate.
  (should-not (decknix--hub-item-mentioned-p
               (decknix-test--make-hub-item :mentioned "true")))
  (should-not (decknix--hub-item-mentioned-p
               (decknix-test--make-hub-item :mentioned 1))))

;; -- decknix--hub-item-team-requested-p ----------------------------

(ert-deftest decknix-hub-mention-bot/item-team-requested-p-strict-eq-t ()
  (should (decknix--hub-item-team-requested-p
           (decknix-test--make-hub-item :team-requested t)))
  (should-not (decknix--hub-item-team-requested-p
               (decknix-test--make-hub-item :team-requested nil)))
  (should-not (decknix--hub-item-team-requested-p
               (decknix-test--make-hub-item)))
  (should-not (decknix--hub-item-team-requested-p
               (decknix-test--make-hub-item :team-requested "true"))))

;; -- decknix--hub-item-reviewed-by-me-p ----------------------------

(ert-deftest decknix-hub-mention-bot/item-reviewed-by-me-p-true-for-review-states ()
  (dolist (state '("APPROVED" "CHANGES_REQUESTED" "COMMENTED"
                   "DISMISSED" "PENDING"))
    (should (decknix--hub-item-reviewed-by-me-p
             (decknix-test--make-hub-item :my-review state)))))

(ert-deftest decknix-hub-mention-bot/item-reviewed-by-me-p-nil-when-absent-or-empty ()
  ;; No review of mine → not personally on the PR (pure team-noise).
  (should-not (decknix--hub-item-reviewed-by-me-p
               (decknix-test--make-hub-item :team-requested t)))
  (should-not (decknix--hub-item-reviewed-by-me-p
               (decknix-test--make-hub-item :my-review nil)))
  (should-not (decknix--hub-item-reviewed-by-me-p
               (decknix-test--make-hub-item :my-review "")))
  ;; A non-string value (defensive) must not count as a review.
  (should-not (decknix--hub-item-reviewed-by-me-p
               (decknix-test--make-hub-item :my-review t))))

;; -- decknix--hub-mention-visible-p (truth table over state) -------

(ert-deftest decknix-hub-mention-bot/mention-visible-p-nil-state-shows-all ()
  (let ((decknix--hub-mention-filter nil)
        (decknix--hub-reviews
         (decknix-test--make-hub-reviews-with-viewer "alice")))
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "alice")))
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob")))
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item)))))

(ert-deftest decknix-hub-mention-bot/mention-visible-p-author-excluded-when-filtering ()
  (let ((decknix--hub-reviews
         (decknix-test--make-hub-reviews-with-viewer "alice"))
        (item (decknix-test--make-hub-item
               :author "alice" :mentioned t :team-requested t)))
    (dolist (state '(me team me+team))
      (let ((decknix--hub-mention-filter state))
        (should-not (decknix--hub-mention-visible-p item))))))

(ert-deftest decknix-hub-mention-bot/mention-visible-p-state-me ()
  (let ((decknix--hub-mention-filter 'me)
        (decknix--hub-reviews
         (decknix-test--make-hub-reviews-with-viewer "alice")))
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob" :mentioned t)))
    (should-not (decknix--hub-mention-visible-p
                 (decknix-test--make-hub-item :author "bob" :team-requested t)))
    (should-not (decknix--hub-mention-visible-p
                 (decknix-test--make-hub-item :author "bob")))))

(ert-deftest decknix-hub-mention-bot/mention-visible-p-state-team ()
  (let ((decknix--hub-mention-filter 'team)
        (decknix--hub-reviews
         (decknix-test--make-hub-reviews-with-viewer "alice")))
    ;; team-only: team yes -> shown.
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob" :team-requested t)))
    ;; team AND directly requested -> STILL shown (must not be excluded).
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob"
                                          :team-requested t :mentioned t)))
    ;; requested of me alone, no team -> hidden.
    (should-not (decknix--hub-mention-visible-p
                 (decknix-test--make-hub-item :author "bob" :mentioned t)))
    (should-not (decknix--hub-mention-visible-p
                 (decknix-test--make-hub-item :author "bob")))))

(ert-deftest decknix-hub-mention-bot/mention-visible-p-state-me+team ()
  (let ((decknix--hub-mention-filter 'me+team)
        (decknix--hub-reviews
         (decknix-test--make-hub-reviews-with-viewer "alice")))
    ;; (1) directly requested -> shown (even alongside team/others).
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob" :mentioned t)))
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob"
                                          :mentioned t :team-requested t)))
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob"
                                          :mentioned t :others-requested t)))
    ;; (2) pure team ask, no individuals tagged -> shown.
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob" :team-requested t)))
    ;; team ask that also tags other individuals -> team-noise, hidden.
    (should-not (decknix--hub-mention-visible-p
                 (decknix-test--make-hub-item :author "bob"
                                              :team-requested t
                                              :others-requested t)))
    ;; neither -> hidden.
    (should-not (decknix--hub-mention-visible-p
                 (decknix-test--make-hub-item :author "bob")))))

;; -- decknix--hub-bot-author-p -------------------------------------

(ert-deftest decknix-hub-bot/author-p-matches-bracket-bot-suffix ()
  (should (decknix--hub-bot-author-p "dependabot[bot]"))
  (should (decknix--hub-bot-author-p "github-actions[bot]"))
  (should (decknix--hub-bot-author-p "copilot-pull-request-reviewer[bot]"))
  ;; The pattern is anchored at end-of-string with `$', so the
  ;; suffix must be at the tail.
  (should-not (decknix--hub-bot-author-p "[bot]-name")))

(ert-deftest decknix-hub-bot/author-p-matches-known-bot-prefixes ()
  (should (decknix--hub-bot-author-p "dependabot"))
  (should (decknix--hub-bot-author-p "dependabot-preview"))
  (should (decknix--hub-bot-author-p "renovate"))
  (should (decknix--hub-bot-author-p "renovate-bot"))
  (should (decknix--hub-bot-author-p "greenkeeper")))

(ert-deftest decknix-hub-bot/author-p-prefix-anchored ()
  ;; `^dependabot' — substring match further in must NOT count.
  (should-not (decknix--hub-bot-author-p "my-dependabot"))
  (should-not (decknix--hub-bot-author-p "x-renovate-y"))
  (should-not (decknix--hub-bot-author-p "x-greenkeeper")))

(ert-deftest decknix-hub-bot/author-p-rejects-humans-and-nil ()
  (should-not (decknix--hub-bot-author-p "alice"))
  (should-not (decknix--hub-bot-author-p "bob-the-builder"))
  (should-not (decknix--hub-bot-author-p ""))
  (should-not (decknix--hub-bot-author-p nil)))

;; -- decknix--hub-agent-author-p -----------------------------------
;;
;; Coding agents author real code changes, so they must NOT be
;; classified as dependency bots even though they are GitHub Apps
;; carrying the `[bot]' suffix.

(ert-deftest decknix-hub-agent/author-p-matches-known-coding-agents ()
  (should (decknix--hub-agent-author-p "augmentcode[bot]"))
  (should (decknix--hub-agent-author-p "augmentcode"))
  (should (decknix--hub-agent-author-p "copilot-swe-agent[bot]"))
  (should (decknix--hub-agent-author-p "cursoragent"))
  (should (decknix--hub-agent-author-p "devin-ai-integration[bot]"))
  (should (decknix--hub-agent-author-p "claude[bot]"))
  (should (decknix--hub-agent-author-p "codex[bot]"))
  (should (decknix--hub-agent-author-p "google-labs-jules[bot]")))

(ert-deftest decknix-hub-agent/author-p-is-case-insensitive ()
  ;; GitHub renders the Copilot coding agent's login as `Copilot'.
  (should (decknix--hub-agent-author-p "Copilot"))
  (should (decknix--hub-agent-author-p "AugmentCode[bot]")))

(ert-deftest decknix-hub-agent/author-p-prefix-anchored ()
  (should-not (decknix--hub-agent-author-p "my-augmentcode"))
  (should-not (decknix--hub-agent-author-p "x-cursoragent"))
  ;; The Copilot *review* bot is a reviewer, not a PR author — it must
  ;; not be swept into the coding-agent allow-list by the `copilot'
  ;; stem alone.
  (should-not (decknix--hub-agent-author-p
               "copilot-pull-request-reviewer[bot]")))

(ert-deftest decknix-hub-agent/author-p-rejects-humans-bots-and-nil ()
  (should-not (decknix--hub-agent-author-p "alice"))
  (should-not (decknix--hub-agent-author-p "dependabot[bot]"))
  (should-not (decknix--hub-agent-author-p ""))
  (should-not (decknix--hub-agent-author-p nil)))

;; -- coding agents are NOT dependency bots -------------------------

(ert-deftest decknix-hub-bot/author-p-excludes-coding-agents ()
  "A coding-agent author is human-equivalent, never a dependency bot.
Regression: `augmentcode[bot]' matched the `\\[bot\\]$' pattern and so
routed Augment-authored code PRs into the dependabot ship flow."
  (should-not (decknix--hub-bot-author-p "augmentcode[bot]"))
  (should-not (decknix--hub-bot-author-p "copilot-swe-agent[bot]"))
  (should-not (decknix--hub-bot-author-p "devin-ai-integration[bot]"))
  (should-not (decknix--hub-bot-author-p "Copilot"))
  ;; ...while genuine dependency bots keep matching.
  (should (decknix--hub-bot-author-p "dependabot[bot]"))
  (should (decknix--hub-bot-author-p "renovate[bot]")))

(ert-deftest decknix-hub-bot/visible-p-shows-coding-agents-when-bots-hidden ()
  "Agent-authored PRs stay visible under the default hide-bots state."
  (let ((decknix--hub-show-bots nil))
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item :author "augmentcode[bot]")))
    (should-not (decknix--hub-bot-visible-p
                 (decknix-test--make-hub-item :author "dependabot[bot]")))))

;; -- decknix--hub-show-bots-normalize -----------------------------

(ert-deftest decknix-hub-bot/normalize-passes-valid-symbols ()
  (should (eq nil        (decknix--hub-show-bots-normalize nil)))
  (should (eq 'show      (decknix--hub-show-bots-normalize 'show)))
  (should (eq 'mentioned (decknix--hub-show-bots-normalize 'mentioned))))

(ert-deftest decknix-hub-bot/normalize-migrates-legacy-t-to-show ()
  (should (eq 'show (decknix--hub-show-bots-normalize t))))

(ert-deftest decknix-hub-bot/normalize-coerces-garbage-to-nil ()
  (should (eq nil (decknix--hub-show-bots-normalize 'bogus)))
  (should (eq nil (decknix--hub-show-bots-normalize "show")))
  (should (eq nil (decknix--hub-show-bots-normalize 42))))

;; -- decknix--hub-show-bots-label ---------------------------------

(ert-deftest decknix-hub-bot/label-known-states ()
  (let ((decknix--hub-show-bots 'show))
    (should (string= "show" (decknix--hub-show-bots-label))))
  (let ((decknix--hub-show-bots 'mentioned))
    (should (string= "mention" (decknix--hub-show-bots-label))))
  (let ((decknix--hub-show-bots nil))
    (should (string= "hide" (decknix--hub-show-bots-label))))
  ;; Unknown state collapses to hide so the label cannot lie about
  ;; what the predicate is doing.
  (let ((decknix--hub-show-bots 'bogus))
    (should (string= "hide" (decknix--hub-show-bots-label)))))

;; -- decknix--hub-item-others-requested-p -------------------------

(ert-deftest decknix-hub-bot/others-requested-p-flag-only ()
  (should (decknix--hub-item-others-requested-p
           (decknix-test--make-hub-item :others-requested t)))
  (should-not (decknix--hub-item-others-requested-p
               (decknix-test--make-hub-item :others-requested nil)))
  (should-not (decknix--hub-item-others-requested-p
               (decknix-test--make-hub-item))))

;; -- decknix--hub-item-bot-mentioned-p ----------------------------

(ert-deftest decknix-hub-bot/bot-mentioned-p-direct-mention-wins ()
  ;; Direct mention is enough on its own.
  (should (decknix--hub-item-bot-mentioned-p
           (decknix-test--make-hub-item :mentioned t)))
  ;; Even when others are tagged, my direct mention keeps it visible.
  (should (decknix--hub-item-bot-mentioned-p
           (decknix-test--make-hub-item
            :mentioned t :others-requested t))))

(ert-deftest decknix-hub-bot/bot-mentioned-p-team-without-others ()
  (should (decknix--hub-item-bot-mentioned-p
           (decknix-test--make-hub-item :team-requested t))))

(ert-deftest decknix-hub-bot/bot-mentioned-p-team-with-others-hidden ()
  (should-not (decknix--hub-item-bot-mentioned-p
               (decknix-test--make-hub-item
                :team-requested t :others-requested t))))

(ert-deftest decknix-hub-bot/bot-mentioned-p-no-flags-hidden ()
  (should-not (decknix--hub-item-bot-mentioned-p
               (decknix-test--make-hub-item)))
  ;; Others requested but neither me nor team: hidden.
  (should-not (decknix--hub-item-bot-mentioned-p
               (decknix-test--make-hub-item :others-requested t))))

;; -- decknix--hub-bot-visible-p -----------------------------------

(ert-deftest decknix-hub-bot/visible-p-default-hides-bots ()
  (let ((decknix--hub-show-bots nil))
    (should-not (decknix--hub-bot-visible-p
                 (decknix-test--make-hub-item :author "dependabot[bot]")))
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item :author "alice")))
    ;; nil author falls through (cannot match bot patterns).
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item)))))

(ert-deftest decknix-hub-bot/visible-p-show-state-overrides ()
  (let ((decknix--hub-show-bots 'show))
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item :author "dependabot[bot]")))
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item :author "renovate")))
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item :author "alice")))))

(ert-deftest decknix-hub-bot/visible-p-mentioned-state-keeps-humans ()
  ;; Non-bot items are always visible regardless of mention flags.
  (let ((decknix--hub-show-bots 'mentioned))
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item :author "alice")))
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item
              :author "alice" :others-requested t)))))

(ert-deftest decknix-hub-bot/visible-p-mentioned-state-filters-bots ()
  (let ((decknix--hub-show-bots 'mentioned))
    ;; Bot + I am directly mentioned: visible.
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item
              :author "dependabot[bot]" :mentioned t)))
    ;; Bot + only my team requested + no other individuals: visible.
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item
              :author "dependabot[bot]" :team-requested t)))
    ;; Bot + team requested + other individuals tagged: HIDDEN (noise).
    (should-not (decknix--hub-bot-visible-p
                 (decknix-test--make-hub-item
                  :author "dependabot[bot]"
                  :team-requested t :others-requested t)))
    ;; Bot + no mention signals at all: HIDDEN.
    (should-not (decknix--hub-bot-visible-p
                 (decknix-test--make-hub-item
                  :author "dependabot[bot]")))))


;; -- request source ----------------------------------------------------
;;
;; Requests unions two queries: `--review-requested=@me' and, because GitHub
;; evicts a reviewer from the reviewers box on review submission,
;; `--reviewed-by=@me'.  The flag is what keeps "a team is pending on this PR"
;; from being read as "one of MY teams" on a row the request query never
;; constrained, and what keeps auto-review off follow-up rows.

(ert-deftest decknix-hub-requested-of-me--explicit-true ()
  (should (decknix--hub-item-review-requested-of-me-p
           '((review_requested_of_me . t)))))

(ert-deftest decknix-hub-requested-of-me--explicit-false ()
  "A follow-up row must read as not-requested however JSON false decodes."
  (should-not (decknix--hub-item-review-requested-of-me-p
               '((review_requested_of_me . :json-false))))
  (should-not (decknix--hub-item-review-requested-of-me-p
               '((review_requested_of_me . nil)))))

(ert-deftest decknix-hub-requested-of-me--absent-is-a-legacy-request ()
  "An older hub emitted no such field and every row WAS a standing request.
Reading absence as false would silently stop auto-review against that feed."
  (should (decknix--hub-item-review-requested-of-me-p '((number . 1)))))

(provide 'decknix-hub-mention-bot-test)
;;; decknix-hub-mention-bot-test.el ends here
