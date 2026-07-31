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

(defun decknix--agent-broker-should-wrap-p (provider-id)
  "Non-nil when a PROVIDER-ID session should be brokered.
Gated on `decknix-agent-broker-enable' and the provider being `claude-code'
(the separate-bridge provider M3b targets first)."
  (and decknix-agent-broker-enable (eq provider-id 'claude-code)))

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

(defun decknix--agent-broker-key-for-resume (provider-id conv-key)
  "Return the broker key to reattach a resumed PROVIDER-ID session, or nil.
Reuses the key persisted for CONV-KEY (so we reattach the same broker); falls
back to a fresh key when none was recorded."
  (when (decknix--agent-broker-should-wrap-p provider-id)
    (or (decknix--agent-broker-key-for-conv-key conv-key)
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

(provide 'decknix-agent-session-broker)
;;; decknix-agent-session-broker.el ends here
