;;; decknix-agent-batch-parse-test.el --- Tests for batch parser -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-batch-parse' (PR
;; B.71).  Stubs `decknix--agent-parse-pr-url' and
;; `decknix--agent-pr-detect-workspace' via `cl-letf' so the
;; parser is exercised against fixed string input without pulling
;; in the live URL parser / git heuristic.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-batch-parse)

(defvar decknix--batch-default-workspace "/default/ws")

(defmacro decknix-test--with-parsed-buffer (text &rest body)
  "Insert TEXT into a temp buffer, parse it, bind specs to `specs', run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (let ((specs (decknix--batch-parse-buffer)))
       ,@body)))

(ert-deftest decknix-batch-parse--empty-buffer-returns-nil ()
  "An empty buffer parses to nil specs."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url) (lambda (_) nil))
            ((symbol-function 'decknix--agent-pr-detect-workspace)
             (lambda (&rest _) nil)))
    (decknix-test--with-parsed-buffer ""
      (should-not specs))))

(ert-deftest decknix-batch-parse--ungrouped-line-pr-url ()
  "A bare PR URL becomes a single ungrouped spec auto-named pr-<repo>-<n>."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url)
             (lambda (_)
               '((owner . "octo") (repo . "myrepo") (number . "42"))))
            ((symbol-function 'decknix--agent-pr-detect-workspace)
             (lambda (&rest _) "/auto/ws")))
    (decknix-test--with-parsed-buffer
        "https://github.com/octo/myrepo/pull/42\n"
      (should (= (length specs) 1))
      (let ((s (car specs)))
        (should (string= (alist-get 'name s) "pr-myrepo-42"))
        (should (string= (alist-get 'workspace s) "/auto/ws"))
        (should (equal (alist-get 'items s)
                       '("https://github.com/octo/myrepo/pull/42")))
        (should-not (alist-get 'grouped s))))))

(ert-deftest decknix-batch-parse--ungrouped-non-pr-uses-sha-name ()
  "Non-parseable line gets a `review-<sha8>' name and default workspace."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url) (lambda (_) nil))
            ((symbol-function 'decknix--agent-pr-detect-workspace)
             (lambda (&rest _) nil)))
    (decknix-test--with-parsed-buffer "some random text\n"
      (should (= (length specs) 1))
      (let ((s (car specs)))
        (should (string-prefix-p "review-" (alist-get 'name s)))
        (should (= (length (alist-get 'name s)) 15)) ; review- + 8 hex
        (should (string= (alist-get 'workspace s) "/default/ws"))
        (should-not (alist-get 'grouped s))))))

(ert-deftest decknix-batch-parse--grouped-divider-no-workspace ()
  "`--- name' divider opens a group at the default workspace."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url) (lambda (_) nil))
            ((symbol-function 'decknix--agent-pr-detect-workspace)
             (lambda (&rest _) nil)))
    (decknix-test--with-parsed-buffer
        "--- mygroup\nitem1\nitem2\n"
      (should (= (length specs) 1))
      (let ((s (car specs)))
        (should (string= (alist-get 'name s) "mygroup"))
        (should (string= (alist-get 'workspace s) "/default/ws"))
        (should (equal (alist-get 'items s) '("item1" "item2")))
        (should (alist-get 'grouped s))))))

(ert-deftest decknix-batch-parse--grouped-divider-with-workspace ()
  "`--- name : /path' divider extracts and expands the workspace."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url) (lambda (_) nil)))
    (decknix-test--with-parsed-buffer
        "--- groupA : /tmp/proj\nfoo\n"
      (should (= (length specs) 1))
      (let ((s (car specs)))
        (should (string= (alist-get 'name s) "groupA"))
        (should (string= (alist-get 'workspace s) "/tmp/proj"))
        (should (equal (alist-get 'items s) '("foo")))
        (should (alist-get 'grouped s))))))

(ert-deftest decknix-batch-parse--blank-and-comment-lines-skipped ()
  "Empty lines and `#'-prefixed comments are dropped from items."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url) (lambda (_) nil)))
    (decknix-test--with-parsed-buffer
        "--- g\n# a comment\n\nreal-item\n"
      (let ((s (car specs)))
        (should (equal (alist-get 'items s) '("real-item")))))))

(ert-deftest decknix-batch-parse--multiple-groups-flushed-in-order ()
  "Two consecutive groups produce two specs, each flushed at the next divider."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url) (lambda (_) nil)))
    (decknix-test--with-parsed-buffer
        "--- one\nA\n--- two\nB\nC\n"
      (should (= (length specs) 2))
      (let ((first (nth 0 specs))
            (second (nth 1 specs)))
        (should (string= (alist-get 'name first) "one"))
        (should (equal (alist-get 'items first) '("A")))
        (should (string= (alist-get 'name second) "two"))
        (should (equal (alist-get 'items second) '("B" "C")))))))

(ert-deftest decknix-batch-parse--ungrouped-then-group-mixes ()
  "Ungrouped lines before a divider become individual specs; group flushes after."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url) (lambda (_) nil))
            ((symbol-function 'decknix--agent-pr-detect-workspace)
             (lambda (&rest _) nil)))
    (decknix-test--with-parsed-buffer
        "loose1\n--- gg\nin-group\n"
      (should (= (length specs) 2))
      (should-not (alist-get 'grouped (nth 0 specs)))
      (should (alist-get 'grouped (nth 1 specs)))
      (should (equal (alist-get 'items (nth 1 specs)) '("in-group"))))))

(ert-deftest decknix-batch-parse--workspace-directive-forces-ungrouped-ws ()
  "`workspace: <path>' forces the ws of following ungrouped urls, one session each."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url)
             (lambda (_)
               '((owner . "octo") (repo . "myrepo") (number . "42"))))
            ((symbol-function 'decknix--agent-pr-detect-workspace)
             (lambda (&rest _) "/auto/ws")))
    (decknix-test--with-parsed-buffer
        "workspace: /forced/ws\nhttps://github.com/octo/myrepo/pull/42\nhttps://github.com/octo/myrepo/pull/43\n"
      (should (= (length specs) 2))                              ; one session per url
      (dolist (s specs)
        (should (string= (alist-get 'workspace s) "/forced/ws")) ; override beats auto-detect
        (should-not (alist-get 'grouped s))                      ; still individual, not merged
        (should (= (length (alist-get 'items s)) 1))))))         ; each its own single item

(ert-deftest decknix-batch-parse--workspace-directive-reset-to-auto ()
  "`workspace:' with no path (or `auto') resumes per-url auto-detection."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url)
             (lambda (_) '((owner . "o") (repo . "r") (number . "1"))))
            ((symbol-function 'decknix--agent-pr-detect-workspace)
             (lambda (&rest _) "/auto/ws")))
    (decknix-test--with-parsed-buffer
        "workspace: /forced/ws\nu1\nworkspace: auto\nu2\n"
      (should (= (length specs) 2))
      (should (string= (alist-get 'workspace (nth 0 specs)) "/forced/ws"))
      (should (string= (alist-get 'workspace (nth 1 specs)) "/auto/ws")))))

(ert-deftest decknix-batch-parse--ws-alias-directive ()
  "`ws: <path>' is accepted as an alias for `workspace:'."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url) (lambda (_) nil))
            ((symbol-function 'decknix--agent-pr-detect-workspace)
             (lambda (&rest _) nil)))
    (decknix-test--with-parsed-buffer "ws: /via/alias\nsomething\n"
      (should (= (length specs) 1))
      (should (string= (alist-get 'workspace (car specs)) "/via/alias")))))

(ert-deftest decknix-batch-parse--close-directive-arms-following-specs ()
  "`close: yes' sets the `close' flag on later specs; `close: no' clears it."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url) (lambda (_) nil))
            ((symbol-function 'decknix--agent-pr-detect-workspace)
             (lambda (&rest _) nil)))
    (decknix-test--with-parsed-buffer "before\nclose: yes\narmed1\narmed2\nclose: no\nafter\n"
      (should (= (length specs) 4))
      (should-not (alist-get 'close (nth 0 specs)))  ; before the directive
      (should (alist-get 'close (nth 1 specs)))       ; armed1
      (should (alist-get 'close (nth 2 specs)))       ; armed2
      (should-not (alist-get 'close (nth 3 specs)))))) ; after close: no

(ert-deftest decknix-batch-parse--close-applies-to-groups-too ()
  "A `close: yes' directive also arms a following `---' group."
  (cl-letf (((symbol-function 'decknix--agent-parse-pr-url) (lambda (_) nil))
            ((symbol-function 'decknix--agent-pr-detect-workspace)
             (lambda (&rest _) nil)))
    (decknix-test--with-parsed-buffer "close: yes\n--- g1\nu1\nu2\n"
      (should (= (length specs) 1))
      (should (alist-get 'grouped (car specs)))
      (should (alist-get 'close (car specs))))))

(provide 'decknix-agent-batch-parse-test)

;;; decknix-agent-batch-parse-test.el ends here
