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
    (let (groups)
      (maphash
       (lambda (repo entry)
         (let ((covering (delete-dups (gethash repo repo-sessions))))
           (push (list :repo repo
                       :prs (decknix--layout-sort-prs (plist-get entry :prs))
                       :uncovered (seq-count (lambda (p) (null (plist-get p :state)))
                                             (plist-get entry :prs))
                       :sessions (length covering)
                       :asking (seq-count (lambda (s)
                                            (decknix--layout-attention-p (nth 3 s)))
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

(defun decknix--layout-sort-groups (groups)
  "Return GROUPS by attention count, then session count, then name."
  (sort (copy-sequence groups)
        (lambda (a b)
          (let ((aa (or (plist-get a :asking) 0))
                (ab (or (plist-get b :asking) 0)))
            (cond
             ((/= aa ab) (> aa ab))
             ((/= (or (plist-get a :sessions) 0) (or (plist-get b :sessions) 0))
              (> (or (plist-get a :sessions) 0) (or (plist-get b :sessions) 0)))
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
             (let* ((wts (seq-filter
                          (lambda (wt)
                            (or (decknix--layout-session-owns-wt-p session wt)
                                (decknix--layout-session-claims-repo-p
                                 session (or (plist-get wt :repo) ""))))
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
                                (decknix--layout-session-claims-repo-p
                                 session (or (plist-get p :repo) ""))))
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
  "Return (:repo R :prs N :worktrees N) per repo across WORKTREES and PRS."
  (let ((by-repo (make-hash-table :test 'equal)))
    (dolist (wt worktrees)
      (let* ((short (car (last (split-string (or (plist-get wt :repo) "?") "/" t))))
             (e (gethash short by-repo)))
        (puthash short (list :repo short
                             :worktrees (1+ (or (plist-get e :worktrees) 0))
                             :prs (or (plist-get e :prs) 0))
                 by-repo)))
    (dolist (pr prs)
      (let* ((short (car (last (split-string (or (plist-get pr :repo) "?") "/" t))))
             (e (gethash short by-repo)))
        (puthash short (list :repo short
                             :worktrees (or (plist-get e :worktrees) 0)
                             :prs (1+ (or (plist-get e :prs) 0)))
                 by-repo)))
    (let (out)
      (maphash (lambda (_k v) (push v out)) by-repo)
      (sort out (lambda (a b) (string< (plist-get a :repo) (plist-get b :repo)))))))

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

;; --- labels -----------------------------------------------------------

(defconst decknix-sidebar-layout-state-glyphs
  '(("asking"   . "●") ("waiting" . "●") ("netfail" . "●")
    ("working"  . "◐") ("finished" . "◑") ("ready" . "○") ("closing" . "◌"))
  "Glyph per session state.  A filled dot means the session wants you.")

(defun decknix--layout-state-glyph (state)
  "Return the row glyph for STATE; a middot when there is no session."
  (or (alist-get state decknix-sidebar-layout-state-glyphs nil nil #'equal)
      "·"))

(defun decknix--layout-group-label (group width)
  "Return the collapsed one-line label for GROUP, padded to WIDTH.

The right column answers the question the row is for:

  sessions present  \"18 14⚑\"  how many agents, how many blocked on me
  no session        \"3 new\"    how many PRs are waiting for one

A bare session count of 0 was the first attempt and it told the user
nothing -- the interesting fact about a repo with no sessions is the work
sitting there, which is exactly the Requests content folded into this
section."
  (let* ((repo (plist-get group :repo))
         (sessions (or (plist-get group :sessions) 0))
         (asking (or (plist-get group :asking) 0))
         (uncovered (or (plist-get group :uncovered) 0))
         (right (cond
                 ((> asking 0) (format "%d %d⚑" sessions asking))
                 ((> sessions 0) (format "%d" sessions))
                 ((> uncovered 0) (format "%d new" uncovered))
                 (t "")))
         (glyph (cond ((> asking 0) "⚑") ((> sessions 0) "●") (t "·")))
         (left (format " %s  %s" glyph repo))
         (pad (max 1 (- width (string-width left) (string-width right)))))
    (concat left (make-string pad ?\s) right)))

(defun decknix--layout-pr-label (pr)
  "Return the expanded row label for PR."
  (let ((state (plist-get pr :state)))
    (format "    %s #%s%s"
            (decknix--layout-state-glyph state)
            (plist-get pr :number)
            (cond (state (format "  %s" state))
                  (t "  no session")))))

(provide 'decknix-sidebar-layout)
;;; decknix-sidebar-layout.el ends here
