;;; decknix-review-board-prcache.el --- What the board knows about a PR after it leaves the feed -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, review, board

;;; Commentary:
;;
;; A PR that merges or closes leaves the reviews feed, and with it went
;; everything the board could say about it: its title, its author, and
;; whether it merged or was closed.  Those are exactly the rows of the
;; Obsolete lane, so that lane read as a list of bare `repo#N' keys.
;;
;; This keeps, per PR key, what the feed last said (title, author, url,
;; created, updated) and, once the PR has gone, its final state from ONE
;; background `gh pr view --json state,mergedAt,closedAt'.  A merged or
;; closed state never changes, so it is asked once and kept for good; a PR
;; that turns out to be still open (it left the queue because the review
;; request was withdrawn) is asked again after an hour.
;;
;; Rendering reads only the in-memory table.  The file is read once, on
;; first use, and written only when something changed, from an idle timer.

;;; Code:

(require 'map)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'decknix-state-io)

(defvar decknix-review-board-prcache-file
  (expand-file-name "~/.local/state/decknix/review-board-prs.eld")
  "Where the per-PR cache persists.")

(defvar decknix-review-board-prcache-max-concurrent 2
  "How many `gh' state lookups may run at once.")

(defvar decknix-review-board-prcache-recheck-open 3600
  "Seconds before a PR found still open is asked about again.")

(defvar decknix-review-board-prcache-retry-failed 600
  "Seconds before a lookup that failed is tried again.
Without it a repo `gh' cannot read would be asked about on every repaint.")

(defvar decknix-review-board-prcache-changed-function nil
  "Function called with no arguments after a lookup changed an entry.
The board sets it to schedule a repaint.")

(defvar decknix-review-board-prcache-process-function #'make-process
  "Starts a lookup's process; tests replace it.  Called like `make-process'.")

(defvar decknix-review-board-prcache--table nil
  "PR key -> entry plist, or nil until loaded.")

(defvar decknix-review-board-prcache--dirty nil
  "Non-nil when the table has changes not yet written.")

(defvar decknix-review-board-prcache--save-timer nil
  "Pending idle save, or nil.")

(defvar decknix-review-board-prcache--inflight nil
  "PR keys with a lookup running.")

(defvar decknix-review-board-prcache--queue nil
  "Pending lookups, as (KEY . URL), oldest first.")

(defconst decknix-review-board-prcache-fields
  '((title . :title) (author . :author) (author_kind . :author-kind)
    (url . :url) (created . :created) (updated . :updated) (repo . :repo))
  "Feed field -> entry key, for what the board shows once the PR has gone.")

;; ── table ────────────────────────────────────────────────────────────

(defun decknix-review-board-prcache--entry-p (entry)
  "Non-nil when ENTRY is a well-formed (KEY . PLIST) store element."
  (and (consp entry) (stringp (car entry)) (listp (cdr entry))))

