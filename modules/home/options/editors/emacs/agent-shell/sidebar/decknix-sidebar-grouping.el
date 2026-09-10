;;; decknix-sidebar-grouping.el --- Group sidebar sessions under sub-headers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, sidebar

;;; Commentary:
;;
;; Sub-header grouping for the sidebar's Live and Previous sections, in
;; the shape WIP already uses: a repository heading with its worktrees
;; and PRs beneath it.
;;
;; Two grouping keys, because neither alone covers the sessions we run:
;;
;;   `workspace'  the session's directory, shown as its basename.
;;   `repo'       the repository the session is ABOUT, from its PR
;;                coordinates.
;;
;; Workspace is the obvious key and is currently the weaker one.
;; Measured across a live sidebar, all eleven Live buffers and all eleven
;; Previous entries reported the same workspace, `~/Code/nurturecloud/',
;; because sessions run from the workspace root rather than from the repo
;; or worktree they are about.  Grouping by workspace therefore yields one
;; group holding everything until that changes -- correct, and for now
;; uninformative.
;;
;; Repo is what actually reproduces the WIP shape today: a review session
;; carries PR coordinates (`rea-integration#65'), so its repository is
;; exact rather than inferred.  Sessions with no PR have no repo, which is
;; why an explicit trailing group exists rather than a guess.
;;
;; This layer is pure: it takes items and a key function and returns
;; groups.  It knows nothing about buffers, alists, or rendering, so the
;; Live section (buffers) and the Previous section (alist entries) share
;; it by passing different key functions.

;;; Code:

(require 'seq)

(defconst decknix-sidebar-group-modes '(off workspace repo)
  "The grouping cycle, in order.

`off' first so the default is the flat list that was there before, and a
user who cycles past the end lands back on it rather than on a mode they
have to recognise.")

(defconst decknix-sidebar-group-unscoped-label "unscoped"
  "Heading for items with no group key.

Named rather than omitted.  A session with no repository is a real
category -- `agile/conn', `standup/conn' -- and silently dropping those
rows, or filing them under a guessed heading, would make the section lie
about what is running.")

(defun decknix-sidebar-group-next (mode)
  "Return the grouping mode following MODE in `decknix-sidebar-group-modes'.
An unrecognised MODE (a stale persisted value, say) cycles to the first
entry rather than signalling, so a bad saved state cannot wedge the
sidebar."
  (let ((tail (cdr (memq mode decknix-sidebar-group-modes))))
    (or (car tail) (car decknix-sidebar-group-modes))))

(defun decknix-sidebar-group-mode-label (mode)
  "Return a short display label for grouping MODE."
  (pcase mode
    ('workspace "workspace")
    ('repo "repo")
    (_ "off")))

(defun decknix-sidebar-group-workspace-label (path)
  "Return the sub-header label for workspace PATH, or nil.

The basename, matching how WIP heads its sections with a bare repository
name (`rea-integration') rather than a full path.  Trailing slashes are
stripped first so \"/a/b/\" and \"/a/b\" head the same group instead of
splitting one workspace in two."
  (when (and (stringp path) (not (string-empty-p path)))
    (let ((trimmed (directory-file-name (expand-file-name path))))
      (let ((base (file-name-nondirectory trimmed)))
        (unless (string-empty-p base) base)))))

(defun decknix-sidebar-group-repo-label (pr-keys)
  "Return the repository sub-header for PR-KEYS, or nil.

PR-KEYS is a list of `repo#number' strings as recorded against a review
session.  Returns the repo of the FIRST key: a session reviewing several
PRs is nearly always reviewing them in one repository, and filing such a
row under every repo would double-count it in the headings."
  (let ((first (car (seq-filter #'stringp pr-keys))))
    (when (and first (string-match "\\`\\([^#]+\\)#" first))
      (match-string 1 first))))

(defun decknix-sidebar-group-items (items key-fn)
  "Group ITEMS into a list of (LABEL . ITEMS) using KEY-FN.

KEY-FN is called with one item and returns its group label, or nil for an
item that belongs to no group.

Labels are sorted alphabetically and the nil-key group is appended LAST
under `decknix-sidebar-group-unscoped-label'.  Alphabetical rather than
first-seen because the sidebar is scanned by eye and re-read constantly:
a heading that moves when an unrelated session starts is worse than one
that sits where it sat yesterday.  Items keep their original relative
order inside a group, so whatever ordering the caller applied (recency,
status) survives.

Returns nil for no ITEMS, so a caller can fall back to a flat render
without a special case."
  (when items
    (let ((table (make-hash-table :test 'equal))
          (labels nil)
          (unscoped nil))
      (dolist (item items)
        (let ((label (funcall key-fn item)))
          (if (or (null label) (and (stringp label) (string-empty-p label)))
              (push item unscoped)
            (unless (gethash label table) (push label labels))
            (puthash label (cons item (gethash label table)) table))))
      (append
       (mapcar (lambda (label)
                 (cons label (nreverse (gethash label table))))
               (sort (nreverse labels) #'string<))
       (when unscoped
         (list (cons decknix-sidebar-group-unscoped-label
                     (nreverse unscoped))))))))

(provide 'decknix-sidebar-grouping)
;;; decknix-sidebar-grouping.el ends here
