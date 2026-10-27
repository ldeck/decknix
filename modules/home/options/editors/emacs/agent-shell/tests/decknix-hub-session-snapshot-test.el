;;; decknix-hub-session-snapshot-test.el --- Session snapshot lifetime -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1") (decknix-agent-shell-hub "0.1"))

;;; Commentary:
;;
;; The session snapshot had a 0.5 s TTL meant to cover one render pass,
;; but a sampled paint ran over two seconds, so it was rebuilt several
;; times inside a single paint, each rebuild asking every session for its
;; tags, PRs and status again.  Within a paint it now lives for the
;; paint; outside one the TTL still applies.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-shell-hub)

(defvar decknix--sidebar-paint-in-progress nil)
(defvar decknix--sidebar-paint-generation 0)

(defmacro decknix-snapshot-test--isolated (&rest body)
  "Run BODY with an empty snapshot and builds counted in `builds'."
  (declare (indent 0))
  `(let ((decknix--hub-review-session-snapshot nil)
         (decknix--hub-review-session-snapshot-at 0)
         (decknix--hub-review-session-snapshot-generation nil)
         (decknix--sidebar-paint-in-progress nil)
         (decknix--sidebar-paint-generation 0)
         (builds 0))
     (cl-letf (((symbol-function 'agent-shell-buffers)
                (lambda () (setq builds (1+ builds)) nil)))
       ,@body)))

(ert-deftest decknix-snapshot--outside-a-paint-the-ttl-applies ()
  (decknix-snapshot-test--isolated
    (decknix--hub-review-session-snapshot)
    (decknix--hub-review-session-snapshot)
    (should (= 1 builds))
    (setq decknix--hub-review-session-snapshot-at
          (- (float-time) 1.0))
    (decknix--hub-review-session-snapshot)
    (should (= 2 builds))))

(ert-deftest decknix-snapshot--within-a-paint-it-outlives-the-ttl ()
  "A paint longer than the TTL must not rebuild the snapshot part way."
  (decknix-snapshot-test--isolated
    (let ((decknix--sidebar-paint-in-progress t)
          (decknix--sidebar-paint-generation 3))
      (decknix--hub-review-session-snapshot)
      (setq decknix--hub-review-session-snapshot-at (- (float-time) 5.0))
      (decknix--hub-review-session-snapshot)
      (should (= 1 builds)))))

(ert-deftest decknix-snapshot--the-next-paint-builds-afresh ()
  (decknix-snapshot-test--isolated
    (let ((decknix--sidebar-paint-in-progress t)
          (decknix--sidebar-paint-generation 3))
      (decknix--hub-review-session-snapshot)
      (setq decknix--hub-review-session-snapshot-at (- (float-time) 5.0))
      (setq decknix--sidebar-paint-generation 4)
      (decknix--hub-review-session-snapshot)
      (should (= 2 builds)))))

(ert-deftest decknix-snapshot--one-built-outside-a-paint-is-not-pinned-by-it ()
  "Only a snapshot built during THIS paint is reused past the TTL."
  (decknix-snapshot-test--isolated
    (decknix--hub-review-session-snapshot)
    (setq decknix--hub-review-session-snapshot-at (- (float-time) 5.0))
    (let ((decknix--sidebar-paint-in-progress t)
          (decknix--sidebar-paint-generation 1))
      (decknix--hub-review-session-snapshot)
      (should (= 2 builds)))))

(ert-deftest decknix-snapshot--linked-authored-prs-are-session-keys ()
  (let ((buffer (generate-new-buffer " *linked-pr-snapshot*"))
        (decknix--hub-review-session-snapshot nil)
        (decknix--hub-review-session-snapshot-at 0))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local decknix--agent-conv-key "current"))
          (cl-letf (((symbol-function 'agent-shell-buffers) (lambda () (list buffer)))
                    ((symbol-function 'decknix--agent-tags-for-buffer) (lambda (_) nil))
                    ((symbol-function 'decknix--agent-review-prs-for-conv-key)
                     (lambda (_) nil))
                    ((symbol-function 'decknix-agent-buffer-status) (lambda (_) "ready"))
                    ((symbol-function 'decknix--agent-linked-prs)
                     (lambda (_)
                       '(((url . "https://github.com/ExampleOwner/widget/pull/21697")
                          (type . "authored"))
                         ((url . "https://github.com/ExampleOwner/widget/pull/21640")
                          (type . "repo")))))
                    ((symbol-function 'decknix--agent-pr-url-accessor)
                     (lambda (item field) (alist-get (intern field) item)))
                    ((symbol-function 'decknix--agent-pr-parse-url)
                     (lambda (_) '("ExampleOwner" "widget" 21697)))
                    ((symbol-function 'decknix-attention-observe) (lambda (&rest _) nil)))
            (should (equal '("exampleowner/widget#21697")
                           (nth 6 (car (decknix--hub-review-session-snapshot)))))))
      (kill-buffer buffer))))

(provide 'decknix-hub-session-snapshot-test)
;;; decknix-hub-session-snapshot-test.el ends here
