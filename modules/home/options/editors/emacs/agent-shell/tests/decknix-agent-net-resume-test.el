;;; decknix-agent-net-resume-test.el --- Tests for auto-resume after network loss -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification for `decknix-agent-net-resume': which failures may be
;; resumed, when a session must be left alone, how the watcher moves
;; between idle/waiting/probing, and that a resume is never sent twice
;; for one failure, not even across a restart.  No real process, timer
;; or session is touched: processes, timers, the status chain and the
;; submit are stubbed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-net-resume)

;; ---------------------------------------------------------------------
;; Classification
;; ---------------------------------------------------------------------

(defconst decknix-net-resume-test--table
  '(;; Observed on 2026-11-24/25 (Claude transcripts and broker logs).
    ("API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)" . network)
    ("API Error: Unable to connect to API (ENOTFOUND)" . network)
    ("API Error: Unable to connect to API (ECONNRESET)" . network)
    ("API Error: Connection closed mid-response. The response above may be incomplete." . network)
    ("API Error: Stream idle timeout - no chunks received" . network)
    ("API Error: Connection error (EAI_AGAIN)" . network)
    ("API Error: connect ECONNREFUSED 160.79.104.10:443" . network)
    ("API Error: Request timed out (ETIMEDOUT)" . network)
    ("API Error: socket hang up" . network)
    ("Request failed: fetch failed" . network)
    ;; Overloaded: the API answered and said not now.
    ("API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}" . overloaded)
    ("API Error: 503 Service Unavailable" . overloaded)
    ("API Error: 502 Bad Gateway" . overloaded)
    ("API Error: 504 Gateway Timeout" . overloaded)
    ;; Never resumed.
    ("API Error: 500 {\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"Internal server error\"}}" . server)
    ("API Error: 429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}}" . rate-limit)
    ("API Error: Rate limit reached for requests" . rate-limit)
    ("API Error: 401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"OAuth token has expired\"}}" . auth)
    ("API Error: 403 Forbidden" . auth)
    ("API Error: Claude AI usage limit reached, resets 5pm" . quota)
    ("API Error: Your credit balance is too low (ECONNRESET)" . quota)
    ("API Error: connect ECONNREFUSED 127.0.0.1:5432" . local)
    ;; Not the agent's own API call at all.
    ("Error: getaddrinfo ENOTFOUND github.com" . nil)
    ("You've hit your weekly limit · resets 12pm (Australia/Sydney)" . nil)
    ("Failed to authenticate: OAuth session expired and could not be refreshed" . nil)
    ("Not logged in · Please run /login" . nil)
    ("The retry logic handles ECONNRESET by backing off." . nil)
    ("" . nil))
  "Failure line -> expected class.")

(ert-deftest decknix-net-resume--classification-table ()
  "Each line classifies as the table says."
  (dolist (row decknix-net-resume-test--table)
    (should (equal (cons (car row) (decknix-agent-net-resume-classify (car row)))
                   row))))

(ert-deftest decknix-net-resume--only-network-and-overloaded-resume ()
  (should (decknix-agent-net-resume-resumable-p 'network))
  (should (decknix-agent-net-resume-resumable-p 'overloaded))
  (dolist (class '(server rate-limit auth quota local nil))
    (should-not (decknix-agent-net-resume-resumable-p class))))

(ert-deftest decknix-net-resume--classify-non-string ()
  (should-not (decknix-agent-net-resume-classify nil))
  (should-not (decknix-agent-net-resume-classify 42)))

(ert-deftest decknix-net-resume--host-from-reason-wins ()
  (should (equal (decknix-agent-net-resume-host-for
                  'codex "API Error: getaddrinfo ENOTFOUND api.example.com")
                 "api.example.com"))
  (should (equal (decknix-agent-net-resume-host-for 'codex "API Error: socket hang up")
                 "api.openai.com"))
  (should (equal (decknix-agent-net-resume-host-for 'mystery nil)
                 decknix-agent-net-resume-default-host)))

;; ---------------------------------------------------------------------
;; Decision: when a session is left alone
;; ---------------------------------------------------------------------

(defun decknix-net-resume-test--facts (&rest overrides)
  "Return facts for a session that should resume, with OVERRIDES."
  (let ((facts (list :enabled t :live t :suppressed nil :class 'network
                     :status "netfail" :asking nil :busy nil :unsent nil
                     :queued nil :attempts 0 :max 3 :now 1000.0
                     :not-before 0 :last nil :min-interval 30)))
    (while overrides
      (setq facts (plist-put facts (pop overrides) (pop overrides))))
    facts))

(ert-deftest decknix-net-resume--decide-resume ()
  (should (eq (decknix-agent-net-resume-decide (decknix-net-resume-test--facts))
              'resume)))

(ert-deftest decknix-net-resume--decide-skip-rules ()
  "Every reason to leave a session alone, in its own words."
  (dolist (case '((:enabled nil disabled)
                  (:live nil dead)
                  (:suppressed t suppressed)
                  (:class rate-limit not-resumable)
                  (:class auth not-resumable)
                  (:class nil not-resumable)
                  (:status "waiting" not-netfail)
                  (:status "working" not-netfail)
                  (:status "ready" not-netfail)
                  (:status "killed" not-netfail)
                  (:asking t asking)
                  (:busy t busy)
                  (:unsent t user-typing)
                  (:queued t queued)
                  (:attempts 3 gave-up)
                  (:last 990.0 too-soon)
                  (:not-before 2000.0 wait)))
    (should (equal (list (car case) (cadr case)
                         (decknix-agent-net-resume-decide
                          (decknix-net-resume-test--facts (car case) (cadr case))))
                   case))))

(ert-deftest decknix-net-resume--decide-asking-beats-busy ()
  "A session waiting on a question is reported as asking, not busy."
  (should (eq (decknix-agent-net-resume-decide
               (decknix-net-resume-test--facts :asking t :busy t :unsent t))
              'asking)))

(ert-deftest decknix-net-resume--decide-old-last-is-fine ()
  (should (eq (decknix-agent-net-resume-decide
               (decknix-net-resume-test--facts :last 900.0))
              'resume)))

;; ---------------------------------------------------------------------
;; Backoff, schedule, prompt, badge
;; ---------------------------------------------------------------------

(ert-deftest decknix-net-resume--backoff-doubles-and-caps ()
  (should (= (decknix-agent-net-resume-backoff 0 10 300) 10))
  (should (= (decknix-agent-net-resume-backoff 1 10 300) 20))
  (should (= (decknix-agent-net-resume-backoff 3 10 300) 80))
  (should (= (decknix-agent-net-resume-backoff 9 10 300) 300))
  (should (= (decknix-agent-net-resume-backoff -2 10 300) 10)))

(ert-deftest decknix-net-resume--schedule-staggers-with-jitter ()
  (should (equal (decknix-agent-net-resume-schedule '(a b c) 4 3 (lambda (n) (/ n 3.0)))
                 '((a . 1.0) (b . 5.0) (c . 9.0))))
  (should (equal (decknix-agent-net-resume-schedule '(a b) 0 0 (lambda (_) 99))
                 '((a . 0) (b . 0))))
  (should-not (decknix-agent-net-resume-schedule nil 4 3 #'identity)))

(ert-deftest decknix-net-resume--prompt-marks-itself ()
  (let ((p (decknix-agent-net-resume-prompt-for 'network 1 3)))
    (should (string-prefix-p "↻ The network dropped and is back." p))
    (should (string-suffix-p "[auto-resume 1/3]" p)))
  (should (string-match-p "overloaded"
                          (decknix-agent-net-resume-prompt-for 'overloaded 2 3))))

(ert-deftest decknix-net-resume--badge ()
  (should-not (decknix-agent-net-resume-badge-for nil t))
  (should (equal (decknix-agent-net-resume-badge-for '(:class network :attempts 0) t) "↻…"))
  (should (equal (decknix-agent-net-resume-badge-for '(:class network :attempts 2) t) "↻2"))
  (should (equal (decknix-agent-net-resume-badge-for '(:class network :attempts 3 :gave-up t) t) "↻✗"))
  (should (equal (decknix-agent-net-resume-badge-for '(:class network :suppressed t) t) "↻off"))
  (should (equal (decknix-agent-net-resume-badge-for '(:class network :skipped scheduled :attempts 1) t) "↻1"))
  (should-not (decknix-agent-net-resume-badge-for '(:class network :skipped user-typing) t))
  (should-not (decknix-agent-net-resume-badge-for '(:class auth) t))
  (should (equal (decknix-agent-net-resume-badge-for '(:resumed t) nil) "↻"))
  (should-not (decknix-agent-net-resume-badge-for '(:suppressed t) nil)))

;; ---------------------------------------------------------------------
;; Watcher state machine
;; ---------------------------------------------------------------------

(defun decknix-net-resume-test--run (events)
  "Feed EVENTS from idle; return the list of (PHASE . ACTIONS) per step."
  (let ((decknix-agent-net-resume-probe-backoff '(10 . 300))
        (state '(:phase idle :failures 0))
        out)
    (dolist (ev events (nreverse out))
      (let ((step (decknix-agent-net-resume-watch-step state ev)))
        (setq state (car step))
        (push (cons (plist-get state :phase) (cdr step)) out)))))

(ert-deftest decknix-net-resume--watch-idle-stays-silent ()
  "With nothing waiting no process or timer is started."
  (should (equal (decknix-net-resume-test--run '((pending 0) (change) (timer) (probe-ok)))
                 '((idle) (idle) (idle) (idle)))))

(ert-deftest decknix-net-resume--watch-full-cycle ()
  (should (equal (decknix-net-resume-test--run
                  '((pending 2) (timer) (probe-fail) (change) (probe-fail)
                    (timer) (probe-ok)))
                 '((waiting start-notify (schedule 10))
                   (probing cancel-timer start-probe)
                   (waiting (schedule 20))
                   (probing cancel-timer start-probe)
                   (waiting (schedule 40))
                   (probing cancel-timer start-probe)
                   (idle cancel-timer stop-notify recovered)))))

(ert-deftest decknix-net-resume--watch-drops-events-while-probing ()
  (should (equal (decknix-net-resume-test--run '((pending 1) (change) (change) (timer) (pending 3)))
                 '((waiting start-notify (schedule 10))
                   (probing cancel-timer start-probe)
                   (probing) (probing) (probing)))))

(ert-deftest decknix-net-resume--watch-disarms-when-nothing-waits ()
  (should (equal (decknix-net-resume-test--run '((pending 1) (change) (pending 0) (probe-ok)))
                 '((waiting start-notify (schedule 10))
                   (probing cancel-timer start-probe)
                   (idle cancel-timer kill-probe stop-notify)
                   (idle)))))

(ert-deftest decknix-net-resume--watch-backoff-caps ()
  (let ((steps (decknix-net-resume-test--run
                (append '((pending 1))
                        (apply #'append (make-list 8 '((timer) (probe-fail))))))))
    (should (equal (car (last steps)) '(waiting (schedule 300))))))

(ert-deftest decknix-net-resume--probe-command ()
  (let ((argv (decknix-agent-net-resume-probe-command '("a.example" "b.example") "/bin/curl" nil)))
    (should (equal (seq-take argv 2) '("sh" "-c")))
    (should (string-match-p "curl.*-I --connect-timeout 5" (nth 2 argv)))
    (should (equal (seq-drop argv 3) '("probe" "a.example" "b.example"))))
  (should (string-match-p "nc.* -z -G 5"
                          (nth 2 (decknix-agent-net-resume-probe-command '("a") nil "/usr/bin/nc"))))
  (should-not (decknix-agent-net-resume-probe-command '("a") nil nil))
  (should-not (decknix-agent-net-resume-probe-command nil "/bin/curl" nil)))

;; ---------------------------------------------------------------------
;; Integration with stubs: records, listener, resume, restart
;; ---------------------------------------------------------------------

(defvar decknix-net-resume-test--buffers nil)
(defvar decknix-net-resume-test--sent nil)
(defvar decknix-net-resume-test--timers nil)
(defvar decknix-net-resume-test--procs nil)

(defmacro decknix-net-resume-test--with-env (&rest body)
  "Run BODY with a temp store, stubbed status, submit, timers and processes."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "net-resume" t))
          (decknix-agent-net-resume-state-file (expand-file-name "net-resume.eld" dir))
          (decknix-agent-net-resume--records nil)
          (decknix-agent-net-resume--loaded nil)
          (decknix-agent-net-resume--last-written nil)
          (decknix-agent-net-resume--watch '(:phase idle :failures 0))
          (decknix-agent-net-resume--notify-proc nil)
          (decknix-agent-net-resume--probe-proc nil)
          (decknix-agent-net-resume--timer nil)
          (decknix-agent-net-resume--due-timer nil)
          (decknix-agent-net-resume-enabled t)
          (decknix-agent-net-resume-max-attempts 3)
          (decknix-agent-net-resume-min-interval 0)
          (decknix-agent-net-resume-stagger 0)
          (decknix-agent-net-resume-jitter 0)
          (decknix-agent-net-resume-session-key-function #'buffer-name)
          (decknix-agent-net-resume-status-function
           (lambda (b) (if (decknix-agent-net-error-flagged-p b) "netfail" "ready")))
          (decknix-agent-net-resume-submit-function
           (lambda (b input)
             (push (cons (buffer-name b) input) decknix-net-resume-test--sent)
             (let ((decknix-agent-net-error-change-functions
                    (list #'decknix-agent-net-resume-on-change)))
               (decknix--agent-net-error-handle-event b 'input-submitted nil))
             t))
          (decknix-agent-net-resume-process-function
           (lambda (&rest args)
             (push (plist-get args :name) decknix-net-resume-test--procs)
             nil))
          (decknix-net-resume-test--buffers nil)
          (decknix-net-resume-test--sent nil)
          (decknix-net-resume-test--timers nil)
          (decknix-net-resume-test--procs nil))
     (cl-letf (((symbol-function 'agent-shell-buffers)
                (lambda () decknix-net-resume-test--buffers))
               ((symbol-function 'run-at-time)
                (lambda (secs _repeat fn &rest args)
                  (push (list secs fn args) decknix-net-resume-test--timers)
                  'fake-timer))
               ((symbol-function 'timerp) (lambda (x) (eq x 'fake-timer)))
               ((symbol-function 'cancel-timer) #'ignore)
               ((symbol-function 'executable-find)
                (lambda (name) (and (member name '("notifyutil" "curl"))
                                    (concat "/stub/" name)))))
       (unwind-protect (progn ,@body)
         (mapc #'kill-buffer (seq-filter #'buffer-live-p decknix-net-resume-test--buffers))
         (delete-directory dir t)))))

(defun decknix-net-resume-test--session (name &optional line)
  "Make a live stub session NAME whose last turn ended on LINE."
  (let ((buf (generate-new-buffer name)))
    (push buf decknix-net-resume-test--buffers)
    (with-current-buffer buf
      (insert "Working on it.\n" (or line "") "\n"))
    buf))

(defun decknix-net-resume-test--fail (buf line)
  "Make BUF's turn end on LINE and tell the listener."
  (with-current-buffer buf (insert line "\n"))
  (decknix-agent-net-error-scan-buffer buf)
  (decknix-agent-net-resume-on-change buf 'turn-complete))

(defun decknix-net-resume-test--fire-timers ()
  "Run every scheduled resume (not watcher timers); return how many."
  (let ((due (seq-filter (lambda (tm) (eq (nth 1 tm) #'decknix-agent-net-resume--resume-one))
                         decknix-net-resume-test--timers)))
    (setq decknix-net-resume-test--timers
          (seq-difference decknix-net-resume-test--timers due))
    (dolist (tm (reverse due)) (apply (nth 1 tm) (nth 2 tm)))
    (length due)))

(ert-deftest decknix-net-resume--failure-arms-the-watcher ()
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a")))
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      (should (eq (plist-get decknix-agent-net-resume--watch :phase) 'waiting))
      (should (member "decknix-net-change" decknix-net-resume-test--procs))
      (should (equal (plist-get (decknix-agent-net-resume-record a) :host)
                     decknix-agent-net-resume-default-host)))))

(ert-deftest decknix-net-resume--a-non-network-failure-arms-nothing ()
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a")))
      (decknix-net-resume-test--fail a "API Error: 500 Internal server error")
      (should (eq (plist-get decknix-agent-net-resume--watch :phase) 'idle))
      (should-not decknix-net-resume-test--procs))))

(ert-deftest decknix-net-resume--recovery-resumes-once-and-staggers ()
  (decknix-net-resume-test--with-env
    (let ((decknix-agent-net-resume-stagger 4)
          (a (decknix-net-resume-test--session "a"))
          (b (decknix-net-resume-test--session "b")))
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      (decknix-net-resume-test--fail b "API Error: Unable to connect to API (ECONNRESET)")
      (decknix-agent-net-resume--dispatch '(change))
      (should (member "decknix-net-probe" decknix-net-resume-test--procs))
      (decknix-agent-net-resume--dispatch '(probe-ok))
      (let ((delays (mapcar #'car (seq-filter (lambda (tm) (eq (nth 1 tm) #'decknix-agent-net-resume--resume-one))
                                              decknix-net-resume-test--timers))))
        (should (equal (sort delays #'<) '(0 4))))
      (should (= (decknix-net-resume-test--fire-timers) 2))
      (should (equal (sort (mapcar #'car decknix-net-resume-test--sent) #'string<) '("a" "b")))
      (should (string-suffix-p "[auto-resume 1/3]" (cdar decknix-net-resume-test--sent)))
      ;; Both are now busy on their resumed turn: nothing waits, nothing runs.
      (should-not (decknix-agent-net-error-flagged-p a))
      (should (eq (plist-get decknix-agent-net-resume--watch :phase) 'idle))
      ;; A second recovery signal sends nothing more.
      (decknix-agent-net-resume--dispatch '(probe-ok))
      (should (= (decknix-net-resume-test--fire-timers) 0))
      (should (= (length decknix-net-resume-test--sent) 2)))))

(ert-deftest decknix-net-resume--own-submit-keeps-the-streak ()
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a")))
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      (decknix-agent-net-resume--resume-one a)
      (should (= (plist-get (decknix-agent-net-resume-record a) :attempts) 1))
      (should-not (buffer-local-value 'decknix-agent-net-resume--submitting a)))))

(ert-deftest decknix-net-resume--cap-then-gave-up ()
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a")))
      (dotimes (_ 3)
        (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
        (plist-put (decknix-agent-net-resume-record a) :not-before 0)
        (decknix-agent-net-resume--resume-one a))
      (should (= (length decknix-net-resume-test--sent) 3))
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      (should (plist-get (decknix-agent-net-resume-record a) :gave-up))
      (decknix-agent-net-resume--resume-one a)
      (should (= (length decknix-net-resume-test--sent) 3))
      (should (equal (decknix-agent-net-resume-badge a) "↻✗"))
      ;; Gave up: the watcher does not keep probing for it.
      (should (eq (plist-get decknix-agent-net-resume--watch :phase) 'idle)))))

(ert-deftest decknix-net-resume--repeat-failure-backs-off ()
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a")))
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      (decknix-agent-net-resume--resume-one a)
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      (should (> (plist-get (decknix-agent-net-resume-record a) :not-before) (float-time)))
      (decknix-agent-net-resume--resume-class 'network)
      (should (= (length decknix-net-resume-test--sent) 1))
      (should (eq (plist-get (decknix-agent-net-resume-record a) :skipped) 'scheduled)))))

(ert-deftest decknix-net-resume--user-input-ends-the-streak ()
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a")))
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      (decknix-agent-net-error-clear a)
      (decknix-agent-net-resume-on-change a 'input-submitted)
      (should-not (plist-get (decknix-agent-net-resume-record a) :class))
      (decknix-agent-net-resume--dispatch '(probe-ok))
      (should (= (decknix-net-resume-test--fire-timers) 0))
      (should-not decknix-net-resume-test--sent))))

(ert-deftest decknix-net-resume--skips-are-spent-not-queued ()
  "Typing, a question or a busy session at recovery: no resume, now or later."
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a"))
          (b (decknix-net-resume-test--session "b"))
          (c (decknix-net-resume-test--session "c")))
      (dolist (buf (list a b c))
        (decknix-net-resume-test--fail buf "API Error: Unable to connect to API (ENOTFOUND)"))
      (with-current-buffer b (setq-local decknix--agent-turn-question t))
      (with-current-buffer c (setq-local shell-maker--busy t))
      (let ((compose (generate-new-buffer "*Compose: a*")))
        (push compose decknix-net-resume-test--buffers)
        (with-current-buffer compose
          (setq-local decknix--compose-target-buffer a)
          (insert "half a thought")))
      (decknix-agent-net-resume--dispatch '(probe-ok))
      (decknix-net-resume-test--fire-timers)
      (should-not decknix-net-resume-test--sent)
      (should (eq (plist-get (decknix-agent-net-resume-record a) :skipped) 'user-typing))
      (should (eq (plist-get (decknix-agent-net-resume-record b) :skipped) 'asking))
      (should (eq (plist-get (decknix-agent-net-resume-record c) :skipped) 'busy))
      (should (eq (plist-get decknix-agent-net-resume--watch :phase) 'idle)))))

(ert-deftest decknix-net-resume--suppressed-and-disabled ()
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a")))
      (decknix-agent-net-resume-suppress a)
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      (should (eq (plist-get decknix-agent-net-resume--watch :phase) 'idle))
      (decknix-agent-net-resume--resume-one a)
      (should-not decknix-net-resume-test--sent)
      (decknix-agent-net-resume-suppress a)
      (should (eq (plist-get decknix-agent-net-resume--watch :phase) 'waiting))
      (decknix-agent-net-resume-toggle)
      (should (eq (plist-get decknix-agent-net-resume--watch :phase) 'idle))
      (decknix-agent-net-resume--resume-one a)
      (should-not decknix-net-resume-test--sent))))

(ert-deftest decknix-net-resume--clean-turn-keeps-the-resumed-badge ()
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a")))
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      (decknix-agent-net-resume--resume-one a)
      (with-current-buffer a (insert "Picked up where I left off.\n"))
      (decknix-agent-net-error-scan-buffer a)
      (decknix-agent-net-resume-on-change a 'turn-complete)
      (should (equal (decknix-agent-net-resume-badge a) "↻"))
      (should (= (or (plist-get (decknix-agent-net-resume-record a) :attempts) 0) 0)))))

(ert-deftest decknix-net-resume--restart-does-not-repeat-or-reset ()
  "The store carries the count, so a restart is neither a fresh cap nor a resend."
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a")))
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      (decknix-agent-net-resume--resume-one a)
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      ;; Restart: memory gone, buffer re-rendered from the broker.
      (setq decknix-agent-net-resume--records nil
            decknix-agent-net-resume--loaded nil
            decknix-agent-net-resume--watch '(:phase idle :failures 0))
      (decknix-agent-net-error-clear a)
      (decknix-agent-net-resume-sweep)
      (let ((rec (decknix-agent-net-resume-record a)))
        (should (= (plist-get rec :attempts) 1))
        (should (> (plist-get rec :not-before) (float-time))))
      (should (eq (plist-get decknix-agent-net-resume--watch :phase) 'waiting)))))

(ert-deftest decknix-net-resume--overloaded-waits-on-a-timer-not-a-probe ()
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a")))
      (decknix-net-resume-test--fail a "API Error: 529 Overloaded")
      (should (eq (plist-get decknix-agent-net-resume--watch :phase) 'idle))
      (should (seq-find (lambda (tm) (eq (nth 1 tm) #'decknix-agent-net-resume--on-due))
                        decknix-net-resume-test--timers))
      (should (>= (plist-get (decknix-agent-net-resume-record a) :not-before)
                  (+ (float-time) 59))))))

(ert-deftest decknix-net-resume--store-is-written-whole-and-reread ()
  (decknix-net-resume-test--with-env
    (let ((a (decknix-net-resume-test--session "a")))
      (decknix-net-resume-test--fail a "API Error: Unable to connect to API (ENOTFOUND)")
      (should (file-exists-p decknix-agent-net-resume-state-file))
      (let ((decknix-agent-net-resume--records nil)
            (decknix-agent-net-resume--loaded nil))
        (should (eq (plist-get (decknix-agent-net-resume-record a) :class) 'network))))))

(provide 'decknix-agent-net-resume-test)
;;; decknix-agent-net-resume-test.el ends here
