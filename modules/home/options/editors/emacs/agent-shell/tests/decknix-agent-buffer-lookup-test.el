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

(provide 'decknix-agent-buffer-lookup-test)
;;; decknix-agent-buffer-lookup-test.el ends here
