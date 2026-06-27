;;; decknix-auto-review.el --- Auto-dispatch PR review sessions -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, review

;;; Commentary:
;;
;; Pure helper layer for auto-dispatching agent review sessions for
;; incoming PR review requests surfaced by the hub.  A single 4-state
;; toggle decides whether (and which) review requests spawn a session
;; automatically:
;;
;;   off    -> disabled (default).
;;   bot    -> bot-authored PRs that @-mention me (ship flow).
;;   human  -> human-authored PRs that @-mention me (review flow).
;;   any    -> both (bots ship, humans review).
;;
;; EVERY active state additionally requires the PR to @-mention me.
;; This is the deliberate safety guard: auto-spawning a review session
;; consumes agent credits, so team-noise PRs (where I am not directly
;; addressed) never trigger a dispatch.
;;
;; This file is side-effect free.  The dispatch wiring (scanning the hub
;; cache, resolving the workspace, calling `decknix--agent-quickaction-start',
;; and the file-notify advice) lives in the heredoc per AGENTS.md Rule 2.
;; Bot/mention classification of a given request is supplied by the hub
;; predicates (`decknix--hub-bot-author-p', `decknix--hub-item-mentioned-p')
;; — this layer takes the resulting booleans so it stays pure and testable.

;;; Code:

