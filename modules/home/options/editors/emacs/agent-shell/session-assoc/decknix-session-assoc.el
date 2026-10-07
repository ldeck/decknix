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
;; live session tagged `helix/nix/rea-integration': it had edited files in 39
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
;; `platform-cli-worktrees/CONN-1040' is attributed to that worktree and not
;; to `platform-cli' -- which is the whole point of being worktree-granular.
;;
;; Pure here; capture at notification time and persistence live in the
;; wiring layer per AGENTS.md Rule 2.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'json)

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
`platform-cli-worktrees/CONN-1040' must attribute to that worktree rather
than to `platform-cli', and a plain prefix test would pick whichever came
first in the list."
  (when (and (stringp path) roots)
    (let ((best nil) (best-len -1))
      (dolist (root roots)
        (when (and (stringp root) (not (string-empty-p root)))
          (let* ((dir (file-name-as-directory root))
                 (len (length dir)))
            (when (and (> len best-len) (string-prefix-p dir path))
              (setq best root best-len len)))))
      (or best (decknix-session-assoc-resolve-removed path roots)))))

(defun decknix-session-assoc-resolve-removed (path roots)
  "Resolve PATH to its REPO when the worktree it named is gone.

A worktree lives at `<repo>-worktrees/<branch>\=', and once the work merges
the worktree is removed -- so its paths match no root, and a session whose
recent work was there resolves to nothing at all.  Measured: the session
this was built for had its last activity in
platform-cli-worktrees/CONN-1040-generator-fixes, which no longer exists.

The repo outlives the worktree and still carries the PRs, so attributing
to it keeps the association that matters.  Derived from the path alone,
by the naming convention, and only accepted when that repo IS a known
root."
  (when (string-match "\\`\\(.*\\)-worktrees/" path)
    (let ((repo (match-string 1 path)))
      (seq-find (lambda (r)
                  (and (stringp r)
                       (string= (file-name-as-directory r)
                                (file-name-as-directory repo))))
                roots))))

(defun decknix-session-assoc-paths-of (update)
  "Return the file paths an ACP session UPDATE reports touching.

Reads `locations', which is where `tool_call' and `tool_call_update'
carry them.

Accepts a VECTOR as well as a list, because that is what the JSON
actually parses to: `json-parse-string' renders arrays as vectors, so a
`listp' test discarded every path.  Hand-written alist fixtures hid it --
they pass a list -- while a real log yielded nothing at all."
  (let ((locs (alist-get 'locations update)))
    (delq nil
          (mapcar (lambda (loc)
                    (let ((p (and (or (listp loc) (vectorp loc))
                                  (alist-get 'path loc))))
                      (and (stringp p) (not (string-empty-p p)) p)))
                  (cond ((vectorp locs) (append locs nil))
                        ((listp locs) locs)
                        (t nil))))))

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
       decknix--agent-assoc))))

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

;; --- persistence ------------------------------------------------------

(defun decknix-session-assoc-state-file ()
  "Return the file the association store lives in.

Under the STATE dir, not `~/.config/decknix\=': that is the system flake\='s
source tree, which nix copies on every `decknix switch\='."
  (expand-file-name
   "decknix/session-assoc.eld"
   (or (getenv "XDG_STATE_HOME") (expand-file-name ".local/state" "~"))))

(defvar decknix--agent-assoc-store nil
  "Alist of (BROKER-KEY . (TURN . ASSOC)), loaded from disk.")

(defun decknix-session-assoc-load ()
  "Load the association store, returning it."
  (setq decknix--agent-assoc-store
        (or (ignore-errors
              (let ((f (decknix-session-assoc-state-file)))
                (when (file-readable-p f)
                  (with-temp-buffer
                    (insert-file-contents f)
                    (read (current-buffer))))))
            nil)))

(defun decknix-session-assoc-save ()
  "Write the association store to disk."
  (ignore-errors
    (let ((f (decknix-session-assoc-state-file)))
      (make-directory (file-name-directory f) t)
      (with-temp-file f (prin1 decknix--agent-assoc-store (current-buffer))))))

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
directory carries one.  `platform-cli-worktrees/CONN-1040-generator-fixes\='
suggests (\"platform-cli\" \"CONN-1040\"), which is how these sessions are
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

(defvar-local decknix--agent-assoc-backfilled nil
  "Non-nil once a backfill has been ATTEMPTED for this buffer.

Separate from whether it found anything, so a session that genuinely has
no association is not retried forever while one never tried still gets
its turn.")

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

(defun decknix-session-assoc-backfill-tick ()
  "Backfill ONE pending session, then stop until the next idle period.

One per tick so a fleet of sessions cannot chain into a multi-second
freeze: 13 of them at ~1.7 s each is ~22 s."
  (when-let* ((buf (car (decknix-session-assoc-backfill-pending))))
    (ignore-errors (decknix-session-assoc-backfill-one buf))))

(defun decknix-session-assoc-start-backfill ()
  "Begin backfilling associations on idle.  Idempotent."
  (decknix-session-assoc-load)
  (unless decknix--agent-assoc-backfill-timer
    (setq decknix--agent-assoc-backfill-timer
          (run-with-idle-timer decknix-session-assoc-backfill-idle t
                               #'decknix-session-assoc-backfill-tick))))

;;;###autoload
(defun decknix-session-assoc-backfill-now ()
  "Backfill every pending session\='s association now, reporting progress.

The deferred path does this on idle; this is for when you want it done
before the next idle period."
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
               done (length pending))
      (when (fboundp 'agent-shell-workspace-sidebar-refresh)
        (ignore-errors (agent-shell-workspace-sidebar-refresh))))))

(declare-function agent-shell-buffers "agent-shell" ())
(declare-function agent-shell-workspace-sidebar-refresh
                  "agent-shell-workspace" ())

(provide 'decknix-session-assoc)
;;; decknix-session-assoc.el ends here
