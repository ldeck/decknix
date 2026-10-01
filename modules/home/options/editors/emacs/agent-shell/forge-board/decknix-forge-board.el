;;; decknix-forge-board.el --- Bulk repo remedies buffer -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-forge-board-model "0.1"))
;; Keywords: git, repos, board

;;; Commentary:
;;
;; `*deckmacs: Forge Board*' -- the repo counterpart to the Review and
;; Session Boards.  Rows are repos the sweep found a problem with, grouped by
;; what is wrong, with marks so one verb can finish a whole lane.
;;
;; Every verb here is NON-DESTRUCTIVE.  Clearing a lock deletes a file no
;; process holds (the CLI re-checks with `lsof' and refuses otherwise), and a
;; re-sync only ever fetches -- the sweep never force-updates a dirty or
;; diverged repo.  There is deliberately no `reset' or `stash' verb: those
;; destroy or hide uncommitted work, and a board built for bulk action is the
;; worst possible place to put them, because the whole point of the marks is
;; to act on many rows at once.  The `dirty' lane says so in its hint.

;;; Code:

(require 'decknix-forge-board-model)
(require 'seq)

(declare-function decknix-repo-sync-problems "decknix-repo-sync-actions" ())
(declare-function decknix-repo-sync-refresh "decknix-repo-sync-actions"
                  (&optional on-done))
(declare-function decknix-repo-sync-clear-lock "decknix-repo-sync-actions"
                  (problem &optional on-done))
(declare-function decknix-repo-sync-retry "decknix-repo-sync-actions"
                  (problem &optional on-done))
(declare-function decknix-repo-sync-resweep "decknix-repo-sync-actions"
                  (&optional on-done))

(defconst decknix-forge-board-buffer "*deckmacs: Forge Board*"
  "Name of the Forge Board buffer.")

(defcustom decknix-forge-board-width 76
  "Column width the board renders to.

Fixed rather than taken from the window: the board opens in whatever
window is to hand, and padding rows to a selected window's width is what
pushed the Session Board's right-hand column out of view."
  :type 'integer
  :group 'decknix)

(defvar decknix-forge-board--groups nil
  "Rendered (LANE . ROWS) pairs, so an action resolves what is on screen.")

(defvar decknix-forge-board--marks (make-hash-table :test 'equal)
  "Marked row keys.")

;; --- target resolution ------------------------------------------------

(defun decknix-forge-board--rows ()
  "Return every rendered row."
  (apply #'append (mapcar #'cdr decknix-forge-board--groups)))

(defun decknix-forge-board--row-at-point ()
  "Return the row on the current line, or nil."
  (get-text-property (line-beginning-position) 'decknix-forge-row))

(defun decknix-forge-board--marked-rows ()
  "Return the marked rows that are still rendered.

Resolved against the rendered set so a mark for a repo that has since
been fixed cannot resurrect it."
  (seq-filter (lambda (r)
                (gethash (decknix-forge-board-row-key r)
                         decknix-forge-board--marks))
              (decknix-forge-board--rows)))

(defun decknix-forge-board--targets ()
  "Return the rows an action applies to: the marks, else the row at point.

Marks win over point.  A bulk verb acting on point while marks exist
would act on one repo when several were selected, or the wrong one if
the cursor moved after marking."
  (or (decknix-forge-board--marked-rows)
      (when-let ((row (decknix-forge-board--row-at-point))) (list row))))

;; --- render -----------------------------------------------------------

(defun decknix-forge-board--lane-face (lane)
  "Return the heading face for LANE."
  (pcase lane
    ('lock 'warning)
    ('failed 'error)
    (_ 'font-lock-comment-face)))

(defun decknix-forge-board-render ()
  "Redraw the board from the current sweep report."
  (let* ((problems (when (fboundp 'decknix-repo-sync-problems)
                     (decknix-repo-sync-problems)))
         (groups (decknix-forge-board-group problems))
         (width decknix-forge-board-width)
         (inhibit-read-only t)
         (line (line-number-at-pos)))
    (setq decknix-forge-board--groups groups)
    (erase-buffer)
    (insert (propertize
             (or (decknix-forge-board-summary groups) "No repo problems")
             'face 'bold)
            "\n\n")
    (dolist (g groups)
      (insert (propertize
               (decknix-forge-board-lane-header (car g) (cdr g) width)
               'face (decknix-forge-board--lane-face (car g)))
              "\n")
      (dolist (row (cdr g))
        (insert (propertize
                 (decknix-forge-board-row-label
                  row (gethash (decknix-forge-board-row-key row)
                               decknix-forge-board--marks)
                  width)
                 'decknix-forge-row row)
                "\n"))
      (insert "\n"))
    (insert (propertize
             "m mark  u unmark  U unmark all  c clear locks  r retry sync\n\
v visit  G resweep all  g refresh  q quit"
             'face 'font-lock-comment-face)
            "\n")
    (goto-char (point-min))
    (forward-line (1- line))))

;; --- marks ------------------------------------------------------------

(defun decknix-forge-board-mark ()
  "Mark the repo on this row and move down."
  (interactive)
  (when-let ((row (decknix-forge-board--row-at-point)))
    (puthash (decknix-forge-board-row-key row) t decknix-forge-board--marks)
    (decknix-forge-board-render))
  (forward-line 1))

(defun decknix-forge-board-unmark ()
  "Unmark the repo on this row and move down."
  (interactive)
  (when-let ((row (decknix-forge-board--row-at-point)))
    (remhash (decknix-forge-board-row-key row) decknix-forge-board--marks)
    (decknix-forge-board-render))
  (forward-line 1))

(defun decknix-forge-board-unmark-all ()
  "Clear every mark."
  (interactive)
  (clrhash decknix-forge-board--marks)
  (decknix-forge-board-render))

;; --- verbs ------------------------------------------------------------

(defun decknix-forge-board--after-each (n verb)
  "Return a callback that reports once all N VERB operations have finished."
  (let ((remaining n))
    (lambda (&rest _)
      (setq remaining (1- remaining))
      (when (<= remaining 0)
        (decknix-repo-sync-refresh
         (lambda (&rest _)
           (when (get-buffer decknix-forge-board-buffer)
             (with-current-buffer decknix-forge-board-buffer
               (decknix-forge-board-render)))
           (message "%s: finished on %d repo%s"
                    verb n (if (= 1 n) "" "s"))))))))

(defun decknix-forge-board-clear-locks ()
  "Clear the abandoned lock on every marked repo that has one.

Rows in other lanes are skipped rather than refused: a mark spanning a
whole sweep should not have to be pruned by hand before the one verb
that applies to part of it will run."
  (interactive)
  (let* ((targets (decknix-forge-board--targets))
         (clearable (decknix-forge-board-filter-clearable targets))
         (skipped (- (length targets) (length clearable))))
    (cond
     ((null targets) (user-error "No repo marked or at point"))
     ((null clearable)
      (user-error "Nothing to clear: no marked repo has a stale lock"))
     (t
      (let ((done (decknix-forge-board--after-each
                   (length clearable) "clear locks")))
        (dolist (row clearable)
          (decknix-repo-sync-clear-lock (plist-get row :problem) done)))
      (message "Clearing %d lock%s%s..."
               (length clearable) (if (= 1 (length clearable)) "" "s")
               (if (> skipped 0) (format " (%d skipped, no lock)" skipped) ""))))))

(defun decknix-forge-board-retry ()
  "Re-sync every marked repo.

Safe on any lane: the sweep only fetches, and never force-updates a
dirty or diverged repo."
  (interactive)
  (let ((targets (decknix-forge-board--targets)))
    (unless targets (user-error "No repo marked or at point"))
    (let ((done (decknix-forge-board--after-each (length targets) "retry sync")))
      (dolist (row targets)
        (decknix-repo-sync-retry (plist-get row :problem) done)))
    (message "Re-syncing %d repo%s..."
             (length targets) (if (= 1 (length targets)) "" "s"))))

(defun decknix-forge-board-visit ()
  "Open the repo on this row in Dired."
  (interactive)
  (let ((row (decknix-forge-board--row-at-point)))
    (unless row (user-error "No repo on this row"))
    (dired (plist-get row :path))))

(defun decknix-forge-board-resweep ()
  "Run the full sweep, then redraw."
  (interactive)
  (message "Re-sweeping all repos...")
  (decknix-repo-sync-resweep
   (lambda (&rest _)
     (when (get-buffer decknix-forge-board-buffer)
       (with-current-buffer decknix-forge-board-buffer
         (decknix-forge-board-render)))
     (message "Re-sweep finished"))))

(defun decknix-forge-board-refresh ()
  "Re-read the report and redraw."
  (interactive)
  (decknix-repo-sync-refresh
   (lambda (&rest _)
     (when (get-buffer decknix-forge-board-buffer)
       (with-current-buffer decknix-forge-board-buffer
         (decknix-forge-board-render))))))

;; --- mode -------------------------------------------------------------

(defvar decknix-forge-board-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "m") #'decknix-forge-board-mark)
    (define-key map (kbd "u") #'decknix-forge-board-unmark)
    (define-key map (kbd "U") #'decknix-forge-board-unmark-all)
    (define-key map (kbd "c") #'decknix-forge-board-clear-locks)
    (define-key map (kbd "r") #'decknix-forge-board-retry)
    (define-key map (kbd "v") #'decknix-forge-board-visit)
    (define-key map (kbd "RET") #'decknix-forge-board-visit)
    (define-key map (kbd "G") #'decknix-forge-board-resweep)
    (define-key map (kbd "g") #'decknix-forge-board-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `decknix-forge-board-mode'.")

(define-derived-mode decknix-forge-board-mode special-mode "Forge Board"
  "Major mode for bulk repo remedies."
  (setq truncate-lines t))

;;;###autoload
(defun decknix-forge-board ()
  "Open the Forge Board."
  (interactive)
  (let ((buf (get-buffer-create decknix-forge-board-buffer)))
    (with-current-buffer buf
      (unless (derived-mode-p 'decknix-forge-board-mode)
        (decknix-forge-board-mode))
      (decknix-forge-board-render))
    (pop-to-buffer buf)))

(provide 'decknix-forge-board)
;;; decknix-forge-board.el ends here
