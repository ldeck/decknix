;;; decknix-agent-purposes-test.el --- Tests for the purpose resolver -*- lexical-binding: t -*-

;;; Commentary:
;; ERT contract for `decknix-agent-purposes':
;;   * `decknix-agent-purpose-resolve' returns the (:provider :model)
;;     plist stored under PURPOSE, or a default plist when the purpose
;;     is unknown.
;;   * `decknix-agent-purpose-validate' warns and coerces an unknown
;;     provider to `decknix-agent-default-provider', and warns and
;;     drops an unknown model to nil (per `decknix-agent-known-models').
;; Provider registration is faked via `cl-letf' so the tests do not
;; require the full provider bootstrap.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-purposes)

;; Test fixtures -- shadowed with `let' inside each test so state
;; never leaks across cases.  Value-carrying `defvar's mark these
;; special so byte-compiled reads bind dynamically against the
;; test's `let'.
(defvar decknix-agent-default-provider 'claude-code)
(defvar decknix-agent-purpose-alist
  '((pr-review     . (:provider auggie :model "prism-a"))
    (bot-pr-review . (:provider auggie :model "haiku4.5"))))

(defmacro decknix-purpose-test--with-registry (&rest body)
  "Fake `decknix-agent-get-provider' to accept the built-in provider ids."
  `(cl-letf (((symbol-function 'decknix-agent-get-provider)
              (lambda (id) (memq id '(auggie claude-code pi)))))
     ,@body))

(ert-deftest decknix-agent-purpose-resolve-pr-review ()
  "Resolver returns the stored :provider/:model plist for `pr-review'."
  (let ((decknix-agent-purpose-alist
         '((pr-review     . (:provider auggie :model "prism-a"))
           (bot-pr-review . (:provider auggie :model "haiku4.5")))))
    (should (equal (list :provider 'auggie :model "prism-a")
                   (decknix-agent-purpose-resolve 'pr-review)))))

(ert-deftest decknix-agent-purpose-resolve-bot-pr-review ()
  "Resolver returns the stored :provider/:model plist for `bot-pr-review'."
  (let ((decknix-agent-purpose-alist
         '((pr-review     . (:provider auggie :model "prism-a"))
           (bot-pr-review . (:provider claude-code :model "haiku")))))
    (should (equal (list :provider 'claude-code :model "haiku")
                   (decknix-agent-purpose-resolve 'bot-pr-review)))))

(ert-deftest decknix-agent-purpose-resolve-unknown-falls-back-to-default ()
  "Unknown purposes return the default provider and no model/mode pin."
  (let ((decknix-agent-purpose-alist nil)
        (decknix-agent-default-provider 'claude-code))
    (should (equal (list :provider 'claude-code :model nil :mode nil)
                   (decknix-agent-purpose-resolve 'nonsense)))))

(ert-deftest decknix-agent-purpose-validate-coerces-unknown-provider ()
  "Unregistered provider is coerced to `decknix-agent-default-provider'."
  (decknix-purpose-test--with-registry
   (let ((decknix-agent-purpose-alist
          '((pr-review     . (:provider nonsense :model nil))
            (bot-pr-review . (:provider auggie   :model nil))))
         (decknix-agent-default-provider 'claude-code))
     (decknix-agent-purpose-validate)
     (should (eq 'claude-code
                 (plist-get (decknix-agent-purpose-resolve 'pr-review)
                            :provider)))
     (should (eq 'auggie
                 (plist-get (decknix-agent-purpose-resolve 'bot-pr-review)
                            :provider))))))

(ert-deftest decknix-agent-purpose-validate-drops-unknown-model ()
  "Model not on the provider's known-list is dropped to nil."
  (decknix-purpose-test--with-registry
   (let ((decknix-agent-purpose-alist
          '((pr-review     . (:provider claude-code :model "prism-a"))
            (bot-pr-review . (:provider auggie      :model "haiku4.5"))))
         (decknix-agent-known-models
          '((auggie      . ("prism-a" "opus4.7" "haiku4.5"))
            (claude-code . ("sonnet" "opus" "haiku")))))
     (decknix-agent-purpose-validate)
     (should (null (plist-get (decknix-agent-purpose-resolve 'pr-review)
                              :model)))
     (should (equal "haiku4.5"
                    (plist-get (decknix-agent-purpose-resolve 'bot-pr-review)
                               :model))))))

(ert-deftest decknix-agent-purpose-validate-keeps-valid-pair ()
  "A valid provider/model pair is left untouched."
  (decknix-purpose-test--with-registry
   (let ((decknix-agent-purpose-alist
          '((pr-review     . (:provider auggie :model "prism-a"))
            (bot-pr-review . (:provider auggie :model "haiku4.5"))))
         (decknix-agent-known-models
          '((auggie . ("prism-a" "opus4.7" "haiku4.5")))))
     (decknix-agent-purpose-validate)
     (should (equal '((pr-review     . (:provider auggie :model "prism-a" :mode nil))
                      (bot-pr-review . (:provider auggie :model "haiku4.5" :mode nil)))
                    decknix-agent-purpose-alist)))))

(ert-deftest decknix-agent-purpose-validate-allows-nil-known-list ()
  "A provider with a nil known-list accepts any model without warning."
  (decknix-purpose-test--with-registry
   (let ((decknix-agent-purpose-alist
          '((pr-review . (:provider pi :model "some-future-pi-model"))))
         (decknix-agent-known-models '((pi . nil))))
     (decknix-agent-purpose-validate)
     (should (equal "some-future-pi-model"
                    (plist-get (decknix-agent-purpose-resolve 'pr-review)
                               :model))))))

;; -- Session/permission mode (:mode) -------------------------------

(ert-deftest decknix-agent-purpose-resolve-includes-mode ()
  "Resolver surfaces a stored :mode verbatim."
  (let ((decknix-agent-purpose-alist
         '((new-session . (:provider claude-code :model nil :mode "auto")))))
    (should (equal "auto"
                   (plist-get (decknix-agent-purpose-resolve 'new-session)
                              :mode)))))

(ert-deftest decknix-agent-purpose-validate-keeps-valid-claude-mode ()
  "A known Claude mode survives validation."
  (decknix-purpose-test--with-registry
   (let ((decknix-agent-purpose-alist
          '((pr-review . (:provider claude-code :model "sonnet" :mode "auto"))))
         (decknix-agent-known-models '((claude-code . ("sonnet" "opus" "haiku"))))
         (decknix-agent-known-modes '((claude-code . ("default" "auto" "acceptEdits")))))
     (decknix-agent-purpose-validate)
     (should (equal "auto"
                    (plist-get (decknix-agent-purpose-resolve 'pr-review) :mode))))))

(ert-deftest decknix-agent-purpose-validate-drops-unknown-mode ()
  "A mode not on the provider's known-mode list is dropped to nil."
  (decknix-purpose-test--with-registry
   (let ((decknix-agent-purpose-alist
          '((pr-review . (:provider claude-code :model "sonnet" :mode "turbo"))))
         (decknix-agent-known-models '((claude-code . ("sonnet"))))
         (decknix-agent-known-modes '((claude-code . ("default" "auto")))))
     (decknix-agent-purpose-validate)
     (should (null (plist-get (decknix-agent-purpose-resolve 'pr-review) :mode))))))

(ert-deftest decknix-agent-purpose-validate-drops-mode-for-modeless-provider ()
  "A provider with no known-mode entry (auggie) drops any mode to nil."
  (decknix-purpose-test--with-registry
   (let ((decknix-agent-purpose-alist
          '((pr-review . (:provider auggie :model "prism-a" :mode "auto"))))
         (decknix-agent-known-models '((auggie . ("prism-a"))))
         (decknix-agent-known-modes '((claude-code . ("auto")))))
     (decknix-agent-purpose-validate)
     (should (null (plist-get (decknix-agent-purpose-resolve 'pr-review) :mode))))))

(provide 'decknix-agent-purposes-test)
;;; decknix-agent-purposes-test.el ends here
