;;; decknix-agent-continuity-test.el --- Restored conversation after a reattach -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Pins how a reattached session's conversation is rebuilt: the broker log
;; split into turns, each turn's prompt found in the transcript by its
;; closing text (not by counting), the bounded read, the state derived from
;; the last turn, and the staggered render queue.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-continuity)

;; -- fixtures ------------------------------------------------------------

(defconst decknix-cont-test--stop "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}")

(defun decknix-cont-test--chunk (text)
  (format "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":%s}}}}"
          (json-encode text)))

(defun decknix-cont-test--tool (id status)
  (format "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"%s\",\"status\":\"%s\"}}}"
          id status))

(defun decknix-cont-test--permission (id)
  (format "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session/request_permission\",\"params\":{\"toolCall\":{\"toolCallId\":\"%s\",\"status\":\"pending\"},\"options\":[]}}"
          id))

(defun decknix-cont-test--user (text &rest extra)
  (json-encode `((type . "user") ,@extra
                 (message (role . "user") (content . ,text)))))

(defun decknix-cont-test--assistant (text)
  (json-encode `((type . "assistant")
                 (message (role . "assistant")
                          (content . [((type . "text") (text . ,text))])))))

(defun decknix-cont-test--texts (page)
  (mapcar #'decknix--continuity-turn-text (plist-get page :turns)))

;; -- the broker log as turns -----------------------------------------------

(ert-deftest decknix-cont/turns-split-at-boundaries-and-keep-inflight ()
  (let ((page (decknix--continuity-turns
               (list (decknix-cont-test--chunk "one") decknix-cont-test--stop
                     (decknix-cont-test--chunk "two") decknix-cont-test--stop
                     (decknix-cont-test--chunk "thr") "# client attached"
                     (decknix-cont-test--chunk "live, not replayed"))
               5)))
    (should (equal (decknix-cont-test--texts page) '("one" "two" "thr")))
    (should (equal (mapcar (lambda (tn) (plist-get tn :committed)) (plist-get page :turns))
                   '(t t nil)))
    (should (equal (plist-get (car (plist-get page :turns)) :stop-reason) "end_turn"))))

(ert-deftest decknix-cont/turns-bounded-with-the-turn-before-as-anchor ()
  "Only TURNS committed turns are rendered; the one before is the anchor."
  (let ((page (decknix--continuity-turns
               (list (decknix-cont-test--chunk "t1") decknix-cont-test--stop
                     (decknix-cont-test--chunk "t2") decknix-cont-test--stop
                     (decknix-cont-test--chunk "t3") decknix-cont-test--stop
                     "# client attached")
               2)))
    (should (equal (decknix-cont-test--texts page) '("t2" "t3")))
    (should (equal (plist-get page :anchor) "t1"))))

(ert-deftest decknix-cont/turns-nil-without-an-attach-marker ()
  (should-not (decknix--continuity-turns (list (decknix-cont-test--chunk "x")) 3)))

(ert-deftest decknix-cont/unanswered-permission-is-pending ()
  (let ((page (decknix--continuity-turns
               (list decknix-cont-test--stop
                     (decknix-cont-test--tool "tc1" "pending")
                     (decknix-cont-test--permission "tc1")
                     "# client attached")
               3)))
    (should (equal (decknix--continuity-permission-tool-id (plist-get page :pending))
                   "tc1"))))

(ert-deftest decknix-cont/answered-or-committed-permission-is-not-pending ()
  (dolist (after (list (decknix-cont-test--tool "tc1" "completed")
                       decknix-cont-test--stop))
    (should-not
     (plist-get (decknix--continuity-turns
                 (list (decknix-cont-test--permission "tc1") after "# client attached")
                 3)
                :pending))))

;; -- the transcript tail ---------------------------------------------------

(ert-deftest decknix-cont/transcript-entries-keep-prompts-and-replies-only ()
  (let ((entries (decknix--continuity-transcript-entries
                  (list (decknix-cont-test--user "typed")
                        (decknix-cont-test--user "meta" '(isMeta . t))
                        (decknix-cont-test--user "sub" '(isSidechain . t))
                        (json-encode '((type . "user")
                                       (message (content . [((type . "tool_result") (content . "x"))]))))
                        (decknix-cont-test--assistant "reply")
                        "not json"))))
    (should (equal entries '((user . "typed") (assistant . "reply"))))))

(ert-deftest decknix-cont/prompt-text-drops-injected-entries ()
  (should (equal (decknix--continuity-prompt-text
                  '("<task-notification>x</task-notification>" "1"))
                 "1"))
  (should (equal (decknix--continuity-prompt-text '("<task-notification>x</task-notification>"))
                 "[background task notification]"))
  (should (equal (decknix--continuity-prompt-text
                  '("<command-name>/standup</command-name><command-args>hx</command-args>"))
                 "/standup hx"))
  (should-not (decknix--continuity-prompt-text nil)))

;; -- pairing turns with prompts ----------------------------------------------

(ert-deftest decknix-cont/pairing-anchors-on-closing-text-not-count ()
  "The real shape: a notification lands mid-turn as a user entry.  Pairing
by count shifts every prompt one turn; anchoring does not."
  (let* ((turns (plist-get (decknix--continuity-turns
                            (list (decknix-cont-test--chunk "Done A. Reply 1.") decknix-cont-test--stop
                                  (decknix-cont-test--chunk "Done B. Reply 1.") decknix-cont-test--stop
                                  "# client attached")
                            5)
                           :turns))
         (entries (decknix--continuity-transcript-entries
                   (list (decknix-cont-test--user "do A")
                         (decknix-cont-test--assistant "working on A")
                         (decknix-cont-test--user "<task-notification>t</task-notification>")
                         (decknix-cont-test--assistant "Done A. Reply 1.")
                         (decknix-cont-test--user "1")
                         (decknix-cont-test--user "<task-notification>u</task-notification>")
                         (decknix-cont-test--assistant "Done B. Reply 1."))))
         (pairs (decknix--continuity-pair turns entries)))
    (should (equal (mapcar #'car pairs) '("do A" "1")))))

(ert-deftest decknix-cont/inflight-turn-takes-the-prompts-after-the-last-reply ()
  (let* ((turns (plist-get (decknix--continuity-turns
                            (list (decknix-cont-test--chunk "earlier.") decknix-cont-test--stop
                                  (decknix-cont-test--chunk "partial")
                                  "# client attached")
                            5)
                           :turns))
         (entries (decknix--continuity-transcript-entries
                   (list (decknix-cont-test--user "first")
                         (decknix-cont-test--assistant "earlier.")
                         (decknix-cont-test--user "now this"))))
         (pairs (decknix--continuity-pair turns entries)))
    (should (equal (mapcar #'car pairs) '("first" "now this")))))

(ert-deftest decknix-cont/unmatched-turn-renders-without-a-prompt ()
  (let ((pairs (decknix--continuity-pair
                (list (list :notes nil :committed t)) nil)))
    (should (equal (mapcar #'car pairs) '(nil)))))

(ert-deftest decknix-cont/notifications-put-the-prompt-before-its-turn ()
  (let* ((turn (list :notes '(n1 n2) :committed t))
         (notes (decknix--continuity-notifications (list (cons "hi" turn) (cons nil turn)))))
    (should (equal (length notes) 5))
    (should (equal (let-alist (car notes) .params.update.sessionUpdate) "user_message_chunk"))
    (should (equal (let-alist (car notes) .params.update.content.text) "hi"))
    (should (equal (cdr notes) '(n1 n2 n1 n2)))))

;; -- state from the replayed last turn ----------------------------------------

(ert-deftest decknix-cont/restored-turns-only-when-the-last-turn-committed ()
  (let ((done (list :notes (list (decknix--agent-broker-parse-json-line
                                   (decknix-cont-test--chunk "Proceed? Reply 1 or 2.")))
                    :committed t))
        (live (list :notes nil :committed nil)))
    (should (equal (decknix--continuity-restored-turns (list (cons "go" done)))
                   '(("go" . "Proceed? Reply 1 or 2."))))
    (should-not (decknix--continuity-restored-turns
                 (list (cons "go" done) (cons "more" live))))))

(ert-deftest decknix-cont/apply-facts-sets-the-asking-flags ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'decknix-agent-turn-restored-facts)
               (lambda (turns)
                 (should (equal turns '(("go" . "Which one?"))))
                 (list :question t :text "Which one?" :answered nil))))
      (decknix--continuity-apply-facts
       (list (cons "go" (list :notes (list (decknix--agent-broker-parse-json-line
                                            (decknix-cont-test--chunk "Which one?")))
                              :committed t))))
      (should (eq decknix--agent-turn-question t))
      (should (equal decknix--agent-turn-closing-text "Which one?")))))

(ert-deftest decknix-cont/last-turn-ignores-turns-before-the-attach ()
  "A turn abandoned at the restart must not borrow the previous turn's question."
  (should-not (decknix--continuity-last-turn
               (list (decknix-cont-test--chunk "old q?") decknix-cont-test--stop
                     "# client attached" (decknix-cont-test--chunk "never finished"))))
  (should (equal (decknix--continuity-turn-text
                  (decknix--continuity-last-turn
                   (list decknix-cont-test--stop "# client attached"
                         (decknix-cont-test--chunk "finished live") decknix-cont-test--stop)))
                 "finished live")))

;; -- render: ordering, bounds, permission ---------------------------------------

(defmacro decknix-cont-test--with-session (log-lines transcript-lines &rest body)
  "Run BODY in a buffer whose broker log and transcript hold the given lines."
  (declare (indent 2))
  `(let* ((dir (make-temp-file "cont" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
          (decknix--agent-broker-dir-memo nil)
          (transcript (expand-file-name "t.jsonl" dir))
          (rendered nil) (requests nil) (verbosity nil)
          (state (list (cons :pending-restore nil) (cons :session '((:id . "sid"))))))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "decknix/agent-sockets" dir) t)
           (with-temp-file (decknix--agent-broker-log-path "k")
             (insert (string-join ,log-lines "\n") "\n"))
           (with-temp-file transcript (insert (string-join ,transcript-lines "\n") "\n"))
           (with-temp-buffer
             (setq-local decknix--agent-broker-key "k")
             (cl-letf* (((symbol-function 'agent-shell--state) (lambda () state))
                        ((symbol-function 'agent-shell--make-pending-restore) (lambda () (list nil)))
                        ((symbol-function 'agent-shell--append-restore-notification)
                         (lambda (_s n) (push n rendered)))
                        ((symbol-function 'agent-shell--pop-pending-restore)
                         (lambda (_s) (list '(held-1) '(held-2))))
                        ((symbol-function 'agent-shell--render-pending-restore)
                         (lambda (s) (setq verbosity (agent-shell--effective-restore-verbosity s))))
                        ((symbol-function 'agent-shell--effective-restore-verbosity)
                         (lambda (_s) 'minimal))
                        ((symbol-function 'agent-shell--on-request)
                         (cl-function (lambda (&key state acp-request)
                                        (ignore state) (push acp-request requests))))
                        (decknix-agent-continuity-transcript-path-function
                         (lambda (_p _sid) transcript)))
               ,@body)))
       (delete-directory dir t))))

(defun decknix-cont-test--kinds (notes)
  (mapcar (lambda (n) (if (symbolp n) n
                        (or (let-alist n .params.update.content.text) 'other)))
          notes))

(ert-deftest decknix-cont/render-puts-history-then-held-live-output ()
  (decknix-cont-test--with-session
      (list (decknix-cont-test--chunk "A done.") decknix-cont-test--stop
            (decknix-cont-test--chunk "streaming") "# client attached")
      (list (decknix-cont-test--user "do A") (decknix-cont-test--assistant "A done.")
            (decknix-cont-test--user "do B"))
    (should (= 2 (decknix-agent-continuity-render (current-buffer))))
    (should (equal (decknix-cont-test--kinds (reverse rendered))
                   '("do A" "A done." "do B" "streaming" held-1 held-2)))
    (should (eq verbosity 'full))
    (should (= decknix--continuity-rendered 2))
    (should (timerp decknix--continuity-settle-timer))
    (cancel-timer decknix--continuity-settle-timer)))

(ert-deftest decknix-cont/render-reads-a-bounded-window ()
  "Old turns beyond the byte window and the turn count are not rendered."
  (let ((lines (append (cl-loop for i below 200
                                append (list (decknix-cont-test--chunk (format "old-%d %s" i (make-string 200 ?x)))
                                             decknix-cont-test--stop))
                       (list (decknix-cont-test--chunk "newest") decknix-cont-test--stop
                             "# client attached"))))
    (decknix-cont-test--with-session lines nil
      (let ((decknix-agent-broker-replay-window-bytes 4096)
            (decknix-agent-continuity-turns 2))
        (decknix-agent-continuity-render (current-buffer))
        (should (= decknix--continuity-rendered 2))
        (should (equal (car (last (decknix-cont-test--kinds (reverse rendered)) 3)) "newest"))
        (should-not (seq-some (lambda (k) (and (stringp k) (string-prefix-p "old-0 " k)))
                              (decknix-cont-test--kinds rendered)))))))

(ert-deftest decknix-cont/render-reshows-a-pending-permission ()
  (decknix-cont-test--with-session
      (list decknix-cont-test--stop (decknix-cont-test--tool "tc9" "pending")
            (decknix-cont-test--permission "tc9") "# client attached")
      nil
    (decknix-agent-continuity-render (current-buffer))
    (should (= 1 (length requests)))
    (should (equal (alist-get 'id (car requests)) 7))
    (should decknix--continuity-permission)
    (when (timerp decknix--continuity-settle-timer)
      (cancel-timer decknix--continuity-settle-timer))))

;; -- the staggered queue ------------------------------------------------------

(ert-deftest decknix-cont/next-action-defers-while-typing ()
  (should (eq (decknix--continuity-next-action nil nil) 'idle))
  (should (eq (decknix--continuity-next-action '(a b) t) 'wait))
  (should (equal (decknix--continuity-next-action '(a b) nil) '(run a b))))

(ert-deftest decknix-cont/tick-renders-one-buffer-and-schedules-the-next ()
  (let* ((a (generate-new-buffer " a")) (b (generate-new-buffer " b"))
         (decknix--continuity-queue (list a b))
         (decknix--continuity-timer nil)
         (done nil))
    (unwind-protect
        (cl-letf (((symbol-function 'decknix-agent-continuity-render)
                   (lambda (buf) (push buf done)))
                  ((symbol-function 'input-pending-p) (lambda (&rest _) nil)))
          (decknix--continuity-tick)
          (should (equal done (list a)))
          (should (equal decknix--continuity-queue (list b)))
          (should (timerp decknix--continuity-timer))
          (cancel-timer decknix--continuity-timer)
          (setq decknix--continuity-timer nil)
          (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
            (decknix--continuity-tick)
            (should (equal done (list a)))
            (should (timerp decknix--continuity-timer))
            (cancel-timer decknix--continuity-timer)))
      (kill-buffer a) (kill-buffer b))))

(provide 'decknix-agent-continuity-test)
;;; decknix-agent-continuity-test.el ends here
