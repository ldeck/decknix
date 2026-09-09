;;; decknix-hub-review-identity-test.el --- Which PR is a session reviewing? -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for `decknix--hub-review-session-covers-p' — the
;; pure decision behind "does this PR already have a review session?".
;;
;; Getting this wrong launches a SECOND review agent against a PR that
;; already has one, and both can post to GitHub.  That is exactly what
;; happened once broker reattach started restoring review sessions: the
;; old check matched buffer NAMES against `pr-<repo>-<number>', reattach
;; renamed those buffers from their tags, the needle stopped matching,
;; and six PRs each ended up with two live agents.
;;
;; The lesson is that buffer name and tags are DISPLAY properties, both
;; user-mutable, and neither is an identity.  The PR coordinates recorded
;; at launch are.  These tests pin that ordering.

;;; Code:

(require 'ert)
(require 'decknix-hub-review-identity)

;; --- recorded coordinates win, and survive any renaming ---

(ert-deftest decknix-review-id--recorded-pr-matches ()
  "Recorded coordinates identify the PR regardless of name or tags."
  (should (decknix--hub-review-session-covers-p
           "upside" 20611 "*Claude: something else entirely*" nil "upside#20611")))

(ert-deftest decknix-review-id--recorded-pr-rejects-other-pr ()
  "A recorded session covering another PR must not suppress this one."
  (should-not (decknix--hub-review-session-covers-p
               "upside" 20611 "*Claude: pr-upside-20611*" '("#20611" "upside")
               "upside#20728")))

(ert-deftest decknix-review-id--recorded-pr-beats-misleading-name ()
  "Recorded coordinates outrank a name that merely looks right.
The name is a display string; a session renamed onto another PR's
convention must not be credited with covering it."
  (should-not (decknix--hub-review-session-covers-p
               "upside" 20733 "*Claude: pr-upside-20733*" nil "upside#99999")))

;; --- fallback: tags, for sessions launched before coordinates existed ---

(ert-deftest decknix-review-id--tags-match-when-no-record ()
  "With no recorded PR, the `#<number>' + repo tag pair identifies it."
  (should (decknix--hub-review-session-covers-p
           "upside" 20611 "*Claude: auto/#20611/upside/review*"
           '("auto" "#20611" "upside" "review") nil)))

(ert-deftest decknix-review-id--tags-tolerate-user-additions ()
  "Amending a session's tags must not orphan it.
Tags are user-editable — `#291' here has picked up `fix'/`firestore'/`pin'
by hand.  A subset test survives that; an equality test would not, and
would silently launch a duplicate reviewer the next time the hub polled."
  (should (decknix--hub-review-session-covers-p
           "reconz-integration" 291 "*Claude: auto/#291/reconz-integration/review*"
           '("auto" "#291" "reconz-integration" "review" "fix" "firestore" "pin")
           nil)))

(ert-deftest decknix-review-id--tags-need-both-number-and-repo ()
  "A number tag alone is ambiguous across repos."
  (should-not (decknix--hub-review-session-covers-p
               "upside" 20611 "*Claude: x*" '("auto" "#20611" "reconz-integration") nil))
  (should-not (decknix--hub-review-session-covers-p
               "upside" 20611 "*Claude: x*" '("auto" "upside" "review") nil)))

(ert-deftest decknix-review-id--tag-number-is-not-a-prefix-match ()
  "`#2061' must not satisfy `#20611', nor `#206110' either."
  (should-not (decknix--hub-review-session-covers-p
               "upside" 20611 "*Claude: x*" '("#2061" "upside") nil))
  (should-not (decknix--hub-review-session-covers-p
               "upside" 20611 "*Claude: x*" '("#206110" "upside") nil)))

;; --- fallback: the legacy buffer-name needle ---

(ert-deftest decknix-review-id--name-needle-still-works ()
  "The original `pr-<repo>-<number>' convention keeps matching."
  (should (decknix--hub-review-session-covers-p
           "upside" 20611 "*Claude: pr-upside-20611*" nil nil)))

(ert-deftest decknix-review-id--name-needle-is-not-a-prefix-match ()
  "`pr-upside-20611' must not be satisfied by `pr-upside-206110'."
  (should-not (decknix--hub-review-session-covers-p
               "upside" 20611 "*Claude: pr-upside-206110*" nil nil)))

;; --- nothing to go on ---

(ert-deftest decknix-review-id--unrelated-session-does-not-match ()
  "A session with no bearing on the PR must never suppress a review."
  (should-not (decknix--hub-review-session-covers-p
               "upside" 20611 "*Claude: decknix/nurturecloud*" '("decknix") nil)))

(ert-deftest decknix-review-id--degrades-on-missing-inputs ()
  "Missing repo/number cannot be matched; never claim coverage."
  (should-not (decknix--hub-review-session-covers-p nil 20611 "*Claude: x*" nil nil))
  (should-not (decknix--hub-review-session-covers-p "upside" nil "*Claude: x*" nil nil))
  (should-not (decknix--hub-review-session-covers-p "" 20611 "*Claude: x*" nil nil)))

;; --- the recorded-coordinate format ---

(ert-deftest decknix-review-id--key-format-is-stable ()
  "The stored key is `repo#number', normalised from a full owner/repo."
  (should (equal "upside#20611" (decknix--hub-review-pr-key "upside" 20611)))
  (should (equal "upside#20611" (decknix--hub-review-pr-key "UpsideRealty/upside" 20611)))
  (should (equal "upside#20611" (decknix--hub-review-pr-key "upside" "20611")))
  (should-not (decknix--hub-review-pr-key nil 20611))
  (should-not (decknix--hub-review-pr-key "upside" nil)))

;; --- capturing the key from the launch name ---

(ert-deftest decknix-review-id--key-from-launch-name ()
  "A `pr-<repo>-<number>' launch name yields the identity to record."
  (should (equal "upside#20611"
                 (decknix--hub-review-pr-key-from-name "pr-upside-20611")))
  (should (equal "oneroof-integration#166"
                 (decknix--hub-review-pr-key-from-name "pr-oneroof-integration-166"))))

(ert-deftest decknix-review-id--key-from-name-rejects-non-review-names ()
  "Only the review convention yields a key; other sessions record nothing.
A quick action is not necessarily a review, and inventing coordinates for
one would suppress a real review of whatever PR it collided with."
  (should-not (decknix--hub-review-pr-key-from-name "auto/#166/oneroof/review"))
  (should-not (decknix--hub-review-pr-key-from-name "decknix/nurturecloud"))
  (should-not (decknix--hub-review-pr-key-from-name "pr-upside-"))
  (should-not (decknix--hub-review-pr-key-from-name nil)))


;; --- grouped sessions cover several PRs ---

(ert-deftest decknix-review-id--group-covers-each-member ()
  "A session recorded against several PRs covers each of them.
Grouped dispatch sends one service's bumps to one agent, so membership
rather than equality is the test -- otherwise four of five bumps would
look unreviewed and each would acquire a second reviewer."
  (let ((group '("upside#1" "upside#2" "upside#3")))
    (should (decknix--hub-review-session-covers-p "upside" 1 "*x*" nil group))
    (should (decknix--hub-review-session-covers-p "upside" 2 "*x*" nil group))
    (should (decknix--hub-review-session-covers-p "upside" 3 "*x*" nil group))))

(ert-deftest decknix-review-id--group-still-denies-non-members ()
  "A group denies a PR it does not contain, even in the same repo."
  (should-not (decknix--hub-review-session-covers-p
               "upside" 4 "*Claude: pr-upside-4*" '("#4" "upside")
               '("upside#1" "upside#2"))))

(ert-deftest decknix-review-id--legacy-string-still-covers ()
  "Entries written before grouping are bare strings and must keep working."
  (should (decknix--hub-review-session-covers-p
           "upside" 20611 "*x*" nil "upside#20611"))
  (should-not (decknix--hub-review-session-covers-p
               "upside" 20612 "*x*" nil "upside#20611")))


;; --- PR URLs, for rows whose feed item has gone ---

(ert-deftest decknix-review-id--pr-url ()
  "Reconstructs the URL from coordinates rather than a feed item."
  (should (equal "https://github.com/UpsideRealty/upside/pull/20611"
                 (decknix--hub-review-pr-url "UpsideRealty" "upside" 20611)))
  (should (equal "https://github.com/UpsideRealty/upside/pull/20611"
                 (decknix--hub-review-pr-url "UpsideRealty" "UpsideRealty/upside" "20611"))))

(ert-deftest decknix-review-id--pr-url-needs-an-owner ()
  "Without an owner there is no URL to guess; nil rather than a wrong link."
  (should-not (decknix--hub-review-pr-url nil "upside" 1))
  (should-not (decknix--hub-review-pr-url "" "upside" 1))
  (should-not (decknix--hub-review-pr-url "org" nil 1))
  (should-not (decknix--hub-review-pr-url "org" "upside" nil)))

(ert-deftest decknix-review-id--key-parse ()
  "`repo#number' splits back into its parts."
  (should (equal '("upside" . "20611") (decknix--hub-review-pr-key-parse "upside#20611")))
  (should (equal '("oneroof-integration" . "166")
                 (decknix--hub-review-pr-key-parse "oneroof-integration#166")))
  (should-not (decknix--hub-review-pr-key-parse "upside"))
  (should-not (decknix--hub-review-pr-key-parse nil)))

(provide 'decknix-hub-review-identity-test)
;;; decknix-hub-review-identity-test.el ends here
