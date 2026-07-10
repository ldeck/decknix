;;; decknix-agent-resourcing.el --- Per-conversation resource aggregation -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-subagent-state "0.1") (decknix-agent-url-parse "0.1"))
;; Keywords: agent, agent-shell, decknix, resourcing

;;; Commentary:
;;
;; Pure aggregation layer for the `C-c s a' resourcing view (#145, agent
;; resourcing Feature 2).  Given the raw resources a conversation touches
;; -- its sub-agents, linked PRs, linked repos, and (URL-matched) hub PR
;; data -- it normalises them into a category-pluggable tree that the
;; display layer renders.
;;
;; Two shapes:
;;
;;   item     (:label STR :url STR|nil :state SYM :attention SYM :meta PLIST)
;;   category (:category SYM :label STR :attention SYM :items (item...))
;;
;; and the top-level tree `(:attention SYM :categories (category...))'.
;;
;; `:attention' reuses the Feature-1 vocabulary (`red' > `amber' > `green'
;; > `none') and rolls up from items to category to tree, so the display
;; can colour a collapsed category by its worst child.
;;
;; Everything here is PURE and clock-injected (sub-agent state takes NOW),
;; so ERT exercises it without a live session or the hub.  The impure
;; collection (reading buffer-locals, the hub globals, the link store) and
;; the interactive display stay in main-bulk per AGENTS.md Rule 2.
;;
;; Category-pluggable: a new source (jira, slack, worktree, …) is one more
;; `decknix--agent-resource-<x>' builder returning a category plist that
;; the orchestration appends before calling `decknix--agent-resource-tree'.

;;; Code:

