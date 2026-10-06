;;; decknix-session-board.el --- Session Board buffer -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-session-board-model "0.1"))
;; Keywords: agent, sessions, board

;;; Commentary:
;;
;; `*deckmacs: Session Board*' -- every live session in one lane, with bulk
;; actions.  Modelled on the Review Board, whose marking and quit idioms this
;; reuses rather than reinvents.
;;
;; The reason it exists: the fleet outgrew per-session browsing.  On a live
;; workspace of 36 sessions, 5 were reviewing PRs that named other people and
;; 16 were reviewing PRs that had left the hub queries entirely.  Identifying
;; those meant cross-referencing the session snapshot, the hub feed and GitHub
;; by hand, and ending them meant visiting each buffer.
;;
;; Quitting goes through `decknix-agent-session-quit''s broker rule, not
;; `kill-buffer'.  Under brokering the buffer's process is only the socat
;; client, so killing the buffer DETACHES and leaves the agent running -- one
;; was found alive two hours after its buffer closed.  A broker another live
;; session is still attached to is left alone.

;;; Code:

(require 'decknix-session-board-model)
(require 'decknix-agent-session-lifecycle)
(require 'decknix-sidebar-layout)
(require 'seq)
(require 'subr-x)

(defconst decknix-session-board-buffer-name "*deckmacs: Session Board*"
  "Name of the Session Board buffer.")

(defcustom decknix-session-board-width 76
  "Column at which the board's right-hand values are aligned.

Capped rather than right-aligned to the window.  The board opens in a
full-width window -- 244 columns on this frame -- and aligning the state
to that put it some 200 characters from the name it describes, which is
exactly the \"pushed out of view\" complaint.  A fixed column keeps the
two readable together however wide the window is, which is also what the
Review Board does with its `%-28s' columns."
  :type 'integer
  :group 'decknix)

(defvar decknix-session-board--marks nil
  "Hash of marked row keys, or nil before first use.")

(defvar decknix-session-board--groups nil
  "Last rendered (LANE . ROWS) grouping, for row lookup.")

(declare-function decknix--hub-review-session-snapshot "decknix-agent-shell-hub" ())
(declare-function decknix--hub-item-mine-to-take-p "decknix-hub-mention-bot" (item &optional viewer))
(declare-function decknix--hub-bot-author-p "decknix-hub-mention-bot" (author))
(declare-function decknix--layout-pr-key "decknix-sidebar-layout" (repo number))
(declare-function decknix-agent-broker-stop "decknix-agent-shell-main" (key))
(declare-function decknix--agent-broker-stop-p "decknix-agent-session-broker" (key others))
(defvar decknix--hub-reviews)

