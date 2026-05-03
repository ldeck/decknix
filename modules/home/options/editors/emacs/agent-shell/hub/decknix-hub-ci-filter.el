;;; decknix-hub-ci-filter.el --- Hub CI status filter state + helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-ci "0.1"))
;; Keywords: agent, hub, ci, filter

;;; Commentary:
;;
;; Tracks which CI statuses are visible in the sidebar Requests / WIP
;; sections.  All five buckets (pass / soft_fail / fail / running /
;; unknown) are visible by default; the `C' transient toggles them
;; individually, and the `a' / `n' bulk verbs flip the whole set.
;;
;; This module owns the data + pure helpers that drive the toggle
;; UI; the transient suffix / prefix definitions live in hub-bulk
;; (`decknix-agent-shell-hub') because they wire into the broader
;; sidebar transient cluster there.
;;
;; Public surface:
;;
;;   `decknix--hub-ci-filter'                 — list of visible statuses
;;   `decknix--hub-ci-filter-order'           — render order + faces
;;   `decknix--hub-ci-status-of'              — alist -> classified status
;;   `decknix--hub-ci-visible-p'              — predicate driving sidebar
;;   `decknix--hub-ci-filter-summary'         — propertised footer string
;;   `decknix--hub-ci-toggle-status'          — single-bucket flip
;;   `decknix--hub-ci-filter-refresh'         — trigger sidebar redraw
;;   `decknix--hub-ci-filter-toggle-{pass,soft,running,unknown,fail}'
;;   `decknix--hub-ci-filter-show-{all,none}' — bulk verbs
;;   `decknix--hub-ci-filter-status-desc'     — transient row builder

;;; Code:

(require 'cl-lib)
(require 'decknix-hub-ci)

;; The sidebar redraw entry point lives in the heredoc; resolved at
;; call time via this forward declaration so the byte-compiler stays
;; clean.
(declare-function agent-shell-workspace-sidebar-refresh
                  "ext:decknix-agent-shell-workspace" ())

;; -- Hub: CI status filter --
;; Tracks which CI statuses are visible (pass, fail, running, unknown).
;; All visible by default.  C in the sidebar toggles individual statuses.

(defvar decknix--hub-ci-filter
  '("pass" "fail" "soft_fail" "running" "unknown")
  "List of visible CI statuses.
Valid values: \"pass\", \"fail\", \"soft_fail\", \"running\", \"unknown\".
\"soft_fail\" = lint/analysis only failures (e.g. Codacy).
When all five are present, no filtering occurs.")

(defun decknix--hub-ci-status-of (item)
  "Return the classified CI status string for ITEM.
Uses individual check details to distinguish soft from hard fails."
  (decknix--hub-ci-classify (alist-get 'ci item)))

(defun decknix--hub-ci-visible-p (item)
  "Return non-nil if ITEM's CI status is in the active filter set."
  (member (decknix--hub-ci-status-of item) decknix--hub-ci-filter))

(defvar decknix--hub-ci-filter-order
  '(("pass"      "✓" success)
    ("soft_fail" "⚠" warning)
    ("fail"      "✗" error)
    ("running"   "⟳" warning)
    ("unknown"   "?" default))
  "Canonical render order for CI filter summary.
Each entry is (STATUS ICON ENABLED-FACE).  Used by the sidebar footer
and the filter transient so both show every possible toggle state —
enabled icons in their status colour, disabled icons dimmed — rather
than hiding disabled options.")

(defun decknix--hub-ci-filter-summary ()
  "Return a propertized summary of the current CI filter.
All five icons render in a fixed order.  Enabled statuses carry
their status-specific face (green/yellow/red/yellow/default);
disabled statuses render with `shadow' so they remain visible but
dim.  The returned string already has per-icon text properties —
callers must not re-`propertize' the whole result or the per-icon
faces will be overwritten."
  (mapconcat
   (lambda (entry)
     (let* ((status (nth 0 entry))
            (icon   (nth 1 entry))
            (on-face (nth 2 entry))
            (on     (member status decknix--hub-ci-filter)))
       (propertize icon 'face (if on on-face 'shadow))))
   decknix--hub-ci-filter-order
   ""))

(defun decknix--hub-ci-toggle-status (status)
  "Toggle STATUS in the CI filter set.
Individual statuses can all be hidden; use the transient's `a' key
to restore all when the list has been emptied."
  (if (member status decknix--hub-ci-filter)
      (setq decknix--hub-ci-filter
            (delete status decknix--hub-ci-filter))
    (push status decknix--hub-ci-filter)))

(defun decknix--hub-ci-filter-refresh ()
  "Refresh the sidebar after a CI filter change."
  (when (get-buffer "*agent-shell-sidebar*")
    (agent-shell-workspace-sidebar-refresh)))

(defun decknix--hub-ci-filter-toggle-pass ()
  "Toggle visibility of passing CI."
  (interactive)
  (decknix--hub-ci-toggle-status "pass")
  (decknix--hub-ci-filter-refresh))

(defun decknix--hub-ci-filter-toggle-soft ()
  "Toggle visibility of soft-fail CI (lint/analysis only)."
  (interactive)
  (decknix--hub-ci-toggle-status "soft_fail")
  (decknix--hub-ci-filter-refresh))

(defun decknix--hub-ci-filter-toggle-running ()
  "Toggle visibility of running CI."
  (interactive)
  (decknix--hub-ci-toggle-status "running")
  (decknix--hub-ci-filter-refresh))

(defun decknix--hub-ci-filter-toggle-unknown ()
  "Toggle visibility of items with no CI data."
  (interactive)
  (decknix--hub-ci-toggle-status "unknown")
  (decknix--hub-ci-filter-refresh))

(defun decknix--hub-ci-filter-toggle-fail ()
  "Toggle visibility of hard-fail CI (build/test failures)."
  (interactive)
  (decknix--hub-ci-toggle-status "fail")
  (decknix--hub-ci-filter-refresh))

(defun decknix--hub-ci-filter-show-all ()
  "Show items with any CI status."
  (interactive)
  (setq decknix--hub-ci-filter
        '("pass" "fail" "soft_fail" "running" "unknown"))
  (decknix--hub-ci-filter-refresh)
  (message "CI filter: all"))

(defun decknix--hub-ci-filter-show-none ()
  "Hide items with any CI status (empties the visible set)."
  (interactive)
  (setq decknix--hub-ci-filter nil)
  (decknix--hub-ci-filter-refresh)
  (message "CI filter: none (use `a' to restore)"))

(defun decknix--hub-ci-filter-status-desc (status icon label)
  "Return a transient description for STATUS with ICON and LABEL.
Enabled icons carry the status-specific face from
`decknix--hub-ci-filter-order' so the transient mirrors what the
sidebar footer shows; disabled icons dim to `shadow'."
  (let* ((on (member status decknix--hub-ci-filter))
         (entry (assoc status decknix--hub-ci-filter-order))
         (on-face (or (nth 2 entry) 'default)))
    (format "%s %s %s"
            (if on
                (propertize "[x]" 'face 'success)
              (propertize "[ ]" 'face 'shadow))
            (propertize icon 'face (if on on-face 'shadow))
            label)))

(provide 'decknix-hub-ci-filter)
;;; decknix-hub-ci-filter.el ends here
