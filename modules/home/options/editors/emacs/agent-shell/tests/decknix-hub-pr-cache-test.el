;;; decknix-hub-pr-cache-test.el --- Tests for hub PR cache persistence -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-pr-cache "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the PR cache module extracted from
;; the hub heredoc.  Exercises save / restore round-tripping, the
;; empty-cache no-op, the corrupt-file failure path, and the
;; defaults that other parts of the system rely on.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-pr-cache)

(defmacro decknix-hub-pr-cache-test--with-isolated-cache (&rest body)
  "Evaluate BODY with the cache hash + cache file both shadowed.
The file lives in a per-test mktemp dir so the user's
~/.config/decknix/hub/pr-cache.el is never touched."
  (declare (indent 0))
  `(let* ((tmp-dir (file-name-as-directory (make-temp-file "hub-pr-cache-" t)))
          (decknix--hub-pr-cache-file
           (expand-file-name "pr-cache.el" tmp-dir))
          (decknix--hub-pr-cache (make-hash-table :test 'equal)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p tmp-dir)
         (delete-directory tmp-dir t)))))

;; -- defaults ------------------------------------------------------

(ert-deftest decknix-hub-pr-cache--defaults ()
  "TTL constants match the documented contract."
  (should (= decknix--hub-pr-cache-ttl 180))
  (should (= decknix--hub-pr-cache-orphan-ttl 30))
  (should (hash-table-p decknix--hub-pr-cache))
  (should (hash-table-p decknix--hub-pr-pending-fetches))
  (should (string-match-p "/decknix/hub/pr-cache.el\\'"
                          decknix--hub-pr-cache-file)))

;; -- save no-ops ---------------------------------------------------

(ert-deftest decknix-hub-pr-cache--save-empty-noop ()
  "Saving an empty cache leaves no file behind (caller-friendly no-op)."
  (decknix-hub-pr-cache-test--with-isolated-cache
    (decknix--hub-pr-cache-save)
    (should-not (file-exists-p decknix--hub-pr-cache-file))))

;; -- save / restore round-trip ------------------------------------

(ert-deftest decknix-hub-pr-cache--save-then-restore-single ()
  "A single entry survives save + restore intact, including timestamp."
  (decknix-hub-pr-cache-test--with-isolated-cache
    (let* ((url "https://github.com/o/r/pull/1")
           (val (cons 1700000000.0 '((kind . wip) (state . "OPEN")))))
      (puthash url val decknix--hub-pr-cache)
      (decknix--hub-pr-cache-save)
      (should (file-exists-p decknix--hub-pr-cache-file))
      ;; Wipe the live hash, then restore from disk.
      (clrhash decknix--hub-pr-cache)
      (should (= (hash-table-count decknix--hub-pr-cache) 0))
      (decknix--hub-pr-cache-restore)
      (should (= (hash-table-count decknix--hub-pr-cache) 1))
      (let ((restored (gethash url decknix--hub-pr-cache)))
        (should (consp restored))
        (should (= (car restored) 1700000000.0))
        (should (equal (alist-get 'kind (cdr restored)) 'wip))
        (should (equal (alist-get 'state (cdr restored)) "OPEN"))))))

(ert-deftest decknix-hub-pr-cache--save-then-restore-many ()
  "Multiple entries all survive the round-trip."
  (decknix-hub-pr-cache-test--with-isolated-cache
    (puthash "https://github.com/o/r/pull/1"
             (cons 1.0 '((kind . wip)))
             decknix--hub-pr-cache)
    (puthash "https://github.com/o/r/pull/2"
             (cons 2.0 '((kind . review)))
             decknix--hub-pr-cache)
    (puthash "https://github.com/o/r/pull/3"
             (cons 3.0 '((kind . wip) (state . "MERGED")))
             decknix--hub-pr-cache)
    (decknix--hub-pr-cache-save)
    (clrhash decknix--hub-pr-cache)
    (decknix--hub-pr-cache-restore)
    (should (= (hash-table-count decknix--hub-pr-cache) 3))
    (should (equal (cdr (gethash "https://github.com/o/r/pull/2"
                                 decknix--hub-pr-cache))
                   '((kind . review))))))

;; -- restore failure paths ----------------------------------------

(ert-deftest decknix-hub-pr-cache--restore-missing-file-noop ()
  "Restoring with no file present is a silent no-op."
  (decknix-hub-pr-cache-test--with-isolated-cache
    ;; Pre-condition: file does not exist
    (should-not (file-exists-p decknix--hub-pr-cache-file))
    (decknix--hub-pr-cache-restore)
    (should (= (hash-table-count decknix--hub-pr-cache) 0))))

(ert-deftest decknix-hub-pr-cache--restore-malformed-file-graceful ()
  "Restoring a malformed cache file fails gracefully (no throw)."
  (decknix-hub-pr-cache-test--with-isolated-cache
    (make-directory (file-name-directory decknix--hub-pr-cache-file) t)
    (with-temp-file decknix--hub-pr-cache-file
      (insert "this is not a valid sexpr ((((\n"))
    ;; Should not throw.
    (decknix--hub-pr-cache-restore)
    ;; Cache stays empty since nothing parseable was loaded.
    (should (= (hash-table-count decknix--hub-pr-cache) 0))))

(ert-deftest decknix-hub-pr-cache--restore-non-list-graceful ()
  "Restoring a file containing a non-list value is a silent no-op."
  (decknix-hub-pr-cache-test--with-isolated-cache
    (make-directory (file-name-directory decknix--hub-pr-cache-file) t)
    (with-temp-file decknix--hub-pr-cache-file
      (insert "42\n"))
    (decknix--hub-pr-cache-restore)
    (should (= (hash-table-count decknix--hub-pr-cache) 0))))

;; -- save creates parent dir --------------------------------------

(ert-deftest decknix-hub-pr-cache--save-creates-parent-dir ()
  "Save creates the cache-file's parent directory if it doesn't exist."
  (decknix-hub-pr-cache-test--with-isolated-cache
    ;; Point the cache file deeper inside the tmp dir at a path
    ;; whose parent does not yet exist.
    (let ((decknix--hub-pr-cache-file
           (expand-file-name "deep/nested/pr-cache.el"
                             (file-name-directory
                              decknix--hub-pr-cache-file))))
      (should-not (file-directory-p (file-name-directory
                                     decknix--hub-pr-cache-file)))
      (puthash "https://github.com/o/r/pull/1"
               (cons 1.0 '((kind . wip)))
               decknix--hub-pr-cache)
      (decknix--hub-pr-cache-save)
      (should (file-directory-p (file-name-directory
                                 decknix--hub-pr-cache-file)))
      (should (file-exists-p decknix--hub-pr-cache-file)))))

(provide 'decknix-hub-pr-cache-test)
;;; decknix-hub-pr-cache-test.el ends here
