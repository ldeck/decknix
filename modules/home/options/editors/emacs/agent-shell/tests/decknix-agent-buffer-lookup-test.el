;;; decknix-agent-buffer-lookup-test.el --- Tests for buffer/conv-key lookups -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-buffer-lookup "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Characterisation tests for the four lookup helpers carved out of
;; main-bulk in PR B.66.  Each helper is exercised in isolation by
;; stubbing the upstream agent-shell entry points and the tag-store
;; accessors via `cl-letf'; no live process or on-disk JSON file is
;; touched.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-buffer-lookup)

;; Carved module forward-declares these (compiler hint only).  Tests
;; let-bind them, so re-declare with an initialiser to mark them as
;; special variables -- see AGENTS.md "Lexical-binding tests, dynamic
;; free vars".
(defvar decknix--agent-auggie-session-id nil)
(defvar decknix--agent-conv-key nil)
(defvar agent-shell--state nil)

;; -- buffer-session-id -------------------------------------------

(ert-deftest decknix-buffer-session-id--prefers-auggie-id ()
  "Reads the buffer-local auggie ID before the ACP fallback."
  (with-temp-buffer
    (setq-local decknix--agent-auggie-session-id "auggie-123")
    (let ((agent-shell--state '(:session (:id "acp-456"))))
      (should (equal (decknix--agent-buffer-session-id) "auggie-123")))))

(ert-deftest decknix-buffer-session-id--falls-back-to-acp ()
  "Without auggie ID, returns the nested ACP session ID."
  (with-temp-buffer
    (setq-local decknix--agent-auggie-session-id nil)
    (let ((agent-shell--state '(:session (:id "acp-456"))))
      (should (equal (decknix--agent-buffer-session-id) "acp-456")))))

(ert-deftest decknix-buffer-session-id--nil-when-neither ()
  "Returns nil when both sources are nil."
  (with-temp-buffer
    (setq-local decknix--agent-auggie-session-id nil)
    (let ((agent-shell--state nil))
      (should (null (decknix--agent-buffer-session-id))))))

;; -- find-new-shell-buffer ---------------------------------------

(ert-deftest decknix-find-new-shell-buffer--returns-fresh-agent-shell ()
  "Returns the new agent-shell buffer absent from the BEFORE snapshot."
  (let* ((before (buffer-list))
         (fresh (generate-new-buffer "*test-fresh-as*")))
    (unwind-protect
        (progn
          (with-current-buffer fresh
            ;; Stub `derived-mode-p' to claim agent-shell-mode for
            ;; this buffer only, regardless of its real major mode.
            (setq-local major-mode 'agent-shell-mode))
          (cl-letf (((symbol-function 'derived-mode-p)
                     (lambda (mode)
                       (eq major-mode mode))))
            (should (eq (decknix--agent-find-new-shell-buffer before)
                        fresh))))
      (kill-buffer fresh))))

