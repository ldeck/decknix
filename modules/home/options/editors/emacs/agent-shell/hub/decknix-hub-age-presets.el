;;; decknix-hub-age-presets.el --- Shared age-filter presets for hub data -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, tools

;;; Commentary:
;;
;; State and helpers for the hub "age filter" — a cycling preset list
;; (`all/1d/3d/7d/14d/30d') used to hide stale items from the sidebar
;; Requests / WIP / Sessions sections.
;;
;; The presets are factored out of the agent-shell heredoc so the
;; sidebar-toggles module (which exposes a parallel saved-Sessions
;; age toggle) can share the same vocabulary without a forward-decl
;; on `decknix--hub-age-presets'.
;;
;; The cycle command refreshes the workspace sidebar when its buffer
;; exists; the call is unguarded by `fboundp' to match the original
;; heredoc behaviour (the buffer is only ever populated by the
;; workspace module, so refresh is reachable iff workspace loaded).

;;; Code:

(require 'cl-lib)
(require 'iso8601)

;; -- Forward declarations: defined elsewhere in agent-shell config --
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")

(defvar decknix--hub-age-filter nil
  "Current age filter threshold in seconds, or nil for no filter.
Use `decknix--hub-cycle-age-filter' to cycle through presets.")

(defvar decknix--hub-age-presets
  '((nil    . "all")
    (86400  . "1d")
    (259200 . "3d")
    (604800 . "7d")
    (1209600 . "14d")
    (2592000 . "30d"))
  "Alist of (SECONDS . LABEL) presets for the age filter.")

(defun decknix--hub-age-filter-label ()
  "Return the label for the current age filter."
  (or (alist-get decknix--hub-age-filter
                 decknix--hub-age-presets)
      "all"))

(defun decknix--hub-cycle-age-filter ()
  "Cycle the hub age filter through presets."
  (interactive)
  (let* ((keys (mapcar #'car decknix--hub-age-presets))
         (pos (cl-position decknix--hub-age-filter keys :test #'equal))
         (next-pos (mod (1+ (or pos 0)) (length keys))))
    (setq decknix--hub-age-filter (nth next-pos keys))
    (when (get-buffer "*agent-shell-sidebar*")
      (agent-shell-workspace-sidebar-refresh))
    (message "Hub age filter: %s" (decknix--hub-age-filter-label))))

(defun decknix--hub-age-visible-p (iso-time)
  "Return non-nil if ISO-TIME is within the current age filter.
Always returns t when filter is nil (show all)."
  (or (null decknix--hub-age-filter)
      (and iso-time (stringp iso-time)
           (condition-case nil
               (let* ((then (encode-time (iso8601-parse iso-time)))
                      (age-secs (float-time
                                 (time-subtract (current-time) then))))
                 (<= age-secs decknix--hub-age-filter))
             (error t)))))

(provide 'decknix-hub-age-presets)
;;; decknix-hub-age-presets.el ends here
