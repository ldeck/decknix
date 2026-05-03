;;; decknix-sidebar-tile.el --- Sidebar tile-cycle helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, sidebar, tile, decknix

;;; Commentary:
;;
;; The sidebar `t' key cycles a desired tile-count (off -> 2 -> 3 ->
;; 4 -> off) for the most-recent live agent buffers.  This module
;; carries the desired-count defvar, a one-shot apply helper, the
;; cycle command, and the auto-engage hook used by the sidebar
;; refresh path so the preference re-tiles when fresh buffers come
;; up (e.g. after Previous-Sessions restore).
;;
;; The persistence layer (read/write `decknix--sidebar-tile-count'
;; into `decknix--sidebar-state-file') intentionally stays in
;; `decknix-agent-shell-workspace' (workspace-bulk) since it is part
;; of the sidebar-state save/restore cluster that owns several other
;; toggles too.
;;
;; Public surface:
;;
;;   `decknix--sidebar-tile-count'           — desired count (defvar)
;;   `decknix--sidebar-tile-current-count'   — number currently tiled
;;   `decknix--sidebar-tile-apply'           — one-shot tiler
;;   `decknix-sidebar-tile-cycle'            — interactive cycler
;;   `decknix--sidebar-maybe-apply-tile-pref' — sidebar-refresh hook

;;; Code:

(require 'cl-lib)
(require 'seq)

;; -- Forward declarations ----------------------------------------
;; All four upstream symbols come from the agent-shell-workspace
;; package; both the buffer-name var and the buffer-local flags are
;; defined there.  `agent-shell-workspace-sidebar-refresh' is the
;; heredoc-resident sidebar redraw entry point.
(declare-function agent-shell-buffers
                  "ext:agent-shell" ())
(declare-function agent-shell-workspace--tile
                  "ext:agent-shell-workspace" (buffers))
(declare-function agent-shell-workspace--untile
                  "ext:agent-shell-workspace" ())
(declare-function agent-shell-workspace-sidebar-refresh
                  "ext:agent-shell-workspace" ())
(defvar agent-shell-workspace-sidebar-buffer-name)

(defvar decknix--sidebar-tile-count 0
  "Desired number of tiled agent-shell buffers in the sidebar.
0 means tiling is off.  Cycled by `decknix-sidebar-tile-cycle'
(0 → 2 → 3 → 4 → 0).  Persisted in
`decknix--sidebar-state-file' so the preference survives Emacs
restarts.  When >0 and the live buffer count is insufficient, the
preference is preserved and applied automatically by
`decknix--sidebar-maybe-apply-tile-pref' once enough buffers
become available (e.g., after Previous sessions resume).")

(defun decknix--sidebar-tile-current-count ()
  "Return the number of currently tiled buffers (0 if not tiled).
Reads the sidebar buffer-local `agent-shell-workspace--tiled-buffers'
list.  Used to detect mismatches against
`decknix--sidebar-tile-count' so auto-apply only re-tiles when the
layout actually needs to change."
  (let ((sb (get-buffer agent-shell-workspace-sidebar-buffer-name)))
    (if (and sb
             (buffer-local-value 'agent-shell-workspace--tiled sb))
        (length (buffer-local-value
                 'agent-shell-workspace--tiled-buffers sb))
      0)))

(defun decknix--sidebar-tile-apply (n)
  "Tile the most-recent N live agent buffers via the upstream API.
Returns the actual number of buffers tiled (capped at upstream's 8).
N must be ≥2; callers using N=0 should instead call
`agent-shell-workspace--untile'."
  (let* ((bufs (seq-filter #'buffer-live-p (agent-shell-buffers)))
         (target (min n (length bufs) 8)))
    (when (>= target 2)
      (agent-shell-workspace--tile (seq-take bufs target)))
    target))

(defun decknix-sidebar-tile-cycle ()
  "Cycle the desired tile count: 0 → 2 → 3 → 4 → 0.
At 0, untile if currently tiled.  At N>0, tile the N most-recent
live agent buffers; if fewer than N are live, store the preference
and message that tiling will engage once enough sessions resume.
The preference is reapplied by
`decknix--sidebar-maybe-apply-tile-pref' on every sidebar refresh."
  (interactive)
  (let* ((current decknix--sidebar-tile-count)
         (next (cond ((= current 0) 2)
                     ((= current 2) 3)
                     ((= current 3) 4)
                     (t 0))))
    (setq decknix--sidebar-tile-count next)
    (cond
     ((= next 0)
      ;; Cycle wrapped back to off — untile if currently tiled.
      (let ((sb (get-buffer agent-shell-workspace-sidebar-buffer-name)))
        (when (and sb
                   (buffer-local-value 'agent-shell-workspace--tiled sb))
          (agent-shell-workspace--untile)))
      (message "Tile: off"))
     (t
      (let* ((live (length (seq-filter #'buffer-live-p (agent-shell-buffers))))
             (applied (decknix--sidebar-tile-apply next)))
        (cond
         ((>= applied 2)
          (message "Tiled %d live agent buffers (target %d)" applied next))
         (t
          (message "Tile target: %d (need %d more live buffer%s)"
                   next (- next live)
                   (if (= (- next live) 1) "" "s")))))))
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))))

(defun decknix--sidebar-maybe-apply-tile-pref ()
  "Re-tile when the desired count is set but layout doesn't match.
Called from the sidebar refresh path so that resuming Previous
sessions or creating a new session naturally engages the
preferred tile count once enough buffers exist.  No-op when
`decknix--sidebar-tile-count' is 0 or the current tiled count
already equals the preference."
  (let ((n decknix--sidebar-tile-count))
    (when (and (integerp n) (>= n 2))
      (let* ((live-bufs (seq-filter #'buffer-live-p (agent-shell-buffers)))
             (target (min n (length live-bufs) 8))
             (current (decknix--sidebar-tile-current-count)))
        (when (and (>= target 2)
                   (/= current target))
          (decknix--sidebar-tile-apply target))))))

(provide 'decknix-sidebar-tile)
;;; decknix-sidebar-tile.el ends here
