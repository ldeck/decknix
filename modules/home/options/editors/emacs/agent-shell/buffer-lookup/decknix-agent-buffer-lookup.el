;;; decknix-agent-buffer-lookup.el --- Agent-shell buffer / conv-key lookups -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-store "0.1"))
;; Keywords: agent, agent-shell, decknix, buffer

;;; Commentary:
;;
;; Four small read-only helpers that find or interrogate agent-shell
;; buffers.  Carved out of `decknix-agent-shell-main' (PR B.66) so the
;; thin lookup layer is testable without standing up an actual
;; agent-shell process or a live tag store.
;;
;;   `decknix--agent-buffer-session-id'
;;       The auggie-CLI session ID for BUF.  Reads the buffer-local
;;       `decknix--agent-auggie-session-id' first (the ID needed for
;;       --resume), falls back to the ACP session ID nested in
;;       `agent-shell--state'.  Returns nil if neither is set.
;;
;;   `decknix--agent-find-new-shell-buffer'
;;       Snapshot diff against BEFORE-BUFFERS -- returns the first
;;       agent-shell buffer that did not exist when the snapshot was
;;       taken.  Used by quick-action launchers that need to find
;;       the buffer they just spawned.
;;
;;   `decknix--agent-find-live-buffer-for-conv-key'
;;       Dedupe lookup: returns the live agent-shell buffer (with a
;;       live process) currently bound to CONV-KEY, so a second
;;       resume of the same conversation can short-circuit to the
;;       existing buffer instead of producing an `*Auggie: ...*<2>'
;;       pair where one buffer holds stale context.
;;
;;   `decknix--agent-current-conv-key'
;;       Reverse-resolve the current buffer's auggie session ID back
;;       to its conversation key by walking the tag-store
;;       conversations table.  Returns nil when not in an
;;       agent-shell buffer or when the session is not yet
;;       registered against any conversation.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)

;; Tag-store accessors -- pure read operations on the JSON cache.
(declare-function decknix--agent-tags-read "decknix-agent-tags-store")
(declare-function decknix--agent-tags-conversations
                  "decknix-agent-tags-store" (store))

;; Upstream agent-shell -- present at runtime in the daemon, but not
;; pulled in at byte-compile time for this isolated package.
(declare-function agent-shell-buffers "agent-shell")
(defvar agent-shell--state)

;; Buffer-locals owned by main-bulk and the session lifecycle modules.
;; `defvar' without a value is a compiler hint; the actual binding is
;; made `defvar-local' wherever the buffer is created.
(defvar decknix--agent-auggie-session-id)
(defvar decknix--agent-conv-key)

