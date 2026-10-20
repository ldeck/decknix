;;; decknix-agent-turn-ask-test.el --- What a closing question expects -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The fixtures are closing turns of real review sessions (anonymised), so
;; these pin the shapes that actually occur rather than ones imagined.

;;; Code:

(require 'ert)
(require 'decknix-agent-turn-ask)
(require 'decknix-review-gate-fixtures)

;; --- verdict ---

(ert-deftest decknix-turn-ask--verdict-from-each-plan-shape ()
  (should (equal "APPROVE" (decknix-agent-turn-ask-verdict
                            decknix-fixture-gate-yes-edit-cancel)))
  (should (equal "REQUEST_CHANGES" (decknix-agent-turn-ask-verdict
                                    decknix-fixture-gate-indented-plan)))
  (should (equal "APPROVE" (decknix-agent-turn-ask-verdict
                            decknix-fixture-gate-choose-one)))
  (should (equal "COMMENT" (decknix-agent-turn-ask-verdict
                            decknix-fixture-gate-heading-verdict))))

(ert-deftest decknix-turn-ask--verdict-unlabelled-fallback ()
  "An option naming the verdict is enough when no label does."
  (should (equal "APPROVE"
                 (decknix-agent-turn-ask-verdict
                  "The rest is the same.\n\n1. proceed — submit the APPROVE\n2. edit"))))

(ert-deftest decknix-turn-ask--verdict-not-from-prose ()
  "Lower-case mentions and headings are not verdicts."
  (should-not (decknix-agent-turn-ask-verdict "2. edit (change the verdict, or comment)"))
  (should-not (decknix-agent-turn-ask-verdict "INLINE COMMENTS\n---\nNone."))
  (should-not (decknix-agent-turn-ask-verdict decknix-fixture-statement))
  (should-not (decknix-agent-turn-ask-verdict nil)))

(ert-deftest decknix-turn-ask--verdict-last-wins ()
  "A plan revised after `edit' restates its verdict further down."
  (should (equal "REQUEST_CHANGES"
                 (decknix-agent-turn-ask-verdict
                  "Was: Verdict: APPROVE\n\nRevised plan\nVerdict: REQUEST_CHANGES\n\nReady to submit?"))))

;; --- posted ---

(ert-deftest decknix-turn-ask--posted-is-the-review-url ()
  (should (decknix-agent-turn-ask-posted-p decknix-fixture-posted))
  (should (decknix-agent-turn-ask-posted-p decknix-fixture-posted-then-asks))
  (should-not (decknix-agent-turn-ask-posted-p decknix-fixture-gate-choose-one))
  (should-not (decknix-agent-turn-ask-posted-p
               "See https://github.com/acme/widgets/pull/12 for the diff.")))

;; --- expected reply ---

(ert-deftest decknix-turn-ask--choose-one-block ()
  (let* ((reply (decknix-agent-turn-ask-reply decknix-fixture-gate-choose-one))
         (opts (plist-get reply :options)))
    (should (eq 'numbered (plist-get reply :kind)))
    (should (equal '(1 2 3) (mapcar (lambda (o) (plist-get o :number)) opts)))
    (should (equal '("yes" "edit" "cancel") (mapcar (lambda (o) (plist-get o :name)) opts)))
    (should (equal '(t nil nil) (mapcar (lambda (o) (plist-get o :recommended)) opts)))
    (should (equal "yes     (submit approval + 2 nits)"
                   (plist-get (car opts) :label)))
    (should (equal "1-3, rec 1" (decknix-agent-turn-ask-reply-label reply)))))

(ert-deftest decknix-turn-ask--choose-one-with-dashes-and-indented-reply-line ()
  (let ((reply (decknix-agent-turn-ask-reply decknix-fixture-gate-heading-verdict)))
    (should (eq 'numbered (plist-get reply :kind)))
    (should (equal '("proceed" "edit" "cancel")
                   (mapcar (lambda (o) (plist-get o :name)) (plist-get reply :options))))))

(ert-deftest decknix-turn-ask--words-after-the-question ()
  (let ((reply (decknix-agent-turn-ask-reply decknix-fixture-gate-yes-edit-cancel)))
    (should (eq 'words (plist-get reply :kind)))
    (should (equal '("yes" "edit" "cancel") (plist-get reply :words)))
    (should (equal "yes/edit/cancel" (decknix-agent-turn-ask-reply-label reply)))))

(ert-deftest decknix-turn-ask--yes-no ()
  (should (eq 'yes-no (plist-get (decknix-agent-turn-ask-reply "Push it? [y/N]") :kind)))
  (should (eq 'yes-no (plist-get (decknix-agent-turn-ask-reply
                                  "Rebased.\n\nShall I force-push?")
                                 :kind)))
  (should (eq 'yes-no (plist-get (decknix-agent-turn-ask-reply
                                  "Looks like the author reworked it. Want me to re-review the new head?")
                                 :kind)))
  (should (equal "yes/no" (decknix-agent-turn-ask-reply-label '(:kind yes-no)))))

(ert-deftest decknix-turn-ask--open-question ()
  "A question no yes, word or number answers gets no quick reply."
  (should (eq 'open (plist-get (decknix-agent-turn-ask-reply
                                "Which branch should this target?")
                               :kind))))

(ert-deftest decknix-turn-ask--a-numbered-list-mid-analysis-is-not-a-choice ()
  "Findings numbered 1-3 followed by more prose are not options."
  (should-not (decknix-agent-turn-ask-options
               "Findings:\n1. a race\n2. a leak\n3. a typo\n\nThe first is real.\nThe second is minor.\nThe third is cosmetic.\nOverall fine.\n\nShall I post it?")))

(ert-deftest decknix-turn-ask--numbering-must-start-at-one-and-run-in-order ()
  (should-not (decknix-agent-turn-ask-options "2. b\n3. c\n\nReply with the number."))
  (should-not (decknix-agent-turn-ask-options "1. a\n3. c\n\nReply with the number.")))

;; --- answering ---

(defun decknix-turn-ask-test--ask (text)
  (list :verdict (decknix-agent-turn-ask-verdict text)
        :reply (decknix-agent-turn-ask-reply text)))

(ert-deftest decknix-turn-ask--intent-of-a-reply ()
  (let ((numbered (decknix-turn-ask-test--ask decknix-fixture-gate-choose-one))
        (words (decknix-turn-ask-test--ask decknix-fixture-gate-yes-edit-cancel)))
    (should (eq 'affirm (decknix-agent-turn-ask-reply-intent numbered "1")))
    (should (eq 'other (decknix-agent-turn-ask-reply-intent numbered "2")))
    (should (eq 'cancel (decknix-agent-turn-ask-reply-intent numbered "3")))
    (should (eq 'affirm (decknix-agent-turn-ask-reply-intent words "yes")))
    (should (eq 'affirm (decknix-agent-turn-ask-reply-intent words "Yes please")))
    (should (eq 'other (decknix-agent-turn-ask-reply-intent words "make the nit shorter")))
    (should (eq 'cancel (decknix-agent-turn-ask-reply-intent words "cancel")))))

(ert-deftest decknix-turn-ask--quick-reply-numbered ()
  (let ((ask (decknix-turn-ask-test--ask decknix-fixture-gate-choose-one)))
    (should (equal '(:text "1" :label "yes     (submit approval + 2 nits)")
                   (decknix-agent-turn-ask-quick-reply ask 1)))
    (should (equal "3" (plist-get (decknix-agent-turn-ask-quick-reply ask 3) :text)))
    (should (plist-get (decknix-agent-turn-ask-quick-reply ask 4) :error))
    (should (plist-get (decknix-agent-turn-ask-quick-reply ask 'yes) :error))))

(ert-deftest decknix-turn-ask--quick-reply-yes ()
  (let ((words (decknix-turn-ask-test--ask decknix-fixture-gate-yes-edit-cancel))
        (open (decknix-turn-ask-test--ask "Which branch should this target?")))
    (should (equal "yes" (plist-get (decknix-agent-turn-ask-quick-reply words 'yes) :text)))
    (should (plist-get (decknix-agent-turn-ask-quick-reply words 2) :error))
    (should (plist-get (decknix-agent-turn-ask-quick-reply open 'yes) :error))
    (should (plist-get (decknix-agent-turn-ask-quick-reply nil 'yes) :error))))

(provide 'decknix-agent-turn-ask-test)
;;; decknix-agent-turn-ask-test.el ends here
