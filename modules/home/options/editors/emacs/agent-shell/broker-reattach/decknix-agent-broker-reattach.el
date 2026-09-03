;;; decknix-agent-broker-reattach.el --- Reattach to live brokers at startup -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, broker, session

;;; Commentary:
;;
;; ldeck/decknix#151, the missing half.
;;
;; The broker already does its job: it holds the ACP bridge in a
;; daemonised process outside Emacs' tree, and it survives its spawner
;; (verified directly -- killed the spawning subshell, the broker stayed
;; alive at ppid=1).  What has never existed is the other side: nothing
;; at daemon start looks for those brokers.  Measured after an Emacs
;; restart with four brokers running:
;;
;;     agent buffers after: (no agent buffers)
;;
;; So the agents were alive, holding whole conversations, with nothing
;; attached.  From the user's chair the sessions had vanished; resuming
;; them minted NEW session ids and spawned NEW brokers, orphaning the
;; originals.  One socket directory held 5 live and 8 dead entries after
;; a few days of that.
;;
;; This module is the discovery and decision layer for startup reattach:
;;
;;   - read each broker's JSON sidecar (sid / socket / pid / cwd);
;;   - keep only those whose pid is still alive;
;;   - drop any Emacs is already attached to, so one conversation never
;;     ends up with two buffers racing the same socket;
;;   - carry the conversation key when the store knows it, so the
;;     restored buffer can be named and tagged rather than anonymous;
;;   - report the dead ones so they can be swept.
;;
;; Pure: every function takes its inputs and returns a decision.  The
;; buffer creation and the socat attach live in the heredoc per
;; AGENTS.md Rule 2.

;;; Code:

