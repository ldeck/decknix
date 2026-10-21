;;; decknix-board-focus.el --- Focus the sidebar on one board -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, decknix, board, sidebar

;;; Commentary:
;;
;; A focus narrows the sidebar to one board, a "pilot": its sessions,
;; the PRs and worktrees of its repositories, and its repo-sync problems.
;; Membership is `decknix-board-session-in-board-p', the board's own rule,
;; so a board and its focus can never disagree.
;;
;; The sidebar asks on every paint, so nothing here reads files or runs
;; processes once the board's definition is cached: each session's answer
;; is memoised for `decknix-board-focus-memo-ttl' seconds, keyed on the
;; parts of the session that membership reads (not its state, which
;; changes constantly and does not matter).
;;
;; Sessions that need you outside the focus are counted, never hidden
;; silently; the attention jump stays global unless
;; `decknix-attention-respect-focus' is set.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'decknix-board)
(require 'decknix-attention)

(declare-function agent-shell-workspace-sidebar-refresh "agent-shell-workspace" ())
(declare-function decknix--sidebar-state-write "decknix-agent-shell-workspace" ())

(defvar decknix-board-focus-name nil
  "Name of the board the sidebar is focused on, or nil for no focus.
Persisted with the sidebar's toggles.")

(defconst decknix-board-focus-memo-ttl 10
  "Seconds a session's membership of the focused board is reused.
Membership depends on tags, PRs and the worktrees a session touched,
which change over minutes; the sidebar repaints every two seconds.")

(defvar decknix-board-focus--cache nil
  "(NAME BOARD ITEMS CTX AT): the focused board, its context, when built.")

(defvar decknix-board-focus--memo (make-hash-table :test 'equal)
  "Session signature -> `yes' or `no', for the cached board.")

(defun decknix-board-focus-invalidate (&rest _)
  "Forget the cached definition and memberships, after a board changed."
  (setq decknix-board-focus--cache nil)
  (clrhash decknix-board-focus--memo))

(add-hook 'decknix-board-reread-functions #'decknix-board-focus-invalidate)

(defun decknix-board-focus--state ()
  "Return the focus cache, rebuilt when the focus, items or age changed."
  (let ((name decknix-board-focus-name)
        (items (and decknix-board-focus-name
                    (gethash decknix-board-focus-name decknix-board--known-items))))
    (unless (and decknix-board-focus--cache
                 (equal (nth 0 decknix-board-focus--cache) name)
                 (eq (nth 2 decknix-board-focus--cache) items)
                 (< (- (float-time) (nth 4 decknix-board-focus--cache))
                    decknix-board-focus-memo-ttl))
      (clrhash decknix-board-focus--memo)
      (let* ((old (and (equal (nth 0 decknix-board-focus--cache) name)
                       (nth 1 decknix-board-focus--cache)))
             ;; The definition is only read when the focus changes or a
             ;; board is re-read, never on the timed rebuild.
             (board (and name (or old (ignore-errors (decknix-board-read name))))))
        (setq decknix-board-focus--cache
              (list name board items
                    (and board (decknix-board-context board items))
                    (float-time)))))
    decknix-board-focus--cache))

(defun decknix-board-focus-board ()
  "Return the focused board's definition, or nil when there is no focus.
A focus naming a board whose file has gone counts as no focus."
  (nth 1 (decknix-board-focus--state)))

(defun decknix-board-focus-active-p ()
  "Non-nil when the sidebar is focused on a board."
  (and (decknix-board-focus-board) t))

(defun decknix-board-focus-title ()
  "Return the focused board's title, or nil."
  (let ((b (decknix-board-focus-board)))
    (and b (or (plist-get b :title) (plist-get b :name)))))

(defun decknix-board-focus-session-p (session)
  "Non-nil when SESSION is in the focus; always, without one."
  (let* ((state (decknix-board-focus--state))
         (board (nth 1 state)))
    (or (null board)
        (let ((key (list (nth 0 session) (nth 1 session) (nth 2 session) (nth 4 session))))
          (pcase (gethash key decknix-board-focus--memo)
            ('yes t)
            ('no nil)
            (_ (let ((in (decknix-board-session-in-board-p board session (nth 3 state))))
                 (puthash key (if in 'yes 'no) decknix-board-focus--memo)
                 in)))))))

(defun decknix-board-focus-sessions (sessions)
  "Return SESSIONS in the focus; all of them without one."
  (if (decknix-board-focus-board)
      (seq-filter #'decknix-board-focus-session-p sessions)
    sessions))

(defun decknix-board-focus-repo-p (repo)
  "Non-nil when REPO is in the focused board's scope; always, without one."
  (let ((board (decknix-board-focus-board)))
    (or (null board) (and repo (decknix-board-repo-in-scope-p board repo) t))))

(defun decknix-board-focus-path-p (path)
  "Non-nil when PATH is in a repository the focus covers; always, without one."
  (or (null (decknix-board-focus-board))
      (and path (seq-some #'decknix-board-focus-repo-p (decknix-board-path-repos path)) t)))

(defun decknix-board-focus-elsewhere-count (sessions)
  "Return how many SESSIONS need you outside the focus; 0 without one."
  (if (decknix-board-focus-board)
      (seq-count (lambda (s) (and (decknix-attention-state-p (nth 3 s))
                                  (not (decknix-board-focus-session-p s))))
                 sessions)
    0))

;; --- commands ------------------------------------------------------------

(defun decknix-board-focus-set (name)
  "Focus the sidebar on board NAME, or clear the focus when NAME is nil."
  (setq decknix-board-focus-name name)
  (decknix-board-focus-invalidate)
  (when (fboundp 'decknix--sidebar-state-write)
    (ignore-errors (decknix--sidebar-state-write)))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (ignore-errors (agent-shell-workspace-sidebar-refresh))))

(defun decknix-board-focus (&optional choose)
  "Focus the sidebar on a board, or clear the focus.
Unfocused, pick a board.  Focused, clear it; with CHOOSE (prefix
argument), pick another board, or `none'."
  (interactive "P")
  (if (and decknix-board-focus-name (not choose))
      (progn (decknix-board-focus-set nil)
             (message "Sidebar focus cleared"))
    (let* ((names (decknix-board-names))
           (choice (progn
                     (unless names (user-error "No boards yet: M-x decknix-board-new"))
                     (completing-read "Focus the sidebar on board: " (cons "none" names)
                                      nil t nil 'decknix-board-history
                                      (if decknix-board-focus-name "none" (car names))))))
      (decknix-board-focus-set (unless (equal choice "none") choice))
      (message (if decknix-board-focus-name
                   (format "Sidebar focused on %s (F clears)" (decknix-board-focus-title))
                 "Sidebar focus cleared")))))

;; The attention jump asks through this, so it needs no board knowledge.
(setq decknix-attention-focus-function #'decknix-board-focus-sessions)

(provide 'decknix-board-focus)
;;; decknix-board-focus.el ends here
