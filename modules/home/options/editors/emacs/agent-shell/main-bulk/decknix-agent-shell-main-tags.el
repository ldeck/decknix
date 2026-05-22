;;; decknix-agent-shell-main-tags.el --- Session metadata: tags, identity, model, links, rename, id-display -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; The conversation-scoped metadata layer of agent-shell.  Owns the
;; interactive tag commands, per-session model persistence helper,
;; PR/repo linking helpers (forward-decls), VCS detection helpers
;; (forward-decls), tags aggregation, session-id accessors, the
;; rename-session command, and the session-id display ops
;; (full / short, copy, toggle).
;;
;; PR Split.S.4: split out of `decknix-agent-shell-main' so the
;; ~2700-line bulk file can be navigated by theme.  Co-resident
;; with the main file in `main-bulk/'.  All pure layers
;; (`decknix-agent-tags-{store,read,mutate}',
;; `decknix-agent-conv-{resolve,recency}',
;; `decknix-agent-session-{workspace,model,id}',
;; `decknix-agent-link-store', `decknix-agent-vcs',
;; `decknix-agent-url-parse') already live in their own carved +
;; ERT-tested packages.  This file owns the side-effecting
;; orchestration: the interactive entry points, the consult /
;; completing-read / yes-or-no-p UI flows, and the
;; agent-shell-mode header refresh adapters.  Side-effecting
;; `(define-key)' bindings into the heredoc's prefix maps still
;; happen in the heredoc itself (per AGENTS.md Rule 2).
;;
;; Forward-declarations for symbols defined in carved packages,
;; in `decknix-agent-shell-main' proper, or in the heredoc are
;; kept inline at the head of each `;; --' subsection so the
;; original structure of the bulk file is preserved.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Forward-declarations for upstream agent-shell + the main-resident
;; / heredoc-resident state that the body below references.
(declare-function agent-shell-set-session-model "ext:agent-shell")
(declare-function agent-shell--state "ext:agent-shell")
(defvar decknix--agent-conv-key)
(defvar decknix--agent-auggie-session-id)
(defvar agent-shell--header-cache)


;; `decknix--agent-tags-file' (path to ~/.config/decknix/agent-sessions.json)
;; moved out of this heredoc into agent-shell/agent/decknix-agent-tags-store.el
;; alongside the cache state and the read/write/conversations triple.
;; Required by the heredoc immediately after the conversation-key /
;; session-cache modules so callers in this file resolve at load time.
(defvar decknix--agent-tags-file)

;; Conversation-key derivation + mergedInto resolution (PR B.34) —
;; moved out of this heredoc into
;; agent-shell/agent/decknix-agent-conv-resolve.el, packaged as
;; `decknix-agent-conv-resolve-el'.  Owns the canonical
;; `decknix--agent-conversation-key' (raw hash → mergedInto
;; resolution), the redirect-walker `decknix--agent-conv-resolve-key',
;; and the two session-aware lookups
;; (`decknix--agent-conversation-key-for-session' /
;; `decknix--agent-latest-session-id-for-conv-key').
(declare-function decknix--agent-conversation-key
                  "decknix-agent-conv-resolve" (first-message))
(declare-function decknix--agent-conv-resolve-key
                  "decknix-agent-conv-resolve" (conv-key))
(declare-function decknix--agent-conversation-key-for-session
                  "decknix-agent-conv-resolve" (session-id))
(declare-function decknix--agent-latest-session-id-for-conv-key
                  "decknix-agent-conv-resolve" (conv-key))

;; Tag store storage layer (PR B.28) — moved out of this heredoc into
;; agent-shell/agent/decknix-agent-tags-store.el.
(defvar decknix--agent-tags-cache)
(defvar decknix--agent-tags-cache-mtime)
(defvar decknix--agent-tags-cache-checked-at)
(defvar decknix--agent-tags-cache-ttl)
(declare-function decknix--agent-tags-read
                  "decknix-agent-tags-store" ())
(declare-function decknix--agent-tags-write
                  "decknix-agent-tags-store" (store))
(declare-function decknix--agent-tags-conversations
                  "decknix-agent-tags-store" (store))

;; -- Per-conversation lastAccessed stamp (PR B.42) --
;; Moved into agent-shell/agent/decknix-agent-conv-recency.el.
(declare-function decknix--agent-conv-touch
                  "decknix-agent-conv-recency" (conv-key))
(declare-function decknix--agent-conv-last-accessed
                  "decknix-agent-conv-recency" (conv-key))

;; -- Tags read accessors (PR B.43) --
;; Moved into agent-shell/agent/decknix-agent-tags-read.el.
(declare-function decknix--agent-tags-for-session
                  "decknix-agent-tags-read" (session-id))
(declare-function decknix--agent-tags-for-conv-key
                  "decknix-agent-tags-read" (conv-key))

;; -- Tags mutators (PR B.70) --
;; Moved into agent-shell/agent/decknix-agent-tags-mutate.el.
(declare-function decknix--agent-tags-set
                  "decknix-agent-tags-mutate" (conv-key tags))
(declare-function decknix--agent-tags-set-current-conversation
                  "decknix-agent-tags-mutate" (tags))

;; -- Per-conversation workspace persistence (PR B.40) --
;; Moved into agent-shell/agent/decknix-agent-session-workspace.el.
(declare-function decknix--agent-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key))
(declare-function decknix--agent-session-save-workspace
                  "decknix-agent-session-workspace" (session-id workspace))
(declare-function decknix--agent-session-save-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key workspace))

