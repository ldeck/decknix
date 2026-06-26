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

;; Buffer-local in `decknix-agent-shell-main-session' (set on session
;; create/resume to the active provider symbol: `auggie', `claude-code'
;; or `pi').  Forward-declared here -- with a nil default so it is a
;; bound special variable -- so this module can scope discovery to the
;; agent the current buffer is running as without a hard dependency.
;; nil means "no agent session" and selects the union search path.
(defvar decknix--agent-provider-id nil)

(defvar decknix--agent-command-dirs
  (list (expand-file-name "~/.claude/commands")
        (expand-file-name "~/.augment/commands"))
  "Union of directories to scan for custom slash commands.
Used as the fallback search path when there is no active agent
provider (e.g. the picker is invoked outside a session buffer).
Covers ~/.claude/commands/ (canonical -- read natively by both
Claude Code and Auggie) plus the legacy ~/.augment/commands/ for
backward compatibility during the transition.  When a buffer DOES
declare a provider via `decknix--agent-provider-id', discovery is
scoped to that agent's dirs instead (see
`decknix--agent-command-dirs-for-provider').")

(defun decknix--agent-command-dirs-for-provider (provider-id)
  "Return the home-global command/prompt dirs for PROVIDER-ID.
Each supported agent reads its slash commands from a different
location, so the picker scopes discovery to the agent the current
buffer is running as:

  `claude-code'  ~/.claude/commands                  (Claude native)
  `auggie'       ~/.claude/commands + ~/.augment/    (Auggie reads
                 commands                             Claude's dir)
  `pi'           ~/.pi/agent/prompts                 (Pi prompt
                                                      templates)

A nil PROVIDER-ID (called outside an agent session) falls back to the
configured union in `decknix--agent-command-dirs' so the picker still
lists everything."
  (pcase provider-id
    ('pi (list (expand-file-name "~/.pi/agent/prompts")))
    ('claude-code (list (expand-file-name "~/.claude/commands")))
    ('auggie (list (expand-file-name "~/.claude/commands")
                   (expand-file-name "~/.augment/commands")))
    (_ decknix--agent-command-dirs)))

(defun decknix--agent-command-project-rels-for-provider (provider-id)
  "Return the project-relative command dirs for PROVIDER-ID.
Claude-family agents read workspace-level `.claude/commands' (and,
for Auggie, the legacy `.augment/commands'); Pi has no project-level
prompt convention -- its prompts are home-global -- so it returns
nil.  A nil PROVIDER-ID scans both Claude-family project dirs."
  (pcase provider-id
    ('pi nil)
    ('claude-code '(".claude/commands"))
    ('auggie '(".claude/commands" ".augment/commands"))
    (_ '(".claude/commands" ".augment/commands"))))

(defun decknix--agent-command-files ()
  "Return an alist of (name . path) for all available commands.
Discovery is scoped to the agent the current buffer is running as
(`decknix--agent-provider-id'): a Pi session lists Pi prompt
templates, a Claude/Auggie session lists Claude commands (plus the
legacy augment dir for Auggie).  Outside an agent session the union
in `decknix--agent-command-dirs' is scanned.  Both home-global and
project-level directories are searched; the scope label (`global' /
`project') is tracked per directory.  Duplicates (same display name)
collapse, preferring the earlier-scanned (global, canonical) entry.
Display name has the form `/cmdname  (scope)'."
  (let* ((provider (and (boundp 'decknix--agent-provider-id)
                        decknix--agent-provider-id))
         ;; (dir . scope) pairs -- globals first, in registry order.
         (scoped (mapcar (lambda (d) (cons d "global"))
                         (decknix--agent-command-dirs-for-provider provider)))
         (result nil)
         (seen nil))
    ;; Add project-level command dirs if they exist -- pushed last so
    ;; they appear first.  Pi has no project-level dirs (returns nil).
    (when-let* ((proj (project-current))
                (root (project-root proj)))
      (dolist (rel (decknix--agent-command-project-rels-for-provider provider))
        (let ((proj-dir (expand-file-name rel root)))
          (when (file-directory-p proj-dir)
            (push (cons proj-dir "project") scoped)))))
    (dolist (entry scoped)
      (let ((dir (car entry))
            (scope (cdr entry)))
        (when (file-directory-p dir)
          (dolist (file (directory-files dir t "\\.md\\'" t))
            (let* ((name (file-name-sans-extension
                          (file-name-nondirectory file)))
                   (display (format "/%s  (%s)" name scope)))
              (unless (member display seen)
                (push display seen)
                (push (cons display file) result)))))))
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
