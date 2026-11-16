;;; decknix-agent-acp-trace-test.el --- Tests for the ACP trace -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-acp-trace "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the PURE layer of the ACP turn/status trace: summarizing an
;; ACP notification alist, per-kind detail strings, session shortening, and
;; line formatting, plus the advice callbacks driven through stand-ins that
;; carry upstream's real `&key' signatures.

;;; Code:

(require 'ert)
(require 'cl-lib)
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

;; -- advice callbacks read upstream's real keywords ----------------------
;;
;; Upstream declares `(cl-defun agent-shell--on-notification (&key state
;; acp-notification))' and `(cl-defun agent-shell--on-request (&key state
;; acp-request))'.  The callbacks once read `:notification' and `:request',
;; got nil, and recorded nothing while the trace was switched on.  These
;; stand-ins carry the real signatures, so keyword drift fails here.

(defmacro decknix-agent-acp-trace-test--recording (&rest body)
  "Run BODY with tracing on, an empty ring, and no log file writes."
  `(let ((decknix-agent-acp-trace-enable t)
         (decknix--agent-acp-trace-ring nil)
         (decknix-agent-acp-trace-log-file null-device))
     ,@body))

(cl-defun decknix-agent-acp-trace-test--on-notification (&key state acp-notification)
  (list state acp-notification))

(cl-defun decknix-agent-acp-trace-test--on-request (&key state acp-request)
  (list state acp-request))

(ert-deftest decknix-agent-acp-trace/advice-records-real-notification ()
  (decknix-agent-acp-trace-test--recording
   (advice-add 'decknix-agent-acp-trace-test--on-notification :before
               #'decknix--agent-acp-trace-on-notification)
   (unwind-protect
       (decknix-agent-acp-trace-test--on-notification
        :state nil
        :acp-notification
        '((jsonrpc . "2.0")
          (method . "session/update")
          (params . ((sessionId . "d8df9eb9-aaaa")
                     (update . ((sessionUpdate . "tool_call")
                                (title . "Read")
                                (status . "pending")))))))
     (advice-remove 'decknix-agent-acp-trace-test--on-notification
                    #'decknix--agent-acp-trace-on-notification))
   (let ((event (car decknix--agent-acp-trace-ring)))
     (should (= 1 (length decknix--agent-acp-trace-ring)))
     (should (equal "tool_call" (plist-get event :label)))
     (should (equal "d8df9eb9-aaaa" (plist-get event :session)))
     (should (equal "tool Read pending" (plist-get event :detail))))))

(ert-deftest decknix-agent-acp-trace/advice-records-real-permission-request ()
  (decknix-agent-acp-trace-test--recording
   (advice-add 'decknix-agent-acp-trace-test--on-request :before
               #'decknix--agent-acp-trace-on-request)
   (unwind-protect
       (decknix-agent-acp-trace-test--on-request
        :state nil
        :acp-request
        '((jsonrpc . "2.0")
          (id . 7)
          (method . "session/request_permission")
          (params . ((sessionId . "d8df9eb9-aaaa")))))
     (advice-remove 'decknix-agent-acp-trace-test--on-request
                    #'decknix--agent-acp-trace-on-request))
   (let ((event (car decknix--agent-acp-trace-ring)))
     (should (= 1 (length decknix--agent-acp-trace-ring)))
     (should (equal "REQ session/request_permission" (plist-get event :label)))
     (should (equal "d8df9eb9-aaaa" (plist-get event :session)))
     (should (equal "AWAITING PERMISSION" (plist-get event :detail))))))

(ert-deftest decknix-agent-acp-trace/advice-is-silent-while-disabled ()
  (decknix-agent-acp-trace-test--recording
   (let ((decknix-agent-acp-trace-enable nil))
     (should-not (decknix--agent-acp-trace-on-notification
                  :state nil
                  :acp-notification '((method . "session/update")))))
   (should-not decknix--agent-acp-trace-ring)))

(provide 'decknix-agent-acp-trace-test)
;;; decknix-agent-acp-trace-test.el ends here
