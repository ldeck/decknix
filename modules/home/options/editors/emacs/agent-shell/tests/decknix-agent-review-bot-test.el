;;; decknix-agent-review-bot-test.el --- Tests for bot-aware review -*- lexical-binding: t -*-

(require 'ert)
(require 'decknix-agent-shell-main-link)

;; Mock variables from hub
(defvar decknix--hub-reviews nil)
(defvar decknix--hub-wip nil)

(ert-deftest decknix-agent-review-bot--hub-pr-author-finds-in-reviews ()
  "Finds author in `decknix--hub-reviews'."
  (let ((decknix--hub-reviews '(((owner . "o") (repo . "r") (number . 1) (author . "bot1"))))
        (decknix--hub-wip nil))
    (should (equal "bot1" (decknix--agent-hub-pr-author "o" "r" 1)))))

(ert-deftest decknix-agent-review-bot--hub-pr-author-finds-in-wip ()
  "Finds author in `decknix--hub-wip'."
  (let ((decknix--hub-reviews nil)
        (decknix--hub-wip '(((owner . "o") (repo . "r") (number . 1) (author . "bot1")))))
    (should (equal "bot1" (decknix--agent-hub-pr-author "o" "r" 1)))))

(ert-deftest decknix-agent-review-bot--hub-pr-author-string-number ()
  "Handles string PR numbers in hub data."
  (let ((decknix--hub-reviews '(((owner . "o") (repo . "r") (number . "1") (author . "bot1")))))
    (should (equal "bot1" (decknix--agent-hub-pr-author "o" "r" 1)))))

(ert-deftest decknix-agent-review-bot--get-params-chooses-bot-vars ()
  "Chooses bot model and command when author matches bot-p."
  (cl-letf (((symbol-function 'decknix--agent-pr-author) (lambda (_) "dependabot[bot]"))
            ((symbol-function 'decknix--hub-bot-author-p) (lambda (_) t))
            (decknix-agent-review-bot-pr-model "bot-model")
            (decknix-agent-review-bot-pr-command "/bot-cmd"))
    (let ((params (decknix--agent-review-get-params "url")))
      (should (equal "bot-model" (car params)))
      (should (equal "/bot-cmd" (cadr params))))))

(ert-deftest decknix-agent-review-bot--get-params-falls-back-to-regular ()
  "Falls back to regular review vars for non-bot authors."
  (cl-letf (((symbol-function 'decknix--agent-pr-author) (lambda (_) "human"))
            ((symbol-function 'decknix--hub-bot-author-p) (lambda (_) nil))
            (decknix-agent-review-pr-model "reg-model"))
    (let ((params (decknix--agent-review-get-params "url")))
      (should (equal "reg-model" (car params)))
      (should (equal "/review-service-pr" (cadr params))))))

(provide 'decknix-agent-review-bot-test)
;;; decknix-agent-review-bot-test.el ends here
