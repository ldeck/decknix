;;; decknix-sidebar-previous.el --- Previous-sessions list + dedupe -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, sidebar, decknix

;;; Commentary:
;;
;; The "Previous Sessions" sidebar section restores the live agent-
;; shell buffers that existed when Emacs last exited.  This module
;; carries the in-memory list (`decknix--sidebar-previous-sessions',
;; populated from `~/.config/decknix/sidebar-state.el' on startup and
;; mutated by the kill / restore / delete paths) and the dedupe
;; helper that collapses parallel session-id snapshots of the same
;; conversation down to a single row.
;;
;; Why dedupe matters: auggie writes a fresh session file on every
;; interrupt / compose, so a single conversation can own several
;; session-ids on disk.  When the Previous list (persisted or in-
;; memory) carries two entries sharing a `conv-key', they both
;; resolve to the same latest snapshot at restore time and render
;; as visually identical rows.  `decknix--sidebar-previous-dedupe'
;; collapses them down to the first occurrence, keeping render /
;; picker / restore flows in sync.  Entries without a `conv-key'
;; fall back to session-id-based uniqueness so they are never
;; accidentally merged.
;;
;; Public surface:
;;
;;   `decknix--sidebar-previous-sessions'  — the list (alists)
;;   `decknix--sidebar-previous-dedupe'    — pure list -> list helper

;;; Code:

(require 'cl-lib)

(defvar decknix--sidebar-previous-sessions nil
  "List of sessions that were live when Emacs last exited.
Each entry is an alist with keys: session-id, name, workspace, conv-key, tags.")

(defvar decknix--sidebar-previous-sessions-file
  (expand-file-name "~/.config/decknix/agent-previous-sessions.el")
  "Path to the file storing the snapshotted Previous Sessions list.
This file is written once at startup by the snapshot logic and
restored across hot-reloads to prevent data loss when the in-memory
list is reset.")

;; -- Previous sessions history ring ------------------------------------
;;
;; Each time Emacs starts and finds sessions in the live file, it takes
;; a snapshot and prepends it to `decknix--sidebar-previous-history'.
;; The ring is capped at `decknix--sidebar-previous-history-depth'
;; entries (oldest entries dropped when the ring is full).  Each entry
;; is an alist:
;;
;;   ((timestamp . FLOAT-TIME) (sessions . LIST-OF-SESSION-ALISTS))
;;
;; The history is persisted to `decknix--sidebar-previous-history-file'
;; so it survives daemon restarts, and is restored at startup (before
;; the snapshot) so new snapshots are prepended to the existing ring.
;;
;; Public surface:
;;   `decknix--sidebar-previous-history'         — the ring (in memory)
;;   `decknix--sidebar-previous-history-depth'   — max ring size
;;   `decknix--sidebar-previous-history-file'    — persistence path
;;   `decknix--sidebar-previous-history-record'  — prepend a new snapshot
;;   `decknix--sidebar-previous-history-save'    — write ring to disk
;;   `decknix--sidebar-previous-history-restore' — read ring from disk

(defcustom decknix--sidebar-previous-history-depth 10
  "Maximum number of historical Previous-Session snapshots to retain.
Oldest entries are dropped when the ring exceeds this depth."
  :type 'integer
  :group 'decknix)

(defcustom decknix--sidebar-previous-history-file
  (expand-file-name "~/.config/decknix/agent-previous-history.el")
  "Path to the file storing the Previous Sessions history ring.
Each entry is an alist with keys `timestamp' (float-time) and
`sessions' (list of session alists).  Newest entries appear first."
  :type 'file
  :group 'decknix)

(defvar decknix--sidebar-previous-history nil
  "Ring of past Previous Session snapshots, newest first.
Each entry: ((timestamp . FLOAT-TIME) (sessions . LIST-OF-SESSION-ALISTS)).
Capped at `decknix--sidebar-previous-history-depth' entries.")

(defun decknix--sidebar-previous-history-record (sessions)
  "Prepend SESSIONS as a new entry in the history ring.
Caps the ring at `decknix--sidebar-previous-history-depth' entries.
No-ops when SESSIONS is nil."
  (when sessions
    (push (list (cons 'timestamp (float-time))
                (cons 'sessions sessions))
          decknix--sidebar-previous-history)
    ;; Trim to depth
    (when (> (length decknix--sidebar-previous-history)
             decknix--sidebar-previous-history-depth)
      (setq decknix--sidebar-previous-history
            (seq-take decknix--sidebar-previous-history
                      decknix--sidebar-previous-history-depth)))))

(defun decknix--sidebar-previous-history-save ()
  "Write `decknix--sidebar-previous-history' to disk.
Best-effort — errors are silently ignored."
  (when (and (boundp 'decknix--sidebar-previous-history-file)
             decknix--sidebar-previous-history-file)
    (condition-case nil
        (let ((path decknix--sidebar-previous-history-file))
          (make-directory (file-name-directory path) t)
          (with-temp-file path
            (insert ";; Auto-generated by decknix-sidebar-previous — do not edit\n")
            (prin1 decknix--sidebar-previous-history (current-buffer))
            (insert "\n")))
      (error nil))))

(defun decknix--sidebar-previous-history-restore ()
  "Read `decknix--sidebar-previous-history' from disk.
Best-effort — errors leave the ring unchanged."
  (when (and (boundp 'decknix--sidebar-previous-history-file)
             decknix--sidebar-previous-history-file
             (file-exists-p decknix--sidebar-previous-history-file))
    (condition-case nil
        (let ((data (with-temp-buffer
                      (insert-file-contents
                       decknix--sidebar-previous-history-file)
                      (goto-char (point-min))
                      (read (current-buffer)))))
          (when (listp data)
            (setq decknix--sidebar-previous-history data)))
      (error nil))))

(defun decknix--sidebar-previous-dedupe (entries)
  "Return ENTRIES with at most one entry per conv-key.
auggie writes a fresh session file on every interrupt/compose, so a
single conversation can own several session-ids on disk.  When the
Previous list (persisted or in-memory) carries two entries sharing a
conv-key, they both resolve to the same latest snapshot at restore
time and render as visually identical rows — this helper collapses
them down to the first occurrence, keeping render/picker/restore
flows in sync.  Entries without a conv-key fall back to
session-id-based uniqueness so they are never accidentally merged."
  (let ((seen (make-hash-table :test 'equal))
        (out nil))
    (dolist (e entries)
      (let* ((ck (alist-get 'conv-key e))
             (key (or ck (cons 'sid (alist-get 'session-id e)))))
        (unless (gethash key seen)
          (puthash key t seen)
          (push e out))))
    (nreverse out)))

(provide 'decknix-sidebar-previous)
;;; decknix-sidebar-previous.el ends here
