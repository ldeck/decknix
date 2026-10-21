;;; decknix-board-github.el --- GitHub issues backend for boards -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, decknix, board, github

;;; Commentary:
;;
;; Board items as GitHub issues in one repository, chosen per board:
;;
;;   :github (:repo "owner/name"      required
;;            :root 1                 the goal issue; the tree hangs off it
;;            :label-prefix "type:"   type labels, e.g. type:epic
;;            :label "hackathon")     only issues carrying this label
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
   (if hierarchy "parent{number} subIssuesSummary{total completed} " "")
   "closedByPullRequestsReferences(first:5,includeClosedPrs:true)"
   "{nodes{number url state isDraft}}}}}}"))

(defconst decknix-board-github--jq
  (concat
   "(.data.repository.issues.nodes[] | {id, number, title, url, state, "
   (format "body: ((.body // \"\")[0:%d]), " decknix-board-github-body-chars)
   "issueType: .issueType.name, labels: [.labels.nodes[].name], "
   "assignees: [.assignees.nodes[].login], parent: .parent.number, "
   "subTotal: .subIssuesSummary.total, subDone: .subIssuesSummary.completed, "
   "prs: [.closedByPullRequestsReferences.nodes[]]}), "
   "{pageInfo: .data.repository.issues.pageInfo}")
  "Shapes each issue down to what the board draws, inside the subprocess.
The last line carries the page cursor.")

(defun decknix-board-github--list-argv (board hierarchy &optional cursor)
  "Return the `gh' command that lists one page of BOARD's issues.
With HIERARCHY, the query includes sub-issue links.  CURSOR continues
from a previous page.  Pages are walked here rather than with
`--paginate', which cannot stop early on a busy repository."
  (let ((repo (decknix-board-github--split-repo
               (decknix-board-github--conf board :repo))))
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

(defun decknix-board-github--normalise (node prefix)
  "Return the board item for issue NODE, a parsed plist.
PREFIX is the type label prefix."
  (let ((labels (plist-get node :labels)))
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
          :parent (plist-get node :parent)
          :sub-total (plist-get node :subTotal)
          :sub-done (plist-get node :subDone)
          :prs (mapcar (lambda (pr)
                         (list :number (plist-get pr :number)
                               :url (plist-get pr :url)
                               :state (downcase (or (plist-get pr :state) ""))
                               :draft (plist-get pr :isDraft)))
                       (plist-get node :prs)))))

(defun decknix-board-github--parse-node-json (json)
  "Parse one issue JSON object string into a plist."
  (json-parse-string json :object-type 'plist :array-type 'list
                     :null-object nil :false-object nil))

(defun decknix-board-github-parse (text prefix)
  "Return board items from TEXT, one shaped issue JSON per line.
PREFIX is the type label prefix."
  (delq nil
        (mapcar (lambda (line)
                  (let ((node (ignore-errors
                                (decknix-board-github--parse-node-json line))))
                    (and (plist-get node :number)
                         (decknix-board-github--normalise node prefix))))
                (split-string text "\n" t "[ \t\r]+"))))

(defun decknix-board-github--hierarchy-unsupported-p (stderr)
  "Non-nil when STDERR says the server does not know sub-issue fields."
  (and (stringp stderr)
       (string-match-p "parent\\|subIssues" stderr)
       (string-match-p "doesn't exist\\|undefinedField\\|Field '" stderr)))

(cl-defmethod decknix-board-backend-list-items ((_backend (eql github)) board callback)
  "List BOARD's issues; fall back to a flat list without sub-issues."
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
            (decknix-board-github--list-argv board hierarchy cursor)
            (lambda (exit stdout stderr)
              (cond
               ((eq exit 0)
                (let ((acc (append acc (decknix-board-github-parse stdout prefix)))
                      (next (decknix-board-github-next-cursor stdout)))
                  (if (and next (< page decknix-board-github-max-pages))
                      (fetch hierarchy next acc (1+ page))
                    (funcall callback (cons acc (list :hierarchy hierarchy))))))
               ((and hierarchy (null cursor)
                     (decknix-board-github--hierarchy-unsupported-p stderr))
                (fetch nil nil nil 1))
               (t (fail exit stderr)))))))
      (fetch t nil nil 1))))

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
