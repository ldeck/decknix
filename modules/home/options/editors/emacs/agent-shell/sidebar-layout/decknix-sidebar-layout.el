;;; decknix-sidebar-layout.el --- Session-first sidebar model -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, sidebar

;;; Commentary:
;;
;; Pure model for the session-first sidebar: Reviews, then WIP, then
;; Unattached.
;;
;; Measured on a live workspace: 47 live sessions, of which 40 were review
;; sessions and 7 the user's own, 33 of them blocked on the user.  Listing
;; each session on its own row is 40 lines before anything else, which is why
;; the Live section had become unreadable and the review board was the only
;; usable view.  The whole of `decknix--layout-review-groups' exists to
;; collapse those 40 into one row per repo, expandable on demand.
;;
;; Two vocabularies meet here and do NOT agree:
;;
;;   session review-PR keys  "upside#21248"             (short repo)
;;   hub feed items          repo "UpsideRealty/upside" (owner/repo)
;;
;; so every comparison goes through `decknix--layout-pr-key', which folds
;; both to the same short, lowercased form.  Comparing them directly is the
;; obvious bug here and it fails silently -- every PR looks uncovered.
;;
;; Side-effecting render, expansion state and actions live in the sidebar
;; layer per AGENTS.md Rule 2.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'decknix-session-assoc)
(require 'subr-x)

(defconst decknix-sidebar-layout-attention-states '("waiting" "asking" "netfail")
  "States meaning a session is blocked on the user.
Same set the Requests filters treat as an attention override, so the two
cannot drift into disagreeing about what \"needs you\" means.")

(defconst decknix-sidebar-layout-state-order
  '("netfail" "waiting" "asking" "working" "finished" "ready" "closing")
  "Session states, most-urgent first.

`netfail' outranks `waiting' because a dead turn produced nothing at all,
while a permission prompt is merely paused.  `finished' sits above `ready'
because unread output is a weaker call on attention than a question but a
stronger one than an idle session.")

(defun decknix--layout-state-rank (state)
  "Return the sort rank of session STATE; lower is more urgent.
An unknown state sorts last rather than first: a state we do not recognise
is not evidence of urgency."
  (or (seq-position decknix-sidebar-layout-state-order state)
      (length decknix-sidebar-layout-state-order)))

(defun decknix--layout-attention-p (state)
  "Return non-nil when STATE means the session is blocked on the user."
  (and (member state decknix-sidebar-layout-attention-states) t))

(defun decknix--layout-pr-key (repo number)
  "Return the canonical PR key for REPO and NUMBER, or nil.

Folds `owner/repo' to its last segment and lowercases, so a feed item and a
session's recorded `repo#number' compare equal.  Nil when either half is
missing -- a half key would collide across PRs."
  (when (and repo number (not (string-empty-p (format "%s" repo))))
    (let* ((s (format "%s" repo))
           (short (car (last (split-string s "/" t)))))
      (when (and short (not (string-empty-p short)))
        (downcase (format "%s#%s" short number))))))

(defun decknix--layout-parse-pr-key (key)
  "Return (SHORT-REPO . NUMBER) parsed from KEY, or nil."
  (when (and (stringp key) (string-match "\\`\\(.+\\)#\\([0-9]+\\)\\'" key))
    (cons (downcase (match-string 1 key))
          (string-to-number (match-string 2 key)))))

;; --- sessions ---------------------------------------------------------

(defun decknix--layout-session-prs (session)
  "Return SESSION's review-PR keys, canonicalised."
  (delq nil (mapcar (lambda (k)
                      (let ((parsed (decknix--layout-parse-pr-key k)))
                        (and parsed (decknix--layout-pr-key (car parsed)
                                                            (cdr parsed)))))
                    (nth 2 session))))

(defun decknix--layout-review-session-p (session)
  "Return non-nil when SESSION was launched to review a PR.

Keyed off recorded review PRs rather than the buffer name: the naming
convention has changed twice (`pr-<repo>-<n>' then `auto/#n/<repo>/review'),
and both are live in the same workspace right now."
  (and (decknix--layout-session-prs session) t))

(defun decknix--layout-sort-sessions (sessions)
  "Return SESSIONS ordered by what needs attention first, then by name."
  (sort (copy-sequence sessions)
        (lambda (a b)
          (let ((ra (decknix--layout-state-rank (nth 3 a)))
                (rb (decknix--layout-state-rank (nth 3 b))))
            (if (/= ra rb)
                (< ra rb)
              (string< (or (nth 0 a) "") (or (nth 0 b) "")))))))

(defun decknix--layout-wip-sessions (sessions)
  "Return the user's own (non-review) SESSIONS, attention-ordered."
  (decknix--layout-sort-sessions
   (seq-remove #'decknix--layout-review-session-p sessions)))

;; --- reviews, collapsed by repo --------------------------------------

(defun decknix--layout-review-groups (sessions items)
  "Return per-repo review groups from SESSIONS and feed ITEMS.

Each group is a plist:
  :repo     short repo name
  :prs      list of (:key :number :state :item), attention-first
  :sessions how many DISTINCT live sessions cover this repo
  :asking   how many of those are blocked on the user

A PR appears whether or not a session covers it, so a request nobody has
started is a row in its repo's group rather than a separate section.  That
is what lets Requests fold in here.

Two things are deduplicated, both found by testing against a live-shaped
fixture rather than by reading the code:

- A PR covered by two sessions is ONE row.  Twelve PRs currently have two
  sessions each, so a row per (session, PR) pair listed each of them twice.
  The surviving row keeps the more urgent state, since that is the one that
  should draw the eye.
- `:sessions' counts distinct sessions, not pairs.  A group session covering
  two PRs of one repo is one agent, and counting it twice overstated exactly
  the repos where grouped dispatch is doing its job."
  (let ((by-repo (make-hash-table :test 'equal))
        (repo-sessions (make-hash-table :test 'equal)))
    (cl-flet ((ensure (repo)
                (or (gethash repo by-repo)
                    (puthash repo (list :repo repo :prs nil) by-repo))))
      ;; Sessions first: they are the reason a repo appears at all.
      (dolist (session sessions)
        (let ((keys (decknix--layout-session-prs session))
              (repos-seen nil))
          (dolist (key keys)
            (let* ((parsed (decknix--layout-parse-pr-key key))
                   (repo (car parsed)))
              (when repo
                ;; Count the session once per repo, however many of that
                ;; repo's PRs it covers.
                (unless (member repo repos-seen)
                  (push repo repos-seen)
                  (puthash repo (cons session (gethash repo repo-sessions))
                           repo-sessions))
                (let* ((entry (ensure repo))
                       (prs (plist-get entry :prs))
                       (hit (seq-find (lambda (p) (equal key (plist-get p :key)))
                                      prs)))
                  (if hit
                      ;; Already covered: keep the more urgent state.
                      (when (< (decknix--layout-state-rank (nth 3 session))
                               (decknix--layout-state-rank (plist-get hit :state)))
                        (plist-put hit :state (nth 3 session)))
                    (plist-put entry :prs
                               (cons (list :key key
                                           :number (cdr parsed)
                                           :state (nth 3 session)
                                           :item nil)
                                     prs)))))))))
      ;; Then feed items: attach to a covered PR, or add an uncovered row.
      (dolist (item items)
        (let* ((key (decknix--layout-pr-key (alist-get 'repo item)
                                            (alist-get 'number item)))
               (parsed (and key (decknix--layout-parse-pr-key key)))
               (repo (car parsed)))
          (when repo
            (let* ((entry (ensure repo))
                   (prs (plist-get entry :prs))
                   (hit (seq-find (lambda (p) (equal key (plist-get p :key))) prs)))
              (if hit
                  (plist-put hit :item item)
                (plist-put entry :prs
                           (cons (list :key key
                                       :number (cdr parsed)
                                       :state nil
                                       :item item)
                                 prs))))))))
    ;; Whether the feed told us anything at all.  With no data, a row with
    ;; a session and no item means "not yet known", not "finished".
    (let ((feed-known (and items t))
          (groups nil))
      (maphash
       (lambda (repo entry)
         (let* ((covering (delete-dups (gethash repo repo-sessions)))
                (prs (decknix--layout-mark-gone
                      (decknix--layout-sort-prs (plist-get entry :prs))
                      feed-known))
                (live-keys (decknix--layout-live-pr-keys prs)))
           (push (list :repo repo
                       :prs prs
                       :uncovered (seq-count (lambda (p) (null (plist-get p :state)))
                                             prs)
                       ;; PRs a session is on that have LEFT the review feed:
                       ;; merged, closed, or no longer requested of me.
                       :gone (seq-count #'decknix--layout-pr-gone-p prs)
                       :humans (seq-count #'decknix--layout-pr-human-p prs)
                       :bots (seq-count #'decknix--layout-pr-bot-p prs)
                       :sessions (length covering)
                       :asking (seq-count
                                (lambda (s)
                                  (and (decknix--layout-attention-p (nth 3 s))
                                       (or (not feed-known)
                                           (decknix--layout-session-on-live-pr-p
                                            s live-keys))))
                                covering))
                 groups)))
       by-repo)
      (decknix--layout-sort-groups groups))))

(defun decknix--layout-sort-prs (prs)
  "Return PRS attention-first, then highest number first.
Highest number first because a PR raised later is the one still moving."
  (sort (copy-sequence prs)
        (lambda (a b)
          (let ((ra (decknix--layout-state-rank (plist-get a :state)))
                (rb (decknix--layout-state-rank (plist-get b :state))))
            (if (/= ra rb)
                (< ra rb)
              (> (or (plist-get a :number) 0) (or (plist-get b :number) 0)))))))

(defun decknix--layout-pr-gone-p (pr)
  "Return non-nil when PR\='s work is over -- merged, closed, or withdrawn.

Reads the `:gone\=' mark set during group construction rather than deriving
it, because deriving needs a fact only the caller has: whether the review
feed had any data at all.

With no feed -- before the first poll, or after a failed one -- EVERY row
has a session and no item, so deriving here marked all work finished and
silenced the whole section.  An empty feed means nothing is known, not
that everything merged."
  (and (plist-get pr :gone) t))

(defun decknix--layout-mark-gone (prs feed-known)
  "Mark rows in PRS whose PR has left the feed, when FEED-KNOWN.

Measured live: of eight repos the sidebar flagged as needing attention,
three were not in the feed at ALL and existed only because a session sat
on a PR that had since merged."
  (when feed-known
    (dolist (p prs)
      (when (and (plist-get p :state) (null (plist-get p :item)))
        (plist-put p :gone t))))
  prs)

(defun decknix--layout-live-pr-keys (prs)
  "Return the keys of PRS still present in the review feed."
  (delq nil (mapcar (lambda (p)
                      (and (plist-get p :item) (plist-get p :key)))
                    prs)))

(defun decknix--layout-session-on-live-pr-p (session live-keys)
  "Return non-nil when SESSION covers any PR in LIVE-KEYS.

A session whose every PR has left the feed is finished with work it has
not noticed ending; counting it as asking is what inflated \"13 need
you\".  A session with no recorded PR at all still counts -- absence of a
record is not evidence the work is done."
  (let ((keys (nth 2 session)))
    (or (null keys)
        (seq-some (lambda (k) (member k live-keys)) keys))))

(defun decknix--layout-pr-author-kind (pr)
  "Return PR\='s author kind as a symbol: `bot\=', `human\=', or nil when unknown."
  (let* ((item (plist-get pr :item))
         (kind (and item (alist-get 'author_kind item))))
    (cond ((null kind) nil)
          ((equal kind "bot") 'bot)
          (t 'human))))

(defun decknix--layout-pr-bot-p (pr)
  "Return non-nil when PR was opened by a bot."
  (eq 'bot (decknix--layout-pr-author-kind pr)))

(defun decknix--layout-pr-human-p (pr)
  "Return non-nil when PR was opened by a human.

`bot_human\=' counts as human: a person has committed to it, so it is no
longer a dependency bump nobody has looked at."
  (eq 'human (decknix--layout-pr-author-kind pr)))

(defun decknix--layout-sort-groups (groups)
  "Return GROUPS most-urgent first.

Order: sessions blocked on me, then PRs with no session at all, then
session count, then name.

Uncovered PRs rank ABOVE busy sessions because they are the only rows
nothing is happening to.  They were not a sort key at all, so a repo with
five untouched review requests sorted below one with two sessions already
working -- the opposite of what a section headed by what-needs-attention
should say."
  (sort (copy-sequence groups)
        (lambda (a b)
          (let ((aa (or (plist-get a :asking) 0))
                (ab (or (plist-get b :asking) 0))
                (ua (or (plist-get a :uncovered) 0))
                (ub (or (plist-get b :uncovered) 0))
                (sa (or (plist-get a :sessions) 0))
                (sb (or (plist-get b :sessions) 0)))
            (cond
             ((/= aa ab) (> aa ab))
             ((/= ua ub) (> ua ub))
             ((/= sa sb) (> sa sb))
             (t (string< (or (plist-get a :repo) "")
                         (or (plist-get b :repo) ""))))))))

(defun decknix--layout-group-wants-me-p (group)
  "Return non-nil when GROUP earns a row at the top of the sidebar.

Two reasons qualify, and only two:

  a session is blocked on me   (:asking > 0)
  a PR has no session at all    (:uncovered > 0)

A repo whose sessions are all `working' or `ready' is work in flight that
wants nothing: it is the single largest source of rows, and showing it at
the top competes with the rows that do want something.  Expanding is still
how you look at it -- see `decknix--layout-filter-groups', which reports how
many were held back rather than dropping them silently."
  (or (> (or (plist-get group :asking) 0) 0)
      (> (or (plist-get group :uncovered) 0) 0)))

(defun decknix--layout-filter-groups (groups attention-only)
  "Return (VISIBLE . HIDDEN-COUNT) for GROUPS.

With ATTENTION-ONLY nil every group is visible and HIDDEN-COUNT is 0, so
the toggle genuinely restores the previous behaviour.

HIDDEN-COUNT is returned rather than discarded because a section that
quietly shrinks is indistinguishable from one with nothing in it -- the
same failure that let a repo-sync error hide for 61 runs."
  (if (not attention-only)
      (cons groups 0)
    (let ((visible (seq-filter #'decknix--layout-group-wants-me-p groups)))
      (cons visible (- (length groups) (length visible))))))

;; --- duplicate coverage ----------------------------------------------

(defun decknix--layout-duplicate-prs (sessions)
  "Return PR keys covered by more than one live session, sorted.

Measured at 12 on a live workspace: each of those PRs had both an
`auto/#n/<repo>/review' session and a legacy `pr-<repo>-<n>' one, so twelve
agents were running twice over the same diff.  Surfacing the count is not
the fix -- whatever spawns both is -- but an invisible duplicate never gets
fixed."
  (let ((counts (make-hash-table :test 'equal))
        dups)
    (dolist (session sessions)
      (dolist (key (decknix--layout-session-prs session))
        (puthash key (1+ (or (gethash key counts) 0)) counts)))
    (maphash (lambda (key n) (when (> n 1) (push key dups))) counts)
    (sort dups #'string<)))

;; --- unattached work --------------------------------------------------

(defun decknix--layout-covered-keys (sessions)
  "Return every PR key covered by a live session."
  (delete-dups (apply #'append (mapcar #'decknix--layout-session-prs sessions))))

(defun decknix--layout-unattached (worktrees covered-paths)
  "Return WORKTREES that no live session is working in.

COVERED-PATHS is the set of workspace paths live sessions occupy.  Paths
are compared through `file-name-as-directory' because the worktree audit
writes some primaries with a trailing slash and some without -- the same
normalisation bug that once hid `decknix-config' from the picker."
  (let ((covered (mapcar (lambda (p)
                           (file-name-as-directory (expand-file-name p)))
                         (delq nil covered-paths))))
    (seq-remove (lambda (wt)
                  (let ((path (plist-get wt :path)))
                    (and path
                         (member (file-name-as-directory
                                  (expand-file-name path))
                                 covered))))
                worktrees)))

(defun decknix--layout-session-workspace (session)
  "Return SESSION's workspace directory, normalised, or nil."
  (let ((ws (nth 4 session)))
    (and (stringp ws) (not (string-empty-p ws))
         (file-name-as-directory (expand-file-name ws)))))

(defun decknix--layout-wt-path (wt)
  "Return worktree WT's path, normalised."
  (let ((p (plist-get wt :path)))
    (and p (file-name-as-directory (expand-file-name p)))))

(defconst decknix-sidebar-layout-min-tag-match 4
  "Shortest tag allowed to claim a repo by name.

Session tags are free text and the short ones are not repo names: `us',
`ai', `mvp', `org' would each match something.  Four characters excludes
every generic tag observed in the live workspace while still matching
`decknix', `followupboss' and `rea-integration'.")

(defun decknix--layout-tag-matches-repo-p (tag repo)
  "Return non-nil when TAG names REPO.  Pure.

Exact match, or TAG as the leading segment of a hyphenated repo name --
`followupboss' names `followupboss-integration', which is how the tags are
written in practice.  Not a substring test: `core' would then claim
`connect-to-core', which it does not name."
  (and (stringp tag) (stringp repo)
       (>= (length tag) decknix-sidebar-layout-min-tag-match)
       (let ((short (downcase (car (last (split-string repo "/" t)))))
             (tag (downcase tag)))
         (or (string= tag short)
             (string-prefix-p (concat tag "-") short)))))

(defun decknix--layout-session-claims-repo-p (session repo)
  "Return non-nil when SESSION's tags name REPO.

The only association available.  A session's workspace is the workspace
ROOT for every session in practice (measured: all 47 reported
`~/Code/nurturecloud/'), and own sessions carry no linked PRs, so neither
can link a session to a repo.  Tags can, because they are how these
sessions are named.

Heuristic, and deliberately conservative -- see
`decknix-sidebar-layout-min-tag-match'.  The durable fix is for the launch
paths to record the repo or worktree the way review sessions record their
PR; until then this is inference, not data."
  (seq-some (lambda (tag) (decknix--layout-tag-matches-repo-p tag repo))
            (nth 1 session)))

(defun decknix--layout-session-observed-roots (session)
  "Return the worktree roots SESSION has recently been working in.

Observed from the paths its tool calls touch, so it is data rather than
inference, and it is worktree-granular and crosses repos -- which the tag
rule could not express.  Nil for a session that has run no tool calls
yet, which is what keeps the tag fallback meaningful."
  (let ((buf (get-buffer (or (nth 0 session) ""))))
    (and (buffer-live-p buf)
         (ignore-errors (decknix-session-assoc-current buf)))))

(defun decknix--layout-session-observed-wt-p (roots wt)
  "Return non-nil when WT is one of the observed ROOTS."
  (decknix-session-assoc-claims-wt-p roots (decknix--layout-wt-path wt)))

(defun decknix--layout-session-owns-wt-p (session wt)
  "Return non-nil when SESSION is working in worktree WT.

Compared as directories: the audit writes some paths with a trailing slash
and some without, which is the normalisation bug that once hid
`decknix-config' from the worktree picker."
  (let ((ws (decknix--layout-session-workspace session))
        (wp (decknix--layout-wt-path wt)))
    (and ws wp (string= ws wp))))

(defun decknix--layout-wip-tree (sessions wip-repos worktrees)
  "Return (:sessions LIST :dormant PLIST) nesting work under its owning session.

Each entry of :sessions is (:session S :worktrees WTS :prs PRS).  A session
claims a worktree when its workspace IS that worktree, and claims a PR when
the PR's branch matches a worktree it claims.

:dormant holds what no live session claims, as (:worktrees WTS :prs PRS).
That is the distinction the sections draw: WIP is work with an agent on it,
Dormant is work sitting there without one.

WIP-REPOS is the hub WIP feed's `repos' list; PRS keep their repo alongside
them because a bare number is ambiguous across repos.

A worktree or PR can legitimately appear under more than one session -- two
agents may share a workspace -- and that is preferred over picking a winner,
which would hide the sharing."
  (let* ((all-prs
          (apply #'append
                 (mapcar (lambda (repo)
                           (mapcar (lambda (pr)
                                     (list :repo (alist-get 'repo repo)
                                           :number (alist-get 'number pr)
                                           :branch (alist-get 'branch pr)
                                           :pr pr))
                                   (alist-get 'prs repo)))
                         wip-repos)))
         (claimed-wts nil)
         (claimed-prs nil)
         (rows
          (mapcar
           (lambda (session)
             (let* ((observed (decknix--layout-session-observed-roots session))
                    (wts (seq-filter
                          (lambda (wt)
                            (or (decknix--layout-session-owns-wt-p session wt)
                                ;; Observed association wins where it exists:
                                ;; it names the WORKTREES this session has
                                ;; actually been editing in, across repos.
                                (and observed
                                     (decknix--layout-session-observed-wt-p
                                      observed wt))
                                ;; Tags only when nothing was observed -- a
                                ;; session that has run no tool calls yet.
                                ;; Measured, the tag rule claimed every
                                ;; worktree of one repo while missing the
                                ;; three other repos the session was in.
                                (and (null observed)
                                     (decknix--layout-session-claims-repo-p
                                      session (or (plist-get wt :repo) "")))))
                          worktrees))
                    ;; Two ways a PR is claimed, and both are needed.  BRANCH
                    ;; is the precise one: a session whose workspace IS a
                    ;; worktree owns the PR for that worktree's branch.  TAG is
                    ;; the loose one, and the only thing available for sessions
                    ;; that sit in the workspace root (all of them, in
                    ;; practice).  Dropping the branch path regressed exactly
                    ;; the case where the association is actually known.
                    (branches (delq nil (mapcar (lambda (wt) (plist-get wt :branch))
                                                wts)))
                    (prs (seq-filter
                          (lambda (p)
                            (or (and (plist-get p :branch)
                                     (member (plist-get p :branch) branches))
                                ;; No repo-level fallback once the session has
                                ;; been observed: claiming a repo's every PR
                                ;; is what hid the one it was working on.
                                (and (null observed)
                                     (decknix--layout-session-claims-repo-p
                                      session (or (plist-get p :repo) "")))))
                          all-prs)))
               (setq claimed-wts (append claimed-wts wts)
                     claimed-prs (append claimed-prs prs))
               ;; Grouped by repo rather than listed flat.  Tag matching is
               ;; repo-level, so a session claims ALL of a repo's work: the
               ;; two followupboss sessions each claimed 5 PRs and 6
               ;; worktrees, which is 22 nested rows for two sessions in a
               ;; section whose purpose is to fit on screen.  One row per repo
               ;; states the same association in a tenth of the space, and is
               ;; honest about the granularity the data actually supports.
               (list :session session :worktrees wts :prs prs
                     :repos (decknix--layout-group-claims wts prs))))
           sessions)))
    (list :sessions rows
          :dormant
          (list :worktrees (seq-remove (lambda (wt) (memq wt claimed-wts)) worktrees)
                :prs (seq-remove (lambda (p) (memq p claimed-prs)) all-prs)))))

(defun decknix--layout-group-claims (worktrees prs)
  "Return per-repo claim groups across WORKTREES and PRS.

Each group carries the ITEMS as well as their counts, because a count alone
cannot say whether anything in there is blocked -- which is the whole point
of the indicators."
  (let ((by-repo (make-hash-table :test 'equal)))
    (dolist (wt worktrees)
      (let* ((short (car (last (split-string (or (plist-get wt :repo) "?") "/" t))))
             (e (gethash short by-repo)))
        (puthash short (list :repo short
                             :worktrees (1+ (or (plist-get e :worktrees) 0))
                             :prs (or (plist-get e :prs) 0)
                             :wt-items (cons wt (plist-get e :wt-items))
                             :pr-items (plist-get e :pr-items))
                 by-repo)))
    (dolist (pr prs)
      (let* ((short (car (last (split-string (or (plist-get pr :repo) "?") "/" t))))
             (e (gethash short by-repo)))
        (puthash short (list :repo short
                             :worktrees (or (plist-get e :worktrees) 0)
                             :prs (1+ (or (plist-get e :prs) 0))
                             :wt-items (plist-get e :wt-items)
                             :pr-items (cons pr (plist-get e :pr-items)))
                 by-repo)))
    (let (out)
      (maphash (lambda (_k v)
                 (push (plist-put v :severity
                                  (decknix--layout-worst-severity
                                   (plist-get v :pr-items)
                                   (plist-get v :wt-items)))
                       out))
               by-repo)
      (sort out (lambda (a b)
                  (let ((sa (or (plist-get a :severity) 9))
                        (sb (or (plist-get b :severity) 9)))
                    (if (/= sa sb)
                        (< sa sb)
                      (string< (plist-get a :repo) (plist-get b :repo)))))))))

(defun decknix--layout-dormant-by-repo (dormant)
  "Group DORMANT work by repo for rendering.

Returns a list of (:repo R :worktrees WTS :prs PRS), repo-sorted.  Grouped
because an ungrouped list of 20-odd branches and PR numbers gives no clue
which belong together."
  (let ((by-repo (make-hash-table :test 'equal)))
    (dolist (wt (plist-get dormant :worktrees))
      (let* ((repo (or (plist-get wt :repo) "?"))
             (short (car (last (split-string repo "/" t))))
             (e (gethash short by-repo)))
        (puthash short (list :repo short
                             :worktrees (cons wt (plist-get e :worktrees))
                             :prs (plist-get e :prs))
                 by-repo)))
    (dolist (pr (plist-get dormant :prs))
      (let* ((repo (or (plist-get pr :repo) "?"))
             (short (car (last (split-string repo "/" t))))
             (e (gethash short by-repo)))
        (puthash short (list :repo short
                             :worktrees (plist-get e :worktrees)
                             :prs (cons pr (plist-get e :prs)))
                 by-repo)))
    (let (out)
      (maphash (lambda (_k v) (push v out)) by-repo)
      (sort out (lambda (a b) (string< (plist-get a :repo) (plist-get b :repo)))))))

(defun decknix--layout-pr-sessions (sessions key)
  "Return the SESSIONS whose review PRs include KEY."
  (seq-filter (lambda (s) (member key (decknix--layout-session-prs s))) sessions))

;; --- state indicators -------------------------------------------------
;;
;; The refactor lost these.  Session rows rendered in `default' and nested
;; work as a grey repo name, so at the sidebar's 48 columns -- where the
;; trailing status word is off-screen -- there was nothing left to read state
;; from.  Colour plus a left-hand glyph has to carry it.

(defconst decknix-sidebar-layout-state-faces
  '(("netfail"  . (:foreground "#ff5f5f" :weight bold))
    ("waiting"  . (:foreground "#ff5f5f" :weight bold))
    ("asking"   . (:foreground "#ffaf5f" :weight bold))
    ("working"  . (:foreground "#d7af5f"))
    ("finished" . (:foreground "#5fd7d7"))
    ("ready"    . (:foreground "#87af87"))
    ("closing"  . (:inherit font-lock-comment-face)))
  "Face per session state.

The first four are copied from `decknix--hub-request-session-faces' so the
sidebar and the Requests row indicator cannot disagree about what a colour
means; `finished', `ready' and `closing' extend it, because the sidebar
shows idle sessions and that indicator does not.")

(defun decknix--layout-state-face (state)
  "Return the face for session STATE."
  (or (alist-get state decknix-sidebar-layout-state-faces nil nil #'equal)
      'default))

;; Severity ranks, low is worse.  A repo row takes the worst rank among its
;; children, which is how one line can stand in for several without hiding a
;; problem.
(defconst decknix-sidebar-layout-severity-faces
  '((0 . (:foreground "#ff5f5f" :weight bold))   ; blocked
    (1 . (:foreground "#ffaf5f" :weight bold))   ; wants me
    (2 . (:foreground "#d7af5f"))                ; in flight
    (3 . (:foreground "#87af87"))                ; green
    (4 . (:inherit font-lock-comment-face)))     ; muted
  "Face per severity rank.")

(defun decknix--layout-severity-face (rank)
  "Return the face for severity RANK."
  (or (alist-get (or rank 4) decknix-sidebar-layout-severity-faces)
      'default))

(defun decknix--layout-pr-severity (pr)
  "Return the severity rank of WIP PR, low being worse.

Order of precedence is the order a human triages in: something blocking the
merge, then something waiting on me, then work in flight, then green."
  (let* ((p (plist-get pr :pr))
         (draft (eq (alist-get 'draft p) t))
         (conflict (equal (alist-get 'mergeable p) "CONFLICTING"))
         (decision (alist-get 'review_decision p))
         (ci (alist-get 'status (alist-get 'ci p)))
         (unres (or (alist-get 'unresolved_total p) 0))
         (needs (eq (alist-get 'needs_reply p) t)))
    (cond
     ((or conflict (equal ci "fail") (equal decision "CHANGES_REQUESTED")) 0)
     ((or (> unres 0) needs) 1)
     (draft 4)
     ((or (equal ci "pending") (equal ci "running")) 2)
     ((equal decision "APPROVED") 3)
     (t 2))))

(defun decknix--layout-wt-severity (wt)
  "Return the severity rank of worktree WT."
  (cond
   ((plist-get wt :dirty) 1)
   ((plist-get wt :active) 2)
   ((plist-get wt :merged) 3)
   ((plist-get wt :orphan) 4)
   (t 2)))

(defun decknix--layout-wt-indicators (wt)
  "Return the indicator string for worktree WT.

Dirty outranks everything: uncommitted work is the only state here that can
be lost, so it must not be masked by a merged or orphaned flag."
  (cond
   ((plist-get wt :dirty) "✎ ")
   ((plist-get wt :active) "● ")
   ((plist-get wt :merged) "✓ ")
   ((plist-get wt :orphan) "⑂ ")
   (t "◌ ")))

(defconst decknix-sidebar-layout-wt-glyph-faces
  '((dirty . warning) (active . success) (merged . shadow)
    (orphan . error) (clean . shadow))
  "Face per worktree condition.

Each glyph carries its own colour so dirty-versus-orphaned is readable
without decoding the shape; the row used to be painted a single severity
face, which made every condition under one repo look alike.")

(defun decknix--layout-wt-condition (wt)
  "Return the condition symbol for worktree WT.

Dirty outranks everything: uncommitted work is the only state here that
can be lost, so it must not be masked by a merged or orphaned flag."
  (cond ((plist-get wt :dirty) 'dirty)
        ((plist-get wt :active) 'active)
        ((plist-get wt :merged) 'merged)
        ((plist-get wt :orphan) 'orphan)
        (t 'clean)))

(defun decknix--layout-wt-glyph (wt)
  "Return WT\='s indicator glyph propertized with its own face."
  (let ((cond- (decknix--layout-wt-condition wt)))
    (propertize (string-trim-right (decknix--layout-wt-indicators wt))
                'face (or (alist-get cond- decknix-sidebar-layout-wt-glyph-faces)
                          'shadow))))

(defun decknix--layout-claim-items (claim budget expanded)
  "Return (PRS WTS HELD) to render for CLAIM under BUDGET.

PRs are NEVER withheld.  An open PR -- draft or awaiting approval -- is
work with a live obligation attached, so hiding one behind \"... 3 more\"
loses the thing the sidebar exists to surface.  The budget applies to
WORKTREES, which are a local artefact and the safe thing to elide.

Previously the budget was spent on PRs first and worktrees got the
remainder, so a repo with more than BUDGET PRs hid the surplus PRs.

HELD is the number of worktrees not shown, so the caller can offer to
expand rather than silently shrinking the list.  EXPANDED non-nil shows
everything."
  (let* ((prs (plist-get claim :pr-items))
         (wts (plist-get claim :wt-items))
         (shown-wts (if (or expanded (not (integerp budget)))
                        wts
                      (seq-take wts (max 0 budget)))))
    (list prs shown-wts (- (length wts) (length shown-wts)))))

(defun decknix--layout-dedup-claims (session-rows)
  "Mark a repo claim that a previous session in SESSION-ROWS already showed.

Two sessions sharing a workspace both claim its repos, and the full
PR/worktree subtree was rendered once per session -- six identical rows
twice, in a sidebar whose purpose is an uncluttered read.

The sharing is still worth stating, so the claim is marked `:duplicate\='
rather than dropped: the render collapses it to one line naming the repo
instead of hiding it, which keeps \"two sessions are on this\" visible
without paying for it twice."
  (let ((seen (make-hash-table :test 'equal)))
    (mapcar
     (lambda (row)
       (let ((claims
              (mapcar
               (lambda (claim)
                 (let ((repo (plist-get claim :repo)))
                   (if (and repo (gethash repo seen))
                       (plist-put (copy-sequence claim) :duplicate t)
                     (when repo (puthash repo t seen))
                     claim)))
               (plist-get row :repos))))
         (plist-put (copy-sequence row) :repos claims)))
     session-rows)))

(defun decknix--layout-worst-severity (prs worktrees)
  "Return the worst severity across PRS and WORKTREES, or nil when both empty."
  (let ((ranks (append (mapcar #'decknix--layout-pr-severity prs)
                       (mapcar #'decknix--layout-wt-severity worktrees))))
    (when ranks (apply #'min ranks))))

;; --- labels -----------------------------------------------------------

(defconst decknix-sidebar-layout-state-glyphs
  '(("asking"   . "●") ("waiting" . "●") ("netfail" . "●")
    ("working"  . "◐") ("finished" . "◑") ("ready" . "○") ("closing" . "◌"))
  "Glyph per session state.  A filled dot means the session wants you.")

(defun decknix--layout-state-glyph (state)
  "Return the row glyph for STATE; a middot when there is no session."
  (or (alist-get state decknix-sidebar-layout-state-glyphs nil nil #'equal)
      "·"))

(defun decknix--layout-count-label (prs worktrees)
  "Return a count label for PRS and WORKTREES, omitting a zero half.

A row reading \"0 pr 2 wt\" spends half its width telling the user what is
not there, and the Dormant section is mostly such rows."
  (string-join
   (delq nil (list (when (> prs 0) (format "%d pr" prs))
                   (when (> worktrees 0) (format "%d wt" worktrees))))
   " "))

(defconst decknix-sidebar-layout-kind-glyphs
  '((human . "@") (bot . "π") (gone . "✓"))
  "Glyph per review-row kind.

`π\=' for a bot matches the author column the Requests rows already use, so
the two sections do not invent different vocabularies for the same fact.
`✓\=' marks work that is over -- merged, closed, or withdrawn.")

(defun decknix--layout-group-label (group width)
  "Return the collapsed one-line label for GROUP, padded to WIDTH.

The right column answers \"what is in here\", in the terms that decide
whether to open it:

  2@ 3π      two human PRs, three bot PRs
  1@ ✓4      one human PR, and four sessions on work already finished
  3 new      three PRs nothing has started on

Counts used to read \"5 5⚑\" -- sessions and blocked sessions -- which
said how many agents were running, not what they were running ON.  A
dependabot bump and a colleague waiting on review are the same number
there, and that is the distinction the section exists to draw."
  (let* ((repo (plist-get group :repo))
         (asking (or (plist-get group :asking) 0))
         (uncovered (or (plist-get group :uncovered) 0))
         (humans (or (plist-get group :humans) 0))
         (bots (or (plist-get group :bots) 0))
         (gone (or (plist-get group :gone) 0))
         (right (decknix--layout-group-right humans bots gone uncovered))
         (glyph (cond ((> asking 0) "⚑")
                      ((> (or (plist-get group :sessions) 0) 0) "●")
                      (t "·")))
         (left (format " %s  %s" glyph repo))
         (pad (max 1 (- width (string-width left) (string-width right)))))
    (concat left (make-string pad ?\s) right)))

(defun decknix--layout-group-right (humans bots gone uncovered)
  "Return the right-hand summary for a Reviews group row."
  (let ((parts (delq nil
                     (list (when (> humans 0)
                             (format "%d%s" humans
                                     (alist-get 'human decknix-sidebar-layout-kind-glyphs)))
                           (when (> bots 0)
                             (format "%d%s" bots
                                     (alist-get 'bot decknix-sidebar-layout-kind-glyphs)))
                           (when (> gone 0)
                             (format "%s%d"
                                     (alist-get 'gone decknix-sidebar-layout-kind-glyphs)
                                     gone))))))
    (cond (parts (string-join parts " "))
          ((> uncovered 0) (format "%d new" uncovered))
          (t ""))))

(defun decknix--layout-pr-author (pr)
  "Return PR\='s author login, or nil."
  (let ((item (plist-get pr :item)))
    (and item (alist-get 'author item))))

(defun decknix--layout-pr-label (pr &optional width)
  "Return the expanded row label for PR, fitted to WIDTH.

Names the AUTHOR, which is the fact that decides whether a row is worth
opening: a dependabot bump and a colleague waiting read identically
without it.  Kind glyph first, since bot-versus-human is the coarser
question and answers most rows on its own.

A PR a session is on that has left the feed reads `done\=' -- it has been
merged, closed or withdrawn, whatever the session still says."
  (let* ((state (plist-get pr :state))
         (kind (decknix--layout-pr-author-kind pr))
         (glyph (or (alist-get kind decknix-sidebar-layout-kind-glyphs) " "))
         (author (decknix--layout-pr-author pr))
         (status (cond ((decknix--layout-pr-gone-p pr) "done")
                       (state state)
                       (t "no session")))
         (left (format "    %s %s #%s "
                       (decknix--layout-state-glyph state)
                       glyph (plist-get pr :number)))
         (right (if author (format "%s  %s" author status) status))
         (width (or width 48))
         (room (max 1 (- width (string-width left)))))
    (concat left
            (if (> (string-width right) room)
                (concat (truncate-string-to-width right (max 1 (1- room))) "…")
              right))))

(provide 'decknix-sidebar-layout)
;;; decknix-sidebar-layout.el ends here
