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

(defun decknix-pr-review-view--plan-for-json (plan)
  "Return a copy of PLAN with array fields coerced to vectors for `json-serialize'."
  (mapcar (lambda (cell)
            (if (memq (car cell) '(inline_comments bot_reactions))
                (cons (car cell) (vconcat (cdr cell)))
              cell))
          plan))

(defun decknix-pr-review-view-write-plan (path plan)
  "Write PLAN alist as JSON to PATH."
  (when (and path (stringp path))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert (json-serialize (decknix-pr-review-view--plan-for-json plan)
                              :null-object nil
                              :false-object :false)
              "\n"))))

(defun decknix-pr-review-view-canonical-approve-body (inline-count thumbs-up-count)
  "Return the canonicalNurtureCloud approve body for INLINE-COUNT and THUMBS-UP-COUNT.  Pure."
  (let ((parts nil))
    (when (> inline-count 0)
      (push (format "%d inline %s" inline-count
                    (if (= inline-count 1) "comment" "comments"))
            parts))
    (when (> thumbs-up-count 0)
      (push (format "thumbs up to %d bot %s" thumbs-up-count
                    (if (= thumbs-up-count 1) "comment" "comments"))
            parts))
    (if parts
        (concat "LGTM + " (string-join (nreverse parts) " + "))
      "LGTM.")))

