;;; decknix-hub-icons-test.el --- Tests for hub icon helpers + age formatter -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-icons "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of the hub icon decoders +
;; age formatter extracted from the agent-shell heredoc.  Format-age
;; uses cl-letf to mock current-time for deterministic boundary
;; checks; icon decoders pin the exact glyph (without inspecting the
;; face property since `decknix--hub-icon' attaches face / display
;; properties that are out of scope for these tests).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-icons)

;; -- Fixtures ------------------------------------------------------

(defvar decknix-test--ref-time
  (encode-time 0 0 12 15 6 2025 t))

;; Test-local default mirrors the production default in
;; `decknix-agent-shell-hub.el'.  A value-initialised `defvar' marks
;; the symbol special so emoji-path `let' bindings rebind it
;; dynamically and the byte-compiled `decknix--hub-activity-icons'
;; observes the change (a value-less `defvar' would bind lexically).
(defvar decknix--hub-symbol-style 'ascii)

(defun decknix-test--iso-offset (seconds-ago)
  (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                      (time-subtract decknix-test--ref-time
                                     (seconds-to-time seconds-ago))
                      t))

(defmacro decknix-test--with-fixed-time (&rest body)
  `(cl-letf (((symbol-function 'current-time)
              (lambda () decknix-test--ref-time)))
     ,@body))

(defun decknix-test--icon-glyph (s)
  "Strip text properties from S to compare bare glyph."
  (when (stringp s) (substring-no-properties s)))

(defun decknix-test--icon-face (s)
  "Get the face property from S."
  (when (stringp s) (get-text-property 0 'face s)))

;; -- format-age: boundary checks -----------------------------------

(ert-deftest decknix-hub-format-age--nil ()
  (should (equal (decknix--hub-format-age nil) "?")))

(ert-deftest decknix-hub-format-age--non-string ()
  (should (equal (decknix--hub-format-age 42) "?")))

(ert-deftest decknix-hub-format-age--malformed ()
  "Unparseable timestamp returns \"?\" via condition-case."
  (should (equal (decknix--hub-format-age "garbage") "?")))

(ert-deftest decknix-hub-format-age--now ()
  "Less than 60 seconds reads as \"now\"."
  (decknix-test--with-fixed-time
   (should (equal (decknix--hub-format-age (decknix-test--iso-offset 0)) "now"))
   (should (equal (decknix--hub-format-age (decknix-test--iso-offset 59))
                  "now"))))

(ert-deftest decknix-hub-format-age--minutes ()
  (decknix-test--with-fixed-time
   (should (equal (decknix--hub-format-age (decknix-test--iso-offset 60)) "1m"))
   (should (equal (decknix--hub-format-age (decknix-test--iso-offset (* 30 60)))
                  "30m"))))

(ert-deftest decknix-hub-format-age--hours ()
  (decknix-test--with-fixed-time
   (should (equal (decknix--hub-format-age (decknix-test--iso-offset (* 60 60)))
                  "1h"))
   (should (equal (decknix--hub-format-age
                   (decknix-test--iso-offset (* 23 60 60)))
                  "23h"))))

(ert-deftest decknix-hub-format-age--days ()
  (decknix-test--with-fixed-time
   (should (equal (decknix--hub-format-age
                   (decknix-test--iso-offset (* 24 60 60)))
                  "1d"))
   (should (equal (decknix--hub-format-age
                   (decknix-test--iso-offset (* 30 24 60 60)))
                  "30d"))))

;; -- review-icon: pcase branches -----------------------------------

(ert-deftest decknix-hub-review-icon--approved ()
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-review-icon '((my_review . "APPROVED"))))
                 "●")))

(ert-deftest decknix-hub-review-icon--changes-requested ()
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-review-icon
                   '((my_review . "CHANGES_REQUESTED"))))
                 "◐")))

(ert-deftest decknix-hub-review-icon--commented ()
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-review-icon '((my_review . "COMMENTED"))))
                 "◐")))

(ert-deftest decknix-hub-review-icon--dismissed ()
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-review-icon '((my_review . "DISMISSED"))))
                 "−")))

(ert-deftest decknix-hub-review-icon--pending ()
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-review-icon '((my_review . "PENDING"))))
                 "…")))

