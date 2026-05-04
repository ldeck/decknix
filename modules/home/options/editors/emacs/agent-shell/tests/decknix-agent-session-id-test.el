;;; decknix-agent-session-id-test.el --- Tests for session-id + conv-key accessors -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-id "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--agent-current-session-id',
;; `decknix--agent-require-session-id', and
;; `decknix--agent-require-conv-key'.  Mode detection is exercised
;; via `derived-mode-p' over a temp buffer in `fundamental-mode'
;; (negative path) plus a synthetic mode that derives from
;; `agent-shell-mode' through a stubbed `derived-mode-p' for the
;; positive path -- the upstream `agent-shell-mode' is not
;; available at test time.  The conv-key resolver is stubbed
;; via `cl-letf'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-session-id)

;; -- current-session-id -----------------------------------------

(ert-deftest decknix-agent-session-id--current-nil-when-not-in-agent-mode ()
  "Returns nil for buffers that are not derived from agent-shell-mode."
  (with-temp-buffer
    ;; fundamental-mode does not derive from agent-shell-mode.
    (setq decknix--agent-auggie-session-id "abc-123")
    (should (null (decknix--agent-current-session-id)))))

(ert-deftest decknix-agent-session-id--current-returns-buffer-local ()
  "Returns the buffer-local var when `derived-mode-p' reports a match."
  (with-temp-buffer
    (cl-letf (((symbol-function 'derived-mode-p)
               (lambda (&rest modes)
                 (memq 'agent-shell-mode modes))))
      (setq decknix--agent-auggie-session-id "abc-123-def")
      (should (equal "abc-123-def" (decknix--agent-current-session-id))))))

;; -- require-session-id -----------------------------------------

(ert-deftest decknix-agent-session-id--require-returns-when-set ()
  "Returns the id when `current-session-id' resolves."
  (with-temp-buffer
    (cl-letf (((symbol-function 'derived-mode-p)
               (lambda (&rest modes) (memq 'agent-shell-mode modes))))
      (setq decknix--agent-auggie-session-id "id-1")
      (should (equal "id-1" (decknix--agent-require-session-id))))))

(ert-deftest decknix-agent-session-id--require-errors-when-nil ()
  "Signals `user-error' when no session id is available."
  (with-temp-buffer
    (should-error (decknix--agent-require-session-id) :type 'user-error)))

;; -- require-conv-key -------------------------------------------

(ert-deftest decknix-agent-session-id--conv-key-returns-resolved ()
  "Returns the resolver result when both lookups succeed."
  (with-temp-buffer
    (cl-letf (((symbol-function 'derived-mode-p)
               (lambda (&rest modes) (memq 'agent-shell-mode modes)))
              ((symbol-function 'decknix--agent-conversation-key-for-session)
               (lambda (sid) (concat "ck:" sid))))
      (setq decknix--agent-auggie-session-id "abc12345-6789")
      (should (equal "ck:abc12345-6789"
                     (decknix--agent-require-conv-key))))))

(ert-deftest decknix-agent-session-id--conv-key-errors-when-resolver-misses ()
  "Signals `user-error' when the resolver returns nil."
  (with-temp-buffer
    (cl-letf (((symbol-function 'derived-mode-p)
               (lambda (&rest modes) (memq 'agent-shell-mode modes)))
              ((symbol-function 'decknix--agent-conversation-key-for-session)
               (lambda (_sid) nil)))
      ;; Need >=8 chars for the substring 0..8 hint.
      (setq decknix--agent-auggie-session-id "abcdefgh-extra")
      (should-error (decknix--agent-require-conv-key) :type 'user-error))))

(ert-deftest decknix-agent-session-id--conv-key-propagates-session-error ()
  "Propagates `user-error' from `require-session-id' (no resolver call)."
  (with-temp-buffer
    (cl-letf (((symbol-function 'decknix--agent-conversation-key-for-session)
               (lambda (_sid)
                 (error "Resolver should not be called when session id is nil"))))
      (should-error (decknix--agent-require-conv-key) :type 'user-error))))

(provide 'decknix-agent-session-id-test)
;;; decknix-agent-session-id-test.el ends here
