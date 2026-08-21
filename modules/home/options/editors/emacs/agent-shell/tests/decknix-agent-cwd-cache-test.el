;;; decknix-agent-cwd-cache-test.el --- Tests for the CWD cache -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-cwd-cache "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the per-directory CWD cache.  The
;; resolver is injected, so these pin the caching contract (including
;; that a nil result is cached -- the whole point, since "no project
;; root" is the expensive answer) without touching the filesystem or
;; project.el.

;;; Code:

(require 'ert)
(require 'decknix-agent-cwd-cache)

(defun decknix-agent-cwd-test--counter ()
  "Return (COUNTER-FN . CELL) where CELL's car counts invocations."
  (let ((cell (list 0)))
    (cons (lambda (dir)
            (setcar cell (1+ (car cell)))
            (concat dir "resolved/"))
          cell)))

(defmacro decknix-agent-cwd-test--with-fresh-cache (&rest body)
  "Run BODY against an empty cache."
  `(let ((decknix-agent-cwd--cache (make-hash-table :test 'equal)))
     ,@body))

(ert-deftest decknix-agent-cwd-cached-resolves-on-miss-test ()
  "A cold lookup calls the resolver and returns its value."
  (decknix-agent-cwd-test--with-fresh-cache
   (let* ((pair (decknix-agent-cwd-test--counter))
          (fn (car pair)) (cell (cdr pair)))
     (should (equal (decknix-agent-cwd-cached "/a/" fn) "/a/resolved/"))
     (should (equal (car cell) 1)))))

(ert-deftest decknix-agent-cwd-cached-hits-on-second-call-test ()
  "A repeat lookup for the same directory does not call the resolver."
  (decknix-agent-cwd-test--with-fresh-cache
   (let* ((pair (decknix-agent-cwd-test--counter))
          (fn (car pair)) (cell (cdr pair)))
     (decknix-agent-cwd-cached "/a/" fn)
     (decknix-agent-cwd-cached "/a/" fn)
     (decknix-agent-cwd-cached "/a/" fn)
     (should (equal (car cell) 1)))))

(ert-deftest decknix-agent-cwd-cached-separates-directories-test ()
  "Distinct directories get distinct entries."
  (decknix-agent-cwd-test--with-fresh-cache
   (let* ((pair (decknix-agent-cwd-test--counter))
          (fn (car pair)) (cell (cdr pair)))
     (should (equal (decknix-agent-cwd-cached "/a/" fn) "/a/resolved/"))
     (should (equal (decknix-agent-cwd-cached "/b/" fn) "/b/resolved/"))
     (should (equal (car cell) 2))
     (should (equal (decknix-agent-cwd-cache-size) 2)))))

(ert-deftest decknix-agent-cwd-cached-caches-nil-result-test ()
  "A nil resolution is cached -- it is the expensive answer, not a miss.
Regression guard: a `gethash' without a distinct sentinel would read a
cached nil as absent and re-run the walk-to-root every call."
  (decknix-agent-cwd-test--with-fresh-cache
   (let* ((calls 0)
          (fn (lambda (_dir) (setq calls (1+ calls)) nil)))
     (should (null (decknix-agent-cwd-cached "/no-project/" fn)))
     (should (null (decknix-agent-cwd-cached "/no-project/" fn)))
     (should (null (decknix-agent-cwd-cached "/no-project/" fn)))
     (should (equal calls 1)))))

(ert-deftest decknix-agent-cwd-cached-passes-nil-dir-through-test ()
  "A nil directory is not cacheable and is handed straight to the resolver."
  (decknix-agent-cwd-test--with-fresh-cache
   (let* ((calls 0)
          (fn (lambda (_dir) (setq calls (1+ calls)) "x")))
     (should (equal (decknix-agent-cwd-cached nil fn) "x"))
     (should (equal (decknix-agent-cwd-cached nil fn) "x"))
     (should (equal calls 2))
     (should (equal (decknix-agent-cwd-cache-size) 0)))))

(ert-deftest decknix-agent-cwd-cache-clear-test ()
  "Clearing forces the next lookup to resolve again."
  (decknix-agent-cwd-test--with-fresh-cache
   (let* ((pair (decknix-agent-cwd-test--counter))
          (fn (car pair)) (cell (cdr pair)))
     (decknix-agent-cwd-cached "/a/" fn)
     (decknix-agent-cwd-cache-clear)
     (should (equal (decknix-agent-cwd-cache-size) 0))
     (decknix-agent-cwd-cached "/a/" fn)
     (should (equal (car cell) 2)))))

(ert-deftest decknix-agent-cwd-cache-respects-limit-test ()
  "Reaching the limit clears the cache rather than growing without bound.
The clear trips on the insert made once the count has REACHED the limit,
so with a limit of 2 the third distinct directory is the one that wipes."
  (decknix-agent-cwd-test--with-fresh-cache
   (let* ((decknix-agent-cwd-cache-limit 2)
          (pair (decknix-agent-cwd-test--counter))
          (fn (car pair)))
     (decknix-agent-cwd-cached "/a/" fn)
     (decknix-agent-cwd-cached "/b/" fn)
     (should (equal (decknix-agent-cwd-cache-size) 2))
     ;; At the limit: this insert clears first, then lands on its own.
     (should (equal (decknix-agent-cwd-cached "/c/" fn) "/c/resolved/"))
     (should (equal (decknix-agent-cwd-cache-size) 1))
     ;; ...and the wiped entries genuinely resolve again.
     (let ((before (car (cdr pair))))
       (decknix-agent-cwd-cached "/a/" fn)
       (should (> (car (cdr pair)) before))))))

(ert-deftest decknix-agent-cwd-resolve-uses-default-directory-test ()
  "The hook resolves `default-directory' and caches under that key."
  (decknix-agent-cwd-test--with-fresh-cache
   (let ((default-directory "/tmp/decknix-cwd-test/"))
     ;; No project anywhere above a non-existent tmp path: falls back to
     ;; the directory itself, and the answer is memoised.
     (should (equal (decknix-agent-cwd-resolve) "/tmp/decknix-cwd-test/"))
     (should (equal (decknix-agent-cwd-cache-size) 1))
     (should (equal (decknix-agent-cwd-resolve) "/tmp/decknix-cwd-test/"))
     (should (equal (decknix-agent-cwd-cache-size) 1)))))

(provide 'decknix-agent-cwd-cache-test)
;;; decknix-agent-cwd-cache-test.el ends here
