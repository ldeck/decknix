;;; decknix-pr-review-view.el --- Read a PR's review in Emacs -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, review

;;; Commentary:
;;
;; Steps 4 and 5 of `specs/pr-review-in-emacs.md', read-only: one buffer
;; per PR, `*PR Review: repo#N*', showing its description, CI, the reviews
;; so far, every review thread grouped by file (paginated, so a large PR
;; is never silently truncated), and the plan the review agent composed,
;; when `/review-service-pr' saved one under
;; ~/.local/state/decknix/reviews/<owner>/<repo>/<n>/plan.json.
;;
;; Every `gh' call runs in a child process; the buffer opens at once and
;; each section fills in as its data arrives.  RET on a thread opens it on
;; GitHub; replying and resolving are later steps.
;;
;; Rendering is pure (data in, text out) and tested; the process plumbing
;; is a small layer around `decknix-pr-review-view-gh-function'.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'decknix-review-threads)

(defgroup decknix-pr-review-view nil
  "Read a PR's review in Emacs." :group 'decknix)

(defcustom decknix-pr-review-view-state-root
  (expand-file-name "~/.local/state/decknix/reviews/")
  "Where review sessions keep each PR's `ctx.json' and `plan.json'."
  :type 'directory :group 'decknix-pr-review-view)

(defvar decknix-pr-review-view-gh-function #'decknix-pr-review-view--gh
  "Runs `gh' with ARGS and calls CALLBACK with (OK OUTPUT).  Tests replace it.")

(defconst decknix-pr-review-view-pr-fields
  "title,author,body,state,isDraft,reviewDecision,statusCheckRollup,reviews,headRefName,baseRefName,additions,deletions,changedFiles,createdAt,updatedAt,url"
  "The `gh pr view --json' fields the view shows.")

(defvar-local decknix-pr-review-view--pr nil
  "(OWNER REPO NUMBER URL) of the PR in this buffer.")

(defvar-local decknix-pr-review-view--data nil
  "What has arrived so far, a plist: `:pr', `:pr-error', `:threads',
`:threads-error', `:threads-loading', `:plan', `:plan-path'.")

(defvar-local decknix-pr-review-view--generation 0
  "Bumped on each refresh, so a reply to an earlier fetch is ignored.")

;; ── paths ────────────────────────────────────────────────────────────

(defun decknix-pr-review-view-state-dir (owner repo number)
  "Return the directory a review session keeps OWNER/REPO#NUMBER's files in."
  (file-name-as-directory
   (expand-file-name (format "%s/%s/%s" owner repo number)
                     decknix-pr-review-view-state-root)))

(defun decknix-pr-review-view-read-plan (dir)
  "Return DIR's `plan.json' parsed, or nil when absent or unreadable."
  (let ((file (expand-file-name "plan.json" dir)))
    (when (file-readable-p file)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents file)
          (json-parse-buffer :object-type 'alist :array-type 'list
                             :null-object nil :false-object nil))))))

(defun decknix-pr-review-view-thread-url (owner repo number thread)
  "Return THREAD's URL on GitHub: its first comment's discussion anchor."
  (let ((id (plist-get (car (plist-get thread :comments)) :id)))
    (format "https://github.com/%s/%s/pull/%s%s" owner repo number
            (if id (format "#discussion_r%s" id) "/files"))))

;; ── rendering (pure) ─────────────────────────────────────────────────

(defun decknix-pr-review-view--heading (text)
  "Return TEXT as a section heading line."
  (concat (propertize text 'face 'bold) "\n"))

(defun decknix-pr-review-view--indent (text prefix)
  "Return TEXT with every line prefixed by PREFIX."
  (mapconcat (lambda (l) (concat prefix l)) (split-string (or text "") "\n") "\n"))

