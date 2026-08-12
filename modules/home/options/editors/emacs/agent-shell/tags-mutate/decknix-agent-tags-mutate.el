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
(declare-function decknix--agent-conv-key-for-session-id
                  "decknix-agent-conv-resolve" (session-id))
(declare-function decknix--agent-broker-save-key-for-conv-key
                  "decknix-agent-session-broker" (conv-key key))

(defvar decknix--agent-conv-key)
(defvar decknix--agent-auggie-session-id)
(defvar decknix--agent-pending-tags)
(defvar decknix--agent-pending-workspace)
(defvar decknix--agent-workspace-persisted)
(defvar decknix--agent-broker-key)

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
the same conversation.

Creates a conversation entry when CONV-KEY has none yet, rather than
no-opping: a brand-new (untagged) session must still be linked so it
is discoverable at restore time.  Previously such sessions were left
unregistered and became orphans -- absent from the store entirely and
thus invisible to `decknix--agent-latest-session-id-for-conv-key',
which is how a resumed conversation could freeze on an older snapshot."
  (when (and conv-key session-id)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "sessions" nil h)
                        h)))
           (sids (gethash "sessions" entry)))
      (unless (and sids (member session-id sids))
        (puthash "sessions"
                 (cons session-id (or sids '()))
                 entry)
        (puthash conv-key entry convs)
        (decknix--agent-tags-write store)))))

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
    ;; Resolve a STABLE key to persist under, so a resumed buffer (whose
    ;; INPUT is the next message, not the conversation's first) and a
    ;; diverging first-message hash cannot scatter this conversation across
    ;; conv-keys: prefer the buffer-local conv-key (resumed buffers carry the
    ;; resolved key), then an existing store entry for the stable session-id,
    ;; and only then the input-derived key (a brand-new conversation).
    (let ((conv-key
           (or (and (bound-and-true-p decknix--agent-conv-key)
                    decknix--agent-conv-key)
               (and (bound-and-true-p decknix--agent-auggie-session-id)
                    decknix--agent-auggie-session-id
                    (fboundp 'decknix--agent-conv-key-for-session-id)
                    (decknix--agent-conv-key-for-session-id
                     decknix--agent-auggie-session-id))
               (decknix--agent-conversation-key input))))
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
        ;; Persist this brokered session's key against the now-known conv-key so
        ;; resume reattaches the same broker (#151 M3b).  No-op unless brokered.
        (when (and (bound-and-true-p decknix--agent-broker-key)
                   (fboundp 'decknix--agent-broker-save-key-for-conv-key))
          (decknix--agent-broker-save-key-for-conv-key
           conv-key decknix--agent-broker-key))
        ;; One-shot: remove ourselves from the buffer-local hook.
        (remove-hook 'comint-input-filter-functions
                     #'decknix--agent-flush-pending-metadata
                     t)))))

;; -- Backfill: retro-tag review sessions + migrate legacy tags -----

(declare-function decknix--agent-canonicalize-command-message
                  "decknix-agent-parse" (first-message))
(declare-function decknix--agent-conversation-key-raw
                  "decknix-agent-parse" (first-message))
(declare-function decknix--agent-parse-pr-url "decknix-agent-url-parse" (url))
(declare-function decknix--agent-session-list-all "decknix-agent-session-cache" ())
(defvar decknix--agent-tags-file)

(defun decknix--agent-tags-backfill-review-tags (first-message)
  "Return review tags for FIRST-MESSAGE, or nil when it is not a review.
Recognises a `/review-service-pr' or `/review-bot-pr' invocation — in
either the literal or the Claude command-wrapper form — whose argument
is a GitHub PR URL, and returns (\"review\" REPO \"#<number>\")."
  (let ((canon (and first-message
                    (decknix--agent-canonicalize-command-message first-message))))
    (when (and canon
               (string-match
                "\\`/review-\\(?:service\\|bot\\)-pr[ \t]+\\(https?://[^ \t\n]+\\)"
                canon))
      (when-let* ((parsed (decknix--agent-parse-pr-url (match-string 1 canon))))
        (list "review"
              (alist-get 'repo parsed)
              (concat "#" (alist-get 'number parsed)))))))

(defun decknix--agent-tags-backfill-plan ()
  "Compute the backfill plan without mutating anything.
Returns a list of (CONV-KEY . TAGS) for review sessions whose store
entry is missing the `review' tag, driven off the saved-session
transcripts."
  (let* ((store (decknix--agent-tags-read))
         (convs (and store (decknix--agent-tags-conversations store)))
         (reviews nil))
    (dolist (session (ignore-errors (decknix--agent-session-list-all)))
      (let* ((fm (alist-get 'firstUserMessage session))
             (tags (decknix--agent-tags-backfill-review-tags fm)))
        (when tags
          (let* ((key (decknix--agent-conversation-key-raw fm))
                 (entry (and convs (gethash key convs)))
                 (have (and entry (gethash "tags" entry))))
            (unless (member "review" have)
              (cl-pushnew (cons key tags) reviews
                          :test (lambda (a b) (equal (car a) (car b)))))))))
    (nreverse reviews)))

(defun decknix-agent-tags-backfill-reviews (&optional apply)
  "Retro-tag review sessions and migrate legacy `#<n>' tags.

Without a prefix arg this is a DRY RUN: it prints the plan to a
*tags-backfill* buffer and writes nothing.  With a prefix arg
(\\[universal-argument]) it backs up `agent-sessions.json' and applies
the plan.

Complements the launch-time tagging: reviews started by typing
`/review-service-pr <url>' into a plain session are never seen by a
launcher, so they carry no tags; this scans the saved transcripts and
writes them under the same `#<n>' scheme the launchers use."
  (interactive "P")
  (let ((reviews (decknix--agent-tags-backfill-plan)))
    (with-current-buffer (get-buffer-create "*tags-backfill*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Tags backfill — %s\n\n"
                        (if apply "APPLY" "DRY RUN (prefix arg to apply)")))
        (insert (format "Review sessions to tag: %d\n" (length reviews)))
        (dolist (r reviews)
          (insert (format "  %s  <- %s\n" (car r)
                          (mapconcat #'identity (cdr r) " "))))
        (goto-char (point-min)))
      (display-buffer (current-buffer)))
    (when apply
      (when (file-exists-p decknix--agent-tags-file)
        (copy-file decknix--agent-tags-file
                   (concat decknix--agent-tags-file
                           (format-time-string ".bak-backfill-%Y%m%d%H%M%S"))
                   t))
      ;; Review tags: idempotent adds (cl-pushnew inside the store writer).
      (dolist (r reviews)
        (decknix--agent-store-metadata-by-conv-key (car r) (cdr r) nil))
      (message "Backfill applied: %d review session(s) tagged"
               (length reviews)))))

(provide 'decknix-agent-tags-mutate)

;;; decknix-agent-tags-mutate.el ends here
