;;; decknix-agent-url-parse-test.el --- Tests for agent URL parsers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-url-parse "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of the URL parsing primitives
;; extracted from the agent-shell heredoc.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-url-parse)

;; -- pr-parse-url --------------------------------------------------

(ert-deftest decknix-agent-pr-parse-url--nil ()
  (should (null (decknix--agent-pr-parse-url nil))))

(ert-deftest decknix-agent-pr-parse-url--basic ()
  "Recognises github.com/OWNER/REPO/pull/N and returns (owner repo n)."
  (should (equal (decknix--agent-pr-parse-url
                  "https://github.com/owner/repo/pull/42")
                 '("owner" "repo" 42))))

(ert-deftest decknix-agent-pr-parse-url--with-trailing-path ()
  "Trailing /files /commits etc. don't disturb the parse."
  (should (equal (decknix--agent-pr-parse-url
                  "https://github.com/owner/repo/pull/123/files")
                 '("owner" "repo" 123))))

(ert-deftest decknix-agent-pr-parse-url--with-fragment ()
  "URL fragment after PR number is ignored."
  (should (equal (decknix--agent-pr-parse-url
                  "https://github.com/owner/repo/pull/7#issuecomment-1")
                 '("owner" "repo" 7))))

(ert-deftest decknix-agent-pr-parse-url--repo-with-hyphens ()
  (should (equal (decknix--agent-pr-parse-url
                  "https://github.com/my-org/my-repo/pull/9")
                 '("my-org" "my-repo" 9))))

(ert-deftest decknix-agent-pr-parse-url--no-match ()
  "Issues, commits, and non-PR URLs return nil."
  (should (null (decknix--agent-pr-parse-url
                 "https://github.com/owner/repo/issues/1")))
  (should (null (decknix--agent-pr-parse-url
                 "https://github.com/owner/repo")))
  (should (null (decknix--agent-pr-parse-url
                 "not a url"))))

;; -- repo-parse-url ------------------------------------------------

(ert-deftest decknix-agent-repo-parse-url--nil ()
  (should (null (decknix--agent-repo-parse-url nil))))

(ert-deftest decknix-agent-repo-parse-url--non-string ()
  (should (null (decknix--agent-repo-parse-url 42))))

(ert-deftest decknix-agent-repo-parse-url--basic ()
  (should (equal (decknix--agent-repo-parse-url
                  "https://github.com/owner/repo")
                 '("owner" "repo"))))

(ert-deftest decknix-agent-repo-parse-url--strips-dot-git ()
  (should (equal (decknix--agent-repo-parse-url
                  "https://github.com/owner/repo.git")
                 '("owner" "repo"))))

(ert-deftest decknix-agent-repo-parse-url--strips-query ()
  "Query string is stripped (regex stops at ?)."
  (should (equal (decknix--agent-repo-parse-url
                  "https://github.com/owner/repo?tab=readme")
                 '("owner" "repo"))))

(ert-deftest decknix-agent-repo-parse-url--strips-fragment ()
  "Fragment is stripped (regex stops at #)."
  (should (equal (decknix--agent-repo-parse-url
                  "https://github.com/owner/repo#readme")
                 '("owner" "repo"))))

(ert-deftest decknix-agent-repo-parse-url--rejects-pr-url ()
  "PR URLs route through `decknix--agent-pr-parse-url' instead."
  (should (null (decknix--agent-repo-parse-url
                 "https://github.com/owner/repo/pull/42"))))

(ert-deftest decknix-agent-repo-parse-url--accepts-issue-url ()
  "Issue URLs match the OWNER/REPO prefix and produce (owner repo)."
  (should (equal (decknix--agent-repo-parse-url
                  "https://github.com/owner/repo/issues/1")
                 '("owner" "repo"))))

(ert-deftest decknix-agent-repo-parse-url--no-match ()
  (should (null (decknix--agent-repo-parse-url
                 "https://gitlab.com/owner/repo")))
  (should (null (decknix--agent-repo-parse-url ""))))

;; -- pr-url-accessor -----------------------------------------------

(ert-deftest decknix-agent-pr-url-accessor--alist-symbol-key ()
  "Alists use interned symbol keys (per JSON parse with `json-key-type 'symbol')."
  (let ((pr '((url . "https://github.com/o/r/pull/1")
              (type . "authored"))))
    (should (equal (decknix--agent-pr-url-accessor pr "url")
                   "https://github.com/o/r/pull/1"))
    (should (equal (decknix--agent-pr-url-accessor pr "type") "authored"))))

(ert-deftest decknix-agent-pr-url-accessor--alist-missing ()
  (should (null (decknix--agent-pr-url-accessor
                 '((other . "x")) "missing"))))

(ert-deftest decknix-agent-pr-url-accessor--hash-string-key ()
  "Hash-tables use string keys (per JSON parse with `json-object-type 'hash-table')."
  (let ((h (make-hash-table :test 'equal)))
    (puthash "url" "https://github.com/o/r/pull/2" h)
    (puthash "type" "subject" h)
    (should (equal (decknix--agent-pr-url-accessor h "url")
                   "https://github.com/o/r/pull/2"))
    (should (equal (decknix--agent-pr-url-accessor h "type") "subject"))))

(ert-deftest decknix-agent-pr-url-accessor--hash-missing ()
  (let ((h (make-hash-table :test 'equal)))
    (should (null (decknix--agent-pr-url-accessor h "missing")))))

;; -- hub-repo-cache-key --------------------------------------------

(ert-deftest decknix-agent-hub-repo-cache-key--basic ()
  (should (equal (decknix--hub-repo-cache-key
                  "https://github.com/owner/repo" "main")
                 "owner/repo#main")))

(ert-deftest decknix-agent-hub-repo-cache-key--strips-dot-git ()
  (should (equal (decknix--hub-repo-cache-key
                  "https://github.com/owner/repo.git" "feature/x")
                 "owner/repo#feature/x")))

(ert-deftest decknix-agent-hub-repo-cache-key--nil-url ()
  (should (null (decknix--hub-repo-cache-key nil "main"))))

(ert-deftest decknix-agent-hub-repo-cache-key--nil-branch ()
  "Nil branch yields nil even with a valid URL."
  (should (null (decknix--hub-repo-cache-key
                 "https://github.com/owner/repo" nil))))

(ert-deftest decknix-agent-hub-repo-cache-key--rejects-pr-url ()
  "PR URLs are rejected by repo-parse-url, so cache-key returns nil."
  (should (null (decknix--hub-repo-cache-key
                 "https://github.com/owner/repo/pull/1" "main"))))

(provide 'decknix-agent-url-parse-test)
;;; decknix-agent-url-parse-test.el ends here
