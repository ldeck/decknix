;;; decknix-focus.el --- Focus-stealing on attention / new sessions -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, focus

;;; Commentary:
;;
;; Optional focus-stealing for backgrounded agent sessions.  A single
;; 3-state toggle decides whether Emacs raises its frame to the
;; foreground when work needs the user's attention:
;;
;;   off       -> never steal focus (default).
;;   attention -> raise the frame when a backgrounded session enters a
;;                `waiting' (needs-input / permission) state.
;;   both      -> attention, plus raise when a new session is created
;;                (e.g. an auto-review dispatch).
;;
;; The decision layer here is pure and side-effect free at load time.
;; The only side effect is `decknix-focus-raise-frame', invoked from the
;; detectors when the toggle and the transition both warrant it.  The
;; runtime wiring (the header status hook, the new-session advice, the
;; sidebar toggle UI and persistence) lives in the heredoc per
;; AGENTS.md Rule 2.

;;; Code:

(require 'cl-lib)

(defconst decknix-focus-states '(off attention both)
  "Ordered cycle of focus-steal states.
See the Commentary for the meaning of each.")

(defvar decknix-focus-steal 'off
  "Current focus-steal state; one of `decknix-focus-states'.
Seeded from `programs.emacs.decknix.ui.focus.steal' at load and
overridden by the persisted sidebar state on reload.")

(defvar-local decknix-focus--last-status nil
  "Last raw status seen for this buffer, used for edge detection.")

;; Sidebar persistence / refresh helpers, resolved at runtime.  Declared
;; so this file byte-compiles clean in isolation (no `packageRequires').
(declare-function decknix--sidebar-state-write "decknix-agent-shell-workspace")
(declare-function decknix--sidebar-state-save "decknix-agent-shell-workspace")
(declare-function agent-shell-workspace-sidebar-refresh "agent-shell-workspace")
(defvar agent-shell-workspace-sidebar-buffer-name "*Agent Sidebar*")

;; -- State cycle ----------------------------------------------------

(defun decknix-focus-next-state (state)
  "Return the state after STATE in `decknix-focus-states'.
An unrecognised STATE resets the cycle to `off'."
  (let ((tail (cdr (memq state decknix-focus-states))))
    (or (car tail) 'off)))

(defun decknix-focus-state-label (state)
  "Return a short human label for STATE."
  (pcase state
    ('attention "attention")
    ('both      "att+new")
    (_          "off")))

;; -- Predicates -----------------------------------------------------

(defun decknix-focus-steal-attention-p ()
  "Return non-nil when attention transitions should steal focus."
  (memq decknix-focus-steal '(attention both)))

(defun decknix-focus-steal-new-session-p ()
  "Return non-nil when new sessions should steal focus."
  (eq decknix-focus-steal 'both))

(defun decknix-focus-attention-edge-p (last raw)
  "Return non-nil on the transition into a needs-attention state.
LAST is the previously seen raw status, RAW the new one.  An edge is
LAST not already \"waiting\" while RAW is \"waiting\"."
  (and (string= raw "waiting")
       (not (equal last "waiting"))))

;; -- Side effect: raise the frame -----------------------------------

(defun decknix-focus--macos-activate ()
  "Bring the Emacs app to the foreground on macOS.
Under the background daemon (ProcessType=Background) macOS will not
raise the app from `raise-frame' alone; an explicit AppleScript
activate is required.  Runs asynchronously and is a no-op off darwin."
  (when (and (eq system-type 'darwin)
             (display-graphic-p)
             (executable-find "osascript"))
    (ignore-errors
      (call-process "osascript" nil 0 nil
                    "-e" "tell application \"Emacs\" to activate"))))

(defun decknix-focus-raise-frame (&optional frame)
  "Raise FRAME (default selected) and give it input focus."
  (let ((f (or frame (selected-frame))))
    (when (frame-live-p f)
      (ignore-errors (make-frame-visible f))
      (ignore-errors (raise-frame f))
      (ignore-errors (select-frame-set-input-focus f))))
  (decknix-focus--macos-activate))

;; -- Detectors ------------------------------------------------------

(defun decknix-focus-note-status (raw visible-p &optional buffer)
  "Record RAW status for BUFFER and maybe steal focus.
Raises the frame when attention-steal is enabled, the buffer is not
already visible/active (VISIBLE-P nil), and a fresh edge into
\"waiting\" occurred.  RAW is always recorded so toggling the feature
on mid-wait does not see a spurious edge on the next tick."
  (with-current-buffer (or buffer (current-buffer))
    (let ((last decknix-focus--last-status))
      (when (and (decknix-focus-steal-attention-p)
                 (not visible-p)
                 (decknix-focus-attention-edge-p last raw))
        (decknix-focus-raise-frame))
      (setq-local decknix-focus--last-status raw))))

(defun decknix-focus-maybe-raise-on-new-session ()
  "Raise the frame when new-session focus-steal is enabled."
  (when (decknix-focus-steal-new-session-p)
    (decknix-focus-raise-frame)))

;; -- UI label + interactive cycle -----------------------------------

(defun decknix-focus-footer-label ()
  "Return the short bracketed label for the focus toggle."
  (format "[%s]" (decknix-focus-state-label decknix-focus-steal)))

(defun decknix-focus-cycle ()
  "Cycle the focus-steal state and persist + refresh the sidebar."
  (interactive)
  (setq decknix-focus-steal (decknix-focus-next-state decknix-focus-steal))
  (cond ((fboundp 'decknix--sidebar-state-write) (decknix--sidebar-state-write))
        ((fboundp 'decknix--sidebar-state-save)  (decknix--sidebar-state-save)))
  (when (and (boundp 'agent-shell-workspace-sidebar-buffer-name)
             (get-buffer agent-shell-workspace-sidebar-buffer-name)
             (fboundp 'agent-shell-workspace-sidebar-refresh))
    (agent-shell-workspace-sidebar-refresh))
  (message "Focus steal: %s" (decknix-focus-state-label decknix-focus-steal)))

;; -- Navigation: focus the sidebar ----------------------------------

(declare-function agent-shell-workspace-toggle "agent-shell-workspace")

(defun decknix-focus-sidebar ()
  "Select the agent sidebar window, opening the Agents workspace if needed.
A cross-context navigation helper: from a session buffer (or anywhere)
jump straight to the sidebar.  Complements the global attention jump
\(C-c A j) which jumps the other way, to the next session needing input."
  (interactive)
  (let* ((bufname (and (boundp 'agent-shell-workspace-sidebar-buffer-name)
                       agent-shell-workspace-sidebar-buffer-name))
         (buf (and bufname (get-buffer bufname)))
         (win (and buf (get-buffer-window buf t))))
    (cond
     (win
      (select-frame-set-input-focus (window-frame win))
      (select-window win))
     ((fboundp 'agent-shell-workspace-toggle)
      (call-interactively #'agent-shell-workspace-toggle)
      (let ((w (and bufname (get-buffer bufname)
                    (get-buffer-window (get-buffer bufname) t))))
        (when (window-live-p w) (select-window w))))
     (t (message "Agent sidebar not available")))))

(provide 'decknix-focus)
;;; decknix-focus.el ends here