(defun decknix-review-board-prcache--ensure ()
  "Return the table, reading the file the first time."
  (or decknix-review-board-prcache--table
      (let ((table (make-hash-table :test 'equal)))
        (dolist (entry (ignore-errors
                         (decknix-state-io-read-list
                          decknix-review-board-prcache-file
                          #'decknix-review-board-prcache--entry-p)))
          (puthash (car entry) (cdr entry) table))
        (setq decknix-review-board-prcache--table table))))

(defun decknix-review-board-prcache-get (key)
  "Return the cached entry plist for PR KEY (`repo#N'), or nil."
  (and (stringp key) (gethash key (decknix-review-board-prcache--ensure))))

(defun decknix-review-board-prcache-merge (entry item)
  "Return ENTRY updated with ITEM's feed fields, and whether it changed.  Pure.
As (NEW-ENTRY . CHANGED).  A field the feed leaves empty keeps its old
value, so a partial feed never erases what a fuller one said."
  (let ((new (copy-sequence entry))
        (changed nil))
    (dolist (field decknix-review-board-prcache-fields)
      (let ((value (map-elt item (car field))))
        (when (and value (not (equal value ""))
                   (not (equal value (plist-get new (cdr field)))))
          (setq new (plist-put new (cdr field) value)
                changed t))))
    (cons new changed)))

(defun decknix-review-board-prcache-learn (items key-fn)
  "Record what the feed says about each of ITEMS, keyed by KEY-FN.
Marks the table dirty and schedules a save only when something changed,
so the usual refresh, where nothing did, costs a hash lookup per item."
  (let ((table (decknix-review-board-prcache--ensure)))
    (dolist (item items)
      (when-let* ((key (funcall key-fn item)))
        (let ((merged (decknix-review-board-prcache-merge (gethash key table) item)))
          (when (cdr merged)
            (puthash key (car merged) table)
            (setq decknix-review-board-prcache--dirty t)))))
    (when decknix-review-board-prcache--dirty
      (decknix-review-board-prcache--schedule-save))))

(defun decknix-review-board-prcache--put (key &rest props)
  "Set PROPS on KEY's entry and mark the table dirty."
  (let* ((table (decknix-review-board-prcache--ensure))
         (entry (copy-sequence (gethash key table))))
    (while props
      (setq entry (plist-put entry (pop props) (pop props))))
    (puthash key entry table)
    (setq decknix-review-board-prcache--dirty t)
    (decknix-review-board-prcache--schedule-save)))

;; ── persistence ──────────────────────────────────────────────────────

(defun decknix-review-board-prcache-save ()
  "Write the table when it has changed.  Whole, via a temporary file."
  (setq decknix-review-board-prcache--save-timer nil)
  (when (and decknix-review-board-prcache--dirty decknix-review-board-prcache--table)
    (let ((file decknix-review-board-prcache-file)
          (entries nil))
      (maphash (lambda (k v) (push (cons k v) entries))
               decknix-review-board-prcache--table)
      (make-directory (file-name-directory file) t)
      (let ((tmp (make-temp-file (expand-file-name ".prcache" (file-name-directory file)))))
        (with-temp-file tmp
          (decknix-state-io-prin1 (sort entries (lambda (a b) (string< (car a) (car b))))
                                  (current-buffer)))
        (rename-file tmp file t))
      (setq decknix-review-board-prcache--dirty nil))))

(defun decknix-review-board-prcache--schedule-save ()
  "Save on the next idle moment, once however many changes arrive."
  (unless (timerp decknix-review-board-prcache--save-timer)
    (setq decknix-review-board-prcache--save-timer
          (run-with-idle-timer 2 nil #'decknix-review-board-prcache-save))))

;; ── final state of a PR that has gone ───────────────────────────────

(defun decknix-review-board-prcache-state-label (entry)
  "Return `merged', `closed' or `open' for ENTRY's state, or nil.  Pure."
  (pcase (plist-get entry :state)
    ("MERGED" "merged")
    ("CLOSED" "closed")
    ("OPEN" "open")
    (_ nil)))

(defun decknix-review-board-prcache-gone-time (entry)
  "Return when ENTRY's PR merged or closed, as a float time, or nil.  Pure."
  (when-let* ((ts (or (plist-get entry :merged-at) (plist-get entry :closed-at)))
              ((stringp ts))
              ((not (string-empty-p ts))))
    (ignore-errors (float-time (date-to-time ts)))))

(defun decknix-review-board-prcache-needs-state-p (entry &optional now)
  "Non-nil when ENTRY's final state should be asked for.  Pure.
Never again once merged or closed; after an hour when last seen open;
not within `decknix-review-board-prcache-retry-failed' of a failed try."
  (let ((now (or now (float-time))))
    (pcase (plist-get entry :state)
      ((or "MERGED" "CLOSED") nil)
      ("OPEN" (> (- now (or (plist-get entry :checked) 0))
                 decknix-review-board-prcache-recheck-open))
      (_ (> (- now (or (plist-get entry :failed-at) 0))
            decknix-review-board-prcache-retry-failed)))))

(defun decknix-review-board-prcache-parse-state (json-text)
  "Return (:state S :merged-at M :closed-at C) from `gh' JSON-TEXT, or nil.
Pure.  Nil for anything that is not an object with a state, so a failed
lookup leaves the entry to be asked again rather than recording junk."
  (when-let* ((obj (ignore-errors (json-parse-string json-text :object-type 'alist
                                                     :null-object nil)))
              ((listp obj))
              (state (alist-get 'state obj))
              ((stringp state)))
    (list :state state
          :merged-at (alist-get 'mergedAt obj)
          :closed-at (alist-get 'closedAt obj))))

(defun decknix-review-board-prcache-request-state (key url)
  "Ask, in the background, whether PR KEY at URL merged or closed.
At most once per KEY at a time and only when the cache says it is worth
asking (`decknix-review-board-prcache-needs-state-p').  Returns non-nil
when a lookup was queued or started."
  (when (and (stringp key) (stringp url)
             (decknix-review-board-prcache-needs-state-p
              (decknix-review-board-prcache-get key))
             (not (member key decknix-review-board-prcache--inflight))
             (not (assoc key decknix-review-board-prcache--queue)))
    (setq decknix-review-board-prcache--queue
          (append decknix-review-board-prcache--queue (list (cons key url))))
    (decknix-review-board-prcache--pump)
    t))

(defun decknix-review-board-prcache--pump ()
  "Start queued lookups up to the concurrency cap."
  (while (and decknix-review-board-prcache--queue
              (< (length decknix-review-board-prcache--inflight)
                 decknix-review-board-prcache-max-concurrent))
    (let ((job (pop decknix-review-board-prcache--queue)))
      (decknix-review-board-prcache--start (car job) (cdr job)))))

(defun decknix-review-board-prcache--start (key url)
  "Run `gh pr view' for PR KEY at URL in a child process."
  (if (not (executable-find "gh"))
      nil
    (push key decknix-review-board-prcache--inflight)
    (let ((out (generate-new-buffer " *review-board-prcache*")))
      (condition-case err
          (funcall decknix-review-board-prcache-process-function
                   :name "review-board-prcache"
                   :buffer out
                   :command (list "gh" "pr" "view" url "--json" "state,mergedAt,closedAt")
                   :connection-type 'pipe
                   :noquery t
                   :stderr (get-buffer-create " *review-board-prcache-err*")
                   :sentinel (lambda (proc _event)
                               (unless (process-live-p proc)
                                 (decknix-review-board-prcache--finish
                                  key (process-exit-status proc) out))))
        (error
         (setq decknix-review-board-prcache--inflight
               (delete key decknix-review-board-prcache--inflight))
         (kill-buffer out)
         (message "Review Board: could not ask about %s: %s"
                  key (error-message-string err)))))))

(defun decknix-review-board-prcache--finish (key status out)
  "Record the lookup for KEY that exited with STATUS, its output in OUT."
  (setq decknix-review-board-prcache--inflight
        (delete key decknix-review-board-prcache--inflight))
  (let ((parsed (and (eql status 0) (buffer-live-p out)
                     (decknix-review-board-prcache-parse-state
                      (with-current-buffer out (buffer-string))))))
    (when (buffer-live-p out) (kill-buffer out))
    (unless parsed
      (decknix-review-board-prcache--put key :failed-at (float-time)))
    (when parsed
      (apply #'decknix-review-board-prcache--put key :checked (float-time) parsed)
      (when decknix-review-board-prcache-changed-function
        (with-demoted-errors "Review Board repaint after a PR lookup: %S"
          (funcall decknix-review-board-prcache-changed-function)))))
  (decknix-review-board-prcache--pump))

(provide 'decknix-review-board-prcache)
;;; decknix-review-board-prcache.el ends here
