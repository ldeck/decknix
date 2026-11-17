;;; decknix-state-io.el --- Print and read state files whole -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: decknix, persistence

;;; Commentary:
;;
;; Every decknix store is a printed Lisp form written with `prin1' and
;; read back with `read'.  The printer obeys `print-length' and
;; `print-level', and some packages let-bind them (to 200, say) around
;; code that ended up triggering one of our saves.  The store was then
;; written as its first 200 entries followed by a literal `...', and read
;; back as a list whose last element is the symbol `...'.  Every reader
;; that took the `car' of each entry then signalled
;; `(wrong-type-argument listp ...)', from inside process sentinels, and
;; the entries past 200 were gone.
;;
;; So writers print through `decknix-state-io-prin1' (or the macro, when
;; the printing is spread over several calls), which turns every limit
;; off whatever the caller bound, and readers pass what they read through
;; `decknix-state-io-clean-list', which drops elements that cannot be
;; entries instead of failing on them.

;;; Code:

(require 'seq)

(defmacro decknix-state-io-with-full-print (&rest body)
  "Run BODY with the printer limits off, so printed data reads back whole."
  (declare (indent 0) (debug t))
  `(let ((print-length nil)
         (print-level nil)
         (print-circle nil))
     ,@body))

(defun decknix-state-io-prin1 (object &optional stream)
  "Print OBJECT readably to STREAM, ignoring any bound printer limits."
  (decknix-state-io-with-full-print (prin1 object stream)))

(defun decknix-state-io-to-string (object)
  "Return OBJECT printed readably, ignoring any bound printer limits."
  (decknix-state-io-with-full-print (prin1-to-string object)))

(defun decknix-state-io-pp (object &optional stream)
  "Pretty-print OBJECT to STREAM, ignoring any bound printer limits."
  (decknix-state-io-with-full-print (pp object stream)))

(defun decknix-state-io-clean-list (data &optional valid-p)
  "Return the elements of DATA that satisfy VALID-P (default `consp').
DATA that is not a proper list yields nil.  This drops the symbol `...'
a truncated print leaves behind, and any other malformed entry."
  (when (proper-list-p data)
    (let ((valid-p (or valid-p #'consp)))
      (seq-filter valid-p data))))

(defun decknix-state-io-read-file (file)
  "Return the first form in FILE, or nil when FILE is absent or unreadable."
  (when (and file (file-readable-p file))
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (read (current-buffer))))))

(defun decknix-state-io-read-list (file &optional valid-p)
  "Return the list stored in FILE, keeping only elements satisfying VALID-P.
VALID-P defaults to `consp'.  See `decknix-state-io-clean-list'."
  (decknix-state-io-clean-list (decknix-state-io-read-file file) valid-p))

(provide 'decknix-state-io)
;;; decknix-state-io.el ends here
