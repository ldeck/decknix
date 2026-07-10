;;; decknix-hub-attention-filter-test.el --- Tests for hub attention filters -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-attention-filter "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the hub attention filter cluster
;; extracted from the hub heredoc.  Covers the three-arg engine
;; predicate, the Requests / WIP flavoured wrappers, the sort
;; helper (oldest-first default + reverse flag + nil-created drift),
;; and the per-bucket toggle commands' set-and-message contract.
;;
;; Sidebar refresh side-effects inside `toggle-and-refresh' are
;; gated on `(fboundp 'agent-shell-workspace-sidebar-refresh)' so
;; tests never need to stub the workspace UI -- the function is
;; not bound during ert-batch.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-attention-filter)

;; -- defvar defaults ----------------------------------------------

(ert-deftest decknix-hub-attention-filter--defaults ()
  "Documented default values match the constants at module load."
  (should     decknix--hub-requests-hide-bot-pending)   ; default ON
  (should     decknix--hub-requests-hide-conflict)      ; default ON
  (should     decknix--hub-requests-hide-draft)         ; default ON
  (should     decknix--hub-requests-hide-i-replied-last) ; default ON
  (should (eq decknix--hub-requests-hide-reviewed 'hide-any)) ; default hide-any
  (should-not decknix--hub-requests-hide-needs-reply)
  (should-not decknix--hub-requests-only-my-replies)
  (should-not decknix--hub-requests-sort-reverse)
  (should-not decknix--hub-wip-hide-needs-reply)
  (should-not decknix--hub-wip-hide-bot-pending)
  (should-not decknix--hub-wip-only-my-replies))

;; -- attention-visible-p engine ----------------------------------

(ert-deftest decknix-hub-attention-filter--all-off-shows-everything ()
  "All toggles off => any item is visible regardless of signals."
  (let ((item-loud '((needs_reply . t) (bot_pending . t) (replies_to_me . t))))
    (should (decknix--hub-attention-visible-p item-loud nil nil nil))))

(ert-deftest decknix-hub-attention-filter--hide-reply-suppresses-non-bot ()
  "HIDE-REPLY hides items with needs_reply unless bot_pending also true."
  (let ((needs-only '((needs_reply . t) (bot_pending . :json-false)))
        (both       '((needs_reply . t) (bot_pending . t))))
    (should-not (decknix--hub-attention-visible-p needs-only t nil nil))
    ;; bot_pending wins -- the dedicated hide-bot toggle handles it.
    (should     (decknix--hub-attention-visible-p both t nil nil))))

(ert-deftest decknix-hub-attention-filter--hide-bot-suppresses-bot-pending ()
  "HIDE-BOT hides items with bot_pending."
  (let ((bot '((bot_pending . t))))
    (should-not (decknix--hub-attention-visible-p bot nil t nil))))

(ert-deftest decknix-hub-attention-filter--only-my-keeps-only-replies ()
  "ONLY-MY hides every item except those with replies_to_me or bot_replies_to_me."
  (let ((human-reply '((replies_to_me . t)))
        (bot-reply   '((bot_replies_to_me . t)))
        (none        '((replies_to_me . :json-false) (bot_replies_to_me . :json-false))))
    (should     (decknix--hub-attention-visible-p human-reply nil nil t))
    (should     (decknix--hub-attention-visible-p bot-reply   nil nil t))
    (should-not (decknix--hub-attention-visible-p none        nil nil t))))

;; -- requests-attention-visible-p / wip-attention-visible-p -------

(ert-deftest decknix-hub-attention-filter--requests-wrapper-uses-requests-state ()
  "Requests wrapper reads the Requests defvars, not WIP defvars."
  (let ((decknix--hub-requests-hide-bot-pending t)
        (decknix--hub-requests-hide-needs-reply nil)
        (decknix--hub-requests-only-my-replies  nil)
        (decknix--hub-wip-hide-bot-pending      nil)
        (item '((bot_pending . t))))
    (should-not (decknix--hub-requests-attention-visible-p item))))

(ert-deftest decknix-hub-attention-filter--wip-wrapper-uses-wip-state ()
  "WIP wrapper reads the WIP defvars, not Requests defvars."
  (let ((decknix--hub-requests-hide-bot-pending t)
        (decknix--hub-wip-hide-bot-pending      nil)
        (decknix--hub-wip-hide-needs-reply      nil)
        (decknix--hub-wip-only-my-replies       nil)
        (item '((bot_pending . t))))
    (should (decknix--hub-wip-attention-visible-p item))))

;; -- requests i-replied-last filter -------------------------------

(ert-deftest decknix-hub-attention-filter--i-replied-hidden-when-on ()
  "With the toggle on (default), a PR I commented last is hidden."
  (let ((decknix--hub-requests-hide-i-replied-last t)
        (mine '((i_replied_last . t))))
    (should-not (decknix--hub-requests-i-replied-visible-p mine))
    (should-not (decknix--hub-requests-attention-visible-p mine))))

(ert-deftest decknix-hub-attention-filter--i-replied-shown-when-off ()
  "With the toggle off, a PR I commented last is visible again."
  (let ((decknix--hub-requests-hide-i-replied-last nil)
        (mine '((i_replied_last . t))))
    (should (decknix--hub-requests-i-replied-visible-p mine))
    (should (decknix--hub-requests-attention-visible-p mine))))

(ert-deftest decknix-hub-attention-filter--i-replied-absent-never-suppressed ()
  "An absent or :json-false i_replied_last field is treated as not-mine."
  (let ((decknix--hub-requests-hide-i-replied-last t)
        (absent '((needs_reply . t)))
        (false  '((i_replied_last . :json-false))))
    (should (decknix--hub-requests-i-replied-visible-p absent))
    (should (decknix--hub-requests-i-replied-visible-p false))))

(ert-deftest decknix-hub-attention-filter--i-replied-toggle-flips ()
  "The toggle command flips the Requests i-replied-last state."
  (let ((decknix--hub-requests-hide-i-replied-last t))
    (call-interactively #'decknix--hub-toggle-requests-hide-i-replied-last)
    (should-not decknix--hub-requests-hide-i-replied-last)
    (call-interactively #'decknix--hub-toggle-requests-hide-i-replied-last)
    (should decknix--hub-requests-hide-i-replied-last)))

;; -- request-activity-time ----------------------------------------

(ert-deftest decknix-hub-attention-filter--activity-time-prefers-updated ()
  "Activity time returns `updated' when present (even if older than created)."
  (should (equal "2025-01-10"
                 (decknix--hub-request-activity-time
                  '((created . "2025-01-05") (updated . "2025-01-10")))))
  ;; `updated' wins unconditionally — it is not a max, it is a preference.
  (should (equal "2025-01-01"
                 (decknix--hub-request-activity-time
                  '((created . "2025-01-05") (updated . "2025-01-01"))))))

(ert-deftest decknix-hub-attention-filter--activity-time-falls-back-to-created ()
  "Activity time falls back to `created' when `updated' is absent or nil."
  (should (equal "2025-01-05"
                 (decknix--hub-request-activity-time '((created . "2025-01-05")))))
  (should (equal "2025-01-05"
                 (decknix--hub-request-activity-time
                  '((created . "2025-01-05") (updated . nil))))))

(ert-deftest decknix-hub-attention-filter--activity-time-nil-when-neither ()
  "Activity time is nil when neither `updated' nor `created' is present."
  (should-not (decknix--hub-request-activity-time '((id . 1)))))

;; -- sort-requests ------------------------------------------------

(ert-deftest decknix-hub-attention-filter--sort-newest-first-by-default ()
  "Default sort (nil) puts the most-recently-updated item first.
Falls back to `created' when `updated' is absent."
  ;; Items with only `created' — newer created at top.
  (let* ((items '(((id . 1) (created . "2025-01-01"))
                  ((id . 2) (created . "2025-01-02"))))
         (decknix--hub-requests-sort-reverse nil)
         (sorted (decknix--hub-sort-requests items)))
    (should (equal '(2 1) (mapcar (lambda (i) (alist-get 'id i)) sorted)))))

(ert-deftest decknix-hub-attention-filter--sort-reverse-flips ()
  "`sort-reverse' non-nil sorts oldest-first."
  (let* ((items '(((id . 2) (created . "2025-01-02"))
                  ((id . 1) (created . "2025-01-01"))))
         (decknix--hub-requests-sort-reverse t)
         (sorted (decknix--hub-sort-requests items)))
    (should (equal '(1 2) (mapcar (lambda (i) (alist-get 'id i)) sorted)))))

(ert-deftest decknix-hub-attention-filter--sort-uses-updated-over-created ()
  "`updated' is preferred over `created' as the sort key.
Item with older `created' but newer `updated' sorts first by default."
  (let* (;; id=1: created 2025-01-01, updated 2025-01-10 (most recently active)
         ;; id=2: created 2025-01-05, no updated
         (items '(((id . 2) (created . "2025-01-05"))
                  ((id . 1) (created . "2025-01-01") (updated . "2025-01-10"))))
         (decknix--hub-requests-sort-reverse nil)
         (sorted (decknix--hub-sort-requests items)))
    (should (equal '(1 2) (mapcar (lambda (i) (alist-get 'id i)) sorted)))))

(ert-deftest decknix-hub-attention-filter--sort-falls-back-to-created ()
  "When `updated' is absent the sort key falls back to `created'."
  (let* ((items '(((id . 1) (created . "2025-01-01"))
                  ((id . 2) (created . "2025-01-03"))))
         (decknix--hub-requests-sort-reverse nil)
         (sorted (decknix--hub-sort-requests items)))
    (should (equal '(2 1) (mapcar (lambda (i) (alist-get 'id i)) sorted)))))

(ert-deftest decknix-hub-attention-filter--sort-nil-key-drifts-last ()
  "Items missing both `updated' and `created' sort to the end in either direction."
  (let* ((items '(((id . 1))
                  ((id . 2) (created . "2025-01-01"))))
         (decknix--hub-requests-sort-reverse nil)
         (sorted (decknix--hub-sort-requests items)))
    (should (equal '(2 1) (mapcar (lambda (i) (alist-get 'id i)) sorted))))
  (let* ((items '(((id . 1))
                  ((id . 2) (created . "2025-01-01"))))
         (decknix--hub-requests-sort-reverse t)
         (sorted (decknix--hub-sort-requests items)))
    (should (equal '(2 1) (mapcar (lambda (i) (alist-get 'id i)) sorted)))))

(ert-deftest decknix-hub-attention-filter--sort-does-not-mutate-input ()
  "Caller's list is not modified -- sort runs on a copy."
  (let* ((items '(((id . 2) (created . "2025-01-02"))
                  ((id . 1) (created . "2025-01-01"))))
         (snapshot (copy-sequence items)))
    (decknix--hub-sort-requests items)
    (should (equal snapshot items))))

;; -- toggle commands ----------------------------------------------

(ert-deftest decknix-hub-attention-filter--toggle-and-refresh-flips-symbol ()
  "`toggle-and-refresh' sets the symbol to its negation and messages."
  (let ((decknix--hub-requests-only-my-replies nil))
    (decknix--hub-toggle-and-refresh
     'decknix--hub-requests-only-my-replies "test: %s")
    (should decknix--hub-requests-only-my-replies)
    (decknix--hub-toggle-and-refresh
     'decknix--hub-requests-only-my-replies "test: %s")
    (should-not decknix--hub-requests-only-my-replies)))

(ert-deftest decknix-hub-attention-filter--per-bucket-toggle-flips-state ()
  "Each interactive bucket toggle flips its own defvar."
  (let ((decknix--hub-requests-hide-needs-reply nil))
    (call-interactively #'decknix--hub-toggle-requests-hide-needs-reply)
    (should decknix--hub-requests-hide-needs-reply))
  (let ((decknix--hub-wip-only-my-replies nil))
    (call-interactively #'decknix--hub-toggle-wip-only-my-replies)
    (should decknix--hub-wip-only-my-replies)))

;; -- conflict filter ----------------------------------------------

(ert-deftest decknix-hub-attention-filter--conflict-default-is-on ()
  "decknix--hub-requests-hide-conflict defaults to t (hide conflicts)."
  (should decknix--hub-requests-hide-conflict))

(ert-deftest decknix-hub-attention-filter--conflict-hides-conflicting ()
  "Conflict filter hides items with mergeable = CONFLICTING when on."
  (let ((item '((mergeable . "CONFLICTING")))
        (decknix--hub-requests-hide-conflict t))
    (should-not (decknix--hub-requests-conflict-visible-p item))))

(ert-deftest decknix-hub-attention-filter--conflict-shows-non-conflicting ()
  "Conflict filter passes items that are not CONFLICTING."
  (let ((mergeable-item '((mergeable . "MERGEABLE")))
        (nil-item       '((mergeable . nil)))
        (absent-item    '())
        (decknix--hub-requests-hide-conflict t))
    (should (decknix--hub-requests-conflict-visible-p mergeable-item))
    (should (decknix--hub-requests-conflict-visible-p nil-item))
    (should (decknix--hub-requests-conflict-visible-p absent-item))))

(ert-deftest decknix-hub-attention-filter--conflict-filter-off-shows-all ()
  "When the conflict filter is off, CONFLICTING items are visible."
  (let ((item '((mergeable . "CONFLICTING")))
        (decknix--hub-requests-hide-conflict nil))
    (should (decknix--hub-requests-conflict-visible-p item))))

(ert-deftest decknix-hub-attention-filter--conflict-toggle-flips-state ()
  "Interactive toggle flips decknix--hub-requests-hide-conflict."
  (let ((decknix--hub-requests-hide-conflict nil))
    (call-interactively #'decknix--hub-toggle-requests-hide-conflict)
    (should decknix--hub-requests-hide-conflict))
  (let ((decknix--hub-requests-hide-conflict t))
    (call-interactively #'decknix--hub-toggle-requests-hide-conflict)
    (should-not decknix--hub-requests-hide-conflict)))

;; -- draft filter -------------------------------------------------

(ert-deftest decknix-hub-attention-filter--draft-default-is-on ()
  "decknix--hub-requests-hide-draft defaults to t (hide drafts)."
  (should decknix--hub-requests-hide-draft))

(ert-deftest decknix-hub-attention-filter--draft-hides-drafts ()
  "Draft filter hides items with draft = t when on."
  (let ((item '((draft . t)))
        (decknix--hub-requests-hide-draft t))
    (should-not (decknix--hub-requests-draft-visible-p item))))

(ert-deftest decknix-hub-attention-filter--draft-shows-non-drafts ()
  "Draft filter passes items that are not drafts.
A nil, :json-false, or absent draft field is treated as non-draft so
ready PRs are never inadvertently suppressed."
  (let ((false-item '((draft . :json-false)))
        (nil-item    '((draft . nil)))
        (absent-item '())
        (decknix--hub-requests-hide-draft t))
    (should (decknix--hub-requests-draft-visible-p false-item))
    (should (decknix--hub-requests-draft-visible-p nil-item))
    (should (decknix--hub-requests-draft-visible-p absent-item))))

(ert-deftest decknix-hub-attention-filter--draft-filter-off-shows-all ()
  "When the draft filter is off, draft items are visible."
  (let ((item '((draft . t)))
        (decknix--hub-requests-hide-draft nil))
    (should (decknix--hub-requests-draft-visible-p item))))

(ert-deftest decknix-hub-attention-filter--draft-toggle-flips-state ()
  "Interactive toggle flips decknix--hub-requests-hide-draft."
  (let ((decknix--hub-requests-hide-draft nil))
    (call-interactively #'decknix--hub-toggle-requests-hide-draft)
    (should decknix--hub-requests-hide-draft))
  (let ((decknix--hub-requests-hide-draft t))
    (call-interactively #'decknix--hub-toggle-requests-hide-draft)
    (should-not decknix--hub-requests-hide-draft)))

;; -- hide-reviewed filter (3-state cycle) ------------------------

(ert-deftest decknix-hub-attention-filter--hide-reviewed-nil-shows-all ()
  "State nil: all items are visible regardless of review outcome."
  (let ((decknix--hub-requests-hide-reviewed nil))
    ;; I approved, not mentioned
    (should (decknix--hub-requests-reviewed-visible-p
             '((my_review . "APPROVED") (mentioned . :json-false))))
    ;; Colleague approved, not mentioned
    (should (decknix--hub-requests-reviewed-visible-p
             '((my_review . nil) (review_decision . "APPROVED")
               (mentioned . :json-false))))))

(ert-deftest decknix-hub-attention-filter--hide-reviewed-hide-mine-hides-my-review ()
  "State hide-mine: hides PRs where I approved, requested changes, or commented."
  (let ((decknix--hub-requests-hide-reviewed 'hide-mine))
    (should-not (decknix--hub-requests-reviewed-visible-p
                 '((my_review . "APPROVED") (mentioned . :json-false))))
    (should-not (decknix--hub-requests-reviewed-visible-p
                 '((my_review . "CHANGES_REQUESTED") (mentioned . :json-false))))
    ;; COMMENTED now counts as "I have had my say" too.
    (should-not (decknix--hub-requests-reviewed-visible-p
                 '((my_review . "COMMENTED") (mentioned . :json-false))))))

(ert-deftest decknix-hub-attention-filter--hide-reviewed-hide-mine-shows-colleague-approved ()
  "State hide-mine: still shows PRs where only a colleague approved."
  (let ((decknix--hub-requests-hide-reviewed 'hide-mine))
    (should (decknix--hub-requests-reviewed-visible-p
             '((my_review . nil) (review_decision . "APPROVED")
               (mentioned . :json-false))))))

(ert-deftest decknix-hub-attention-filter--hide-reviewed-hide-any-hides-all-concluded ()
  "State hide-any: hides PRs where any conclusive review outcome exists."
  (let ((decknix--hub-requests-hide-reviewed 'hide-any))
    ;; I approved
    (should-not (decknix--hub-requests-reviewed-visible-p
                 '((my_review . "APPROVED") (mentioned . :json-false))))
    ;; Colleague approved (review_decision)
    (should-not (decknix--hub-requests-reviewed-visible-p
                 '((my_review . nil) (review_decision . "APPROVED")
                   (mentioned . :json-false))))
    ;; Colleague has a standing review via others_reviewed, even when the
    ;; aggregate review_decision is not yet conclusive (e.g. COMMENTED).
    (should-not (decknix--hub-requests-reviewed-visible-p
                 '((my_review . nil) (review_decision . "REVIEW_REQUIRED")
                   (others_reviewed . t) (mentioned . :json-false))))))

(ert-deftest decknix-hub-attention-filter--hide-reviewed-approved-not-forced-by-request ()
  "Being a currently-requested reviewer must NOT force an approved PR to show.
This is the regression the blanket `mentioned' override caused: a PR a
colleague already approved, on which I am still an individually-requested
reviewer, was always shown under hide-any.  It must now be hidden."
  (let ((item '((my_review . nil) (review_decision . "APPROVED")
                (others_reviewed . t) (mentioned . t)
                (re_requested . :json-false)
                (comment_mentioned . :json-false)
                (review_stale . :json-false))))
    (let ((decknix--hub-requests-hide-reviewed 'hide-any))
      (should-not (decknix--hub-requests-reviewed-visible-p item)))))

(ert-deftest decknix-hub-attention-filter--hide-reviewed-re-request-resurfaces ()
  "A genuine re-request (re_requested = t) resurfaces a reviewed PR."
  (let ((item '((my_review . "APPROVED") (review_decision . "APPROVED")
                (re_requested . t))))
    (let ((decknix--hub-requests-hide-reviewed 'hide-mine))
      (should (decknix--hub-requests-reviewed-visible-p item)))
    (let ((decknix--hub-requests-hide-reviewed 'hide-any))
      (should (decknix--hub-requests-reviewed-visible-p item)))))

(ert-deftest decknix-hub-attention-filter--hide-reviewed-comment-mention-resurfaces ()
  "A direct @-mention (comment_mentioned = t) resurfaces a reviewed PR."
  (let ((item '((my_review . nil) (review_decision . "APPROVED")
                (others_reviewed . t) (comment_mentioned . t))))
    (let ((decknix--hub-requests-hide-reviewed 'hide-any))
      (should (decknix--hub-requests-reviewed-visible-p item)))))

(ert-deftest decknix-hub-attention-filter--hide-reviewed-stale-resurfaces ()
  "A stale review (review_stale = t) resurfaces the PR for another look."
  ;; hide-mine: I approved, but the author has since pushed / resolved.
  (let ((item '((my_review . "APPROVED") (review_stale . t))))
    (let ((decknix--hub-requests-hide-reviewed 'hide-mine))
      (should (decknix--hub-requests-reviewed-visible-p item)))
    ;; hide-any: a colleague concluded, but it has since moved forward.
    (let ((decknix--hub-requests-hide-reviewed 'hide-any))
      (should (decknix--hub-requests-reviewed-visible-p
               '((review_decision . "CHANGES_REQUESTED") (review_stale . t))))))
  ;; But when the filter is nil everything shows regardless (sanity).
  (let ((decknix--hub-requests-hide-reviewed nil))
    (should (decknix--hub-requests-reviewed-visible-p
             '((my_review . "APPROVED") (review_stale . :json-false))))))

(ert-deftest decknix-hub-attention-filter--hide-reviewed-label ()
  "`decknix--hub-requests-reviewed-label' returns the right short string."
  (let ((decknix--hub-requests-hide-reviewed nil))
    (should (string= "show" (decknix--hub-requests-reviewed-label))))
  (let ((decknix--hub-requests-hide-reviewed 'hide-mine))
    (should (string= "hide-mine" (decknix--hub-requests-reviewed-label))))
  (let ((decknix--hub-requests-hide-reviewed 'hide-any))
    (should (string= "hide-any" (decknix--hub-requests-reviewed-label)))))

(ert-deftest decknix-hub-attention-filter--hide-reviewed-cycle-advances-state ()
  "Cycle advances nil → hide-mine → hide-any → nil."
  (let ((decknix--hub-requests-hide-reviewed nil))
    (call-interactively #'decknix--hub-cycle-requests-hide-reviewed)
    (should (eq decknix--hub-requests-hide-reviewed 'hide-mine))
    (call-interactively #'decknix--hub-cycle-requests-hide-reviewed)
    (should (eq decknix--hub-requests-hide-reviewed 'hide-any))
    (call-interactively #'decknix--hub-cycle-requests-hide-reviewed)
    (should (eq decknix--hub-requests-hide-reviewed nil))))

(provide 'decknix-hub-attention-filter-test)
;;; decknix-hub-attention-filter-test.el ends here
