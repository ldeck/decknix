;;; decknix-agent-dispatch-control-test.el --- Tests for the dispatch control watcher -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-dispatch-control "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; The arm seam is replaced by a recorder and the receiver's real start is
;; turned into an error, so no test arms the real receiver or reaches a
;; session.  Files go to a temporary 0700 state dir.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'decknix-agent-dispatch-control)

(defconst control-test--rid "99999999-8888-4777-8666-555555555555")
(defconst control-test--rid-2 "77777777-8888-4777-8666-555555555555")
(defconst control-test--coord "cccccccc-dddd-4eee-8fff-000000000000")

(defvar control-test--clock 1000)
(defvar control-test--arms nil "Calls the arm stub received: (ON SOURCE RELEASE).")

(defmacro control-test-with-env (&rest body)
  (declare (indent 0))
  `(let* ((root (make-temp-file "control-test" t))
          (decknix-agent-dispatch-dir (expand-file-name "state" root))
          (control-test--arms nil)
          (control-test--clock 1000)
          (decknix-agent-dispatch-mode nil)
          (decknix-agent-dispatch-remote-control t)
          (decknix-agent-dispatch-control--started-at 900)
          (decknix-agent-dispatch-control--seen nil)
          (decknix-agent-dispatch-control-arm-function
           (lambda (on source release)
             (push (list on source release) control-test--arms)
             (setq decknix-agent-dispatch-mode on))))
     (unwind-protect
         (cl-letf (((symbol-function 'decknix-agent-dispatch--now)
                    (lambda () control-test--clock))
                   ((symbol-function 'decknix-agent-dispatch--start)
                    (lambda () (error "REAL receiver start called"))))
           (decknix-agent-dispatch--ensure-dirs)
           ,@body)
       (delete-directory root t))))

(defun control-test--sub (name)
  (expand-file-name name decknix-agent-dispatch-dir))

(defun control-test--drop (&rest args)
  "Write a control request; ARGS override fields (:mode sets the file mode)."
  (let* ((req (list :v 3 :id control-test--rid :kind "dispatch" :op "on"
                    :created_at control-test--clock
                    :expires_at (+ control-test--clock 60)))
         (mode (or (plist-get args :file-mode) #o600)))
    (cl-loop for (k v) on args by #'cddr
             unless (eq k :file-mode)
             do (setq req (plist-put req k v)))
    (let ((path (expand-file-name (concat (plist-get req :id) ".json")
                                  (control-test--sub "control"))))
      (with-file-modes #o600
        (with-temp-file path (insert (json-serialize req))))
      (set-file-modes path mode)
      path)))

(defun control-test--receipt (&optional id)
  (let ((path (expand-file-name (concat (or id control-test--rid) ".json")
                                (control-test--sub "receipts"))))
    (when (file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (json-parse-string (buffer-string) :object-type 'plist)))))

(defun control-test--left ()
  (directory-files (control-test--sub "control") nil "\\`[^.]"))

(ert-deftest decknix-agent-dispatch-control/install-starts-nothing ()
  (should-not decknix-agent-dispatch-control-mode)
  (should-not decknix-agent-dispatch-control--timer)
  (should-not (cl-some (lambda (tm)
                         (let ((f (timer--function tm)))
                           (and (symbolp f)
                                (string-prefix-p "decknix-agent-dispatch-control"
                                                 (symbol-name f)))))
                       timer-list)))

(ert-deftest decknix-agent-dispatch-control/on-arms-the-receiver-as-control ()
  (control-test-with-env
    (control-test--drop :from control-test--coord :release_queued t)
    (decknix-agent-dispatch-control--tick)
    (should (equal `((t ,(concat "control:" control-test--coord) t)) control-test--arms))
    (let ((r (control-test--receipt)))
      (should (equal "accepted" (plist-get r :state)))
      (should (equal "dispatch" (plist-get r :kind)))
      (should (equal "on" (plist-get r :outcome))))
    (should-not (control-test--left))))

(ert-deftest decknix-agent-dispatch-control/off-disarms-and-is-a-no-op-when-off ()
  (control-test-with-env
    (setq decknix-agent-dispatch-mode t)
    (control-test--drop :op "off")
    (decknix-agent-dispatch-control--tick)
    (should (equal '((nil nil nil)) control-test--arms))
    (should (equal "off" (plist-get (control-test--receipt) :outcome)))
    (control-test--drop :op "off" :id control-test--rid-2)
    (decknix-agent-dispatch-control--tick)
    (should (= 1 (length control-test--arms)))
    (should (equal "already-off" (plist-get (control-test--receipt control-test--rid-2)
                                            :outcome)))))

(ert-deftest decknix-agent-dispatch-control/on-when-on-changes-nothing ()
  (control-test-with-env
    (setq decknix-agent-dispatch-mode t)
    (control-test--drop)
    (decknix-agent-dispatch-control--tick)
    (should-not control-test--arms)
    (should (equal "already-on" (plist-get (control-test--receipt) :outcome)))))

(ert-deftest decknix-agent-dispatch-control/remote-control-off-refuses-on-but-honours-off ()
  (control-test-with-env
    (setq decknix-agent-dispatch-remote-control nil)
    (control-test--drop)
    (decknix-agent-dispatch-control--tick)
    (should-not control-test--arms)
    (should (equal "rejected" (plist-get (control-test--receipt) :state)))
    (should (equal "remote-control-disabled" (plist-get (control-test--receipt) :reason)))
    (setq decknix-agent-dispatch-mode t)
    (control-test--drop :op "off" :id control-test--rid-2)
    (decknix-agent-dispatch-control--tick)
    (should (equal '((nil nil nil)) control-test--arms))))

(ert-deftest decknix-agent-dispatch-control/refusals ()
  (cl-flet ((refused (&rest args)
              (control-test-with-env
                (apply #'control-test--drop args)
                (decknix-agent-dispatch-control--tick)
                (should-not control-test--arms)
                (should-not (control-test--left))
                (let ((r (control-test--receipt)))
                  (cons (plist-get r :state) (plist-get r :reason))))))
    (should (equal '("rejected" . "unsafe-file") (refused :file-mode #o644)))
    (should (equal '("expired" . "expired-before-claim")
                   (refused :created_at 900 :expires_at 950)))
    (should (equal '("rejected" . "ttl-too-long") (refused :expires_at 5000)))
    (should (equal '("rejected" . "predates-control")
                   (refused :created_at 850 :expires_at 1100)))
    (should (equal '("rejected" . "bad-op") (refused :op "toggle")))
    (should (equal '("rejected" . "bad-kind") (refused :kind "spawn")))
    (should (equal '("rejected" . "bad-from") (refused :from "nope")))
    (should (equal '("rejected" . "bad-version") (refused :v 2)))))

(ert-deftest decknix-agent-dispatch-control/a-failed-arm-is-rejected ()
  (control-test-with-env
    (setq decknix-agent-dispatch-control-arm-function
          (lambda (&rest _) (user-error "Dispatch state dir is loose")))
    (control-test--drop)
    (decknix-agent-dispatch-control--tick)
    (should (equal "rejected" (plist-get (control-test--receipt) :state)))
    (should (string-prefix-p "arm-failed" (plist-get (control-test--receipt) :reason)))))

(ert-deftest decknix-agent-dispatch-control/mode-toggle-starts-and-stops-only-the-watcher ()
  (let* ((root (make-temp-file "control-mode" t))
         (decknix-agent-dispatch-dir (expand-file-name "state" root)))
    (unwind-protect
        (progn
          (decknix-agent-dispatch-control-mode 1)
          (should decknix-agent-dispatch-control--timer)
          (should decknix-agent-dispatch-control--started-at)
          (should (file-directory-p (expand-file-name "control" decknix-agent-dispatch-dir)))
          (should-not decknix-agent-dispatch-mode)
          (decknix-agent-dispatch-control-mode -1)
          (should-not decknix-agent-dispatch-control--timer)
          (should-not decknix-agent-dispatch-control--watch))
      (decknix-agent-dispatch-control-mode -1)
      (delete-directory root t))))

(provide 'decknix-agent-dispatch-control-test)
;;; decknix-agent-dispatch-control-test.el ends here