(require 'json)
(require 'subr-x)

(defun decknix--broker-reattach-parse-sidecar (text)
  "Parse a broker sidecar TEXT into an alist, or nil.

The broker writes `<socket>.json' alongside its socket:

    {\"sid\":\"s-...\",\"socket\":\"/...\",\"pid\":2177,
     \"cwd\":\"/Users/ldeck/Code/nurturecloud\",
     \"created\":\"2026-09-02T22:13:43Z\",\"bridge\":\"claude-agent-acp\"}

Returns nil rather than signalling on anything unparseable: this runs
over every file in the socket directory at startup, and one truncated
sidecar (a broker killed mid-write) must not stop the rest from being
recovered."
  (when (and text (stringp text) (not (string-empty-p text)))
    (condition-case nil
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-key-type 'symbol))
          (json-read-from-string text))
      (error nil))))

(defun decknix--broker-reattach-plan (brokers attached conv-key-fn)
  "Return the brokers to attach to, as an alist of (KEY . CONV-KEY).

BROKERS is an alist of (KEY . LIVE-P).  ATTACHED is the list of keys
Emacs already holds a buffer for.  CONV-KEY-FN maps a broker key to its
conversation key, or nil when unknown; it is injected so the decision is
testable without the tag store.

Order is preserved so the caller attaches oldest-first, matching the
order the sockets were created.

Two exclusions, and only two:

  DEAD      the socket directory accumulates entries -- 8 of 13 dead in
            one real sample -- and attaching to a corpse hangs a buffer
            on a socket nobody is serving.

  ATTACHED  reattaching a broker Emacs already has gives one
            conversation two buffers racing the same socket.

A broker whose conversation is UNKNOWN is still attached: losing the
name is cosmetic, abandoning a live agent mid-turn is not."
  (let (plan)
    (dolist (entry brokers)
      (let ((key (car entry))
            (live (cdr entry)))
        (when (and live (not (member key attached)))
          (push (cons key (and conv-key-fn (funcall conv-key-fn key))) plan))))
    (nreverse plan)))

(defun decknix--broker-reattach-stale (brokers)
  "Return the keys in BROKERS whose broker is no longer running.

BROKERS is an alist of (KEY . LIVE-P).  These accumulate every time a
session ends or Emacs restarts without reattaching; without a sweep the
socket directory grows without bound (94 files in one observed case).
Reported rather than deleted here so the caller decides the policy."
  (let (stale)
    (dolist (entry brokers)
      (unless (cdr entry) (push (car entry) stale)))
    (nreverse stale)))


;; ---------------------------------------------------------------------------
;; Live layer -- enumerate the socket directory
;; ---------------------------------------------------------------------------

(defvar decknix--agent-broker-key)
(declare-function decknix--agent-broker-dir "decknix-agent-broker-rehydrate" ())
(declare-function decknix--agent-broker-live-p "decknix-agent-broker-rehydrate" (key))
(declare-function decknix--agent-broker-key-for-conv-key
                  "decknix-agent-session-broker" (conv-key))
(declare-function decknix--agent-tags-read "decknix-agent-tags-store" ())
(declare-function decknix--agent-tags-conversations "decknix-agent-tags-store" (store))

(defun decknix--broker-reattach-keys ()
  "Return an alist of (KEY . LIVE-P) for every broker in the socket dir."
  (let* ((dir (and (fboundp 'decknix--agent-broker-dir)
                   (decknix--agent-broker-dir)))
         (out nil))
    (when (and dir (file-directory-p dir))
      (dolist (f (sort (directory-files dir nil "\\.sock\\'") #'string<))
        (let ((key (file-name-sans-extension f)))
          (push (cons key
                      (and (fboundp 'decknix--agent-broker-live-p)
                           (decknix--agent-broker-live-p key)))
                out))))
    (nreverse out)))

(defun decknix--broker-reattach-attached-keys ()
  "Return the broker keys Emacs already has a buffer attached to."
  (let (keys)
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (and (derived-mode-p 'agent-shell-mode)
                   (bound-and-true-p decknix--agent-broker-key))
          (push decknix--agent-broker-key keys))))
    keys))

(defun decknix--broker-reattach-conv-key-for (key)
  "Return the conversation key whose broker is KEY, or nil.
Reverse lookup over the tag store, which records `brokerKey' per
conversation (`decknix--agent-broker-save-key-for-conv-key')."
  (ignore-errors
    (let* ((store (decknix--agent-tags-read))
           (convs (and store (decknix--agent-tags-conversations store)))
           (found nil))
      (when (hash-table-p convs)
        (maphash (lambda (ck entry)
                   (when (and (not found)
                              (hash-table-p entry)
                              (equal (gethash "brokerKey" entry) key))
                     (setq found ck)))
                 convs))
      found)))

;;;###autoload
(defun decknix-agent-broker-reattach-report ()
  "Report which brokers are live, attached, orphaned, or stale.

Read-only.  Run this before wiring reattach into startup, and after a
restart, to see what recovery WOULD do without doing it."
  (interactive)
  (let* ((brokers (decknix--broker-reattach-keys))
         (attached (decknix--broker-reattach-attached-keys))
         (plan (decknix--broker-reattach-plan
                brokers attached #'decknix--broker-reattach-conv-key-for))
         (stale (decknix--broker-reattach-stale brokers)))
    (message
     (concat
      (format "brokers=%d live=%d attached=%d orphaned=%d stale=%d"
              (length brokers)
              (seq-count #'cdr brokers)
              (length attached)
              (length plan)
              (length stale))
      (when plan
        (concat "\nwould attach:\n"
                (mapconcat (lambda (p)
                             (format "  %s  conv=%s" (car p) (or (cdr p) "<unknown>")))
                           plan "\n")))))
    (list :brokers (length brokers) :live (seq-count #'cdr brokers)
          :attached (length attached) :orphaned (length plan)
          :stale (length stale) :plan plan)))


;; ---------------------------------------------------------------------------
;; Reattach -- resume each orphaned conversation onto its LIVE broker
;; ---------------------------------------------------------------------------

(declare-function decknix--agent-latest-session-id-for-conv-key
                  "decknix-agent-conv-resolve" (conv-key))
(declare-function decknix--agent-workspace-for-conv-key
                  "decknix-agent-session-workspace" (conv-key))
(declare-function decknix--agent-tags-for-conv-key
                  "decknix-agent-tags-read" (conv-key))
(declare-function decknix--agent-session-derive-name
                  "decknix-agent-session-format"
                  (tags &optional workspace branch first-message sid))
(declare-function decknix--agent-session-resume
                  "decknix-agent-shell-main-session"
                  (session-id history-count &optional display-name workspace
                   conv-key search-term))
(defvar decknix-agent-session-history-count)

(defcustom decknix-agent-broker-reattach-on-startup t
  "Reattach to surviving brokers when the daemon starts.

The broker holds its bridge outside Emacs' process tree, so a restart
leaves live agents with nothing attached.  Without this you get them back
only by hand (`p' then `M-RET' in the sidebar), and that RESUMES them --
minting a new session id and, until 414cf87, spawning a second broker
beside the one still running.

Reattach instead goes through the normal resume path with the
conversation's SAVED broker key, so `decknix-agent-broker-attach' finds a
live socket and connects to it rather than spawning.  The agent, and any
turn it was mid-way through, is the same process you left."
  :type 'boolean :group 'decknix)

(defcustom decknix-agent-broker-reattach-delay 12
  "Seconds after startup before reattaching.

Must be LATER than the orphan reaper's own 8s timer
\(`decknix-agent-reap-orphaned-bridges'), so reattach sees the settled
set of survivors rather than racing a sweep that is still deciding what
to kill."
  :type 'number :group 'decknix)

(defun decknix--broker-reattach-one (key conv-key)
  "Reattach the conversation CONV-KEY to its live broker KEY.
Returns non-nil when a resume was dispatched.

Verifies that CONV-KEY's SAVED broker key is still KEY before resuming.
The mapping is derived by scanning the store for a conversation whose
`brokerKey' matches, and a conversation can be re-brokered (a resume
while the old broker was dead mints a fresh key), so a stale reverse
match would attach a conversation to another agent.  Cheap check, and
the failure it prevents is putting your session in front of a different
conversation's model."
  (when (and conv-key
             (or (not (fboundp 'decknix--agent-broker-key-for-conv-key))
                 (equal key (decknix--agent-broker-key-for-conv-key conv-key))))
    (let* ((sid (ignore-errors
                  (decknix--agent-latest-session-id-for-conv-key conv-key)))
           (ws (ignore-errors (decknix--agent-workspace-for-conv-key conv-key)))
           (tags (ignore-errors (decknix--agent-tags-for-conv-key conv-key)))
           (name (ignore-errors
                   (decknix--agent-session-derive-name tags ws nil nil sid))))
      (when sid
        (ignore-errors
          (decknix--agent-session-resume
           sid (if (boundp 'decknix-agent-session-history-count)
                   decknix-agent-session-history-count 0)
           name ws conv-key))
        t))))

;;;###autoload
(defun decknix-agent-broker-reattach-all (&optional quiet)
  "Reattach every orphaned live broker to its conversation.

Idempotent: brokers Emacs is already attached to are skipped, so running
it twice cannot give one conversation two buffers.  A broker whose
conversation is unknown is left alone HERE (unlike the plan, which
includes it) -- without a conv-key there is no session id to resume and
no name to give the buffer, so there is nothing to reattach TO.  It stays
visible in `decknix-agent-broker-reattach-report'.

With QUIET, does not message."
  (interactive)
  (let* ((brokers (decknix--broker-reattach-keys))
         (attached (decknix--broker-reattach-attached-keys))
         (plan (decknix--broker-reattach-plan
                brokers attached #'decknix--broker-reattach-conv-key-for))
         (done 0) (skipped 0))
    (dolist (entry plan)
      (if (decknix--broker-reattach-one (car entry) (cdr entry))
          (setq done (1+ done))
        (setq skipped (1+ skipped))))
    (unless quiet
      (message "decknix: reattached %d broker%s%s"
               done (if (= done 1) "" "s")
               (if (> skipped 0)
                   (format " (%d skipped: no conversation)" skipped) "")))
    done))

(defun decknix-agent-broker-reattach-maybe-on-startup ()
  "Arm the startup reattach when enabled.  Idempotent.

Runs QUIET so a no-op start (the common case: nothing survived, or
everything is already attached) says nothing.  But a startup that DID
reattach leaves a line in *Messages*, because otherwise there is no way
after the fact to tell a timer-driven reattach from the user having
pressed `p' `M-RET' by hand -- both leave the session id unchanged, so
the observable end state is identical.  That ambiguity made the
acceptance test for this feature inconclusive; one message removes it."
  (when decknix-agent-broker-reattach-on-startup
    (run-with-timer
     decknix-agent-broker-reattach-delay nil
     (lambda ()
       (let ((done (ignore-errors (decknix-agent-broker-reattach-all t))))
         (when (and (numberp done) (> done 0))
           (message "decknix: startup reattached %d broker%s"
                    done (if (= done 1) "" "s"))))))))

(provide 'decknix-agent-broker-reattach)
;;; decknix-agent-broker-reattach.el ends here
