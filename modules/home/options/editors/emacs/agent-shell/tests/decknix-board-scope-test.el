;;; decknix-board-scope-test.el --- Board repository scope and sidebar focus -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-board "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; A board confined to repositories: pattern matching, the membership
;; modes, fetching several repositories (and expanding patterns) from
;; recorded `gh' output, and linking cached PRs to items.  Subprocesses
;; go through a recorder; nothing reaches GitHub.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-board)
(require 'decknix-board-fixture)

(defvar decknix--hub-worktree-clone-map nil)
(defvar decknix--hub-worktree-cache nil)
(defvar decknix--hub-reviews nil)
(defvar decknix--hub-wip nil)

(defmacro decknix-board-scope-test-recorder (responses &rest body)
  "Run BODY with subprocesses recorded in `calls', answered from RESPONSES.
RESPONSES is a function (ARGV) returning (EXIT STDOUT STDERR)."
  (declare (indent 1))
  `(let* ((calls nil)
          (answer ,responses)
          (decknix-board-process-function
           (lambda (argv callback)
             (setq calls (append calls (list argv)))
             (apply callback (funcall answer argv)))))
     ,@body))

(defmacro decknix-board-scope-test-isolated (&rest body)
  "Run BODY with empty expansion and path caches."
  `(let ((decknix-board-scope--owner-repos (make-hash-table :test 'equal))
         (decknix-board--path-memo (make-hash-table :test 'equal))
         (decknix-board--path-memo-at (float-time))
         (decknix-board--known-items (make-hash-table :test 'equal)))
     ,@body))

(defun decknix-board-scope-test--session (name tags &optional state ws prs)
  (list name tags prs (or state "idle") ws "ck"))

(defconst decknix-board-scope-test--api-ndjson
  (mapconcat
   #'identity
   '("{\"assignees\":[],\"body\":\"\",\"id\":\"I_api01\",\"issueType\":null,\"labels\":[\"type:story\"],\"number\":4,\"parent\":2,\"parentRepo\":\"acme/hack-boards\",\"prs\":[],\"state\":\"OPEN\",\"subDone\":0,\"subTotal\":0,\"title\":\"API for the tree\",\"url\":\"https://github.com/acme/hack-api/issues/4\"}"
     "{\"assignees\":[],\"body\":\"\",\"id\":\"I_api02\",\"issueType\":null,\"labels\":[\"type:task\"],\"number\":9,\"parent\":4,\"parentRepo\":\"acme/hack-api\",\"prs\":[],\"state\":\"OPEN\",\"subDone\":0,\"subTotal\":0,\"title\":\"Endpoint\",\"url\":\"https://github.com/acme/hack-api/issues/9\"}")
   "\n")
  "Shaped issues of acme/hack-api: #4 is a sub-issue of acme/hack-boards#2.")

(defconst decknix-board-scope-test--board
  '(:name "hack" :title "Hack" :goal "Ship boards"
    :tags-all ("hackathon") :repos ("acme/hack-*")
    :backend github
    :github (:repo "acme/hack-boards" :root 1 :label-prefix "type:")))

;; --- patterns ------------------------------------------------------------

(ert-deftest decknix-board-scope-test-exact-match-ignores-case ()
  (should (decknix-board-repo-match-p "UpsideRealty/upside" "upsiderealty/upside"))
  (should-not (decknix-board-repo-match-p "UpsideRealty/upside" "UpsideRealty/upside-x"))
  ;; A bare name, from a directory, matches on the name part.
  (should (decknix-board-repo-match-p "UpsideRealty/upside" "upside"))
  (should-not (decknix-board-repo-match-p "UpsideRealty/upside" "nurturecloud"))
  (should-not (decknix-board-repo-match-p "UpsideRealty/upside" nil)))

(ert-deftest decknix-board-scope-test-glob-match ()
  (should (decknix-board-repo-match-p "UpsideRealty/hack-*" "UpsideRealty/hack-api"))
  (should-not (decknix-board-repo-match-p "UpsideRealty/hack-*" "Other/hack-api"))
  (should (decknix-board-repo-match-p "*/followupboss-*" "UpsideRealty/followupboss-integration"))
  (should (decknix-board-repo-match-p "*/followupboss-*" "followupboss-integration"))
  (should-not (decknix-board-repo-match-p "*/followupboss-*" "UpsideRealty/upside"))
  (should (decknix-board-repo-match-p "acme/hack-?" "acme/hack-1")))

(ert-deftest decknix-board-scope-test-regexp-match-is-anchored ()
  (let ((e '(:regexp "nc-helix/.*-cli")))
    (should (decknix-board-repo-match-p e "nc-helix/platform-cli"))
    (should-not (decknix-board-repo-match-p e "nc-helix/platform-cli-old"))
    (should-not (decknix-board-repo-match-p e "x-nc-helix/platform-cli"))
    ;; A bare name needs an owner to try the regexp against.
    (should-not (decknix-board-repo-match-p e "platform-cli"))
    (should (decknix-board-repo-match-p e "platform-cli" '("nc-helix")))))

(ert-deftest decknix-board-scope-test-scope-defaults-to-issue-home ()
  (let ((b '(:github (:repo "acme/home"))))
    (should (equal (decknix-board-scope b) '("acme/home")))
    (should-not (decknix-board-scope-explicit-p b))
    (should (decknix-board-repo-in-scope-p b "acme/home"))
    (should-not (decknix-board-repo-in-scope-p b "acme/other"))))

(ert-deftest decknix-board-scope-test-owners-and-exact ()
  (let ((b '(:repos ("UpsideRealty/upside" "*/followupboss-*" "nc-helix/hack-*"
                     (:regexp "x/y"))
             :github (:repo "acme/home"))))
    (should (equal (decknix-board-scope-owners b) '("acme" "upsiderealty" "nc-helix")))
    (should (equal (decknix-board-scope-exact b) '("UpsideRealty/upside")))))

(ert-deftest decknix-board-scope-test-parse-wizard-repos ()
  (should-not (decknix-board-parse-repos "acme/home" "acme/home"))
  (should-not (decknix-board-parse-repos "" "acme/home"))
  (should (equal (decknix-board-parse-repos "acme/home, acme/hack-*,/nc-helix\\/.*/" "acme/home")
                 '("acme/home" "acme/hack-*" (:regexp "nc-helix\\/.*")))))

;; --- where sessions are --------------------------------------------------

(ert-deftest decknix-board-scope-test-path-repos-from-caches ()
  (decknix-board-scope-test-isolated
   (let ((decknix--hub-worktree-clone-map (make-hash-table :test 'equal))
         (decknix--hub-worktree-cache (make-hash-table :test 'equal)))
     (puthash "/c/upside/" "upsiderealty/upside" decknix--hub-worktree-clone-map)
     (puthash "upsiderealty/followupboss-integration"
              '(:primary "/c/followupboss-integration"
                :worktrees (("HX-1" . "/c/followupboss-integration-worktrees/HX-1")))
              decknix--hub-worktree-cache)
     (should (equal (decknix-board-path-repos "/c/upside") '("upsiderealty/upside")))
     (should (equal (decknix-board-path-repos "/c/followupboss-integration-worktrees/HX-1/src")
                    '("upsiderealty/followupboss-integration")))
     ;; Neither cache knows it: the layout names the repository.
     (should (equal (decknix-board-path-repos "/c/address-normaliser-worktrees/HX-9")
                    '("address-normaliser")))
     (should (equal (decknix-board-path-repos "/c/reapit-service") '("reapit-service"))))))

(ert-deftest decknix-board-scope-test-session-repos ()
  (decknix-board-scope-test-isolated
   (should (equal (decknix-board-session-repos
                   (decknix-board-scope-test--session "s" nil nil "/c/upside-worktrees/x"
                                                      '("followupboss-integration#12")))
                  '("followupboss-integration" "upside")))))

;; --- membership ----------------------------------------------------------

(defun decknix-board-scope-test--in-p (board session repos)
  "Is SESSION on BOARD when it works in REPOS?"
  (let ((decknix-board-session-repos-function (lambda (_s) repos)))
    (decknix-board-scope-test-isolated
     (decknix-board-session-in-board-p board session))))

(ert-deftest decknix-board-scope-test-membership-modes ()
  (let* ((base '(:name "p" :tags-any ("bramlett") :repos ("UpsideRealty/upside")
                 :github (:repo "UpsideRealty/followupboss-integration")))
         (tagged (decknix-board-scope-test--session "t" '("bramlett")))
         (other (decknix-board-scope-test--session "o" '("misc"))))
    (cl-flet ((in (mode s repos)
                (decknix-board-scope-test--in-p (append (list :match mode) base) s repos)))
      ;; either (the default): tags, or a repository in scope.
      (should (decknix-board-scope-test--in-p base tagged nil))
      (should (decknix-board-scope-test--in-p base other '("upsiderealty/upside")))
      (should-not (decknix-board-scope-test--in-p base other '("upsiderealty/other")))
      ;; tags: the repository does not count.
      (should (in 'tags tagged nil))
      (should-not (in 'tags other '("upsiderealty/upside")))
      ;; repos: the tags do not count.
      (should-not (in 'repos tagged nil))
      (should (in 'repos other '("upside")))
      ;; both: tags and repository.
      (should-not (in 'both tagged nil))
      (should-not (in 'both other '("upsiderealty/upside")))
      (should (in 'both tagged '("upsiderealty/upside"))))))

(ert-deftest decknix-board-scope-test-either-without-repos-is-the-tag-rule ()
  "The issue home alone must not pull in every session working in it."
  (let ((b '(:name "h" :tags-all ("hackathon") :github (:repo "UpsideRealty/upside"))))
    (should-not (decknix-board-scope-test--in-p
                 b (decknix-board-scope-test--session "o" '("x")) '("upsiderealty/upside")))
    ;; Asking for repositories explicitly uses the home as the scope.
    (should (decknix-board-scope-test--in-p
             (append '(:match repos) b) (decknix-board-scope-test--session "o" '("x"))
             '("upsiderealty/upside")))))

(ert-deftest decknix-board-scope-test-both-without-tags-is-the-repo-rule ()
  (let ((b '(:name "r" :match both :repos ("acme/a") :github (:repo "acme/a"))))
    (should (decknix-board-scope-test--in-p b (decknix-board-scope-test--session "s" nil)
                                            '("acme/a")))))

(ert-deftest decknix-board-scope-test-exclude-tags-win ()
  (let ((b '(:name "e" :tags-any ("bramlett") :exclude-tags ("archived")
             :github (:repo "acme/a"))))
    (should-not (decknix-board-scope-test--in-p
                 b (decknix-board-scope-test--session "s" '("bramlett" "archived")) nil))
    (should-not (decknix-board-scope-test--in-p
                 b (decknix-board-scope-test--session "s" '("a#3" "archived")) nil))))

(ert-deftest decknix-board-scope-test-a-tag-naming-a-scope-repo-places-a-session ()
  (let ((b '(:name "u" :match repos
             :repos ("UpsideRealty/followupboss-integration" "UpsideRealty/upside")
             :github (:repo "UpsideRealty/followupboss-integration"))))
    (should (decknix-board-scope-test--in-p
             b (decknix-board-scope-test--session "s" '("followupboss")) nil))
    ;; Too short to name a repository.
    (should-not (decknix-board-scope-test--in-p
                 b (decknix-board-scope-test--session "s" '("us")) nil))))

;; --- fetching several repositories ---------------------------------------

(defun decknix-board-scope-test--gh (argv)
  "Answer ARGV as GitHub would for the acme fixtures."
  (cond
   ((equal (seq-take argv 3) '("gh" "repo" "list"))
    (list 0 "acme/hack-boards\nacme/hack-api\nacme/website\n" ""))
   ((member "name=hack-boards" argv) (list 0 decknix-board-test-github-ndjson ""))
   ((member "name=hack-api" argv) (list 0 decknix-board-scope-test--api-ndjson ""))
   (t (list 1 "" "gh: Could not resolve to a Repository"))))

(ert-deftest decknix-board-scope-test-list-argv-per-repo ()
  (let ((argv (decknix-board-github--list-argv decknix-board-scope-test--board t nil
                                               "acme/hack-api")))
    (should (member "owner=acme" argv))
    (should (member "name=hack-api" argv))
    (should (seq-some (lambda (a) (string-search "parent{number repository{nameWithOwner}}" a))
                      argv))))

(ert-deftest decknix-board-scope-test-expands-patterns-once-then-caches ()
  (decknix-board-scope-test-isolated
   (decknix-board-scope-test-recorder #'decknix-board-scope-test--gh
     (let (result)
       (decknix-board-backend-list-items 'github decknix-board-scope-test--board
                                         (lambda (r) (setq result r)))
       (should (equal (car calls)
                      '("gh" "repo" "list" "acme" "--limit" "1000" "--no-archived"
                        "--json" "nameWithOwner" "--jq" ".[].nameWithOwner")))
       ;; The home first, then the pattern's matches; website is not hack-*.
       (should (equal (plist-get (cdr result) :repos) '("acme/hack-boards" "acme/hack-api")))
       (should (= 3 (length calls)))
       (should (= 10 (length (car result))))
       (should-not (plist-get (cdr result) :warning))
       (setq calls nil)
       (decknix-board-backend-list-items 'github decknix-board-scope-test--board #'ignore)
       (should-not (seq-some (lambda (c) (member "list" c)) calls))
       (should (= 2 (length calls)))))))

(ert-deftest decknix-board-scope-test-exact-repos-need-no-listing ()
  (decknix-board-scope-test-isolated
   (decknix-board-scope-test-recorder #'decknix-board-scope-test--gh
     (decknix-board-backend-list-items
      'github '(:name "x" :repos ("acme/hack-api") :github (:repo "acme/hack-boards"))
      #'ignore)
     (should (equal (mapcar (lambda (c) (seq-find (lambda (a) (string-prefix-p "name=" a)) c))
                            calls)
                    '("name=hack-boards" "name=hack-api"))))))

(ert-deftest decknix-board-scope-test-repo-cap ()
  (decknix-board-scope-test-isolated
   (let ((decknix-board-github-max-repos 2))
     (should (equal (decknix-board-github-concrete-repos
                     '(:repos ("a/one" "a/two" "a/three") :github (:repo "a/home")))
                    '("a/home" "a/one"))))))

(ert-deftest decknix-board-scope-test-merge-keys-and-cross-repo-parents ()
  (decknix-board-scope-test-isolated
   (decknix-board-scope-test-recorder #'decknix-board-scope-test--gh
     (let (result)
       (decknix-board-backend-list-items 'github decknix-board-scope-test--board
                                         (lambda (r) (setq result r)))
       (let* ((items (car result))
              (api4 (decknix-board--find items "acme/hack-api#4"))
              (home4 (decknix-board--find items "acme/hack-boards#4")))
         (should api4)
         (should home4)
         (should (plist-get api4 :foreign))
         (should-not (plist-get home4 :foreign))
         (should (equal (plist-get api4 :parent-key) "acme/hack-boards#2"))
         (should (equal (decknix-board-item-tag decknix-board-scope-test--board api4)
                        "hack-api#4"))
         (should (equal (decknix-board-item-tag decknix-board-scope-test--board home4)
                        "hack-boards#4"))
         ;; The cross-repository sub-issue nests under its parent.
         (let* ((tree (decknix-board-board-tree decknix-board-scope-test--board items
                                                (cdr result)))
                (epic (seq-find (lambda (n) (eql 2 (plist-get (car n) :number)))
                                (cdr (car (plist-get tree :nodes))))))
           (should (member "acme/hack-api#4"
                           (mapcar (lambda (n) (decknix-board-item-key (car n))) (cdr epic))))))))))

(ert-deftest decknix-board-scope-test-partial-failure-is-a-warning ()
  (decknix-board-scope-test-isolated
   (decknix-board-scope-test-recorder #'decknix-board-scope-test--gh
     (let (result)
       (decknix-board-backend-list-items
        'github '(:name "x" :repos ("acme/gone") :github (:repo "acme/hack-boards"))
        (lambda (r) (setq result r)))
       (should (= 8 (length (car result))))
       (should-not (plist-get (cdr result) :error))
       (should (string-match-p "acme/gone: gh: Could not resolve"
                               (plist-get (cdr result) :warning)))))))

(ert-deftest decknix-board-scope-test-total-failure-is-an-error ()
  (decknix-board-scope-test-isolated
   (decknix-board-scope-test-recorder (lambda (_argv) (list 1 "" "auth required"))
     (let (result)
       (decknix-board-backend-list-items 'github '(:name "x" :github (:repo "acme/a"))
                                         (lambda (r) (setq result r)))
       (should-not (car result))
       (should (string-match-p "auth required" (plist-get (cdr result) :error)))))))

;; --- sessions on multi-repository items ----------------------------------

(defun decknix-board-scope-test--items ()
  (append
   (decknix-board-github-parse decknix-board-test-github-ndjson "type:" "acme/hack-boards")
   (mapcar (lambda (i) (append i (list :foreign t)))
           (decknix-board-github-parse decknix-board-scope-test--api-ndjson "type:"
                                       "acme/hack-api"))))

(ert-deftest decknix-board-scope-test-item-tags-per-repo ()
  (let* ((items (decknix-board-scope-test--items))
         (g (decknix-board-group-sessions
             decknix-board-scope-test--board
             (list (decknix-board-scope-test--session "home" '("hackathon" "#4"))
                   (decknix-board-scope-test--session "api" '("hack-api#4"))
                   (decknix-board-scope-test--session "both" '("hack-boards#4" "hack-api#9")))
             items)))
    (should (equal (mapcar #'car (decknix-board-item-sessions "acme/hack-boards#4" g))
                   '("home" "both")))
    (should (equal (mapcar #'car (decknix-board-item-sessions "acme/hack-api#4" g)) '("api")))
    (should (equal (mapcar #'car (decknix-board-item-sessions "acme/hack-api#9" g)) '("both")))))

;; --- PRs from the cached feeds -------------------------------------------

(ert-deftest decknix-board-scope-test-feed-prs-read-both-feeds ()
  (let ((decknix--hub-reviews '((items . (((repo . "acme/hack-api") (number . 30)
                                           (title . "Endpoint (hack-api#9)")
                                           (url . "u30"))))))
        (decknix--hub-wip '((repos . (((repo . "acme/hack-boards")
                                       (prs . (((number . 31) (title . "Tree")
                                                (branch . "4-render-tree") (url . "u31"))))))))))
    (should (equal (mapcar (lambda (p) (list (plist-get p :repo) (plist-get p :number)
                                             (plist-get p :source)))
                           (decknix-board-feed-prs))
                   '(("acme/hack-api" 30 review) ("acme/hack-boards" 31 mine))))))

(ert-deftest decknix-board-scope-test-link-prs ()
  (let* ((items (decknix-board-scope-test--items))
         (prs (list '(:repo "acme/hack-api" :number 30 :title "Endpoint (hack-api#9)" :url "u30")
                    '(:repo "acme/hack-boards" :number 31 :title "Tree" :branch "4-render-tree"
                      :url "u31")
                    ;; The draft PR GitHub already links to #4.
                    '(:repo "acme/hack-boards" :number 20 :title "wip"
                      :url "https://github.com/acme/hack-boards/pull/20")
                    '(:repo "acme/hack-boards" :number 32 :title "Fixes #40" :url "u32")
                    '(:repo "acme/website" :number 33 :title "#4" :url "u33")))
         (links (decknix-board-link-prs decknix-board-scope-test--board items prs))
         (by (plist-get links :by-item)))
    (should (equal (mapcar (lambda (p) (plist-get p :number))
                           (alist-get "acme/hack-api#9" by nil nil #'equal))
                   '(30)))
    (should (equal (mapcar (lambda (p) (plist-get p :number))
                           (alist-get "acme/hack-boards#4" by nil nil #'equal))
                   '(31 20)))
    ;; #40 is not #4; a PR outside the scope is not shown at all.
    (should (equal (mapcar (lambda (p) (plist-get p :number)) (plist-get links :prs))
                   '(30 31 20 32)))
    (should-not (plist-get (car (last (plist-get links :prs))) :items))))

(ert-deftest decknix-board-scope-test-draw-shows-scope-and-open-prs ()
  (with-temp-buffer
    (decknix-board-mode)
    (setq decknix-board--board decknix-board-scope-test--board
          decknix-board--items (decknix-board-scope-test--items)
          decknix-board--meta '(:hierarchy t :repos ("acme/hack-boards" "acme/hack-api"))
          decknix-board--fetched-at (current-time))
    (cl-letf (((symbol-function 'decknix-board-live-sessions) (lambda () nil)))
      (decknix-board--draw
       nil (list '(:repo "acme/hack-api" :number 30 :title "Endpoint (hack-api#9)" :url "u30"
                   :source review)))
      (let ((text (buffer-string)))
        (should (string-match-p "Repos: acme/hack-\\*   (2 read)   match either" text))
        (should (string-match-p "hack-api#4 API for the tree" text))
        (should (string-match-p "Endpoint  PR hack-api#30" text))
        (should (string-match-p "Open PRs (1)" text))
        (should (string-match-p "hack-api#30 Endpoint (hack-api#9)  -> hack-api#9" text))))))

(provide 'decknix-board-scope-test)
;;; decknix-board-scope-test.el ends here
