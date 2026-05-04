;;; decknix-agent-workspace-detect.el --- Workspace + branch detection for new sessions -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, workspace

;;; Commentary:
;;
;; Pure detection helpers carved out of `decknix-agent-shell-main'
;; (main-bulk) into the same `agent-shell/agent/' cluster as
;; `decknix-agent-tags-{store,read}' and the per-conversation
;; persistence pairs.  Owns the heuristics that the session-
;; creation / quick-action flows use to suggest a workspace
;; directory and the current git branch, and the user-tunable
;; defvar that seeds the third lookup tier.
;;
;; Three entry points + one defvar:
;;
;;   `decknix-agent-workspace-roots'
;;       List of parent directories that contain git repositories.
;;       Used by `decknix--agent-pr-detect-workspace' as the
;;       third-tier lookup -- if the saved-workspace heuristics
;;       both miss, this list is searched for a REPO subdir.
;;       Set this in your decknix-config's extraConfig.
;;
;;   `decknix--agent-detect-workspace'
;;       Returns the best workspace directory for a new session,
;;       preferring the current `project-root' (when project.el
;;       resolves) and falling back to `default-directory'.
;;
;;   `decknix--agent-pr-detect-workspace'
;;       Returns the best local checkout for a PR from OWNER/REPO,
;;       checking three tiers in order: saved-workspace exact-
;;       basename match, saved-workspace REPO-subdir match, and
;;       `decknix-agent-workspace-roots' REPO-subdir match.  OWNER
;;       is part of the stable contract but not yet used by the
;;       heuristics.
;;
;;   `decknix--agent-detect-branch'
;;       Returns the current git branch name for DIR via
;;       `git rev-parse --abbrev-ref HEAD', or nil when
;;       detached / not a repo / empty.

;;; Code:

(require 'cl-lib)

;; Forward declarations for the tags-store accessors this module
;; relies on (see B.43's commentary for the trivialBuild
;; load-path mechanic).
(declare-function decknix--agent-tags-read "decknix-agent-tags-store")
(declare-function decknix--agent-tags-conversations
                  "decknix-agent-tags-store" (store))

;; Forward declaration for `project-current' / `project-root' --
;; the project library is built-in but the byte-compiler does
;; not always autoload the symbols at compile time.
(declare-function project-current "project" (&optional may-prompt directory))
(declare-function project-root "project" (project))

(defun decknix--agent-detect-workspace ()
  "Detect the best workspace directory for a new session.
Uses project root if available, otherwise `default-directory'."
  (or (when (fboundp 'project-root)
        (when-let ((proj (project-current)))
          (project-root proj)))
      default-directory))

(defvar decknix-agent-workspace-roots nil
  "List of parent directories that contain git repositories.
Used by `decknix--agent-pr-detect-workspace' to find the local
checkout of a repo from a PR URL.  E.g., if this contains
\"~/Code/myorg\" and the PR is for \"myrepo\", the function
checks whether ~/Code/myorg/myrepo/ exists.
Set this in your decknix-config's extraConfig or default.el.")

(defun decknix--agent-pr-detect-workspace (owner repo)
  "Find the best workspace for a PR from OWNER/REPO.
Search order:
  1. Saved workspaces whose path ends in REPO (exact match)
  2. Saved workspaces that contain a REPO subdirectory on disk
  3. Known workspace roots (`decknix-agent-workspace-roots') containing REPO
  4. nil (caller should prompt the user)"
  ;; OWNER is part of the stable contract (callers pass it from the
  ;; PR URL parser) but the current heuristics only need REPO.  A
  ;; future pass can disambiguate same-named repos across orgs.
  (ignore owner)
  (or
   ;; 1. Check saved workspaces for a path ending in /REPO/
   (let ((best nil))
     (condition-case nil
         (let* ((store (decknix--agent-tags-read))
                (convs (decknix--agent-tags-conversations store)))
           (maphash
            (lambda (_key entry)
              (when (hash-table-p entry)
                (let ((ws (gethash "workspace" entry)))
                  (when (and ws (stringp ws))
                    ;; Match repo name as the last path component
                    (let ((dir-name (file-name-nondirectory
                                     (directory-file-name ws))))
                      (when (string-equal-ignore-case dir-name repo)
                        (when (file-directory-p ws)
                          (setq best ws))))))))
            convs))
       (error nil))
     best)
   ;; 2. Check saved workspaces for a REPO subdirectory on disk.
   ;; Handles repos not checked out as their own workspace but under
   ;; a parent org directory (e.g., ~/Code/nurturecloud/ contains
   ;; nct-intelligence-beholder/).  Returns the PARENT workspace,
   ;; not the repo subdir — matching the convention where tags
   ;; identify the specific repo within the org workspace.
   (let ((best nil))
     (condition-case nil
         (let* ((store (decknix--agent-tags-read))
                (convs (decknix--agent-tags-conversations store))
                (seen (make-hash-table :test 'equal)))
           (maphash
            (lambda (_key entry)
              (when (hash-table-p entry)
                (let ((ws (gethash "workspace" entry)))
                  (when (and ws (stringp ws))
                    (let ((expanded (expand-file-name ws)))
                      (unless (gethash expanded seen)
                        (puthash expanded t seen)
                        (let ((candidate (expand-file-name repo expanded)))
                          (when (file-directory-p candidate)
                            (setq best (file-name-as-directory expanded))))))))))
            convs))
       (error nil))
     best)
   ;; 3. Check known workspace roots for REPO subdir
   (cl-loop for root in decknix-agent-workspace-roots
            for candidate = (expand-file-name repo root)
            when (file-directory-p candidate)
            return (file-name-as-directory candidate))))

(defun decknix--agent-detect-branch (dir)
  "Detect the current git branch in DIR, or nil."
  (let ((default-directory dir))
    (let ((branch (string-trim
                   (shell-command-to-string
                    "git rev-parse --abbrev-ref HEAD 2>/dev/null"))))
      (unless (or (string-empty-p branch)
                  (string= branch "HEAD"))
        branch))))

(provide 'decknix-agent-workspace-detect)
;;; decknix-agent-workspace-detect.el ends here
