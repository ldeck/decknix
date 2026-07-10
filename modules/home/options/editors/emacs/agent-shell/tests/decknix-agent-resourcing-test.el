;;; decknix-agent-resourcing-test.el --- Tests for resource aggregation -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for `decknix-agent-resourcing' — the pure layer that
;; normalises a conversation's sub-agents, linked PRs, and linked repos into
;; a category-pluggable resource tree with attention rollup (#145).  All
;; sub-agent state is exercised via an injected NOW; hub PR alists are plain
;; literals (URL-matched), so nothing here needs a live session or the hub.

;;; Code:

(require 'ert)
(require 'decknix-agent-resourcing)

(defconst decknix-resourcing-test--now 1000000.0)

(defun decknix-resourcing-test--subagent (age-seconds msg)
  "A sub-agent alist whose `modified' is AGE-SECONDS before NOW."
  (let ((t- (seconds-to-time (- decknix-resourcing-test--now age-seconds))))
    `((sessionId . "sub-abcdef01")
      (firstUserMessage . ,msg)
      (exchangeCount . 3)
      (modified . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z" t-)))))

;; -- attention rollup ------------------------------------------------

(ert-deftest decknix-resourcing--attention-max-picks-worst ()
  (should (eq 'red (decknix--agent-resource-attention-max 'amber 'red)))
  (should (eq 'amber (decknix--agent-resource-attention-max 'amber 'green)))
  (should (eq 'green (decknix--agent-resource-attention-max 'green nil)))
  (should (eq 'none (decknix--agent-resource-attention-max nil nil))))

(ert-deftest decknix-resourcing--rollup-over-items ()
  (should (eq 'red
              (decknix--agent-resource-rollup
               '((:attention green) (:attention red) (:attention none)))))
  (should (eq 'none (decknix--agent-resource-rollup '()))))

;; -- sub-agents category ---------------------------------------------

(ert-deftest decknix-resourcing--subagent-item-fresh-live-is-running ()
  (let ((item (decknix--agent-resource-subagent-item
               (decknix-resourcing-test--subagent 5 "Explore the monolith")
               decknix-resourcing-test--now t)))
    (should (eq 'running (plist-get item :state)))
    (should (eq 'green (plist-get item :attention)))
    (should (equal "Explore the monolith" (plist-get item :label)))
    (should (null (plist-get item :url)))
    (should (equal "sub-abcdef01" (plist-get (plist-get item :meta) :session-id)))))

(ert-deftest decknix-resourcing--subagent-item-label-collapses-and-falls-back ()
  ;; Multi-line message collapses to one line.
  (let ((item (decknix--agent-resource-subagent-item
               (decknix-resourcing-test--subagent 5 "line one\n  line two")
               decknix-resourcing-test--now t)))
    (should (equal "line one line two" (plist-get item :label))))
  ;; Blank message -> falls back to a short session id.
  (let ((item (decknix--agent-resource-subagent-item
               (decknix-resourcing-test--subagent 5 "   ")
               decknix-resourcing-test--now t)))
    (should (equal "sub-abcd" (plist-get item :label)))))

(ert-deftest decknix-resourcing--subagents-category-rolls-up-and-nil-when-empty ()
  (should-not (decknix--agent-resource-subagents nil decknix-resourcing-test--now t))
  (let ((cat (decknix--agent-resource-subagents
              (list (decknix-resourcing-test--subagent 5 "fresh")     ; running/green
                    (decknix-resourcing-test--subagent 5000 "stale")) ; done/none
              decknix-resourcing-test--now t)))
    (should (eq 'subagents (plist-get cat :category)))
    (should (equal "Sub-agents" (plist-get cat :label)))
    (should (= 2 (length (plist-get cat :items))))
    (should (eq 'green (plist-get cat :attention)))))

;; -- linked PRs (hub URL match) --------------------------------------

(defconst decknix-resourcing-test--hub
  '(((url . "https://github.com/o/r/pull/1")
     (state . "OPEN") (ci . ((status . "fail"))))
    ((url . "https://github.com/o/r/pull/2")
     (state . "OPEN") (needs_reply . t) (ci . ((status . "pass"))))
    ((url . "https://github.com/o/r/pull/3")
     (state . "MERGED") (ci . ((status . "pass")))))
  "Flat hub PR alists keyed by url, as the orchestration would pass in.")

(ert-deftest decknix-resourcing--hub-match-by-url ()
  (should (equal "MERGED"
                 (alist-get 'state
                            (decknix--agent-resource-hub-match
                             "https://github.com/o/r/pull/3"
                             decknix-resourcing-test--hub))))
  (should-not (decknix--agent-resource-hub-match "https://github.com/o/r/pull/9"
                                                 decknix-resourcing-test--hub))
  (should-not (decknix--agent-resource-hub-match nil decknix-resourcing-test--hub)))

(ert-deftest decknix-resourcing--pr-state-derivation ()
  (should (eq 'neutral (decknix--agent-resource-pr-state nil)))
  (should (eq 'done (decknix--agent-resource-pr-state '((state . "MERGED")))))
  (should (eq 'done (decknix--agent-resource-pr-state '((state . "CLOSED")))))
  (should (eq 'todo (decknix--agent-resource-pr-state '((state . "OPEN") (draft . t)))))
  (should (eq 'wip (decknix--agent-resource-pr-state '((state . "OPEN"))))))

(ert-deftest decknix-resourcing--pr-attention-derivation ()
  (should (eq 'none (decknix--agent-resource-pr-attention nil)))
  (should (eq 'red (decknix--agent-resource-pr-attention '((ci . ((status . "fail")))))))
  (should (eq 'red (decknix--agent-resource-pr-attention '((mergeable . "CONFLICTING")))))
  (should (eq 'amber (decknix--agent-resource-pr-attention '((needs_reply . t)))))
  (should (eq 'amber (decknix--agent-resource-pr-attention '((ci . ((status . "running")))))))
  (should (eq 'green (decknix--agent-resource-pr-attention '((ci . ((status . "pass")))))))
  (should (eq 'none (decknix--agent-resource-pr-attention '((state . "OPEN"))))))

(ert-deftest decknix-resourcing--pr-item-label-role-and-enrichment ()
  ;; alist link record (works via the accessor just like a hash-table).
  (let ((item (decknix--agent-resource-pr-item
               '((url . "https://github.com/o/r/pull/1") (type . "authored"))
               decknix-resourcing-test--hub)))
    (should (equal "o/r#1 (mine)" (plist-get item :label)))
    (should (equal "https://github.com/o/r/pull/1" (plist-get item :url)))
    (should (eq 'wip (plist-get item :state)))
    (should (eq 'red (plist-get item :attention))))          ; CI fail
  (let ((item (decknix--agent-resource-pr-item
               '((url . "https://github.com/o/r/pull/2") (type . "subject"))
               decknix-resourcing-test--hub)))
    (should (equal "o/r#2 (reviewing)" (plist-get item :label)))
    (should (eq 'amber (plist-get item :attention))))        ; needs_reply
  ;; Unmatched URL -> neutral / none, no role for unknown type.
  (let ((item (decknix--agent-resource-pr-item
               '((url . "https://github.com/o/r/pull/9") (type . "authored"))
               decknix-resourcing-test--hub)))
    (should (eq 'neutral (plist-get item :state)))
    (should (eq 'none (plist-get item :attention)))))

(ert-deftest decknix-resourcing--prs-category-nil-when-empty ()
  (should-not (decknix--agent-resource-prs nil decknix-resourcing-test--hub))
  (let ((cat (decknix--agent-resource-prs
              '(((url . "https://github.com/o/r/pull/1") (type . "authored")))
              decknix-resourcing-test--hub)))
    (should (eq 'prs (plist-get cat :category)))
    (should (eq 'red (plist-get cat :attention)))))

;; -- linked repos ----------------------------------------------------

(ert-deftest decknix-resourcing--repo-item-label ()
  (let ((item (decknix--agent-resource-repo-item
               '((url . "https://github.com/o/r") (type . "repo") (branch . "main")))))
    (should (equal "o/r @main" (plist-get item :label)))
    (should (eq 'neutral (plist-get item :state))))
  ;; No branch -> bare repo.
  (let ((item (decknix--agent-resource-repo-item
               '((url . "https://github.com/o/r") (type . "repo")))))
    (should (equal "o/r" (plist-get item :label)))))

;; -- tree assembly ---------------------------------------------------

(ert-deftest decknix-resourcing--tree-drops-empty-and-rolls-up ()
  (let* ((subs (decknix--agent-resource-subagents
                (list (decknix-resourcing-test--subagent 5000 "stale")) ; done/none
                decknix-resourcing-test--now t))
         (prs (decknix--agent-resource-prs
               '(((url . "https://github.com/o/r/pull/1") (type . "authored"))) ; red
               decknix-resourcing-test--hub))
         (tree (decknix--agent-resource-tree (list subs nil prs))))
    ;; nil category dropped; two real categories kept.
    (should (= 2 (length (plist-get tree :categories))))
    ;; overall attention is the worst across categories.
    (should (eq 'red (plist-get tree :attention)))))

(ert-deftest decknix-resourcing--tree-empty-when-nothing ()
  (let ((tree (decknix--agent-resource-tree (list nil nil))))
    (should (null (plist-get tree :categories)))
    (should (eq 'none (plist-get tree :attention)))))

(provide 'decknix-agent-resourcing-test)
;;; decknix-agent-resourcing-test.el ends here