(defun decknix-pr-review-view--sync-approve-body (plan)
  "If PLAN's verdict is APPROVE, update its body to match canonical counts.  Pure."
  (if (not (equal (alist-get 'verdict plan) "APPROVE"))
      plan
    (let* ((inline (alist-get 'inline_comments plan))
           (reactions (alist-get 'bot_reactions plan))
           (thumbs (seq-count (lambda (r)
                                (member (alist-get 'reaction r) '("+" "+1" "thumbs_up" "👍")))
                              reactions))
           (body (decknix-pr-review-view-canonical-approve-body (length inline) thumbs))
           (out (copy-sequence plan)))
      (setf (alist-get 'body out) body)
      out)))

(defun decknix-pr-review-view-render-walkthrough (walkthrough)
  "Render WALKTHROUGH (`before_what', `after_what', `before_why', `after_why', `steps', `glossary').  Pure."
  (if (null walkthrough)
      ""
    (let ((bg (alist-get 'background walkthrough))
          (bw (alist-get 'before_what walkthrough))
          (aw (alist-get 'after_what walkthrough))
          (by (alist-get 'before_why walkthrough))
          (ay (alist-get 'after_why walkthrough))
          (steps (alist-get 'steps walkthrough))
          (glossary (alist-get 'glossary walkthrough)))
      (concat
       (decknix-pr-review-view--heading "Walkthrough (Before / After & Call Order)")
       (if (and bg (not (string-empty-p bg)))
           (concat (decknix-pr-review-view--indent bg "  ") "\n\n")
         "")
       (if (or bw aw)
           (concat "  WHAT (Before): " (or bw "-") "\n"
                   "  WHAT (After):  " (or aw "-") "\n")
         "")
       (if (or by ay)
           (concat "  WHY  (Before): " (or by "-") "\n"
                   "  WHY  (After):  " (or ay "-") "\n")
         "")
       (if steps
           (concat "\n  Call-order steps\n"
                   (mapconcat
                    (lambda (s)
                      (format "    %s. %s (%s)\n"
                              (or (alist-get 'step s) "?")
                              (or (alist-get 'title s) "?")
                              (or (alist-get 'target s) "?")))
                    steps ""))
         "")
       (if glossary
           (concat "\n  Glossary\n"
                   (mapconcat
                    (lambda (g)
                      (format "    %s: %s\n"
                              (propertize (or (alist-get 'term g) "?") 'face 'bold)
                              (or (alist-get 'definition g) "")))
                    glossary ""))
         "")
       "\n"))))

(defun decknix-pr-review-view-render-plan (plan path)
  "Return the agent's plan section for PLAN read from PATH.  Pure.
Tags verdict, body, and each inline comment with text properties so `v', `e',
`a', `k' and `C-c C-c' can edit and submit the review directly from Emacs."
  (concat
   (decknix-pr-review-view--heading
    "Agent's plan  (v cycle verdict · e edit · a add inline · k drop inline · C-c C-c submit · C-c C-k cancel · V canvas)")
   (if (null plan)
       (format "  (none saved%s)\n" (if path (format " at %s" path) ""))
     (let ((inline (alist-get 'inline_comments plan))
           (reactions (alist-get 'bot_reactions plan))
           (idx 0))
       (concat
        (propertize (format "  verdict  %s\n" (or (alist-get 'verdict plan) "?"))
                    'decknix-pr-review-plan-field 'verdict)
        (format "  file     %s\n\n" path)
        (propertize (concat (decknix-pr-review-view--indent
                             (string-trim (or (alist-get 'body plan) "")) "  ")
                            "\n")
                    'decknix-pr-review-plan-field 'body)
        (if (null inline) ""
          (concat "\n  inline comments\n"
                  (mapconcat
                   (lambda (c)
                     (prog1
                         (propertize
                          (format "    %s:%s  %s\n"
                                  (or (alist-get 'path c) "?") (or (alist-get 'line c) "?")
                                  (string-trim (or (alist-get 'body c) "")))
                          'decknix-pr-review-inline-idx idx
                          'decknix-pr-review-inline c)
                       (setq idx (1+ idx))))
                   inline "")))
        (if (null reactions) ""
          (concat "\n  bot reactions\n"
                  (mapconcat (lambda (r)
                               (format "    %s on %s\n" (or (alist-get 'reaction r) "?")
                                       (or (alist-get 'comment_id r) "?")))
                             reactions "")))
        (if-let* ((wt (alist-get 'walkthrough plan)))
            (concat "\n" (decknix-pr-review-view-render-walkthrough wt))
          ""))))))

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

(defun decknix-pr-review-view--ensure-plan ()
  "Return the buffer's mutable plan alist, initialising an empty one if needed."
  (or (plist-get decknix-pr-review-view--data :plan)
      (pcase-let ((`(,owner ,repo ,number ,url) decknix-pr-review-view--pr))
        (list (cons 'pr_url (or url (format "https://github.com/%s/%s/pull/%s" owner repo number)))
              (cons 'verdict "APPROVE")
              (cons 'body "LGTM.")
              (cons 'inline_comments nil)
              (cons 'bot_reactions nil)))))

(defun decknix-pr-review-view--save-and-paint (plan)
  "Persist PLAN to `:plan-path' and repaint the buffer."
  (let ((path (plist-get decknix-pr-review-view--data :plan-path)))
    (setq decknix-pr-review-view--data
          (plist-put decknix-pr-review-view--data :plan plan))
    (when path (decknix-pr-review-view-write-plan path plan))
    (decknix-pr-review-view--paint)))

(defconst decknix-pr-review-view-verdicts '("APPROVE" "COMMENT" "REQUEST_CHANGES")
  "Verdict cycle order.")

(defun decknix-pr-review-view-cycle-verdict ()
  "Cycle the plan's verdict (`APPROVE' -> `COMMENT' -> `REQUEST_CHANGES') and save."
  (interactive)
  (let* ((plan (copy-sequence (decknix-pr-review-view--ensure-plan)))
         (cur (or (alist-get 'verdict plan) "APPROVE"))
         (pos (seq-position decknix-pr-review-view-verdicts cur))
         (next (nth (mod (1+ (or pos -1)) (length decknix-pr-review-view-verdicts))
                    decknix-pr-review-view-verdicts)))
    (setf (alist-get 'verdict plan) next)
    (setq plan (decknix-pr-review-view--sync-approve-body plan))
    (decknix-pr-review-view--save-and-paint plan)
    (message "Verdict: %s" next)))

(defun decknix-pr-review-view-edit-at-point ()
  "Edit the inline comment at point, or the review body when not on an inline comment."
  (interactive)
  (let* ((plan (copy-sequence (decknix-pr-review-view--ensure-plan)))
         (idx (get-text-property (line-beginning-position) 'decknix-pr-review-inline-idx)))
    (if (numberp idx)
        (let* ((inline (copy-sequence (alist-get 'inline_comments plan)))
               (entry (copy-sequence (nth idx inline)))
               (path (alist-get 'path entry))
               (line (alist-get 'line entry))
               (old (or (alist-get 'body entry) ""))
               (new (read-string (format "Edit comment (%s:%s): " path line) old)))
          (setf (alist-get 'body entry) (string-trim new))
          (setf (nth idx inline) entry)
          (setf (alist-get 'inline_comments plan) inline)
          (decknix-pr-review-view--save-and-paint plan)
          (message "Updated inline comment on %s:%s" path line))
      (let* ((old (or (alist-get 'body plan) ""))
             (new (read-string "Edit review body: " old)))
        (setf (alist-get 'body plan) (string-trim new))
        (decknix-pr-review-view--save-and-paint plan)
        (message "Updated review body")))))

(defun decknix-pr-review-view-add-inline-comment (path line body)
  "Add a new inline comment on PATH at LINE with BODY to the plan and save."
  (interactive
   (list (read-string "File path (relative to repo root): ")
         (read-number "Line number: " 1)
         (read-string "Comment (prefix with nit: / fix: / question: / discussion:): " "nit: ")))
  (let* ((plan (copy-sequence (decknix-pr-review-view--ensure-plan)))
         (inline (append (alist-get 'inline_comments plan)
                         (list (list (cons 'path (string-trim path))
                                     (cons 'line line)
                                     (cons 'body (string-trim body)))))))
    (setf (alist-get 'inline_comments plan) inline)
    (setq plan (decknix-pr-review-view--sync-approve-body plan))
    (decknix-pr-review-view--save-and-paint plan)
    (message "Added inline comment on %s:%s" path line)))

(defun decknix-pr-review-view-delete-inline-comment ()
  "Remove the inline comment at point from the review plan and save."
  (interactive)
  (let ((idx (get-text-property (line-beginning-position) 'decknix-pr-review-inline-idx)))
    (unless (numberp idx)
      (user-error "Move point to an inline comment line first"))
    (let* ((plan (copy-sequence (decknix-pr-review-view--ensure-plan)))
           (inline (alist-get 'inline_comments plan))
           (removed (nth idx inline))
           (kept (append (seq-take inline idx) (seq-drop inline (1+ idx)))))
      (setf (alist-get 'inline_comments plan) kept)
      (setq plan (decknix-pr-review-view--sync-approve-body plan))
      (decknix-pr-review-view--save-and-paint plan)
      (message "Dropped inline comment on %s:%s"
               (alist-get 'path removed) (alist-get 'line removed)))))

(defvar decknix-pr-review-view-execute-command
  (expand-file-name "~/Code/nurturecloud/.nc-tools/bin/pr-review-execute")
  "Path to `pr-review-execute' used by `C-c C-c' (`decknix-pr-review-view-submit').")

(defun decknix-pr-review-view-submit ()
  "Confirm and submit the current review plan (verdict + inline comments + bot reactions)."
  (interactive)
  (pcase-let* ((`(,owner ,repo ,number ,_url) decknix-pr-review-view--pr)
               (plan (decknix-pr-review-view--ensure-plan))
               (verdict (or (alist-get 'verdict plan) "APPROVE"))
               (inline (alist-get 'inline_comments plan))
               (reactions (alist-get 'bot_reactions plan))
               (dir (decknix-pr-review-view-state-dir owner repo number))
               (ctx-file (expand-file-name "ctx.json" dir))
               (plan-file (or (plist-get decknix-pr-review-view--data :plan-path)
                              (expand-file-name "plan.json" dir)))
               (buf (current-buffer)))
    (decknix-pr-review-view-write-plan plan-file plan)
    (when (yes-or-no-p
           (format "Submit %s (%d inline comment%s, %d bot reaction%s) for %s/%s#%s? "
                   verdict
                   (length inline) (if (= (length inline) 1) "" "s")
                   (length reactions) (if (= (length reactions) 1) "" "s")
                   owner repo number))
      (if (and (file-executable-p decknix-pr-review-view-execute-command)
               (file-readable-p ctx-file))
          (let ((out (generate-new-buffer " *pr-review-submit*")))
            (message "Submitting review for %s/%s#%s via pr-review-execute..." owner repo number)
            (make-process
             :name "pr-review-submit" :buffer out
             :command (list decknix-pr-review-view-execute-command
                            "--context" ctx-file
                            "--no-ai-attribution"
                            plan-file)
             :connection-type 'pipe :noquery t
             :sentinel (lambda (proc _ev)
                         (unless (process-live-p proc)
                           (let ((code (process-exit-status proc))
                                 (txt (with-current-buffer out (string-trim (buffer-string)))))
                             (kill-buffer out)
                             (if (eql code 0)
                                 (progn
                                   (message "Submitted %s on %s/%s#%s" verdict owner repo number)
                                   (when (buffer-live-p buf)
                                     (with-current-buffer buf (decknix-pr-review-view-refresh))))
                               (message "Review submit failed (%d): %s" code txt)))))))
        (let ((flag (pcase verdict
                      ("APPROVE" "--approve")
                      ("REQUEST_CHANGES" "--request-changes")
                      (_ "--comment")))
              (body (or (alist-get 'body plan) "LGTM.")))
          (funcall decknix-pr-review-view-gh-function
                   (list "pr" "review" (format "%s" number)
                         "-R" (format "%s/%s" owner repo)
                         flag "-b" body)
                   (lambda (ok text)
                     (if ok
                         (progn
                           (message "Submitted %s on %s/%s#%s" verdict owner repo number)
                           (when (buffer-live-p buf)
                             (with-current-buffer buf (decknix-pr-review-view-refresh))))
                       (message "gh pr review failed: %s" (string-trim text))))))))))

(defun decknix-pr-review-view--html-escape (s)
  "HTML-escape string S.  Pure."
  (replace-regexp-in-string
   "\"" "&quot;"
   (replace-regexp-in-string
    ">" "&gt;"
    (replace-regexp-in-string
     "<" "&lt;"
     (replace-regexp-in-string "&" "&amp;" (or s ""))))))

(defun decknix-pr-review-view-canvas-html (pr plan threads)
  "Generate a self-contained HTML workbench (Guided / Before-After / Threads / Plan) for PR.  Pure."
  (let* ((esc #'decknix-pr-review-view--html-escape)
         (title (funcall esc (or (alist-get 'title pr) "PR Review")))
         (body (funcall esc (or (alist-get 'body pr) "")))
         (verdict (funcall esc (or (alist-get 'verdict plan) "PENDING")))
         (rbody (funcall esc (or (alist-get 'body plan) "")))
         (wt (alist-get 'walkthrough plan))
         (bw (funcall esc (or (alist-get 'before_what wt) "Existing behaviour before this PR.")))
         (aw (funcall esc (or (alist-get 'after_what wt) (or (alist-get 'body pr) "Updated behaviour in this PR."))))
         (by (funcall esc (or (alist-get 'before_why wt) "Why the previous state needed changing.")))
         (ay (funcall esc (or (alist-get 'after_why wt) "How the new state resolves it safely.")))
         (inline (alist-get 'inline_comments plan)))
    (concat
     "<!doctype html><html><head><meta charset='utf-8'><title>" title "</title>"
     "<style>"
     "body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:0;background:#f8fafc;color:#1e293b;}"
     "header{background:#fff;border-bottom:1px solid #e2e8f0;padding:14px 24px;display:flex;justify-content:space-between;align-items:center;}"
     ".badge{background:#dbeafe;color:#1d4ed8;padding:4px 10px;border-radius:999px;font-weight:600;font-size:13px;}"
     "main{max-width:1200px;margin:24px auto;padding:0 24px;display:grid;grid-template-columns:1fr 1fr;gap:18px;}"
     ".full{grid-column:1 / -1;}"
     ".card{background:#fff;border:1px solid #e2e8f0;border-radius:10px;padding:18px;}"
     ".before{background:#fef2f2;border-color:#fecaca;}.after{background:#f0fdf4;border-color:#bbf7d0;}"
     "h2{margin:0 0 10px;font-size:14px;text-transform:uppercase;letter-spacing:.05em;color:#64748b;}"
     "pre{white-space:pre-wrap;font-family:ui-monospace,SFMono-Regular,monospace;font-size:13px;margin:0;}"
     ".comment{border-left:3px solid #3b82f6;padding:8px 12px;margin:8px 0;background:#f1f5f9;border-radius:4px;}"
     "</style></head><body>"
     "<header><div><strong>" title "</strong></div><div class='badge'>Verdict: " verdict "</div></header>"
     "<main>"
     "<div class='card before'><h2>Before (What)</h2><pre>" bw "</pre></div>"
     "<div class='card after'><h2>After (What)</h2><pre>" aw "</pre></div>"
     "<div class='card before'><h2>Before (Why)</h2><pre>" by "</pre></div>"
     "<div class='card after'><h2>After (Why)</h2><pre>" ay "</pre></div>"
     "<div class='card full'><h2>Proposed Review Plan (" (number-to-string (length inline)) " inline comments)</h2>"
     "<pre>" rbody "</pre>"
     (mapconcat (lambda (c)
                  (format "<div class='comment'><strong>%s:%s</strong><br>%s</div>"
                          (funcall esc (format "%s" (or (alist-get 'path c) "?")))
                          (funcall esc (format "%s" (or (alist-get 'line c) "?")))
                          (funcall esc (or (alist-get 'body c) ""))))
                inline "")
     "</div>"
     "<div class='card full'><h2>PR Description</h2><pre>" body "</pre></div>"
     "<div class='card full'><h2>Review Threads (" (number-to-string (length threads)) ")</h2>"
     (mapconcat (lambda (th)
                  (format "<div class='comment'><strong>%s:L%s (%s)</strong><br>%s</div>"
                          (funcall esc (or (plist-get th :path) "PR"))
                          (funcall esc (format "%s" (or (plist-get th :line) "?")))
                          (decknix-pr-review-view--thread-flag th)
                          (mapconcat (lambda (c)
                                       (format "<em>%s:</em> %s"
                                               (funcall esc (or (plist-get c :author) "?"))
                                               (funcall esc (or (plist-get c :body) ""))))
                                     (plist-get th :comments) "<br>")))
                threads "")
     "</div></main></body></html>\n")))

(defun decknix-pr-review-view-open-canvas ()
  "Write `<state-dir>/canvas.html' for this PR and open it in xwidget-webkit or browser."
  (interactive)
  (pcase-let* ((`(,owner ,repo ,number ,_url) decknix-pr-review-view--pr)
               (dir (decknix-pr-review-view-state-dir owner repo number))
               (out (expand-file-name "canvas.html" dir))
               (html (decknix-pr-review-view-canvas-html
                      (plist-get decknix-pr-review-view--data :pr)
                      (plist-get decknix-pr-review-view--data :plan)
                      (plist-get decknix-pr-review-view--data :threads))))
    (make-directory dir t)
    (with-temp-file out (insert html))
    (let ((url (concat "file://" out)))
      (if (and (display-graphic-p) (fboundp 'xwidget-webkit-browse-url))
          (xwidget-webkit-browse-url url)
        (browse-url url)))))

(defun decknix-pr-review-view-cancel ()
  "Cancel the staged review in this buffer and close the window."
  (interactive)
  (pcase-let ((`(,owner ,repo ,number ,_url) decknix-pr-review-view--pr)
              (plan-file (plist-get decknix-pr-review-view--data :plan-path)))
    (when (yes-or-no-p (format "Cancel review for %s/%s#%s and close view? " owner repo number))
      (when (and plan-file (file-exists-p plan-file)
                 (yes-or-no-p (format "Also discard staged %s? " plan-file)))
        (ignore-errors (delete-file plan-file)))
      (quit-window t)
      (message "Cancelled review view for %s/%s#%s" owner repo number))))

(defvar decknix-pr-review-view-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'decknix-pr-review-view-open-thread)
    (define-key map (kbd "o") #'decknix-pr-review-view-browse)
    (define-key map (kbd "n") #'decknix-pr-review-view-next-thread)
    (define-key map (kbd "p") #'decknix-pr-review-view-prev-thread)
    (define-key map (kbd "v") #'decknix-pr-review-view-cycle-verdict)
    (define-key map (kbd "e") #'decknix-pr-review-view-edit-at-point)
    (define-key map (kbd "a") #'decknix-pr-review-view-add-inline-comment)
    (define-key map (kbd "k") #'decknix-pr-review-view-delete-inline-comment)
    (define-key map (kbd "d") #'decknix-pr-review-view-delete-inline-comment)
    (define-key map (kbd "V") #'decknix-pr-review-view-open-canvas)
    (define-key map (kbd "C-c C-c") #'decknix-pr-review-view-submit)
    (define-key map (kbd "C-c C-k") #'decknix-pr-review-view-cancel)
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
