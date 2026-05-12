;;; decknix-agent-workspace-persist.el --- Workspace-persist policy -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, workspace

;;; Commentary:
;;
;; Pure policy helpers for the workspace auto-persist safety net
;; (PR B.81).  Carved out of `decknix--agent-auto-persist-workspace'
;; so the "should I stash workspace + install the comint hook?"
;; decision and the "what's the first message in the input ring?"
;; lookup can be exercised without a live comint buffer.
;;
;; Public surface (one decision + one accessor):
;;
;;   (decknix--workspace-persist-decision WS PERSISTED-P PENDING-SET-P)
;;     -> (:action 'install :stash WS)   ; valid ws + not persisted, no
;;                                       ;   pending workspace stashed yet
;;     |  (:action 'install :stash nil)  ; valid ws + not persisted, but
;;                                       ;   guided post-create already
;;                                       ;   stashed a pending workspace
;;     |  (:action 'no-op)               ; otherwise
;;
;;   (decknix--workspace-ring-first-message RING-LENGTH RING-REF-FN)
;;     -> the oldest entry from a comint input-ring (the first user
;;        message of a resumed session), or nil when the ring is
;;        empty.  RING-REF-FN is invoked as `(funcall RING-REF-FN
;;        IDX)' so the carved module never depends on `comint' or
;;        `ring' libraries.
;;
;; Per AGENTS.md Rule 2 the actual `add-hook',
;; `setq-local decknix--agent-pending-workspace', ring access via
;; `(ring-ref comint-input-ring ...)', and `agent-shell-subscribe-to'
;; calls stay in main-bulk.  This module only encodes:
;;
;;   "given workspace + persistence flags, what should we do?" and
;;   "given a ring's length and lookup fn, what's the first message?"

;;; Code:

(defun decknix--workspace-persist-decision (ws persisted-p pending-set-p)
  "Resolve the workspace-persist action for the current buffer.

WS is the candidate workspace string (typically
`decknix--agent-session-workspace' or `default-directory').
PERSISTED-P is non-nil when `decknix--agent-workspace-persisted'
is already set.  PENDING-SET-P is non-nil when
`decknix--agent-pending-workspace' has already been stashed by
the guided post-create path.

Result plist:
  (:action install :stash WS)   -- caller should `setq-local'
                                   `decknix--agent-pending-workspace'
                                   to WS and add the comint hook.
  (:action install :stash nil)  -- caller should add the hook
                                   without overwriting an
                                   already-stashed pending ws.
  (:action no-op)               -- nothing to do (no valid ws,
                                   already persisted, etc.)

The two `install' shapes share the hook step but diverge on
the stash step -- letting the bulk caller decide both with one
`pcase' branch."
  (cond
   ((or persisted-p
        (not (and ws (stringp ws) (not (string-empty-p ws)))))
    (list :action 'no-op))
   (pending-set-p
    (list :action 'install :stash nil))
   (t
    (list :action 'install :stash ws))))

(defun decknix--workspace-ring-first-message (ring-length ring-ref-fn)
  "Return the oldest non-empty entry from a comint input-ring.

RING-LENGTH is the integer result of `(ring-length RING)';
RING-REF-FN is a function that, called with an index, returns the
ring's element at that index (i.e. a closure over the ring).

The oldest entry sits at index `(1- RING-LENGTH)' in comint's
ring (newest at 0); we only return it when the entry is a
non-empty string so the caller can use it as the first user
message for `decknix--agent-flush-pending-metadata'.

Returns nil when the ring is empty or the lookup yields a blank
entry -- both cases the caller should treat as 'no first message
available, defer to comint input-filter'."
  (when (and (integerp ring-length) (> ring-length 0)
             (functionp ring-ref-fn))
    (let ((msg (funcall ring-ref-fn (1- ring-length))))
      (when (and (stringp msg) (not (string-empty-p msg)))
        msg))))

(provide 'decknix-agent-workspace-persist)
;;; decknix-agent-workspace-persist.el ends here
