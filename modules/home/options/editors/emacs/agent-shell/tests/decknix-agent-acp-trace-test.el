;;; decknix-agent-acp-trace-test.el --- Tests for the ACP trace -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-acp-trace "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the PURE layer of the ACP turn/status trace: summarizing an
;; ACP notification alist, per-kind detail strings, session shortening, and
;; line formatting.  No advice, no ring, no file I/O.

;;; Code:

(require 'ert)
(require 'decknix-agent-acp-trace)

;; -- summarize ----------------------------------------------------------

(ert-deftest decknix-agent-acp-trace/summarize-session-update ()
  "A session/update summarizes to its sessionUpdate kind + sessionId + detail."
  (let* ((n '((method . "session/update")
              (params . ((sessionId . "d8df9eb9-aaaa")
                         (update . ((sessionUpdate . "agent_message_chunk")))))))
         (s (decknix--agent-acp-trace-summarize n)))
    (should (equal "agent_message_chunk" (plist-get s :label)))
    (should (equal "d8df9eb9-aaaa" (plist-get s :session)))
    (should (equal "message" (plist-get s :detail)))))

(ert-deftest decknix-agent-acp-trace/summarize-non-update-uses-method ()
  "A non-session/update notification is labelled by its JSON-RPC method."
  (let ((s (decknix--agent-acp-trace-summarize
            '((method . "session/request_permission")
              (params . ((sessionId . "abc")))))))
    (should (equal "session/request_permission" (plist-get s :label)))
    (should (equal "abc" (plist-get s :session)))))

(ert-deftest decknix-agent-acp-trace/summarize-nil-without-method ()
  "No method -> nil (nothing to record)."
  (should-not (decknix--agent-acp-trace-summarize '((params . ((sessionId . "x")))))))

;; -- detail -------------------------------------------------------------

(ert-deftest decknix-agent-acp-trace/detail-per-kind ()
  "Detail strings are compact and kind-specific."
  (should (equal "message" (decknix--agent-acp-trace-detail "agent_message_chunk" nil)))
  (should (equal "thought" (decknix--agent-acp-trace-detail "agent_thought_chunk" nil)))
  (should (equal "commands" (decknix--agent-acp-trace-detail "available_commands_update" nil)))
  (should (equal "mode=default"
                 (decknix--agent-acp-trace-detail
                  "current_mode_update" '((currentModeId . "default")))))
  (should (string-match-p "tool Read completed"
                          (decknix--agent-acp-trace-detail
                           "tool_call" '((title . "Read") (status . "completed")))))
  (should (equal "" (decknix--agent-acp-trace-detail nil nil))))

;; -- short session ------------------------------------------------------

(ert-deftest decknix-agent-acp-trace/short-session ()
  (should (equal "d8df9eb9" (decknix--agent-acp-trace-short "d8df9eb9-75b4-4329")))
  (should (equal "abc" (decknix--agent-acp-trace-short "abc")))
  (should (equal "" (decknix--agent-acp-trace-short nil)))
  (should (equal "" (decknix--agent-acp-trace-short ""))))

;; -- format -------------------------------------------------------------

(ert-deftest decknix-agent-acp-trace/format-line-shape ()
  "A formatted line carries the label, short sid, and detail."
  (let ((line (decknix--agent-acp-trace-format
               '(:time 0 :label "tool_call" :session "d8df9eb9-zz" :detail "tool Read"))))
    (should (string-match-p "tool_call" line))
    (should (string-match-p "sid=d8df9eb9" line))
    (should (string-match-p "tool Read" line))))

(ert-deftest decknix-agent-acp-trace/format-no-session-omits-sid ()
  "With no session, the line has no `sid=' token."
  (let ((line (decknix--agent-acp-trace-format
               '(:time 0 :label "TURN-END" :detail "*agent*"))))
    (should (string-match-p "TURN-END" line))
    (should-not (string-match-p "sid=" line))))

(provide 'decknix-agent-acp-trace-test)
;;; decknix-agent-acp-trace-test.el ends here
