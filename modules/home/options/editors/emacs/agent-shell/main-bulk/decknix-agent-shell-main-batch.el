;;; decknix-agent-shell-main-batch.el --- Batch session launcher -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; Batch session launcher: a compose editor for kicking off multiple
;; agent-shell sessions at once with `---'-separated groups.
;;
;; Syntax:
;;   --- <group-name> [: <workspace>]
;;   <url-or-item>
;;   <url-or-item>
;;
;;   <ungrouped-url>          ← gets its own session
;;
;; Lines within a group share a single session.  Ungrouped lines each
;; get their own session.  Default workspace is the current project
;; root.
;;
;; PR Split.S.2: split out of `decknix-agent-shell-main' so the
;; ~3460-line bulk file can be navigated by theme.  Co-resident with
;; the main file in `main-bulk/'.  The pure parser
;; (`decknix--batch-parse-buffer') and command/tags/workspace
;; builders (`decknix--batch-build-*' / `-summary-rows') live in
;; their own carved + ERT-tested packages
;; (`decknix-agent-batch-parse', `decknix-agent-batch-build');
;; this file owns the side-effecting orchestration: the launcher,
;; the summary buffer, the minor mode, and the interactive entry
;; point.  Side-effecting `(define-key)' binding the entry point
;; into the heredoc's prefix maps still happens in the heredoc
;; itself (per AGENTS.md Rule 2).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Forward declarations for symbols defined in carved batch / agent /
;; url-parse packages, in `decknix-agent-shell-main', or in external
;; Emacs modules.  Resolved at runtime via the heredoc's `(require)'
;; chain in `default.el'.
(declare-function yas-minor-mode "ext:yasnippet")
(declare-function yas-activate-extra-mode "ext:yasnippet")
(declare-function decknix--agent-parse-pr-url
                  "decknix-agent-url-parse")
(declare-function decknix--agent-detect-workspace
                  "decknix-agent-shell-main")
(declare-function decknix--agent-pr-detect-workspace
                  "decknix-agent-shell-main")
(declare-function decknix--agent-quickaction-start
                  "decknix-agent-shell-main-link"
                  (name tags workspace command))
(declare-function decknix--batch-parse-buffer
                  "decknix-agent-batch-parse")
(declare-function decknix--batch-build-command
                  "decknix-agent-batch-build" (grouped items))
(declare-function decknix--batch-build-tags
                  "decknix-agent-batch-build" (items parser-fn))
(declare-function decknix--batch-resolve-workspace
                  "decknix-agent-batch-build"
                  (spec items default-ws parser-fn detect-fn))
(declare-function decknix--batch-summary-rows
                  "decknix-agent-batch-build" (results))


;; -- State --

(defvar decknix--batch-default-workspace nil
  "Default workspace for the current batch editor.")

(defvar decknix--batch-launch-results nil
  "List of (NAME STATUS BUFFER) for the most recent batch launch.")


;; -- Launcher + summary --

(defun decknix--batch-launch (specs)
  "Launch sessions for each spec in SPECS.
Each spec is an alist with name, workspace, items, grouped.
Grouped specs send all items as a single message.
Ungrouped specs send each item via /review-service-pr.

PR B.82: command/tags/workspace transforms are pinned by
`decknix-agent-batch-build' (carved, +12 ERT).  This function
is the orchestration adapter: it walks SPECS, calls the pure
builders, invokes the live `decknix--agent-quickaction-start',
and accumulates results."
  (setq decknix--batch-launch-results nil)
  (dolist (spec specs)
    (let* ((name (alist-get 'name spec))
           (items (alist-get 'items spec))
           (grouped (alist-get 'grouped spec))
           (command (decknix--batch-build-command grouped items))
           (tags (decknix--batch-build-tags
                  items #'decknix--agent-parse-pr-url))
           (workspace (decknix--batch-resolve-workspace
                       spec items decknix--batch-default-workspace
                       #'decknix--agent-parse-pr-url
                       #'decknix--agent-pr-detect-workspace)))
      (condition-case err
          (progn
            (decknix--agent-quickaction-start name tags workspace command)
            (push (list name "launched" nil) decknix--batch-launch-results))
        (error
         (push (list name "failed" (error-message-string err))
               decknix--batch-launch-results)))))
  (setq decknix--batch-launch-results
        (nreverse decknix--batch-launch-results))
  ;; Show summary
  (decknix--batch-show-summary))

(defun decknix--batch-show-summary ()
  "Display a summary buffer of the batch launch results.

PR B.82: per-row icon + status mapping is pinned by
`decknix--batch-summary-rows' (carved).  This function applies
faces and inserts the rows."
  (let ((buf (get-buffer-create "*Batch Launch*"))
        (rows (decknix--batch-summary-rows
               decknix--batch-launch-results)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Batch Launch Summary\n"
                            'font-lock-face '(:weight bold :height 1.2)))
        (insert (propertize (make-string 40 ?═)
                            'font-lock-face 'font-lock-comment-face)
                "\n\n")
        (dolist (row rows)
          (let ((icon (plist-get row :icon))
                (name (plist-get row :name))
                (status (plist-get row :status))
                (err (plist-get row :err)))
            (insert (propertize
                     icon
                     'font-lock-face
                     (if (string= status "launched")
                         'success 'error))
                    (propertize name 'font-lock-face '(:weight bold))
                    (format "  — %s" status)
                    (if err (format " (%s)" err) "")
                    "\n")))
        (insert "\n"
                (propertize (format "%d sessions launched"
                                   (length rows))
                            'font-lock-face 'font-lock-comment-face)
                "\n\n"
                (propertize "Press q to close.\n"
                            'font-lock-face 'font-lock-comment-face))
        (special-mode)
        (goto-char (point-min))))
    (display-buffer buf
                    '((display-buffer-at-bottom)
                      (window-height . fit-window-to-buffer)))))


