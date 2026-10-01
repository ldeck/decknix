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
;; A second guard requires the PR to be REVIEW-READY.  Dispatch reads
;; the raw hub feed, not the rendered Requests list, so without this it
;; happily spawned sessions for PRs the sidebar itself hides by default:
;; a draft (author has explicitly marked it not-ready) or a
;; merge-conflicting PR (its diff is against a stale base, so line
;; anchors and "is this still referenced" checks are unreliable — the
;; only honest review verdict is "please rebase").  The booleans come
;; from the PR's own `draft' and `mergeable' fields.
;;
;; They used to come from the sidebar's toggle-aware predicates
;; (`decknix--hub-requests-draft-visible-p', `-conflict-visible-p') on the
;; reasoning that the `x' / `X' toggles should govern auto-review too -- one
;; control surface, and "auto-review only dispatches what the Requests list
;; would show you".  That is wrong for these two conditions, and attom#296
;; showed how: it is a draft on GitHub and in the feed, but the viewer had
;; drafts VISIBLE, so `draft-visible-p' returned t, auto-review read it as
;; review-ready, and dispatched a session against work its author had
;; explicitly marked unfinished.
;;
;; Wanting to SEE a draft and wanting an agent to REVIEW it are different
;; decisions. Draft and conflicting are the author's declarations about the
;; PR, not the viewer's preferences about a list, so a display filter must not
;; decide a dispatch.
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
;; Throttle bursty dispatch: many eligible PRs on one hub refresh would
;; otherwise cold-start that many node+claude processes at once, thrashing
;; the machine and freezing Emacs.  `decknix-agent-spawn-enqueue' paces them.
(require 'decknix-agent-spawn-queue)
;; Eligibility reads the canonical direct/team/standing-request predicates.
(require 'decknix-hub-mention-bot)

(defconst decknix-auto-review-states '(off bot human any)
  "Ordered cycle of auto-review states.
See the Commentary for the meaning of each.")

(defvar decknix-auto-review-mode 'off
  "Current auto-review state; one of `decknix-auto-review-states'.")

(defvar decknix-auto-review-default-review-command "/review-service-pr"
  "Slash command sent for human-authored auto-review dispatch.
Must be an EXECUTOR that actually reviews the PR, not a router.  Auto-
review already targets one specific PR (it appends the PR URL), so it
does not need `/review-service-pr-factory' — that command is a thin
dispatcher that only inspects the announcing Slack message and PRINTS
the command to re-run, which under unattended auto-review just prints a
recommendation and stops instead of reviewing.  `/review-service-pr'
does the analysis and composes the verdict (gated on confirmation before
posting), so the session surfaces via the attention indicator with real
work done.")

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
(declare-function decknix--sidebar-state-write "decknix-agent-shell-workspace")
(declare-function decknix--hub-review-pr-key
                  "decknix-hub-review-identity" (repo number))
(declare-function decknix--hub-request-priority
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-item-team-requested-p "decknix-hub-mention-bot" (item))
(declare-function decknix--hub-item-mentioned-p "decknix-hub-mention-bot")
(declare-function decknix--hub-requests-draft-visible-p "decknix-hub-attention-filter")
(declare-function decknix--hub-requests-conflict-visible-p "decknix-hub-attention-filter")
(declare-function decknix--hub-request-has-live-session-p "decknix-agent-shell-hub")
(declare-function decknix--agent-pr-detect-workspace "decknix-agent-shell-main-link")
(declare-function decknix--agent-quickaction-start "decknix-agent-shell-main-link")
(declare-function agent-shell-workspace-sidebar-refresh "agent-shell-workspace")
(declare-function decknix-agent-purpose-resolve "decknix-agent-purposes")
(defvar decknix--hub-reviews)
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

(defun decknix-auto-review-item-action (state bot-p mentioned-p
                                              &optional draft-p conflicting-p)
  "Return the dispatch action for a PR under STATE.
BOT-P is non-nil when the PR author is a bot; MENTIONED-P is non-nil
when the PR @-mentions me (directly requested or named in a comment).
DRAFT-P and CONFLICTING-P mark a PR as not review-ready — the author
has not finished it, or its diff is against a stale base — and suppress
dispatch in every state; both default to nil so a caller that has not
resolved readiness keeps the previous behaviour.
Returns `ship' (bot ship-flow), `review' (human review-flow), or nil
when the PR should not be auto-dispatched.  All active states require
MENTIONED-P."
  (when (and mentioned-p (not (eq state 'off))
             (not draft-p) (not conflicting-p))
    (pcase state
      ('bot   (and bot-p 'ship))
      ('human (and (not bot-p) 'review))
      ('any   (if bot-p 'ship 'review))
      (_      nil))))

;; -- Command resolution --------------------------------------------

(defun decknix-auto-review--item-repo-short (item)
  "Return ITEM's repo name without its owner prefix."
  (car (last (split-string (or (alist-get 'repo item) "") "/"))))

(defun decknix-auto-review-group-plan (entries &optional priority-fn)
  "Group ENTRIES into dispatch units.  Pure.

ENTRIES is a list of (ACTION . ITEM).  Returns a list of
(ACTION REPO AUTHOR ITEMS), one per session to launch.

`ship' entries (bot-authored) group by repo AND author.  Five dependabot
bumps on one service become one session, which is the entire point: a
single agent can sequence them, notice that one depends on another, or
fix them together -- none of which five independent sessions can do,
because none of them knows the other four exist.

Grouping by author as well as repo is deliberate.  `author_kind' is
`bot' for several authors, and the ship command is dependabot-shaped, so
folding a renovate PR in with dependabot ones would hand an agent a
sequence it has no coherent way to run.  Same repo, different bot,
different session.

`review' entries (human-authored) are NEVER grouped.  They are
individually authored and individually argued with; folding them would
hide exactly the reviews that most need reading.

PRIORITY-FN, when supplied, orders members within a group (descending)
and orders the units by their strongest member -- so one urgent bump
lifts its group rather than being buried inside it."
  (let ((groups nil))
    (dolist (entry entries)
      (let* ((action (car entry))
             (item (cdr entry))
             (repo (decknix-auto-review--item-repo-short item))
             (author (or (alist-get 'author item) ""))
             ;; Human reviews get a unique key so they never coalesce.
             (key (if (eq action 'ship)
                      (list action repo author)
                    (list action repo author (alist-get 'number item))))
             (cell (assoc key groups)))
        (if cell
            (setcdr cell (cons item (cdr cell)))
          (push (cons key (list item)) groups))))
    (let ((units
           (mapcar
            (lambda (cell)
              (let* ((key (car cell))
                     (items (nreverse (cdr cell)))
                     (items (if priority-fn
                                (sort items (lambda (a b)
                                              (> (funcall priority-fn a)
                                                 (funcall priority-fn b))))
                              items)))
                (list (nth 0 key) (nth 1 key) (nth 2 key) items)))
            (nreverse groups))))
      (if priority-fn
          (sort units (lambda (a b)
                        (> (apply #'max (mapcar priority-fn (nth 3 a)))
                           (apply #'max (mapcar priority-fn (nth 3 b))))))
        units))))

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

(defcustom decknix-auto-review-include-team-requests t
  "When non-nil, a review requested of one of my TEAMS counts as mine.

Some repos never assign individual reviewers and rely on the CODEOWNERS team
being tagged -- `attom-integration' and `followupboss-integration' both do.
Those PRs arrive with `mentioned' nil and `team_requested' t, so an
eligibility test keyed on `mentioned' alone dispatched nothing for them.

Set to nil to go back to individual requests only, which is the right choice
if a team you are in carries more PRs than you intend to review."
  :type 'boolean
  :group 'decknix)

(defun decknix-auto-review--draft-p (item)
  "Return non-nil when ITEM is a draft PR.

Reads the PR's own `draft' flag rather than
`decknix--hub-requests-draft-visible-p'. That predicate answers \"does this
row pass my filters\", and its first clause is
`(not decknix--hub-requests-hide-draft)' -- so making drafts VISIBLE in the
sidebar made it return t for a draft, which auto-review read as
review-ready. A display filter must not decide a dispatch: attom#296 is a
draft on GitHub and in the feed, and was dispatched anyway."
  (eq (alist-get 'draft item) t))

(defun decknix-auto-review--conflicting-p (item)
  "Return non-nil when ITEM's diff conflicts with its base.
Reads `mergeable' directly, for the same reason as
`decknix-auto-review--draft-p'."
  (equal (alist-get 'mergeable item) "CONFLICTING"))

(defun decknix-auto-review--requested-of-me-p (item)
  "Return non-nil when ITEM asks for MY review, directly or via a team.

A team request standing BESIDE named individual reviewers is not an ask of
me: those individuals are who was chosen.  See
`decknix--hub-item-mine-to-take-p'.

Requires a STANDING request.  Requests now also carries PRs recovered by the
hub's `--reviewed-by=@me' source, which exist so I can see a follow-up I owe
a human reply -- dispatching a fresh review session at one would re-review
work I have already reviewed, unprompted."
  (and (or (not (fboundp 'decknix--hub-item-review-requested-of-me-p))
           (decknix--hub-item-review-requested-of-me-p item))
       ;; Gated on the DATA, not on the function existing.  Keying it off
       ;; `fboundp' made the new rule apply to items that carry no
       ;; `requested_reviewers' at all -- which the hub omits when the list
       ;; is empty -- so those stopped dispatching entirely.
       (if (and (assq 'requested_reviewers item)
                (fboundp 'decknix--hub-item-mine-to-take-p))
           ;; A team request ALONGSIDE named individuals is the fallback those
           ;; individuals have already answered -- taking it anyway reviewed
           ;; 10 of 26 requests nobody had asked me for.  `include-team-
           ;; requests' still gates the team case; being individually
           ;; requested is never gated, since that is a direct ask.
           (or (decknix--hub-item-individually-requested-p item)
               (and decknix-auto-review-include-team-requests
                    (decknix--hub-item-mine-to-take-p item)))
         ;; No `requested_reviewers' on this item (older hub, or a PR with
         ;; none requested): fall back to the mention flag rather than
         ;; dispatching nothing.
         (or (decknix--hub-item-mentioned-p item)
             (and decknix-auto-review-include-team-requests
                  (fboundp 'decknix--hub-item-team-requested-p)
                  (decknix--hub-item-team-requested-p item))))
       t))

(defun decknix-auto-review--eligible-action (item)
  "Return the dispatch action for ITEM, or nil when it must not dispatch.

Was the head of the old per-item dispatcher, which grouping replaced:
eligibility for the whole tick has to be known BEFORE deciding how many
sessions to launch.  Same conditions as before, in the same order."
  (let* ((bot-p (decknix--hub-bot-author-p (alist-get 'author item)))
         (mentioned-p (decknix-auto-review--requested-of-me-p item))
         (draft-p (decknix-auto-review--draft-p item))
         (conflicting-p (decknix-auto-review--conflicting-p item))
         (action (decknix-auto-review-item-action
                  decknix-auto-review-mode bot-p mentioned-p
                  draft-p conflicting-p))
         (repo-full (or (alist-get 'repo item) ""))
         (number (alist-get 'number item))
         (url (alist-get 'url item))
         (key (decknix-auto-review-dispatch-key repo-full number)))
    (when (and action url number
               (not (string-empty-p repo-full))
               (not (decknix-auto-review-dispatched-p key))
               ;; Already covered -- including by a GROUP session, since
               ;; `covers-p' tests membership of the recorded PR list.
               (not (decknix--hub-request-has-live-session-p item)))
      action)))

(defvar decknix-auto-review-group-ship-command "/review-and-ship-bot-prs"
  "Slash command for a GROUP of bot PRs on one service.
A sequencer over the singular command, not a batch approver: each PR is
still reviewed and approved individually.  See the command definition in
`decknix-config/commands/review-and-ship-bot-prs.md'.")

(defun decknix-auto-review--dispatch-unit (unit)
  "Launch one session for UNIT, an (ACTION REPO AUTHOR ITEMS) tuple.

A single-item unit dispatches exactly as before.  A multi-item unit --
only ever bot PRs on one service -- dispatches ONE session for all of
them, which is the whole point: five bumps handled by five agents cannot
sequence themselves, spot that two touch the same lockfile, or share one
fix, because none of them knows the others exist.

Marks every member dispatched BEFORE launching, so a second file-notify
tick arriving during session startup cannot re-dispatch any of them."
  (let* ((action (nth 0 unit))
         (repo (nth 1 unit))
         (items (nth 3 unit))
         (grouped (> (length items) 1))
         (first (car items))
         (owner (car (split-string (or (alist-get 'repo first) "") "/")))
         (urls (delq nil (mapcar (lambda (i) (alist-get 'url i)) items)))
         (numbers (mapcar (lambda (i) (alist-get 'number i)) items))
         (workspace (decknix--agent-pr-detect-workspace owner repo))
         (purpose (if (eq action 'ship) 'bot-pr-review 'pr-review))
         (cfg (decknix-agent-purpose-resolve purpose))
         (model (plist-get cfg :model))
         (provider (plist-get cfg :provider))
         (mode (plist-get cfg :mode))
         (command-base (if grouped
                           decknix-auto-review-group-ship-command
                         (decknix-auto-review-resolve-command action workspace)))
         (command (format "%s %s" command-base (string-join urls " ")))
         (name (if grouped
                   (format "pr-%s-group" repo)
                 (format "pr-%s-%s" repo (car numbers))))
         (tags (if grouped
                   (list "review" repo "auto" "group")
                 (list "review" repo (format "#%s" (car numbers)) "auto")))
         ;; Recorded explicitly: a group's NAME encodes no PR number, so
         ;; there is nothing for the identity layer to derive from it.
         ;; Guarded: a missing identity layer must degrade to "no
         ;; recorded coordinates" -- the tags/name fallbacks still
         ;; identify the session -- rather than aborting the dispatch and
         ;; silently leaving the PR unreviewed.
         (review-prs (when (fboundp 'decknix--hub-review-pr-key)
                       (delq nil
                             (mapcar (lambda (i)
                                       (decknix--hub-review-pr-key
                                        (alist-get 'repo i) (alist-get 'number i)))
                                     items)))))
    (when (and urls workspace)
      (dolist (i items)
        (decknix-auto-review-mark-dispatched
         (decknix-auto-review-dispatch-key
          (or (alist-get 'repo i) "") (alist-get 'number i))))
      (decknix-agent-spawn-enqueue
       (lambda ()
         (decknix--agent-quickaction-start
          name tags workspace command model provider mode t review-prs)
         (message "[auto-review] %s %s/%s %s via %s"
                  action owner repo
                  (if grouped
                      (format "(%d PRs: %s)" (length numbers)
                              (mapconcat #'number-to-string numbers ", "))
                    (format "#%s" (car numbers)))
                  command-base)))
      action)))

(defun decknix-auto-review--maybe-dispatch (&rest _)
  "Scan hub reviews and auto-dispatch eligible sessions.
No-op when `decknix-auto-review-mode' is `off'.  Wired as `:after'
advice on `decknix--hub-refresh-reviews' so it fires whenever the
reviews data is (re)loaded — i.e. on every file-notify refresh."
  (when (and (not (eq decknix-auto-review-mode 'off))
             (boundp 'decknix--hub-reviews)
             decknix--hub-reviews)
    (let* ((items (alist-get 'items decknix--hub-reviews))
           ;; Decide eligibility for the WHOLE tick before launching
           ;; anything.  Dispatching as we walk is what produced one
           ;; session per bump: by the time the second bump was seen the
           ;; first had already been given its own agent.
           (entries (delq nil
                          (mapcar (lambda (it)
                                    (when-let* ((a (ignore-errors
                                                     (decknix-auto-review--eligible-action it))))
                                      (cons a it)))
                                  items)))
           (plan (decknix-auto-review-group-plan
                  entries
                  (when (fboundp 'decknix--hub-request-priority)
                    #'decknix--hub-request-priority))))
      (dolist (unit plan)
        (ignore-errors (decknix-auto-review--dispatch-unit unit))))))

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
    ;; Persist immediately.  `launchctl kickstart -k' sends SIGKILL and so
    ;; skips `kill-emacs-hook' -- waiting for the shutdown save loses the
    ;; choice on exactly the restart the user just performed deliberately.
    (when (fboundp 'decknix--sidebar-state-write)
      (decknix--sidebar-state-write))
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
