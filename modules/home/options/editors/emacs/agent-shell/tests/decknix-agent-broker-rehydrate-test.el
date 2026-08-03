;;; decknix-agent-broker-rehydrate-test.el --- Tests for broker reattach replay -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-broker-rehydrate "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the pure log-tail parser behind #151 M6 reattach replay:
;; given broker-log lines, `decknix--agent-broker-inflight-notifications'
;; returns exactly the agent-side notifications of the current in-flight
;; turn (after the last committed `stopReason', before the last
;; `# client attached'), filtering markers, handshake results, meta
;; updates and the user prompt.

;;; Code:

(require 'ert)
(require 'decknix-agent-broker-rehydrate)

;; -- fixtures ------------------------------------------------------

(defun decknix-brk-test--update (kind &optional text)
  "A session/update log line of KIND, optionally carrying TEXT."
  (json-serialize
   `((jsonrpc . "2.0")
     (method . "session/update")
     (params . ((sessionId . "sid-1")
                (update . ,(append `((sessionUpdate . ,kind))
                                   (when text
                                     `((content . ((type . "text")
                                                   (text . ,text))))))))))))

(defun decknix-brk-test--result (id &optional stop-reason)
  "A JSON-RPC result log line for ID, optionally with STOP-REASON."
  (json-serialize
   `((jsonrpc . "2.0")
     (id . ,id)
     (result . ,(if stop-reason
                    `((stopReason . ,stop-reason))
                  '((ok . t)))))))

(defun decknix-brk-test--kinds (notes)
  "The `sessionUpdate' kind of each notification in NOTES."
  (mapcar (lambda (n)
            (alist-get 'sessionUpdate
                       (alist-get 'update (alist-get 'params n))))
          notes))

;; -- parse-json-line ----------------------------------------------

(ert-deftest decknix-brk/parse-line--marker-blank-malformed ()
  "Marker, blank and malformed lines parse to nil."
  (should (null (decknix--agent-broker-parse-json-line "# client attached")))
  (should (null (decknix--agent-broker-parse-json-line "")))
  (should (null (decknix--agent-broker-parse-json-line "   ")))
  (should (null (decknix--agent-broker-parse-json-line "{not json"))))

(ert-deftest decknix-brk/parse-line--valid-object ()
  "A valid JSON object parses to a symbol-keyed alist."
  (let ((obj (decknix--agent-broker-parse-json-line
              (decknix-brk-test--update "agent_message_chunk" "hi"))))
    (should (listp obj))
    (should (equal (alist-get 'method obj) "session/update"))))

(ert-deftest decknix-brk/stop-reason-predicate ()
  (should (decknix--agent-broker-result-stop-reason-p
           (decknix--agent-broker-parse-json-line
            (decknix-brk-test--result 4 "end_turn"))))
  (should-not (decknix--agent-broker-result-stop-reason-p
               (decknix--agent-broker-parse-json-line
                (decknix-brk-test--result 3))))
  (should-not (decknix--agent-broker-result-stop-reason-p
               (decknix--agent-broker-parse-json-line
                (decknix-brk-test--update "agent_message_chunk" "x")))))

;; -- inflight-notifications ---------------------------------------

(ert-deftest decknix-brk/inflight--no-attach-marker ()
  "No `# client attached' anywhere -> nothing to replay."
  (should (null (decknix--agent-broker-inflight-notifications
                 (list "# broker up: s"
                       (decknix-brk-test--update "agent_message_chunk" "a"))))))

(ert-deftest decknix-brk/inflight--last-turn-committed ()
  "When the last turn committed before the current attach, replay nothing."
  (let ((lines (list "# broker up"
                     "# client attached"
                     (decknix-brk-test--update "agent_message_chunk" "done")
                     (decknix-brk-test--result 4 "end_turn")
                     "# client detached"
                     "# client attached")))
    (should (null (decknix--agent-broker-inflight-notifications lines)))))

(ert-deftest decknix-brk/inflight--basic-detached-tail ()
  "Agent content that streamed while detached is returned, in order."
  (let* ((lines (list "# broker up"
                      "# client attached"
                      (decknix-brk-test--update "agent_message_chunk" "committed")
                      (decknix-brk-test--result 4 "end_turn") ; boundary
                      "# client detached"
                      (decknix-brk-test--update "tool_call")
                      (decknix-brk-test--update "agent_message_chunk" "1")
                      (decknix-brk-test--update "tool_call_update")
                      "# client attached")) ; current live attach
         (notes (decknix--agent-broker-inflight-notifications lines)))
    (should (equal (decknix-brk-test--kinds notes)
                   '("tool_call" "agent_message_chunk" "tool_call_update")))))

(ert-deftest decknix-brk/inflight--filters-meta-handshake-and-prompt ()
  "Meta updates, handshake results and the user prompt are excluded."
  (let* ((lines (list "# broker up"
                      (decknix-brk-test--result 5 "end_turn") ; boundary
                      "# client detached"
                      (decknix-brk-test--update "usage_update")
                      (decknix-brk-test--update "available_commands_update")
                      (decknix-brk-test--update "config_option_update")
                      (decknix-brk-test--update "session_info_update")
                      (decknix-brk-test--update "user_message_chunk" "prompt")
                      (decknix-brk-test--result 1) ; initialize handshake
                      (decknix-brk-test--update "agent_message_chunk" "real")
                      "# client attached"))
         (notes (decknix--agent-broker-inflight-notifications lines)))
    (should (equal (decknix-brk-test--kinds notes) '("agent_message_chunk")))))

(ert-deftest decknix-brk/inflight--no-prior-boundary-first-turn ()
  "A first turn still in flight (no committed boundary) replays from start."
  (let* ((lines (list "# broker up"
                      "# client attached"
                      (decknix-brk-test--update "agent_message_chunk" "a")
                      "# client detached"
                      (decknix-brk-test--update "agent_message_chunk" "b")
                      "# client attached"))
         (notes (decknix--agent-broker-inflight-notifications lines)))
    ;; both chunks (before and after the mid detach) reach the fresh buffer
    (should (equal (decknix-brk-test--kinds notes)
                   '("agent_message_chunk" "agent_message_chunk")))))

(ert-deftest decknix-brk/inflight--boundary-is-last-attach ()
  "Content after the last attach is NOT replayed (the socket delivers it)."
  (let* ((lines (list "# broker up"
                      (decknix-brk-test--result 4 "end_turn")
                      "# client detached"
                      (decknix-brk-test--update "tool_call")       ; replay
                      "# client attached"                          ; current
                      (decknix-brk-test--update "agent_message_chunk" "live")))
         (notes (decknix--agent-broker-inflight-notifications lines)))
    (should (equal (decknix-brk-test--kinds notes) '("tool_call")))))

(provide 'decknix-agent-broker-rehydrate-test)
;;; decknix-agent-broker-rehydrate-test.el ends here
