;;; decknix-agent-session-restart-test.el --- Tests for session restart -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-restart "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the pure name-extraction helper backing
;; `decknix-agent-session-restart'.  The interactive command itself
;; drives windows / processes and is exercised manually; the parser is
;; the testable contract: given a session buffer name, recover the
;; user-facing name so the restarted buffer reclaims its label.

;;; Code:

(require 'ert)
(require 'decknix-agent-session-restart)

(ert-deftest decknix-agent-session-restart-name--auggie ()
  "`*Auggie: NAME*' yields NAME."
  (should (equal (decknix--agent-session-restart-name-from-buffer
                  "*Auggie: my-feature*")
                 "my-feature")))

(ert-deftest decknix-agent-session-restart-name--claude ()
  "Provider prefix other than Auggie is handled (`*Claude: ...*')."
  (should (equal (decknix--agent-session-restart-name-from-buffer
                  "*Claude: pr-decknix-42*")
                 "pr-decknix-42")))

(ert-deftest decknix-agent-session-restart-name--strips-uniquifier ()
  "An Emacs `<N>' uniquifier after the closing `*' is ignored."
  (should (equal (decknix--agent-session-restart-name-from-buffer
                  "*Pi: a*<2>")
                 "a")))

(ert-deftest decknix-agent-session-restart-name--keeps-inner-colon ()
  "A colon inside the name is preserved (match stops at the final `*')."
  (should (equal (decknix--agent-session-restart-name-from-buffer
                  "*Auggie: a: b*")
                 "a: b")))

(ert-deftest decknix-agent-session-restart-name--upstream-default-is-nil ()
  "The upstream `<Provider> Agent @ <ws>' default is not our form."
  (should (null (decknix--agent-session-restart-name-from-buffer
                 "Auggie Agent @ ~/tools/decknix"))))

(ert-deftest decknix-agent-session-restart-name--non-session-is-nil ()
  "Plain buffers without the `*<Provider>: <name>*' shape return nil."
  (should (null (decknix--agent-session-restart-name-from-buffer "*scratch*")))
  (should (null (decknix--agent-session-restart-name-from-buffer "foo.el"))))

(ert-deftest decknix-agent-session-restart-name--nil-input ()
  "Nil input safely returns nil."
  (should (null (decknix--agent-session-restart-name-from-buffer nil))))

(provide 'decknix-agent-session-restart-test)
;;; decknix-agent-session-restart-test.el ends here