(ert-deftest decknix-hub-review-icon--unknown-or-missing ()
  "Unknown state and missing field both yield empty string."
  (should (equal (decknix--hub-review-icon '((my_review . "WAT"))) ""))
  (should (equal (decknix--hub-review-icon '()) ""))
  (should (equal (decknix--hub-review-icon '((my_review . nil))) "")))

;; -- wip-review-icon: pcase branches -------------------------------

(ert-deftest decknix-hub-wip-review-icon--approved ()
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-wip-review-icon
                   '((review_decision . "APPROVED"))))
                 "●")))

(ert-deftest decknix-hub-wip-review-icon--changes-requested ()
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-wip-review-icon
                   '((review_decision . "CHANGES_REQUESTED"))))
                 "◐")))

(ert-deftest decknix-hub-wip-review-icon--review-required ()
  (let ((item '((review_decision . "REVIEW_REQUIRED"))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-wip-review-icon item))
                   "◐"))
    (should (equal (decknix-test--icon-face
                    (decknix--hub-wip-review-icon item))
                   'success))))

(ert-deftest decknix-hub-wip-review-icon--unknown-or-missing ()
  (should (equal (decknix--hub-wip-review-icon
                  '((review_decision . "OTHER"))) ""))
  (should (equal (decknix--hub-wip-review-icon '()) "")))

;; -- activity-icons: flag combinations -----------------------------

(ert-deftest decknix-hub-activity-icons--approved-hides-all ()
  "Approved PRs (decision=APPROVED) yield empty activity icons."
  (let ((pr '((review_decision . "APPROVED")
              (needs_reply . t)
              (replies_to_me . t))))
    (should (equal (decknix--hub-activity-icons pr) ""))))

(ert-deftest decknix-hub-activity-icons--none ()
  "All flags absent or false yield empty string."
  (should (equal (decknix--hub-activity-icons '()) ""))
  (should (equal (decknix--hub-activity-icons
                  '((needs_reply . nil) (bot_pending . nil)
                    (replies_to_me . nil)))
                 "")))

(ert-deftest decknix-hub-activity-icons--bot-only-needs-an-open-thread ()
  "A bot signal alone shows beta only when a thread is actually open."
  (should (string-empty-p
           (string-trim (decknix--hub-activity-icons '((bot_pending . t))))))
  (should (equal " \u03b2"
                 (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((bot_pending . t)
                     (total_threads . 1) (unresolved_threads . 1)))))))

(ert-deftest decknix-hub-activity-icons--needs-reply-only ()
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((needs_reply . t))))
                 "i ")))

(ert-deftest decknix-hub-activity-icons--i-replied-last-means-addressed ()
  "My own post being the latest settles the row, even after a human reply.

Reverses \"replies-to-me outranks i-replied-last\". Under the attribution
rule an icon means work OUTSTANDING, and if my comment is the most recent
one I have addressed what came before it."
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((replies_to_me . t) (i_replied_last . t))))
                 "")))

(ert-deftest decknix-hub-activity-icons--i-replied-with-bot-pending-is-silent ()
  "Nothing outstanding: I posted last and the bot left no open thread."
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((i_replied_last . t) (bot_pending . t))))
                 "")))

(ert-deftest decknix-hub-activity-icons--bot-and-needs-reply-needs-an-open-thread ()
  "Bot activity with no open thread is silent; with one it shows beta."
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((bot_pending . t) (needs_reply . t))))
                 ""))
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((bot_pending . t) (needs_reply . t)
                     (total_threads . 2) (unresolved_threads . 1))))
                 " β")))

(ert-deftest decknix-hub-activity-icons--slots-coexist-when-both-outstanding ()
  "The two slots are independent, but each needs its own outstanding work."
  ;; Human reply outstanding, bot has no open thread: human only.
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((bot_pending . t) (replies_to_me . t))))
                 "i "))
  ;; Both outstanding: both slots.
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((bot_replies_to_me . t) (replies_to_me . t)
                     (total_threads . 3) (unresolved_threads . 1))))
                 "iβ"))
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((replies_to_me . t))))
                 "i ")))

