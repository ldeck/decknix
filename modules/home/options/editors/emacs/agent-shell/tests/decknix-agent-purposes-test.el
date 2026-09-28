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

;; --- a pinned, versioned model must survive validation ----------------
;;
;; The team policy (decknix-config `claudePinnedModel') is to pin a
;; SPECIFIC Claude version and never a floating alias, because an alias
;; drifts onto a new flagship and strands resume.  But the known-model
;; list held only the aliases, so validation dropped exactly the values
;; the policy mandates and accepted only the ones it forbids:
;;
;;     [decknix-agent-purpose] pr-review model "claude-opus-4-8" is not
;;     known for provider claude-code; dropping to nil
;;
;; The warning understates it.  Dropping to nil means review sessions ran
;; on the provider default, so the pin was inert while looking configured
;; -- the failure the pin exists to prevent, reached by another route.

(ert-deftest decknix-agent-purpose-known-model--accepts-a-versioned-claude-id ()
  "A versioned `claude-*' id is a model, not a typo."
  (should (decknix-agent-purpose--known-model-p 'claude-code "claude-opus-4-8"))
  (should (decknix-agent-purpose--known-model-p 'claude-code "claude-opus-5"))
  (should (decknix-agent-purpose--known-model-p 'claude-code "claude-sonnet-5"))
  (should (decknix-agent-purpose--known-model-p
           'claude-code "claude-haiku-4-5-20251001")))

(ert-deftest decknix-agent-purpose-known-model--still-accepts-the-aliases ()
  "The short aliases remain valid; the pattern is additive."
  (should (decknix-agent-purpose--known-model-p 'claude-code "opus"))
  (should (decknix-agent-purpose--known-model-p 'claude-code "sonnet"))
  (should (decknix-agent-purpose--known-model-p 'claude-code "haiku")))

(ert-deftest decknix-agent-purpose-known-model--still-rejects-a-typo ()
  "Validation must keep catching what it was written for."
  (should-not (decknix-agent-purpose--known-model-p 'claude-code "opus-4-8"))
  (should-not (decknix-agent-purpose--known-model-p 'claude-code "claud-opus-5"))
  (should-not (decknix-agent-purpose--known-model-p 'claude-code "gpt-5")))

(ert-deftest decknix-agent-purpose-known-model--pattern-is-per-provider ()
  "A Claude id is not automatically valid for another provider."
  (should-not (decknix-agent-purpose--known-model-p 'auggie "claude-opus-5")))

(ert-deftest decknix-agent-purpose-validate-keeps-a-pinned-claude-version ()
  "The pinned version reaches the session instead of being dropped."
  (decknix-purpose-test--with-registry
   (let ((decknix-agent-purpose-alist
          '((pr-review . (:provider claude-code
                                    :model "claude-opus-4-8" :mode "auto"))))
         (decknix-agent-known-modes '((claude-code . ("auto")))))
     (decknix-agent-purpose-validate)
     (should (equal "claude-opus-4-8"
                    (plist-get (decknix-agent-purpose-resolve 'pr-review)
                               :model))))))

;; -- Opus 5.5 must pass model validation -------------------------------
;;
;; The review purposes default to `opus[1m]', the id the Claude adapter labels
;; "Opus 5.5". It matches neither the old enumerated list ("sonnet" "opus"
;; "haiku") nor the `claude-<family>-<n>' pattern, so validation would have
;; dropped it to nil with a warning and the purpose would have silently run on
;; the adapter default instead.

(ert-deftest decknix-purpose-model--opus-5-5-alias-is-known ()
  "`opus[1m]' passes, since the review purposes now default to it."
  (should (decknix-agent-purpose--known-model-p 'claude-code "opus[1m]")))

(ert-deftest decknix-purpose-model--versioned-opus-5-still-passes-by-pattern ()
  "`claude-opus-5' is accepted by the pattern without an enum entry."
  (should (decknix-agent-purpose--known-model-p 'claude-code "claude-opus-5")))

(ert-deftest decknix-purpose-model--default-alias-is-known ()
  "`default' is a real adapter option and must not be rejected."
  (should (decknix-agent-purpose--known-model-p 'claude-code "default")))

(ert-deftest decknix-purpose-model--a-typo-is-still-rejected ()
  "Widening the list must not make validation useless."
  (should-not (decknix-agent-purpose--known-model-p 'claude-code "opus[1M]"))
  (should-not (decknix-agent-purpose--known-model-p 'claude-code "opus-1m"))
  (should-not (decknix-agent-purpose--known-model-p 'claude-code "bogus")))


(provide 'decknix-agent-purposes-test)
;;; decknix-agent-purposes-test.el ends here