(defun decknix-pr-review-view-render-summary (pr)
  "Return the title block for PR (`gh pr view' JSON as an alist).  Pure."
  (concat
   (propertize (or (alist-get 'title pr) "") 'face 'bold) "\n"
   (format "%s  by %s  %s -> %s  +%s/-%s in %s files%s\n"
           (or (alist-get 'state pr) "?")
           (or (alist-get 'login (alist-get 'author pr)) "?")
           (or (alist-get 'headRefName pr) "?")
           (or (alist-get 'baseRefName pr) "?")
           (or (alist-get 'additions pr) 0)
           (or (alist-get 'deletions pr) 0)
           (or (alist-get 'changedFiles pr) 0)
           (if (eq (alist-get 'isDraft pr) t) "  (draft)" ""))
   (format "decision %s   updated %s\n"
           (or (alist-get 'reviewDecision pr) "-")
           (or (alist-get 'updatedAt pr) "?"))))

(defun decknix-pr-review-view-render-description (pr)
  "Return PR's description section.  Pure."
  (let ((body (string-trim (or (alist-get 'body pr) ""))))
    (concat (decknix-pr-review-view--heading "Description")
            (if (string-empty-p body) "  (none)" (decknix-pr-review-view--indent body "  "))
            "\n")))

(defun decknix-pr-review-view--check-result (check)
  "Return CHECK's outcome word: its conclusion, else its state or status."
  (let ((r (or (alist-get 'conclusion check) (alist-get 'state check)
               (alist-get 'status check))))
    (if (or (null r) (equal r "")) "PENDING" r)))

(defun decknix-pr-review-view-render-ci (pr)
  "Return PR's CI section, failures first.  Pure."
  (let* ((checks (alist-get 'statusCheckRollup pr))
         (bad '("FAILURE" "ERROR" "TIMED_OUT" "CANCELLED" "ACTION_REQUIRED"))
         (sorted (sort (copy-sequence checks)
                       (lambda (a b)
                         (and (member (decknix-pr-review-view--check-result a) bad)
                              (not (member (decknix-pr-review-view--check-result b) bad)))))))
    (concat (decknix-pr-review-view--heading "CI")
            (if (null checks)
                "  (no checks)\n"
              (mapconcat (lambda (c)
                           (let ((result (decknix-pr-review-view--check-result c)))
                             (format "  %-9s %s\n"
                                     (propertize result 'face
                                                 (cond ((member result bad) 'error)
                                                       ((member result '("SUCCESS" "NEUTRAL" "SKIPPED"))
                                                        'success)
                                                       (t 'font-lock-comment-face)))
                                     (or (alist-get 'name c) (alist-get 'context c) "?"))))
                         sorted "")))))

(defun decknix-pr-review-view-render-reviews (pr)
  "Return PR's reviews section, oldest first.  Pure."
  (let ((reviews (alist-get 'reviews pr)))
    (concat (decknix-pr-review-view--heading "Reviews")
            (if (null reviews)
                "  (none yet)\n"
              (mapconcat
               (lambda (r)
                 (let ((body (string-trim (or (alist-get 'body r) ""))))
                   (format "  %-18s %-17s %s\n"
                           (or (alist-get 'login (alist-get 'author r)) "?")
                           (or (alist-get 'state r) "?")
                           (truncate-string-to-width
                            (car (split-string body "\n")) 70 nil nil "…"))))
               reviews "")))))

(defun decknix-pr-review-view--thread-flag (thread)
  "Return THREAD's disposition word."
  (cond ((plist-get thread :resolved) "resolved")
        ((plist-get thread :outdated) "outdated")
        (t "open")))

(defun decknix-pr-review-view-render-threads (threads)
  "Return the threads section for THREADS, grouped by file.  Pure.
Each thread line carries the text property `decknix-pr-review-thread'
with the thread plist, which RET reads."
  (let ((summary (decknix-review-threads-summary threads)))
    (concat
     (decknix-pr-review-view--heading
      (format "Threads  %d open, %d resolved, %d outdated"
              (plist-get summary :actionable) (plist-get summary :resolved)
              (plist-get summary :outdated)))
     (if (null threads)
         "  (none)\n"
       (mapconcat
        (lambda (file)
          (concat
           (propertize (concat "  " (if (string-empty-p (car file)) "(no file)" (car file)))
                       'face 'font-lock-function-name-face)
           "\n"
           (mapconcat
            (lambda (thread)
              (let* ((open (decknix-review-threads-actionable-p thread))
                     (head (format "    L%-5s %-8s %s\n"
                                   (or (plist-get thread :line) "?")
                                   (decknix-pr-review-view--thread-flag thread)
                                   (string-join (plist-get thread :authors) ", ")))
                     (comments
                      (mapconcat
                       (lambda (c)
                         (concat (format "      %s: " (or (plist-get c :author) "?"))
                                 (string-trim
                                  (decknix-pr-review-view--indent
                                   (string-trim (plist-get c :body)) "        "))
                                 "\n"))
                       (plist-get thread :comments) "")))
                (propertize (concat (propertize head 'face (if open 'warning 'font-lock-comment-face))
                                    (if open comments ""))
                            'decknix-pr-review-thread thread)))
            (cdr file) "")))
        (decknix-review-threads-group-by-file threads) "")))))

(defun decknix-pr-review-view-render-plan (plan path)
  "Return the agent's plan section for PLAN read from PATH.  Pure."
  (concat
   (decknix-pr-review-view--heading "Agent's plan")
   (if (null plan)
       (format "  (none saved%s)\n" (if path (format " at %s" path) ""))
     (concat
      (format "  verdict  %s\n" (or (alist-get 'verdict plan) "?"))
      (format "  file     %s\n\n" path)
      (decknix-pr-review-view--indent (string-trim (or (alist-get 'body plan) "")) "  ")
      "\n"
      (let ((inline (alist-get 'inline_comments plan)))
        (if (null inline) ""
          (concat "\n  inline comments\n"
                  (mapconcat (lambda (c)
                               (format "    %s:%s  %s\n"
                                       (or (alist-get 'path c) "?") (or (alist-get 'line c) "?")
                                       (string-trim (or (alist-get 'body c) ""))))
                             inline ""))))
      (let ((reactions (alist-get 'bot_reactions plan)))
        (if (null reactions) ""
          (concat "\n  bot reactions\n"
                  (mapconcat (lambda (r)
                               (format "    %s on %s\n" (or (alist-get 'reaction r) "?")
                                       (or (alist-get 'comment_id r) "?")))
                             reactions ""))))))))

(defun decknix-pr-review-view-render (data)
  "Return the whole buffer text for DATA (see `decknix-pr-review-view--data')."
  (let ((pr (plist-get data :pr)))
    (concat
     (cond (pr (decknix-pr-review-view-render-summary pr))
           ((plist-get data :pr-error)
            (propertize (format "Could not read the PR: %s\n" (plist-get data :pr-error))
                        'face 'error))
           (t "Loading the PR...\n"))
     "\n"
     (decknix-pr-review-view-render-plan (plist-get data :plan) (plist-get data :plan-path))
     "\n"
     (if pr
         (concat (decknix-pr-review-view-render-description pr) "\n"
                 (decknix-pr-review-view-render-ci pr) "\n"
                 (decknix-pr-review-view-render-reviews pr) "\n")
       "")
     (cond ((plist-get data :threads-error)
            (concat (decknix-pr-review-view--heading "Threads")
                    (propertize (format "  Could not read the threads: %s\n"
                                        (plist-get data :threads-error))
                                'face 'error)))
           ((plist-get data :threads-loading)
            (concat (decknix-pr-review-view--heading "Threads") "  Loading...\n"))
           (t (decknix-pr-review-view-render-threads (plist-get data :threads)))))))

;; ── fetching ─────────────────────────────────────────────────────────

(defun decknix-pr-review-view--gh (args callback)
  "Run `gh' with ARGS in a child process; call CALLBACK with (OK OUTPUT)."
  (let ((out (generate-new-buffer " *pr-review-view-gh*")))
    (condition-case err
        (make-process
         :name "pr-review-view-gh" :buffer out :command (cons "gh" args)
         :connection-type 'pipe :noquery t
         :sentinel (lambda (proc _event)
                     (unless (process-live-p proc)
                       (let ((text (with-current-buffer out (buffer-string))))
                         (kill-buffer out)
                         (funcall callback (eql 0 (process-exit-status proc)) text)))))
      (error (kill-buffer out)
             (funcall callback nil (error-message-string err))))))

(defun decknix-pr-review-view--parse (text)
  "Return TEXT parsed as JSON (alists and lists), or nil."
  (ignore-errors
    (json-parse-string text :object-type 'alist :array-type 'list
                       :null-object nil :false-object nil)))

(defun decknix-pr-review-view--first-line (text)
  "Return the first non-blank line of TEXT, for an error message."
  (or (seq-find (lambda (l) (not (string-empty-p (string-trim l))))
                (split-string (or text "") "\n"))
      "no output"))

(defun decknix-pr-review-view-fetch-threads (owner repo number callback &optional after acc)
  "Fetch every review thread of OWNER/REPO#NUMBER, then CALLBACK.
CALLBACK gets (THREADS) on success or (nil ERROR) on failure.  Follows
`pageInfo' one page at a time (AFTER is the cursor, ACC the threads so
far), so a PR with more threads than a page is read whole rather than
truncated."
  (funcall decknix-pr-review-view-gh-function
           (append (list "api" "graphql"
                         "-f" (concat "query=" decknix-review-threads-query)
                         "-f" (concat "owner=" owner)
                         "-f" (concat "repo=" repo)
                         "-F" (format "pr=%s" number)
                         "-F" (format "size=%s" decknix-review-threads-page-size))
                   (and after (list "-f" (concat "after=" after))))
           (lambda (ok text)
             (let ((page (and ok (decknix-review-threads-parse-page
                                  (decknix-pr-review-view--parse text)))))
               (cond
                ((not page)
                 (funcall callback nil (decknix-pr-review-view--first-line text)))
                ((and (nth 1 page) (nth 2 page))
                 (decknix-pr-review-view-fetch-threads
                  owner repo number callback (nth 2 page) (append acc (nth 0 page))))
                (t (funcall callback (append acc (nth 0 page)))))))))

(defun decknix-pr-review-view--update (buf generation &rest props)
  "Merge PROPS into BUF's data and repaint, unless a later refresh superseded it."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (eql generation decknix-pr-review-view--generation)
        (while props
          (setq decknix-pr-review-view--data
                (plist-put decknix-pr-review-view--data (pop props) (pop props))))
        (decknix-pr-review-view--paint)))))

(defun decknix-pr-review-view--paint ()
  "Repaint this buffer from its data, keeping point's line."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (insert (decknix-pr-review-view-render decknix-pr-review-view--data))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun decknix-pr-review-view-refresh ()
  "Fetch everything again, in the background."
  (interactive)
  (pcase-let* ((`(,owner ,repo ,number ,url) decknix-pr-review-view--pr)
               (buf (current-buffer))
               (generation (cl-incf decknix-pr-review-view--generation))
               (dir (decknix-pr-review-view-state-dir owner repo number))
               (plan-path (expand-file-name "plan.json" dir)))
    (setq decknix-pr-review-view--data
          (list :threads-loading t
                :plan (decknix-pr-review-view-read-plan dir)
                :plan-path plan-path))
    (decknix-pr-review-view--paint)
    (funcall decknix-pr-review-view-gh-function
             (list "pr" "view" (or url (format "https://github.com/%s/%s/pull/%s" owner repo number))
                   "--json" decknix-pr-review-view-pr-fields)
             (lambda (ok text)
               (let ((pr (and ok (decknix-pr-review-view--parse text))))
                 (if pr
                     (decknix-pr-review-view--update buf generation :pr pr)
                   (decknix-pr-review-view--update
                    buf generation :pr-error (decknix-pr-review-view--first-line text))))))
    (decknix-pr-review-view-fetch-threads
     owner repo number
     (lambda (threads &optional error)
       (decknix-pr-review-view--update buf generation
                                       :threads-loading nil
                                       :threads threads
                                       :threads-error error)))))

;; ── the buffer ───────────────────────────────────────────────────────

(defun decknix-pr-review-view-open-thread ()
  "Open the thread at point on GitHub."
  (interactive)
  (pcase-let ((`(,owner ,repo ,number ,_url) decknix-pr-review-view--pr))
    (if-let* ((thread (get-text-property (point) 'decknix-pr-review-thread)))
        (browse-url (decknix-pr-review-view-thread-url owner repo number thread))
      (user-error "No thread here"))))

(defun decknix-pr-review-view-browse ()
  "Open the PR on GitHub."
  (interactive)
  (pcase-let ((`(,owner ,repo ,number ,url) decknix-pr-review-view--pr))
    (browse-url (or url (format "https://github.com/%s/%s/pull/%s" owner repo number)))))

(defun decknix-pr-review-view--move-thread (direction)
  "Move point to the next thread in DIRECTION (1 or -1)."
  (let ((here (get-text-property (point) 'decknix-pr-review-thread))
        (pos (point)))
    (while (and (if (> direction 0) (< pos (point-max)) (> pos (point-min)))
                (let ((p (get-text-property pos 'decknix-pr-review-thread)))
                  (or (null p) (eq p here))))
      (setq pos (+ pos direction)))
    (when (get-text-property pos 'decknix-pr-review-thread)
      (goto-char pos)
      (beginning-of-line))))

(defun decknix-pr-review-view-next-thread ()
  "Move to the next thread."
  (interactive)
  (decknix-pr-review-view--move-thread 1))

(defun decknix-pr-review-view-prev-thread ()
  "Move to the previous thread."
  (interactive)
  (decknix-pr-review-view--move-thread -1))

(defvar decknix-pr-review-view-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'decknix-pr-review-view-open-thread)
    (define-key map (kbd "o") #'decknix-pr-review-view-browse)
    (define-key map (kbd "n") #'decknix-pr-review-view-next-thread)
    (define-key map (kbd "p") #'decknix-pr-review-view-prev-thread)
    (define-key map (kbd "g") #'decknix-pr-review-view-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `decknix-pr-review-view-mode'.")

(define-derived-mode decknix-pr-review-view-mode special-mode "PRReview"
  "Read-only view of a PR's review: description, CI, reviews, threads, plan.
\\{decknix-pr-review-view-mode-map}"
  (setq truncate-lines nil)
  (buffer-disable-undo))

;;;###autoload
(defun decknix-pr-review-view-open (owner repo number &optional url)
  "Show OWNER/REPO#NUMBER, at URL if given, in `*PR Review: REPO#NUMBER*'.
Everything is fetched in the background."
  (let ((buf (get-buffer-create (format "*PR Review: %s#%s*" repo number))))
    (with-current-buffer buf
      (unless (derived-mode-p 'decknix-pr-review-view-mode)
        (decknix-pr-review-view-mode))
      (setq decknix-pr-review-view--pr (list owner repo number url))
      (decknix-pr-review-view-refresh))
    (pop-to-buffer buf)
    buf))

(provide 'decknix-pr-review-view)
;;; decknix-pr-review-view.el ends here
