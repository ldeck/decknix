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
