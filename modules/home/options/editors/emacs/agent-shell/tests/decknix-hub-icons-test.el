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
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-wip-review-icon
                   '((review_decision . "REVIEW_REQUIRED"))))
                 "◐")))

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

(ert-deftest decknix-hub-activity-icons--bot-only ()
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((bot_pending . t))))
                 "🤖")))

(ert-deftest decknix-hub-activity-icons--needs-reply-only ()
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((needs_reply . t))))
                 "💬")))

(ert-deftest decknix-hub-activity-icons--bot-supersedes-needs-reply ()
  "Bot-pending and needs-reply both set: bot wins (cond branch order)."
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((bot_pending . t) (needs_reply . t))))
                 "🤖")))

(ert-deftest decknix-hub-activity-icons--replies-coexists ()
  "Replies-to-me appends after bot/needs-reply."
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((bot_pending . t) (replies_to_me . t))))
                 "🤖↩"))
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((needs_reply . t) (replies_to_me . t))))
                 "💬↩"))
  (should (equal (decknix-test--icon-glyph
                  (decknix--hub-activity-icons
                   '((replies_to_me . t))))
                 "↩")))

(ert-deftest decknix-hub-activity-icons--strict-eq-t ()
  "Flags must be eq to t — string \"true\" or 1 do not count."
  (should (equal (decknix--hub-activity-icons
                  '((bot_pending . "true") (needs_reply . 1))) "")))

;; -- wip-reply-icon: legacy alias ----------------------------------

(ert-deftest decknix-hub-wip-reply-icon--delegates ()
  "Legacy name forwards to activity-icons."
  (should (equal (decknix--hub-wip-reply-icon
                  '((bot_pending . t)))
                 (decknix--hub-activity-icons
                  '((bot_pending . t))))))

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
  "Approved but failing TeamCity build should be red."
  (let ((item '((state . "OPEN") (review_decision . "APPROVED")))
        (tc '((status . "FAILURE"))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-primary-status-icon item 'wip tc))
                   "●"))
    (should (equal (decknix-test--icon-face
                    (decknix--hub-primary-status-icon item 'wip tc))
                   'error))))

(ert-deftest decknix-hub-icons--primary-status-open-needs-review ()
  (let ((item '((state . "OPEN") (review_decision . "REVIEW_REQUIRED"))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-primary-status-icon item 'wip))
                   "◐"))))

(ert-deftest decknix-hub-icons--primary-status-open-approved-ci-fail ()
  "Approved but failing CI should be red."
  (let ((item '((state . "OPEN")
                 (review_decision . "APPROVED")
                 (ci . ((status . "fail"))))))
    (should (equal (decknix-test--icon-glyph
                    (decknix--hub-primary-status-icon item 'wip))
                   "●"))
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

;;; decknix-hub-icons-test.el ends here
