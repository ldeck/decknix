;;; decknix-sidebar-layout-test.el --- Tests for the session-first sidebar -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Fixtures mirror a measured live workspace: 47 sessions, 40 of them
;; reviews, 33 blocked on the user, and 12 PRs covered twice.  The two
;; vocabularies are reproduced deliberately -- sessions record
;; "upside#21248" while feed items carry "UpsideRealty/upside" -- because
;; comparing them directly is the obvious bug and it fails SILENTLY: every
;; PR reads as uncovered and the collapse produces nonsense.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-sidebar-layout)

(defun decknix-layout-test--session (name state prs &optional tags)
  (list name (or tags '("t")) prs state))

(defconst decknix-layout-test--sessions
  (list
   (decknix-layout-test--session "*Claude: auto/#21248/upside/review*" "asking"
                                 '("upside#21248"))
   (decknix-layout-test--session "*Claude: pr-upside-21248*" "ready"
                                 '("upside#21248"))
   (decknix-layout-test--session "*Claude: auto/#17172/upside/review*" "asking"
                                 '("upside#17172"))
   (decknix-layout-test--session "*Claude: auto/#445/metabase/review*" "asking"
                                 '("metabase#445"))
   (decknix-layout-test--session "*Claude: group/oneroof*" "working"
                                 '("oneroof-integration#190"
                                   "oneroof-integration#189"))
   (decknix-layout-test--session "*Claude: decknix/nurturecloud*" "working" nil)
   (decknix-layout-test--session "*Pi: pilot/us*" "ready" nil))
  "Sessions in the live shape, including a duplicated PR and a group session.")

(defconst decknix-layout-test--items
  '(((repo . "UpsideRealty/upside") (number . 21248))
    ((repo . "UpsideRealty/upside") (number . 21205))
    ((repo . "UpsideRealty/metabase") (number . 445))
    ((repo . "UpsideRealty/dapi-contracts") (number . 4)))
  "Feed items, owner-qualified as the hub emits them.")

;; --- the two vocabularies ---------------------------------------------

(ert-deftest decknix-layout--pr-key-folds-owner-and-case ()
  "A feed item and a session's recorded key must compare equal."
  (should (equal (decknix--layout-pr-key "UpsideRealty/upside" 21248)
                 (decknix--layout-pr-key "upside" 21248)))
  (should (equal "upside#21248" (decknix--layout-pr-key "UpsideRealty/Upside" 21248))))

(ert-deftest decknix-layout--pr-key-rejects-half-input ()
  "A half key would collide across PRs."
  (should-not (decknix--layout-pr-key nil 1))
  (should-not (decknix--layout-pr-key "a/b" nil))
  (should-not (decknix--layout-pr-key "" 1)))

(ert-deftest decknix-layout--parses-a-key-back ()
  (should (equal '("upside" . 21248) (decknix--layout-parse-pr-key "upside#21248")))
  (should-not (decknix--layout-parse-pr-key "upside"))
  (should-not (decknix--layout-parse-pr-key "upside#abc"))
  (should-not (decknix--layout-parse-pr-key nil)))

;; --- review vs own ----------------------------------------------------

(ert-deftest decknix-layout--review-detection-ignores-buffer-name ()
  "The naming convention changed twice and both forms are live in the same
workspace, so recorded review PRs are the only reliable signal."
  (should (decknix--layout-review-session-p
           (decknix-layout-test--session "*Claude: anything at all*" "ready"
                                         '("upside#1"))))
  (should-not (decknix--layout-review-session-p
               (decknix-layout-test--session "*Claude: pr-looks-like-review*"
                                             "ready" nil))))

(ert-deftest decknix-layout--wip-holds-only-my-own-sessions ()
  (let ((wip (decknix--layout-wip-sessions decknix-layout-test--sessions)))
    (should (= 2 (length wip)))
    (should (equal '("*Claude: decknix/nurturecloud*" "*Pi: pilot/us*")
                   (mapcar #'car wip)))))

;; --- attention ordering -----------------------------------------------

(ert-deftest decknix-layout--attention-states-sort-first ()
  "Ordering is the whole point of the redesign: what wants you, first."
  (let ((sorted (decknix--layout-sort-sessions
                 (list (decknix-layout-test--session "c" "ready" nil)
                       (decknix-layout-test--session "b" "working" nil)
                       (decknix-layout-test--session "a" "asking" nil)
                       (decknix-layout-test--session "z" "netfail" nil)))))
    (should (equal '("z" "a" "b" "c") (mapcar #'car sorted)))))

(ert-deftest decknix-layout--unknown-state-sorts-last ()
  "An unrecognised state is not evidence of urgency."
  (let ((sorted (decknix--layout-sort-sessions
                 (list (decknix-layout-test--session "weird" "banana" nil)
                       (decknix-layout-test--session "idle" "ready" nil)))))
    (should (equal '("idle" "weird") (mapcar #'car sorted)))))

(ert-deftest decknix-layout--only-blocked-states-count-as-attention ()
  (dolist (s '("asking" "waiting" "netfail"))
    (should (decknix--layout-attention-p s)))
  (dolist (s '("ready" "working" "finished" "closing" nil "banana"))
    (should-not (decknix--layout-attention-p s))))

;; --- collapsed review groups ------------------------------------------

(ert-deftest decknix-layout--groups-collapse-by-repo ()
  "40 review sessions became 40 lines; one row per repo is the fix."
  (let ((groups (decknix--layout-review-groups decknix-layout-test--sessions
                                                decknix-layout-test--items)))
    ;; Blocked sessions first (upside 2, metabase 1), then PRs with NO
    ;; session (dapi 1), then session count (oneroof 1).  dapi outranks
    ;; oneroof despite having no session precisely because it has none:
    ;; nothing is happening to that PR, whereas oneroof's is already being
    ;; worked.
    (should (equal '("upside" "metabase" "dapi-contracts" "oneroof-integration")
                   (mapcar (lambda (g) (plist-get g :repo)) groups)))))

(ert-deftest decknix-layout--a-pr-covered-twice-is-one-row ()
  "Twelve PRs have two sessions each; a row per (session, PR) pair listed
every one of them twice."
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions
                                                 decknix-layout-test--items))
         (upside (seq-find (lambda (g) (equal "upside" (plist-get g :repo))) groups))
         (numbers (mapcar (lambda (p) (plist-get p :number))
                          (plist-get upside :prs))))
    (should (equal numbers (delete-dups (copy-sequence numbers))))
    (should (equal '(21248 17172 21205) numbers))))

(ert-deftest decknix-layout--a-pr-covered-twice-keeps-the-urgent-state ()
  "#21248 has an `asking' session and a `ready' one; the row must read
`asking', because that is the one that should draw the eye."
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions nil))
         (upside (seq-find (lambda (g) (equal "upside" (plist-get g :repo))) groups))
         (pr (seq-find (lambda (p) (= 21248 (plist-get p :number)))
                       (plist-get upside :prs))))
    (should (equal "asking" (plist-get pr :state)))))

(ert-deftest decknix-layout--a-group-session-counts-once-per-repo ()
  "One session covering two PRs of a repo is one agent.  Counting it twice
overstated exactly the repos where grouped dispatch is working."
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions nil))
         (g (seq-find (lambda (g) (equal "oneroof-integration" (plist-get g :repo)))
                      groups)))
    (should (= 1 (plist-get g :sessions)))
    (should (= 2 (length (plist-get g :prs))))))

(ert-deftest decknix-layout--group-counts-sessions-and-attention ()
  "Three distinct sessions touch upside and two are blocked, but one of
those two sits on #17172, which the feed no longer carries -- merged,
closed or withdrawn.  That session is finished with work it has not
noticed ending, so it does not count as asking.

Counting it did: measured live, three of eight flagged repos were not in
the review feed at all."
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions
                                                 decknix-layout-test--items))
         (upside (seq-find (lambda (g) (equal "upside" (plist-get g :repo))) groups)))
    (should (= 3 (plist-get upside :sessions)))
    (should (= 1 (plist-get upside :asking)))
    (should (= 1 (plist-get upside :gone)))))

(ert-deftest decknix-layout--groups-sort-by-attention-then-sessions ()
  "A repo with a blocked session outranks a busier but quiet one."
  (let ((groups (decknix--layout-review-groups
                 (list (decknix-layout-test--session "a" "ready" '("quiet#1"))
                       (decknix-layout-test--session "b" "ready" '("quiet#2"))
                       (decknix-layout-test--session "c" "asking" '("loud#9")))
                 nil)))
    (should (equal '("loud" "quiet") (mapcar (lambda (g) (plist-get g :repo)) groups)))))

(ert-deftest decknix-layout--group-label-counts-match-what-expanding-shows ()
  "The header must agree with the rows underneath it.  With a feed, the
right column counts PRs by author kind, so it has to equal the number of
rows of each kind the group holds."
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions
                                                decknix-layout-test--items))
         (g (seq-find (lambda (x) (equal "upside" (plist-get x :repo))) groups))
         (label (decknix--layout-group-label g 48))
         (waiting (seq-filter #'decknix--layout-pr-waiting-p (plist-get g :prs)))
         (humans (seq-count #'decknix--layout-pr-human-p waiting))
         (bots (seq-count #'decknix--layout-pr-bot-p waiting)))
    (should (= humans (plist-get g :humans)))
    (should (= bots (plist-get g :bots)))
    (when (> (plist-get g :gone) 0)
      (should (string-match-p (format "✗%d" (plist-get g :gone)) label)))))

(ert-deftest decknix-layout--an-uncovered-request-still-gets-a-row ()
  "This is what lets Requests fold in: a PR nobody has started is a row in
its repo, marked as having no session."
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions
                                                 decknix-layout-test--items))
         (upside (seq-find (lambda (g) (equal "upside" (plist-get g :repo))) groups))
         (uncovered (seq-find (lambda (p) (null (plist-get p :state)))
                              (plist-get upside :prs))))
    (should uncovered)
    (should (= 21205 (plist-get uncovered :number)))
    (should (alist-get 'repo (plist-get uncovered :item)))))

(ert-deftest decknix-layout--a-repo-with-only-requests-appears ()
  "dapi-contracts has a request and no session; it must not vanish."
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions
                                                 decknix-layout-test--items))
         (g (seq-find (lambda (g) (equal "dapi-contracts" (plist-get g :repo))) groups)))
    (should g)
    (should (= 0 (plist-get g :sessions)))
    (should (= 1 (length (plist-get g :prs))))))

(ert-deftest decknix-layout--a-covered-pr-keeps-its-feed-item ()
  "The row needs both: the session state AND the PR's CI/mergeable facts."
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions
                                                 decknix-layout-test--items))
         (g (seq-find (lambda (g) (equal "metabase" (plist-get g :repo))) groups))
         (pr (car (plist-get g :prs))))
    (should (equal "asking" (plist-get pr :state)))
    (should (alist-get 'repo (plist-get pr :item)))))

(ert-deftest decknix-layout--group-session-covering-several-prs ()
  "One session covers two oneroof PRs; both must appear, counted once each."
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions nil))
         (g (seq-find (lambda (g) (equal "oneroof-integration" (plist-get g :repo)))
                      groups)))
    (should (= 2 (length (plist-get g :prs))))
    (should (equal '(190 189) (mapcar (lambda (p) (plist-get p :number))
                                      (plist-get g :prs))))))

(ert-deftest decknix-layout--prs-sort-attention-then-newest ()
  (let ((prs (decknix--layout-sort-prs
              '((:number 100 :state "ready") (:number 200 :state "ready")
                (:number 50 :state "asking")))))
    (should (equal '(50 200 100) (mapcar (lambda (p) (plist-get p :number)) prs)))))

;; --- duplicate coverage ----------------------------------------------

(ert-deftest decknix-layout--duplicates-are-detected ()
  "Twelve PRs were being reviewed by two agents at once."
  (should (equal '("upside#21248")
                 (decknix--layout-duplicate-prs decknix-layout-test--sessions))))

(ert-deftest decknix-layout--one-session-per-pr-is-not-a-duplicate ()
  (should-not (decknix--layout-duplicate-prs
               (list (decknix-layout-test--session "a" "ready" '("x#1"))
                     (decknix-layout-test--session "b" "ready" '("x#2"))))))

;; --- unattached -------------------------------------------------------

(ert-deftest decknix-layout--unattached-excludes-occupied-worktrees ()
  (let ((wts '((:path "/w/a" :branch "one") (:path "/w/b" :branch "two"))))
    (should (equal '("two")
                   (mapcar (lambda (w) (plist-get w :branch))
                           (decknix--layout-unattached wts '("/w/a")))))))

(ert-deftest decknix-layout--unattached-normalises-a-trailing-slash ()
  "The audit writes some paths with a trailing slash and some without; a
plain compare is the bug that once hid `decknix-config' from the picker."
  (should-not (decknix--layout-unattached '((:path "/w/a")) '("/w/a/")))
  (should-not (decknix--layout-unattached '((:path "/w/a/")) '("/w/a"))))

(ert-deftest decknix-layout--covered-keys-dedupe-across-sessions ()
  (should (equal '("upside#21248" "upside#17172" "metabase#445"
                   "oneroof-integration#190" "oneroof-integration#189")
                 (decknix--layout-covered-keys decknix-layout-test--sessions))))

;; --- labels -----------------------------------------------------------

(ert-deftest decknix-layout--group-label-fits-the-width ()
  "The sidebar window is 48 columns; a label that overflows wraps and
destroys the one-row-per-repo property the collapse exists for."
  (dolist (group (decknix--layout-review-groups decknix-layout-test--sessions
                                                 decknix-layout-test--items))
    (should (= 48 (string-width (decknix--layout-group-label group 48))))))

(ert-deftest decknix-layout--quiet-repo-omits-a-zero-count ()
  "A trailing \" 0⚑\" on every quiet repo is noise in a scanned column."
  (should-not (string-match-p "⚑" (decknix--layout-group-label
                                    '(:repo "r" :sessions 2 :asking 0) 48)))
  (should (string-match-p "⚑" (decknix--layout-group-label
                               '(:repo "r" :sessions 2 :asking 1) 48))))

(ert-deftest decknix-layout--shape-means-completeness-on-a-session-too ()
  "Supersedes `filled-glyph-means-wants-you'.

Shape says how complete a unit of work is on EVERY row kind: half in
flight, full a complete unit.  A filled circle used to mean `the agent
wants you', which is the glyph a PR row uses for `open and raised' --
the same shape for unrelated things.  Sharing shapes across row kinds is
fine, the indentation ties each to its row, but only while the shape
means the same KIND of thing."
  (should (equal "◐" (decknix--layout-state-glyph "working")))
  ;; Blocked on you is its own glyph, not the in-flight shape.
  (dolist (s '("asking" "waiting" "netfail"))
    (should (equal decknix-attention-glyph (decknix--layout-state-glyph s))))
  (dolist (s '("finished" "ready"))
    (should (equal "●" (decknix--layout-state-glyph s))))
  (should (equal "◌" (decknix--layout-state-glyph "closing")))
  (should (equal "·" (decknix--layout-state-glyph nil))))

(ert-deftest decknix-layout--colour-separates-the-in-flight-states ()
  "An agent mid-task and one paused on a question are both half circles,
so the colour has to carry the difference: yellow moving, purple waiting
on a person."
  (should-not (equal (decknix--layout-state-face "working")
                     (decknix--layout-state-face "asking"))))

(ert-deftest decknix-layout--wanting-the-user-is-its-own-colour ()
  "Not failing and not progressing -- waiting on a person, which is the
most actionable row the sidebar can show."
  (dolist (s '("asking" "waiting" "netfail"))
    (should (eq 'decknix-attention-face (decknix--layout-state-face s)))))

(ert-deftest decknix-layout--a-complete-session-reads-like-a-passing-build ()
  (dolist (s '("finished" "ready"))
    (should (equal '(:foreground "#87af87") (decknix--layout-state-face s)))))

(ert-deftest decknix-layout--pr-label-says-when-nothing-is-on-it ()
  (should (string-match-p "no session"
                          (decknix--layout-pr-label '(:number 5 :state nil))))
  (should (string-match-p "asking"
                          (decknix--layout-pr-label '(:number 5 :state "asking")))))

(ert-deftest decknix-layout--group-counts-uncovered-prs ()
  "The folded-in Requests content: PRs in this repo with no session."
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions
                                                 decknix-layout-test--items))
         (upside (seq-find (lambda (g) (equal "upside" (plist-get g :repo))) groups))
         (dapi (seq-find (lambda (g) (equal "dapi-contracts" (plist-get g :repo)))
                         groups)))
    (should (= 1 (plist-get upside :uncovered)))   ; #21205
    (should (= 1 (plist-get dapi :uncovered)))))

(ert-deftest decknix-layout--a-sessionless-repo-reports-work-not-zero ()
  "A bare \"0\" told the user nothing; the interesting fact is the waiting work."
  (should (string-match-p "1 new"
                          (decknix--layout-group-label
                           '(:repo "dapi-contracts" :sessions 0 :asking 0
                             :uncovered 1) 48)))
  (should-not (string-match-p "0"
                              (decknix--layout-group-label
                               '(:repo "r" :sessions 0 :asking 0 :uncovered 1) 48))))

(ert-deftest decknix-layout--a-quiet-but-covered-repo-shows-its-count ()
  "A covered repo with nothing blocked gets the quiet glyph, and its right
column reports WHAT is in there rather than how many agents are on it."
  (let ((label (decknix--layout-group-label
                '(:repo "r" :sessions 2 :doing 2 :asking 0 :uncovered 0
                        :humans 1 :bots 1) 48)))
    (should (string-match-p "●" label))
    (should (string-match-p "1@" label))
    (should (string-match-p "1π" label))
    (should-not (string-match-p "⚑" label))))


;; --- attention-only filtering -----------------------------------------
;;
;; A repo whose sessions are all `working' or `ready' is in flight and wants
;; nothing.  At the top of the sidebar it competes with the rows that do.

(ert-deftest decknix-layout--a-blocked-session-earns-a-row ()
  (should (decknix--layout-group-wants-me-p '(:asking 1 :sessions 3 :uncovered 0))))

(ert-deftest decknix-layout--an-unstarted-pr-earns-a-row ()
  "This is the folded-in Requests case: nobody is on it yet."
  (should (decknix--layout-group-wants-me-p '(:asking 0 :sessions 0 :uncovered 2))))

(ert-deftest decknix-layout--work-in-flight-does-not-earn-a-row ()
  "Sessions present, none blocked, nothing unstarted: wants nothing."
  (should-not (decknix--layout-group-wants-me-p
               '(:asking 0 :sessions 4 :uncovered 0))))

(ert-deftest decknix-layout--an-empty-group-does-not-earn-a-row ()
  (should-not (decknix--layout-group-wants-me-p '(:asking 0 :sessions 0 :uncovered 0)))
  (should-not (decknix--layout-group-wants-me-p nil)))

(ert-deftest decknix-layout--filter-reports-what-it-held-back ()
  "A section that quietly shrinks is indistinguishable from an empty one --
the same failure that let a repo-sync error hide for 61 runs."
  (let* ((groups '((:repo "loud" :asking 2 :sessions 2 :uncovered 0)
                   (:repo "quiet" :asking 0 :sessions 4 :uncovered 0)
                   (:repo "new" :asking 0 :sessions 0 :uncovered 1)))
         (split (decknix--layout-filter-groups groups t)))
    (should (equal '("loud" "new")
                   (mapcar (lambda (g) (plist-get g :repo)) (car split))))
    (should (= 1 (cdr split)))))

(ert-deftest decknix-layout--filter-off-restores-everything ()
  "The toggle has to genuinely restore the previous behaviour, held count
included, or `off' would still be a filtered view."
  (let* ((groups '((:repo "a" :asking 0 :sessions 4 :uncovered 0)
                   (:repo "b" :asking 1 :sessions 1 :uncovered 0)))
         (split (decknix--layout-filter-groups groups nil)))
    (should (= 2 (length (car split))))
    (should (= 0 (cdr split)))))

(ert-deftest decknix-layout--filter-of-nothing-is-nothing ()
  (should (equal '(nil . 0) (decknix--layout-filter-groups nil t))))


;; --- WIP nesting and Dormant ------------------------------------------
;;
;; The old layout emitted a SECOND heading also called "WIP" for my PRs and
;; worktrees, with nothing stating which session was on which. Nesting fixes
;; that; Dormant holds what no live session claims.

(defun decknix-layout-test--ws-session (name state ws)
  (list name '("t") nil state ws))

(defconst decknix-layout-test--wip-repos
  '(((repo . "UpsideRealty/upside")
     (prs . (((number . 20511) (branch . "fix/postman"))
             ((number . 21300) (branch . "unrelated-branch")))))
    ((repo . "nc-helix/platform-cli")
     (prs . (((number . 57) (branch . "CONN-1040-generator-fixes")))))))

(defconst decknix-layout-test--worktrees
  '((:repo "upsiderealty/upside" :branch "fix/postman" :path "/w/upside-wt/postman")
    (:repo "nc-helix/platform-cli" :branch "CONN-1040-generator-fixes"
     :path "/w/cli-wt/CONN-1040")
    (:repo "upsiderealty/decknix" :branch "abandoned" :path "/w/decknix-wt/old")))

(ert-deftest decknix-layout--wip-nests-the-worktree-a-session-occupies ()
  (let* ((s (decknix-layout-test--ws-session "*Claude: a*" "working" "/w/upside-wt/postman"))
         (tree (decknix--layout-wip-tree (list s) decknix-layout-test--wip-repos
                                         decknix-layout-test--worktrees))
         (row (car (plist-get tree :sessions))))
    (should (equal '("fix/postman")
                   (mapcar (lambda (w) (plist-get w :branch))
                           (plist-get row :worktrees))))))

(ert-deftest decknix-layout--wip-nests-the-pr-on-that-branch ()
  "The PR is claimed via the worktree's branch, which is the only link
between a session's workspace and a PR number."
  (let* ((s (decknix-layout-test--ws-session "*Claude: a*" "working" "/w/upside-wt/postman"))
         (tree (decknix--layout-wip-tree (list s) decknix-layout-test--wip-repos
                                         decknix-layout-test--worktrees))
         (row (car (plist-get tree :sessions))))
    (should (equal '(20511) (mapcar (lambda (p) (plist-get p :number))
                                    (plist-get row :prs))))))

(ert-deftest decknix-layout--workspace-match-ignores-a-trailing-slash ()
  "The audit writes some paths with a trailing slash and some without; the
plain compare is the bug that once hid `decknix-config' from the picker."
  (let ((s (decknix-layout-test--ws-session "*Claude: a*" "working" "/w/upside-wt/postman/")))
    (should (decknix--layout-session-owns-wt-p
             s '(:path "/w/upside-wt/postman")))
    (should (decknix--layout-session-owns-wt-p
             (decknix-layout-test--ws-session "*C*" "working" "/w/upside-wt/postman")
             '(:path "/w/upside-wt/postman/")))))

(ert-deftest decknix-layout--unclaimed-work-is-dormant ()
  "Everything no live session occupies lands in Dormant, not nowhere."
  (let* ((s (decknix-layout-test--ws-session "*Claude: a*" "working" "/w/upside-wt/postman"))
         (tree (decknix--layout-wip-tree (list s) decknix-layout-test--wip-repos
                                         decknix-layout-test--worktrees))
         (dormant (plist-get tree :dormant)))
    (should (equal '("CONN-1040-generator-fixes" "abandoned")
                   (mapcar (lambda (w) (plist-get w :branch))
                           (plist-get dormant :worktrees))))
    ;; #20511 is claimed via the session's worktree branch; the other two
    ;; belong to repos no tag names.
    (should (equal '(21300 57) (mapcar (lambda (p) (plist-get p :number))
                                       (plist-get dormant :prs))))))

(ert-deftest decknix-layout--tag-claims-a-repo-by-name ()
  "The only association available for a session in the workspace ROOT, which
is where all 47 live sessions actually sit."
  (should (decknix--layout-tag-matches-repo-p "decknix" "upsiderealty/decknix"))
  (should (decknix--layout-tag-matches-repo-p
           "followupboss" "UpsideRealty/followupboss-integration"))
  (should (decknix--layout-tag-matches-repo-p "rea-integration" "o/rea-integration")))

(ert-deftest decknix-layout--short-tags-claim-nothing ()
  "`us\=', `ai\=', `mvp\=' and `org\=' are all real session tags and none is a repo
name; without a floor they would each claim something."
  (dolist (tag '("us" "ai" "mvp" "org" "" nil))
    (should-not (decknix--layout-tag-matches-repo-p tag "upsiderealty/mvp-thing"))))

(ert-deftest decknix-layout--tag-match-is-not-a-substring-test ()
  "`core\=' does not name `connect-to-core\=', and a substring test would say it
does -- so the prefix must be the LEADING hyphenated segment."
  (should-not (decknix--layout-tag-matches-repo-p "core" "o/connect-to-core"))
  (should-not (decknix--layout-tag-matches-repo-p "integration" "o/rea-integration")))

(ert-deftest decknix-layout--no-sessions-makes-everything-dormant ()
  (let* ((tree (decknix--layout-wip-tree nil decknix-layout-test--wip-repos
                                         decknix-layout-test--worktrees))
         (dormant (plist-get tree :dormant)))
    (should (= 3 (length (plist-get dormant :worktrees))))
    (should (= 3 (length (plist-get dormant :prs))))))

(ert-deftest decknix-layout--two-sessions-sharing-a-workspace-both-claim-it ()
  "Preferred over picking a winner, which would hide that they share."
  (let* ((a (decknix-layout-test--ws-session "*A*" "working" "/w/upside-wt/postman"))
         (b (decknix-layout-test--ws-session "*B*" "ready" "/w/upside-wt/postman"))
         (tree (decknix--layout-wip-tree (list a b) decknix-layout-test--wip-repos
                                         decknix-layout-test--worktrees)))
    (dolist (row (plist-get tree :sessions))
      (should (= 1 (length (plist-get row :worktrees)))))
    ;; and it is not double-counted into Dormant
    (should-not (seq-find (lambda (w) (equal "fix/postman" (plist-get w :branch)))
                          (plist-get (plist-get tree :dormant) :worktrees)))))

(ert-deftest decknix-layout--a-session-with-no-workspace-claims-nothing ()
  (let* ((s (decknix-layout-test--ws-session "*A*" "ready" nil))
         (tree (decknix--layout-wip-tree (list s) decknix-layout-test--wip-repos
                                         decknix-layout-test--worktrees)))
    (should-not (plist-get (car (plist-get tree :sessions)) :worktrees))
    (should (= 3 (length (plist-get (plist-get tree :dormant) :worktrees))))))

;; --- what unattended work is worth a row ------------------------------
;;
;; The section used to render one row per repo with a bare tally -- `2 wt\=',
;; `1 pr 3 wt\=' -- and was reported as saying nothing actionable.  The first
;; replacement listed every unattended item and was worse: live numbers were
;; 20 worktrees and 7 PRs, so 24 rows against the 8 it replaced, 14 of them
;; orphans whose only remedy is a bulk prune.  So the split is what decides
;; whether this section informs or buries, and these pin it.

(ert-deftest decknix-layout--dormant-gives-a-dirty-worktree-a-row ()
  "Dirty is uncommitted work: the one state here that can be LOST."
  (let ((split (decknix--layout-dormant-split
                (list :worktrees (list (list :branch "a" :dirty t))))))
    (should (= 1 (length (plist-get split :worktrees))))
    (should (= 0 (plist-get split :orphans)))
    (should (= 0 (plist-get split :quiet)))))

(ert-deftest decknix-layout--dormant-counts-orphans-instead-of-listing-them ()
  "14 rows saying `branch gone from origin\=' is how the first attempt made
the section three times bigger than the tally it replaced."
  (let ((split (decknix--layout-dormant-split
                (list :worktrees (list (list :branch "a" :orphan t)
                                       (list :branch "b" :orphan t))))))
    (should-not (plist-get split :worktrees))
    (should (= 2 (plist-get split :orphans)))
    (should (= 0 (plist-get split :quiet)))))

(ert-deftest decknix-layout--dormant-prefers-dirty-over-orphan ()
  "An orphaned worktree that is ALSO dirty still holds work that can be
lost, so it must not be swept into the prune count."
  (let ((split (decknix--layout-dormant-split
                (list :worktrees (list (list :branch "a" :orphan t :dirty t))))))
    (should (= 1 (length (plist-get split :worktrees))))
    (should (= 0 (plist-get split :orphans)))))

(ert-deftest decknix-layout--dormant-drops-a-clean-tracking-worktree ()
  "Nothing to decide, so it costs a row and earns nothing."
  (let ((split (decknix--layout-dormant-split
                (list :worktrees (list (list :branch "a"))))))
    (should-not (plist-get split :worktrees))
    (should (= 1 (plist-get split :quiet)))))

(ert-deftest decknix-layout--dormant-gives-a-non-draft-pr-a-row ()
  "Open and sessionless means it is waiting on a reviewer or blocked."
  (let ((split (decknix--layout-dormant-split
                (list :prs (list (list :number 1 :pr '((draft . :json-false))))))))
    (should (= 1 (length (plist-get split :prs))))))

(ert-deftest decknix-layout--dormant-counts-a-draft-pr-as-quiet ()
  "A draft is the author saying not yet."
  (let ((split (decknix--layout-dormant-split
                (list :prs (list (list :number 1 :pr '((draft . t))))))))
    (should-not (plist-get split :prs))
    (should (= 1 (plist-get split :quiet)))))

(ert-deftest decknix-layout--dormant-buckets-account-for-every-item ()
  "Rows plus orphans plus quiet must equal the input, or the section is
dropping work silently -- the failure it already had once."
  (let* ((wts (list (list :branch "a" :dirty t)
                    (list :branch "b" :orphan t)
                    (list :branch "c")))
         (prs (list (list :number 1 :pr '((draft . t)))
                    (list :number 2 :pr '((draft . :json-false)))))
         (split (decknix--layout-dormant-split (list :worktrees wts :prs prs))))
    (should (= (+ (length wts) (length prs))
               (+ (length (plist-get split :worktrees))
                  (length (plist-get split :prs))
                  (plist-get split :orphans)
                  (plist-get split :quiet))))))

(ert-deftest decknix-layout--dormant-split-handles-an-empty-section ()
  (let ((split (decknix--layout-dormant-split nil)))
    (should-not (plist-get split :worktrees))
    (should-not (plist-get split :prs))
    (should (= 0 (plist-get split :orphans)))
    (should (= 0 (plist-get split :quiet)))))

;; --- where a PR stands relative to my review ---------------------------
;;
;; Nothing in Reviews changed after a response: an approved PR whose session
;; had auto-closed came back as `new\=', and one left open after `LGTM + 1
;; comment\=' looked the same whether or not the author had since pushed.

(defun decknix-layout-test--rpr (item &optional state gone)
  (list :number 1 :state state :item item :gone gone))

(ert-deftest decknix-layout--an-unreviewed-pr-has-no-phase ()
  (should-not (decknix--layout-review-phase
               (decknix-layout-test--rpr '((review_requested_of_me . t))))))

(ert-deftest decknix-layout--an-approval-with-nothing-since-is-responded ()
  (should (eq 'responded (decknix--layout-review-phase
                          (decknix-layout-test--rpr
                           '((my_review . "APPROVED") (pushed_since_my_review . :false)))))))

(ert-deftest decknix-layout--a-push-after-my-review-is-updated ()
  (let ((pr (decknix-layout-test--rpr
             '((my_review . "COMMENTED") (pushed_since_my_review . t)))))
    (should (eq 'updated (decknix--layout-review-phase pr)))
    (should (equal "pushed" (decknix--layout-review-update-reason pr)))))

(ert-deftest decknix-layout--a-reply-to-me-is-updated ()
  (let ((pr (decknix-layout-test--rpr '((my_review . "COMMENTED") (replies_to_me . t)))))
    (should (eq 'updated (decknix--layout-review-phase pr)))
    (should (equal "replied" (decknix--layout-review-update-reason pr)))))

(ert-deftest decknix-layout--a-dismissed-review-is-updated ()
  (should (eq 'updated (decknix--layout-review-phase
                        (decknix-layout-test--rpr '((my_review . "DISMISSED")))))))

(ert-deftest decknix-layout--a-pending-draft-review-is-not-a-response ()
  (should-not (decknix--layout-review-phase
               (decknix-layout-test--rpr '((my_review . "PENDING"))))))

(ert-deftest decknix-layout--a-merged-pr-is-obsolete-whatever-i-said ()
  (should (eq 'obsolete (decknix--layout-review-phase
                         (decknix-layout-test--rpr '((my_review . "APPROVED")) "ready" t)))))

(ert-deftest decknix-layout--a-responded-pr-with-no-session-is-not-new ()
  "The reported fault: LGTM, session auto-closed, repo flagged new again."
  (let* ((items '(((repo . "o/r") (number . 7) (author . "pat")
                   (my_review . "APPROVED") (pushed_since_my_review . :false))))
         (g (car (decknix--layout-review-groups nil items items))))
    (should (= 0 (plist-get g :uncovered)))
    (should (= 1 (plist-get g :responded)))
    (should (eq 'responded (decknix--layout-group-state g)))
    (should-not (decknix--layout-group-wants-me-p g))
    (should (string-match-p "✓1" (decknix--layout-group-label g 48)))))

(ert-deftest decknix-layout--a-pr-that-moved-since-my-review-wants-me ()
  (let* ((items '(((repo . "o/r") (number . 7) (author . "pat")
                   (my_review . "APPROVED") (pushed_since_my_review . t))))
         (g (car (decknix--layout-review-groups nil items items))))
    (should (= 1 (plist-get g :updated)))
    (should (eq 'updated (decknix--layout-group-state g)))
    (should (decknix--layout-group-wants-me-p g))
    (should (string-match-p "↻1" (decknix--layout-group-label g 48)))))

(ert-deftest decknix-layout--a-session-left-open-after-responding-goes-quiet ()
  "LGTM + 1 comment, session kept open: not `doing\=' until the author moves."
  (let* ((items '(((repo . "o/r") (number . 7) (author . "pat")
                   (my_review . "COMMENTED") (pushed_since_my_review . :false))))
         (g (list :repo "r" :asking 0 :uncovered 0 :sessions 1 :doing 0 :responded 1)))
    (ignore items)
    (should (eq 'responded (decknix--layout-group-state g)))
    (should (string-match-p "✓" (decknix--layout-group-label g 48)))))

(ert-deftest decknix-layout--a-tick-never-sits-beside-waiting-prs ()
  (let ((label (decknix--layout-group-label
                '(:repo "upside" :asking 0 :uncovered 8 :doing 0 :responded 1 :humans 8) 48)))
    (should-not (string-match-p "\\`  ?✓" label))
    (should (string-match-p "✓1" label))))

(ert-deftest decknix-layout--a-responded-pr-row-says-what-i-said ()
  (should (string-match-p "✓ approved"
                          (decknix--layout-pr-label
                           (decknix-layout-test--rpr '((my_review . "APPROVED")) "ready")
                           60))))

;; --- memos see a refreshed feed -------------------------------------
;;
;; Both signatures hashed only repo and PR numbers, so a feed refresh that
;; changed a PR's state but not its number reused the old tree.
;; followupboss#279 rendered approved after its approval was dismissed.

(ert-deftest decknix-layout--a-refreshed-wip-feed-changes-the-signature ()
  (let ((before (list (list (cons 'repo "o/r")
                            (cons 'prs (list (list (cons 'number 279) (cons 'review_decision "APPROVED")))))))
        (after (list (list (cons 'repo "o/r")
                           (cons 'prs (list (list (cons 'number 279) (cons 'review_decision "REVIEW_REQUIRED"))))))))
    (should-not (= (decknix--layout-wip-signature nil before nil)
                   (decknix--layout-wip-signature nil after nil)))))

(ert-deftest decknix-layout--the-same-wip-feed-keeps-its-signature ()
  "The memo must still serve every paint between refreshes."
  (let ((feed (list (list (cons 'repo "o/r") (cons 'prs (list (list (cons 'number 1))))))))
    (should (= (decknix--layout-wip-signature nil feed nil)
               (decknix--layout-wip-signature nil feed nil)))))

(ert-deftest decknix-layout--a-refreshed-review-feed-changes-the-signature ()
  (let ((a (list (list (cons 'repo "o/r") (cons 'number 7) (cons 'my_review nil))))
        (b (list (list (cons 'repo "o/r") (cons 'number 7) (cons 'my_review "APPROVED")))))
    (should-not (= (decknix--layout-groups-signature nil a)
                   (decknix--layout-groups-signature nil b)))))

(ert-deftest decknix-layout--a-freshly-filtered-list-of-the-same-items-hits ()
  "The sidebar filters into a NEW list every paint; the items are the same."
  (let ((items (list (list (cons 'repo "o/r") (cons 'number 7)))))
    (should (= (decknix--layout-groups-signature nil (copy-sequence items))
               (decknix--layout-groups-signature nil (copy-sequence items))))))

;; --- token quotas ---------------------------------------------------

(defconst decknix-layout-test--now (date-to-time "2026-10-09T06:00:00Z"))

(ert-deftest decknix-layout--quota-until-is-compact ()
  (should (equal "42m" (decknix--layout-quota-until "2026-10-09T06:42:00Z" decknix-layout-test--now)))
  (should (equal "3h05" (decknix--layout-quota-until "2026-10-09T09:05:00Z" decknix-layout-test--now)))
  (should (equal "5d" (decknix--layout-quota-until "2026-10-14T07:00:00Z" decknix-layout-test--now)))
  (should-not (decknix--layout-quota-until nil decknix-layout-test--now)))

(ert-deftest decknix-layout--quota-reset-shows-only-when-it-matters ()
  "A reset time beside 16% is noise; beside 95% it is what you wait for."
  (should (equal "5h 16%" (decknix--layout-quota-window
                           '((name . "5h") (used_percent . 16) (resets_at . "2026-10-09T08:00:00Z"))
                           decknix-layout-test--now)))
  (should (equal "5h 95% ↻2h00" (decknix--layout-quota-window
                                 '((name . "5h") (used_percent . 95) (resets_at . "2026-10-09T08:00:00Z"))
                                 decknix-layout-test--now))))

(ert-deftest decknix-layout--quota-face-says-whether-a-prompt-would-go-through ()
  (should (eq 'success (decknix--layout-quota-face '((windows . (((used_percent . 9))))))))
  (should (eq 'warning (decknix--layout-quota-face '((windows . (((used_percent . 85))))))))
  (should (eq 'error (decknix--layout-quota-face '((limit_reached . t)))))
  (should (eq 'error (decknix--layout-quota-face '((error . "token expired"))))))

(ert-deftest decknix-layout--a-refusing-account-is-not-green-at-low-usage ()
  "Anthropic at 16% with extra usage off refused Pi outright."
  (should (eq 'warning (decknix--layout-quota-face
                        '((windows . (((used_percent . 16))))
                          (note . "extra usage off: refuses third-party apps"))))))

(ert-deftest decknix-layout--quota-lines-fit-and-carry-the-reason ()
  (let ((lines (decknix--layout-quota-lines
                '((label . "claude") (plan . "max 20x")
                  (windows . (((name . "5h") (used_percent . 16)) ((name . "week") (used_percent . 10))))
                  (note . "extra usage off: refuses third-party apps"))
                decknix-layout-test--now 47)))
    (should (= 2 (length lines)))
    (should (string-match-p "claude.*5h 16%.*week 10%" (car lines)))
    (should (string-match-p "extra usage off" (cadr lines)))
    (dolist (l lines) (should (<= (string-width l) 47)))))

(ert-deftest decknix-layout--quota-heading-says-how-old-the-data-is ()
  (should (equal '("Tokens · now" . nil)
                 (decknix--layout-quota-heading "2026-10-09T05:59:30Z" decknix-layout-test--now)))
  (should (equal '("Tokens · 3m" . nil)
                 (decknix--layout-quota-heading "2026-10-09T05:57:00Z" decknix-layout-test--now))))

(ert-deftest decknix-layout--quota-heading-flags-a-hub-that-stopped ()
  "Three missed five-minute polls."
  (should (equal '("Tokens · stale 40m" . t)
                 (decknix--layout-quota-heading "2026-10-09T05:20:00Z" decknix-layout-test--now)))
  (should (cdr (decknix--layout-quota-heading nil decknix-layout-test--now))))

;; --- sub-agents --------------------------------------------------------

(ert-deftest decknix-layout--a-subagent-is-named-by-type-and-task ()
  "Not by its parent: six rows read `↳ C mvp/followupboss/us'."
  (should (equal "pr-implementer: Contacts 01.2 to ready"
                 (decknix--layout-subagent-label
                  '((agentType . "pr-implementer") (description . "Contacts 01.2 to ready")
                    (slug . "mvp/followupboss/us"))))))

(ert-deftest decknix-layout--a-subagent-without-meta-falls-back-to-its-slug ()
  (should (equal "s" (decknix--layout-subagent-label '((slug . "s")))))
  (should (equal "agent" (decknix--layout-subagent-label nil))))

(ert-deftest decknix-layout--a-user-stopped-subagent-reads-stopped ()
  (should (eq 'stopped (decknix--layout-subagent-state '((stoppedByUser . t)) 'done)))
  (should (eq 'running (decknix--layout-subagent-state '((stoppedByUser . t)) 'running)))
  (should (eq 'done (decknix--layout-subagent-state nil 'done))))

(ert-deftest decknix-layout--subagent-counts-come-in-display-order ()
  (should (equal '((running . 2) (stopped . 1) (done . 3))
                 (decknix--layout-subagent-counts '(done running stopped done running done)))))

(ert-deftest decknix-layout--subagent-summary-counts-every-child ()
  (should (equal "6 agents ◐2 ■1 ●3"
                 (substring-no-properties
                  (decknix--layout-subagent-summary '(done running stopped done running done))))))

;; --- PRs a session created ---------------------------------------------

(ert-deftest decknix-layout--a-created-pr-is-recognised-case-insensitively ()
  (should (decknix--layout-pr-created-p '(:repo "UpsideRealty/rea-integration" :number 89)
                                        '("upsiderealty/rea-integration#89")))
  (should-not (decknix--layout-pr-created-p '(:repo "UpsideRealty/rea-integration" :number 8)
                                            '("UpsideRealty/rea-integration#89")))
  (should-not (decknix--layout-pr-created-p '(:repo "o/r" :number 1) nil)))

(ert-deftest decknix-layout--a-session-keeps-the-prs-it-created ()
  "Even with no recent activity anywhere near them."
  (cl-letf (((symbol-function 'decknix--layout-session-observed-roots)
             (lambda (_s) '("/w/followupboss-integration-worktrees/CONN-1088-bench")))
            ((symbol-function 'decknix--layout-session-created-prs)
             (lambda (_s) '("UpsideRealty/rea-integration#89"))))
    (let* ((decknix--layout-wip-memo nil)
           (wip '(((repo . "UpsideRealty/rea-integration")
                   (prs . (((number . 89) (branch . "CONN-1140-nix-pilot"))
                           ((number . 90) (branch . "someone-else")))))))
           (row (car (plist-get (decknix--layout-wip-tree-1
                                 (list '("*s*" nil nil "ready" nil)) wip nil)
                                :sessions))))
      (should (equal '(89) (mapcar (lambda (p) (plist-get p :number)) (plist-get row :prs)))))))

;; --- worktree labels ------------------------------------------------
;;
;; A review worktree is checked out detached at the PR head, so its branch
;; is the HEAD hash.  Rows read `dfebdad\', `f95dad0\', `69ad4fa\' and were
;; reported as unrecognisable.

(ert-deftest decknix-layout--a-named-branch-is-its-own-label ()
  (should (equal "HX-1062-acker" (decknix--layout-wt-label (list :branch "HX-1062-acker")))))

(ert-deftest decknix-layout--a-review-worktree-is-labelled-by-its-pr ()
  (should (equal "review #301"
                 (decknix--layout-wt-label
                  (list :branch "dfebdad" :path "/r/attom-integration-worktrees/pr-301")))))

(ert-deftest decknix-layout--a-review-worktree-carries-the-pr-title-when-known ()
  (should (equal "review #301 Fix the thing"
                 (decknix--layout-wt-label
                  (list :branch "dfebdad" :repo "o/r" :path "/r/x/pr-301/")
                  (lambda (repo n) (and (equal repo "o/r") (= n 301) "Fix the thing"))))))

(ert-deftest decknix-layout--other-detached-worktrees-fall-back-to-the-directory ()
  (should (equal "spike-dir"
                 (decknix--layout-wt-label (list :branch "abc1234" :path "/r/spike-dir")))))

(ert-deftest decknix-layout--a-hash-is-recognised-and-a-word-is-not ()
  (should (decknix--layout-hash-p "dfebdad"))
  (should-not (decknix--layout-hash-p "feature"))
  (should-not (decknix--layout-hash-p "deadbeefcafe-branch")))

;; --- sessions covering one PR -----------------------------------------

(ert-deftest decknix-layout--pr-sessions-finds-every-cover ()
  "Drives the indented session rows shown only where two agents share a PR."
  (should (= 2 (length (decknix--layout-pr-sessions
                        decknix-layout-test--sessions "upside#21248"))))
  (should (= 1 (length (decknix--layout-pr-sessions
                        decknix-layout-test--sessions "upside#17172"))))
  (should-not (decknix--layout-pr-sessions
               decknix-layout-test--sessions "upside#99999")))


;; --- state indicators -------------------------------------------------
;;
;; The refactor rendered session rows in `default' and nested work as a grey
;; repo name.  At the sidebar's 48 columns the trailing status word is
;; off-screen, so there was nothing left to read state from.

(defun decknix-layout-test--pr (&rest kv)
  "Build a WIP PR whose `:pr' is an ALIST, as the JSON feed parses it.
Written as a plist first and converted, because a plist there silently
reads as nil through `alist-get' -- which is how the first version of these
tests \"passed\" the code it was meant to exercise."
  (let (alist)
    (while kv
      (push (cons (pop kv) (pop kv)) alist))
    (list :number 1 :branch "b" :repo "o/r" :pr (nreverse alist))))

(ert-deftest decknix-layout--every-session-state-has-a-face ()
  "A state rendering in `default' is a state the user cannot see."
  (dolist (state '("netfail" "waiting" "asking" "working" "finished"
                   "ready" "closing"))
    (should-not (eq 'default (decknix--layout-state-face state)))))

(ert-deftest decknix-layout--unknown-state-falls-back-not-errors ()
  (should (eq 'default (decknix--layout-state-face "banana")))
  (should (eq 'default (decknix--layout-state-face nil))))

(ert-deftest decknix-layout--session-faces-agree-with-the-requests-indicator ()
  "One face for blocked-on-you, shared with the Requests indicator, so a
colour cannot mean one thing in the sidebar and another on a Request row."
  (dolist (state '("netfail" "waiting" "asking"))
    (should (eq 'decknix-attention-face (decknix--layout-state-face state))))
  (should (plist-get (decknix--layout-state-face "working") :foreground)))

(ert-deftest decknix-layout--a-blocked-review-group-uses-the-attention-face ()
  (should (eq 'decknix-attention-face
              (decknix--layout-group-face '(:asking 1 :prs nil)))))

;; --- PR severity ------------------------------------------------------

(ert-deftest decknix-layout--a-blocked-pr-is-worst ()
  "Conflict, failing CI and changes-requested all block the merge."
  (should (= 0 (decknix--layout-pr-severity
                (decknix-layout-test--pr 'mergeable "CONFLICTING"))))
  (should (= 0 (decknix--layout-pr-severity
                (decknix-layout-test--pr 'ci '((status . "fail"))))))
  (should (= 0 (decknix--layout-pr-severity
                (decknix-layout-test--pr 'review_decision "CHANGES_REQUESTED")))))

(ert-deftest decknix-layout--unresolved-threads-want-me ()
  (should (= 1 (decknix--layout-pr-severity
                (decknix-layout-test--pr 'unresolved_total 2))))
  (should (= 1 (decknix--layout-pr-severity
                (decknix-layout-test--pr 'needs_reply t)))))

(ert-deftest decknix-layout--blocked-outranks-wants-me ()
  "A conflicted PR with unresolved threads is blocked first: the threads
cannot be actioned into a merge while the conflict stands."
  (should (= 0 (decknix--layout-pr-severity
                (decknix-layout-test--pr 'mergeable "CONFLICTING"
                                         'unresolved_total 3)))))

(ert-deftest decknix-layout--an-approved-green-pr-reads-green ()
  (should (= 3 (decknix--layout-pr-severity
                (decknix-layout-test--pr 'review_decision "APPROVED"
                                         'ci '((status . "pass")))))))

(ert-deftest decknix-layout--a-draft-is-muted-but-not-if-blocked ()
  "A draft is not asking for anything -- unless it is broken."
  (should (= 4 (decknix--layout-pr-severity (decknix-layout-test--pr 'draft t))))
  (should (= 0 (decknix--layout-pr-severity
                (decknix-layout-test--pr 'draft t 'mergeable "CONFLICTING")))))

;; --- PR indicators ----------------------------------------------------

(ert-deftest decknix-layout--dirty-outranks-every-other-worktree-flag ()
  "Uncommitted work is the only state here that can be LOST, so it must not
be masked by a merged or orphaned flag."
  (should (= 1 (decknix--layout-wt-severity '(:dirty t :merged t :orphan t))))
  (should (equal "✎ " (decknix--layout-wt-indicators
                       '(:dirty t :merged t :orphan t)))))

(ert-deftest decknix-layout--worktree-states-are-distinguishable ()
  (should (equal "● " (decknix--layout-wt-indicators '(:active t))))
  (should (equal "✓ " (decknix--layout-wt-indicators '(:merged t))))
  (should (equal "⑂ " (decknix--layout-wt-indicators '(:orphan t))))
  (should (equal "◌ " (decknix--layout-wt-indicators '()))))

;; --- repo rollup ------------------------------------------------------

(ert-deftest decknix-layout--repo-row-takes-its-worst-child ()
  "A collapsed repo must still show that something inside is blocked."
  (should (= 0 (decknix--layout-worst-severity
                (list (decknix-layout-test--pr 'review_decision "APPROVED"
                                               'ci '((status . "pass")))
                      (decknix-layout-test--pr 'mergeable "CONFLICTING"))
                nil)))
  (should (= 1 (decknix--layout-worst-severity nil '((:dirty t))))))

(ert-deftest decknix-layout--a-repo-with-nothing-has-no-severity ()
  (should-not (decknix--layout-worst-severity nil nil)))

(ert-deftest decknix-layout--claims-carry-their-items-not-just-counts ()
  "A count cannot say whether anything in there is blocked, which is the
whole point of the indicators."
  (let* ((s (decknix-layout-test--ws-session "*A*" "working" "/w/upside-wt/postman"))
         (tree (decknix--layout-wip-tree (list s) decknix-layout-test--wip-repos
                                         decknix-layout-test--worktrees))
         (claim (car (plist-get (car (plist-get tree :sessions)) :repos))))
    (should (plist-get claim :pr-items))
    (should (plist-get claim :wt-items))
    (should (numberp (plist-get claim :severity)))))

(ert-deftest decknix-layout--worst-repo-sorts-first ()
  "Within a session, the repo needing attention leads."
  (let* ((claims (decknix--layout-group-claims
                  '((:repo "o/clean" :branch "x"))
                  (list (list :repo "o/broken" :number 1 :branch "y"
                              :pr '((mergeable . "CONFLICTING")))))))
    (should (equal "broken" (plist-get (car claims) :repo)))))


(ert-deftest decknix-layout--count-label-omits-a-zero-half ()
  "A row reading \"0 pr 2 wt\" spends half its width on what is absent."
  (should (equal "2 wt" (decknix--layout-count-label 0 2)))
  (should (equal "3 pr" (decknix--layout-count-label 3 0)))
  (should (equal "3 pr 2 wt" (decknix--layout-count-label 3 2)))
  (should (equal "" (decknix--layout-count-label 0 0))))


;; --- shared repo claims -----------------------------------------------

(ert-deftest decknix-layout--a-repo-claimed-twice-is-marked-not-repeated ()
  "Two sessions sharing a workspace both claim its repos, and the full
PR/worktree subtree was rendered once per session -- six identical rows
twice."
  (let* ((rows (list (list :repos (list (list :repo "upside" :pr-items (list (list :repo "o/upside" :number 1)))))
                     (list :repos (list (list :repo "upside" :pr-items (list (list :repo "o/upside" :number 1)))))))
         (out (decknix--layout-dedup-claims rows)))
    (should-not (plist-get (car (plist-get (nth 0 out) :repos)) :duplicate))
    (should (plist-get (car (plist-get (nth 1 out) :repos)) :duplicate))))

(ert-deftest decknix-layout--the-duplicate-claim-is-kept-not-dropped ()
  "The sharing is worth stating; the render collapses it to one line
rather than hiding that two sessions are on the same repo."
  (let* ((rows (list (list :repos (list (list :repo "upside" :pr-items (list (list :repo "o/upside" :number 1)))))
                     (list :repos (list (list :repo "upside" :pr-items (list (list :repo "o/upside" :number 1)))))))
         (out (decknix--layout-dedup-claims rows)))
    (should (= 1 (length (plist-get (nth 1 out) :repos))))))

(ert-deftest decknix-layout--different-prs-in-one-repo-are-both-shown ()
  "followupboss-integration#334 vanished: HX-1338 read `shared' because
HX-1337 showed a DIFFERENT PR in the same repo."
  (let* ((rows (list (list :repos (list (list :repo "fub" :prs 1 :pr-items (list (list :repo "o/fub" :number 330)))))
                     (list :repos (list (list :repo "fub" :prs 1 :pr-items (list (list :repo "o/fub" :number 334)))))))
         (out (decknix--layout-dedup-claims rows))
         (second (car (plist-get (nth 1 out) :repos))))
    (should-not (plist-get second :duplicate))
    (should (equal '(334) (mapcar (lambda (p) (plist-get p :number)) (plist-get second :pr-items))))))

(ert-deftest decknix-layout--a-partly-shared-claim-lists-only-the-new-items ()
  (let* ((rows (list (list :repos (list (list :repo "fub" :pr-items (list (list :repo "o/fub" :number 1)))))
                     (list :repos (list (list :repo "fub" :prs 2
                                              :pr-items (list (list :repo "o/fub" :number 1)
                                                              (list :repo "o/fub" :number 2)))))))
         (second (car (plist-get (nth 1 (decknix--layout-dedup-claims rows)) :repos))))
    (should (equal '(2) (mapcar (lambda (p) (plist-get p :number)) (plist-get second :pr-items))))
    (should (= 1 (plist-get second :prs)))))

(ert-deftest decknix-layout--distinct-repos-are-both-first ()
  (let* ((rows (list (list :repos (list (list :repo "a")))
                     (list :repos (list (list :repo "b")))))
         (out (decknix--layout-dedup-claims rows)))
    (should-not (plist-get (car (plist-get (nth 1 out) :repos)) :duplicate))))

(ert-deftest decknix-layout--dedup-does-not-mutate-its-input ()
  "The tree is rebuilt per render but shared with the model; marking the
caller\='s plists would make the FIRST session show as a duplicate on the
next paint."
  (let* ((claim (list :repo "upside"))
         (rows (list (list :repos (list claim))
                     (list :repos (list claim)))))
    (decknix--layout-dedup-claims rows)
    (should-not (plist-get claim :duplicate))))

(ert-deftest decknix-layout--dedup-is-stable-across-repeated-calls ()
  "A render runs on every refresh; the second must mark the same claim."
  (let* ((rows (list (list :repos (list (list :repo "upside" :pr-items (list (list :repo "o/upside" :number 1)))))
                     (list :repos (list (list :repo "upside" :pr-items (list (list :repo "o/upside" :number 1))))))))
    (dotimes (_ 3)
      (let ((out (decknix--layout-dedup-claims rows)))
        (should-not (plist-get (car (plist-get (nth 0 out) :repos)) :duplicate))
        (should (plist-get (car (plist-get (nth 1 out) :repos)) :duplicate))))))


;; --- an open PR is never withheld -------------------------------------

(ert-deftest decknix-layout--prs-are-never-held-back ()
  "An open PR -- draft or awaiting approval -- carries a live obligation.
The budget used to be spent on PRs first, so a repo with more than the
budget hid the surplus behind \"... 3 more\"."
  (let* ((claim (list :pr-items (make-list 9 '(:number 1))
                      :wt-items nil))
         (split (decknix--layout-claim-items claim 5 nil)))
    (should (= 9 (length (nth 0 split))))
    (should (= 0 (nth 2 split)))))

(ert-deftest decknix-layout--the-budget-elides-worktrees-not-prs ()
  "A worktree is a local artefact and the safe thing to hide."
  (let* ((claim (list :pr-items (make-list 4 '(:number 1))
                      :wt-items (make-list 7 '(:branch "b"))))
         (split (decknix--layout-claim-items claim 5 nil)))
    (should (= 4 (length (nth 0 split))))
    (should (= 5 (length (nth 1 split))))
    (should (= 2 (nth 2 split)))))

(ert-deftest decknix-layout--expanding-shows-every-worktree ()
  (let* ((claim (list :pr-items nil :wt-items (make-list 7 '(:branch "b"))))
         (split (decknix--layout-claim-items claim 2 t)))
    (should (= 7 (length (nth 1 split))))
    (should (= 0 (nth 2 split)))))

;; --- Reviews ordering -------------------------------------------------

(ert-deftest decknix-layout--uncovered-prs-outrank-busy-sessions ()
  "They are the only rows nothing is happening to.  `:uncovered\=' was not a
sort key, so five untouched review requests sorted below two sessions
already working."
  (let ((out (decknix--layout-sort-groups
              (list (list :repo "busy" :asking 0 :sessions 2 :uncovered 0)
                    (list :repo "idle" :asking 0 :sessions 0 :uncovered 5)))))
    (should (equal "idle" (plist-get (car out) :repo)))))

(ert-deftest decknix-layout--blocked-sessions-outrank-everything ()
  (let ((out (decknix--layout-sort-groups
              (list (list :repo "new" :asking 0 :sessions 0 :uncovered 9)
                    (list :repo "blocked" :asking 1 :sessions 1 :uncovered 0)))))
    (should (equal "blocked" (plist-get (car out) :repo)))))

(ert-deftest decknix-layout--order-is-stable-on-a-tie ()
  (let ((out (decknix--layout-sort-groups
              (list (list :repo "zz" :asking 0 :sessions 1 :uncovered 0)
                    (list :repo "aa" :asking 0 :sessions 1 :uncovered 0)))))
    (should (equal "aa" (plist-get (car out) :repo)))))


;; --- observed association beats tags ---------------------------------

(ert-deftest decknix-layout--observed-roots-claim-across-repos ()
  "The case that prompted this: one session working in platform-cli AND
rea-integration worktrees.  The tag rule is repo-granular and named only
rea-integration, so the platform-cli PR appeared nowhere."
  (let ((roots '("/w/platform-cli-worktrees/CONN-1040"
                 "/w/rea-integration-worktrees/CONN-801")))
    (should (decknix--layout-session-observed-wt-p
             roots '(:path "/w/platform-cli-worktrees/CONN-1040")))
    (should (decknix--layout-session-observed-wt-p
             roots '(:path "/w/rea-integration-worktrees/CONN-801")))))

(ert-deftest decknix-layout--observed-roots-do-not-claim-untouched-work ()
  "The other half of the tag failure: claiming every worktree of a repo
the session merely happens to be named after."
  (should-not (decknix--layout-session-observed-wt-p
               '("/w/rea-integration-worktrees/CONN-801")
               '(:path "/w/rea-integration-worktrees/CONN-999"))))

(ert-deftest decknix-layout--no-observation-means-no-claim-by-observation ()
  "A session that has run no tool calls observes nothing, which is what
keeps the tag fallback meaningful rather than dead code."
  (should-not (decknix--layout-session-observed-wt-p
               nil '(:path "/w/anything"))))

(ert-deftest decknix-layout--observed-roots-come-from-the-session-buffer ()
  "Resolved per session, so two sessions cannot inherit each other\='s work."
  (let ((buf (generate-new-buffer "*Claude: obs*")))
    (unwind-protect
        (cl-letf (((symbol-function 'decknix-session-assoc-current)
                   (lambda (b) (when (eq b buf) '("/w/mine")))))
          (should (equal '("/w/mine")
                         (decknix--layout-session-observed-roots
                          (list "*Claude: obs*" nil nil "ready" nil))))
          (should-not (decknix--layout-session-observed-roots
                       (list "*Claude: other*" nil nil "ready" nil))))
      (kill-buffer buf))))

(ert-deftest decknix-layout--a-dead-session-buffer-observes-nothing ()
  "The snapshot can name a buffer that has since been killed."
  (should-not (decknix--layout-session-observed-roots
               (list "*Claude: gone*" nil nil "ready" nil))))


;; --- work that has already finished -----------------------------------

(ert-deftest decknix-layout--a-pr-with-a-session-but-no-feed-item-is-gone ()
  "The feed no longer carries it, so it has merged, closed, or stopped
being requested -- whatever the session still says."
  (let ((prs (list (list :state "asking" :item nil)
                   (list :state "asking" :item '((number . 1)))
                   (list :state nil :item nil))))
    (decknix--layout-mark-gone prs t)
    (should (decknix--layout-pr-gone-p (nth 0 prs)))
    (should-not (decknix--layout-pr-gone-p (nth 1 prs)))
    (should-not (decknix--layout-pr-gone-p (nth 2 prs)))))

(ert-deftest decknix-layout--nothing-is-gone-when-the-feed-said-nothing ()
  "Before the first poll every row has a session and no item.  Deriving
`gone\=' there marked all work finished and silenced the whole section."
  (let ((prs (list (list :state "asking" :item nil))))
    (decknix--layout-mark-gone prs nil)
    (should-not (decknix--layout-pr-gone-p (car prs)))))

(ert-deftest decknix-layout--a-session-on-only-finished-prs-is-not-asking ()
  "Measured live: three of eight flagged repos were not in the review feed
at all and existed only because a session sat on a merged PR.  Counting
those is what inflated \"13 need you\"."
  (should-not (decknix--layout-session-on-live-pr-p
               '("*a*" nil ("upside#1") "asking" nil) '("upside#2"))))

(ert-deftest decknix-layout--a-session-on-any-live-pr-is-still-asking ()
  "Partial completion must not silence a session that still has live work."
  (should (decknix--layout-session-on-live-pr-p
           '("*a*" nil ("upside#1" "upside#2") "asking" nil) '("upside#2"))))

(ert-deftest decknix-layout--a-session-with-no-recorded-pr-still-counts ()
  "Absence of a record is not evidence the work is done."
  (should (decknix--layout-session-on-live-pr-p
           '("*a*" nil nil "asking" nil) nil)))

(ert-deftest decknix-layout--live-keys-come-only-from-feed-backed-rows ()
  (should (equal '("a#1")
                 (decknix--layout-live-pr-keys
                  '((:key "a#1" :item ((number . 1)))
                    (:key "a#2" :item nil))))))

;; --- author and kind --------------------------------------------------

(ert-deftest decknix-layout--author-kind-reads-the-feed-item ()
  (should (eq 'bot (decknix--layout-pr-author-kind
                    '(:item ((author_kind . "bot"))))))
  (should (eq 'human (decknix--layout-pr-author-kind
                      '(:item ((author_kind . "human")))))))

(ert-deftest decknix-layout--a-human-committing-to-a-bot-pr-counts-as-human ()
  "`bot_human\=' means a person has committed to it, so it is no longer a
dependency bump nobody has looked at."
  (should (decknix--layout-pr-human-p '(:item ((author_kind . "bot_human"))))))

(ert-deftest decknix-layout--an-unknown-kind-is-neither ()
  "A row with no feed item has no author to report."
  (let ((pr '(:state "asking" :item nil)))
    (should-not (decknix--layout-pr-bot-p pr))
    (should-not (decknix--layout-pr-human-p pr))))

(ert-deftest decknix-layout--the-pr-row-names-its-author ()
  "A dependabot bump and a colleague waiting read identically without it."
  (let ((label (decknix--layout-pr-label
                '(:number 250 :state nil
                          :item ((author . "dependabot[bot]")
                                 (author_kind . "bot")))
                60)))
    (should (string-match-p "dependabot" label))
    (should (string-match-p "π" label))))

(ert-deftest decknix-layout--a-finished-pr-with-a-session-reads-obsolete ()
  "The session is still open on work that is over."
  (let ((prs (list (list :number 1 :state "asking" :item nil))))
    (decknix--layout-mark-gone prs t)
    (should (string-match-p "obsolete" (decknix--layout-pr-label (car prs) 60)))))

(ert-deftest decknix-layout--an-unmarked-row-keeps-its-session-state ()
  "With no feed, the row must still report what the session is doing
rather than claiming the work is over."
  (should (string-match-p
           "asking" (decknix--layout-pr-label '(:number 1 :state "asking") 60))))

(ert-deftest decknix-layout--the-pr-row-never-exceeds-its-width ()
  (let ((pr (list :number 12345 :state "asking"
                  :item (list (cons 'author (make-string 200 ?x))
                              (cons 'author_kind "human")))))
    (dolist (w '(30 48 70))
      (should (<= (string-width (decknix--layout-pr-label pr w)) w)))))

;; --- the group right column -------------------------------------------

(ert-deftest decknix-layout--group-right-splits-human-from-bot ()
  "\"5 5⚑\" said how many agents were running, not what they ran ON."
  (should (equal "2@ 3π" (decknix--layout-group-right 2 3 0 0))))

(ert-deftest decknix-layout--group-right-reports-finished-work ()
  (should (equal "1@ ✗4" (decknix--layout-group-right 1 0 4 0))))

(ert-deftest decknix-layout--group-right-falls-back-to-new-count ()
  (should (equal "3 new" (decknix--layout-group-right 0 0 0 3))))

(ert-deftest decknix-layout--group-right-omits-a-zero-kind ()
  (should (equal "4π" (decknix--layout-group-right 0 4 0 0))))

(ert-deftest decknix-layout--group-right-of-nothing-is-empty ()
  (should (equal "" (decknix--layout-group-right 0 0 0 0))))

(ert-deftest decknix-layout--group-label-is-exactly-the-width ()
  (dolist (w '(40 48 60))
    (should (= w (string-width
                  (decknix--layout-group-label
                   '(:repo "attom-integration" :asking 2 :humans 2 :bots 3) w))))))


;; --- not recomputing what has not changed -----------------------------

(ert-deftest decknix-layout--identical-input-reuses-the-grouping ()
  "The sidebar repaints every two seconds while the data behind it changes
when the hub polls.  Rebuilding regardless cost 92 ms a paint, 51% of it
GC, which is what the hitch report blamed on the sidebar timers."
  (let ((decknix--layout-groups-memo nil))
    (let ((a (decknix--layout-review-groups decknix-layout-test--sessions
                                            decknix-layout-test--items))
          (b (decknix--layout-review-groups decknix-layout-test--sessions
                                            decknix-layout-test--items)))
      (should (eq a b)))))

(ert-deftest decknix-layout--a-session-changing-state-rebuilds ()
  "Reusing here would freeze the attention flags at whatever they were."
  (let ((decknix--layout-groups-memo nil))
    (let* ((a (decknix--layout-review-groups
               (list (decknix-layout-test--session "s" "ready" '("r#1"))) nil))
           (b (decknix--layout-review-groups
               (list (decknix-layout-test--session "s" "asking" '("r#1"))) nil)))
      (should-not (eq a b)))))

(ert-deftest decknix-layout--a-session-appearing-rebuilds ()
  (let ((decknix--layout-groups-memo nil))
    (let* ((a (decknix--layout-review-groups
               (list (decknix-layout-test--session "s" "ready" '("r#1"))) nil))
           (b (decknix--layout-review-groups
               (list (decknix-layout-test--session "s" "ready" '("r#1"))
                     (decknix-layout-test--session "t" "ready" '("r#2")))
               nil)))
      (should-not (eq a b)))))

(ert-deftest decknix-layout--a-different-feed-of-the-same-length-rebuilds ()
  "The sidebar filters items before grouping, so two filter settings can
yield the same COUNT.  Keying on length alone reused the wrong groups."
  (let ((decknix--layout-groups-memo nil)
        (one '(((repo . "o/a") (number . 1))))
        (two '(((repo . "o/b") (number . 2)))))
    (let ((a (decknix--layout-review-groups nil one))
          (b (decknix--layout-review-groups nil two)))
      (should-not (eq a b)))))

(ert-deftest decknix-layout--invalidating-forces-a-rebuild ()
  "The escape hatch for anything the signature cannot see."
  (let ((decknix--layout-groups-memo nil))
    (let ((a (decknix--layout-review-groups decknix-layout-test--sessions nil)))
      (decknix-layout-invalidate-groups)
      (should-not (eq a (decknix--layout-review-groups
                         decknix-layout-test--sessions nil))))))


;; --- hidden by a filter is not the same as finished -------------------

(ert-deftest decknix-layout--a-filtered-pr-is-not-done ()
  "reapit-service#244 has a MERGE CONFLICT.  Conflicted and draft PRs are
hidden by default, so the grouping saw no feed item for it and reported
the work finished.  It is not: it is waiting on its author."
  (let ((prs (list (list :key "r#244" :state "asking" :item nil))))
    (decknix--layout-mark-gone prs t '("r#244"))
    (should (decknix--layout-pr-filtered-p (car prs)))
    (should-not (decknix--layout-pr-gone-p (car prs)))
    (should (string-match-p "not reviewable"
                            (decknix--layout-pr-label (car prs) 60)))))

(ert-deftest decknix-layout--a-pr-absent-from-the-raw-feed-is-done ()
  "The other half: genuinely merged, closed, or no longer requested."
  (let ((prs (list (list :key "r#1" :state "asking" :item nil))))
    (decknix--layout-mark-gone prs t '("r#999"))
    (should (decknix--layout-pr-gone-p (car prs)))
    (should-not (decknix--layout-pr-filtered-p (car prs)))))

(ert-deftest decknix-layout--a-filtered-pr-does-not-raise-the-flag ()
  "A conflicted PR is waiting on its author, so a session sitting on it is
not work the user can act on."
  (let ((prs (list (list :key "r#244" :state "asking" :item nil))))
    (decknix--layout-mark-gone prs t '("r#244"))
    (should-not (decknix--layout-live-pr-keys prs))))

(ert-deftest decknix-layout--without-the-raw-feed-everything-reads-gone ()
  "Degrades to the previous behaviour rather than erroring when no caller
supplies the unfiltered feed."
  (let ((prs (list (list :key "r#1" :state "asking" :item nil))))
    (decknix--layout-mark-gone prs t nil)
    (should (decknix--layout-pr-gone-p (car prs)))))

(ert-deftest decknix-layout--an-actionable-pr-still-raises-the-flag ()
  "The guard must not silence real work."
  (let ((prs (list (list :key "r#2" :state "asking"
                         :item '((number . 2))))))
    (decknix--layout-mark-gone prs t '("r#2"))
    (should (equal '("r#2") (decknix--layout-live-pr-keys prs)))))


;; --- what an observed session claims ---------------------------------
;;
;; Repo-wide claiming gave one session an unrelated upside PR and seven
;; unrelated upside worktrees: it had read AGENTS.md in the primary checkout,
;; and its own upside worktree had since been removed, which the resolver
;; also mapped to the repo.  These go through the real tree, because the old
;; tests checked the helpers in isolation and never the claim.

(defun decknix-layout-test--claims (roots wip-repos worktrees)
  "Return (WT-BRANCHES . PR-NUMBERS) one session observed in ROOTS claims."
  (cl-letf (((symbol-function 'decknix--layout-session-observed-roots)
             (lambda (_s) roots)))
    (let* ((decknix--layout-wip-memo nil)
           (row (car (plist-get (decknix--layout-wip-tree-1
                                 (list '("*s*" nil nil "working" nil))
                                 wip-repos worktrees)
                                :sessions))))
      (cons (mapcar (lambda (w) (plist-get w :branch)) (plist-get row :worktrees))
            (mapcar (lambda (p) (plist-get p :number)) (plist-get row :prs))))))

(defconst decknix-layout-test--upside-wip
  '(((repo . "UpsideRealty/upside")
     (prs . (((number . 20511) (branch . "CONN-1006-extraction-spec"))
             ((number . 20600) (branch . "enhancement/HX-1062-acker"))))))
  "Two of my upside PRs: one unrelated, one on the session's own branch.")

(defconst decknix-layout-test--upside-wts
  '((:repo "upsiderealty/upside" :branch "CONN-1006-extraction-spec"
     :path "/w/upside-worktrees/CONN-1006-extraction-spec")
    (:repo "upsiderealty/upside" :branch "CONN-1080-rectify"
     :path "/w/upside-worktrees/CONN-1080-rectify")))

(ert-deftest decknix-layout--a-primary-checkout-claims-nothing ()
  "Reading AGENTS.md in the primary is not working on the repo."
  (should (equal '(nil . nil)
                 (decknix-layout-test--claims '("/w/upside")
                                              decknix-layout-test--upside-wip
                                              decknix-layout-test--upside-wts))))

(ert-deftest decknix-layout--a-removed-worktree-claims-only-its-own-pr ()
  "Its directory is its branch, so it names one PR and nothing else."
  (should (equal '(nil . (20600))
                 (decknix-layout-test--claims '("/w/upside-worktrees/HX-1062-acker")
                                              decknix-layout-test--upside-wip
                                              decknix-layout-test--upside-wts))))

(ert-deftest decknix-layout--a-live-worktree-claims-itself-and-its-pr-only ()
  (should (equal '(("CONN-1006-extraction-spec") . (20511))
                 (decknix-layout-test--claims '("/w/upside-worktrees/CONN-1006-extraction-spec")
                                              decknix-layout-test--upside-wip
                                              decknix-layout-test--upside-wts))))

(ert-deftest decknix-layout--a-gone-worktree-of-another-repo-claims-nothing-here ()
  "Matching the branch alone would cross repos that reuse a ticket key."
  (should (equal '(nil . nil)
                 (decknix-layout-test--claims '("/w/envoy-worktrees/HX-1062-acker")
                                              decknix-layout-test--upside-wip
                                              decknix-layout-test--upside-wts))))


;; --- a guess must not look like a fact --------------------------------

(ert-deftest decknix-layout--observation-is-evidence ()
  (should (eq 'observed (decknix--layout-claim-provenance
                         '("*a*" nil nil "ready" nil) '("/w/a")))))

(ert-deftest decknix-layout--no-observation-yet-is-pending-not-inferred ()
  "Before the backfill reaches a session, what is shown is a guess that
will be REPLACED.  Saying so is the difference between \"not yet\" and
\"this is all there is\" -- and the silent version is why an association
that was inert for weeks looked like it was working."
  (let ((buf (generate-new-buffer "*p*")))
    (unwind-protect
        (should (eq 'pending (decknix--layout-claim-provenance
                              (list "*p*" nil nil "ready" nil) nil)))
      (kill-buffer buf))))

(ert-deftest decknix-layout--backfilled-with-nothing-found-is-inferred ()
  "The backfill ran and the session has no file activity, so its name is
all there is and will remain all there is."
  (let ((buf (generate-new-buffer "*i*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (setq-local decknix--agent-assoc-backfilled t))
          (should (eq 'inferred (decknix--layout-claim-provenance
                                 (list "*i*" nil nil "ready" nil) nil))))
      (kill-buffer buf))))

(ert-deftest decknix-layout--a-dead-session-buffer-is-not-pending ()
  "Nothing is coming for it, so calling it pending would promise a refresh
that never arrives."
  (should (eq 'inferred (decknix--layout-claim-provenance
                         '("*gone*" nil nil "ready" nil) nil))))

(ert-deftest decknix-layout--each-provenance-has-a-distinct-mark ()
  (let ((marks (mapcar #'decknix--layout-provenance-mark
                       '(observed pending inferred))))
    (should (equal marks (delete-dups (copy-sequence marks))))))

(ert-deftest decknix-layout--only-observed-claims-get-the-full-face ()
  "A guess must not compete visually with what the sidebar knows."
  (should (eq 'default (decknix--layout-provenance-face 'observed)))
  (dolist (p '(pending inferred))
    (should-not (eq 'default (decknix--layout-provenance-face p)))))

(ert-deftest decknix-layout--the-heading-counts-the-guesses ()
  "Measured live: 6 of 9 sessions were guessing from tags, and the display
gave no hint which."
  (should (= 2 (decknix--layout-inferred-count
                '((:provenance observed) (:provenance inferred)
                  (:provenance pending))))))

(ert-deftest decknix-layout--nothing-inferred-counts-zero ()
  (should (= 0 (decknix--layout-inferred-count
                '((:provenance observed) (:provenance observed))))))


;; --- the WIP tree is not rebuilt on every paint -----------------------

(ert-deftest decknix-layout--wip-tree-reuses-on-identical-input ()
  "Measured at 96.6 ms a call with a GC on EVERY call -- the next largest
cost on a repaint that averaged 833 ms."
  (let ((decknix--layout-wip-memo nil))
    (let ((a (decknix--layout-wip-tree nil nil nil))
          (b (decknix--layout-wip-tree nil nil nil)))
      (should (eq a b)))))

(ert-deftest decknix-layout--wip-tree-rebuilds-when-a-worktree-appears ()
  (let ((decknix--layout-wip-memo nil))
    (let ((a (decknix--layout-wip-tree nil nil nil))
          (b (decknix--layout-wip-tree nil nil '((:path "/w/a" :branch "b")))))
      (should-not (eq a b)))))

(ert-deftest decknix-layout--wip-tree-rebuilds-when-a-worktree-goes-dirty ()
  "Dirty drives the glyph and the colour, so reusing here would show clean
work that has uncommitted changes."
  (let ((decknix--layout-wip-memo nil))
    (let ((a (decknix--layout-wip-tree nil nil '((:path "/w/a" :branch "b"))))
          (b (decknix--layout-wip-tree nil nil
                                       '((:path "/w/a" :branch "b" :dirty t)))))
      (should-not (eq a b)))))

(ert-deftest decknix-layout--wip-tree-rebuilds-when-observation-arrives ()
  "The backfill lands asynchronously.  A tree reused across that change
would keep showing the TAG guess after the evidence had arrived -- which
is the failure the provenance marks exist to make visible."
  (let ((decknix--layout-wip-memo nil)
        (observed nil))
    (cl-letf (((symbol-function 'decknix--layout-session-observed-roots)
               (lambda (_s) observed)))
      (let* ((sess (list (decknix-layout-test--session "s" "ready" '("r#1"))))
             (a (decknix--layout-wip-tree sess nil nil)))
        (setq observed '("/w/a"))
        (should-not (eq a (decknix--layout-wip-tree sess nil nil)))))))

(ert-deftest decknix-layout--wip-tree-rebuilds-when-a-session-changes-state ()
  (let ((decknix--layout-wip-memo nil))
    (let ((a (decknix--layout-wip-tree
              (list (decknix-layout-test--session "s" "ready" '("r#1"))) nil nil))
          (b (decknix--layout-wip-tree
              (list (decknix-layout-test--session "s" "asking" '("r#1"))) nil nil)))
      (should-not (eq a b)))))

(ert-deftest decknix-layout--invalidating-wip-forces-a-rebuild ()
  (let ((decknix--layout-wip-memo nil))
    (let ((a (decknix--layout-wip-tree nil nil nil)))
      (decknix-layout-invalidate-wip)
      (should-not (eq a (decknix--layout-wip-tree nil nil nil))))))


;; --- the Reviews section says what is in it ---------------------------

(ert-deftest decknix-layout--a-repo-with-prs-waiting-is-not-inert ()
  "Every row rendered `default\=' unless a session was blocked, so five
repos holding eight bot PRs awaiting review looked like nothing at all."
  (should (eq 'new (decknix--layout-group-state
                    '(:repo "r" :uncovered 3 :sessions 0 :asking 0))))
  (should-not (eq 'default (decknix--layout-group-face
                            '(:repo "r" :uncovered 3)))))

(ert-deftest decknix-layout--a-blocked-pr-makes-its-repo-red ()
  "Changes requested or a conflict means something in there cannot move."
  (dolist (item '(((review_decision . "CHANGES_REQUESTED"))
                  ((mergeable . "CONFLICTING"))))
    (should (eq 'blocked (decknix--layout-group-state
                          (list :prs (list (list :item item))))))))

(ert-deftest decknix-layout--a-session-blocked-on-me-outranks-the-rest ()
  (should (eq 'asking (decknix--layout-group-state
                       '(:asking 1 :uncovered 2
                         :prs ((:item ((review_decision . "CHANGES_REQUESTED")))))))))

(ert-deftest decknix-layout--a-repo-merely-being-worked-is-amber-not-green ()
  (should (eq 'doing (decknix--layout-group-state
                      '(:sessions 2 :doing 2 :asking 0 :uncovered 0)))))

(ert-deftest decknix-layout--an-empty-repo-has-no-state ()
  (should-not (decknix--layout-group-state '(:repo "r"))))

(ert-deftest decknix-layout--each-group-state-has-its-own-face ()
  (let ((faces (mapcar #'decknix--layout-group-face
                       '((:asking 1) (:prs ((:item ((mergeable . "CONFLICTING")))))
                         (:uncovered 1) (:sessions 1)))))
    (should (equal faces (delete-dups (copy-sequence faces))))))

(provide 'decknix-sidebar-layout-test)
;;; decknix-sidebar-layout-test.el ends here
