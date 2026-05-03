;;; decknix-hub-repo-cache-test.el --- Tests for hub repo cache persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-repo-cache "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the repo HEAD status cache module
;; extracted from the hub heredoc.  Direct parallel to
;; `decknix-hub-pr-cache-test' (PR B.24): same fixture pattern,
;; same coverage shape, but with the OWNER/REPO#BRANCH key shape
;; the repo cache uses instead of plain PR URLs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-repo-cache)

(defmacro decknix-hub-repo-cache-test--with-isolated-cache (&rest body)
  "Evaluate BODY with the cache hash + cache file both shadowed.
The file lives in a per-test mktemp dir so the user's
~/.config/decknix/hub/repo-cache.el is never touched."
  (declare (indent 0))
  `(let* ((tmp-dir (file-name-as-directory
                    (make-temp-file "hub-repo-cache-" t)))
          (decknix--hub-repo-cache-file
           (expand-file-name "repo-cache.el" tmp-dir))
          (decknix--hub-repo-cache (make-hash-table :test 'equal)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p tmp-dir)
         (delete-directory tmp-dir t)))))

;; -- defaults ------------------------------------------------------

(ert-deftest decknix-hub-repo-cache--defaults ()
  "TTL constant + defvar shapes match the documented contract.
The repo cache uses a longer TTL (300s = 5min) than the PR cache
(180s) because repo HEAD changes less often than PR review state."
  (should (= decknix--hub-repo-cache-ttl 300))
  (should (hash-table-p decknix--hub-repo-cache))
  (should (hash-table-p decknix--hub-repo-pending-fetches))
  (should (string-match-p "/decknix/hub/repo-cache.el\\'"
                          decknix--hub-repo-cache-file)))

;; -- save no-ops ---------------------------------------------------

(ert-deftest decknix-hub-repo-cache--save-empty-noop ()
  "Saving an empty cache leaves no file behind (caller-friendly no-op)."
  (decknix-hub-repo-cache-test--with-isolated-cache
    (decknix--hub-repo-cache-save)
    (should-not (file-exists-p decknix--hub-repo-cache-file))))

;; -- save / restore round-trip ------------------------------------

(ert-deftest decknix-hub-repo-cache--save-then-restore-single ()
  "A single entry survives save + restore intact, including timestamp."
  (decknix-hub-repo-cache-test--with-isolated-cache
    (let* ((key "decknix/decknix#main")
           (val (cons 1700000000.0
                      '((sha . "abc1234")
                        (state . "SUCCESS")))))
      (puthash key val decknix--hub-repo-cache)
      (decknix--hub-repo-cache-save)
      (should (file-exists-p decknix--hub-repo-cache-file))
      ;; Wipe the live hash, then restore from disk.
      (clrhash decknix--hub-repo-cache)
      (should (= (hash-table-count decknix--hub-repo-cache) 0))
      (decknix--hub-repo-cache-restore)
      (should (= (hash-table-count decknix--hub-repo-cache) 1))
      (let ((restored (gethash key decknix--hub-repo-cache)))
        (should (consp restored))
        (should (= (car restored) 1700000000.0))
        (should (equal (alist-get 'sha (cdr restored)) "abc1234"))
        (should (equal (alist-get 'state (cdr restored)) "SUCCESS"))))))

(ert-deftest decknix-hub-repo-cache--save-then-restore-many ()
  "Multiple entries (across different repos / branches) all survive."
  (decknix-hub-repo-cache-test--with-isolated-cache
    (puthash "decknix/decknix#main"
             (cons 1.0 '((sha . "aaa") (state . "SUCCESS")))
             decknix--hub-repo-cache)
    (puthash "decknix/decknix#feature-x"
             (cons 2.0 '((sha . "bbb") (state . "PENDING")))
             decknix--hub-repo-cache)
    (puthash "other/repo#main"
             (cons 3.0 '((sha . "ccc") (state . "FAILURE")))
             decknix--hub-repo-cache)
    (decknix--hub-repo-cache-save)
    (clrhash decknix--hub-repo-cache)
    (decknix--hub-repo-cache-restore)
    (should (= (hash-table-count decknix--hub-repo-cache) 3))
    (should (equal (cdr (gethash "decknix/decknix#feature-x"
                                 decknix--hub-repo-cache))
                   '((sha . "bbb") (state . "PENDING"))))))

;; -- restore failure paths ----------------------------------------

(ert-deftest decknix-hub-repo-cache--restore-missing-file-noop ()
  "Restoring with no file present is a silent no-op."
  (decknix-hub-repo-cache-test--with-isolated-cache
    (should-not (file-exists-p decknix--hub-repo-cache-file))
    (decknix--hub-repo-cache-restore)
    (should (= (hash-table-count decknix--hub-repo-cache) 0))))

(ert-deftest decknix-hub-repo-cache--restore-malformed-file-graceful ()
  "Restoring a malformed cache file fails gracefully (no throw)."
  (decknix-hub-repo-cache-test--with-isolated-cache
    (make-directory (file-name-directory
                     decknix--hub-repo-cache-file) t)
    (with-temp-file decknix--hub-repo-cache-file
      (insert "this is not a valid sexpr ((((\n"))
    (decknix--hub-repo-cache-restore)
    (should (= (hash-table-count decknix--hub-repo-cache) 0))))

(ert-deftest decknix-hub-repo-cache--restore-non-list-graceful ()
  "Restoring a file containing a non-list value is a silent no-op."
  (decknix-hub-repo-cache-test--with-isolated-cache
    (make-directory (file-name-directory
                     decknix--hub-repo-cache-file) t)
    (with-temp-file decknix--hub-repo-cache-file
      (insert "42\n"))
    (decknix--hub-repo-cache-restore)
    (should (= (hash-table-count decknix--hub-repo-cache) 0))))

;; -- save creates parent dir --------------------------------------

(ert-deftest decknix-hub-repo-cache--save-creates-parent-dir ()
  "Save creates the cache-file's parent directory if it doesn't exist."
  (decknix-hub-repo-cache-test--with-isolated-cache
    (let ((decknix--hub-repo-cache-file
           (expand-file-name "deep/nested/repo-cache.el"
                             (file-name-directory
                              decknix--hub-repo-cache-file))))
      (should-not (file-directory-p (file-name-directory
                                     decknix--hub-repo-cache-file)))
      (puthash "decknix/decknix#main"
               (cons 1.0 '((sha . "abc")))
               decknix--hub-repo-cache)
      (decknix--hub-repo-cache-save)
      (should (file-directory-p (file-name-directory
                                 decknix--hub-repo-cache-file)))
      (should (file-exists-p decknix--hub-repo-cache-file)))))

(provide 'decknix-hub-repo-cache-test)
;;; decknix-hub-repo-cache-test.el ends here
