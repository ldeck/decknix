;;; decknix-board-test.el --- Tests for coordination boards -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-board "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Definitions on disk, session grouping, the item tag convention, the
;; tree built from a recorded GitHub fetch and its flat fallback, the
;; exact commands a create runs, and the confirmation gates in front of
;; every external write.  Subprocesses are replaced by a recorder; no
;; test reaches GitHub or Slack.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-board)
(require 'decknix-board-fixture)

(defconst decknix-board-test--board
  '(:name "hack" :title "Hack" :goal "Ship boards"
    :tags-all ("hackathon") :tags-any nil :workspace nil
    :slack-channel "C0123ABCD" :backend github
    :github (:repo "acme/hack-boards" :root 1 :label-prefix "type:")))

(defun decknix-board-test--items ()
  (decknix-board-github-parse decknix-board-test-github-ndjson "type:"))

(defun decknix-board-test--item (n)
  (seq-find (lambda (i) (eql (plist-get i :number) n)) (decknix-board-test--items)))

(defmacro decknix-board-test-with-recorder (responses &rest body)
  "Run BODY with subprocesses recorded in `calls'.
RESPONSES is a list of (EXIT STDOUT STDERR), answered in order; the last
repeats."
  (declare (indent 1))
  `(let* ((calls nil)
          (responses ,responses)
          (decknix-board-process-function
           (lambda (argv callback)
             (setq calls (append calls (list argv)))
             (let ((r (if (cdr responses) (pop responses) (car responses))))
               (apply callback r)))))
     ,@body))

;; --- definitions ---------------------------------------------------------

(ert-deftest decknix-board-test-definition-round-trip ()
  (let ((decknix-board-directory (make-temp-file "boards" t)))
    (unwind-protect
        (progn
          (decknix-board-write decknix-board-test--board)
          (should (equal (decknix-board-names) '("hack")))
          (should (equal (decknix-board-read "hack") decknix-board-test--board)))
      (delete-directory decknix-board-directory t))))

(ert-deftest decknix-board-test-read-defaults-name-and-backend ()
  (let ((decknix-board-directory (make-temp-file "boards" t)))
    (unwind-protect
        (progn
          (with-temp-file (decknix-board-definition-file "bare")
            (insert "(:title \"Bare\" :github (:repo \"a/b\"))"))
          (let ((board (decknix-board-read "bare")))
            (should (equal (plist-get board :name) "bare"))
            (should (eq (plist-get board :backend) 'github))))
      (delete-directory decknix-board-directory t))))

(ert-deftest decknix-board-test-valid-name ()
  (should (decknix-board-valid-name-p "hack-2026"))
  (should-not (decknix-board-valid-name-p "Hack"))
  (should-not (decknix-board-valid-name-p "../x"))
  (should-not (decknix-board-valid-name-p "")))

;; --- grouping and the tag convention -------------------------------------

(defun decknix-board-test--session (name tags &optional state ws)
  (list name tags nil (or state "idle") ws "ck"))

(ert-deftest decknix-board-test-item-tag-uses-repo-name ()
  (should (equal (decknix-board-item-tag decknix-board-test--board
                                         (decknix-board-test--item 4))
                 "hack-boards#4")))

(ert-deftest decknix-board-test-session-in-board-by-tags ()
  (let ((b decknix-board-test--board))
    (should (decknix-board-session-in-board-p
             b (decknix-board-test--session "a" '("hackathon" "x"))))
    (should-not (decknix-board-session-in-board-p
                 b (decknix-board-test--session "b" '("other"))))
    ;; The repo-qualified item tag claims a session on its own.
    (should (decknix-board-session-in-board-p
             b (decknix-board-test--session "c" '("hack-boards#4"))))
    ;; A bare #4 does not: it could be any board's.
    (should-not (decknix-board-session-in-board-p
                 b (decknix-board-test--session "d" '("#4"))))))

(ert-deftest decknix-board-test-session-in-board-tags-any-and-workspace ()
  (let ((b '(:name "w" :tags-any ("red" "blue") :workspace "/work/hack"
             :github (:repo "a/b"))))
    (should (decknix-board-session-in-board-p
             b (decknix-board-test--session "a" '("blue") nil "/work/hack/sub")))
    (should-not (decknix-board-session-in-board-p
                 b (decknix-board-test--session "b" '("blue") nil "/work/other")))
    (should-not (decknix-board-session-in-board-p
                 b (decknix-board-test--session "c" '("green") nil "/work/hack")))
    ;; /work/hackathon is not under /work/hack.
    (should-not (decknix-board-session-in-board-p
                 b (decknix-board-test--session "d" '("red") nil "/work/hackathon")))))

(ert-deftest decknix-board-test-board-without-criteria-claims-nothing ()
  (let ((b '(:name "empty" :github (:repo "a/b"))))
    (should-not (decknix-board-session-in-board-p
                 b (decknix-board-test--session "a" '("anything") nil "/x")))))

(ert-deftest decknix-board-test-item-numbers ()
  (let ((b decknix-board-test--board))
    (should (equal (decknix-board-session-item-numbers
                    b (decknix-board-test--session "a" '("hackathon" "#4" "other#9")))
                   '(4)))
    (should (equal (decknix-board-session-item-numbers
                    b (decknix-board-test--session "b" '("hack-boards#5")))
                   '(5)))
    ;; Outside the board, a bare #4 means nothing.
    (should-not (decknix-board-session-item-numbers
                 b (decknix-board-test--session "c" '("#4"))))))

(ert-deftest decknix-board-test-group-sessions ()
  (let* ((s1 (decknix-board-test--session "one" '("hackathon" "#4") "asking"))
         (s2 (decknix-board-test--session "two" '("hack-boards#4")))
         (s3 (decknix-board-test--session "three" '("hackathon")))
         (s4 (decknix-board-test--session "four" '("elsewhere")))
         (s5 (decknix-board-test--session "five" '("hackathon" "#99")))
         (g (decknix-board-group-sessions decknix-board-test--board
                                          (list s1 s2 s3 s4 s5)
                                          (decknix-board-test--items))))
    (should (equal (mapcar #'car (plist-get g :board)) '("one" "two" "three" "five")))
    (should (equal (mapcar #'car (alist-get 4 (plist-get g :by-item))) '("one" "two")))
    ;; #99 is not an item, so that session is on no item.
    (should (equal (mapcar #'car (plist-get g :unassigned)) '("three" "five")))))

(ert-deftest decknix-board-test-session-tags ()
  (should (equal (decknix-board-session-tags decknix-board-test--board
                                             (decknix-board-test--item 4))
                 '("hackathon" "hack-boards#4")))
  (should (equal (decknix-board-session-tags
                  '(:name "x" :tags-any ("red" "blue") :github (:repo "a/b"))
                  '(:number 3))
                 '("red" "b#3"))))

;; --- parsing and the tree ------------------------------------------------

(ert-deftest decknix-board-test-parse-fixture ()
  (let ((items (decknix-board-test--items)))
    (should (= (length items) 8))
    (let ((story (decknix-board-test--item 4)))
      (should (equal (plist-get story :type) "story"))
      (should (equal (plist-get story :state) "open"))
      (should (eql (plist-get story :parent) 2))
      (should (equal (plist-get story :assignees) '("ldeck" "ye")))
      (should (equal (plist-get story :prs)
                     '((:number 20 :url "https://github.com/acme/hack-boards/pull/20"
                        :state "open" :draft t)))))
    (should (equal (plist-get (decknix-board-test--item 5) :state) "closed"))
    ;; No type label: GitHub's own issue type stands in.
    (should (equal (plist-get (decknix-board-test--item 7) :type) "feature"))
    (should (equal (plist-get (decknix-board-test--item 1) :id) "I_kwDOAAAA01"))))

(ert-deftest decknix-board-test-parse-skips-garbage-lines ()
  (should (= 1 (length (decknix-board-github-parse
                        "not json\n{\"number\":3,\"title\":\"t\",\"labels\":[]}\n" "type:")))))

(defun decknix-board-test--shape (node)
  (cons (plist-get (car node) :number) (mapcar #'decknix-board-test--shape (cdr node))))

(ert-deftest decknix-board-test-tree-under-root ()
  (let ((tree (decknix-board-tree (decknix-board-test--items) 1 t)))
    (should (equal (mapcar #'decknix-board-test--shape (plist-get tree :nodes))
                   '((1 (2 (4 (5 (6)))) (3 (7))))))
    (should (equal (mapcar #'decknix-board-test--shape (plist-get tree :unlinked))
                   '((8))))))

(ert-deftest decknix-board-test-tree-without-root ()
  (let ((tree (decknix-board-tree (decknix-board-test--items) nil t)))
    (should (equal (mapcar (lambda (n) (plist-get (car n) :number)) (plist-get tree :nodes))
                   '(1 8)))
    (should-not (plist-get tree :unlinked))))

(ert-deftest decknix-board-test-tree-flat-fallback ()
  (let* ((items (mapcar (lambda (i) (plist-put (copy-sequence i) :parent nil))
                        (decknix-board-test--items)))
         (tree (decknix-board-tree items 1 nil)))
    (should (equal (mapcar #'car (plist-get tree :flat))
                   '("goal" "epic" "story" "task" "subtask" "feature")))
    (should (equal (mapcar (lambda (i) (plist-get i :number))
                           (alist-get "task" (plist-get tree :flat) nil nil #'equal))
                   '(5 8)))))

(ert-deftest decknix-board-test-tree-survives-cycle ()
  (let ((items (list '(:number 1 :parent 2 :title "a")
                     '(:number 2 :parent 1 :title "b"))))
    ;; Neither is top-level; the render shows nothing rather than looping.
    (should (listp (plist-get (decknix-board-tree items nil t) :nodes)))))

(ert-deftest decknix-board-test-ancestors ()
  (should (equal (mapcar (lambda (i) (plist-get i :number))
                         (decknix-board-ancestors (decknix-board-test--items)
                                                  (decknix-board-test--item 6)))
                 '(1 2 4 5))))

;; --- fetching ------------------------------------------------------------

(ert-deftest decknix-board-test-list-argv ()
  (let ((argv (decknix-board-github--list-argv decknix-board-test--board t)))
    (should (equal (seq-take argv 3) '("gh" "api" "graphql")))
    (should-not (seq-some (lambda (a) (string-prefix-p "endCursor=" a)) argv))
    (should (member "endCursor=CUR"
                    (decknix-board-github--list-argv decknix-board-test--board t "CUR")))
    (should (member "owner=acme" argv))
    (should (member "name=hack-boards" argv))
    (should (seq-some (lambda (a) (string-match-p "parent{number}" a)) argv))
    (should-not (seq-some (lambda (a) (string-match-p "parent{number}" a))
                          (decknix-board-github--list-argv decknix-board-test--board nil)))))

(ert-deftest decknix-board-test-list-argv-label-filter ()
  (let ((argv (decknix-board-github--list-argv
               '(:github (:repo "a/b" :label "hackathon")) t)))
    (should (seq-some (lambda (a) (string-search "labels:[\"hackathon\"]" a)) argv))))

(ert-deftest decknix-board-test-list-items-falls-back-without-sub-issues ()
  (decknix-board-test-with-recorder
      (list '(1 "" "gh: Field 'parent' doesn't exist on type 'Issue'")
            (list 0 decknix-board-test-github-ndjson ""))
    (let (result)
      (decknix-board-backend-list-items 'github decknix-board-test--board
                                        (lambda (r) (setq result r)))
      (should (= 2 (length calls)))
      (should-not (seq-some (lambda (a) (string-match-p "parent{number}" a))
                            (nth 1 calls)))
      (should (= 8 (length (car result))))
      (should-not (plist-get (cdr result) :hierarchy)))))

(ert-deftest decknix-board-test-list-items-walks-pages-up-to-the-cap ()
  (let* ((more "{\"pageInfo\":{\"endCursor\":\"C1\",\"hasNextPage\":true}}")
         (page (concat decknix-board-test-github-ndjson "\n" more)))
    (decknix-board-test-with-recorder (list (list 0 page ""))
      (let ((decknix-board-github-max-pages 3) result)
        (decknix-board-backend-list-items 'github decknix-board-test--board
                                          (lambda (r) (setq result r)))
        (should (= 3 (length calls)))
        (should (member "endCursor=C1" (nth 1 calls)))
        (should (= 24 (length (car result))))
        (should (plist-get (cdr result) :hierarchy))))))

(ert-deftest decknix-board-test-next-cursor ()
  (should (equal (decknix-board-github-next-cursor
                  "{\"number\":1}\n{\"pageInfo\":{\"endCursor\":\"X\",\"hasNextPage\":true}}")
                 "X"))
  (should-not (decknix-board-github-next-cursor
               "{\"pageInfo\":{\"endCursor\":\"X\",\"hasNextPage\":false}}")))

(ert-deftest decknix-board-test-list-items-reports-other-errors ()
  (decknix-board-test-with-recorder (list '(1 "" "gh: Could not resolve to a Repository"))
    (let (result)
      (decknix-board-backend-list-items 'github decknix-board-test--board
                                        (lambda (r) (setq result r)))
      (should (= 1 (length calls)))
      (should (string-match-p "Could not resolve" (plist-get (cdr result) :error))))))

;; --- creating ------------------------------------------------------------

(ert-deftest decknix-board-test-create-runs-label-create-and-link ()
  (decknix-board-test-with-recorder
      (list '(1 "" "label already exists")
            '(0 "https://github.com/acme/hack-boards/issues/9\n" "")
            '(0 "{}" ""))
    (let (created)
      (decknix-board-backend-create-item
       'github decknix-board-test--board
       (list :type "story" :title "New story" :body "Why"
             :parent (decknix-board-test--item 2))
       (lambda (url err) (setq created (list url err))))
      (should (equal (nth 0 calls)
                     '("gh" "label" "create" "type:story" "--repo" "acme/hack-boards"
                       "--color" "c5def5" "--description" "decknix board item type")))
      (should (equal (nth 1 calls)
                     '("gh" "issue" "create" "--repo" "acme/hack-boards"
                       "--title" "New story" "--body" "Why" "--label" "type:story")))
      (should (equal (seq-take (nth 2 calls) 3) '("gh" "api" "graphql")))
      (should (member "parent=I_kwDOAAAA02" (nth 2 calls)))
      (should (member "child=https://github.com/acme/hack-boards/issues/9" (nth 2 calls)))
      (should (equal created '("https://github.com/acme/hack-boards/issues/9" nil))))))

(ert-deftest decknix-board-test-create-without-parent-skips-link ()
  (decknix-board-test-with-recorder
      (list '(0 "" "") '(0 "https://github.com/acme/hack-boards/issues/10\n" ""))
    (let (created)
      (decknix-board-backend-create-item
       'github decknix-board-test--board (list :type "goal" :title "G" :body "")
       (lambda (url _err) (setq created url)))
      (should (= 2 (length calls)))
      (should (equal created "https://github.com/acme/hack-boards/issues/10")))))

(ert-deftest decknix-board-test-create-is-gated-on-confirmation ()
  (decknix-board-test-with-recorder (list '(0 "" ""))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (should-not (decknix-board-create-item decknix-board-test--board
                                             (list :type "task" :title "T")))
      (should-not calls))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (decknix-board-create-item decknix-board-test--board
                                         (list :type "task" :title "T")))
      (should calls))))

(ert-deftest decknix-board-test-url-number ()
  (should (eql 12 (decknix-board--url-number "https://github.com/a/b/issues/12")))
  (should-not (decknix-board--url-number nil)))

;; --- Slack ---------------------------------------------------------------

(ert-deftest decknix-board-test-slack-is-gated-on-confirmation ()
  (decknix-board-test-with-recorder (list '(0 "" ""))
    (let ((decknix-board-slack-post-command '("poster")))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (should-not (decknix-board-slack-send "C1" "hello"))
        (should-not calls))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (should (eq 'posted (decknix-board-slack-send "C1" "hello")))
        (should (equal calls '(("poster" "--channel" "C1" "--message" "hello"))))))))

(ert-deftest decknix-board-test-slack-fallback-copies-and-opens ()
  (decknix-board-test-with-recorder (list '(0 "" ""))
    (let ((kill-ring nil) opened)
      (cl-letf (((symbol-function 'decknix-board--slack-command) (lambda () nil))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
        (should (eq 'copied (decknix-board-slack-send "C1" "status")))
        (should (equal (car kill-ring) "status"))
        (should (equal opened "https://slack.com/app_redirect?channel=C1"))
        (should-not calls)))))

(ert-deftest decknix-board-test-slack-text ()
  (let* ((items (decknix-board-test--items))
         (g (decknix-board-group-sessions
             decknix-board-test--board
             (list (decknix-board-test--session "one" '("hackathon" "#4") "asking"))
             items))
         (text (decknix-board-slack-text decknix-board-test--board
                                         (decknix-board-test--item 2) items g)))
    (should (string-match-p "epic #2 Board UI" text))
    ;; Epic 2, story 4, task 5 (closed), subtask 6.
    (should (string-match-p "1 done, 3 open" text))
    (should (string-match-p "Waiting on people: one" text))
    (should (string-match-p "- #4 Render the tree" text))))

;; --- text for agents -----------------------------------------------------

(ert-deftest decknix-board-test-session-brief ()
  (let* ((items (decknix-board-test--items))
         (item (decknix-board-test--item 4))
         (brief (decknix-board-session-brief decknix-board-test--board item
                                             (decknix-board-ancestors items item))))
    (should (string-match-p "story #4 Render the tree" brief))
    (should (string-match-p "Board goal: Ship boards" brief))
    (should (string-match-p "goal #1 .* > epic #2 Board UI" brief))
    (should (string-match-p "issues/4" brief))
    (should (string-match-p "boards/hack\\.md" brief))
    (should (string-match-p "hack-boards#4" brief))
    (should (string-match-p "Slack C0123ABCD" brief))))

(ert-deftest decknix-board-test-markdown ()
  (let* ((items (decknix-board-test--items))
         (g (decknix-board-group-sessions
             decknix-board-test--board
             (list (decknix-board-test--session "one" '("hackathon" "#4")))
             items))
         (md (decknix-board-markdown decknix-board-test--board
                                     (decknix-board-tree items 1 t) g 0)))
    (should (string-match-p "^# Hack$" md))
    (should (string-match-p "^- \\[ \\] goal #1 " md))
    (should (string-match-p "^      - \\[x\\] task #5 Fold rows" md))
    (should (string-match-p "story #4 Render the tree (@ldeck @ye) sessions: `one`" md))
    (should (string-match-p "## Outside the goal" md))))

;; --- the buffer ----------------------------------------------------------

(ert-deftest decknix-board-test-draw-and-navigate ()
  (let ((asking (generate-new-buffer "asking-session")))
    (unwind-protect
        (with-temp-buffer
          (decknix-board-mode)
          (setq decknix-board--board decknix-board-test--board
                decknix-board--items (decknix-board-test--items)
                decknix-board--meta '(:hierarchy t)
                decknix-board--fetched-at (current-time))
          (cl-letf (((symbol-function 'decknix-board-live-sessions)
                     (lambda ()
                       (list (decknix-board-test--session
                              (buffer-name asking) '("hackathon" "#4") "asking")))))
            (decknix-board--render t)
            (let ((text (buffer-string)))
              (should (string-match-p "Needs you (1)" text))
              (should (string-match-p "#4 Render the tree" text))
              (should (string-match-p "PR #20 draft" text))
              (should (string-match-p "Outside the goal" text)))
            ;; Rows are reachable one at a time with n.
            (goto-char (point-min))
            (decknix-board-next)
            (should (eq (get-text-property (point) 'decknix-board-session) asking))
            (decknix-board-next)
            (should (eql 1 (plist-get (get-text-property (point) 'decknix-board-item) :number)))
            ;; The session row under #4 belongs to #4.
            (search-forward "#4 Render")
            (decknix-board-next)
            (should (eq (get-text-property (point) 'decknix-board-session) asking))
            (should (eql 4 (plist-get (decknix-board--item-at-point) :number)))
            ;; Folding #2 hides its subtree.
            (goto-char (point-min))
            (search-forward "#2 Board UI")
            (decknix-board-toggle)
            (should-not (string-match-p "#4 Render" (buffer-string)))
            ;; An unchanged board is not redrawn.
            (let ((tick (buffer-modified-tick)))
              (decknix-board--render)
              (should (= tick (buffer-modified-tick))))))
      (kill-buffer asking))))

(ert-deftest decknix-board-test-recreate-by-buffer-name ()
  (let ((decknix-board-directory (make-temp-file "boards" t))
        opened)
    (unwind-protect
        (cl-letf (((symbol-function 'decknix-board-open)
                   (lambda (name) (setq opened name) 'buf)))
          (decknix-board-write decknix-board-test--board)
          (should (eq 'buf (decknix-board-recreate "*Board: hack*")))
          (should (equal opened "hack"))
          (setq opened nil)
          (should-not (decknix-board-recreate "*Board: gone*"))
          (should-not (decknix-board-recreate "*scratch*"))
          (should-not opened)
          (should (get 'decknix-board-recreate 'decknix-layout-recreate-with-name)))
      (delete-directory decknix-board-directory t))))

(provide 'decknix-board-test)
;;; decknix-board-test.el ends here
