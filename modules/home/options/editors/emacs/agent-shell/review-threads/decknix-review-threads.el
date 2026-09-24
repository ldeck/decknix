;;; decknix-review-threads.el --- Review threads as data -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, review

;;; Commentary:
;;
;; Step 4 of `specs/pr-review-in-emacs.md': review threads with enough detail
;; to render, navigate and reply to, rather than the counts the sidebar glyphs
;; need.
;;
;; The unit is a THREAD, not a comment.  A thread has a file, a line, a
;; resolution state and an ordered conversation, and that is what a reviewer
;; acts on: you answer a thread, you resolve a thread.  Modelling comments
;; individually loses the only grouping that matters.
;;
;; Pure layers only, per AGENTS.md Rule 2: parsing a GraphQL page, stitching
;; pages together, and ordering for display.  The `gh api' call and the
;; rendering live outside.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst decknix-review-threads-page-size 100
  "Threads requested per GraphQL page.

`reviewThreads(first: 100)' unpaginated was adequate for the glyph counts,
which only needed a total, and is not adequate here: a large PR would
render a silently truncated conversation, which is worse than refusing to
render one.")

(defconst decknix-review-threads-query
  "query($owner:String!,$repo:String!,$pr:Int!,$size:Int!,$after:String){
     repository(owner:$owner,name:$repo){
       pullRequest(number:$pr){
         reviewThreads(first:$size, after:$after){
           pageInfo{ hasNextPage endCursor }
           nodes{
             id isResolved isOutdated path line originalLine diffSide
             comments(first:100){
               nodes{ databaseId author{login} body createdAt }
             }
           }
         }
       }
     }
   }"
  "Thread query carrying enough to render, jump and reply.")


;; --- parsing one page -------------------------------------------------

(defun decknix-review-threads--comment (node)
  "Return a comment plist from GraphQL NODE."
  (list :id (alist-get 'databaseId node)
        :author (alist-get 'login (alist-get 'author node))
        :body (or (alist-get 'body node) "")
        :created (alist-get 'createdAt node)))

(defun decknix-review-threads--thread (node)
  "Return a thread plist from GraphQL NODE.

`line' is nil on an OUTDATED thread, because the line it referred to no
longer exists in the diff.  `originalLine' is kept so such a thread can
still say where it was raised instead of rendering as a bare comment with
no location."
  (let* ((comments (mapcar #'decknix-review-threads--comment
                           (alist-get 'nodes (alist-get 'comments node))))
         (authors (delete-dups (delq nil (mapcar (lambda (c) (plist-get c :author))
                                                 comments)))))
    (list :id (alist-get 'id node)
          :resolved (eq (alist-get 'isResolved node) t)
          :outdated (eq (alist-get 'isOutdated node) t)
          :path (alist-get 'path node)
          :line (or (alist-get 'line node) (alist-get 'originalLine node))
          :line-current (alist-get 'line node)
          :side (alist-get 'diffSide node)
          :comments comments
          :authors authors
          :last-author (plist-get (car (last comments)) :author))))

(defun decknix-review-threads-parse-page (response)
  "Return (THREADS HAS-NEXT CURSOR) from a GraphQL RESPONSE alist.

Returns nil when RESPONSE carries no thread container at all, which is how
an error payload or an unexpected shape arrives.  Callers must treat that
as a failure rather than as \"no threads\": reporting a PR as having no
review threads when the query actually failed is the worse of the two
mistakes."
  (let* ((threads-node (thread-last response
                         (alist-get 'data)
                         (alist-get 'repository)
                         (alist-get 'pullRequest)
                         (alist-get 'reviewThreads))))
    (when threads-node
      (let ((page (alist-get 'pageInfo threads-node)))
        (list (mapcar #'decknix-review-threads--thread
                      (alist-get 'nodes threads-node))
              (eq (alist-get 'hasNextPage page) t)
              (alist-get 'endCursor page))))))


;; --- ordering for display --------------------------------------------

(defun decknix-review-threads-actionable-p (thread)
  "Return non-nil when THREAD still wants something from the reader.
Unresolved and not outdated.  An outdated thread is history: the code it
was raised against is gone, so there is nothing to answer."
  (and thread
       (not (plist-get thread :resolved))
       (not (plist-get thread :outdated))))

(defun decknix-review-threads-group-by-file (threads)
  "Return ((PATH . THREADS) ...) with actionable files first.

Within a file, threads sort by line so they read in the order they appear
in the diff.  Files carrying actionable threads come first, because the
reason to open this surface is to find what still needs answering; a file
whose threads are all resolved is reference material.  Ties break on path
so the order is stable between refreshes rather than dependent on the
order GitHub returned."
  (let ((by-path (make-hash-table :test 'equal))
        paths)
    (dolist (thread threads)
      (let ((path (or (plist-get thread :path) "")))
        (unless (gethash path by-path) (push path paths))
        (puthash path (cons thread (gethash path by-path)) by-path)))
    (let ((entries
           (mapcar (lambda (path)
                     (cons path
                           (sort (nreverse (gethash path by-path))
                                 (lambda (a b)
                                   (< (or (plist-get a :line) 0)
                                      (or (plist-get b :line) 0))))))
                   (nreverse paths))))
      (sort entries
            (lambda (a b)
              (let ((aa (seq-some #'decknix-review-threads-actionable-p (cdr a)))
                    (ba (seq-some #'decknix-review-threads-actionable-p (cdr b))))
                (cond ((and aa (not ba)) t)
                      ((and ba (not aa)) nil)
                      (t (string< (car a) (car b))))))))))

(defun decknix-review-threads-summary (threads)
  "Return a plist counting THREADS by disposition."
  (list :total (length threads)
        :actionable (length (seq-filter #'decknix-review-threads-actionable-p threads))
        :resolved (length (seq-filter (lambda (t*) (plist-get t* :resolved)) threads))
        :outdated (length (seq-filter (lambda (t*)
                                        (and (plist-get t* :outdated)
                                             (not (plist-get t* :resolved))))
                                      threads))))

(provide 'decknix-review-threads)
;;; decknix-review-threads.el ends here
