;;; decknix-agent-compose-history-test.el --- Tests for compose history -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-compose-history' (PR
;; B.75).  Exercises the on-demand item/queue/dedup state machine
;; without touching the user's session directory by stubbing
;; `decknix--prompt-extract-from-file' via `cl-letf'.
;;
;; Buffer-local state is exercised inside `with-temp-buffer' so the
;; defvar-locals in the carved module take effect in isolation.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ring)
(require 'decknix-agent-compose-history)

(defmacro decknix-test--with-history-buffer (&rest body)
  "Run BODY inside a fresh buffer with reset history state."
  `(with-temp-buffer
     (decknix--compose-history-reset)
     ,@body))

(ert-deftest decknix-compose-history--reset-clears-all-state ()
  "`-history-reset' returns every var to its initial value."
  (decknix-test--with-history-buffer
   (setq decknix--compose-history-index 7
         decknix--compose-saved-input "draft"
         decknix--compose-history-items '("a" "b")
         decknix--compose-history-seen (make-hash-table :test 'equal)
         decknix--compose-history-file-queue '("/tmp/x.json")
         decknix--compose-history-exhausted t
         decknix--compose-history-local-only nil)
   (decknix--compose-history-reset)
   (should (= -1 decknix--compose-history-index))
   (should (null decknix--compose-saved-input))
   (should (null decknix--compose-history-items))
   (should (null decknix--compose-history-seen))
   (should (null decknix--compose-history-file-queue))
   (should (null decknix--compose-history-exhausted))
   (should (eq t decknix--compose-history-local-only))))

(ert-deftest decknix-compose-history--load-next-batch-dedups-and-appends ()
  "Loading a batch puts new prompts at the end of items + marks seen."
  (decknix-test--with-history-buffer
   (let ((seen (make-hash-table :test 'equal)))
     (puthash "old" t seen)
     (setq decknix--compose-history-items '("old")
           decknix--compose-history-seen seen
           decknix--compose-history-file-queue '("/tmp/a.json")))
   (cl-letf (((symbol-function 'decknix--prompt-extract-from-file)
              (lambda (_file) '("old" "new1" "new2"))))
     (let ((added (decknix--compose-history-load-next-batch)))
       (should added)
       (should (equal '("old" "new1" "new2")
                      decknix--compose-history-items))
       (should (gethash "new1" decknix--compose-history-seen))
       (should (gethash "new2" decknix--compose-history-seen))))
   (should (null decknix--compose-history-file-queue))
   (should (eq t decknix--compose-history-exhausted))))

(ert-deftest decknix-compose-history--load-next-batch-skips-empty-files ()
  "Files yielding only duplicates fall through to the next file."
  (decknix-test--with-history-buffer
   (let ((seen (make-hash-table :test 'equal))
         (call-count 0))
     (puthash "dup" t seen)
     (setq decknix--compose-history-items '("dup")
           decknix--compose-history-seen seen
           decknix--compose-history-file-queue '("/tmp/a.json" "/tmp/b.json"))
     (cl-letf (((symbol-function 'decknix--prompt-extract-from-file)
                (lambda (_file)
                  (cl-incf call-count)
                  (if (= call-count 1) '("dup") '("fresh")))))
       (should (decknix--compose-history-load-next-batch))
       (should (equal '("dup" "fresh") decknix--compose-history-items))
       (should (= 2 call-count))))))

(ert-deftest decknix-compose-history--navigate-previous-advances-index ()
  "First M-p moves index to 0 and inserts the newest prompt."
  (decknix-test--with-history-buffer
   (let ((seen (make-hash-table :test 'equal)))
     (puthash "p1" t seen)
     (puthash "p2" t seen)
     (setq decknix--compose-history-items '("p1" "p2")
           decknix--compose-history-seen seen
           decknix--compose-history-exhausted t
           decknix--compose-history-local-only t))
   (insert "draft")
   (decknix--compose-history-navigate-previous)
   (should (= 0 decknix--compose-history-index))
   (should (string= "draft" decknix--compose-saved-input))
   (should (string= "p1" (buffer-string)))))

(ert-deftest decknix-compose-history--navigate-previous-stops-at-end ()
  "M-p past the last item dings and leaves index unchanged."
  (decknix-test--with-history-buffer
   (let ((seen (make-hash-table :test 'equal)))
     (puthash "only" t seen)
     (setq decknix--compose-history-items '("only")
           decknix--compose-history-seen seen
           decknix--compose-history-index 0
           decknix--compose-history-exhausted t
           decknix--compose-history-local-only t))
   (insert "only")
   ;; Suppress ding noise during the assertion
   (cl-letf (((symbol-function 'ding) #'ignore))
     (decknix--compose-history-navigate-previous))
   (should (= 0 decknix--compose-history-index))))

(ert-deftest decknix-compose-history--navigate-next-restores-saved-input ()
  "M-n at index 0 restores saved input and resets index to -1."
  (decknix-test--with-history-buffer
   (let ((seen (make-hash-table :test 'equal)))
     (puthash "p1" t seen)
     (setq decknix--compose-history-items '("p1")
           decknix--compose-history-seen seen
           decknix--compose-history-index 0
           decknix--compose-saved-input "my-draft"
           decknix--compose-history-exhausted t))
   (insert "p1")
   (decknix--compose-history-navigate-next)
   (should (= -1 decknix--compose-history-index))
   (should (string= "my-draft" (buffer-string)))))

(ert-deftest decknix-compose-history--navigate-next-from-old-walks-newer ()
  "M-n from an older index walks toward index 0."
  (decknix-test--with-history-buffer
   (let ((seen (make-hash-table :test 'equal)))
     (puthash "newer" t seen)
     (puthash "older" t seen)
     (setq decknix--compose-history-items '("newer" "older")
           decknix--compose-history-seen seen
           decknix--compose-history-index 1
           decknix--compose-history-exhausted t))
   (insert "older")
   (decknix--compose-history-navigate-next)
   (should (= 0 decknix--compose-history-index))
   (should (string= "newer" (buffer-string)))))

(provide 'decknix-agent-compose-history-test)
;;; decknix-agent-compose-history-test.el ends here
