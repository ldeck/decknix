;;; decknix-agent-dispatch-test.el --- Tests for the explicit-approval dispatcher -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-dispatch "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT suite for `decknix-agent-dispatch'.  Nothing here may reach a real
;; session: every test runs inside `dispatch-test-with-env', which replaces
;; the submit seam with a recorder and turns the real submit entry points
;; (`shell-maker-submit', `decknix--compose-submit-after-wait',
;; `agent-shell-interrupt') into hard errors, so a regression that bypasses
;; the seam fails loudly instead of sending.  Sessions are plain buffers with
;; a pipe process standing in for the agent bridge.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'decknix-agent-dispatch)

(defvar shell-maker--busy nil)

(defconst dispatch-test--sid "11111111-2222-4333-8444-555555555555")
(defconst dispatch-test--sid-2 "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
(defconst dispatch-test--rid "99999999-8888-4777-8666-555555555555")

(defvar dispatch-test--sent nil "List of (BUFFER . INPUT) the stub received.")
(defvar dispatch-test--sids nil "Alist BUFFER -> session id the resolver returns.")
(defvar dispatch-test--submit-mode 'ok
  "How the stub behaves: ok, nil-return, error, no-busy.")

(defun dispatch-test--stub-submit (buf input)
  (push (cons buf input) dispatch-test--sent)
  (pcase dispatch-test--submit-mode
    ('ok (with-current-buffer buf (setq-local shell-maker--busy t)) t)
    ('no-busy t)
    ('nil-return nil)
    ('error (error "boom"))))

(defun dispatch-test--make-session (name sid &optional no-process)
  "Return a buffer NAME that resolves to SID, with a live pipe process."
  (let ((buf (generate-new-buffer name)))
    (unless no-process
      (make-pipe-process :name name :buffer buf :noquery t))
    (push (cons buf sid) dispatch-test--sids)
    buf))

(defmacro dispatch-test-with-env (&rest body)
  "Run BODY against an isolated 0700 state dir and a fake clock/session set."
  (declare (indent 0))
  `(let* ((root (make-temp-file "dispatch-test" t))
          (decknix-agent-dispatch-dir (expand-file-name "state" root))
          (dispatch-test--sent nil)
          (dispatch-test--sids nil)
          (dispatch-test--submit-mode 'ok)
          (dispatch-test--clock 1000)
          (decknix-agent-dispatch--active (make-hash-table :test 'equal))
          (decknix-agent-dispatch--pending-seen nil)
          (decknix-agent-dispatch--armed-at 900)
          (decknix-agent-dispatch-submit-function #'dispatch-test--stub-submit)
          (decknix-agent-dispatch-session-id-function
           (lambda (buf) (alist-get buf dispatch-test--sids)))
          (decknix-agent-dispatch-buffers-function
           (lambda () (mapcar #'car dispatch-test--sids))))
     (unwind-protect
         (cl-letf (((symbol-function 'decknix-agent-dispatch--now)
                    (lambda () dispatch-test--clock))
                   ((symbol-function 'shell-maker-submit)
                    (lambda (&rest _) (error "REAL shell-maker-submit called")))
                   ((symbol-function 'decknix--compose-submit-after-wait)
                    (lambda (&rest _) (error "REAL compose submit called")))
                   ((symbol-function 'agent-shell-interrupt)
                    (lambda (&rest _) (error "INTERRUPT called"))))
           (decknix-agent-dispatch--ensure-dirs)
           ,@body)
       (dolist (cell dispatch-test--sids)
         (when-let ((p (get-buffer-process (car cell)))) (delete-process p))
         (kill-buffer (car cell)))
       (delete-directory root t))))

(defvar dispatch-test--clock 1000)

(defun dispatch-test--sub (name)
  (expand-file-name name decknix-agent-dispatch-dir))

(defun dispatch-test--drop (&rest args)
  "Write a request the way the CLI would; return its path.
ARGS: :id :session :prompt :created :expires :hash :version :mode."
  (let* ((id (or (plist-get args :id) dispatch-test--rid))
         (prompt (or (plist-get args :prompt) "do the thing"))
         (req (list :v (or (plist-get args :version) 1)
                    :id id
                    :session_id (or (plist-get args :session) dispatch-test--sid)
                    :prompt prompt
                    :prompt_sha256 (or (plist-get args :hash)
                                       (secure-hash
                                        'sha256 (encode-coding-string prompt 'utf-8)))
                    :created_at (or (plist-get args :created) dispatch-test--clock)
                    :expires_at (or (plist-get args :expires)
                                    (+ dispatch-test--clock 120))))
         (path (expand-file-name (concat id ".json")
                                 (dispatch-test--sub "pending"))))
    (with-file-modes #o600
      (with-temp-file path (insert (json-serialize req))))
    (set-file-modes path (or (plist-get args :mode) #o600))
    path))

(defun dispatch-test--receipt (&optional id)
  (let ((path (expand-file-name (concat (or id dispatch-test--rid) ".json")
                                (dispatch-test--sub "receipts"))))
    (when (file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (goto-char (point-min))
        (json-parse-string (buffer-string) :object-type 'plist)))))

(defun dispatch-test--state-files (sub)
  (directory-files (dispatch-test--sub sub) nil "\\`[^.]"))

;; -- pure ----------------------------------------------------------

(ert-deftest decknix-agent-dispatch/uuid-is-exact-and-lowercase ()
  (should (decknix-agent-dispatch--uuid-p dispatch-test--sid))
  (should-not (decknix-agent-dispatch--uuid-p "11111111-2222-4333-8444"))
  (should-not (decknix-agent-dispatch--uuid-p "11111111"))
  (should-not (decknix-agent-dispatch--uuid-p (upcase dispatch-test--sid-2)))
  (should-not (decknix-agent-dispatch--uuid-p (concat dispatch-test--sid "\n")))
  (should-not (decknix-agent-dispatch--uuid-p (concat dispatch-test--sid "x")))
  (should-not (decknix-agent-dispatch--uuid-p nil)))

(defun dispatch-test--req ()
  (list :v 1 :id dispatch-test--rid :session_id dispatch-test--sid
        :prompt "hello"
        :prompt_sha256 (secure-hash 'sha256 (encode-coding-string "hello" 'utf-8))
        :created_at 1000 :expires_at 1120))

(ert-deftest decknix-agent-dispatch/validate-accepts-a-good-request ()
  (should-not (decknix-agent-dispatch--validate (dispatch-test--req) 1000)))

(ert-deftest decknix-agent-dispatch/validate-rejects-bad-requests ()
  (cl-flet ((bad (key val now)
              (let ((r (copy-sequence (dispatch-test--req))))
                (plist-put r key val)
                (decknix-agent-dispatch--validate r now))))
    (should (equal "bad-version" (bad :v 2 1000)))
    (should (equal "bad-id" (bad :id "nope" 1000)))
    (should (equal "bad-session-id" (bad :session_id "11111111" 1000)))
    (should (equal "bad-session-id" (bad :session_id (upcase dispatch-test--sid-2) 1000)))
    (should (equal "hash-mismatch" (bad :prompt_sha256 "00" 1000)))
    (should (equal "expired" (dispatch-test--call-validate-late)))
    (should (equal "ttl-too-long" (bad :expires_at 99999 1000)))
    (should (equal "future-dated" (bad :created_at 5000 1000)))
    (should (equal "malformed" (decknix-agent-dispatch--validate nil 1000)))))

(defun dispatch-test--call-validate-late ()
  (decknix-agent-dispatch--validate (dispatch-test--req) 1121))

(ert-deftest decknix-agent-dispatch/validate-rejects-empty-and-reserved-prompts ()
  (cl-flet ((with-prompt (p)
              (decknix-agent-dispatch--validate
               (list :v 1 :id dispatch-test--rid :session_id dispatch-test--sid
                     :prompt p
                     :prompt_sha256 (secure-hash 'sha256 (encode-coding-string p 'utf-8))
                     :created_at 1000 :expires_at 1120)
               1000)))
    (should (equal "empty-prompt" (with-prompt "  \n ")))
    (should (equal "reserved-prompt" (with-prompt "help")))
    (should (equal "reserved-prompt" (with-prompt " Clear\n")))
    (should (equal "reserved-prompt" (with-prompt "config")))
    (should (equal "prompt-too-large"
                   (with-prompt (make-string (1+ decknix-agent-dispatch-max-prompt-bytes) ?a))))
    (should-not (with-prompt "héllo wörld ☃"))))

(ert-deftest decknix-agent-dispatch/decide-table ()
  (cl-flet ((d (&rest kv)
              (apply #'decknix-agent-dispatch--decide
                     (append kv '(:matches 1 :same t :proc t
                                           :unsent nil :busy nil)))))
    (should (equal 'submit (d)))
    (should (equal '(refuse . "no-session") (d :matches 0)))
    (should (equal '(refuse . "ambiguous-session") (d :matches 2)))
    (should (equal '(refuse . "session-changed") (d :same nil)))
    (should (equal '(refuse . "no-process") (d :proc nil)))
    (should (equal '(refuse . "unsent-input") (d :unsent t)))
    (should (equal 'wait (d :busy t)))
    (should (equal '(refuse . "unsent-input") (d :busy t :unsent t)))))

;; -- install is inert ---------------------------------------------

(ert-deftest decknix-agent-dispatch/install-sends-and-starts-nothing ()
  (should-not decknix-agent-dispatch-mode)
  (should-not (cl-some (lambda (tm)
                         (let ((f (timer--function tm)))
                           (and (symbolp f)
                                (string-prefix-p "decknix-agent-dispatch" (symbol-name f)))))
                       timer-list))
  (should-not decknix-agent-dispatch--timer)
  (should-not decknix-agent-dispatch--watch)
  (let ((decknix-agent-dispatch-dir (expand-file-name "never" temporary-file-directory)))
    (should-not (file-exists-p decknix-agent-dispatch-dir))))

(ert-deftest decknix-agent-dispatch/arm-refuses-unsafe-state-dir ()
  (dispatch-test-with-env
    (set-file-modes decknix-agent-dispatch-dir #o755)
    (should-error (decknix-agent-dispatch--check-dirs) :type 'user-error)
    (should-not decknix-agent-dispatch--timer)))

;; -- delivery ------------------------------------------------------

(ert-deftest decknix-agent-dispatch/delivers-once-to-the-exact-session ()
  (dispatch-test-with-env
    (let ((target (dispatch-test--make-session "target" dispatch-test--sid))
          (other (dispatch-test--make-session "other" dispatch-test--sid-2)))
      (dispatch-test--drop :prompt "do the thing\n")
      (decknix-agent-dispatch--tick)
      (should (equal (list (cons target "do the thing")) dispatch-test--sent))
      (should-not (buffer-local-value 'shell-maker--busy other))
      (let ((r (dispatch-test--receipt)))
        (should (equal "accepted" (plist-get r :state)))
        (should (equal dispatch-test--sid (plist-get r :session_id)))
        (should (equal 12 (plist-get r :prompt_len)))
        (should (plist-get r :prompt_sha256))
        (should-not (plist-get r :prompt)))
      (should-not (dispatch-test--state-files "pending"))
      (should-not (dispatch-test--state-files "inflight"))
      (decknix-agent-dispatch--tick)
      (should (= 1 (length dispatch-test--sent))))))

(ert-deftest decknix-agent-dispatch/receipt-is-private-and-never-overwritten ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (dispatch-test--drop)
    (decknix-agent-dispatch--tick)
    (let ((path (expand-file-name (concat dispatch-test--rid ".json")
                                  (dispatch-test--sub "receipts"))))
      (should (= #o600 (logand (file-modes path) #o777)))
      (should-not (decknix-agent-dispatch--write-receipt
                   dispatch-test--rid dispatch-test--sid "rejected" "late"))
      (should (equal "accepted" (plist-get (dispatch-test--receipt) :state))))))

(ert-deftest decknix-agent-dispatch/unknown-session-is-refused-not-sent ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid-2)
    (dispatch-test--drop)
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--sent)
    (let ((r (dispatch-test--receipt)))
      (should (equal "rejected" (plist-get r :state)))
      (should (equal "no-session" (plist-get r :reason))))
    (should-not (dispatch-test--state-files "pending"))
    (should-not (dispatch-test--state-files "inflight"))))

(ert-deftest decknix-agent-dispatch/id-prefix-never-matches ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (dispatch-test--drop :session (substring dispatch-test--sid 0 8))
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--sent)
    (should (equal "bad-session-id" (plist-get (dispatch-test--receipt) :reason)))))

(ert-deftest decknix-agent-dispatch/ambiguous-session-is-refused ()
  (dispatch-test-with-env
    (dispatch-test--make-session "a" dispatch-test--sid)
    (dispatch-test--make-session "b" dispatch-test--sid)
    (dispatch-test--drop)
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--sent)
    (should (equal "ambiguous-session" (plist-get (dispatch-test--receipt) :reason)))))

(ert-deftest decknix-agent-dispatch/stale-request-expires-without-sending ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (dispatch-test--drop :created 800 :expires 920)
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--sent)
    (should (equal "expired" (plist-get (dispatch-test--receipt) :state)))))

(ert-deftest decknix-agent-dispatch/request-predating-arming-is-refused ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (setq decknix-agent-dispatch--armed-at 990)
    (dispatch-test--drop :created 980 :expires 1100)
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--sent)
    (let ((r (dispatch-test--receipt)))
      (should (equal "rejected" (plist-get r :state)))
      (should (equal "predates-arming" (plist-get r :reason))))))

(ert-deftest decknix-agent-dispatch/no-process-is-refused ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid t)
    (dispatch-test--drop)
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--sent)
    (should (equal "no-process" (plist-get (dispatch-test--receipt) :reason)))))

(ert-deftest decknix-agent-dispatch/unsent-input-is-refused-and-left-alone ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (with-current-buffer buf
        (insert "> ")
        (set-marker (process-mark (get-buffer-process buf)) (point-max))
        (insert "half typed thought"))
      (dispatch-test--drop)
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--sent)
      (should (equal "unsent-input" (plist-get (dispatch-test--receipt) :reason)))
      (should (equal "> half typed thought"
                     (with-current-buffer buf (buffer-string)))))))

(ert-deftest decknix-agent-dispatch/busy-session-waits-without-interrupt ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (with-current-buffer buf (setq-local shell-maker--busy t))
      (dispatch-test--drop)
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--sent)
      (should-not (dispatch-test--receipt))
      (should (equal (list (concat dispatch-test--rid ".json"))
                     (dispatch-test--state-files "inflight")))
      (setq dispatch-test--clock 1010)
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--sent)
      (with-current-buffer buf (setq-local shell-maker--busy nil))
      (setq dispatch-test--clock 1020)
      (decknix-agent-dispatch--tick)
      (should (= 1 (length dispatch-test--sent)))
      (should (equal "accepted" (plist-get (dispatch-test--receipt) :state))))))

(ert-deftest decknix-agent-dispatch/busy-until-expiry-is-not-sent ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (with-current-buffer buf (setq-local shell-maker--busy t))
      (dispatch-test--drop)
      (decknix-agent-dispatch--tick)
      (setq dispatch-test--clock 1121)
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--sent)
      (should (equal "expired" (plist-get (dispatch-test--receipt) :state)))
      (should-not (dispatch-test--state-files "inflight")))))

(ert-deftest decknix-agent-dispatch/session-change-while-waiting-is-refused ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (with-current-buffer buf (setq-local shell-maker--busy t))
      (dispatch-test--drop)
      (decknix-agent-dispatch--tick)
      (setf (alist-get buf dispatch-test--sids) dispatch-test--sid-2)
      (with-current-buffer buf (setq-local shell-maker--busy nil))
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--sent)
      (should (equal "no-session" (plist-get (dispatch-test--receipt) :reason))))))

(ert-deftest decknix-agent-dispatch/buffer-swap-while-waiting-is-session-changed ()
  (dispatch-test-with-env
    (let ((old (dispatch-test--make-session "old" dispatch-test--sid)))
      (with-current-buffer old (setq-local shell-maker--busy t))
      (dispatch-test--drop)
      (decknix-agent-dispatch--tick)
      (setf (alist-get old dispatch-test--sids) nil)
      (dispatch-test--make-session "new" dispatch-test--sid)
      (with-current-buffer old (setq-local shell-maker--busy nil))
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--sent)
      (should (equal "session-changed" (plist-get (dispatch-test--receipt) :reason))))))

(ert-deftest decknix-agent-dispatch/duplicate-request-id-delivers-once ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (dispatch-test--drop)
    (decknix-agent-dispatch--tick)
    (dispatch-test--drop)
    (decknix-agent-dispatch--tick)
    (should (= 1 (length dispatch-test--sent)))
    (should (equal "accepted" (plist-get (dispatch-test--receipt) :state)))
    (should-not (dispatch-test--state-files "pending"))))

(ert-deftest decknix-agent-dispatch/second-claim-of-same-file-loses ()
  (dispatch-test-with-env
    (let ((path (dispatch-test--drop)))
      (should (decknix-agent-dispatch--claim dispatch-test--rid))
      (should-not (decknix-agent-dispatch--claim dispatch-test--rid))
      (should-not (file-exists-p path)))))

(ert-deftest decknix-agent-dispatch/symlinked-or-loose-request-is-refused ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (dispatch-test--drop :mode #o644)
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--sent)
    (should (equal "unsafe-file" (plist-get (dispatch-test--receipt) :reason))))
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (let ((real (expand-file-name "real.json" (dispatch-test--sub "tmp"))))
      (with-temp-file real (insert "{}"))
      (make-symbolic-link real (expand-file-name (concat dispatch-test--rid ".json")
                                                 (dispatch-test--sub "pending"))))
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--sent)
    (should (equal "unsafe-file" (plist-get (dispatch-test--receipt) :reason)))))

(ert-deftest decknix-agent-dispatch/garbage-request-is-rejected ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (let ((path (expand-file-name (concat dispatch-test--rid ".json")
                                  (dispatch-test--sub "pending"))))
      (with-file-modes #o600 (with-temp-file path (insert "not json")))
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--sent)
      (should (equal "malformed" (plist-get (dispatch-test--receipt) :reason)))
      (should-not (file-exists-p path)))))

;; -- outcome uncertainty ------------------------------------------

(ert-deftest decknix-agent-dispatch/submit-error-is-unknown-and-never-retried ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (setq dispatch-test--submit-mode 'error)
    (dispatch-test--drop)
    (decknix-agent-dispatch--tick)
    (decknix-agent-dispatch--tick)
    (should (= 1 (length dispatch-test--sent)))
    (should (equal "unknown" (plist-get (dispatch-test--receipt) :state)))
    (should-not (dispatch-test--state-files "pending"))))

(ert-deftest decknix-agent-dispatch/submit-without-busy-evidence-is-unknown ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (setq dispatch-test--submit-mode 'no-busy)
    (dispatch-test--drop)
    (decknix-agent-dispatch--tick)
    (should (equal "unknown" (plist-get (dispatch-test--receipt) :state)))))

(ert-deftest decknix-agent-dispatch/refused-submit-is-not-accepted ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (setq dispatch-test--submit-mode 'nil-return)
    (dispatch-test--drop)
    (decknix-agent-dispatch--tick)
    (let ((r (dispatch-test--receipt)))
      (should (equal "rejected" (plist-get r :state)))
      (should (equal "submit-refused" (plist-get r :reason))))))

;; -- recovery / disarm --------------------------------------------

(ert-deftest decknix-agent-dispatch/recovery-never-retries ()
  (dispatch-test-with-env
    (let ((attempted "aaaaaaaa-0000-4000-8000-000000000001")
          (untouched "aaaaaaaa-0000-4000-8000-000000000002")
          (done "aaaaaaaa-0000-4000-8000-000000000003"))
      (dispatch-test--make-session "target" dispatch-test--sid)
      (dolist (id (list attempted untouched done))
        (dispatch-test--drop :id id)
        (rename-file (expand-file-name (concat id ".json") (dispatch-test--sub "pending"))
                     (expand-file-name (concat id ".json") (dispatch-test--sub "inflight"))))
      (with-file-modes #o600
        (with-temp-file (expand-file-name (concat attempted ".attempt")
                                          (dispatch-test--sub "inflight"))
          (insert "1")))
      (decknix-agent-dispatch--write-receipt done dispatch-test--sid "accepted" nil)
      (decknix-agent-dispatch--recover)
      (should-not dispatch-test--sent)
      (should (equal "unknown" (plist-get (dispatch-test--receipt attempted) :state)))
      (should (equal "not-sent" (plist-get (dispatch-test--receipt untouched) :state)))
      (should (equal "accepted" (plist-get (dispatch-test--receipt done) :state)))
      (should-not (dispatch-test--state-files "inflight")))))

(ert-deftest decknix-agent-dispatch/disarm-drops-waiting-requests ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (with-current-buffer buf (setq-local shell-maker--busy t))
      (dispatch-test--drop)
      (decknix-agent-dispatch--tick)
      (decknix-agent-dispatch--disarm-requests)
      (should-not dispatch-test--sent)
      (should (equal "not-sent" (plist-get (dispatch-test--receipt) :state)))
      (should (equal "disarmed" (plist-get (dispatch-test--receipt) :reason)))
      (should-not (dispatch-test--state-files "inflight")))))

(ert-deftest decknix-agent-dispatch/mode-toggle-starts-and-stops-cleanly ()
  (let* ((root (make-temp-file "dispatch-mode" t))
         (decknix-agent-dispatch-dir (expand-file-name "state" root))
         (decknix-agent-dispatch--active (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (decknix-agent-dispatch-mode 1)
          (should decknix-agent-dispatch-mode)
          (should decknix-agent-dispatch--timer)
          (should decknix-agent-dispatch--armed-at)
          (decknix-agent-dispatch-mode -1)
          (should-not decknix-agent-dispatch--timer)
          (should-not decknix-agent-dispatch--watch)
          (should-not decknix-agent-dispatch--armed-at))
      (decknix-agent-dispatch-mode -1)
      (delete-directory root t))))

(ert-deftest decknix-agent-dispatch/mode-stays-off-on-unsafe-dir ()
  (let* ((root (make-temp-file "dispatch-mode" t))
         (decknix-agent-dispatch-dir (expand-file-name "state" root)))
    (unwind-protect
        (progn
          (make-directory decknix-agent-dispatch-dir)
          (make-directory (expand-file-name "pending" decknix-agent-dispatch-dir))
          (cl-letf (((symbol-function 'decknix-agent-dispatch--ensure-dirs) #'ignore))
            (set-file-modes decknix-agent-dispatch-dir #o755)
            (should-error (decknix-agent-dispatch-mode 1) :type 'user-error))
          (should-not decknix-agent-dispatch-mode)
          (should-not decknix-agent-dispatch--timer))
      (decknix-agent-dispatch-mode -1)
      (delete-directory root t))))

(ert-deftest decknix-agent-dispatch/arming-does-not-release-an-old-pending-request ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (dispatch-test--drop :created 1000 :expires 1120)
    (setq dispatch-test--clock 1030)
    (setq decknix-agent-dispatch--armed-at 1030)
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--sent)
    (should (equal "predates-arming" (plist-get (dispatch-test--receipt) :reason)))))

(ert-deftest decknix-agent-dispatch/internal-error-settles-fail-closed ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (dispatch-test--drop)
    (cl-letf (((symbol-function 'decknix-agent-dispatch--busy-p)
               (lambda (_) (error "kaboom"))))
      (decknix-agent-dispatch--tick)
      (decknix-agent-dispatch--tick))
    (should-not dispatch-test--sent)
    (let ((r (dispatch-test--receipt)))
      (should (equal "not-sent" (plist-get r :state)))
      (should (string-prefix-p "internal-error" (plist-get r :reason))))
    (should-not (dispatch-test--state-files "inflight"))))

(ert-deftest decknix-agent-dispatch/unbound-busy-flag-reads-as-idle-not-error ()
  (let ((buf (generate-new-buffer "no-busy-var")))
    (unwind-protect
        (should-not (decknix-agent-dispatch--busy-p buf))
      (kill-buffer buf))))

;; -- polling cost --------------------------------------------------

(defun dispatch-test--count-listings (thunk)
  "Call THUNK and return how many times pending/ was listed."
  (let ((n 0))
    (cl-letf* ((orig (symbol-function 'decknix-agent-dispatch--pending-ids))
               ((symbol-function 'decknix-agent-dispatch--pending-ids)
                (lambda () (cl-incf n) (funcall orig))))
      (funcall thunk))
    n))

(ert-deftest decknix-agent-dispatch/an-unchanged-pending-dir-is-not-listed ()
  "Idle ticks stat pending/ once and do not read it."
  (dispatch-test-with-env
    (should (= 1 (dispatch-test--count-listings #'decknix-agent-dispatch--tick)))
    (should (= 0 (dispatch-test--count-listings
                  (lambda ()
                    (decknix-agent-dispatch--tick)
                    (decknix-agent-dispatch--tick)))))))

(ert-deftest decknix-agent-dispatch/a-new-request-moves-the-mtime-and-is-delivered ()
  (dispatch-test-with-env
    (let ((target (dispatch-test--make-session "target" dispatch-test--sid)))
      (decknix-agent-dispatch--tick)
      ;; Make the change visible even on a filesystem with coarse mtimes.
      (setcar decknix-agent-dispatch--pending-seen '(0 0 0 0))
      (dispatch-test--drop)
      (decknix-agent-dispatch--tick)
      (should (equal (list (cons target "do the thing")) dispatch-test--sent)))))

(ert-deftest decknix-agent-dispatch/an-unread-backlog-is-listed-again ()
  "More than one tick's worth of requests never marks the dir as read."
  (dispatch-test-with-env
    (let ((decknix-agent-dispatch--pending-seen nil))
      (cl-letf (((symbol-function 'decknix-agent-dispatch--pending-ids)
                 (lambda () (make-list 9 "x")))
                ((symbol-function 'decknix-agent-dispatch--process-pending) #'ignore))
        (decknix-agent-dispatch--tick)
        (should-not decknix-agent-dispatch--pending-seen)))))

(ert-deftest decknix-agent-dispatch/the-rescan-interval-lists-regardless ()
  (dispatch-test-with-env
    (decknix-agent-dispatch--tick)
    (setcdr decknix-agent-dispatch--pending-seen
            (- (float-time) decknix-agent-dispatch-rescan-interval 1))
    (should (= 1 (dispatch-test--count-listings #'decknix-agent-dispatch--tick)))))

(ert-deftest decknix-agent-dispatch/a-file-notify-kick-forces-a-listing ()
  (dispatch-test-with-env
    (decknix-agent-dispatch--tick)
    (let ((decknix-agent-dispatch--kick nil) (fn nil))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_s _r f &rest _) (setq fn f) 'kick)))
        (decknix-agent-dispatch--kick-scan))
      (should (= 1 (dispatch-test--count-listings fn))))))

(provide 'decknix-agent-dispatch-test)
;;; decknix-agent-dispatch-test.el ends here
