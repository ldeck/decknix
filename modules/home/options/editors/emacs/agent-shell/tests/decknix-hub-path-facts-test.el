;;; decknix-hub-path-facts-test.el --- Path-fact cache contract -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1") (decknix-hub-path-facts "0.1"))

;;; Commentary:
;;
;; Pins the disk-free render contract for `decknix-hub-path-facts':
;;   * the pure accessors (`-path-equal-p', `-path-mtime',
;;     `-path-truename') NEVER touch the filesystem, and
;;   * the background worker (`-path-facts-refresh') yields the moment
;;     input is pending and records existence + mtime + truename.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-path-facts)

(defmacro decknix-path-facts-test--isolated (&rest body)
  "Run BODY with a fresh, empty path-fact cache."
  (declare (indent 0))
  `(let ((decknix--hub-path-facts (make-hash-table :test 'equal))
         (decknix-hub-path-facts-ttl 10.0))
     ,@body))

(defmacro decknix-path-facts-test--no-disk (&rest body)
  "Run BODY with every filesystem probe stubbed to signal.
Any accidental disk touch fails the test loudly."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'file-truename)
              (lambda (&rest _) (error "file-truename on render path")))
             ((symbol-function 'file-equal-p)
              (lambda (&rest _) (error "file-equal-p on render path")))
             ((symbol-function 'file-exists-p)
              (lambda (&rest _) (error "file-exists-p on render path")))
             ((symbol-function 'file-attributes)
              (lambda (&rest _) (error "file-attributes on render path"))))
     ,@body))

;; -- Pure accessors are disk-free -----------------------------------

(ert-deftest decknix-path-facts--equal-p-cold-cache-is-disk-free ()
  "`-path-equal-p' compares expanded paths with no probe when uncached."
  (decknix-path-facts-test--isolated
    (decknix-path-facts-test--no-disk
      (should (decknix--hub-path-equal-p "/tmp/a" "/tmp/a/"))
      (should (decknix--hub-path-equal-p "/tmp/a" "/tmp/a"))
      (should-not (decknix--hub-path-equal-p "/tmp/a" "/tmp/b"))
      (should-not (decknix--hub-path-equal-p "/tmp/a" nil)))))

(ert-deftest decknix-path-facts--equal-p-uses-cached-truename ()
  "Two distinct keys sharing a cached truename compare equal, disk-free."
  (decknix-path-facts-test--isolated
    (puthash (decknix--hub-path-key "/tmp/link")
             (list :truename "/tmp/real" :exists t :mtime nil :ts (float-time))
             decknix--hub-path-facts)
    (puthash (decknix--hub-path-key "/tmp/real")
             (list :truename "/tmp/real" :exists t :mtime nil :ts (float-time))
             decknix--hub-path-facts)
    (decknix-path-facts-test--no-disk
      (should (decknix--hub-path-equal-p "/tmp/link" "/tmp/real")))))

(ert-deftest decknix-path-facts--mtime-cold-cache-is-nil-and-disk-free ()
  "Unknown path -> nil mtime with no probe; cached exists=nil -> nil."
  (decknix-path-facts-test--isolated
    (puthash (decknix--hub-path-key "/tmp/gone")
             (list :truename "/tmp/gone" :exists nil :mtime '(1 2 3 4)
                   :ts (float-time))
             decknix--hub-path-facts)
    (decknix-path-facts-test--no-disk
      (should-not (decknix--hub-path-mtime "/tmp/unknown"))
      (should-not (decknix--hub-path-mtime "/tmp/gone")))))

