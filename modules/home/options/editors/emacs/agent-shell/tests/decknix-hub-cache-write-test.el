;;; decknix-hub-cache-write-test.el --- Tests for change-only cache writes -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The writer's contract: unchanged data never touches the disk, changed
;; data replaces the file whole, and a vanished file is rewritten.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-cache-write)

(defmacro decknix-hub-cache-write-test--in-tmp (file-var &rest body)
  "Bind FILE-VAR to a cache path in a fresh temp dir and run BODY."
  (declare (indent 1))
  `(let* ((dir (file-name-as-directory (make-temp-file "cache-write-" t)))
          (,file-var (expand-file-name "sub/cache.el" dir))
          (decknix--hub-cache-write-digests (make-hash-table :test 'equal)))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(defun decknix-hub-cache-write-test--read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest decknix-hub-cache-write/first-write-creates-file-and-dir ()
  (decknix-hub-cache-write-test--in-tmp file
    (should (decknix-hub-cache-write file ";; h\n" '((a . 1))))
    (should (equal (decknix-hub-cache-write-test--read file)
                   ";; h\n((a . 1))\n"))))

(ert-deftest decknix-hub-cache-write/unchanged-data-skips-the-disk ()
  "A second write of equal data returns nil and never calls write-region."
  (decknix-hub-cache-write-test--in-tmp file
    (decknix-hub-cache-write file nil '((a . 1)))
    (let ((writes 0))
      (cl-letf* ((orig (symbol-function 'write-region))
                 ((symbol-function 'write-region)
                  (lambda (&rest args) (cl-incf writes) (apply orig args))))
        (should-not (decknix-hub-cache-write file nil (list (cons 'a 1))))
        (should (= writes 0))))))

(ert-deftest decknix-hub-cache-write/changed-data-rewrites ()
  (decknix-hub-cache-write-test--in-tmp file
    (decknix-hub-cache-write file nil '((a . 1)))
    (should (decknix-hub-cache-write file nil '((a . 2))))
    (should (equal (read (decknix-hub-cache-write-test--read file)) '((a . 2))))))

(ert-deftest decknix-hub-cache-write/vanished-file-is-rewritten ()
  "The digest alone is not trusted: a deleted file is written again."
  (decknix-hub-cache-write-test--in-tmp file
    (decknix-hub-cache-write file nil '((a . 1)))
    (delete-file file)
    (should (decknix-hub-cache-write file nil '((a . 1))))
    (should (file-exists-p file))))

(ert-deftest decknix-hub-cache-write/force-writes-unchanged-data ()
  (decknix-hub-cache-write-test--in-tmp file
    (decknix-hub-cache-write file nil '((a . 1)))
    (should (decknix-hub-cache-write file nil '((a . 1)) t))))

(ert-deftest decknix-hub-cache-write/leaves-no-temp-files ()
  (decknix-hub-cache-write-test--in-tmp file
    (decknix-hub-cache-write file nil '((a . 1)))
    (decknix-hub-cache-write file nil '((a . 2)))
    (should (equal (directory-files (file-name-directory file) nil "\\`[^.]")
                   '("cache.el")))
    (should-not (directory-files (file-name-directory file) nil
                                 "\\`\\.cache-write-"))))

(ert-deftest decknix-hub-cache-write/digests-are-per-file ()
  "Equal data written to two files writes both."
  (decknix-hub-cache-write-test--in-tmp file
    (let ((other (concat file "-2")))
      (should (decknix-hub-cache-write file nil '(x)))
      (should (decknix-hub-cache-write other nil '(x))))))

(provide 'decknix-hub-cache-write-test)
;;; decknix-hub-cache-write-test.el ends here
