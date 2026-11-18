;;; decknix-session-assoc.el --- What a session is actually working on -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, sessions, worktrees

;;; Commentary:
;;
;; Associates a session with the WORKTREES it is working in, observed from the
;; file paths its tool calls touch, rather than inferred from its name.
;;
;; The sidebar previously guessed from session tags: a tag naming a repo
;; claimed that repo's worktrees and PRs.  Two things were wrong with that.
;; It is repo-granular, so it cannot express "this session is on two
;; worktrees of one repo and one of another"; and it is a name, so it claims
;; work the session never touched while missing work it did.  Measured on a
;; live session tagged `squad/nix/web-integration': it had edited files in 39
;; worktrees across FOUR repos, and the tag named one of them.  The
;; platform-cli PR it was actually working on appeared nowhere.
;;
;; Observation alone is not enough either, and the same measurement shows
;; why: a session alive for two months touches everything eventually.  39
;; worktrees is as useless as one wrong one.  So the set is RECENCY-BOUNDED,
;; counted in turns:
;;
;;     last  20 turns ->  2 worktrees   <- the work in hand
;;     last  80 turns ->  7
;;     last 160 turns -> 20
;;
;; Turns rather than wall-clock because a session idle overnight has not
;; changed what it is working on, and a busy hour can move through several
;; worktrees.
;;
;; Paths resolve to the LONGEST matching known worktree, so a file inside
;; `platform-cli-worktrees/ACME-1040' is attributed to that worktree and not
;; to `platform-cli' -- which is the whole point of being worktree-granular.
;;
;; Pure here; capture at notification time and persistence live in the
;; wiring layer per AGENTS.md Rule 2.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'map)
(require 'subr-x)
(require 'json)
(require 'decknix-state-io)

(defcustom decknix-session-assoc-window 20
  "How many turns back a session's worktree association reaches.

Measured on a live two-month-old session: 20 turns yielded the 2
worktrees it was actually working in, 80 yielded 7, and 160 yielded 20.
The whole history yielded 39 across four repos, which is no more useful
than the wrong single repo the tag named."
  :type 'integer
  :group 'decknix)

;; --- path -> worktree -------------------------------------------------

(defun decknix-session-assoc-resolve (path roots)
  "Return the entry of ROOTS that PATH lies within, or nil.

ROOTS is a list of directory paths.  The LONGEST match wins: a file in
`platform-cli-worktrees/ACME-1040' must attribute to that worktree rather
than to `platform-cli', and a plain prefix test would pick whichever came
first in the list."
  (when (and (stringp path) roots)
    (let ((best nil) (best-len -1))
      (dolist (root roots)
        (when (and (stringp root) (not (string-empty-p root)))
          (let* ((dir (file-name-as-directory root))
                 (len (length dir)))
            (when (and (> len best-len)
                       ;; The root itself counts: `cd /w/repo-worktrees/X'
                       ;; names the directory, with no trailing slash.
                       (string-prefix-p dir (file-name-as-directory path)))
              (setq best root best-len len)))))
      (or best (decknix-session-assoc-resolve-removed path roots)))))

(defun decknix-session-assoc-resolve-removed (path roots)
  "Resolve PATH to its WORKTREE directory when that worktree is no root.

A worktree lives at `<repo>-worktrees/<dir>\=' and is missing from ROOTS in
two cases: it has been removed since its work merged, or it was created
after ROOTS was taken.  Either way PATH matches no root.

This used to answer with the REPO, and the sidebar then gave the session
every PR and worktree in that repo.  Measured: a session whose widget
worktree had been removed was credited with all of widget -- an unrelated
PR and seven unrelated worktrees -- and its work in a worktree created
mid-session was credited to auth-sidecar as a whole.  The worktree
directory is the precise fact: by the naming convention it is also the
branch, so it still identifies the session\='s PR after the worktree is
gone.  Accepted only when the repo IS a known root."
  (when (string-match "\\`\\(.*\\)-worktrees/\\([^/]+\\)" path)
    (let ((repo (match-string 1 path))
          (dir (match-string 0 path)))
      (when (seq-find (lambda (r)
                        (and (stringp r)
                             (string= (file-name-as-directory r)
                                      (file-name-as-directory repo))))
                      roots)
        dir))))

