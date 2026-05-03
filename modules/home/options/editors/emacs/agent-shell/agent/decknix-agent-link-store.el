;;; decknix-agent-link-store.el --- Conversation link records (PRs + repos) -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-store "0.1") (decknix-agent-url-parse "0.1"))
;; Keywords: agent, agent-shell, decknix, links, persistence

;;; Commentary:
;;
;; Per-conversation link store for PRs and repos.  All link records
;; live under the same `linked_prs' key inside the conversation
;; entry of `~/.config/decknix/agent-sessions.json' for backward
;; compatibility.  Two record shapes coexist:
;;
;;   PR link   : {"url":   ".../pull/N",
;;                "type":  "authored" | "subject",
;;                "added": "auto" | "manual",
;;                "linked_at": "ISO"}
;;   Repo link : {"url":    "https://github.com/OWNER/REPO",
;;                "type":   "repo",
;;                "branch": "main",
;;                "added":  ...,
;;                "linked_at": "ISO"}
;;
;; The seven entry points follow the storage-layer / accessor split
;; established by `decknix-agent-tags-store':
;;
;;   `decknix--agent-linked-items'   — all records for a conv-key
;;   `decknix--agent-linked-prs'     — PR records only
;;   `decknix--agent-linked-repos'   — repo records only
;;   `decknix--agent-link-pr'        — append a PR record (no-op if dup)
;;   `decknix--agent-unlink-pr'      — remove a PR record by URL
;;   `decknix--agent-link-repo'      — append a repo record (URL+branch)
;;   `decknix--agent-unlink-repo'    — remove a repo record (URL+branch)
;;
;; Hub-side reactions (re-writing `linked-prs.json' for the daemon,
;; forcing a fresh `gh' fetch when a freshly-linked PR was outside
;; the WIP adapter window) are gated through `fboundp' so this
;; module loads cleanly even when the hub feature is disabled.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'decknix-agent-tags-store)
(require 'decknix-agent-url-parse)

;; Hub-side callbacks fired after mutations.  The hub package may
;; not be loaded in every configuration (`cfg.hub.enable = false');
;; gating the calls through `fboundp' keeps this module self-
;; contained while still hooking into hub workflows when present.
(declare-function decknix--hub-write-linked-prs "decknix-agent-shell-hub")
(declare-function decknix--hub-pr-fetch-async   "decknix-agent-shell-hub" (url))
(declare-function decknix--hub-repo-fetch-async "decknix-agent-shell-hub" (url branch))
(defvar decknix--hub-pr-cache)

(defun decknix--agent-linked-items (conv-key)
  "Return all linked items (PRs and repos) for CONV-KEY, insertion order."
  (when conv-key
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (gethash "linked_prs" entry)))))

(defun decknix--agent-linked-prs (conv-key)
  "Return linked PR records for CONV-KEY (excludes repo-type links).
PR records have type \"authored\" or \"subject\"; repo records are
surfaced via `decknix--agent-linked-repos' or `decknix--agent-linked-items'."
  (seq-remove
   (lambda (rec)
     (equal (decknix--agent-pr-url-accessor rec "type") "repo"))
   (decknix--agent-linked-items conv-key)))

(defun decknix--agent-linked-repos (conv-key)
  "Return linked repo records for CONV-KEY (type \"repo\" only)."
  (seq-filter
   (lambda (rec)
     (equal (decknix--agent-pr-url-accessor rec "type") "repo"))
   (decknix--agent-linked-items conv-key)))

