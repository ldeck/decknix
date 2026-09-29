;;; decknix-agent-session-model.el --- Per-conversation auggie model overrides -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-store "0.1"))
;; Keywords: agent, agent-shell, decknix, persistence, model

;;; Commentary:
;;
;; Per-conversation model override layer extracted from the
;; agent-shell heredoc (main-bulk).  The global default model for
;; new sessions lives in `~/.augment/settings.json' (declared via
;; `decknix.cli.auggie.settings.model').  Any per-conversation
;; override the user makes mid-session with `C-c C-v' is persisted
;; here against the conv-key inside the same
;; `~/.config/decknix/agent-sessions.json' store as tags / linked
;; PRs / saved workspaces, so resume-time we can pass `--model
;; <id>' to auggie and continue on the same agent.
;;
;; Two entry points:
;;
;;   `decknix--agent-session-model-for-conv-key'
;;       Return the saved model-id for CONV-KEY, or nil when no
;;       override has been recorded.  Read by the resume path in
;;       main-bulk to compute the `--model' arg.
;;   `decknix--agent-session-save-model-for-conv-key'
;;       Persist MODEL-ID for CONV-KEY.  Creates the conversation
;;       entry if it doesn't exist (with empty tags / sessions
;;       lists, matching the shape used by the other accessors).
;;       Called from the on-success callback of the interactive
;;       `decknix-agent-set-session-model' command -- which itself
;;       stays in the heredoc per AGENTS.md Rule 2 because it
;;       wraps the upstream `agent-shell-set-session-model' UI
;;       verb.

;;; Code:

(require 'decknix-agent-tags-store)
(require 'map)

(defun decknix--agent-model-id-from-state (state)
  "Return the model id from agent-shell STATE, or nil.  Pure.

Reads `:config-options' first.  The adapter reports the live model as the
`model' config option's `:current-value'; `(:session :model-id)' is nil in
current builds, which is why the save-on-change callback silently recorded
nothing -- its `when' guard never passed, for any provider.  The old path is
still tried second so an older adapter keeps working."
  (or (let ((options (alist-get :config-options state))
            (found nil))
        (dolist (opt options)
          (when (and (not found) (equal (alist-get :id opt) "model"))
            (setq found (alist-get :current-value opt))))
        (and (stringp found) (not (string-empty-p found)) found))
      (let ((legacy (ignore-errors
                      (map-nested-elt state '(:session :model-id)))))
        (and (stringp legacy) (not (string-empty-p legacy)) legacy))))

(declare-function agent-shell--state "agent-shell" ())

(defun decknix--agent-session-current-model-id ()
  "Return the current buffer's live model id, or nil."
  (decknix--agent-model-id-from-state (ignore-errors (agent-shell--state))))

(defun decknix-agent-session-sync-model ()
  "Record this buffer's LIVE model as the conversation's pin.

For conversations whose model was changed while the save callback was
reading a state path that no longer exists: the change took effect in the
session but was never written, so the header and the resume path both still
report the old model."
  (interactive)
  (let ((conv-key (bound-and-true-p decknix--agent-conv-key))
        (live (decknix--agent-session-current-model-id)))
    (cond
     ((not (and conv-key live))
      (message "No live model to record for this buffer"))
     ((equal live (decknix--agent-session-model-for-conv-key conv-key))
      (message "Model already recorded: %s" live))
     (t
      (decknix--agent-session-save-model-for-conv-key conv-key live)
      (message "Model %s recorded for this conversation" live)))))

(defun decknix--agent-session-model-for-conv-key (conv-key)
  "Return saved auggie model-id for CONV-KEY, or nil."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (gethash "model" entry)))))

(defun decknix--agent-session-save-model-for-conv-key
    (conv-key model-id)
  "Persist auggie MODEL-ID for CONV-KEY in agent-sessions.json."
  (when (and conv-key model-id)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "tags" nil h)
                        (puthash "sessions" nil h)
                        h))))
      (puthash "model" model-id entry)
      (puthash conv-key entry convs)
      (decknix--agent-tags-write store))))

;; -- bulk re-pinning across conversations ---------------------------
;;
;; A saved model is a pin, and `decknix--agent-model-replay-reconcile'
;; re-applies it on every resume for as long as the session still
;; advertises it.  That is correct -- it is what "set the model for this
;; conversation" means -- but it also means a conversation started on an
;; older model stays there for life, and there was no way to move a
;; backlog of them forward short of resuming each one and pressing
;; `C-c C-v'.  183 of 573 conversations were pinned to `claude-opus-4-8'
;; when this was written.

(defun decknix--agent-model-migration-plan (convs from to)
  "Pure: conv-keys in CONVS pinned to FROM and therefore due to become TO.

Separate from the write so the count can be shown BEFORE anything is
rewritten: this edits the same store that holds tags, linked PRs and
saved workspaces, and a silent bulk rewrite of it is not something to
offer without a number attached.

Sorted, so a dry run and the write that follows agree on order.  Entries
with no pin are absent by design: they already follow the provider
default, so re-pinning them would REMOVE the freedom to move with it."
  (when (and (hash-table-p convs) (stringp from) (stringp to)
             (not (string-empty-p from)) (not (string-empty-p to))
             (not (string= from to)))
    (let (keys)
      (maphash (lambda (k entry)
                 (when (and (hash-table-p entry)
                            (equal (gethash "model" entry) from))
                   (push k keys)))
               convs)
      (sort keys #'string<))))

(defun decknix--agent-models-in-store (convs)
  "Pure: alist of (MODEL-ID . COUNT) actually pinned across CONVS.
Offered as completion candidates so the migration is driven by what is
really in the store rather than by a list of ids typed from memory."
  (when (hash-table-p convs)
    (let ((counts nil))
      (maphash (lambda (_k entry)
                 (when (hash-table-p entry)
                   (let ((model (gethash "model" entry)))
                     (when (and (stringp model) (not (string-empty-p model)))
                       (let ((cell (assoc model counts)))
                         (if cell
                             (setcdr cell (1+ (cdr cell)))
                           (push (cons model 1) counts)))))))
               convs)
      (sort counts (lambda (a b) (> (cdr a) (cdr b)))))))

(defun decknix-agent-migrate-pinned-model (from to)
  "Re-pin every conversation currently pinned to FROM so it uses TO.

Interactively, FROM completes from the models actually present in the
store (with counts) and TO from the same list plus free entry, so moving
a backlog onto a new model is one command rather than one resume per
conversation.

Only the stored pin changes.  A LIVE session keeps the model its ACP
session was started with until it is set again -- use `C-c C-v' there,
which sets and persists in one step.  Conversations with no pin are left
alone: they already track the provider default, and pinning them would
take away that freedom.

The store's own writer keeps a rolling `agent-sessions.json.bak', so the
previous state survives one bad call."
  (interactive
   (let* ((store (decknix--agent-tags-read))
          (convs (decknix--agent-tags-conversations store))
          (present (decknix--agent-models-in-store convs))
          (candidates (mapcar (lambda (cell)
                                (format "%s  (%d)" (car cell) (cdr cell)))
                              present))
          (from-raw (completing-read "Re-pin conversations FROM model: "
                                     candidates nil nil))
          (from (car (split-string from-raw "  (")))
          (to (completing-read (format "Re-pin %s TO model: " from)
                               (mapcar #'car present) nil nil)))
     (list from to)))
  (let* ((store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store))
         (plan (decknix--agent-model-migration-plan convs from to)))
    (cond
     ((null plan)
      (message "No conversations pinned to %s%s" from
               (if (string= from to) " (from and to are the same)" "")))
     ((not (yes-or-no-p (format "Re-pin %d conversation%s from %s to %s? "
                                (length plan)
                                (if (= 1 (length plan)) "" "s")
                                from to)))
      (message "Model migration cancelled"))
     (t
      (dolist (key plan)
        (let ((entry (gethash key convs)))
          (when (hash-table-p entry)
            (puthash "model" to entry))))
      ;; One write for the whole batch: the writer rotates a backup on
      ;; every call, so writing per conversation would push the pre-change
      ;; state out of the single backup slot it keeps.
      (decknix--agent-tags-write store)
      (message "Re-pinned %d conversation%s from %s to %s"
               (length plan)
               (if (= 1 (length plan)) "" "s") from to)))))

(provide 'decknix-agent-session-model)
;;; decknix-agent-session-model.el ends here
