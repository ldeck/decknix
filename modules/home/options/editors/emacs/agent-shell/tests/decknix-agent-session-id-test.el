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
;; `decknix--agent-require-conv-key' prefers `decknix--agent-current-conv-key'
;; (buffer-lookup).  Load it for real: an `fboundp' guard means an absent
;; module degrades SILENTLY to the old derive-from-message path, so a
;; stub would hide exactly the regression these tests exist to catch.
(require 'decknix-agent-buffer-lookup nil t)

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
              ;; No buffer-local key and no store scan: this test is about
              ;; the DERIVE fallback, and `current-conv-key' would otherwise
              ;; read the real ~/.config/decknix store.
              ((symbol-function 'decknix--agent-current-conv-key) (lambda () nil))
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
              ((symbol-function 'decknix--agent-current-conv-key) (lambda () nil))
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

;; -- require-conv-key must agree with the buffer it is called in ------
;;
;; Reported: `C-c s t l' listed a pi session's seven tags, but `C-c s t r'
;; answered "This conversation has no tags".  Measured on the live buffer:
;;
;;     buffer-local conv-key = e06099eb69ea3456   <- where the tags live
;;     current-conv-key      = e06099eb69ea3456
;;     require-conv-key      = b081f2b691929f3f   <- what tag-remove used
;;
;; `require-conv-key' recomputed the key by hashing the session's first
;; message instead of trusting the key the buffer was actually filed
;; under, so show and remove disagreed about which conversation you were
;; in.  `decknix--agent-current-conv-key' already prefers the buffer-local
;; key -- and its docstring describes this exact hazard -- so the fix is
;; to route through it.
;;
;; The silent-corruption case is worse than the visible one: had the
;; recomputed key existed in the store, `tag-add' would have written tags
;; to the WRONG conversation, and `tag-remove' does `remhash' when the
;; last tag goes.

(ert-deftest decknix-session-id/require-conv-key-prefers-the-buffers-own-key ()
  "The buffer's own conv-key wins over one recomputed from the message."
  (with-temp-buffer
    (setq-local major-mode 'agent-shell-mode)
    (setq-local decknix--agent-conv-key "e06099")
    (setq-local decknix--agent-auggie-session-id "sid-1")
    (cl-letf (((symbol-function 'derived-mode-p) (lambda (m) (eq m 'agent-shell-mode)))
              ((symbol-function 'decknix--agent-require-session-id)
               (lambda () "sid-1"))
              ;; the stale path: hashing the first message
              ((symbol-function 'decknix--agent-conversation-key-for-session)
               (lambda (&rest _) "b081f2b6")))
      (should (equal (decknix--agent-require-conv-key) "e06099")))))

(ert-deftest decknix-session-id/require-conv-key-falls-back-when-unbound ()
  "With no buffer-local key, the session-id derivation is still used.
A session that has not yet flushed its first message has no local key,
and must still resolve."
  (with-temp-buffer
    (setq-local major-mode 'agent-shell-mode)
    (setq-local decknix--agent-conv-key nil)
    (setq-local decknix--agent-auggie-session-id "sid-1")
    (cl-letf (((symbol-function 'derived-mode-p) (lambda (m) (eq m 'agent-shell-mode)))
              ((symbol-function 'decknix--agent-require-session-id)
               (lambda () "sid-1"))
              ;; nil local key AND no scan hit, so the derive path is reached.
              ((symbol-function 'decknix--agent-current-conv-key) (lambda () nil))
              ((symbol-function 'decknix--agent-conversation-key-for-session)
               (lambda (&rest _) "derived-key")))
      (should (equal (decknix--agent-require-conv-key) "derived-key")))))

(provide 'decknix-agent-session-id-test)
;;; decknix-agent-session-id-test.el ends here
