;;; decknix-board-github.el --- GitHub issues backend for boards -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, decknix, board, github

;;; Commentary:
;;
;; Board items as GitHub issues.  The issue home is one repository,
;; where new items are created:
;;
;;   :github (:repo "owner/name"      required
;;            :root 1                 the goal issue; the tree hangs off it
;;            :label-prefix "type:"   type labels, e.g. type:epic
;;            :label "hackathon")     only issues carrying this label
;;
;; Items are read from every repository in the board's scope (:repos, see
;; `decknix-board-scope'), the home first.  Patterns are expanded with
;; `gh repo list OWNER', cached for `decknix-board-github-repo-list-ttl'.
;; Each repository is one issues query, as for a single-repository board,
;; rather than one `search' across them: search has no repository
;; wildcard either, caps results at 1000 and limits the query's length,
;; and the per-repository query already carries sub-issue links and the
;; PRs that close each issue.  Sub-issues may cross repositories, so each
;; issue's parent is fetched with its repository.
;;
;; The hierarchy comes from GitHub sub-issues: every issue is fetched once
;; with its `parent', and the tree is built client-side.  That is one
;; query per 100 issues whatever the depth, where walking `subIssues' from the
;; root would nest a connection per level and blow GitHub's node budget
;; at four levels.  When the server does not know sub-issues (an older
;; GitHub Enterprise), the same query is retried without them and the
;; board falls back to grouping by type label.
;;
;; The fetch runs in a `gh' subprocess and `--jq' trims each issue to the
;; fields the board draws, so Emacs only parses small JSON lines.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'decknix-board-backend)
(require 'decknix-board-scope)

(defcustom decknix-board-github-program "gh"
  "The GitHub CLI used by boards."
  :type 'string :group 'decknix)

(defcustom decknix-board-github-max-pages 5
  "Pages of 100 issues fetched per refresh.
A board repository is per purpose, so 500 issues is generous; the cap
stops a board pointed at a busy shared repo from fetching forever."
  :type 'integer :group 'decknix)

(defconst decknix-board-github-body-chars 1200
  "Characters of each issue body kept, for briefs and the snapshot.")

(defun decknix-board-github--conf (board key)
  "Return KEY from BOARD's :github settings."
  (plist-get (plist-get board :github) key))

(defun decknix-board-github--label-prefix (board)
  "Return BOARD's type label prefix."
  (or (decknix-board-github--conf board :label-prefix) "type:"))

(defcustom decknix-board-github-max-repos 20
  "Most repositories a board reads issues from.
A pattern like `owner/*' could otherwise fetch a whole organisation every
minute."
  :type 'integer :group 'decknix)

(defcustom decknix-board-github-repo-list-ttl 600
  "Seconds an owner's repository list, used to expand patterns, is reused."
  :type 'integer :group 'decknix)

(defun decknix-board-github--split-repo (repo)
  "Return (OWNER . NAME) for REPO \"owner/name\", or signal."
  (if (and (stringp repo) (string-match "\\`\\([^/ ]+\\)/\\([^/ ]+\\)\\'" repo))
      (cons (match-string 1 repo) (match-string 2 repo))
    (user-error "Board repo must be owner/name, not %S" repo)))

;; --- fetching ------------------------------------------------------------

(defun decknix-board-github--query (hierarchy label)
  "Return the issues query; with HIERARCHY, ask for sub-issue links.
LABEL, when non-nil, restricts the query to issues carrying it."
  (concat
   "query($owner:String!,$name:String!,$endCursor:String){"
   "repository(owner:$owner,name:$name){"
   "issues(first:100,after:$endCursor,states:[OPEN,CLOSED],"
   "orderBy:{field:CREATED_AT,direction:ASC}"
   (if label (format ",labels:[%s]" (json-encode label)) "")
   "){pageInfo{hasNextPage endCursor} nodes{"
   "id number title url state body issueType{name} "
   "labels(first:20){nodes{name}} assignees(first:5){nodes{login}} "
   (if hierarchy
       "parent{number repository{nameWithOwner}} subIssuesSummary{total completed} "
     "")
   "closedByPullRequestsReferences(first:5,includeClosedPrs:true)"
   "{nodes{number url state isDraft}}}}}}"))

