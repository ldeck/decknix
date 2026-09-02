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

;; ---------------------------------------------------------------------------
;; Store-scatter diagnostic (temporary).  A session-id should live in exactly
;; ONE conversation.  When it gets registered into a second one, it scatters
;; across the store — the root of the "container conversation" pollution that
;; mislabelled the Live sidebar.  Static tracing could not pin WHICH caller
;; passes the wrong conv-key, so this logs the moment (with a compact caller
;; backtrace) the next time it happens.  Log-only: no behaviour change.
;; ---------------------------------------------------------------------------

(defvar decknix--agent-register-scatter-log
  (expand-file-name "~/.config/decknix/agent-scatter.log")
  "File appended to when a session-id is registered into a conversation while
it already lives in another (the store-scatter signature).  Set to nil to
disable.  A diagnostic aid, not load-bearing.")

(defvar decknix--agent-register-container-threshold 10
  "Registering a session into a conversation that already lists at least this
many sessions is logged as a possible container-seed — even when the session
is not yet elsewhere.  This catches the FIRST registration into a pollution
sink (which the cross-conversation check alone stays silent on, since the
session has no other home yet).")

(defvar decknix--agent-container-drain-threshold 15
  "When a session is registered into a conversation SMALLER than this, it is
removed from any OTHER conversation at or above this size — an oversized
`container' that has accumulated unrelated sessions.  Set high enough that it
only ever drains a clear pollution sink (the 20+-session gemini container that
mislabelled the sidebar), never a normal thread's handful of resume snapshots
or a small curated grouping.")

(defun decknix--agent-register-scatter-others (conv-key session-id convs)
  "Pure: sorted conv-keys in CONVS other than CONV-KEY whose `sessions' already
list SESSION-ID.  Non-empty means registering SESSION-ID under CONV-KEY would
scatter it across conversations."
  (let (others)
    (when (hash-table-p convs)
      (maphash (lambda (k e)
                 (when (and (not (equal k conv-key))
                            (hash-table-p e)
                            (member session-id (gethash "sessions" e)))
                   (push k others)))
               convs))
    (sort others #'string<)))

(defun decknix--agent-container-homes (conv-key session-id convs threshold)
  "Pure: sorted conv-keys in CONVS other than CONV-KEY that list SESSION-ID and
hold at least THRESHOLD sessions.  These are the oversized containers a
single-home registration should drain SESSION-ID out of."
  (let (hits)
    (when (hash-table-p convs)
      (maphash (lambda (k e)
                 (when (and (not (equal k conv-key))
                            (hash-table-p e)
                            (>= (length (gethash "sessions" e)) threshold)
                            (member session-id (gethash "sessions" e)))
                   (push k hits)))
               convs))
    (sort hits #'string<)))

(defun decknix--agent-register-caller-trace ()
  "Compact innermost-first chain of the call stack, for the scatter diagnostic.
Captures ALL named-function frames (not just `decknix' ones): a container seed
is timer-driven, so the culprit sits in a non-decknix frame (a timer callback /
subscription lambda) between `timer-event-handler' and the register call — a
decknix-only filter hides exactly the frame we need.  Byte-compiled closures
print as `closure'/`lambda', still useful for locating the path."
  (let (names)
    (dolist (frame (backtrace-frames))
      (let* ((fn (nth 1 frame))
             (n (cond ((symbolp fn) (symbol-name fn))
                      ((byte-code-function-p fn) "<bytecode>")
                      ((and (consp fn) (eq (car fn) 'lambda)) "<lambda>")
                      ((and (consp fn) (eq (car fn) 'closure)) "<closure>")
                      (t nil))))
        (when (and n (not (string-match-p "register-\\(scatter\\|caller\\|log\\)" n)))
          (push n names))))
    (string-join (seq-take (delete-dups (nreverse names)) 14) " <- ")))

(defvar decknix--agent-register-scatter-log-adopt t
  "When non-nil, log a NEW session id registered into a TAGGED conversation.

This is the `adopt' trigger, and it exists because the other two missed
the bug that actually keeps happening.  `e06099' has captured a
freshly-created session three times — `conn,demos' on 28 Aug, then
`conn,standup' on 1 Sep — each time appending the user's tags to its
existing `#20571 review pr #256 hot'.  Every occurrence had to be
reconstructed afterwards from store backups because nothing recorded it:

  `scatter'     wants the sid to already live elsewhere — it was brand new
  `big-target'  wants >= 10 sessions in the target — it held one

so the precise signature of the fault was the one case going unlogged.
Two fixes have been shipped for two different routes into that container
\(`ff624a5' shared input ring, `edabfeb' buffer adoption) and it recurred
both times, which is the argument for recording it rather than inferring
it again.

Noisier than the other triggers by design: joining an established
conversation is legitimate on resume.  The point is a timestamped
backtrace at the moment it happens, not a verdict.")

(defun decknix--agent-register-log-scatter (conv-key session-id convs)
  "Append a diagnostic line when registering SESSION-ID under CONV-KEY looks
like store scatter.  Three triggers: `scatter' — the id already lives in
another conversation; `big-target' — the target already lists at least
`decknix--agent-register-container-threshold' sessions (a likely pollution
sink), which catches the FIRST registration into it before any duplication
exists; and `adopt' — a session-id NEW to the store joining a conversation
that already carries tags (see `decknix--agent-register-scatter-log-adopt').
No-op when disabled or no trigger fires.  Never signals."
  (when decknix--agent-register-scatter-log
    (ignore-errors
      (let* ((others (decknix--agent-register-scatter-others conv-key session-id convs))
             (target (gethash conv-key convs))
             (tsize (if (hash-table-p target)
                        (length (gethash "sessions" target)) 0))
             (big (>= tsize decknix--agent-register-container-threshold))
             (ttags-p (and (hash-table-p target)
                           (gethash "tags" target) t))
             ;; `adopt': the sid is new to the STORE (not in this target, not
             ;; in any other) and the target is already an established,
             ;; tagged conversation -- i.e. a fresh session inheriting
             ;; someone else's identity.
             (adopt (and decknix--agent-register-scatter-log-adopt
                         ttags-p
                         (null others)
                         (hash-table-p target)
                         (not (member session-id (gethash "sessions" target)))))
             (reason (cond ((and others big) "scatter+big")
                           (others "scatter")
                           (big "big-target")
                           (adopt "adopt"))))
        (when reason
          (let* ((ttags (and (hash-table-p target) (gethash "tags" target)))
                 (line (format "%s [%s] sid=%s target=%s(n=%d tags=%s) already-in=%s via %s\n"
                               (format-time-string "%FT%T%z") reason
                               session-id conv-key tsize
                               (if ttags (string-join ttags ",") "-")
                               (if others (string-join others ",") "-")
                               (decknix--agent-register-caller-trace))))
            (with-temp-buffer
              (insert line)
              (append-to-file (point-min) (point-max)
                              decknix--agent-register-scatter-log))))))))

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
which is how a resumed conversation could freeze on an older snapshot.

Single-home drain: a session-id belongs to exactly ONE conversation, but a
resolver occasionally homed it in an oversized `container' entry (a stale
conversation that accumulated many unrelated sessions + a union of their
tags), which mislabelled the Live sidebar.  So when SESSION-ID is registered
into a SPECIFIC conversation (one below
`decknix--agent-container-drain-threshold' sessions), it is removed from any
such container it also sits in.  The sink therefore empties organically — each
member leaves the next time it is registered under its real key — with no
risky bulk migration, and small / curated groupings are never touched (the
drain only fires when CONV-KEY itself is specific)."
  (when (and conv-key session-id)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "sessions" nil h)
                        h)))
           (sids (gethash "sessions" entry))
           (dirty nil))
      (unless (and sids (member session-id sids))
        ;; Diagnostic (log-only): flag if this registration scatters the
        ;; session-id across conversations, capturing the caller.
        (decknix--agent-register-log-scatter conv-key session-id convs)
        (puthash "sessions"
                 (cons session-id (or sids '()))
                 entry)
        (puthash conv-key entry convs)
        (setq dirty t))
      ;; Drain the session-id out of any oversized container it also lives in,
      ;; but only when homing it into a specific (small) conversation — never
      ;; when CONV-KEY is itself large, so we can't fragment a real long thread.
      (when (< (length (gethash "sessions" entry))
               decknix--agent-container-drain-threshold)
        (dolist (ck (decknix--agent-container-homes
                     conv-key session-id convs
                     decknix--agent-container-drain-threshold))
          (let ((ce (gethash ck convs)))
            (puthash "sessions"
                     (delete session-id (copy-sequence (gethash "sessions" ce)))
                     ce)
            (setq dirty t))))
      (when dirty
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