(require 'cl-lib)
(require 'seq)

(defconst decknix-auto-review-states '(off bot human any)
  "Ordered cycle of auto-review states.
See the Commentary for the meaning of each.")

(defvar decknix-auto-review-mode 'off
  "Current auto-review state; one of `decknix-auto-review-states'.")

(defvar decknix-auto-review-default-review-command "/review-service-pr-factory"
  "Slash command sent for human-authored auto-review dispatch.
Runs the background review-factory flow so the verdict is ready to
inspect later; the session surfaces via the attention indicator.")

(defvar decknix-auto-review-default-ship-command "/review-and-ship-bot-pr"
  "Slash command sent for bot-authored auto-review dispatch.")

(defvar decknix-auto-review-commands nil
  "Per-workspace command overrides.
Alist of (WORKSPACE . PLIST) where WORKSPACE is a path string and
PLIST may contain `:review' and/or `:ship' command strings.  Matching
is path-normalised via `expand-file-name'.  A missing key for the
requested action falls back to the matching global default.")

(defvar decknix-auto-review--dispatched (make-hash-table :test 'equal)
  "Set of dispatch keys already auto-dispatched this session.
Guards against re-dispatch on every file-notify tick in the window
between launching a session and its buffer appearing (the live-session
guard takes over once the buffer exists).")

;; External symbols resolved at runtime.  Declared here so this file
;; byte-compiles clean in isolation (it has no `packageRequires');
;; the dispatch orchestration below calls them only when the hub /
;; main-link modules are actually loaded.  Value-less `defvar' marks
;; the hub/model vars special so references compile as dynamic
;; varrefs against the live globals.
(declare-function decknix--hub-bot-author-p "decknix-hub-mention-bot")
(declare-function decknix--hub-item-mentioned-p "decknix-hub-mention-bot")
(declare-function decknix--hub-request-has-live-session-p "decknix-agent-shell-hub")
(declare-function decknix--agent-pr-detect-workspace "decknix-agent-shell-main-link")
(declare-function decknix--agent-quickaction-start "decknix-agent-shell-main-link")
(declare-function agent-shell-workspace-sidebar-refresh "agent-shell-workspace")
(defvar decknix--hub-reviews)
(defvar decknix-agent-review-pr-model)
(defvar decknix-agent-review-bot-pr-model)
(defvar agent-shell-workspace-sidebar-buffer-name "*Agent Sidebar*")

;; -- State cycle ----------------------------------------------------

(defun decknix-auto-review-next-state (state)
  "Return the state after STATE in `decknix-auto-review-states'.
An unrecognised STATE resets the cycle to `off'."
  (let ((tail (cdr (memq state decknix-auto-review-states))))
    (or (car tail) 'off)))

(defun decknix-auto-review-state-label (state)
  "Return a short human label for STATE.
Active states carry a trailing `+@' to advertise the mention guard."
  (pcase state
    ('bot   "bot+@")
    ('human "human+@")
    ('any   "any+@")
    (_      "off")))

;; -- Item action classifier ----------------------------------------

(defun decknix-auto-review-item-action (state bot-p mentioned-p)
  "Return the dispatch action for a PR under STATE.
BOT-P is non-nil when the PR author is a bot; MENTIONED-P is non-nil
when the PR @-mentions me (directly requested or named in a comment).
Returns `ship' (bot ship-flow), `review' (human review-flow), or nil
when the PR should not be auto-dispatched.  All active states require
MENTIONED-P."
  (when (and mentioned-p (not (eq state 'off)))
    (pcase state
      ('bot   (and bot-p 'ship))
      ('human (and (not bot-p) 'review))
      ('any   (if bot-p 'ship 'review))
      (_      nil))))

;; -- Command resolution --------------------------------------------

(defun decknix-auto-review-resolve-command (action workspace)
  "Return the slash command string for ACTION in WORKSPACE.
ACTION is `ship' or `review'.  A `decknix-auto-review-commands' entry
whose car path-matches WORKSPACE wins; otherwise the matching global
default is used."
  (let* ((ws (and workspace
                  (directory-file-name (expand-file-name workspace))))
         (entry (and ws (seq-find
                         (lambda (e)
                           (string= ws (directory-file-name
                                        (expand-file-name (car e)))))
                         decknix-auto-review-commands)))
         (plist (cdr entry))
         (key (if (eq action 'ship) :ship :review))
         (default (if (eq action 'ship)
                      decknix-auto-review-default-ship-command
                    decknix-auto-review-default-review-command)))
    (or (and plist (plist-get plist key)) default)))

;; -- Dedup keys -----------------------------------------------------

(defun decknix-auto-review-dispatch-key (repo number)
  "Return a stable dedup key string for REPO and NUMBER.
NUMBER is normalised so int and string forms collapse to one key."
  (format "%s#%s" repo (if (numberp number)
                           (number-to-string number)
                         number)))

(defun decknix-auto-review-dispatched-p (key)
  "Return non-nil when KEY has already been auto-dispatched."
  (and (gethash key decknix-auto-review--dispatched) t))

(defun decknix-auto-review-mark-dispatched (key)
  "Record KEY as auto-dispatched."
  (puthash key t decknix-auto-review--dispatched))

;; -- Dispatch orchestration ----------------------------------------
;;
;; These read live hub state and spawn sessions, so they call the
;; forward-declared hub / main-link helpers above.  Pure decisions are
;; delegated to the tested helpers; this layer is the I/O glue.  The
;; `:after' advice that drives `decknix-auto-review--maybe-dispatch'
;; on every reviews refresh is wired in the heredoc (a side-effect,
;; per AGENTS.md Rule 2).

(defun decknix-auto-review--dispatch-item (item)
  "Auto-dispatch a review session for hub review ITEM when eligible.
Returns the action used (`ship'/`review') or nil when skipped.
Skips when: no action applies under the current state, a live review
session already exists for the PR, or it was already dispatched this
Emacs session (dedup guards the file-notify->buffer-appears window)."
  (let* ((bot-p (decknix--hub-bot-author-p (alist-get 'author item)))
         (mentioned-p (decknix--hub-item-mentioned-p item))
         (action (decknix-auto-review-item-action
                  decknix-auto-review-mode bot-p mentioned-p)))
    (when action
      (let* ((repo-full (or (alist-get 'repo item) ""))
             (parts (split-string repo-full "/"))
             (owner (car parts))
             (repo (car (last parts)))
             (number (alist-get 'number item))
             (url (alist-get 'url item))
             (key (decknix-auto-review-dispatch-key repo-full number)))
        (when (and url (not (string-empty-p owner)) repo number
                   (not (decknix-auto-review-dispatched-p key))
                   (not (decknix--hub-request-has-live-session-p item)))
          (let* ((name (format "pr-%s-%s" repo number))
                 (tags (list "review" repo (format "#%s" number) "auto"))
                 (workspace (decknix--agent-pr-detect-workspace owner repo))
                 (command-base (decknix-auto-review-resolve-command
                                action workspace))
                 (model (if (eq action 'ship)
                            (or decknix-agent-review-bot-pr-model
                                decknix-agent-review-pr-model)
                          decknix-agent-review-pr-model))
                 (command (format "%s %s" command-base url)))
            ;; Mark before launching so a second file-notify tick during
            ;; session startup can't double-dispatch.
            (decknix-auto-review-mark-dispatched key)
            (decknix--agent-quickaction-start name tags workspace command model)
            (message "[auto-review] %s %s/%s#%s via %s"
                     action owner repo number command-base)
            action))))))

(defun decknix-auto-review--maybe-dispatch (&rest _)
  "Scan hub reviews and auto-dispatch eligible sessions.
No-op when `decknix-auto-review-mode' is `off'.  Wired as `:after'
advice on `decknix--hub-refresh-reviews' so it fires whenever the
reviews data is (re)loaded — i.e. on every file-notify refresh."
  (when (and (not (eq decknix-auto-review-mode 'off))
             (boundp 'decknix--hub-reviews)
             decknix--hub-reviews)
    (dolist (item (alist-get 'items decknix--hub-reviews))
      (ignore-errors (decknix-auto-review--dispatch-item item)))))

(defun decknix-auto-review-seed-current ()
  "Mark every currently-known review PR as already dispatched.
Called when auto-review transitions from `off' to an active state so
the existing backlog is treated as handled — only genuinely new
incoming mentioned PRs dispatch a session (\"incoming\" semantics)."
  (when (and (boundp 'decknix--hub-reviews) decknix--hub-reviews)
    (dolist (item (alist-get 'items decknix--hub-reviews))
      (decknix-auto-review-mark-dispatched
       (decknix-auto-review-dispatch-key
        (or (alist-get 'repo item) "") (alist-get 'number item))))))

;; -- Toggle UI -----------------------------------------------------

(defun decknix-auto-review-footer-label ()
  "Return a propertised `[state]' label for the footer / transient."
  (propertize (format "[%s]" (decknix-auto-review-state-label
                              decknix-auto-review-mode))
              'face (if (eq decknix-auto-review-mode 'off)
                        'font-lock-comment-face
                      'font-lock-constant-face)))

(defun decknix-auto-review-cycle-mode ()
  "Cycle `decknix-auto-review-mode' to its next state and apply it.
On the off -> active transition the existing review backlog is seeded
as already-dispatched (so only genuinely incoming mentioned PRs spawn
a session), then an immediate scan runs.  Refreshes the sidebar so
the new state is visible."
  (interactive)
  (let ((was-off (eq decknix-auto-review-mode 'off)))
    (setq decknix-auto-review-mode
          (decknix-auto-review-next-state decknix-auto-review-mode))
    (when (and was-off (not (eq decknix-auto-review-mode 'off)))
      (decknix-auto-review-seed-current))
    (decknix-auto-review--maybe-dispatch)
    (when (and (fboundp 'agent-shell-workspace-sidebar-refresh)
               (get-buffer agent-shell-workspace-sidebar-buffer-name))
      (agent-shell-workspace-sidebar-refresh))
    (message "Auto-review: %s"
             (decknix-auto-review-state-label decknix-auto-review-mode))))

(provide 'decknix-auto-review)
;;; decknix-auto-review.el ends here
