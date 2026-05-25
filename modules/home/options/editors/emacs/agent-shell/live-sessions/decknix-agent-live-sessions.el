;;; decknix-agent-live-sessions.el --- Eager live-sessions persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, sidebar, decknix

;;; Commentary:
;;
;; Persistence layer for the "live agent-shell sessions" set, used by
;; the workspace sidebar's Previous Sessions section.  Splits the
;; previous monolithic save/restore (a 30 s idle timer that walked
;; `agent-shell-buffers' and rewrote the session list inside
;; `~/.config/decknix/sidebar-state.el') into two responsibilities:
;;
;;   - Live file (`~/.config/decknix/agent-live-sessions.el')
;;     Updated eagerly via lifecycle hooks: a session is added when
;;     its buffer reaches `agent-shell-mode' and removed when the
;;     buffer is killed.  Atomic writes via `with-temp-file' so a
;;     partial signal cannot corrupt it.  Always reflects what is
;;     alive RIGHT NOW; survives launchd kickstarts because the last
;;     successful eager write is on disk.
;;
;;   - Dismissed file (`~/.config/decknix/agent-dismissed-sessions.el')
;;     Set of session keys the user explicitly hid from the Previous
;;     Sessions section.  Persists across restarts so dismissals
;;     stick.
;;
;; The Previous Sessions section in the sidebar is now rendered from
;; an in-memory snapshot taken once at startup
;; (`decknix--live-sessions-snapshot-and-truncate'): read the live
;; file, freeze the result in memory as the previous-list, then
;; truncate the live file so this run starts from zero.  Any session
;; opened during this run goes through the eager hooks and updates
;; the live file in place.
;;
;; Identity:
;;
;;   Each entry is keyed by `conv-key' (the 16-char hash of the first
;;   user message — stable across resumed sessions) when available;
;;   sessions still warming up before conv-key is known fall back to
;;   `(:sid . SESSION-ID)'.  Add and remove operations dedupe on
;;   whichever key is present so a single conversation never owns
;;   more than one row.
;;
;; Suppression of writes during shutdown:
;;
;;   `kill-buffer-hook' fires during normal Emacs exit too — without
;;   `decknix--live-sessions-suppress-write', a clean quit would
;;   remove every entry from the live file as Emacs tore down each
;;   buffer, and the next start would have nothing to snapshot as
;;   Previous.  The bulk wiring sets this flag inside an early
;;   `kill-emacs-hook' so the live file freezes the moment shutdown
;;   begins; the file then survives the buffer-kill cascade and
;;   becomes the next run's Previous list.
;;
;; Public surface:
;;
;;   `decknix--live-sessions-file'             — defcustom path
;;   `decknix--live-sessions-dismissed-file'   — defcustom path
;;   `decknix--live-sessions-suppress-write'   — write-suppression flag
;;
;;   ;; Pure helpers (returns new list, no IO)
;;   `decknix--live-sessions-entry-key'        — entry -> key
;;   `decknix--live-sessions-add-entry'        — entries entry -> entries
;;   `decknix--live-sessions-remove-by'        — entries conv-key sid -> entries
;;   `decknix--live-sessions-filter-dismissed' — entries dismissed -> entries
;;   `decknix--live-sessions-dismissed-add'    — dismissed key -> dismissed
;;
;;   ;; IO wrappers (read/write the on-disk files)
;;   `decknix--live-sessions-read'
;;   `decknix--live-sessions-write'
;;   `decknix--live-sessions-dismissed-read'
;;   `decknix--live-sessions-dismissed-write'
;;
;;   ;; High-level hook entry points (combine read + pure + write)
;;   `decknix--live-sessions-record'           — entry -> nil
;;   `decknix--live-sessions-forget'           — conv-key sid -> nil
;;   `decknix--live-sessions-snapshot-and-truncate' — () -> snapshot
;;   `decknix--live-sessions-dismiss'          — key -> nil

;;; Code:

(require 'cl-lib)

(defcustom decknix--live-sessions-file
  (expand-file-name "~/.config/decknix/agent-live-sessions.el")
  "Path to the file storing the eagerly-updated live agent-shell sessions.
Each line of the on-disk s-expression is a list of alists with keys
`session-id', `name', `workspace', `conv-key', `tags'."
  :type 'file
  :group 'decknix)

(defcustom decknix--live-sessions-dismissed-file
  (expand-file-name "~/.config/decknix/agent-dismissed-sessions.el")
  "Path to the file storing dismissed Previous-Sessions keys.
Each entry is either a `conv-key' string or a cons `(:sid . SID)' for
sessions that never acquired a conv-key."
  :type 'file
  :group 'decknix)

(defvar decknix--live-sessions-suppress-write nil
  "When non-nil, the IO wrappers no-op instead of writing.
The bulk wiring sets this in an early `kill-emacs-hook' so the
buffer-kill cascade during Emacs shutdown does NOT erase the live
file — that file is the snapshot the next Emacs run will read into
its Previous Sessions section.")

;; -- Pure helpers --------------------------------------------------

(defun decknix--live-sessions-entry-key (entry)
  "Return a stable key for ENTRY (alist with `conv-key' / `session-id').
Prefers `conv-key' (string).  Falls back to `(:sid . SESSION-ID)' so
sessions still warming up before conv-key is known are still uniquely
addressable.  Returns nil when neither field is set."
  (let ((ck (alist-get 'conv-key entry))
        (sid (alist-get 'session-id entry)))
    (cond
     ((and (stringp ck) (not (string-empty-p ck))) ck)
     ((and (stringp sid) (not (string-empty-p sid))) (cons :sid sid))
     (t nil))))

(defun decknix--live-sessions-add-entry (entries entry)
  "Return ENTRIES with ENTRY added, replacing any prior match.
Match is by `decknix--live-sessions-entry-key', so adding a row with
the same conv-key (or sid, when conv-key is absent) replaces the
older snapshot — keeping a single row per conversation regardless of
how many partial states the lifecycle hooks captured along the way.

When ENTRY has no resolvable key, it is appended as a fresh row (no
collapsing — the caller has nothing to dedupe against)."
  (let ((key (decknix--live-sessions-entry-key entry)))
    (if (null key)
        (append entries (list entry))
      (let ((filtered
             (cl-remove-if
              (lambda (e)
                (equal (decknix--live-sessions-entry-key e) key))
              entries)))
        (append filtered (list entry))))))

(defun decknix--live-sessions-remove-by (entries conv-key sid)
  "Return ENTRIES with any row matching CONV-KEY or SID removed.
CONV-KEY matches `entry.conv-key' when both are non-empty strings;
SID matches `entry.session-id'.  Either argument may be nil — only
the non-nil ones participate.  Returns ENTRIES unchanged when neither
matches anything."
  (cl-remove-if
   (lambda (e)
     (let ((eck (alist-get 'conv-key e))
           (esid (alist-get 'session-id e)))
       (or (and (stringp conv-key) (not (string-empty-p conv-key))
                (stringp eck) (equal eck conv-key))
           (and (stringp sid) (not (string-empty-p sid))
                (stringp esid) (equal esid sid)))))
   entries))

(defun decknix--live-sessions-filter-dismissed (entries dismissed)
  "Return ENTRIES with any row whose key is in DISMISSED removed.
DISMISSED is the list returned by `decknix--live-sessions-dismissed-read'."
  (if (null dismissed)
      entries
    (let ((set (make-hash-table :test 'equal)))
      (dolist (k dismissed) (puthash k t set))
      (cl-remove-if
       (lambda (e)
         (let ((k (decknix--live-sessions-entry-key e)))
           (and k (gethash k set))))
       entries))))

(defun decknix--live-sessions-dismissed-add (dismissed key)
  "Return DISMISSED with KEY added at the front (idempotent)."
  (if (or (null key)
          (cl-find key dismissed :test #'equal))
      dismissed
    (cons key dismissed)))

;; -- IO wrappers ---------------------------------------------------

(defun decknix--live-sessions--read-file (path)
  "Read a single s-expression from PATH; return nil when missing/unreadable."
  (when (file-exists-p path)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (read (current-buffer)))
      (error nil))))

(defun decknix--live-sessions--write-file (path value header)
  "Atomically write VALUE (printed via `prin1') to PATH with HEADER.
Forces fsync so an unexpected shutdown cannot lose recent writes —
`write-region-inhibit-fsync' defaults to t (no fsync) for performance,
but session persistence is more important than write latency here.
No-ops when `decknix--live-sessions-suppress-write' is non-nil."
  (unless decknix--live-sessions-suppress-write
    (make-directory (file-name-directory path) t)
    (let ((write-region-inhibit-fsync nil))
      (with-temp-file path
        (insert header)
        (prin1 value (current-buffer))
        (insert "\n")))))

(defun decknix--live-sessions-read ()
  "Read the live-sessions file and return the entries (or nil)."
  (decknix--live-sessions--read-file decknix--live-sessions-file))

(defun decknix--live-sessions-write (entries)
  "Atomically write ENTRIES to the live-sessions file."
  (decknix--live-sessions--write-file
   decknix--live-sessions-file entries
   ";; Auto-generated by decknix-agent-live-sessions — do not edit\n"))

(defun decknix--live-sessions-dismissed-read ()
  "Read the dismissed-keys file and return the list (or nil)."
  (decknix--live-sessions--read-file
   decknix--live-sessions-dismissed-file))

(defun decknix--live-sessions-dismissed-write (keys)
  "Atomically write KEYS to the dismissed-keys file."
  (decknix--live-sessions--write-file
   decknix--live-sessions-dismissed-file keys
   ";; Auto-generated by decknix-agent-live-sessions — do not edit\n"))

;; -- High-level wiring (read + pure transform + write) -------------

(defun decknix--live-sessions-record (entry)
  "Add or replace ENTRY in the live-sessions file."
  (decknix--live-sessions-write
   (decknix--live-sessions-add-entry
    (decknix--live-sessions-read) entry)))

(defun decknix--live-sessions-forget (conv-key sid)
  "Remove the row matching CONV-KEY or SID from the live-sessions file."
  (decknix--live-sessions-write
   (decknix--live-sessions-remove-by
    (decknix--live-sessions-read) conv-key sid)))

(defun decknix--live-sessions-snapshot-and-truncate ()
  "Read the live-sessions file, then truncate it; return the prior entries.
Used at startup to freeze the previous run's live set as this run's
Previous Sessions list while resetting the file so eager updates in
this run start from zero.

The truncation is best-effort: if writing nil fails (e.g., disk full),
the snapshot is still returned so the caller can populate the Previous
Sessions list — stale data on the next run is safer than losing the list.
When the file is already empty or missing, skip the truncation write so we
do not mask the real absence of prior sessions with a redundant no-op write."
  (let ((snapshot (decknix--live-sessions-read)))
    ;; Only write nil when there was content — avoids an unnecessary IO
    ;; round-trip on a clean first boot or when the file was already empty.
    (when snapshot
      (condition-case nil
          (decknix--live-sessions-write nil)
        (error nil)))                   ; best-effort — never lose snapshot
    snapshot))

(defun decknix--live-sessions-dismiss (key)
  "Add KEY to the dismissed-keys file (idempotent)."
  (decknix--live-sessions-dismissed-write
   (decknix--live-sessions-dismissed-add
    (decknix--live-sessions-dismissed-read) key)))

(provide 'decknix-agent-live-sessions)
;;; decknix-agent-live-sessions.el ends here
