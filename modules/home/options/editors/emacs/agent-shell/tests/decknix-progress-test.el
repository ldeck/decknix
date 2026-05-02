;;; decknix-progress-test.el --- Characterisation tests for decknix-progress -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-progress "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the current behaviour of `decknix-progress' (the
;; provider-agnostic data layer).  Run from a Nix derivation; failure
;; aborts the build.  No assertions added here without a corresponding
;; defun in `decknix-progress.el' — these tests are characterisation
;; only, not specification.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-progress)

;; -- Attention rollup -------------------------------------------------

(ert-deftest decknix-progress--attention-max/picks-higher-rank ()
  (should (eq 'red   (decknix-progress--attention-max 'red 'amber)))
  (should (eq 'red   (decknix-progress--attention-max 'amber 'red)))
  (should (eq 'amber (decknix-progress--attention-max 'amber 'green)))
  (should (eq 'green (decknix-progress--attention-max 'green 'none)))
  (should (eq 'none  (decknix-progress--attention-max 'none 'none))))

(ert-deftest decknix-progress--attention-max/treats-nil-as-none ()
  (should (eq 'none  (decknix-progress--attention-max nil nil)))
  (should (eq 'amber (decknix-progress--attention-max nil 'amber)))
  (should (eq 'red   (decknix-progress--attention-max 'red nil))))

(ert-deftest decknix-progress--rollup-attention/walks-children ()
  (let ((item (list :attention 'green
                    :children (list (list :attention 'amber)
                                    (list :attention 'red)
                                    (list :attention 'none)))))
    (should (eq 'red (decknix-progress--rollup-attention item)))))

(ert-deftest decknix-progress--rollup-attention/recurses-grandchildren ()
  (let ((item (list :attention 'none
                    :children (list (list :attention 'none
                                          :children
                                          (list (list :attention 'amber)))))))
    (should (eq 'amber (decknix-progress--rollup-attention item)))))

;; -- PR state derivation ---------------------------------------------

(ert-deftest decknix-progress--state-from-pr/merged-wins ()
  (should (eq 'done
              (decknix-progress--state-from-pr
               (decknix-test-make-pr :merged-at "2025-01-01T00:00:00Z"
                                     :state "closed"
                                     :ci-status "fail")))))

(ert-deftest decknix-progress--state-from-pr/closed-not-merged-is-neutral ()
  (should (eq 'neutral
              (decknix-progress--state-from-pr
               (decknix-test-make-pr :state "closed" :merged-at nil)))))

(ert-deftest decknix-progress--state-from-pr/ci-fail-is-blocked ()
  (should (eq 'blocked
              (decknix-progress--state-from-pr
               (decknix-test-make-pr :ci-status "fail")))))

(ert-deftest decknix-progress--state-from-pr/draft-is-todo ()
  (should (eq 'todo
              (decknix-progress--state-from-pr
               (decknix-test-make-pr :draft t)))))

(ert-deftest decknix-progress--state-from-pr/default-is-wip ()
  (should (eq 'wip (decknix-progress--state-from-pr (decknix-test-make-pr)))))

;; -- Jira state derivation -------------------------------------------

(ert-deftest decknix-progress--state-from-jira/done-category ()
  (should (eq 'done
              (decknix-progress--state-from-jira
               (decknix-test-make-jira-task :status-category "done")))))

(ert-deftest decknix-progress--state-from-jira/blocked-status-name ()
  (should (eq 'blocked
              (decknix-progress--state-from-jira
               (decknix-test-make-jira-task :status "Blocked"
                                            :status-category "indeterminate")))))

(ert-deftest decknix-progress--state-from-jira/inward-blocks-link ()
  (let ((task (decknix-test-make-jira-task
               :status-category "indeterminate"
               :links '(((direction . "inward")
                         (link_type . "is blocked by")
                         (other . ((status_category . "indeterminate")
                                   (key . "OTHER-1"))))))))
    (should (eq 'blocked (decknix-progress--state-from-jira task)))))

(ert-deftest decknix-progress--state-from-jira/inward-block-on-done-not-blocked ()
  (let ((task (decknix-test-make-jira-task
               :status-category "indeterminate"
               :links '(((direction . "inward")
                         (link_type . "is blocked by")
                         (other . ((status_category . "done")
                                   (key . "OTHER-1"))))))))
    (should (eq 'wip (decknix-progress--state-from-jira task)))))

(ert-deftest decknix-progress--state-from-jira/new-and-indeterminate ()
  (should (eq 'todo (decknix-progress--state-from-jira
                     (decknix-test-make-jira-task :status-category "new"))))
  (should (eq 'wip  (decknix-progress--state-from-jira
                     (decknix-test-make-jira-task :status-category "indeterminate")))))

;; -- Todo state derivation -------------------------------------------

(ert-deftest decknix-progress--state-from-todo/known-states ()
  (should (eq 'todo    (decknix-progress--state-from-todo "NOT_STARTED")))
  (should (eq 'wip     (decknix-progress--state-from-todo "IN_PROGRESS")))
  (should (eq 'done    (decknix-progress--state-from-todo "COMPLETE")))
  (should (eq 'neutral (decknix-progress--state-from-todo "CANCELLED"))))

(ert-deftest decknix-progress--state-from-todo/unknown-defaults-todo ()
  (should (eq 'todo (decknix-progress--state-from-todo "WHATEVER")))
  (should (eq 'todo (decknix-progress--state-from-todo nil))))

;; -- PR attention ----------------------------------------------------

(ert-deftest decknix-progress--attention-from-pr/closed-not-merged-none ()
  (should (eq 'none
              (decknix-progress--attention-from-pr
               (decknix-test-make-pr :state "closed" :merged-at nil)))))

(ert-deftest decknix-progress--attention-from-pr/merged-clean-green ()
  (should (eq 'green
              (decknix-progress--attention-from-pr
               (decknix-test-make-pr :merged-at "2025-01-01T00:00:00Z"
                                     :ci-status "pass")))))

(ert-deftest decknix-progress--attention-from-pr/merged-ci-fail-red ()
  (should (eq 'red
              (decknix-progress--attention-from-pr
               (decknix-test-make-pr :merged-at "2025-01-01T00:00:00Z"
                                     :ci-status "fail")))))

(ert-deftest decknix-progress--attention-from-pr/ci-fail-red ()
  (should (eq 'red
              (decknix-progress--attention-from-pr
               (decknix-test-make-pr :ci-status "fail")))))

(ert-deftest decknix-progress--attention-from-pr/conflicting-red ()
  (should (eq 'red
              (decknix-progress--attention-from-pr
               (decknix-test-make-pr :mergeable "conflicting")))))

(ert-deftest decknix-progress--attention-from-pr/changes-requested-amber ()
  (should (eq 'amber
              (decknix-progress--attention-from-pr
               (decknix-test-make-pr :review-decision "CHANGES_REQUESTED")))))

(ert-deftest decknix-progress--attention-from-pr/needs-reply-amber ()
  (should (eq 'amber
              (decknix-progress--attention-from-pr
               (decknix-test-make-pr :needs-reply t)))))

(ert-deftest decknix-progress--attention-from-pr/approved-clean-green ()
  (should (eq 'green
              (decknix-progress--attention-from-pr
               (decknix-test-make-pr :review-decision "APPROVED"
                                     :ci-status "pass")))))

(ert-deftest decknix-progress--attention-from-pr/default-none ()
  (should (eq 'none (decknix-progress--attention-from-pr (decknix-test-make-pr)))))

;; -- Jira / Todo attention -------------------------------------------

(ert-deftest decknix-progress--attention-from-jira/blocked-red ()
  (let ((task (decknix-test-make-jira-task
               :status-category "indeterminate"
               :links '(((direction . "inward")
                         (link_type . "is blocked by")
                         (other . ((status_category . "indeterminate"))))))))
    (should (eq 'red (decknix-progress--attention-from-jira task)))))

(ert-deftest decknix-progress--attention-from-jira/done-green ()
  (should (eq 'green
              (decknix-progress--attention-from-jira
               (decknix-test-make-jira-task :status-category "done")))))

(ert-deftest decknix-progress--attention-from-jira/code-review-amber ()
  (should (eq 'amber
              (decknix-progress--attention-from-jira
               (decknix-test-make-jira-task :status "Code Review"
                                            :status-category "indeterminate")))))

(ert-deftest decknix-progress--attention-from-todo/maps-states ()
  (should (eq 'red   (decknix-progress--attention-from-todo 'blocked)))
  (should (eq 'amber (decknix-progress--attention-from-todo 'wip)))
  (should (eq 'green (decknix-progress--attention-from-todo 'done)))
  (should (eq 'none  (decknix-progress--attention-from-todo 'todo)))
  (should (eq 'none  (decknix-progress--attention-from-todo 'neutral))))

;; -- PR id + item conversion -----------------------------------------

(ert-deftest decknix-progress--pr-id/format ()
  (should (equal "pr:owner/repo#42"
                 (decknix-progress--pr-id "owner/repo" 42)))
  (should (equal "pr:?#?" (decknix-progress--pr-id nil nil))))

(ert-deftest decknix-progress--pr-to-item/shape ()
  (let* ((pr (decknix-test-make-pr :number 7 :title "Hello"))
         (item (decknix-progress--pr-to-item "owner/repo" pr)))
    (should (equal "pr:owner/repo#7" (plist-get item :id)))
    (should (eq 'pr (plist-get item :provider)))
    (should (string-match-p "owner/repo #7 — Hello" (plist-get item :title)))
    (should (eq 'wip (plist-get item :state)))
    (should (eq 'none (plist-get item :attention)))
    (should (null (plist-get item :children)))))

(ert-deftest decknix-progress--from-hub-prs/empty-when-unbound ()
  (decknix-test-with-hub-data nil nil
    (should (null (decknix-progress--from-hub-prs)))))

(ert-deftest decknix-progress--from-hub-prs/walks-repos ()
  (decknix-test-with-hub-data
      (decknix-test-make-hub-wip
       (list (cons "o/r1" (list (decknix-test-make-pr :number 1)
                                (decknix-test-make-pr :number 2)))
             (cons "o/r2" (list (decknix-test-make-pr :number 3)))))
      nil
    (let ((items (decknix-progress--from-hub-prs)))
      (should (= 3 (length items)))
      (should (equal '("pr:o/r1#1" "pr:o/r1#2" "pr:o/r2#3")
                     (mapcar (lambda (it) (plist-get it :id)) items))))))

;; -- Todo markdown parser --------------------------------------------

(ert-deftest decknix-progress--todo-glyph-state/maps-chars ()
  (should (eq 'todo    (decknix-progress--todo-glyph-state ?\s)))
  (should (eq 'wip     (decknix-progress--todo-glyph-state ?/)))
  (should (eq 'done    (decknix-progress--todo-glyph-state ?x)))
  (should (eq 'done    (decknix-progress--todo-glyph-state ?X)))
  (should (eq 'neutral (decknix-progress--todo-glyph-state ?-)))
  (should (eq 'todo    (decknix-progress--todo-glyph-state ??))))

(ert-deftest decknix-progress--todo-parse-markdown/basic-line ()
  (let* ((text "[ ] UUID:abc NAME:Hello DESCRIPTION:World")
         (parsed (decknix-progress--todo-parse-markdown text))
         (entry (car parsed)))
    (should (= 1 (length parsed)))
    (should (equal 0 (alist-get 'depth entry)))
    (should (eq 'todo (alist-get 'state entry)))
    (should (equal "abc" (alist-get 'id entry)))
    (should (equal "Hello" (alist-get 'name entry)))
    (should (equal "World" (alist-get 'description entry)))))

(ert-deftest decknix-progress--todo-parse-markdown/depth-from-dashes ()
  (let* ((text "--[/] UUID:abc NAME:Child")
         (entry (car (decknix-progress--todo-parse-markdown text))))
    (should (equal 2 (alist-get 'depth entry)))
    (should (eq 'wip (alist-get 'state entry)))))

(ert-deftest decknix-progress--todo-parse-markdown/ignores-non-matching-lines ()
  (let ((parsed (decknix-progress--todo-parse-markdown
                 "junk\n[x] UUID:k NAME:Done\nmore junk")))
    (should (= 1 (length parsed)))
    (should (eq 'done (alist-get 'state (car parsed))))))

;; -- Persistence round-trip ------------------------------------------

(ert-deftest decknix-progress--persist/writes-snapshot-and-index ()
  (decknix-test-with-tmp-progress-dir
    (let* ((conv "conv-key-1")
           (payload (list :conv-key conv
                          :updated 12345.0
                          :attention 'amber
                          :items (list (list :id "x:1"
                                             :provider 'pr
                                             :title "T"
                                             :url "https://x"
                                             :state 'wip
                                             :attention 'amber)))))
      (decknix-progress--persist conv payload)
      (let* ((snap (decknix-test-read-json-file
                    (decknix-progress--snapshot-path conv)))
             (idx  (decknix-test-read-json-file
                    (decknix-progress--index-path)))
             (entry (gethash conv idx)))
        (should (equal conv (gethash "conv_key" snap)))
        (should (equal "amber" (gethash "attention" snap)))
        (should (= 1 (length (gethash "items" snap))))
        (should (hash-table-p entry))
        (should (= 1 (gethash "count" entry)))
        (should (equal "amber" (gethash "attention" entry)))))))

(ert-deftest decknix-progress--read-index/missing-returns-empty ()
  (decknix-test-with-tmp-progress-dir
    (let ((idx (decknix-progress--read-index)))
      (should (hash-table-p idx))
      (should (= 0 (hash-table-count idx))))))

(provide 'decknix-progress-test)
;;; decknix-progress-test.el ends here
