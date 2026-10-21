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
;;    :backend github
;;    :github (:repo "owner/name" :root 1 :label-prefix "type:"))
;;
;; Grouping.  A session belongs to a board when it carries every
;; :tags-all tag, at least one :tags-any tag (when any are given) and
;; sits under :workspace (when given).  A board with none of the three
;; claims no session by them, or it would claim every session.
;;
;; Item tags.  A session works on an item when it is tagged
;; `<prefix>#<number>', where the prefix is the repository name for
;; GitHub (`hack#12'), or, inside the board, just `#12'.  The repo form
;; stays unambiguous across boards, because tags are global; it also puts
;; a session on its board by itself.  `N' on an item tags a new session
;; that way.
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
    file))

(defun decknix-board-backend (board)
  "Return BOARD's backend symbol."
  (or (plist-get board :backend) 'github))

(defun decknix-board-root (board)
  "Return BOARD's goal item number, from its backend settings, or nil."
  (plist-get (plist-get board (intern (format ":%s" (decknix-board-backend board))))
             :root))

;; --- tags and grouping ---------------------------------------------------

(defun decknix-board-tag-prefix (board)
  "Return the prefix of BOARD's item tags."
  (or (plist-get board :item-tag-prefix)
      (decknix-board-backend-tag-prefix (decknix-board-backend board) board)))

(defun decknix-board-item-tag (board item)
  "Return the tag that puts a session on BOARD's ITEM, e.g. `hack#12'."
  (format "%s#%s" (decknix-board-tag-prefix board) (plist-get item :number)))

(defun decknix-board--under-p (dir root)
  "Non-nil when directory DIR is ROOT or below it.  Pure: no file access."
  (and (stringp dir) (stringp root)
       (let ((d (file-name-as-directory (expand-file-name dir)))
             (r (file-name-as-directory (expand-file-name root))))
         (string-prefix-p r d))))

(defun decknix-board--item-tag-number (board tag)
  "Return the item number TAG names on BOARD, or nil."
  (let ((re (concat "\\`\\(?:" (regexp-quote (decknix-board-tag-prefix board))
                    "\\)?#\\([0-9]+\\)\\'")))
    (and (stringp tag) (string-match re tag)
         (string-to-number (match-string 1 tag)))))

(defun decknix-board--has-full-item-tag-p (board tags)
  "Non-nil when TAGS include one of BOARD's `prefix#N' item tags."
  (let ((prefix (concat (decknix-board-tag-prefix board) "#")))
    (seq-some (lambda (tag)
                (and (string-prefix-p prefix tag)
                     (decknix-board--item-tag-number board tag)))
              tags)))

(defun decknix-board-session-in-board-p (board session)
  "Non-nil when SESSION (NAME TAGS PRS STATE WORKSPACE ...) is on BOARD."
  (let ((tags (nth 1 session))
        (all (plist-get board :tags-all))
        (any (plist-get board :tags-any))
        (ws (plist-get board :workspace)))
    (or (decknix-board--has-full-item-tag-p board tags)
        (and (or all any ws)
             (seq-every-p (lambda (tag) (member tag tags)) all)
             (or (null any) (seq-some (lambda (tag) (member tag tags)) any))
             (or (null ws) (decknix-board--under-p (nth 4 session) ws))))))

(defun decknix-board-session-item-numbers (board session)
  "Return the item numbers SESSION is tagged for on BOARD."
  (let ((in-board (decknix-board-session-in-board-p board session))
        (prefix (concat (decknix-board-tag-prefix board) "#")))
    (delete-dups
     (delq nil
           (mapcar (lambda (tag)
                     (and (or in-board (string-prefix-p prefix tag))
                          (decknix-board--item-tag-number board tag)))
                   (nth 1 session))))))

