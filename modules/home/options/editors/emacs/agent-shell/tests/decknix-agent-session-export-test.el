;;; decknix-agent-session-export-test.el --- Tests for the session state export -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-export "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Sessions are plain buffers with a pipe process; the buffer list, session
;; ids and sidebar status are injected, and files go to a temporary dir.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'decknix-agent-session-export)

(defvar shell-maker--busy nil)
(defvar decknix-agent-dispatch-mode nil)
(defvar decknix-agent-dispatch-control-mode nil)
(defvar decknix-agent-dispatch-remote-control t)

(defconst export-test--sid "11111111-2222-4333-8444-555555555555")

(defvar export-test--sessions nil "Alist BUFFER -> session id.")
(defvar export-test--status nil "Alist BUFFER -> sidebar status.")
(defvar export-test--writes nil "Files written, newest first.")

(defmacro export-test-with-env (&rest body)
  (declare (indent 0))
  `(let* ((root (make-temp-file "export-test" t))
          (decknix-agent-session-export-dir (expand-file-name "sessions" root))
          (decknix-agent-session-export--written (make-hash-table :test 'equal))
          (decknix-agent-session-export--heartbeat-at 0)
          (decknix--hub-cache-write-digests (make-hash-table :test 'equal))
          (export-test--sessions nil)
          (export-test--status nil)
          (export-test--writes nil)
          (decknix-agent-session-export-buffers-function
           (lambda () (mapcar #'car export-test--sessions)))
          (decknix-agent-session-export-session-id-function
           (lambda (buf) (alist-get buf export-test--sessions)))
          (decknix-agent-session-export-status-function
           (lambda (buf) (or (alist-get buf export-test--status) "ready")))
          (decknix-agent-session-export-write-function
           (lambda (file text &optional force)
             (when (decknix-hub-cache-write-string file text force)
               (push (file-name-nondirectory file) export-test--writes)
               t))))
     (unwind-protect (progn ,@body)
       (dolist (cell export-test--sessions)
         (when-let ((p (get-buffer-process (car cell)))) (delete-process p))
         (when (buffer-live-p (car cell)) (kill-buffer (car cell))))
       (delete-directory root t))))

(defun export-test--session (name sid)
  (let ((buf (generate-new-buffer name)))
    (make-pipe-process :name name :buffer buf :noquery t)
    (push (cons buf sid) export-test--sessions)
    buf))

(defun export-test--read (name)
  (let ((f (expand-file-name name decknix-agent-session-export-dir)))
    (when (file-exists-p f)
      (with-temp-buffer
        (insert-file-contents f)
        (json-parse-string (buffer-string) :object-type 'plist
                           :null-object nil :false-object :false)))))

(defun export-test--notify (buf update)
  (decknix-agent-session-export-observe-notification
   :state (list (cons :buffer buf))
   :acp-notification `((method . "session/update")
                       (params . ((update . ,update))))))

;; -- pure ------------------------------------------------------------

