;;; decknix-agent-session-restart-test.el --- Tests for session restart -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-restart "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the pure name-extraction helper backing
;; `decknix-agent-session-restart'.  The interactive command itself
;; drives windows / processes and is exercised manually; the parser is
;; the testable contract: given a session buffer name, recover the
;; user-facing name so the restarted buffer reclaims its label.

;;; Code:

(require 'ert)
(require 'decknix-agent-session-restart)

(ert-deftest decknix-agent-session-restart-name--auggie ()
  "`*Auggie: NAME*' yields NAME."
  (should (equal (decknix--agent-session-restart-name-from-buffer
                  "*Auggie: my-feature*")
                 "my-feature")))

(ert-deftest decknix-agent-session-restart-name--claude ()
  "Provider prefix other than Auggie is handled (`*Claude: ...*')."
  (should (equal (decknix--agent-session-restart-name-from-buffer
                  "*Claude: pr-decknix-42*")
                 "pr-decknix-42")))

(ert-deftest decknix-agent-session-restart-name--strips-uniquifier ()
  "An Emacs `<N>' uniquifier after the closing `*' is ignored."
  (should (equal (decknix--agent-session-restart-name-from-buffer
                  "*Pi: a*<2>")
                 "a")))

(ert-deftest decknix-agent-session-restart-name--keeps-inner-colon ()
  "A colon inside the name is preserved (match stops at the final `*')."
  (should (equal (decknix--agent-session-restart-name-from-buffer
                  "*Auggie: a: b*")
                 "a: b")))

(ert-deftest decknix-agent-session-restart-name--upstream-default-is-nil ()
  "The upstream `<Provider> Agent @ <ws>' default is not our form."
  (should (null (decknix--agent-session-restart-name-from-buffer
                 "Auggie Agent @ ~/tools/decknix"))))

(ert-deftest decknix-agent-session-restart-name--non-session-is-nil ()
  "Plain buffers without the `*<Provider>: <name>*' shape return nil."
  (should (null (decknix--agent-session-restart-name-from-buffer "*scratch*")))
  (should (null (decknix--agent-session-restart-name-from-buffer "foo.el"))))

(ert-deftest decknix-agent-session-restart-name--nil-input ()
  "Nil input safely returns nil."
  (should (null (decknix--agent-session-restart-name-from-buffer nil))))


;; -- orphan reaper must never kill a live broker ----------------------
;;
;; `broker.enable' makes sessions survive an Emacs restart by holding the
;; bridge in a daemonised broker.  The reaper then killed them 8s after
;; every daemon start, because the broker's command line is
;;
;;     decknix-agent-broker --daemonize --socket <sock> -- claude-agent-acp
;;
;; which CONTAINS the bridge name, and being daemonised its ppid is 1 --
;; both of the reaper's conditions.  Measured on the live machine before
;; the fix: 7 of 7 live brokers were reapable.  That is why every switch
;; lost its sessions and `p M-RET' was always needed.

(ert-deftest decknix-reaper/spares-a-live-broker ()
  "A daemonised broker is never reaped, though it matches on both counts."
  (should-not
   (decknix-agent--reapable-bridge-p
    "1" 50200 999
    "decknix-agent-broker --daemonize --socket /x/s-1.sock --session-id s-1 -- claude-agent-acp")))

(ert-deftest decknix-reaper/still-reaps-a-genuine-orphan ()
  "A bare re-parented bridge is still garbage and still collected.
This is the leak the reaper was added for (09df9ff)."
  (should
   (decknix-agent--reapable-bridge-p
    "1" 4242 999
    "/nix/store/xxx-claude-agent-acp/bin/claude-agent-acp")))

(ert-deftest decknix-reaper/spares-bridges-owned-by-a-live-emacs ()
  "A bridge whose parent is a daemon (ppid != 1) is in use."
  (should-not
   (decknix-agent--reapable-bridge-p
    "48695" 49011 999
    "/nix/store/xxx-claude-agent-acp/bin/claude-agent-acp")))

(ert-deftest decknix-reaper/never-reaps-itself ()
  "Self-preservation: this Emacs is not a bridge to collect."
  (should-not (decknix-agent--reapable-bridge-p "1" 999 999 "claude-agent-acp")))

(ert-deftest decknix-reaper/ignores-unrelated-processes ()
  "Anything that is not a bridge is left alone."
  (should-not (decknix-agent--reapable-bridge-p "1" 4242 999 "/usr/bin/ssh-agent"))
  (should-not (decknix-agent--reapable-bridge-p "1" 4242 999 "node /some/other/thing.js")))

(provide 'decknix-agent-session-restart-test)
;;; decknix-agent-session-restart-test.el ends here
