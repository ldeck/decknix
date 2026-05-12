;;; decknix-agent-compose-internals-test.el --- Tests for compose-internals -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-compose-internals' (PR
;; B.69).  Pins behaviour of the target resolver, the display-buffer
;; spec, and the completion-at-point bounds detection without
;; touching live agent-shell processes.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-compose-internals)

(defvar decknix--compose-target-buffer nil)

(ert-deftest decknix-compose-display-action--shape ()
  "Display action is a side-window spec at the bottom slot 0."
  (let ((spec (decknix--compose-display-action)))
    ;; First entry is the action functions list `(display-buffer-in-side-window)';
    ;; subsequent entries are alist parameters.
    (should (equal (car spec) '(display-buffer-in-side-window)))
    (should (eq (cdr (assq 'side spec)) 'bottom))
    (should (= (cdr (assq 'slot spec)) 0))
    (should (= (cdr (assq 'window-height spec)) 10))))

(ert-deftest decknix-compose-find-target--current-buffer-when-agent-shell ()
  "Returns current buffer when in an agent-shell-derived mode."
  (with-temp-buffer
    ;; Stub `derived-mode-p' to claim agent-shell membership.
    (cl-letf (((symbol-function 'derived-mode-p)
               (lambda (&rest modes) (memq 'agent-shell-mode modes))))
      (let ((decknix--compose-target-buffer nil))
        (should (eq (decknix--compose-find-target) (current-buffer)))))))

(ert-deftest decknix-compose-find-target--target-buffer-when-set ()
  "Returns `decknix--compose-target-buffer' when not in agent-shell."
  (let ((target (generate-new-buffer " *target*")))
    (unwind-protect
        (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) nil)))
          (let ((decknix--compose-target-buffer target))
            (should (eq (decknix--compose-find-target) target))))
      (kill-buffer target))))

(ert-deftest decknix-compose-find-target--falls-back-to-most-recent ()
  "Falls back to (car (agent-shell-buffers)) when neither path matches."
  (let ((live (generate-new-buffer " *live*")))
    (unwind-protect
        (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) nil))
                  ((symbol-function 'agent-shell-buffers)
                   (lambda () (list live))))
          (let ((decknix--compose-target-buffer nil))
            (should (eq (decknix--compose-find-target) live))))
      (kill-buffer live))))

(ert-deftest decknix-compose-find-target--user-error-when-none ()
  "Signals `user-error' when no agent-shell buffer can be found."
  (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) nil))
            ((symbol-function 'agent-shell-buffers) (lambda () nil)))
    (let ((decknix--compose-target-buffer nil))
      (should-error (decknix--compose-find-target) :type 'user-error))))

(ert-deftest decknix-compose-command-completion--nil-when-no-target ()
  "Completion returns nil when target buffer is nil."
  (with-temp-buffer
    (let ((decknix--compose-target-buffer nil))
      (insert "/foo")
      (should-not (decknix--compose-command-completion-at-point)))))

(ert-deftest decknix-compose-command-completion--nil-when-no-slash ()
  "Completion returns nil when prefix is not preceded by `/'."
  (let ((target (generate-new-buffer " *target*")))
    (unwind-protect
        (with-current-buffer target
          (set (make-local-variable 'agent-shell--state)
               '((:available-commands . (((name . "review")
                                          (description . "Review PR")))))))
      (with-temp-buffer
        (let ((decknix--compose-target-buffer target))
          (insert "foo")
          (should-not (decknix--compose-command-completion-at-point))))
      (kill-buffer target))))

(ert-deftest decknix-compose-file-completion--nil-when-no-at ()
  "File completion returns nil when prefix is not preceded by `@'."
  (let ((target (generate-new-buffer " *target*")))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell--project-files)
                   (lambda () '("a.el" "b/c.el"))))
          (with-temp-buffer
            (let ((decknix--compose-target-buffer target))
              (insert "foo")
              (should-not (decknix--compose-file-completion-at-point)))))
      (kill-buffer target))))

(ert-deftest decknix-compose-trigger-completion--ignores-mid-line-slash ()
  "Trigger no-ops when `/' is mid-line (not after whitespace/BOL)."
  (with-temp-buffer
    ;; "abc/" -- slash is preceded by `c', not whitespace
    (insert "abc/")
    ;; Should not raise even though completion-at-point is unbound here.
    (cl-letf (((symbol-function 'completion-at-point)
               (lambda () (error "should not be called"))))
      (should-not (decknix--compose-trigger-completion)))))

(ert-deftest decknix-compose-setup-completion--installs-three-hooks ()
  "Hook installer adds the two CAPF entries plus the post-self-insert."
  (with-temp-buffer
    ;; `add-hook ... nil t' will make the hook variables buffer-local;
    ;; ensure they start empty so the `memq' checks below are precise.
    (setq-local completion-at-point-functions nil)
    (setq-local post-self-insert-hook nil)
    (decknix--compose-setup-completion)
    (should (memq #'decknix--compose-file-completion-at-point
                  completion-at-point-functions))
    (should (memq #'decknix--compose-command-completion-at-point
                  completion-at-point-functions))
    (should (memq #'decknix--compose-trigger-completion
                  post-self-insert-hook))))

(provide 'decknix-agent-compose-internals-test)

;;; decknix-agent-compose-internals-test.el ends here
