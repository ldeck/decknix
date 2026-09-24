;;; decknix-review-threads-test.el --- Tests for review thread data -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Pure layers of step 4 of `specs/pr-review-in-emacs.md': parsing a GraphQL
;; page, and ordering threads for display.  The fixture is shaped like the real
;; response so a change to that shape fails here rather than silently yielding
;; no threads.

;;; Code:

(require 'ert)
(require 'decknix-review-threads)

(defun decknix-threads-test--page (nodes &optional has-next cursor)
  "Wrap NODES in the GraphQL envelope the real query returns."
  `((data
     . ((repository
         . ((pullRequest
             . ((reviewThreads
                 . ((pageInfo . ((hasNextPage . ,(if has-next t :json-false))
                                 (endCursor . ,(or cursor "CUR"))))
                    (nodes . ,nodes)))))))))))

(defun decknix-threads-test--node (&rest overrides)
  "A thread node with sensible defaults, plus OVERRIDES."
  (append overrides
          `((id . "PRRT_1") (isResolved . :json-false) (isOutdated . :json-false)
            (path . "flake.nix") (line . 34) (originalLine . 30)
            (diffSide . "RIGHT")
            (comments . ((nodes . (((databaseId . 1)
                                    (author . ((login . "augmentcode[bot]")))
                                    (body . "fix: values are type strings")
                                    (createdAt . "2026-09-24T08:41:00Z")))))))))

;; --- parsing ----------------------------------------------------------

(ert-deftest decknix-threads-parse--reads-the-real-envelope ()
  "A page parses into threads plus its pagination state."
  (let* ((parsed (decknix-review-threads-parse-page
                  (decknix-threads-test--page
                   (list (decknix-threads-test--node)) t "ABC")))
         (threads (nth 0 parsed)))
    (should (= 1 (length threads)))
    (should (nth 1 parsed))
    (should (equal "ABC" (nth 2 parsed)))
    (should (equal "flake.nix" (plist-get (car threads) :path)))
    (should (equal 34 (plist-get (car threads) :line)))
    (should-not (plist-get (car threads) :resolved))))

(ert-deftest decknix-threads-parse--carries-the-conversation ()
  "Every comment is kept, in order, with author and body.
The whole point of the surface is reading the conversation rather than the
last comment, which is all the glyph counts ever needed."
  (let* ((node (decknix-threads-test--node
                '(comments . ((nodes . (((databaseId . 1)
                                          (author . ((login . "augmentcode[bot]")))
                                          (body . "first")
                                          (createdAt . "2026-09-24T08:41:00Z"))
                                         ((databaseId . 2)
                                          (author . ((login . "ldeck")))
                                          (body . "second")
                                          (createdAt . "2026-09-24T08:46:00Z"))))))))
         (thread (car (nth 0 (decknix-review-threads-parse-page
                              (decknix-threads-test--page (list node)))))))
    (should (equal '("first" "second")
                   (mapcar (lambda (c) (plist-get c :body))
                           (plist-get thread :comments))))
    (should (equal "ldeck" (plist-get thread :last-author)))
    (should (equal '("augmentcode[bot]" "ldeck") (plist-get thread :authors)))))

(ert-deftest decknix-threads-parse--outdated-falls-back-to-original-line ()
  "An outdated thread keeps a location.
GitHub returns `line' nil once the line it referred to has gone, and a
thread rendering with no location at all reads as a bare comment."
  (let* ((node (decknix-threads-test--node '(isOutdated . t) '(line . nil)))
         (thread (car (nth 0 (decknix-review-threads-parse-page
                              (decknix-threads-test--page (list node)))))))
    (should (plist-get thread :outdated))
    (should (equal 30 (plist-get thread :line)))
    (should-not (plist-get thread :line-current))))

(ert-deftest decknix-threads-parse--failure-is-nil-not-empty ()
  "An error payload or unexpected shape must NOT read as \"no threads\".

Reporting a PR as having no review threads when the query actually failed
is the worse of the two mistakes: it looks like a clean PR."
  (should-not (decknix-review-threads-parse-page nil))
  (should-not (decknix-review-threads-parse-page
               '((errors . (((message . "Bad credentials")))))))
  (should-not (decknix-review-threads-parse-page '((data . ((repository . nil))))))
  ;; A genuinely empty page still parses, with an empty thread list.
  (let ((parsed (decknix-review-threads-parse-page
                 (decknix-threads-test--page nil))))
    (should parsed)
    (should-not (nth 0 parsed))
    (should-not (nth 1 parsed))))

;; --- actionability ----------------------------------------------------

(ert-deftest decknix-threads-actionable--unresolved-and-current ()
  "Only an unresolved, non-outdated thread wants something."
  (should (decknix-review-threads-actionable-p '(:resolved nil :outdated nil)))
  (should-not (decknix-review-threads-actionable-p '(:resolved t :outdated nil)))
  (should-not (decknix-review-threads-actionable-p '(:resolved nil :outdated t)))
  (should-not (decknix-review-threads-actionable-p nil)))

;; --- grouping ---------------------------------------------------------

(ert-deftest decknix-threads-group--files-with-work-come-first ()
  "The reason to open this surface is to find what needs answering."
  (let* ((resolved '(:path "a-first-alphabetically.nix" :line 1 :resolved t))
         (open '(:path "z-last-alphabetically.nix" :line 1 :resolved nil))
         (grouped (decknix-review-threads-group-by-file (list resolved open))))
    (should (equal "z-last-alphabetically.nix" (car (nth 0 grouped))))
    (should (equal "a-first-alphabetically.nix" (car (nth 1 grouped))))))

(ert-deftest decknix-threads-group--threads-sort-by-line-within-a-file ()
  "Threads read in diff order, not the order GitHub returned them."
  (let* ((threads '((:path "f.nix" :line 40 :resolved nil)
                    (:path "f.nix" :line 12 :resolved nil)
                    (:path "f.nix" :line 31 :resolved nil)))
         (grouped (decknix-review-threads-group-by-file threads)))
    (should (equal '(12 31 40)
                   (mapcar (lambda (t*) (plist-get t* :line)) (cdr (car grouped)))))))

(ert-deftest decknix-threads-group--ties-break-on-path-for-stability ()
  "Two files with equal disposition order deterministically.
Depending on GitHub's return order would reshuffle the buffer between
refreshes."
  (let ((grouped (decknix-review-threads-group-by-file
                  '((:path "zebra.nix" :line 1 :resolved nil)
                    (:path "alpha.nix" :line 1 :resolved nil)))))
    (should (equal '("alpha.nix" "zebra.nix") (mapcar #'car grouped)))))

(ert-deftest decknix-threads-group--handles-a-missing-path ()
  "A thread with no path is grouped rather than dropped."
  (let ((grouped (decknix-review-threads-group-by-file
                  '((:path nil :line 1 :resolved nil)))))
    (should (= 1 (length grouped)))
    (should (equal "" (car (car grouped))))))

(ert-deftest decknix-threads-group--empty-input ()
  "No threads yields no groups rather than signalling."
  (should-not (decknix-review-threads-group-by-file nil)))

;; --- summary ----------------------------------------------------------

(ert-deftest decknix-threads-summary--counts-by-disposition ()
  "Outdated-but-unresolved is counted separately from actionable."
  (let ((summary (decknix-review-threads-summary
                  '((:resolved nil :outdated nil)
                    (:resolved nil :outdated nil)
                    (:resolved t :outdated nil)
                    (:resolved nil :outdated t)))))
    (should (equal 4 (plist-get summary :total)))
    (should (equal 2 (plist-get summary :actionable)))
    (should (equal 1 (plist-get summary :resolved)))
    (should (equal 1 (plist-get summary :outdated)))))

(provide 'decknix-review-threads-test)
;;; decknix-review-threads-test.el ends here
