;;; decknix-agent-review-submit-test.el --- Tests for submit/route helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-review-submit "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests pinning the contract of the carved
;; submit/route helpers (PR B.62).  Side-effecting helpers
;; (`-submit-jira', `-submit-file', `-submit-pr') exercise their
;; full body via a mktemp dir / fresh kill-ring; `-content-for-
;; route' is exercised as a pure transform; `-submit-to-agent' is
;; exercised through stubbed shell-maker / agent-shell entry
;; points so the user-facing busy-prompt branches are pinned
;; without spinning up a real agent process.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-review-submit)

;; Re-declare with a value so the test's `let'-bind is dynamic --
;; the carved module's `(defvar X)' is only a compiler hint, which
;; would otherwise let-bind lexically and never be visible to the
;; byte-compiled `decknix--agent-review-submit-to-agent'.
(defvar decknix--agent-review-source-buffer nil)

;; -- content-for-route --------------------------------------------

(ert-deftest decknix-review-submit-content-for-route--agent-strips-meta ()
  "The agent route deletes the leading `🧭 review meta' blockquote."
  (with-temp-buffer
    ;; `decknix--agent-review-strip-meta' matches `> 🧭 **review
    ;; meta**' blockquote lines (see decknix-agent-review-format.el)
    ;; -- not heading-style markers -- so use the real preamble shape.
    (insert "> 🧭 **review meta**\n"
            "> - session: foo\n"
            "> - workspace: /tmp\n"
            ">\n"
            "> 📋 **instructions for the agent**\n"
            "> do the thing\n")
    (let ((out (decknix--agent-review-content-for-route 'agent)))
      (should (stringp out))
      (should-not (string-match-p "review meta" out))
      (should (string-match-p "instructions for the agent" out))
      (should (string-match-p "do the thing" out)))))

(ert-deftest decknix-review-submit-content-for-route--non-agent-keeps-meta ()
  "Non-agent routes return the buffer verbatim (meta + body)."
  (with-temp-buffer
    (insert "> 🧭 **review meta**\nfoo\n## annotations\nbar\n")
    (dolist (route '(pr jira file))
      (let ((out (decknix--agent-review-content-for-route route)))
        (should (string= (buffer-string) out))))))

(ert-deftest decknix-review-submit-content-for-route--empty-buffer ()
  "An empty review buffer returns the empty string for every route."
  (with-temp-buffer
    (dolist (route '(agent pr jira file))
      (should (string= "" (decknix--agent-review-content-for-route route))))))

;; -- submit-pr -----------------------------------------------------

(ert-deftest decknix-review-submit-pr--copies-content-to-kill-ring ()
  "Submit-pr puts CONTENT at the head of the kill-ring."
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil)
        (content "hello pr review"))
    (decknix--agent-review-submit-pr content)
    (should (string= content (current-kill 0 t)))))

;; -- submit-jira ---------------------------------------------------

(ert-deftest decknix-review-submit-jira--writes-file-under-drafts-dir ()
  "Submit-jira writes a `review-*.md' under the drafts dir."
  (let* ((dir (make-temp-file "decknix-review-jira-" t))
         (decknix-agent-review-jira-drafts-dir dir))
    (unwind-protect
        (let ((content "# review\nlooks good"))
          (decknix--agent-review-submit-jira content)
          (let ((files (directory-files dir nil "\\`review-.*\\.md\\'")))
            (should (= 1 (length files)))
            (let ((written (with-temp-buffer
                             (insert-file-contents
                              (expand-file-name (car files) dir))
                             (buffer-string))))
              (should (string= content written)))))
      (delete-directory dir t))))

(ert-deftest decknix-review-submit-jira--creates-missing-parent-dir ()
  "Submit-jira creates `decknix-agent-review-jira-drafts-dir' on demand."
  (let* ((root (make-temp-file "decknix-review-jira-mkdir-" t))
         (nested (expand-file-name "deep/nest" root))
         (decknix-agent-review-jira-drafts-dir nested))
    (unwind-protect
        (progn
          (should-not (file-directory-p nested))
          (decknix--agent-review-submit-jira "x")
          (should (file-directory-p nested)))
      (delete-directory root t))))

;; -- submit-file ---------------------------------------------------

(ert-deftest decknix-review-submit-file--writes-to-chosen-path ()
  "Submit-file writes CONTENT to the path returned by `read-file-name'."
  (let* ((dir (make-temp-file "decknix-review-file-" t))
         (target (expand-file-name "out.md" dir)))
    (unwind-protect
        (cl-letf (((symbol-function 'read-file-name)
                   (lambda (&rest _) target)))
          (decknix--agent-review-submit-file "saved body")
          (should (file-exists-p target))
          (with-temp-buffer
            (insert-file-contents target)
            (should (string= "saved body" (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest decknix-review-submit-file--empty-path-is-noop ()
  "An empty `read-file-name' result writes nothing."
  (let* ((dir (make-temp-file "decknix-review-file-empty-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'read-file-name)
                   (lambda (&rest _) "")))
          (decknix--agent-review-submit-file "should not appear")
          (should (null (directory-files dir nil "\\`[^.]"))))
      (delete-directory dir t))))

;; -- submit-to-agent ----------------------------------------------
;;
;; Full path needs a live shell-maker process; we stub the leaves
;; (shell-maker-submit, agent-shell-interrupt, pop-to-buffer,
;; process-live-p) so the dispatch logic can be pinned without
;; spinning up an agent.

(defmacro decknix-test-with-stubbed-agent-target (&rest body)
  "Run BODY with a fake target buffer + stubbed shell-maker entry points.
Captures the last `shell-maker-submit' :input value into
`decknix-test--last-submit-input' and the last queued content
into `decknix-test--last-queue-input' for assertions."
  (declare (indent 0))
  `(let* ((target (generate-new-buffer " *decknix-test-target*"))
          (decknix--agent-review-source-buffer target)
          (decknix-test--last-submit-input nil)
          (decknix-test--last-queue-input nil)
          (shell-maker--busy nil))
     (unwind-protect
         (cl-letf (((symbol-function 'get-buffer-process)
                    (lambda (_) 'fake-process))
                   ((symbol-function 'process-live-p)
                    (lambda (_) t))
                   ((symbol-function 'shell-maker-submit)
                    (lambda (&rest args)
                      (setq decknix-test--last-submit-input
                            (plist-get args :input))))
                   ((symbol-function 'pop-to-buffer)
                    (lambda (&rest _) nil))
                   ((symbol-function 'decknix--compose-enqueue-prompt)
                    (lambda (_target content)
                      (setq decknix-test--last-queue-input content))))
           ,@body)
       (when (buffer-live-p target)
         (kill-buffer target)))))

(ert-deftest decknix-review-submit-to-agent--idle-submits-content ()
  "Submitting to an idle agent calls `shell-maker-submit' with :input."
  (decknix-test-with-stubbed-agent-target
    (decknix--agent-review-submit-to-agent "the prompt")
    (should (string= "the prompt" decknix-test--last-submit-input))
    (should (null decknix-test--last-queue-input))))

(ert-deftest decknix-review-submit-to-agent--dead-buffer-errors ()
  "A non-live source buffer signals a `user-error'."
  (let* ((target (generate-new-buffer " *decknix-test-target*"))
         (decknix--agent-review-source-buffer target))
    (kill-buffer target)
    (should-error (decknix--agent-review-submit-to-agent "x")
                  :type 'user-error)))

(ert-deftest decknix-review-submit-to-agent--busy-cancel-errors ()
  "Cancelling the busy prompt signals `user-error' (no submit)."
  (decknix-test-with-stubbed-agent-target
    (with-current-buffer decknix--agent-review-source-buffer
      (setq-local shell-maker--busy t))
    (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) ?c)))
      (should-error (decknix--agent-review-submit-to-agent "x")
                    :type 'user-error))
    (should (null decknix-test--last-submit-input))
    (should (null decknix-test--last-queue-input))))

(ert-deftest decknix-review-submit-to-agent--busy-queue-defers ()
  "Choosing [q]ueue when busy routes to `decknix--compose-enqueue-prompt'."
  (decknix-test-with-stubbed-agent-target
    (with-current-buffer decknix--agent-review-source-buffer
      (setq-local shell-maker--busy t))
    (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) ?q)))
      (decknix--agent-review-submit-to-agent "queued body"))
    (should (string= "queued body" decknix-test--last-queue-input))
    (should (null decknix-test--last-submit-input))))

(provide 'decknix-agent-review-submit-test)
;;; decknix-agent-review-submit-test.el ends here
