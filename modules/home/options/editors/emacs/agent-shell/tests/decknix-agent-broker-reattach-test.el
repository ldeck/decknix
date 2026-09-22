;;; decknix-agent-broker-reattach-test.el --- Tests for startup reattach -*- lexical-binding: t -*-

;;; Commentary:
;;
;; ldeck/decknix#151: on daemon start, ATTACH to brokers that are still
;; holding live agent bridges instead of leaving them orphaned.
;;
;; Measured before writing this.  The broker survives its spawner
;; (verified: killed the spawning subshell, broker stayed at ppid=1), and
;; `decknix-agent-broker-attach' can connect to a socket.  But nothing at
;; startup enumerates the socket directory, so after an Emacs restart:
;;
;;     agent buffers after: (no agent buffers)
;;
;; while four brokers sat running with nothing attached.  The user's
;; sessions appear lost; resuming them mints NEW session ids and spawns
;; NEW brokers, so the originals leak.  One socket dir held 5 live and 8
;; dead entries after a few days of this.
;;
;; Only the pure discovery/decision layer is tested: which sockets are
;; live, which are already attached, and what to do with each.  The
;; buffer creation and socat attach live in the heredoc per AGENTS.md
;; Rule 2.

;;; Code:

(require 'ert)
(require 'decknix-agent-broker-reattach)

;; ---------------------------------------------------------------------
;; Sidecar parsing
;; ---------------------------------------------------------------------

(ert-deftest decknix-reattach--parses-a-sidecar ()
  "The broker writes a JSON sidecar naming its socket, pid and cwd."
  (let ((s (decknix--broker-reattach-parse-sidecar
            "{\"sid\":\"s-1\",\"socket\":\"/tmp/s-1.sock\",\"pid\":42,
              \"cwd\":\"/w/repo\",\"created\":\"2026-09-02T22:13:43Z\",
              \"bridge\":\"claude-agent-acp\"}")))
    (should (equal (alist-get 'sid s) "s-1"))
    (should (equal (alist-get 'cwd s) "/w/repo"))
    (should (equal (alist-get 'pid s) 42))))

(ert-deftest decknix-reattach--bad-sidecar-is-nil-not-an-error ()
  "A truncated or absent sidecar must not break startup."
  (should-not (decknix--broker-reattach-parse-sidecar "{not json"))
  (should-not (decknix--broker-reattach-parse-sidecar ""))
  (should-not (decknix--broker-reattach-parse-sidecar nil)))

;; ---------------------------------------------------------------------
;; Which brokers are candidates
;; ---------------------------------------------------------------------

(ert-deftest decknix-reattach--only-live-brokers ()
  "A broker whose pid is gone is not a candidate.
The socket dir accumulates dead entries -- 8 of 13 in one real sample --
so filtering on liveness is what keeps startup from attaching to
corpses."
  (let ((plan (decknix--broker-reattach-plan
               '(("s-live" . t) ("s-dead" . nil))
               nil nil)))
    (should (equal (mapcar #'car plan) '("s-live")))))

(ert-deftest decknix-reattach--skips-already-attached ()
  "A broker Emacs is already attached to is left alone.
Reattaching twice would give one conversation two buffers racing on the
same socket."
  (let ((plan (decknix--broker-reattach-plan
               '(("s-a" . t) ("s-b" . t))
               '("s-a")                    ; already attached
               nil)))
    (should (equal (mapcar #'car plan) '("s-b")))))

(ert-deftest decknix-reattach--carries-the-conversation ()
  "Each candidate carries the conv-key its broker belongs to, when known.
That is what lets the restored buffer be named and tagged correctly
instead of appearing as an anonymous shell."
  (let ((plan (decknix--broker-reattach-plan
               '(("s-a" . t))
               nil
               (lambda (key) (when (equal key "s-a") "conv-123")))))
    (should (equal (cdr (assoc "s-a" plan)) "conv-123"))))

(ert-deftest decknix-reattach--unknown-conversation-still-attaches ()
  "A broker with no recorded conversation is still worth attaching to.
Losing the name is a cosmetic cost; abandoning a live agent that holds
an in-flight turn is not."
  (let ((plan (decknix--broker-reattach-plan
               '(("s-orphan" . t)) nil (lambda (_) nil))))
    (should (equal (mapcar #'car plan) '("s-orphan")))
    (should-not (cdr (assoc "s-orphan" plan)))))

(ert-deftest decknix-reattach--empty-inputs ()
  "No brokers, or all dead, means no work and no error."
  (should-not (decknix--broker-reattach-plan nil nil nil))
  (should-not (decknix--broker-reattach-plan '(("a" . nil)) nil nil)))

;; ---------------------------------------------------------------------
;; Stale cleanup
;; ---------------------------------------------------------------------

(ert-deftest decknix-reattach--stale-are-those-with-dead-pids ()
  "Dead entries are reported so they can be swept.
They accumulate every time a session ends or Emacs restarts without
reattaching; without a sweep the directory grows without bound."
  (should (equal (decknix--broker-reattach-stale
                  '(("s-live" . t) ("s-dead1" . nil) ("s-dead2" . nil)))
                 '("s-dead1" "s-dead2"))))

(ert-deftest decknix-reattach--nothing-stale-is-empty ()
  (should-not (decknix--broker-reattach-stale '(("s-live" . t)))))


;; --- a reattach that lands on a dead agent must not leave a row ------
;;
;; Reported 2026-09-22 by comparing the Live list across a switch: a
;; `broker/claude/test\=' session from 4 AUGUST came back, seven weeks
;; later, in a buffer whose process was already dead -- and sat in the
;; Live list, in red, as `killed\='.
;;
;; Reattach keeps brokers "whose pid is still alive", and that is the
;; flaw: liveness is tested at the BROKER, not at the agent behind it. A
;; broker is a relay built to outlive things; when its bridge exits the
;; broker can stay up, pass the pid test, and be reattached to nothing.

(ert-deftest decknix-broker-dead-p--killed-is-dead ()
  "`killed' is the status a reattach-to-nothing produces."
  (should (decknix--broker-reattach-dead-p "killed")))

(ert-deftest decknix-broker-dead-p--live-states-are-not ()
  "Every state a working session can be in must survive."
  (dolist (s '("ready" "working" "asking" "waiting" "initializing" "finished"))
    (should-not (decknix--broker-reattach-dead-p s))))

(ert-deftest decknix-broker-dead-p--unknown-is-not-dead ()
  "`unknown' means the status could not be read, not that it is dead.

Deliberately conservative: killing a buffer we merely failed to classify
would lose a live conversation, which is far worse than leaving one stale
row on screen."
  (should-not (decknix--broker-reattach-dead-p "unknown"))
  (should-not (decknix--broker-reattach-dead-p nil))
  (should-not (decknix--broker-reattach-dead-p "")))

(provide 'decknix-agent-broker-reattach-test)
;;; decknix-agent-broker-reattach-test.el ends here
