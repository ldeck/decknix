;;; decknix-board-backend.el --- Issue backends for coordination boards -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, decknix, board

;;; Commentary:
;;
;; The seam between a coordination board and wherever its work items
;; live.  A board names a backend symbol (`github' today); each backend
;; implements the generics below with an `eql' specialiser.  Jira and
;; taskwarrior are meant to slot in here without the board UI changing.
;;
;; Every backend speaks one item shape, a plist:
;;
;;   :number    stable key within the backend (issue number)
;;   :title :url :body (excerpt) :state ("open" / "closed")
;;   :type      "goal" "epic" "story" "task" "subtask", or nil
;;   :parent    parent :number, or nil
;;   :labels :assignees (lists of strings)
;;   :prs       list of (:number :url :state :draft)
;;   :id        backend-native id, needed to link children
;;
;; Subprocesses go through `decknix-board-process-function', never
;; `make-process' directly, so the tests can record the exact commands a
;; create would run and prove nothing external happens without consent.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst decknix-board-types '("goal" "epic" "story" "task" "subtask")
  "Item types, outermost first.  The order is the hierarchy.")

(defun decknix-board-type-rank (type)
  "Return TYPE's depth in `decknix-board-types', or one past the end."
  (or (seq-position decknix-board-types type)
      (length decknix-board-types)))

(defun decknix-board-child-type (type)
  "Return the type a child of a TYPE item defaults to."
  (or (nth (1+ (decknix-board-type-rank type)) decknix-board-types)
      "subtask"))

;; --- subprocesses --------------------------------------------------------

(defvar decknix-board-process-function #'decknix-board--make-process
  "Function (ARGV CALLBACK) that runs ARGV asynchronously.
CALLBACK receives (EXIT-CODE STDOUT STDERR) when it finishes.  Tests bind
this to a recorder.")

(defun decknix-board--make-process (argv callback)
  "Run ARGV in a background process; call CALLBACK with its results.
Stdout and stderr are kept apart because stdout is parsed as JSON and
`gh' writes its diagnostics to stderr."
  (let ((out (generate-new-buffer " *decknix-board-out*"))
        (err (generate-new-buffer " *decknix-board-err*")))
    (condition-case e
        (make-process
         :name "decknix-board" :buffer out :stderr err :noquery t
         :connection-type 'pipe
         :command argv
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (let ((stdout (with-current-buffer out (buffer-string)))
                   (stderr (if (buffer-live-p err)
                               (with-current-buffer err (buffer-string))
                             "")))
               (kill-buffer out)
               (when (buffer-live-p err) (kill-buffer err))
               (funcall callback (process-exit-status proc) stdout stderr)))))
      (error
       (kill-buffer out) (kill-buffer err)
       (funcall callback 127 "" (error-message-string e))
       nil))))

(defun decknix-board-run (argv callback)
  "Run ARGV via `decknix-board-process-function', then CALLBACK."
  (funcall decknix-board-process-function argv callback))

;; --- the interface -------------------------------------------------------

(cl-defgeneric decknix-board-backend-list-items (backend board callback)
  "Fetch BOARD's items from BACKEND without blocking.
Call CALLBACK with (ITEMS . META).  META is a plist: `:hierarchy' is
non-nil when items carry real parent links, `:error' a message when the
fetch failed (ITEMS is then nil).")

(cl-defgeneric decknix-board-backend-create-item (backend board spec callback)
  "Create an item in BACKEND for BOARD from SPEC.
SPEC is a plist (:type :title :body :parent PARENT-ITEM).  This is an
external write: callers confirm with the user first.  CALLBACK receives
the new item's URL, or nil and an error message.")

(cl-defgeneric decknix-board-backend-item-url (backend board item)
  "Return the URL that shows ITEM of BOARD in BACKEND.")

(cl-defgeneric decknix-board-backend-tag-prefix (backend board)
  "Return the prefix of BOARD's item tags in BACKEND, e.g. a repo name.")

(cl-defgeneric decknix-board-backend-describe (backend board)
  "Return a short human label for where BOARD's items live in BACKEND.")

(cl-defmethod decknix-board-backend-item-url (_backend _board item)
  "Default: the URL the backend reported for ITEM."
  (plist-get item :url))

(provide 'decknix-board-backend)
;;; decknix-board-backend.el ends here