(defun decknix-board-group-sessions (board sessions items)
  "Group SESSIONS for BOARD against ITEMS.
Return (:board BOARD-SESSIONS :by-item ALIST :unassigned SESSIONS), where
ALIST maps an item number to its sessions."
  (let ((numbers (mapcar (lambda (i) (plist-get i :number)) items))
        mine by-item unassigned)
    (dolist (s sessions)
      (when (decknix-board-session-in-board-p board s)
        (push s mine)
        (let ((hits (seq-filter (lambda (n) (memq n numbers))
                                (decknix-board-session-item-numbers board s))))
          (if (null hits)
              (push s unassigned)
            (dolist (n hits)
              (setf (alist-get n by-item) (append (alist-get n by-item) (list s))))))))
    (list :board (nreverse mine) :by-item by-item :unassigned (nreverse unassigned))))

;; --- the item tree -------------------------------------------------------

(defun decknix-board--item-less-p (a b)
  "Order items A and B by type depth, then number."
  (let ((ra (decknix-board-type-rank (plist-get a :type)))
        (rb (decknix-board-type-rank (plist-get b :type))))
    (if (/= ra rb) (< ra rb) (< (plist-get a :number) (plist-get b :number)))))

(defun decknix-board-tree (items root hierarchy)
  "Arrange ITEMS for display.
With HIERARCHY (items carry parent links) return (:nodes NODES :unlinked
NODES), each node (ITEM . CHILD-NODES).  NODES is the tree under ROOT
when it is among ITEMS, else every top-level item; :unlinked holds the
other top-level trees.  Without HIERARCHY return (:flat GROUPS), an
alist of type to items, outermost type first."
  (if (not hierarchy)
      (let (groups)
        (dolist (item (sort (copy-sequence items) #'decknix-board--item-less-p))
          (let ((type (or (plist-get item :type) "untyped")))
            (setf (alist-get type groups nil nil #'equal)
                  (append (alist-get type groups nil nil #'equal) (list item)))))
        (list :flat (sort groups (lambda (a b)
                                   (< (decknix-board-type-rank (car a))
                                      (decknix-board-type-rank (car b)))))))
    (let ((by-number (make-hash-table))
          (children (make-hash-table))
          (seen (make-hash-table))
          top)
      (dolist (item items) (puthash (plist-get item :number) item by-number))
      (dolist (item items)
        (let ((parent (plist-get item :parent)))
          (if (and parent (gethash parent by-number))
              (puthash parent (cons item (gethash parent children)) children)
            (push item top))))
      (cl-labels ((build (item)
                    ;; A cycle is impossible on GitHub, but a hand-edited
                    ;; backend must not hang the render.
                    (puthash (plist-get item :number) t seen)
                    (cons item
                          (mapcar #'build
                                  (seq-remove
                                   (lambda (c) (gethash (plist-get c :number) seen))
                                   (sort (copy-sequence
                                          (gethash (plist-get item :number) children))
                                         #'decknix-board--item-less-p))))))
        (let* ((top (sort top #'decknix-board--item-less-p))
               (root-item (and root (seq-find (lambda (i) (eql (plist-get i :number) root))
                                              top))))
          (if root-item
              (list :nodes (list (build root-item))
                    :unlinked (mapcar #'build (remq root-item top)))
            (list :nodes (mapcar #'build top) :unlinked nil)))))))

(defun decknix-board-ancestors (items item)
  "Return ITEM's ancestors among ITEMS, outermost first."
  (let (chain (seen nil) (cur item))
    (while (and cur (plist-get cur :parent) (not (memq (plist-get cur :parent) seen)))
      (push (plist-get cur :parent) seen)
      (setq cur (seq-find (lambda (i) (eql (plist-get i :number) (plist-get cur :parent)))
                          items))
      (when cur (push cur chain)))
    chain))

;; --- text for people and agents -----------------------------------------

(defun decknix-board--item-label (item)
  "Return `epic #3 Title' for ITEM."
  (format "%s#%s %s"
          (if (plist-get item :type) (concat (plist-get item :type) " ") "")
          (plist-get item :number) (plist-get item :title)))

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
      (insert (format "A session tagged `%s#N` (or `#N` with the board's tags) works on item N.\n\n"
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
                    (let ((ss (alist-get (plist-get item :number) by-item)))
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
                                    (seq-some (lambda (a) (eql (plist-get a :number)
                                                               (plist-get item :number)))
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
                                            (alist-get (plist-get i :number) by-item)))
                           subject)))
              (and active
                   (concat "In progress:\n"
                           (mapconcat (lambda (i)
                                        (format "- #%s %s" (plist-get i :number)
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
(defvar-local decknix-board--collapsed nil "Item numbers folded in the view.")
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

(defun decknix-board--item-line (item depth folded children-p)
  "Return ITEM's row text at DEPTH; FOLDED and CHILDREN-P set the marker."
  (let* ((closed (equal (plist-get item :state) "closed"))
         (prs (plist-get item :prs)))
    (concat
     (make-string (* 2 depth) ?\s)
     (cond ((not children-p) "  ") (folded "▸ ") (t "▾ "))
     (if closed (propertize "✓ " 'face 'success) "  ")
     (if (plist-get item :type)
         (propertize (format "%-7s " (plist-get item :type)) 'face 'font-lock-type-face)
       "")
     (propertize (format "#%s " (plist-get item :number)) 'face 'font-lock-constant-face)
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
     (mapconcat (lambda (pr)
                  (propertize (format "  PR #%s%s" (plist-get pr :number)
                                      (cond ((equal (plist-get pr :state) "merged") " merged")
                                            ((plist-get pr :draft) " draft")
                                            ((equal (plist-get pr :state) "closed") " closed")
                                            (t "")))
                              'face 'font-lock-keyword-face))
                prs ""))))

(defun decknix-board--insert-node (node depth by-item)
  "Insert tree NODE at DEPTH, with its sessions from BY-ITEM."
  (let* ((item (car node))
         (n (plist-get item :number))
         (folded (memq n decknix-board--collapsed))
         (start (point)))
    (insert (decknix-board--item-line item depth folded (cdr node)) "\n")
    (add-text-properties start (point) (list 'decknix-board-item item
                                             'decknix-board-row t))
    (dolist (s (alist-get n by-item))
      (decknix-board--insert-session s (+ 6 (* 2 depth))))
    (unless folded
      (dolist (c (cdr node)) (decknix-board--insert-node c (1+ depth) by-item)))))

(defun decknix-board--heading (text)
  "Insert section heading TEXT."
  (insert "\n" (propertize text 'face 'bold) "\n"))

(defun decknix-board--draw (sessions)
  "Redraw the current board buffer from its caches and SESSIONS."
  (let* ((board decknix-board--board)
         (items decknix-board--items)
         (grouping (decknix-board-group-sessions board sessions items))
         (tree (decknix-board-tree items
                                   (decknix-board-root board)
                                   (plist-get decknix-board--meta :hierarchy)))
         (by-item (plist-get grouping :by-item))
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
    (insert (propertize "RET open  N new session  c create child  j jump  b broadcast  s slack  TAB fold  g refresh  e edit  ? help"
                        'face 'shadow)
            "\n")
    (let ((need (decknix-attention-ordered-sessions (plist-get grouping :board))))
      (when need
        (decknix-board--heading (format "%s Needs you (%d)" decknix-attention-glyph (length need)))
        (dolist (s need) (decknix-board--insert-session s 2))))
    (cond
     ((plist-get tree :flat)
      (dolist (group (plist-get tree :flat))
        (decknix-board--heading (capitalize (car group)))
        (dolist (item (cdr group))
          (decknix-board--insert-node (list item) 0 by-item))))
     (t
      (decknix-board--heading "Plan")
      (if (plist-get tree :nodes)
          (dolist (n (plist-get tree :nodes)) (decknix-board--insert-node n 0 by-item))
        (insert (propertize (if decknix-board--fetched-at
                                "  No items yet: c creates one."
                              "  Fetching...")
                            'face 'shadow)
                "\n"))
      (when (plist-get tree :unlinked)
        (decknix-board--heading "Outside the goal")
        (dolist (n (plist-get tree :unlinked)) (decknix-board--insert-node n 0 by-item)))))
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
                         (eql (plist-get want :number) (plist-get have :number))))))))
    (if found
        (goto-char (prop-match-beginning found))
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun decknix-board--fingerprint-of (sessions)
  "Return the render inputs of the current buffer with SESSIONS."
  (list (mapcar (lambda (s) (list (nth 0 s) (nth 1 s) (nth 3 s) (nth 4 s))) sessions)
        decknix-board--items decknix-board--meta decknix-board--error
        decknix-board--fetched-at decknix-board--fetching decknix-board--collapsed
        decknix-board--board))

(defun decknix-board--render (&optional force)
  "Render the current board buffer unless nothing changed, or FORCE."
  (let* ((sessions (decknix-board-live-sessions))
         (fp (decknix-board--fingerprint-of sessions)))
    (when (or force (not (equal fp decknix-board--fingerprint)))
      (setq decknix-board--fingerprint fp)
      ;; A tick redraws a board shown in an unselected window, whose
      ;; cursor is the window's point, not the buffer's.
      (let ((win (get-buffer-window (current-buffer) t)))
        (when win (goto-char (window-point win)))
        (decknix-board--draw sessions)
        (when win (set-window-point win (point)))))))

;; --- fetching ------------------------------------------------------------

(defun decknix-board--write-snapshot (buf)
  "Write BUF's board snapshot when its text changed."
  (with-current-buffer buf
    (let* ((sessions (decknix-board-live-sessions))
           (board decknix-board--board)
           (tree (decknix-board-tree decknix-board--items
                                     (decknix-board-root board)
                                     (plist-get decknix-board--meta :hierarchy)))
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
               (decknix-board--write-snapshot buf))
             (decknix-board--render))))))))

(defun decknix-board--due-p ()
  "Non-nil when the current board buffer should fetch again."
  (and (not decknix-board--fetching)
       (or (null decknix-board--fetch-started)
           (> (- (float-time) decknix-board--fetch-started)
              decknix-board-fetch-interval))))

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
  (alist-get (plist-get item :number)
             (plist-get (decknix-board-group-sessions
                         decknix-board--board (decknix-board-live-sessions)
                         decknix-board--items)
                        :by-item)))

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
    (let ((n (plist-get item :number)))
      (setq decknix-board--collapsed
            (if (memq n decknix-board--collapsed)
                (delq n decknix-board--collapsed)
              (cons n decknix-board--collapsed))))
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
          (user-error "No session on #%s: N starts one" (plist-get item :number)))
        (pop-to-buffer (decknix-board--pick-session sessions))))))

(defun decknix-board-browse ()
  "Open the item at point in the browser."
  (interactive)
  (let ((item (or (decknix-board--item-at-point) (user-error "No item here"))))
    (browse-url (decknix-board-backend-item-url
                 (decknix-board-backend decknix-board--board) decknix-board--board item))))

(defun decknix-board-visit (&optional browse)
  "Go to the session on this row or the item's only session, else browse.
With BROWSE (prefix argument), always open the item in the browser."
  (interactive "P")
  (let ((buf (get-text-property (point) 'decknix-board-session)))
    (cond
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
                   (if parent (format " under #%s" (plist-get parent :number)) "")))
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
                     (and root (seq-find (lambda (i) (eql (plist-get i :number) root))
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
         (board (list :name name :title title :goal goal
                      :workspace workspace :tags-all tags :tags-any nil
                      :slack-channel channel :backend 'github
                      :github (list :repo repo :root root :label-prefix "type:"))))
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
