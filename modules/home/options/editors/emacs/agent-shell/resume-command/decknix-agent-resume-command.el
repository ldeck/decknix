;;; decknix-agent-resume-command.el --- ResumeCommand value object -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, resume

;;; Commentary:
;;
;; ResumeCommand value-object for the SessionResume bounded context
;; (PR B.76).  Composes the auggie ACP command line that
;; `decknix--agent-session-resume--new' hands to `agent-shell-start'
;; via its `:client-maker' closure.
;;
;; Pure builder: takes BASE-CMD + (optional) WORKSPACE + (optional)
;; MODEL + SESSION-ID and returns a fresh list of strings.  No I/O,
;; no buffer state, no filesystem checks -- workspace existence
;; validation is the caller's responsibility (see Rule 2).
;;
;; The composed argument order matches the historical bulk
;; implementation:
;;
;;   (append BASE-CMD
;;           (when WS    '("--workspace-root" WS))
;;           (when MODEL '("--model" MODEL))
;;           '("--resume" SID))
;;
;; This ordering matters at the integration boundary: any future
;; auggie flags that interact with workspace selection (env-vars,
;; secrets-root, etc.) must come *before* `--resume' so the resumed
;; conversation sees the same execution context as a fresh session.
;;
;; Single-responsibility (SOLID): this module knows how to *compose*
;; a resume command line and nothing else.  The bulk caller owns:
;; (a) resolving the saved per-conversation model override,
;; (b) validating the workspace directory,
;; (c) wiring the result into a `:client-maker' closure that
;;     survives the dynamic-binding regime in `default.el',
;; (d) starting the shell + setting up the post-create timer.

;;; Code:

(defun decknix--resume-command-build (base-cmd workspace model session-id)
  "Build the auggie ACP command line for a session resume.

BASE-CMD is the upstream `agent-shell-auggie-acp-command' list
(may be nil).  WORKSPACE, when a non-empty string, injects
`--workspace-root WORKSPACE' before any model/resume args; nil or
the empty string omit the flag.  MODEL, when a non-empty string,
injects `--model MODEL'; nil omits the flag so auggie falls back to
the global default in settings.json.  SESSION-ID is appended last
as `--resume SESSION-ID'.

Returns a fresh list of strings; BASE-CMD is not mutated."
  (let ((ws-args (when (and (stringp workspace)
                            (not (string-empty-p workspace)))
                   (list "--workspace-root" workspace)))
        (model-args (when (and (stringp model)
                               (not (string-empty-p model)))
                      (list "--model" model)))
        (resume-args (list "--resume" session-id)))
    (append base-cmd ws-args model-args resume-args)))

(provide 'decknix-agent-resume-command)
;;; decknix-agent-resume-command.el ends here
