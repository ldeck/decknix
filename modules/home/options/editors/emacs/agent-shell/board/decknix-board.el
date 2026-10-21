;;; decknix-board.el --- Per-purpose coordination boards for agent sessions -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, decknix, board

;;; Commentary:
;;
;; A board coordinates one purpose (a hackathon, a pilot, a migration):
;; the goal and its epics, stories, tasks and subtasks from an issue
;; backend, and the live agent sessions working on each of them.
;;
;; Each board is a plain data file, ~/.config/decknix/boards/NAME.eld:
;;
;;   (:name "hack" :title "Hackathon 2026" :goal "Ship X"
;;    :workspace "~/Code/hack"             ; optional
;;    :tags-all ("hackathon") :tags-any nil ; session grouping
;;    :slack-channel "C0123ABCD"            ; optional
;;    :repos ("owner/hack-*")               ; optional, see below
;;    :match either                         ; tags | repos | either | both
;;    :exclude-tags ("archived")            ; optional
;;    :backend github
;;    :github (:repo "owner/name" :root 1 :label-prefix "type:"))
;;
;; Repositories.  :repos is the board's scope: exact `owner/name' entries,
;; globs and `(:regexp RX)' (`decknix-board-scope').  Items are read from
;; every repository in it; :github :repo stays the issue home, where `c'
;; creates.  Without :repos the scope is the issue home alone.
;;
;; Grouping.  A session matches a board's tags when it carries every
;; :tags-all tag, at least one :tags-any tag (when any are given) and
;; sits under :workspace (when given); a board with none of the three
;; matches no session by them, or it would claim every session.  It
;; matches the board's repositories when the cached facts place it in
;; one (`decknix-board-session-repos').  :match combines the two, `either'
;; by default; see `decknix-board-session-in-board-p'.  The sidebar's
;; focus uses the same function, so a board and its focus always agree.
;;
;; Item tags.  A session works on an item when it is tagged
;; `<prefix>#<number>', where the prefix is the repository name for
;; GitHub (`hack#12'), or, inside the board, just `#12' for the issue
;; home.  The repo form stays unambiguous across boards, because tags are
;; global; it also puts a session on its board by itself.  `N' on an item
;; tags a new session that way.
;;
;; Rendering reads only caches: the backend fetch is a subprocess and the
;; sessions come from the snapshot the sidebar already keeps.  A tick
;; costs nothing while the board is hidden or input is pending, and an
;; unchanged board is not redrawn.  Each fetch also writes a Markdown
;; snapshot to ~/.local/state/decknix/boards/NAME.md, so agents can read
;; the plan without Emacs.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'decknix-board-backend)
(require 'decknix-board-scope)
(require 'decknix-board-github)
(require 'decknix-attention)

(declare-function decknix--session-bulk-send-open-compose
                  "decknix-agent-shell-main-session" (bufs))
(declare-function decknix--agent-quickaction-start "decknix-agent-shell-main-link"
                  (name tags workspace command &optional model provider-id mode
                        background review-prs))
(declare-function decknix-agent-provider-select "decknix-agent-provider" ())
(declare-function decknix-agent-purpose-resolve "decknix-agent-purposes" (purpose))
(declare-function decknix--agent-tags-all "decknix-agent-tags-read" ())
(declare-function decknix--agent-tags-for-buffer "decknix-agent-tags-read" (buffer))
(declare-function decknix--hub-review-session-snapshot "decknix-agent-shell-hub" ())
(declare-function agent-shell-buffers "ext:agent-shell" ())
(defvar decknix-agent-default-provider)
(defvar decknix--hub-review-session-snapshot)
(defvar decknix--hub-review-session-snapshot-at)

(defgroup decknix-board nil
  "Per-purpose coordination boards."
  :group 'decknix)

(defcustom decknix-board-directory "~/.config/decknix/boards/"
  "Where board definitions live, one NAME.eld per board."
  :type 'directory :group 'decknix-board)

(defcustom decknix-board-state-directory "~/.local/state/decknix/boards/"
  "Where each board's Markdown snapshot is written for agents to read."
  :type 'directory :group 'decknix-board)

(defcustom decknix-board-tick-interval 10
  "Seconds between session repaints of a visible board."
  :type 'integer :group 'decknix-board)

(defcustom decknix-board-fetch-interval 60
  "Seconds between backend fetches while a board is visible."
  :type 'integer :group 'decknix-board)

(defcustom decknix-board-snapshot-max-age 15
  "Seconds a session snapshot built by the sidebar is reused.
Rebuilding it walks every buffer's status chain; a board repainting every
few seconds can show states that are a few seconds old instead."
  :type 'integer :group 'decknix-board)

(defcustom decknix-board-slack-post-command nil
  "Command that posts a Slack message, as a list.
`--channel ID --message TEXT' are appended.  nil looks for a
`slack-post-message.py' on `exec-path' or in a workspace's
`.nc-tools/bin'.  When there is none, `s' copies the update and opens the
channel instead of posting."
  :type '(choice (const nil) (repeat string)) :group 'decknix-board)

;; --- definitions ---------------------------------------------------------

