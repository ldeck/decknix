;;; decknix-agent-conv-hidden.el --- Hidden-conversation flag accessors -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-store "0.1"))
;; Keywords: agent, agent-shell, decknix, tags

;;; Commentary:
;;
;; Predicate + setter for the `hidden' boolean stored against each
;; conversation in `~/.config/decknix/agent-sessions.json'.  Hidden
;; conversations are background / automated sessions (e.g. git-hook
;; commit reviews, attention-batch sessions) that should not appear
;; in user-facing pickers / sidebars.
;;
;; Carved out of `decknix-agent-shell-main' (PR B.67) so the small
;; flag-mutation pair is testable without standing up the full main
;; heredoc, and so future hidden-conversation logic can grow here
;; without bloating main-bulk.
;;
;; Two entry points:
;;
;;   `decknix--agent-conversation-hidden-p'
;;       Returns non-nil when CONV-KEY exists in the store and its
;;       `hidden' flag is `t'.  Errors are absorbed (returns nil)
;;       so callers in render hot paths cannot fault on a missing
;;       or malformed store.
;;
;;   `decknix--agent-conversation-set-hidden'
;;       Writes the flag.  Creates the per-conversation entry if it
;;       doesn't exist yet.  Persists via `decknix--agent-tags-write'
;;       so the cache and the on-disk JSON stay in sync.
;;
;; The interactive verb that wraps the setter (toggle-from-sidebar)
;; stays in main-bulk per AGENTS.md Rule 2 -- it side-effects the
;; sidebar refresh.

;;; Code:

(require 'cl-lib)

;; Tag-store accessors (load/save/conversations) -- always present in
;; the daemon at runtime; declared here so the byte-compiler is happy
;; in isolation.
(declare-function decknix--agent-tags-read "decknix-agent-tags-store")
(declare-function decknix--agent-tags-write
                  "decknix-agent-tags-store" (store))
(declare-function decknix--agent-tags-conversations
                  "decknix-agent-tags-store" (store))

(defun decknix--agent-conversation-hidden-p (conv-key)
  "Return non-nil if CONV-KEY is marked as hidden in agent-sessions.json.
Hidden conversations are background/automated sessions (e.g., git hook
commit reviews) that should not appear in user-facing session lists."
  (condition-case nil
      (let* ((store (decknix--agent-tags-read))
             (convs (decknix--agent-tags-conversations store))
             (entry (gethash conv-key convs)))
        (and entry (eq (gethash "hidden" entry) t)))
    (error nil)))

(defun decknix--agent-conversation-set-hidden (conv-key hidden)
  "Set the hidden flag for CONV-KEY to HIDDEN (t or nil)."
  (let* ((store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store))
         (entry (gethash conv-key convs)))
    (unless entry
      (setq entry (make-hash-table :test 'equal))
      (puthash conv-key entry convs))
    (puthash "hidden" (if hidden t :json-false) entry)
    (decknix--agent-tags-write store)))

(provide 'decknix-agent-conv-hidden)
;;; decknix-agent-conv-hidden.el ends here