(defconst decknix-board-github--jq
  (concat
   "(.data.repository.issues.nodes[] | {id, number, title, url, state, "
   (format "body: ((.body // \"\")[0:%d]), " decknix-board-github-body-chars)
   "issueType: .issueType.name, labels: [.labels.nodes[].name], "
   "assignees: [.assignees.nodes[].login], parent: .parent.number, "
   "parentRepo: .parent.repository.nameWithOwner, "
   "subTotal: .subIssuesSummary.total, subDone: .subIssuesSummary.completed, "
   "prs: [.closedByPullRequestsReferences.nodes[]]}), "
   "{pageInfo: .data.repository.issues.pageInfo}")
  "Shapes each issue down to what the board draws, inside the subprocess.
The last line carries the page cursor.")

(defun decknix-board-github--list-argv (board hierarchy &optional cursor repo)
  "Return the `gh' command that lists one page of BOARD's issues in REPO.
REPO defaults to the board's issue home.  With HIERARCHY, the query
includes sub-issue links.  CURSOR continues from a previous page.  Pages
are walked here rather than with `--paginate', which cannot stop early on
a busy repository."
  (let ((repo (decknix-board-github--split-repo
               (or repo (decknix-board-github--conf board :repo)))))
    (append
     (list decknix-board-github-program "api" "graphql"
           "-f" (concat "owner=" (car repo))
           "-f" (concat "name=" (cdr repo)))
     (and cursor (list "-f" (concat "endCursor=" cursor)))
     (list "-f" (concat "query=" (decknix-board-github--query
                                  hierarchy
                                  (decknix-board-github--conf board :label)))
           "--jq" decknix-board-github--jq))))

(defun decknix-board-github-next-cursor (text)
  "Return the cursor of the next page named in TEXT, or nil on the last."
  (seq-some (lambda (line)
              (let* ((obj (ignore-errors (decknix-board-github--parse-node-json line)))
                     (info (plist-get obj :pageInfo)))
                (and info (plist-get info :hasNextPage) (plist-get info :endCursor))))
            (reverse (split-string text "\n" t "[ \t\r]+"))))

(defun decknix-board-github--item-type (labels issue-type prefix)
  "Return the board type from LABELS (with PREFIX), else ISSUE-TYPE."
  (or (seq-some (lambda (l)
                  (and (string-prefix-p prefix l)
                       (downcase (substring l (length prefix)))))
                labels)
      (and (stringp issue-type) (downcase issue-type))))

(defun decknix-board-github-key (repo number)
  "Return the item key of issue NUMBER in REPO, `owner/name#N' lower-cased."
  (format "%s#%s" (downcase repo) number))

(defun decknix-board-github--normalise (node prefix &optional repo)
  "Return the board item for issue NODE, a parsed plist.
PREFIX is the type label prefix.  REPO, the repository it came from,
gives the item a :key that is unique across repositories, and its
parent one too."
  (let* ((labels (plist-get node :labels))
         (parent (plist-get node :parent))
         (parent-repo (or (plist-get node :parentRepo) repo)))
    (append
     (and repo
          (list :repo repo
                :key (decknix-board-github-key repo (plist-get node :number))
                :parent-key (and parent (decknix-board-github-key parent-repo parent))))
     (list :number (plist-get node :number)
           :id (plist-get node :id)
           :title (or (plist-get node :title) "")
           :url (plist-get node :url)
           :state (downcase (or (plist-get node :state) "open"))
           :body (or (plist-get node :body) "")
           :type (decknix-board-github--item-type
                  labels (plist-get node :issueType) prefix)
           :labels labels
           :assignees (plist-get node :assignees)
           :parent parent
           :sub-total (plist-get node :subTotal)
           :sub-done (plist-get node :subDone)
           :prs (mapcar (lambda (pr)
                          (list :number (plist-get pr :number)
                                :url (plist-get pr :url)
                                :state (downcase (or (plist-get pr :state) ""))
                                :draft (plist-get pr :isDraft)))
                        (plist-get node :prs))))))

(defun decknix-board-github--parse-node-json (json)
  "Parse one issue JSON object string into a plist."
  (json-parse-string json :object-type 'plist :array-type 'list
                     :null-object nil :false-object nil))

(defun decknix-board-github-parse (text prefix &optional repo)
  "Return board items from TEXT, one shaped issue JSON per line.
PREFIX is the type label prefix; REPO the repository they came from."
  (delq nil
        (mapcar (lambda (line)
                  (let ((node (ignore-errors
                                (decknix-board-github--parse-node-json line))))
                    (and (plist-get node :number)
                         (decknix-board-github--normalise node prefix repo))))
                (split-string text "\n" t "[ \t\r]+"))))

(defun decknix-board-github--hierarchy-unsupported-p (stderr)
  "Non-nil when STDERR says the server does not know sub-issue fields."
  (and (stringp stderr)
       (string-match-p "parent\\|subIssues" stderr)
       (string-match-p "doesn't exist\\|undefinedField\\|Field '" stderr)))

;; --- which repositories ------------------------------------------------

(defun decknix-board-github--repo-list-argv (owner)
  "Return the command listing OWNER's unarchived repositories."
  (list decknix-board-github-program "repo" "list" owner
        "--limit" "1000" "--no-archived"
        "--json" "nameWithOwner" "--jq" ".[].nameWithOwner"))

(defun decknix-board-github--owner-fresh-p (owner)
  "Non-nil when OWNER's repository list is cached and young enough."
  (let ((hit (gethash (downcase owner) decknix-board-scope--owner-repos)))
    (and hit (< (- (float-time) (car hit)) decknix-board-github-repo-list-ttl))))

(defun decknix-board-github--patterned-p (board)
  "Non-nil when BOARD's scope has an entry naming more than one repository."
  (seq-some (lambda (e) (not (and (stringp e) (string-search "/" e)
                                  (not (decknix-board-repo-glob-p e)))))
            (decknix-board-scope board)))

(defun decknix-board-github-concrete-repos (board)
  "Return the repositories BOARD reads issues from, from caches.
The issue home first, then exact :repos entries in order, then pattern
matches sorted; one per repository whatever its case, at most
`decknix-board-github-max-repos'."
  (let ((home (decknix-board-github--conf board :repo))
        (seen nil) (out nil))
    (dolist (r (append (and home (list home))
                       (decknix-board-scope-exact board)
                       (sort (seq-remove
                              (lambda (r) (member (downcase r)
                                                  (mapcar #'downcase
                                                          (decknix-board-scope-exact board))))
                              (decknix-board-scope-known-repos board))
                             #'string<)))
      (unless (member (downcase r) seen)
        (push (downcase r) seen)
        (push r out)))
    (seq-take (nreverse out) decknix-board-github-max-repos)))

(defun decknix-board-github-expand (board callback)
  "Call CALLBACK with (REPOS . WARNINGS) once BOARD's patterns are expanded.
Owners whose list is cached and fresh are not fetched again; a board
without patterns runs nothing."
  (let ((owners (and (decknix-board-github--patterned-p board)
                     (seq-remove #'decknix-board-github--owner-fresh-p
                                 (decknix-board-scope-owners board))))
        (warnings nil))
    (if (null owners)
        (funcall callback (cons (decknix-board-github-concrete-repos board) nil))
      (let ((pending (length owners)))
        (dolist (owner owners)
          (decknix-board-run
           (decknix-board-github--repo-list-argv owner)
           (lambda (exit stdout stderr)
             (if (eq exit 0)
                 (puthash (downcase owner)
                          (cons (float-time) (split-string stdout "\n" t "[ \t\r]+"))
                          decknix-board-scope--owner-repos)
               (push (format "could not list %s's repositories: %s"
                             owner (string-trim stderr))
                     warnings))
             (when (zerop (setq pending (1- pending)))
               (funcall callback (cons (decknix-board-github-concrete-repos board)
                                       (nreverse warnings)))))))))))

;; --- listing -------------------------------------------------------------

(defun decknix-board-github--list-repo (board repo callback)
  "List REPO's issues for BOARD; CALLBACK gets (ITEMS . META).
Falls back to a flat list when the server lacks sub-issues."
  (let ((prefix (decknix-board-github--label-prefix board)))
    (cl-labels
        ((fail (exit stderr)
           (funcall callback
                    (cons nil (list :error
                                    (if (string-empty-p (string-trim stderr))
                                        (format "gh exited %s" exit)
                                      (string-trim stderr))))))
         (fetch (hierarchy cursor acc page)
           (decknix-board-run
            (decknix-board-github--list-argv board hierarchy cursor repo)
            (lambda (exit stdout stderr)
              (cond
               ((eq exit 0)
                (let ((acc (append acc (decknix-board-github-parse stdout prefix repo)))
                      (next (decknix-board-github-next-cursor stdout)))
                  (if (and next (< page decknix-board-github-max-pages))
                      (fetch hierarchy next acc (1+ page))
                    (funcall callback (cons acc (list :hierarchy hierarchy))))))
               ((and hierarchy (null cursor)
                     (decknix-board-github--hierarchy-unsupported-p stderr))
                (fetch nil nil nil 1))
               (t (fail exit stderr)))))))
      (fetch t nil nil 1))))

(defun decknix-board-github-merge (board repos results warnings)
  "Merge per-repository RESULTS, in REPOS order, into (ITEMS . META).
Items outside BOARD's issue home are marked :foreign.  Only when every
repository failed is the result an :error; otherwise failures, and
WARNINGS, become a :warning and the board shows what did arrive."
  (let* ((home (downcase (or (decknix-board-github--conf board :repo) "")))
         (ok (seq-remove (lambda (r) (plist-get (cdr r) :error)) results))
         (failed (cl-loop for repo in repos for r in results
                          when (plist-get (cdr r) :error)
                          collect (format "%s: %s" repo (plist-get (cdr r) :error))))
         (items (mapcan (lambda (r)
                          (mapcar (lambda (i)
                                    (if (equal (downcase (or (plist-get i :repo) home)) home)
                                        i
                                      (append i (list :foreign t))))
                                  (car r)))
                        ok)))
    (if (null ok)
        (cons nil (list :error (string-join (append failed warnings) "; ")))
      (cons items
            (append (list :hierarchy (seq-every-p (lambda (r) (plist-get (cdr r) :hierarchy)) ok)
                          :repos repos)
                    (let ((w (append failed warnings)))
                      (and w (list :warning (string-join w "; ")))))))))

(cl-defmethod decknix-board-backend-list-items ((_backend (eql github)) board callback)
  "List the issues of every repository in BOARD's scope, merged."
  (decknix-board-github-expand
   board
   (lambda (expanded)
     (let* ((repos (car expanded))
            (results (make-list (length repos) nil))
            (pending (length repos)))
       (if (null repos)
           (funcall callback (cons nil (list :error "No repository: set :github :repo")))
         (cl-loop for repo in repos for i from 0 do
                  (let ((i i))
                    (decknix-board-github--list-repo
                     board repo
                     (lambda (result)
                       (setf (nth i results) result)
                       (when (zerop (setq pending (1- pending)))
                         (funcall callback
                                  (decknix-board-github-merge
                                   board repos results (cdr expanded)))))))))))))

;; --- creating ------------------------------------------------------------

(defun decknix-board-github--label-argv (repo label)
  "Return the command that makes sure LABEL exists in REPO."
  (list decknix-board-github-program "label" "create" label
        "--repo" repo "--color" "c5def5"
        "--description" "decknix board item type"))

(defun decknix-board-github--create-argv (repo title body labels)
  "Return the command creating an issue TITLE / BODY with LABELS in REPO."
  (append (list decknix-board-github-program "issue" "create"
                "--repo" repo "--title" title "--body" (or body ""))
          (mapcan (lambda (l) (list "--label" l)) labels)))

(defun decknix-board-github--link-argv (parent-id child-url)
  "Return the command making CHILD-URL a sub-issue of PARENT-ID."
  (list decknix-board-github-program "api" "graphql"
        "-f" (concat "query=mutation($parent:ID!,$child:String!){"
                     "addSubIssue(input:{issueId:$parent,subIssueUrl:$child})"
                     "{issue{number}}}")
        "-f" (concat "parent=" parent-id)
        "-f" (concat "child=" child-url)))

(defun decknix-board-github--issue-url (stdout)
  "Return the issue URL `gh issue create' printed in STDOUT, or nil."
  (and (stringp stdout)
       (string-match "https://[^ \t\n]+/issues/[0-9]+" stdout)
       (match-string 0 stdout)))

(defun decknix-board-github-type-label (board type)
  "Return BOARD's label for item TYPE."
  (concat (decknix-board-github--label-prefix board) type))

(cl-defmethod decknix-board-backend-create-item ((_backend (eql github)) board spec callback)
  "Create a GitHub issue from SPEC, labelled by type, linked to its parent.
The type label is created first and its failure ignored: it fails when
the label exists, which is the usual case, and `gh issue create' would
refuse an unknown label."
  (let* ((repo (decknix-board-github--conf board :repo))
         (type (plist-get spec :type))
         (type-label (and type (decknix-board-github-type-label board type)))
         (board-label (decknix-board-github--conf board :label))
         (labels (delq nil (list type-label board-label)))
         (parent (plist-get spec :parent)))
    (decknix-board-github--split-repo repo)
    (cl-labels
        ((create ()
           (decknix-board-run
            (decknix-board-github--create-argv
             repo (plist-get spec :title) (plist-get spec :body) labels)
            (lambda (exit stdout stderr)
              (let ((url (and (eq exit 0)
                              (decknix-board-github--issue-url stdout))))
                (cond
                 ((null url)
                  (funcall callback nil (string-trim (concat stderr stdout))))
                 ((plist-get parent :id)
                  (link url))
                 (t (funcall callback url nil)))))))
         (link (url)
           (decknix-board-run
            (decknix-board-github--link-argv (plist-get parent :id) url)
            (lambda (exit _stdout stderr)
              (funcall callback url
                       (unless (eq exit 0)
                         (format "created %s but could not link it under #%s: %s"
                                 url (plist-get parent :number)
                                 (string-trim stderr))))))))
      (let ((ensure (seq-filter #'identity labels)))
        (if (null ensure)
            (create)
          (let ((pending (length ensure)))
            (dolist (label ensure)
              (decknix-board-run
               (decknix-board-github--label-argv repo label)
               (lambda (&rest _)
                 (when (zerop (setq pending (1- pending)))
                   (create)))))))))))

(cl-defmethod decknix-board-backend-tag-prefix ((_backend (eql github)) board)
  "The repository name: tags read `repo#12', like GitHub's own references."
  (cdr (decknix-board-github--split-repo
        (decknix-board-github--conf board :repo))))

(cl-defmethod decknix-board-backend-describe ((_backend (eql github)) board)
  "The repository, owner/name."
  (decknix-board-github--conf board :repo))

;; --- repository candidates for the wizard ---------------------------------

(defvar decknix-board-github--repos nil
  "Repositories the user can see, most recently pushed first.
Filled asynchronously so the wizard's repo prompt never waits on gh.")

(defun decknix-board-github-refresh-repos ()
  "Start fetching repository candidates for `decknix-board-new'."
  (decknix-board-run
   (list decknix-board-github-program "api"
         "user/repos?per_page=100&sort=pushed" "--jq" ".[].full_name")
   (lambda (exit stdout _stderr)
     (when (eq exit 0)
       (setq decknix-board-github--repos (split-string stdout "\n" t))))))

(provide 'decknix-board-github)
;;; decknix-board-github.el ends here