(defvar decknix-board-reread-functions nil
  "Functions called with a board's name when its definition was written or re-read.
The sidebar's focus caches the definition and drops it here.")

(defun decknix-board-valid-name-p (name)
  "Non-nil when NAME can name a board file and buffer."
  (and (stringp name)
       (let ((case-fold-search nil))
         (string-match-p "\\`[a-z0-9][a-z0-9._-]*\\'" name))))

(defun decknix-board-definition-file (name)
  "Return the definition file for board NAME."
  (expand-file-name (concat name ".eld") decknix-board-directory))

(defun decknix-board-names ()
  "Return the names of every defined board, sorted."
  (let ((dir (expand-file-name decknix-board-directory)))
    (and (file-directory-p dir)
         (sort (mapcar #'file-name-sans-extension
                       (directory-files dir nil "\\.eld\\'"))
               #'string<))))

(defun decknix-board-read-file (file)
  "Return the board defined in FILE.  :name defaults to the file's name."
  (let ((board (with-temp-buffer
                 (insert-file-contents file)
                 (goto-char (point-min))
                 (read (current-buffer)))))
    (unless (and (listp board) (keywordp (car board)))
      (user-error "%s is not a board plist" file))
    (unless (plist-get board :name)
      (setq board (plist-put board :name (file-name-base file))))
    (unless (plist-get board :backend)
      (setq board (plist-put board :backend 'github)))
    board))

(defun decknix-board-read (name)
  "Return the board called NAME."
  (let ((file (decknix-board-definition-file name)))
    (unless (file-exists-p file)
      (user-error "No board %s (expected %s)" name file))
    (decknix-board-read-file file)))

(defun decknix-board-write (board)
  "Write BOARD to its definition file and return the file."
  (let ((file (decknix-board-definition-file (plist-get board :name))))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";; -*- mode: lisp-data -*-\n"
              ";; decknix board.  Edit freely; `g' on the board re-reads it.\n"
              ";; No secrets here: this is plain, shareable data.\n")
      (let ((print-length nil) (print-level nil))
        (pp board (current-buffer))))
    (run-hook-with-args 'decknix-board-reread-functions (plist-get board :name))
    file))

(defun decknix-board-backend (board)
  "Return BOARD's backend symbol."
  (or (plist-get board :backend) 'github))

(defun decknix-board-root (board)
  "Return BOARD's goal item number, from its backend settings, or nil."
  (plist-get (plist-get board (intern (format ":%s" (decknix-board-backend board))))
             :root))

;; --- item identity ------------------------------------------------------

(defun decknix-board-item-key (item)
  "Return ITEM's key, unique across the board's repositories.
`owner/name#N' for an item that knows its repository, else its number."
  (or (plist-get item :key) (plist-get item :number)))

(defun decknix-board-item-parent-key (item)
  "Return the key of ITEM's parent, or nil."
  (if (plist-get item :key) (plist-get item :parent-key) (plist-get item :parent)))

(defun decknix-board--find (items key)
  "Return the item of ITEMS whose key is KEY."
  (seq-find (lambda (i) (equal (decknix-board-item-key i) key)) items))

;; --- tags and grouping ---------------------------------------------------

(defun decknix-board-tag-prefix (board)
  "Return the prefix of the tags of BOARD's issue-home items."
  (or (plist-get board :item-tag-prefix)
      (decknix-board-backend-tag-prefix (decknix-board-backend board) board)))

(defun decknix-board--home-item-p (board item)
  "Non-nil when ITEM lives in BOARD's issue home (or does not say)."
  (let ((repo (plist-get item :repo))
        (home (decknix-board-home-repo board)))
    (or (null repo) (null home) (string= (downcase repo) (downcase home)))))

(defun decknix-board-item-tag (board item)
  "Return the tag that puts a session on BOARD's ITEM, e.g. `hack#12'.
An item from another repository in scope is tagged with that
repository's name, as GitHub writes cross-repository references."
  (format "%s#%s"
          (if (decknix-board--home-item-p board item)
              (decknix-board-tag-prefix board)
            (decknix-board-repo-short (plist-get item :repo)))
          (plist-get item :number)))

(defun decknix-board--under-p (dir root)
  "Non-nil when directory DIR is ROOT or below it.  Pure: no file access."
  (and (stringp dir) (stringp root)
       (let ((d (file-name-as-directory (expand-file-name dir)))
             (r (file-name-as-directory (expand-file-name root))))
         (string-prefix-p r d))))

(defvar decknix-board--known-items (make-hash-table :test 'equal)
  "Board name -> the items its last fetch returned.
Lets the sidebar's focus recognise item tags of a board that is not open.")

(defun decknix-board-context (board &optional items)
  "Return what matching sessions against BOARD needs, computed once.
ITEMS default to the board's last fetch.  A plist: :shorts maps each tag
prefix (lower-cased) to its repository, from the issue home and the
repositories items came from; :keyed is non-nil when items carry keys;
:known lists the concrete repositories in scope."
  (let* ((items (or items (gethash (plist-get board :name) decknix-board--known-items)))
         (home (decknix-board-home-repo board))
         (shorts (list (cons (downcase (decknix-board-tag-prefix board)) home))))
    (dolist (i items)
      (let ((r (plist-get i :repo)))
        (when r
          (let ((short (decknix-board-repo-short r)))
            (unless (assoc short shorts) (push (cons short r) shorts))))))
    (list :shorts (nreverse shorts)
          :keyed (and (seq-some (lambda (i) (plist-get i :key)) items) t)
          :known (decknix-board-scope-known-repos board))))

(defun decknix-board--tag-ref (tag)
  "Return (PREFIX . NUMBER) for an item TAG `prefix#N' or `#N', else nil."
  (and (stringp tag) (string-match "\\`\\([^#]*\\)#\\([0-9]+\\)\\'" tag)
       (cons (match-string 1 tag) (string-to-number (match-string 2 tag)))))

(defun decknix-board--tag-key (board tag ctx in-board)
  "Return the item key TAG names on BOARD, or nil.
A bare `#N' names an issue-home item, and only for a session IN-BOARD;
`repo#N' names an item of any repository the board's items come from."
  (let ((ref (decknix-board--tag-ref tag)))
    (when ref
      (let ((repo (if (string-empty-p (car ref))
                      (and in-board (cons t (decknix-board-home-repo board)))
                    (let ((hit (assoc (downcase (car ref)) (plist-get ctx :shorts))))
                      (and hit (cons t (cdr hit)))))))
        (when repo
          (if (and (plist-get ctx :keyed) (cdr repo))
              (decknix-board-github-key (cdr repo) (cdr ref))
            (cdr ref)))))))

(defun decknix-board--has-full-item-tag-p (tags ctx)
  "Non-nil when TAGS include a `repo#N' tag for one of CTX's repositories."
  (seq-some (lambda (tag)
              (let ((ref (decknix-board--tag-ref tag)))
                (and ref (not (string-empty-p (car ref)))
                     (assoc (downcase (car ref)) (plist-get ctx :shorts)))))
            tags))

(defun decknix-board-match-mode (board)
  "Return how BOARD combines tags and repositories: :match, else `either'."
  (or (plist-get board :match) 'either))

(defun decknix-board--tag-criteria-p (board)
  "Non-nil when BOARD groups sessions by tags or workspace."
  (or (plist-get board :tags-all) (plist-get board :tags-any) (plist-get board :workspace)))

(defun decknix-board--tags-match-p (board session)
  "Non-nil when SESSION meets BOARD's tag and workspace criteria.
A board without any claims nothing by them, or it would claim everything."
  (let ((tags (nth 1 session))
        (all (plist-get board :tags-all))
        (any (plist-get board :tags-any))
        (ws (plist-get board :workspace)))
    (and (decknix-board--tag-criteria-p board)
         (seq-every-p (lambda (tag) (member tag tags)) all)
         (or (null any) (seq-some (lambda (tag) (member tag tags)) any))
         (or (null ws) (decknix-board--under-p (nth 4 session) ws)))))

(defun decknix-board--excluded-p (board session)
  "Non-nil when SESSION carries one of BOARD's :exclude-tags."
  (seq-some (lambda (tag) (member tag (nth 1 session))) (plist-get board :exclude-tags)))

(defun decknix-board-session-repo-match-p (board session &optional ctx)
  "Non-nil when SESSION works in a repository in BOARD's scope.
By the cached facts of `decknix-board-session-repos-function', or failing
those by a tag naming a concrete repository in scope (`followupboss' for
`UpsideRealty/followupboss-integration')."
  (or (seq-some (lambda (r) (decknix-board-repo-in-scope-p board r))
                (funcall decknix-board-session-repos-function session))
      (let ((known (plist-get (or ctx (decknix-board-context board)) :known)))
        (seq-some (lambda (tag)
                    (seq-some (lambda (r) (decknix-board-tag-names-repo-p tag r)) known))
                  (nth 1 session)))))

(defun decknix-board-session-in-board-p (board session &optional ctx)
  "Non-nil when SESSION (NAME TAGS PRS STATE WORKSPACE ...) is on BOARD.
CTX is `decknix-board-context', computed when nil.

An item tag (`repo#N') always claims the session; :exclude-tags always
removes it.  Otherwise :match decides:
  `either' (default)  tags/workspace, or a repository in :repos
  `tags'              tags/workspace only
  `repos'             a repository in scope only
  `both'              a repository in scope, and the tags/workspace
                      when the board sets any
Without :repos, `either' is the tag rule alone, so the issue home does
not quietly pull in every session working in that repository."
  (let ((ctx (or ctx (decknix-board-context board))))
    (and (not (decknix-board--excluded-p board session))
         (or (decknix-board--has-full-item-tag-p (nth 1 session) ctx)
             (pcase (decknix-board-match-mode board)
               ('tags (decknix-board--tags-match-p board session))
               ('repos (decknix-board-session-repo-match-p board session ctx))
               ('both (and (or (not (decknix-board--tag-criteria-p board))
                               (decknix-board--tags-match-p board session))
                           (decknix-board-session-repo-match-p board session ctx)))
               (_ (or (decknix-board--tags-match-p board session)
                      (and (decknix-board-scope-explicit-p board)
                           (decknix-board-session-repo-match-p board session ctx))))))
         t)))

(defun decknix-board-session-item-keys (board session &optional ctx in-board)
  "Return the item keys SESSION is tagged for on BOARD.
IN-BOARD says whether SESSION is on the board, which is what gives a bare
`#N' its meaning; it is computed when not given."
  (let* ((ctx (or ctx (decknix-board-context board)))
         (in-board (if (eq in-board 'unknown)
                       (decknix-board-session-in-board-p board session ctx)
                     in-board)))
    (delete-dups
     (delq nil (mapcar (lambda (tag) (decknix-board--tag-key board tag ctx in-board))
                       (nth 1 session))))))

(defun decknix-board-session-item-numbers (board session)
  "Return the issue-home item numbers SESSION is tagged for on BOARD."
  (let ((ctx (list :shorts (list (cons (downcase (decknix-board-tag-prefix board))
                                       (decknix-board-home-repo board)))
                   :keyed nil)))
    (decknix-board-session-item-keys board session ctx 'unknown)))

(defun decknix-board-group-sessions (board sessions items)
  "Group SESSIONS for BOARD against ITEMS.
Return (:board BOARD-SESSIONS :by-item ALIST :unassigned SESSIONS), where
ALIST maps an item key to its sessions."
  (let ((ctx (decknix-board-context board items))
        (keys (mapcar #'decknix-board-item-key items))
        mine by-item unassigned)
    (dolist (s sessions)
      (when (decknix-board-session-in-board-p board s ctx)
        (push s mine)
        (let ((hits (seq-filter (lambda (k) (member k keys))
                                (decknix-board-session-item-keys board s ctx t))))
          (if (null hits)
              (push s unassigned)
            (dolist (k hits)
              (setf (alist-get k by-item nil nil #'equal)
                    (append (alist-get k by-item nil nil #'equal) (list s))))))))
    (list :board (nreverse mine) :by-item by-item :unassigned (nreverse unassigned))))

(defun decknix-board-item-sessions (key grouping)
  "Return the sessions GROUPING puts on the item with KEY."
  (alist-get key (plist-get grouping :by-item) nil nil #'equal))

;; --- PRs from the hub's feeds --------------------------------------------

(defun decknix-board-link-prs (board items prs)
  "Return (:by-item ALIST :prs SCOPED) linking BOARD's scoped PRS to ITEMS.
A PR links to an item that GitHub already says it closes, or whose tag
or number its title or branch names (`decknix-board-pr-references-p').
SCOPED is every PR in scope, each with :items, the keys it links to."
  (let ((home (decknix-board-home-repo board))
        by-item scoped)
    (dolist (pr (decknix-board-scope-prs board prs))
      (let* ((url (plist-get pr :url))
             (hits (seq-filter
                    (lambda (i)
                      (or (and url (seq-some (lambda (p) (equal (plist-get p :url) url))
                                             (plist-get i :prs)))
                          (decknix-board-pr-references-p
                           pr (or (plist-get i :repo) home) (plist-get i :number)
                           (decknix-board-item-tag board i))))
                    items))
             (keys (mapcar #'decknix-board-item-key hits)))
        (dolist (k keys)
          (setf (alist-get k by-item nil nil #'equal)
                (append (alist-get k by-item nil nil #'equal) (list pr))))
        (push (append pr (list :items keys)) scoped)))
    (list :by-item by-item :prs (nreverse scoped))))

;; --- the item tree -------------------------------------------------------

(defun decknix-board--item-less-p (a b)
  "Order items A and B by type depth, then repository, then number."
  (let ((ra (decknix-board-type-rank (plist-get a :type)))
        (rb (decknix-board-type-rank (plist-get b :type)))
        (pa (or (plist-get a :repo) ""))
        (pb (or (plist-get b :repo) "")))
    (cond ((/= ra rb) (< ra rb))
          ((not (string= pa pb)) (string< pa pb))
          (t (< (plist-get a :number) (plist-get b :number))))))

(defun decknix-board-tree (items root hierarchy &optional home)
  "Arrange ITEMS for display.
With HIERARCHY (items carry parent links) return (:nodes NODES :unlinked
NODES), each node (ITEM . CHILD-NODES).  NODES is the tree under issue
ROOT of repository HOME when it is among ITEMS, else every top-level
item; :unlinked holds the other top-level trees.  Without HIERARCHY
return (:flat GROUPS), an alist of type to items, outermost type first."
  (if (not hierarchy)
      (let (groups)
        (dolist (item (sort (copy-sequence items) #'decknix-board--item-less-p))
          (let ((type (or (plist-get item :type) "untyped")))
            (setf (alist-get type groups nil nil #'equal)
                  (append (alist-get type groups nil nil #'equal) (list item)))))
        (list :flat (sort groups (lambda (a b)
                                   (< (decknix-board-type-rank (car a))
                                      (decknix-board-type-rank (car b)))))))
    (let ((by-key (make-hash-table :test 'equal))
          (children (make-hash-table :test 'equal))
          (seen (make-hash-table :test 'equal))
          top)
      (dolist (item items) (puthash (decknix-board-item-key item) item by-key))
      (dolist (item items)
        (let ((parent (decknix-board-item-parent-key item)))
          (if (and parent (gethash parent by-key))
              (puthash parent (cons item (gethash parent children)) children)
            (push item top))))
      (cl-labels ((build (item)
                    ;; A cycle is impossible on GitHub, but a hand-edited
                    ;; backend must not hang the render.
                    (puthash (decknix-board-item-key item) t seen)
                    (cons item
                          (mapcar #'build
                                  (seq-remove
                                   (lambda (c) (gethash (decknix-board-item-key c) seen))
                                   (sort (copy-sequence
                                          (gethash (decknix-board-item-key item) children))
                                         #'decknix-board--item-less-p))))))
        (let* ((top (sort top #'decknix-board--item-less-p))
               (root-item (and root
                               (seq-find
                                (lambda (i)
                                  (and (eql (plist-get i :number) root)
                                       (or (null home) (null (plist-get i :repo))
                                           (string= (downcase home)
                                                    (downcase (plist-get i :repo))))))
                                top))))
          (if root-item
              (list :nodes (list (build root-item))
                    :unlinked (mapcar #'build (remq root-item top)))
            (list :nodes (mapcar #'build top) :unlinked nil)))))))

(defun decknix-board-board-tree (board items meta)
  "Return BOARD's tree of ITEMS, hierarchical when META says so."
  (decknix-board-tree items (decknix-board-root board) (plist-get meta :hierarchy)
                      (decknix-board-home-repo board)))

(defun decknix-board-ancestors (items item)
  "Return ITEM's ancestors among ITEMS, outermost first."
  (let (chain (seen nil) (cur item))
    (while (and cur (decknix-board-item-parent-key cur)
                (not (member (decknix-board-item-parent-key cur) seen)))
      (push (decknix-board-item-parent-key cur) seen)
      (setq cur (decknix-board--find items (decknix-board-item-parent-key cur)))
      (when cur (push cur chain)))
    chain))

;; --- text for people and agents -----------------------------------------

(defun decknix-board--item-ref (item)
  "Return `#3' for ITEM, or `repo#3' when it is from another repository."
  (format "%s#%s"
          (if (plist-get item :foreign) (decknix-board-repo-short (plist-get item :repo)) "")
          (plist-get item :number)))

(defun decknix-board--item-label (item)
  "Return `epic #3 Title' for ITEM."
  (format "%s%s %s"
          (if (plist-get item :type) (concat (plist-get item :type) " ") "")
          (decknix-board--item-ref item) (plist-get item :title)))

(defun decknix-board--excerpt (text n)
  "Return TEXT trimmed to N characters with an ellipsis when cut."
  (let ((s (string-trim (replace-regexp-in-string "\r" "" (or text "")))))
    (if (> (length s) n) (concat (substring s 0 n) "...") s)))

(defun decknix-board-snapshot-file (board)
  "Return BOARD's Markdown snapshot file."
  (expand-file-name (concat (plist-get board :name) ".md")
                    decknix-board-state-directory))

(defun decknix-board-session-brief (board item ancestors)
  "Return the first prompt for a session working on BOARD's ITEM.
ANCESTORS is ITEM's parent chain, outermost first."
  (let ((channel (plist-get board :slack-channel)))
    (string-join
     (delq nil
           (list
            (format "You are working on %s for the %s board."
                    (decknix-board--item-label item)
                    (or (plist-get board :title) (plist-get board :name)))
            (format "Board goal: %s" (or (plist-get board :goal) "(none stated)"))
            (and ancestors
                 (format "Parent chain: %s"
                         (mapconcat #'decknix-board--item-label ancestors " > ")))
            (format "Item: %s" (or (decknix-board-backend-item-url
                                    (decknix-board-backend board) board item)
                                   ""))
            (let ((body (decknix-board--excerpt (plist-get item :body) 800)))
              (and (not (string-empty-p body)) (concat "Description:\n" body)))
            (format "Whole plan, and which session is on which item: %s (refreshed every minute while the board is open)."
                    (abbreviate-file-name (decknix-board-snapshot-file board)))
            (format "This session is tagged %s; a new item's sessions use its own tag the same way."
                    (decknix-board-item-tag board item))
            (and channel (format "Team channel: Slack %s." channel))
            "Start by reading the item and proposing a short plan before changing anything."))
     "\n\n")))

(defun decknix-board--session-names (sessions)
  "Return SESSIONS' buffer names joined."
  (mapconcat (lambda (s) (format "`%s`" (nth 0 s))) sessions ", "))

(defun decknix-board-markdown (board tree grouping &optional now)
  "Return BOARD's Markdown snapshot from TREE and session GROUPING.
NOW is the time to stamp, for tests."
  (let ((by-item (plist-get grouping :by-item)))
    (with-temp-buffer
      (insert (format "# %s\n\n" (or (plist-get board :title) (plist-get board :name))))
      (insert (format "Goal: %s\n\n" (or (plist-get board :goal) "(none)")))
      (insert (format "Items: %s\n" (decknix-board-backend-describe
                                     (decknix-board-backend board) board)))
      (when (plist-get board :slack-channel)
        (insert (format "Slack channel: %s\n" (plist-get board :slack-channel))))
      (insert (format "Updated: %s\n\n"
                      (format-time-string "%Y-%m-%d %H:%M %Z" (or now (current-time)))))
      (insert (format "A session tagged `%s#N` (or `#N` with the board's tags) works on item N; items from other repositories use their repository's name.\n\n"
                      (decknix-board-tag-prefix board)))
      (cl-labels ((line (item depth)
                    (insert (make-string (* 2 depth) ?\s)
                            (format "- [%s] %s"
                                    (if (equal (plist-get item :state) "closed") "x" " ")
                                    (decknix-board--item-label item)))
                    (when (plist-get item :assignees)
                      (insert " (" (mapconcat (lambda (a) (concat "@" a))
                                              (plist-get item :assignees) " ")
                              ")"))
                    (let ((ss (alist-get (decknix-board-item-key item) by-item nil nil #'equal)))
                      (when ss (insert " sessions: " (decknix-board--session-names ss))))
                    (insert "\n"))
                  (node (n depth)
                    (line (car n) depth)
                    (dolist (c (cdr n)) (node c (1+ depth)))))
        (if (plist-get tree :flat)
            (dolist (group (plist-get tree :flat))
              (insert (format "## %s\n\n" (capitalize (car group))))
              (dolist (item (cdr group)) (line item 0))
              (insert "\n"))
          (dolist (n (plist-get tree :nodes)) (node n 0))
          (when (plist-get tree :unlinked)
            (insert "\n## Outside the goal\n\n")
            (dolist (n (plist-get tree :unlinked)) (node n 0)))))
      (when (plist-get grouping :unassigned)
        (insert "\n## Sessions on no item\n\n")
        (dolist (s (plist-get grouping :unassigned))
          (insert (format "- `%s` (%s)\n" (nth 0 s) (or (nth 3 s) "unknown")))))
      (buffer-string))))

(defun decknix-board-slack-text (board item items grouping)
  "Return a status update for BOARD, or for ITEM when non-nil.
ITEMS are all the board's items; GROUPING its sessions."
  (let* ((by-item (plist-get grouping :by-item))
         (subject (if item
                      (cons item (seq-filter
                                  (lambda (i)
                                    (seq-some (lambda (a) (equal (decknix-board-item-key a)
                                                                 (decknix-board-item-key item)))
                                              (decknix-board-ancestors items i)))
                                  items))
                    items))
         (open (seq-count (lambda (i) (not (equal (plist-get i :state) "closed"))) subject))
         (done (- (length subject) open))
         (need (seq-filter (lambda (s) (decknix-attention-state-p (nth 3 s)))
                           (plist-get grouping :board))))
    (string-join
     (delq nil
           (list
            (if item
                (format "%s: %s" (decknix-board--item-label item)
                        (or (plist-get item :url) ""))
              (format "%s update" (or (plist-get board :title) (plist-get board :name))))
            (format "%d done, %d open%s" done open
                    (if (plist-get grouping :board)
                        (format ", %d agent session%s"
                                (length (plist-get grouping :board))
                                (if (= 1 (length (plist-get grouping :board))) "" "s"))
                      ""))
            (and need (format "Waiting on people: %s"
                              (mapconcat (lambda (s) (nth 0 s)) need ", ")))
            (let ((active (seq-filter
                           (lambda (i) (and (not (equal (plist-get i :state) "closed"))
                                            (alist-get (decknix-board-item-key i) by-item
                                                       nil nil #'equal)))
                           subject)))
              (and active
                   (concat "In progress:\n"
                           (mapconcat (lambda (i)
                                        (format "- %s %s" (decknix-board--item-ref i)
                                                (plist-get i :title)))
                                      active "\n"))))))
     "\n")))

;; --- live sessions -------------------------------------------------------

(defun decknix-board--snapshot ()
  "Return the live session tuples, reusing the sidebar's recent snapshot."
  (or (and (boundp 'decknix--hub-review-session-snapshot)
           (boundp 'decknix--hub-review-session-snapshot-at)
           decknix--hub-review-session-snapshot
           (numberp decknix--hub-review-session-snapshot-at)
           (< (- (float-time) decknix--hub-review-session-snapshot-at)
              decknix-board-snapshot-max-age)
           decknix--hub-review-session-snapshot)
      (and (fboundp 'decknix--hub-review-session-snapshot)
           (ignore-errors (decknix--hub-review-session-snapshot)))))

(defun decknix-board-live-sessions ()
  "Return live sessions (NAME TAGS PRS STATE WORKSPACE ...), states current.
The attention table is preferred: it is updated whenever anything
computes a state, so it is fresher than an older snapshot."
  (delq nil
        (mapcar (lambda (s)
                  (let ((buf (get-buffer (or (nth 0 s) ""))))
                    (when (buffer-live-p buf)
                      (let ((state (or (decknix-attention-observed-state buf) (nth 3 s))))
                        (append (list (nth 0 s) (nth 1 s) (nth 2 s) state)
                                (nthcdr 4 s))))))
                (decknix-board--snapshot))))

;; --- buffer state --------------------------------------------------------

(defvar-local decknix-board--board nil "The board this buffer shows.")
(defvar-local decknix-board--items nil "Last fetched items.")
(defvar-local decknix-board--meta nil "Last fetch's META plist.")
(defvar-local decknix-board--error nil "Last fetch error, or nil.")
(defvar-local decknix-board--fetched-at nil "When the last fetch finished.")
(defvar-local decknix-board--fetching nil "Non-nil while a fetch runs.")
(defvar-local decknix-board--fetch-started nil "When the last fetch began.")
(defvar-local decknix-board--collapsed nil "Keys of the items folded in the view.")
(defvar-local decknix-board--fingerprint nil "Inputs of the last render.")
(defvar-local decknix-board--snapshot-text nil "Last Markdown snapshot written.")

(defvar decknix-board--timer nil "Shared tick for every board buffer.")

(defun decknix-board-buffer-name (name)
  "Return the buffer name for board NAME."
  (format "*Board: %s*" name))

(defun decknix-board--buffers ()
  "Return the live board buffers."
  (seq-filter (lambda (b) (buffer-local-value 'decknix-board--board b))
              (buffer-list)))

;; --- rendering -----------------------------------------------------------

(defun decknix-board--state-glyph (state)
  "Return a propertized glyph for session STATE."
  (cond ((decknix-attention-state-p state)
         (propertize decknix-attention-glyph 'face 'decknix-attention-face))
        ((equal state "working") (propertize "◐" 'face 'warning))
        (t (propertize "●" 'face 'shadow))))

(defun decknix-board--insert-session (session indent)
  "Insert a row for SESSION at INDENT."
  (let ((start (point))
        (buf (get-buffer (nth 0 session))))
    (insert (make-string indent ?\s)
            (decknix-board--state-glyph (nth 3 session)) " "
            (format "%-8s " (or (nth 3 session) "?"))
            (nth 0 session))
    (let ((since (and buf (decknix-attention-state-p (nth 3 session))
                      (decknix-attention-since buf))))
      (when since
        (insert (propertize (format "  %s" (decknix-attention-age-label since))
                            'face 'shadow))))
    (insert "\n")
    (add-text-properties start (point) (list 'decknix-board-session buf
                                             'decknix-board-row t))))

(defun decknix-board--pr-label (pr)
  "Return ` PR #N draft' for PR, naming its repository when it is a feed PR."
  (format "  PR %s#%s%s"
          (if (plist-get pr :source) (decknix-board-repo-short (plist-get pr :repo)) "")
          (plist-get pr :number)
          (cond ((equal (plist-get pr :state) "merged") " merged")
                ((plist-get pr :draft) " draft")
                ((equal (plist-get pr :state) "closed") " closed")
                (t ""))))

(defun decknix-board--item-prs (item feed)
  "Return ITEM's PRs: those GitHub links, then FEED PRs naming it."
  (append (plist-get item :prs)
          (seq-remove (lambda (pr)
                        (seq-some (lambda (p) (equal (plist-get p :url) (plist-get pr :url)))
                                  (plist-get item :prs)))
                      feed)))

(defun decknix-board--item-line (item depth folded children-p &optional feed)
  "Return ITEM's row text at DEPTH; FOLDED and CHILDREN-P set the marker.
FEED holds the hub's open PRs that name ITEM."
  (let* ((closed (equal (plist-get item :state) "closed"))
         (prs (decknix-board--item-prs item feed)))
    (concat
     (make-string (* 2 depth) ?\s)
     (cond ((not children-p) "  ") (folded "▸ ") (t "▾ "))
     (if closed (propertize "✓ " 'face 'success) "  ")
     (if (plist-get item :type)
         (propertize (format "%-7s " (plist-get item :type)) 'face 'font-lock-type-face)
       "")
     (propertize (concat (decknix-board--item-ref item) " ") 'face 'font-lock-constant-face)
     (propertize (plist-get item :title) 'face (if closed 'shadow 'default))
     (if (and (plist-get item :sub-total) (> (plist-get item :sub-total) 0))
         (propertize (format "  %s/%s" (plist-get item :sub-done) (plist-get item :sub-total))
                     'face 'shadow)
       "")
     (if (plist-get item :assignees)
         (propertize (concat "  " (mapconcat (lambda (a) (concat "@" a))
                                             (plist-get item :assignees) " "))
                     'face 'font-lock-variable-name-face)
       "")
     (mapconcat (lambda (pr) (propertize (decknix-board--pr-label pr)
                                         'face 'font-lock-keyword-face))
                prs ""))))

(defun decknix-board--insert-node (node depth by-item &optional pr-links)
  "Insert tree NODE at DEPTH, with its sessions from BY-ITEM.
PR-LINKS maps item keys to the feed PRs that name them."
  (let* ((item (car node))
         (key (decknix-board-item-key item))
         (folded (member key decknix-board--collapsed))
         (start (point)))
    (insert (decknix-board--item-line item depth folded (cdr node)
                                      (alist-get key pr-links nil nil #'equal))
            "\n")
    (add-text-properties start (point) (list 'decknix-board-item item
                                             'decknix-board-row t))
    (dolist (s (alist-get key by-item nil nil #'equal))
      (decknix-board--insert-session s (+ 6 (* 2 depth))))
    (unless folded
      (dolist (c (cdr node)) (decknix-board--insert-node c (1+ depth) by-item pr-links)))))

(defun decknix-board--heading (text)
  "Insert section heading TEXT."
  (insert "\n" (propertize text 'face 'bold) "\n"))

(defun decknix-board--scope-label (board)
  "Return BOARD's repository scope as one line, or nil without :repos."
  (when (decknix-board-scope-explicit-p board)
    (mapconcat (lambda (e) (if (stringp e) e (format "/%s/" (cadr e))))
               (decknix-board-scope board) ", ")))

(defun decknix-board--scoped-feed (board)
  "Return the hub's cached open PRs in BOARD's scope."
  (decknix-board-scope-prs board (decknix-board-feed-prs)))

(defun decknix-board--insert-prs (links items)
  "Insert the Open PRs section from LINKS (`decknix-board-link-prs')."
  (let ((prs (plist-get links :prs)))
    (when prs
      (decknix-board--heading (format "Open PRs (%d)" (length prs)))
      (dolist (pr prs)
        (let ((start (point))
              (refs (mapcar (lambda (k)
                              (let ((i (decknix-board--find items k)))
                                (if i (decknix-board--item-ref i) (format "%s" k))))
                            (plist-get pr :items))))
          (insert "  "
                  (propertize (format "%s#%s" (decknix-board-repo-short (plist-get pr :repo))
                                      (plist-get pr :number))
                              'face 'font-lock-keyword-face)
                  (if (plist-get pr :draft) (propertize " draft" 'face 'shadow) "")
                  " " (or (plist-get pr :title) "")
                  (if refs
                      (propertize (concat "  -> " (string-join refs " ")) 'face 'shadow)
                    (propertize "  (no item)" 'face 'shadow))
                  "\n")
          (add-text-properties start (point) (list 'decknix-board-pr pr
                                                   'decknix-board-row t)))))))

(defun decknix-board--draw (sessions &optional feed)
  "Redraw the current board buffer from its caches, SESSIONS and FEED.
FEED is the hub's open PRs in the board's scope."
  (let* ((board decknix-board--board)
         (items decknix-board--items)
         (grouping (decknix-board-group-sessions board sessions items))
         (tree (decknix-board-board-tree board items decknix-board--meta))
         (by-item (plist-get grouping :by-item))
         (links (decknix-board-link-prs board items feed))
         (inhibit-read-only t)
         (row (or (get-text-property (point) 'decknix-board-item)
                  (get-text-property (point) 'decknix-board-session)))
         (line (line-number-at-pos)))
    (erase-buffer)
    (insert (propertize (or (plist-get board :title) (plist-get board :name))
                        'face '(:inherit bold :height 1.2))
            "\n")
    (when (plist-get board :goal)
      (insert "Goal: " (plist-get board :goal) "\n"))
    (insert (format "Items: %s" (decknix-board-backend-describe
                                 (decknix-board-backend board) board)))
    (when (plist-get board :slack-channel)
      (insert "   Slack: " (plist-get board :slack-channel)))
    (insert "\n")
    (let ((scope (decknix-board--scope-label board)))
      (when scope
        (insert "Repos: " scope
                (let ((read (plist-get decknix-board--meta :repos)))
                  (if read (propertize (format "   (%d read)" (length read)) 'face 'shadow) ""))
                (propertize (format "   match %s" (decknix-board-match-mode board)) 'face 'shadow)
                "\n")))
    (let ((open (seq-count (lambda (i) (not (equal (plist-get i :state) "closed"))) items)))
      (insert (format "%d open, %d done, %d session%s   fetched %s%s\n"
                      open (- (length items) open)
                      (length (plist-get grouping :board))
                      (if (= 1 (length (plist-get grouping :board))) "" "s")
                      (if decknix-board--fetched-at
                          (format-time-string "%H:%M:%S" decknix-board--fetched-at)
                        (if decknix-board--fetching "now..." "never"))
                      (if (and items (not (plist-get decknix-board--meta :hierarchy)))
                          "   (no sub-issues: grouped by type)" ""))))
    (when decknix-board--error
      (insert (propertize (concat "Fetch failed: " decknix-board--error) 'face 'error) "\n"))
    (when (plist-get decknix-board--meta :warning)
      (insert (propertize (concat "Partly fetched: " (plist-get decknix-board--meta :warning))
                          'face 'warning)
              "\n"))
    (insert (propertize "RET open  N new session  c create child  j jump  b broadcast  s slack  TAB fold  g refresh  e edit  ? help"
                        'face 'shadow)
            "\n")
    (let ((need (decknix-attention-ordered-sessions (plist-get grouping :board))))
      (when need
        (decknix-board--heading (format "%s Needs you (%d)" decknix-attention-glyph (length need)))
        (dolist (s need) (decknix-board--insert-session s 2))))
    (let ((pr-links (plist-get links :by-item)))
      (cond
       ((plist-get tree :flat)
        (dolist (group (plist-get tree :flat))
          (decknix-board--heading (capitalize (car group)))
          (dolist (item (cdr group))
            (decknix-board--insert-node (list item) 0 by-item pr-links))))
       (t
        (decknix-board--heading "Plan")
        (if (plist-get tree :nodes)
            (dolist (n (plist-get tree :nodes))
              (decknix-board--insert-node n 0 by-item pr-links))
          (insert (propertize (if decknix-board--fetched-at
                                  "  No items yet: c creates one."
                                "  Fetching...")
                              'face 'shadow)
                  "\n"))
        (when (plist-get tree :unlinked)
          (decknix-board--heading "Outside the goal")
          (dolist (n (plist-get tree :unlinked))
            (decknix-board--insert-node n 0 by-item pr-links))))))
    (decknix-board--insert-prs links items)
    (when (plist-get grouping :unassigned)
      (decknix-board--heading "Sessions on no item")
      (dolist (s (plist-get grouping :unassigned)) (decknix-board--insert-session s 2)))
    (decknix-board--restore-point row line)
    (list tree grouping)))

(defun decknix-board--restore-point (row line)
  "Return to the row showing ROW, else to LINE."
  (goto-char (point-min))
  (let ((found (and row
                    (text-property-search-forward
                     (if (bufferp row) 'decknix-board-session 'decknix-board-item)
                     row
                     (lambda (want have)
                       (if (bufferp want) (eq want have)
                         (equal (decknix-board-item-key want)
                                (and have (decknix-board-item-key have)))))))))
    (if found
        (goto-char (prop-match-beginning found))
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun decknix-board--fingerprint-of (sessions feed)
  "Return the render inputs of the current buffer with SESSIONS and FEED."
  (list (mapcar (lambda (s) (list (nth 0 s) (nth 1 s) (nth 3 s) (nth 4 s))) sessions)
        (mapcar (lambda (pr) (list (plist-get pr :url) (plist-get pr :title)
                                   (plist-get pr :draft)))
                feed)
        decknix-board--items decknix-board--meta decknix-board--error
        decknix-board--fetched-at decknix-board--fetching decknix-board--collapsed
        decknix-board--board))

(defun decknix-board--render (&optional force)
  "Render the current board buffer unless nothing changed, or FORCE."
  (let* ((sessions (decknix-board-live-sessions))
         (feed (decknix-board--scoped-feed decknix-board--board))
         (fp (decknix-board--fingerprint-of sessions feed)))
    (when (or force (not (equal fp decknix-board--fingerprint)))
      (setq decknix-board--fingerprint fp)
      ;; A tick redraws a board shown in an unselected window, whose
      ;; cursor is the window's point, not the buffer's.
      (let ((win (get-buffer-window (current-buffer) t)))
        (when win (goto-char (window-point win)))
        (decknix-board--draw sessions feed)
        (when win (set-window-point win (point)))))))

;; --- fetching ------------------------------------------------------------

(defun decknix-board--write-snapshot (buf)
  "Write BUF's board snapshot when its text changed."
  (with-current-buffer buf
    (let* ((sessions (decknix-board-live-sessions))
           (board decknix-board--board)
           (tree (decknix-board-board-tree board decknix-board--items decknix-board--meta))
           (grouping (decknix-board-group-sessions board sessions decknix-board--items))
           (text (decknix-board-markdown board tree grouping))
           (body (replace-regexp-in-string "^Updated: .*\n" "" text)))
      (unless (equal body decknix-board--snapshot-text)
        (setq decknix-board--snapshot-text body)
        (let ((file (decknix-board-snapshot-file board)))
          (ignore-errors
            (make-directory (file-name-directory file) t)
            (let ((coding-system-for-write 'utf-8))
              (write-region text nil file nil 'silent))))))))

(defun decknix-board--fetch (buf)
  "Start fetching BUF's items unless a fetch is already running."
  (with-current-buffer buf
    (unless decknix-board--fetching
      (setq decknix-board--fetching t
            decknix-board--fetch-started (float-time))
      (decknix-board-backend-list-items
       (decknix-board-backend decknix-board--board) decknix-board--board
       (lambda (result)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq decknix-board--fetching nil)
             (if (plist-get (cdr result) :error)
                 (setq decknix-board--error (plist-get (cdr result) :error))
               (setq decknix-board--items (car result)
                     decknix-board--meta (cdr result)
                     decknix-board--error nil
                     decknix-board--fetched-at (current-time))
               (puthash (plist-get decknix-board--board :name) (car result)
                        decknix-board--known-items)
               (decknix-board--write-snapshot buf))
             (decknix-board--render))))))))

(defun decknix-board--due-p ()
  "Non-nil when the current board buffer should fetch again."
  (let ((age (and decknix-board--fetch-started
                  (- (float-time) decknix-board--fetch-started))))
    (or (null age)
        (and (not decknix-board--fetching) (> age decknix-board-fetch-interval))
        ;; A fetch whose sentinel never ran (gh wedged on auth, a killed
        ;; process buffer) must not freeze the board for the session.
        (and decknix-board--fetching (> age (* 5 decknix-board-fetch-interval))
             (progn (setq decknix-board--fetching nil) t)))))

(defun decknix-board--tick ()
  "Repaint visible boards and fetch the stale ones.
Skips everything while input is pending or a minibuffer is open, so a
board never competes with typing."
  (let ((boards (decknix-board--buffers)))
    (if (null boards)
        (decknix-board--stop)
      (unless (or (input-pending-p) (active-minibuffer-window))
        (dolist (buf boards)
          (when (get-buffer-window buf t)
            (with-current-buffer buf
              (when (decknix-board--due-p) (decknix-board--fetch buf))
              (decknix-board--render))))))))

(defun decknix-board--start ()
  "Start the shared tick."
  (unless (timerp decknix-board--timer)
    (setq decknix-board--timer
          (run-with-timer decknix-board-tick-interval decknix-board-tick-interval
                          #'decknix-board--tick))))

(defun decknix-board--stop ()
  "Stop the shared tick."
  (when (timerp decknix-board--timer)
    (cancel-timer decknix-board--timer))
  (setq decknix-board--timer nil))

;; --- commands ------------------------------------------------------------

(defvar decknix-board-history nil "Board names picked before.")
(defvar decknix-board-repo-history nil "Repositories typed into the wizard.")

(defun decknix-board--read-name ()
  "Read the name of a defined board."
  (let ((names (decknix-board-names)))
    (unless names (user-error "No boards yet: M-x decknix-board-new"))
    (completing-read "Board: " names nil t nil 'decknix-board-history
                     (and (derived-mode-p 'decknix-board-mode)
                          (plist-get decknix-board--board :name)))))

;;;###autoload
(defun decknix-board-open (name)
  "Open the board called NAME.
With no boards defined yet, or with a prefix argument, define one."
  (interactive (list (and (not current-prefix-arg) (decknix-board-names)
                          (decknix-board--read-name))))
  (if (null name)
      (decknix-board-new)
    (let* ((board (decknix-board-read name))
           (buf (get-buffer-create (decknix-board-buffer-name name))))
      (with-current-buffer buf
        (unless (derived-mode-p 'decknix-board-mode) (decknix-board-mode))
        (setq decknix-board--board board)
        (decknix-board--render t)
        (decknix-board--fetch buf))
      (decknix-board--start)
      (pop-to-buffer buf)
      buf)))

(defun decknix-board-recreate (buffer-name)
  "Reopen the board shown in a buffer called BUFFER-NAME, for layout restore.
Return the buffer, or nil when the name is not a board's or its
definition has gone."
  (when (string-match "\\`\\*Board: \\(.+\\)\\*\\'" buffer-name)
    (let ((name (match-string 1 buffer-name)))
      (and (file-exists-p (decknix-board-definition-file name))
           (decknix-board-open name)))))

(put 'decknix-board-recreate 'decknix-layout-recreate-with-name t)

(defun decknix-board--current ()
  "Return the board of the current buffer, or signal."
  (or decknix-board--board (user-error "Not in a board buffer")))

(defun decknix-board-refresh ()
  "Re-read the definition and fetch the board's items now."
  (interactive)
  (let ((board (decknix-board--current)))
    (setq decknix-board--board (decknix-board-read (plist-get board :name)))
    (run-hook-with-args 'decknix-board-reread-functions (plist-get board :name))
    (decknix-board--fetch (current-buffer))
    (decknix-board--render t)
    (message "Refreshing %s..." (plist-get board :name))))

;;;###autoload
(defun decknix-board-edit (name)
  "Open the definition file of board NAME."
  (interactive (list (if (derived-mode-p 'decknix-board-mode)
                         (plist-get decknix-board--board :name)
                       (decknix-board--read-name))))
  (find-file (decknix-board-definition-file name)))

(defun decknix-board--item-at-point ()
  "Return the item on this row, or of the session row's item above it."
  (or (get-text-property (point) 'decknix-board-item)
      (and (get-text-property (point) 'decknix-board-session)
           (save-excursion
             (let ((indent (current-indentation)) found)
               (while (and (not found) (zerop (forward-line -1)))
                 (let ((item (get-text-property (point) 'decknix-board-item)))
                   (cond (item (setq found item))
                         ((< (current-indentation) indent)
                          (setq found 'none)))))
               (and (not (eq found 'none)) found))))))

(defun decknix-board--item-sessions (item)
  "Return the live sessions working on ITEM."
  (decknix-board-item-sessions
   (decknix-board-item-key item)
   (decknix-board-group-sessions decknix-board--board (decknix-board-live-sessions)
                                 decknix-board--items)))

(defun decknix-board--row-p ()
  "Non-nil when the current line is an item or session row."
  (get-text-property (line-beginning-position) 'decknix-board-row))

(defun decknix-board--move (step)
  "Move STEP lines at a time to the next item or session row."
  (let ((start (point)) found)
    (while (and (not found) (zerop (forward-line step)) (not (eobp)))
      (setq found (decknix-board--row-p)))
    (if found (back-to-indentation) (goto-char start))))

(defun decknix-board-next ()
  "Move to the next item or session row."
  (interactive)
  (decknix-board--move 1))

(defun decknix-board-previous ()
  "Move to the previous item or session row."
  (interactive)
  (decknix-board--move -1))

(defun decknix-board-toggle ()
  "Fold or unfold the item at point."
  (interactive)
  (let ((item (get-text-property (point) 'decknix-board-item)))
    (unless item (user-error "No item on this line"))
    (let ((k (decknix-board-item-key item)))
      (setq decknix-board--collapsed
            (if (member k decknix-board--collapsed)
                (delete k decknix-board--collapsed)
              (cons k decknix-board--collapsed))))
    (decknix-board--render t)))

(defun decknix-board--pick-session (sessions)
  "Return a buffer from SESSIONS, asking when there are several."
  (let ((names (mapcar #'car sessions)))
    (get-buffer (if (cdr names)
                    (completing-read "Session: " names nil t)
                  (car names)))))

(defun decknix-board-jump ()
  "Go to the session at point, or to the item's session."
  (interactive)
  (let ((buf (get-text-property (point) 'decknix-board-session)))
    (if (buffer-live-p buf)
        (pop-to-buffer buf)
      (let* ((item (or (decknix-board--item-at-point) (user-error "No item here")))
             (sessions (decknix-board--item-sessions item)))
        (unless sessions
          (user-error "No session on %s: N starts one" (decknix-board--item-ref item)))
        (pop-to-buffer (decknix-board--pick-session sessions))))))

(defun decknix-board-browse ()
  "Open the item or PR at point in the browser."
  (interactive)
  (let ((pr (get-text-property (point) 'decknix-board-pr)))
    (when pr (browse-url (plist-get pr :url))))
  (unless (get-text-property (point) 'decknix-board-pr)
    (decknix-board--browse-item)))

(defun decknix-board--browse-item ()
  "Open the item at point in the browser."
  (let ((item (or (decknix-board--item-at-point) (user-error "No item here"))))
    (browse-url (decknix-board-backend-item-url
                 (decknix-board-backend decknix-board--board) decknix-board--board item))))

(defun decknix-board-visit (&optional browse)
  "Go to the session on this row or the item's only session, else browse.
With BROWSE (prefix argument), always open the item in the browser."
  (interactive "P")
  (let ((buf (get-text-property (point) 'decknix-board-session)))
    (cond
     ((get-text-property (point) 'decknix-board-pr) (decknix-board-browse))
     ((and (not browse) (buffer-live-p buf)) (pop-to-buffer buf))
     (t
      (let* ((item (or (decknix-board--item-at-point) (user-error "No item here")))
             (sessions (and (not browse) (decknix-board--item-sessions item))))
        (if (= 1 (length sessions))
            (pop-to-buffer (get-buffer (nth 0 (car sessions))))
          (decknix-board-browse)))))))

(defun decknix-board-session-tags (board item)
  "Return the tags for a new session on BOARD's ITEM (nil: board only)."
  (let ((all (plist-get board :tags-all))
        (any (plist-get board :tags-any)))
    (delete-dups
     (append (copy-sequence all)
             (and any (not (seq-some (lambda (tag) (member tag all)) any))
                  (list (car any)))
             (and item (list (decknix-board-item-tag board item)))))))

(defun decknix-board-new-session (&optional choose-provider)
  "Start an agent session on the item at point, briefed and tagged.
With CHOOSE-PROVIDER (prefix argument), pick the provider."
  (interactive "P")
  (let* ((board (decknix-board--current))
         (item (or (decknix-board--item-at-point)
                   (user-error "Move to an item first")))
         (tags (decknix-board-session-tags board item))
         (workspace (or (plist-get board :workspace)
                        (read-directory-name "Workspace: " nil nil t)))
         (brief (decknix-board-session-brief
                 board item (decknix-board-ancestors decknix-board--items item)))
         (provider (if (and choose-provider (fboundp 'decknix-agent-provider-select))
                       (decknix-agent-provider-select)
                     (bound-and-true-p decknix-agent-default-provider)))
         (mode (and (fboundp 'decknix-agent-purpose-resolve)
                    (plist-get (decknix-agent-purpose-resolve 'new-session) :mode))))
    (unless (fboundp 'decknix--agent-quickaction-start)
      (user-error "Agent sessions are not loaded"))
    (decknix--agent-quickaction-start (string-join tags "/") tags
                                      (expand-file-name workspace) brief
                                      nil provider mode)))

(defun decknix-board-broadcast (&optional whole-board)
  "Compose one message to the item's sessions, or all board sessions.
With WHOLE-BOARD (prefix argument), or off any item, send to every
session on the board."
  (interactive "P")
  (let* ((board (decknix-board--current))
         (item (and (not whole-board) (decknix-board--item-at-point)))
         (sessions (if item
                       (decknix-board--item-sessions item)
                     (plist-get (decknix-board-group-sessions
                                 board (decknix-board-live-sessions) decknix-board--items)
                                :board)))
         (bufs (delq nil (mapcar (lambda (s) (get-buffer (nth 0 s))) sessions))))
    (unless bufs (user-error "No live sessions to send to"))
    (unless (fboundp 'decknix--session-bulk-send-open-compose)
      (user-error "Bulk send is not loaded"))
    (decknix--session-bulk-send-open-compose bufs)))

(defun decknix-board--url-number (url)
  "Return the trailing number of issue URL, or nil."
  (and (stringp url) (string-match "/\\([0-9]+\\)\\'" url)
       (string-to-number (match-string 1 url))))

(defun decknix-board-create-item (board spec &optional on-created)
  "Create SPEC on BOARD's backend once the user confirms; return non-nil if sent.
SPEC is (:type :title :body :parent).  ON-CREATED gets the new URL."
  (let ((parent (plist-get spec :parent)))
    (when (yes-or-no-p
           (format "Create %s %S in %s%s? "
                   (or (plist-get spec :type) "item") (plist-get spec :title)
                   (decknix-board-backend-describe (decknix-board-backend board) board)
                   (if parent (format " under %s" (decknix-board--item-ref parent)) "")))
      (decknix-board-backend-create-item
       (decknix-board-backend board) board spec
       (lambda (url err)
         (cond ((and url err) (message "Board: %s" err))
               (url (message "Board: created %s" url))
               (t (message "Board: create failed: %s" err)))
         (when (and url on-created) (funcall on-created url))))
      t)))

(defun decknix-board-create-child ()
  "Create an item under the one at point (or under the goal)."
  (interactive)
  (let* ((board (decknix-board--current))
         (root (decknix-board-root board))
         (parent (or (get-text-property (point) 'decknix-board-item)
                     (and root (seq-find (lambda (i) (and (eql (plist-get i :number) root)
                                                          (decknix-board--home-item-p board i)))
                                         decknix-board--items))))
         (type (completing-read "Type: " decknix-board-types nil t nil nil
                                (decknix-board-child-type
                                 (or (plist-get parent :type) "goal"))))
         (title (read-string (format "%s title: " (capitalize type))))
         (body (read-string "Body (optional): "))
         (buf (current-buffer)))
    (when (string-empty-p (string-trim title)) (user-error "A title is required"))
    (decknix-board-create-item
     board (list :type type :title title :body body :parent parent)
     (lambda (_url) (when (buffer-live-p buf) (decknix-board--fetch buf))))))

;; --- Slack ---------------------------------------------------------------

(defun decknix-board--slack-command ()
  "Return the Slack posting command, or nil when there is none."
  (or decknix-board-slack-post-command
      (let ((exe (or (executable-find "slack-post-message.py")
                     (car (file-expand-wildcards
                           (expand-file-name "~/Code/*/.nc-tools/bin/slack-post-message.py"))))))
        (and exe (file-executable-p exe) (list exe)))))

(defun decknix-board-slack-argv (command channel text)
  "Return COMMAND extended to post TEXT to CHANNEL."
  (append command (list "--channel" channel "--message" text)))

(defun decknix-board-slack-channel-url (channel)
  "Return a URL that opens Slack CHANNEL."
  (format "https://slack.com/app_redirect?channel=%s" channel))

(defun decknix-board-slack-send (channel text)
  "Post TEXT to Slack CHANNEL after the user confirms.
Without a posting command, copy TEXT and open the channel instead.
Return `posted', `copied' or nil when declined."
  (let ((command (decknix-board--slack-command)))
    (cond
     ((string-empty-p (string-trim text)) (user-error "Nothing to send"))
     ((and command
           (yes-or-no-p (format "Post %d characters to Slack %s? " (length text) channel)))
      (decknix-board-run
       (decknix-board-slack-argv command channel text)
       (lambda (exit _out err)
         (if (eq exit 0)
             (message "Board: posted to %s" channel)
           (kill-new text)
           (message "Board: Slack post failed (%s); the text is on the kill ring"
                    (string-trim err)))))
      'posted)
     ((and (not command)
           (y-or-n-p (format "No Slack poster found.  Copy the update and open %s? " channel)))
      (kill-new text)
      (browse-url (decknix-board-slack-channel-url channel))
      'copied))))

(defvar-local decknix-board--slack-channel nil "Channel this draft goes to.")

(defun decknix-board-slack-submit ()
  "Send this Slack draft, after confirming."
  (interactive)
  (let ((buf (current-buffer)))
    (when (decknix-board-slack-send decknix-board--slack-channel
                                    (string-trim (buffer-string)))
      (quit-window t (get-buffer-window buf)))))

(defun decknix-board-slack-cancel ()
  "Discard this Slack draft."
  (interactive)
  (quit-window t))

(defvar decknix-board-slack-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'decknix-board-slack-submit)
    (define-key map (kbd "C-c C-k") #'decknix-board-slack-cancel)
    map)
  "Keys for a board's Slack draft.")

(define-derived-mode decknix-board-slack-mode text-mode "Board-Slack"
  "Edit a board update before it goes to Slack."
  (setq header-line-format
        '(:eval (format " Slack %s   C-c C-c send (asks first)   C-c C-k cancel"
                        decknix-board--slack-channel))))

(defun decknix-board-slack ()
  "Draft a Slack update for the item at point, or the whole board."
  (interactive)
  (let* ((board (decknix-board--current))
         (channel (or (plist-get board :slack-channel)
                      (user-error "This board has no :slack-channel (e to edit)")))
         (text (decknix-board-slack-text
                board (decknix-board--item-at-point) decknix-board--items
                (decknix-board-group-sessions board (decknix-board-live-sessions)
                                              decknix-board--items)))
         (draft (get-buffer-create (format "*Board Slack: %s*" (plist-get board :name)))))
    (with-current-buffer draft
      (decknix-board-slack-mode)
      (erase-buffer)
      (insert text)
      (setq decknix-board--slack-channel channel)
      (goto-char (point-min)))
    (pop-to-buffer draft)))

;; --- the wizard ----------------------------------------------------------

(defun decknix-board--repo-candidates ()
  "Repositories to offer: those boards already use, then the user's."
  (delete-dups
   (append (delq nil (mapcar (lambda (n)
                               (ignore-errors
                                 (decknix-board-github--conf (decknix-board-read n) :repo)))
                             (decknix-board-names)))
           decknix-board-repo-history
           decknix-board-github--repos)))

(defun decknix-board-parse-repos (text home)
  "Return the :repos entries in TEXT, comma-separated; nil when only HOME.
An entry wrapped in slashes, `/RX/', is a regexp; anything else is an
exact `owner/name' or a glob."
  (let ((entries (mapcar (lambda (e)
                           (if (string-match "\\`/\\(.+\\)/\\'" e)
                               (list :regexp (match-string 1 e))
                             e))
                         (seq-remove #'string-empty-p
                                     (mapcar #'string-trim (split-string (or text "") ","))))))
    (unless (or (null entries) (equal entries (list home)))
      entries)))

(defun decknix-board-read-repos (home)
  "Read a board's repositories, defaulting to its issue HOME."
  (decknix-board-parse-repos
   (read-string (format "Repos in scope (comma-separated; globs like owner/hack-*, /regexp/) [%s]: "
                        home)
                nil nil home)
   home))

(defun decknix-board--read-tags (prompt default)
  "Read tags with PROMPT, offering known tags, DEFAULT pre-filled."
  (let ((known (and (fboundp 'decknix--agent-tags-all)
                    (ignore-errors (decknix--agent-tags-all)))))
    (seq-remove #'string-empty-p
                (mapcar #'string-trim
                        (completing-read-multiple prompt known nil nil default)))))

;;;###autoload
(defun decknix-board-new ()
  "Define a new board, optionally create its goal issue, and open it."
  (interactive)
  ;; Started now so the list has usually arrived by the repo prompt.
  (ignore-errors (decknix-board-github-refresh-repos))
  (let* ((name (let ((n (read-string "Board name (a-z0-9-): ")))
                 (unless (decknix-board-valid-name-p n)
                   (user-error "Use lower-case letters, digits, . _ or -"))
                 (when (file-exists-p (decknix-board-definition-file n))
                   (user-error "Board %s exists: M-x decknix-board-edit" n))
                 n))
         (title (read-string "Title: " nil nil (capitalize name)))
         (goal (read-string "Goal (one line): "))
         (repo (completing-read "GitHub repo (owner/name): "
                                (decknix-board--repo-candidates)
                                nil nil nil 'decknix-board-repo-history))
         (_ (decknix-board-github--split-repo repo))
         (repos (decknix-board-read-repos repo))
         (tags (decknix-board--read-tags "Session tags (all required): " name))
         (workspace (and (y-or-n-p "Also group sessions by a workspace directory? ")
                         (abbreviate-file-name
                          (read-directory-name "Workspace: " nil nil t))))
         (channel (let ((c (string-trim (read-string "Slack channel ID (optional, e.g. C0123ABCD): "))))
                    (and (not (string-empty-p c)) c)))
         (root-choice (completing-read "Goal issue: "
                                       '("create one now" "use an existing issue" "none")
                                       nil t nil nil "create one now"))
         (root (and (equal root-choice "use an existing issue")
                    (read-number "Goal issue number: ")))
         (board (append
                 (list :name name :title title :goal goal
                       :workspace workspace :tags-all tags :tags-any nil)
                 (and repos (list :repos repos :match 'either))
                 (list :slack-channel channel :backend 'github
                       :github (list :repo repo :root root :label-prefix "type:")))))
    (decknix-board-write board)
    (let ((buf (decknix-board-open name)))
      (when (equal root-choice "create one now")
        (decknix-board-create-item
         board (list :type "goal" :title title :body goal)
         (lambda (url)
           (let ((n (decknix-board--url-number url)))
             (when n
               (let* ((fresh (decknix-board-read name))
                      (gh (plist-put (copy-sequence (plist-get fresh :github)) :root n)))
                 (decknix-board-write (plist-put fresh :github gh)))
               (when (buffer-live-p buf)
                 (with-current-buffer buf (decknix-board-refresh)))))))))))

;; --- mode ----------------------------------------------------------------

(defvar decknix-board-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "n") #'decknix-board-next)
    (define-key map (kbd "p") #'decknix-board-previous)
    (define-key map (kbd "TAB") #'decknix-board-toggle)
    (define-key map (kbd "RET") #'decknix-board-visit)
    (define-key map (kbd "o") #'decknix-board-browse)
    (define-key map (kbd "c") #'decknix-board-create-child)
    (define-key map (kbd "N") #'decknix-board-new-session)
    (define-key map (kbd "j") #'decknix-board-jump)
    (define-key map (kbd "b") #'decknix-board-broadcast)
    (define-key map (kbd "s") #'decknix-board-slack)
    (define-key map (kbd "g") #'decknix-board-refresh)
    (define-key map (kbd "e") #'decknix-board-edit)
    (define-key map (kbd "?") #'describe-mode)
    map)
  "Keys for a board buffer.")

(define-derived-mode decknix-board-mode special-mode "Board"
  "A coordination board: a plan from an issue backend and its live sessions.

\\{decknix-board-mode-map}"
  (setq truncate-lines t)
  (buffer-disable-undo))

(provide 'decknix-board)
;;; decknix-board.el ends here
