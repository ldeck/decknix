;;; decknix-agent-session-resume-background-test.el --- Background session resume -*- lexical-binding: t -*-

;;; Commentary:
;;
;; `decknix session spawn' resumes a lane's saved session from a timer, so
;; the resume must take no window: no `set-window-buffer' on the live
;; dedupe path, and `agent-shell--start :no-focus t' instead of
;; `agent-shell-start' (which hardcodes `:no-focus nil') on the new path.
;; Every collaborator of the resume is stubbed; the real starters error.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-picker-selections)
(require 'decknix-agent-shell-main-session)

(defvar agent-shell-display-action nil)

(defmacro resume-bg-test-with-stubs (started &rest body)
  "Run BODY with resume collaborators stubbed; STARTED collects start calls."
  (declare (indent 1))
  `(cl-letf* (((symbol-function 'decknix--agent-find-live-buffer-for-conv-key) #'ignore)
              ((symbol-function 'decknix--agent-find-live-buffer-for-session-id) #'ignore)
              ((symbol-function 'decknix--agent-session-model-for-conv-key) #'ignore)
              ((symbol-function 'decknix--agent-store-field-for-session-id) #'ignore)
              ((symbol-function 'decknix--agent-provider-for-session-id) (lambda (_) 'claude))
              ((symbol-function 'decknix--agent-broker-key-for-resume) #'ignore)
              ((symbol-function 'decknix--agent-broker-resume-from-live-p) #'ignore)
              ((symbol-function 'decknix--agent-broker-wrap-command) (lambda (cmd _) cmd))
              ((symbol-function 'decknix--agent-command-build) (lambda (&rest _) '("claude")))
              ((symbol-function 'decknix--agent-session-mode-for-conv-key) #'ignore)
              ((symbol-function 'decknix-agent-purpose-resolve) #'ignore)
              ((symbol-function 'decknix--agent-existing-additional-roots) #'ignore)
              ((symbol-function 'decknix--agent-additional-roots-for-conv-key) #'ignore)
              ((symbol-function 'decknix--agent-make-config) (lambda (&rest _) 'config))
              ((symbol-function 'decknix-agent-provider-resume-cli-flag) #'ignore)
              ((symbol-function 'decknix--agent-session-extract-all-turns) #'ignore)
              ((symbol-function 'decknix--agent-model-replay-needed-p) #'ignore)
              ((symbol-function 'decknix--agent-resume-primer-needed-p) #'ignore)
              ((symbol-function 'decknix--agent-resume-register-real-sid-on-ready) #'ignore)
              ((symbol-function 'decknix--agent-register-session-id) #'ignore)
              ((symbol-function 'decknix--agent-conv-touch) #'ignore)
              ((symbol-function 'run-at-time) #'ignore)
              ((symbol-function 'set-window-buffer)
               (lambda (&rest _) (error "set-window-buffer called")))
              ((symbol-function 'agent-shell-start)
               (lambda (&rest _) (error "agent-shell-start called")))
              ((symbol-function 'agent-shell--start)
               (lambda (&rest args)
                 (push args ,started)
                 (get-buffer-create " *resume-bg-test*"))))
     (unwind-protect (progn ,@body)
       (when (get-buffer " *resume-bg-test*")
         (kill-buffer " *resume-bg-test*")))))

(ert-deftest decknix-agent-session-resume/background-starts-without-focus ()
  (let ((started nil))
    (resume-bg-test-with-stubs started
      (let ((buf (decknix--agent-session-resume
                  "11111111-2222-4333-8444-555555555555" 0 "lane-07" nil "ck" nil t)))
        (should (bufferp buf))
        (should (= 1 (length started)))
        (should (eq t (plist-get (car started) :no-focus)))
        (should (eq t (plist-get (car started) :new-session)))
        (should (eq 'config (plist-get (car started) :config)))))))

(ert-deftest decknix-agent-session-resume/background-dedupe-takes-no-window ()
  (let ((started nil)
        (live (get-buffer-create " *resume-bg-live*")))
    (unwind-protect
        (resume-bg-test-with-stubs started
          (cl-letf (((symbol-function 'decknix--agent-find-live-buffer-for-conv-key)
                     (lambda (_) live)))
            (should (eq live (decknix--agent-session-resume
                              "11111111-2222-4333-8444-555555555555" 0 nil nil "ck" nil t)))
            (should-not started)))
      (kill-buffer live))))

(ert-deftest decknix-agent-session-resume/foreground-is-unchanged ()
  (let ((started nil))
    (resume-bg-test-with-stubs started
      (should-error (decknix--agent-session-resume
                     "11111111-2222-4333-8444-555555555555" 0 nil nil "ck")
                    :type 'error)
      (should-not started))))

(provide 'decknix-agent-session-resume-background-test)
;;; decknix-agent-session-resume-background-test.el ends here