(ert-deftest decknix-hub-activity-icons--resolved-threads-are-addressed ()
  "Every thread resolved means the comment was addressed: no icon.

This settles a flip-flop, so the history matters. The original code
suppressed on resolution; on 2026-09-22 that was reversed because
platform-cli #41/#44 showed nothing while carrying `needs_reply\='; and it
is now restored, because the reversal made bot review summaries light the
HUMAN icon on four more PRs.

Both earlier positions were too coarse. The distinction that was missing
is ATTRIBUTION, not resolution: `needs_reply\=' means \"the last post was
not mine\", which is true of a bot. A human comment with no thread at all
still shows -- see `human-comment-with-no-threads-shows\=' -- so the #41/#44
case is kept where it is genuinely a human."
  (let ((pr '((total_threads . 22)
              (unresolved_threads . 0)
              (replies_to_me . t))))
    (should (string-empty-p (string-trim (decknix--hub-activity-icons pr))))))

(ert-deftest decknix-hub-activity-icons--resolved-threads-clear-both-slots ()
  "With every thread resolved nothing is outstanding, human or bot."
  (let ((pr '((total_threads . 22)
              (unresolved_threads . 0)
              (needs_reply . t)
              (replies_to_me . t)
              (review_decision . "REVIEW_REQUIRED"))))
    (should (string-empty-p (string-trim (decknix--hub-activity-icons pr))))))

(ert-deftest decknix-hub-activity-icons--bot-pending-shows-when-unresolved ()
  "Bot icon renders when unresolved_threads > 0 (actionable bot feedback)."
  (let ((pr '((total_threads . 22)
              (unresolved_threads . 3)
              (bot_pending . t))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-activity-icons pr))
                   " β"))))

(ert-deftest decknix-hub-activity-icons--no-thread-data-falls-back ()
  "No total_threads field: stream-based behaviour applies."
  (let ((pr '((needs_reply . t) (replies_to_me . t))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-activity-icons pr))
                   "i "))))

(ert-deftest decknix-hub-activity-icons--zero-total-threads-falls-back ()
  "total_threads = 0 means PR-level comments only, no inline threads.
Stream-based ladder still applies."
  (let ((pr '((total_threads . 0)
              (unresolved_threads . 0)
              (needs_reply . t))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-activity-icons pr))
                   "i "))))

;; -- activity-icons: emoji symbol style ----------------------------
;; The ASCII glyph set above is the default (`decknix--hub-symbol-style'
;; = 'ascii).  These tests pin the alternate emoji branch reachable via
;; the sidebar `y' toggle so both contracts stay covered.

(ert-deftest decknix-hub-activity-icons--emoji-style-human-replies ()
  "With symbol style 'emoji, replies-to-me renders ↩."
  (let ((decknix--hub-symbol-style 'emoji))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-activity-icons '((replies_to_me . t))))
                   "↩ "))))

(ert-deftest decknix-hub-activity-icons--emoji-style-needs-reply ()
  "With symbol style 'emoji, needs-reply renders 💬."
  (let ((decknix--hub-symbol-style 'emoji))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-activity-icons '((needs_reply . t))))
                   "💬 "))))

