;;; decknix-agent-resume-primer-test.el --- Tests for resume primer -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for `decknix-agent-resume-primer' — the pure
;; helper that builds the continuation primer auto-sent as the first
;; user message of a resumed session whose provider bridge does not
;; restore prior context into the model (Claude, Pi).

;;; Code:

(require 'ert)
(require 'decknix-agent-resume-primer)

;; --- nil / empty session-id ---

(ert-deftest decknix-resume-primer--nil-without-session-id ()
  "No session-id -> nil (nothing to resume, nothing to prime)."
  (should-not (decknix--agent-resume-primer-message
               "Claude" nil "/p/abc.jsonl" '("x") "hi"))
  (should-not (decknix--agent-resume-primer-message
               "Claude" "" "/p/abc.jsonl" '("x") "hi")))

;; --- header / continuation framing ---

(ert-deftest decknix-resume-primer--names-provider-and-continuation ()
  "Header names the provider and frames this as a resumed continuation."
  (let ((msg (decknix--agent-resume-primer-message
              "Claude" "sid-1" nil nil nil)))
    (should (stringp msg))
    (should (string-match-p "resumed continuation" msg))
    (should (string-match-p "Claude" msg))
    (should (string-match-p "not a new one" msg))))

(ert-deftest decknix-resume-primer--degrades-without-label ()
  "A nil/empty provider label degrades to generic phrasing, no \"nil\"."
  (let ((msg (decknix--agent-resume-primer-message
              nil "sid-1" nil nil nil)))
    (should (stringp msg))
    (should (string-match-p "earlier agent session" msg))
    (should-not (string-match-p "nil" msg))))

;; --- optional detail lines ---

(ert-deftest decknix-resume-primer--includes-session-id ()
  "The source session id is always present."
  (should (string-match-p
           "Source session id: sid-42"
           (decknix--agent-resume-primer-message
            "Claude" "sid-42" nil nil nil))))

(ert-deftest decknix-resume-primer--includes-transcript-when-present ()
  "A non-empty data-path renders a transcript pointer line."
  (should (string-match-p
           "Prior transcript: /home/u/.claude/projects/sid.jsonl"
           (decknix--agent-resume-primer-message
            "Claude" "sid" "/home/u/.claude/projects/sid.jsonl" nil nil))))

(ert-deftest decknix-resume-primer--omits-transcript-when-absent ()
  "A nil/empty data-path omits the transcript line entirely."
  (let ((msg (decknix--agent-resume-primer-message "Claude" "sid" nil nil nil)))
    (should-not (string-match-p "Prior transcript:" msg)))
  (let ((msg (decknix--agent-resume-primer-message "Claude" "sid" "" nil nil)))
    (should-not (string-match-p "Prior transcript:" msg))))

(ert-deftest decknix-resume-primer--renders-tags-with-hash ()
  "Tags render space-joined with a leading # each; absent when nil."
  (should (string-match-p
           "Source tags: #review #decknix"
           (decknix--agent-resume-primer-message
            "Claude" "sid" nil '("review" "decknix") nil)))
  (should-not (string-match-p
               "Source tags:"
               (decknix--agent-resume-primer-message
                "Claude" "sid" nil nil nil))))

;; --- last-user-message grounding cue ---

(ert-deftest decknix-resume-primer--includes-last-message-cue ()
  "A non-blank last user message renders a one-line grounding cue."
  (let ((msg (decknix--agent-resume-primer-message
              "Claude" "sid" nil nil "Fix the resume bug")))
    (should (string-match-p "Most recently in this conversation:" msg))
    (should (string-match-p "Fix the resume bug" msg))))

(ert-deftest decknix-resume-primer--omits-blank-last-message ()
  "A nil or whitespace-only last message omits the cue block."
  (let ((msg (decknix--agent-resume-primer-message "Claude" "sid" nil nil nil)))
    (should-not (string-match-p "Most recently" msg)))
  (let ((msg (decknix--agent-resume-primer-message
              "Claude" "sid" nil nil "   \n\t ")))
    (should-not (string-match-p "Most recently" msg))))

(ert-deftest decknix-resume-primer--collapses-multiline-last-message ()
  "A multi-line last message is collapsed to a single line."
  (let ((msg (decknix--agent-resume-primer-message
              "Claude" "sid" nil nil "line one\nline two\n  line three")))
    (should (string-match-p "line one line two line three" msg))))

(ert-deftest decknix-resume-primer--truncates-long-last-message ()
  "A very long last message is truncated (does not bloat the prompt)."
  (let* ((long (make-string 2000 ?x))
         (msg (decknix--agent-resume-primer-message
               "Claude" "sid" nil nil long)))
    ;; The excerpt is capped well under the raw length and ends with the
    ;; truncation ellipsis.
    (should (< (length msg) 1200))
    (should (string-match-p "\\.\\.\\." msg))))

;; --- closing instruction keeps the model from charging ahead ---

(ert-deftest decknix-resume-primer--asks-to-wait ()
  "The primer tells the model to summarise and wait, not run ahead."
  (let ((msg (decknix--agent-resume-primer-message "Claude" "sid" nil nil nil)))
    (should (string-match-p "wait for my next instruction" msg))
    (should (string-match-p "fresh start" msg))))

(provide 'decknix-agent-resume-primer-test)
;;; decknix-agent-resume-primer-test.el ends here
