;;; decknix-state-io-test.el --- Tests for whole-state printing and tolerant reads -*- lexical-binding: t -*-

;;; Commentary:
;;
;; A store saved while a caller had `print-length' bound used to come out
;; as its first N entries and a literal `...'; reading that back then
;; failed on the symbol.  Writers must print everything, and readers must
;; drop what cannot be an entry instead of failing.

;;; Code:

(require 'ert)
(require 'decknix-state-io)

(defmacro decknix-state-io-test--with-file (var &rest body)
  "Bind VAR to a fresh temp file name and run BODY, deleting it after."
  (declare (indent 1))
  `(let ((,var (make-temp-file "state-io-")))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,var)))))

(defconst decknix-state-io-test--entries
  '(("a" . 1) ("b" . 2) ("c" . 3) ("d" . (4 (5 (6 (7))))))
  "More entries, and deeper, than the bound limits below allow.")

(ert-deftest decknix-state-io/prin1-ignores-bound-print-length ()
  (decknix-state-io-test--with-file file
    (let ((print-length 2) (print-level 2))
      (with-temp-file file
        (decknix-state-io-prin1 decknix-state-io-test--entries (current-buffer))))
    (should (equal (decknix-state-io-read-file file)
                   decknix-state-io-test--entries))))

(ert-deftest decknix-state-io/to-string-ignores-bound-print-length ()
  (let ((print-length 2) (print-level 2))
    (should (equal (car (read-from-string
                         (decknix-state-io-to-string decknix-state-io-test--entries)))
                   decknix-state-io-test--entries))))

(ert-deftest decknix-state-io/pp-ignores-bound-print-length ()
  (let ((print-length 2) (print-level 2))
    (should (equal (car (read-from-string
                         (with-output-to-string
                           (decknix-state-io-pp decknix-state-io-test--entries))))
                   decknix-state-io-test--entries))))

(ert-deftest decknix-state-io/macro-covers-several-prints ()
  (let ((print-length 2))
    (should (equal (decknix-state-io-with-full-print
                     (prin1-to-string '(1 2 3)))
                   "(1 2 3)"))))

(ert-deftest decknix-state-io/read-drops-truncation-marker ()
  "A file saved truncated keeps the entries it has and loses the `...'."
  (decknix-state-io-test--with-file file
    (with-temp-file file (insert ";; header\n((\"a\" . 1) (\"b\" . 2) ...)\n"))
    (should (equal (decknix-state-io-read-list file)
                   '(("a" . 1) ("b" . 2))))))

(ert-deftest decknix-state-io/read-applies-predicate ()
  (decknix-state-io-test--with-file file
    (with-temp-file file (insert "(\"x\" (k . v) 3 ...)"))
    (should (equal (decknix-state-io-read-list file #'stringp) '("x")))))

(ert-deftest decknix-state-io/read-tolerates-missing-and-garbage ()
  (should-not (decknix-state-io-read-list "/nonexistent/state-io-file"))
  (decknix-state-io-test--with-file file
    (with-temp-file file (insert "((\"a\" . 1"))
    (should-not (decknix-state-io-read-list file)))
  (decknix-state-io-test--with-file file
    (with-temp-file file (insert "just-a-symbol"))
    (should-not (decknix-state-io-read-list file))))

(ert-deftest decknix-state-io/clean-list-rejects-improper-lists ()
  (should-not (decknix-state-io-clean-list '((a . 1) . tail)))
  (should (equal (decknix-state-io-clean-list '((a . 1) ... nil (b . 2)))
                 '((a . 1) (b . 2)))))

(provide 'decknix-state-io-test)
;;; decknix-state-io-test.el ends here
