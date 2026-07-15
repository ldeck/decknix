;;; decknix-agent-heartbeat-watch.el --- Reclaim stuck busy heartbeats -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, heartbeat, performance

;;; Commentary:
;;
;; agent-shell animates a busy "spinner" by running a heartbeat timer
;; (`agent-shell-heartbeat-start') while a prompt request is in flight,
;; and stops it only inside that request's on-success / on-failure
;; callback.  If a request never gets a response -- the ACP bridge dies,
;; the connection breaks, or a turn is orphaned (all plausible after a
;; wedged daemon or a resume-all storm) -- neither callback fires and the
;; heartbeat leaks: the session stays `busy' and the spinner animates
;; forever, forcing a header/mode-line redisplay several times a second.
;; A single leaked heartbeat was the residual idle-CPU floor that
;; survived the sidebar-timer fix.
;;
;; This watchdog reclaims those.  A slow periodic timer checks every live
;; agent-shell buffer whose heartbeat is still running: if the buffer has
;; produced no output (its `buffer-chars-modified-tick' is unchanged) for
;; longer than `decknix-agent-heartbeat-stuck-seconds', the heartbeat is
;; considered stuck and STOPPED.  A genuinely-working turn streams output
;; (or tool-call fragments) well within the window, so it is never cut
;; off; the window is deliberately generous so a slow-but-live tool call
;; is safe.
;;
;; It stops ONLY the heartbeat (the redisplay drain), not the shell's
;; request state: if the orphaned request does eventually respond, its
;; on-success path still completes normally (calling
;; `agent-shell-heartbeat-stop' again is idempotent).  So the reclaim is
;; safe and reversible -- it removes the CPU cost, nothing else.
;;
;; The pure decision (`decknix--agent-hb-stuck-p') is carved for ERT; the
;; timer wiring lives in the heredoc per AGENTS.md Rule 2.

;;; Code:

(require 'map)

(declare-function agent-shell-buffers "ext:agent-shell")
(declare-function agent-shell--state "ext:agent-shell")
(declare-function agent-shell-heartbeat-stop "ext:agent-shell-heartbeat")

(defcustom decknix-agent-heartbeat-stuck-seconds 600
  "Seconds of no buffer output after which a running heartbeat is stuck.
A live turn streams output (or tool-call fragments) far sooner, so this
only ever fires on a leaked heartbeat (dead/orphaned request).  Generous
by design: better to let a slow-but-live tool call run than to cut it
off; a truly stuck heartbeat is reclaimed within this window regardless."
  :type 'integer
  :group 'decknix)

(defvar-local decknix--agent-hb-last-tick nil
  "`buffer-chars-modified-tick' at the previous watchdog check.")

(defvar-local decknix--agent-hb-idle-since nil
  "`float-time' since which this buffer's output has been unchanged, or nil.")

(defvar decknix--agent-hb-watch-timer nil
  "The single watchdog timer, or nil when not armed.")

(defun decknix--agent-hb-running-p (state)
  "Return non-nil when STATE's heartbeat timer is live (spinner animating)."
  (let ((hb (and state (map-elt state :heartbeat))))
    (and hb (timerp (map-elt hb :heartbeat-timer)))))

(defun decknix--agent-hb-stuck-p (running tick last-tick idle-since now threshold)
  "Return non-nil when a running heartbeat looks stuck (leaked).
RUNNING is whether the heartbeat timer is live.  TICK is the buffer's
current `buffer-chars-modified-tick'; LAST-TICK the value at the previous
check.  IDLE-SINCE is when output last stopped changing (or nil).  NOW is
the current `float-time'.  Stuck when the heartbeat is running, the
buffer has not changed since the last check, and it has been idle for at
least THRESHOLD seconds.  Pure, so the decision is ERT-testable."
  (and running
       (eql tick last-tick)
       (numberp idle-since)
       (>= (- now idle-since) threshold)))

(defun decknix--agent-hb-watch-buffer (buf now threshold)
  "Reclaim a stuck heartbeat in BUF (a live agent-shell buffer).
NOW is `float-time'; THRESHOLD the stuck window in seconds.  Updates the
buffer's activity bookkeeping and, when the heartbeat is judged stuck by
`decknix--agent-hb-stuck-p', stops it (only the heartbeat)."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let* ((state (ignore-errors (agent-shell--state)))
             (running (decknix--agent-hb-running-p state))
             (tick (buffer-chars-modified-tick)))
        (cond
         ((not running)
          ;; No spinner: keep the baseline fresh so a future run starts clean.
          (setq decknix--agent-hb-last-tick tick
                decknix--agent-hb-idle-since nil))
         ((not (eql tick decknix--agent-hb-last-tick))
          ;; Output changed since last check -> genuinely working.
          (setq decknix--agent-hb-last-tick tick
                decknix--agent-hb-idle-since now))
         (t
          (unless decknix--agent-hb-idle-since
            (setq decknix--agent-hb-idle-since now))
          (when (decknix--agent-hb-stuck-p
                 running tick decknix--agent-hb-last-tick
                 decknix--agent-hb-idle-since now threshold)
            (ignore-errors
              (agent-shell-heartbeat-stop :heartbeat (map-elt state :heartbeat)))
            (setq decknix--agent-hb-idle-since nil)
            (message "decknix: reclaimed stuck heartbeat in %s"
                     (buffer-name buf)))))))))

(defun decknix--agent-hb-watch-tick ()
  "Watchdog entry point: reclaim stuck heartbeats across live agent buffers."
  (when (fboundp 'agent-shell-buffers)
    (let ((now (float-time)))
      (dolist (buf (ignore-errors (agent-shell-buffers)))
        (decknix--agent-hb-watch-buffer
         buf now decknix-agent-heartbeat-stuck-seconds)))))

(defun decknix--agent-hb-watch-start ()
  "Arm the heartbeat watchdog timer (idempotent across hot-reloads)."
  (when (timerp decknix--agent-hb-watch-timer)
    (cancel-timer decknix--agent-hb-watch-timer))
  (setq decknix--agent-hb-watch-timer
        (run-with-timer 60 60 #'decknix--agent-hb-watch-tick)))

(provide 'decknix-agent-heartbeat-watch)
;;; decknix-agent-heartbeat-watch.el ends here