(ert-deftest decknix-path-facts--mtime-returns-cached ()
  "A cached, existing entry yields its stored mtime disk-free."
  (decknix-path-facts-test--isolated
    (puthash (decknix--hub-path-key "/tmp/here")
             (list :truename "/tmp/here" :exists t :mtime '(25000 0 0 0)
                   :ts (float-time))
             decknix--hub-path-facts)
    (decknix-path-facts-test--no-disk
      (should (equal '(25000 0 0 0) (decknix--hub-path-mtime "/tmp/here"))))))

;; -- Background worker probes + yields -------------------------------

(ert-deftest decknix-path-facts--put-records-real-facts ()
  "`-path-facts-put' records exists + mtime + truename for a real dir."
  (decknix-path-facts-test--isolated
    (let ((dir (make-temp-file "decknix-pf" t)))
      (unwind-protect
          (let ((facts (decknix--hub-path-facts-put dir)))
            (should (plist-get facts :exists))
            (should (plist-get facts :mtime))
            (should (equal (directory-file-name (file-truename dir))
                           (plist-get facts :truename))))
        (delete-directory dir t)))))

(ert-deftest decknix-path-facts--put-skips-fresh-entry ()
  "A fresh entry is returned as-is (no re-probe) unless FORCE is set.
Identity, not call-counting: `file-truename' recurses per path
component so counting its calls is unreliable.  A skipped put
returns the very same cached plist object; a forced put builds a
new one."
  (decknix-path-facts-test--isolated
    (let ((dir (make-temp-file "decknix-pf" t)))
      (unwind-protect
          (let ((first (decknix--hub-path-facts-put dir)))
            (should (eq first (decknix--hub-path-facts-put dir)))
            (should-not (eq first (decknix--hub-path-facts-put dir t))))
        (delete-directory dir t)))))

(ert-deftest decknix-path-facts--refresh-yields-on-input ()
  "`-path-facts-refresh' processes nothing while input is pending."
  (decknix-path-facts-test--isolated
    (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t))
              ((symbol-function 'decknix--hub-path-facts-put)
               (lambda (&rest _) (error "should not probe while typing"))))
      (should-not (decknix--hub-path-facts-refresh '("/tmp/a" "/tmp/b"))))))

(ert-deftest decknix-path-facts--refresh-populates-when-idle ()
  "With no pending input, refresh probes every path."
  (decknix-path-facts-test--isolated
    (let ((seen nil))
      (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) nil))
                ((symbol-function 'decknix--hub-path-facts-put)
                 (lambda (p &optional _f) (push p seen))))
        (decknix--hub-path-facts-refresh '("/tmp/a" "/tmp/b" nil 5))
        (should (equal '("/tmp/a" "/tmp/b") (nreverse seen)))))))

(ert-deftest decknix-path-facts--refresh-stops-after-its-slice ()
  "A long sweep yields `more' once its slice is spent, leaving the rest."
  (decknix-path-facts-test--isolated
    (let ((seen nil)
          (decknix-hub-path-facts-slice-seconds 0.01))
      (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) nil))
                ((symbol-function 'decknix--hub-path-facts-put)
                 (lambda (p &optional _f) (push p seen) (sleep-for 0.02))))
        (should (eq 'more (decknix--hub-path-facts-refresh '("/a" "/b" "/c"))))
        (should (equal '("/a") seen))))))

(ert-deftest decknix-path-facts--refresh-within-its-slice-returns-nil ()
  (decknix-path-facts-test--isolated
    (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) nil))
              ((symbol-function 'decknix--hub-path-facts-put) #'ignore))
      (should-not (decknix--hub-path-facts-refresh '("/a" "/b"))))))

(ert-deftest decknix-path-facts--stale-entry-reuses-a-fresh-truename ()
  "Existence and mtime are re-read; the truename is not resolved again."
  (decknix-path-facts-test--isolated
    (let ((dir (make-temp-file "decknix-pf" t)))
      (unwind-protect
          (progn
            (decknix--hub-path-facts-put dir)
            (let ((key (decknix--hub-path-key dir)))
              (plist-put (gethash key decknix--hub-path-facts) :ts 0)
              (cl-letf (((symbol-function 'file-truename)
                         (lambda (&rest _) (error "truename re-resolved"))))
                (let ((facts (decknix--hub-path-facts-put dir)))
                  (should (plist-get facts :exists))
                  (should (> (plist-get facts :ts) 0))))))
        (delete-directory dir t)))))

(ert-deftest decknix-path-facts--an-old-truename-is-resolved-again ()
  (decknix-path-facts-test--isolated
    (let ((dir (make-temp-file "decknix-pf" t))
          (resolved 0))
      (unwind-protect
          (progn
            (decknix--hub-path-facts-put dir)
            (let ((key (decknix--hub-path-key dir)))
              (plist-put (gethash key decknix--hub-path-facts) :ts 0)
              (plist-put (gethash key decknix--hub-path-facts) :tn-ts 0)
              (cl-letf* ((orig (symbol-function 'file-truename))
                         ((symbol-function 'file-truename)
                          (lambda (&rest args) (cl-incf resolved) (apply orig args))))
                (decknix--hub-path-facts-put dir)
                (should (> resolved 0)))))
        (delete-directory dir t)))))

(ert-deftest decknix-path-facts--a-vanished-path-drops-its-truename-age ()
  "Once a path is gone its truename is resolved afresh when it returns."
  (decknix-path-facts-test--isolated
    (let ((dir (make-temp-file "decknix-pf" t)))
      (decknix--hub-path-facts-put dir)
      (delete-directory dir t)
      (let ((key (decknix--hub-path-key dir)))
        (plist-put (gethash key decknix--hub-path-facts) :ts 0)
        (let ((facts (decknix--hub-path-facts-put dir)))
          (should-not (plist-get facts :exists))
          (should-not (plist-get facts :tn-ts)))))))

(provide 'decknix-hub-path-facts-test)
;;; decknix-hub-path-facts-test.el ends here