;; -- Per-session model persistence (PR B.37) --
;; Moved into agent-shell/agent/decknix-agent-session-model.el.
;; The interactive `decknix-agent-set-session-model' command stays
;; here per AGENTS.md Rule 2 -- it wraps the upstream
;; `agent-shell-set-session-model' UI verb whose on-success callback
;; calls into the module's `save' primitive.
(declare-function decknix--agent-session-model-for-conv-key
                  "decknix-agent-session-model" (conv-key))
(declare-function decknix--agent-session-save-model-for-conv-key
                  "decknix-agent-session-model" (conv-key model-id))

;; -- Session file path helper --
;; Defined in agent-shell/agent/decknix-agent-session-history.el.
(declare-function decknix--agent-session-file
                  "decknix-agent-session-history" (session-id))

(defun decknix-agent-set-session-model ()
  "Change the model for the current agent-shell session and persist it.
Wraps `agent-shell-set-session-model' with an on-success callback
that records the new model-id against the current conversation in
agent-sessions.json so subsequent resumes pass `--model <id>' to
auggie.

The current model is annotated with \" ← current\" in the picker so
it is immediately visible when browsing candidates."
  (interactive)
  ;; `completion-extra-properties' is a dynamically-scoped special
  ;; variable (defvar'd by Emacs core), so this let-binding is active
  ;; inside the upstream completing-read call even though this file
  ;; uses lexical-binding.
  (let* ((current-model-id (map-nested-elt (agent-shell--state)
                                           '(:session :model-id)))
         (completion-extra-properties
          (when current-model-id
            (list :annotation-function
                  (lambda (candidate)
                    (when (string-match-p (regexp-quote current-model-id)
                                         candidate)
                      " ← current"))))))
    (agent-shell-set-session-model
     (eval `(lambda ()
              (let ((model-id (map-nested-elt
                               (agent-shell--state)
                               '(:session :model-id)))
                    (conv-key (bound-and-true-p
                               decknix--agent-conv-key)))
                (when (and conv-key model-id)
                  (decknix--agent-session-save-model-for-conv-key
                   conv-key model-id)
                  (message "Model %s saved for this conversation"
                           model-id))))
           t))))

;; -- PR / repo linking: store/retrieve linked items per conversation --
;; Source moved into agent-shell/agent/decknix-agent-link-store.el.
;; Hub-side post-mutation callbacks (write-linked-prs / pr-fetch-async /
;; repo-fetch-async) are gated through `fboundp' inside the module.
(declare-function decknix--agent-linked-items "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-linked-prs   "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-linked-repos "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-link-pr      "decknix-agent-link-store"
                  (conv-key url &optional pr-type added))
(declare-function decknix--agent-unlink-pr    "decknix-agent-link-store" (conv-key url))
(declare-function decknix--agent-link-repo    "decknix-agent-link-store"
                  (conv-key url branch &optional added))
(declare-function decknix--agent-unlink-repo  "decknix-agent-link-store"
                  (conv-key url branch))

;; -- VCS detection helpers (used by repo-linking commands) --
;; Moved into agent-shell/agent/decknix-agent-vcs.el.
(declare-function decknix--git-remote-url "decknix-agent-vcs")
(declare-function decknix--detect-default-branch "decknix-agent-vcs")

;; -- Tags aggregation (PR B.44) --
;; `decknix--agent-tags-all' moved into the existing
;; `decknix-agent-tags-read' module.
(declare-function decknix--agent-tags-all
                  "decknix-agent-tags-read")

;; -- Session-id + conv-key accessors (PR B.48) --
;; Moved into agent-shell/agent/decknix-agent-session-id.el.
;; The buffer-local `decknix--agent-auggie-session-id' defvar
;; itself stays in the heredoc (initialised by the agent-shell
;; startup hook -- a side-effect that belongs there by Rule 2).
(declare-function decknix--agent-current-session-id
                  "decknix-agent-session-id")
