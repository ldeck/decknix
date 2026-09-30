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
    ;; Order is attention first (upside 2, metabase 1), then session count
    ;; (oneroof 1 > dapi 0) -- not alphabetical and not raw session count.
    (should (equal '("upside" "metabase" "oneroof-integration" "dapi-contracts")
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

(provide 'decknix-sidebar-layout-test)
;;; decknix-sidebar-layout-test.el ends here