(require 'decknix-agent-subagent-state)
(require 'decknix-agent-url-parse)

(declare-function decknix--agent-subagent-state
                  "decknix-agent-subagent-state"
                  (subagent now &optional parent-live-p))
(declare-function decknix--agent-subagent-attention
                  "decknix-agent-subagent-state" (state))
(declare-function decknix--agent-pr-parse-url "decknix-agent-url-parse" (url))
(declare-function decknix--agent-repo-parse-url "decknix-agent-url-parse" (url))
(declare-function decknix--agent-pr-url-accessor
                  "decknix-agent-url-parse" (pr field))

;; -- Attention rollup (self-contained; no dep on the hub-gated progress
;;    layer, so sub-agent resourcing works with the hub disabled) --------

(defconst decknix--agent-resource-attention-rank
  '((none . 0) (green . 1) (amber . 2) (red . 3))
  "Priority rank for attention symbols; higher wins on rollup.")

(defun decknix--agent-resource-attention-max (a b)
  "Return the higher-priority attention of A and B (nil counts as `none')."
  (let* ((a (or a 'none))
         (b (or b 'none))
         (ra (or (alist-get a decknix--agent-resource-attention-rank) 0))
         (rb (or (alist-get b decknix--agent-resource-attention-rank) 0)))
    (if (>= ra rb) a b)))

(defun decknix--agent-resource-rollup (items)
  "Roll up `:attention' across resource ITEMS to a single symbol."
  (let ((acc 'none))
    (dolist (it items acc)
      (setq acc (decknix--agent-resource-attention-max
                 acc (plist-get it :attention))))))

;; -- Sub-agents category ---------------------------------------------

(defun decknix--agent-resource-subagent-item (subagent now &optional parent-live-p)
  "Normalise one SUBAGENT alist into a resource item at NOW.
PARENT-LIVE-P is forwarded to `decknix--agent-subagent-state'."
  (let* ((state (decknix--agent-subagent-state subagent now parent-live-p))
         (attention (decknix--agent-subagent-attention state))
         (msg (alist-get 'firstUserMessage subagent))
         (sid (or (alist-get 'sessionId subagent) ""))
         (label (if (and (stringp msg)
                         (not (string-empty-p (string-trim msg))))
                    (truncate-string-to-width
                     (replace-regexp-in-string
                      "[ \t\n\r]+" " " (string-trim msg))
                     60 nil nil "…")
                  (if (>= (length sid) 8) (substring sid 0 8) sid))))
    (list :label label
          :url nil
          :state state
          :attention attention
          :meta (list :session-id sid
                      :modified (alist-get 'modified subagent)
                      :exchanges (alist-get 'exchangeCount subagent)))))

(defun decknix--agent-resource-subagents (subagents now &optional parent-live-p)
  "Build the sub-agents resource category from SUBAGENTS, or nil if none.
NOW is a float-time; PARENT-LIVE-P marks the parent session as alive."
  (when subagents
    (let ((items (mapcar (lambda (s)
                           (decknix--agent-resource-subagent-item
                            s now parent-live-p))
                         subagents)))
      (list :category 'subagents
            :label "Sub-agents"
            :attention (decknix--agent-resource-rollup items)
            :items items))))

;; -- Linked-PRs category (hub-enriched by URL match) -----------------

(defun decknix--agent-resource-hub-match (url hub-items)
  "Return the alist in HUB-ITEMS whose `url' equals URL, or nil."
  (and url
       (seq-find (lambda (h) (equal (alist-get 'url h) url)) hub-items)))

(defun decknix--agent-resource-pr-state (hub-match)
  "Derive a resource state symbol from a matched hub PR alist HUB-MATCH.
nil (no hub data for this linked PR) -> `neutral'."
  (if (null hub-match)
      'neutral
    (let ((state (alist-get 'state hub-match))
          (draft (eq (alist-get 'draft hub-match) t)))
      (cond ((member state '("MERGED" "CLOSED")) 'done)
            (draft 'todo)
            (t 'wip)))))

(defun decknix--agent-resource-pr-attention (hub-match)
  "Derive attention from a matched hub PR alist HUB-MATCH (nil -> `none').
Reads normalised fields only (`ci.status', `needs_reply', `mergeable'),
so no dependency on the hub CI classifier."
  (if (null hub-match)
      'none
    (let* ((ci-status (alist-get 'status (alist-get 'ci hub-match)))
           (needs (eq (alist-get 'needs_reply hub-match) t))
           (conflicting (equal (alist-get 'mergeable hub-match) "CONFLICTING")))
      (cond ((or (equal ci-status "fail") conflicting) 'red)
            ((or needs (equal ci-status "running")) 'amber)
            ((equal ci-status "pass") 'green)
            (t 'none)))))

(defun decknix--agent-resource-pr-item (linked-pr hub-items)
  "Normalise a LINKED-PR record (hash-table or alist) into a resource item.
HUB-ITEMS enriches state/attention by `url' match.  The link type
\(\"authored\"/\"subject\") is surfaced as a role tag."
  (let* ((url (decknix--agent-pr-url-accessor linked-pr "url"))
         (type (decknix--agent-pr-url-accessor linked-pr "type"))
         (parsed (and url (decknix--agent-pr-parse-url url)))
         (ref (if parsed
                  (format "%s/%s#%d" (nth 0 parsed) (nth 1 parsed) (nth 2 parsed))
                (or url "?")))
         (role (pcase type
                 ("authored" " (mine)")
                 ("subject"  " (reviewing)")
                 (_ "")))
         (hub-match (decknix--agent-resource-hub-match url hub-items)))
    (list :label (concat ref role)
          :url url
          :state (decknix--agent-resource-pr-state hub-match)
          :attention (decknix--agent-resource-pr-attention hub-match)
          :meta (list :type type))))

(defun decknix--agent-resource-prs (linked-prs hub-items)
  "Build the linked-PRs resource category, or nil if LINKED-PRS is empty.
HUB-ITEMS is the flat list of hub PR alists used for URL enrichment."
  (when linked-prs
    (let ((items (mapcar (lambda (p)
                           (decknix--agent-resource-pr-item p hub-items))
                         linked-prs)))
      (list :category 'prs
            :label "Linked PRs"
            :attention (decknix--agent-resource-rollup items)
            :items items))))

;; -- Linked-repos category -------------------------------------------

(defun decknix--agent-resource-repo-item (linked-repo)
  "Normalise a LINKED-REPO record (hash-table or alist) into a resource item."
  (let* ((url (decknix--agent-pr-url-accessor linked-repo "url"))
         (branch (decknix--agent-pr-url-accessor linked-repo "branch"))
         (parsed (and url (decknix--agent-repo-parse-url url)))
         (label (if parsed
                    (format "%s/%s%s" (nth 0 parsed) (nth 1 parsed)
                            (if (and branch (not (string-empty-p branch)))
                                (format " @%s" branch) ""))
                  (or url "?"))))
    (list :label label
          :url url
          :state 'neutral
          :attention 'none
          :meta (list :branch branch))))

(defun decknix--agent-resource-repos (linked-repos)
  "Build the linked-repos resource category, or nil if LINKED-REPOS is empty."
  (when linked-repos
    (let ((items (mapcar #'decknix--agent-resource-repo-item linked-repos)))
      (list :category 'repos
            :label "Linked repos"
            :attention (decknix--agent-resource-rollup items)
            :items items))))

;; -- Tree assembly ---------------------------------------------------

(defun decknix--agent-resource-tree (categories)
  "Assemble CATEGORIES (some possibly nil) into a resource tree plist.
Drops nil/empty categories and rolls attention up across the rest.
Returns `(:attention SYM :categories (category...))'."
  (let* ((cats (seq-filter (lambda (c)
                             (and c (plist-get c :items)))
                           categories))
         (attention (let ((acc 'none))
                      (dolist (c cats acc)
                        (setq acc (decknix--agent-resource-attention-max
                                   acc (plist-get c :attention)))))))
    (list :attention attention
          :categories cats)))

(provide 'decknix-agent-resourcing)
;;; decknix-agent-resourcing.el ends here
