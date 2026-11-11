;;; decknix-session-urls.el --- The URLs a session is handling -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, url, github, jira, review

;;; Commentary:
;;
;; Which links is this session about?  Answered from two places:
;;
;;   1. Its IDENTITY: the PR(s) it reviews (recorded at launch), the PRs
;;      linked to its conversation and the PRs it created.  These come
;;      first and keep their label, because they are what the session is
;;      FOR, and they may have scrolled out of the transcript entirely.
;;   2. Its TEXT: every URL (and bare ticket key, when a tracker base URL
;;      is known) in the tail of the transcript, most recent first.
;;
;; Most recent first rather than by first appearance: the link you want
;; is nearly always the one the agent printed last (the PR it just opened,
;; the CI run it just started, the comment it just posted).  First
;; appearance would put the prompt preamble's links on top and bury the
;; fresh one, which is the scrolling this exists to remove.
;;
;; Everything here is pure: text in, plists out.  Reading the buffer, the
;; recorded identity and the cache live in `decknix-session-urls-ui'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(defgroup decknix-session-urls nil
  "Collect, pick and act on the URLs an agent session is handling."
  :group 'decknix)

(defcustom decknix-session-urls-jira-base-url nil
  "Base URL bare ticket keys resolve against, e.g. \"https://example.atlassian.net\".
When nil, the base is taken from the first ticket URL seen in the scanned
text; with neither, bare keys are not offered (a key with no URL is not
something you can open)."
  :type '(choice (const :tag "Infer from the transcript" nil) string)
  :group 'decknix-session-urls)

(defcustom decknix-session-urls-jira-projects nil
  "Project keys a bare ticket key may use, e.g. (\"ABC\" \"OPS\").
nil accepts any key shape not in `decknix-session-urls-key-denylist'.
Setting it is the cure for false positives in a noisy transcript."
  :type '(repeat string)
  :group 'decknix-session-urls)

