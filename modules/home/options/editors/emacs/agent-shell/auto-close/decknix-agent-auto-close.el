;;; decknix-agent-auto-close.el --- Auto-close a session after a clean turn -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, review

;;; Commentary:
;;
;; "Arm this review session to close itself once it's done."  You make a call
;; on a PR, tell the agent to enact the verdict and stop, arm auto-close, and
;; walk away — the session posts the verdict and then closes without you coming
;; back to clean it up.
;;
;; Mechanism.  Arming sets a per-buffer phase to `armed'.  On the next turn that
;; finishes cleanly (`shell-maker-finish-output' with :success — advised in the
;; heredoc), the buffer enters a `closing' phase and a visible countdown
;; (`decknix-agent-auto-close-countdown', default 60s).  When it elapses the
;; session is quit + saved (via `decknix-agent-session-quit', prompts
;; suppressed).  The countdown is CANCELLED if you engage — type, C-g, or submit
;; another prompt — so a turn that ended with a follow-up question keeps the
;; session open the moment you respond, without needing to parse intent.
;;
;; The `closing' phase surfaces as a distinct status string "closing"
;; (`decknix-agent-buffer-status' / `decknix-agent-closing-p'), which
;; `decknix-session-state' maps to the `closing' lifecycle state (its own glyph)
;; so `C-c b' and the sidebar show it apart from working/ready/etc.
;;
;; Rule 2: this package owns the pure countdown helpers, the buffer-local state,
;; and the arm/cancel/begin/fire functions; the `advice-add' wiring onto
;; `shell-maker-finish-output' / `agent-shell-heartbeat-start' lives in the
;; heredoc.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function agent-shell-workspace--buffer-status "ext:agent-shell-workspace" (buffer))
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")
(declare-function decknix-agent-session-quit "decknix-agent-shell-main-session")

(defgroup decknix-agent-auto-close nil
  "Auto-close an agent session after a clean turn."
  :group 'decknix)

(defcustom decknix-agent-auto-close-countdown 60
  "Seconds to wait after a successful turn before auto-closing an armed session.
The countdown is cancelled if you interact with the session (type, C-g, or send
another prompt), so a follow-up question keeps it open the moment you engage."
  :type 'integer :group 'decknix-agent-auto-close)

;; Per-buffer phase: nil | `armed' | `closing'.
(defvar-local decknix--agent-auto-close-phase nil
  "Auto-close phase for this agent buffer: nil, `armed', or `closing'.")
(defvar-local decknix--agent-auto-close-timer nil
  "Pending countdown timer, or nil.")
(defvar-local decknix--agent-auto-close-deadline nil
  "`float-time' at which the pending auto-close fires, or nil.")

;; ── Pure helpers (ERT-tested) ──────────────────────────────────────────

(defun decknix--agent-auto-close-remaining (deadline now)
  "Whole seconds until DEADLINE from NOW, floored at 0."
  (max 0 (round (- (or deadline now) now))))

(defun decknix--agent-auto-close-message (secs)
  "Countdown prompt shown while an armed session is finishing."
  (format "Auto-close in %ds — type, C-g, or submit to keep the session open."
          secs))

;; ── Status surface ─────────────────────────────────────────────────────

(defun decknix-agent-closing-p (&optional buffer)
  "Non-nil when BUFFER (default current) is counting down to auto-close."
  (eq 'closing (buffer-local-value 'decknix--agent-auto-close-phase
                                   (or buffer (current-buffer)))))

(defun decknix-agent-buffer-status (buffer)
  "Status string for BUFFER, injecting \"closing\" during the auto-close countdown.
Otherwise defers to agent-shell's own detection (nil if unavailable)."
  (if (decknix-agent-closing-p buffer)
      "closing"
    (and (fboundp 'agent-shell-workspace--buffer-status)
         (ignore-errors (agent-shell-workspace--buffer-status buffer)))))

(defun decknix--agent-auto-close-refresh ()
  "Best-effort repaint so a phase change shows in the header + sidebar.
The sidebar refresh is debounced by the paint advice; the idle tick would also
pick the change up within ~2s via its status fingerprint, so this is only to
make it feel immediate."
  (force-mode-line-update)
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (ignore-errors (agent-shell-workspace-sidebar-refresh))))

;; ── Arm / cancel ───────────────────────────────────────────────────────

(defun decknix--agent-auto-close-arm (&optional buffer)
  "Arm BUFFER (default current) to auto-close after its next clean turn.
Non-interactive: used by the batch launcher for unattended review sessions."
  (with-current-buffer (or buffer (current-buffer))
    (setq decknix--agent-auto-close-phase 'armed)
    (decknix--agent-auto-close-refresh)))

;;;###autoload
(defun decknix-agent-arm-auto-close ()
  "Arm THIS session to auto-close after its next turn finishes cleanly.
One-shot: it fires once then disarms, and is cancelled if you interact before
it fires.  Give the agent a terminal instruction (\"enact the verdict, post it,
then stop\") and arm this, then walk away."
  (interactive)
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (decknix--agent-auto-close-arm)
  (message "Auto-close armed — closes ~%ds after the next clean turn (interact to keep open)."
           decknix-agent-auto-close-countdown))

(defun decknix-agent-toggle-auto-close ()
  "Toggle auto-close arming for this session."
  (interactive)
  (if decknix--agent-auto-close-phase
      (decknix--agent-auto-close-cancel)
    (decknix-agent-arm-auto-close)))

(defun decknix--agent-auto-close-cancel (&optional buffer quiet)
  "Cancel any armed/pending auto-close in BUFFER (default current)."
  (with-current-buffer (or buffer (current-buffer))
    (when (timerp decknix--agent-auto-close-timer)
      (cancel-timer decknix--agent-auto-close-timer))
    (remove-hook 'post-self-insert-hook #'decknix--agent-auto-close-interaction t)
    (let ((was decknix--agent-auto-close-phase))
      (setq decknix--agent-auto-close-timer nil
            decknix--agent-auto-close-deadline nil
            decknix--agent-auto-close-phase nil)
      (decknix--agent-auto-close-refresh)
      (when (and was (not quiet) (eq was 'closing))
        (message "Auto-close cancelled — session kept open.")))))

;; ── Countdown lifecycle ────────────────────────────────────────────────

(defun decknix--agent-auto-close-on-finish (&rest args)
  "`:after' advice for `shell-maker-finish-output': begin the countdown.
Only when this buffer is `armed' and the turn finished with :success non-nil."
  (when (and (eq decknix--agent-auto-close-phase 'armed)
             (plist-get args :success))
    (decknix--agent-auto-close-begin)))

(defun decknix--agent-auto-close-begin ()
  "Enter the `closing' countdown for the current buffer."
  (let ((buf (current-buffer)))
    (when (timerp decknix--agent-auto-close-timer)
      (cancel-timer decknix--agent-auto-close-timer))
    (setq decknix--agent-auto-close-phase 'closing
          decknix--agent-auto-close-deadline
          (+ (float-time) decknix-agent-auto-close-countdown)
          decknix--agent-auto-close-timer
          (run-with-timer decknix-agent-auto-close-countdown nil
                          #'decknix--agent-auto-close-fire buf))
    (add-hook 'post-self-insert-hook #'decknix--agent-auto-close-interaction nil t)
    (decknix--agent-auto-close-refresh)
    (message "%s" (decknix--agent-auto-close-message
                   decknix-agent-auto-close-countdown))))

(defun decknix--agent-auto-close-interaction ()
  "Buffer-local hook: typing into a closing session cancels the countdown."
  (when (eq decknix--agent-auto-close-phase 'closing)
    (decknix--agent-auto-close-cancel)))

(defun decknix--agent-auto-close-on-new-turn (&rest _)
  "`:before' advice for `agent-shell-heartbeat-start': a new turn cancels a
pending close (you engaged — e.g. answered a follow-up question)."
  (when (eq decknix--agent-auto-close-phase 'closing)
    (decknix--agent-auto-close-cancel nil t)))

(defun decknix--agent-auto-close-fire (buffer)
  "Timer callback: quit BUFFER's session if it is still `closing'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq decknix--agent-auto-close-phase 'closing)
        (remove-hook 'post-self-insert-hook #'decknix--agent-auto-close-interaction t)
        (setq decknix--agent-auto-close-phase nil
              decknix--agent-auto-close-timer nil
              decknix--agent-auto-close-deadline nil)
        ;; Unattended close: reuse the full quit (SIGHUP-saves the session)
        ;; but suppress its confirmation + the kill-process query.
        (if (fboundp 'decknix-agent-session-quit)
            (let ((kill-buffer-query-functions nil))
              (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
                (call-interactively 'decknix-agent-session-quit)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buffer)))))))

(provide 'decknix-agent-auto-close)
;;; decknix-agent-auto-close.el ends here
