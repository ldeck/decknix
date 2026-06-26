;;; decknix-agent-fork-test.el --- Tests for fork context hand-off -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for `decknix-agent-fork' — the pure helpers that
;; build the context hand-off message injected as the first user message
;; of a forked session (`decknix-agent-session-fork', C-c s f / C-c A f).

;;; Code:

(require 'ert)
(require 'decknix-agent-fork)

;; --- source-data-path ---

(ert-deftest decknix-fork--data-path-joins-dir-id-extension ()
  "Path is sessions-dir / <session-id><extension>."
  (should (equal "/home/u/.augment/sessions/abc123.json"
                 (decknix--agent-fork-source-data-path
                  "/home/u/.augment/sessions" ".json" "abc123"))))

(ert-deftest decknix-fork--data-path-nil-without-session-id ()
  "No session-id -> nil (no specific file can be named)."
  (should-not (decknix--agent-fork-source-data-path
               "/home/u/.augment/sessions" ".json" nil))
  (should-not (decknix--agent-fork-source-data-path
               "/home/u/.augment/sessions" ".json" "")))

(ert-deftest decknix-fork--data-path-tolerates-nil-extension ()
  "A nil/empty extension just yields the bare id under the dir."
  (should (equal "/home/u/.pi/sessions/sid"
                 (decknix--agent-fork-source-data-path
                  "/home/u/.pi/sessions" nil "sid"))))

(ert-deftest decknix-fork--data-path-bare-id-without-dir ()
  "No sessions-dir -> just the filename, no leading slash."
  (should (equal "abc123.json"
                 (decknix--agent-fork-source-data-path nil ".json" "abc123"))))

;; --- handoff-message ---

(ert-deftest decknix-fork--message-includes-all-known-fields ()
  "A fully-populated hand-off names the provider, id, path and tags."
  (let ((msg (decknix--agent-fork-handoff-message
              "Auggie" "abc123"
              "/home/u/.augment/sessions/abc123.json"
              '("review" "decknix"))))
    (should (string-match-p "forked" msg))
    (should (string-match-p "Auggie" msg))
    (should (string-match-p "abc123" msg))
    (should (string-match-p "/home/u/.augment/sessions/abc123.json" msg))
    (should (string-match-p "#review" msg))
    (should (string-match-p "#decknix" msg))))

(ert-deftest decknix-fork--message-omits-unknown-fields ()
  "Unknown id / path / tags lines are dropped, not rendered empty."
  (let ((msg (decknix--agent-fork-handoff-message "Claude Code" nil nil nil)))
    (should (string-match-p "Claude Code" msg))
    (should-not (string-match-p "session id:" msg))
    (should-not (string-match-p "session data:" msg))
    (should-not (string-match-p "tags:" msg))))

(ert-deftest decknix-fork--message-handles-unknown-provider ()
  "Nil provider label degrades to a generic phrasing, no `nil' token."
  (let ((msg (decknix--agent-fork-handoff-message nil "abc123" nil nil)))
    (should (string-match-p "forked" msg))
    (should-not (string-match-p "nil" msg))
    (should (string-match-p "abc123" msg))))

(ert-deftest decknix-fork--message-is-plain-text ()
  "No markdown emphasis / headings leak into the prompt."
  (let ((msg (decknix--agent-fork-handoff-message
              "Pi" "s1" "/p/s1.json" '("x"))))
    (should-not (string-match-p "\\*\\*" msg))
    (should-not (string-match-p "^#[^a-z]" msg))))

(ert-deftest decknix-fork--message-id-uniqueness ()
  "Different source ids yield different messages (conv-key won't collide)."
  (should-not
   (equal (decknix--agent-fork-handoff-message "Auggie" "id-a" nil nil)
          (decknix--agent-fork-handoff-message "Auggie" "id-b" nil nil))))

(provide 'decknix-agent-fork-test)
;;; decknix-agent-fork-test.el ends here