(defun decknix--agent-link-pr (conv-key url &optional pr-type added)
  "Link PR at URL to conversation CONV-KEY.
PR-TYPE is \"authored\" or \"subject\" (default: \"authored\").
ADDED is \"auto\" or \"manual\" (default: \"manual\").
No-op if URL is already linked."
  (when (and conv-key url (decknix--agent-pr-parse-url url))
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "tags" nil h)
                        (puthash "sessions" nil h)
                        h)))
           (existing (gethash "linked_prs" entry))
           (already (seq-find
                     (lambda (pr)
                       (equal (if (hash-table-p pr)
                                  (gethash "url" pr)
                                (alist-get 'url pr))
                              url))
                     existing)))
      (unless already
        (let ((pr-entry (make-hash-table :test 'equal)))
          (puthash "url" url pr-entry)
          (puthash "type" (or pr-type "authored") pr-entry)
          (puthash "added" (or added "manual") pr-entry)
          (puthash "linked_at"
                   (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)
                   pr-entry)
          (puthash "linked_prs" (append existing (list pr-entry)) entry)
          (puthash conv-key entry convs)
          (decknix--agent-tags-write store)
          ;; Update linked-prs.json for the hub daemon
          (when (fboundp 'decknix--hub-write-linked-prs)
            (decknix--hub-write-linked-prs))
          ;; Force a fresh PR-state fetch.  The hub's WIP adapter only
          ;; tracks open PRs, so a PR that merged/closed between the
          ;; last hub poll and this link call would otherwise stay
          ;; stuck at its cached state for up to the cache TTL.
          (when (fboundp 'decknix--hub-pr-fetch-async)
            (when (boundp 'decknix--hub-pr-cache)
              (remhash url decknix--hub-pr-cache))
            (decknix--hub-pr-fetch-async url))
          t)))))

(defun decknix--agent-unlink-pr (conv-key url)
  "Remove PR at URL from conversation CONV-KEY.
Leaves repo-type links for the same URL untouched."
  (when (and conv-key url)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (let ((existing (gethash "linked_prs" entry)))
          (puthash "linked_prs"
                   (seq-remove
                    (lambda (rec)
                      (and (equal (decknix--agent-pr-url-accessor rec "url") url)
                           (not (equal (decknix--agent-pr-url-accessor rec "type")
                                       "repo"))))
                    existing)
                   entry)
          (decknix--agent-tags-write store)
          ;; Update linked-prs.json for the hub daemon
          (when (fboundp 'decknix--hub-write-linked-prs)
            (decknix--hub-write-linked-prs)))))))

(defun decknix--agent-link-repo (conv-key url branch &optional added)
  "Link repo at URL with BRANCH to conversation CONV-KEY.
URL is a `https://github.com/OWNER/REPO' URL (pull-request URLs are
rejected — use `decknix--agent-link-pr' for those).
ADDED is \"auto\" or \"manual\" (default: \"manual\").
No-op if URL+BRANCH is already linked as a repo."
  (when (and conv-key url branch
             (decknix--agent-repo-parse-url url))
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (or (gethash conv-key convs)
                      (let ((h (make-hash-table :test 'equal)))
                        (puthash "tags" nil h)
                        (puthash "sessions" nil h)
                        h)))
           (existing (gethash "linked_prs" entry))
           (already (seq-find
                     (lambda (rec)
                       (and (equal (decknix--agent-pr-url-accessor rec "url") url)
                            (equal (decknix--agent-pr-url-accessor rec "type") "repo")
                            (equal (decknix--agent-pr-url-accessor rec "branch") branch)))
                     existing)))
      (unless already
        (let ((rec (make-hash-table :test 'equal)))
          (puthash "url" url rec)
          (puthash "type" "repo" rec)
          (puthash "branch" branch rec)
          (puthash "added" (or added "manual") rec)
          (puthash "linked_at"
                   (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)
                   rec)
          (puthash "linked_prs" (append existing (list rec)) entry)
          (puthash conv-key entry convs)
          (decknix--agent-tags-write store)
          ;; Force a fresh repo status fetch so the new row lights up
          ;; without waiting for the next sidebar refresh cycle.
          (when (fboundp 'decknix--hub-repo-fetch-async)
            (decknix--hub-repo-fetch-async url branch))
          t)))))

(defun decknix--agent-unlink-repo (conv-key url branch)
  "Remove repo link for URL+BRANCH from conversation CONV-KEY."
  (when (and conv-key url branch)
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when (hash-table-p entry)
        (let ((existing (gethash "linked_prs" entry)))
          (puthash "linked_prs"
                   (seq-remove
                    (lambda (rec)
                      (and (equal (decknix--agent-pr-url-accessor rec "url") url)
                           (equal (decknix--agent-pr-url-accessor rec "type") "repo")
                           (equal (decknix--agent-pr-url-accessor rec "branch") branch)))
                    existing)
                   entry)
          (decknix--agent-tags-write store))))))

(provide 'decknix-agent-link-store)
;;; decknix-agent-link-store.el ends here