;; -- Batch compose minor mode for syntax highlighting --

(defvar decknix-batch-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") 'decknix--batch-submit)
    (define-key map (kbd "C-c C-k") 'decknix--batch-cancel)
    map)
  "Keymap for `decknix-batch-compose-mode'.")

(defun decknix--batch-submit ()
  "Parse and launch all sessions from the batch editor."
  (interactive)
  (let ((specs (decknix--batch-parse-buffer)))
    (if (null specs)
        (user-error "No items to process — add URLs or groups")
      (when (y-or-n-p (format "Launch %d session(s)? "
                              (length specs)))
        (let ((buf (current-buffer)))
          (decknix--batch-launch specs)
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(defun decknix--batch-cancel ()
  "Cancel the batch editor."
  (interactive)
  (when (y-or-n-p "Cancel batch? ")
    (kill-buffer (current-buffer))))

(defvar decknix--batch-font-lock-keywords
  (list
   ;; --- divider lines (group headers)
   (list "^---\\s-+\\(.+?\\)\\(\\s-*:\\s-*\\(\\S-+.*\\)\\)?$"
         '(0 'font-lock-keyword-face t)
         '(1 'font-lock-function-name-face t)
         '(3 'font-lock-string-face t t))
   ;; GitHub PR URLs
   (list "https?://github\\.com/[^ \t\n]+"
         '(0 'link t))
   ;; Comments
   (list "^#.*$"
         '(0 'font-lock-comment-face t)))
  "Font-lock keywords for batch compose mode.")

(define-minor-mode decknix-batch-compose-mode
  "Minor mode for the batch session editor.
Provides syntax highlighting for --- dividers, URLs, and comments.
\\<decknix-batch-compose-mode-map>
\\[decknix--batch-submit]  Submit — parse and launch all sessions.
\\[decknix--batch-cancel]  Cancel — close without launching."
  :lighter " Batch"
  :keymap decknix-batch-compose-mode-map
  (if decknix-batch-compose-mode
      (progn
        (font-lock-add-keywords nil decknix--batch-font-lock-keywords)
        (setq-local header-line-format
                    (list
                     (propertize
                      " Batch: C-c C-c submit | C-c C-k cancel"
                      'face 'header-line)))
        ;; Enable yasnippet with batch-compose-mode snippets
        ;; (--- groups, PR URLs, workspace templates)
        (when (fboundp 'yas-minor-mode)
          (yas-minor-mode 1)
          (yas-activate-extra-mode 'decknix-batch-compose-mode))
        (font-lock-flush))
    (font-lock-remove-keywords nil decknix--batch-font-lock-keywords)
    (setq-local header-line-format nil)
    (font-lock-flush)))

(defun decknix-agent-batch-process ()
  "Open a batch compose editor for launching multiple sessions.
Syntax:
  --- <group-name> [: <workspace>]
  <url>
  <url>

  --- <another-group> [: ~/other/path]
  <url>

  <ungrouped-url>

Lines within a --- group share a single session.
Ungrouped lines each get their own session.
Comments start with #."
  (interactive)
  (let* ((default-ws (decknix--agent-detect-workspace))
         (buf (generate-new-buffer "*Batch Process*")))
    (display-buffer buf
                    '((display-buffer-at-bottom)
                      (window-height . 15)
                      (dedicated . t)))
    (select-window (get-buffer-window buf))
    (with-current-buffer buf
      (text-mode)
      (setq-local decknix--batch-default-workspace default-ws)
      (decknix-batch-compose-mode 1)
      ;; Insert template
      (insert (format "# Batch session launcher — workspace: %s\n"
                      default-ws)
              "# Syntax: --- <name> [: <workspace>]\n"
              "#         <url-per-line>\n"
              "# Ungrouped URLs get individual sessions.\n"
              "# C-c C-c to launch, C-c C-k to cancel.\n\n")
      (set-buffer-modified-p nil))))

(provide 'decknix-agent-shell-main-batch)
;;; decknix-agent-shell-main-batch.el ends here