(declare-function decknix--agent-require-session-id
                  "decknix-agent-session-id")
(declare-function decknix--agent-require-conv-key
                  "decknix-agent-session-id")

;; Carved session-list helpers used by tag-list / tag-cleanup.
(declare-function decknix--agent-session-list
                  "decknix-agent-sessions-cache")
(declare-function decknix--agent-session-group-by-conversation
                  "decknix-agent-session-list" (sessions))
(declare-function decknix--agent-session-preview
                  "decknix-agent-session-list" (session))
(declare-function decknix--agent-session-display-name
                  "decknix-agent-session-list" (session))

;; Symbols owned by `decknix-agent-shell-main' proper that the
;; tag-list / tag-cleanup paths shell into.
(declare-function decknix--agent-unsorted-table
                  "decknix-agent-shell-main" (candidates))
(declare-function decknix--agent-session-resume
                  "decknix-agent-shell-main"
                  (session-id history-count
                              &optional display-name keep-current conv-key))
(defvar decknix-agent-session-history-count)

(defun decknix-agent-tag-show ()
  "Show the tags for the current conversation."
  (interactive)
  (let* ((session-id (decknix--agent-require-session-id))
         (tags (decknix--agent-tags-for-session session-id)))
    (if tags
        (message "Conversation tags: [%s]" (string-join tags ", "))
      (message "No tags on this conversation"))))

(defun decknix-agent-tag-add ()
  "Add tags to the current conversation.
Accepts comma-separated input for multiple tags at once — completion
re-fires after each comma so subsequent tags can be picked from the
same set.  Shows all existing tags for completion; type new names to
create them.  Already-applied tags are annotated `(applied)'."
  (interactive)
  (let* ((conv-key (decknix--agent-require-conv-key))
         (session-id (decknix--agent-require-session-id))
         (existing (decknix--agent-tags-all))
         (current (decknix--agent-tags-for-conv-key conv-key))
         ;; Show which tags are already applied via annotation
         (annotator (eval
                     `(lambda (tag)
                        (if (member tag ',current) " (applied)" ""))
                     t))
         ;; completing-read-multiple invokes completion for each
         ;; entry between `crm-separator' (defaults to `,' with
         ;; optional surrounding whitespace), returning a list of
         ;; strings.  Replaces the prior single completing-read +
         ;; split-string approach which only completed the first tag.
         (input (let ((completion-extra-properties
                       (list :annotation-function annotator)))
                  (completing-read-multiple
                   "Add tag(s) (comma-separated): "
                   existing nil nil)))
         ;; Defensive: trim whitespace, remove empties.  CRM already
         ;; trims via `crm-separator', but a stray empty entry from
         ;; a trailing comma would otherwise become a "" tag.
         (new-tags (seq-remove #'string-empty-p
                               (mapcar #'string-trim input))))
    (unless new-tags
      (user-error "No tags provided"))
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "tags" nil h)
                        (puthash "sessions" nil h)
                        h)))
           (tags (gethash "tags" entry))
           (sids (gethash "sessions" entry))
           (added nil)
           (skipped nil))
      ;; Add each tag, tracking what was added vs already present
      (dolist (tag new-tags)
        (if (member tag tags)
            (push tag skipped)
          (setq tags (append tags (list tag)))
          (push tag added)))
      (puthash "tags" tags entry)
      ;; Track this session in the conversation
      (cl-pushnew session-id sids :test #'string=)
      (puthash "sessions" sids entry)
      ;; Bump recency so this conversation sorts to the top
      (puthash "lastAccessed"
               (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry)
      (puthash conv-key entry convs)
      (decknix--agent-tags-write store)
      ;; Report what happened
      (cond
       ((and added (not skipped))
        (message "Tagged: %s → [%s]"
                 (string-join (nreverse added) ", ")
                 (string-join tags ", ")))
       ((and added skipped)
        (message "Tagged: %s (already had: %s) → [%s]"
                 (string-join (nreverse added) ", ")
                 (string-join (nreverse skipped) ", ")
                 (string-join tags ", ")))
       (t
        (message "All tags already applied: [%s]"
                 (string-join tags ", ")))))))

(defun decknix-agent-tag-remove ()
  "Remove a tag from the current conversation."
  (interactive)
  (let* ((conv-key (decknix--agent-require-conv-key))
         (current (decknix--agent-tags-for-conv-key conv-key)))
    (unless current
      (user-error "This conversation has no tags"))
    (let* ((tag (completing-read "Remove tag: " current nil t))
           (store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs))
           (remaining (remove tag (gethash "tags" entry))))
      (if remaining
          (progn
            (puthash "tags" remaining entry)
            (puthash "lastAccessed"
                     (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry))
        (remhash conv-key convs))
      (decknix--agent-tags-write store)
      (message "Removed \"%s\" from conversation" tag))))

(defun decknix-agent-tag-list ()
  "List conversations filtered by tag.
Prompts for a tag, then shows the latest session per matching conversation."
  (interactive)
  (let* ((all-tags (decknix--agent-tags-all)))
    (unless all-tags
      (user-error "No tags defined yet"))
    (let* ((tag (completing-read "Filter by tag: " all-tags nil t))
           (store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (sessions (decknix--agent-session-list))
           (conv-groups (decknix--agent-session-group-by-conversation sessions))
           (matching nil))
      ;; Find conversations with this tag
      (maphash (lambda (conv-key entry)
                 (when (and (hash-table-p entry)
                            (member tag (gethash "tags" entry)))
                   (push conv-key matching)))
               convs)
      (unless matching
        (user-error "No conversations tagged \"%s\"" tag))
      ;; Build picker from latest session per matching conversation
      (let* ((entries
              (cl-loop for conv-key in matching
                       for group = (seq-find
                                    (lambda (g) (string= (car g) conv-key))
                                    conv-groups)
                       when group
                       collect (let* ((latest (cadr group))
                                      (tags (decknix--agent-tags-for-conv-key conv-key))
                                      (tag-str (if tags (format " [%s]" (string-join tags ", ")) "")))
                                 (cons (format "%s%s"
                                               (decknix--agent-session-preview latest)
                                               tag-str)
                                       (cons 'session latest))))))
        (unless entries
          (user-error "No sessions found for tag \"%s\"" tag))
        (let* ((selection (completing-read
                           (format "Conversations tagged \"%s\": " tag)
                           (decknix--agent-unsorted-table
                            (mapcar #'car entries)) nil t))
               (chosen (cdr (assoc selection entries)))
               (session (cdr chosen))
               (session-id (alist-get 'sessionId session)))
          (let ((conv-key (decknix--agent-conversation-key
                           (alist-get 'firstUserMessage
                                      session ""))))
            (decknix--agent-session-resume
             session-id
             decknix-agent-session-history-count
             (decknix--agent-session-display-name session)
             nil conv-key)))))))

(defun decknix-agent-tag-edit ()
  "Rename a tag across all conversations."
  (interactive)
  (let* ((all-tags (decknix--agent-tags-all)))
    (unless all-tags
      (user-error "No tags defined yet"))
    (let* ((old-tag (completing-read "Rename tag: " all-tags nil t))
           (new-tag (string-trim
                     (read-string (format "Rename \"%s\" to: " old-tag) old-tag)))
           (store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (count 0))
      (when (string-empty-p new-tag)
        (user-error "Tag cannot be empty"))
      (when (string= old-tag new-tag)
        (user-error "Same name, nothing to do"))
      (maphash (lambda (_key entry)
                 (when (hash-table-p entry)
                   (let ((tags (gethash "tags" entry)))
                     (when (member old-tag tags)
                       (puthash "tags"
                                (mapcar (lambda (tg) (if (string= tg old-tag) new-tag tg)) tags)
                                entry)
                       (cl-incf count)))))
               convs)
      (decknix--agent-tags-write store)
      (message "Renamed \"%s\" → \"%s\" across %d conversation%s"
               old-tag new-tag count (if (= count 1) "" "s")))))

(defun decknix-agent-tag-delete ()
  "Delete a tag from all conversations."
  (interactive)
  (let* ((all-tags (decknix--agent-tags-all)))
    (unless all-tags
      (user-error "No tags defined yet"))
    (let* ((tag (completing-read "Delete tag globally: " all-tags nil t)))
      (when (y-or-n-p (format "Delete tag \"%s\" from all conversations? " tag))
        (let* ((store (decknix--agent-tags-read))
               (convs (decknix--agent-tags-conversations store))
               (count 0)
               (empties nil))
          (maphash (lambda (key entry)
                     (when (hash-table-p entry)
                       (let ((tags (gethash "tags" entry)))
                         (when (member tag tags)
                           (let ((remaining (remove tag tags)))
                             (if remaining
                                 (puthash "tags" remaining entry)
                               (push key empties)))
                           (cl-incf count)))))
                   convs)
          (dolist (key empties) (remhash key convs))
          (decknix--agent-tags-write store)
          (message "Deleted \"%s\" from %d conversation%s"
                   tag count (if (= count 1) "" "s")))))))

(defun decknix-agent-tag-cleanup ()
  "Remove conversation entries that have no matching sessions on disk."
  (interactive)
  (let* ((store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store))
         (sessions (decknix--agent-session-list))
         (conv-groups (decknix--agent-session-group-by-conversation sessions))
         (live-keys (mapcar #'car conv-groups))
         (orphans nil))
    (maphash (lambda (key _entry)
               (unless (member key live-keys)
                 (push key orphans)))
             convs)
    (if orphans
        (when (y-or-n-p (format "Remove %d orphaned conversation tag%s? "
                                (length orphans)
                                (if (= (length orphans) 1) "" "s")))
          (dolist (key orphans) (remhash key convs))
          (decknix--agent-tags-write store)
          (message "Cleaned up %d orphaned conversation%s"
                   (length orphans)
                   (if (= (length orphans) 1) "" "s")))
      (message "No orphaned conversations found"))))

;; == Rename session/conversation ==
;; Persists the name into agent-sessions.json tags so it survives
;; restarts and appears correctly in the sidebar and picker.

(declare-function agent-shell-workspace-sidebar-refresh
                  "ext:agent-shell-workspace")
(defvar shell-maker--buffer-name-override)

(defun decknix-agent-session-rename (new-name)
  "Rename the current conversation to NEW-NAME.
Updates the tags in agent-sessions.json (replacing all existing tags
with the new name) and renames the live buffer.  Works from any
agent-shell buffer."
  (interactive
   (let* ((conv-key (decknix--agent-require-conv-key))
          (current-tags (decknix--agent-tags-for-conv-key conv-key))
          (default (string-join current-tags "/")))
     (list (read-string (format "Rename conversation%s: "
                                (if (string-empty-p default) ""
                                  (format " (%s)" default)))
                        default))))
  (when (string-empty-p (string-trim new-name))
    (user-error "Name cannot be empty"))
  (let* ((conv-key (decknix--agent-require-conv-key))
         (session-id (decknix--agent-require-session-id))
         (store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store))
         (entry (or (gethash conv-key convs)
                    (let ((h (make-hash-table :test 'equal)))
                      (puthash "tags" nil h)
                      (puthash "sessions" nil h)
                      h)))
         (sids (gethash "sessions" entry))
         ;; Split new-name on "/" or "," to allow multi-tag names
         (new-tags (seq-remove #'string-empty-p
                               (mapcar #'string-trim
                                       (split-string new-name "[/,]" t)))))
    ;; Update tags
    (puthash "tags" new-tags entry)
    (cl-pushnew session-id sids :test #'string=)
    (puthash "sessions" sids entry)
    ;; Bump recency
    (puthash "lastAccessed"
             (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry)
    (puthash conv-key entry convs)
    (decknix--agent-tags-write store)
    ;; Rename the live buffer
    (let ((display (string-join new-tags "/")))
      (rename-buffer (format "*Auggie: %s*" display) t)
      (when (boundp 'shell-maker--buffer-name-override)
        (setq shell-maker--buffer-name-override (buffer-name)))
      ;; Refresh sidebar if visible
      (when (fboundp 'agent-shell-workspace-sidebar-refresh)
        (ignore-errors (agent-shell-workspace-sidebar-refresh)))
      (message "Renamed conversation → %s" display))))

;; == Session ID: shortened display, copy, toggle ==

(defvar decknix--agent-show-full-session-id nil
  "When non-nil, show the full session ID in the header.
When nil (default), show only the first 8 characters.")

(defun decknix--agent-get-session-id ()
  "Return the current ACP session ID, or nil."
  (when (derived-mode-p 'agent-shell-mode)
    (map-nested-elt (agent-shell--state) '(:session :id))))

(defun decknix-agent-session-copy-id (&optional full)
  "Copy the session ID to the kill ring.
With prefix argument FULL (\\[universal-argument]), copy the full ID.
Otherwise copy the shortened 8-character hash."
  (interactive "P")
  (if-let ((id (decknix--agent-get-session-id)))
      (let ((result (if full id
                     (substring id 0 (min 8 (length id))))))
        (kill-new result)
        (message "Copied: %s" result))
    (user-error "No active session")))

(defun decknix-agent-session-toggle-id-display ()
  "Toggle between showing short (8-char) and full session ID in the header."
  (interactive)
  (setq decknix--agent-show-full-session-id
        (not decknix--agent-show-full-session-id))
  ;; Force header refresh
  (when (derived-mode-p 'agent-shell-mode)
    (setq-local agent-shell--header-cache (make-hash-table :test 'equal))
    (force-mode-line-update))
  (message "Session ID display: %s"
           (if decknix--agent-show-full-session-id "full" "short (8 chars)")))


;; -- Session info display (C-c s i) --

(defun decknix-agent-session-info ()
  "Display information about the current agent-shell session in the minibuffer.
Shows: session ID, conversation key, model, tags, workspace, and
timestamps (created, last modified, exchange count) from the session JSON.

Bound to \\[decknix-agent-session-info] in agent-shell buffers."
  (interactive)
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (let* ((session-id (or (and (boundp 'decknix--agent-auggie-session-id)
                              decknix--agent-auggie-session-id)
                         (ignore-errors
                           (map-nested-elt (agent-shell--state)
                                           '(:session :id)))))
         (conv-key   (and (boundp 'decknix--agent-conv-key)
                          decknix--agent-conv-key))
         (workspace  (and (boundp 'decknix--agent-session-workspace)
                          decknix--agent-session-workspace))
         ;; Prefer live ACP state (model-id + human name) over the
         ;; persisted override so the display always reflects reality.
         (live-model-id (ignore-errors
                          (map-nested-elt (agent-shell--state)
                                         '(:session :model-id))))
         (live-models   (ignore-errors
                          (map-nested-elt (agent-shell--state)
                                         '(:session :models))))
         (live-model-name (when live-model-id
                            (map-elt (seq-find
                                      (lambda (m)
                                        (string= (map-elt m :model-id)
                                                 live-model-id))
                                      live-models)
                                     :name)))
         (persisted-model (and conv-key
                               (decknix--agent-session-model-for-conv-key conv-key)))
         ;; Show "name (id)" when we have a name, else just the id or override.
         (model      (cond
                      (live-model-name (format "%s (%s)" live-model-name live-model-id))
                      (live-model-id   live-model-id)
                      (persisted-model persisted-model)))
         (tags       (and conv-key
                          (decknix--agent-tags-for-conv-key conv-key)))
         ;; Read session JSON for timestamps + exchange count
         (json-data  (when session-id
                       (condition-case nil
                           (let* ((json-array-type 'list)
                                  (json-object-type 'alist)
                                  (json-key-type 'symbol)
                                  (file (decknix--agent-session-file session-id)))
                             (when (file-exists-p file)
                               (json-read-file file)))
                         (error nil))))
         (created    (when json-data (alist-get 'created json-data)))
         (modified   (when json-data (alist-get 'modified json-data)))
         (exchanges  (when json-data (alist-get 'exchangeCount json-data 0)))
         ;; Format helpers
         (fmt-time   (lambda (iso)
                       (if (and iso (stringp iso) (> (length iso) 0))
                           (condition-case nil
                               (format-time-string
                                "%Y-%m-%d %H:%M"
                                (date-to-time iso))
                             (error iso))
                         "unknown")))
         (id-display (if session-id
                         (substring session-id 0 (min 16 (length session-id)))
                       "none"))
         (key-display (if conv-key
                          (substring conv-key 0 (min 16 (length conv-key)))
                        "none")))
    (message
     (concat "Session: %s  Conv: %s\n"
             "Model: %s  Exchanges: %s\n"
             "Tags: %s\n"
             "Workspace: %s\n"
             "Created: %s  Modified: %s")
     id-display
     key-display
     (or model "default")
     (or (and exchanges (number-to-string exchanges)) "?")
     (if tags (mapconcat (lambda (tag) (format "#%s" tag)) tags " ") "none")
     (or workspace "none")
     (funcall fmt-time created)
     (funcall fmt-time modified))))

(provide 'decknix-agent-shell-main-tags)
;;; decknix-agent-shell-main-tags.el ends here
