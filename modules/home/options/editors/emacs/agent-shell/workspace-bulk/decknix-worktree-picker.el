;;; decknix-worktree-picker.el --- Interactive worktree cleanup picker -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, git, worktree, cleanup

;;; Commentary:
;;
;; Selection picker for bulk worktree cleanup (spec §3.6.13).
;; Surfaces worktrees across all local clones, joined with GitHub PR state
;; and active Emacs sessions, so stale/merged/orphaned worktrees can be
;; removed safely.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'tabulated-list)
(require 'transient)

(declare-function tabulated-list-get-tag "tabulated-list")
(declare-function tabulated-list-get-id "tabulated-list")
(declare-function tabulated-list-put-tag "tabulated-list" (tag &optional advance))

(defvar decknix--hub-wip)
(defvar decknix--hub-worktree-cache)

(defvar decknix-wt-prune-safe-branch-delete nil
  "When non-nil, use `git branch -d' instead of `-D' during prune sweep.")

(defvar-local decknix-worktree-picker--filter-merged t
  "When non-nil, show worktrees whose branch is merged into main/master.")

(defvar-local decknix-worktree-picker--filter-closed t
  "When non-nil, show worktrees whose PR is closed or abandoned.")

(defvar-local decknix-worktree-picker--filter-no-session t
  "When non-nil, show worktrees not currently open in an Emacs session.")

(defvar-local decknix-worktree-picker--filter-dirty nil
  "When non-nil, show worktrees even if they have uncommitted changes.")

(defvar-local decknix-worktree-picker--filter-orphans t
  "When non-nil, show worktrees whose upstream branch is deleted.")

(defun decknix-worktree-picker--get-sessions ()
  "Return a set of workspace paths for all active sessions."
  (let ((sessions (make-hash-table :test 'equal))
        (path (expand-file-name "~/.config/decknix/agent-sessions.json")))
    (when (file-exists-p path)
      (condition-case nil
          (let* ((json-object-type 'alist)
                 (json-array-type 'list)
                 (json-false nil)
                 (data (json-read-file path))
                 (convs (cdr (assoc 'conversations data))))
            (dolist (conv convs)
              (let ((ws (cdr (assoc 'workspace (cdr conv)))))
                (when ws (puthash (expand-file-name ws) t sessions)))))
        (error nil)))
    sessions))

(defun decknix-worktree-picker--get-pr-map ()
  "Return a map of (repo . branch) -> PR state."
  (let ((pr-map (make-hash-table :test 'equal)))
    (dolist (pr decknix--hub-wip)
      (let* ((repo (cdr (assoc 'repo pr)))
             (branch (cdr (assoc 'branch pr)))
             (state (cdr (assoc 'state pr)))
             (merged (cdr (assoc 'merged_at pr))))
        (puthash (cons repo branch)
                 (if merged "merged" state)
                 pr-map)))
    pr-map))

(defun decknix-worktree-picker-list-entries ()
  "Build entries for the worktree picker using `decknix wt audit --json'."
  (let* ((json-str (shell-command-to-string "decknix wt audit --json"))
         (report (json-parse-string json-str :object-type 'alist :array-type 'list :null-object nil :false-object nil))
         (pr-map (decknix-worktree-picker--get-pr-map))
         (entries nil))
    (dolist (repo-report report)
      (let ((repo-key (cdr (assoc 'repo repo-report)))
            (worktrees (cdr (assoc 'worktrees repo-report))))
        (dolist (wt worktrees)
          (let* ((branch (cdr (assoc 'branch wt)))
                 (path (cdr (assoc 'path wt)))
                 (abs-path (expand-file-name path))
                 (dirty (cdr (assoc 'dirty wt)))
                 (orphan (cdr (assoc 'orphan wt)))
                 (active (cdr (assoc 'active wt)))
                 (merged (cdr (assoc 'merged wt)))
                 (age (cdr (assoc 'age_days wt)))
                 (pr-state (gethash (cons repo-key branch) pr-map "none"))
                 (closed (string= pr-state "CLOSED")))

            ;; Filter logic
            (when (or (and decknix-worktree-picker--filter-merged merged)
                      (and decknix-worktree-picker--filter-closed closed)
                      (and decknix-worktree-picker--filter-no-session (not active))
                      (and decknix-worktree-picker--filter-dirty dirty)
                      (and decknix-worktree-picker--filter-orphans orphan)
                      ;; If no filters are active, show everything?
                      ;; Actually, let's just show what matched the toggles.
                      )

              (push (list (list repo-key branch abs-path) ;; ID
                          (vector
                           repo-key
                           branch
                           (concat
                            (if dirty (propertize "!" 'face 'error) " ")
                            (if active (propertize "*" 'face 'warning) " ")
                            (if merged (propertize "✓" 'face 'success) " ")
                            (if orphan (propertize "⊘" 'face 'error) " "))
                           (propertize pr-state 'face
                                       (pcase pr-state
                                         ("OPEN" 'font-lock-keyword-face)
                                         ("merged" 'font-lock-doc-face)
                                         (_ 'font-lock-comment-face)))
                           (format "%dd" age)))
                    entries))))))
    (nreverse entries)))

(defvar decknix-worktree-picker-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "m") #'decknix-worktree-picker-mark)
    (define-key map (kbd "u") #'decknix-worktree-picker-unmark)
    (define-key map (kbd "U") #'decknix-worktree-picker-unmark-all)
    (define-key map (kbd "p") #'decknix-worktree-picker-prune)
    (define-key map (kbd "x") #'decknix-worktree-picker-prune) ;; Default x to prune sweep now
    (define-key map (kbd "X") #'decknix-worktree-picker-remove) ;; X for legacy
    (define-key map (kbd "f M") #'decknix-worktree-picker-toggle-merged)
    (define-key map (kbd "f C") #'decknix-worktree-picker-toggle-closed)
    (define-key map (kbd "f S") #'decknix-worktree-picker-toggle-session)
    (define-key map (kbd "f D") #'decknix-worktree-picker-toggle-dirty)
    (define-key map (kbd "f O") #'decknix-worktree-picker-toggle-orphans)
    (define-key map (kbd "g") #'revert-buffer)
    map)
  "Keymap for `decknix-worktree-picker-mode'.")

(define-derived-mode decknix-worktree-picker-mode tabulated-list-mode "Worktree Picker"
  "Major mode for selecting worktrees to clean up.

Mark worktrees with `m', unmark with `u'.
Execute full sweep (branch/dir/metadata) on marked with `x' or `p'.
Execute legacy removal (dir only) on marked with `X'.
Toggle filters with `f M' (merged), `f C' (closed), `f S' (active session),
`f D' (dirty), `f O' (orphans)."
  (setq tabulated-list-format [("Repo" 20 t)
                               ("Branch" 30 t)
                               ("S" 5 nil)
                               ("PR State" 10 t)
                               ("Age" 5 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key '("Repo" . nil))
  (setq tabulated-list-entries #'decknix-worktree-picker-list-entries)
  (tabulated-list-init-header))

(defun decknix-worktree-picker-mark ()
  "Mark current worktree for removal."
  (interactive)
  (tabulated-list-put-tag "D" t))

(defun decknix-worktree-picker-unmark ()
  "Unmark current worktree."
  (interactive)
  (tabulated-list-put-tag " " t))

(defun decknix-worktree-picker-unmark-all ()
  "Unmark all worktrees."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (tabulated-list-put-tag " ")
      (forward-line 1))))

(defun decknix-worktree-picker--get-marked ()
  "Return list of marked item IDs."
  (let ((marked nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (equal (tabulated-list-get-tag) "D")
          (push (tabulated-list-get-id) marked))
        (forward-line 1)))
    (nreverse marked)))

(defun decknix-worktree-picker-execute ()
  "Deprecated: use `decknix-worktree-picker-prune' or `-remove'."
  (interactive)
  (decknix-worktree-picker-prune))

(defun decknix-worktree-picker-remove ()
  "Remove all marked worktrees (directory only, legacy)."
  (interactive)
  (let ((marked (decknix-worktree-picker--get-marked)))
    (if (null marked)
        (message "No worktrees marked for removal")
      (when (yes-or-no-p (format "Remove %d marked worktrees (files only)? " (length marked)))
        (dolist (id marked)
          (let ((repo (nth 0 id))
                (branch (nth 1 id))
                (path (nth 2 id)))
            (message "Removing %s [%s]..." repo branch)
            ;; Run git worktree remove asynchronously
            (let ((default-directory (file-name-directory path)))
              (make-process
               :name "git-worktree-remove"
               :buffer nil
               :command (list "git" "worktree" "remove" path)
               :sentinel (lambda (_proc event)
                           (when (string= event "finished\n")
                             (message "Removed %s [%s]" repo branch)))))))))))

(defun decknix-worktree-picker-prune ()
  "Prune all marked worktrees (full sweep: dir + branch + metadata)."
  (interactive)
  (let ((marked (decknix-worktree-picker--get-marked)))
    (if (null marked)
        (message "No worktrees marked for pruning")
      (let* ((paths (mapcar #'cl-caddr marked))
             (count (length marked))
             (summary (format "Prune %d marked worktrees (sweep branch/dir/metadata)? " count)))
        (decknix--wt-run-prune-sweep paths summary)))))

(defun decknix--wt-run-prune-sweep (paths summary)
  "Run the full prune sweep on PATHS with SUMMARY prompt.
If PATHS is nil, runs a general sweep of all stale worktrees."
  (let* ((paths-file (when paths
                       (let ((tf (make-temp-file "decknix-wt-paths-")))
                         (with-temp-file tf
                           (insert (mapconcat #'identity paths "\n")))
                         tf)))
         (args (list "wt" "prune"))
         (prompt (concat summary "[d]ry run, [c]onfirm, [q]uit ")))
    (when paths-file
      (setq args (append args (list "--paths-file" paths-file))))
    (when decknix-wt-prune-safe-branch-delete
      (setq args (append args (list "--safe-delete-branch"))))

    (let ((choice (read-char-choice prompt '(?d ?c ?q))))
      (pcase choice
        (?q (message "Aborted"))
        (?d (let ((out (shell-command-to-string (mapconcat #'identity (append '("decknix") args) " "))))
              (with-current-buffer (get-buffer-create "*decknix prune dry-run*")
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (insert out)
                  (goto-char (point-min))
                  (display-buffer (current-buffer))))))
        (?c (let ((final-args (append args '("--apply"))))
              (message "Pruning...")
              (let ((out (shell-command-to-string (mapconcat #'identity (append '("decknix") final-args) " "))))
                (message "Prune complete:\n%s" (string-trim out))
                (when (derived-mode-p 'decknix-worktree-picker-mode)
                  (revert-buffer))))))
      (when paths-file
        (delete-file paths-file)))))

(defun decknix-worktree-picker-toggle-merged ()
  "Toggle merged filter."
  (interactive)
  (setq decknix-worktree-picker--filter-merged (not decknix-worktree-picker--filter-merged))
  (revert-buffer))

(defun decknix-worktree-picker-toggle-closed ()
  "Toggle closed filter."
  (interactive)
  (setq decknix-worktree-picker--filter-closed (not decknix-worktree-picker--filter-closed))
  (revert-buffer))

(defun decknix-worktree-picker-toggle-session ()
  "Toggle session filter."
  (interactive)
  (setq decknix-worktree-picker--filter-no-session (not decknix-worktree-picker--filter-no-session))
  (revert-buffer))

(defun decknix-worktree-picker-toggle-dirty ()
  "Toggle dirty filter."
  (interactive)
  (setq decknix-worktree-picker--filter-dirty (not decknix-worktree-picker--filter-dirty))
  (revert-buffer))

(defun decknix-worktree-picker-toggle-orphans ()
  "Toggle orphans filter."
  (interactive)
  (setq decknix-worktree-picker--filter-orphans (not decknix-worktree-picker--filter-orphans))
  (revert-buffer))

(defun decknix-worktree-picker ()
  "Open the worktree cleanup picker."
  (interactive)
  (let ((buf (get-buffer-create "*decknix worktree picker*")))
    (with-current-buffer buf
      (decknix-worktree-picker-mode))
    (switch-to-buffer buf)
    (revert-buffer)))

(provide 'decknix-worktree-picker)
;;; decknix-worktree-picker.el ends here
