;;; decknix-priority.el --- Ranked lane-based work view -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, hub, priority

;;; Commentary:
;;
;; A ranked, lane-based "what should I do next?" view over the hub's
;; existing data.  Four ordered lanes, highest-leverage first:
;;
;;   Discussions -> Reviews -> Tasks -> Queue
;;
;; The decision layer (lane classification, stable keys, age, ranking,
;; the `collect' aggregator) is pure and side-effect free, taking the
;; parsed hub wrappers as arguments so it is fully unit-testable.  The
;; renderer (a standalone read-only `*Agent Priority*' buffer) reads the
;; live hub defvars via `bound-and-true-p' so this package carries no
;; hard dependency on the hub module.  Phase 1 of issue #142 — existing
;; sources only, additive (no change to the main sidebar render path).

;;; Code:

(require 'seq)

(defconst decknix-priority-lanes '(discussions reviews tasks queue)
  "Ordered lanes, highest leverage first.")

(defun decknix-priority-lane-label (lane)
  "Return the display label for LANE."
  (pcase lane
    ('discussions "Discussions")
    ('reviews     "Reviews")
    ('tasks       "Tasks")
    ('queue       "Queue")
    (_            (format "%s" lane))))

;; -- Lane classification (pure) -------------------------------------

(defun decknix-priority-review-lane (item)
  "Lane for a review request ITEM: `discussions' if a human awaits my
reply, else `reviews'."
  (if (alist-get 'replies_to_me item) 'discussions 'reviews))

(defun decknix-priority-wip-lane (pr)
  "Lane for a WIP PR: nil (excluded) when terminal, `discussions' when a
human awaits my reply, else `queue'."
  (cond ((or (member (alist-get 'state pr) '("MERGED" "CLOSED"))
             (alist-get 'merged_at pr))
         nil)
        ((alist-get 'replies_to_me pr) 'discussions)
        (t 'queue)))

(defun decknix-priority-task-lane (task)
  "Lane for a Jira TASK: nil when done, else `tasks'."
  (if (string= (or (alist-get 'status_category task) "") "done") nil 'tasks))

;; -- Age + ranking (pure) -------------------------------------------

(defun decknix-priority-age-seconds (ts now)
  "Whole seconds between NOW and ISO-8601 TS, or nil if unparseable."
  (when (and ts (stringp ts))
    (condition-case nil
        (max 0 (floor (float-time (time-subtract now (date-to-time ts)))))
      (error nil))))

(defun decknix-priority-item-less-p (a b)
  "Rank item A before B: directly-mentioned first, then oldest first.
Items with no age sort last within their mention class."
  (let ((ma (alist-get 'mention a)) (mb (alist-get 'mention b))
        (aa (alist-get 'age a)) (ab (alist-get 'age b)))
    (cond ((and ma (not mb)) t)
          ((and mb (not ma)) nil)
          ((and aa ab) (> aa ab))
          (aa t)
          (t nil))))

;; -- Normalisers (pure) ---------------------------------------------

(defun decknix-priority--ci-badge (item)
  "Short CI badge for ITEM, or empty string."
  (or (alist-get 'status (alist-get 'ci item)) ""))

(defun decknix-priority--review-item (item now)
  (list (cons 'key (format "review:%s#%s" (alist-get 'repo item)
                           (alist-get 'number item)))
        (cons 'lane (decknix-priority-review-lane item))
        (cons 'title (or (alist-get 'title item) ""))
        (cons 'url (alist-get 'url item))
        (cons 'repo (alist-get 'repo item))
        (cons 'age (decknix-priority-age-seconds
                    (or (alist-get 'updated item) (alist-get 'created item)) now))
        (cons 'mention (and (alist-get 'mentioned item) t))
        (cons 'badge (decknix-priority--ci-badge item))))

(defun decknix-priority--wip-item (pr repo now)
  (list (cons 'key (format "wip:%s#%s" repo (alist-get 'number pr)))
        (cons 'lane (decknix-priority-wip-lane pr))
        (cons 'title (or (alist-get 'title pr) ""))
        (cons 'url (alist-get 'url pr))
        (cons 'repo repo)
        (cons 'age (decknix-priority-age-seconds (alist-get 'updated pr) now))
        (cons 'mention nil)
        (cons 'badge (decknix-priority--ci-badge pr))))

(defun decknix-priority--task-item (task now)
  (list (cons 'key (format "task:%s" (alist-get 'key task)))
        (cons 'lane (decknix-priority-task-lane task))
        (cons 'title (format "%s %s" (alist-get 'key task)
                             (or (alist-get 'summary task) "")))
        (cons 'url (alist-get 'url task))
        (cons 'repo nil)
        (cons 'age (decknix-priority-age-seconds (alist-get 'updated task) now))
        (cons 'mention nil)
        (cons 'badge (or (alist-get 'status task) ""))))

