;;; decknix-agent-session-group-test.el --- Tests for session-group -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-session-group "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--agent-session-group-by-
;; conversation' and `decknix--agent-session-live-label' (carved from
;; `decknix-agent-shell-main' / main-bulk into
;; `decknix-agent-session-group').
;;
;; Both helpers depend on four sibling lookups (conversation-key,
;; conversation-hidden-p, conv-last-accessed, tags-for-session); tests
;; stub all four via `cl-letf' so the suite never reaches the real
;; tag-store JSON or the conv-recency cache.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'decknix-agent-session-group)

;; Tags are now resolved by BUFFER (conv-key unioned with session id).
(unless (fboundp 'decknix--agent-tags-resolve)
  (defun decknix--agent-tags-resolve (conv-key session-id)
    (let ((a (and conv-key (fboundp 'decknix--agent-tags-for-conv-key)
                  (decknix--agent-tags-for-conv-key conv-key)))
          (b (and session-id (fboundp 'decknix--agent-tags-for-session)
                  (decknix--agent-tags-for-session session-id))))
      (cond ((and a b) (delete-dups (append a b))) (a) (b)))))

(unless (fboundp 'decknix--agent-tags-for-buffer)
  (defun decknix--agent-tags-for-buffer (buffer)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (decknix--agent-tags-resolve
         (and (boundp 'decknix--agent-conv-key) decknix--agent-conv-key)
         (and (boundp 'decknix--agent-auggie-session-id)
              decknix--agent-auggie-session-id))))))


;; Stubs for forward-declared helpers.
(unless (fboundp 'decknix--agent-conversation-key)
  ;; Default: each first-message hashes to a unique key (use the first
  ;; word so test fixtures can drive grouping by message content).
  (defun decknix--agent-conversation-key (msg)
    (when msg (car (split-string (or msg "") "[ \n]" t)))))
;; Session-level resolver: first message, then the session-id store scan.
;; Mirrors the real `decknix--agent-session-conv-key' so the grouping
;; specs below still exercise message-based grouping, while the
;; fallback-specific test can stub the store side independently.
(unless (fboundp 'decknix--agent-conv-key-for-session-id)
  (defun decknix--agent-conv-key-for-session-id (_sid) nil))
(unless (fboundp 'decknix--agent-session-conv-key)
  (defun decknix--agent-session-conv-key (session)
    (when session
      (let ((fm (alist-get 'firstUserMessage session ""))
            (sid (alist-get 'sessionId session)))
        (or (and fm (decknix--agent-conversation-key fm))
            (and sid (decknix--agent-conv-key-for-session-id sid)))))))
(unless (fboundp 'decknix--agent-conversation-hidden-p)
  (defun decknix--agent-conversation-hidden-p (_key) nil))
(unless (fboundp 'decknix--agent-conv-last-accessed)
  (defun decknix--agent-conv-last-accessed (_key) nil))
(unless (fboundp 'decknix--agent-tags-for-session)
  (defun decknix--agent-tags-for-session (_id) nil))
;; live-label now prefixes a provider glyph resolved from the buffer's
;; provider id; the real helper lives in `decknix-agent-provider'.
(unless (fboundp 'decknix-agent-provider-glyph-for-buffer)
  (defun decknix-agent-provider-glyph-for-buffer (_buf) "A"))

;; Buffer-local defvars owned by main-bulk; given a default value here
;; (per AGENTS.md note on hub-data vars) so that `buffer-local-value'
;; doesn't void-variable on a buffer that hasn't `setq-local'd them.
(defvar decknix--agent-session-workspace nil)
(defvar decknix--agent-auggie-session-id nil)

(defun decknix-agent-session-group-test--session
    (sid first-msg modified)
  "Build a synthetic session alist for the aggregator."
  `((sessionId . ,sid)
    (modified . ,modified)
    (firstUserMessage . ,first-msg)))

;; -- group-by-conversation ---------------------------------------

(ert-deftest decknix-agent-session-group/groups-by-first-message ()
  "Sessions sharing a first-message word fall into the same triple."
  (let* ((s1 (decknix-agent-session-group-test--session
              "s1" "alpha hello"   "2026-05-08T01:00:00Z"))
         (s2 (decknix-agent-session-group-test--session
              "s2" "alpha redo"    "2026-05-08T02:00:00Z"))
         (s3 (decknix-agent-session-group-test--session
              "s3" "beta start"    "2026-05-08T03:00:00Z"))
         (groups (decknix--agent-session-group-by-conversation
                  (list s1 s2 s3))))
    (should (= (length groups) 2))
    (let ((alpha (cl-find "alpha" groups :key #'car :test #'string=))
          (beta (cl-find "beta" groups :key #'car :test #'string=)))
      (should alpha)
      (should beta)
      (should (= (length (caddr alpha)) 2))
      (should (= (length (caddr beta)) 1)))))

(ert-deftest decknix-agent-session-group/picks-latest-as-representative ()
  "The representative (cadr) is the session with the newest `modified'."
  (let* ((older (decknix-agent-session-group-test--session
                 "old" "alpha foo" "2026-05-08T01:00:00Z"))
         (newer (decknix-agent-session-group-test--session
                 "new" "alpha foo" "2026-05-08T05:00:00Z"))
         (groups (decknix--agent-session-group-by-conversation
                  (list older newer))))
    (should (= (length groups) 1))
    (should (string= "new" (alist-get 'sessionId (cadr (car groups)))))))

(ert-deftest decknix-agent-session-group/sorts-newest-conversation-first ()
  "Inter-group order: most-recent representative comes first."
  (let* ((a (decknix-agent-session-group-test--session
             "a" "alpha"  "2026-05-08T01:00:00Z"))
         (b (decknix-agent-session-group-test--session
             "b" "beta"   "2026-05-08T05:00:00Z"))
         (groups (decknix--agent-session-group-by-conversation
                  (list a b))))
    (should (string= "beta" (caar groups)))
    (should (string= "alpha" (caadr groups)))))

(ert-deftest decknix-agent-session-group/last-accessed-bumps-conversation ()
  "A `lastAccessed' newer than `modified' bumps the conversation up."
  (let* ((a (decknix-agent-session-group-test--session
             "a" "alpha"  "2026-05-08T05:00:00Z"))  ; newer modified
         (b (decknix-agent-session-group-test--session
             "b" "beta"   "2026-05-08T01:00:00Z"))) ; older modified
    (cl-letf (((symbol-function 'decknix--agent-conv-last-accessed)
               (lambda (key)
                 ;; beta was tagged/resumed more recently than alpha was modified
                 (when (string= key "beta") "2026-05-08T09:00:00Z"))))
      (let ((groups (decknix--agent-session-group-by-conversation
                     (list a b))))
        (should (string= "beta" (caar groups)))))))

(ert-deftest decknix-agent-session-group/excludes-hidden-by-default ()
  "Hidden conversations are dropped unless INCLUDE-HIDDEN."
  (let* ((s (decknix-agent-session-group-test--session
             "s" "alpha"  "2026-05-08T01:00:00Z")))
    (cl-letf (((symbol-function 'decknix--agent-conversation-hidden-p)
               (lambda (_) t)))
      (should-not (decknix--agent-session-group-by-conversation (list s)))
      (should (= 1 (length (decknix--agent-session-group-by-conversation
                            (list s) t)))))))

(ert-deftest decknix-agent-session-group/skips-empty-first-message-keys ()
  "A session that resolves to NO conversation at all is skipped silently.
Neither its message nor the store knows it, so there is no conversation
to group it under."
  (let ((s (decknix-agent-session-group-test--session
            "s" "" "2026-05-08T01:00:00Z")))
    (cl-letf (((symbol-function 'decknix--agent-conversation-key)
               (lambda (_) nil))
              ((symbol-function 'decknix--agent-conv-key-for-session-id)
               (lambda (_) nil)))
      (should-not (decknix--agent-session-group-by-conversation (list s))))))

(ert-deftest decknix-agent-session-group/groups-a-resumed-session-via-the-store ()
  "A resumed/forked session groups under its conversation, not dropped.

Its first message is the resume primer or fork preamble, which keys no
conversation -- and the `when conv-key' guard used to DROP it, so a whole
conversation could vanish from the collapsed `C-c s s' view even though
its sessions were listed and correctly tagged.  Observed with day6:
three sessions on disk, all tagged, no row in the picker.

The session-id is stable across resume and fork, so the store scan
recovers the conversation the hash cannot."
  (let ((s (decknix-agent-session-group-test--session
            "sid-day6" "This message is a resumed continuation"
            "2026-05-08T01:00:00Z")))
    (cl-letf (((symbol-function 'decknix--agent-conversation-key)
               (lambda (_) nil))            ; primer keys nothing
              ((symbol-function 'decknix--agent-conv-key-for-session-id)
               (lambda (sid) (when (equal sid "sid-day6") "756afa19"))))
      (let ((groups (decknix--agent-session-group-by-conversation (list s))))
        (should (= 1 (length groups)))
        (should (equal (car (car groups)) "756afa19"))))))

;; -- live-label --------------------------------------------------

(ert-deftest decknix-agent-session-group/live-label-buffer-name-only ()
  "No workspace + no tags = bare buffer name (no separator)."
  (with-temp-buffer
    (rename-buffer "*Auggie: alone*" t)
    (let ((label (decknix--agent-session-live-label (current-buffer))))
      (should (string= "A *Auggie: alone*" label)))))

(ert-deftest decknix-agent-session-group/live-label-prefixes-provider-glyph ()
  "The label starts with the buffer's provider glyph + a space."
  (with-temp-buffer
    (rename-buffer "*Claude: x*" t)
    (cl-letf (((symbol-function 'decknix-agent-provider-glyph-for-buffer)
               (lambda (_) "C")))
      (should (string-prefix-p
               "C " (decknix--agent-session-live-label (current-buffer)))))))

(ert-deftest decknix-agent-session-group/live-label-with-workspace ()
  "Workspace short-name is appended after the em-dash."
  (with-temp-buffer
    (rename-buffer "*Auggie: ws*" t)
    (setq-local decknix--agent-session-workspace "/Users/me/proj/decknix/")
    (let ((label (decknix--agent-session-live-label (current-buffer))))
      (should (string-match-p "decknix" label))
      (should (string-match-p " — " label)))))

(ert-deftest decknix-agent-session-group/live-label-with-tags ()
  "Tags render as `#tag1 #tag2' after the workspace, joined by two spaces."
  (with-temp-buffer
    (rename-buffer "*Auggie: tagged*" t)
    (setq-local decknix--agent-auggie-session-id "sid-xyz")
    (cl-letf (((symbol-function 'decknix--agent-tags-for-session)
               (lambda (_) '("review" "urgent"))))
      (let ((label (decknix--agent-session-live-label (current-buffer))))
        (should (string-match-p "#review" label))
        (should (string-match-p "#urgent" label))))))

(provide 'decknix-agent-session-group-test)
;;; decknix-agent-session-group-test.el ends here
