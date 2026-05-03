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
  "ONLY-MY hides every item except those with replies_to_me."
  (let ((mine    '((replies_to_me . t)))
        (other   '((replies_to_me . :json-false))))
    (should     (decknix--hub-attention-visible-p mine  nil nil t))
    (should-not (decknix--hub-attention-visible-p other nil nil t))))

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

;; -- sort-requests ------------------------------------------------

(ert-deftest decknix-hub-attention-filter--sort-oldest-first-by-default ()
  "Default sort puts the older `created' first."
  (let* ((items '(((id . 2) (created . "2025-01-02"))
                  ((id . 1) (created . "2025-01-01"))))
         (decknix--hub-requests-sort-reverse nil)
         (sorted (decknix--hub-sort-requests items)))
    (should (equal '(1 2) (mapcar (lambda (i) (alist-get 'id i)) sorted)))))

(ert-deftest decknix-hub-attention-filter--sort-reverse-flips ()
  "`sort-reverse' non-nil sorts newest-first."
  (let* ((items '(((id . 1) (created . "2025-01-01"))
                  ((id . 2) (created . "2025-01-02"))))
         (decknix--hub-requests-sort-reverse t)
         (sorted (decknix--hub-sort-requests items)))
    (should (equal '(2 1) (mapcar (lambda (i) (alist-get 'id i)) sorted)))))

(ert-deftest decknix-hub-attention-filter--sort-nil-created-drifts-last ()
  "Items missing `created' sort to the end in either direction."
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

(provide 'decknix-hub-attention-filter-test)
;;; decknix-hub-attention-filter-test.el ends here
