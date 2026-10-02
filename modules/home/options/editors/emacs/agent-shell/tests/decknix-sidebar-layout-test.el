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
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions
                                                 decknix-layout-test--items))
         (upside (seq-find (lambda (g) (equal "upside" (plist-get g :repo))) groups)))
    ;; three distinct sessions touch upside, two of them blocked
    (should (= 3 (plist-get upside :sessions)))
    (should (= 2 (plist-get upside :asking)))))

(ert-deftest decknix-layout--groups-sort-by-attention-then-sessions ()
  "A repo with a blocked session outranks a busier but quiet one."
  (let ((groups (decknix--layout-review-groups
                 (list (decknix-layout-test--session "a" "ready" '("quiet#1"))
                       (decknix-layout-test--session "b" "ready" '("quiet#2"))
                       (decknix-layout-test--session "c" "asking" '("loud#9")))
                 nil)))
    (should (equal '("loud" "quiet") (mapcar (lambda (g) (plist-get g :repo)) groups)))))

(ert-deftest decknix-layout--group-label-shows-distinct-session-count ()
  "The header count must match what expanding the group reveals."
  (let* ((groups (decknix--layout-review-groups decknix-layout-test--sessions nil))
         (g (seq-find (lambda (x) (equal "oneroof-integration" (plist-get x :repo)))
                      groups)))
    (should (string-match-p " 1\\'" (string-trim-right
                                    (decknix--layout-group-label g 48))))))

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

(ert-deftest decknix-layout--filled-glyph-means-wants-you ()
  (dolist (s '("asking" "waiting" "netfail"))
    (should (equal "●" (decknix--layout-state-glyph s))))
  (should (equal "○" (decknix--layout-state-glyph "ready")))
  (should (equal "·" (decknix--layout-state-glyph nil))))

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
  (let ((label (decknix--layout-group-label
                '(:repo "r" :sessions 2 :asking 0 :uncovered 0) 48)))
    (should (string-match-p "●" label))
    (should (string-match-p "2" label))
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

(ert-deftest decknix-layout--dormant-groups-by-repo ()
  (let* ((tree (decknix--layout-wip-tree nil decknix-layout-test--wip-repos
                                         decknix-layout-test--worktrees))
         (groups (decknix--layout-dormant-by-repo (plist-get tree :dormant))))
    (should (equal '("decknix" "platform-cli" "upside")
                   (mapcar (lambda (g) (plist-get g :repo)) groups)))))

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
  "The first four are copied from `decknix--hub-request-session-faces' so a
colour cannot mean one thing in the sidebar and another on a Request row."
  (dolist (state '("netfail" "waiting" "asking" "working"))
    (should (plist-get (decknix--layout-state-face state) :foreground))))

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
  (let* ((rows (list (list :repos (list (list :repo "upside")))
                     (list :repos (list (list :repo "upside")))))
         (out (decknix--layout-dedup-claims rows)))
    (should-not (plist-get (car (plist-get (nth 0 out) :repos)) :duplicate))
    (should (plist-get (car (plist-get (nth 1 out) :repos)) :duplicate))))

(ert-deftest decknix-layout--the-duplicate-claim-is-kept-not-dropped ()
  "The sharing is worth stating; the render collapses it to one line
rather than hiding that two sessions are on the same repo."
  (let* ((rows (list (list :repos (list (list :repo "upside")))
                     (list :repos (list (list :repo "upside")))))
         (out (decknix--layout-dedup-claims rows)))
    (should (= 1 (length (plist-get (nth 1 out) :repos))))))

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
  (let* ((rows (list (list :repos (list (list :repo "upside")))
                     (list :repos (list (list :repo "upside"))))))
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

(provide 'decknix-sidebar-layout-test)
;;; decknix-sidebar-layout-test.el ends here
