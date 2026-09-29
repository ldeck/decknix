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
;; Follows `decknix-dos-board' deliberately -- constant lanes, cursor,
;; single-key actions, read-only, refreshed rather than recomputed.  The
;; engine here is the hub JSON plus the pure packages (priority, status,
;; identity, and this board's own model), so nothing is computed twice.

;;; Code:

(require 'decknix-review-board-model)

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
                        background review-prs))
(defvar decknix--agent-broker-key)
(defvar decknix--hub-reviews)
(defvar decknix--agent-conv-key)

(defgroup decknix-review-board nil
  "Ordered review worklist." :group 'decknix)

(defface decknix-review-board-lane
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for lane headings." :group 'decknix-review-board)

(defface decknix-review-board-needs-you
  '((t :inherit error :weight bold))
  "Face for the needs-you lane heading." :group 'decknix-review-board)

(defface decknix-review-board-covered
  '((t :inherit warning))
  "Face for a blocked row somebody else has already answered or invalidated.

Deliberately NOT bold and NOT `error'.  The row is still yours, but an
approved or stale PR must not compete with a review nobody has looked at
-- if everything blocked is red, red stops meaning anything."
  :group 'decknix-review-board)

(defvar-local decknix-review-board--model nil
  "The lane model rendered in this buffer.")

(defvar-local decknix-review-board--marks nil
  "Hash of marked row keys (see `decknix-review-board-row-key').")

(defconst decknix-review-board-buffer-name "*Review Board*"
  "Name of the review board buffer.")

