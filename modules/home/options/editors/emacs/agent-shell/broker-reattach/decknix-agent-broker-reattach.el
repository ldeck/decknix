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

(provide 'decknix-agent-broker-reattach)
;;; decknix-agent-broker-reattach.el ends here