(defcustom decknix-session-urls-scan-limit 262144
  "How many characters at the end of a transcript to scan for URLs.
Bounds the cost on a huge transcript.  The session's identity PRs are
always included whatever the limit."
  :type 'integer
  :group 'decknix-session-urls)

(defcustom decknix-session-urls-ci-patterns
  '("/actions/runs/" "/actions/workflows/" "buildkite\\.com/" "circleci\\.com/"
    "teamcity" "jenkins" "travis-ci\\." "/-/pipelines/" "/-/jobs/")
  "Regexps marking a URL as a CI build link."
  :type '(repeat regexp)
  :group 'decknix-session-urls)

(defconst decknix-session-urls-key-denylist
  '("UTF" "SHA" "ISO" "RFC" "CVE" "HTTP" "TLS" "SSL" "AES" "RSA" "GPT" "IPV" "MD")
  "Prefixes that look like ticket keys but are not (UTF-8, SHA-256, ...).")

(defconst decknix-session-urls-url-regexp
  "https?://[^][ \t\n\r\"'<>(){}`|\\]+"
  "Matches a URL candidate; `decknix-session-urls-trim' tidies its end.")

(defconst decknix-session-urls--key-regexp
  "\\(?:\\`\\|[^[:alnum:]_/-]\\)\\(\\([A-Z][A-Z0-9]\\{1,9\\}\\)-[1-9][0-9]\\{0,6\\}\\)\\(?:[^[:alnum:]_]\\|\\'\\)"
  "Matches a bare ticket key: group 1 the key, group 2 its project.
Anchored by explicit neighbours rather than symbol boundaries, which
would depend on the calling buffer's syntax table.")

(defun decknix-session-urls-trim (url)
  "Return URL without the punctuation prose and Markdown leave on its end."
  (let ((u url))
    (while (and (> (length u) 0)
                (memq (aref u (1- (length u))) '(?. ?, ?\; ?: ?! ?? ?* ?_ ?~)))
      (setq u (substring u 0 -1)))
    u))

;; ── classification ───────────────────────────────────────────────────

(defun decknix-session-urls--short (url)
  "Return URL's host and path, without scheme or query, for a label."
  (let ((s (replace-regexp-in-string "\\`https?://" "" url)))
    (setq s (replace-regexp-in-string "[?#].*\\'" "" s))
    (if (> (length s) 60) (concat (substring s 0 59) "…") s)))

(defun decknix-session-urls--ci-p (url)
  "Non-nil when URL matches `decknix-session-urls-ci-patterns'."
  (seq-some (lambda (re) (string-match-p re url)) decknix-session-urls-ci-patterns))

(defun decknix-session-urls--github (url)
  "Classify a github.com URL, or return nil."
  (when (string-match
         "\\`https?://github\\.com/\\([^/]+\\)/\\([^/#?]+\\)/\\(pull\\|issues\\|commit\\)/\\([^/#?]+\\)\\(.*\\)\\'"
         url)
    (let* ((owner (match-string 1 url))
           (repo (match-string 2 url))
           (type (match-string 3 url))
           (id (match-string 4 url))
           (rest (match-string 5 url))
           (key (format "%s#%s" repo id))
           (base (format "https://github.com/%s/%s/pull/%s" owner repo id)))
      (pcase type
        ("pull"
         (let ((kind (cond
                      ((string-match-p
                        "#\\(discussion_r\\|issuecomment-\\|pullrequestreview-\\|r[0-9]\\)"
                        rest)
                       'pr-thread)
                      ((string-match "\\`/commits/\\([0-9a-f]\\{7,40\\}\\)" rest) 'commit)
                      ((string-prefix-p "/files" rest) 'pr-files)
                      ((string-prefix-p "/checks" rest) 'pr-checks)
                      (t 'pr))))
           (list :url url :kind kind :repo (concat owner "/" repo)
                 :number (string-to-number id) :key key :pr-url base
                 :label (pcase kind
                          ('pr key)
                          ('pr-thread (concat key " comment"))
                          ('pr-files (concat key " files"))
                          ('pr-checks (concat key " checks"))
                          ('commit (format "%s@%s" repo
                                           (substring (match-string 1 rest) 0 7)))))))
        ("issues"
         (list :url url :kind 'issue :repo (concat owner "/" repo)
               :number (string-to-number id) :key key
               :label (if (string-match-p "#issuecomment-" rest)
                          (concat key " comment")
                        key)))
        ("commit"
         (list :url url :kind 'commit :repo (concat owner "/" repo)
               :label (format "%s@%s" repo (substring id 0 (min 7 (length id))))))))))

(defun decknix-session-urls-classify (url)
  "Return a plist describing URL: at least `:url', `:kind' and `:label'.

Kinds: `pr' (with `pr-files', `pr-checks' and `pr-thread' for its views
and comment anchors), `issue', `commit', `ci', `jira', `confluence' and
`other'.  GitHub PR-ish kinds carry `:key' (`repo#N', the Review Board's
identity), `:repo' (`owner/repo'), `:number' and `:pr-url'."
  (cond
   ((and (decknix-session-urls--ci-p url)
         (not (string-match-p "/pull/[0-9]+\\(/\\|#\\|\\'\\)" url)))
    (list :url url :kind 'ci :label (concat "CI " (decknix-session-urls--short url))))
   ((decknix-session-urls--github url))
   ((string-match "\\`https?://[^/]+/browse/\\([A-Z][A-Z0-9]+-[0-9]+\\)" url)
    (list :url url :kind 'jira :key (match-string 1 url) :label (match-string 1 url)))
   ((string-match-p "\\`https?://[^/]+\\(/wiki/\\|/confluence/\\)\\|\\`https?://confluence\\." url)
    (list :url url :kind 'confluence
          :label (if (string-match "/pages/[0-9]+/\\([^/?#]+\\)" url)
                     (replace-regexp-in-string "[+-]" " " (match-string 1 url))
                   (decknix-session-urls--short url))))
   (t (list :url url :kind 'other :label (decknix-session-urls--short url)))))

(defun decknix-session-urls-pr-views (entry)
  "Return ((NAME . URL) ...) for ENTRY's PR files and checks views, or nil."
  (when-let* ((base (plist-get entry :pr-url)))
    (list (cons "files" (concat base "/files"))
          (cons "checks" (concat base "/checks")))))

(defun decknix-session-urls-pr-key-url (key)
  "Return the PR URL for an `owner/repo#N' KEY, or nil."
  (when (and (stringp key)
             (string-match "\\`\\([^/#]+\\)/\\([^/#]+\\)#\\([0-9]+\\)\\'" key))
    (format "https://github.com/%s/%s/pull/%s"
            (match-string 1 key) (match-string 2 key) (match-string 3 key))))

(defun decknix-session-urls-review-key-from-name (name)
  "Return `repo#N' from a review buffer NAME like `*Agent: auto/#7/widget/review*'.
A fallback only, for a session with no recorded coordinates; it decides
nothing more consequential than whether to offer review keys."
  (when (and (stringp name)
             (string-match "#\\([0-9]+\\)/\\([^/*]+\\)/review\\b" name))
    (format "%s#%s" (match-string 2 name) (match-string 1 name))))

;; ── scanning ─────────────────────────────────────────────────────────

(defun decknix-session-urls--line-at (text pos)
  "Return the trimmed line of TEXT containing POS, at most 70 chars."
  (let* ((bol (let ((i (and (> pos 0) (cl-position ?\n text :end pos :from-end t))))
                (if i (1+ i) 0)))
         (eol (or (cl-position ?\n text :start pos) (length text)))
         (line (string-trim (substring text bol eol))))
    (if (> (length line) 70) (concat (substring line 0 69) "…") line)))

(defun decknix-session-urls--md-title (text start)
  "Return the Markdown link title ending just before START in TEXT, or nil.
START is where a URL begins; `[title](' must immediately precede it."
  (when (and (>= start 2) (eq (aref text (1- start)) ?\() (eq (aref text (- start 2)) ?\]))
    (let ((open (cl-position ?\[ text :end (- start 2) :from-end t)))
      (when (and open
                 (not (cl-position ?\n text :start open :end (- start 2))))
        (substring text (1+ open) (- start 2))))))

(defun decknix-session-urls-scan (text &optional offset)
  "Return the URLs in TEXT in order of appearance, as plists.
Each has `:url', `:pos' (its start, plus OFFSET), `:where' (its line) and
`:title' (the Markdown link text, when it is the target of one)."
  (let ((offset (or offset 0)) (case-fold-search nil) (start 0) out)
    (while (string-match decknix-session-urls-url-regexp text start)
      (let* ((beg (match-beginning 0))
             (url (decknix-session-urls-trim (match-string 0 text))))
        (setq start (match-end 0))
        (when (string-match-p "\\`https?://[^/]+\\..+" url)
          (push (list :url url :pos (+ offset beg)
                      :where (decknix-session-urls--line-at text beg)
                      :title (decknix-session-urls--md-title text beg))
                out))))
    (nreverse out)))

(defun decknix-session-urls-jira-base (text)
  "Return the tracker base URL from the first ticket URL in TEXT, or nil."
  (when (string-match "\\(https?://[^/ \t\n\"'<>()]+\\)/browse/[A-Z][A-Z0-9]+-[0-9]+" text)
    (match-string 1 text)))

(defun decknix-session-urls--key-ok-p (project)
  "Non-nil when PROJECT may start a bare ticket key."
  (if decknix-session-urls-jira-projects
      (member project decknix-session-urls-jira-projects)
    (not (member project decknix-session-urls-key-denylist))))

(defun decknix-session-urls-jira-keys (text base &optional offset)
  "Return bare ticket keys in TEXT resolved against BASE, as URL plists.
Keys inside a URL are skipped (the URL itself is collected).  nil when
BASE is nil: a key with nowhere to open is not offered."
  (when base
    (let ((offset (or offset 0)) (case-fold-search nil) (start 0) out
          (spans (let ((s 0) acc)
                   (while (string-match decknix-session-urls-url-regexp text s)
                     (push (cons (match-beginning 0) (match-end 0)) acc)
                     (setq s (match-end 0)))
                   acc)))
      (while (string-match decknix-session-urls--key-regexp text start)
        (let ((beg (match-beginning 1))
              (key (match-string 1 text))
              (project (match-string 2 text)))
          (setq start (match-end 1))
          (when (and (decknix-session-urls--key-ok-p project)
                     (not (seq-some (lambda (s) (and (>= beg (car s)) (< beg (cdr s)))) spans)))
            (push (list :url (format "%s/browse/%s" (string-remove-suffix "/" base) key)
                        :pos (+ offset beg) :where (decknix-session-urls--line-at text beg)
                        :bare t)
                  out))))
      (nreverse out))))

;; ── collection ───────────────────────────────────────────────────────

(defun decknix-session-urls--norm (url)
  "Return URL normalised for de-duplication."
  (string-remove-suffix "/" url))

(defun decknix-session-urls-collect (identity text &optional offset jira-base)
  "Return the URLs a session is handling, identity first, then most recent.

IDENTITY is a list of plists with `:url' and `:source' (`reviewing',
`linked' or `created'), in the order to show them.  TEXT is the scanned
transcript tail, starting at buffer position OFFSET.  JIRA-BASE resolves
bare ticket keys; nil infers it from TEXT.

Each URL appears once.  An identity URL also seen in TEXT keeps its
identity label and gains the `:pos' of its latest mention."
  (let* ((found (append (decknix-session-urls-scan text offset)
                        (decknix-session-urls-jira-keys
                         text (or jira-base (decknix-session-urls-jira-base text)) offset)))
         (latest (make-hash-table :test 'equal))
         (seen (make-hash-table :test 'equal))
         out)
    (dolist (f found)
      (let* ((k (decknix-session-urls--norm (plist-get f :url)))
             (prev (gethash k latest)))
        (when (or (null prev) (> (plist-get f :pos) (plist-get prev :pos)))
          (puthash k (if (and prev (plist-get prev :title) (not (plist-get f :title)))
                         (plist-put (copy-sequence f) :title (plist-get prev :title))
                       f)
                   latest))))
    (dolist (id identity)
      (let* ((url (plist-get id :url))
             (k (and (stringp url) (decknix-session-urls--norm url))))
        (when (and k (not (gethash k seen)))
          (puthash k t seen)
          (let ((hit (gethash k latest)))
            (push (append (list :source (plist-get id :source)
                                :detail (plist-get id :detail)
                                :pos (and hit (plist-get hit :pos))
                                :where (symbol-name (plist-get id :source)))
                          (decknix-session-urls-classify url))
                  out)))))
    (let (tail)
      (maphash (lambda (k f) (unless (gethash k seen) (push f tail))) latest)
      (setq tail (sort tail (lambda (a b) (> (plist-get a :pos) (plist-get b :pos)))))
      (dolist (f tail)
        (push (append (list :source (if (plist-get f :bare) 'key 'text)
                            :pos (plist-get f :pos)
                            :where (plist-get f :where)
                            :title (plist-get f :title))
                      (decknix-session-urls-classify (plist-get f :url)))
              out)))
    (nreverse out)))

(defun decknix-session-urls-annotation (entry)
  "Return the completion annotation for ENTRY: kind, label, where it appeared."
  (format "  %-10s %-28s %s"
          (symbol-name (plist-get entry :kind))
          (truncate-string-to-width
           (or (plist-get entry :title) (plist-get entry :label) "") 28 nil nil "…")
          (pcase (plist-get entry :source)
            ('reviewing "reviewing")
            ('linked (concat "linked" (if-let* ((d (plist-get entry :detail)))
                                          (format " (%s)" d) "")))
            ('created "created here")
            ('key (concat "key: " (or (plist-get entry :where) "")))
            (_ (or (plist-get entry :where) "")))))

(defun decknix-session-urls-url-around (line col)
  "Return the URL in LINE whose text spans column COL, or nil.
Also answers on the title of a Markdown `[title](url)' link, since that
is all of it you see once agent-shell hides the URL."
  (let ((case-fold-search nil) (start 0) hit)
    (while (and (not hit) (string-match "\\[\\([^]\n]*\\)\\](\\(https?://[^) \t\n]+\\))" line start))
      (when (and (>= col (match-beginning 0)) (< col (match-end 0)))
        (setq hit (decknix-session-urls-trim (match-string 2 line))))
      (setq start (match-end 0)))
    (setq start 0)
    (while (and (not hit) (string-match decknix-session-urls-url-regexp line start))
      (when (and (>= col (match-beginning 0)) (<= col (match-end 0)))
        (setq hit (decknix-session-urls-trim (match-string 0 line))))
      (setq start (match-end 0)))
    hit))

(provide 'decknix-session-urls)
;;; decknix-session-urls.el ends here