(ert-deftest decknix-find-new-shell-buffer--nil-when-no-new-as-buffer ()
  "Returns nil when no agent-shell buffer was created after the snapshot."
  (let* ((before (buffer-list))
         (fresh (generate-new-buffer "*test-fresh-other*")))
    (unwind-protect
        (cl-letf (((symbol-function 'derived-mode-p)
                   (lambda (_mode) nil)))
          (should (null (decknix--agent-find-new-shell-buffer before))))
      (kill-buffer fresh))))

(ert-deftest decknix-find-new-shell-buffer--skips-a-claimed-buffer ()
  "A buffer that already belongs to a conversation is never adopted.

`before-buffers' is only a snapshot, so ANY agent-shell buffer created
between the snapshot and the lookup qualifies -- including one spawned
concurrently by a resume, a sidebar restore or an auto-review.  Adopting
it makes the guided new-session flow rename someone else's buffer and
file the new session under that conversation's conv-key, so the user's
tags land on that conversation and the new session inherits its whole
tag union (observed: a session tagged `conn,demos' came back with
`#20571 review pr #256 hot' as well).

A resumed buffer stamps `decknix--agent-conv-key' synchronously at
creation, whereas a genuinely new one has none until its first message
-- so an unclaimed buffer is the one this launch actually created."
  (let* ((before (buffer-list))
         (claimed (generate-new-buffer "*test-claimed-as*"))
         (fresh (generate-new-buffer "*test-fresh-as*")))
    (unwind-protect
        (progn
          (with-current-buffer claimed
            (setq-local major-mode 'agent-shell-mode)
            (setq-local decknix--agent-conv-key "e06099eb69ea3456"))
          (with-current-buffer fresh
            (setq-local major-mode 'agent-shell-mode))
          (cl-letf (((symbol-function 'derived-mode-p)
                     (lambda (mode) (eq major-mode mode))))
            (should (eq (decknix--agent-find-new-shell-buffer before)
                        fresh))))
      (kill-buffer claimed)
      (kill-buffer fresh))))

(ert-deftest decknix-find-new-shell-buffer--falls-back-to-claimed ()
  "When every new buffer is claimed, still return one rather than nil.

Returning nil would drop the caller's rename + tag persistence entirely,
which is a worse outcome than the mis-attribution this guard avoids:
the session would be left unnamed and untagged.  The preference is a
tie-break, not a hard filter."
  (let* ((before (buffer-list))
         (claimed (generate-new-buffer "*test-claimed-only*")))
    (unwind-protect
        (progn
          (with-current-buffer claimed
            (setq-local major-mode 'agent-shell-mode)
            (setq-local decknix--agent-conv-key "e06099eb69ea3456"))
          (cl-letf (((symbol-function 'derived-mode-p)
                     (lambda (mode) (eq major-mode mode))))
            (should (eq (decknix--agent-find-new-shell-buffer before)
                        claimed))))
      (kill-buffer claimed))))

;; -- find-live-buffer-for-conv-key -------------------------------

(ert-deftest decknix-find-live-buffer-for-conv-key--nil-on-nil-key ()
  "Short-circuits to nil for a nil conv-key without touching buffers."
  (cl-letf (((symbol-function 'agent-shell-buffers)
             (lambda () (error "Should not be called"))))
    (should (null (decknix--agent-find-live-buffer-for-conv-key nil)))))

(ert-deftest decknix-find-live-buffer-for-conv-key--matches-by-conv-key ()
  "Returns the buffer whose buffer-local conv-key matches."
  (let* ((target (generate-new-buffer "*test-target-as*"))
         (other (generate-new-buffer "*test-other-as*")))
    (unwind-protect
        (progn
          (with-current-buffer target
            (setq-local major-mode 'agent-shell-mode)
            (setq-local decknix--agent-conv-key "ck-match"))
          (with-current-buffer other
            (setq-local major-mode 'agent-shell-mode)
            (setq-local decknix--agent-conv-key "ck-miss"))
          (cl-letf (((symbol-function 'agent-shell-buffers)
                     (lambda () (list other target)))
                    ((symbol-function 'process-live-p)
                     (lambda (_p) t))
                    ((symbol-function 'get-buffer-process)
                     (lambda (_b) 'fake-proc))
                    ((symbol-function 'derived-mode-p)
                     (lambda (mode) (eq major-mode mode))))
            (should (eq (decknix--agent-find-live-buffer-for-conv-key
                         "ck-match")
                        target))))
      (kill-buffer target)
      (kill-buffer other))))

(ert-deftest decknix-find-live-buffer-for-conv-key--skips-dead-process ()
  "Buffer with matching conv-key but dead process does not qualify."
  (let ((buf (generate-new-buffer "*test-dead-as*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local major-mode 'agent-shell-mode)
            (setq-local decknix--agent-conv-key "ck"))
          (cl-letf (((symbol-function 'agent-shell-buffers)
                     (lambda () (list buf)))
                    ((symbol-function 'process-live-p)
                     (lambda (_p) nil))
                    ((symbol-function 'get-buffer-process)
                     (lambda (_b) 'fake-dead))
                    ((symbol-function 'derived-mode-p)
                     (lambda (mode) (eq major-mode mode))))
            (should (null (decknix--agent-find-live-buffer-for-conv-key
                           "ck")))))
      (kill-buffer buf))))

;; -- find-live-buffer-for-session-id -----------------------------
;;
;; Dedupe by conv-key alone is not sufficient. A conv-key is derived
;; from conversation content and demonstrably scatters (#151): the SAME
;; session id ends up registered under two different keys. When that
;; happens, resuming the session finds no live buffer for the new key
;; and spawns a second agent-shell -- a second ACP bridge process
;; resuming the SAME session id as the buffer already open.
;;
;; Observed live: session a6f88415-b1f0-40b0-b8ff-7ff5e926a712 held by
;; both `*Claude: fix*' (conv-key 2a94df56ec2eae48, bridge -39) and
;; `*Claude: nurturecloud/decknix/claude*' (conv-key ba8c08cbdb08559f,
;; bridge -36). Two writers on one transcript.
;;
;; The session id is the identity that cannot scatter, so it is the
;; backstop the dedupe needs.

(ert-deftest decknix-find-live-buffer-for-session-id--nil-on-nil-id ()
  "Short-circuits to nil for a nil session id without touching buffers."
  (cl-letf (((symbol-function 'agent-shell-buffers)
             (lambda () (error "Should not be called"))))
    (should (null (decknix--agent-find-live-buffer-for-session-id nil)))
    (should (null (decknix--agent-find-live-buffer-for-session-id "")))))

(ert-deftest decknix-find-live-buffer-for-session-id--matches-across-conv-keys ()
  "Finds the live buffer holding SESSION-ID even under a different conv-key.
This is the whole point: the conv-key has scattered, so only the
session id can still identify the conversation."
  (let* ((target (generate-new-buffer "*test-sid-target*"))
         (other (generate-new-buffer "*test-sid-other*")))
    (unwind-protect
        (progn
          (with-current-buffer target
            (setq-local major-mode 'agent-shell-mode)
            (setq-local decknix--agent-conv-key "ba8c08cbdb08559f")
            (setq-local decknix--agent-auggie-session-id "a6f88415"))
          (with-current-buffer other
            (setq-local major-mode 'agent-shell-mode)
            (setq-local decknix--agent-conv-key "other-key")
            (setq-local decknix--agent-auggie-session-id "different-sid"))
          (cl-letf (((symbol-function 'agent-shell-buffers)
                     (lambda () (list other target)))
                    ((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'get-buffer-process) (lambda (_b) 'fake-proc))
                    ((symbol-function 'derived-mode-p)
                     (lambda (mode) (eq major-mode mode))))
            (should (eq (decknix--agent-find-live-buffer-for-session-id "a6f88415")
                        target))))
      (kill-buffer target)
      (kill-buffer other))))

(ert-deftest decknix-find-live-buffer-for-session-id--skips-dead-process ()
  "A process-less corpse must not short-circuit resume.
Same rule as the conv-key lookup: switching to a dead shell is worse
than spawning a live one."
  (let ((buf (generate-new-buffer "*test-sid-dead*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local major-mode 'agent-shell-mode)
            (setq-local decknix--agent-auggie-session-id "sid"))
          (cl-letf (((symbol-function 'agent-shell-buffers) (lambda () (list buf)))
                    ((symbol-function 'process-live-p) (lambda (_p) nil))
                    ((symbol-function 'get-buffer-process) (lambda (_b) 'fake-dead))
                    ((symbol-function 'derived-mode-p)
                     (lambda (mode) (eq major-mode mode))))
            (should (null (decknix--agent-find-live-buffer-for-session-id "sid")))))
      (kill-buffer buf))))

(ert-deftest decknix-find-live-buffer-for-session-id--falls-back-to-acp-id ()
  "Matches the ACP session id when the auggie-side id is not set yet.
`decknix--agent-buffer-session-id' already defines that precedence;
the lookup must honour it rather than reading one field directly."
  (let ((buf (generate-new-buffer "*test-sid-acp*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local major-mode 'agent-shell-mode)
            (setq-local decknix--agent-auggie-session-id nil)
            (setq-local agent-shell--state '((:session . ((:id . "acp-sid"))))))
          (cl-letf (((symbol-function 'agent-shell-buffers) (lambda () (list buf)))
                    ((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'get-buffer-process) (lambda (_b) 'fake-proc))
                    ((symbol-function 'derived-mode-p)
                     (lambda (mode) (eq major-mode mode))))
            (should (eq (decknix--agent-find-live-buffer-for-session-id "acp-sid")
                        buf))))
      (kill-buffer buf))))

;; -- current-conv-key --------------------------------------------

(ert-deftest decknix-current-conv-key--finds-key-by-session-id ()
  "Walks the conversations table and returns the key whose `sessions'
list contains the buffer-local auggie session ID."
  (let ((convs (make-hash-table :test 'equal))
        (entry-a (make-hash-table :test 'equal))
        (entry-b (make-hash-table :test 'equal)))
    (puthash "sessions" '("sid-1" "sid-2") entry-a)
    (puthash "sessions" '("sid-7") entry-b)
    (puthash "ck-a" entry-a convs)
    (puthash "ck-b" entry-b convs)
    (cl-letf (((symbol-function 'decknix--agent-tags-read)
               (lambda () 'fake-store))
              ((symbol-function 'decknix--agent-tags-conversations)
               (lambda (_) convs))
              ((symbol-function 'derived-mode-p)
               (lambda (_) t)))
      (with-temp-buffer
        (setq-local decknix--agent-auggie-session-id "sid-7")
        (should (equal (decknix--agent-current-conv-key) "ck-b"))))))

(ert-deftest decknix-current-conv-key--nil-when-not-in-agent-shell ()
  "Returns nil when not in an agent-shell buffer."
  (cl-letf (((symbol-function 'derived-mode-p)
             (lambda (_) nil)))
    (with-temp-buffer
      (setq-local decknix--agent-auggie-session-id "sid-7")
      (should (null (decknix--agent-current-conv-key))))))

(ert-deftest decknix-current-conv-key--nil-when-no-session-id ()
  "Returns nil when the buffer-local session ID is not set."
  (cl-letf (((symbol-function 'derived-mode-p)
             (lambda (_) t)))
    (with-temp-buffer
      (setq-local decknix--agent-auggie-session-id nil)
      (should (null (decknix--agent-current-conv-key))))))

(ert-deftest decknix-current-conv-key--prefers-buffer-local-key ()
  "When the buffer carries its own conv-key, return it verbatim and do NOT
consult the store — immune to a session-id being wrongly listed in a
polluted container conversation (the Live-sidebar mislabel bug)."
  (cl-letf (((symbol-function 'derived-mode-p) (lambda (_) t))
            ((symbol-function 'decknix--agent-tags-read)
             (lambda () (error "store must not be consulted with a local key")))
            ((symbol-function 'decknix--agent-tags-conversations)
             (lambda (_) (error "store must not be consulted with a local key"))))
    (with-temp-buffer
      (setq-local decknix--agent-auggie-session-id "sid-shared")
      (setq-local decknix--agent-conv-key "ck-own")
      (should (equal (decknix--agent-current-conv-key) "ck-own")))))

(provide 'decknix-agent-buffer-lookup-test)
;;; decknix-agent-buffer-lookup-test.el ends here
