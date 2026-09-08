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
;; The verbs that WRITE to GitHub (approve, ship) are deliberately still
;; unbound.  They need the manifest-and-confirmation gate from the spec,
;; and a batch cannot be looser than the single-PR case which already
;; mandates one.  Everything bound here is recoverable; those are not.
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
(declare-function agent-shell-buffers "ext:agent-shell")
(declare-function decknix-auto-review--dispatch-unit "decknix-auto-review" (unit))
(declare-function decknix--agent-broker-stop-p "decknix-agent-session-broker" (key other-keys))
(declare-function decknix-agent-broker-stop "decknix-agent-session-broker" (key))
(declare-function decknix--agent-pr-detect-workspace
                  "decknix-agent-workspace-detect" (owner repo))
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
                     (list :name (buffer-name buf)
                           :buffer buf
                           :conv-key ck
                           :prs prs
                           :state (ignore-errors (decknix-agent-buffer-status buf))
                           :bot-p (decknix-review-board--prs-bot-p prs)))))))
           (agent-shell-buffers)))))

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

(defun decknix-review-board--build ()
  "Return a freshly built board model."
  (decknix-review-board-build
   (alist-get 'items decknix--hub-reviews)
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
         (line (format "%s %-2s %5d  %-58s %s"
                       (if marked "*" " ")
                       (if (string-empty-p badge) " " badge)
                       (plist-get row :priority)
                       (truncate-string-to-width
                        (decknix-review-board--row-title row) 58)
                       (or state ""))))
    (insert (propertize line
                        'decknix-review-board-row row
                        'face (when attention 'decknix-review-board-needs-you))
            "\n")))

(defun decknix-review-board--render ()
  "Render `decknix-review-board--model' into the current buffer."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (insert (propertize "Review Board" 'face 'decknix-review-board-lane)
            (format "  (%d rows)\n\n" (decknix-review-board-count
                                       decknix-review-board--model)))
    (dolist (lane decknix-review-board-lanes)
      (let* ((rows (alist-get (car lane) decknix-review-board--model))
             (face (if (eq (car lane) 'needs-you)
                       'decknix-review-board-needs-you
                     'decknix-review-board-lane)))
        ;; Empty lanes are rendered too: a lane's position on screen has
        ;; to be learnable, and one that vanishes when empty means the
        ;; layout shifts under you exactly when you are scanning it.
        (insert (propertize (format "%s (%d)" (cdr lane) (length rows)) 'face face)
                "\n")
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

(defun decknix-review-board-refresh ()
  "Rebuild and re-render the board."
  (interactive)
  (when-let* ((buf (get-buffer decknix-review-board-buffer-name)))
    (with-current-buffer buf
      (setq decknix-review-board--model (decknix-review-board--build))
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
            (key (car (plist-get row :prs)))
            (item (decknix-review-board--item-for-key key))
            (url (alist-get 'url item)))
      (browse-url url)
    (user-error "No PR URL for this row")))

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
  "Command the board hands a ship plan to.
It owns train ordering and its own confirmation gate; the board's job is
to name the PRs, not to merge them.")

(defun decknix-review-board--row-status (row)
  "Return ROW's aggregated staleness."
  (decknix--hub-review-status-aggregate (plist-get row :statuses)))

(defun decknix-review-board--manifest (by-repo blocked dry)
  "Return the confirmation manifest text for a ship plan."
  (with-temp-buffer
    (insert (format "Ship plan%s

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
  NOT shipping:
")
      (dolist (b blocked)
        (insert (format "    %-28s %s
"
                        (or (car (plist-get (car b) :prs)) "?")
                        (cdr b)))))
    (buffer-string)))

(defun decknix-review-board-ship (&optional dry)
  "Ship the target rows via `decknix-review-board-merge-command'.

With a prefix argument, DRY: passes `--dry', so the train is planned and
printed without merging anything.

The board does not merge.  It names the PRs and hands them to a command
that owns train ordering and its own confirmation gate -- so this gate is
the SECOND one, not the only one.  That is deliberate: the batch case
cannot be looser than the single-PR case, which already requires an
explicit confirmation before anything is posted.

Refuses stale and already-merged rows, and SAYS which.  A ship that
silently dropped them would be indistinguishable from one that merged
them."
  (interactive "P")
  (let* ((rows (decknix-review-board--targets))
         (plan (decknix-review-board-ship-plan
                rows #'decknix-review-board--row-status))
         (by-repo (car plan))
         (blocked (cdr plan)))
    (unless rows (user-error "Nothing selected"))
    (unless by-repo
      (user-error "Nothing shippable%s"
                  (if blocked
                      (format " (%d blocked: %s)" (length blocked)
                              (mapconcat #'cdr blocked "; "))
                    "")))
    (let ((manifest (decknix-review-board--manifest by-repo blocked dry)))
      ;; Shown in full, then confirmed.  A count is not a manifest: the
      ;; point is to read the PR numbers before they merge, not to be
      ;; told how many there were afterwards.
      (with-current-buffer (get-buffer-create "*Review Board Ship Plan*")
        (let ((inhibit-read-only t))
          (erase-buffer) (insert manifest) (goto-char (point-min)))
        (special-mode)
        (display-buffer (current-buffer)))
      (if (not (yes-or-no-p
                (format "Hand %d train%s to %s? "
                        (length by-repo) (if (= 1 (length by-repo)) "" "s")
                        decknix-review-board-merge-command)))
          (message "Ship cancelled")
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
    (define-key map (kbd "m") #'decknix-review-board-mark)
    (define-key map (kbd "u") #'decknix-review-board-unmark)
    (define-key map (kbd "U") #'decknix-review-board-unmark-all)
    (define-key map (kbd "M") #'decknix-review-board-mark-lane)
    (define-key map (kbd "d") #'decknix-review-board-dispatch)
    (define-key map (kbd "k") #'decknix-review-board-quit-sessions)
    (define-key map (kbd "D") #'decknix-review-board-detach-sessions)
    (define-key map (kbd "s") #'decknix-review-board-ship)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `decknix-review-board-mode'.

`k' and `D' mirror `C-c s q' and `C-c s D' so the quit/detach
distinction is learned once rather than twice.

`s' ships, behind a manifest and an explicit confirmation.  There is no
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
      (setq decknix-review-board--model (decknix-review-board--build))
      (decknix-review-board--render))
    (pop-to-buffer buf)))

(provide 'decknix-review-board)
;;; decknix-review-board.el ends here
