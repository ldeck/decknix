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
(defconst dispatch-test--rid-2 "77777777-8888-4777-8666-555555555555")

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
          (decknix-agent-dispatch--delivered (make-hash-table :test 'equal))
          (decknix-agent-dispatch--last-delivered (make-hash-table :test 'equal))
          (decknix-agent-dispatch--interrupts nil)
          (dispatch-test--interrupted nil)
          (dispatch-test--tags nil)
          (dispatch-test--quiet nil)
          (decknix-agent-dispatch-interrupt-function
           (lambda (buf) (push buf dispatch-test--interrupted)))
          (decknix-agent-dispatch-tags-function
           (lambda (sid) (alist-get sid dispatch-test--tags nil nil #'equal)))
          (decknix-agent-dispatch-settled-function
           (lambda (buf) (memq buf dispatch-test--quiet)))
          (decknix-agent-dispatch-closing-text-function
           (lambda (buf) (buffer-local-value 'dispatch-test--closing buf)))
          (decknix-agent-dispatch--pending-seen nil)
          (decknix-agent-dispatch--armed-at 900)
          (decknix-agent-dispatch-submit-function #'dispatch-test--stub-submit)
          (decknix-agent-dispatch-session-id-function
           (lambda (buf) (alist-get buf dispatch-test--sids)))
          (decknix-agent-dispatch-buffers-function
           (lambda () (mapcar #'car dispatch-test--sids)))
          (dispatch-test--buf-tags nil)
          (dispatch-test--spawned nil)
          (dispatch-test--resumed nil)
          (dispatch-test--retired nil)
          (dispatch-test--spawn-mode 'buffer)
          (dispatch-test--retire-mode 'kill)
          (decknix-agent-dispatch--spawning (make-hash-table :test 'equal))
          (decknix-agent-dispatch--last-spawn-at nil)
          (decknix-agent-dispatch--lane-buffers nil)
          (decknix-agent-dispatch-spawn-counted-tag-regexp "\\`lane-[0-9]+\\'")
          (decknix-agent-dispatch--armed-by nil)
          (decknix-agent-dispatch--release-queued nil)
          (decknix-agent-dispatch-lifecycle-policy 'always)
          (decknix-agent-dispatch-spawn-roots (list root))
          (decknix-agent-dispatch-spawn-max-live 32)
          (decknix-agent-dispatch-spawn-min-interval 10)
          (decknix-agent-dispatch-retire-protected-tags '("coordinator"))
          (decknix-agent-dispatch-live-tags-function
           (lambda (buf) (alist-get buf dispatch-test--buf-tags)))
          (decknix-agent-dispatch-spawn-function #'dispatch-test--stub-spawn)
          (decknix-agent-dispatch-resume-function #'dispatch-test--stub-resume)
          (decknix-agent-dispatch-retire-function #'dispatch-test--stub-retire))
     (make-directory (expand-file-name "ws" root))
     (unwind-protect
         (cl-letf (((symbol-function 'decknix-agent-dispatch--now)
                    (lambda () dispatch-test--clock))
                   ((symbol-function 'decknix--agent-quickaction-start)
                    (lambda (&rest _) (error "REAL quickaction-start called")))
                   ((symbol-function 'decknix--agent-session-resume)
                    (lambda (&rest _) (error "REAL session resume called")))
                   ((symbol-function 'decknix-session-lifecycle-quit)
                    (lambda (&rest _) (error "REAL lifecycle quit called")))
                   ((symbol-function 'agent-shell--start)
                    (lambda (&rest _) (error "REAL agent-shell--start called")))
                   ((symbol-function 'shell-maker-submit)
                    (lambda (&rest _) (error "REAL shell-maker-submit called")))
                   ((symbol-function 'decknix--compose-submit-after-wait)
                    (lambda (&rest _) (error "REAL compose submit called")))
                   ((symbol-function 'agent-shell-interrupt)
                    (lambda (&rest _) (error "INTERRUPT called"))))
           (decknix-agent-dispatch--ensure-dirs)
           ,@body)
       (dolist (cell dispatch-test--sids)
         (when (buffer-live-p (car cell))
           (when-let ((p (get-buffer-process (car cell)))) (delete-process p))
           (kill-buffer (car cell))))
       (delete-directory root t))))

(defvar dispatch-test--clock 1000)
(defvar dispatch-test--buf-tags nil "Alist BUFFER -> tags the live-tags seam returns.")
(defvar dispatch-test--spawned nil "Specs the spawn stub received, newest first.")
(defvar dispatch-test--resumed nil "Specs the resume stub received, newest first.")
(defvar dispatch-test--retired nil "Buffers the retire stub received.")
(defvar dispatch-test--spawn-mode 'buffer
  "How the spawn/resume stubs behave: buffer, silent (never call back), fail.")
(defvar dispatch-test--retire-mode 'kill "How the retire stub behaves: kill, keep.")

(defun dispatch-test--stub-start (spec callback log)
  (set log (cons spec (symbol-value log)))
  (pcase dispatch-test--spawn-mode
    ('buffer
     (let ((buf (generate-new-buffer "spawned")))
       (make-pipe-process :name "spawned" :buffer buf :noquery t)
       (push (cons buf nil) dispatch-test--sids)
       (push (cons buf (plist-get spec :tags)) dispatch-test--buf-tags)
       (funcall callback buf nil)))
    ('fail (funcall callback nil "boom"))
    ('silent nil)))

(defun dispatch-test--stub-spawn (spec callback)
  (dispatch-test--stub-start spec callback 'dispatch-test--spawned))

(defun dispatch-test--stub-resume (spec callback)
  (dispatch-test--stub-start spec callback 'dispatch-test--resumed))

(defun dispatch-test--stub-retire (buf)
  (push buf dispatch-test--retired)
  (when (eq dispatch-test--retire-mode 'kill)
    (when-let ((p (get-buffer-process buf))) (delete-process p))
    (kill-buffer buf)))
(defvar dispatch-test--interrupted nil "Buffers the interrupt stub was called with.")
(defvar dispatch-test--tags nil "Alist session id -> tags.")
(defvar dispatch-test--quiet nil "Busy buffers that read as waiting on background work.")
(defvar-local dispatch-test--closing nil)

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
    (should (equal "bad-version" (bad :v 4 1000)))
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

(ert-deftest decknix-agent-dispatch/enable-on-start-arms-as-startup-and-refuses-older-requests ()
  (dispatch-test-with-env
    (setq decknix-agent-dispatch--armed-at nil)
    (dispatch-test--make-session "target" dispatch-test--sid)
    (dispatch-test--drop :created (- dispatch-test--clock 5))
    (dispatch-test--drop3 "spawn" :id dispatch-test--rid-2
                          :created_at (- dispatch-test--clock 5) :queue t)
    (unwind-protect
        (progn
          (decknix-agent-dispatch-enable-on-start)
          (should decknix-agent-dispatch-mode)
          (should (equal "startup" (plist-get (decknix-agent-dispatch-state) :armed_by)))
          (should (eql dispatch-test--clock (plist-get (decknix-agent-dispatch-state) :armed_at)))
          (should-not decknix-agent-dispatch--release-queued)
          (decknix-agent-dispatch--tick)
          (should-not dispatch-test--sent)
          (should-not dispatch-test--spawned)
          (should (equal "predates-arming" (plist-get (dispatch-test--receipt) :reason)))
          (should (equal "predates-arming"
                         (plist-get (dispatch-test--receipt dispatch-test--rid-2) :reason))))
      (decknix-agent-dispatch-mode -1))))

(ert-deftest decknix-agent-dispatch/enable-on-start-leaves-an-armed-receiver-alone ()
  (dispatch-test-with-env
    (unwind-protect
        (progn
          (decknix-agent-dispatch-mode 1)
          (decknix-agent-dispatch-enable-on-start)
          (should (equal "human" (plist-get (decknix-agent-dispatch-state) :armed_by))))
      (decknix-agent-dispatch-mode -1))))

(ert-deftest decknix-agent-dispatch/enable-on-start-reports-rather-than-signals ()
  (let* ((root (make-temp-file "dispatch-mode" t))
         (decknix-agent-dispatch-dir (expand-file-name "state" root)))
    (unwind-protect
        (progn
          (make-directory decknix-agent-dispatch-dir)
          (make-directory (expand-file-name "pending" decknix-agent-dispatch-dir))
          (cl-letf (((symbol-function 'decknix-agent-dispatch--ensure-dirs) #'ignore))
            (set-file-modes decknix-agent-dispatch-dir #o755)
            (decknix-agent-dispatch-enable-on-start))
          (should-not decknix-agent-dispatch-mode))
      (decknix-agent-dispatch-mode -1)
      (delete-directory root t))))

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

;; -- version 2: modes, interrupts, receipts, notices -----------------

(defconst dispatch-test--coord "cccccccc-dddd-4eee-8fff-000000000000")

(defun dispatch-test--drop2 (&rest args)
  "Write a version 2 request; ARGS as `dispatch-test--drop' plus :when
:from :reason :notify :from_name :ttl."
  (let* ((id (or (plist-get args :id) dispatch-test--rid))
         (prompt (or (plist-get args :prompt) "do the thing"))
         (req (append
               (list :v 2 :id id
                     :session_id (or (plist-get args :session) dispatch-test--sid)
                     :prompt prompt
                     :prompt_sha256 (secure-hash 'sha256 (encode-coding-string prompt 'utf-8))
                     :created_at dispatch-test--clock
                     :expires_at (+ dispatch-test--clock (or (plist-get args :ttl) 86400)))
               (cl-loop for k in '(:when :from :reason :from_name)
                        when (plist-get args k) append (list k (plist-get args k)))
               (and (plist-get args :notify) (list :notify t))))
         (path (expand-file-name (concat id ".json") (dispatch-test--sub "pending"))))
    (with-file-modes #o600
      (with-temp-file path (insert (json-serialize req))))
    path))

(defun dispatch-test--json (path)
  (when (file-exists-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (json-parse-string (buffer-string) :object-type 'plist))))

(defun dispatch-test--answered (&optional id)
  (dispatch-test--json (expand-file-name (concat (or id dispatch-test--rid) ".answered.json")
                                         (dispatch-test--sub "receipts"))))

(defun dispatch-test--notices (from)
  (let ((dir (expand-file-name from (dispatch-test--sub "notices"))))
    (when (file-directory-p dir)
      (mapcar (lambda (f) (dispatch-test--json (expand-file-name f dir)))
              (directory-files dir nil "\\.json\\'")))))

(defun dispatch-test--type (buf text)
  (with-current-buffer buf
    (insert "> ")
    (set-marker (process-mark (get-buffer-process buf)) (point-max))
    (insert text)))

(ert-deftest decknix-agent-dispatch/v2-validation ()
  (let ((r (list :v 2 :id dispatch-test--rid :session_id dispatch-test--sid
                 :prompt "hello"
                 :prompt_sha256 (secure-hash 'sha256 (encode-coding-string "hello" 'utf-8))
                 :created_at 1000 :expires_at (+ 1000 86400))))
    (should-not (decknix-agent-dispatch--validate r 1000))
    (should (equal "ttl-too-long"
                   (decknix-agent-dispatch--validate
                    (plist-put (copy-sequence r) :expires_at (+ 1000 (* 8 86400))) 1000)))
    (should (equal "bad-mode"
                   (decknix-agent-dispatch--validate
                    (append r '(:when "later")) 1000)))
    (should (equal "bad-from"
                   (decknix-agent-dispatch--validate (append r '(:from "nope")) 1000)))
    (should (equal "interrupt-needs-reason"
                   (decknix-agent-dispatch--validate (append r '(:when "interrupt")) 1000)))
    (should-not (decknix-agent-dispatch--validate
                 (append r '(:when "interrupt" :reason "obsolete work")) 1000))
    (should (equal "ttl-too-long"
                   (decknix-agent-dispatch--validate
                    (plist-put (plist-put (copy-sequence r) :v 1) :expires_at 99999) 1000)))))

(ert-deftest decknix-agent-dispatch/v2-decide-table ()
  (cl-flet ((d (&rest kv)
              (apply #'decknix-agent-dispatch--decide
                     (append kv '(:matches 1 :same t :proc t :unsent nil :busy nil)))))
    (should (equal 'wait (d :mode 'idle :unsent t)))
    (should (equal 'wait (d :mode 'idle :busy t)))
    (should (equal '(refuse . "busy") (d :mode 'now :busy t)))
    (should (equal '(refuse . "unsent-input") (d :mode 'now :unsent t)))
    (should (equal 'interrupt (d :mode 'interrupt :busy t)))
    (should (equal 'wait (d :mode 'interrupt :busy t :interrupted 1000)))
    (should (equal '(refuse . "unsent-input") (d :mode 'interrupt :busy t :unsent t)))
    (should (equal 'submit (d :mode 'interrupt)))))

(ert-deftest decknix-agent-dispatch/v2-idle-waits-for-typed-text-then-delivers ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (dispatch-test--type buf "half typed")
      (dispatch-test--drop2 :from dispatch-test--coord :from_name "coord")
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--sent)
      (should-not (dispatch-test--receipt))
      (should (= 1 (decknix-agent-dispatch-waiting-count dispatch-test--sid)))
      (with-current-buffer buf (erase-buffer) (insert "> ")
                           (set-marker (process-mark (get-buffer-process buf)) (point-max)))
      (setq dispatch-test--clock 5000)
      (decknix-agent-dispatch--tick)
      (should (equal (format "[decknix message %s from coord]\ndo the thing"
                             (substring dispatch-test--rid 0 8))
                     (cdar dispatch-test--sent)))
      (should (equal "accepted" (plist-get (dispatch-test--receipt) :state)))
      (should (equal dispatch-test--rid
                     (plist-get (decknix-agent-dispatch-last-delivered dispatch-test--sid) :id))))))

(ert-deftest decknix-agent-dispatch/v2-idle-outlives-the-v1-ceiling ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (with-current-buffer buf (setq-local shell-maker--busy t))
      (dispatch-test--drop2)
      (decknix-agent-dispatch--tick)
      (setq dispatch-test--clock (+ 1000 3600))
      (decknix-agent-dispatch--tick)
      (should-not (dispatch-test--receipt))
      (with-current-buffer buf (setq-local shell-maker--busy nil))
      (decknix-agent-dispatch--tick)
      (should (equal "accepted" (plist-get (dispatch-test--receipt) :state))))))

(ert-deftest decknix-agent-dispatch/v2-now-refuses-a-busy-session ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (with-current-buffer buf (setq-local shell-maker--busy t))
      (dispatch-test--drop2 :when "now" :ttl 60 :from dispatch-test--coord :notify t)
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--sent)
      (should-not dispatch-test--interrupted)
      (should (equal "busy" (plist-get (dispatch-test--receipt) :reason)))
      (let ((n (car (dispatch-test--notices dispatch-test--coord))))
        (should (equal "rejected" (plist-get n :state)))
        (should (equal "busy" (plist-get n :reason)))))))

(ert-deftest decknix-agent-dispatch/v2-interrupt-cancels-then-delivers-with-reason ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (push (cons dispatch-test--coord '("coordinator")) dispatch-test--tags)
      (with-current-buffer buf (setq-local shell-maker--busy t))
      (dispatch-test--drop2 :when "interrupt" :reason "plan changed"
                            :from dispatch-test--coord :from_name "coord")
      (decknix-agent-dispatch--tick)
      (should (equal (list buf) dispatch-test--interrupted))
      (should-not dispatch-test--sent)
      (decknix-agent-dispatch--tick)
      (should (= 1 (length dispatch-test--interrupted)))
      (with-current-buffer buf (setq-local shell-maker--busy nil))
      (decknix-agent-dispatch--tick)
      (should (string-match-p "interrupted your turn: plan changed\\]\ndo the thing\\'"
                              (cdar dispatch-test--sent)))
      (should (equal "accepted" (plist-get (dispatch-test--receipt) :state)))
      (should-not (dispatch-test--state-files "inflight")))))

(ert-deftest decknix-agent-dispatch/v2-interrupt-policy-refuses-untagged-senders ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (with-current-buffer buf (setq-local shell-maker--busy t))
      (dispatch-test--drop2 :when "interrupt" :reason "x" :from dispatch-test--coord)
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--interrupted)
      (should (equal "interrupt-not-allowed" (plist-get (dispatch-test--receipt) :reason))))))

(ert-deftest decknix-agent-dispatch/v2-interrupt-policy-table ()
  (let ((decknix-agent-dispatch--interrupts nil)
        (tags (lambda (s) (pcase s ("C" '("coordinator")) ("L" '("interruptible"))))))
    (let ((decknix-agent-dispatch-interrupt-policy 'never))
      (should (equal "interrupt-not-allowed"
                     (decknix-agent-dispatch--interrupt-refusal "C" "L" tags 0))))
    (let ((decknix-agent-dispatch-interrupt-policy 'opt-in))
      (should-not (decknix-agent-dispatch--interrupt-refusal "X" "L" tags 0))
      (should (decknix-agent-dispatch--interrupt-refusal "C" "M" tags 0)))
    (let ((decknix-agent-dispatch-interrupt-policy 'coordinator))
      (should-not (decknix-agent-dispatch--interrupt-refusal "C" "M" tags 0))
      (should-not (decknix-agent-dispatch--interrupt-refusal nil "L" tags 0))
      (should (decknix-agent-dispatch--interrupt-refusal "X" "M" tags 0))
      (should (equal "interrupt-self"
                     (decknix-agent-dispatch--interrupt-refusal "C" "C" tags 0))))
    (let ((decknix-agent-dispatch-interrupt-policy 'always))
      (should-not (decknix-agent-dispatch--interrupt-refusal "X" "M" tags 0)))))

(ert-deftest decknix-agent-dispatch/v2-interrupts-are-rate-limited-and-loop-guarded ()
  (let ((decknix-agent-dispatch--interrupts nil)
        (decknix-agent-dispatch-interrupt-policy 'always)
        (tags #'ignore))
    (decknix-agent-dispatch--note-interrupt "A" "B" 1000)
    (should (equal "interrupt-rate-limited"
                   (decknix-agent-dispatch--interrupt-refusal "C" "B" tags 1100)))
    (should (equal "interrupt-loop"
                   (decknix-agent-dispatch--interrupt-refusal "B" "A" tags 1100)))
    (should-not (decknix-agent-dispatch--interrupt-refusal "C" "D" tags 1100))
    (should-not (decknix-agent-dispatch--interrupt-refusal "B" "A" tags 1400))))

(ert-deftest decknix-agent-dispatch/v2-answered-receipt-and-notices ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (dispatch-test--drop2 :from dispatch-test--coord :notify t)
      (decknix-agent-dispatch--tick)
      (should (equal "accepted" (plist-get (dispatch-test--receipt) :state)))
      (should-not (dispatch-test--answered))
      (with-current-buffer buf
        (setq-local dispatch-test--closing "Done; PR is up.")
        (setq-local shell-maker--busy nil))
      (decknix-agent-dispatch--tick)
      (let ((a (dispatch-test--answered)))
        (should (equal "answered" (plist-get a :state)))
        (should (equal "Done; PR is up." (plist-get a :tail))))
      (should (equal '("accepted" "answered")
                     (sort (mapcar (lambda (n) (plist-get n :state))
                                   (dispatch-test--notices dispatch-test--coord))
                           #'string<))))))

(ert-deftest decknix-agent-dispatch/v2-answered-when-the-turn-only-waits-on-background-work ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (dispatch-test--drop2)
      (decknix-agent-dispatch--tick)
      (decknix-agent-dispatch--tick)
      (should-not (dispatch-test--answered))
      (push buf dispatch-test--quiet)
      (decknix-agent-dispatch--tick)
      (should (eq t (plist-get (dispatch-test--answered) :turn_open))))))

(ert-deftest decknix-agent-dispatch/v2-expiry-notifies-the-sender ()
  (dispatch-test-with-env
    (let ((buf (dispatch-test--make-session "target" dispatch-test--sid)))
      (with-current-buffer buf (setq-local shell-maker--busy t))
      (dispatch-test--drop2 :ttl 100 :from dispatch-test--coord :notify t)
      (decknix-agent-dispatch--tick)
      (setq dispatch-test--clock 1200)
      (decknix-agent-dispatch--tick)
      (should (equal "expired" (plist-get (dispatch-test--receipt) :state)))
      (should (equal "expired" (plist-get (car (dispatch-test--notices dispatch-test--coord))
                                          :state))))))

(ert-deftest decknix-agent-dispatch/v1-sends-no-envelope-and-no-notice ()
  (dispatch-test-with-env
    (dispatch-test--make-session "target" dispatch-test--sid)
    (dispatch-test--drop)
    (decknix-agent-dispatch--tick)
    (should (equal "do the thing" (cdar dispatch-test--sent)))
    (should-not (directory-files (dispatch-test--sub "notices") nil "\\`[^.]"))
    (should (= 0 (hash-table-count decknix-agent-dispatch--delivered)))))

;; -- version 3: spawn and retire -----------------------------------

(defconst dispatch-test--lane-tags ["us" "lane-07"])

(defun dispatch-test--ws ()
  (expand-file-name "ws" (file-name-directory (directory-file-name decknix-agent-dispatch-dir))))

(defun dispatch-test--v3 (kind &rest args)
  "Return a version 3 KIND request plist; ARGS override or add fields."
  (let* ((brief (if (plist-member args :brief) (plist-get args :brief) "Pick up lane 07."))
         (base (pcase kind
                 ("spawn" (list :workspace (dispatch-test--ws)
                                :tags dispatch-test--lane-tags
                                :brief brief
                                :brief_sha256 (and (stringp brief)
                                                   (secure-hash
                                                    'sha256 (encode-coding-string brief 'utf-8)))))
                 ("retire" (list :session_id dispatch-test--sid
                                 :expect_tags dispatch-test--lane-tags))
                 (_ nil)))
         (req (append (list :v 3 :id (or (plist-get args :id) dispatch-test--rid)
                            :kind kind
                            :created_at dispatch-test--clock
                            :expires_at (+ dispatch-test--clock 3600))
                      base)))
    (cl-loop for (k v) on args by #'cddr
             unless (eq k :brief)
             do (setq req (plist-put req k v)))
    req))

(defun dispatch-test--drop3 (kind &rest args)
  (let* ((req (apply #'dispatch-test--v3 kind args))
         (path (expand-file-name (concat (plist-get req :id) ".json")
                                 (dispatch-test--sub "pending"))))
    (with-file-modes #o600
      (with-temp-file path (insert (json-serialize req))))
    path))

(defun dispatch-test--spawned-receipt (&optional id)
  (dispatch-test--json (expand-file-name (concat (or id dispatch-test--rid) ".spawned.json")
                                         (dispatch-test--sub "receipts"))))

(defun dispatch-test--lane (name sid tags)
  (let ((buf (dispatch-test--make-session name sid)))
    (push (cons buf tags) dispatch-test--buf-tags)
    buf))

(ert-deftest decknix-agent-dispatch/v3-validation-table ()
  (dispatch-test-with-env
    (cl-flet ((v (kind &rest args)
                (decknix-agent-dispatch--validate (apply #'dispatch-test--v3 kind args)
                                                  dispatch-test--clock)))
      (should-not (v "spawn"))
      (should-not (v "retire"))
      (should-not (v "spawn" :resume_session_id dispatch-test--sid-2 :agent "claude"
                     :model "opus" :mode "auto" :name "lane-07" :queue t))
      (should (equal "bad-kind" (v "launch")))
      (should (equal "bad-kind" (v "dispatch")))
      (should (equal "bad-tags" (v "spawn" :tags [])))
      (should (equal "bad-tags" (v "spawn" :tags [1])))
      (should (equal "bad-tags" (v "spawn" :tags "us")))
      (should (equal "bad-workspace" (v "spawn" :workspace "relative/dir")))
      (should (equal "malformed" (v "spawn" :brief nil)))
      (should (equal "hash-mismatch" (v "spawn" :brief_sha256 "00")))
      (should (equal "bad-resume-id" (v "spawn" :resume_session_id "11111111")))
      (should (equal "bad-field" (v "spawn" :agent 7)))
      (should (equal "bad-session-id" (v "retire" :session_id "11111111")))
      (should (equal "bad-tags" (v "retire" :expect_tags nil)))
      (should (equal "bad-from" (v "retire" :from "nope")))
      (should (equal "bad-reason" (v "retire" :reason (make-string 400 ?x))))
      (should (equal "ttl-too-long" (v "spawn" :expires_at (+ dispatch-test--clock 90000))))
      (should (equal "bad-id" (v "spawn" :id "nope"))))))

(ert-deftest decknix-agent-dispatch/v3-dispatch-kind-in-pending-is-wrong-channel ()
  (dispatch-test-with-env
    (dispatch-test--drop3 "dispatch" :op "on")
    (decknix-agent-dispatch--tick)
    (should (equal "rejected" (plist-get (dispatch-test--receipt) :state)))
    (should (equal "bad-kind" (plist-get (dispatch-test--receipt) :reason)))))

(ert-deftest decknix-agent-dispatch/spawn-creates-in-background-with-an-envelope ()
  (dispatch-test-with-env
    (dispatch-test--drop3 "spawn" :from dispatch-test--coord :from_name "coord"
                          :model "opus" :mode "auto" :name "lane-07")
    (decknix-agent-dispatch--tick)
    (should (= 1 (length dispatch-test--spawned)))
    (let ((spec (car dispatch-test--spawned)))
      (should (equal (dispatch-test--ws) (plist-get spec :workspace)))
      (should (equal '("us" "lane-07") (plist-get spec :tags)))
      (should (equal "lane-07" (plist-get spec :name)))
      (should (equal "opus" (plist-get spec :model)))
      (should (equal "auto" (plist-get spec :mode)))
      (should (equal (format "[decknix spawn %s from coord]\nPick up lane 07."
                             (substring dispatch-test--rid 0 8))
                     (plist-get spec :brief))))
    (let ((r (dispatch-test--receipt)))
      (should (equal "accepted" (plist-get r :state)))
      (should (equal "spawn" (plist-get r :kind)))
      (should (equal "new" (plist-get r :outcome))))
    (should-not (dispatch-test--spawned-receipt))
    (should-not (dispatch-test--state-files "inflight"))
    (let ((buf (caar dispatch-test--sids)))
      (setf (alist-get buf dispatch-test--sids) dispatch-test--sid-2)
      (decknix-agent-dispatch--tick)
      (let ((s (dispatch-test--spawned-receipt)))
        (should (equal dispatch-test--sid-2 (plist-get s :session_id)))
        (should (equal (buffer-name buf) (plist-get s :buffer)))
        (should (equal "new" (plist-get s :outcome)))))
    (should (= 0 (hash-table-count decknix-agent-dispatch--spawning)))))

(ert-deftest decknix-agent-dispatch/spawn-finds-the-existing-lane-and-sends-nothing ()
  (dispatch-test-with-env
    (let ((lane (dispatch-test--lane "lane" dispatch-test--sid '("us" "lane-07" "PLAT-1"))))
      (dispatch-test--drop3 "spawn")
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--spawned)
      (should-not dispatch-test--resumed)
      (should-not dispatch-test--sent)
      (should (equal "existing" (plist-get (dispatch-test--receipt) :outcome)))
      (let ((s (dispatch-test--spawned-receipt)))
        (should (equal dispatch-test--sid (plist-get s :session_id)))
        (should (equal (buffer-name lane) (plist-get s :buffer)))
        (should (equal "existing" (plist-get s :outcome)))))))

(ert-deftest decknix-agent-dispatch/spawn-matching-two-lanes-is-ambiguous ()
  (dispatch-test-with-env
    (dispatch-test--lane "a" dispatch-test--sid '("us" "lane-07"))
    (dispatch-test--lane "b" dispatch-test--sid-2 '("US" "Lane-07"))
    (dispatch-test--drop3 "spawn")
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--spawned)
    (should (equal "ambiguous-existing" (plist-get (dispatch-test--receipt) :reason)))))

(ert-deftest decknix-agent-dispatch/spawn-refusals ()
  (cl-flet ((refused (setup &rest args)
              (dispatch-test-with-env
                (funcall setup)
                (apply #'dispatch-test--drop3 "spawn" args)
                (decknix-agent-dispatch--tick)
                (should-not dispatch-test--spawned)
                (should (equal "rejected" (plist-get (dispatch-test--receipt) :state)))
                (plist-get (dispatch-test--receipt) :reason))))
    (should (equal "lifecycle-not-allowed"
                   (refused (lambda () (setq decknix-agent-dispatch-lifecycle-policy 'never)))))
    (should (equal "lifecycle-not-allowed"
                   (refused (lambda () (setq decknix-agent-dispatch-lifecycle-policy 'coordinator))
                            :from dispatch-test--coord)))
    (should (equal "workspace-not-allowed"
                   (refused #'ignore :workspace temporary-file-directory)))
    (should (equal "no-workspace"
                   (refused (lambda () (delete-directory (dispatch-test--ws))))))
    (should (equal "too-many-sessions"
                   (refused (lambda ()
                              (setq decknix-agent-dispatch-spawn-max-live 1)
                              (dispatch-test--lane "other" dispatch-test--sid-2 '("lane-03"))))))
    (should (equal "spawn-rate-limited"
                   (refused (lambda () (setq decknix-agent-dispatch--last-spawn-at
                                             (- dispatch-test--clock 5))))))))

(ert-deftest decknix-agent-dispatch/spawn-agent-names-map-to-provider-ids ()
  (should (eq 'claude-code (decknix-agent-dispatch--agent-provider "claude")))
  (should (eq 'auggie (decknix-agent-dispatch--agent-provider "auggie")))
  (should (eq 'pi (decknix-agent-dispatch--agent-provider "pi")))
  (should-not (decknix-agent-dispatch--agent-provider nil))
  (should (eq :unknown (decknix-agent-dispatch--agent-provider "claude-code")))
  (should (eq :unknown (decknix-agent-dispatch--agent-provider "gpt"))))

(ert-deftest decknix-agent-dispatch/default-spawn-starts-the-mapped-provider ()
  (dolist (case '(("claude" . claude-code) ("auggie" . auggie) ("pi" . pi) (nil . nil)))
    (dispatch-test-with-env
      (let (started result)
        (cl-letf (((symbol-function 'decknix-agent-get-provider)
                   (lambda (id) (memq id '(claude-code auggie pi))))
                  ((symbol-function 'decknix--agent-find-new-shell-buffer) (lambda (_) 'buf))
                  ((symbol-function 'decknix--agent-quickaction-start)
                   (lambda (&rest args) (setq started args))))
          (decknix-agent-dispatch--start-session
           (list :name "lane" :tags '("lane-01") :workspace "/w" :brief "go"
                 :agent (car case))
           (lambda (buf err) (setq result (list buf err)))))
        (should (equal '(buf nil) result))
        (should (eq (cdr case) (nth 5 started)))
        (should (eq t (nth 7 started)))))))

(ert-deftest decknix-agent-dispatch/spawn-with-an-unknown-agent-is-rejected-before-starting ()
  (dispatch-test-with-env
    (dispatch-test--drop3 "spawn" :agent "gpt")
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--spawned)
    (should (equal "rejected" (plist-get (dispatch-test--receipt) :state)))
    (should (equal "unknown-agent" (plist-get (dispatch-test--receipt) :reason)))
    (should-not decknix-agent-dispatch--last-spawn-at))
  (dispatch-test-with-env
    (cl-letf (((symbol-function 'decknix-agent-get-provider) #'ignore))
      (dispatch-test--drop3 "spawn" :agent "pi")
      (decknix-agent-dispatch--tick))
    (should-not dispatch-test--spawned)
    (should (equal "unknown-agent" (plist-get (dispatch-test--receipt) :reason))))
  (dispatch-test-with-env
    (dispatch-test--drop3 "spawn" :agent "claude")
    (decknix-agent-dispatch--tick)
    (should (equal "claude" (plist-get (car dispatch-test--spawned) :agent)))
    (should (equal "accepted" (plist-get (dispatch-test--receipt) :state)))))

(ert-deftest decknix-agent-dispatch/spawn-cap-counts-only-lanes ()
  (dispatch-test-with-env
    (setq decknix-agent-dispatch-spawn-max-live 1)
    (dispatch-test--lane "human" dispatch-test--sid '("PLAT-1"))
    (dispatch-test--lane "review" dispatch-test--sid-2 '("review" "repo#12"))
    (dispatch-test--make-session "untagged" "33333333-2222-4333-8444-555555555555")
    (should (= 0 (decknix-agent-dispatch-counted-lanes)))
    (dispatch-test--drop3 "spawn" :tags ["PLAT-2"])
    (decknix-agent-dispatch--tick)
    (should (equal "accepted" (plist-get (dispatch-test--receipt) :state)))
    (should (= 1 (decknix-agent-dispatch-counted-lanes))))
  (dispatch-test-with-env
    (setq decknix-agent-dispatch-spawn-max-live 2)
    (dispatch-test--lane "a" dispatch-test--sid '("us" "lane-01"))
    (dispatch-test--lane "b" dispatch-test--sid-2 '("Lane-12"))
    (dispatch-test--lane "c" "33333333-2222-4333-8444-555555555555" '("lane-1x" "xlane-2"))
    (should (= 2 (decknix-agent-dispatch-counted-lanes)))
    (dispatch-test--drop3 "spawn")
    (decknix-agent-dispatch--tick)
    (should (equal "too-many-sessions" (plist-get (dispatch-test--receipt) :reason)))))

(ert-deftest decknix-agent-dispatch/spawned-sessions-count-without-a-lane-tag ()
  (dispatch-test-with-env
    (setq decknix-agent-dispatch-spawn-max-live 1)
    (dispatch-test--drop3 "spawn" :tags ["PLAT-2"])
    (decknix-agent-dispatch--tick)
    (should (= 1 (length dispatch-test--spawned)))
    (setf (alist-get (caar dispatch-test--sids) dispatch-test--sids) dispatch-test--sid-2)
    (decknix-agent-dispatch--tick)
    (should (dispatch-test--spawned-receipt))
    (should (= 1 (decknix-agent-dispatch-counted-lanes)))
    (setq dispatch-test--clock (+ dispatch-test--clock 60))
    (dispatch-test--drop3 "spawn" :id dispatch-test--rid-2 :tags ["PLAT-3"])
    (decknix-agent-dispatch--tick)
    (should (= 1 (length dispatch-test--spawned)))
    (should (equal "too-many-sessions"
                   (plist-get (dispatch-test--receipt dispatch-test--rid-2) :reason)))
    (let ((buf (caar dispatch-test--sids)))
      (delete-process (get-buffer-process buf))
      (kill-buffer buf))
    (should (= 0 (decknix-agent-dispatch-counted-lanes)))))

(ert-deftest decknix-agent-dispatch/spawn-cap-defaults-to-32-lanes ()
  (should (= 32 (eval (car (get 'decknix-agent-dispatch-spawn-max-live 'standard-value)) t))))

(ert-deftest decknix-agent-dispatch/lane-usage-reports-counted-lanes-and-the-cap ()
  (dispatch-test-with-env
    (setq decknix-agent-dispatch-spawn-max-live 5)
    (dispatch-test--lane "a" dispatch-test--sid '("us" "lane-01"))
    (dispatch-test--lane "review" dispatch-test--sid-2 '("review"))
    (should (equal '(:lanes_live 1 :spawn_max_live 5) (decknix-agent-dispatch-lane-usage)))))

(ert-deftest decknix-agent-dispatch/counted-tag-regexp-nil-counts-only-spawned ()
  (dispatch-test-with-env
    (setq decknix-agent-dispatch-spawn-counted-tag-regexp nil)
    (dispatch-test--lane "a" dispatch-test--sid '("lane-01"))
    (should (= 0 (decknix-agent-dispatch-counted-lanes)))))

(ert-deftest decknix-agent-dispatch/spawn-coordinator-policy-allows-a-coordinator ()
  (dispatch-test-with-env
    (setq decknix-agent-dispatch-lifecycle-policy 'coordinator
          dispatch-test--tags `((,dispatch-test--coord . ("coordinator"))))
    (dispatch-test--drop3 "spawn" :from dispatch-test--coord)
    (decknix-agent-dispatch--tick)
    (should (= 1 (length dispatch-test--spawned)))))

(ert-deftest decknix-agent-dispatch/spawn-times-out-or-dies-as-spawn-failed ()
  (dispatch-test-with-env
    (setq dispatch-test--spawn-mode 'silent)
    (dispatch-test--drop3 "spawn")
    (decknix-agent-dispatch--tick)
    (should (equal "accepted" (plist-get (dispatch-test--receipt) :state)))
    (setq dispatch-test--clock (+ dispatch-test--clock 181))
    (decknix-agent-dispatch--tick)
    (let ((s (dispatch-test--spawned-receipt)))
      (should (equal "spawn-failed" (plist-get s :state)))
      (should (equal "timeout" (plist-get s :reason)))))
  (dispatch-test-with-env
    (dispatch-test--drop3 "spawn")
    (decknix-agent-dispatch--tick)
    (let ((buf (caar dispatch-test--sids)))
      (delete-process (get-buffer-process buf))
      (kill-buffer buf))
    (decknix-agent-dispatch--tick)
    (should (equal "buffer-died" (plist-get (dispatch-test--spawned-receipt) :reason))))
  (dispatch-test-with-env
    (setq dispatch-test--spawn-mode 'fail)
    (dispatch-test--drop3 "spawn")
    (decknix-agent-dispatch--tick)
    (should (equal "spawn-failed" (plist-get (dispatch-test--spawned-receipt) :state)))))

(ert-deftest decknix-agent-dispatch/a-started-spawn-holds-the-rate-limit-slot ()
  (dispatch-test-with-env
    (dispatch-test--drop3 "spawn")
    (decknix-agent-dispatch--tick)
    (should (= 1 (length dispatch-test--spawned)))
    (setq dispatch-test--clock (+ dispatch-test--clock 5))
    (dispatch-test--drop3 "spawn" :id dispatch-test--rid-2 :tags ["lane-08"])
    (decknix-agent-dispatch--tick)
    (should (= 1 (length dispatch-test--spawned)))
    (should (equal "spawn-rate-limited"
                   (plist-get (dispatch-test--receipt dispatch-test--rid-2) :reason)))))

(ert-deftest decknix-agent-dispatch/a-failed-spawn-frees-the-rate-limit-slot ()
  (dispatch-test-with-env
    (setq dispatch-test--spawn-mode 'fail)
    (dispatch-test--drop3 "spawn")
    (decknix-agent-dispatch--tick)
    (should (equal "spawn-failed" (plist-get (dispatch-test--spawned-receipt) :state)))
    (should-not decknix-agent-dispatch--last-spawn-at)
    (setq dispatch-test--spawn-mode 'buffer)
    (dispatch-test--drop3 "spawn" :id dispatch-test--rid-2 :tags ["lane-08"])
    (decknix-agent-dispatch--tick)
    (should (equal "accepted" (plist-get (dispatch-test--receipt dispatch-test--rid-2) :state)))
    (should (= 2 (length dispatch-test--spawned))))
  (dispatch-test-with-env
    (let (callback)
      (setq decknix-agent-dispatch--last-spawn-at 700
            decknix-agent-dispatch-spawn-function
            (lambda (_spec cb) (setq callback cb)))
      (dispatch-test--drop3 "spawn")
      (decknix-agent-dispatch--tick)
      (should (eql dispatch-test--clock decknix-agent-dispatch--last-spawn-at))
      (setq dispatch-test--clock (+ dispatch-test--clock 2))
      (funcall callback nil "unknown agent claude")
      (should (equal "spawn-failed" (plist-get (dispatch-test--spawned-receipt) :state)))
      (should (eql 700 decknix-agent-dispatch--last-spawn-at))))
  (dispatch-test-with-env
    (setq decknix-agent-dispatch-spawn-function
          (lambda (_spec _cb) (error "start blew up")))
    (dispatch-test--drop3 "spawn")
    (decknix-agent-dispatch--tick)
    (should (equal "spawn-failed" (plist-get (dispatch-test--spawned-receipt) :state)))
    (should-not decknix-agent-dispatch--last-spawn-at)))

(ert-deftest decknix-agent-dispatch/spawn-resumes-then-delivers-the-brief-once-settled ()
  (dispatch-test-with-env
    (dispatch-test--drop3 "spawn" :resume_session_id dispatch-test--sid-2)
    (decknix-agent-dispatch--tick)
    (should-not dispatch-test--spawned)
    (should (equal dispatch-test--sid-2 (plist-get (car dispatch-test--resumed) :session_id)))
    (should (equal "resumed" (plist-get (dispatch-test--receipt) :outcome)))
    (let ((buf (caar dispatch-test--sids)))
      (setf (alist-get buf dispatch-test--sids) dispatch-test--sid-2)
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--sent)
      (setq dispatch-test--clock (+ dispatch-test--clock 5))
      (decknix-agent-dispatch--tick)
      (should (equal buf (caar dispatch-test--sent)))
      (should (string-prefix-p "[decknix spawn " (cdar dispatch-test--sent)))
      (let ((s (dispatch-test--spawned-receipt)))
        (should (equal "resumed" (plist-get s :outcome)))
        (should (equal dispatch-test--sid-2 (plist-get s :session_id)))))))

(ert-deftest decknix-agent-dispatch/queued-spawn-needs-a-release-to-beat-arming ()
  (dispatch-test-with-env
    (setq decknix-agent-dispatch--armed-at 990)
    (dispatch-test--drop3 "spawn" :created_at 980 :queue t)
    (decknix-agent-dispatch--tick)
    (should (equal "predates-arming" (plist-get (dispatch-test--receipt) :reason))))
  (dispatch-test-with-env
    (setq decknix-agent-dispatch--armed-at 990
          decknix-agent-dispatch--release-queued t)
    (dispatch-test--drop3 "spawn" :created_at 980 :queue t)
    (decknix-agent-dispatch--tick)
    (should (equal "accepted" (plist-get (dispatch-test--receipt) :state))))
  (dispatch-test-with-env
    (setq decknix-agent-dispatch--armed-at 990
          decknix-agent-dispatch--release-queued t)
    (dispatch-test--drop3 "spawn" :created_at 980)
    (decknix-agent-dispatch--tick)
    (should (equal "predates-arming" (plist-get (dispatch-test--receipt) :reason)))))

(ert-deftest decknix-agent-dispatch/retire-quits-an-idle-lane-and-verifies ()
  (dispatch-test-with-env
    (let ((lane (dispatch-test--lane "lane" dispatch-test--sid '("us" "lane-07"))))
      (dispatch-test--drop3 "retire" :expect_buffer "lane" :reason "done")
      (decknix-agent-dispatch--tick)
      (should (equal (list lane) dispatch-test--retired))
      (let ((r (dispatch-test--receipt)))
        (should (equal "accepted" (plist-get r :state)))
        (should (equal "retire" (plist-get r :kind)))
        (should (equal "retired" (plist-get r :outcome)))))))

(ert-deftest decknix-agent-dispatch/retire-refusals ()
  (cl-flet ((refused (setup &rest args)
              (dispatch-test-with-env
                (let ((lane (dispatch-test--lane "lane" dispatch-test--sid '("us" "lane-07"))))
                  (funcall setup lane)
                  (apply #'dispatch-test--drop3 "retire" args)
                  (decknix-agent-dispatch--tick)
                  (should-not dispatch-test--retired)
                  (should (buffer-live-p lane))
                  (plist-get (dispatch-test--receipt) :reason)))))
    (should (equal "protected-session"
                   (refused (lambda (l) (setf (alist-get l dispatch-test--buf-tags)
                                              '("us" "lane-07" "coordinator"))))))
    (should (equal "unsent-input"
                   (refused (lambda (l) (dispatch-test--type l "half typed")) :force t)))
    (should (equal "session-changed"
                   (refused (lambda (l) (setf (alist-get l dispatch-test--buf-tags) '("us"))))))
    (should (equal "session-changed" (refused #'ignore :expect_buffer "other")))
    (should (equal "no-session" (refused #'ignore :session_id dispatch-test--sid-2)))
    (should (equal "lifecycle-not-allowed"
                   (refused (lambda (_) (setq decknix-agent-dispatch-lifecycle-policy 'never)))))
    (should (equal "retire-self-needs-force"
                   (refused #'ignore :from dispatch-test--sid)))))

(ert-deftest decknix-agent-dispatch/retire-waits-for-idle-unless-forced ()
  (dispatch-test-with-env
    (let ((lane (dispatch-test--lane "lane" dispatch-test--sid '("us" "lane-07"))))
      (with-current-buffer lane (setq-local shell-maker--busy t))
      (dispatch-test--drop3 "retire")
      (decknix-agent-dispatch--tick)
      (should-not dispatch-test--retired)
      (should-not (dispatch-test--receipt))
      (with-current-buffer lane (setq-local shell-maker--busy nil))
      (decknix-agent-dispatch--tick)
      (should (equal "retired" (plist-get (dispatch-test--receipt) :outcome)))))
  (dispatch-test-with-env
    (let ((lane (dispatch-test--lane "lane" dispatch-test--sid '("us" "lane-07"))))
      (with-current-buffer lane (setq-local shell-maker--busy t))
      (dispatch-test--drop3 "retire" :force t)
      (decknix-agent-dispatch--tick)
      (should (equal (list lane) dispatch-test--retired))
      (should (equal "retired" (plist-get (dispatch-test--receipt) :outcome))))))

(ert-deftest decknix-agent-dispatch/retire-that-leaves-the-buffer-is-unknown ()
  (dispatch-test-with-env
    (setq dispatch-test--retire-mode 'keep)
    (dispatch-test--lane "lane" dispatch-test--sid '("us" "lane-07"))
    (dispatch-test--drop3 "retire")
    (decknix-agent-dispatch--tick)
    (should (equal "unknown" (plist-get (dispatch-test--receipt) :state)))))

(ert-deftest decknix-agent-dispatch/state-records-who-armed-it ()
  (let* ((root (make-temp-file "dispatch-mode" t))
         (decknix-agent-dispatch-dir (expand-file-name "state" root))
         (decknix-agent-dispatch--active (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (decknix-agent-dispatch-mode 1)
          (should (equal "human" (plist-get (decknix-agent-dispatch-state) :armed_by)))
          (should (plist-get (decknix-agent-dispatch-state) :on))
          (should (integerp (plist-get (decknix-agent-dispatch-state) :armed_at)))
          (decknix-agent-dispatch-mode -1)
          (let ((decknix-agent-dispatch-arming-source (concat "control:" dispatch-test--coord))
                (decknix-agent-dispatch-arming-release-queued t))
            (decknix-agent-dispatch-mode 1))
          (should (equal (concat "control:" dispatch-test--coord)
                         (plist-get (decknix-agent-dispatch-state) :armed_by)))
          (should decknix-agent-dispatch--release-queued)
          (decknix-agent-dispatch-mode -1)
          (should-not (plist-get (decknix-agent-dispatch-state) :on))
          (should-not (plist-get (decknix-agent-dispatch-state) :armed_by)))
      (decknix-agent-dispatch-mode -1)
      (delete-directory root t))))

(provide 'decknix-agent-dispatch-test)
;;; decknix-agent-dispatch-test.el ends here
