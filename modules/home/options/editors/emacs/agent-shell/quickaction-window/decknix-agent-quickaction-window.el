;;; decknix-agent-quickaction-window.el --- Quickaction window resolver -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, quickaction, window

;;; Commentary:
;;
;; Pure helpers for the quickaction "where should the new session
;; appear?" decision (PR B.80).  Carved out of
;; `decknix--agent-quickaction-start' so the sidebar-detection
;; predicate and the target-window selection rule can be exercised
;; without an actual frame / sidebar / dedicated window.
;;
;; Public surface (one predicate + one resolver):
;;
;;   (decknix--quickaction-window-is-sidebar-p SIDE-PARAM DEDICATED-P
;;                                              BUFFER-NAME SIDEBAR-NAME)
;;     -> non-nil when the window described by these signals should
;;        be treated as the sidebar.  Inputs are caller-evaluated
;;        (`(window-parameter WIN 'window-side)',
;;         `(window-dedicated-p WIN)',
;;         `(buffer-name (window-buffer WIN))', and the configured
;;        sidebar-buffer-name) so this stays free of frame / buffer
;;        state.
;;
;;   (decknix--quickaction-target-window CUR-IS-SIDEBAR CUR MAIN-WIN)
;;     -> the window the new session buffer should be displayed in.
;;        When CUR is the sidebar, prefer the frame's main window
;;        (falling back to CUR if MAIN-WIN is nil); otherwise just
;;        return CUR so the new buffer replaces the caller in place.
;;
;; Per AGENTS.md Rule 2 the actual `selected-window' / `window-main-window'
;; resolution and the `agent-shell-start' invocation stay in main-bulk;
;; this module only encodes the two bounded-context rules:
;;
;;   "what counts as a sidebar?" and
;;   "given that the caller is a sidebar, where should we display?"

;;; Code:

(defun decknix--quickaction-window-is-sidebar-p (side-param dedicated-p
                                                            buffer-name
                                                            sidebar-name)
  "Return non-nil when the described window should be treated as the sidebar.

SIDE-PARAM is the result of `(window-parameter WIN 'window-side)';
DEDICATED-P is `(window-dedicated-p WIN)';
BUFFER-NAME is `(buffer-name (window-buffer WIN))';
SIDEBAR-NAME is the configured sidebar buffer name (typically
`agent-shell-workspace-sidebar-buffer-name' or the literal
`*agent-shell-sidebar*').

The predicate is true when ANY of three signals fires:
  * SIDE-PARAM is non-nil (it's a side window)
  * DEDICATED-P is non-nil (caller wants exclusive use)
  * BUFFER-NAME equals SIDEBAR-NAME

The four-argument shape mirrors the original `or' chain so the
inline call site reads as a single predicate invocation."
  (or side-param
      dedicated-p
      (and (stringp buffer-name)
           (stringp sidebar-name)
           (string= buffer-name sidebar-name))))

(defun decknix--quickaction-target-window (cur-is-sidebar cur main-win)
  "Return the window the new quickaction session should display in.

CUR-IS-SIDEBAR is the boolean result from
`decknix--quickaction-window-is-sidebar-p' for the
currently-selected window.  CUR is the selected window; MAIN-WIN
is the frame's `window-main-window' (may be nil during minibuffer
recursion).

Decision:
  * caller is sidebar  + main-win available -> main-win
  * caller is sidebar  + no main-win        -> CUR (fallback)
  * caller is not sidebar                   -> CUR (replace in place)

Returning CUR for the non-sidebar case preserves the `c' upstream
behaviour (open in current window).  The sidebar branch protects
the sidebar from being clobbered by `agent-shell-start' so the
workspace tab keeps its layout."
  (if cur-is-sidebar
      (or main-win cur)
    cur))

(provide 'decknix-agent-quickaction-window)
;;; decknix-agent-quickaction-window.el ends here
