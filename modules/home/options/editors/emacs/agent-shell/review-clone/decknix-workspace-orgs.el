;;; decknix-workspace-orgs.el --- GitHub org -> local workspace map -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, decknix, workspace, github

;;; Commentary:
;;
;; Which local workspace a GitHub org's repositories belong in, so a PR
;; in a repository that has never been checked out can still be placed:
;; the review board clones it into the org's workspace and starts the
;; review there, instead of leaving the row Idle because no checkout was
;; found.
;;
;; `decknix-workspaces' is fed from the `decknix.workspaces' Nix option
;; (written into default.el).  `decknix-workspace-resolve' is the one
;; decision: an existing checkout always wins, then the org's workspace
;; (reusing a clone already there), and only then "no workspace".  It
;; takes its lookups as arguments so it stays pure and testable.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup decknix-workspaces nil
  "Local workspaces and the GitHub orgs they hold."
  :group 'decknix)

(defcustom decknix-workspaces nil
  "Local workspaces, each with the GitHub orgs whose repositories live there.

A list of (NAME . PLIST).  PLIST keys:
  :path        the workspace directory, e.g. \"~/Code/acme\".
  :orgs        GitHub owners (orgs or users) cloned there, matched
               case-insensitively, e.g. (\"acme\" \"acme-infra\").
  :clone-args  extra `git clone' arguments for an on-demand clone; nil
               uses `decknix-workspace-default-clone-args'.

Set from the `decknix.workspaces' Nix option; customise it directly only
for an experiment, since the next build writes the Nix value back."
  :type '(alist :key-type string
                :value-type (plist :options ((:path directory)
                                             (:orgs (repeat string))
                                             (:clone-args (repeat string)))))
  :group 'decknix-workspaces)

(defcustom decknix-workspace-default-clone-args '("--filter=blob:none")
  "`git clone' arguments for an on-demand clone with no per-workspace value.
A blobless partial clone has the full history (so `git log' and blame
work) but fetches file contents only when checked out, which keeps a
large repository's first clone short."
  :type '(repeat string)
  :group 'decknix-workspaces)

(defun decknix-workspace--entry-for-org (owner &optional workspaces)
  "Return the (NAME . PLIST) entry of WORKSPACES holding OWNER, or nil.
WORKSPACES defaults to `decknix-workspaces'.  Case-insensitive."
  (when (and (stringp owner) (not (string-empty-p owner)))
    (cl-find-if (lambda (entry)
                  (cl-some (lambda (org) (and (stringp org)
                                              (string-equal-ignore-case org owner)))
                           (plist-get (cdr entry) :orgs)))
                (or workspaces decknix-workspaces))))

(defun decknix-workspace-for-org (owner &optional workspaces)
  "Return the expanded workspace directory for GitHub OWNER, or nil."
  (when-let* ((entry (decknix-workspace--entry-for-org owner workspaces))
              (path (plist-get (cdr entry) :path)))
    (file-name-as-directory (expand-file-name path))))

(defun decknix-workspace-clone-args (owner &optional workspaces)
  "Return the `git clone' arguments for an on-demand clone of OWNER's repo."
  (or (plist-get (cdr (decknix-workspace--entry-for-org owner workspaces))
                 :clone-args)
      decknix-workspace-default-clone-args))

(defun decknix-workspace-resolve (owner repo &optional detect-fn primary-fn exists-fn)
  "Decide where a review of OWNER/REPO runs.  Pure.

Returns a plist whose :kind is one of:
  `checkout'  a local checkout exists.  :workspace is the session's cwd,
              :primary the checkout when known (else nil).
  `clone'     no checkout, but OWNER maps to a workspace: clone into
              :target, then run in :workspace.
  `unmapped'  neither; :org names the owner to add to `decknix-workspaces'.

Precedence, checkout first: DETECT-FN (OWNER REPO), the established
workspace detection, wins outright; then PRIMARY-FN (OWNER REPO), a known
primary clone anywhere on disk (a framework repository kept outside its
org's workspace, say), run from the org's workspace when there is one;
then a checkout already in the org's workspace, tested with EXISTS-FN
\(default `file-directory-p'), which also picks up a clone that appeared
since the last look."
  (let* ((exists-fn (or exists-fn #'file-directory-p))
         (detected (and detect-fn (funcall detect-fn owner repo)))
         (org-ws (decknix-workspace-for-org owner))
         (primary (and (not detected) primary-fn (funcall primary-fn owner repo)))
         (target (and org-ws (stringp repo) (not (string-empty-p repo))
                      (expand-file-name repo org-ws))))
    (cond
     (detected (list :kind 'checkout :workspace detected :primary nil))
     (primary
      (list :kind 'checkout
            :workspace (or org-ws
                           (file-name-directory
                            (directory-file-name (expand-file-name primary))))
            :primary primary))
     ((and target (funcall exists-fn target))
      (list :kind 'checkout :workspace org-ws :primary target))
     (target (list :kind 'clone :workspace org-ws :target target))
     (t (list :kind 'unmapped :org owner)))))

(defun decknix-workspace-unmapped-message (owner)
  "Return the row text for an OWNER with no checkout and no workspace."
  (format "no workspace for %s: add it to decknix.workspaces (C clones elsewhere)"
          (or owner "?")))

(provide 'decknix-workspace-orgs)
;;; decknix-workspace-orgs.el ends here
