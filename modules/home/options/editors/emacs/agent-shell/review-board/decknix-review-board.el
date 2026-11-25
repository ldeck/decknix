;;; decknix-review-board.el --- Ordered, grouped review worklist -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, review, board

;;; Commentary:
;;
;; A single screen for the review worklist: which review needs you next,
;; which sessions are finished, and which requests have nobody on them.
;;
;; The sidebar answers "what exists".  This answers "what now" -- which
;; the sidebar structurally cannot, because it is ordered for glancing at
;; and lists sessions and requests as separate things rather than as one
;; worklist.
;;
;; Marks (`m'/`u'/`U'/`M') and the non-writing verbs -- dispatch, jump,
;; quit, detach -- act on the marked set, or on the row at point when
;; nothing is marked.
;;
;; `s' (merge) is the one bound verb that WRITES to GitHub, and only
;; behind a full manifest and an explicit confirmation -- a batch cannot
;; be looser than the single-PR case, which already mandates one.  It
;; hands the PRs to `/merge-train', which owns the second gate.
;;
;; Two heavier verbs stay unbound: a standalone APPROVE, and a full SHIP
;; (`/ship' -- validate in dev, merge, progressive deploy, Jira Done).
;; Merge is only the rebase-merge step; shipping a bot PR already has a
;; home on this board via `d' (which dispatches `/review-and-ship-bot-pr'
;; behind the mandatory review gate).
;;
;; Follows the on-support board's model deliberately -- constant lanes, cursor,
;; single-key actions, read-only, refreshed rather than recomputed.  The
;; engine here is the hub JSON plus the pure packages (priority, status,
;; identity, and this board's own model), so nothing is computed twice.

;;; Code:

(require 'decknix-review-board-model)
(require 'decknix-review-board-rereview)
(require 'decknix-review-board-columns)
(require 'decknix-review-board-prcache)
(require 'decknix-agent-session-lifecycle)
;; The one look for "needs you": its glyph and face, shared with the
;; sidebar, the picker and the tab bar.
(require 'decknix-attention)

(declare-function decknix--hub-review-pr-key "decknix-hub-review-identity" (repo number))
(declare-function decknix--hub-review-find-item "decknix-hub-review-status" (items repo number))
(declare-function decknix--hub-review-status "decknix-hub-review-status" (item found))
(declare-function decknix--hub-review-status-badge "decknix-hub-review-status" (status))
(declare-function decknix--hub-review-priority "decknix-hub-review-priority" (item &optional status age-days))
(declare-function decknix--hub-request-priority "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-bot-author-p "decknix-hub-mention-bot" (author))
(declare-function decknix--agent-review-prs-for-conv-key "decknix-agent-session-broker" (conv-key))
(declare-function decknix-agent-buffer-status "decknix-agent-auto-close" (buffer))
(declare-function decknix--agent-tags-for-buffer "decknix-agent-tags-read" (buffer))
(declare-function decknix--agent-plan-label "decknix-agent-turn-signals" (progress))
(declare-function decknix-agent-turn-closing-ask "decknix-agent-turn-signals" (&optional buffer))
(declare-function decknix-agent-turn-closing-text "decknix-agent-turn-signals" (&optional buffer))
(declare-function decknix-agent-turn-answered "decknix-agent-turn-signals" (&optional buffer))
(declare-function decknix-agent-turn-quick-reply "decknix-agent-turn-signals" (buffer key))
(declare-function decknix-agent-turn-reply-key "decknix-agent-turn-signals" (event))
(declare-function decknix-review-board-activity-verb "decknix-review-board-model" (tags))
(defvar decknix--agent-turn-plan)
(declare-function agent-shell-buffers "ext:agent-shell")
(declare-function decknix-auto-review--dispatch-unit "decknix-auto-review" (unit))
(declare-function decknix--agent-broker-stop-p "decknix-agent-session-broker" (key other-keys))
(declare-function decknix-agent-broker-stop "decknix-agent-session-broker" (key))
(declare-function decknix--agent-pr-detect-workspace
                  "decknix-agent-workspace-detect" (owner repo))
(declare-function decknix--git-remote-url "decknix-agent-vcs")
(declare-function decknix--hub-review-pr-url
                  "decknix-hub-review-identity" (owner repo number))
(declare-function decknix--hub-review-pr-key-parse
                  "decknix-hub-review-identity" (key))
(declare-function decknix-auto-review-cycle-mode "decknix-auto-review")
(declare-function decknix--nav-hub-start-review-background
                  "decknix-agent-shell-workspace" (url))
(declare-function decknix--nav-hub-start-review
                  "decknix-agent-shell-workspace" (url &optional background))
(declare-function decknix-review-board--parse-urls
                  "decknix-review-board-model" (input))
(declare-function decknix--hub-item-visible-p "decknix-agent-shell-hub" (repo))
(declare-function decknix--hub-age-visible-p "decknix-agent-shell-hub" (ts))
(declare-function decknix--hub-ci-visible-p "decknix-agent-shell-hub" (item))
(declare-function decknix--hub-mention-visible-p "decknix-agent-shell-hub" (item))
(declare-function decknix--hub-bot-visible-p "decknix-agent-shell-hub" (item))
(declare-function decknix--hub-requests-attention-visible-p "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-reviewed-visible-p "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-conflict-visible-p "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-draft-visible-p "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-request-activity-time "decknix-hub-attention-filter" (item))
(declare-function decknix-auto-review-state-label "decknix-auto-review" (state))
(declare-function decknix--hub-review-priority-explain
                  "decknix-hub-review-priority" (item &optional status age-days))
(declare-function decknix--hub-request-age-days
                  "decknix-hub-attention-filter" (item))
(defvar decknix-auto-review-mode)
(declare-function decknix--agent-quickaction-start
                  "decknix-agent-shell-main-link"
                  (name tags workspace command &optional model provider-id mode
                        background review-prs additional-roots))
(declare-function decknix-agent-re-review-send "decknix-agent-re-review"
                  (target content &optional no-display))
(declare-function decknix-agent-re-review-needle "decknix-agent-re-review" (repo number))
(declare-function decknix-agent-re-review-target "decknix-agent-re-review"
                  (needle number buffers entries))
(declare-function decknix-agent-re-review--send-when-ready "decknix-agent-re-review"
                  (needle content &optional tries no-display))
(declare-function decknix--sidebar-restore-previous-session
                  "decknix-agent-shell-workspace" (entry &optional focus))
(declare-function decknix--nav-hub-start-review-fresh
                  "decknix-agent-shell-workspace" (url background parsed &optional context))
(declare-function decknix--review-worktree-refresh-then
                  "decknix-agent-shell-workspace" (owner repo number head on-ready))
(declare-function decknix-attention-set-flags "decknix-attention" (flags))
(declare-function decknix-review-clone-state "decknix-review-clone" (owner repo))
(declare-function decknix-review-clone-clear "decknix-review-clone" (owner repo))
(declare-function decknix-review-clone-resolve-cached "decknix-review-clone" (owner repo))
(declare-function decknix-review-clone-row-note "decknix-review-clone"
                  (state &optional resolution))
(declare-function decknix-review-clone-ensure "decknix-review-clone"
                  (owner repo target callback &optional args))
(declare-function decknix-workspace-for-org "decknix-workspace-orgs"
                  (owner &optional workspaces))
(declare-function decknix-workspace-clone-args "decknix-workspace-orgs"
                  (owner &optional workspaces))
(declare-function decknix--agent-net-error-p "decknix-agent-net-error" (text))
(declare-function decknix--agent-net-error-buffer-tail "decknix-agent-net-error" (buffer))
(declare-function decknix--agent-net-error-reset-buffer "decknix-agent-net-error" (buffer))
(declare-function decknix--session-bulk-dispatch "decknix-agent-shell-main-session" (bufs input))
(declare-function decknix-attention-since "decknix-attention" (buffer))
(declare-function decknix--layout-severity-face "decknix-sidebar-layout" (rank))
(declare-function decknix-pr-review-view-open "decknix-pr-review-view"
                  (owner repo number &optional url))
(defvar decknix-agent-net-error-retry-prompt)
(defvar decknix--sidebar-previous-sessions)
(defvar decknix--agent-broker-key)
(defvar decknix--hub-reviews)
(defvar decknix--agent-conv-key)

(defgroup decknix-review-board nil
  "Ordered review worklist." :group 'decknix)

(defface decknix-review-board-lane
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for lane headings." :group 'decknix-review-board)

(defface decknix-review-board-needs-you
  '((t :inherit decknix-attention-face))
  "Face for the needs-you lane heading and a blocked row nobody has covered.
The shared attention face, so a session blocked on you looks the same
here as in the sidebar, the picker and the tab bar."
  :group 'decknix-review-board)

(defface decknix-review-board-assessing
  '((t :inherit default))
  "Face for a review still being assessed (or revised): in flight, plain.
Amber means something wants you; a review in flight wants nothing."
  :group 'decknix-review-board)

(defface decknix-review-board-actioned
  '((t :inherit font-lock-function-name-face))
  "Face for a review acting on your answer, i.e. posting it."
  :group 'decknix-review-board)

(defface decknix-review-board-posted
  '((t :inherit success))
  "Face for a review that is on GitHub."
  :group 'decknix-review-board)

(defconst decknix-review-board-phase-looks
  `((awaiting  ,decknix-attention-glyph decknix-attention-face "awaiting you")
    (asking    ,decknix-attention-glyph decknix-attention-face "asking")
    (waiting   ,decknix-attention-glyph decknix-attention-face "permission")
    (netfail   "✖" error "crashed")
    (stalled   ,decknix-attention-glyph decknix-attention-face "stalled")
    (handed-off "→" font-lock-comment-face "handed off")
    (assessing "◐" decknix-review-board-assessing "assessing")
    (revising  "◐" decknix-review-board-assessing "revising")
    (actioned  "◑" decknix-review-board-actioned "posting")
    (acted     "●" decknix-review-board-actioned "actioned")
    (posted    "✓" decknix-review-board-posted "posted")
    (updated   ,decknix-attention-glyph decknix-attention-face "updated")
    (idle      "●" font-lock-comment-face "idle"))
  "(PHASE GLYPH FACE LABEL) for each `decknix-review-board-phases' entry.

The sidebar's shape family: a half circle for work in flight, a full one
for a unit at rest, the flag for blocked on you, and `✓' for a review that
is done, as the sidebar marks a PR you have reviewed.  Assessing and
posting are both in flight, so they share the half circle and differ in
which half and colour.")

(defun decknix-review-board--phase-look (phase)
  "Return (GLYPH FACE LABEL) for PHASE."
  (or (cdr (assq phase decknix-review-board-phase-looks))
      (list "●" 'font-lock-comment-face (symbol-name (or phase 'idle)))))

(defconst decknix-review-board-severity-faces
  '((0 . (:foreground "#ff5f5f" :weight bold))
    (1 . (:foreground "#ffaf5f" :weight bold))
    (2 . default)
    (3 . (:foreground "#87af87"))
    (4 . (:inherit font-lock-comment-face)))
  "Fallback severity faces, used only when the sidebar is not loaded.
The same values as `decknix-sidebar-layout-severity-faces'.")

(defun decknix-review-board--severity-face (rank)
  "Return the face for severity RANK: the sidebar's, so the two agree."
  (if (fboundp 'decknix--layout-severity-face)
      (decknix--layout-severity-face rank)
    (or (alist-get (or rank 4) decknix-review-board-severity-faces) 'default)))

(defface decknix-review-board-covered
  '((t :inherit font-lock-comment-face))
  "Face for a blocked row somebody else has already answered or invalidated.

Deliberately NOT bold and NOT `error'.  The row is still yours, but an
approved or stale PR must not compete with a review nobody has looked at
-- if everything blocked is red, red stops meaning anything.  Grey, the
sidebar's quiet colour, rather than amber, which means waiting on you."
  :group 'decknix-review-board)

(defvar-local decknix-review-board--model nil
  "The lane model rendered in this buffer.")

(defvar-local decknix-review-board--marks nil
  "Hash of marked row keys (see `decknix-review-board-row-key').")

(defconst decknix-review-board-buffer-name "*Review Board*"
  "Name of the review board buffer.")

;; ── gathering ────────────────────────────────────────────────────────

(defconst decknix-review-board-tail-chars 4000
  "How much trailing session text is read for a crash when net-error is absent.")

(defvar-local decknix-review-board--tail-memo nil
  "(TICK . NETFAIL) for the session text last read, in a session buffer.")

(defun decknix-review-board--session-netfail (buf state)
  "Return the network failure BUF's last message ended on, or nil.

Read from the text, not the status, because a session whose first prompt
failed never completed a turn for net-error to flag: it read as idle with
an `API Error: ... (ENOTFOUND)' as its only output.  Only a stopped
session is read (a live turn is not dead), through net-error's own
matcher, and memoised on the buffer's modification tick, so a repaint
reads each session's text at most once per change."
  (when (and (buffer-live-p buf)
             (not (member state '("working" "waiting" "netfail")))
             (fboundp 'decknix--agent-net-error-p))
    (with-current-buffer buf
      (let ((tick (buffer-chars-modified-tick)))
        (if (eql tick (car decknix-review-board--tail-memo))
            (cdr decknix-review-board--tail-memo)
          (let ((reason (decknix--agent-net-error-p
                         (if (fboundp 'decknix--agent-net-error-buffer-tail)
                             (decknix--agent-net-error-buffer-tail buf)
                           (buffer-substring-no-properties
                            (max (point-min) (- (point-max) decknix-review-board-tail-chars))
                            (point-max))))))
            (setq decknix-review-board--tail-memo (cons tick reason))
            reason))))))

(defun decknix-review-board--session-handed-off (buf prs)
  "Return why BUF's review of PRS is someone else's now, or nil.
Single-PR sessions only: a group is a bot batch nobody hands off."
  (when (= 1 (length prs))
    (decknix-review-board-handed-off
     (and (fboundp 'decknix-agent-turn-closing-text)
          (decknix-agent-turn-closing-text buf))
     (decknix-review-board--item-for-key (car prs))
     (alist-get 'viewer decknix--hub-reviews))))

(defun decknix-review-board--sessions ()
  "Return the live review sessions as model plists.

Only sessions with recorded PR coordinates: a session with none is not a
review, and guessing from its name is what produced duplicate reviewers
in the first place."
  (when (fboundp 'agent-shell-buffers)
    (delq nil
          (mapcar
           (lambda (buf)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (let* ((ck (bound-and-true-p decknix--agent-conv-key))
                        (prs (and ck (ignore-errors
                                       (decknix--agent-review-prs-for-conv-key ck)))))
                   (when prs
                     (let* ((tags (ignore-errors
                                    (decknix--agent-tags-for-buffer buf)))
                            (plan (bound-and-true-p decknix--agent-turn-plan))
                            (state nil))
                       (setq state (ignore-errors (decknix-agent-buffer-status buf)))
                       (list :name (buffer-name buf)
                             :buffer buf
                             :conv-key ck
                             :prs prs
                             :state state
                             :netfail (decknix-review-board--session-netfail buf state)
                             :handed-off (decknix-review-board--session-handed-off buf prs)
                             :since (and (fboundp 'decknix-attention-since)
                                         (decknix-attention-since buf))
                             ;; Where the review is in its two phases, from
                             ;; what turn-signals already holds in memory:
                             ;; the closing turn (parsed once per turn) and
                             ;; the gate the last prompt answered.
                             :ask (and (fboundp 'decknix-agent-turn-closing-ask)
                                       (ignore-errors (decknix-agent-turn-closing-ask buf)))
                             :posted (and (fboundp 'decknix-agent-turn-closing-text)
                                          (decknix-agent-turn-ask-posted-p
                                           (decknix-agent-turn-closing-text buf)))
                             :answered (and (fboundp 'decknix-agent-turn-answered)
                                            (decknix-agent-turn-answered buf))
                             :bot-p (decknix-review-board--prs-bot-p prs)
                             ;; What the session is DOING (its intent tag)
                             ;; and how far along its plan is, for the
                             ;; In-progress lane.  Both nil-tolerant.
                             :verb (and tags
                                        (decknix-review-board-activity-verb tags))
                             :progress (and plan
                                            (fboundp 'decknix--agent-plan-label)
                                            (decknix--agent-plan-label plan)))))))))
           (agent-shell-buffers)))))

(defvar decknix-review-board--owner-map (make-hash-table :test 'equal)
  "Short repo name -> owner, accumulated from every feed seen.

Accumulated rather than recomputed because the rows that most need a URL
are exactly the ones whose repo may have left the feed: a service whose
only open PR just merged has no items left, so a map built from the
CURRENT feed alone would forget the owner precisely when the Finished
lane needs it.  Entries are cheap and a repo's owner does not change.")

(defun decknix-review-board--learn-owners (items)
  "Record short-repo -> owner for every ITEMS entry carrying `owner/repo'."
  (dolist (item items)
    (let* ((full (map-elt item 'repo))
           (parts (and (stringp full) (split-string full "/"))))
      (when (= 2 (length parts))
        (puthash (nth 1 parts) (nth 0 parts)
                 decknix-review-board--owner-map)))))

(defun decknix-review-board--owner-for (repo)
  "Return the owner for short REPO, or nil.

Falls back to the workspace's git remote, which covers a repo never seen
in a feed at all -- a review session for a repo with no other open PRs."
  (or (gethash repo decknix-review-board--owner-map)
      (when-let* ((ws (ignore-errors
                        (decknix--agent-pr-detect-workspace nil repo)))
                  (default-directory ws)
                  (url (ignore-errors (decknix--git-remote-url))))
        (when (string-match "github\\.com[:/]\\([^/]+\\)/" url)
          (match-string 1 url)))))

(defun decknix-review-board-row-url (row)
  "Return a PR URL for ROW, or nil.

Prefers the feed item's own URL, then reconstructs from coordinates.  The
reconstruction is what makes Finished rows openable at all: their PR has
left the feed, so there is no item to read a URL from."
  (let ((key (car (plist-get row :prs))))
    (or (when-let* ((item (decknix-review-board--item-for-key key)))
          (map-elt item 'url))
        (when-let* ((parsed (decknix--hub-review-pr-key-parse key))
                    (owner (decknix-review-board--owner-for (car parsed))))
          (decknix--hub-review-pr-url owner (car parsed) (cdr parsed))))))

(defun decknix-review-board--item-for-key (key)
  "Return the feed item for a `repo#number' KEY, or nil."
  (when (and (stringp key)
             (string-match "\\`\\(.+\\)#\\([0-9]+\\)\\'" key))
    (decknix--hub-review-find-item
     (alist-get 'items decknix--hub-reviews)
     (match-string 1 key) (string-to-number (match-string 2 key)))))

(defun decknix-review-board--status-for-key (key)
  "Return the staleness status for KEY."
  (let ((item (decknix-review-board--item-for-key key)))
    (decknix--hub-review-status item (and item t))))

(defun decknix-review-board--priority-for-key (key)
  "Return the review priority for KEY, or 0 when it has left the feed.

A departed PR scores 0 rather than inheriting the `gone' floor: its row
is already filed under Finished, and dragging the number down would only
make the column noisy."
  (let ((item (decknix-review-board--item-for-key key)))
    (if item (decknix--hub-request-priority item) 0)))

(defun decknix-review-board--prs-bot-p (prs)
  "Non-nil when the first resolvable PR in PRS was authored by a bot."
  (seq-some (lambda (key)
              (when-let* ((item (decknix-review-board--item-for-key key)))
                (decknix--hub-bot-author-p (alist-get 'author item))))
            prs))

(defun decknix-review-board--item-key (item)
  "Return the `repo#number' key for a feed ITEM."
  (decknix--hub-review-pr-key (alist-get 'repo item) (alist-get 'number item)))

(defun decknix-review-board--item-bot-p (item)
  "Non-nil when ITEM was authored by a bot."
  (and (decknix--hub-bot-author-p (alist-get 'author item)) t))

(defvar decknix-review-board-auto-dismiss nil
  "When non-nil, a merged or closed PR's session drops off the board.
The Finished lane is emptied automatically on every refresh, so an
actioned review clears itself once its PR lands.  When nil (the default),
finished sessions stay in the Finished lane for you to clear by hand --
seeing them is the prompt to quit the session and free its broker.
Toggle with `x'.")

(defvar decknix-review-board-show-all nil
  "When non-nil, show every review request, ignoring the sidebar filters.")

(defun decknix-review-board--request-visible-p (item)
  "Non-nil when ITEM passes the SAME filters the sidebar Requests section uses.

The board was reading the raw feed, so it showed 30 rows where the
sidebar showed 2 -- 28 PRs deliberately hidden: bots that do not mention
you, drafts, items aged out.  Noise on its own, but `d' made it a
correctness problem: auto-review's readiness check is built as the
NEGATION of these predicates precisely so it can never dispatch a PR the
Requests list is hiding, and a board that ignored them offered a key to
do exactly that."
  (and (decknix--hub-item-visible-p (alist-get 'repo item))
       (decknix--hub-age-visible-p (decknix--hub-request-activity-time item))
       (decknix--hub-ci-visible-p item)
       (decknix--hub-mention-visible-p item)
       (decknix--hub-bot-visible-p item)
       (decknix--hub-requests-attention-visible-p item)
       (decknix--hub-requests-reviewed-visible-p item)
       (decknix--hub-requests-conflict-visible-p item)
       (decknix--hub-requests-draft-visible-p item)))

(defun decknix-review-board--request-items ()
  "Return the feed items the board should offer as work to pick up."
  (let ((items (alist-get 'items decknix--hub-reviews)))
    (if decknix-review-board-show-all
        items
      (seq-filter #'decknix-review-board--request-visible-p items))))

(defun decknix-review-board-toggle-filters ()
  "Toggle between the sidebar's filters and the whole feed."
  (interactive)
  (setq decknix-review-board-show-all (not decknix-review-board-show-all))
  (decknix-review-board-refresh)
  (message "Requests: %s"
           (if decknix-review-board-show-all
               "ALL (sidebar filters ignored)"
             "filtered, as the sidebar")))

(defun decknix-review-board--rereview-for-key (key settled)
  "Return the re-review info for PR KEY, or nil.  See
`decknix-review-board-rereview-info'; SETTLED as there."
  (when-let* ((item (decknix-review-board--item-for-key key)))
    (decknix-review-board-rereview-info
     item settled (alist-get 'viewer decknix--hub-reviews)
     (decknix-review-board-rereview-seen-head key))))

(defun decknix-review-board--board-items ()
  "Return the requests to offer, plus every PR updated since my review.

An updated PR is offered even when the sidebar filters hide it: the
reviewed-PR filter is what hides it, and its whole point is that it no
longer is."
  (let* ((shown (decknix-review-board--request-items))
         (updated (seq-filter
                   (lambda (item)
                     (and (not (memq item shown))
                          (decknix-review-board--rereview-for-key
                           (decknix-review-board--item-key item) nil)))
                   (alist-get 'items decknix--hub-reviews))))
    (append shown updated)))

(defun decknix-review-board--build ()
  "Return a freshly built model.

Sessions are NEVER filtered -- a running agent is a fact regardless of
whether its PR passes a display filter, and a Finished session's PR is
not in the feed at all.  Filters govern only what is offered as work to
pick up."
  (let ((items (alist-get 'items decknix--hub-reviews)))
    (decknix-review-board--learn-owners items)
    (decknix-review-board-prcache-learn items #'decknix-review-board--item-key))
  (let ((model (decknix-review-board-build
                (decknix-review-board--board-items)
                (decknix-review-board--sessions)
                #'decknix-review-board--item-key
                #'decknix-review-board--status-for-key
                #'decknix-review-board--priority-for-key
                #'decknix-review-board--item-bot-p
                #'decknix-review-board--rereview-for-key
                #'decknix-review-board--activity-for-key)))
    (decknix-review-board--request-gone-states model)
    model))

(defun decknix-review-board--activity-for-key (key)
  "Return PR KEY's last activity as a float time, or nil.
The feed's `updated' while it is listed; once it has gone, when it
merged or closed, or failing that what the feed last said."
  (let* ((item (decknix-review-board--item-for-key key))
         (entry (decknix-review-board-prcache-get key))
         (ts (or (and item (decknix-review-board--activity-time-string item))
                 (plist-get entry :updated))))
    (or (and (not item) (decknix-review-board-prcache-gone-time entry))
        (and (stringp ts) (ignore-errors (float-time (date-to-time ts)))))))

(defun decknix-review-board--activity-time-string (item)
  "Return ITEM's activity timestamp string, with or without the hub filter."
  (if (fboundp 'decknix--hub-request-activity-time)
      (decknix--hub-request-activity-time item)
    (or (alist-get 'updated item) (alist-get 'created item))))

(defun decknix-review-board--request-gone-states (model)
  "Ask once, in the background, whether each Obsolete PR merged or closed.
Starts nothing for a PR already answered (see
`decknix-review-board-prcache-request-state'), so a repaint costs a
cache lookup per row."
  (dolist (row (alist-get 'obsolete model))
    (dolist (key (plist-get row :prs))
      (when-let* ((url (decknix-review-board-row-url (list :prs (list key)))))
        (decknix-review-board-prcache-request-state key url)))))

;; ── rendering ────────────────────────────────────────────────────────

(defun decknix-review-board--row-facts (row)
  "Return what ROW's columns show about its PR: the feed item, else the cache.
As (ITEM . ENTRY): ITEM is the live feed entry or nil, ENTRY the cached
plist, so a PR that has left the feed still has a title and an author."
  (let ((key (car (plist-get row :prs))))
    (cons (or (plist-get row :item) (decknix-review-board--item-for-key key))
          (decknix-review-board-prcache-get key))))

(defun decknix-review-board--row-title (row)
  "Return a display title for ROW."
  (if (eq (plist-get row :kind) 'group)
      (format "%d PRs" (length (plist-get row :prs)))
    (let ((facts (decknix-review-board--row-facts row)))
      (or (and (car facts) (alist-get 'title (car facts)))
          (plist-get (cdr facts) :title)
          ""))))

(defun decknix-review-board--row-key-label (row)
  "Return ROW's key column: the PR key, or the group's name."
  (if (eq (plist-get row :kind) 'group)
      (or (plist-get row :name) "group")
    (or (car (plist-get row :prs)) "?")))

(defun decknix-review-board--row-owner-repo (row)
  "Return (OWNER . REPO) for ROW's first PR, from its feed item, or nil."
  (let* ((item (or (plist-get row :item)
                   (car (plist-get row :items))
                   (decknix-review-board--item-for-key (car (plist-get row :prs)))))
         (parts (split-string (or (and item (alist-get 'repo item)) "") "/")))
    (when (= 2 (length parts))
      (cons (nth 0 parts) (nth 1 parts)))))

(defun decknix-review-board--clone-note (row)
  "Return why ROW has no session when it is about its checkout, or nil.
Cloning, a failed clone, an org with no workspace, or a repository not
cloned yet: each used to read as a bare \"no session\", the same as a PR
nobody had looked at.  Reads only in-memory state and a memoised
resolution, so a repaint starts no process."
  (when-let* (((fboundp 'decknix-review-clone-row-note))
              (coords (decknix-review-board--row-owner-repo row)))
    (decknix-review-clone-row-note
     (decknix-review-clone-state (car coords) (cdr coords))
     (ignore-errors
       (decknix-review-clone-resolve-cached (car coords) (cdr coords))))))

(defun decknix-review-board--gone-label (row)
  "Return `merged', `closed', `left queue' or `...' for an Obsolete ROW.
`...' while the one background lookup is still out."
  (let ((labels (delete-dups
                 (mapcar (lambda (key)
                           (pcase (decknix-review-board-prcache-state-label
                                   (decknix-review-board-prcache-get key))
                             ('nil "...") ("open" "left queue") (l l)))
                         (plist-get row :prs)))))
    (string-join labels "/")))

(defun decknix-review-board--phase-text (row has-session)
  "Return ROW's trailing phase text, propertised."
  (let* ((phase (plist-get row :phase))
         (look (decknix-review-board--phase-look phase))
         (rank (decknix-review-board-row-rank row))
         (detail (plist-get row :phase-detail))
         (state (plist-get row :state))
         (lane (plist-get row :lane))
         (verb (plist-get row :verb))
         (progress (plist-get row :progress)))
    (cond
     ((and (not has-session) (plist-get row :rereview))
      (concat (propertize (nth 2 look) 'face (decknix-review-board--severity-face rank))
              (and detail (concat "  " detail))
              (propertize "  · no session" 'face 'font-lock-comment-face)))
     ((not has-session)
      (let ((note (decknix-review-board--clone-note row)))
        (propertize (or note "no session")
                    'face (if (and note (string-prefix-p "clone failed" note))
                              'error
                            'font-lock-comment-face))))
     (t
      (concat
       (when (eq lane 'obsolete)
         (propertize (concat (decknix-review-board--gone-label row) "  ")
                     'face 'font-lock-comment-face))
       (when (and (eq lane 'doing) verb)
         (propertize (format "%s " verb) 'face 'font-lock-keyword-face))
       (when (and (eq lane 'doing) progress)
         (propertize (format "%s " progress) 'face 'font-lock-constant-face))
       (propertize (nth 2 look) 'face (decknix-review-board--severity-face rank))
       (when (and detail (not (string-empty-p detail)))
         (concat "  " (if (equal detail "moot")
                          (propertize detail 'face 'font-lock-comment-face)
                        detail)))
       (when (and (eq phase 'idle) state
                  (not (member state '("ready" "finished"))))
         (propertize (concat "  " state) 'face 'font-lock-comment-face)))))))

(defun decknix-review-board--row-help (_window object pos)
  "Return the hover text for the row at POS in OBJECT: its priority breakdown.
Computed when hovered, not when painted, so a repaint costs nothing for it."
  (when-let* ((row (and (bufferp object)
                        (get-text-property pos 'decknix-review-board-row object))))
    (let* ((key (car (plist-get row :prs)))
           (item (decknix-review-board--item-for-key key)))
      (concat
       (or key "?")
       (if (and item (fboundp 'decknix--hub-review-priority-explain))
           (concat "\n" (decknix--hub-review-priority-explain
                         item
                         (and (fboundp 'decknix--hub-review-status)
                              (decknix--hub-review-status item t))
                         (and (fboundp 'decknix--hub-request-age-days)
                              (decknix--hub-request-age-days item))))
         "\nleft the feed: priority 0 (merged, closed or no longer requested)")
       (if-let* ((d (plist-get row :phase-detail))) (concat "\n" d) "")))))

(defun decknix-review-board--window-width ()
  "Return the width of the window showing this buffer, or 160."
  (let ((win (get-buffer-window (current-buffer) t)))
    (if (window-live-p win) (window-width win) 160)))

(defvar-local decknix-review-board--rendered-width nil
  "Window width the board was last laid out for.")

(defun decknix-review-board--insert-row (row &optional title-width)
  "Insert one propertised ROW, its title TITLE-WIDTH columns wide."
  (let* ((title-width (or title-width
                          (decknix-review-board-columns-title-width
                           (decknix-review-board--window-width))))
         (status (decknix--hub-review-status-aggregate (plist-get row :statuses)))
         (badge (decknix--hub-review-status-badge status))
         (attention (plist-get row :attention))
         (marked (and decknix-review-board--marks
                      (decknix-review-board--marked-p row)))
         ;; A session indicator, because the two largest lanes are mostly
         ;; NOT sessions.  Without it a request with no agent and a session
         ;; that happens to be idle render identically, and the board reads
         ;; as a list of stale sessions to clean up rather than a backlog.
         (has-session (and (plist-get row :session) t))
         (look (decknix-review-board--phase-look (plist-get row :phase)))
         (rank (decknix-review-board-row-rank row))
         (facts (decknix-review-board--row-facts row))
         (item (car facts))
         (entry (cdr facts))
         (author (decknix-review-board-columns-author
                  (or (alist-get 'author item) (plist-get entry :author))
                  (or (alist-get 'author_kind item) (plist-get entry :author-kind))))
         (age (decknix-review-board-columns-age
               (or (alist-get 'created item) (plist-get entry :created))
               (let ((times (delq nil (list (plist-get row :activity)
                                            (plist-get row :since)))))
                 (and times (apply #'max times)))))
         (ci (decknix-review-board-columns-ci item))
         (mine (decknix-review-board-columns-my-review item))
         (threads (decknix-review-board-columns-threads item))
         (cell #'decknix-review-board-columns-cell)
         (line
          (concat
           (if marked "*" " ") " "
           (funcall cell (if (string-empty-p badge) "" badge) 2) " "
           (if (or has-session (plist-get row :rereview))
               (propertize (nth 0 look) 'face (decknix-review-board--severity-face rank))
             (propertize "\u00b7" 'face 'font-lock-comment-face))
           " "
           (format "%5d" (plist-get row :priority)) "  "
           (funcall cell (decknix-review-board--row-key-label row) 24) " "
           (funcall cell (decknix-review-board--row-title row) title-width) " "
           (propertize (funcall cell author decknix-review-board-columns-author-width)
                       'face 'font-lock-comment-face)
           " "
           (propertize (funcall cell age 9) 'face 'font-lock-comment-face) " "
           (propertize (car ci) 'face (decknix-review-board--severity-face (cdr ci))) " "
           (propertize (funcall cell (car mine) 2)
                       'face (decknix-review-board--severity-face (cdr mine)))
           " "
           (funcall cell threads 6) " "
           (decknix-review-board--phase-text row has-session)))
         (row-face (decknix-review-board--row-face attention status)))
    (when row-face
      (add-face-text-property 0 (length line) row-face t line))
    (insert (propertize line
                        'decknix-review-board-row row
                        'help-echo #'decknix-review-board--row-help)
            "\n")))

(defun decknix-review-board--column-labels (title-width)
  "Return the column labels for a title TITLE-WIDTH wide.
Laid out with the same cells as a row, so the two cannot drift."
  (let ((cell #'decknix-review-board-columns-cell))
    (concat "m "
            (funcall cell "st" 2) " "
            "s"  " "
            (format "%5s" "pri") "  "
            (funcall cell "pr" 24) " "
            (funcall cell "title" title-width) " "
            (funcall cell "author" decknix-review-board-columns-author-width) " "
            (funcall cell "age/quiet" 9) " "
            "c" " "
            (funcall cell "me" 2) " "
            (funcall cell "thr" 6) " "
            "phase")))

(defun decknix-review-board--header-line ()
  "Return the board's header line: the column labels, pinned while scrolling."
  (concat (propertize " " 'display '(space :align-to 0))
          (propertize (decknix-review-board--column-labels
                       (decknix-review-board-columns-title-width
                        (decknix-review-board--window-width)))
                      'face 'font-lock-comment-face)))

(defun decknix-review-board--header-text ()
  "Return the board's two header lines: state, then the main keys."
  (let ((need (decknix-review-board-attention-count decknix-review-board--model))
        (stalled (decknix-review-board-stalled-count decknix-review-board--model)))
    (concat
     (propertize "Review Board" 'face 'decknix-review-board-lane)
     (format "  %d rows" (decknix-review-board-count decknix-review-board--model))
     (if (> need 0)
         (propertize (format "  %s %d need you" decknix-attention-glyph need)
                     'face 'decknix-attention-face)
       "")
     (if (> stalled 0)
         (propertize (format "  %d stalled" stalled) 'face 'decknix-attention-face)
       "")
     ;; Auto-review state belongs HERE, not only in the Requests
     ;; transient: this is the screen where you decide what to do about
     ;; reviews, so the policy that spawns them unasked is part of it.
     (propertize (format "   %s · auto-review %s · re-review %s · auto-dismiss %s"
                         (if decknix-review-board-show-all "ALL requests" "filtered")
                         (if (fboundp 'decknix-auto-review-state-label)
                             (format "[%s]" (decknix-auto-review-state-label
                                             decknix-auto-review-mode))
                           "[?]")
                         (format "[%s]" (or decknix-review-board-auto-rereview "off"))
                         (if decknix-review-board-auto-dismiss "[on]" "[off]"))
                 'face 'font-lock-constant-face)
     "\n"
     ;; The keys used every day; `?' has the rest.  Eight lines of cheat
     ;; sheet pushed the rows off a laptop screen.
     (propertize
      "  RET open  v view  i inspect  j jump  y/1-9 answer, nudge or resume  d dispatch  k quit  s merge  R re-review  g refresh  ? all keys\n"
      'face 'font-lock-comment-face))))

(defun decknix-review-board--render ()
  "Render `decknix-review-board--model' into the current buffer."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (title-width (decknix-review-board-columns-title-width
                      (decknix-review-board--window-width))))
    (setq decknix-review-board--rendered-width (decknix-review-board--window-width))
    (erase-buffer)
    (insert (decknix-review-board--header-text) "\n")
    (dolist (lane decknix-review-board-lanes)
      (let* ((rows (alist-get (car lane) decknix-review-board--model))
             (face (if (memq (car lane) '(needs-you rereview stalled))
                       'decknix-review-board-needs-you
                     'decknix-review-board-lane)))
        ;; Empty lanes are rendered too: a lane's position on screen has
        ;; to be learnable, and one that vanishes when empty means the
        ;; layout shifts under you exactly when you are scanning it.
        (insert (propertize (format "%s (%d)" (cdr lane) (length rows)) 'face face)
                (propertize
                 (format "  %s\n"
                         (or (alist-get (car lane) decknix-review-board-lane-help)
                             ""))
                 'face 'font-lock-comment-face))
        (if rows
            (dolist (row rows) (decknix-review-board--insert-row row title-width))
          (insert (propertize "    (none)\n" 'face 'font-lock-comment-face)))
        (insert "\n")))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun decknix-review-board--on-resize (&rest _)
  "Lay the board out again when its window's width changed.  Model only."
  (when-let* ((buf (get-buffer decknix-review-board-buffer-name))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (unless (eql decknix-review-board--rendered-width
                   (decknix-review-board--window-width))
        (decknix-review-board--render)))))

;; ── commands ─────────────────────────────────────────────────────────

(defun decknix-review-board--row-at-point ()
  "Return the row at point, or nil."
  (get-text-property (point) 'decknix-review-board-row))

(defun decknix-review-board-review-url (input)
  "Start review sessions for the PR url(s) in INPUT.

Prompts for free text rather than a single url: the common case is
pasting a line out of Slack that names two or three PRs, and making the
user split that by hand is the friction this removes.  Anything in the
text that is not a GitHub PR url is ignored (see
`decknix-review-board--parse-urls').

Sessions start in the BACKGROUND.  Dispatching three reviews should not
steal the window three times, and the board is the surface you watch them
from -- it refreshes itself once they are launched.

The board otherwise only acts on rows that already exist; this is the one
verb that adds work, which is why it asks rather than acting on point."
  (interactive
   (list (read-string
          "Review PR url(s): "
          (let ((clip (ignore-errors (current-kill 0 t))))
            (when (and (stringp clip)
                       (decknix-review-board--parse-urls clip))
              (string-trim clip))))))
  (let ((urls (decknix-review-board--parse-urls input)))
    (cond
     ((null urls)
      (message "No GitHub PR url found in that text"))
     ((and (> (length urls) 1)
           (not (yes-or-no-p (format "Start %d review sessions? " (length urls)))))
      (message "Cancelled"))
     (t
      (dolist (url urls)
        (if (fboundp 'decknix--nav-hub-start-review-background)
            (decknix--nav-hub-start-review-background url)
          (decknix--nav-hub-start-review url t)))
      (message "Started %d review session%s"
               (length urls) (if (= 1 (length urls)) "" "s"))
      (when (fboundp 'decknix-review-board-refresh)
        (ignore-errors (decknix-review-board-refresh)))))))

(defvar decknix-review-board--stale nil
  "Non-nil when a session's turn moved while the board was not on screen.")

(setq decknix-review-board-prcache-changed-function
      #'decknix-review-board-schedule-refresh)

(defun decknix-review-board-refresh ()
  "Rebuild and re-render the board."
  (interactive)
  (when-let* ((buf (get-buffer decknix-review-board-buffer-name)))
    (setq decknix-review-board--stale nil)
    (with-current-buffer buf
      (setq decknix-review-board--model
            (let ((m (decknix-review-board--build)))
              (if decknix-review-board-auto-dismiss
                  (decknix-review-board-drop-finished m)
                m)))
      (decknix-review-board--render))))

(defcustom decknix-review-board-settle-delay 1.0
  "Seconds after a session's turn ends or starts before the board repaints."
  :type 'number
  :group 'decknix-review-board)

(defvar decknix-review-board--settle-timer nil
  "Pending repaint armed by `decknix-review-board-schedule-refresh', or nil.")

(defun decknix-review-board--settle-refresh ()
  "Repaint the board for a session whose turn changed, if it is on screen.
Otherwise mark it stale, for `decknix-review-board-refresh-if-stale'."
  (setq decknix-review-board--settle-timer nil)
  (when-let* ((buf (get-buffer decknix-review-board-buffer-name)))
    (if (get-buffer-window buf t)
        (ignore-errors (decknix-review-board-refresh))
      (setq decknix-review-board--stale t))))

(defun decknix-review-board-refresh-if-stale (&rest _)
  "Repaint the board now that it is shown, if a turn moved while it was not.

The board usually lives in a tab of its own, and a turn that ends while
another tab is selected skips the repaint.  Switching back then showed the
rows as they were, so a session that had reached its gate still read
`In progress' until the reviews feed next changed.  Run from
`tab-bar-tab-post-select-functions' and the board's own
`window-buffer-change-functions'."
  (when-let* ((decknix-review-board--stale)
              (buf (get-buffer decknix-review-board-buffer-name))
              ((get-buffer-window buf t)))
    (ignore-errors (decknix-review-board-refresh))))

(defun decknix-review-board-schedule-refresh ()
  "Repaint the board shortly, once, when a session's turn ends or starts.

The board used to rebuild only when the reviews feed was re-read, which
says nothing about sessions: a review reaching its gate changes no
GitHub data, so the row kept saying `working' until the hub next wrote
`github-reviews.json', minutes later.  A turn boundary is exactly when a
row's state moves, so that is when to repaint.

Coalesced on one timer, because several sessions finishing together
should cost one repaint, and skipped while the board is not shown: the
next `g' or feed refresh rebuilds it anyway.  A plain timer, not an idle
one: turns end from a process filter while you are often already idle,
and an idle timer armed then waits for the NEXT idle period, which is
the staleness this exists to remove."
  (when (and (get-buffer decknix-review-board-buffer-name)
             (not (timerp decknix-review-board--settle-timer)))
    (setq decknix-review-board--settle-timer
          (run-with-timer decknix-review-board-settle-delay nil
                          #'decknix-review-board--settle-refresh))))

(defun decknix-review-board-next ()
  "Move to the next row."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp)) (not (decknix-review-board--row-at-point)))
      (forward-line 1))
    (unless (decknix-review-board--row-at-point) (goto-char start))))

(defun decknix-review-board-prev ()
  "Move to the previous row."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (not (bobp)) (not (decknix-review-board--row-at-point)))
      (forward-line -1))
    (unless (decknix-review-board--row-at-point) (goto-char start))))

(defun decknix-review-board-jump ()
  "Jump to the session buffer for the row at point."
  (interactive)
  (if-let* ((row (decknix-review-board--row-at-point))
            (buf (plist-get row :buffer)))
      (pop-to-buffer buf)
    (user-error "No session for this row")))

(defun decknix-review-board-browse ()
  "Browse the PR for the row at point.
For a group, browses its highest-priority member -- the one it starts
with, so the link matches where the session's attention is."
  (interactive)
  (if-let* ((row (decknix-review-board--row-at-point))
            (url (decknix-review-board-row-url row)))
      (browse-url url)
    (user-error "No PR URL for this row")))

(defun decknix-review-board-copy-url ()
  "Copy the PR URL(s) for the target rows to the kill ring.

A group copies every member, newline-separated, because the useful thing
to paste about a grouped row is the whole set -- that is what makes it a
group."
  (interactive)
  (let* ((rows (decknix-review-board--targets))
         (urls (delq nil
                     (apply #'append
                            (mapcar
                             (lambda (row)
                               (mapcar (lambda (key)
                                         (decknix-review-board-row-url
                                          (list :prs (list key))))
                                       (plist-get row :prs)))
                             rows)))))
    (unless urls (user-error "No PR URL for the selection"))
    (kill-new (string-join urls "\n"))
    (message "Copied %d URL%s" (length urls) (if (= 1 (length urls)) "" "s"))))

(defun decknix-review-board--marks-table ()
  "Return this buffer's mark table, creating it if needed."
  (or decknix-review-board--marks
      (setq decknix-review-board--marks (make-hash-table :test 'equal))))

(defun decknix-review-board--marked-p (row)
  "Non-nil when ROW is marked."
  (gethash (decknix-review-board-row-key row) (decknix-review-board--marks-table)))

(defun decknix-review-board--marked-rows ()
  "Return the marked rows, in lane order."
  (seq-filter #'decknix-review-board--marked-p
              (decknix-review-board-rows decknix-review-board--model)))

(defun decknix-review-board--targets ()
  "Return the rows a verb should act on.

The marked set, or the row at point when nothing is marked.  The dired
convention, chosen because it is already in everyone's fingers rather
than because it is the only option."
  (or (decknix-review-board--marked-rows)
      (when-let* ((row (decknix-review-board--row-at-point))) (list row))))

(defun decknix-review-board--lane-at-point ()
  "Return the lane symbol whose section point is in, or nil."
  (save-excursion
    (let (lane)
      (while (and (not lane) (not (bobp)))
        (when-let* ((row (get-text-property (point) 'decknix-review-board-row)))
          (setq lane (plist-get row :lane)))
        (forward-line -1))
      lane)))

(defun decknix-review-board-mark ()
  "Mark the row at point and move on."
  (interactive)
  (when-let* ((row (decknix-review-board--row-at-point)))
    (puthash (decknix-review-board-row-key row) t (decknix-review-board--marks-table))
    (decknix-review-board--render)
    (decknix-review-board-next)))

(defun decknix-review-board-unmark ()
  "Unmark the row at point and move on."
  (interactive)
  (when-let* ((row (decknix-review-board--row-at-point)))
    (remhash (decknix-review-board-row-key row) (decknix-review-board--marks-table))
    (decknix-review-board--render)
    (decknix-review-board-next)))

(defun decknix-review-board-unmark-all ()
  "Clear every mark."
  (interactive)
  (clrhash (decknix-review-board--marks-table))
  (decknix-review-board--render)
  (message "Marks cleared"))

(defun decknix-review-board-mark-lane ()
  "Mark every row in the lane at point."
  (interactive)
  (if-let* ((lane (decknix-review-board--lane-at-point))
            (rows (decknix-review-board-lane-rows decknix-review-board--model lane)))
      (progn
        (dolist (row rows)
          (puthash (decknix-review-board-row-key row) t
                   (decknix-review-board--marks-table)))
        (decknix-review-board--render)
        (message "Marked %d in %s" (length rows) lane))
    (user-error "No lane here")))

(defun decknix-review-board--report (verb done skipped)
  "Message what VERB did to DONE rows and did not do to SKIPPED ones."
  (message "%s: %d row%s%s" verb done (if (= done 1) "" "s")
           (if skipped
               (format " (%d skipped: nothing to act on)" skipped)
             "")))

(defun decknix-review-board-dispatch ()
  "Dispatch review sessions for the target rows.

Routes through the auto-review dispatcher, so a group launches as ONE
session with the same command and ordering auto-review would have used.
A board that dispatched differently from the automatic path would be a
second way to get it wrong."
  (interactive)
  (let* ((part (decknix-review-board-partition-targets
                'dispatch (decknix-review-board--targets)))
         (rows (car part))
         (done 0)
         (unplaced nil))
    (unless rows (user-error "Nothing to dispatch"))
    (dolist (row rows)
      (let* ((items (or (plist-get row :items)
                        (when-let* ((i (plist-get row :item))) (list i))))
             (first (car items))
             (repo (car (last (split-string (or (alist-get 'repo first) "") "/"))))
             (author (or (alist-get 'author first) ""))
             (action (if (decknix-review-board--item-bot-p first) 'ship 'review))
             (coords (decknix-review-board--row-owner-repo row)))
        ;; Pressing `d' on a row whose clone failed is the retry.
        (when (and coords (fboundp 'decknix-review-clone-clear))
          (decknix-review-clone-clear (car coords) (cdr coords)))
        (when (and items (fboundp 'decknix-auto-review--dispatch-unit))
          (if (ignore-errors
                (decknix-auto-review--dispatch-unit (list action repo author items)))
              (setq done (1+ done))
            (push (or (car coords) repo) unplaced)))))
    (decknix-review-board-unmark-all)
    (decknix-review-board-refresh)
    (if unplaced
        (message "Dispatched %d; not placed: no workspace for %s (add to decknix.workspaces, or C to clone elsewhere)"
                 done (string-join (delete-dups (nreverse unplaced)) ", "))
      (decknix-review-board--report "Dispatched" done (length (cdr part))))))

(defun decknix-review-board-clone-elsewhere (parent)
  "Clone the row at point's repository under PARENT, then dispatch its review.

For a PR whose org maps to no workspace: `d' cannot place it, and
guessing a directory would scatter clones.  Asks for the parent
directory (the org's workspace when there is one), clones into
PARENT/REPO in the background, and dispatches the row once the clone is
on disk.  Add the org to `decknix.workspaces' to make this automatic."
  (interactive
   (let* ((row (decknix-review-board--row-at-point))
          (coords (and row (decknix-review-board--row-owner-repo row))))
     (unless coords (user-error "No PR repository on this row"))
     (list (read-directory-name
            (format "Clone %s/%s under: " (car coords) (cdr coords))
            (or (and (fboundp 'decknix-workspace-for-org)
                     (decknix-workspace-for-org (car coords)))
                "~/Code/")))))
  (let* ((row (decknix-review-board--row-at-point))
         (coords (decknix-review-board--row-owner-repo row))
         (owner (car coords))
         (repo (cdr coords))
         (target (expand-file-name repo (expand-file-name parent))))
    (unless (fboundp 'decknix-review-clone-ensure)
      (user-error "On-demand cloning is not loaded"))
    (decknix-review-clone-clear owner repo)
    (message "Cloning %s/%s into %s..." owner repo target)
    (decknix-review-clone-ensure
     owner repo target
     (lambda (ok value)
       (if (not ok)
           (message "Clone of %s/%s failed: %s" owner repo value)
         (message "Cloned %s/%s; dispatching its review" owner repo)
         (let* ((items (or (plist-get row :items)
                           (when-let* ((i (plist-get row :item))) (list i))))
                (first (car items)))
           (when (and items (fboundp 'decknix-auto-review--dispatch-unit))
             (decknix-auto-review--dispatch-unit
              (list (if (decknix-review-board--item-bot-p first) 'ship 'review)
                    repo (or (alist-get 'author first) "") items))))))
     (and (fboundp 'decknix-workspace-clone-args)
          (decknix-workspace-clone-args owner)))
    (decknix-review-board-refresh)))

(defun decknix-review-board--session-buffers (rows)
  "Return the live session buffers for ROWS."
  (delq nil (mapcar (lambda (r)
                      (let ((b (plist-get r :buffer)))
                        (and (buffer-live-p b) b)))
                    rows)))

(defun decknix-review-board-quit-sessions ()
  "Quit the target sessions, terminating their brokers.

Confirms first, and says how many.  Under brokering a killed buffer
leaves the agent running, so ending a session is now an explicit act --
and doing it to several at once is exactly when a count is worth
reading before rather than after."
  (interactive)
  (let* ((part (decknix-review-board-partition-targets
                'quit (decknix-review-board--targets)))
         (bufs (decknix-review-board--session-buffers (car part))))
    (unless bufs (user-error "No live sessions to quit"))
    ;; Confirmation, the broker-stop rule and the kill all live in
    ;; `decknix-agent-session-lifecycle', shared with the Session Board.  The
    ;; two copies had already drifted -- this one suppressed
    ;; `kill-buffer-query-functions' and the other did not.
    (when-let ((n (decknix-session-lifecycle-quit bufs)))
      (decknix-review-board-unmark-all)
      (decknix-review-board-refresh)
      (decknix-review-board--report "Quit" n (length (cdr part))))))

(defun decknix-review-board-detach-sessions ()
  "Detach the target sessions, leaving their agents running.
No confirmation: detaching is reversible, and the agent keeps working."
  (interactive)
  (let* ((part (decknix-review-board-partition-targets
                'detach (decknix-review-board--targets)))
         (bufs (decknix-review-board--session-buffers (car part))))
    (unless bufs (user-error "No live sessions to detach"))
    (let ((n (decknix-session-lifecycle-detach bufs)))
      (decknix-review-board-unmark-all)
      (decknix-review-board-refresh)
      (decknix-review-board--report "Detached" n (length (cdr part))))))

(defvar decknix-review-board-merge-command "/merge-train"
  "Command the board hands a merge plan to.
It owns train ordering and its own confirmation gate; the board's job is
to name the PRs, not to merge them.")

(defun decknix-review-board--row-status (row)
  "Return ROW's aggregated staleness."
  (decknix--hub-review-status-aggregate (plist-get row :statuses)))

(defun decknix-review-board--manifest (by-repo blocked dry)
  "Return the confirmation manifest text for a merge plan."
  (with-temp-buffer
    (insert (format "Merge plan%s

" (if dry "  (DRY RUN)" "")))
    (dolist (cell by-repo)
      (insert (format "  %s
    %s %s
"
                      (car cell)
                      decknix-review-board-merge-command
                      (string-join (cdr cell) " "))))
    (when blocked
      (insert "
  NOT merging:
")
      (dolist (b blocked)
        (insert (format "    %-28s %s
"
                        (or (car (plist-get (car b) :prs)) "?")
                        (cdr b)))))
    (buffer-string)))

(defun decknix-review-board-merge (&optional dry)
  "Merge the target rows via `decknix-review-board-merge-command'.

With a prefix argument, DRY: passes `--dry', so the train is planned and
printed without merging anything.

The board does not merge.  It names the PRs and hands them to a command
that owns train ordering and its own confirmation gate -- so this gate is
the SECOND one, not the only one.  That is deliberate: the batch case
cannot be looser than the single-PR case, which already requires an
explicit confirmation before anything is posted.

Refuses stale and already-merged rows, and SAYS which.  A merge that
silently dropped them would be indistinguishable from one that merged
them."
  (interactive "P")
  (let* ((rows (decknix-review-board--targets))
         (plan (decknix-review-board-merge-plan
                rows #'decknix-review-board--row-status))
         (by-repo (car plan))
         (blocked (cdr plan)))
    (unless rows (user-error "Nothing selected"))
    (unless by-repo
      (user-error "Nothing to merge%s"
                  (if blocked
                      (format " (%d blocked: %s)" (length blocked)
                              (mapconcat #'cdr blocked "; "))
                    "")))
    (let ((manifest (decknix-review-board--manifest by-repo blocked dry)))
      ;; Shown in full, then confirmed.  A count is not a manifest: the
      ;; point is to read the PR numbers before they merge, not to be
      ;; told how many there were afterwards.
      (with-current-buffer (get-buffer-create "*Review Board Merge Plan*")
        (let ((inhibit-read-only t))
          (erase-buffer) (insert manifest) (goto-char (point-min)))
        (special-mode)
        (display-buffer (current-buffer)))
      (if (not (yes-or-no-p
                (format "Hand %d train%s to %s? "
                        (length by-repo) (if (= 1 (length by-repo)) "" "s")
                        decknix-review-board-merge-command)))
          (message "Merge cancelled")
        (dolist (cell by-repo)
          (let* ((repo (car cell))
                 (nums (cdr cell))
                 (workspace (decknix--agent-pr-detect-workspace nil repo))
                 (command (format "%s %s%s"
                                  decknix-review-board-merge-command
                                  (string-join nums " ")
                                  (if dry " --dry" ""))))
            (if (not workspace)
                (message "No workspace for %s; skipped" repo)
              (decknix--agent-quickaction-start
               (format "merge-%s" repo)
               (list "merge" repo "train") workspace command
               nil nil nil t))))
        (decknix-review-board-unmark-all)
        (decknix-review-board-refresh)
        (message "Handed %d train%s to %s%s"
                 (length by-repo) (if (= 1 (length by-repo)) "" "s")
                 decknix-review-board-merge-command
                 (if blocked (format "; %d blocked" (length blocked)) ""))))))

(defconst decknix-review-board-help-text
  "Review Board

  The review WORKLIST, not a session list.  Most rows in Grouped and Idle
  have no agent on them at all -- they are PRs waiting for someone.

NAVIGATE
  n / p, TAB      next / previous row
  r               review PR url(s) not listed here -- paste one or several;
                  the only verb that ADDS work rather than acting on a row
  RET / o         browse the PR on GitHub
  c / w           copy the PR URL(s) to the kill ring
  i               inspect: what this session is asking, or the PR detail
  v               view the PR in *PR Review: repo#N*: description, CI,
                  reviews, every thread by file, and the agent's saved plan
                  (read-only; RET on a thread opens it on GitHub)
  j               jump to the session buffer
                  (and back: C-c C-b in a review session returns to its row)
  r               review a PR by url (paste one or several)
  g               refresh          q  bury          ?  this help
  A               cycle auto-review: off / bot / human / any
  x               toggle auto-dismiss: finished sessions drop off, or stay
  f               filters: the sidebar\'s, or the whole feed

FILTERS
  Requests use the SAME filters as the sidebar (bots, drafts, age, CI,
  mentions).  Without them the board showed 30 rows where the sidebar
  showed 2.  Sessions are never filtered -- a running agent is a fact,
  and an Obsolete session\'s PR has left the feed entirely.

MARK  (verbs act on the marked set, or the row at point when none marked)
  m / u           mark / unmark          U  unmark all
  M               mark every row in this lane

ANSWER  (the row at point only; always asks first)
  y               on a crashed session (lost its link): reset it and send
                  `continue\'; on a stalled one: nudge it on to its gate
                  (`decknix-review-board-nudge-prompt\'); otherwise send
                  \"yes\" to a session asking yes/no or yes/edit/cancel
  1-9             send that number to a session offering a numbered choice;
                  refused when it offered no such option
  The row says what each wants: `reply yes/edit/cancel', `reply 1-3, rec 1'.

ACT
  d               dispatch review sessions (a Grouped row launches ONE
                  session for the whole service, which is the point).
                  A repository with no checkout is cloned first into its
                  org\'s workspace (decknix.workspaces); the row reads
                  `cloning...\' meanwhile, or the clone error.  `d\' again
                  retries a failed clone
  C               clone the row\'s repository into a directory you pick,
                  then dispatch: for an org with no workspace
  k               quit sessions and TERMINATE their brokers (confirms)
  D               detach: close the buffer, agent keeps working
  s               merge via /merge-train     C-u s  dry run
  R               re-review a PR updated since the review: refresh its
                  worktree to the new head, then ask the review session
                  (resumed, or a new one) to review only the changes since,
                  check whether the feedback was addressed, and stop at the
                  confirmation gate as before.  C-u R acknowledges the push
                  without re-reviewing.  Once per head either way.
  X               cycle what an update does: off (board only) / notify
                  (message + needs you in the sidebar) / auto (start the
                  re-review); see `decknix-review-board-auto-rereview\'

LANES
  Needs you       asked you something, or crashed on the network
  Re-review       the author pushed since the review
  Stalled         stopped short of its gate without asking: `y\' nudges
  In progress     assessing, revising, or posting your answer
  Waiting on others  PR in draft, or the review handed to someone else
                  (the session said so, or another reviewer approved)
  Posted          your review is on GitHub          (most recent first)
  Obsolete        PR merged or closed: `k\' it     (most recent first)

COLUMNS  (labels pinned in the header line)
  m               `*\' when marked
  st              staleness badge, see BADGES
  s               the session's glyph (see PHASES), `·\' when nobody is on it
  pri             priority score, higher sorts first; hover for the breakdown
  pr, title       the PR; a merged one keeps its title from the cache
  author          short login, ⚙ for a bot
  age/quiet       how old the PR is / how long since anything moved
  c               CI: ✓ pass, ✗ fail, ◐ running
  me              my prior review: A approved, CR changes, C commented
  thr             open threads: hN human, bN bot
  phase           the phase, then what it waits on, or `no session\'

PHASES  (where a review is in /review-service-pr: assess, gate, post)
  \u2691  awaiting you  the plan is ready: verdict shown, with the reply it
                 wants (`reply 1-3, rec 1', `reply yes/edit/cancel')
  ⚑  asking        any other question; `permission\' too
  ✖  crashed       the last message is a network failure (red); y
  ⚑  stalled       stopped without posting or asking; y nudges it
  →  handed off    another reviewer has it (grey, Waiting on others)
  \u25d0  assessing     reading the PR; you have not answered it yet
  \u25d0  revising      changing the plan after you said edit
  \u25d1  posting       acting on your go-ahead: posting the review
  \u25cf  actioned      it acted on your go-ahead but reported no review link;
                 `i' to see what happened
  \u2713  posted        the review is on GitHub (the session said so, or
                 the feed has your review); filed under Posted
  \u2691  updated       the author pushed after the review (yours with
                 feedback, or another reviewer\'s while your session sat
                 finished); filed under Re-review with what changed:
                 commits, files, your threads, a dismissed approval.
                 Base-branch merges and same-diff rebases do not count.
  \u25cf  idle          nothing in flight

BADGES
  \u2298   gone       PR left your review queue (merged / closed).  The
                 session is obsolete; `k\' it.  Its row says merged or
                 closed (asked of GitHub once, kept on disk), and a
                 question it was asking reads `moot\'.
  \u21bb   stale      author pushed since -- the analysis is void
  \u2611   answered   someone else responded; may be redundant

PRIORITY  (why the numbers look the way they do)
  Two axes added together, so the score is a rank, not a percentage, and
  NEGATIVE IS NORMAL for deprioritised work.

    what     incident +100   deferred -30   feature 0
    where    replies-to-me +60  needs-reply +50  re-requested +45
             stale +40  mine +30  team +15  otherwise +10
    minus    bot -35   draft -40   answered -25   gone -1000
    plus     age, +1/day, capped at +14

  So a bot PR nobody has asked you about scores 10 - 35 = -25.  That is
  it saying `real, but not next'.  Hover a row for its breakdown.

COLOURS  (the sidebar's)
  red failed or crashed, amber waiting on you, plain in flight, green
  done, grey quiet (waiting on others, obsolete, no session)."
  "Help text for `decknix-review-board-help'.

Spelled out rather than deferred to `describe-mode' because the two
things that confuse a first reader -- why most rows have no session, and
why the numbers go negative -- are not answerable from a keymap.")

(defun decknix-review-board-help ()
  "Show the board's keys and legend."
  (interactive)
  (let ((buf (get-buffer-create "*Review Board Help*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert decknix-review-board-help-text)
        (goto-char (point-min)))
      (special-mode))
    (display-buffer buf)))

;;;###autoload
(defun decknix-agent-session-pr-url (&optional open)
  "Copy the PR URL(s) this session is reviewing.  With OPEN, browse instead.

Works from the session buffer itself, not only from the board: when you
are reading a review you generally want its PR to hand, and going via the
board to get there is a detour through a screen you did not want.

Uses the recorded coordinates, so it still answers for a session whose PR
has merged -- which is when you most want the link, to confirm it did."
  (interactive "P")
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (let* ((ck (bound-and-true-p decknix--agent-conv-key))
         (prs (and ck (ignore-errors
                        (decknix--agent-review-prs-for-conv-key ck))))
         (urls (delq nil
                     (mapcar (lambda (key)
                               (decknix-review-board-row-url (list :prs (list key))))
                             prs))))
    (unless urls
      (user-error "No PR recorded for this session"))
    (if open
        (progn (browse-url (car urls))
               (message "Opened %s" (car urls)))
      (kill-new (string-join urls "\n"))
      (message "Copied %d URL%s: %s"
               (length urls) (if (= 1 (length urls)) "" "s") (car urls)))))

(defcustom decknix-review-board-inspect-lines 40
  "How many trailing lines of a session to show in the inspect window.

Trailing rather than \"the last agent message\": the message boundary is
not reliably delimited in the rendered buffer, and guessing it wrong
would silently truncate the question you are trying to read.  A fixed
tail is dumber and cannot mislead."
  :type 'integer
  :group 'decknix-review-board)

(defconst decknix-review-board-inspect-buffer "*Review Board Inspect*"
  "Buffer showing the detail of the row at point.")

(defun decknix-review-board--inspect-session (row)
  "Return inspect text for a ROW that has a live session."
  (let ((buf (plist-get row :buffer)))
    (if (not (buffer-live-p buf))
        "session buffer is gone"
      (with-current-buffer buf
        (let* ((end (point-max))
               (start (save-excursion
                        (goto-char end)
                        (forward-line (- decknix-review-board-inspect-lines))
                        (line-beginning-position))))
          (concat
           (format "state: %s\n" (or (ignore-errors
                                        (decknix-agent-buffer-status buf))
                                      "?"))
           (format "phase: %s%s\n\n"
                   (nth 2 (decknix-review-board--phase-look (plist-get row :phase)))
                   (if-let* ((d (plist-get row :phase-detail))
                             ((not (string-empty-p d))))
                       (concat "   " d)
                     ""))
           (buffer-substring-no-properties start end)))))))

(defun decknix-review-board--inspect-request (row)
  "Return inspect text for a ROW with no session: the PR as the feed sees it."
  (let* ((key (car (plist-get row :prs)))
         (item (decknix-review-board--item-for-key key)))
    (if (not item)
        (concat "No feed entry for " (or key "?") ".\n\n"
                "That normally means the PR has left your review queue --\n"
                "merged, closed, or no longer requested of you.")
      (concat
       (format "%s\n\n" (or (map-elt item 'title) ""))
       (format "author    %s%s\n" (or (map-elt item 'author) "?")
               (if (eq t (map-elt item 'draft)) "   (draft)" ""))
       (format "updated   %s\n" (or (map-elt item 'updated) "?"))
       (format "threads   %s unresolved of %s\n"
               (or (map-elt item 'unresolved_threads) 0)
               (or (map-elt item 'total_threads) 0))
       (format "decision  %s\n\n" (or (map-elt item 'review_decision) "-"))
       ;; The priority breakdown, because a number you cannot interrogate
       ;; is an ordering you cannot trust -- and this is where someone
       ;; actually asks "why is this one above that one?".
       (if (fboundp 'decknix--hub-review-priority-explain)
           (decknix--hub-review-priority-explain
            item
            (when (fboundp 'decknix--hub-review-status)
              (decknix--hub-review-status item t))
            (when (fboundp 'decknix--hub-request-age-days)
              (decknix--hub-request-age-days item)))
         "")))))

(defun decknix-review-board-inspect ()
  "Show the detail of the row at point in a side window.

Read-only, and deliberately so at this step: seeing what a session is
asking is most of the value, and it carries none of the risk of
answering it from a screen that shows only a row."
  (interactive)
  (let ((row (decknix-review-board--row-at-point)))
    (unless row (user-error "No row here"))
    (let* ((title (or (plist-get row :name) (car (plist-get row :prs)) "?"))
           (url (decknix-review-board-row-url row))
           (body (concat
                  (if-let* ((info (plist-get row :rereview)))
                      (decknix-review-board-rereview-detail info)
                    "")
                  (if (plist-get row :session)
                      (decknix-review-board--inspect-session row)
                    (decknix-review-board--inspect-request row))))
           (buf (get-buffer-create decknix-review-board-inspect-buffer)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize title 'face 'decknix-review-board-lane) "\n")
          (when url (insert (propertize url 'face 'link) "\n"))
          (insert "\n" body)
          (goto-char (point-min)))
        (special-mode))
      (display-buffer buf '((display-buffer-below-selected)
                            (window-height . 0.45)
                            (inhibit-same-window . t))))))

(defcustom decknix-review-board-nudge-prompt
  "You stopped without reaching the review's confirmation gate. Carry on from where you left off: finish the analysis, present the complete plan, and stop at the gate for my answer. Do not post anything yet."
  "What `y' sends to a stalled review session.
It asks for the gate, never for a post, so a nudge cannot route around
the confirmation the review command requires."
  :type 'string
  :group 'decknix-review-board)

(defun decknix-review-board--send (buf prompt)
  "Send PROMPT to BUF through the bulk dispatcher: now if idle, else queued."
  (if (fboundp 'decknix--session-bulk-dispatch)
      (decknix--session-bulk-dispatch (list buf) prompt)
    (user-error "Session dispatch is not loaded")))

(defun decknix-review-board--resume-crashed (row buf)
  "Reset ROW's session BUF after a network failure and send it `continue'."
  (when (yes-or-no-p (format "%s lost its link%s.  Reset it and send \"%s\"? "
                             (buffer-name buf)
                             (if-let* ((d (plist-get row :netfail)))
                                 (format " (%s)" d) "")
                             (if (boundp 'decknix-agent-net-error-retry-prompt)
                                 decknix-agent-net-error-retry-prompt
                               "continue")))
    (when (fboundp 'decknix--agent-net-error-reset-buffer)
      (decknix--agent-net-error-reset-buffer buf))
    (decknix-review-board--send buf (if (boundp 'decknix-agent-net-error-retry-prompt)
                                        decknix-agent-net-error-retry-prompt
                                      "continue"))
    t))

(defun decknix-review-board--nudge (buf)
  "Ask before sending BUF the nudge prompt."
  (when (yes-or-no-p (format "Nudge %s on to its review gate?  It is sent: \"%s\" "
                             (buffer-name buf)
                             (truncate-string-to-width decknix-review-board-nudge-prompt 60
                                                       nil nil "…")))
    (decknix-review-board--send buf decknix-review-board-nudge-prompt)
    t))

(defun decknix-review-board-reply ()
  "Answer, nudge or resume the session at point with the key just pressed.

`y' on a crashed session (lost its link) resets it and sends `continue';
on a stalled one (stopped without asking) it sends
`decknix-review-board-nudge-prompt'.  Otherwise `y' sends \"yes\" to a
session asking yes or no (or offering yes among its words), and `1'-`9'
send that option's number to one offering a numbered choice.  The row at
point only, never the marked set: one keystroke answering several gates
at once would post several reviews.  Always asks first, naming the
session and what is sent, and refuses a key the question did not offer
\(see `decknix-agent-turn-quick-reply')."
  (interactive)
  (let* ((row (decknix-review-board--row-at-point))
         (buf (and row (plist-get row :buffer)))
         (key (decknix-agent-turn-reply-key last-command-event))
         (phase (plist-get row :phase))
         (yes (eq last-command-event ?y)))
    (unless (buffer-live-p buf) (user-error "No session on this row"))
    (unless key (user-error "Not a reply key"))
    (when (cond
           ((and yes (eq phase 'netfail)) (decknix-review-board--resume-crashed row buf))
           ((and yes (eq phase 'stalled)) (decknix-review-board--nudge buf))
           (t (decknix-agent-turn-quick-reply buf key)))
      (decknix-review-board-schedule-refresh))))

(defun decknix-review-board-view ()
  "Open the PR at point in a review buffer: description, CI, threads, plan.
Read-only for now.  Everything it shows is fetched in the background, so
it opens at once and fills in."
  (interactive)
  (let* ((row (or (decknix-review-board--row-at-point)
                  (user-error "No row here")))
         (url (decknix-review-board-row-url row))
         (parsed (decknix-review-board--parse-pr-url url)))
    (unless parsed (user-error "No PR url for this row"))
    (unless (fboundp 'decknix-pr-review-view-open)
      (user-error "The PR review view is not loaded"))
    (decknix-pr-review-view-open (alist-get 'owner parsed) (alist-get 'repo parsed)
                                 (string-to-number (alist-get 'number parsed)) url)))

(defun decknix-review-board-toggle-auto-dismiss ()
  "Toggle whether finished sessions drop off the board automatically.
See `decknix-review-board-auto-dismiss'."
  (interactive)
  (setq decknix-review-board-auto-dismiss
        (not decknix-review-board-auto-dismiss))
  (decknix-review-board-refresh)
  (message "Auto-dismiss %s%s"
           (if decknix-review-board-auto-dismiss "on" "off")
           (if decknix-review-board-auto-dismiss
               " — merged/closed PRs' sessions now drop off"
             " — finished sessions stay for manual quit")))

(defun decknix-review-board-cycle-auto-review ()
  "Cycle the auto-review policy (off / bot / human / any) and re-render.

The same command the Requests transient exposes; surfaced here because
the board is where you decide what to do about reviews, and the policy
that spawns sessions without asking is part of that decision rather than
a setting kept somewhere else."
  (interactive)
  (unless (fboundp 'decknix-auto-review-cycle-mode)
    (user-error "Auto-review is not available"))
  (decknix-auto-review-cycle-mode)
  (decknix-review-board-refresh))

(defun decknix-review-board--rereview-refresh (owner repo number head callback)
  "Move the review worktree for OWNER/REPO#NUMBER to HEAD, then CALLBACK."
  (if (fboundp 'decknix--review-worktree-refresh-then)
      (decknix--review-worktree-refresh-then owner repo number head callback)
    (funcall callback nil)))

(defun decknix-review-board--rereview-deliver (row url prompt context)
  "Hand PROMPT to ROW's review session for URL, never taking a window.

The row's own live session first.  Otherwise the re-review routing:
another live buffer for the PR, else the saved session resumed in the
background, else a new review whose command carries CONTEXT (the prompt
without a worktree path, since the new session makes its own).  A busy
session gets the prompt queued, not interleaved with its turn."
  (let ((buf (plist-get row :buffer)))
    (if (and (buffer-live-p buf) (fboundp 'decknix-agent-re-review-send))
        (decknix-agent-re-review-send buf prompt t)
      (let* ((parsed (decknix-review-board--parse-pr-url url))
             (repo (alist-get 'repo parsed))
             (number (alist-get 'number parsed))
             (needle (and (fboundp 'decknix-agent-re-review-needle)
                          (decknix-agent-re-review-needle repo number)))
             (route (if (fboundp 'decknix-agent-re-review-target)
                        (decknix-agent-re-review-target
                         needle number
                         (and (fboundp 'agent-shell-buffers) (agent-shell-buffers))
                         (and (boundp 'decknix--sidebar-previous-sessions)
                              decknix--sidebar-previous-sessions))
                      (list 'fresh))))
        (pcase (car route)
          ('live (decknix-agent-re-review-send (cdr route) prompt t))
          ('saved
           (decknix--sidebar-restore-previous-session (cdr route) nil)
           (decknix-agent-re-review--send-when-ready needle prompt nil t))
          (_ (decknix--nav-hub-start-review-fresh url t parsed context)))))))

(setq decknix-review-board-rereview-refresh-function
      #'decknix-review-board--rereview-refresh
      decknix-review-board-rereview-deliver-function
      #'decknix-review-board--rereview-deliver)

(defun decknix-review-board--parse-pr-url (url)
  "Return URL's ((owner . O) (repo . R) (number . N)) alist, or nil.
The shape `decknix--agent-parse-pr-url' returns, from the board's own
regexp, so the board does not depend on the main package for it."
  (when (and (stringp url)
             (string-match decknix-review-board-pr-url-regexp url))
    (list (cons 'owner (match-string 1 url))
          (cons 'repo (match-string 2 url))
          (cons 'number (match-string 3 url)))))

(defun decknix-review-board--rereview-start-row (row info)
  "Start the re-review INFO describes for ROW."
  (let* ((url (decknix-review-board-row-url row))
         (parsed (decknix-review-board--parse-pr-url url)))
    (if (not parsed)
        (message "Review Board: no PR url for %s" (car (plist-get row :prs)))
      (decknix-review-board-rereview-start
       row info url (alist-get 'owner parsed) (alist-get 'repo parsed)
       (alist-get 'number parsed)))))

(defun decknix-review-board-rereview (&optional acknowledge)
  "Re-review the target rows the author updated since the review.

Refreshes each PR's worktree to its new head and asks the review session
to review only the changes since, behind the usual confirmation gate.
With a prefix argument, ACKNOWLEDGE the push instead: the row leaves the
Re-review lane without a re-review.  Either way, once per head."
  (interactive "P")
  (let* ((part (decknix-review-board-partition-targets
                'rereview (decknix-review-board--targets)))
         (rows (car part)))
    (unless rows (user-error "Nothing here was updated since its review"))
    (dolist (row rows)
      (let ((info (plist-get row :rereview)))
        (if acknowledge
            (decknix-review-board-rereview-mark-seen
             (car (plist-get row :prs)) (plist-get info :head))
          (decknix-review-board--rereview-start-row row info))))
    (decknix-review-board-unmark-all)
    (decknix-review-board-refresh)
    (decknix-review-board--report (if acknowledge "Acknowledged" "Re-reviewing")
                                  (length rows) (length (cdr part)))))

(defun decknix-review-board-cycle-auto-rereview ()
  "Cycle `decknix-review-board-auto-rereview': off, notify, auto."
  (interactive)
  (setq decknix-review-board-auto-rereview
        (pcase decknix-review-board-auto-rereview
          ('nil 'notify) ('notify 'auto) (_ nil)))
  (decknix-review-board-rereview-tick)
  (decknix-review-board-refresh)
  (message "Re-review on update: %s"
           (pcase decknix-review-board-auto-rereview
             ('nil "off (board only)")
             ('notify "notify")
             ('auto "auto (starts the re-review; never posts without you)"))))

(defun decknix-review-board--rereview-candidates-p (items)
  "Non-nil when any of ITEMS could be an update, settled session or not.
A cheap pass over the feed so the tick builds nothing on the common
poll where no PR moved."
  (let ((viewer (alist-get 'viewer decknix--hub-reviews)))
    (seq-some (lambda (item)
                (let ((key (decknix-review-board--item-key item)))
                  (decknix-review-board-rereview-info
                   item t viewer (decknix-review-board-rereview-seen-head key))))
              items)))

(defun decknix-review-board--rereview-rows ()
  "Return the board rows updated since their review."
  (when (decknix-review-board--rereview-candidates-p
         (alist-get 'items decknix--hub-reviews))
    (alist-get 'rereview (decknix-review-board--build))))

(defun decknix-review-board--rereview-flags (rows)
  "Return (BUFFER . REASON) for every ROWS entry with a live session."
  (delq nil (mapcar (lambda (row)
                      (let ((buf (plist-get row :buffer)))
                        (when (buffer-live-p buf)
                          (cons buf (concat "updated: "
                                            (decknix-review-board-rereview-summary
                                             (plist-get row :rereview)))))))
                    rows)))

(defun decknix-review-board-rereview-tick (&rest _)
  "Act on PRs updated since their review, after each reviews-feed refresh.

Flags their sessions as needing you (sidebar Needs you, `C-c A j', the
mode-line count), says so once per new head, and in `auto' starts the
re-review.  Runs from the hub refresh, not the board, so it works with
the board closed."
  (condition-case err
      (let ((rows (and decknix-review-board-auto-rereview
                       (decknix-review-board--rereview-rows))))
        (when (fboundp 'decknix-attention-set-flags)
          (decknix-attention-set-flags (decknix-review-board--rereview-flags rows)))
        (decknix-review-board-rereview-process
         rows decknix-review-board-auto-rereview
         #'decknix-review-board--rereview-start-row))
    (error (message "Review Board re-review check failed: %s"
                    (error-message-string err)))))

(defvar decknix-review-board-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'decknix-review-board-next)
    (define-key map (kbd "p") #'decknix-review-board-prev)
    (define-key map (kbd "TAB") #'decknix-review-board-next)
    (define-key map (kbd "<backtab>") #'decknix-review-board-prev)
    (define-key map (kbd "RET") #'decknix-review-board-browse)
    (define-key map (kbd "o") #'decknix-review-board-browse)
    (define-key map (kbd "j") #'decknix-review-board-jump)
    (define-key map (kbd "g") #'decknix-review-board-refresh)
    (define-key map (kbd "r") #'decknix-review-board-review-url)
    (define-key map (kbd "m") #'decknix-review-board-mark)
    (define-key map (kbd "u") #'decknix-review-board-unmark)
    (define-key map (kbd "U") #'decknix-review-board-unmark-all)
    (define-key map (kbd "M") #'decknix-review-board-mark-lane)
    (define-key map (kbd "d") #'decknix-review-board-dispatch)
    (define-key map (kbd "C") #'decknix-review-board-clone-elsewhere)
    (define-key map (kbd "k") #'decknix-review-board-quit-sessions)
    (define-key map (kbd "D") #'decknix-review-board-detach-sessions)
    (define-key map (kbd "s") #'decknix-review-board-merge)
    (define-key map (kbd "c") #'decknix-review-board-copy-url)
    (define-key map (kbd "w") #'decknix-review-board-copy-url)
    (define-key map (kbd "A") #'decknix-review-board-cycle-auto-review)
    (define-key map (kbd "x") #'decknix-review-board-toggle-auto-dismiss)
    (define-key map (kbd "f") #'decknix-review-board-toggle-filters)
    (define-key map (kbd "i") #'decknix-review-board-inspect)
    (define-key map (kbd "v") #'decknix-review-board-view)
    (define-key map (kbd "y") #'decknix-review-board-reply)
    (define-key map (kbd "R") #'decknix-review-board-rereview)
    (define-key map (kbd "X") #'decknix-review-board-cycle-auto-rereview)
    (dotimes (i 9)
      (define-key map (kbd (number-to-string (1+ i))) #'decknix-review-board-reply))
    (define-key map (kbd "?") #'decknix-review-board-help)
    (define-key map (kbd ".") #'decknix-review-board-help)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `decknix-review-board-mode'.

`k' and `D' mirror `C-c s q' and `C-c s D' so the quit/detach
distinction is learned once rather than twice.

`y' and the digits answer the session at point, behind a confirmation
naming what is sent: on a review gate the answer is what posts.

`s' merges, behind a manifest and an explicit confirmation.  There is no
`approve': `submit-pr-review' is deprecated and approval now happens
inside the review commands, behind the mandatory review gate.  A board
verb that approved directly would route around it.")

(define-derived-mode decknix-review-board-mode special-mode "ReviewBoard"
  "Major mode for the review worklist."
  (setq truncate-lines t)
  (buffer-disable-undo)
  (setq header-line-format '(:eval (decknix-review-board--header-line)))
  (add-hook 'window-buffer-change-functions
            #'decknix-review-board-refresh-if-stale nil t)
  (add-hook 'window-size-change-functions
            #'decknix-review-board--on-resize nil t))

;;;###autoload
(defun decknix-review-board ()
  "Open the review board."
  (interactive)
  (let ((buf (get-buffer-create decknix-review-board-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'decknix-review-board-mode)
        (decknix-review-board-mode))
      (setq decknix-review-board--model
            (let ((m (decknix-review-board--build)))
              (if decknix-review-board-auto-dismiss
                  (decknix-review-board-drop-finished m)
                m)))
      (decknix-review-board--render))
    (pop-to-buffer buf)))

(provide 'decknix-review-board)
;;; decknix-review-board.el ends here
