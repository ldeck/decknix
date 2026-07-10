;;; decknix-agent-subagent-state.el --- Sub-agent state derivation -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, subagent

;;; Commentary:
;;
;; Pure decision layer for sub-agent liveness state (#144, agent
;; resourcing Feature 1).
;;
;; Claude sub-agents are filesystem-discovered but stateless: the
;; walker (`decknix--agent-session-subagents') returns alists with
;; `modified' (ISO-8601), `created', `exchangeCount', etc. but no
;; `:state', so the sidebar renders every one in the same `shadow'
;; face.  This module derives a coarse liveness state from the signals
;; that are actually observable for a filesystem entry -- recency of
;; the transcript's last write plus whether the parent session is still
;; live -- so the renderer can colourise running vs finished sub-agents.
;;
;; What is deliberately NOT modelled here, and why:
;;   - "working vs waiting" -- a sub-agent has no live process/socket we
;;     can probe, only its transcript mtime, so we cannot tell a
;;     mid-turn agent from one blocked on a tool.  Only recency.
;;   - "failed / crashed" -- `~/.config/decknix/agent-deaths.log' is
;;     process-level (keyed on the ACP client process, no sessionId)
;;     and dominated by normal SIGKILL quits, so it cannot be joined to
;;     a specific sub-agent.  `failed' is reserved in the ladder but
;;     never emitted by this layer (deferred; see #144).
;;
;; Two pure functions, both clock-injected so ERT can exercise every
;; boundary without touching the wall clock; the render side-effects
;; stay in workspace-bulk per AGENTS.md Rule 2:
;;
;;   (decknix--agent-subagent-state SUBAGENT NOW &optional PARENT-LIVE-P)
;;     -> `running' | `active' | `done'
;;   (decknix--agent-subagent-attention STATE)
;;     -> `green' | `amber' | `red' | `none'  (drives the row face)

;;; Code:

(require 'time-date)

;; The `decknix' customisation group is defined in the emacs config
;; heredoc (welcome.nix); carved modules only reference it, matching
;; the other defcustom-bearing packages (e.g. `decknix-progress-ui').

(defcustom decknix-agent-subagent-running-window 30
  "Seconds since a sub-agent's last transcript write to count as `running'.
A sub-agent whose `modified' timestamp is within this window of now --
and whose parent session is still live -- is treated as actively
streaming.  Kept short because a working agent rewrites its JSONL on
essentially every token."
  :type 'integer
  :group 'decknix)

(defcustom decknix-agent-subagent-active-window 600
  "Seconds since a sub-agent's last write to count as `active' vs `done'.
Between `decknix-agent-subagent-running-window' and this bound a
sub-agent is `active' (recently touched but not currently streaming);
older than this it is `done'.  Default 10 minutes."
  :type 'integer
  :group 'decknix)

(defun decknix--agent-subagent-mtime (subagent)
  "Return SUBAGENT's last-write time as float-time, or nil.
Reads the `modified' ISO-8601 field produced by the session walker;
returns nil when it is absent or unparseable, so callers can treat an
unknown age as `done' rather than erroring."
  (let ((modified (and (listp subagent) (alist-get 'modified subagent))))
    (when (and (stringp modified) (not (string-empty-p modified)))
      (ignore-errors (float-time (date-to-time modified))))))

(defun decknix--agent-subagent-state (subagent now &optional parent-live-p)
  "Return the derived liveness state of SUBAGENT at NOW.
NOW is a float-time (as from `float-time'); injecting it keeps this
function clock-free and unit-testable.  PARENT-LIVE-P, when non-nil,
means the parent session buffer is still alive -- a sub-agent can only
be `running' while its parent lives, so a fresh mtime under a dead
parent caps at `active'.

States, freshest to stalest:
  `running' -- parent live and last write within
               `decknix-agent-subagent-running-window' of NOW.
  `active'  -- last write within `decknix-agent-subagent-active-window'.
  `done'    -- older than that, or `modified' missing/unparseable.

`failed' is intentionally never returned here (see Commentary)."
  (let* ((mtime (decknix--agent-subagent-mtime subagent))
         (age (and mtime (- now mtime))))
    (cond
     ((null age) 'done)
     ;; A negative age (mtime in the future, e.g. clock skew) is still
     ;; freshly-written -- treat as the freshest bucket.
     ((and parent-live-p (< age decknix-agent-subagent-running-window))
      'running)
     ((< age decknix-agent-subagent-active-window) 'active)
     (t 'done))))

(defun decknix--agent-subagent-attention (state)
  "Map a sub-agent STATE symbol to a progress-layer attention symbol.
Attention drives the row face (`decknix-progress-attention-*'):
`running' -> `green', `active' -> `amber', `failed' -> `red',
everything else (`done', nil, unknown) -> `none' (the shadowed
default)."
  (pcase state
    ('running 'green)
    ('active 'amber)
    ('failed 'red)
    (_ 'none)))

(provide 'decknix-agent-subagent-state)
;;; decknix-agent-subagent-state.el ends here
