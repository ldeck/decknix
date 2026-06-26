;;; decknix-agent-command-discover.el --- Custom auggie command discovery -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, commands

;;; Commentary:
;;
;; Discovery primitives for auggie custom commands carved out of
;; `decknix-agent-shell-main' (main-bulk) into the
;; `agent-shell/agent/' cluster.  Owns the user-tunable defvar
;; that seeds the search path, plus the two pure scanners that
;; back the `decknix-agent-command-{run,new,edit}' commands and
;; the `decknix--agent-quickaction-start' family.
;;
;; Two entry points + one defvar:
;;
;;   `decknix--agent-command-dirs'
;;       List of global directories scanned for command Markdown
;;       files.  Defaults to BOTH `~/.claude/commands/' (canonical
;;       -- read natively by Claude Code and Auggie) and the legacy
;;       `~/.augment/commands/' (kept for backward compatibility
;;       during the transition).  Project-level `.claude/commands/'
;;       and `.augment/commands/' are added dynamically by
;;       `-command-files' when `project-current' resolves.
;;
;;   `decknix--agent-command-files'
;;       Returns an alist of (display-name . absolute-path) for
;;       every `*.md' file under the configured directories.
;;       Display name has the form `/cmdname  (scope)' where
;;       scope is `global' for entries under `~/.claude/' or
;;       `~/.augment/' and `project' otherwise.  Both the Claude
;;       and legacy locations are scanned; duplicates (same display
;;       name) collapse, preferring the earlier-scanned (Claude)
;;       entry.  Order is insertion-reversed so the project entries
;;       (pushed last) appear first.
;;
;;   `decknix--agent-command-description'
;;       Reads the YAML frontmatter from a command FILE (first
;;       500 bytes only) and returns the value of the
;;       `description:' field as a string.  Returns the empty
;;       string when the file lacks a frontmatter block or the
;;       field is missing -- callers concatenate the result into
;;       completion annotations and a missing description should
;;       not error out.

;;; Code:

;; Forward declarations for `project-current' / `project-root' --
;; the project library is built-in but the byte-compiler does not
;; always autoload the symbols at compile time.
(declare-function project-current "project" (&optional may-prompt directory))
(declare-function project-root "project" (project))

(defvar decknix--agent-command-dirs
  (list (expand-file-name "~/.claude/commands")
        (expand-file-name "~/.augment/commands"))
  "Directories to scan for custom slash commands.
Defaults to ~/.claude/commands/ (canonical -- read natively by both
Claude Code and Auggie) plus the legacy ~/.augment/commands/ for
backward compatibility during the transition.  Project-level
.claude/commands/ and .augment/commands/ are added dynamically.")

(defun decknix--agent-command-files ()
  "Return an alist of (name . path) for all available commands.
Scans global and project-level command directories.  Both the
Claude-native (.claude/commands) and legacy auggie (.augment/commands)
locations are scanned so commands deployed to either are discoverable
during the transition; duplicates (same display name) collapse,
preferring the earlier-scanned (Claude) entry."
  (let ((dirs (copy-sequence decknix--agent-command-dirs))
        (result nil)
        (seen nil))
    ;; Add project-level command dirs (.claude first, then legacy
    ;; .augment) if they exist -- pushed last so they appear first.
    (when-let* ((proj (project-current))
                (root (project-root proj)))
      (dolist (rel '(".claude/commands" ".augment/commands"))
        (let ((proj-dir (expand-file-name rel root)))
          (when (file-directory-p proj-dir)
            (push proj-dir dirs)))))
    (dolist (dir dirs)
      (when (file-directory-p dir)
        (dolist (file (directory-files dir t "\\.md\\'" t))
          (let* ((name (file-name-sans-extension
                        (file-name-nondirectory file)))
                 (scope (if (or (string-prefix-p
                                 (expand-file-name "~/.claude") dir)
                                (string-prefix-p
                                 (expand-file-name "~/.augment") dir))
                            "global" "project"))
                 (display (format "/%s  (%s)" name scope)))
            (unless (member display seen)
              (push display seen)
              (push (cons display file) result))))))
    (nreverse result)))

(defun decknix--agent-command-description (file)
  "Extract the description from a command FILE's YAML frontmatter."
  (with-temp-buffer
    (insert-file-contents file nil 0 500)
    (goto-char (point-min))
    (if (and (looking-at "---")
             (re-search-forward "^description:\\s-*\\(.+\\)" nil t))
        (match-string 1)
      "")))

(provide 'decknix-agent-command-discover)
;;; decknix-agent-command-discover.el ends here
