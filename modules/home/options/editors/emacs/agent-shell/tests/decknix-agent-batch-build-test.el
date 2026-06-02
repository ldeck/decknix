;;; decknix-agent-batch-build-test.el --- Tests for batch builders -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-batch-build' (PR B.82).

;;; Code:

(require 'ert)
(require 'decknix-agent-batch-build)

;; Mock dependencies from main-link
(unless (fboundp 'decknix--agent-review-get-params)
  (defun decknix--agent-review-get-params (url)
    (list nil "/review-service-pr")))

;; --- build-command ---

(ert-deftest decknix-batch-build--command-ungrouped-takes-first ()
  "Ungrouped path emits one /review-service-pr line for the first item."
  (should (equal "/review-service-pr https://github.com/o/r/pull/1"
                 (decknix--batch-build-command
                  nil '("https://github.com/o/r/pull/1"
                        "https://github.com/o/r/pull/2")))))

(ert-deftest decknix-batch-build--command-grouped-joins-newlines ()
  "Grouped path concatenates one line per item."
  (should (equal (concat "/review-service-pr a\n"
                         "/review-service-pr b\n"
                         "/review-service-pr c")
                 (decknix--batch-build-command t '("a" "b" "c")))))

(ert-deftest decknix-batch-build--command-grouped-single-item ()
  "Grouped + single item still produces a single command line."
  (should (equal "/review-service-pr only"
                 (decknix--batch-build-command t '("only")))))

;; --- build-tags ---

(defun decknix-batch-build-test--parser (item)
  "Test parser: maps URLs to alists, returns nil for blanks."
  (cond
   ((string= item "https://github.com/o/r/pull/1")
    '((repo . "r") (number . "1") (owner . "o")))
   ((string= item "https://github.com/o/r/pull/2")
    '((repo . "r") (number . "2") (owner . "o")))
   ((string= item "https://github.com/o/other/pull/3")
    '((repo . "other") (number . "3") (owner . "o")))
   (t nil)))

(ert-deftest decknix-batch-build--tags-base-tag-always-present ()
  "Empty items still produce the `\"review\"' base tag."
  (should (equal '("review")
                 (decknix--batch-build-tags
                  '() #'decknix-batch-build-test--parser))))

(ert-deftest decknix-batch-build--tags-collects-repo-and-number ()
  "Single PR adds repo + #N tags (latest first by `cl-pushnew')."
  (let ((tags (decknix--batch-build-tags
               '("https://github.com/o/r/pull/1")
               #'decknix-batch-build-test--parser)))
    (should (member "review" tags))
    (should (member "r" tags))
    (should (member "#1" tags))))

(ert-deftest decknix-batch-build--tags-dedupes-repo ()
  "Two PRs in the same repo only contribute one repo tag."
  (let* ((tags (decknix--batch-build-tags
                '("https://github.com/o/r/pull/1"
                  "https://github.com/o/r/pull/2")
                #'decknix-batch-build-test--parser))
         (repo-tags (seq-filter (lambda (s) (string= s "r")) tags)))
    (should (= 1 (length repo-tags)))
    (should (member "#1" tags))
    (should (member "#2" tags))))

(ert-deftest decknix-batch-build--tags-skips-unparseable ()
  "Items the parser cannot handle contribute no tags."
  (should (equal '("review")
                 (decknix--batch-build-tags
                  '("not-a-url" "also-not-a-url")
                  #'decknix-batch-build-test--parser))))

;; --- resolve-workspace ---

(defun decknix-batch-build-test--detect (owner repo)
  "Test detector: returns a workspace for known (owner, repo) pairs."
  (cond
   ((and (string= owner "o") (string= repo "r")) "/work/r")
   (t nil)))

(ert-deftest decknix-batch-build--resolve-ungrouped-uses-spec-ws ()
  "Ungrouped specs always return the spec's workspace verbatim."
  (let ((spec '((workspace . "/from-spec") (grouped . nil))))
    (should (equal "/from-spec"
                   (decknix--batch-resolve-workspace
                    spec '("https://github.com/o/r/pull/1") "/default"
                    #'decknix-batch-build-test--parser
                    #'decknix-batch-build-test--detect)))))

(ert-deftest decknix-batch-build--resolve-explicit-group-ws-wins ()
  "Grouped spec with explicit workspace skips auto-detection."
  (let ((spec '((workspace . "/explicit") (grouped . t))))
    (should (equal "/explicit"
                   (decknix--batch-resolve-workspace
                    spec '("https://github.com/o/r/pull/1") "/default"
                    #'decknix-batch-build-test--parser
                    #'decknix-batch-build-test--detect)))))

(ert-deftest decknix-batch-build--resolve-grouped-default-detects ()
  "Grouped spec at the default ws auto-detects from the first parseable item."
  (let ((spec '((workspace . "/default") (grouped . t))))
    (should (equal "/work/r"
                   (decknix--batch-resolve-workspace
                    spec
                    '("not-a-url" "https://github.com/o/r/pull/1")
                    "/default"
                    #'decknix-batch-build-test--parser
                    #'decknix-batch-build-test--detect)))))

(ert-deftest decknix-batch-build--resolve-grouped-fallback-on-no-detect ()
  "Grouped spec at default ws + no detection falls back to the default."
  (let ((spec '((workspace . "/default") (grouped . t))))
    (should (equal "/default"
                   (decknix--batch-resolve-workspace
                    spec '("not-a-url")
                    "/default"
                    #'decknix-batch-build-test--parser
                    #'decknix-batch-build-test--detect)))))

;; --- summary-rows ---

(ert-deftest decknix-batch-build--summary-launched-uses-check ()
  "`launched' status maps to the green check icon."
  (let ((rows (decknix--batch-summary-rows
               '(("foo" "launched" nil)))))
    (should (= 1 (length rows)))
    (should (equal "\u2713 " (plist-get (car rows) :icon)))
    (should (equal "foo" (plist-get (car rows) :name)))
    (should (null (plist-get (car rows) :err)))))

(ert-deftest decknix-batch-build--summary-failed-uses-cross ()
  "Non-`launched' status maps to the red cross icon and preserves error."
  (let ((rows (decknix--batch-summary-rows
               '(("bar" "failed" "boom")))))
    (should (equal "\u2717 " (plist-get (car rows) :icon)))
    (should (equal "boom" (plist-get (car rows) :err)))))

(ert-deftest decknix-batch-build--summary-preserves-order ()
  "Row ordering matches the input results list."
  (let ((rows (decknix--batch-summary-rows
               '(("a" "launched" nil)
                 ("b" "failed" "x")
                 ("c" "launched" nil)))))
    (should (equal '("a" "b" "c")
                   (mapcar (lambda (r) (plist-get r :name)) rows)))))

(provide 'decknix-agent-batch-build-test)
;;; decknix-agent-batch-build-test.el ends here
