;;; decknix-board-scope.el --- Which repositories and sessions a board covers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, decknix, board

;;; Commentary:
;;
;; A board's repository scope, and the cached facts that place a session
;; in a repository.  Shared by the board and the sidebar's focus, so the
;; two can never disagree about what a board covers.
;;
;;   :repos ("UpsideRealty/upside"          exact owner/name
;;           "UpsideRealty/hack-*"          glob over owner/name
;;           "*/followupboss-*"             glob with any owner
;;           (:regexp "nc-helix/.*-cli"))   anchored regexp over owner/name
;;
;; Without :repos the scope is the board's issue home, :github :repo.
;; Matching ignores case, because the hub's caches lowercase owners and
;; GitHub does not care.
;;
;; A session's repositories come only from caches other features already
;; keep: the PRs it reviews, the PRs it created, the worktree roots its
;; tool calls touched, and its workspace path resolved through the hub's
;; clone map and worktree registry.  Nothing here reads the filesystem or
;; runs git, because the sidebar asks on every paint.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defvar decknix--hub-worktree-clone-map)
(defvar decknix--hub-worktree-cache)
(defvar decknix--agent-broker-key)
(declare-function decknix-session-assoc-current "decknix-session-assoc" (&optional buffer))
(declare-function decknix-session-assoc-created "decknix-session-assoc" (key))

;; --- repository names and patterns ---------------------------------------

(defun decknix-board-repo-short (repo)
  "Return REPO's name without its owner, lower-cased."
  (and (stringp repo)
       (downcase (car (last (split-string repo "/" t))))))

(defun decknix-board-repo-owner (repo)
  "Return REPO's owner, lower-cased, or nil for a bare name."
  (and (stringp repo) (string-match "\\`\\([^/]+\\)/" repo)
       (downcase (match-string 1 repo))))

(defun decknix-board-repo-glob-p (entry)
  "Non-nil when string ENTRY uses glob characters."
  (and (stringp entry) (string-match-p "[*?[]" entry)))

(defun decknix-board--anchored (regexp)
  "Return REGEXP anchored to the whole string."
  (concat "\\`\\(?:" regexp "\\)\\'"))

