;;; decknix-agent-review-capture-test.el --- Tests for review capture -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-review-capture'
;; (PR B.73).  Stubs the session-id resolver and history extractor
;; so the delegator semantics are pinned without any live buffer
;; or filesystem state.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-review-capture)

(ert-deftest decknix-agent-review-capture--nil-sid-returns-nil ()
  "When the source buffer has no session id, capture returns nil."
  (cl-letf (((symbol-function 'decknix--agent-buffer-session-id)
             (lambda () nil))
            ((symbol-function 'decknix--agent-session-extract-history)
             (lambda (&rest _) (error "should not be called"))))
    (with-temp-buffer
      (should-not
       (decknix--agent-review-capture-exchange (current-buffer) 1)))))

(ert-deftest decknix-agent-review-capture--delegates-to-extractor ()
  "When sid is present, capture forwards (sid, n) to the extractor."
  (let ((seen nil))
    (cl-letf (((symbol-function 'decknix--agent-buffer-session-id)
               (lambda () "sid-abc"))
              ((symbol-function 'decknix--agent-session-extract-history)
               (lambda (sid n)
                 (setq seen (list sid n))
                 '(("u" . "a")))))
      (with-temp-buffer
        (let ((result (decknix--agent-review-capture-exchange
                       (current-buffer) 7)))
          (should (equal seen '("sid-abc" 7)))
          (should (equal result '(("u" . "a")))))))))

(ert-deftest decknix-agent-review-capture--runs-in-source-buffer ()
  "The extractor runs with current-buffer set to SOURCE-BUFFER."
  (let ((source (generate-new-buffer " *src*"))
        (saw-buffer nil))
    (with-current-buffer source (setq-local some-marker 'src-buf))
    (cl-letf (((symbol-function 'decknix--agent-buffer-session-id)
               (lambda ()
                 (setq saw-buffer (buffer-local-value
                                   'some-marker (current-buffer)))
                 "sid-x"))
              ((symbol-function 'decknix--agent-session-extract-history)
               (lambda (&rest _) nil)))
      (decknix--agent-review-capture-exchange source 1)
      (kill-buffer source)
      (should (eq saw-buffer 'src-buf)))))

(provide 'decknix-agent-review-capture-test)

;;; decknix-agent-review-capture-test.el ends here
