;;; decknix-agent-live-sessions-test.el --- Tests for live-sessions persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-live-sessions "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix-agent-live-sessions':
;;
;; - Pure helpers (`add-entry', `remove-by', `filter-dismissed',
;;   `dismissed-add', `entry-key') return new lists with the
;;   expected dedupe / removal semantics.
;; - IO wrappers (`read', `write', `snapshot-and-truncate',
;;   `dismiss') round-trip through tmp files and respect the
;;   `decknix--live-sessions-suppress-write' shutdown flag.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-live-sessions)

(defun decknix-live-sessions-test--entry (sid ck &optional name)
  "Build a live-sessions alist with SID and CK."
  (list (cons 'session-id sid)
        (cons 'name (or name sid))
        (cons 'workspace "/tmp")
        (cons 'conv-key ck)
        (cons 'tags nil)))

(defmacro decknix-live-sessions-test--with-tmp (&rest body)
  "Run BODY with the live + dismissed files bound to fresh tmp paths."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "decknix-live-sessions-" t))
          (decknix--live-sessions-file
           (expand-file-name "live.el" tmp))
          (decknix--live-sessions-dismissed-file
           (expand-file-name "dismissed.el" tmp))
          (decknix--live-sessions-suppress-write nil))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p tmp)
         (delete-directory tmp t)))))

;; -- entry-key -----------------------------------------------------

(ert-deftest decknix-live-sessions-entry-key--prefers-conv-key ()
  (should (equal "ck-a"
                 (decknix--live-sessions-entry-key
                  (decknix-live-sessions-test--entry "s1" "ck-a")))))

(ert-deftest decknix-live-sessions-entry-key--falls-back-to-sid ()
  (should (equal '(:sid . "s1")
                 (decknix--live-sessions-entry-key
                  (decknix-live-sessions-test--entry "s1" nil)))))

(ert-deftest decknix-live-sessions-entry-key--nil-when-both-missing ()
  (should (null (decknix--live-sessions-entry-key
                 (decknix-live-sessions-test--entry nil nil)))))

(ert-deftest decknix-live-sessions-entry-key--treats-empty-as-missing ()
  (should (equal '(:sid . "s1")
                 (decknix--live-sessions-entry-key
                  (decknix-live-sessions-test--entry "s1" "")))))

;; -- add-entry -----------------------------------------------------

(ert-deftest decknix-live-sessions-add-entry--appends-when-empty ()
  (let* ((e1 (decknix-live-sessions-test--entry "s1" "ck-a"))
         (out (decknix--live-sessions-add-entry nil e1)))
    (should (equal (list e1) out))))

(ert-deftest decknix-live-sessions-add-entry--idempotent-on-conv-key ()
  "Adding the same conv-key twice keeps the list at one row."
  (let* ((e1 (decknix-live-sessions-test--entry "s1" "ck-a" "first"))
         (e2 (decknix-live-sessions-test--entry "s2" "ck-a" "second"))
         (out (decknix--live-sessions-add-entry
               (decknix--live-sessions-add-entry nil e1) e2)))
    (should (= 1 (length out)))
    ;; The newer entry wins (replacement, not skip).
    (should (equal "second" (alist-get 'name (car out))))
    (should (equal "s2" (alist-get 'session-id (car out))))))

(ert-deftest decknix-live-sessions-add-entry--idempotent-on-sid-when-no-conv-key ()
  (let* ((e1 (decknix-live-sessions-test--entry "s1" nil "first"))
         (e2 (decknix-live-sessions-test--entry "s1" nil "second"))
         (out (decknix--live-sessions-add-entry
               (decknix--live-sessions-add-entry nil e1) e2)))
    (should (= 1 (length out)))
    (should (equal "second" (alist-get 'name (car out))))))

(ert-deftest decknix-live-sessions-add-entry--keeps-distinct-conv-keys ()
  (let* ((e1 (decknix-live-sessions-test--entry "s1" "ck-a"))
         (e2 (decknix-live-sessions-test--entry "s2" "ck-b"))
         (out (decknix--live-sessions-add-entry
               (decknix--live-sessions-add-entry nil e1) e2)))
    (should (= 2 (length out)))
    (should (equal '("ck-a" "ck-b")
                   (mapcar (lambda (e) (alist-get 'conv-key e)) out)))))

;; -- remove-by -----------------------------------------------------

(ert-deftest decknix-live-sessions-remove-by--by-conv-key ()
  (let* ((e1 (decknix-live-sessions-test--entry "s1" "ck-a"))
         (e2 (decknix-live-sessions-test--entry "s2" "ck-b"))
         (out (decknix--live-sessions-remove-by (list e1 e2) "ck-a" nil)))
    (should (equal (list e2) out))))

(ert-deftest decknix-live-sessions-remove-by--by-sid ()
  (let* ((e1 (decknix-live-sessions-test--entry "s1" nil))
         (e2 (decknix-live-sessions-test--entry "s2" nil))
         (out (decknix--live-sessions-remove-by (list e1 e2) nil "s1")))
    (should (equal (list e2) out))))

(ert-deftest decknix-live-sessions-remove-by--no-match-passthrough ()
  (let* ((e1 (decknix-live-sessions-test--entry "s1" "ck-a"))
         (out (decknix--live-sessions-remove-by (list e1) "ck-z" "s-z")))
    (should (equal (list e1) out))))

(ert-deftest decknix-live-sessions-remove-by--ignores-empty-keys ()
  (let* ((e1 (decknix-live-sessions-test--entry "" ""))
         (out (decknix--live-sessions-remove-by (list e1) "" "")))
    (should (equal (list e1) out))))

;; -- filter-dismissed ----------------------------------------------

(ert-deftest decknix-live-sessions-filter-dismissed--removes-matches ()
  (let* ((e1 (decknix-live-sessions-test--entry "s1" "ck-a"))
         (e2 (decknix-live-sessions-test--entry "s2" "ck-b"))
         (out (decknix--live-sessions-filter-dismissed
               (list e1 e2) (list "ck-b"))))
    (should (equal (list e1) out))))

(ert-deftest decknix-live-sessions-filter-dismissed--passthrough-when-empty ()
  (let* ((e1 (decknix-live-sessions-test--entry "s1" "ck-a"))
         (out (decknix--live-sessions-filter-dismissed (list e1) nil)))
    (should (equal (list e1) out))))

(ert-deftest decknix-live-sessions-filter-dismissed--matches-sid-fallback ()
  "Dismissed `(:sid . SID)' shadows entries lacking conv-key."
  (let* ((e1 (decknix-live-sessions-test--entry "s1" nil))
         (out (decknix--live-sessions-filter-dismissed
               (list e1) (list (cons :sid "s1")))))
    (should (null out))))

;; -- dismissed-add -------------------------------------------------

(ert-deftest decknix-live-sessions-dismissed-add--idempotent ()
  (let ((d (decknix--live-sessions-dismissed-add nil "ck-a")))
    (should (equal '("ck-a") d))
    (should (equal '("ck-a") (decknix--live-sessions-dismissed-add d "ck-a")))))

(ert-deftest decknix-live-sessions-dismissed-add--ignores-nil ()
  (should (equal '("ck-a")
                 (decknix--live-sessions-dismissed-add '("ck-a") nil))))

;; -- IO: roundtrip -------------------------------------------------

(ert-deftest decknix-live-sessions-read--missing-file-returns-nil ()
  (decknix-live-sessions-test--with-tmp
    (should (null (decknix--live-sessions-read)))
    (should (null (decknix--live-sessions-dismissed-read)))))

(ert-deftest decknix-live-sessions-write+read--roundtrip ()
  (decknix-live-sessions-test--with-tmp
    (let* ((e1 (decknix-live-sessions-test--entry "s1" "ck-a"))
           (e2 (decknix-live-sessions-test--entry "s2" "ck-b")))
      (decknix--live-sessions-write (list e1 e2))
      (should (equal (list e1 e2) (decknix--live-sessions-read))))))

(ert-deftest decknix-live-sessions-record--persists-and-dedupes ()
  (decknix-live-sessions-test--with-tmp
    (decknix--live-sessions-record
     (decknix-live-sessions-test--entry "s1" "ck-a" "first"))
    (decknix--live-sessions-record
     (decknix-live-sessions-test--entry "s2" "ck-a" "second"))
    (let ((entries (decknix--live-sessions-read)))
      (should (= 1 (length entries)))
      (should (equal "second" (alist-get 'name (car entries)))))))

(ert-deftest decknix-live-sessions-forget--removes-row ()
  (decknix-live-sessions-test--with-tmp
    (decknix--live-sessions-record
     (decknix-live-sessions-test--entry "s1" "ck-a"))
    (decknix--live-sessions-record
     (decknix-live-sessions-test--entry "s2" "ck-b"))
    (decknix--live-sessions-forget "ck-a" nil)
    (let ((entries (decknix--live-sessions-read)))
      (should (= 1 (length entries)))
      (should (equal "ck-b" (alist-get 'conv-key (car entries)))))))

;; -- snapshot-and-truncate -----------------------------------------

(ert-deftest decknix-live-sessions-snapshot-and-truncate--returns-and-clears ()
  (decknix-live-sessions-test--with-tmp
    (let* ((e1 (decknix-live-sessions-test--entry "s1" "ck-a")))
      (decknix--live-sessions-write (list e1))
      (let ((snap (decknix--live-sessions-snapshot-and-truncate)))
        (should (equal (list e1) snap))
        (should (null (decknix--live-sessions-read)))))))

(ert-deftest decknix-live-sessions-snapshot-and-truncate--missing-is-nil ()
  (decknix-live-sessions-test--with-tmp
    (let ((snap (decknix--live-sessions-snapshot-and-truncate)))
      (should (null snap))
      (should (null (decknix--live-sessions-read))))))

;; -- dismiss roundtrip ---------------------------------------------

(ert-deftest decknix-live-sessions-dismiss--persists-keys ()
  (decknix-live-sessions-test--with-tmp
    (decknix--live-sessions-dismiss "ck-a")
    (decknix--live-sessions-dismiss "ck-b")
    (decknix--live-sessions-dismiss "ck-a") ;; idempotent
    (let ((d (decknix--live-sessions-dismissed-read)))
      (should (= 2 (length d)))
      (should (member "ck-a" d))
      (should (member "ck-b" d)))))

;; -- suppress-write flag -------------------------------------------

(ert-deftest decknix-live-sessions--suppress-write-no-ops ()
  "When suppress-write is set, write functions do nothing."
  (decknix-live-sessions-test--with-tmp
    (decknix--live-sessions-write
     (list (decknix-live-sessions-test--entry "s1" "ck-a")))
    (let ((decknix--live-sessions-suppress-write t))
      ;; A forget that would normally remove the row no-ops.
      (decknix--live-sessions-forget "ck-a" nil)
      ;; A record that would normally add a row no-ops.
      (decknix--live-sessions-record
       (decknix-live-sessions-test--entry "s2" "ck-b")))
    (let ((entries (decknix--live-sessions-read)))
      (should (= 1 (length entries)))
      (should (equal "ck-a" (alist-get 'conv-key (car entries)))))))

(provide 'decknix-agent-live-sessions-test)
;;; decknix-agent-live-sessions-test.el ends here