(defun decknix-board-repo-match-p (entry repo &optional owners)
  "Non-nil when scope ENTRY covers REPO.
REPO is `owner/name', or a bare name when only the directory is known.
A bare name matches an exact or glob ENTRY on its name part alone; it
matches a regexp ENTRY when the regexp accepts `OWNER/name' for one of
OWNERS, since a regexp cannot be split at the slash."
  (when (and (stringp repo) (not (string-empty-p repo)))
    (let ((case-fold-search t)
          (repo (downcase repo))
          (bare (not (string-search "/" repo))))
      (pcase entry
        ((pred stringp)
         (let ((e (downcase (if bare (decknix-board-repo-short entry) entry))))
           (if (decknix-board-repo-glob-p e)
               (string-match-p (wildcard-to-regexp e) repo)
             (string= e repo))))
        (`(:regexp ,rx)
         (let ((re (decknix-board--anchored rx)))
           (if bare
               (seq-some (lambda (o) (string-match-p re (concat o "/" repo))) owners)
             (string-match-p re repo))))))))

;; --- a board's scope -----------------------------------------------------

(defun decknix-board-home-repo (board)
  "Return BOARD's issue home, `owner/name', or nil."
  (plist-get (plist-get board :github) :repo))

(defun decknix-board-scope (board)
  "Return BOARD's repository scope entries: :repos, else its issue home."
  (or (plist-get board :repos)
      (let ((home (decknix-board-home-repo board)))
        (and home (list home)))))

(defun decknix-board-scope-explicit-p (board)
  "Non-nil when BOARD names its repositories with :repos."
  (and (plist-get board :repos) t))

(defun decknix-board-scope-owners (board)
  "Return the owners BOARD names literally, lower-cased.
They bound where a pattern with a wildcard owner is expanded."
  (delete-dups
   (delq nil
         (mapcar (lambda (e)
                   (and (stringp e)
                        (let ((o (decknix-board-repo-owner e)))
                          (and o (not (decknix-board-repo-glob-p o)) o))))
                 (cons (decknix-board-home-repo board) (decknix-board-scope board))))))

(defun decknix-board-scope-exact (board)
  "Return BOARD's scope entries that name one repository each."
  (seq-filter (lambda (e) (and (stringp e) (string-search "/" e)
                               (not (decknix-board-repo-glob-p e))))
              (decknix-board-scope board)))

(defun decknix-board-repo-in-scope-p (board repo)
  "Non-nil when REPO is in BOARD's scope."
  (let ((owners (decknix-board-scope-owners board)))
    (seq-some (lambda (e) (decknix-board-repo-match-p e repo owners))
              (decknix-board-scope board))))

;; --- expansion cache -----------------------------------------------------

(defvar decknix-board-scope--owner-repos (make-hash-table :test 'equal)
  "Owner -> (FETCHED-AT . REPOS) from `gh repo list', filled by backends.")

(defun decknix-board-scope-cached-repos (owner)
  "Return the cached repositories of OWNER, or nil."
  (cdr (gethash (downcase owner) decknix-board-scope--owner-repos)))

(defun decknix-board-scope-known-repos (board)
  "Return the concrete repositories in BOARD's scope known so far.
Exact entries, plus every cached repository of the board's owners that a
pattern accepts.  Never fetches."
  (let ((exact (mapcar #'downcase (decknix-board-scope-exact board)))
        (expanded
         (seq-filter (lambda (r) (decknix-board-repo-in-scope-p board r))
                     (apply #'append
                            (mapcar #'decknix-board-scope-cached-repos
                                    (decknix-board-scope-owners board))))))
    (delete-dups (append exact (mapcar #'downcase expanded)))))

;; --- where a path is -----------------------------------------------------

(defconst decknix-board-path-memo-ttl 30
  "Seconds a resolved path stays memoised.
The caches behind it change when the hub audits worktrees, minutes apart;
the sidebar asks for the same workspaces every two seconds.")

(defvar decknix-board--path-memo (make-hash-table :test 'equal)
  "Path -> repositories, cleared every `decknix-board-path-memo-ttl'.")

(defvar decknix-board--path-memo-at 0
  "When `decknix-board--path-memo' was last cleared.")

(defun decknix-board--under-dir-p (dir root)
  "Non-nil when directory DIR is ROOT or below it.  Both end in a slash."
  (string-prefix-p root dir))

(defun decknix-board--registry-repo (dir)
  "Return the repository whose primary or worktree holds DIR, or nil.
The deepest match wins, so a worktree nested beside its primary resolves
to itself."
  (let (best best-len)
    (when (and (boundp 'decknix--hub-worktree-cache)
               (hash-table-p decknix--hub-worktree-cache))
      (maphash
       (lambda (repo entry)
         (dolist (p (cons (plist-get entry :primary)
                          (mapcar #'cdr (plist-get entry :worktrees))))
           (when (stringp p)
             (let ((root (file-name-as-directory (expand-file-name p))))
               (when (and (decknix-board--under-dir-p dir root)
                          (or (null best-len) (> (length root) best-len)))
                 (setq best repo best-len (length root)))))))
       decknix--hub-worktree-cache))
    best))

(defun decknix-board--clone-map-repo (dir)
  "Return the repository the hub's clone map records for DIR, or nil."
  (and (boundp 'decknix--hub-worktree-clone-map)
       (hash-table-p decknix--hub-worktree-clone-map)
       (let ((v (gethash dir decknix--hub-worktree-clone-map)))
         (and (stringp v) v))))

(defun decknix-board--path-name-guess (dir)
  "Return the bare repository name DIR's layout suggests.
`<repo>-worktrees/<branch>' names its repository in the parent; any other
directory is taken to be a checkout named after its repository."
  (let* ((parts (split-string dir "/" t))
         (wt (seq-find (lambda (p) (string-suffix-p "-worktrees" p)) parts)))
    (downcase (if wt (string-remove-suffix "-worktrees" wt) (car (last parts))))))

(defun decknix-board-path-repos (path)
  "Return the repositories PATH belongs to, from caches only.
The hub's clone map and worktree registry give `owner/name'; without
either, the directory layout gives a bare name."
  (when (and (stringp path) (not (string-empty-p path)))
    (when (> (- (float-time) decknix-board--path-memo-at) decknix-board-path-memo-ttl)
      (clrhash decknix-board--path-memo)
      (setq decknix-board--path-memo-at (float-time)))
    (let ((dir (file-name-as-directory (expand-file-name path))))
      (pcase (gethash dir decknix-board--path-memo 'miss)
        ('miss
         (let ((repos (list (or (decknix-board--clone-map-repo dir)
                                (decknix-board--registry-repo dir)
                                (decknix-board--path-name-guess dir)))))
           (puthash dir repos decknix-board--path-memo)
           repos))
        (hit hit)))))

;; --- where a session is --------------------------------------------------

(defun decknix-board--pr-key-repo (key)
  "Return the repository part of PR KEY `repo#N' or `owner/repo#N'."
  (and (stringp key) (string-match "\\`\\(.+\\)#[0-9]+\\'" key)
       (downcase (match-string 1 key))))

(defun decknix-board--session-observed (session)
  "Return the worktree roots SESSION's tool calls touched, or nil."
  (let ((buf (get-buffer (or (nth 0 session) ""))))
    (and (buffer-live-p buf) (fboundp 'decknix-session-assoc-current)
         (ignore-errors (decknix-session-assoc-current buf)))))

(defun decknix-board--session-created (session)
  "Return the PRs SESSION created, as `owner/repo#N' strings."
  (let ((buf (get-buffer (or (nth 0 session) ""))))
    (and (buffer-live-p buf) (fboundp 'decknix-session-assoc-created)
         (local-variable-p 'decknix--agent-broker-key buf)
         (ignore-errors
           (decknix-session-assoc-created
            (buffer-local-value 'decknix--agent-broker-key buf))))))

(defun decknix-board-session-repos (session)
  "Return the repositories SESSION (NAME TAGS PRS STATE WORKSPACE ...) is in.
From the PRs it reviews and created, the worktrees it worked in, and its
workspace.  Lower-cased; some may be bare names."
  (delete-dups
   (delq nil
         (append
          (mapcar #'decknix-board--pr-key-repo (nth 2 session))
          (mapcar #'decknix-board--pr-key-repo (decknix-board--session-created session))
          (mapcan #'decknix-board-path-repos (decknix-board--session-observed session))
          (decknix-board-path-repos (nth 4 session))))))

(defvar decknix-board-session-repos-function #'decknix-board-session-repos
  "Function (SESSION) returning the repositories SESSION is in.
Tests bind this to a table.")

(defconst decknix-board-min-repo-tag 4
  "Shortest tag that may name a repository.
The sidebar's rule: `us' or `ai' would otherwise claim repos.")

(defun decknix-board-tag-names-repo-p (tag repo)
  "Non-nil when TAG names REPO: its name, or its leading hyphenated segment.
`followupboss' names `followupboss-integration', which is how sessions are
tagged in practice."
  (and (stringp tag) (>= (length tag) decknix-board-min-repo-tag)
       (let ((short (decknix-board-repo-short repo))
             (tag (downcase tag)))
         (or (string= tag short) (string-prefix-p (concat tag "-") short)))))

;; --- PRs from the hub's feeds --------------------------------------------

(defvar decknix--hub-reviews)
(defvar decknix--hub-wip)

(defun decknix-board-feed-prs ()
  "Return the open PRs the hub has cached, as plists.
Reviews asked of me and my own PRs; each (:repo :number :title :url
:branch :draft :source).  Read from memory: no network, no files."
  (append
   (mapcar (lambda (it)
             (list :repo (alist-get 'repo it) :number (alist-get 'number it)
                   :title (alist-get 'title it) :url (alist-get 'url it)
                   :branch (alist-get 'branch it) :draft (alist-get 'draft it)
                   :source 'review))
           (and (boundp 'decknix--hub-reviews) (alist-get 'items decknix--hub-reviews)))
   (mapcan (lambda (repo)
             (mapcar (lambda (pr)
                       (list :repo (alist-get 'repo repo) :number (alist-get 'number pr)
                             :title (alist-get 'title pr) :url (alist-get 'url pr)
                             :branch (alist-get 'branch pr) :draft (alist-get 'draft pr)
                             :source 'mine))
                     (alist-get 'prs repo)))
           (and (boundp 'decknix--hub-wip) (alist-get 'repos decknix--hub-wip)))))

(defun decknix-board-scope-prs (board prs)
  "Return PRS whose repository is in BOARD's scope, once each."
  (let (seen out)
    (dolist (pr prs)
      (let ((k (downcase (format "%s#%s" (plist-get pr :repo) (plist-get pr :number)))))
        (when (and (not (member k seen))
                   (decknix-board-repo-in-scope-p board (plist-get pr :repo)))
          (push k seen)
          (push pr out))))
    (nreverse out)))

(defun decknix-board-pr-references-p (pr item-repo number tag)
  "Non-nil when PR's title or branch refers to issue NUMBER of ITEM-REPO.
TAG is the item's board tag, `repo#N'.  The tag counts anywhere; a bare
`#N' in the title only within the same repository, as GitHub reads it;
a branch named `N-...', `issue-N-...' or `gh-N-...' likewise."
  (let ((case-fold-search t)
        (title (or (plist-get pr :title) ""))
        (branch (or (plist-get pr :branch) ""))
        (n (number-to-string number))
        (same (and item-repo (plist-get pr :repo)
                   (string= (downcase item-repo) (downcase (plist-get pr :repo))))))
    (or (and tag (or (string-match-p (concat (regexp-quote tag) "\\b") title)
                     (string-match-p (regexp-quote tag) branch)))
        (and same
             (or (string-match-p (concat "#" n "\\b") title)
                 (string-match-p (concat "\\(?:\\`\\|/\\)\\(?:issue-\\|gh-\\)?" n
                                         "\\(?:[-_]\\|\\'\\)")
                                 branch))))))

(provide 'decknix-board-scope)
;;; decknix-board-scope.el ends here
