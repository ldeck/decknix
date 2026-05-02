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
        (team (plist-get props :team-requested)))
    `((author . ,author)
      (mentioned . ,mentioned)
      (team_requested . ,team))))

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
    ;; team-only: team yes, mention no
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob" :team-requested t)))
    ;; team-and-mention: excluded by `(and team (not me))'
    (should-not (decknix--hub-mention-visible-p
                 (decknix-test--make-hub-item :author "bob"
                                              :team-requested t :mentioned t)))
    (should-not (decknix--hub-mention-visible-p
                 (decknix-test--make-hub-item :author "bob" :mentioned t)))
    (should-not (decknix--hub-mention-visible-p
                 (decknix-test--make-hub-item :author "bob")))))

(ert-deftest decknix-hub-mention-bot/mention-visible-p-state-me+team ()
  (let ((decknix--hub-mention-filter 'me+team)
        (decknix--hub-reviews
         (decknix-test--make-hub-reviews-with-viewer "alice")))
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob" :mentioned t)))
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob" :team-requested t)))
    (should (decknix--hub-mention-visible-p
             (decknix-test--make-hub-item :author "bob"
                                          :mentioned t :team-requested t)))
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

;; -- decknix--hub-bot-visible-p ------------------------------------

(ert-deftest decknix-hub-bot/visible-p-default-hides-bots ()
  (let ((decknix--hub-show-bots nil))
    (should-not (decknix--hub-bot-visible-p
                 (decknix-test--make-hub-item :author "dependabot[bot]")))
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item :author "alice")))
    ;; nil author falls through (cannot match bot patterns).
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item)))))

(ert-deftest decknix-hub-bot/visible-p-show-bots-flag-overrides ()
  (let ((decknix--hub-show-bots t))
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item :author "dependabot[bot]")))
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item :author "renovate")))
    (should (decknix--hub-bot-visible-p
             (decknix-test--make-hub-item :author "alice")))))

(provide 'decknix-hub-mention-bot-test)
;;; decknix-hub-mention-bot-test.el ends here
