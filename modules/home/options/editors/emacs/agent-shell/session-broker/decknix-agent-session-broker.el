;;; decknix-agent-session-broker.el --- Brokered-session key store + command wrap -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-store "0.1"))
;; Keywords: agent, agent-shell, decknix, acp, broker

;;; Commentary:
;;
;; Foundation for #151 M3b — running Claude sessions through the agent broker so
;; the bridge (and its turn) survives Emacs / `decknix switch'.  Brokering is a
;; per-session opt-in: when `decknix-agent-broker-enable' is on, a Claude
;; session's ACP `:command' is routed through the `decknix-agent-broker-attach'
;; wrapper under a stable KEY, so acp.el attaches to a persistent, daemonised
;; broker instead of spawning the bridge in Emacs' process tree.
;;
;; This module owns:
;;   * the enable flag + the wrapper command name;
;;   * `decknix--agent-broker-generate-key' — a fresh, unique, filename-safe key;
;;   * `decknix--agent-broker-wrap-command' — the pure argv transform
;;     (WRAPPER KEY "--" . ARGV);
;;   * `decknix--agent-broker-should-wrap-p' — the enable + provider gate;
;;   * a per-conversation KEY store (`…-key-for-conv-key' / `…-save-key-…'),
;;     mirroring the mode/model stores, so a resumed session reattaches to the
;;     SAME broker it created (the key is generated at launch of a new session
;;     and persisted against its conv-key at post-create, reused on resume).
;;
;; The pure helpers are ERT-tested; the store mirrors `decknix-agent-session-mode'.
;; Wiring the transform into `decknix--agent-command-build' + the new/resume
;; lifecycle stays in main-bulk / the heredoc per AGENTS.md Rule 2.

;;; Code:

(require 'decknix-agent-tags-store)
(require 'subr-x)

(defvar decknix-agent-broker-enable nil
  "When non-nil, launch Claude sessions through the agent broker (#151).
Seeded from `programs.emacs.decknix.agentShell.broker.enable'.  Default off:
sessions launch the bridge directly in Emacs' process tree, exactly as before.")

(defvar decknix-agent-broker-attach-command "decknix-agent-broker-attach"
  "The spawn-or-attach wrapper acp.el's `:command' is routed through when
brokering.  It spawns the daemonised broker (holding the real bridge) on the
first attach and re-attaches on every reconnect.")

(defvar-local decknix--agent-broker-key nil
  "This brokered session's key (its broker socket name), or nil when not brokered.
Set at launch; persisted against the conv-key once the first message establishes
it, so resume reattaches the same broker.")

(defun decknix--agent-broker-generate-key ()
  "Return a fresh, unique, filename-safe broker session key.
Used to name the broker's unix socket; persisted against the conv-key so resume
reattaches the same broker."
  (format "s-%s-%s"
          (format-time-string "%Y%m%d%H%M%S")
          (substring (secure-hash 'sha256
                                  (format "%s-%s-%s"
                                          (emacs-pid) (float-time) (random)))
                     0 10)))

(defun decknix--agent-broker-wrap-command (argv key)
  "Wrap ARGV so acp.el attaches through the broker under KEY.
Returns (WRAPPER KEY \"--\" . ARGV).  Returns ARGV unchanged when KEY is nil/blank
or ARGV is empty, so a missing key can never silently drop the bridge command."
  (if (and key (stringp key) (not (string-empty-p key)) argv)
      (append (list decknix-agent-broker-attach-command key "--") argv)
    argv))

(defconst decknix--agent-broker-providers '(claude-code pi)
  "Providers whose sessions are brokered.

Membership tracks one property: the provider runs a SEPARATE ACP bridge
process, which is the thing a broker can hold open across an Emacs
restart.  Both `claude-code' (claude-agent-acp) and `pi' (pi-acp) do.
`auggie' does not, so a broker would have nothing to keep alive.

The wrapper itself (`decknix--agent-broker-wrap-command') is a pure argv
transform and provider-agnostic; the gate named `claude-code' alone
because M3b shipped it first, not because pi was unsuitable.  That
omission showed up as the pi session being the single buffer that did
not return from a restart.")

(defun decknix--agent-broker-should-wrap-p (provider-id)
  "Non-nil when a PROVIDER-ID session should be brokered.
Gated on `decknix-agent-broker-enable' and PROVIDER-ID running a separate
ACP bridge (see `decknix--agent-broker-providers')."
  (and decknix-agent-broker-enable
       (memq provider-id decknix--agent-broker-providers)
       t))

;; ── Per-conversation broker-key store (mirrors decknix-agent-session-mode) ──

(defun decknix--agent-broker-key-for-conv-key (conv-key)
  "Return the saved broker key for CONV-KEY, or nil."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (gethash "brokerKey" entry)))))

(defun decknix--agent-broker-key-for-new (provider-id)
  "Return a fresh broker key for a NEW PROVIDER-ID session.
Nil when the session should not be brokered (toggle off / non-Claude)."
  (when (decknix--agent-broker-should-wrap-p provider-id)
    (decknix--agent-broker-generate-key)))

(defun decknix--agent-broker-scan-key-for-session-id (convs session-id)
  "Pure: earliest broker key among CONVS entries that list SESSION-ID, or nil.
CONVS is the conversations hash-table (conv-key -> entry hash-table).  When
several entries match (a transient left by an earlier mis-keyed resume) the
timestamp-ordered key name sorts the ORIGINAL broker first — the one still
holding the session — so prefer the lexicographically smallest key."
  (let ((keys nil))
    (when (hash-table-p convs)
      (maphash
       (lambda (_ entry)
         (when (and (hash-table-p entry)
                    (member session-id (gethash "sessions" entry)))
           (let ((bk (gethash "brokerKey" entry)))
             (when (and bk (stringp bk) (not (string-empty-p bk)))
               (push bk keys)))))
       convs))
    (car (sort keys #'string<))))

(defun decknix--agent-broker-key-for-session-id (session-id)
  "Return the saved broker key linked to SESSION-ID, or nil.
The session id is stable across launch and resume, unlike the conv-key
\(derived from the first message, which the live write path and the
transcript-read path hash differently for long or edited prompts) — so
this is the RELIABLE reattach link.  See
`decknix--agent-broker-scan-key-for-session-id'."
  (when (and session-id (stringp session-id) (not (string-empty-p session-id)))
    (decknix--agent-broker-scan-key-for-session-id
     (decknix--agent-tags-conversations (decknix--agent-tags-read))
     session-id)))

(defun decknix--agent-broker-key-for-resume (provider-id conv-key &optional session-id)
  "Return the broker key to reattach a resumed PROVIDER-ID session, or nil.
Resolve by the stable SESSION-ID first (reliable across launch/resume),
then fall back to CONV-KEY (fragile: the first-message hash can diverge
between the live write path and the transcript-read path, e.g. long
prompts truncated differently), and finally to a fresh key when nothing
was recorded."
  (when (decknix--agent-broker-should-wrap-p provider-id)
    (or (and session-id (decknix--agent-broker-key-for-session-id session-id))
        (decknix--agent-broker-key-for-conv-key conv-key)
        (decknix--agent-broker-generate-key))))

(defun decknix--agent-broker-save-key-for-conv-key (conv-key key)
  "Persist broker KEY for CONV-KEY in agent-sessions.json."
  (when (and conv-key key)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "tags" nil h)
                        (puthash "sessions" nil h)
                        h))))
      (puthash "brokerKey" key entry)
      (puthash conv-key entry convs)
      (decknix--agent-tags-write store))))

;; ── Recorded review coordinates ──────────────────────────────────────
;;
;; Co-resident with the broker key because they are the same kind of
;; fact: immutable session metadata persisted against the conv-key,
;; written once at launch and read back after a restart.

(defun decknix--agent-review-pr-for-conv-key (conv-key)
  "Return the recorded `repo#number' this conversation reviews, or nil."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (gethash "reviewPr" entry)))))

(defun decknix--agent-save-review-pr-for-conv-key (conv-key pr-key)
  "Persist PR-KEY (`repo#number') as CONV-KEY's review target.

Recorded so \"does this PR already have a reviewer?\" can be answered
from a fact rather than from a display string.  The buffer name is
rewritten on reattach and the tags are edited by hand, so both drift;
this does not."
  (when (and conv-key pr-key)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "tags" nil h)
                        (puthash "sessions" nil h)
                        h))))
      (puthash "reviewPr" pr-key entry)
      (puthash conv-key entry convs)
      (decknix--agent-tags-write store))))

(provide 'decknix-agent-session-broker)
;;; decknix-agent-session-broker.el ends here
