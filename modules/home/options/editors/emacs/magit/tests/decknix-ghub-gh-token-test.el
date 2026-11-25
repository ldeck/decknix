;;; decknix-ghub-gh-token-test.el --- Tests for decknix-ghub-gh-token -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-ghub-gh-token)

(defconst decknix-ghub-gh-token-test--fake-gh
  (list "sh" "-c"
        (concat "echo 'diagnostic noise' >&2; "
                "if [ \"$1 $2 $3 $5\" = \"auth token --hostname --user\" ] "
                "&& [ \"$6\" = ldeck ]; then printf 'tok-%s-%s\\n' \"$4\" \"$6\"; "
                "else exit 1; fi")
        "gh")
  "Stand-in for gh: answers `auth token' only for user ldeck.")

(defmacro decknix-ghub-gh-token-test--with-fake-gh (&rest body)
  (declare (indent 0))
  `(let ((decknix-ghub-gh-token-command decknix-ghub-gh-token-test--fake-gh)
         (decknix-ghub-gh-token--cache (make-hash-table :test #'equal)))
     ,@body))

(ert-deftest decknix-ghub-gh-token-test-hostname ()
  (should (equal "github.com" (decknix-ghub-gh-token--hostname "api.github.com")))
  (should (equal "github.com" (decknix-ghub-gh-token--hostname "github.com")))
  (should (equal "ghe.example.com"
                 (decknix-ghub-gh-token--hostname "ghe.example.com/api/v3")))
  (should-not (decknix-ghub-gh-token--hostname nil)))

(ert-deftest decknix-ghub-gh-token-test-fetch-success ()
  (decknix-ghub-gh-token-test--with-fake-gh
    (should (equal "tok-github.com-ldeck"
                   (decknix-ghub-gh-token-fetch "github.com" "ldeck")))))

(ert-deftest decknix-ghub-gh-token-test-fetch-failure-is-nil ()
  (decknix-ghub-gh-token-test--with-fake-gh
    (should-not (decknix-ghub-gh-token-fetch "github.com" "someone-else"))))

(ert-deftest decknix-ghub-gh-token-test-fetch-empty-output-is-nil ()
  (let ((decknix-ghub-gh-token-command '("sh" "-c" "exit 0" "gh")))
    (should-not (decknix-ghub-gh-token-fetch "github.com" "ldeck"))))

(ert-deftest decknix-ghub-gh-token-test-fetch-missing-program-is-nil ()
  (let ((decknix-ghub-gh-token-command '("decknix-no-such-gh-binary")))
    (should-not (decknix-ghub-gh-token-fetch "github.com" "ldeck"))))

(ert-deftest decknix-ghub-gh-token-test-get-caches-success-only ()
  (decknix-ghub-gh-token-test--with-fake-gh
    (let ((calls 0)
          (real (symbol-function 'decknix-ghub-gh-token-fetch)))
      (cl-letf (((symbol-function 'decknix-ghub-gh-token-fetch)
                 (lambda (h u) (cl-incf calls) (funcall real h u))))
        (should (equal "tok-github.com-ldeck"
                       (decknix-ghub-gh-token-get "api.github.com" "ldeck")))
        (should (equal "tok-github.com-ldeck"
                       (decknix-ghub-gh-token-get "api.github.com" "ldeck")))
        (should (= 1 calls))
        (should-not (decknix-ghub-gh-token-get "api.github.com" "nobody"))
        (should-not (decknix-ghub-gh-token-get "api.github.com" "nobody"))
        (should (= 3 calls))
        (decknix-ghub-gh-token-clear-cache)
        (decknix-ghub-gh-token-get "api.github.com" "ldeck")
        (should (= 4 calls))))))

(defun decknix-ghub-gh-token-test--orig (auth-source-token)
  "Fake `ghub--token' whose auth-source lookup yields AUTH-SOURCE-TOKEN."
  (lambda (_host username _package &optional nocreate _forge)
    (or auth-source-token
        (unless nocreate
          (error "Required token for %s does not exist" username)))))

(ert-deftest decknix-ghub-gh-token-test-advice-prefers-auth-source ()
  (decknix-ghub-gh-token-test--with-fake-gh
    (cl-letf (((symbol-function 'decknix-ghub-gh-token-get)
               (lambda (&rest _) (error "gh must not be consulted"))))
      (should (equal "from-auth-source"
                     (decknix-ghub-gh-token--around
                      (decknix-ghub-gh-token-test--orig "from-auth-source")
                      "api.github.com" "ldeck" 'forge))))))

(ert-deftest decknix-ghub-gh-token-test-advice-falls-back-to-gh ()
  (decknix-ghub-gh-token-test--with-fake-gh
    (should (equal "tok-github.com-ldeck"
                   (decknix-ghub-gh-token--around
                    (decknix-ghub-gh-token-test--orig nil)
                    "api.github.com" "ldeck" 'forge nil nil)))
    (should (equal "tok-github.com-ldeck"
                   (decknix-ghub-gh-token--around
                    (decknix-ghub-gh-token-test--orig nil)
                    "api.github.com" "ldeck" 'forge nil 'github)))))

(ert-deftest decknix-ghub-gh-token-test-advice-keeps-original-error ()
  (decknix-ghub-gh-token-test--with-fake-gh
    (should-error (decknix-ghub-gh-token--around
                   (decknix-ghub-gh-token-test--orig nil)
                   "api.github.com" "nobody" 'forge))
    (should-not (decknix-ghub-gh-token--around
                 (decknix-ghub-gh-token-test--orig nil)
                 "api.github.com" "nobody" 'forge t))))

(ert-deftest decknix-ghub-gh-token-test-advice-skips-other-forges ()
  (decknix-ghub-gh-token-test--with-fake-gh
    (cl-letf (((symbol-function 'decknix-ghub-gh-token-get)
               (lambda (&rest _) (error "gh must not be consulted"))))
      (should-error (decknix-ghub-gh-token--around
                     (decknix-ghub-gh-token-test--orig nil)
                     "gitlab.com/api/v4" "ldeck" 'forge nil 'gitlab)))))

(ert-deftest decknix-ghub-gh-token-test-install-is-idempotent ()
  (let ((sym (make-symbol "fake-ghub--token")))
    (fset sym (decknix-ghub-gh-token-test--orig nil))
    (decknix-ghub-gh-token-install sym)
    (decknix-ghub-gh-token-install sym)
    (let ((n 0))
      (advice-mapc (lambda (&rest _) (cl-incf n)) sym)
      (should (= 1 n)))
    (decknix-ghub-gh-token-uninstall sym)
    (should-not (advice-member-p #'decknix-ghub-gh-token--around sym))))

(provide 'decknix-ghub-gh-token-test)
;;; decknix-ghub-gh-token-test.el ends here
