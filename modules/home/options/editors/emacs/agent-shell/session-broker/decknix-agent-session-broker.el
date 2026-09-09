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

;; ── Stopping a broker ────────────────────────────────────────────────
;;
;; Brokering redefined what killing an agent buffer means.  The buffer's
;; process is the socat client, so killing it DETACHES: the broker and
;; the agent behind it survive.  That is exactly what #151 is for, and
;; exactly wrong for "quit" -- which is what auto-close calls.  The
;; result was a silent leak: an auto-closed review left its agent running
;; indefinitely, socket, pidfile and megabytes of log intact.
;;
;; So the two intents need separating.  Detach keeps the agent; quit ends
;; it and must say so explicitly, because `kill-buffer' no longer does.

(declare-function decknix--agent-broker-pidfile-path
                  "decknix-agent-broker-rehydrate" (key))

(defun decknix--agent-broker-stop-p (key other-keys)
  "Non-nil when the broker KEY should be terminated on quit.

OTHER-KEYS are the broker keys of the OTHER live agent buffers.  A broker
that another buffer is still attached to is spared: stopping it would
kill an agent someone is watching in a window they never touched.  Pure,
so both conditions are testable without processes."
  (and key (stringp key) (not (string-empty-p key))
       (not (member key other-keys))
       t))

(defun decknix--agent-broker-pid (key)
  "Return the pid recorded in KEY's pidfile, or nil."
  (when-let* ((pf (and (fboundp 'decknix--agent-broker-pidfile-path)
                       (decknix--agent-broker-pidfile-path key)))
              ((file-readable-p pf))
              (pid (ignore-errors
                     (string-to-number
                      (string-trim
                       (with-temp-buffer (insert-file-contents pf)
                                         (buffer-string)))))))
    (and (integerp pid) (> pid 0) pid)))

(defun decknix-agent-broker-stop (key)
  "Terminate the broker KEY and clean up its socket and pidfile.

Returns non-nil when a process was signalled.  Killing the broker takes
the bridge with it: the bridge is its child, so it dies with the process
group rather than needing a second signal.

Leaves the LOG in place.  It is the record of what the agent did while
detached, and the rehydrate path reads it; a stopped session is exactly
when you are most likely to want it."
  (when-let* ((pid (decknix--agent-broker-pid key)))
    (ignore-errors (signal-process pid 'TERM))
    (let ((pf (and (fboundp 'decknix--agent-broker-pidfile-path)
                   (decknix--agent-broker-pidfile-path key))))
      (when (and pf (file-exists-p pf)) (ignore-errors (delete-file pf)))
      (when pf
        (let ((sock (file-name-sans-extension pf)))
          (when (file-exists-p sock) (ignore-errors (delete-file sock))))))
    pid))

;; ── Recorded review coordinates ──────────────────────────────────────
;;
;; Co-resident with the broker key because they are the same kind of
;; fact: immutable session metadata persisted against the conv-key,
;; written once at launch and read back after a restart.

(defun decknix--agent-review-pr-normalize (value)
  "Return VALUE as a list of `repo#number' keys.

The field was written as a single string before grouped dispatch existed,
and those entries are still on disk, so a bare string reads back as a
one-element list rather than being discarded.  Pure, and the only place
that shape question is answered."
  (cond
   ((null value) nil)
   ((stringp value) (if (string-empty-p value) nil (list value)))
   ((listp value) (seq-filter (lambda (s) (and (stringp s)
                                               (not (string-empty-p s))))
                              value))
   (t nil)))

(defun decknix--agent-review-prs-for-conv-key (conv-key)
  "Return the `repo#number' keys this conversation reviews, as a list.

A list because one session can cover several PRs: grouped dispatch sends
a service's dependency bumps to a single agent so they can be sequenced,
conflict-checked or fixed together, which per-PR sessions structurally
cannot do."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (decknix--agent-review-pr-normalize (gethash "reviewPr" entry))))))

(defun decknix--agent-review-pr-for-conv-key (conv-key)
  "Return the FIRST `repo#number' CONV-KEY reviews, or nil.
Compatibility shim for callers that predate grouped sessions; prefer
`decknix--agent-review-prs-for-conv-key', which cannot silently drop the
rest of a group."
  (car (decknix--agent-review-prs-for-conv-key conv-key)))

(defun decknix--agent-conv-key-for-review-pr (pr-key)
  "Return (CONV-KEY . LATEST-SESSION-ID) for the conversation reviewing PR-KEY.

Answers \"have I reviewed this PR before?\" from recorded coordinates
rather than from a live buffer.  The launcher previously asked only
whether a SESSION was live, so closing a review and re-triggering it
started over with no history -- the conversation was still on record and
nothing looked for it."
  (let* ((store (decknix--agent-tags-read))
         (convs (decknix--agent-tags-conversations store))
         found)
    (when (hash-table-p convs)
      (maphash
       (lambda (ck entry)
         (when (and (not found) (hash-table-p entry))
           (let ((prs (decknix--agent-review-pr-normalize
                       (gethash "reviewPr" entry)))
                 (sessions (gethash "sessions" entry)))
             (when (and (member pr-key prs) sessions)
               (setq found (cons ck (car (last sessions))))))))
       convs))
    found))

(defun decknix--agent-save-review-prs-for-conv-key (conv-key pr-keys)
  "Persist PR-KEYS as CONV-KEY's review targets.

PR-KEYS may be a single `repo#number' string or a list of them; either
way a list is stored, so the on-disk shape stops depending on how many
PRs a session happened to start with.

Recorded so \"does this PR already have a reviewer?\" can be answered
from a fact rather than from a display string.  The buffer name is
rewritten on reattach and the tags are edited by hand, so both drift;
this does not."
  (let ((keys (decknix--agent-review-pr-normalize pr-keys)))
    (when (and conv-key keys)
      (let* ((store (decknix--agent-tags-read))
             (convs (decknix--agent-tags-conversations store))
             (entry (or (gethash conv-key convs)
                        (let ((h (make-hash-table :test 'equal)))
                          (puthash "tags" nil h)
                          (puthash "sessions" nil h)
                          h))))
        (puthash "reviewPr" keys entry)
        (puthash conv-key entry convs)
        (decknix--agent-tags-write store)))))

(defun decknix--agent-save-review-pr-for-conv-key (conv-key pr-key)
  "Persist PR-KEY as CONV-KEY's review target.  See the plural form."
  (decknix--agent-save-review-prs-for-conv-key conv-key pr-key))

(provide 'decknix-agent-session-broker)
;;; decknix-agent-session-broker.el ends here
