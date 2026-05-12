;;; decknix-agent-tags-mutate.el --- Tag-store mutators -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, tags

;;; Commentary:
;;
;; Mutators for the v2 tag store (PR B.70), carved out of main-bulk
;; so the persistence dance can be exercised without spinning up a
;; live agent-shell process.  All three functions write back via
;; `decknix--agent-tags-write' and read via `-tags-read' /
;; `-conversations'.
;;
;; Public surface:
;;
;;   `decknix--agent-store-metadata-by-conv-key'  CONV-KEY -> tags+ws
;;   `decknix--agent-register-session-id'         CONV-KEY -> session
;;   `decknix--agent-flush-pending-metadata'      comint-input-filter
;;
;; The user-facing flush is a `comint-input-filter-functions' hook
;; target; the `add-hook' that installs it stays in main-bulk
;; (`decknix--agent-auto-persist-workspace') per AGENTS.md Rule 2.
;; Buffer-local state read here (`decknix--agent-conv-key',
;; `-pending-tags', `-pending-workspace', `-workspace-persisted',
;; `-auggie-session-id') is owned by main-bulk and forward-declared.

;;; Code:

(require 'cl-lib)

;; Forward declarations -- carved tag-store + buffer-locals owned
;; by main-bulk.
(declare-function decknix--agent-tags-read "decknix-agent-tags-store" ())
(declare-function decknix--agent-tags-write "decknix-agent-tags-store" (store))
(declare-function decknix--agent-tags-conversations
                  "decknix-agent-tags-store" (store))
(declare-function decknix--agent-conversation-key
                  "decknix-agent-conv-resolve" (first-message))

(defvar decknix--agent-conv-key)
(defvar decknix--agent-auggie-session-id)
(defvar decknix--agent-pending-tags)
(defvar decknix--agent-pending-workspace)
(defvar decknix--agent-workspace-persisted)

(defun decknix--agent-store-metadata-by-conv-key (conv-key tags workspace)
  "Store TAGS and WORKSPACE directly under CONV-KEY in the tag store.
Use this when the conversation key is known at creation time (e.g., quickactions
where the first message is the command itself)."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "sessions" nil h)
                        h))))
      (when tags
        (let ((existing (gethash "tags" entry)))
          (dolist (tag tags)
            (cl-pushnew tag existing :test #'string=))
          (puthash "tags" existing entry)))
      (when workspace
        (puthash "workspace" workspace entry))
      ;; Bump recency
      (puthash "lastAccessed"
               (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry)
      (puthash conv-key entry convs)
      (decknix--agent-tags-write store))))

(defun decknix--agent-register-session-id (conv-key session-id)
  "Ensure SESSION-ID is in the sessions list for CONV-KEY.
This keeps all session snapshots (original + resumed) linked to
the same conversation."
  (when (and conv-key session-id)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when entry
        (let ((sids (gethash "sessions" entry)))
          (unless (and sids (member session-id sids))
            (puthash "sessions"
                     (cons session-id (or sids '()))
                     entry)
            (decknix--agent-tags-write store)))))))

(defun decknix--agent-flush-pending-metadata (input)
  "Persist pending metadata for the current buffer using INPUT.

Designed for `comint-input-filter-functions': fires on the first
non-empty user input, derives the conversation key directly from
the input text (sidestepping the session-list cache), and writes
any pending tags + workspace under that key in v2 format.

Removes itself from `comint-input-filter-functions' after a
successful flush so the work runs at most once per buffer.  Empty
or whitespace-only input leaves the hook in place for the next
submission."
  (when (and input (stringp input)
             (not (string-empty-p (string-trim input))))
    (let ((conv-key (decknix--agent-conversation-key input)))
      (when conv-key
        ;; Stash conv-key buffer-locally for header-line lookups.
        (unless decknix--agent-conv-key
          (setq-local decknix--agent-conv-key conv-key))
        ;; Register the session id under the conv-key when known.
        (when (and (boundp 'decknix--agent-auggie-session-id)
                   decknix--agent-auggie-session-id)
          (decknix--agent-register-session-id
           conv-key decknix--agent-auggie-session-id))
        ;; Persist pending tags + workspace.
        (when (or decknix--agent-pending-tags
                  decknix--agent-pending-workspace)
          (decknix--agent-store-metadata-by-conv-key
           conv-key
           decknix--agent-pending-tags
           decknix--agent-pending-workspace)
          (when decknix--agent-pending-workspace
            (setq-local decknix--agent-workspace-persisted t))
          (when decknix--agent-pending-tags
            (message "Tags applied: [%s]"
                     (string-join decknix--agent-pending-tags
                                  ", ")))
          (setq-local decknix--agent-pending-tags nil)
          (setq-local decknix--agent-pending-workspace nil))
        ;; One-shot: remove ourselves from the buffer-local hook.
        (remove-hook 'comint-input-filter-functions
                     #'decknix--agent-flush-pending-metadata
                     t)))))

(provide 'decknix-agent-tags-mutate)

;;; decknix-agent-tags-mutate.el ends here