(defconst decknix-session-assoc-path-re
  "\\(?:^\\|[^[:alnum:]_.~/-]\\)\\(/\\(?:Users\\|home\\|private\\|tmp\\|var\\|opt\\)/[^] \t\n\r\f\v\"'`;|&<>(){}*?$,]+\\)"
  "Matches an absolute path inside a tool call's input text.
Whitespace is spelled out rather than written `[:space:]', which follows
the current buffer's syntax table: where a newline is a comment ender,
not whitespace, a path ran on across lines into a junk root.")

(defun decknix-session-assoc-input-paths (input)
  "Return absolute paths named anywhere in a tool call's INPUT.

INPUT is the parsed `rawInput\=': an alist (or vector) of strings.  Every
string is searched, because the path a Bash call works in lives only in
its command text -- `cd /w/repo-worktrees/X; git ...\=' -- with
`locations\=' left null.  The OUTPUT is deliberately not read: command
output names any number of paths the session merely looked at."
  (let (out)
    (cl-labels ((walk (v)
                  (cond ((stringp v)
                         (let ((start 0))
                           (while (string-match decknix-session-assoc-path-re v start)
                             (push (directory-file-name (match-string 1 v)) out)
                             (setq start (match-end 1)))))
                        ((vectorp v) (mapc #'walk v))
                        ((consp v)
                         (if (and (atom (car v)) (not (consp (cdr v))))
                             (walk (cdr v))
                           (mapc #'walk v))))))
      (walk input))
    (nreverse (delete-dups out))))

(defun decknix-session-assoc-paths-of (update)
  "Return the file paths an ACP session UPDATE reports touching.

Reads `locations\=', which is where file tools carry them, and the tool
call\='s input, which is the only place a Bash call names its paths.
Reading `locations\=' alone missed a session that did all its work in a
infra-foundations worktree through subagent Bash calls: 35 touches, none
recorded, and the PR it was shepherding showed as Unattended.

Accepts a VECTOR as well as a list, because that is what the JSON
actually parses to: `json-parse-string' renders arrays as vectors, so a
`listp' test discarded every path.  Hand-written alist fixtures hid it --
they pass a list -- while a real log yielded nothing at all."
  (let ((locs (alist-get 'locations update)))
    (delete-dups
     (append
      (delq nil
            (mapcar (lambda (loc)
                      (let ((p (and (or (listp loc) (vectorp loc))
                                    (alist-get 'path loc))))
                        (and (stringp p) (not (string-empty-p p)) p)))
                    (cond ((vectorp locs) (append locs nil))
                          ((listp locs) locs)
                          (t nil))))
      (decknix-session-assoc-input-paths (alist-get 'rawInput update))))))

;; --- the recency-bounded set ------------------------------------------

(defun decknix-session-assoc-touch (assoc root turn)
  "Return ASSOC with ROOT recorded as touched at TURN.

ASSOC is an alist of (ROOT . LAST-TURN).  Only the most recent turn per
root is kept: the count of touches is not interesting, and keeping a list
of them would grow without bound in exactly the long-lived sessions this
exists to handle."
  (if (null root)
      assoc
    (cons (cons root turn)
          (seq-remove (lambda (cell) (equal (car cell) root)) assoc))))

(defun decknix-session-assoc-active (assoc turn &optional window)
  "Return the roots in ASSOC touched within WINDOW turns of TURN.

Sorted most-recent first, so the sidebar shows the work in hand at the
top of a session's subtree."
  (let* ((window (or window decknix-session-assoc-window))
         (ranked (sort (copy-sequence assoc)
                       (lambda (a b) (> (cdr a) (cdr b)))))
         ;; Measured from the last turn that touched a FILE, not from the
         ;; current turn.  A session that has been discussing rather than
         ;; editing is still working on what it last edited: the session
         ;; this was built for had its file activity at turn 44 of 64, so a
         ;; window counted from 64 found nothing and the sidebar fell back
         ;; to tags -- which is the whole failure this replaces.
         (latest (if ranked (cdar ranked) turn)))
    (mapcar #'car
            (seq-filter (lambda (cell) (> (cdr cell) (- latest window)))
                        ranked))))

(defun decknix-session-assoc-prune (assoc turn &optional window)
  "Return ASSOC without roots older than WINDOW turns before TURN.

Applied before persisting, so a session's stored association cannot grow
to the 39 entries the full history produced."
  (let ((window (or window decknix-session-assoc-window)))
    (seq-filter (lambda (cell) (> (cdr cell) (- turn window)))
                (copy-sequence assoc))))

;; --- claims -----------------------------------------------------------

(defun decknix-session-assoc-claims-wt-p (roots wt-path)
  "Return non-nil when WT-PATH is one of ROOTS.

Compared as directories: the worktree audit writes some paths with a
trailing slash and some without, which is the normalisation bug that once
hid `decknix-config' from the worktree picker."
  (and wt-path
       (seq-some (lambda (r)
                   (and r (string= (file-name-as-directory r)
                                   (file-name-as-directory wt-path))))
                 roots)
       t))

(defun decknix-session-assoc-claims-branch-p (roots branch wt-for-root)
  "Return non-nil when a root in ROOTS is the worktree for BRANCH.

WT-FOR-ROOT maps a root path to its checked-out branch.  This is how a PR
is claimed: by the branch of a worktree the session is working in, which
is precise, rather than by its repo, which is not."
  (and branch
       (seq-some (lambda (r)
                   (equal branch (funcall wt-for-root r)))
                 roots)
       t))

;; --- backfill from an existing log -----------------------------------

(defun decknix-session-assoc-from-lines (lines roots)
  "Return (TURN . ASSOC) built from broker-log LINES, resolved against ROOTS.

TURN is the turn index the last line sits in, so the caller can seed a
session\='s recency clock and have the window mean the same thing as it
would had the capture run live.

Turn boundaries are results carrying `stopReason\=', the same marker the
replay uses.  Counted WITHIN the lines given: a bounded tail is all that
can be read -- the largest live log measured 207 MB -- so the indices are
relative to the start of that tail, which is exactly what the recency
window needs.

Pure, so a backfill can be verified against a real log without writing
anything."
  (let ((turn 0) (assoc nil))
    (dolist (line lines)
      (let ((obj (decknix--assoc-parse-line line)))
        (cond
         ((null obj) nil)
         ((decknix--assoc-turn-boundary-p obj) (setq turn (1+ turn)))
         (t
          (let ((update (alist-get 'update (alist-get 'params obj))))
            (dolist (path (decknix-session-assoc-paths-of update))
              (when-let* ((root (decknix-session-assoc-resolve path roots)))
                (setq assoc (decknix-session-assoc-touch assoc root turn)))))))))
    (cons turn assoc)))

(defun decknix--assoc-parse-line (line)
  "Parse LINE as one ACP JSON object, or nil."
  (when (and line (stringp line))
    (let ((s (string-trim line)))
      (when (and (> (length s) 0) (eq (aref s 0) ?{))
        (ignore-errors
          (json-parse-string s :object-type 'alist
                             :null-object nil :false-object nil))))))

(defun decknix--assoc-turn-boundary-p (obj)
  "Non-nil when OBJ is a result carrying a `stopReason\=' -- a committed turn."
  (let ((res (alist-get 'result obj)))
    (and (listp res) (alist-get 'stopReason res))))

;; --- capture (side-effecting, kept here with its own pure core) -------

(defvar decknix--agent-assoc-roots-cache nil
  "Cons of (WT-COUNT . ROOTS): the worktree roots and the table size they
were derived from.

Rebuilt only when the worktree table\='s SIZE changes.  Capture runs from
the ACP notification handler, which fires on every streamed chunk, and
`decknix-hub-wt-rows\=' walks a hash table and allocates a list -- calling
it per tool call is the shape of defect that has already cost three
performance regressions in this tree.

A worktree replaced without changing the count is missed until the next
count change.  That is accepted: the alternative is re-deriving the list
on a hot path, and a stale root only delays an association.")

(declare-function decknix-hub-wt-rows "decknix-hub-wt-stale" ())
(defvar decknix--hub-wt-facts)

(defcustom decknix-session-assoc-repo-report
  (expand-file-name "~/.config/decknix/repo-sync.json")
  "Report listing every repo checkout in the workspace.

Needed because the worktree audit lists only WORKTREES.  A session
editing in a primary checkout resolved against nothing and recorded no
association at all -- measured, the session this was built for had edited
decknix-config and platform-cli themselves."
  :type 'file
  :group 'decknix)

(defvar decknix--agent-assoc-repo-roots-cache nil
  "Cons of (MTIME . PATHS) read from `decknix-session-assoc-repo-report'.")

(defun decknix-session-assoc-repo-roots ()
  "Return every repo checkout path, cached on the report's mtime."
  (let* ((f decknix-session-assoc-repo-report)
         (attrs (and (file-readable-p f) (file-attributes f)))
         (mtime (and attrs (float-time
                            (file-attribute-modification-time attrs)))))
    (cond
     ((null mtime) (cdr decknix--agent-assoc-repo-roots-cache))
     ((and decknix--agent-assoc-repo-roots-cache
           (equal mtime (car decknix--agent-assoc-repo-roots-cache)))
      (cdr decknix--agent-assoc-repo-roots-cache))
     (t
      (let ((paths
             (ignore-errors
               (let* ((json (with-temp-buffer (insert-file-contents f)
                                              (buffer-string)))
                      (data (json-parse-string json :object-type 'alist
                                               :array-type 'list
                                               :null-object nil
                                               :false-object nil)))
                 (delq nil (mapcar (lambda (r) (alist-get 'path r))
                                   (alist-get 'repos data)))))))
        (setq decknix--agent-assoc-repo-roots-cache (cons mtime paths))
        paths)))))

(defun decknix-session-assoc-roots ()
  "Return the known worktree AND repo-checkout roots.

Both, because a session works in whichever it happens to be in.  The
worktree audit alone left a session editing a primary checkout resolving
against nothing.

Resolution takes the LONGEST match, so a file inside a worktree still
attributes to that worktree rather than to the repo whose path is also a
prefix of it."
  (append
   (decknix-session-assoc-repo-roots)
   (if (not (and (boundp 'decknix--hub-wt-facts)
                 (hash-table-p decknix--hub-wt-facts)
                 (fboundp 'decknix-hub-wt-rows)))
       (cdr decknix--agent-assoc-roots-cache)
     (let ((count (hash-table-count decknix--hub-wt-facts)))
       (unless (and decknix--agent-assoc-roots-cache
                    (equal count (car decknix--agent-assoc-roots-cache)))
         (setq decknix--agent-assoc-roots-cache
               (cons count
                     (delq nil
                           (mapcar (lambda (r)
                                     (or (alist-get 'path r)
                                         (plist-get r :path)))
                                   (ignore-errors (decknix-hub-wt-rows)))))))
       (cdr decknix--agent-assoc-roots-cache)))))

(defvar-local decknix--agent-assoc nil
  "This session\='s (ROOT . LAST-TURN) alist of observed worktrees.")

(defvar-local decknix--agent-assoc-turn 0
  "This session\='s turn counter, used as the recency clock.")

(defun decknix-session-assoc-observe (update)
  "Record the worktrees an ACP session UPDATE touches, in the current buffer.

Returns non-nil when something was recorded.  Does nothing for an update
carrying no `locations\=', which is nearly all of them -- the measured
session had 24707 message chunks against 2400 tool calls."
  (when-let* ((paths (decknix-session-assoc-paths-of update)))
    (let ((roots (decknix-session-assoc-roots))
          (any nil))
      (dolist (path paths)
        (when-let* ((root (decknix-session-assoc-resolve path roots)))
          (setq decknix--agent-assoc
                (decknix-session-assoc-touch
                 decknix--agent-assoc root decknix--agent-assoc-turn))
          (setq any t)))
      any)))

(defun decknix-session-assoc-end-turn ()
  "Advance this session\='s recency clock, prune, and persist.

Persisted per TURN rather than per tool call: a turn boundary is rare
(360 over the life of the session measured) while tool calls are not
(2400), and writing the store on each would put a file write on the
notification path."
  (setq decknix--agent-assoc-turn (1+ decknix--agent-assoc-turn))
  (setq decknix--agent-assoc
        (decknix-session-assoc-prune
         decknix--agent-assoc decknix--agent-assoc-turn))
  (when (and (local-variable-p 'decknix--agent-broker-key)
             (bound-and-true-p decknix--agent-broker-key))
    (ignore-errors
      (decknix-session-assoc-remember
       decknix--agent-broker-key decknix--agent-assoc-turn
       decknix--agent-assoc))
    ;; And read what this turn added to the broker log, which is what
    ;; recovers a PR live capture missed.
    (ignore-errors
      (decknix-session-assoc-created-turn-ended decknix--agent-broker-key))))

(defcustom decknix-session-assoc-backfill-steps '(4 16)
  "Tail sizes in MB to try when backfilling from a broker log.

Escalating, stopping as soon as an association is found.  Measured on a
76 MB log: a 4 MB tail covered only the last 15 turns, which happened to
hold no file activity at all; 16 MB reached the work and produced the
same answer as 48 MB, so there is nothing to gain past it.

Cost is why this escalates rather than reading one large window: 4 MB
parses in ~265 ms and 16 MB in ~1.7 s, and most logs are small enough
that the first step answers."
  :type '(repeat integer)
  :group 'decknix)

(defun decknix-session-assoc-backfill (log-path &optional roots)
  "Return (TURN . ASSOC) for LOG-PATH, read from an escalating tail.

Stops at the first window that yields an association, so a small log
costs one small read.  Nil when the log is unreadable or nothing in it
resolves to a known root."
  (when (and log-path (file-readable-p log-path))
    (let* ((roots (or roots (decknix-session-assoc-roots)))
           (size (or (file-attribute-size (file-attributes log-path)) 0))
           (result nil))
      (catch 'done
        (dolist (mb decknix-session-assoc-backfill-steps)
          (let* ((window (* mb 1024 1024))
                 (beg (max 0 (- size window)))
                 (lines (with-temp-buffer
                          (insert-file-contents log-path nil beg size)
                          (split-string (buffer-string) "\n" t)))
                 (res (decknix-session-assoc-from-lines lines roots)))
            (when (cdr res) (setq result res) (throw 'done res))
            ;; The whole file was already in this window; a larger one
            ;; cannot help.
            (when (<= beg 0) (throw 'done nil))))
        nil)
      result)))

(defun decknix-session-assoc-apply (buffer turn assoc)
  "Seed BUFFER\='s association with TURN and ASSOC."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq decknix--agent-assoc assoc)
      (setq decknix--agent-assoc-turn turn))))

;; --- PRs a session created -------------------------------------------
;;
;; The association above is RECENCY-bounded: a session claims what it has
;; touched lately.  So a session that raised PRs and moved on lost them --
;; squad/nix/web-integration raised web-integration#89 and platform-cli#61,
;; then spent its later turns on a benchmark, and showed no PRs at all.  A
;; PR a session raised is its work for as long as the PR is open, so the
;; PRs it created are recorded separately and never age out.
;;
;; Two sources feed the record.  Live capture sees the ACP notifications
;; while the buffer is attached.  The broker log sees everything, attached
;; or not, and is read INCREMENTALLY: a byte offset per session, advanced
;; at each turn end and on a timer.  It used to be read once per session,
;; ever, so a PR raised while the buffer was detached, or while the store
;; was unreadable, was never recovered: seven PRs across three lanes showed
;; as unattended in the sidebar although their sessions had created them.

(defconst decknix-session-assoc-pr-url-re
  "https://github\\.com/\\([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\)/pull/\\([0-9]+\\)"
  "Matches a GitHub PR URL, capturing owner/repo and number.")

(defun decknix-session-assoc-bash-call-p (update)
  "Return non-nil when UPDATE belongs to a Bash tool call.
Claude Code names the tool in `_meta.claudeCode.toolName\='; other agents
only give the ACP kind, where `execute\=' is a terminal command.  Matching
on input text alone also caught an Agent call whose prompt told the
sub-agent to run `gh pr create\=', and the first PR URL in its summary,
any PR at all, was credited to the session."
  (let ((tool (map-nested-elt update '(_meta claudeCode toolName))))
    (if tool
        (equal tool "Bash")
      (equal (alist-get 'kind update) "execute"))))

(defun decknix-session-assoc-creating-call-p (update)
  "Return non-nil when UPDATE is a Bash call that runs `gh pr create\='."
  (and (decknix-session-assoc-bash-call-p update)
       (let ((cmd (alist-get 'command (alist-get 'rawInput update))))
         (and (stringp cmd)
              (string-match-p "\\bgh[ \t]+pr[ \t]+create\\b" cmd)))))

(defun decknix-session-assoc-output-text (update)
  "Return the output UPDATE carries, as one string.
`content\=' is read only from the completed update and only without a
`rawOutput\=': on earlier updates it can echo the command, whose PR body
names other PRs."
  (let ((raw (alist-get 'rawOutput update))
        (stdout (map-nested-elt update '(_meta claudeCode toolResponse stdout)))
        (content (and (null (alist-get 'rawOutput update))
                      (equal (alist-get 'status update) "completed")
                      (alist-get 'content update))))
    (mapconcat (lambda (v) (cond ((null v) "") ((stringp v) v) (t (format "%S" v))))
               (list raw stdout content) "\n")))

(defun decknix-session-assoc-output-prs (update)
  "Return every `owner/repo#N\=' in UPDATE\='s output, first seen first.
All of them: a loop raising three PRs in one call prints three URLs, and
keeping only the first recorded one."
  (let ((text (decknix-session-assoc-output-text update)) (start 0) out)
    (while (string-match decknix-session-assoc-pr-url-re text start)
      (push (format "%s#%s" (match-string 1 text) (match-string 2 text)) out)
      (setq start (match-end 0)))
    (seq-uniq (nreverse out))))

(defun decknix-session-assoc-note-created (update pending created)
  "Fold UPDATE into PENDING (a hash of tool-call ids) and CREATED (a list).
Returns the new CREATED.  A creating call\='s id is remembered until the
call completes, and every PR URL in its output on the way is added."
  (let ((id (alist-get 'toolCallId update)))
    (when (and id (decknix-session-assoc-creating-call-p update))
      (puthash id t pending))
    (if (not (and id (gethash id pending)))
        created
      (let ((prs (seq-remove (lambda (pr) (member pr created))
                             (decknix-session-assoc-output-prs update))))
        (when (member (alist-get 'status update) '("completed" "failed"))
          (remhash id pending))
        (append created prs)))))

(defun decknix-session-assoc-published-created (obj)
  "Return `owner/repo#N\=' when OBJ is Claude Code\='s record of a new PR.
The broker logs it as a `code_change_published\=' system event with
action `created\=', whichever call or sub-agent ran the command, so it
does not depend on reading the command or its output at all."
  (when (and (equal (alist-get 'subtype obj) "code_change_published")
             (equal (alist-get 'action obj) "created"))
    (let ((url (alist-get 'url obj)))
      (when (and (stringp url)
                 (string-match decknix-session-assoc-pr-url-re url))
        (format "%s#%s" (match-string 1 url) (match-string 2 url))))))

(defun decknix--assoc-parse-event (line)
  "Parse the JSON object in broker-log LINE, or nil.
System events are logged after a prefix (`!Unexpected case: {...}\='), so
parsing starts at the first brace rather than requiring one first."
  (when (stringp line)
    (when-let* ((i (string-search "{" line)))
      (ignore-errors
        (json-parse-string (if (eq i 0) line (substring line i))
                           :object-type 'alist
                           :null-object nil :false-object nil)))))

(defun decknix-session-assoc-created-fold-line (line pending created)
  "Fold broker-log LINE into PENDING and CREATED; return the new CREATED.
A sub-agent\='s tool calls stream through its parent\='s log (carrying
`_meta.claudeCode.parentToolUseId\='), so what a sub-agent creates is
credited to the session that owns the log."
  (let ((obj (decknix--assoc-parse-event line)))
    (if-let* ((pr (and obj (decknix-session-assoc-published-created obj))))
        (if (member pr created) created (append created (list pr)))
      (let ((update (and obj (map-nested-elt obj '(params update)))))
        (if update
            (decknix-session-assoc-note-created update pending created)
          created)))))

(defun decknix-session-assoc-created-from-lines (lines &optional pending)
  "Return the PRs created in broker-log LINES, as `owner/repo#N\=' strings.
PENDING, a hash of tool-call ids, carries creating calls across reads."
  (let ((pending (or pending (make-hash-table :test 'equal))) (created nil))
    (dolist (line lines)
      (setq created (decknix-session-assoc-created-fold-line line pending created)))
    created))

(defvar-local decknix--agent-assoc-creating nil
  "Tool-call ids of this session\='s in-flight `gh pr create\=' calls.")

(defun decknix-session-assoc-observe-created (update)
  "Record a PR this session just created, from live UPDATE.  Returns it or nil."
  (unless decknix--agent-assoc-creating
    (setq decknix--agent-assoc-creating (make-hash-table :test 'equal)))
  (when-let* ((key (and (local-variable-p 'decknix--agent-broker-key)
                        (bound-and-true-p decknix--agent-broker-key)))
              (found (decknix-session-assoc-note-created
                      update decknix--agent-assoc-creating nil)))
    (car (last (decknix-session-assoc-created-record key found)))))

(defun decknix-session-assoc-state-dir ()
  "Return the decknix state directory."
  (expand-file-name
   "decknix" (or (getenv "XDG_STATE_HOME") (expand-file-name ".local/state" "~"))))

(defun decknix-session-assoc-created-file ()
  "Return the file recording which PRs each session created."
  (expand-file-name "session-prs.eld" (decknix-session-assoc-state-dir)))

(defun decknix--session-assoc-write-atomic (file data)
  "Print DATA to FILE through a temporary file renamed into place.
A reader, or a crash mid-write, sees the old file or the new one, never
the torn one that once left session-prs.eld unreadable."
  (make-directory (file-name-directory file) t)
  (let ((tmp (make-temp-file (concat file ".tmp-"))))
    (condition-case err
        (progn
          (with-temp-file tmp (decknix-state-io-prin1 data (current-buffer)))
          (rename-file tmp file t))
      (error (ignore-errors (delete-file tmp))
             (signal (car err) (cdr err))))))

(defun decknix--session-assoc-entry-p (entry)
  "Non-nil when ENTRY is a (BROKER-KEY . DATA) cell of either store."
  (and (consp entry) (stringp (car entry))))

(defvar decknix--agent-created-store 'unloaded
  "Alist of (BROKER-KEY . PR-KEYS), or `unloaded\='.")

(defun decknix--session-assoc-created-store ()
  "Return the created-PR store, loading it on first use."
  (when (eq decknix--agent-created-store 'unloaded)
    (setq decknix--agent-created-store
          (decknix-state-io-read-list (decknix-session-assoc-created-file)
                                      #'decknix--session-assoc-entry-p)))
  decknix--agent-created-store)

(defun decknix-session-assoc-created (key)
  "Return the PRs session KEY created, as `owner/repo#N\=' strings."
  (cdr (assoc key (decknix--session-assoc-created-store))))

(defun decknix-session-assoc-remember-created (key prs)
  "Record that session KEY created PRS, and persist."
  (when (stringp key)
    (setq decknix--agent-created-store
          (cons (cons key prs)
                (seq-remove (lambda (c) (equal (car c) key))
                            (decknix--session-assoc-created-store))))
    (ignore-errors
      (decknix--session-assoc-write-atomic
       (decknix-session-assoc-created-file) decknix--agent-created-store))))

(defun decknix-session-assoc-created-record (key prs)
  "Add PRS to the PRs session KEY created; mirror and return the new ones.
New means not recorded for KEY before, compared without case."
  (let* ((before (decknix-session-assoc-created key))
         (new nil))
    (dolist (pr prs)
      (unless (seq-some (lambda (b) (string-equal-ignore-case b pr))
                        (append before new))
        (setq new (append new (list pr)))))
    (when new
      (decknix-session-assoc-remember-created key (append before new))
      (decknix-session-assoc-link-created key new))
    new))

;; --- mirroring into the conversation's links --------------------------
;;
;; The store above is keyed by BROKER key, which a re-broker replaces, and
;; then the session's PRs are gone from the sidebar.  The conversation's
;; `linked_prs' in agent-sessions.json is keyed by the conversation, which
;; survives that, and the sidebar already reads it.  So each newly
;; recorded PR is also linked there, marked `auto'.  Only NEW ones: linking
;; a session's whole history would list dozens of merged PRs under it.

(declare-function decknix--agent-link-pr "decknix-agent-link-store"
                  (conv-key url &optional pr-type added))
(declare-function decknix--agent-linked-prs "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-pr-url-accessor "decknix-agent-url-parse" (pr field))
(declare-function decknix--agent-tags-read "decknix-agent-tags-store" ())
(declare-function decknix--agent-tags-conversations "decknix-agent-tags-store" (store))
(defvar decknix--agent-conv-key)

(defun decknix-session-assoc-pr-url (pr)
  "Return the GitHub URL of PR, an `owner/repo#N\=' string, or nil."
  (when (and (stringp pr) (string-match "\\`\\([^#]+\\)#\\([0-9]+\\)\\'" pr))
    (format "https://github.com/%s/pull/%s" (match-string 1 pr) (match-string 2 pr))))

(defun decknix-session-assoc-buffer-for (key)
  "Return the live agent buffer whose broker key is KEY, or nil."
  (when (fboundp 'agent-shell-buffers)
    (seq-find (lambda (b)
                (and (buffer-live-p b)
                     (local-variable-p 'decknix--agent-broker-key b)
                     (equal (buffer-local-value 'decknix--agent-broker-key b) key)))
              (ignore-errors (agent-shell-buffers)))))

(defun decknix-session-assoc-conv-key-for (key)
  "Return the conversation key of the session with broker key KEY, or nil.
The live buffer\='s own key first, since that is the one the sidebar reads;
else the stored conversation recording KEY as its `brokerKey\='."
  (or (when-let* ((buf (decknix-session-assoc-buffer-for key)))
        (and (local-variable-p 'decknix--agent-conv-key buf)
             (buffer-local-value 'decknix--agent-conv-key buf)))
      (when (and (fboundp 'decknix--agent-tags-read)
                 (fboundp 'decknix--agent-tags-conversations))
        (let ((convs (decknix--agent-tags-conversations (decknix--agent-tags-read)))
              (found nil))
          (when (hash-table-p convs)
            (maphash (lambda (ck e)
                       (when (and (not found) (hash-table-p e)
                                  (equal (gethash "brokerKey" e) key))
                         (setq found ck)))
                     convs))
          found))))

(defun decknix-session-assoc-linked-p (conv-key pr)
  "Return non-nil when PR is already linked to CONV-KEY, however added.
Compared as `owner/repo#N\=' without case, so a manual link written with
different case or a trailing path is neither duplicated nor replaced."
  (seq-some (lambda (rec)
              (let ((url (decknix--agent-pr-url-accessor rec "url")))
                (and (stringp url)
                     (string-match decknix-session-assoc-pr-url-re url)
                     (string-equal-ignore-case
                      (format "%s#%s" (match-string 1 url) (match-string 2 url))
                      pr))))
            (decknix--agent-linked-prs conv-key)))

(defun decknix-session-assoc-link-created (key prs)
  "Link PRS, which session KEY created, to its conversation as `auto\='."
  (when (and prs (fboundp 'decknix--agent-link-pr)
             (fboundp 'decknix--agent-linked-prs)
             (fboundp 'decknix--agent-pr-url-accessor))
    (ignore-errors
      (when-let* ((ck (decknix-session-assoc-conv-key-for key)))
        (dolist (pr prs)
          (unless (decknix-session-assoc-linked-p ck pr)
            (decknix--agent-link-pr ck (decknix-session-assoc-pr-url pr)
                                    "authored" "auto")))))))

;; --- incremental broker-log scan --------------------------------------

(defcustom decknix-session-assoc-created-chunk (* 32 1024 1024)
  "Most bytes of a broker log one scan reads.
Logs pass 100 MB and the first scan of each starts at byte 0, so the
catch-up is split into chunks, each in its own short-lived child."
  :type 'integer
  :group 'decknix)

(defun decknix--assoc-created-candidate-p (bol eol pending)
  "Non-nil when the line from BOL to EOL can change what was created.
Most lines cannot, and the cheap search keeps a 32 MB chunk from being
parsed as JSON line by line."
  (save-excursion
    (or (progn (goto-char bol) (search-forward "gh pr create" eol t))
        (progn (goto-char bol) (search-forward "code_change_published" eol t))
        (catch 'hit
          (maphash (lambda (id _)
                     (goto-char bol)
                     (when (search-forward id eol t) (throw 'hit t)))
                   pending)
          nil))))

(defun decknix-session-assoc-created-scan-chunk (log-path offset pending &optional cap)
  "Scan LOG-PATH from byte OFFSET for created PRs; return a plist.
PENDING lists the ids of creating calls whose output may still be to come.
Reads at most CAP bytes (default `decknix-session-assoc-created-chunk'),
more only when one line is longer than that.

Returns (:offset END :pending IDS :prs PRS :size SIZE :complete BOOL
:reset BOOL).  END is just past the last COMPLETE line read, so a line
being written is read whole next time rather than half now.  A log
smaller than OFFSET was truncated or replaced, and is read from 0 with
:reset t.  :complete means the read reached SIZE, the end of the file.

Pure apart from reading the file, so the daemon and a child Emacs give
the same answer."
  (let* ((size (or (file-attribute-size (file-attributes log-path)) 0))
         (reset (> offset size))
         (offset (if reset 0 offset))
         (cap (max 1 (or cap decknix-session-assoc-created-chunk)))
         (table (make-hash-table :test 'equal))
         (created nil) (end offset) (complete nil))
    (dolist (id pending) (puthash id t table))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let ((want cap) (done nil))
        (while (not done)
          (erase-buffer)
          (let ((stop (min size (+ offset want))))
            (when (> stop offset)
              (insert-file-contents-literally log-path nil offset stop))
            (setq complete (>= stop size))
            (goto-char (point-max))
            (cond ((search-backward "\n" nil t)
                   (setq end (+ offset (point)) done t))
                  (complete (setq done t))
                  (t (setq want (* 2 want)))))))
      (let ((limit (1+ (- end offset))))
        (goto-char (point-min))
        (while (< (point) limit)
          (let ((bol (point)) (eol (line-end-position)))
            (when (decknix--assoc-created-candidate-p bol eol table)
              (setq created (decknix-session-assoc-created-fold-line
                             (decode-coding-string
                              (buffer-substring-no-properties bol eol) 'utf-8)
                             table created)))
            (goto-char (1+ eol))))))
    (list :offset end :pending (hash-table-keys table) :prs created
          :size size :complete complete :reset reset)))

(defun decknix-session-assoc-created-scan-command (log-path offset pending cap)
  "Return the argv of a batch Emacs printing one chunk scan of LOG-PATH.
The child loads this same library, so the answer is exactly what
`decknix-session-assoc-created-scan-chunk' gives in the daemon."
  (let ((form `(progn
                 (setq native-comp-jit-compilation nil)
                 (require 'decknix-session-assoc)
                 (decknix-state-io-prin1
                  (decknix-session-assoc-created-scan-chunk
                   ,log-path ,offset ',pending ,cap)))))
    (list (expand-file-name invocation-name invocation-directory)
          "-Q" "--batch"
          "-L" (file-name-directory (locate-library "decknix-session-assoc"))
          "-L" (file-name-directory (locate-library "decknix-state-io"))
          "--eval" (decknix-state-io-to-string form))))

(defun decknix-session-assoc-created-scan (log-path offset pending callback &optional cap)
  "Scan LOG-PATH from OFFSET in a child Emacs; return the process.
CALLBACK receives the plist of `decknix-session-assoc-created-scan-chunk',
or the symbol `error\='.  Out of process because a read of a large log
froze Emacs for minutes while endpoint security inspected it, and a
\\[keyboard-quit] out of it left the same scan to start again."
  (let ((buf (generate-new-buffer " *decknix-created-scan*" t)))
    (make-process
     :name "decknix-created-scan" :buffer buf
     :command (decknix-session-assoc-created-scan-command
               (expand-file-name log-path) offset pending
               (or cap decknix-session-assoc-created-chunk))
     :connection-type 'pipe :noquery t :coding 'utf-8-unix
     :stderr (get-buffer-create " *decknix-created-scan-stderr*")
     :sentinel
     (lambda (proc _event)
       (unless (process-live-p proc)
         (let ((res (if (and (eq (process-status proc) 'exit)
                             (eq 0 (process-exit-status proc))
                             (buffer-live-p buf))
                        (condition-case nil
                            (car (read-from-string
                                  (with-current-buffer buf (buffer-string))))
                          (error 'error))
                      'error)))
           (when (buffer-live-p buf) (kill-buffer buf))
           (funcall callback (if (and (consp res) (plist-member res :offset))
                                 res
                               'error))))))))

;; Offsets live in their own file: the created store is read by the
;; sidebar on every paint, and these change on every scan.

(defun decknix-session-assoc-created-offsets-file ()
  "Return the file recording how far each session\='s broker log was read."
  (expand-file-name "session-prs-offsets.eld" (decknix-session-assoc-state-dir)))

(defvar decknix--agent-created-offsets 'unloaded
  "Alist of (BROKER-KEY OFFSET . PENDING-IDS), or `unloaded\='.")

(defun decknix--session-assoc-created-offsets ()
  "Return the offsets store, loading it on first use."
  (when (eq decknix--agent-created-offsets 'unloaded)
    (setq decknix--agent-created-offsets
          (seq-filter (lambda (e) (natnump (cadr e)))
                      (decknix-state-io-read-list
                       (decknix-session-assoc-created-offsets-file)
                       (lambda (e) (and (decknix--session-assoc-entry-p e)
                                        (consp (cdr e))))))))
  decknix--agent-created-offsets)

(defun decknix-session-assoc-created-offset (key)
  "Return (OFFSET . PENDING-IDS) for session KEY, or nil when never read."
  (cdr (assoc key (decknix--session-assoc-created-offsets))))

(defun decknix-session-assoc-created-set-offset (key offset pending)
  "Record that session KEY\='s log was read to OFFSET with PENDING ids open."
  (setq decknix--agent-created-offsets
        (cons (cons key (cons offset pending))
              (seq-remove (lambda (c) (equal (car c) key))
                          (decknix--session-assoc-created-offsets))))
  (ignore-errors
    (decknix--session-assoc-write-atomic
     (decknix-session-assoc-created-offsets-file) decknix--agent-created-offsets)))

(defun decknix-session-assoc-created-apply-scan (key result)
  "Fold scan RESULT into session KEY\='s stores; return the PRs new to KEY."
  (decknix-session-assoc-created-set-offset
   key (plist-get result :offset) (plist-get result :pending))
  (decknix-session-assoc-created-record key (plist-get result :prs)))

;; --- persistence ------------------------------------------------------

(defun decknix-session-assoc-state-file ()
  "Return the file the association store lives in.

Under the STATE dir, not `~/.config/decknix\=': that is the system flake\='s
source tree, which nix copies on every `decknix switch\='."
  ;; v2: roots resolved before the worktree-directory fix name whole repos
  ;; and cannot be repaired in place.  A new file leaves every session's
  ;; store empty, which is what makes the backfill re-derive it from the
  ;; broker log with the current resolver.
  (expand-file-name
   "decknix/session-assoc-v2.eld"
   (or (getenv "XDG_STATE_HOME") (expand-file-name ".local/state" "~"))))

(defvar decknix--agent-assoc-store nil
  "Alist of (BROKER-KEY . (TURN . ASSOC)), loaded from disk.")

(defun decknix-session-assoc-load ()
  "Load the association store, returning it."
  (setq decknix--agent-assoc-store
        (decknix-state-io-read-list (decknix-session-assoc-state-file)
                                    #'decknix--session-assoc-entry-p)))

(defun decknix-session-assoc-save ()
  "Write the association store to disk."
  (ignore-errors
    (let ((f (decknix-session-assoc-state-file)))
      (make-directory (file-name-directory f) t)
      (with-temp-file f (decknix-state-io-prin1 decknix--agent-assoc-store (current-buffer))))))

(defun decknix-session-assoc-remember (key turn assoc)
  "Record KEY\='s TURN and ASSOC in the store and persist it."
  (when (and key (stringp key))
    (setq decknix--agent-assoc-store
          (cons (cons key (cons turn assoc))
                (seq-remove (lambda (c) (equal (car c) key))
                            decknix--agent-assoc-store)))
    (decknix-session-assoc-save)))

(defun decknix-session-assoc-recall (key)
  "Return KEY\='s stored (TURN . ASSOC), or nil."
  (cdr (assoc key decknix--agent-assoc-store)))

(defun decknix-session-assoc-current (&optional buffer)
  "Return the worktree roots BUFFER is currently working in."
  (with-current-buffer (or buffer (current-buffer))
    (when (local-variable-p 'decknix--agent-assoc)
      (decknix-session-assoc-active
       decknix--agent-assoc
       (if (local-variable-p 'decknix--agent-assoc-turn)
           decknix--agent-assoc-turn
         0)))))

;; --- launching work from a row ----------------------------------------

(defun decknix-session-assoc-suggest-tags (path &optional branch)
  "Return suggested session tags for work at PATH on BRANCH.

The repo short name, plus the ticket key when the branch or worktree
directory carries one.  `platform-cli-worktrees/ACME-1040-generator-fixes\='
suggests (\"platform-cli\" \"ACME-1040\"), which is how these sessions are
named by hand anyway.

Suggestions only: every prompt still runs, so a wrong guess costs a
keystroke rather than a mis-tagged session."
  (let* ((path (and path (directory-file-name (expand-file-name path))))
         (base (and path (file-name-nondirectory path)))
         (parent (and path (file-name-nondirectory
                            (directory-file-name
                             (file-name-directory path)))))
         ;; A worktree lives in `<repo>-worktrees/<branch>', so the repo is
         ;; the parent with that suffix removed; otherwise PATH is the repo.
         (repo (if (and parent (string-suffix-p "-worktrees" parent))
                   (string-remove-suffix "-worktrees" parent)
                 base))
         (ticket (car (seq-keep
                       (lambda (s)
                         (and (stringp s)
                              (string-match "\\b\\([A-Z][A-Z0-9]+-[0-9]+\\)" s)
                              (match-string 1 s)))
                       (list branch base)))))
    (delq nil (list repo ticket))))

(defun decknix-session-assoc-launch-target (row)
  "Return (PATH . TAGS) to launch a session for sidebar ROW, or nil.

ROW is a plist carrying at least `:path\=', optionally `:branch\='.  Returns
nil when there is no path, since a session has to start somewhere."
  (let ((path (plist-get row :path)))
    (when (and path (stringp path) (not (string-empty-p path)))
      (cons (expand-file-name path)
            (decknix-session-assoc-suggest-tags path (plist-get row :branch))))))

;; --- restore + deferred backfill --------------------------------------

(declare-function decknix--agent-broker-log-path
                  "decknix-agent-broker-rehydrate" (key))
(defvar decknix--agent-broker-key)

(defun decknix-session-assoc-restore (&optional buffer)
  "Seed BUFFER\='s association from the store, returning non-nil on a hit.

Called on resume so a reattached session shows the worktrees it was
working in immediately, rather than nothing until its next tool call."
  (with-current-buffer (or buffer (current-buffer))
    (when-let* (((local-variable-p 'decknix--agent-broker-key))
                (key decknix--agent-broker-key)
                (hit (decknix-session-assoc-recall key)))
      (decknix-session-assoc-apply (current-buffer) (car hit) (cdr hit))
      t)))

(defcustom decknix-session-assoc-backfill-idle 30
  "Seconds of idle time before backfilling one session\='s association.

Deferred and one-at-a-time because the parse is not cheap: a 16 MB tail
measured ~1.7 s, and 13 sessions would be ~22 s.  Doing that on a switch
would make the editor unusable exactly when the user is trying to start
work.

Each session is backfilled once ever -- the result is persisted -- so
this runs a handful of times and then never again."
  :type 'integer
  :group 'decknix)

(defvar decknix--agent-assoc-backfill-timer nil)

(defvar-local decknix--agent-assoc-backfilled nil
  "Non-nil once a backfill has been ATTEMPTED for this buffer.

Separate from whether it found anything, so a session that genuinely has
no association is not retried forever while one never tried still gets
its turn.")

(defun decknix-session-assoc-backfill-one (buffer)
  "Backfill BUFFER\='s association from its broker log and persist it.

Returns non-nil when something was recorded."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* (((local-variable-p 'decknix--agent-broker-key))
                  (key decknix--agent-broker-key)
                  ((fboundp 'decknix--agent-broker-log-path))
                  (log (decknix--agent-broker-log-path key))
                  (_ (setq decknix--agent-assoc-backfilled t))
                  (res (decknix-session-assoc-backfill log)))
        (decknix-session-assoc-apply buffer (car res) (cdr res))
        (decknix-session-assoc-remember key (car res) (cdr res))
        t))))

(defvar decknix--session-assoc-backfill-proc nil
  "The child Emacs backfilling one session\='s association, or nil.")

(defun decknix-session-assoc-backfill-command (log-path roots)
  "Return the argv of a batch Emacs printing LOG-PATH\='s backfill over ROOTS.
The child loads this same library, so the answer is exactly what
`decknix-session-assoc-backfill' gives in the daemon."
  (let ((form `(progn
                 (setq native-comp-jit-compilation nil)
                 (require 'decknix-session-assoc)
                 (let ((decknix-session-assoc-backfill-steps
                        ',decknix-session-assoc-backfill-steps))
                   (decknix-state-io-prin1
                    (decknix-session-assoc-backfill ,log-path ',roots))))))
    (list (expand-file-name invocation-name invocation-directory)
          "-Q" "--batch"
          "-L" (file-name-directory (locate-library "decknix-session-assoc"))
          "-L" (file-name-directory (locate-library "decknix-state-io"))
          "--eval" (decknix-state-io-to-string form))))

(defun decknix-session-assoc-backfill-async (log-path roots callback)
  "Compute LOG-PATH\='s backfill over ROOTS in a child Emacs; return it.
CALLBACK receives (TURN . ASSOC), nil when nothing resolved, or the
symbol `error'.  Reading and parsing a 4 to 16 MB log tail took one to
two seconds of the daemon\='s main thread per session, once for every
session after each restart."
  (let ((buf (generate-new-buffer " *decknix-assoc-backfill*" t)))
    (make-process
     :name "decknix-assoc-backfill" :buffer buf
     :command (decknix-session-assoc-backfill-command log-path roots)
     :connection-type 'pipe :noquery t :coding 'utf-8-unix
     :stderr (get-buffer-create " *decknix-assoc-backfill-stderr*")
     :sentinel
     (lambda (proc _event)
       (unless (process-live-p proc)
         (let ((res (if (and (eq (process-status proc) 'exit)
                             (eq 0 (process-exit-status proc))
                             (buffer-live-p buf))
                        (condition-case nil
                            (car (read-from-string
                                  (with-current-buffer buf (buffer-string))))
                          (error 'error))
                      'error)))
           (when (buffer-live-p buf) (kill-buffer buf))
           (funcall callback res)))))))

(defun decknix-session-assoc-backfill-start (buffer)
  "Backfill BUFFER\='s association in a child Emacs; return the process."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* (((local-variable-p 'decknix--agent-broker-key))
                  (key decknix--agent-broker-key)
                  ((fboundp 'decknix--agent-broker-log-path))
                  (log (decknix--agent-broker-log-path key))
                  (_ (setq decknix--agent-assoc-backfilled t))
                  ((file-readable-p log)))
        (setq decknix--session-assoc-backfill-proc
              (decknix-session-assoc-backfill-async
               log (decknix-session-assoc-roots)
               (lambda (res)
                 (setq decknix--session-assoc-backfill-proc nil)
                 (when (and (consp res) (cdr res))
                   (decknix-session-assoc-apply buffer (car res) (cdr res))
                   (decknix-session-assoc-remember key (car res) (cdr res))))))))))

(defun decknix-session-assoc-backfill-pending ()
  "Return the live agent buffers still awaiting a backfill.

A stored association that is EMPTY counts as pending.  Live capture
persists on every turn boundary, including when it has recorded nothing,
so within a turn of startup it wrote (TURN . nil) for each session -- and
treating any stored entry as done excluded every one of them from the
backfill permanently.  Measured: all 13 stored associations held zero
roots, which is the whole feature doing nothing."
  (when (fboundp 'agent-shell-buffers)
    (seq-filter
     (lambda (b)
       (and (buffer-live-p b)
            (with-current-buffer b
              (and (local-variable-p 'decknix--agent-broker-key)
                   decknix--agent-broker-key
                   (not decknix--agent-assoc-backfilled)
                   (null (cdr (decknix-session-assoc-recall
                               decknix--agent-broker-key)))))))
     (ignore-errors (agent-shell-buffers)))))

;; --- scheduling the created-PR scan -----------------------------------

(defcustom decknix-session-assoc-created-interval 60
  "Seconds between checks for broker logs that grew.
A plain timer, not an idle one: an idle timer fires once per idle period,
so lanes raising PRs while the user is away would wait until they came
back.  A check is a `stat\=' per live session; the read runs in a child."
  :type 'integer
  :group 'decknix)

(defcustom decknix-session-assoc-created-soon-idle 2
  "Idle seconds before a scan asked for at a turn end starts."
  :type 'number
  :group 'decknix)

(defvar decknix--session-assoc-created-scan nil
  "The child process scanning a broker log for created PRs, or nil.")

(defvar decknix--session-assoc-created-seen (make-hash-table :test 'equal)
  "Broker key -> log size when its last scan reached the end of the log.
A log whose size has not moved since is not read again, which also stops
a failing scan, or a last line never finished, being retried every tick.")

(defvar decknix--session-assoc-created-dirty nil
  "Broker keys whose turn ended since their last scan, oldest first.")

(defvar decknix--session-assoc-created-timer nil
  "The periodic timer checking for grown broker logs.")

(defvar decknix--session-assoc-created-soon nil
  "The pending one-shot idle timer for a scan, or nil.")

(defun decknix-session-assoc-created-live-logs ()
  "Return (KEY . LOG) for every live agent buffer with a broker log."
  (when (and (fboundp 'agent-shell-buffers)
             (fboundp 'decknix--agent-broker-log-path))
    (delq nil
          (mapcar (lambda (b)
                    (when (and (buffer-live-p b)
                               (local-variable-p 'decknix--agent-broker-key b))
                      (when-let* ((key (buffer-local-value 'decknix--agent-broker-key b))
                                  (log (ignore-errors (decknix--agent-broker-log-path key))))
                        (cons key log))))
                  (ignore-errors (agent-shell-buffers))))))

(defun decknix-session-assoc-created-due-p (key log)
  "Return non-nil when session KEY\='s LOG has lines not yet scanned."
  (when-let* ((size (and log (file-attribute-size (file-attributes log)))))
    (let ((offset (or (car (decknix-session-assoc-created-offset key)) 0)))
      (or (< size offset)
          (and (> size offset)
               (not (eql size (gethash key decknix--session-assoc-created-seen))))))))

(defun decknix-session-assoc-created-next ()
  "Return the (KEY . LOG) to scan next, or nil.
A session whose turn just ended goes first; then any whose log grew."
  (let ((logs (decknix-session-assoc-created-live-logs)) (next nil))
    (while (and (null next) decknix--session-assoc-created-dirty)
      (let* ((key (pop decknix--session-assoc-created-dirty))
             (cell (assoc key logs)))
        (when (and cell (decknix-session-assoc-created-due-p key (cdr cell)))
          (setq next cell))))
    (or next
        (seq-find (lambda (cell) (decknix-session-assoc-created-due-p (car cell) (cdr cell)))
                  logs))))

(defun decknix-session-assoc-created-start (key log)
  "Scan session KEY\='s LOG from where the last scan stopped; return the process."
  (let ((state (decknix-session-assoc-created-offset key)))
    (setq decknix--session-assoc-created-scan
          (decknix-session-assoc-created-scan
           log (or (car state) 0) (cdr state)
           (lambda (res)
             (setq decknix--session-assoc-created-scan nil)
             (if (not (consp res))
                 (puthash key (file-attribute-size (file-attributes log))
                          decknix--session-assoc-created-seen)
               (if (plist-get res :complete)
                   (puthash key (plist-get res :size) decknix--session-assoc-created-seen)
                 (remhash key decknix--session-assoc-created-seen))
               (when (decknix-session-assoc-created-apply-scan key res)
                 (decknix-session-assoc-refresh-sidebar))
               ;; More to read (a catch-up chunk, or lines that arrived
               ;; meanwhile): go on at the next quiet moment.
               (decknix-session-assoc-created-soon)))))))

(defun decknix-session-assoc-created-tick ()
  "Start scanning ONE session\='s new broker-log lines; return the process.
Nil when a scan or a backfill child is already running, or nothing is due."
  (unless (or (process-live-p decknix--session-assoc-created-scan)
              (process-live-p decknix--session-assoc-backfill-proc))
    (when-let* ((next (decknix-session-assoc-created-next)))
      (decknix-session-assoc-created-start (car next) (cdr next)))))

(defun decknix--session-assoc-created-quiet-tick ()
  "Run the scan tick unless the user is typing or in the minibuffer."
  (if (or (input-pending-p) (active-minibuffer-window))
      (decknix-session-assoc-created-soon)
    (ignore-errors (decknix-session-assoc-created-tick))))

(defun decknix-session-assoc-created-soon ()
  "Run the scan tick at the next quiet moment.  Bursts collapse to one."
  (unless (timerp decknix--session-assoc-created-soon)
    (setq decknix--session-assoc-created-soon
          (run-with-idle-timer
           decknix-session-assoc-created-soon-idle nil
           (lambda ()
             (setq decknix--session-assoc-created-soon nil)
             (decknix--session-assoc-created-quiet-tick))))))

(defun decknix-session-assoc-created-turn-ended (key)
  "Ask for session KEY\='s broker log to be scanned soon."
  (when (stringp key)
    (unless (member key decknix--session-assoc-created-dirty)
      (setq decknix--session-assoc-created-dirty
            (append decknix--session-assoc-created-dirty (list key))))
    (decknix-session-assoc-created-soon)))

(defvar agent-shell-workspace-sidebar-buffer-name "*Agent Sidebar*")

(defun decknix-session-assoc-refresh-sidebar ()
  "Repaint the agent sidebar when it exists."
  (when (and (fboundp 'agent-shell-workspace-sidebar-refresh)
             (get-buffer (or (bound-and-true-p agent-shell-workspace-sidebar-buffer-name)
                             "*Agent Sidebar*")))
    (ignore-errors (agent-shell-workspace-sidebar-refresh))))

(defun decknix-session-assoc-backfill-tick ()
  "Start ONE child reading a broker log, then stop until the next tick.

Both kinds of backfill read a broker log, so each runs in a child
process and this tick only starts one, when none is running: the
association first, then once none is pending, the created-PR scan.  The
daemon touches only the small finished result."
  (unless (or (process-live-p decknix--session-assoc-backfill-proc)
              (process-live-p decknix--session-assoc-created-scan))
    (if-let* ((buf (car (decknix-session-assoc-backfill-pending))))
        (ignore-errors (decknix-session-assoc-backfill-start buf))
      (ignore-errors (decknix-session-assoc-created-tick)))))

(defun decknix-session-assoc-start-backfill ()
  "Begin backfilling associations on idle and scanning for PRs.  Idempotent."
  (decknix-session-assoc-load)
  (unless decknix--agent-assoc-backfill-timer
    (setq decknix--agent-assoc-backfill-timer
          (run-with-idle-timer decknix-session-assoc-backfill-idle t
                               #'decknix-session-assoc-backfill-tick)))
  (unless (timerp decknix--session-assoc-created-timer)
    (setq decknix--session-assoc-created-timer
          (run-with-timer decknix-session-assoc-created-interval
                          decknix-session-assoc-created-interval
                          #'decknix--session-assoc-created-quiet-tick))))

;;;###autoload
(defun decknix-session-assoc-backfill-now ()
  "Backfill every pending session\='s association now, and rescan for PRs.

The deferred path does this on idle; this is for when you want it done
before the next idle period.  The PR scan still runs in a child, one
session after another, so it returns at once."
  (interactive)
  (decknix-session-assoc-load)
  (let ((pending (decknix-session-assoc-backfill-pending)) (done 0))
    (if (null pending)
        (message "Session associations: nothing pending")
      (dolist (buf pending)
        (message "Backfilling %s..." (buffer-name buf))
        (when (decknix-session-assoc-backfill-one buf)
          (setq done (1+ done))))
      (message "Session associations: %d of %d backfilled"
               done (length pending)))
    ;; Forget which logs were read to the end, so every live session is
    ;; checked again; the offsets stay, so only new lines are read.
    (clrhash decknix--session-assoc-created-seen)
    (dolist (cell (decknix-session-assoc-created-live-logs))
      (decknix-session-assoc-created-turn-ended (car cell)))
    (decknix-session-assoc-created-tick)
    (decknix-session-assoc-refresh-sidebar)))


(declare-function agent-shell-buffers "agent-shell" ())
(declare-function agent-shell-workspace-sidebar-refresh
                  "agent-shell-workspace" ())

(provide 'decknix-session-assoc)
;;; decknix-session-assoc.el ends here
