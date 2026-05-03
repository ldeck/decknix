;;; decknix-agent-shell-context.el --- Context panel: issues, PRs, CI, reviews -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, context, github, ci

;;; Commentary:
;;
;; Context panel module extracted from agent-shell.nix as part of PR B-Bulk.1.
;; Tracks GitHub issues, PRs, CI status, and review threads for an
;; agent-shell-mode buffer; renders a compact badge or expanded section
;; in the unified header-line via `decknix--header-update'.
;;
;; This module is loaded only when
;; `programs.emacs.decknix.agentShell.context.enable' is non-nil
;; (the corresponding `(require ...)' lives in the same
;; `optionalString cfg.context.enable' block in agent-shell.nix).
;; Cross-feature `fboundp' guards in other modules continue to gate
;; calls to this module's entry points correctly: when context is
;; disabled, the module is never required and its symbols stay
;; undefined.

;; FIXME(arch-debt): this module is a verbatim bulk extraction of 35
;; declarations.  Follow-up PRs (B.22+) should tease out
;; individually-tested sub-modules using the standard
;; `mkEmacsTestedPackage' pattern.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

;; Forward declarations for symbols defined elsewhere in the heredoc.
(declare-function decknix--header-update "ext:decknix-agent-shell")
(declare-function decknix--agent-buffer-session-id "ext:decknix-agent-shell")
(declare-function decknix--agent-tags-read "ext:decknix-agent-shell")
(declare-function decknix--agent-tags-write "ext:decknix-agent-shell")
(declare-function forge-visit-topic "ext:forge")
(declare-function project-current "project")
(declare-function project-root "project")


;; == Context Panel: issues, PRs, CI status, reviews ==
;; Surfaces work context in the header-line with C-c i navigation.
;; Uses `gh` CLI for GitHub data fetching.

;; -- Data model --
;; Each buffer tracks a set of context items (issues, PRs).
;; Items can be auto-detected from conversation text or manually pinned.

(defvar-local decknix--context-header-expanded nil
  "Whether context data is expanded in the header-line.
nil = collapsed (default): show a compact badge with item count.
t = expanded: show the full issues/PRs/CI/reviews detail.")

(defvar-local decknix--context-items nil
  "Alist of tracked context items for this agent-shell buffer.
Each entry is (ID . plist) where ID is e.g. \"#49\" or \"NC-1234\".
Plist keys: :type (issue|pr|jira), :repo, :number, :state, :title, :pinned, :url")

(defvar-local decknix--context-ci nil
  "Plist of CI status for current branch. Keys: :status :name :elapsed :url")

(defvar-local decknix--context-reviews nil
  "Plist of PR review status. Keys: :total :unresolved :url")

(defvar-local decknix--context-branch nil
  "Current git branch name for context.")

(defvar-local decknix--context-repo nil
  "Current GitHub owner/repo for context (e.g. \"ldeck/decknix\").")

(defvar decknix--context-ci-timer nil
  "Timer for periodic CI status polling.")

;; -- Repository detection --
(defun decknix--context-detect-repo ()
  "Detect GitHub owner/repo from the project's git remote."
  (let* ((default-directory (or (when (fboundp 'project-root)
                                  (when-let ((proj (project-current)))
                                    (project-root proj)))
                                default-directory))
         (url (string-trim
               (shell-command-to-string "git remote get-url origin 2>/dev/null"))))
    (when (string-match "github\\.com[:/]\\([^/]+/[^/.]+\\)" url)
      (match-string 1 url))))

;; -- Reference detection from buffer text --
(defun decknix--context-scan-buffer ()
  "Scan agent-shell buffer text for issue/PR references.
Returns an alist of (ID . plist) for newly detected items."
  (let ((found nil)
        (text (buffer-substring-no-properties (point-min) (point-max))))
    ;; GitHub issues/PRs: #123 or org/repo#123
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward
              "\\(?:\\([A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\)\\)?#\\([0-9]+\\)" nil t)
        (let* ((repo (or (match-string 1) decknix--context-repo))
               (num (match-string 2))
               (id (if (match-string 1)
                       (format "%s#%s" repo num)
                     (format "#%s" num))))
          (unless (assoc id found)
            (push (cons id (list :type 'github :repo repo
                                 :number (string-to-number num)
                                 :state nil :title nil :pinned nil))
                  found))))
      ;; Jira tickets: PROJ-123
      (goto-char (point-min))
      (while (re-search-forward "\\b\\([A-Z][A-Z0-9]+-[0-9]+\\)\\b" nil t)
        (let ((id (match-string 1)))
          (unless (or (assoc id found)
                      ;; Exclude false positives (common non-Jira patterns)
                      (string-match-p "\\`\\(HTTP\\|SHA\\|UTF\\|ISO\\)-" id))
            (push (cons id (list :type 'jira :state nil :title nil :pinned nil))
                  found)))))
    found))

;; -- Merge detected items into tracked context --
(defun decknix--context-refresh-detected ()
  "Scan buffer and merge newly detected items into context.
Preserves pinned items and previously fetched metadata."
  (let ((detected (decknix--context-scan-buffer)))
    ;; Add new items (don't overwrite existing with fetched metadata)
    (dolist (item detected)
      (unless (assoc (car item) decknix--context-items)
        (push item decknix--context-items)))))

;; -- Pin / unpin --
(defun decknix-context-pin (id)
  "Manually pin an issue or PR ID to the current session context."
  (interactive "sPin issue/PR (e.g. #49, NC-1234, org/repo#12): ")
  (let ((entry (assoc id decknix--context-items)))
    (if entry
        (plist-put (cdr entry) :pinned t)
      ;; Detect type from format
      (let ((type (cond
                   ((string-match "\\`[A-Z][A-Z0-9]+-[0-9]+\\'" id) 'jira)
                   (t 'github))))
        (push (cons id (list :type type :pinned t :state nil :title nil))
              decknix--context-items)))
    (decknix--context-update-header)
    (message "Pinned %s to context" id)))

(defun decknix-context-unpin ()
  "Remove a tracked item from the session context."
  (interactive)
  (let* ((keys (mapcar #'car decknix--context-items))
         (choice (completing-read "Unpin: " keys nil t)))
    (setq decknix--context-items
          (assoc-delete-all choice decknix--context-items))
    (decknix--context-update-header)
    (message "Removed %s from context" choice)))

;; -- GitHub data fetching via gh CLI --
(defun decknix--context-gh-json (args)
  "Run gh CLI with ARGS, return parsed JSON or nil on error."
  (condition-case nil
      (let ((output (string-trim
                     (shell-command-to-string
                      (format "gh %s 2>/dev/null" args)))))
        (when (and output (not (string-empty-p output))
                   (string-prefix-p "{" output))
          (json-read-from-string output)))
    (error nil)))

(defun decknix--context-gh-json-array (args)
  "Run gh CLI with ARGS, return parsed JSON array or nil."
  (condition-case nil
      (let ((output (string-trim
                     (shell-command-to-string
                      (format "gh %s 2>/dev/null" args)))))
        (when (and output (not (string-empty-p output))
                   (string-prefix-p "[" output))
          (json-read-from-string output)))
    (error nil)))

(defun decknix--context-fetch-issue (repo number)
  "Fetch issue/PR metadata from GitHub for REPO #NUMBER."
  (let ((data (decknix--context-gh-json
               (format "issue view %d --repo %s --json number,title,state,url,isPullRequest"
                       number repo))))
    (when data
      (let ((is-pr (eq (alist-get 'isPullRequest data) t)))
        (list :state (downcase (or (alist-get 'state data) "unknown"))
              :title (alist-get 'title data)
              :url (alist-get 'url data)
              :type (if is-pr 'pr 'issue))))))

(defun decknix--context-fetch-ci ()
  "Fetch latest CI run status for the current branch."
  (let* ((branch (or decknix--context-branch
                     (string-trim
                      (shell-command-to-string "git branch --show-current 2>/dev/null"))))
         (repo (or decknix--context-repo (decknix--context-detect-repo)))
         (data (decknix--context-gh-json
                (format "run list --branch %s --repo %s --limit 1 --json status,conclusion,name,url,updatedAt"
                        (shell-quote-argument branch)
                        (shell-quote-argument (or repo ""))))))
    (when (and data (> (length data) 0))
      (let* ((run (if (vectorp data) (aref data 0) (car data)))
             (status (alist-get 'status run))
             (conclusion (alist-get 'conclusion run)))
        (setq decknix--context-ci
              (list :status (cond
                             ((string= status "completed")
                              (if (string= conclusion "success") "pass" "fail"))
                             ((string= status "in_progress") "running")
                             (t status))
                    :name (alist-get 'name run)
                    :url (alist-get 'url run)))))))

(defun decknix--context-fetch-reviews ()
  "Fetch unresolved review thread count for open PRs in context."
  (let ((unresolved 0) (total 0) (pr-url nil))
    (dolist (item decknix--context-items)
      (let ((props (cdr item)))
        (when (and (eq (plist-get props :type) 'pr)
                   (string= (plist-get props :state) "open"))
          (let* ((repo (or (plist-get props :repo) decknix--context-repo))
                 (num (plist-get props :number))
                 (threads (decknix--context-gh-json-array
                           (format "pr view %d --repo %s --json reviewThreads --jq '.reviewThreads'"
                                   num (shell-quote-argument (or repo ""))))))
            (when threads
              (setq pr-url (plist-get props :url))
              (let ((vec (if (vectorp threads) threads (vconcat threads))))
                (setq total (+ total (length vec)))
                (dotimes (i (length vec))
                  (let ((thread (aref vec i)))
                    (unless (eq (alist-get 'isResolved thread) t)
                      (setq unresolved (1+ unresolved)))))))))))
    (setq decknix--context-reviews
          (list :total total :unresolved unresolved :url pr-url))))

;; -- Header-line rendering --
;; Context is collapsed by default.  C-c I toggles inline expansion.
;; C-u C-c I opens the full panel in a help-style side window.

(defun decknix--context-header-badge ()
  "Build a compact context badge for the collapsed header.
Shows item count and CI status as a short string, e.g. \"ctx:3 ✓\"."
  (let* ((n (length decknix--context-items))
         (ci-icon (when decknix--context-ci
                    (let ((st (plist-get decknix--context-ci :status)))
                      (cond ((string= st "pass")
                             (propertize "\u2713" 'face 'success))
                            ((string= st "fail")
                             (propertize "\u2717" 'face 'error))
                            ((string= st "running")
                             (propertize "\u27f3" 'face 'warning))
                            (t nil)))))
         (unres (when decknix--context-reviews
                  (plist-get decknix--context-reviews :unresolved)))
         (parts nil))
    (when (> n 0)
      (push (propertize (format "ctx:%d" n)
                        'face 'font-lock-comment-face)
            parts))
    (when ci-icon (push ci-icon parts))
    (when (and unres (> unres 0))
      (push (propertize (format "rev:%d" unres) 'face 'warning)
            parts))
    (when parts
      (concat " "
              (propertize
               (mapconcat #'identity (nreverse parts) " ")
               'help-echo "C-c I to expand context, C-u C-c I for side panel")))))

(defun decknix--context-header-expanded-string ()
  "Build the full (expanded) header-line string showing tracked context."
  (let ((parts nil))
    ;; Issues
    (let ((issues (cl-remove-if-not
                   (lambda (item) (eq (plist-get (cdr item) :type) 'issue))
                   decknix--context-items)))
      (when issues
        (push (format "Issues: %s"
                      (mapconcat
                       (lambda (item)
                         (let* ((id (car item))
                                (state (plist-get (cdr item) :state)))
                           (propertize id 'face
                                       (cond ((string= state "open") 'success)
                                             ((string= state "closed") 'shadow)
                                             (t 'default)))))
                       issues " "))
              parts)))
    ;; PRs
    (let ((prs (cl-remove-if-not
                (lambda (item) (eq (plist-get (cdr item) :type) 'pr))
                decknix--context-items)))
      (when prs
        (push (format "PR: %s"
                      (mapconcat
                       (lambda (item)
                         (let* ((id (car item))
                                (state (plist-get (cdr item) :state)))
                           (propertize id 'face
                                       (cond ((string= state "open") 'success)
                                             ((string= state "merged") 'font-lock-constant-face)
                                             ((string= state "closed") 'shadow)
                                             (t 'default)))))
                       prs " "))
              parts)))
    ;; CI
    (when decknix--context-ci
      (let ((st (plist-get decknix--context-ci :status)))
        (push (format "CI: %s"
                      (propertize
                       (cond ((string= st "pass") "\u2705")
                             ((string= st "fail") "\u274c")
                             ((string= st "running") "\ud83d\udd04")
                             (t "?"))
                       'face (cond ((string= st "pass") 'success)
                                   ((string= st "fail") 'error)
                                   (t 'warning))))
              parts)))
    ;; Reviews
    (when (and decknix--context-reviews
               (plist-get decknix--context-reviews :url))
      (let ((unres (plist-get decknix--context-reviews :unresolved)))
        (when (> unres 0)
          (push (propertize (format "Reviews: %d unresolved" unres)
                            'face 'warning)
                parts))))
    (if parts
        (concat " " (mapconcat #'identity (nreverse parts) "  |  "))
      nil)))

(defun decknix--context-header-string ()
  "Build the header-line context string.
When collapsed (default), returns a compact badge (item count + CI icon).
When expanded, returns the full issues/PRs/CI/reviews detail.
Toggle with C-c I; C-u C-c I opens the full panel in a side window."
  (if decknix--context-header-expanded
      (decknix--context-header-expanded-string)
    (decknix--context-header-badge)))

(defun decknix--context-update-header ()
  "Update the header-line-format for the current agent-shell buffer.
Delegates to the unified header which incorporates context data."
  (when (derived-mode-p 'agent-shell-mode)
    (decknix--header-update)))

;; -- Full refresh (async-ish: fetch all data, update header) --
(defun decknix--context-full-refresh ()
  "Refresh all context data and update header-line."
  (interactive)
  (unless decknix--context-repo
    (setq decknix--context-repo (decknix--context-detect-repo)))
  (unless decknix--context-branch
    (setq decknix--context-branch
          (string-trim
           (shell-command-to-string "git branch --show-current 2>/dev/null"))))
  ;; Scan buffer for new references
  (decknix--context-refresh-detected)
  ;; Fetch GitHub metadata for items missing state
  (dolist (item decknix--context-items)
    (let ((props (cdr item)))
      (when (and (memq (plist-get props :type) '(github issue pr))
                 (null (plist-get props :state)))
        (let* ((repo (or (plist-get props :repo) decknix--context-repo))
               (num (plist-get props :number)))
          (when (and repo num)
            (let ((meta (decknix--context-fetch-issue repo num)))
              (when meta
                (plist-put props :state (plist-get meta :state))
                (plist-put props :title (plist-get meta :title))
                (plist-put props :url (plist-get meta :url))
                (plist-put props :type (plist-get meta :type)))))))))
  ;; Fetch CI and reviews
  (decknix--context-fetch-ci)
  (decknix--context-fetch-reviews)
  ;; Update display
  (decknix--context-update-header))

;; -- CI polling timer --
(defun decknix--context-start-ci-polling ()
  "Start polling CI status every 60 seconds."
  (when decknix--context-ci-timer
    (cancel-timer decknix--context-ci-timer))
  (setq decknix--context-ci-timer
        (run-with-timer 60 60
                        (lambda ()
                          (when-let ((buf (cl-find-if
                                           (lambda (b)
                                             (with-current-buffer b
                                               (derived-mode-p 'agent-shell-mode)))
                                           (buffer-list))))
                            (with-current-buffer buf
                              (decknix--context-fetch-ci)
                              (decknix--context-update-header)))))))

;; -- Persistence: save/restore pinned context items --
;; Piggybacks on the existing agent-sessions.json tag store.
;; Each session entry gains a "context" key with pinned items.

(defun decknix--context-save ()
  "Save pinned context items for the current agent-shell session."
  (when-let ((session-id (decknix--agent-buffer-session-id)))
    (let* ((store (decknix--agent-tags-read))
           (entry (or (gethash session-id store)
                      (make-hash-table :test 'equal)))
           (pinned (cl-remove-if-not
                    (lambda (item) (plist-get (cdr item) :pinned))
                    decknix--context-items))
           (serialized (mapcar (lambda (item)
                                 (list (cons "id" (car item))
                                       (cons "type" (symbol-name
                                                     (plist-get (cdr item) :type)))
                                       (cons "repo" (plist-get (cdr item) :repo))
                                       (cons "number" (plist-get (cdr item) :number))))
                               pinned)))
      (puthash "context" serialized entry)
      (puthash session-id entry store)
      (decknix--agent-tags-write store))))

(defun decknix--context-restore ()
  "Restore pinned context items for the current agent-shell session."
  (when-let ((session-id (decknix--agent-buffer-session-id)))
    (let* ((store (decknix--agent-tags-read))
           (entry (gethash session-id store))
           (saved (and entry (gethash "context" entry))))
      (when saved
        (dolist (item saved)
          (let* ((id (cdr (assoc "id" item)))
                 (type (intern (or (cdr (assoc "type" item)) "github")))
                 (repo (cdr (assoc "repo" item)))
                 (num (cdr (assoc "number" item))))
            (unless (assoc id decknix--context-items)
              (push (cons id (list :type type :repo repo :number num
                                   :state nil :title nil :pinned t))
                    decknix--context-items))))))))


;; -- Detail panel (transient-style buffer) --
(defun decknix-context-panel ()
  "Show a detailed context panel for the current session."
  (interactive)
  (decknix--context-full-refresh)
  (let ((buf (get-buffer-create "*Agent Context*"))
        (items decknix--context-items)
        (ci decknix--context-ci)
        (reviews decknix--context-reviews)
        (branch decknix--context-branch)
        (repo decknix--context-repo))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (propertize "Agent Context Panel\n"
                     'font-lock-face '(:weight bold :height 1.2))
         (propertize (make-string 52 ?\u2500) 'font-lock-face 'font-lock-comment-face)
         "\n\n")
        ;; Issues
        (let ((issues (cl-remove-if-not
                       (lambda (i) (eq (plist-get (cdr i) :type) 'issue))
                       items)))
          (insert (propertize "Issues\n" 'font-lock-face '(:weight bold))
                  (propertize (make-string 40 ?\u2500) 'font-lock-face 'font-lock-comment-face)
                  "\n")
          (if issues
              (dolist (item issues)
                (let* ((id (car item))
                       (props (cdr item))
                       (pin (if (plist-get props :pinned) " \ud83d\udccc" "")))
                  (insert (format "  %-12s %-35s %s%s\n"
                                  id
                                  (or (plist-get props :title) "")
                                  (or (plist-get props :state) "?")
                                  pin))))
            (insert "  (none detected)\n"))
          (insert "\n"))
        ;; PRs
        (let ((prs (cl-remove-if-not
                    (lambda (i) (eq (plist-get (cdr i) :type) 'pr))
                    items)))
          (insert (propertize "Pull Requests\n" 'font-lock-face '(:weight bold))
                  (propertize (make-string 40 ?\u2500) 'font-lock-face 'font-lock-comment-face)
                  "\n")
          (if prs
              (dolist (item prs)
                (let* ((id (car item))
                       (props (cdr item))
                       (state (or (plist-get props :state) "?"))
                       (icon (cond ((string= state "merged") "\u2705")
                                   ((string= state "open") "\ud83d\udfe2")
                                   ((string= state "closed") "\ud83d\udd34")
                                   (t " "))))
                  (insert (format "  %s %-10s %-32s %s\n"
                                  icon id
                                  (or (plist-get props :title) "")
                                  state))))
            (insert "  (none detected)\n"))
          (insert "\n"))
        ;; Branch & CI
        (insert (propertize "Branch & CI\n" 'font-lock-face '(:weight bold))
                (propertize (make-string 40 ?\u2500) 'font-lock-face 'font-lock-comment-face)
                "\n")
        (when branch
          (insert (format "  Branch: %s" branch))
          (when repo (insert (format "  (%s)" repo)))
          (insert "\n"))
        (if ci
            (let ((st (plist-get ci :status)))
              (insert (format "  CI:     %s %s\n"
                              (cond ((string= st "pass") "\u2705 success")
                                    ((string= st "fail") "\u274c failed")
                                    ((string= st "running") "\ud83d\udd04 running")
                                    (t st))
                              (or (plist-get ci :name) ""))))
          (insert "  CI:     (not fetched)\n"))
        (insert "\n")
        ;; Reviews
        (insert (propertize "Reviews\n" 'font-lock-face '(:weight bold))
                (propertize (make-string 40 ?\u2500) 'font-lock-face 'font-lock-comment-face)
                "\n")
        (if reviews
            (insert (format "  %d threads, %d unresolved\n"
                            (plist-get reviews :total)
                            (plist-get reviews :unresolved)))
          (insert "  (no open PRs in context)\n"))
        (insert "\n"
                (propertize (make-string 52 ?\u2500) 'font-lock-face 'font-lock-comment-face)
                "\n"
                (propertize "Press q to close.  C-c i g to open item in browser.\n"
                            'font-lock-face 'font-lock-comment-face))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buf
                   '((display-buffer-in-side-window)
                     (side . right)
                     (slot . 0)
                     (window-width . 0.4)
                     (preserve-size . (t . nil))))))

(defun decknix-context-toggle ()
  "Toggle inline context expansion in the header-line.
When collapsed, the header shows a compact badge (item count + CI icon).
When expanded, the full context detail is shown."
  (interactive)
  (if (and (null decknix--context-items)
           (null decknix--context-ci)
           (null decknix--context-reviews))
      (progn
        (message "No context items tracked yet.  Use C-c i p to pin an issue/PR, or mention a #123 / owner/repo#N in conversation.")
        ;; Trigger a refresh in case items can be auto-detected
        (when (fboundp 'decknix--context-full-refresh)
          (decknix--context-full-refresh)))
    (setq decknix--context-header-expanded
          (not decknix--context-header-expanded))
    (decknix--header-update)
    (message "Context header: %s  (C-u C-c I for side panel)"
             (if decknix--context-header-expanded "expanded" "collapsed"))))

(defun decknix-context-toggle-or-panel (arg)
  "Toggle context display.  With prefix ARG, open the full side panel.
Without prefix, toggle inline context in the header-line.

  C-c I     — toggle collapsed/expanded header context
  C-u C-c I — open the full Agent Context panel in a help-style side window"
  (interactive "P")
  (if arg
      (decknix-context-panel)
    (decknix-context-toggle)))

;; -- Navigation commands --
(defun decknix-context-browse ()
  "Open a tracked context item in the browser."
  (interactive)
  (let* ((items (cl-remove-if
                 (lambda (i) (null (plist-get (cdr i) :url)))
                 decknix--context-items))
         (choices (mapcar (lambda (i)
                           (format "%s  %s" (car i)
                                   (or (plist-get (cdr i) :title) "")))
                         items))
         (choice (completing-read "Open in browser: " choices nil t))
         (id (car (split-string choice "  ")))
         (url (plist-get (cdr (assoc id decknix--context-items)) :url)))
    (when url (browse-url url))))

(defun decknix-context-browse-ci ()
  "Open the latest CI run in the browser."
  (interactive)
  (if-let ((url (plist-get decknix--context-ci :url)))
      (browse-url url)
    (message "No CI run URL available. Try C-c i c to refresh.")))

(defun decknix-context-forge-visit ()
  "Visit a tracked issue/PR in magit-forge."
  (interactive)
  (let* ((choices (mapcar (lambda (i)
                           (format "%s  %s" (car i)
                                   (or (plist-get (cdr i) :title) "")))
                         decknix--context-items))
         (choice (completing-read "Visit in forge: " choices nil t))
         (id (car (split-string choice "  ")))
         (props (cdr (assoc id decknix--context-items)))
         (num (plist-get props :number)))
    (if (and num (fboundp 'forge-visit-topic))
        (progn
          ;; FIXME(arch-debt): repo is read from props but the
          ;; current branch only browses the URL; a follow-up can
          ;; restore proper `forge-visit-topic' dispatch keyed on
          ;; (repo . num).
          (message "Opening %s in forge..." id)
          (if-let ((url (plist-get props :url)))
              (browse-url url)
            (message "No URL for %s" id)))
      (message "No forge support for %s" id))))

(defun decknix-context-list-issues ()
  "Show tracked issues in a completing-read picker."
  (interactive)
  (decknix--context-full-refresh)
  (let* ((issues (cl-remove-if-not
                  (lambda (i) (eq (plist-get (cdr i) :type) 'issue))
                  decknix--context-items))
         (choices (mapcar (lambda (i)
                           (format "%-12s %-6s %s"
                                   (car i)
                                   (or (plist-get (cdr i) :state) "?")
                                   (or (plist-get (cdr i) :title) "")))
                         issues)))
    (if choices
        (let* ((choice (completing-read "Issue: " choices nil t))
               (id (car (split-string (string-trim choice))))
               (url (plist-get (cdr (assoc id decknix--context-items)) :url)))
          (when url (browse-url url)))
      (message "No issues in context"))))

(defun decknix-context-list-prs ()
  "Show tracked PRs in a completing-read picker."
  (interactive)
  (decknix--context-full-refresh)
  (let* ((prs (cl-remove-if-not
               (lambda (i) (eq (plist-get (cdr i) :type) 'pr))
               decknix--context-items))
         (choices (mapcar (lambda (i)
                           (format "%-12s %-6s %s"
                                   (car i)
                                   (or (plist-get (cdr i) :state) "?")
                                   (or (plist-get (cdr i) :title) "")))
                         prs)))
    (if choices
        (let* ((choice (completing-read "PR: " choices nil t))
               (id (car (split-string (string-trim choice))))
               (url (plist-get (cdr (assoc id decknix--context-items)) :url)))
          (when url (browse-url url)))
      (message "No PRs in context"))))

(defun decknix-context-show-ci ()
  "Refresh and display CI status."
  (interactive)
  (decknix--context-fetch-ci)
  (decknix--context-update-header)
  (if decknix--context-ci
      (let ((st (plist-get decknix--context-ci :status))
            (name (plist-get decknix--context-ci :name)))
        (message "CI: %s — %s"
                 (cond ((string= st "pass") "success")
                       ((string= st "fail") "FAILED")
                       ((string= st "running") "running...")
                       (t st))
                 (or name "unknown")))
    (message "No CI data available")))

(defun decknix-context-show-reviews ()
  "Refresh and display PR review status."
  (interactive)
  (decknix--context-fetch-reviews)
  (decknix--context-update-header)
  (if decknix--context-reviews
      (message "Reviews: %d threads, %d unresolved"
               (plist-get decknix--context-reviews :total)
               (plist-get decknix--context-reviews :unresolved))
    (message "No open PRs in context")))

(provide 'decknix-agent-shell-context)
;;; decknix-agent-shell-context.el ends here
