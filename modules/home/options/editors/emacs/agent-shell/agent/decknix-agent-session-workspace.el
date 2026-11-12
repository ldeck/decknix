;;; decknix-agent-session-workspace.el --- Per-conversation workspace persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-store "0.1") (decknix-agent-conv-resolve "0.1"))
;; Keywords: agent, agent-shell, decknix, persistence, workspace

;;; Commentary:
;;
;; Per-conversation workspace-directory persistence layer carved
;; out of the agent-shell heredoc (main-bulk).  Workspaces live
;; in the same `~/.config/decknix/agent-sessions.json' store as
;; tags / linked PRs / per-session model overrides, keyed by the
;; conversation key (16-char hash of the first user message); on
;; resume the path is read back so auggie can be relaunched with
;; `--workspace-root' and `default-directory' set to the original
;; project, even if the daemon has been restarted in the
;; meantime.
;;
;; Three entry points:
;;
;;   `decknix--agent-workspace-for-conv-key'
;;       Return the saved workspace for CONV-KEY, or nil when
;;       none recorded.  Read by the resume / picker / quick-
;;       action paths in main-bulk + workspace-bulk.
;;   `decknix--agent-session-save-workspace'
;;       Persist WORKSPACE under the conv-key resolved from
;;       SESSION-ID.  Used by session-creation flows that have a
;;       fresh session-id but no conv-key in hand yet.  Resolves
;;       through `decknix--agent-conversation-key-for-session';
;;       no-ops cleanly if either the resolve fails or either
;;       arg is nil.
;;   `decknix--agent-session-save-workspace-for-conv-key'
;;       Persist WORKSPACE directly for CONV-KEY -- used by the
;;       session picker when the user adopts a workspace for an
;;       already-known conversation.
;;
;; Auto-creates the conversation entry with empty `tags' and
;; `sessions' lists so the shape matches the other accessors in
;; this store.

;;; Code:

(require 'decknix-agent-tags-store)
(require 'decknix-agent-conv-resolve)
(require 'seq)

(defun decknix--agent-workspace-for-conv-key (conv-key)
  "Return the workspace directory for conversation CONV-KEY, or nil."
  (let* ((store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store)))
    (let ((entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (gethash "workspace" entry)))))

(defun decknix--agent-session-save-workspace (session-id workspace)
  "Persist WORKSPACE for the conversation containing SESSION-ID.
Looks up the conversation key from cached session data, then stores
the workspace in the conversation entry alongside tags."
  (when (and session-id workspace)
    (let ((conv-key (decknix--agent-conversation-key-for-session
                     session-id)))
      (when conv-key
        (let* ((store (decknix--agent-tags-read))
               (convs (decknix--agent-tags-conversations store))
               (entry (or (gethash conv-key convs)
                          (let ((h (make-hash-table :test 'equal)))
                            (puthash "tags" nil h)
                            (puthash "sessions" nil h)
                            h))))
          (puthash "workspace" workspace entry)
          (puthash conv-key entry convs)
          (decknix--agent-tags-write store))))))

(defun decknix--agent-session-save-workspace-for-conv-key
    (conv-key workspace)
  "Persist WORKSPACE for CONV-KEY directly (no session-id lookup).
Used by the session picker when the user selects a workspace for a
conversation that had no workspace stored."
  (when (and conv-key workspace)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "tags" nil h)
                        (puthash "sessions" nil h)
                        h))))
      (puthash "workspace" workspace entry)
      (puthash conv-key entry convs)
      (decknix--agent-tags-write store))))

(defun decknix--agent-additional-roots-for-conv-key (conv-key)
  "Return the extra working directories recorded for CONV-KEY, or nil.
A review session starts in the workspace root and works on its PR
worktree as an additional root; resume must pass the same roots back or
the resumed session loses the worktree."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (let ((roots (gethash "additionalRoots" entry)))
          (seq-filter #'stringp (if (vectorp roots) (append roots nil) roots)))))))

(defun decknix--agent-session-save-additional-roots-for-conv-key (conv-key roots)
  "Persist ROOTS as CONV-KEY's extra working directories."
  (when (and conv-key roots)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "tags" nil h)
                        (puthash "sessions" nil h)
                        h))))
      (puthash "additionalRoots" roots entry)
      (puthash conv-key entry convs)
      (decknix--agent-tags-write store))))

(defun decknix--agent-existing-additional-roots (roots &optional exists-fn)
  "Return the members of ROOTS that still exist.  Pure given EXISTS-FN.
A review worktree is pruned once its PR is done; handing the agent a
directory that is gone would fail the resume rather than just lose a
root.  EXISTS-FN defaults to `file-directory-p'."
  (seq-filter (or exists-fn #'file-directory-p) roots))

(provide 'decknix-agent-session-workspace)
;;; decknix-agent-session-workspace.el ends here
