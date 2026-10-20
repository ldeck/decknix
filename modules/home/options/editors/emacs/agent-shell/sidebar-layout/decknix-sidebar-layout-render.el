;;; decknix-sidebar-layout-render.el --- Session-first sidebar render -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-layout "0.1"))
;; Keywords: agent, hub, sidebar

;;; Commentary:
;;
;; Side-effecting half of `decknix-sidebar-layout': the Reviews and WIP
;; sections, their expansion state, and the row properties the actions read.
;;
;; Gated on `decknix-sidebar-layout-enable'.  With it nil the sidebar renders
;; exactly as before, because this replaces three established sections
;; (Requests, WIP, Live) at once and a single variable is a cheaper rollback
;; than a revert.

;;; Code:

(require 'decknix-sidebar-layout)
(require 'decknix-attention)
(require 'decknix-hub-icons)
(require 'cl-lib)
(require 'seq)

(declare-function decknix--hub-review-session-snapshot "decknix-agent-shell-hub" ())
(declare-function decknix--hub-requests-attention-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-reviewed-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-draft-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-conflict-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-not-mine-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function agent-shell-workspace-sidebar-refresh "agent-shell-workspace" ())

(defvar decknix-sidebar-layout-enable t
  "When non-nil, render the session-first Reviews/WIP/Unattached sections.
Set nil to fall back to the previous Requests/WIP/Live layout.")

(defvar decknix-sidebar-layout-reviews-attention-only t
  "When non-nil (default), Reviews lists only repos that want something.

That means a blocked session or a PR with no session.  A repo whose
sessions are all `working' or `ready' is in flight and wants nothing; at
the top of the sidebar it competes with the rows that do.  Toggle with
\[decknix-layout-toggle-attention-only]; the count held back is always
shown, so the section never shrinks silently.")

(defvar decknix--layout-expanded (make-hash-table :test 'equal)
  "Repo -> non-nil when its Reviews group is expanded.")

(defvar decknix--layout-state-file
  (expand-file-name "~/.config/decknix/hub/sidebar-layout.el")
  "Where expansion state is persisted across restarts.")

(declare-function decknix--sidebar-render-section-header
                  "decknix-sidebar-format" (title &optional section-id))

(defun decknix--layout-save-state ()
  "Persist which groups are expanded."
  (ignore-errors
    (let ((repos nil))
      (maphash (lambda (k v) (when v (push k repos))) decknix--layout-expanded)
      (with-temp-file decknix--layout-state-file
        (prin1 (sort repos #'string<) (current-buffer))))))

(defun decknix--layout-load-state ()
  "Restore expansion state, if any was saved."
  (ignore-errors
    (when (file-readable-p decknix--layout-state-file)
      (let ((repos (with-temp-buffer
                     (insert-file-contents decknix--layout-state-file)
                     (read (current-buffer)))))
        (clrhash decknix--layout-expanded)
        (dolist (r repos) (puthash r t decknix--layout-expanded))))))

(defun decknix--layout-expanded-p (repo)
  "Return non-nil when REPO's group is expanded."
  (gethash repo decknix--layout-expanded))

(defun decknix-layout-toggle-expand ()
  "Expand or collapse the group or held-items row at point."
  (interactive)
  (let ((repo (or (get-text-property (line-beginning-position)
                                     'decknix-layout-repo)
                  (get-text-property (line-beginning-position)
                                     'decknix-layout-expand-key))))
    (unless repo (user-error "Nothing to expand on this row"))
    (if (decknix--layout-expanded-p repo)
        (remhash repo decknix--layout-expanded)
      (puthash repo t decknix--layout-expanded))
    (decknix--layout-save-state)
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))))

(defun decknix-layout-toggle-attention-only ()
  "Toggle whether Reviews lists only repos that want something."
  (interactive)
  (setq decknix-sidebar-layout-reviews-attention-only
        (not decknix-sidebar-layout-reviews-attention-only))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Reviews: %s"
           (if decknix-sidebar-layout-reviews-attention-only
               "only what wants me" "everything")))

(defun decknix-layout-toggle-enable ()
  "Turn the session-first sidebar layout on or off.

Off restores the previous Requests/WIP/Live sections, which is why the
toggles for those are only offered when it IS off -- under the new layout
their renders are skipped, so they would be switches that change nothing."
  (interactive)
  (setq decknix-sidebar-layout-enable (not decknix-sidebar-layout-enable))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Sidebar layout: %s"
           (if decknix-sidebar-layout-enable "session-first" "previous")))

;; Defined above their cyclers: a `setq' on a variable whose `defvar' comes
;; later compiles as a free-variable assignment, which is a warning now and
;; a lexical-binding trap the moment this file is reorganised.
(defvar decknix-sidebar-layout-items-per-repo 5
  "Most PRs plus worktrees to list under one repo, or nil for all.

Listing every item flat gave the two followupboss sessions eleven rows
each.  A handful per repo restores the visibility the refactor lost without
returning to that; the remainder is reported, never silently dropped.")

(defvar decknix-sidebar-layout-dormant-limit 12
  "Most unattended items to render, or nil for all.
Items, not repo groups: the section lists the individual worktrees and PRs
that want something, having previously listed one row per repo with a
tally that said nothing about whether any of it wanted you.  Unattended
work is a backlog, not a queue, so it stays bounded -- an unbounded list
of every branch ever left behind pushes the sections that need action off
screen.  The number held back is always reported.")

(defconst decknix-sidebar-layout-items-cycle '(3 5 10 nil)
  "Cycle for `decknix-sidebar-layout-items-per-repo'; nil means all.")

(defun decknix-layout-cycle-items-per-repo ()
  "Cycle how many items are listed under one repo in WIP."
  (interactive)
  (let* ((cur decknix-sidebar-layout-items-per-repo)
         (pos (seq-position decknix-sidebar-layout-items-cycle cur))
         (next (nth (mod (1+ (or pos -1))
                         (length decknix-sidebar-layout-items-cycle))
                    decknix-sidebar-layout-items-cycle)))
    (setq decknix-sidebar-layout-items-per-repo next)
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))
    (message "WIP items per repo: %s" (or next "all"))))

(defconst decknix-sidebar-layout-dormant-cycle '(6 12 24 nil)
  "Cycle for `decknix-sidebar-layout-dormant-limit'; nil means all.")

(defun decknix-layout-cycle-dormant-limit ()
  "Cycle how many unattended items are listed."
  (interactive)
  (let* ((cur decknix-sidebar-layout-dormant-limit)
         (pos (seq-position decknix-sidebar-layout-dormant-cycle cur))
         (next (nth (mod (1+ (or pos -1))
                         (length decknix-sidebar-layout-dormant-cycle))
                    decknix-sidebar-layout-dormant-cycle)))
    (setq decknix-sidebar-layout-dormant-limit next)
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))
    (message "Unattended items shown: %s" (or next "all"))))

(defun decknix--layout-sidebar-width ()
  "Return the width of the sidebar window, falling back to the selected one.

Resolved from the buffer rather than from `window-width' with no argument:
the render runs with whatever window is selected, so the bare call answered
for the wrong one and padded every row to it."
  (let ((win (get-buffer-window (current-buffer))))
    (if (window-live-p win) (window-width win) (window-width))))

(defun decknix--layout-sessions ()
  "Return the live session snapshot, or nil."
  (and (fboundp 'decknix--hub-review-session-snapshot)
       (ignore-errors (decknix--hub-review-session-snapshot))))

(defvar decknix--hub-reviews)

(defun decknix--layout-feed-items ()
  "Return the hub's request items, or nil.

Reads the same `decknix--hub-reviews' the old Requests render used, and
applies the SAME visibility filters -- otherwise folding Requests into
Reviews would quietly re-show every draft, conflicted and already-reviewed
PR those filters exist to hide."
  (let ((items (and (boundp 'decknix--hub-reviews)
                    (alist-get 'items decknix--hub-reviews))))
    (if (fboundp 'decknix--hub-requests-attention-visible-p)
        (seq-filter
         (lambda (item)
           (and (decknix--hub-requests-attention-visible-p item)
                (decknix--hub-requests-reviewed-visible-p item)
                (decknix--hub-requests-draft-visible-p item)
                (decknix--hub-requests-conflict-visible-p item)
                (or (not (fboundp 'decknix--hub-requests-not-mine-visible-p))
                    (decknix--hub-requests-not-mine-visible-p item))))
         items)
      items)))

(defvar decknix--hub-wip)
(defvar decknix--agent-provider-id)

(declare-function decknix--sidebar-render-subagents
                  "decknix-agent-shell-workspace" (line-num session-id provider-id))
(declare-function decknix--agent-buffer-session-id
                  "decknix-agent-buffer-lookup" (&optional buf))

(defvar decknix-sidebar-layout-subagent-limit 10
  "Most sub-agents listed when a session\'s summary row is expanded.")

(defun decknix--layout-subagents-of (buffer-name)
  "Return ((SUB . STATE) ...) for BUFFER-NAME\'s sub-agents, newest first."
  (let ((buf (and buffer-name (get-buffer buffer-name))))
    (when (and buf (buffer-live-p buf)
               (fboundp 'decknix--agent-session-subagents)
               (fboundp 'decknix--agent-subagent-state))
      (let ((sid (ignore-errors (decknix--agent-buffer-session-id buf)))
            (provider (and (local-variable-p 'decknix--agent-provider-id buf)
                           (buffer-local-value 'decknix--agent-provider-id buf)))
            (now (float-time)))
        (when (and sid provider)
          (mapcar (lambda (s)
                    (cons s (decknix--layout-subagent-state
                             s (decknix--agent-subagent-state s now t))))
                  (ignore-errors (decknix--agent-session-subagents sid provider))))))))

(defun decknix--layout-subagent-row (sub state indent width)
  "Return the row for one SUB in STATE at INDENT, fitted to WIDTH."
  (let* ((age (and (alist-get 'modified sub)
                   (fboundp 'decknix--hub-format-age)
                   (decknix--hub-format-age (alist-get 'modified sub))))
         (left (format "%s↳ %s " indent (decknix--layout-subagent-glyph state)))
         (right (or age ""))
         (room (max 1 (- width (string-width left) (string-width right) 1)))
         (label (decknix--layout-subagent-label sub))
         (label (if (> (string-width label) room)
                    (concat (truncate-string-to-width label (max 1 (1- room))) "…")
                  label)))
    (concat left label
            (make-string (max 1 (- width (string-width left) (string-width label)
                                   (string-width right)))
                         ?\s)
            (propertize right 'face 'shadow))))

(defun decknix--layout-render-subagents (line-num buffer-name &optional width)
  "Render BUFFER-NAME\'s sub-agents under its row.  Returns LINE-NUM.

One child is shown as itself.  Several collapse to one summary row,
`↳ 6 agents ◐2 ■1 ●3\', expanding on RET to a row per child named by its
type and task.  Each child row opens its details on RET.

They had rendered one row per child, every one reading `↳ C\' and the
PARENT\'s name, so six children took six rows and said nothing about which
was doing what.  Finished children still honour
`decknix--sidebar-hide-completed-subagents\' in the expanded list; the
summary counts them all."
  (let* ((width (or width 48))
         (pairs (decknix--layout-subagents-of buffer-name))
         (shown (if (bound-and-true-p decknix--sidebar-hide-completed-subagents)
                    (seq-remove (lambda (p) (memq (cdr p) '(done stopped))) pairs)
                  pairs))
         (key (concat "subagents:" (or buffer-name ""))))
    (cl-flet ((child (pair indent)
                (insert (propertize (decknix--layout-subagent-row (car pair) (cdr pair) indent width)
                                    'decknix-layout-subagent (car pair)
                                    'help-echo "RET for this agent's details")
                        "\n")
                (setq line-num (1+ line-num))))
      (cond
       ((null pairs))
       ((= 1 (length pairs)) (child (car pairs) "    "))
       (t
        (insert (propertize (concat "    ↳ " (decknix--layout-subagent-summary (mapcar #'cdr pairs)))
                            'decknix-layout-expand-key key
                            'help-echo "RET to list these agents")
                "\n")
        (setq line-num (1+ line-num))
        (when (decknix--layout-expanded-p key)
          ;; Capped: one session had run 156.  Newest first, so the cap
          ;; keeps the ones still likely to matter.
          (dolist (pair (seq-take shown decknix-sidebar-layout-subagent-limit))
            (child pair "      "))
          (when (> (length shown) decknix-sidebar-layout-subagent-limit)
            (insert (propertize (format "        … %d more"
                                        (- (length shown) decknix-sidebar-layout-subagent-limit))
                                'face 'font-lock-comment-face)
                    "\n")
            (setq line-num (1+ line-num))))))))
  line-num)

(defvar-local decknix--layout-subagent-file nil
  "Transcript file of the sub-agent shown in this buffer.")

(defun decknix--layout-subagent-last-text (file)
  "Return the last assistant text in sub-agent transcript FILE, or nil.
Reads only the file\'s tail: a sub-agent transcript can run to megabytes."
  (when (and file (file-readable-p file))
    (let* ((size (file-attribute-size (file-attributes file)))
           (start (max 0 (- size 262144)))
           (last nil))
      (with-temp-buffer
        (insert-file-contents file nil start size)
        (dolist (line (split-string (buffer-string) "\n" t))
          (let ((o (ignore-errors
                     (json-parse-string line :object-type 'alist :array-type 'list
                                        :null-object nil :false-object nil))))
            (when (equal "assistant" (alist-get 'role (alist-get 'message o)))
              (let ((text (mapconcat (lambda (c) (or (and (equal "text" (alist-get 'type c))
                                                           (alist-get 'text c))
                                                      ""))
                                     (let ((c (alist-get 'content (alist-get 'message o))))
                                       (if (listp c) c nil))
                                     "")))
                (unless (string-empty-p (string-trim text)) (setq last text)))))))
      last)))

(defun decknix-layout-subagent-show (sub)
  "Show SUB\'s details: what it was asked to do, its state, and its last word."
  (interactive (list (get-text-property (line-beginning-position) 'decknix-layout-subagent)))
  (unless sub (user-error "No sub-agent on this row"))
  (let* ((file (alist-get 'filePath sub))
         (buf (get-buffer-create (format "*Agent: %s*" (decknix--layout-subagent-label sub)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (decknix--layout-subagent-label sub) 'face 'bold) "\n\n")
        (dolist (row `(("Type" . ,(alist-get 'agentType sub))
                       ("Task" . ,(alist-get 'description sub))
                       ("Stopped by you" . ,(and (eq (alist-get 'stoppedByUser sub) t) "yes"))
                       ("Last active" . ,(alist-get 'modified sub))
                       ("Transcript" . ,(and file (abbreviate-file-name file)))))
          (when (cdr row) (insert (format "%-15s %s\n" (car row) (cdr row)))))
        (insert "\n" (propertize "Last message" 'face 'bold) "\n\n"
                (or (decknix--layout-subagent-last-text file) "(none yet)") "\n"
                "\n" (propertize "o open transcript   q quit" 'face 'shadow) "\n"))
      (special-mode)
      (setq-local decknix--layout-subagent-file file)
      (local-set-key (kbd "o") (lambda () (interactive)
                                 (if decknix--layout-subagent-file
                                     (find-file-read-only decknix--layout-subagent-file)
                                   (user-error "No transcript recorded"))))
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun decknix--layout-wip-repos ()
  "Return the hub WIP feed's repos list, or nil."
  (and (boundp 'decknix--hub-wip)
       (alist-get 'repos decknix--hub-wip)))

(declare-function decknix--hub-wt-audit-refresh-if-stale "decknix-hub-wt-stale" ())

(defun decknix--layout-worktrees ()
  "Return cached worktree records, kicking an async audit when stale.

The kick used to live inside `decknix--hub-render-wip', which this layout
no longer calls -- so nothing refreshed the cache and every repo reported
`0 wt' forever.  Measured straight after a switch: `wt-cache-ready' nil,
0 rows, and the worktree a session was actually sitting in invisible.

`-if-stale' is async and self-guarding (one subprocess at a time), so
calling it from the render path cannot queue an audit per paint."
  (when (fboundp 'decknix--hub-wt-audit-refresh-if-stale)
    (ignore-errors (decknix--hub-wt-audit-refresh-if-stale)))
  (and (fboundp 'decknix-hub-wt-rows)
       (ignore-errors (decknix-hub-wt-rows))))

(defun decknix--layout-short-name (buffer-name)
  "Return BUFFER-NAME without the agent wrapper."
  (replace-regexp-in-string
   "\\`\\*\\(Claude\\|Pi\\|Auggie\\|Codex\\|Gemini\\)?:? ?\\|\\*\\'" ""
   (or buffer-name "")))

(defun decknix--layout-session-buffer (session)
  "Return SESSION's live agent buffer, or nil."
  (let ((buf (and session (get-buffer (or (nth 0 session) "")))))
    (and (buffer-live-p buf) buf)))

(defun decknix-layout-buffer-at (pos)
  "Return the live agent buffer the sidebar row at POS stands for, or nil.

Rows rendered by this layout name their session three ways, and upstream
only knew the first, so its goto refused every WIP row."
  (let ((b (or (get-text-property pos 'agent-shell-workspace-buffer)
               (get-text-property pos 'decknix-layout-buffer)
               (nth 0 (get-text-property pos 'decknix-layout-session))
               ;; The question line under a Needs-you row: RET and `i' act
               ;; on its session, though `n'/`p' pass over it.
               (nth 0 (get-text-property pos 'decknix-layout-ask)))))
    (when (stringp b) (setq b (get-buffer b)))
    (and (bufferp b) (buffer-live-p b) b)))

(defun decknix-layout-pr-live-sessions (pr sessions)
  "Return the live buffers of those SESSIONS covering review PR."
  (delq nil (mapcar #'decknix--layout-session-buffer
                    (decknix--layout-pr-sessions sessions (plist-get pr :key)))))

(defun decknix-layout-ret-action (pos)
  "Return what RET should do on a Reviews PR row at POS, or nil.

  (goto BUF)     exactly one live session covers the PR: go to it
  (choose BUFS)  several do: let the user pick
  nil            none, or not a Reviews PR row: the caller's default

The session is what wants attention on a covered PR; the PR itself is a
click away on M-RET.  RET used to open GitHub, which is the one thing a
reader looking at a blocked session did not want."
  (let ((pr (get-text-property pos 'decknix-layout-pr)))
    (when pr
      (let ((bufs (decknix-layout-pr-live-sessions pr (decknix--layout-sessions))))
        (cond ((null bufs) nil)
              ((null (cdr bufs)) (list 'goto (car bufs)))
              (t (list 'choose bufs)))))))

(defconst decknix-layout-actionable-props
  '(agent-shell-workspace-buffer decknix-layout-buffer decknix-layout-session
    decknix-layout-repo decknix-layout-pr decknix-hub-type
    decknix-layout-expand-key decknix-layout-subagent decknix-layout-worktree
    decknix-layout-claim decknix-layout-orphan-prune decknix-previous-session
    decknix-sidebar-saved-session decknix-repo-sync-problem
    decknix-repo-sync-collapsed)
  "Row properties that give RET something to do.
`n' and `p' stop only on rows carrying one, so headers, blank lines and
counted tails are skipped.")

(defun decknix-layout-actionable-p (pos)
  "Return non-nil when the row at POS has an action."
  (seq-some (lambda (prop) (get-text-property pos prop))
            decknix-layout-actionable-props))

(defvar agent-shell-workspace-sidebar-buffer-name "*Agent Sidebar*")

(defun decknix-layout--call-in-sidebar (fn)
  "Call FN with the sidebar current, and its window selected when shown.

These commands are also offered from the `?' menu, which runs its
suffixes from the main window; moving point there would move it in the
wrong buffer."
  (let* ((buf (get-buffer agent-shell-workspace-sidebar-buffer-name))
         (win (and buf (get-buffer-window buf t))))
    (cond ((or (null buf) (eq (current-buffer) buf)) (funcall fn))
          (win (with-selected-window win (funcall fn)))
          (t (with-current-buffer buf (funcall fn))))))

(defun decknix-layout-next-row (&optional n)
  "Move to the Nth next row that has an action; backwards when N is negative."
  (interactive "p")
  (decknix-layout--call-in-sidebar
   (lambda () (decknix-layout--next-row-1 (or n 1)))))

(defun decknix-layout--next-row-1 (n)
  "Move to the Nth next actionable row in the current buffer."
  (let* ((n (or n 1))
         (step (if (< n 0) -1 1))
         (count (abs n))
         (found (line-beginning-position)))
    (save-excursion
      (beginning-of-line)
      (while (and (> count 0) (zerop (forward-line step)) (not (eobp)))
        (when (decknix-layout-actionable-p (point))
          (setq found (point) count (1- count)))))
    (goto-char found)))

(defun decknix-layout-prev-row (&optional n)
  "Move to the Nth previous row that has an action."
  (interactive "p")
  (decknix-layout-next-row (- (or n 1))))

(defun decknix-layout-row-buffers (pos)
  "Return the live session buffers the row at POS stands for."
  (let ((buf (decknix-layout-buffer-at pos))
        (pr (get-text-property pos 'decknix-layout-pr)))
    (cond (buf (list buf))
          (pr (decknix-layout-pr-live-sessions pr (decknix--layout-sessions))))))

(defun decknix-layout--find-row (buffer)
  "Return the start of the best sidebar row standing for BUFFER, or nil.
A session's own row beats a PR row that merely covers it."
  (let (pr-row)
    (save-excursion
      (goto-char (point-min))
      (catch 'found
        (while (not (eobp))
          (let ((bol (point)))
            (cond ((eq buffer (decknix-layout-buffer-at bol)) (throw 'found bol))
                  ((and (null pr-row) (get-text-property bol 'decknix-layout-pr)
                        (memq buffer (decknix-layout-row-buffers bol)))
                   (setq pr-row bol))))
          (forward-line 1))
        pr-row))))

(defun decknix-layout--next-attention-target ()
  "Return the attention buffer after the one at point, in jump order."
  (let* ((ordered (decknix-attention-buffers))
         (here (seq-find (lambda (b) (memq b ordered))
                         (decknix-layout-row-buffers (line-beginning-position)))))
    (decknix-attention-next ordered here)))

(defun decknix-layout-goto-next-attention ()
  "Move point to the next session that needs you.
The order is the attention jump's: `netfail', `waiting', `asking', then
the longest wait.  `J' goes to the session itself."
  (interactive)
  (decknix-layout--call-in-sidebar #'decknix-layout--goto-next-attention-1))

(defun decknix-layout--goto-next-attention-1 ()
  "Move point to the next attention session's row in the current buffer."
  (let ((target (decknix-layout--next-attention-target)))
    (if (null target)
        (message "No session needs you")
      (let ((row (decknix-layout--find-row target)))
        (if row
            (progn (goto-char row)
                   (message "%s: %s" (decknix--layout-short-name (buffer-name target))
                            (or (decknix-attention-observed-state target) "needs you")))
          (message "%s needs you but has no row here; J goes to it"
                   (decknix--layout-short-name (buffer-name target))))))))

(defun decknix-layout-jump-next-attention ()
  "Go straight to the session `j' would have moved to."
  (interactive)
  (let ((target (decknix-layout--call-in-sidebar
                 #'decknix-layout--next-attention-target)))
    (if target
        (decknix-attention-display target)
      (message "No session needs you"))))

(defun decknix--layout-session-pr-gone-p (session raw-keys)
  "Return non-nil when every PR SESSION reviews has left the feed's RAW-KEYS.
Nil when RAW-KEYS is empty: no feed means nothing is known, not that every
PR merged."
  (let ((prs (decknix--layout-session-prs session)))
    (and prs raw-keys
         (seq-every-p (lambda (k) (not (member k raw-keys))) prs))))

(defun decknix--layout-raw-feed-keys ()
  "Return the canonical PR keys of the unfiltered review feed."
  (delq nil (mapcar (lambda (i)
                      (decknix--layout-pr-key (alist-get 'repo i) (alist-get 'number i)))
                    (and (boundp 'decknix--hub-reviews)
                         (alist-get 'items decknix--hub-reviews)))))

(declare-function decknix-agent-turn-closing-text "decknix-agent-turn-signals"
                  (&optional buffer))
(declare-function decknix-agent-turn-question-excerpt "decknix-agent-turn-signals"
                  (text))
(declare-function decknix-agent-turn-closing-ask "decknix-agent-turn-signals"
                  (&optional buffer))
(declare-function decknix-agent-turn-ask-reply-label "decknix-agent-turn-ask" (reply))
(declare-function decknix-agent-turn-quick-reply "decknix-agent-turn-signals" (buffer key))
(declare-function decknix-agent-turn-reply-key "decknix-agent-turn-signals" (event))
(defvar agent-shell-attention--pending)

(defun decknix--layout-permission-label (buf)
  "Return the permission prompt BUF is waiting on, from upstream's table."
  (and (boundp 'agent-shell-attention--pending)
       (hash-table-p agent-shell-attention--pending)
       (let ((e (gethash buf agent-shell-attention--pending)))
         (cond ((and (consp e) (stringp (car e))) (car e))
               ((and (plistp e) (stringp (plist-get e :label))) (plist-get e :label))))))

(defun decknix-layout-session-ask (buf state)
  "Return one line saying what session BUF, in STATE, is asking, or nil.

Read from what is already cached in memory -- the permission prompt
upstream recorded, or the closing text the turn-signals capture keeps --
so it costs no buffer scan and no I/O on the paint path."
  (when (buffer-live-p buf)
    (or (and (equal state "waiting") (decknix--layout-permission-label buf))
        (and (fboundp 'decknix-agent-turn-closing-text)
             (fboundp 'decknix-agent-turn-question-excerpt)
             (decknix-agent-turn-question-excerpt
              (decknix-agent-turn-closing-text buf))))))

(defun decknix-layout-session-reply-hint (buf)
  "Return the reply session BUF's question wants, e.g. \"1-3, rec 1\", or nil.
From the closing turn turn-signals has already parsed, so no I/O.  Nil
for a free-text question, which no quick key answers."
  (when-let* (((fboundp 'decknix-agent-turn-closing-ask))
              ((fboundp 'decknix-agent-turn-ask-reply-label))
              (reply (plist-get (decknix-agent-turn-closing-ask buf) :reply))
              ((not (eq (plist-get reply :kind) 'open))))
    (decknix-agent-turn-ask-reply-label reply)))

(defun decknix--layout-ask-row (session text width)
  "Return the dimmed one-line TEXT shown under SESSION, fitted to WIDTH."
  (let* ((lead "      ↳ ")
         (room (max 1 (- width (string-width lead))))
         (text (replace-regexp-in-string "[\n\t]+" " " text))
         (text (if (> (string-width text) room)
                   (concat (truncate-string-to-width text (max 1 (1- room))) "…")
                 text)))
    (propertize (concat lead text)
                'face 'font-lock-comment-face
                'decknix-layout-ask session
                'help-echo "i for the full question")))

(defun decknix--layout-needs-you-row (session width raw-keys)
  "Return the Needs-you row for SESSION, fitted to WIDTH.

A review session whose PR has left the feed is still listed -- it IS
blocked on a prompt -- but dimmed and marked, since the answer is most
likely to close it."
  (let* ((state (nth 3 session))
         (buf (decknix--layout-session-buffer session))
         (gone (decknix--layout-session-pr-gone-p session raw-keys))
         (age (decknix-attention-age-label (and buf (decknix-attention-since buf))))
         (right (string-trim (concat state " " age (if gone " · PR gone" ""))))
         (left (format " %s  " (decknix--layout-state-glyph state)))
         (room (max 1 (- width (string-width left) (string-width right) 1)))
         (name (decknix--layout-short-name (nth 0 session)))
         (name (if (> (string-width name) room)
                   (concat (truncate-string-to-width name (max 1 (1- room))) "…")
                 name))
         (pad (max 1 (- width (string-width left) (string-width name)
                        (string-width right)))))
    (propertize (concat left name (make-string pad ?\s) right)
                'face (if gone 'font-lock-comment-face
                        (decknix--layout-state-face state))
                'decknix-layout-session session
                'decknix-layout-buffer (nth 0 session)
                'decknix-layout-needs-you t
                'agent-shell-workspace-buffer buf
                'help-echo "RET go to it · j next · i what it asks · y/1-9 answer")))

(defun decknix--layout-render-needs-you (line-num width)
  "Render every session blocked on the user, first.  Returns LINE-NUM.

Listed whatever section the session would otherwise sit in, because each
of those sections can hide one.  Three review sessions asking for a
decision were invisible: their PRs had merged, so they did not count as
`asking' for their repo, the repo then had nothing else waiting, and the
whole group folded into \"N more in flight, nothing waiting\".  A session
blocked on you must never be hidden by a judgement about its PR."
  (let* ((sessions (decknix-attention-ordered-sessions (decknix--layout-sessions)))
         (live (seq-filter #'decknix--layout-session-buffer sessions)))
    (when live
      (let ((raw-keys (decknix--layout-raw-feed-keys)))
        (decknix--sidebar-render-section-header
         (format "Needs you (%d)" (length live)) 'needs-you)
        (setq line-num (1+ line-num))
        (dolist (session live)
          (insert (decknix--layout-needs-you-row session width raw-keys) "\n")
          (setq line-num (1+ line-num))
          ;; What it asks, so most can be triaged without opening them,
          ;; and the reply it wants, which `y' or a digit can send.
          (let* ((buf (decknix--layout-session-buffer session))
                 (ask (decknix-layout-session-ask buf (nth 3 session)))
                 (hint (decknix-layout-session-reply-hint buf)))
            (when (and ask (not (string-empty-p ask)))
              (insert (decknix--layout-ask-row
                       session (if hint (concat ask "  · reply " hint) ask) width)
                      "\n")
              (setq line-num (1+ line-num)))))
        (insert "\n")
        (setq line-num (1+ line-num)))))
  line-num)

(defconst decknix-layout-inspect-buffer "*Sidebar Inspect*"
  "Buffer showing what the session at point is asking.")

(defvar decknix-layout-inspect-lines 40
  "Trailing lines of the session shown under its last message.")

(defvar-local decknix-layout--inspect-target nil
  "The session buffer an inspect buffer describes.")

(defun decknix-layout-inspect-text (buf)
  "Return the inspect text for session BUF.  Reads memory only."
  (let* ((state (or (decknix-attention-observed-state buf) "?"))
         (since (decknix-attention-since buf))
         (ask (decknix-layout-session-ask buf state))
         (closing (and (fboundp 'decknix-agent-turn-closing-text)
                       (decknix-agent-turn-closing-text buf)))
         (tail (with-current-buffer buf
                 (save-excursion
                   (goto-char (point-max))
                   (forward-line (- decknix-layout-inspect-lines))
                   (buffer-substring-no-properties (point) (point-max))))))
    (concat
     (format "state: %s%s\n" state
             (if since (format "   for %s" (decknix-attention-age-label since)) ""))
     (if ask (format "asks:  %s\n" ask) "")
     (if (and closing (not (string-empty-p (string-trim closing))))
         (concat "\n" (propertize "Last message" 'face 'bold) "\n\n"
                 (string-trim closing) "\n")
       "")
     "\n" (propertize "Session tail" 'face 'bold) "\n\n" tail)))

(defun decknix-layout-inspect-go ()
  "Go to the session this inspect buffer describes."
  (interactive)
  (let ((target decknix-layout--inspect-target))
    (quit-window)
    (decknix-attention-display target)))

(defvar decknix-layout-inspect-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'decknix-layout-inspect-go)
    (define-key map (kbd "o") #'decknix-layout-inspect-go)
    map)
  "Keymap for `decknix-layout-inspect-mode'.")

(define-derived-mode decknix-layout-inspect-mode special-mode "Inspect"
  "What a session is asking.  RET goes to it, q closes this.")

(defun decknix-layout-reply ()
  "Answer the question of the session at point with the key just pressed.
`y' for yes, `1'-`9' for a numbered option; always confirms first.  See
`decknix-agent-turn-quick-reply', shared with the Review Board."
  (interactive)
  (let ((buf (car (decknix-layout--call-in-sidebar
                   (lambda () (decknix-layout-row-buffers (line-beginning-position))))))
        (key (and (fboundp 'decknix-agent-turn-reply-key)
                  (decknix-agent-turn-reply-key last-command-event))))
    (unless (buffer-live-p buf) (user-error "No session on this row"))
    (unless (and key (fboundp 'decknix-agent-turn-quick-reply))
      (user-error "Not a reply key"))
    (decknix-agent-turn-quick-reply buf key)))

(defun decknix-layout-inspect ()
  "Show what the session at point is asking, without leaving the sidebar.

Its state and how long it has waited, the question, its whole last
message, and the tail of the session.  Read-only, as on the Review
Board: seeing the question is most of the value, and answering it from a
summary is the risk this avoids.  RET in the window goes to the session."
  (interactive)
  (let ((buf (car (decknix-layout--call-in-sidebar
                   (lambda () (decknix-layout-row-buffers (line-beginning-position)))))))
    (unless (buffer-live-p buf) (user-error "No session on this row"))
    (let ((out (get-buffer-create decknix-layout-inspect-buffer))
          (text (decknix-layout-inspect-text buf)))
      (with-current-buffer out
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize (decknix--layout-short-name (buffer-name buf)) 'face 'bold)
                  "\n" (propertize "RET go to it · q close" 'face 'shadow) "\n\n"
                  text)
          (goto-char (point-min)))
        (decknix-layout-inspect-mode)
        (setq decknix-layout--inspect-target buf))
      (let ((main (seq-find
                   (lambda (w)
                     (not (or (window-parameter w 'window-side)
                              (equal (buffer-name (window-buffer w))
                                     agent-shell-workspace-sidebar-buffer-name))))
                   (window-list nil 'no-minibuf))))
        (if main
            (with-selected-window main
              (display-buffer out '((display-buffer-below-selected)
                                    (window-height . 0.45)
                                    (inhibit-same-window . t))))
          (display-buffer out))))))

(defun decknix--layout-render-reviews (line-num width)
  "Render the Reviews section.  Returns the updated LINE-NUM."
  (let* ((sessions (decknix--layout-sessions))
         (items (decknix--layout-feed-items))
         ;; The unfiltered feed, so a PR the filters hide is not mistaken
         ;; for one that has left the review queue entirely.
         (all-items (and (boundp 'decknix--hub-reviews)
                         (alist-get 'items decknix--hub-reviews)))
         (all-groups (decknix--layout-review-groups sessions items all-items))
         (split (decknix--layout-filter-groups
                 all-groups decknix-sidebar-layout-reviews-attention-only))
         (groups (car split))
         (held (cdr split))
         (dups (decknix--layout-duplicate-prs sessions))
         ;; PRs, not sessions.  The heading counted live review SESSIONS,
         ;; so it read "Reviews (0)" above five repos holding eight PRs
         ;; genuinely awaiting review -- the count said nothing was there
         ;; while the rows said otherwise.
         (total (apply #'+ (mapcar (lambda (g) (length (plist-get g :prs)))
                                   all-groups)))
         (asking (apply #'+ (mapcar (lambda (g) (or (plist-get g :asking) 0))
                                    all-groups))))
    (when (or groups (> held 0))
      (decknix--sidebar-render-section-header
       (if (> asking 0)
           (format "Reviews (%d) — %d need you" total asking)
         (format "Reviews (%d)" total))
       'reviews)
      (setq line-num (1+ line-num))
      (dolist (group groups)
        (let ((repo (plist-get group :repo)))
          (insert (propertize (decknix--layout-group-label group width)
                              'face (decknix--layout-group-face group)
                              'decknix-layout-repo repo
                              'decknix-layout-group group)
                  "\n")
          (setq line-num (1+ line-num))
          (when (decknix--layout-expanded-p repo)
            (dolist (pr (plist-get group :prs))
              (insert (propertize (decknix--layout-pr-label pr width)
                                  'face (cond ((decknix--layout-attention-p
                                                (plist-get pr :state))
                                               'decknix-attention-face)
                                              ((eq 'updated (decknix--layout-review-phase pr))
                                               (alist-get 'updated decknix-sidebar-layout-group-faces))
                                              (t 'font-lock-comment-face))
                                  'decknix-layout-pr pr
                                  'help-echo "RET its session (or a choice) · M-RET open the PR"
                                  'decknix-hub-type 'request
                                  'decknix-hub-repo (alist-get 'repo (plist-get pr :item))
                                  'decknix-hub-number (plist-get pr :number)
                                  'decknix-hub-url (alist-get 'url (plist-get pr :item)))
                      "\n")
              (setq line-num (1+ line-num))
              ;; A review session is normally implied by its PR row, so
              ;; listing it as well would double every review.  MORE than one
              ;; session on a PR is the exception worth naming: 16 PRs have
              ;; two agents on them, which is invisible from a single row and
              ;; is the thing to act on.
              (let ((covering (decknix--layout-pr-sessions
                               sessions (plist-get pr :key))))
                ;; One covering session: the PR row IS that session, so its
                ;; sub-agents belong directly under it.
                (when (= (length covering) 1)
                  (setq line-num (decknix--layout-render-subagents
                                  line-num (nth 0 (car covering)) width)))
                (when (> (length covering) 1)
                  (dolist (cs covering)
                    (insert (propertize
                             (format "      %s %s"
                                     (decknix--layout-state-glyph (nth 3 cs))
                                     (decknix--layout-short-name (nth 0 cs)))
                             'face 'error
                             'decknix-layout-session cs
                             'decknix-layout-buffer (nth 0 cs)
                             'agent-shell-workspace-buffer
                             (decknix--layout-session-buffer cs))
                            "\n")
                    (setq line-num (1+ line-num))
                    (setq line-num (decknix--layout-render-subagents
                                    line-num (nth 0 cs) width)))))))))
      (when (> held 0)
        (insert (propertize
                 (format " ·  %d more in flight, nothing waiting" held)
                 'face 'font-lock-comment-face
                 'decknix-layout-held held)
                "\n")
        (setq line-num (1+ line-num)))
      (when dups
        (insert (propertize (format " ⚠  %d PRs have 2+ sessions" (length dups))
                            'face 'error
                            'decknix-layout-duplicates dups)
                "\n")
        (setq line-num (1+ line-num)))))
  line-num)

(defun decknix--layout-render-wip (line-num width)
  "Render WIP: my live sessions with their own work nested beneath each.

Nesting rather than a separate PR-centric section: the old layout listed my
PRs and worktrees under a second heading also called \"WIP\", with nothing
stating which session was on which.  An item may appear under two sessions
when both share a workspace, which is preferred over picking a winner and
hiding the sharing."
  (let* ((sessions (decknix--layout-sessions))
         (wip (decknix--layout-wip-sessions sessions))
         (tree (decknix--layout-wip-tree wip (decknix--layout-wip-repos)
                                         (decknix--layout-worktrees))))
    (when (or wip (decknix--layout-unattended-p (plist-get tree :dormant)))
      (insert "\n")
      (setq line-num (1+ line-num))
      (decknix--sidebar-render-section-header
       (let ((guessed (decknix--layout-inferred-count
                       (plist-get tree :sessions))))
         ;; Naming the guesses in the heading, because a wrong guess that
         ;; renders like a fact is the defect every sidebar bug this week
         ;; turned out to be.
         (let ((need (seq-count (lambda (sess) (decknix--layout-attention-p (nth 3 sess)))
                                wip)))
           (concat (format "WIP (%d" (length wip))
                   (if (> need 0) (format " — %d need you" need) "")
                   (cond ((and (> guessed 0) (> need 0)) (format ", %d inferred" guessed))
                         ((> guessed 0) (format " — %d inferred" guessed))
                         (t ""))
                   ")")))
       'wip-sessions)
      (setq line-num (1+ line-num))
      (dolist (row (decknix--layout-dedup-claims (plist-get tree :sessions)))
        (let* ((session (plist-get row :session))
               (state (nth 3 session))
               (name (decknix--layout-short-name (nth 0 session)))
               (left (format " %s  %s" (decknix--layout-state-glyph state) name))
               (right (or state ""))
               (pad (max 1 (- width (string-width left) (string-width right)))))
          ;; Coloured by state, not just bolded on attention.  At 48 columns
          ;; the trailing status word is off-screen, so colour and the
          ;; left-hand glyph are the only state the user can actually read.
          (insert (propertize (concat left (make-string pad ?\s) right)
                              'face (decknix--layout-state-face state)
                              'decknix-layout-session session
                              'decknix-layout-buffer (nth 0 session)
                              ;; The property upstream's goto, kill and
                              ;; rename read.  Without it RET on a WIP row
                              ;; said "No live agent buffer at point".
                              'agent-shell-workspace-buffer
                              (decknix--layout-session-buffer session))
                  "\n")
          (setq line-num (1+ line-num))
          (setq line-num (decknix--layout-render-subagents
                          line-num (nth 0 session) width))
          (dolist (claim (plist-get row :repos))
            (setq line-num (decknix--layout-render-claim
                            line-num width claim session
                            (plist-get row :provenance))))))
      (setq line-num (decknix--layout-render-dormant
                      line-num width (plist-get tree :dormant)))))
  line-num)

(defun decknix--layout-item-title (pr)
  "Return PR\='s title, falling back to its branch then its number.

The title rather than the branch: a branch name is mostly the ticket key
repeated from the title, and the old sidebar showed titles."
  (let ((raw (plist-get pr :pr)))
    (or (alist-get 'title raw)
        (plist-get pr :branch)
        (format "#%s" (plist-get pr :number)))))

(defun decknix--layout-pr-row (pr width)
  "Return the rendered line for PR, fitted to WIDTH.

Built from the hub\='s own icon vocabulary -- author provenance, primary
state, activity -- each carrying its OWN colour, rather than one severity
face painted over the whole row.  The row had become a uniformly coloured
string of flat ASCII, which is legible only if you already know what you
are looking at; the glyph colours are what make draft-versus-conflicting
or human-versus-bot readable without decoding.

The title is truncated rather than allowed to push the glyphs out of the
window, since the glyphs are the part worth keeping when space runs out."
  (let* ((raw (plist-get pr :pr))
         (icons (concat (decknix--hub-author-icon raw)
                        (decknix--hub-primary-status-icon raw 'wip)
                        (decknix--hub-approved-icon raw)
                        (decknix--hub-changes-icon raw)
                        (decknix--hub-conflict-icon raw)
                        (decknix--hub-stale-approval-icon raw)
                        (decknix--hub-unresolved-icon raw)
                        (decknix--hub-reply-icon raw)
                        (decknix--hub-discussion-icon raw)
                        (decknix--hub-activity-icons raw)))
         (age (decknix--hub-format-age (alist-get 'updated raw)))
         (num (format "#%s" (plist-get pr :number)))
         (lead (format "    %s %-3s %s " icons age num))
         (room (max 1 (- width (string-width lead))))
         (title (decknix--layout-item-title pr))
         (title (if (> (string-width title) room)
                    (concat (truncate-string-to-width title (max 1 (1- room))) "…")
                  title)))
    (concat lead (propertize title 'face 'shadow))))

(defun decknix--layout-render-claim (line-num width claim session
                                             &optional provenance)
  "Render one repo CLAIM under SESSION, with its items.  Returns LINE-NUM.

The repo line takes its colour from the WORST item beneath it, so a
collapsed repo still shows that something in there is blocked."
  (if (plist-get claim :duplicate)
      (decknix--layout-render-duplicate-claim line-num width claim session)
    (decknix--layout-render-claim-1 line-num width claim session provenance)))

(defun decknix--layout-render-duplicate-claim (line-num width claim session)
  "Render CLAIM as one line, its items having been shown under an earlier
session.  Keeps the sharing visible without repeating the whole subtree."
  (let* ((left (format "    ⇡ %s" (plist-get claim :repo)))
         (right "shared ↑")
         (pad (max 1 (- width (string-width left) (string-width right)))))
    (insert (propertize (concat left (make-string pad ?\s) right)
                        'face 'font-lock-comment-face
                        'decknix-layout-claim claim
                        'decknix-layout-session session)
            "\n")
    (1+ line-num)))

(defun decknix--layout-render-claim-1 (line-num width claim session
                                               &optional provenance)
  "Render CLAIM and its nested items.  Returns LINE-NUM.

PROVENANCE marks whether this association is evidence or a guess."
  (let* ((prs (plist-get claim :pr-items))
         (wts (plist-get claim :wt-items))
         (left (format "   %s⇡ %s"
                       (decknix--layout-provenance-mark provenance)
                       (plist-get claim :repo)))
         (right (decknix--layout-count-label (plist-get claim :prs)
                                             (plist-get claim :worktrees)))
         (pad (max 1 (- width (string-width left) (string-width right))))
         (expand-key (concat "items:" (or (plist-get claim :repo) "")))
         (split (decknix--layout-claim-items
                 claim decknix-sidebar-layout-items-per-repo
                 (decknix--layout-expanded-p expand-key)))
         (shown-prs (nth 0 split))
         (shown-wts (nth 1 split))
         (held (nth 2 split)))
    (ignore prs wts)
    (insert (propertize (concat left (make-string pad ?\s) right)
                        'face (if (eq provenance 'observed)
                                  (decknix--layout-severity-face
                                   (plist-get claim :severity))
                                ;; A guess must not compete with what the
                                ;; sidebar actually knows.
                                (decknix--layout-provenance-face provenance))
                        'decknix-layout-claim claim
                        'decknix-layout-provenance provenance
                        'decknix-layout-session session)
            "\n")
    (setq line-num (1+ line-num))
    (dolist (pr shown-prs)
      (insert (propertize
               (decknix--layout-pr-row pr width)
               'decknix-hub-type 'wip
               'decknix-hub-repo (plist-get pr :repo)
               'decknix-hub-number (plist-get pr :number)
               'decknix-hub-url (alist-get 'url (plist-get pr :pr)))
              "\n")
      (setq line-num (1+ line-num)))
    (dolist (wt shown-wts)
      (insert (propertize
               (format "    %s %-3s %s" (decknix--layout-wt-glyph wt)
                       (decknix--layout-wt-markers wt)
                       (propertize (decknix--layout-wt-label wt #'decknix--layout-review-title)
                                   'face 'shadow))
               'decknix-layout-worktree wt)
              "\n")
      (setq line-num (1+ line-num)))
    (when (> held 0)
      ;; Carries the expand key: without a property this row was inert, so
      ;; RET on it did nothing and the held worktrees were unreachable.
      (insert (propertize (format "      … %d more worktree%s"
                                  held (if (= 1 held) "" "s"))
                          'face 'font-lock-comment-face
                          'decknix-layout-expand-key expand-key
                          'help-echo "RET to show these worktrees")
              "\n")
      (setq line-num (1+ line-num))))
  line-num)


(defun decknix--layout-review-title (repo number)
  "Return the title of review request REPO#NUMBER from the reviews feed.
REPO is compared case-insensitively: the worktree audit reports it
lower-cased, the feed as GitHub spells it."
  (when (boundp 'decknix--hub-reviews)
    (let ((item (seq-find
                 (lambda (i)
                   (and (equal number (alist-get 'number i))
                        (string-equal-ignore-case (or repo "")
                                                  (or (alist-get 'repo i) ""))))
                 (alist-get 'items decknix--hub-reviews))))
      (alist-get 'title item))))

(defun decknix--layout-unattended-p (dormant)
  "Return non-nil when DORMANT holds anything the WIP group would show."
  (let ((split (decknix--layout-dormant-split dormant)))
    (or (plist-get split :prs) (plist-get split :worktrees)
        (> (plist-get split :orphans) 0) (> (plist-get split :quiet) 0))))

(defun decknix--layout-render-dormant (line-num width dormant)
  "Render unattended work as the last group of WIP.  Returns LINE-NUM.

Work no live session is on: dirty worktrees and open non-draft PRs.  It
used to be a section of its own whose rows named a PR or branch with no
repo beside them, which was reported as unrecognisable.  As a WIP group it
takes WIP\='s structure: a `no session\' row standing where a session would,
then one `⇡ repo\' row per repo coloured by its worst item, then the items.

Orphans and drafts are counted, not listed.  Live numbers when this was
first built: 27 unattended worktrees and 7 PRs, of which 6 dirty and 4
open.  Listing every item produced 24 rows, 14 of them only saying `this
branch is gone from origin\', whose remedy is a bulk prune."
  (let* ((split (decknix--layout-dormant-split dormant))
         (all-prs (plist-get split :prs))
         (all-wts (plist-get split :worktrees))
         (orphans (plist-get split :orphans))
         (quiet (plist-get split :quiet))
         (n (+ (length all-wts) (length all-prs)))
         (limit decknix-sidebar-layout-dormant-limit)
         ;; PRs claim the budget first: someone else is waiting on a PR,
         ;; where a dirty worktree is only waiting on me.
         (prs (if limit (seq-take all-prs limit) all-prs))
         (wts (if limit (seq-take all-wts (max 0 (- limit (length prs)))) all-wts))
         (held (- n (length prs) (length wts)))
         (claims (decknix--layout-group-claims wts prs)))
    (when (or (> n 0) (> orphans 0) (> quiet 0))
      (let* ((left (format " %s  no session" (decknix-lifecycle-shape 'worktree-new)))
             (right (if (> n 0) (format "%d unattended" n) "unattended"))
             (pad (max 1 (- width (string-width left) (string-width right)))))
        (insert (propertize (concat left (make-string pad ?\s) right)
                            'face 'font-lock-comment-face
                            'decknix-layout-unattended t)
                "\n")
        (setq line-num (1+ line-num)))
      (dolist (claim claims)
        (setq line-num (decknix--layout-render-claim-1
                        line-num width claim nil 'observed)))
      ;; Every tail is NAMED.  A section that drops rows silently reads as
      ;; "that is all of it", which is the way this one already misled.
      (when (> held 0)
        (insert (propertize (format "    … %d more over the limit" held)
                            'face 'font-lock-comment-face
                            'help-echo "raise `unattended' in the sidebar transient")
                "\n")
        (setq line-num (1+ line-num)))
      (when (> orphans 0)
        (insert (propertize (format "    ⑂ %d orphaned, RET to prune" orphans)
                            'face 'font-lock-comment-face
                            'decknix-layout-orphan-prune t
                            'help-echo "branch gone from origin -- RET opens the worktree picker")
                "\n")
        (setq line-num (1+ line-num)))
      (when (> quiet 0)
        (insert (propertize (format "    · %d quiet, nothing wanted" quiet)
                            'face 'font-lock-comment-face)
                "\n")
        (setq line-num (1+ line-num)))))
  line-num)

(defun decknix--layout-render-tokens (line-num width)
  "Render the Tokens section: remaining quota per model account.
Returns LINE-NUM.  Reads what the hub daemon last wrote, so painting it
costs no network; an absent file renders nothing rather than a guess."
  (let ((accounts (and (boundp 'decknix--hub-token-quotas)
                       (alist-get 'accounts decknix--hub-token-quotas))))
    (when accounts
      (insert "\n")
      (setq line-num (1+ line-num))
      (let* ((now (current-time))
             (heading (decknix--layout-quota-heading
                       (alist-get 'updated decknix--hub-token-quotas) now)))
        (decknix--sidebar-render-section-header
         (if (cdr heading) (propertize (car heading) 'face 'warning) (car heading))
         'tokens)
        (setq line-num (1+ line-num)))
      (let ((now (current-time)))
        (dolist (account accounts)
          (dolist (line (decknix--layout-quota-lines account now width))
            (insert (propertize line 'decknix-layout-quota account) "\n")
            (setq line-num (1+ line-num)))))))
  line-num)

(provide 'decknix-sidebar-layout-render)
;;; decknix-sidebar-layout-render.el ends here
