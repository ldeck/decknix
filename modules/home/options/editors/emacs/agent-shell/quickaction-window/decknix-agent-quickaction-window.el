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
;; Public surface (predicates + resolvers):
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
;;   (decknix--quit-pick-replacement MRU-OTHER-BUFS VISIBLE-BUFS)
;;     -> the buffer to switch to after killing the current session.
;;        Prefers the first MRU candidate that is NOT already on
;;        screen in another window of the same frame, so quitting
;;        from a split-window view does not duplicate a session
;;        already visible in the other pane.  Falls back to the head
;;        of MRU-OTHER-BUFS when every candidate is already visible.
;;
;;   (decknix--quickaction-window-candidates DESCRIPTORS)
;;     -> ordered placement candidates for the spawn-into-which-pane
;;        prompt.  Each DESCRIPTOR is (WIN BUFFER-NAME IS-CURRENT
;;        IS-SIDEBAR); sidebar entries are filtered out and each
;;        non-sidebar window expands into Replace / Split right /
;;        Split below variants.  Returns nil when fewer than three
;;        non-sidebar windows are present so the caller can skip the
;;        prompt and use its existing fast-path.
;;
;; Per AGENTS.md Rule 2 the actual `selected-window' /
;; `window-main-window' / `window-list' / `split-window' invocations
;; stay in main-bulk; this module only encodes the bounded-context
;; rules: "what counts as a sidebar?", "given the caller is a sidebar,
;; where should we display?", "given a quit and the visible-elsewhere
;; set, what's the next session to surface?", and "given a window
;; layout, what placement choices should the prompt offer?".

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

(defun decknix--quit-pick-replacement (mru-other-bufs visible-bufs)
  "Pick the buffer to switch to after killing the current session.

MRU-OTHER-BUFS is the list of remaining live agent-shell buffers
in most-recently-used order, with the buffer being killed already
removed.  VISIBLE-BUFS is the list of buffers currently displayed
in OTHER windows of the same frame (the killed buffer's window
excluded by the caller).

Returns the first MRU candidate that is NOT in VISIBLE-BUFS so
the replacement does not duplicate a session already on screen
in another pane.  When every MRU candidate is already visible
elsewhere — or only one option remains — falls back to the head
of MRU-OTHER-BUFS.  Returns nil only when MRU-OTHER-BUFS is empty
(caller routes to the welcome screen)."
  (or (seq-find (lambda (buf) (not (memq buf visible-bufs)))
                mru-other-bufs)
      (car mru-other-bufs)))

(defun decknix--quickaction-window-candidates (descriptors)
  "Build placement candidates for the quickaction spawn prompt.

DESCRIPTORS is a list of `(WIN BUFFER-NAME IS-CURRENT IS-SIDEBAR)'
tuples covering every window of the current frame; the caller
constructs them from `window-list' (sidebar status pre-classified
via `decknix--quickaction-window-is-sidebar-p').

Sidebar descriptors are filtered out.  Each remaining descriptor
contributes three candidates: Replace, Split right, Split below.
Within each variant the current window comes first so the prompt's
default selection (RET) lands on \"Replace ‹current›\" — the
historical fast-path behaviour.

Returns a list of `(LABEL ACTION WIN)' entries, where ACTION is
one of `:replace', `:split-right', `:split-below'.  Returns nil
when fewer than three non-sidebar descriptors are present so the
caller can skip the prompt and use its existing target-window
fast-path (no new prompt for single-pane or 2-pane layouts)."
  (let* ((non-sidebar (seq-remove (lambda (d) (nth 3 d)) descriptors))
         (sorted (append (seq-filter (lambda (d) (nth 2 d)) non-sidebar)
                         (seq-remove (lambda (d) (nth 2 d)) non-sidebar))))
    (when (>= (length non-sidebar) 3)
      (let (out)
        (dolist (d sorted)
          (push (list (format "Replace ‹%s›" (nth 1 d))
                      :replace (nth 0 d))
                out))
        (dolist (d sorted)
          (push (list (format "Split right of ‹%s›" (nth 1 d))
                      :split-right (nth 0 d))
                out))
        (dolist (d sorted)
          (push (list (format "Split below ‹%s›" (nth 1 d))
                      :split-below (nth 0 d))
                out))
        (nreverse out)))))

(provide 'decknix-agent-quickaction-window)
;;; decknix-agent-quickaction-window.el ends here