(ert-deftest decknix-agent-session-export/state-mapping ()
  (let ((decknix-agent-session-export-background-seconds 120))
    (should (equal "idle" (decknix-agent-session-export-state "ready" nil nil nil)))
    (should (equal "idle" (decknix-agent-session-export-state "finished" nil nil 999)))
    (should (equal "working" (decknix-agent-session-export-state "working" t nil 10)))
    (should (equal "working" (decknix-agent-session-export-state "working" t '(x) 999)))
    (should (equal "background" (decknix-agent-session-export-state "working" t nil 121)))
    (should (equal "working" (decknix-agent-session-export-state "working" t nil nil)))
    (should (equal "waiting-permission" (decknix-agent-session-export-state "waiting" t nil 999)))
    (should (equal "asking" (decknix-agent-session-export-state "asking" nil nil nil)))
    (should (equal "netfail" (decknix-agent-session-export-state "netfail" nil nil nil)))
    (should (equal "dead" (decknix-agent-session-export-state "killed" nil nil nil)))
    (should (equal "starting" (decknix-agent-session-export-state "initializing" nil nil nil)))))

(ert-deftest decknix-agent-session-export/tool-tracking ()
  (let* ((tools (decknix-agent-session-export--tool-update
                 nil '((sessionUpdate . "tool_call") (toolCallId . "a")
                       (title . "Run tests") (status . "pending"))
                 10))
         (tools (decknix-agent-session-export--tool-update
                 tools '((sessionUpdate . "tool_call") (toolCallId . "b")
                         (title . "Read file"))
                 20)))
    (should (equal '(("b" "Read file" . 20) ("a" "Run tests" . 10)) tools))
    (setq tools (decknix-agent-session-export--tool-update
                 tools '((sessionUpdate . "tool_call_update") (toolCallId . "b")
                         (status . "completed"))
                 30))
    (should (equal '(("a" "Run tests" . 10)) tools))
    (should (equal tools (decknix-agent-session-export--tool-update
                          tools '((sessionUpdate . "tool_call_update")
                                  (toolCallId . "zz") (status . "in_progress"))
                          40)))))

;; -- snapshot and files ------------------------------------------------

(ert-deftest decknix-agent-session-export/idle-session-snapshot ()
  (export-test-with-env
    (let ((buf (export-test--session "lane" export-test--sid)))
      (decknix-agent-session-export-sweep 1000.0)
      (let ((s (export-test--read (concat export-test--sid ".json"))))
        (should (equal "idle" (plist-get s :state)))
        (should (equal "lane" (plist-get s :buffer)))
        (should (eq :false (plist-get s :busy)))
        (should (equal (emacs-pid) (plist-get s :emacs_pid)))
        (should-not (plist-get s :tool)))
      (should (= #o700 (logand #o777 (file-modes decknix-agent-session-export-dir))))
      (should (= #o600 (logand #o777 (file-modes (expand-file-name
                                                  (concat export-test--sid ".json")
                                                  decknix-agent-session-export-dir)))))
      (ignore buf))))

(ert-deftest decknix-agent-session-export/plan-is-exported ()
  "What the session is doing and will do next, from its last ACP plan."
  (export-test-with-env
    (let ((decknix-agent-session-export-plan-function
           (lambda (_buf) '(:total 4 :completed 1 :current "run tests" :next nil))))
      (export-test--session "lane" export-test--sid)
      (decknix-agent-session-export-sweep 1000.0)
      (let ((plan (plist-get (export-test--read (concat export-test--sid ".json")) :plan)))
        (should (equal "run tests" (plist-get plan :current)))
        (should-not (plist-get plan :next))
        (should (= 1 (plist-get plan :done)))
        (should (= 4 (plist-get plan :total)))))))

(ert-deftest decknix-agent-session-export/no-plan-is-null ()
  (export-test-with-env
    (let ((decknix-agent-session-export-plan-function #'ignore))
      (export-test--session "lane" export-test--sid)
      (decknix-agent-session-export-sweep 1000.0)
      (should-not (plist-get (export-test--read (concat export-test--sid ".json")) :plan)))))

(ert-deftest decknix-agent-session-export/tags-are-exported ()
  "The file carries the tags the sidebar shows, so the CLI resolves a lane
by the same tags even before its session id joins a store entry."
  (export-test-with-env
    (let* ((seen nil)
           (decknix-agent-session-export-tags-function
            (lambda (buf sid)
              (push (cons (buffer-name buf) sid) seen)
              '("lane-04" "PLAT-1342"))))
      (export-test--session "lane" export-test--sid)
      (decknix-agent-session-export-sweep 1000.0)
      (should (equal ["lane-04" "PLAT-1342"]
                     (plist-get (export-test--read (concat export-test--sid ".json"))
                                :tags)))
      (should (equal (list (cons "lane" export-test--sid)) seen)))))

(ert-deftest decknix-agent-session-export/no-tags-is-an-empty-array ()
  (export-test-with-env
    (let ((decknix-agent-session-export-tags-function (lambda (_buf _sid) nil)))
      (export-test--session "lane" export-test--sid)
      (decknix-agent-session-export-sweep 1000.0)
      (should (equal [] (plist-get (export-test--read (concat export-test--sid ".json"))
                                   :tags))))))

(ert-deftest decknix-agent-session-export/a-failing-tag-lookup-still-exports ()
  (export-test-with-env
    (let ((decknix-agent-session-export-tags-function
           (lambda (_buf _sid) (error "store unreadable"))))
      (export-test--session "lane" export-test--sid)
      (decknix-agent-session-export-sweep 1000.0)
      (let ((s (export-test--read (concat export-test--sid ".json"))))
        (should (equal "idle" (plist-get s :state)))
        (should (equal [] (plist-get s :tags)))))))

(ert-deftest decknix-agent-session-export/working-then-background ()
  (export-test-with-env
    (let ((buf (export-test--session "lane" export-test--sid)))
      (push (cons buf "working") export-test--status)
      (with-current-buffer buf
        (setq-local shell-maker--busy t)
        (setq decknix-agent-session-export--last-activity 1000.0))
      (export-test--notify buf '((sessionUpdate . "tool_call") (toolCallId . "t1")
                                 (title . "gradle test")))
      (with-current-buffer buf (setq decknix-agent-session-export--last-activity 1000.0))
      (decknix-agent-session-export-sweep 1500.0)
      (let ((s (export-test--read (concat export-test--sid ".json"))))
        (should (equal "working" (plist-get s :state)))
        (should (equal "gradle test" (plist-get (plist-get s :tool) :name)))
        (should (= 1500 (plist-get s :busy_since))))
      (export-test--notify buf '((sessionUpdate . "tool_call_update") (toolCallId . "t1")
                                 (status . "completed")))
      (with-current-buffer buf (setq decknix-agent-session-export--last-activity 1500.0))
      (decknix-agent-session-export-sweep 1700.0)
      (let ((s (export-test--read (concat export-test--sid ".json"))))
        (should (equal "background" (plist-get s :state)))
        (should (= 1700 (plist-get s :state_since)))
        (should (= 1500 (plist-get s :last_activity)))
        (should (= 0 (plist-get s :tools_in_flight)))))))

(ert-deftest decknix-agent-session-export/unchanged-state-is-not-rewritten ()
  (export-test-with-env
    (export-test--session "lane" export-test--sid)
    (decknix-agent-session-export-sweep 1000.0)
    (setq export-test--writes nil)
    (decknix-agent-session-export-sweep 1005.0)
    (should-not (member (concat export-test--sid ".json") export-test--writes))
    (should-not (member "_emacs.json" export-test--writes))
    (decknix-agent-session-export-sweep 1031.0)
    (should (equal '("_emacs.json") export-test--writes))))

(ert-deftest decknix-agent-session-export/heartbeat-reports-the-receiver ()
  (export-test-with-env
    (let ((decknix-agent-dispatch-mode nil))
      (decknix-agent-session-export-sweep 1000.0)
      (let ((h (export-test--read "_emacs.json")))
        (should (= 1000 (plist-get h :at)))
        (should (= (emacs-pid) (plist-get h :pid)))
        (should (eq :false (plist-get h :receiver)))))))

(ert-deftest decknix-agent-session-export/heartbeat-reports-arming-and-control ()
  (export-test-with-env
    (let ((decknix-agent-dispatch-mode t)
          (decknix-agent-dispatch-control-mode t)
          (decknix-agent-dispatch-remote-control nil))
      (cl-letf (((symbol-function 'decknix-agent-dispatch-state)
                 (lambda () (list :on t :armed_at 990 :armed_by "control:abc")))
                ((symbol-function 'decknix-agent-dispatch-lane-usage)
                 (lambda () (list :lanes_live 3 :spawn_max_live 12))))
        (decknix-agent-session-export-sweep 1000.0))
      (let ((h (export-test--read "_emacs.json")))
        (should (= 3 (plist-get h :lanes_live)))
        (should (= 12 (plist-get h :spawn_max_live)))
        (should (eq t (plist-get h :receiver)))
        (should (eq t (plist-get h :control)))
        (should (eq :false (plist-get h :remote_control)))
        (should (= 990 (plist-get h :armed_at)))
        (should (equal "control:abc" (plist-get h :armed_by))))))
  (export-test-with-env
    (let ((decknix-agent-dispatch-mode nil)
          (decknix-agent-dispatch-control-mode nil))
      (decknix-agent-session-export-sweep 1000.0)
      (let ((h (export-test--read "_emacs.json")))
        (should (eq :false (plist-get h :control)))
        (should (plist-member h :armed_at))
        (should-not (plist-get h :armed_at))
        (should-not (plist-get h :armed_by))
        (should (plist-member h :lanes_live))))))

(ert-deftest decknix-agent-session-export/heartbeat-now-writes-at-once ()
  (export-test-with-env
    (let ((decknix-agent-session-export-mode t)
          (decknix-agent-dispatch-mode nil))
      (decknix-agent-session-export-sweep 1000.0)
      (setq export-test--writes nil
            decknix-agent-dispatch-mode t)
      (decknix-agent-session-export-heartbeat-now)
      (should (equal '("_emacs.json") export-test--writes))
      (should (eq t (plist-get (export-test--read "_emacs.json") :receiver))))
    (let ((decknix-agent-session-export-mode nil))
      (setq export-test--writes nil)
      (decknix-agent-session-export-heartbeat-now)
      (should-not export-test--writes))))

(ert-deftest decknix-agent-session-export/killed-buffer-is-written-dead-once ()
  (export-test-with-env
    (let ((buf (export-test--session "lane" export-test--sid)))
      (decknix-agent-session-export-sweep 1000.0)
      (delete-process (get-buffer-process buf))
      (kill-buffer buf)
      (setq export-test--sessions nil)
      (decknix-agent-session-export-sweep 1010.0)
      (should (equal "dead" (plist-get (export-test--read (concat export-test--sid ".json"))
                                       :state)))
      (setq export-test--writes nil)
      (decknix-agent-session-export-sweep 1015.0)
      (should-not export-test--writes))))

(ert-deftest decknix-agent-session-export/background-p-needs-a-quiet-open-turn ()
  (with-temp-buffer
    (let ((decknix-agent-session-export-background-seconds 120))
      (setq-local shell-maker--busy t)
      (setq decknix-agent-session-export--last-activity (- (float-time) 300))
      (should (decknix-agent-session-export-background-p (current-buffer)))
      (setq decknix-agent-session-export--tools '(("t" "x" . 0)))
      (should-not (decknix-agent-session-export-background-p (current-buffer)))
      (setq decknix-agent-session-export--tools nil
            decknix-agent-session-export--last-activity (float-time))
      (should-not (decknix-agent-session-export-background-p (current-buffer)))
      (setq-local shell-maker--busy nil
                  decknix-agent-session-export--last-activity (- (float-time) 300))
      (should-not (decknix-agent-session-export-background-p (current-buffer))))))

(ert-deftest decknix-agent-session-export/next-delay-paces-itself ()
  (let ((decknix-agent-session-export-interval 5))
    (should (= 5 (decknix-agent-session-export--next-delay 0.01)))
    (should (= 20 (decknix-agent-session-export--next-delay 1.0)))))

(provide 'decknix-agent-session-export-test)
;;; decknix-agent-session-export-test.el ends here
