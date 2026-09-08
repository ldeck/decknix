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
;; Read-only, in this step.  Marks and batch verbs are specified in
;; `specs/review-board.md' and land after this has been lived with: the
;; verbs that write to GitHub need a confirmation gate, and that is worth
;; designing against a board that exists rather than one imagined.
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
         (line (format "  %-2s %5d  %-58s %s"
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
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `decknix-review-board-mode'.

Navigation and inspection only, for now.  `m'/`u' (marks) and the acting
verbs are reserved rather than bound: binding a key to nothing teaches
the wrong reflex, and the writing verbs need their confirmation gate
designed first.")

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
