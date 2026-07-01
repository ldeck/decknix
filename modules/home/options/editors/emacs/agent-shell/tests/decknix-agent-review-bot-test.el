;;; decknix-agent-review-bot-test.el --- Tests for bot-aware review -*- lexical-binding: t -*-

(require 'ert)
(require 'decknix-agent-shell-main-link)

;; Mock variables from hub.  These mirror the on-disk JSON shapes that
;; `decknix--hub-read-json' parses with `:object-type 'alist':
;;   github-reviews.json -> ((updated . S) (viewer . S) (items . (ITEM...)))
;;   github-wip.json     -> ((updated . S) (repos . (((repo . S) (prs . (PR...)))...)))
;; A ReviewRequest carries a combined `repo' field ("owner/repo") and an
;; `author'; a WipPr carries neither owner/repo nor author.  The lookup
;; under test must descend into `items'/`repos' rather than walking the
;; wrapper's own top-level metadata cons cells.
(defvar decknix--hub-reviews nil)
(defvar decknix--hub-wip nil)

(ert-deftest decknix-agent-review-bot--hub-pr-author-finds-in-reviews ()
  "Finds author in the `items' wrapper of `decknix--hub-reviews'."
  (let ((decknix--hub-reviews
         '((updated . "2026-06-04T03:15:14.391062Z")
           (viewer . "me")
           (items . (((repo . "o/r") (number . 1) (author . "bot1"))))))
        (decknix--hub-wip nil))
    (should (equal "bot1" (decknix--agent-hub-pr-author "o" "r" 1)))))

(ert-deftest decknix-agent-review-bot--hub-pr-author-skips-wrapper-metadata ()
  "Wrapper metadata entries must not crash the lookup.
Regression for `Wrong type argument: listp, (updated . \"...\")':
the function used to iterate the wrapper alists' own top-level cons
cells (e.g. `(updated . S)') instead of descending into `items' /
`repos', so `alist-get' walked an improper cons and signalled."
  (let ((decknix--hub-reviews
         '((updated . "2026-06-04T03:15:14.391062Z")
           (viewer . "me")
           (items . (((repo . "o/r") (number . 2) (author . "human"))))))
        (decknix--hub-wip
         '((updated . "2026-06-04T03:15:14.391062Z")
           (repos . (((repo . "o/r")
                      (prs . (((number . 7) (title . "x"))))))))))
    ;; Must not signal; resolves the review author and ignores the
    ;; author-less WIP record.
    (should (equal "human" (decknix--agent-hub-pr-author "o" "r" 2)))
    (should (null (decknix--agent-hub-pr-author "o" "r" 7)))))

(ert-deftest decknix-agent-review-bot--hub-pr-author-string-number ()
  "Handles string PR numbers in hub data."
  (let ((decknix--hub-reviews
         '((items . (((repo . "o/r") (number . "1") (author . "bot1")))))))
    (should (equal "bot1" (decknix--agent-hub-pr-author "o" "r" 1)))))

(ert-deftest decknix-agent-review-bot--hub-pr-author-string-arg ()
  "Resolves author when NUMBER arg is a string (as parsed from a PR URL).
Regression for `cl--position: Wrong type argument: number-or-marker-p,
\"19088\"' when launching a review: `decknix--agent-parse-pr-url'
returns the PR number as a string, but the lookup predicate assumed an
integer and called `number-to-string' / `=' on it, signalling inside
`cl-find-if'.  Must resolve regardless of whether the hub record stores
the number as an integer or a string."
  ;; hub record carries an integer number; arg is the string "1"
  (let ((decknix--hub-reviews
         '((items . (((repo . "o/r") (number . 1) (author . "bot1"))))))
        (decknix--hub-wip nil))
    (should (equal "bot1" (decknix--agent-hub-pr-author "o" "r" "1"))))
  ;; hub record carries a string number; arg is also a string
  (let ((decknix--hub-reviews
         '((items . (((repo . "o/r") (number . "1") (author . "bot2"))))))
        (decknix--hub-wip nil))
    (should (equal "bot2" (decknix--agent-hub-pr-author "o" "r" "1")))))

(ert-deftest decknix-agent-review-bot--get-params-chooses-bot-vars ()
  "Chooses bot model, command, and provider when author matches bot-p.
The (provider, model) pair is sourced from the `bot-pr-review'
purpose in `decknix-agent-purpose-alist' -- so both slots move
together and a bot batch can be pinned to a different provider
than a human batch."
  (cl-letf (((symbol-function 'decknix--agent-pr-author)
             (lambda (_) "dependabot[bot]"))
            ((symbol-function 'decknix--hub-bot-author-p) (lambda (_) t))
            (decknix-agent-purpose-alist
             '((pr-review     . (:provider auggie      :model "reg-model"))
               (bot-pr-review . (:provider claude-code :model "bot-model"))))
            (decknix-agent-review-bot-pr-command "/bot-cmd"))
    (let ((params (decknix--agent-review-get-params "url")))
      (should (equal "bot-model"    (nth 0 params)))
      (should (equal "/bot-cmd"     (nth 1 params)))
      (should (eq    'claude-code   (nth 2 params))))))

(ert-deftest decknix-agent-review-bot--get-params-falls-back-to-regular ()
  "Falls back to the `pr-review' purpose for non-bot authors.
Provider must come from `pr-review', not `bot-pr-review'."
  (cl-letf (((symbol-function 'decknix--agent-pr-author) (lambda (_) "human"))
            ((symbol-function 'decknix--hub-bot-author-p) (lambda (_) nil))
            (decknix-agent-purpose-alist
             '((pr-review     . (:provider auggie      :model "reg-model"))
               (bot-pr-review . (:provider claude-code :model "bot-model")))))
    (let ((params (decknix--agent-review-get-params "url")))
      (should (equal "reg-model"          (nth 0 params)))
      (should (equal "/review-service-pr" (nth 1 params)))
      (should (eq    'auggie              (nth 2 params))))))

(provide 'decknix-agent-review-bot-test)
;;; decknix-agent-review-bot-test.el ends here
