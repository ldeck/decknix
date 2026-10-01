;;; decknix-agent-broker-rehydrate-page-test.el --- Backwards paging -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The paging rule, pinned because the alternative is unusable rather than
;; merely slow: the longest live broker log measured 95872 lines, so a
;; replay that starts at the beginning blocks the open of every resumed
;; session.  The window therefore reads BACKWARDS from the live attach
;; marker, and older turns load on demand.
;;
;; It counts TURNS, not lines, so the window always lands on a turn
;; boundary.  That is what keeps a `tool_call_update' with the `tool_call'
;; it updates: measured on a real log, only 9 of 10764 updates reference an
;; earlier turn.

;;; Code:

(require 'ert)
(require 'decknix-agent-broker-rehydrate)

(defun decknix-page-test--log (&rest lines) (apply #'list lines))

(defconst decknix-page-test--stop
  "{\"id\":1,\"result\":{\"stopReason\":\"end_turn\"}}")

(defun decknix-page-test--chunk (text)
  (format "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"%s\"}}}}"
          text))

;; --- the window reads backwards from the attach marker ----------------

(ert-deftest decknix-page--turns-zero-is-the-inflight-tail-only ()
  (let* ((log (decknix-page-test--log
               (decknix-page-test--chunk "old")
               decknix-page-test--stop
               (decknix-page-test--chunk "inflight")
               "# client attached"))
         (page (decknix--agent-broker-page log 0)))
    (should (= 1 (length (cdr page))))))

(ert-deftest decknix-page--each-turn-steps-one-boundary-further-back ()
  "The point of paging: asking for more reaches further back, and the
count must grow rather than stay pinned to the last turn."
  (let* ((log (decknix-page-test--log
               (decknix-page-test--chunk "t1")
               decknix-page-test--stop
               (decknix-page-test--chunk "t2")
               decknix-page-test--stop
               (decknix-page-test--chunk "t3")
               "# client attached")))
    (should (= 1 (length (cdr (decknix--agent-broker-page log 0)))))
    (should (= 2 (length (cdr (decknix--agent-broker-page log 1)))))
    (should (= 3 (length (cdr (decknix--agent-broker-page log 2)))))))

(ert-deftest decknix-page--a-short-log-replays-whole-rather-than-empty ()
  "Asking for more turns than exist must not return nothing; a young
session has little history and should show all of it."
  (let* ((log (decknix-page-test--log
               (decknix-page-test--chunk "only")
               "# client attached"))
         (page (decknix--agent-broker-page log 50)))
    (should (= 1 (length (cdr page))))))

(ert-deftest decknix-page--never-replays-past-the-attach-marker ()
  "Everything after the marker is delivered live by the broker, so
replaying it would print the output twice."
  (let* ((log (decknix-page-test--log
               (decknix-page-test--chunk "before")
               "# client attached"
               (decknix-page-test--chunk "live")))
         (page (decknix--agent-broker-page log 5)))
    (should (= 1 (length (cdr page))))))

(ert-deftest decknix-page--no-attach-marker-is-nil-not-a-full-replay ()
  "Failing open here would replay an entire 95872-line log."
  (should-not (decknix--agent-broker-page
               (decknix-page-test--log (decknix-page-test--chunk "x")) 5)))

(ert-deftest decknix-page--start-index-lets-the-caller-ask-for-the-next-page ()
  "`replay-more' continues from this index; if it did not move, loading
more would re-render the same turns."
  (let* ((log (decknix-page-test--log
               (decknix-page-test--chunk "t1")
               decknix-page-test--stop
               (decknix-page-test--chunk "t2")
               decknix-page-test--stop
               (decknix-page-test--chunk "t3")
               "# client attached"))
         (near (car (decknix--agent-broker-page log 0)))
         (far  (car (decknix--agent-broker-page log 2))))
    (should (< far near))))

(ert-deftest decknix-page--session-meta-kinds-are-not-replayed ()
  "Usage and command-list updates are not content; replaying them would
re-announce slash commands on every resume."
  (let* ((log (decknix-page-test--log
               "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"usage_update\"}}}"
               "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"available_commands_update\"}}}"
               "# client attached")))
    (should-not (cdr (decknix--agent-broker-page log 5)))))

(ert-deftest decknix-page--malformed-lines-are-skipped-not-fatal ()
  "A broker log is a live append-only file and can hold a torn last line."
  (let* ((log (decknix-page-test--log
               "{not json"
               ""
               (decknix-page-test--chunk "ok")
               "# client attached")))
    (should (= 1 (length (cdr (decknix--agent-broker-page log 5)))))))

(provide 'decknix-agent-broker-rehydrate-page-test)
;;; decknix-agent-broker-rehydrate-page-test.el ends here