(defun decknix-priority-collect (reviews wip tasks &optional now)
  "Classify the hub wrappers REVIEWS, WIP and TASKS into ranked lanes.
Returns an alist keyed by `decknix-priority-lanes'; each value is the
lane's items sorted by `decknix-priority-item-less-p'.  NOW defaults to
the current time."
  (let* ((now (or now (current-time)))
         (acc (mapcar (lambda (l) (cons l nil)) decknix-priority-lanes)))
    (dolist (it (alist-get 'items reviews))
      (let ((n (decknix-priority--review-item it now)))
        (when (memq (alist-get 'lane n) decknix-priority-lanes)
          (push n (alist-get (alist-get 'lane n) acc)))))
    (dolist (repo-entry (alist-get 'repos wip))
      (let ((repo (alist-get 'repo repo-entry)))
        (dolist (pr (alist-get 'prs repo-entry))
          (let ((lane (decknix-priority-wip-lane pr)))
            (when (memq lane decknix-priority-lanes)
              (push (decknix-priority--wip-item pr repo now)
                    (alist-get lane acc)))))))
    (dolist (tk (alist-get 'items tasks))
      (let ((lane (decknix-priority-task-lane tk)))
        (when (memq lane decknix-priority-lanes)
          (push (decknix-priority--task-item tk now) (alist-get lane acc)))))
    (dolist (l decknix-priority-lanes)
      (setf (alist-get l acc)
            (sort (alist-get l acc) #'decknix-priority-item-less-p)))
    acc))

;; -- Renderer: standalone *Agent Priority* buffer ------------------
;; Reads the live hub defvars via `bound-and-true-p' (forward-declared
;; below) so the pure core above stays independently testable.

(defvar decknix--hub-reviews)
(defvar decknix--hub-wip)
(defvar decknix--hub-jira-tasks)

(defconst decknix-priority-buffer-name "*Agent Priority*"
  "Name of the standalone Priority view buffer.")

(defun decknix-priority--format-age (secs)
  "Human-readable age for SECS, or empty string when nil."
  (cond ((null secs) "")
        ((< secs 3600) (format "%dm" (max 1 (/ secs 60))))
        ((< secs 86400) (format "%dh" (/ secs 3600)))
        (t (format "%dd" (/ secs 86400)))))

(defun decknix-priority--open-at-point ()
  "Open the URL of the priority row at point, if any."
  (interactive)
  (let ((url (get-text-property (line-beginning-position)
                                'decknix-priority-url)))
    (if url (browse-url url) (message "No item on this line"))))

(defun decknix-priority--insert-row (item)
  "Insert one priority ITEM row, propertised with its URL."
  (let* ((badge (alist-get 'badge item))
         (repo (alist-get 'repo item))
         (age (decknix-priority--format-age (alist-get 'age item)))
         (line (format "  %s%s%s%s"
                       (if (alist-get 'mention item) "@ " "  ")
                       (if (and badge (not (string-empty-p badge)))
                           (format "[%s] " badge) "")
                       (if repo (format "%s " repo) "")
                       (alist-get 'title item))))
    (insert (propertize line 'decknix-priority-url (alist-get 'url item)))
    (unless (string-empty-p age)
      (insert (propertize (format "  (%s)" age) 'face 'shadow)))
    (insert "\n")))

(defun decknix-priority--data ()
  "Collect ranked lanes from the live hub defvars."
  (decknix-priority-collect (bound-and-true-p decknix--hub-reviews)
                            (bound-and-true-p decknix--hub-wip)
                            (bound-and-true-p decknix--hub-jira-tasks)))

(defun decknix-priority-refresh ()
  "Rebuild the Priority buffer from current hub data."
  (interactive)
  (let ((buf (get-buffer-create decknix-priority-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'decknix-priority-mode) (decknix-priority-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Priority — what to do next\n\n" 'face 'bold))
        (let ((lanes (decknix-priority--data)))
          (dolist (l decknix-priority-lanes)
            (let ((items (alist-get l lanes)))
              (insert (propertize
                       (format "%s (%d)\n" (decknix-priority-lane-label l)
                               (length items))
                       'face 'font-lock-keyword-face))
              (if items
                  (dolist (it items) (decknix-priority--insert-row it))
                (insert (propertize "  (none)\n" 'face 'shadow)))
              (insert "\n")))))
      (goto-char (point-min)))
    buf))

(defvar decknix-priority-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'decknix-priority--open-at-point)
    (define-key map (kbd "g")   #'decknix-priority-refresh)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `decknix-priority-mode'.")

(define-derived-mode decknix-priority-mode special-mode "Priority"
  "Major mode for the ranked lane-based Priority view.")

;;;###autoload
(defun decknix-priority ()
  "Open the ranked lane-based Priority view in a standalone buffer."
  (interactive)
  (pop-to-buffer (decknix-priority-refresh)))

(provide 'decknix-priority)
;;; decknix-priority.el ends here
