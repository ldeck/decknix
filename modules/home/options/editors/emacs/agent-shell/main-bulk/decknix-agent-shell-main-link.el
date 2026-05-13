;;; decknix-agent-shell-main-link.el --- Quickaction + PR/repo linking -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; Quickaction launcher + PR-review entry point + PR/repo linking
;; commands.  Co-resident with the main file in `main-bulk/'.
;;
;; PR Split.S.6: extracted out of `decknix-agent-shell-main' so the
;; bulk file can shrink toward a pure preamble + `(require)' index.
;; This file owns:
;;
;;   - `decknix--agent-quickaction-start': the reusable spawn-a-new-
;;     session-with-a-primed-first-message primitive that drives
;;     every quick action (PR review today, future investigate-issue
;;     / triage / etc.).  Selects a non-sidebar target window via
;;     the carved `decknix-agent-quickaction-window' policy, applies
;;     metadata via `decknix--agent-session-new-post-create' (split
;;     into `decknix-agent-shell-main-session'), then subscribes to
;;     `prompt-ready' so the COMMAND fires the instant the ACP
;;     session is fully established.
;;
;;   - `decknix-agent-review-pr': the canonical quick action.
;;     Parses a GitHub PR URL via `decknix--agent-parse-pr-url',
;;     auto-generates the session name (`pr-<repo>-<number>') and
;;     tags (`review' / `<repo>' / `#<number>'), prompts only for
;;     the workspace, then drives `decknix--agent-quickaction-start'
;;     with `/review-service-pr <url>'.
;;
;;   - `decknix-agent-link-pr' / `-link-repo' / `-unlink-pr':
;;     interactive linking commands that mutate the carved
;;     `decknix-agent-link-store' for the current conversation key.
;;     PR links surface in the workspace sidebar's review-column
;;     row; repo links surface as branch+sha rows under the same
;;     repo group.
;;
;; The split file forward-declares every carved pure helper it
;; touches (`decknix-agent-{url-parse,clipboard,parse,vcs,
;; link-store,session-{workspace,model},conv-resolve,buffer-lookup,
;; quickaction-window,workspace-detect}') and the upstream
;; `agent-shell' / `shell-maker' surfaces it drives.  Side-effecting
;; `(define-key)' bindings into the heredoc's prefix maps still
;; happen in the heredoc itself (per AGENTS.md Rule 2).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Forward declarations for symbols defined in carved packages, in
;; sibling split files, in `decknix-agent-shell-main', or in external
;; Emacs modules.  Resolved at runtime via the heredoc's `(require)'
;; chain in `default.el'.

;; URL parsing (`agent/decknix-agent-url-parse').
(declare-function decknix--agent-parse-pr-url
                  "decknix-agent-url-parse" (url))
(declare-function decknix--agent-pr-parse-url
                  "decknix-agent-url-parse" (url))
(declare-function decknix--agent-repo-parse-url
                  "decknix-agent-url-parse" (url))
(declare-function decknix--agent-pr-url-accessor
                  "decknix-agent-url-parse" (rec key))

;; Clipboard URL DWIM (`agent/decknix-agent-clipboard').
(declare-function decknix--agent-clipboard-url
                  "decknix-agent-clipboard")
(declare-function decknix--clipboard-github-pr-url
                  "decknix-agent-clipboard")
(declare-function decknix--clipboard-github-repo-url
                  "decknix-agent-clipboard")

;; Workspace detection for PR review (`agent/decknix-agent-workspace-detect').
(declare-function decknix--agent-pr-detect-workspace
                  "decknix-agent-workspace-detect" (owner repo))

;; Quickaction window policy (PR B.80 — pure resolvers in
;; `quickaction-window/decknix-agent-quickaction-window').
(declare-function decknix--quickaction-window-is-sidebar-p
                  "decknix-agent-quickaction-window"
                  (side-param dedicated-p buffer-name sidebar-buf))
(declare-function decknix--quickaction-target-window
                  "decknix-agent-quickaction-window"
                  (cur-is-sidebar cur main-win))
(declare-function decknix--quickaction-window-candidates
                  "decknix-agent-quickaction-window"
                  (descriptors))

;; Buffer lookup (PR B.66 — `buffer-lookup/decknix-agent-buffer-lookup').
(declare-function decknix--agent-find-new-shell-buffer
                  "decknix-agent-buffer-lookup" (before-buffers))
(declare-function decknix--agent-current-conv-key
                  "decknix-agent-buffer-lookup")

;; Conversation / link / workspace metadata (carved).
(declare-function decknix--agent-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key))
(declare-function decknix--agent-linked-items
                  "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-link-pr "decknix-agent-link-store"
                  (conv-key url &optional pr-type added))
(declare-function decknix--agent-unlink-pr
                  "decknix-agent-link-store" (conv-key url))
(declare-function decknix--agent-link-repo "decknix-agent-link-store"
                  (conv-key url branch &optional added))
(declare-function decknix--agent-unlink-repo
                  "decknix-agent-link-store" (conv-key url branch))

;; VCS helpers (`agent/decknix-agent-vcs').
(declare-function decknix--git-remote-url "decknix-agent-vcs")
(declare-function decknix--detect-default-branch "decknix-agent-vcs")

;; Session lifecycle hook (sibling split: `decknix-agent-shell-main-session').
(declare-function decknix--agent-session-new-post-create
                  "decknix-agent-shell-main-session"
                  (before-buffers name tags workspace
                                  &optional first-message))

;; Session cache state (carved into `decknix-agent-session-cache';
;; mutated here to force the picker to pick up the new session).
(defvar decknix--agent-session-cache-time)

;; Upstream agent-shell / shell-maker surfaces.
(declare-function agent-shell-start "ext:agent-shell")
(declare-function agent-shell-subscribe-to "ext:agent-shell")
(declare-function agent-shell--make-acp-client "ext:agent-shell")
(declare-function agent-shell-auggie-make-agent-config
                  "ext:agent-shell-auggie")
(declare-function agent-shell-workspace-sidebar-refresh
                  "ext:agent-shell-workspace")
(declare-function shell-maker-submit "ext:shell-maker")
(defvar agent-shell-auggie-acp-command)
(defvar agent-shell-auggie-authentication)
(defvar agent-shell-auggie-environment)
(defvar agent-shell-display-action)
(defvar agent-shell-workspace-sidebar-buffer-name)


;; -- Quickaction primitive --

(defun decknix--agent-quickaction-start (name tags workspace command)
  "Start a quick-action session with NAME, TAGS, WORKSPACE, and auto-send COMMAND.
Creates a new agent session, applies metadata, then subscribes to the
`prompt-ready' event to send COMMAND as soon as the ACP session is
fully established.  Returns immediately.
When invoked from a dedicated or side window (e.g., the sidebar), the
new session is displayed in the frame's main window instead of
replacing the caller, preserving the sidebar.
When the current frame has three or more non-sidebar windows the
caller is prompted to pick a placement (Replace / Split right /
Split below per pane); the default selection lands on
\"Replace ‹current›\" so RET reproduces today's behaviour."
  ;; PR B.80: window-classification + target-selection are pinned
  ;; by `decknix-agent-quickaction-window' (carved, +10 ERT).
  ;; Bulk evaluates the frame/window I/O signals and hands them
  ;; to the pure resolvers; returned target drives the
  ;; `display-buffer-alist' override below.
  (let* ((workspace (expand-file-name workspace))
         (cur (selected-window))
         (sidebar-buf (or (bound-and-true-p
                           agent-shell-workspace-sidebar-buffer-name)
                          "*agent-shell-sidebar*"))
         (cur-is-sidebar
          (decknix--quickaction-window-is-sidebar-p
           (window-parameter cur 'window-side)
           (window-dedicated-p cur)
           (buffer-name (window-buffer cur))
           sidebar-buf))
         (target-win
          (decknix--quickaction-target-window
           cur-is-sidebar cur (window-main-window (selected-frame))))
         (before-buffers (buffer-list))
         (augmented-cmd
          (append agent-shell-auggie-acp-command
                  (list "--workspace-root" workspace)))
         (config
          (let ((base (agent-shell-auggie-make-agent-config)))
            (setf (alist-get :client-maker base)
                  (eval `(lambda (buffer)
                           (agent-shell--make-acp-client
                            :command ,(car augmented-cmd)
                            :command-params ',(cdr augmented-cmd)
                            :environment-variables
                            (cond ((map-elt agent-shell-auggie-authentication :none)
                                   agent-shell-auggie-environment)
                                  ((map-elt agent-shell-auggie-authentication :login)
                                   agent-shell-auggie-environment)
                                  (t
                                   (error "Invalid Auggie authentication")))
                            :context-buffer buffer)) t))
            base)))
    ;; Placement prompt: when the caller is not the sidebar AND the
    ;; current frame has 3+ non-sidebar windows, ask which pane the
    ;; new session should land in (or split off).  The carved
    ;; `decknix--quickaction-window-candidates' returns nil for
    ;; single-pane / 2-pane / sidebar layouts so the existing
    ;; target-win fast-path passes through untouched.
    (unless cur-is-sidebar
      (let* ((descriptors
              (mapcar
               (lambda (w)
                 (let ((bn (buffer-name (window-buffer w))))
                   (list w bn (eq w cur)
                         (decknix--quickaction-window-is-sidebar-p
                          (window-parameter w 'window-side)
                          (window-dedicated-p w)
                          bn sidebar-buf))))
               (window-list nil 'no-minibuffer)))
             (cands (decknix--quickaction-window-candidates descriptors)))
        (when cands
          (let* ((labels (mapcar #'car cands))
                 (label (completing-read
                         "Quickaction placement: "
                         labels nil t nil nil (car labels)))
                 (entry (assoc label cands))
                 (action (nth 1 entry))
                 (anchor (nth 2 entry)))
            (when (and action (window-live-p anchor))
              (setq target-win
                    (pcase action
                      (:replace anchor)
                      (:split-right (split-window anchor nil 'right))
                      (:split-below (split-window anchor nil 'below))
                      (_ anchor))))))))
    ;; Override display-action to target the selected window,
    ;; preventing splits when called from sidebar or after
    ;; minibuffer exit.
    (let ((default-directory workspace)
          (agent-shell-display-action
           (eval `(cons (lambda (buffer alist)
                          (let ((win ,target-win))
                            (if (window-live-p win)
                                (window--display-buffer
                                 buffer win 'reuse alist)
                              (display-buffer-same-window buffer alist))))
                        nil)
                 t)))
      (agent-shell-start :config config))
    (setq decknix--agent-session-cache-time 0)
    (decknix--agent-session-new-post-create
     before-buffers name tags workspace command)
    ;; Find the newly created shell buffer and subscribe to prompt-ready.
    ;; agent-shell-start creates the buffer synchronously (mode-hook fires
    ;; before it returns), so find-new-shell-buffer works immediately.
    (let ((shell-buf (decknix--agent-find-new-shell-buffer before-buffers)))
      (when shell-buf
        (agent-shell-subscribe-to
         :shell-buffer shell-buf
         :event 'prompt-ready
         :on-event
         (eval `(lambda (_event)
                  (when (buffer-live-p ,shell-buf)
                    (with-current-buffer ,shell-buf
                      (goto-char (point-max))
                      (shell-maker-submit :input ,command))
                    (message "Sent: %s"
                             (truncate-string-to-width ,command 60))))
               t))))))


;; -- PR review quick action --

(defun decknix-agent-review-pr (url)
  "Start a PR review session for URL.
Parses the GitHub PR URL, creates a new session with auto-generated
name and tags, then sends /review-service-pr.  Metadata enrichment
\(author, Jira key, title\) is handled by the review command itself.

Interactively, prompts for URL (defaulting to clipboard if it
looks like a PR URL) and workspace (defaulting to current project)."
  (interactive
   (let* ((default-url (decknix--agent-clipboard-url))
          (url (read-string
                (if default-url
                    (format "PR URL [%s]: " default-url)
                  "PR URL: ")
                nil nil default-url)))
     (list url)))
  ;; Parse and validate
  (let ((parsed (decknix--agent-parse-pr-url url)))
    (unless parsed
      (user-error "Not a valid GitHub PR URL: %s" url))
    (let* ((owner (alist-get 'owner parsed))
           (repo (alist-get 'repo parsed))
           (number (alist-get 'number parsed))
           ;; Auto-generate session name: pr-<repo>-<number>
           (name (format "pr-%s-%s" repo number))
           ;; Tags: review + repo + PR number for distinguishability
           (tags (list "review" repo (format "#%s" number)))
           ;; Workspace: smart detection from PR URL
           ;; Priority: saved workspace → workspace-roots → project root → cwd
           (default-ws (decknix--agent-pr-detect-workspace owner repo))
           (workspace (read-directory-name
                       (format "Workspace for %s/%s#%s: "
                               owner repo number)
                       default-ws nil t))
           ;; Confirm name
           (name (read-string (format "Session name [%s]: " name)
                              nil nil name))
           (command (format "/review-service-pr %s" url)))
      (decknix--agent-quickaction-start name tags workspace command)
      (message "Starting review: %s/%s#%s" owner repo number))))


;; -- PR / repo linking interactive commands --

(defun decknix-agent-link-pr ()
  "Link a GitHub PR to the current session's conversation.
Prompts for URL (defaults to clipboard if it looks like a PR URL).
With prefix arg, prompts for PR type (authored/subject)."
  (interactive)
  (let* ((conv-key (decknix--agent-current-conv-key))
         (_ (unless conv-key
              (user-error "Not in an agent session buffer")))
         (default-url (decknix--clipboard-github-pr-url))
         (url (read-string
               (if default-url
                   (format "PR URL [%s]: "
                           (truncate-string-to-width default-url 50))
                 "PR URL: ")
               nil nil default-url))
         (_ (unless (decknix--agent-pr-parse-url url)
              (user-error "Not a valid GitHub PR URL")))
         (pr-type (if current-prefix-arg
                      (completing-read "Type: " '("authored" "subject")
                                       nil t nil nil "authored")
                    "authored")))
    (if (decknix--agent-link-pr conv-key url pr-type "manual")
        (progn
          (message "Linked %s PR: %s" pr-type url)
          (when (get-buffer "*agent-shell-sidebar*")
            (agent-shell-workspace-sidebar-refresh)))
      (message "PR already linked"))))

(defun decknix-agent-link-repo ()
  "Link a GitHub repo + branch to the current session's conversation.
Prompts for repo URL (defaults: clipboard if it looks like a repo URL,
or the session's workspace remote if it points at github.com) and
branch (defaulted via `decknix--detect-default-branch').

Use this for repos where work goes directly to a branch (no PR) — the
sidebar will show a commit row with HEAD SHA, age, CI status and DTSP
deploy indicator, sorted intermixed with PR rows by recency."
  (interactive)
  (let* ((conv-key (decknix--agent-current-conv-key))
         (_ (unless conv-key
              (user-error "Not in an agent session buffer")))
         (workspace (decknix--agent-workspace-for-conv-key conv-key))
         (ws-remote (when (and workspace (file-directory-p workspace))
                      (decknix--git-remote-url workspace)))
         (clip-url (decknix--clipboard-github-repo-url))
         (default-url (or clip-url ws-remote))
         (url (read-string
               (if default-url
                   (format "Repo URL [%s]: "
                           (truncate-string-to-width default-url 50))
                 "Repo URL: ")
               nil nil default-url))
         (_ (unless (decknix--agent-repo-parse-url url)
              (user-error "Not a valid GitHub repo URL (maybe a PR URL?)")))
         (default-branch
           (or (when (and workspace (file-directory-p workspace))
                 (decknix--detect-default-branch workspace))
               "main"))
         (branch (read-string (format "Branch [%s]: " default-branch)
                              nil nil default-branch)))
    (if (decknix--agent-link-repo conv-key url branch "manual")
        (progn
          (message "Linked repo: %s@%s" url branch)
          (when (get-buffer "*agent-shell-sidebar*")
            (agent-shell-workspace-sidebar-refresh)))
      (message "Repo+branch already linked"))))

(defun decknix-agent-unlink-pr ()
  "Unlink a GitHub PR or repo from the current session's conversation.
Both PRs and repo links surface in the same picker so you can unlink
either via a single command."
  (interactive)
  (let* ((conv-key (decknix--agent-current-conv-key))
         (_ (unless conv-key
              (user-error "Not in an agent session buffer")))
         (linked (decknix--agent-linked-items conv-key)))
    (if (not linked)
        (message "No linked items")
      (let* ((entries
              (mapcar
               (lambda (rec)
                 (let* ((url (decknix--agent-pr-url-accessor rec "url"))
                        (tp (or (decknix--agent-pr-url-accessor rec "type")
                                "authored"))
                        (branch (decknix--agent-pr-url-accessor rec "branch"))
                        (label (if (equal tp "repo")
                                   (format "[repo:%s] %s"
                                           (or branch "?") url)
                                 (format "[%s] %s" tp url))))
                   (cons label (cons rec url))))
               linked))
             (choice (completing-read "Unlink item: "
                                      (mapcar #'car entries) nil t))
             (pair (cdr (assoc choice entries)))
             (rec (car pair))
             (url (cdr pair))
             (tp (decknix--agent-pr-url-accessor rec "type"))
             (branch (decknix--agent-pr-url-accessor rec "branch")))
        (if (equal tp "repo")
            (decknix--agent-unlink-repo conv-key url branch)
          (decknix--agent-unlink-pr conv-key url))
        (message "Unlinked: %s" url)
        (when (get-buffer "*agent-shell-sidebar*")
          (agent-shell-workspace-sidebar-refresh))))))


(provide 'decknix-agent-shell-main-link)
;;; decknix-agent-shell-main-link.el ends here
