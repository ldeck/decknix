;;; decknix-progress-sidebar.el --- Sidebar badges for decknix-progress -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-progress "0.1"))
;; Keywords: agent, progress, tools

;;; Commentary:
;;
;; Surfaces the attention rollup from `decknix-progress' as a compact
;; badge on every sidebar row that has a conv-key (Live, Previous,
;; Saved).  Reads only `index.json' (cheap summary), never the per-conv
;; snapshots, so a sidebar refresh stays microseconds even with
;; hundreds of tracked conversations.  An mtime-aware cache means
;; repeat reads within the same render cycle parse the file at most
;; once.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)
(require 'transient)
(require 'decknix-progress)

;; -- Forward declarations: functions defined elsewhere in agent-shell config --
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")
(defvar decknix--sidebar-state-file)

;; == Progress: sidebar badges (PR 3) ==
;;
;; Surfaces the PR 1 attention rollup as a compact badge on every
;; sidebar row that has a conv-key (Live, Previous, Saved).  Reads
;; only `index.json' (cheap summary), never the per-conv snapshots,
;; so a sidebar refresh stays microseconds even with hundreds of
;; tracked conversations.  An mtime-aware cache means repeat reads
;; within the same render cycle parse the file at most once.

(defvar decknix-progress--index-cache nil
  "Cons cell (MTIME . HASH-TABLE) caching the parsed `index.json'.
Invalidated when the file's modification time changes or via
`decknix-progress--index-cache-clear' on file-notify events.")

(defun decknix-progress--index-cache-clear ()
  "Drop the cached index so the next read re-parses from disk."
  (setq decknix-progress--index-cache nil))

(defun decknix-progress--read-index-cached ()
  "Return the parsed `index.json' as a hash table, using a mtime cache."
  (let* ((path (decknix-progress--index-path))
         (mtime (when (file-exists-p path)
                  (nth 5 (file-attributes path)))))
    (cond
     ((null mtime)
      (setq decknix-progress--index-cache nil)
      (make-hash-table :test 'equal))
     ((and decknix-progress--index-cache
           (equal (car decknix-progress--index-cache) mtime))
      (cdr decknix-progress--index-cache))
     (t
      (let ((h (decknix-progress--read-index)))
        (setq decknix-progress--index-cache (cons mtime h))
        h)))))

(defun decknix-progress--sidebar-badge (conv-key)
  "Return a propertized progress badge for CONV-KEY, or empty string.
Reads only `index.json' (no per-conv snapshot parse).  Honoured by the
`decknix--sidebar-show-progress' toggle in the render path."
  (if (or (null conv-key) (string-empty-p conv-key))
      ""
    (let* ((idx (decknix-progress--read-index-cached))
           (entry (and (hash-table-p idx) (gethash conv-key idx))))
      (if (not (hash-table-p entry))
          ""
        (let* ((count (or (gethash "count" entry) 0))
               (att-raw (or (gethash "attention" entry) "none"))
               (att (intern att-raw)))
          (if (and (zerop count) (eq att 'none))
              ""
            (let* ((glyph (pcase att
                            ('red   "⚑")
                            ('amber "◐")
                            ('green "✓")
                            (_      "·")))
                   (face (pcase att
                           ('red   'decknix-progress-attention-red)
                           ('amber 'decknix-progress-attention-amber)
                           ('green 'decknix-progress-attention-green)
                           (_      'decknix-progress-attention-none))))
              (propertize (format " [%d%s]" count glyph)
                          'face face
                          'help-echo
                          (format "%d progress item%s — attention: %s"
                                  count (if (= count 1) "" "s")
                                  att-raw)))))))))

;; -- Toggle state + command --

(defvar decknix--sidebar-show-progress t
  "When non-nil, render `decknix-progress--sidebar-badge' on session rows.
Persisted via `decknix--sidebar-state-file'; toggle with `p' in the
sidebar Toggles transient (Live section).")

(defun decknix-sidebar-toggle-progress ()
  "Toggle the per-session progress badge in the sidebar."
  (interactive)
  (setq decknix--sidebar-show-progress
        (not decknix--sidebar-show-progress))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Progress badges: %s"
           (if decknix--sidebar-show-progress "shown" "hidden")))

;; -- Transient suffix (Live section) --

(transient-define-suffix decknix-sidebar-transient--show-progress ()
  :key "p"
  :description
  (lambda ()
    (format "progress      %s"
            (propertize
             (if decknix--sidebar-show-progress "[on]" "[off]")
             'face (if decknix--sidebar-show-progress
                       'success 'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-toggle-progress))

;; -- File-notify: invalidate cache + refresh sidebar on changes --
;;
;; Watch `index.json' directly rather than the parent directory:
;; macOS kqueue (Emacs's `file-notify' backend on darwin) does not
;; reliably fire events for changes to files inside a watched dir,
;; only for changes to the dir entry itself.  Per-file watches are
;; reliable, and the index is the only file the sidebar reads.

(defvar decknix-progress--sidebar-watch nil
  "File-notify descriptor for `index.json'.")

(defvar decknix-progress--sidebar-refresh-timer nil
  "Coalescing timer for sidebar refresh on progress changes.")

(defun decknix-progress--sidebar-watch-callback (_event)
  "Invalidate the index cache and schedule a coalesced sidebar refresh."
  (decknix-progress--index-cache-clear)
  (when decknix-progress--sidebar-refresh-timer
    (cancel-timer decknix-progress--sidebar-refresh-timer))
  (setq decknix-progress--sidebar-refresh-timer
        (run-at-time
         0.3 nil
         (lambda ()
           (setq decknix-progress--sidebar-refresh-timer nil)
           (when (and (fboundp 'agent-shell-workspace-sidebar-refresh)
                      (get-buffer "*agent-shell-sidebar*"))
             (ignore-errors
               (agent-shell-workspace-sidebar-refresh)))))))

(defun decknix-progress--sidebar-start-watch ()
  "Watch `index.json'; refresh sidebar on changes.
If the file does not yet exist, create an empty one so the watch can
be installed (the writer in PR 1 will overwrite it on next persist)."
  (decknix-progress--ensure-dir)
  (let ((path (decknix-progress--index-path)))
    (unless (file-exists-p path)
      (let ((coding-system-for-write 'utf-8))
        (with-temp-file path (insert "{}"))))
    (when decknix-progress--sidebar-watch
      (ignore-errors
        (file-notify-rm-watch decknix-progress--sidebar-watch)))
    (setq decknix-progress--sidebar-watch
          (condition-case _err
              (file-notify-add-watch
               path
               '(change attribute-change)
               #'decknix-progress--sidebar-watch-callback)
            (error nil)))))

;; The watch is started by the surrounding `default.el' (right after the
;; `(require ...)' calls) so that it does not fire at byte-compile time
;; when this file is loaded by the byte-compiler.

(provide 'decknix-progress-sidebar)
;;; decknix-progress-sidebar.el ends here