(defun decknix--agent-buffer-session-id (&optional buf)
  "Return the auggie CLI session ID for BUF (default: current buffer).
Reads the buffer-local `decknix--agent-auggie-session-id' first (this is
the ID needed for --resume).  Falls back to the ACP session ID from
`agent-shell--state' if the auggie ID is not yet set."
  (with-current-buffer (or buf (current-buffer))
    (or (and (boundp 'decknix--agent-auggie-session-id)
             decknix--agent-auggie-session-id)
        (ignore-errors
          (and (boundp 'agent-shell--state)
               agent-shell--state
               (map-nested-elt agent-shell--state '(:session :id)))))))

(defun decknix--agent-find-new-shell-buffer (before-buffers)
  "Find the agent-shell buffer that was created after BEFORE-BUFFERS snapshot.
Returns the new buffer, or nil if not found.

BEFORE-BUFFERS is only a snapshot, so \"new\" means \"appeared since\" --
not \"created by this launch\".  Any agent-shell buffer spawned
concurrently qualifies: a resume, a sidebar restore, an auto-review.  The
caller then renames that buffer and persists ITS tags/workspace against
whatever conversation it already belongs to, so a guided new session
adopts a resumed conversation's identity and the user's tags are appended
to that conversation's tag list (observed: a session created with
`conn,demos' came back carrying `#20571 review pr #256 hot' too, filed
into the long-running `e06099' container).

Buffers already bound to a conversation are therefore deprioritised: a
resumed buffer stamps `decknix--agent-conv-key' synchronously at creation
\(see `decknix--agent-session-resume--new'), while a genuinely new one
carries none until its first message flush -- so an UNCLAIMED buffer is
the one this launch actually created.

The preference is a tie-break rather than a filter: when every candidate
is claimed we still return one, because returning nil would drop the
caller's rename and metadata persistence altogether, leaving the session
unnamed and untagged -- worse than the mis-attribution being avoided."
  (let ((candidates
         (seq-filter (lambda (buf)
                       (and (buffer-live-p buf)
                            (not (memq buf before-buffers))
                            (with-current-buffer buf
                              (derived-mode-p 'agent-shell-mode))))
                     (buffer-list))))
    (or (seq-find (lambda (buf)
                    (with-current-buffer buf
                      (not (bound-and-true-p decknix--agent-conv-key))))
                  candidates)
        (when candidates
          ;; Every candidate is already claimed -- the race actually
          ;; happened.  Say so: the original incident was only
          ;; reconstructible from store backups because nothing recorded
          ;; it at the time.
          (message "decknix: new-session lookup found only claimed buffer(s) (%s); \
metadata may be mis-filed"
                   (mapconcat #'buffer-name candidates ", "))
          (car candidates)))))

(defun decknix--agent-find-live-buffer-for-conv-key (conv-key)
  "Return the first live agent-shell buffer whose conv-key matches CONV-KEY.
Returns nil when CONV-KEY is nil or no live buffer is bound to it.
Used by `decknix--agent-session-resume' to dedupe: spawning a second
buffer for a conversation that is already live produces a confusing
`*Auggie: ...*<2>' pair where one buffer holds stale context.

A buffer only qualifies when its underlying auggie process is also
alive — a process-less buffer corpse (Emacs buffer alive, auggie
process dead) would otherwise short-circuit resume and leave the
user staring at a dead shell."
  (when conv-key
    (seq-find
     (lambda (buf)
       (and (buffer-live-p buf)
            (process-live-p (get-buffer-process buf))
            (with-current-buffer buf
              (and (derived-mode-p 'agent-shell-mode)
                   (bound-and-true-p decknix--agent-conv-key)
                   (equal decknix--agent-conv-key conv-key)))))
     (when (fboundp 'agent-shell-buffers)
       (agent-shell-buffers)))))

(defun decknix--agent-find-live-buffer-for-session-id (session-id)
  "Return the first live agent-shell buffer already holding SESSION-ID.
Returns nil when SESSION-ID is nil/empty or no live buffer holds it.

The session-id backstop to `decknix--agent-find-live-buffer-for-conv-key'.
A conv-key is derived from conversation content and scatters (#151) --
the same session can end up registered under two different keys.  When
it does, a conv-key-only dedupe finds nothing live for the new key and
resume spawns a second agent-shell: a second ACP bridge process
resuming the SAME session id that another buffer already has open, so
two bridges write one transcript.  The session id cannot scatter, which
is exactly why it is the right identity to fall back on.

Reads the id through `decknix--agent-buffer-session-id' so the
auggie-id-then-ACP-id precedence stays defined in one place.  Same
liveness rule as the conv-key lookup: a process-less buffer corpse does
not qualify, since short-circuiting resume onto a dead shell is worse
than spawning a live one."
  (when (and (stringp session-id)
             (not (string-empty-p session-id)))
    (seq-find
     (lambda (buf)
       (and (buffer-live-p buf)
            (process-live-p (get-buffer-process buf))
            (with-current-buffer buf
              (and (derived-mode-p 'agent-shell-mode)
                   (equal (decknix--agent-buffer-session-id buf) session-id)))))
     (when (fboundp 'agent-shell-buffers)
       (agent-shell-buffers)))))

(defun decknix--agent-current-conv-key ()
  "Get the conversation key for the current agent-shell buffer.
Prefer the buffer-local `decknix--agent-conv-key' — the key THIS session
was filed under.  A session-id can be listed in more than one conversation
after store scatter/pollution (e.g. a stale container conversation that
wrongly accumulated many dispatched review session-ids); the session-id
scan below returns whichever such conversation `maphash' visits first,
which mislabelled every affected Live sidebar row with that container's
merged tags.  Fall back to the scan only when the buffer has no local key."
  (when (derived-mode-p 'agent-shell-mode)
    (or (and (boundp 'decknix--agent-conv-key) decknix--agent-conv-key)
        (when-let ((sid decknix--agent-auggie-session-id))
          (let* ((store (decknix--agent-tags-read))
                 (convs (decknix--agent-tags-conversations store)))
            (catch 'found
              (maphash
               (lambda (key entry)
                 (when (hash-table-p entry)
                   (when (member sid (gethash "sessions" entry))
                     (throw 'found key))))
               convs)
              nil))))))

(provide 'decknix-agent-buffer-lookup)
;;; decknix-agent-buffer-lookup.el ends here
