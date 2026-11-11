;;; decknix-session-urls-test.el --- Tests for the session URL collector -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for `decknix-session-urls': classification, scan
;; order, de-duplication, identity-first ordering, bare ticket keys with
;; and without a tracker base, and the bounded scan.  Pure: strings in,
;; plists out.

;;; Code:

(require 'ert)
(require 'decknix-session-urls)

(defun decknix-session-urls-test--kinds (entries)
  "Return the (KIND . URL) pairs of ENTRIES."
  (mapcar (lambda (e) (cons (plist-get e :kind) (plist-get e :url))) entries))

;; ── classification ───────────────────────────────────────────────────

(ert-deftest decknix-session-urls-classify-pr-and-its-views ()
  (let ((e (decknix-session-urls-classify "https://github.com/acme/widget/pull/460")))
    (should (eq 'pr (plist-get e :kind)))
    (should (equal "widget#460" (plist-get e :key)))
    (should (equal "acme/widget" (plist-get e :repo)))
    (should (equal 460 (plist-get e :number)))
    (should (equal '(("files" . "https://github.com/acme/widget/pull/460/files")
                     ("checks" . "https://github.com/acme/widget/pull/460/checks"))
                   (decknix-session-urls-pr-views e))))
  (should (eq 'pr-files (plist-get (decknix-session-urls-classify
                                    "https://github.com/acme/widget/pull/460/files")
                                   :kind)))
  (should (eq 'pr-checks (plist-get (decknix-session-urls-classify
                                     "https://github.com/acme/widget/pull/460/checks")
                                    :kind))))

(ert-deftest decknix-session-urls-classify-comment-anchors-are-threads ()
  (dolist (url '("https://github.com/acme/widget/pull/460#discussion_r12345"
                 "https://github.com/acme/widget/pull/460#issuecomment-99"
                 "https://github.com/acme/widget/pull/460#pullrequestreview-7"
                 "https://github.com/acme/widget/pull/460/files#r12345"))
    (let ((e (decknix-session-urls-classify url)))
      (should (eq 'pr-thread (plist-get e :kind)))
      (should (equal "https://github.com/acme/widget/pull/460" (plist-get e :pr-url))))))

(ert-deftest decknix-session-urls-classify-issue-commit-ci ()
  (should (eq 'issue (plist-get (decknix-session-urls-classify
                                 "https://github.com/acme/widget/issues/12") :kind)))
  (let ((c (decknix-session-urls-classify
            "https://github.com/acme/widget/commit/0123456789abcdef")))
    (should (eq 'commit (plist-get c :kind)))
    (should (equal "widget@0123456" (plist-get c :label))))
  (should (eq 'commit (plist-get (decknix-session-urls-classify
                                  "https://github.com/acme/widget/pull/4/commits/abcdef1234")
                                 :kind)))
  (should (eq 'ci (plist-get (decknix-session-urls-classify
                              "https://github.com/acme/widget/actions/runs/42") :kind)))
  (should (eq 'ci (plist-get (decknix-session-urls-classify
                              "https://buildkite.com/acme/widget/builds/9") :kind)))
  ;; A PR's checks tab is a PR view, not a CI build.
  (should (eq 'pr-checks (plist-get (decknix-session-urls-classify
                                     "https://github.com/acme/widget/pull/4/checks")
                                    :kind))))

(ert-deftest decknix-session-urls-classify-jira-confluence-other ()
  (let ((j (decknix-session-urls-classify "https://example.atlassian.net/browse/ABC-123")))
    (should (eq 'jira (plist-get j :kind)))
    (should (equal "ABC-123" (plist-get j :label))))
  (let ((c (decknix-session-urls-classify
            "https://example.atlassian.net/wiki/spaces/ENG/pages/42/Deploy+Guide")))
    (should (eq 'confluence (plist-get c :kind)))
    (should (equal "Deploy Guide" (plist-get c :label))))
  (should (eq 'other (plist-get (decknix-session-urls-classify "https://example.com/docs")
                                :kind))))

(ert-deftest decknix-session-urls-trim-drops-trailing-punctuation ()
  (should (equal "https://example.com/a" (decknix-session-urls-trim "https://example.com/a.")))
  (should (equal "https://example.com/a" (decknix-session-urls-trim "https://example.com/a**,"))))

(ert-deftest decknix-session-urls-review-key-from-name ()
  (should (equal "widget#460"
                 (decknix-session-urls-review-key-from-name "*Agent: auto/#460/widget/review*")))
  (should (null (decknix-session-urls-review-key-from-name "*Agent: widget*"))))

(ert-deftest decknix-session-urls-pr-key-url ()
  (should (equal "https://github.com/acme/widget/pull/7"
                 (decknix-session-urls-pr-key-url "acme/widget#7")))
  (should (null (decknix-session-urls-pr-key-url "widget#7"))))

;; ── scanning + ordering ──────────────────────────────────────────────

(ert-deftest decknix-session-urls-scan-finds-markdown-and-bare ()
  (let ((found (decknix-session-urls-scan
                "See [the PR](https://github.com/acme/widget/pull/1) and https://example.com/x.\n"
                100)))
    (should (equal '("https://github.com/acme/widget/pull/1" "https://example.com/x")
                   (mapcar (lambda (f) (plist-get f :url)) found)))
    (should (equal "the PR" (plist-get (car found) :title)))
    (should (= 113 (plist-get (car found) :pos)))))

(ert-deftest decknix-session-urls-collect-most-recent-first-and-dedups ()
  (let* ((text (concat "first https://example.com/a\n"
                       "then https://example.com/b\n"
                       "again https://example.com/a\n"))
         (entries (decknix-session-urls-collect nil text 1)))
    (should (equal '("https://example.com/a" "https://example.com/b")
                   (mapcar (lambda (e) (plist-get e :url)) entries)))
    ;; The surviving occurrence is the latest one.
    (should (equal "again https://example.com/a" (plist-get (car entries) :where)))))

(ert-deftest decknix-session-urls-collect-identity-first-and-labelled ()
  (let* ((text "Opened https://github.com/acme/widget/pull/9 then https://example.com/z\n")
         (identity '((:url "https://github.com/acme/widget/pull/460" :source reviewing)
                     (:url "https://github.com/acme/widget/pull/9" :source created)))
         (entries (decknix-session-urls-collect identity text 1)))
    (should (equal '((pr . "https://github.com/acme/widget/pull/460")
                     (pr . "https://github.com/acme/widget/pull/9")
                     (other . "https://example.com/z"))
                   (decknix-session-urls-test--kinds entries)))
    (should (eq 'reviewing (plist-get (nth 0 entries) :source)))
    (should (null (plist-get (nth 0 entries) :pos)))
    ;; An identity URL also in the text keeps its label and gains a position.
    (should (eq 'created (plist-get (nth 1 entries) :source)))
    (should (= 8 (plist-get (nth 1 entries) :pos)))))

(ert-deftest decknix-session-urls-bare-keys-need-a-base ()
  (let ((text "Tracked in ABC-123; UTF-8 and SHA-256 are not tickets.\n"))
    (should (null (decknix-session-urls-jira-keys text nil)))
    (should (null (seq-filter (lambda (e) (eq 'jira (plist-get e :kind)))
                              (decknix-session-urls-collect nil text 1 nil))))
    (let ((entries (decknix-session-urls-collect nil text 1 "https://example.atlassian.net/")))
      (should (equal '((jira . "https://example.atlassian.net/browse/ABC-123"))
                     (decknix-session-urls-test--kinds entries)))
      (should (eq 'key (plist-get (car entries) :source))))))

(ert-deftest decknix-session-urls-bare-keys-infer-base-from-a-ticket-url ()
  (let* ((text (concat "See https://example.atlassian.net/browse/OPS-1\n"
                       "and also ABC-77 later\n"))
         (entries (decknix-session-urls-collect nil text 1 nil)))
    (should (equal '((jira . "https://example.atlassian.net/browse/ABC-77")
                     (jira . "https://example.atlassian.net/browse/OPS-1"))
                   (decknix-session-urls-test--kinds entries)))))

(ert-deftest decknix-session-urls-bare-key-inside-url-is-not-doubled ()
  (let ((entries (decknix-session-urls-collect
                  nil "https://example.atlassian.net/browse/ABC-5 and ABC-5\n" 1 nil)))
    (should (= 1 (length entries)))))

(ert-deftest decknix-session-urls-bare-keys-respect-project-list ()
  (let ((decknix-session-urls-jira-projects '("ABC")))
    (should (equal '("https://t.example/browse/ABC-1")
                   (mapcar (lambda (e) (plist-get e :url))
                           (decknix-session-urls-jira-keys "ABC-1 XYZ-2" "https://t.example"))))))

(ert-deftest decknix-session-urls-annotation-names-kind-label-where ()
  (let ((a (decknix-session-urls-annotation
            '(:kind pr :label "widget#460" :source reviewing))))
    (should (string-match-p "pr" a))
    (should (string-match-p "widget#460" a))
    (should (string-match-p "reviewing" a))))

(ert-deftest decknix-session-urls-url-around-point ()
  (let ((line "see [the PR](https://github.com/acme/widget/pull/1) or https://example.com/x."))
    (should (equal "https://github.com/acme/widget/pull/1"
                   (decknix-session-urls-url-around line 6)))
    (should (equal "https://example.com/x"
                   (decknix-session-urls-url-around line 60)))
    (should (null (decknix-session-urls-url-around line 1)))))

(provide 'decknix-session-urls-test)
;;; decknix-session-urls-test.el ends here