(ert-deftest decknix-hub-wip-reply-icon--delegates ()
  "Legacy name forwards to activity-icons."
  (should (equal (decknix--hub-wip-reply-icon
                  '((bot_pending . t)))
                 (decknix--hub-activity-icons
                  '((bot_pending . t))))))

;; -- author-icon: bot / bot+human / human provenance --------------

(ert-deftest decknix-hub-icons--author-icon-bot ()
  "author_kind \"bot\" -> π (bot-opened, only bot commits)."
  (should (equal "π" (decknix-test--icon-glyph
                      (decknix--hub-author-icon '((author_kind . "bot")))))))

(ert-deftest decknix-hub-icons--author-icon-bot-human-is-bold-omega ()
  "author_kind \"bot_human\" -> bold Ω (a human committed to a bot PR)."
  (let ((icon (decknix--hub-author-icon '((author_kind . "bot_human")))))
    (should (equal "Ω" (decknix-test--icon-glyph icon)))
    (should (eq 'bold (plist-get (decknix-test--icon-face icon) :weight)))))

(ert-deftest decknix-hub-icons--author-icon-human-is-plain-omega ()
  "author_kind \"human\" -> dim Ω (non-bold)."
  (let ((icon (decknix--hub-author-icon '((author_kind . "human")))))
    (should (equal "Ω" (decknix-test--icon-glyph icon)))
    (should (eq 'shadow (decknix-test--icon-face icon)))))

(ert-deftest decknix-hub-icons--author-icon-fallback-without-kind ()
  "Old data (no author_kind) degrades via the author login: a bot login
-> π (can't detect a human committer without commit data), else Ω."
  (should (equal "π" (decknix-test--icon-glyph
                      (decknix--hub-author-icon '((author . "dependabot[bot]"))))))
  (should (equal "Ω" (decknix-test--icon-glyph
                      (decknix--hub-author-icon '((author . "alice")))))))

(ert-deftest decknix-hub-icons--primary-status-bot-shows-state-not-pi ()
  "A bot-authored PR now shows its state glyph — provenance moved to the
author column, so the leading glyph is no longer replaced by π."
  (let ((item '((state . "OPEN")
                (author . "dependabot[bot]")
                (review_decision . "REVIEW_REQUIRED"))))
    (should (equal "◐" (decknix-test--icon-glyph
                        (decknix--hub-primary-status-icon item 'review))))))

(ert-deftest decknix-hub-icons--primary-status-placeholder ()
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-primary-status-icon '() 'placeholder))
                 "○")))

(ert-deftest decknix-hub-icons--primary-status-draft ()
  (let ((item '((state . "OPEN") (draft . t) (ci . ((status . "running"))))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-primary-status-icon item 'wip))
                   "★"))))

(ert-deftest decknix-hub-icons--primary-status-open-approved ()
  (let ((item '((state . "OPEN") (review_decision . "APPROVED"))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-primary-status-icon item 'wip))
                   "●"))))

(ert-deftest decknix-hub-icons--primary-status-open-approved-tc-fail ()
  "Approved but failing TeamCity build should be red.

The glyph is the BLOCKED one, not the approved one: a PR that does not
build is not ready for anything, whoever approved it, and the row should
say what is wrong rather than what went right."
  (let ((item '((state . "OPEN") (review_decision . "APPROVED")))
        (tc '((status . "FAILURE"))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-primary-status-icon item 'wip tc))
                   "⊖"))
    (should (equal (decknix-test--icon-face
                    (decknix--hub-primary-status-icon item 'wip tc))
                   'error))))

(ert-deftest decknix-hub-icons--primary-status-open-needs-review ()
  (let ((item '((state . "OPEN") (review_decision . "REVIEW_REQUIRED"))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-primary-status-icon item 'wip))
                   "◐"))))


(ert-deftest decknix-hub-icons--my-unreviewed-pr-is-not-green ()
  "Superseded `...-needs-review-ci-pass-is-green', which pinned the rule
that green meant `CI is fine'.

Colour now answers WHOSE MOVE.  `REVIEW_REQUIRED' is nobody-has-looked-yet
-- on my own PR that waits on a reviewer, so it is grey.  Painting it the
same green as approved-and-mergeable is what emptied the colour of
meaning: measured on followupboss-integration, eleven of twelve PRs were
green and none were approved."
  (let ((item '((state . "OPEN")
                (review_decision . "REVIEW_REQUIRED")
                (ci . ((status . "pass"))))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-primary-status-icon item 'wip))
                   "◐"))
    (should (equal (decknix-test--icon-face
                    (decknix--hub-primary-status-icon item 'wip))
                   'shadow))))

(ert-deftest decknix-hub-icons--a-pr-sent-to-me-unreviewed-is-amber ()
  "Same facts, opposite side: it waits on ME."
  (let ((item '((state . "OPEN")
                (review_decision . "REVIEW_REQUIRED")
                (ci . ((status . "pass"))))))
    (should (equal (decknix-test--icon-face
                    (decknix--hub-primary-status-icon item 'review))
                   'warning))))

(ert-deftest decknix-hub-icons--primary-status-open-approved-ci-fail ()
  "Approved but failing CI should be red, and read as BLOCKED.

An approved PR that does not build is not ready for anything; showing the
approved glyph in red said the opposite of what the row means."
  (let ((item '((state . "OPEN")
                 (review_decision . "APPROVED")
                 (ci . ((status . "fail"))))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-primary-status-icon item 'wip))
                   "⊖"))
    (should (equal (decknix-test--icon-face
                    (decknix--hub-primary-status-icon item 'wip))
                   'error))))

(ert-deftest decknix-hub-icons--primary-status-conflicting ()
  "Conflicting PRs use the square-with-dot glyph."
  (let ((item '((state . "OPEN")
                 (mergeable . "CONFLICTING"))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-primary-status-icon item 'wip))
                   "▣"))
    (should (equal (decknix-test--icon-face
                    (decknix--hub-primary-status-icon item 'wip))
                   'error))))

(ert-deftest decknix-hub-icons--primary-status-merged ()
  (let ((item '((state . "MERGED"))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-primary-status-icon item 'wip))
                   "■"))))

;; -- format-row-label ----------------------------------------------

(ert-deftest decknix-hub-icons/format-row-label-merged ()
  (should (equal (decknix--hub-format-row-label '((state . "MERGED"))) "merged")))

(ert-deftest decknix-hub-icons/format-row-label-closed ()
  (should (equal (decknix--hub-format-row-label '((state . "CLOSED"))) "closed")))

(ert-deftest decknix-hub-icons/format-row-label-conflict ()
  (should (equal (decknix--hub-format-row-label '((state . "OPEN") (mergeable . "CONFLICTING"))) "merge conflict")))

(ert-deftest decknix-hub-icons/format-row-label-draft ()
  (should (equal (decknix--hub-format-row-label '((state . "OPEN") (draft . t))) "drafting")))

(ert-deftest decknix-hub-icons/format-row-label-ci-failing ()
  (should (equal (decknix--hub-format-row-label '((state . "OPEN") (ci . ((status . "fail"))))) "CI failing")))

(ert-deftest decknix-hub-icons/format-row-label-ci-running ()
  (should (equal (decknix--hub-format-row-label '((state . "OPEN") (ci . ((status . "running"))))) "CI running")))

(ert-deftest decknix-hub-icons/format-row-label-awaiting-review ()
  (should (equal (decknix--hub-format-row-label '((state . "OPEN") (review_decision . "REVIEW_REQUIRED"))) "awaiting review")))

(ert-deftest decknix-hub-icons/format-row-label-approved ()
  (should (equal (decknix--hub-format-row-label '((state . "OPEN") (review_decision . "APPROVED"))) "approved")))


;; --- thread resolution must not hide a human reply -------------------
;;
;; Reported 2026-09-22: comments were added to nc-helix/platform-cli #41
;; and #44 and the sidebar showed nothing. The feed had the signals --
;; #44 `replies_to_me\=' t, `needs_reply\=' t, `total_threads\=' 4; #41
;; `needs_reply\=' t, `total_threads\=' 6 -- but BOTH had
;; `unresolved_threads\=' 0, and the Tier-1 suppression cleared every icon
;; whenever all inline threads were resolved.
;;
;; The rationale was sound for bots: "a bot trailing no suggestions
;; leaves nothing actionable". It over-reached to humans. Resolution is
;; usually done by the author or the bot, not by me, so a resolved thread
;; says nothing about whether I have read the reply in it.

(ert-deftest decknix-hub-icons--bot-noise-is-still-suppressed ()
  "The case the suppression was written for still works.
A bot posted and every thread is resolved: nothing actionable, rail clear."
  (let ((icons (decknix--hub-activity-icons
                '((bot_pending . t)
                  (total_threads . 3) (unresolved_threads . 0)))))
    (should (string-empty-p (string-trim icons)))))

(ert-deftest decknix-hub-icons--unresolved-threads-unaffected ()
  "With work outstanding, everything shows as before."
  (should-not (string-empty-p
               (string-trim (decknix--hub-activity-icons
                             '((needs_reply . t) (total_threads . 2)
                               (unresolved_threads . 1)))))))

(ert-deftest decknix-hub-icons--approved-still-clears-everything ()
  "Approval suppression is independent and unchanged."
  (should (string-empty-p
           (decknix--hub-activity-icons
            '((replies_to_me . t) (review_decision . "APPROVED")
              (total_threads . 4) (unresolved_threads . 0))))))


;; --- icons mean OUTSTANDING work, by author ---------------------------
;;
;; Revises the 2026-09-22 change, which removed thread-resolution gating
;; from the human slot entirely. That fixed silence on platform-cli #41
;; and #44 and over-corrected: `needs_reply\=' in the feed means "the last
;; post was not mine", NOT "a human posted", so bot review summaries lit
;; the human icon. Measured on the live feed, platform-cli #45-#48 all
;; carried `needs_reply\=' t with `bot_replies_to_me\=' t and zero
;; unresolved threads -- four rows shouting about bots that had finished.
;;
;; The rule the icons now encode:
;;   italic i  a HUMAN comment that is not yet addressed
;;   beta      an UNRESOLVED bot comment
;; A bot that reviewed and found nothing leaves no unresolved thread, so
;; it shows nothing.

(ert-deftest decknix-hub-icons--bot-review-with-no-findings-is-silent ()
  "The #45-#48 shape: bot replied, every thread resolved. Rail stays clear."
  (should (string-empty-p
           (string-trim
            (decknix--hub-activity-icons
             '((needs_reply . t) (bot_replies_to_me . t)
               (total_threads . 2) (unresolved_threads . 0)))))))

(ert-deftest decknix-hub-icons--bot-with-no-threads-at-all-is-silent ()
  "#46/#48: a bot summary and no threads. Its findings WOULD be threads."
  (should (string-empty-p
           (string-trim
            (decknix--hub-activity-icons
             '((needs_reply . t) (bot_replies_to_me . t)
               (total_threads . 0) (unresolved_threads . 0)))))))

(ert-deftest decknix-hub-icons--unresolved-bot-thread-shows-beta ()
  "A bot finding still open is exactly what the bot slot is for."
  (let ((icons (decknix--hub-activity-icons
                '((bot_replies_to_me . t)
                  (total_threads . 3) (unresolved_threads . 2)))))
    (should (string-match-p "\u03b2" icons))))

(ert-deftest decknix-hub-icons--i-replied-last-is-addressed ()
  "#49: I answered last, so nothing is outstanding whoever posted before."
  (should (string-empty-p
           (string-trim
            (decknix--hub-activity-icons
             '((i_replied_last . t) (total_threads . 2)
               (unresolved_threads . 0)))))))

(ert-deftest decknix-hub-icons--human-reply-to-me-always-shows ()
  "A person answering ME is outstanding until I answer back."
  (should-not (string-empty-p
               (string-trim
                (decknix--hub-activity-icons
                 '((replies_to_me . t) (total_threads . 0)
                   (unresolved_threads . 0)))))))

(ert-deftest decknix-hub-icons--human-comment-with-no-threads-shows ()
  "A PR-level human comment is never a thread, so resolution cannot gate it.
This is the platform-cli #41/#44 case that motivated the 09-22 change,
preserved: no bot attribution, no threads, latest post not mine."
  (should-not (string-empty-p
               (string-trim
                (decknix--hub-activity-icons
                 '((needs_reply . t) (total_threads . 0)
                   (unresolved_threads . 0)))))))

(ert-deftest decknix-hub-icons--human-thread-still-open-shows ()
  (should-not (string-empty-p
               (string-trim
                (decknix--hub-activity-icons
                 '((needs_reply . t) (total_threads . 2)
                   (unresolved_threads . 1)))))))

(ert-deftest decknix-hub-icons--waiting-on-them-needs-an-open-thread ()
  "`i_replied_last' with an OPEN thread means I am waiting on them.

Leaving a thread unresolved after replying is how you say \"still
waiting\", so it is a real state and gets the dim glyph. With nothing open
it is simply addressed and shows nothing -- that distinction is the whole
point, and an earlier pass collapsed both into silence."
  (should (string-empty-p
           (string-trim (decknix--hub-activity-icons '((i_replied_last . t))))))
  (should (string-empty-p
           (string-trim (decknix--hub-activity-icons
                         '((i_replied_last . t)
                           (total_threads . 2) (unresolved_threads . 0))))))
  (should-not (string-empty-p
               (string-trim (decknix--hub-activity-icons
                             '((i_replied_last . t)
                               (total_threads . 2) (unresolved_threads . 1)))))))

(ert-deftest decknix-hub-icons--a-human-reply-outranks-waiting ()
  "If they answered after me, that is a call to act, not a wait."
  (should (equal "i "
                 (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((i_replied_last . t) (replies_to_me . t)
                     (total_threads . 2) (unresolved_threads . 1)))))))

(ert-deftest decknix-hub-icons--emoji-style-bot-needs-an-open-thread ()
  "Emoji layout follows the same gating as ascii."
  (let ((decknix--hub-symbol-style 'emoji))
    (should (string-empty-p
             (string-trim (decknix--hub-activity-icons '((bot_pending . t))))))
    (should-not (string-empty-p
                 (string-trim (decknix--hub-activity-icons
                               '((bot_pending . t)
                                 (total_threads . 2) (unresolved_threads . 1))))))))

;; -- attributed feed: the glyph answers "should I read this?" ---------
;;
;; `needs_reply' means "the last post was not mine" -- it is set by a
;; bodiless APPROVED review and by a "LGTM" in the conversation tab, which
;; is why the italic `i' fired when nothing needed an answer.  Reported as
;; *"italic i doesn't necessarily mean there's a comment that needs to be
;; responded to"*.
;;
;; An attributed feed carries `human_unresolved' / `bot_unresolved' (the
;; inline threads split by who spoke last) and `human_said_something' (a
;; human wrote a NON-EMPTY body after my last activity).  Presence of the
;; integer counts is what selects these rules; a feed from an older hub
;; binary keeps the legacy ones.

(defun decknix-icons-test--attributed (&rest overrides)
  "A PR alist carrying the attributed fields, plus OVERRIDES."
  (append overrides
          '((human_unresolved . 0) (bot_unresolved . 0)
            (total_threads . 0) (unresolved_threads . 0))))

(ert-deftest decknix-hub-icons-attr--bodiless-approval-is-silent ()
  "An approval with no comment is good news, not a demand.
It sets `needs_reply' because a review record exists, which is the
sharpest of the false positives: it rendered as the same glyph as an
unanswered question."
  (should (string-empty-p
           (string-trim
            (decknix--hub-activity-icons
             (decknix-icons-test--attributed
              '(needs_reply . t) '(review_decision . "APPROVED")))))))

(ert-deftest decknix-hub-icons-attr--lgtm-conversation-comment-is-silent ()
  "A human comment with no substance left after me is not something to read.
`needs_reply' is t here -- the last post was theirs -- but no thread is
open and nothing was said after my last say."
  (should (string-empty-p
           (string-trim
            (decknix--hub-activity-icons
             (decknix-icons-test--attributed '(needs_reply . t)))))))

(ert-deftest decknix-hub-icons-attr--human-thread-open-shows-italic-i ()
  "An unresolved HUMAN thread is exactly what the glyph should mean."
  (let ((icons (decknix--hub-activity-icons
                (decknix-icons-test--attributed
                 '(human_unresolved . 1) '(unresolved_threads . 1)
                 '(total_threads . 1)))))
    (should (string-match-p "i" icons))))

(ert-deftest decknix-hub-icons-attr--human-substance-shows-without-a-thread ()
  "A conversation comment is never a thread, so counts cannot gate it.
`human_said_something' carries the PR-level case."
  (let ((icons (decknix--hub-activity-icons
                (decknix-icons-test--attributed
                 '(human_said_something . t)))))
    (should (string-match-p "i" icons))))

(ert-deftest decknix-hub-icons-attr--bot-thread-shows-beta-not-i ()
  "An open bot thread is a bot signal only.
Previously an open Copilot thread and a colleague's question were one
number, so a bot review lit the human glyph."
  (let ((icons (decknix--hub-activity-icons
                (decknix-icons-test--attributed
                 '(bot_unresolved . 2) '(unresolved_threads . 2)
                 '(total_threads . 2)))))
    (should (string-match-p "β" icons))
    (should-not (string-match-p "i" icons))))

(ert-deftest decknix-hub-icons-attr--bot-review-finding-nothing-is-silent ()
  "\"Reviewed, 0 items\" leaves no thread, so it must stay silent."
  (should (string-empty-p
           (string-trim
            (decknix--hub-activity-icons
             (decknix-icons-test--attributed
              '(bot_pending . t) '(needs_reply . t)))))))

(ert-deftest decknix-hub-icons-attr--both-slots-when-both-are-open ()
  "A human thread and a bot thread coexist in their own slots."
  (let ((icons (decknix--hub-activity-icons
                (decknix-icons-test--attributed
                 '(human_unresolved . 1) '(bot_unresolved . 1)
                 '(unresolved_threads . 2) '(total_threads . 2)))))
    (should (string-match-p "i" icons))
    (should (string-match-p "β" icons))))

(ert-deftest decknix-hub-icons-attr--resolved-human-thread-goes-quiet ()
  "Answering and resolving clears the glyph."
  (should (string-empty-p
           (string-trim
            (decknix--hub-activity-icons
             (decknix-icons-test--attributed
              '(total_threads . 3) '(needs_reply . t)))))))

(ert-deftest decknix-hub-icons-attr--approved-pr-still-shows-a-human-thread ()
  "Approval no longer suppresses a real comment.

The legacy path returns \"\" for any APPROVED PR, which hides an open
human thread on an approved PR -- precisely a comment worth considering.
With attribution available the fields decide instead of the decision."
  (let ((icons (decknix--hub-activity-icons
                (decknix-icons-test--attributed
                 '(review_decision . "APPROVED")
                 '(human_unresolved . 1) '(unresolved_threads . 1)
                 '(total_threads . 1)))))
    (should (string-match-p "i" icons))))

(ert-deftest decknix-hub-icons-attr--waiting-dot-survives ()
  "I replied and left the thread open: still \"waiting on them\", dimly.
Collapsing that into silence loses the distinction between an answered
thread and one deliberately left open."
  (let ((icons (decknix--hub-activity-icons
                (decknix-icons-test--attributed
                 '(i_replied_last . t) '(bot_unresolved . 0)
                 '(unresolved_threads . 1) '(total_threads . 1)))))
    (should (string-match-p "\\." icons))))

(ert-deftest decknix-hub-icons-attr--legacy-feed-keeps-legacy-rules ()
  "Absent counts select the old behaviour, not nil-as-zero.

The daemon keeps writing the old shape until it restarts, so a feed
without `human_unresolved' must behave exactly as before rather than
going silent across the board."
  (should-not (string-empty-p
               (string-trim
                (decknix--hub-activity-icons
                 '((needs_reply . t) (total_threads . 0)
                   (unresolved_threads . 0)))))))


;; -- a thread I replied to but never resolved --------------------------
;;
;; Reported on followupboss-integration#203: two open bot threads, no glyph.
;; The feed was self-consistent -- 56 total_threads, `unresolved_threads' 0,
;; `bot_unresolved' 0 -- because `unresolved_to_me' counts only threads whose
;; last commenter is NOT me, and I had replied on both. Still open, still
;; needing resolution, and invisible.

(ert-deftest decknix-hub-icons-attr--open-thread-i-replied-to-shows-waiting ()
  "Two threads open with me last: the dim waiting marker, not silence."
  (let ((icons (decknix--hub-activity-icons
                (decknix-icons-test--attributed
                 '(unresolved_total . 2)
                 '(total_threads . 56)
                 '(bot_replies_to_me . t)
                 '(needs_reply . t)))))
    (should-not (string-empty-p (string-trim icons)))
    (should (string-match-p "\\." icons))))

(ert-deftest decknix-hub-icons-attr--all-resolved-stays-silent ()
  "`unresolved_total' 0 across many threads is genuinely nothing to show."
  (should (string-empty-p
           (string-trim
            (decknix--hub-activity-icons
             (decknix-icons-test--attributed
              '(unresolved_total . 0) '(total_threads . 56)
              '(needs_reply . t)))))))

(ert-deftest decknix-hub-icons-attr--unresolved-total-does-not-mask-a-human ()
  "An open HUMAN thread still outranks the waiting marker."
  (let ((icons (decknix--hub-activity-icons
                (decknix-icons-test--attributed
                 '(unresolved_total . 3) '(human_unresolved . 1)
                 '(unresolved_threads . 1) '(total_threads . 3)))))
    (should (string-match-p "i" icons))))

(ert-deftest decknix-hub-icons-attr--unresolved-total-absent-falls-back ()
  "A feed without the field keeps the old behaviour rather than going quiet."
  (let ((icons (decknix--hub-activity-icons
                (decknix-icons-test--attributed
                 '(i_replied_last . t)
                 '(unresolved_threads . 1) '(total_threads . 1)))))
    (should (string-match-p "\\." icons))))


(provide 'decknix-hub-icons-test)
;;; decknix-hub-icons-test.el ends here