(defun decknix-session-board--marks-table ()
  "Return the marks hash, creating it on first use."
  (or decknix-session-board--marks
      (setq decknix-session-board--marks (make-hash-table :test 'equal))))

(defun decknix-session-board--item-table ()
  "Return a hash of PR key -> feed item."
  (let ((tbl (make-hash-table :test 'equal)))
    (dolist (item (and (boundp 'decknix--hub-reviews)
                       (alist-get 'items decknix--hub-reviews)))
      (when-let ((key (decknix--layout-pr-key (alist-get 'repo item)
                                              (alist-get 'number item))))
        (puthash key item tbl)))
    tbl))

(defun decknix-session-board--compute ()
  "Return the current (LANE . ROWS) grouping."
  (let ((tbl (decknix-session-board--item-table)))
    (decknix-session-board-group
     (ignore-errors (decknix--hub-review-session-snapshot))
     (lambda (key) (gethash key tbl))
     (lambda (item) (decknix--hub-item-mine-to-take-p item))
     ;; `author_kind' is computed by the hub (it distinguishes a coding
     ;; agent's PR, which is real work, from a dependabot bump); fall back to
     ;; the login pattern when an older feed lacks it.
     (lambda (item)
       (let ((kind (alist-get 'author_kind item)))
         (if kind
             (equal kind "bot")
           (decknix--hub-bot-author-p (alist-get 'author item))))))))

(defun decknix-session-board-obsolete-rows ()
  "Return the rows in cleanup lanes: sessions whose work is over.

`orphaned\=' (the PR left both hub queries -- merged, closed, or no longer
requested), `stale\=' (the PR conflicts or is a draft, so only its author
can move it) and `not-mine\=' (named reviewers exclude me).

Shared with the board rather than re-derived, so a one-shot purge and the
board can never disagree about what is obsolete."
  (let ((groups (decknix-session-board--compute)))
    (apply #'append
           (mapcar #'cdr
                   (seq-filter (lambda (g)
                                 (memq (car g)
                                       (decknix-session-board-killable-lanes)))
                               groups)))))

(defun decknix-session-board--obsolete-summary (rows)
  "Return a short per-lane tally of ROWS."
  (string-join
   (delq nil
         (mapcar (lambda (lane)
                   (let ((n (seq-count (lambda (r) (eq lane (plist-get r :lane)))
                                       rows)))
                     (when (> n 0)
                       (format "%d %s" n
                               (downcase (decknix-session-board-lane-title lane))))))
                 (decknix-session-board-killable-lanes)))
   ", "))

;;;###autoload
(defun decknix-session-purge-obsolete (&optional noconfirm)
  "End every session whose work is over, naming them first.

The sessions a review fleet leaves behind: measured on a live workspace,
11 of 24 were sitting on PRs that had merged, closed, or stopped being
requested.  They keep brokers alive and, until the Reviews counts were
fixed, made the sidebar claim attention for finished work.

Lists what it will end in a help buffer before asking, because the whole
point is acting on sessions the user is not looking at -- a bare count
gives nothing to check.  NOCONFIRM skips the prompt for callers that have
already confirmed."
  (interactive)
  (let ((rows (decknix-session-board-obsolete-rows)))
    (if (null rows)
        (message "No obsolete sessions")
      (let ((bufs (delq nil (mapcar (lambda (r) (get-buffer (plist-get r :buffer)))
                                    rows))))
        (unless noconfirm
          (with-help-window "*decknix: obsolete sessions*"
            (princ (format "%d obsolete session%s (%s)\n\n"
                           (length rows) (if (= 1 (length rows)) "" "s")
                           (decknix-session-board--obsolete-summary rows)))
            (dolist (lane (decknix-session-board-killable-lanes))
              (let ((in-lane (seq-filter (lambda (r) (eq lane (plist-get r :lane)))
                                         rows)))
                (when in-lane
                  (princ (format "%s -- %s\n"
                                 (decknix-session-board-lane-title lane)
                                 (decknix-session-board-lane-hint lane)))
                  (dolist (r in-lane)
                    (princ (format "    %-46s %s\n"
                                   (plist-get r :buffer)
                                   (string-join (or (plist-get r :prs) '("-")) ","))))
                  (princ "\n"))))))
        (if (and (not noconfirm)
                 (not (yes-or-no-p
                       (format "End %d obsolete session%s? " (length bufs)
                               (if (= 1 (length bufs)) "" "s")))))
            (message "No action")
          (let ((n (decknix-session-lifecycle-quit bufs t)))
            (when (get-buffer "*decknix: obsolete sessions*")
              (kill-buffer "*decknix: obsolete sessions*"))
            (when (get-buffer decknix-session-board-buffer)
              (with-current-buffer decknix-session-board-buffer
                (ignore-errors (decknix-session-board-refresh))))
            (when (fboundp 'agent-shell-workspace-sidebar-refresh)
              (ignore-errors (agent-shell-workspace-sidebar-refresh)))
            (message "Ended %s obsolete session%s"
                     (or n 0) (if (equal n 1) "" "s"))))))))

;; --- render -----------------------------------------------------------

(defun decknix-session-board--render ()
  "Redraw the board from current data, preserving point by line."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (width (min decknix-session-board-width
                    (max 40 (1- (window-width))))))
    (setq decknix-session-board--groups (decknix-session-board--compute))
    (erase-buffer)
    (let ((summary (decknix-session-board-summary decknix-session-board--groups)))
      (insert (propertize (format " Sessions: %s\n" (or summary "none live"))
                          'face 'font-lock-keyword-face))
      (insert (propertize " m/u mark  M lane  C cleanup  k kill  D detach  RET jump  g refresh  ? help\n"
                          'face 'font-lock-comment-face)))
    (dolist (group decknix-session-board--groups)
      (let ((lane (car group)) (rows (cdr group)))
        (insert "\n")
        (insert (propertize (decknix-session-board-lane-header lane rows width)
                           'face (if (memq lane (decknix-session-board-killable-lanes))
                                     'warning 'font-lock-function-name-face))
                "\n")
        (dolist (row rows)
          (let ((marked (gethash (decknix-session-board-row-key row)
                                 (decknix-session-board--marks-table))))
            (insert (propertize
                     (decknix-session-board-row-label row marked width)
                     'face (cond (marked 'highlight)
                                 ((decknix-session-board-killable-p row)
                                  'font-lock-comment-face)
                                 (t 'default))
                     'decknix-session-board-row row)
                    "\n")))))
    (goto-char (point-min))
    (forward-line (1- line))
    (set-buffer-modified-p nil)))

(defun decknix-session-board--row-at-point ()
  "Return the row on the current line, or nil."
  (get-text-property (line-beginning-position) 'decknix-session-board-row))

(defun decknix-session-board--all-rows ()
  "Return every rendered row."
  (apply #'append (mapcar #'cdr decknix-session-board--groups)))

(defun decknix-session-board--marked-rows ()
  "Return the marked rows, or nil."
  (let ((marks (decknix-session-board--marks-table)))
    (seq-filter (lambda (r) (gethash (decknix-session-board-row-key r) marks))
                (decknix-session-board--all-rows))))

(defun decknix-session-board--targets ()
  "Return the rows an action applies to: the marked set, else the row at point.

Marks win over point, so a bulk action never silently operates on one row
because the cursor happened to move after marking."
  (or (decknix-session-board--marked-rows)
      (when-let ((row (decknix-session-board--row-at-point))) (list row))))

;; --- commands ---------------------------------------------------------

(defun decknix-session-board-next ()
  "Move to the next session row."
  (interactive)
  (forward-line 1)
  (while (and (not (eobp)) (not (decknix-session-board--row-at-point)))
    (forward-line 1)))

(defun decknix-session-board-prev ()
  "Move to the previous session row."
  (interactive)
  (forward-line -1)
  (while (and (not (bobp)) (not (decknix-session-board--row-at-point)))
    (forward-line -1)))

(defun decknix-session-board-mark ()
  "Mark the row at point and move on."
  (interactive)
  (when-let ((row (decknix-session-board--row-at-point)))
    (puthash (decknix-session-board-row-key row) t
             (decknix-session-board--marks-table))
    (decknix-session-board--render)
    (decknix-session-board-next)))

(defun decknix-session-board-unmark ()
  "Unmark the row at point and move on."
  (interactive)
  (when-let ((row (decknix-session-board--row-at-point)))
    (remhash (decknix-session-board-row-key row)
             (decknix-session-board--marks-table))
    (decknix-session-board--render)
    (decknix-session-board-next)))

(defun decknix-session-board-unmark-all ()
  "Clear every mark."
  (interactive)
  (clrhash (decknix-session-board--marks-table))
  (decknix-session-board--render)
  (message "Marks cleared"))

(defun decknix-session-board-mark-lane ()
  "Mark every row in the lane at point."
  (interactive)
  (let* ((row (decknix-session-board--row-at-point))
         (lane (and row (plist-get row :lane))))
    (unless lane (user-error "Not on a session row"))
    (dolist (r (alist-get lane decknix-session-board--groups))
      (puthash (decknix-session-board-row-key r) t
               (decknix-session-board--marks-table)))
    (decknix-session-board--render)
    (message "Marked %s" (decknix-session-board-lane-title lane))))

(defun decknix-session-board-mark-cleanup ()
  "Mark every session in a cleanup lane (Not Mine, Orphaned)."
  (interactive)
  (let ((n 0))
    (dolist (row (decknix-session-board--all-rows))
      (when (decknix-session-board-killable-p row)
        (puthash (decknix-session-board-row-key row) t
                 (decknix-session-board--marks-table))
        (setq n (1+ n))))
    (decknix-session-board--render)
    (message "Marked %d cleanup session%s" n (if (= n 1) "" "s"))))

(defun decknix-session-board-jump ()
  "Switch to the session on this row."
  (interactive)
  (let* ((row (decknix-session-board--row-at-point))
         (buf (and row (get-buffer (plist-get row :buffer)))))
    (unless (buffer-live-p buf) (user-error "That session is no longer live"))
    (pop-to-buffer buf)))

(defun decknix-session-board-refresh ()
  "Recompute and redraw."
  (interactive)
  (decknix-session-board--render)
  (message "%s" (or (decknix-session-board-summary decknix-session-board--groups)
                    "No live sessions")))

(defun decknix-session-board-kill ()
  "Quit the marked sessions, or the one at point, terminating their brokers.

Confirms with a count and the lanes involved.  Under brokering a killed
buffer leaves the agent running, so this goes through the broker rule rather
than `kill-buffer'; a broker another live session is attached to survives."
  (interactive)
  (let* ((rows (decknix-session-board--targets))
         (bufs (delq nil (mapcar (lambda (r) (get-buffer (plist-get r :buffer)))
                                 rows)))
         (live (seq-filter #'buffer-live-p bufs))
         (lanes (delete-dups (mapcar (lambda (r)
                                       (decknix-session-board-lane-title
                                        (plist-get r :lane)))
                                     rows))))
    (unless live (user-error "No live sessions selected"))
    ;; Lanes are named in the prompt because the set may span them, and
    ;; "quit 9 sessions" reads very differently from "quit 9 sessions
    ;; (Orphaned)".  The quit itself is the shared implementation.
    (when (yes-or-no-p
           (format "Quit %d session%s (%s) and terminate their brokers? "
                   (length live) (if (= 1 (length live)) "" "s")
                   (string-join lanes ", ")))
      (let ((names (mapcar #'buffer-name live))
            (n (decknix-session-lifecycle-quit live t)))
        (dolist (nm names) (remhash nm (decknix-session-board--marks-table)))
        (decknix-session-board--render)
        (message "Quit %d session%s" (or n 0) (if (= 1 (or n 0)) "" "s"))))))

(defun decknix-session-board-detach ()
  "Detach the marked sessions, or the one at point, leaving agents running.

Free to offer now the implementation is shared: the Review Board already
had `D' for this, and a session board without it would send the user back
there for half a lifecycle."
  (interactive)
  (let* ((rows (decknix-session-board--targets))
         (bufs (delq nil (mapcar (lambda (r) (get-buffer (plist-get r :buffer)))
                                 rows)))
         (names (mapcar (lambda (b) (buffer-name b))
                        (seq-filter #'buffer-live-p bufs)))
         (n (decknix-session-lifecycle-detach bufs)))
    (when (zerop n) (user-error "No live sessions selected"))
    (dolist (nm names) (remhash nm (decknix-session-board--marks-table)))
    (decknix-session-board--render)
    (message "Detached %d session%s (agents still running)"
             n (if (= 1 n) "" "s"))))

(defun decknix-session-board-help ()
  "Describe the lanes and keys."
  (interactive)
  (message
   "%s"
   (string-join
    (append
     (mapcar (lambda (lane)
               (format "%-14s %s"
                       (decknix-session-board-lane-title lane)
                       (decknix-session-board-lane-hint lane)))
             decknix-session-board-lanes)
     '("" "m/u mark  M lane  C cleanup lane  U clear  k kill  RET jump  g refresh"))
    "\n")))

(defvar decknix-session-board-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'decknix-session-board-next)
    (define-key map (kbd "p") #'decknix-session-board-prev)
    (define-key map (kbd "TAB") #'decknix-session-board-next)
    (define-key map (kbd "<backtab>") #'decknix-session-board-prev)
    (define-key map (kbd "RET") #'decknix-session-board-jump)
    (define-key map (kbd "j") #'decknix-session-board-jump)
    (define-key map (kbd "m") #'decknix-session-board-mark)
    (define-key map (kbd "u") #'decknix-session-board-unmark)
    (define-key map (kbd "U") #'decknix-session-board-unmark-all)
    (define-key map (kbd "M") #'decknix-session-board-mark-lane)
    (define-key map (kbd "C") #'decknix-session-board-mark-cleanup)
    (define-key map (kbd "k") #'decknix-session-board-kill)
    (define-key map (kbd "D") #'decknix-session-board-detach)
    (define-key map (kbd "g") #'decknix-session-board-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'decknix-session-board-help)
    map)
  "Keymap for `decknix-session-board-mode'.")

(define-derived-mode decknix-session-board-mode special-mode "SessionBoard"
  "Major mode for the Session Board."
  (setq truncate-lines t)
  ;; A rendered read-only view, redrawn on every mark: undo records here can
  ;; never be undone and only accumulate.  Same reason the agent sidebar
  ;; disables it.
  (buffer-disable-undo))

;;;###autoload
(defun decknix-session-board ()
  "Open the Session Board."
  (interactive)
  (let ((buf (get-buffer-create decknix-session-board-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'decknix-session-board-mode)
        (decknix-session-board-mode))
      (decknix-session-board--render))
    (pop-to-buffer buf)))

(provide 'decknix-session-board)
;;; decknix-session-board.el ends here
