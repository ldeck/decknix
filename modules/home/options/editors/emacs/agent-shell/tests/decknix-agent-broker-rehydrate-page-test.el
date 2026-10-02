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
(require 'cl-lib)
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


;; --- is the agent mid-turn? -------------------------------------------

(ert-deftest decknix-inflight--visible-content-after-the-boundary-is-inflight ()
  (should (decknix--agent-broker-inflight-p
           (decknix-page-test--log
            decknix-page-test--stop
            (decknix-page-test--chunk "still going")))))

(ert-deftest decknix-inflight--a-committed-turn-is-not-inflight ()
  (should-not (decknix--agent-broker-inflight-p
               (decknix-page-test--log
                (decknix-page-test--chunk "done")
                decknix-page-test--stop))))

(ert-deftest decknix-inflight--meta-updates-after-a-turn-are-not-inflight ()
  "An IDLE session keeps emitting usage and mode updates after its turn
commits.  Counting those marked all 13 live sessions as working."
  (should-not (decknix--agent-broker-inflight-p
               (decknix-page-test--log
                decknix-page-test--stop
                "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"usage_update\"}}}"
                "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"current_mode_update\"}}}"))))

(ert-deftest decknix-inflight--a-log-with-no-boundary-at-all-is-inflight ()
  "A first turn that has not committed yet."
  (should (decknix--agent-broker-inflight-p
           (decknix-page-test--log (decknix-page-test--chunk "first")))))


;; --- the status check must never read a whole log ---------------------

(ert-deftest decknix-tail--reads-only-the-end-of-the-file ()
  "The status check runs once per session per sidebar refresh.  Reading
whole logs cost 452 MB per refresh across 13 open sessions and made Emacs
unresponsive; the largest single log took 6.8 seconds to read and split."
  (let ((f (make-temp-file "dk-tail")))
    (unwind-protect
        (progn
          (with-temp-file f
            (dotimes (i 50000)
              (insert (format "{\"n\":%d}\n" i))))
          (let* ((size (file-attribute-size (file-attributes f)))
                 (lines (decknix--agent-broker-read-log-tail f 4096)))
            (should (> size 100000))
            ;; Only the tail, so far fewer lines than the file holds.
            (should (< (length lines) 1000))
            ;; And it is the END of the file, not the start.
            (should (string-match-p "4999" (car (last lines))))))
      (delete-file f))))

(ert-deftest decknix-tail--a-window-with-no-boundary-reads-as-working ()
  "Over a bounded window that is the correct inference: a log whose last
64 KB holds no committed turn has been producing output throughout it."
  (should (decknix--agent-broker-inflight-p
           (list (decknix-page-test--chunk "a")
                 (decknix-page-test--chunk "b")))))

(ert-deftest decknix-tail--an-empty-window-is-not-working ()
  (should-not (decknix--agent-broker-inflight-p nil)))

(ert-deftest decknix-tail--missing-file-is-nil-not-an-error ()
  (should-not (decknix--agent-broker-read-log-tail "/nonexistent/x.log")))


;; --- liveness probe must not fork ------------------------------------

(ert-deftest decknix-live--probe-does-not-spawn-a-process ()
  "`call-process' to `kill' ran once per session per status query and
measured 0.33 s for 13 against 0.0000 s for the builtin -- the dominant
cost of a status sweep, and what made the buffer picker lag."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _) (error "status probe must not fork"))))
    ;; A real pidfile for a process we know is alive: this one.
    (let* ((dir (make-temp-file "dk-brk" t))
           (key "s-test")
           (pf (expand-file-name (format "%s.sock.pid" key) dir)))
      (unwind-protect
          (progn
            (with-temp-file pf (insert (number-to-string (emacs-pid))))
            (cl-letf (((symbol-function 'decknix--agent-broker-dir)
                       (lambda () dir)))
              (should (decknix--agent-broker-live-p key))))
        (delete-directory dir t)))))

(ert-deftest decknix-live--a-dead-pid-is-not-live ()
  (let* ((dir (make-temp-file "dk-brk2" t))
         (key "s-dead")
         (pf (expand-file-name (format "%s.sock.pid" key) dir)))
    (unwind-protect
        (progn
          (with-temp-file pf (insert "999999"))
          (cl-letf (((symbol-function 'decknix--agent-broker-dir)
                     (lambda () dir)))
            (should-not (decknix--agent-broker-live-p key))))
      (delete-directory dir t))))

(ert-deftest decknix-live--a-missing-pidfile-is-not-live ()
  (cl-letf (((symbol-function 'decknix--agent-broker-dir)
             (lambda () "/nonexistent")))
    (should-not (decknix--agent-broker-live-p "s-nope"))))

;; --- the working-state cache -----------------------------------------

(ert-deftest decknix-working-cache--an-unchanged-log-is-not-re-read ()
  "Keyed on the log\='s identity, not a clock.  Allocation is the reason:
each miss reads 64 KB, splits it into hundreds of strings and JSON-parses
each one, and at 13 sessions every 2 seconds that churn drives the GC
that interrupts typing."
  (let ((reads 0)
        (decknix--agent-broker-working-cache (make-hash-table :test 'equal))
        (f (make-temp-file "dk-wc")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "{}\n"))
          (cl-letf (((symbol-function 'decknix--agent-broker-log-path)
                     (lambda (_k) f))
                    ((symbol-function 'decknix--agent-broker-read-log-tail)
                     (lambda (&rest _) (setq reads (1+ reads)) nil)))
            (let ((attrs (file-attributes f)))
              (dotimes (_ 20)
                (decknix--agent-broker-inflight-cached-p "s-x" attrs))
              (should (= 1 reads)))))
      (delete-file f))))

(ert-deftest decknix-working-cache--a-grown-log-is-re-read ()
  "A log that grew may have changed what the last turn looks like, so the
cached answer is no longer evidence."
  (let ((reads 0)
        (decknix--agent-broker-working-cache (make-hash-table :test 'equal))
        (f (make-temp-file "dk-wc2")))
    (unwind-protect
        (cl-letf (((symbol-function 'decknix--agent-broker-log-path)
                   (lambda (_k) f))
                  ((symbol-function 'decknix--agent-broker-read-log-tail)
                   (lambda (&rest _) (setq reads (1+ reads)) nil)))
          (with-temp-file f (insert "{}\n"))
          (decknix--agent-broker-inflight-cached-p "s-y" (file-attributes f))
          ;; Same mtime resolution is possible, so change the SIZE too --
          ;; which is exactly why size is part of the key.
          (with-temp-file f (insert "{}\n{}\n{}\n"))
          (decknix--agent-broker-inflight-cached-p "s-y" (file-attributes f))
          (should (= 2 reads)))
      (delete-file f))))

(ert-deftest decknix-working-cache--is-keyed-per-session ()
  (let ((reads 0)
        (decknix--agent-broker-working-cache (make-hash-table :test 'equal))
        (f (make-temp-file "dk-wc3")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "{}\n"))
          (cl-letf (((symbol-function 'decknix--agent-broker-log-path)
                     (lambda (_k) f))
                    ((symbol-function 'decknix--agent-broker-read-log-tail)
                     (lambda (&rest _) (setq reads (1+ reads)) nil)))
            (let ((attrs (file-attributes f)))
              (decknix--agent-broker-inflight-cached-p "s-a" attrs)
              (decknix--agent-broker-inflight-cached-p "s-b" attrs)
              (should (= 2 reads)))))
      (delete-file f))))

(ert-deftest decknix-working-cache--caches-false-too ()
  "Most sessions are idle; caching only the positive case would re-read
nearly all of them on every pass."
  (let ((reads 0)
        (decknix--agent-broker-working-cache (make-hash-table :test 'equal))
        (f (make-temp-file "dk-wc4")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "{}\n"))
          (cl-letf (((symbol-function 'decknix--agent-broker-log-path)
                     (lambda (_k) f))
                    ((symbol-function 'decknix--agent-broker-read-log-tail)
                     (lambda (&rest _) (setq reads (1+ reads)) nil)))
            (let ((attrs (file-attributes f)))
              (dotimes (_ 5)
                (should-not (decknix--agent-broker-inflight-cached-p "s-z" attrs)))
              (should (= 1 reads)))))
      (delete-file f))))

(ert-deftest decknix-working-cache--staleness-is-not-cached ()
  "Freshness depends on the clock: a fresh log goes stale with no file
change, so caching that half would pin an abandoned turn at `working'."
  (let* ((decknix--agent-broker-working-cache (make-hash-table :test 'equal))
         (decknix-agent-broker-inflight-stale-seconds 0)
         (buf (generate-new-buffer " st"))
         (f (make-temp-file "dk-wc5")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "{}\n"))
          (with-current-buffer buf (setq-local decknix--agent-broker-key "s-s"))
          (cl-letf (((symbol-function 'decknix--agent-broker-log-path)
                     (lambda (_k) f))
                    ((symbol-function 'decknix--agent-broker-live-p)
                     (lambda (_k) t))
                    ((symbol-function 'decknix--agent-broker-read-log-tail)
                     (lambda (&rest _) (list "x"))))
            ;; Zero staleness window: nothing can be working, regardless of
            ;; what the log tail holds.
            (should-not (decknix--agent-broker-working-p buf))))
      (kill-buffer buf) (delete-file f))))

(provide 'decknix-agent-broker-rehydrate-page-test)
;;; decknix-agent-broker-rehydrate-page-test.el ends here
