;;; decknix-ship-progress-test.el --- Tests for /ship progress records -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'decknix-ship-progress)

(defmacro decknix-ship-progress-test--in-tmp (&rest body)
  "Run BODY with an empty, private progress directory and table."
  (declare (indent 0))
  `(let* ((decknix-ship-progress-dir (file-name-as-directory (make-temp-file "ship" t)))
          (decknix-ship-progress--records (make-hash-table :test 'equal))
          (decknix-ship-progress-generation 0))
     (unwind-protect (progn ,@body)
       (delete-directory decknix-ship-progress-dir t))))

(defun decknix-ship-progress-test--write (name text)
  (let ((f (expand-file-name name decknix-ship-progress-dir)))
    (with-temp-file f (insert text))
    f))

(ert-deftest decknix-ship-progress--a-record-needs-repo-number-and-stage ()
  (should (decknix-ship-progress-parse
           "{\"repo\":\"o/r\",\"number\":3,\"stage\":\"us-stg\",\"status\":\"verified\"}"))
  (should-not (decknix-ship-progress-parse "{\"repo\":\"o/r\",\"number\":3}"))
  (should-not (decknix-ship-progress-parse "not json")))

(ert-deftest decknix-ship-progress--records-load-and-look-up-case-insensitively ()
  (decknix-ship-progress-test--in-tmp
    (decknix-ship-progress-test--write
     "o-r-3.json" "{\"repo\":\"O/R\",\"number\":3,\"stage\":\"us-prd\",\"status\":\"done\"}")
    (decknix-ship-progress-test--write "junk.json" "{}")
    (decknix-ship-progress-load-all)
    (should (equal "us-prd" (alist-get 'stage (decknix-ship-progress-lookup "o/r" 3))))
    (should-not (decknix-ship-progress-lookup "o/r" 4))
    (should (> decknix-ship-progress-generation 0))))

(ert-deftest decknix-ship-progress--a-deleted-file-drops-its-record ()
  (decknix-ship-progress-test--in-tmp
    (let ((f (decknix-ship-progress-test--write
              "o-r-3.json" "{\"repo\":\"o/r\",\"number\":3,\"stage\":\"us-dev\"}")))
      (decknix-ship-progress--on-event (list nil 'created f))
      (should (decknix-ship-progress-lookup "o/r" 3))
      (delete-file f)
      (decknix-ship-progress--on-event (list nil 'deleted f))
      (should-not (decknix-ship-progress-lookup "o/r" 3)))))

;;; decknix-ship-progress-test.el ends here