;; ── gathering ────────────────────────────────────────────────────────

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
                            (plan (bound-and-true-p decknix--agent-turn-plan)))
                       (list :name (buffer-name buf)
                             :buffer buf
                             :conv-key ck
                             :prs prs
                             :state (ignore-errors (decknix-agent-buffer-status buf))
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

(defun decknix-review-board--build ()
  "Return a freshly built model.

Sessions are NEVER filtered -- a running agent is a fact regardless of
whether its PR passes a display filter, and a Finished session's PR is
not in the feed at all.  Filters govern only what is offered as work to
pick up."
  (decknix-review-board--learn-owners (alist-get 'items decknix--hub-reviews))
  (decknix-review-board-build
   (decknix-review-board--request-items)
   (decknix-review-board--sessions)
   #'decknix-review-board--item-key
   #'decknix-review-board--status-for-key
   #'decknix-review-board--priority-for-key
   #'decknix-review-board--item-bot-p))

;; ── rendering ────────────────────────────────────────────────────────

(defun decknix-review-board--row-title (row)
  "Return a display title for ROW."
  (let ((prs (plist-get row :prs)))
    (if (eq (plist-get row :kind) 'group)
        (format "%s  (%d PRs)"
                (or (plist-get row :name) "group") (length prs))
      (let* ((key (car prs))
             (item (decknix-review-board--item-for-key key))
             (title (and item (alist-get 'title item))))
        (format "%-22s %s" (or key "?") (or title ""))))))

(defun decknix-review-board--insert-row (row)
  "Insert one propertised ROW."
  (let* ((status (decknix--hub-review-status-aggregate (plist-get row :statuses)))
         (badge (decknix--hub-review-status-badge status))
         (state (plist-get row :state))
         (attention (decknix-review-board--attention-p state))
         (marked (and decknix-review-board--marks
                      (decknix-review-board--marked-p row)))
         ;; A session indicator, because the two largest lanes are mostly
         ;; NOT sessions.  Without it a request with no agent and a session
         ;; that happens to be idle render identically, and the board reads
         ;; as a list of stale sessions to clean up rather than a backlog.
         (has-session (and (plist-get row :session) t))
         ;; In-progress rows lead their status column with what the
         ;; session is DOING (its verb) and how far along (N/M), so the
         ;; lane reads as "merge 3/5 working" rather than a bare state.
         (verb (plist-get row :verb))
         (progress (plist-get row :progress))
         (activity (when (eq (plist-get row :lane) 'doing)
                     (string-trim
                      (concat (when verb
                                (propertize (format "%-6s " verb)
                                            'face 'font-lock-keyword-face))
                              (when progress
                                (propertize (format "%-5s " progress)
                                            'face 'font-lock-constant-face))))))
         (trailing (cond (attention (or state ""))
                         ((and (eq (plist-get row :lane) 'doing)
                               (not (string-empty-p (or activity ""))))
                          (concat activity "  "
                                  (propertize (or state "")
                                              'face 'font-lock-comment-face)))
                         (has-session (or state ""))
                         (t (propertize "no session"
                                        'face 'font-lock-comment-face))))
         (line (format "%s %-2s %s %5d  %-52s %s"
                       (if marked "*" " ")
                       (if (string-empty-p badge) " " badge)
                       (if has-session
                           (propertize "\u25cf" 'face 'font-lock-string-face)
                         (propertize "\u00b7" 'face 'font-lock-comment-face))
                       (plist-get row :priority)
                       (truncate-string-to-width
                        (decknix-review-board--row-title row) 52)
                       trailing)))
    (insert (propertize line
                        'decknix-review-board-row row
                        ;; Urgency reflects the PR, not just the agent: see
                        ;; `decknix-review-board--row-face'.
                        'face (decknix-review-board--row-face attention status))
            "\n")))

(defun decknix-review-board--render ()
  "Render `decknix-review-board--model' into the current buffer."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (insert (propertize "Review Board" 'face 'decknix-review-board-lane)
            (format "  (%d rows)   " (decknix-review-board-count
                                      decknix-review-board--model))
            ;; Auto-review state belongs HERE, not only in the Requests
            ;; transient: this is the screen where you decide what to do
            ;; about reviews, so the policy that spawns them unasked is
            ;; part of the picture rather than a setting elsewhere.
            (propertize (format "%s   auto-review %s   auto-dismiss [%s]"
                                (if decknix-review-board-show-all
                                    "ALL requests" "filtered")
                                (if (fboundp 'decknix-auto-review-state-label)
                                    (format "[%s]" (decknix-auto-review-state-label
                                                    decknix-auto-review-mode))
                                  "[?]")
                                (if decknix-review-board-auto-dismiss "on" "off"))
                        'face 'font-lock-constant-face)
            "\n"
            ;; A visible cheat sheet, not a pointer to one.  `?' existed
            ;; and was announced in a header line, which is discoverability
            ;; only for someone already looking for it.  Eight verbs on a
            ;; read-only screen need to be readable without asking.
            (propertize
             (concat "  n/p move   RET open   i inspect   c copy   j jump   m mark   M lane\n"
                     "  d dispatch  k quit   D detach  s merge  A auto-review  x auto-dismiss  f filters  g refresh  ? help\n"
                     "  r review a PR url not listed here\n")
             'face 'font-lock-comment-face)
            "\n"
            (propertize "  m  ● pri  row                                                  state\n"
                        'face 'font-lock-comment-face)
            "\n")
    (dolist (lane decknix-review-board-lanes)
      (let* ((rows (alist-get (car lane) decknix-review-board--model))
             (face (if (eq (car lane) 'needs-you)
                       'decknix-review-board-needs-you
                     'decknix-review-board-lane)))
        ;; Empty lanes are rendered too: a lane's position on screen has
        ;; to be learnable, and one that vanishes when empty means the
        ;; layout shifts under you exactly when you are scanning it.
        (insert (propertize (format "%s (%d)" (cdr lane) (length rows)) 'face face)
                (propertize
                 (format "  — %s\n"
                         (or (alist-get (car lane) decknix-review-board-lane-help)
                             ""))
                 'face 'font-lock-comment-face))
        (if rows
            (dolist (row rows) (decknix-review-board--insert-row row))
          (insert (propertize "    (none)\n" 'face 'font-lock-comment-face)))
        (insert "\n")))
    (goto-char (point-min))
    (forward-line (1- line))))

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

(defun decknix-review-board-refresh ()
  "Rebuild and re-render the board."
  (interactive)
  (when-let* ((buf (get-buffer decknix-review-board-buffer-name)))
    (with-current-buffer buf
      (setq decknix-review-board--model
            (let ((m (decknix-review-board--build)))
              (if decknix-review-board-auto-dismiss
                  (decknix-review-board-drop-finished m)
                m)))
      (decknix-review-board--render))))

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
         (done 0))
    (unless rows (user-error "Nothing to dispatch"))
    (dolist (row rows)
      (let* ((items (or (plist-get row :items)
                        (when-let* ((i (plist-get row :item))) (list i))))
             (first (car items))
             (repo (car (last (split-string (or (alist-get 'repo first) "") "/"))))
             (author (or (alist-get 'author first) ""))
             (action (if (decknix-review-board--item-bot-p first) 'ship 'review)))
        (when (and items (fboundp 'decknix-auto-review--dispatch-unit))
          (ignore-errors
            (decknix-auto-review--dispatch-unit (list action repo author items))
            (setq done (1+ done))))))
    (decknix-review-board-unmark-all)
    (decknix-review-board-refresh)
    (decknix-review-board--report "Dispatched" done (length (cdr part)))))

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
    (when (yes-or-no-p (format "Quit %d session%s and terminate their brokers? "
                               (length bufs) (if (= 1 (length bufs)) "" "s")))
      (let ((others (delq nil
                          (mapcar (lambda (b)
                                    (unless (memq b bufs)
                                      (buffer-local-value 'decknix--agent-broker-key b)))
                                  (agent-shell-buffers)))))
        (dolist (buf bufs)
          (let ((key (buffer-local-value 'decknix--agent-broker-key buf)))
            ;; Same shared-broker guard the single-session quit uses, so
            ;; a broker another buffer is attached to survives here too.
            (when (and (fboundp 'decknix--agent-broker-stop-p)
                       (decknix--agent-broker-stop-p key others))
              (ignore-errors (decknix-agent-broker-stop key))))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf))))
      (decknix-review-board-unmark-all)
      (decknix-review-board-refresh)
      (decknix-review-board--report "Quit" (length bufs) (length (cdr part))))))

(defun decknix-review-board-detach-sessions ()
  "Detach the target sessions, leaving their agents running.
No confirmation: detaching is reversible, and the agent keeps working."
  (interactive)
  (let* ((part (decknix-review-board-partition-targets
                'detach (decknix-review-board--targets)))
         (bufs (decknix-review-board--session-buffers (car part))))
    (unless bufs (user-error "No live sessions to detach"))
    (dolist (buf bufs)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf)))
    (decknix-review-board-unmark-all)
    (decknix-review-board-refresh)
    (decknix-review-board--report "Detached" (length bufs) (length (cdr part)))))

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
  j               jump to the session buffer
  r               review a PR by url (paste one or several)
  g               refresh          q  bury          ?  this help
  A               cycle auto-review: off / bot / human / any
  x               toggle auto-dismiss: finished sessions drop off, or stay
  f               filters: the sidebar\'s, or the whole feed

FILTERS
  Requests use the SAME filters as the sidebar (bots, drafts, age, CI,
  mentions).  Without them the board showed 30 rows where the sidebar
  showed 2.  Sessions are never filtered -- a running agent is a fact,
  and a Finished session\'s PR has left the feed entirely.

MARK  (verbs act on the marked set, or the row at point when none marked)
  m / u           mark / unmark          U  unmark all
  M               mark every row in this lane

ACT
  d               dispatch review sessions (a Grouped row launches ONE
                  session for the whole service, which is the point)
  k               quit sessions and TERMINATE their brokers (confirms)
  D               detach: close the buffer, agent keeps working
  s               merge via /merge-train     C-u s  dry run

COLUMNS
  m               `*' when marked
  badge           see below
  session         `\u25cf' an agent is attached   `\u00b7' nobody is on it
  pri             priority score -- higher sorts first
  state           the agent's state, or `no session'

BADGES
  \u2298   gone       PR left your review queue (merged / closed).  The
                 session is finished work; `k' it.
  \u21bb   stale      author pushed since -- the analysis is void
  \u2611   answered   someone else responded; may be redundant

PRIORITY  (why the numbers look the way they do)
  Two axes added together, so the score is a rank, not a percentage, and
  NEGATIVE IS NORMAL for deprioritised work.

    what     incident HOT/PIR/DOS/ALR +100   EH -30   feature 0
    where    replies-to-me +60  needs-reply +50  re-requested +45
             stale +40  mine +30  team +15  otherwise +10
    minus    bot -35   draft -40   answered -25   gone -1000
    plus     age, +1/day, capped at +14

  So a bot PR nobody has asked you about scores 10 - 35 = -25.  That is
  it saying `real, but not next'.  Hover a row for its breakdown."
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
           (format "state: %s\n\n" (or (ignore-errors
                                          (decknix-agent-buffer-status buf))
                                        "?"))
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
           (body (if (plist-get row :session)
                     (decknix-review-board--inspect-session row)
                   (decknix-review-board--inspect-request row)))
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
    (define-key map (kbd "k") #'decknix-review-board-quit-sessions)
    (define-key map (kbd "D") #'decknix-review-board-detach-sessions)
    (define-key map (kbd "s") #'decknix-review-board-merge)
    (define-key map (kbd "c") #'decknix-review-board-copy-url)
    (define-key map (kbd "w") #'decknix-review-board-copy-url)
    (define-key map (kbd "A") #'decknix-review-board-cycle-auto-review)
    (define-key map (kbd "x") #'decknix-review-board-toggle-auto-dismiss)
    (define-key map (kbd "f") #'decknix-review-board-toggle-filters)
    (define-key map (kbd "i") #'decknix-review-board-inspect)
    (define-key map (kbd "?") #'decknix-review-board-help)
    (define-key map (kbd ".") #'decknix-review-board-help)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `decknix-review-board-mode'.

`k' and `D' mirror `C-c s q' and `C-c s D' so the quit/detach
distinction is learned once rather than twice.

`s' merges, behind a manifest and an explicit confirmation.  There is no
`approve': `submit-pr-review' is deprecated and approval now happens
inside the review commands, behind the mandatory review gate.  A board
verb that approved directly would route around it.")

(define-derived-mode decknix-review-board-mode special-mode "ReviewBoard"
  "Major mode for the review worklist."
  (setq truncate-lines t)
  (buffer-disable-undo))

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
