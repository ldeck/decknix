;;; decknix-agent-shell-hub.el --- Hub: PR reviews, WIP, tasks, deploys -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, review, wip

;;; Commentary:
;;
;; Hub module extracted from agent-shell.nix as part of PR B-Bulk.2.
;; Reads per-adapter JSON files from ~/.config/decknix/hub/ and
;; renders Requests (PR reviews), WIP (my PRs), Linked PR/repo rows,
;; Jira tasks, TeamCity deploys, etc. into the workspace sidebar.
;;
;; This module is loaded only when
;; `programs.emacs.decknix.agentShell.hub.enable' is non-nil
;; (the corresponding `(require ...)' lives in the same
;; `optionalString cfg.hub.enable' block in agent-shell.nix).
;; Cross-feature `fboundp' guards in main / workspace continue to gate
;; calls to this module's entry points correctly: when hub is
;; disabled, the module is never required and its symbols stay
;; undefined.
;;
;; The file is a verbatim bulk extraction of 167 declarations
;; (162 from the first hub sub-heredoc; 5 from the second).
;; Side-effects (cache restores, file-notify watchers, advice on
;; `agent-shell-workspace-sidebar-refresh', the `M-' transient
;; suffixes' interactive mutators, and a few `(require ...)' calls
;; for already-extracted helper modules) stay in the heredoc,
;; immediately after the `(require 'decknix-agent-shell-hub)' line.

;; FIXME(arch-debt): this module is a verbatim 167-form bulk
;; extraction.  Follow-up PRs (B.22+) should slice it into
;; individually-tested sub-modules (PR rendering, WIP rendering,
;; cache layer, watcher, transients) using the standard
;; `mkEmacsTestedPackage' pattern.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'filenotify)
(require 'transient)

;; Forward declarations for symbols defined elsewhere in the heredoc
;; or in already-extracted helper modules (most are resolved at runtime
;; via the `(require ...)' chain in agent-shell.nix's hub heredoc).
(declare-function decknix--header-update "ext:decknix-agent-shell")
(declare-function decknix--agent-buffer-session-id "ext:decknix-agent-shell")
(declare-function decknix--agent-tags-read "ext:decknix-agent-shell")
(declare-function decknix--agent-tags-write "ext:decknix-agent-shell")
(declare-function decknix--agent-conversation-key-raw "decknix-agent-parse")
(declare-function decknix--agent-pr-parse-url "decknix-agent-url-parse")
(declare-function decknix--agent-parse-pr-url "decknix-agent-url-parse")
(declare-function decknix--agent-repo-parse-url "decknix-agent-url-parse")
(declare-function decknix--agent-pr-url-accessor "decknix-agent-url-parse")
(declare-function decknix--hub-repo-cache-key "decknix-agent-url-parse")
(declare-function decknix--hub-format-age "decknix-hub-icons")
(declare-function decknix--hub-icon "decknix-hub-ci")
(declare-function decknix--hub-ci-icon "decknix-hub-ci")
(declare-function decknix--hub-ci-classify "decknix-hub-ci")
(declare-function decknix--hub-review-icon "decknix-hub-icons")
(declare-function decknix--hub-wip-review-icon "decknix-hub-icons")
(declare-function decknix--hub-activity-icons "decknix-hub-icons")
(declare-function decknix--hub-wip-reply-icon "decknix-hub-icons")
(declare-function decknix--hub-tc-build-for-branch "decknix-hub-teamcity")
(declare-function decknix--hub-tc-icon "decknix-hub-teamcity")
(declare-function decknix--hub-deploy-indicator "decknix-hub-teamcity")
(declare-function decknix--hub-task-status-icon "decknix-hub-jira-tasks")
(declare-function decknix--hub-org-visibility "decknix-hub-org-filter")
(declare-function decknix--hub-org-visible-p "decknix-hub-org-filter")
(declare-function decknix--hub-org-filter-summary "decknix-hub-org-filter")
(declare-function decknix--hub-discover-orgs "decknix-hub-org-filter")
(declare-function decknix--hub-age-visible-p "decknix-hub-age-presets")
(declare-function decknix--hub-age-filter-cycle "decknix-hub-age-presets")
(declare-function decknix--hub-age-filter-label "decknix-hub-age-presets")
(declare-function decknix--hub-mention-visible-p "decknix-hub-mention-bot")
(declare-function decknix--hub-bot-author-p "decknix-hub-mention-bot")
(declare-function decknix--hub-bot-visible-p "decknix-hub-mention-bot")
(declare-function decknix--hub-mention-filter-label "decknix-hub-mention-bot")
(declare-function decknix--hub-mention-filter-normalize "decknix-hub-mention-bot")
;; Attention-filter cluster (PR B.33) -- engine + toggle commands
;; live in `decknix-hub-attention-filter'.  Declared up here because
;; the transient suffixes earlier in this file (line ~480 onward)
;; reference the toggle commands by `#'symbol' before the moved
;; declarations at the original site near line ~726.
(declare-function decknix--hub-toggle-requests-hide-needs-reply
                  "decknix-hub-attention-filter")
(declare-function decknix--hub-toggle-requests-hide-bot-pending
                  "decknix-hub-attention-filter")
(declare-function decknix--hub-toggle-requests-only-my-replies
                  "decknix-hub-attention-filter")
(declare-function decknix--hub-toggle-requests-sort-reverse
                  "decknix-hub-attention-filter")
(declare-function decknix--hub-toggle-wip-hide-needs-reply
                  "decknix-hub-attention-filter")
(declare-function decknix--hub-toggle-wip-hide-bot-pending
                  "decknix-hub-attention-filter")
(declare-function decknix--hub-toggle-wip-only-my-replies
                  "decknix-hub-attention-filter")
(declare-function decknix--hub-pr-status-from-hub "decknix-hub-pr-lookup")
(declare-function decknix--hub-pr-cache-get "decknix-hub-pr-lookup")
(declare-function decknix--hub-worktree-canonical-repo "decknix-hub-worktree-parse")
(declare-function decknix--hub-worktree-repo-from-url "decknix-hub-worktree-parse")
(declare-function decknix--hub-worktree-normalize-path "decknix-hub-worktree-parse")
(declare-function decknix--hub-worktree-parse-porcelain "decknix-hub-worktree-parse")
(declare-function decknix--sidebar-action-prop "ext:decknix-agent-shell")
(declare-function decknix--sidebar-state-save "ext:decknix-agent-shell")
(declare-function decknix--sidebar-state-load "ext:decknix-agent-shell")
(declare-function decknix--sidebar-refresh "ext:decknix-agent-shell")
(declare-function decknix--sidebar-render-section-header "decknix-sidebar-format")
(declare-function decknix--agent-current-conv-key "ext:decknix-agent-shell")
(declare-function decknix--agent-linked-prs "ext:decknix-agent-shell")
(declare-function decknix--agent-linked-items "ext:decknix-agent-shell")
(declare-function decknix--agent-tags-conversations "ext:decknix-agent-shell")
(declare-function decknix--git-remote-url "decknix-agent-vcs")
(declare-function decknix--hub-cycle-age-filter "ext:decknix-agent-shell")
(declare-function decknix--hub-item-mentioned-p "decknix-hub-mention-bot")
(declare-function decknix--hub-item-team-requested-p "decknix-hub-mention-bot")
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")
(declare-function agent-shell-workspace-sidebar-mode-map "ext:agent-shell-workspace")

;; Forward defvars for heredoc-resident toggle / cache state.
(defvar decknix--sidebar-refresh-suspended)
(defvar decknix--sidebar-tile-count)
(defvar decknix-hub-eager-clone-probe)
(defvar decknix--hub-org-visibility)
(defvar decknix--hub-show-bots)
(defvar decknix--hub-mention-filter)
(defvar decknix--hub-mention-filter-cycle)
(defvar decknix--hub-requests-hide-needs-reply)
(defvar decknix--hub-requests-hide-bot-pending)
(defvar decknix--hub-requests-only-my-replies)
(defvar decknix--hub-requests-sort-reverse)
(defvar decknix--hub-wip-hide-needs-reply)
(defvar decknix--hub-wip-hide-bot-pending)
(defvar decknix--hub-wip-only-my-replies)
(defvar decknix--hub-wip-hide-linked)
(defvar decknix--hub-expand-prs)
(defvar decknix--hub-symbol-style)
(defvar decknix--hub-repo-name-cap)


;; == Hub: surface decknix-hub data in the sidebar ==
;; Reads per-adapter JSON files from ~/.config/decknix/hub/ and
;; renders Requests (PR reviews) and WIP (my PRs) sections above
;; Live sessions.  A file-notify watcher triggers sidebar refresh
;; automatically when any hub file changes — zero polling from Emacs.

(defvar decknix--hub-dir
  (expand-file-name "~/.config/decknix/hub/")
  "Directory where decknix-hub writes per-adapter JSON files.")

(defvar decknix--hub-reviews nil
  "Parsed github-reviews.json data (alist).")
(defvar decknix--hub-wip nil
  "Parsed github-wip.json data (alist).")
(defvar decknix--hub-meta nil
  "Parsed meta.json data (alist).")
(defvar decknix--hub-jira-tasks nil
  "Parsed jira-tasks.json data (alist).")
(defvar decknix--hub-teamcity-builds nil
  "Parsed teamcity-builds.json data (alist).")
(defvar decknix--hub-deploys nil
  "Parsed teamcity-deploys.json data (alist).")
(defvar decknix--hub-show-deploys t
  "When non-nil, show deployment pipeline indicators (DTSP) in WIP section.")
(defvar decknix--hub-watcher nil
  "File-notify descriptor watching the hub directory.")

(defun decknix--hub-read-json (filename)
  "Read and parse a JSON file from the hub directory.
Returns nil on any error (file missing, parse failure, etc.)."
  (let ((path (expand-file-name filename decknix--hub-dir)))
    (when (file-exists-p path)
      (condition-case err
          (json-parse-string
           (with-temp-buffer
             (insert-file-contents path)
             (buffer-string))
           :object-type 'alist
           :array-type 'list
           :null-object nil
           :false-object nil)
        (error
         (message "hub: parse error in %s: %s" filename err)
         nil)))))

(defun decknix--hub-refresh-reviews ()
  "Re-read github-reviews.json."
  (setq decknix--hub-reviews
        (decknix--hub-read-json "github-reviews.json")))

(defun decknix--hub-refresh-wip ()
  "Re-read github-wip.json."
  (setq decknix--hub-wip
        (decknix--hub-read-json "github-wip.json")))

(defun decknix--hub-refresh-meta ()
  "Re-read meta.json."
  (setq decknix--hub-meta
        (decknix--hub-read-json "meta.json")))

(defun decknix--hub-refresh-jira ()
  "Re-read jira-tasks.json."
  (setq decknix--hub-jira-tasks
        (decknix--hub-read-json "jira-tasks.json")))

(defun decknix--hub-refresh-teamcity ()
  "Re-read teamcity-builds.json."
  (setq decknix--hub-teamcity-builds
        (decknix--hub-read-json "teamcity-builds.json")))

(defun decknix--hub-refresh-deploys ()
  "Re-read teamcity-deploys.json."
  (setq decknix--hub-deploys
        (decknix--hub-read-json "teamcity-deploys.json")))

(defun decknix--hub-refresh-all ()
  "Re-read all hub JSON files."
  (decknix--hub-refresh-reviews)
  (decknix--hub-refresh-wip)
  (decknix--hub-refresh-meta)
  (decknix--hub-refresh-jira)
  (decknix--hub-refresh-teamcity)
  (decknix--hub-refresh-deploys))

(defun decknix--hub-on-file-change (event)
  "Handle a file-notify EVENT for the hub directory.
Re-reads only the changed file and refreshes the sidebar."
  (let ((file (nth 2 event)))
    (when (and file (stringp file))
      (let ((name (file-name-nondirectory file)))
        (pcase name
          ("github-reviews.json"  (decknix--hub-refresh-reviews))
          ("github-wip.json"      (decknix--hub-refresh-wip))
          ("meta.json"            (decknix--hub-refresh-meta))
          ("jira-tasks.json"      (decknix--hub-refresh-jira))
          ("teamcity-builds.json" (decknix--hub-refresh-teamcity))
          ("teamcity-deploys.json" (decknix--hub-refresh-deploys))
          (_ nil))
        ;; Refresh the sidebar if it exists
        (when (and (fboundp 'agent-shell-workspace-sidebar-refresh)
                   (get-buffer "*agent-shell-sidebar*"))
          (agent-shell-workspace-sidebar-refresh))))))

(defun decknix--hub-start-watcher ()
  "Start watching the hub directory for changes."
  (when decknix--hub-watcher
    (file-notify-rm-watch decknix--hub-watcher)
    (setq decknix--hub-watcher nil))
  (when (file-directory-p decknix--hub-dir)
    (setq decknix--hub-watcher
          (file-notify-add-watch
           decknix--hub-dir '(change)
           #'decknix--hub-on-file-change))))

;; Hub toggle keys now live in the T transient.  Review launching
;; is merged into the `r' (requests) picker — M-r inside the picker
;; toggles the ready-for-review filter, replacing the old `R' key.

(defvar decknix--sidebar-refresh-suspended nil
  "When non-nil, `agent-shell-workspace-sidebar-refresh' is a no-op.
Pickers that let-bind global filter vars (bot-visibility, sort direction,
etc.) set this so 2-second refresh timers and file-notify callbacks firing
during the picker's `recursive-edit' do not re-render the sidebar with the
picker's local toggle state.  Restored to nil automatically when the
picker's dynamic binding unwinds.")

(defun decknix--hub-toggle-org (org)
  "Toggle visibility of ORG and refresh the sidebar."
  (unless decknix--hub-org-visibility
    ;; First toggle: initialise all orgs as visible
    (setq decknix--hub-org-visibility (make-hash-table :test 'equal))
    (dolist (o (decknix--hub-discover-orgs))
      (puthash o t decknix--hub-org-visibility)))
  (puthash org (not (gethash org decknix--hub-org-visibility))
           decknix--hub-org-visibility)
  ;; If everything is now visible again, clear the table
  (when (cl-every (lambda (o) (gethash o decknix--hub-org-visibility))
                  (decknix--hub-discover-orgs))
    (setq decknix--hub-org-visibility nil))
  (when (get-buffer "*agent-shell-sidebar*")
    (agent-shell-workspace-sidebar-refresh)))

(defun decknix--hub-org-filter-show-all ()
  "Show all orgs (clear filter)."
  (interactive)
  (setq decknix--hub-org-visibility nil)
  (when (get-buffer "*agent-shell-sidebar*")
    (agent-shell-workspace-sidebar-refresh))
  (message "Hub: showing all orgs"))

(defun decknix--hub-org-filter-show-none ()
  "Hide all orgs."
  (interactive)
  (setq decknix--hub-org-visibility (make-hash-table :test 'equal))
  (dolist (org (decknix--hub-discover-orgs))
    (puthash org nil decknix--hub-org-visibility))
  (when (get-buffer "*agent-shell-sidebar*")
    (agent-shell-workspace-sidebar-refresh))
  (message "Hub: hiding all orgs"))

;; `decknix--hub-org-filter-summary' was extracted alongside
;; the other org-filter pure helpers — see the
;; `(require 'decknix-hub-org-filter)' a few lines up.

;; -- Hub: per-org toggle command factory --
(defun decknix--hub-make-org-toggle-cmd (org)
  "Create and return a named command symbol for toggling ORG visibility."
  (let ((sym (intern (format "decknix--hub-toggle--%s"
                             (replace-regexp-in-string
                              "[^a-zA-Z0-9]" "-" org)))))
    (fset sym (eval `(lambda ()
                       ,(format "Toggle visibility of %s." org)
                       (interactive)
                       (decknix--hub-toggle-org ,org)) t))
    sym))

;; -- Hub: org filter transient --
(defun decknix--hub-org-filter-children (_)
  "Generate transient children: one toggle per discovered org + show all/none."
  (let ((orgs (decknix--hub-discover-orgs)))
    (append
     (cl-loop for org in orgs
              for idx from 1
              collect
              (let ((cmd (decknix--hub-make-org-toggle-cmd org))
                    (vis (decknix--hub-org-visible-p org)))
                (transient-parse-suffix
                 transient--prefix
                 (list (number-to-string idx)
                       (format "%s %s"
                               (if vis
                                   (propertize "✓" 'face 'success)
                                 (propertize "✗" 'face 'error))
                               org)
                       cmd
                       :transient t))))
     (list
      (transient-parse-suffix
       transient--prefix
       '("a" "Show all" decknix--hub-org-filter-show-all :transient t))
      (transient-parse-suffix
       transient--prefix
       '("n" "Show none" decknix--hub-org-filter-show-none :transient t))))))

(transient-define-prefix decknix-hub-org-filter-transient ()
  "Toggle visibility of GitHub orgs in the hub sidebar."
  [:class transient-column
   :setup-children decknix--hub-org-filter-children])

(defun decknix--hub-org-filter-dispatch ()
  "Open the org filter transient, or show setup help if no data."
  (interactive)
  (if (decknix--hub-has-data-p)
      (call-interactively #'decknix-hub-org-filter-transient)
    (message (concat
      "Hub: no data. Enable the daemon in your decknix-config:\n"
      "  decknix.services.hub.enable = true;\n"
      "Then: decknix switch"))))

;; -- Hub: org filter in main transient --
(transient-define-suffix decknix-sidebar-transient--org-filter ()
  :key "O"
  :description
  (lambda ()
    (if (decknix--hub-has-data-p)
        (let ((summary (decknix--hub-org-filter-summary)))
          (format "Org filter    %s"
                  (propertize
                   (format "[%s]" summary)
                   'face (if (string= summary "all")
                             'font-lock-comment-face
                           'font-lock-constant-face))))
      (format "Org filter    %s"
              (propertize "[not running]"
                          'face 'font-lock-comment-face))))
  (interactive)
  (call-interactively #'decknix--hub-org-filter-dispatch))

(transient-define-suffix decknix-sidebar-transient--age-filter ()
  :key "F"
  :description
  (lambda ()
    (let ((label (decknix--hub-age-filter-label)))
      (format "Age filter    %s"
              (propertize
               (format "[%s]" label)
               'face (if (string= label "all")
                         'font-lock-comment-face
                       'font-lock-constant-face)))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-cycle-age-filter))

(transient-define-suffix decknix-sidebar-transient--ci-filter ()
  :key "C"
  :description
  (lambda ()
    ;; Mirror the footer construction: build with `concat' so the
    ;; per-icon faces inside the summary survive (a wrapping
    ;; `propertize'/`format' clobbers them).
    (concat "ci            "
            (propertize "[" 'face 'font-lock-comment-face)
            (decknix--hub-ci-filter-summary)
            (propertize "]" 'face 'font-lock-comment-face)))
  (interactive)
  (call-interactively #'decknix-hub-ci-filter-transient))

(transient-define-suffix decknix-sidebar-transient--mention-filter ()
  :key "@"
  :description
  (lambda ()
    (let ((label (decknix--hub-mention-filter-label)))
      (format "mention       %s"
              (propertize
               (format "[%s]" label)
               'face (if (string= label "off")
                         'font-lock-comment-face
                       'font-lock-constant-face)))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-cycle-mention-filter))

(transient-define-suffix decknix-sidebar-transient--bot-filter ()
  :key "B"
  :description
  (lambda ()
    (format "bots         %s"
            (propertize
             (if decknix--hub-show-bots "[show]" "[hide]")
             'face (if decknix--hub-show-bots
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-toggle-bot-filter))

;; Requests row labels are icon-led to match the sidebar footer:
;; the comparable text-only labels (age, bots, ci, mention, sort)
;; sort first, then ↩, 💬, 🤖 by code-point.
(transient-define-suffix decknix-sidebar-transient--req-needs-reply ()
  :key "c"
  :description
  (lambda ()
    (concat (decknix--hub-icon "💬" 'default)
            "             "
            (propertize
             (if decknix--hub-requests-hide-needs-reply "[hide]" "[show]")
             'face (if decknix--hub-requests-hide-needs-reply
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-toggle-requests-hide-needs-reply))

(transient-define-suffix decknix-sidebar-transient--req-bot-pending ()
  :key "b"
  :description
  (lambda ()
    (concat (decknix--hub-icon "🤖" 'default)
            "             "
            (propertize
             (if decknix--hub-requests-hide-bot-pending "[hide]" "[show]")
             'face (if decknix--hub-requests-hide-bot-pending
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-toggle-requests-hide-bot-pending))

(transient-define-suffix decknix-sidebar-transient--req-my-replies ()
  :key "M"
  :description
  (lambda ()
    (format "↩             %s"
            (propertize
             (if decknix--hub-requests-only-my-replies "[only]" "[all]")
             'face (if decknix--hub-requests-only-my-replies
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-toggle-requests-only-my-replies))

(transient-define-suffix decknix-sidebar-transient--req-sort ()
  :key "s"
  :description
  (lambda ()
    (format "sort          %s"
            (propertize
             (if decknix--hub-requests-sort-reverse "[new→old]" "[old→new]")
             'face (if decknix--hub-requests-sort-reverse
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-toggle-requests-sort-reverse))

(transient-define-suffix decknix-sidebar-transient--wip-needs-reply ()
  :key "n"
  :description
  (lambda ()
    (format "comments %s  %s"
            (decknix--hub-icon "💬" 'default)
            (propertize
             (if decknix--hub-wip-hide-needs-reply "[hide]" "[show]")
             'face (if decknix--hub-wip-hide-needs-reply
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-toggle-wip-hide-needs-reply))

(transient-define-suffix decknix-sidebar-transient--wip-bot-pending ()
  :key "u"
  :description
  (lambda ()
    (format "bot review %s %s"
            (decknix--hub-icon "🤖" 'default)
            (propertize
             (if decknix--hub-wip-hide-bot-pending "[hide]" "[show]")
             'face (if decknix--hub-wip-hide-bot-pending
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-toggle-wip-hide-bot-pending))

(transient-define-suffix decknix-sidebar-transient--wip-my-replies ()
  :key "r"
  :description
  (lambda ()
    (format "replies ↩   %s"
            (propertize
             (if decknix--hub-wip-only-my-replies "[only]" "[all]")
             'face (if decknix--hub-wip-only-my-replies
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-toggle-wip-only-my-replies))

(transient-define-suffix decknix-sidebar-transient--expand-prs ()
  :key "E"
  :description
  (lambda ()
    (format "session PRs  %s"
            (propertize
             (pcase decknix--hub-expand-prs
               ('nil "[off]")
               ('pr "[PR]")
               ('pipeline "[pipeline]")
               ('both "[PR+pipeline]")
               (_ "[off]"))
             'face (if decknix--hub-expand-prs
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-cycle-expand-prs))

(transient-define-suffix decknix-sidebar-transient--deploy-indicator ()
  :key "P"
  :description
  (lambda ()
    (format "pipeline     %s"
            (propertize
             (if decknix--hub-show-deploys "[show]" "[hide]")
             'face (if decknix--hub-show-deploys
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-toggle-deploy-indicator))

(transient-define-suffix decknix-sidebar-transient--symbol-style ()
  :key "y"
  :description
  (lambda ()
    (format "symbols      %s"
            (propertize (format "[%s]" decknix--hub-symbol-style)
                        'face 'font-lock-constant-face)))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-toggle-symbol-style))

(transient-define-suffix decknix-sidebar-transient--repo-name-cap ()
  :key "N"
  :description
  (lambda ()
    (format "repo name    %s"
            (propertize (format "[%s]" decknix--hub-repo-name-cap)
                        'face 'font-lock-constant-face)))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-cycle-repo-name-cap))

(transient-define-suffix decknix-sidebar-transient--wip-hide-linked ()
  :key "L"
  :description
  (lambda ()
    (format "hide linked  %s"
            (propertize
             (if decknix--hub-wip-hide-linked "[on]" "[off]")
             'face (if decknix--hub-wip-hide-linked
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix--hub-toggle-wip-hide-linked))

;; Hub toggles now live in the T transient
;; (decknix-sidebar-toggles-transient) — no need to append here.

(defun decknix--hub-item-visible-p (repo-full)
  "Return non-nil if REPO-FULL (owner/repo) passes the org visibility filter."
  (decknix--hub-org-visible-p
   (car (split-string (or repo-full "") "/"))))

;; -- Hub: CI status filter --
;; Tracks which CI statuses are visible (pass, fail, running, unknown).
;; All visible by default.  C in the sidebar toggles individual statuses.

;; CI status filter (PR B.30) -- moved out of this heredoc into
;; agent-shell/hub/decknix-hub-ci-filter.el, packaged as
;; `decknix-hub-ci-filter-el'.  Owns the filter list, the canonical
;; render-order alist, the predicates (`status-of', `visible-p'),
;; the propertised footer summary, the toggle / show-all / show-none
;; commands, the per-bucket toggle defuns called from the
;; transient suffixes below, and the transient row-description
;; builder.  The transient suffix / prefix forms stay in this file
;; because they wire into the broader sidebar transient cluster.
;;
;; Forward declarations so the rest of this file (the transients
;; below + state save/restore in workspace-bulk) byte-compiles
;; clean against the moved symbols.
(defvar decknix--hub-ci-filter)
(defvar decknix--hub-ci-filter-order)
(declare-function decknix--hub-ci-status-of "decknix-hub-ci-filter" (item))
(declare-function decknix--hub-ci-visible-p "decknix-hub-ci-filter" (item))
(declare-function decknix--hub-ci-filter-summary "decknix-hub-ci-filter" ())
(declare-function decknix--hub-ci-toggle-status "decknix-hub-ci-filter" (status))
(declare-function decknix--hub-ci-filter-refresh "decknix-hub-ci-filter" ())
(declare-function decknix--hub-ci-filter-toggle-pass "decknix-hub-ci-filter" ())
(declare-function decknix--hub-ci-filter-toggle-soft "decknix-hub-ci-filter" ())
(declare-function decknix--hub-ci-filter-toggle-running "decknix-hub-ci-filter" ())
(declare-function decknix--hub-ci-filter-toggle-unknown "decknix-hub-ci-filter" ())
(declare-function decknix--hub-ci-filter-toggle-fail "decknix-hub-ci-filter" ())
(declare-function decknix--hub-ci-filter-show-all "decknix-hub-ci-filter" ())
(declare-function decknix--hub-ci-filter-show-none "decknix-hub-ci-filter" ())
(declare-function decknix--hub-ci-filter-status-desc
                  "decknix-hub-ci-filter" (status icon label))

(transient-define-suffix decknix--hub-ci-filter--pass ()
  :key "g"
  :description (lambda () (decknix--hub-ci-filter-status-desc
                           "pass" "✓" "green   (pass)"))
  :transient t
  (interactive)
  (decknix--hub-ci-filter-toggle-pass))

(transient-define-suffix decknix--hub-ci-filter--soft ()
  :key "l"
  :description (lambda () (decknix--hub-ci-filter-status-desc
                           "soft_fail" "⚠" "lint    (soft-fail)"))
  :transient t
  (interactive)
  (decknix--hub-ci-filter-toggle-soft))

(transient-define-suffix decknix--hub-ci-filter--running ()
  :key "y"
  :description (lambda () (decknix--hub-ci-filter-status-desc
                           "running" "⟳" "yellow  (running)"))
  :transient t
  (interactive)
  (decknix--hub-ci-filter-toggle-running))

(transient-define-suffix decknix--hub-ci-filter--unknown ()
  :key "?"
  :description (lambda () (decknix--hub-ci-filter-status-desc
                           "unknown" "?" "grey    (unknown)"))
  :transient t
  (interactive)
  (decknix--hub-ci-filter-toggle-unknown))

(transient-define-suffix decknix--hub-ci-filter--fail ()
  :key "r"
  :description (lambda () (decknix--hub-ci-filter-status-desc
                           "fail" "✗" "red     (hard-fail)"))
  :transient t
  (interactive)
  (decknix--hub-ci-filter-toggle-fail))

(transient-define-prefix decknix-hub-ci-filter-transient ()
  "Toggle visibility of CI statuses in the Requests list.

Each status can be turned on or off independently.  Combine them to
show, for example, only hard failures and unknowns while hiding
lint-only failures and still-running checks."
  [:description
   (lambda ()
     ;; Summary already carries per-icon faces — must not
     ;; re-propertize or the status colours are overwritten.
     (concat "CI filter  ["
             (decknix--hub-ci-filter-summary)
             "]"))
   (decknix--hub-ci-filter--pass)
   (decknix--hub-ci-filter--soft)
   (decknix--hub-ci-filter--running)
   (decknix--hub-ci-filter--unknown)
   (decknix--hub-ci-filter--fail)]
  [""
   ("a" "Show all" decknix--hub-ci-filter-show-all :transient t)
   ("n" "Show none" decknix--hub-ci-filter-show-none :transient t)
   ("q" "Done" transient-quit-one)])

(defun decknix--hub-cycle-mention-filter ()
  "Cycle the mention filter through off → me → team → me+team → off."
  (interactive)
  (let* ((cycle decknix--hub-mention-filter-cycle)
         (cur (or (memq decknix--hub-mention-filter cycle) cycle))
         (next (or (cadr cur) (car cycle))))
    (setq decknix--hub-mention-filter next))
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (message "Mention filter: %s" (decknix--hub-mention-filter-label)))

;; Backwards-compat alias for any caller / keybinding that still
;; refers to the old binary toggle name.
(defalias 'decknix--hub-toggle-mention-filter
  'decknix--hub-cycle-mention-filter)

(defun decknix--hub-toggle-bot-filter ()
  "Toggle visibility of bot-authored PRs (e.g. dependabot)."
  (interactive)
  (setq decknix--hub-show-bots (not decknix--hub-show-bots))
  (when (get-buffer "*agent-shell-sidebar*")
    (agent-shell-workspace-sidebar-refresh))
  (message "Bot PRs: %s"
           (if decknix--hub-show-bots "shown" "hidden")))

;; -- Hub: attention filters (needs-reply / bot-pending / replies-to-me) --
;;
;; Source moved out of this file into
;; agent-shell/hub/decknix-hub-attention-filter.el, packaged as
;; `decknix-hub-attention-filter-el'.  Owns the seven defvars
;; (Requests + WIP toggle state plus the Requests sort-reverse
;; flag), the engine (sort-requests, attention-visible-p shared
;; predicate, requests-/wip- flavoured wrappers), the shared
;; `toggle-and-refresh' helper, and the seven per-bucket toggle
;; commands wired to the sidebar Toggles transient (`T') and
;; footer.  The transient suffix / prefix forms that surface
;; these commands stay in workspace-bulk's broader transient
;; cluster.

;; Forward declarations so the surrounding hub-bulk code (which
;; reads the defvars and calls the engine functions when rendering
;; rows) byte-compiles clean against the moved symbols.
(defvar decknix--hub-requests-hide-needs-reply)
(defvar decknix--hub-requests-hide-bot-pending)
(defvar decknix--hub-requests-only-my-replies)
(defvar decknix--hub-requests-sort-reverse)
(defvar decknix--hub-wip-hide-needs-reply)
(defvar decknix--hub-wip-hide-bot-pending)
(defvar decknix--hub-wip-only-my-replies)
(declare-function decknix--hub-sort-requests "decknix-hub-attention-filter" (items))
(declare-function decknix--hub-attention-visible-p
                  "decknix-hub-attention-filter"
                  (item hide-reply hide-bot only-my))
(declare-function decknix--hub-requests-attention-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-wip-attention-visible-p
                  "decknix-hub-attention-filter" (pr))
(declare-function decknix--hub-toggle-and-refresh
                  "decknix-hub-attention-filter" (sym message-fmt))

;; -- Hub: active review detection --
;; Cross-references request items against live agent-shell buffers
;; to detect PRs that already have a review session open.
(defun decknix--hub-request-has-live-session-p (item)
  "Return non-nil if ITEM's PR has a live agent-shell review session.
Checks buffer names for the pattern `pr-<repo>-<number>'."
  (let* ((repo-full (or (alist-get 'repo item) ""))
         (repo (car (last (split-string repo-full "/"))))
         (number (alist-get 'number item))
         (needle (format "pr-%s-%s" repo number)))
    (and (fboundp 'agent-shell-buffers)
         (seq-some (lambda (buf)
                     (string-match-p (regexp-quote needle)
                                     (buffer-name buf)))
                   (agent-shell-buffers)))))

(defvar decknix--hub-request-active-face
  '(:foreground "#d7af5f")
  "Face spec applied to Request rows / picker labels under
review by a live agent session.  The same warm gold used by the
`me' @-mention badge so the colour vocabulary stays consistent
with other \"this is yours to act on\" signals.  Composed via
`add-face-text-property' with `append', so per-column faces
(repo, age, CI, status icons) keep their semantic colours and
only the neutral text (title, `#NUMBER', separators) takes on
the tint \u2014 a subtle whole-row cue that does not fight the
column-by-column rendering.")

(defun decknix--hub-request-tint-active (str item)
  "Tint STR yellow when ITEM is a Request with a live review session.
Mutates STR in place via `add-face-text-property' (`append' merge
order) and returns it for fluent use at call sites.  No-op when no
live session exists, so callers can wrap unconditionally."
  (when (and (stringp str)
             (> (length str) 0)
             (decknix--hub-request-has-live-session-p item))
    (add-face-text-property 0 (length str)
                            decknix--hub-request-active-face
                            'append str))
  str)

;; -- Hub: live-linked PR set --
;; Build a hash table of "owner/repo#number" keys for every PR
;; linked to any live agent-shell session. Used to hide WIP PRs
;; already being reviewed / worked on in a live session.
(defun decknix--hub-live-linked-pr-set ()
  "Return a hash table of live-linked PR keys.
Each key is the string \"OWNER/REPO#NUMBER\"; value is t.
Returns an empty table when no live sessions exist."
  (let ((set (make-hash-table :test 'equal)))
    (when (fboundp 'agent-shell-buffers)
      (dolist (buf (agent-shell-buffers))
        (when (buffer-live-p buf)
          (let ((ck (with-current-buffer buf
                      (decknix--agent-current-conv-key))))
            (when ck
              (dolist (pr (decknix--agent-linked-prs ck))
                (let* ((url (decknix--agent-pr-url-accessor pr "url"))
                       (parsed (decknix--agent-pr-parse-url url)))
                  (when parsed
                    (let ((owner (nth 0 parsed))
                          (repo (nth 1 parsed))
                          (num (nth 2 parsed)))
                      (puthash (format "%s/%s#%d" owner repo num)
                               t set))))))))))
    set))

(defun decknix--hub-wip-pr-live-linked-p (repo-full number set)
  "Return non-nil if PR REPO-FULL#NUMBER is present in SET.
SET is a hash table as produced by `decknix--hub-live-linked-pr-set'."
  (and set number repo-full
       (gethash (format "%s#%d" repo-full number) set)))

;; -- Hub: PR expand toggle --
(defvar decknix--hub-expand-prs nil
  "How linked PRs are displayed under sessions in sidebar.
Valid values: nil (badges only), `pr' (PR status lines),
`pipeline' (deploy indicators only), `both' (PR + pipeline).")

(defun decknix--hub-cycle-expand-prs ()
  "Cycle expanded display of linked PRs: off → pr → pipeline → both."
  (interactive)
  (setq decknix--hub-expand-prs
        (pcase decknix--hub-expand-prs
          ('nil 'pr)
          ('pr 'pipeline)
          ('pipeline 'both)
          ('both nil)
          (_ nil)))
  (when (get-buffer "*agent-shell-sidebar*")
    (agent-shell-workspace-sidebar-refresh))
  (message "Session PRs: %s"
           (pcase decknix--hub-expand-prs
             ('nil "badges only")
             ('pr "PR status")
             ('pipeline "pipeline only")
             ('both "PR + pipeline"))))

;; -- Hub: symbol style (ascii vs emoji) --
(defvar decknix--hub-symbol-style 'ascii
  "Symbol set used in expanded PR lines.
`ascii' = compact glyphs (existing look: ✓merged ✓ ✗).
`emoji' = coloured emoji (🔀 ✅ ❌ 🟡 ❔ ⚠).")

(defun decknix--hub-sym (key)
  "Return the symbol string for KEY honouring `decknix--hub-symbol-style'.
KEY is one of: merged closed open draft loading pass fail running
unknown conflict."
  (let ((emoji '((merged   . "🔀")
                 (closed   . "🚫")
                 (open     . "◍")
                 (draft    . "📝")
                 (loading  . "⟳")
                 (pass     . "✅")
                 (fail     . "❌")
                 (running  . "🟡")
                 (unknown  . "❔")
                 (conflict . "⚠")))
        (ascii '((merged   . "✓merged")
                 (closed   . "✗closed")
                 (open     . "open")
                 (draft    . "draft")
                 (loading  . "⟳")
                 (pass     . "✓")
                 (fail     . "✗")
                 (running  . "⟳")
                 (unknown  . "?")
                 (conflict . "⇌"))))
    (or (alist-get key (if (eq decknix--hub-symbol-style 'emoji)
                           emoji ascii))
        "?")))

(defun decknix--hub-toggle-symbol-style ()
  "Toggle the expanded PR symbol style between `ascii' and `emoji'."
  (interactive)
  (setq decknix--hub-symbol-style
        (if (eq decknix--hub-symbol-style 'emoji) 'ascii 'emoji))
  (when (get-buffer "*agent-shell-sidebar*")
    (agent-shell-workspace-sidebar-refresh))
  (message "PR symbols: %s" decknix--hub-symbol-style))

;; Hub repo-name cap (PR B.36) — moved out of this file into
;; agent-shell/hub/decknix-hub-repo-name.el, packaged as
;; `decknix-hub-repo-name-el'.  Owns the cap state defvar
;; (`decknix--hub-repo-name-cap', forward-declared near line 142
;; for the earlier transient-suffix label use), the pure
;; truncator (`decknix--hub-repo-name-apply', called from the
;; columnar PR row renderers below), and the interactive cycler
;; (`decknix--hub-cycle-repo-name-cap', bound via the `N' suffix
;; in the sidebar Toggles transient).  The transient suffix
;; itself stays in this file per AGENTS.md Rule 2.
(declare-function decknix--hub-repo-name-apply "decknix-hub-repo-name" (repo))
(declare-function decknix--hub-cycle-repo-name-cap "decknix-hub-repo-name")

;; -- Hub: WIP de-dupe toggle (PR B.39) --
;; Moved out of this file into
;; agent-shell/hub/decknix-hub-wip-link-filter.el, packaged as
;; `decknix-hub-wip-link-filter-el'.  Owns the cap state defvar
;; (`decknix--hub-wip-hide-linked', forward-declared near line
;; 139 for the earlier transient-suffix label use at line 607)
;; and the interactive flipper (`decknix--hub-toggle-wip-hide-
;; linked').  The transient suffix that surfaces the toggle in
;; the sidebar Toggles transient (`L', line ~601 above) stays
;; in this file per AGENTS.md Rule 2.
(declare-function decknix--hub-toggle-wip-hide-linked
                  "decknix-hub-wip-link-filter")

;; -- Hub: WIP join — look up live PR status from hub data --
;;
;; The PR status cache (`decknix--hub-pr-cache' hash + the TTL
;; constants + `-cache-save' / `-cache-restore') was carved out
;; into `agent-shell/hub/decknix-hub-pr-cache.el' as PR B.24.
;; Forward declarations below keep the rest of this file's
;; byte-compile clean.  The async fetcher
;; (`decknix--hub-pr-fetch-async', defined below) and the
;; data-accessor reader (`decknix--hub-pr-cache-get' in
;; `decknix-hub-pr-lookup') stay in their existing homes.

(declare-function decknix--hub-pr-cache-save "decknix-hub-pr-cache")
(declare-function decknix--hub-pr-cache-restore "decknix-hub-pr-cache")
(defvar decknix--hub-pr-cache)
(defvar decknix--hub-pr-cache-ttl)
(defvar decknix--hub-pr-cache-orphan-ttl)
(defvar decknix--hub-pr-cache-file)
(defvar decknix--hub-pr-pending-fetches)

(defun decknix--hub-pr-fetch-async (url)
  "Fetch PR status for URL via `gh pr view' asynchronously.
Populates `decknix--hub-pr-cache' and refreshes the sidebar on completion."
  (when (and url (not (gethash url decknix--hub-pr-pending-fetches)))
    (let ((parsed (decknix--agent-pr-parse-url url)))
      (when parsed
        (let* ((full-repo (format "%s/%s" (nth 0 parsed) (nth 1 parsed)))
               (number (nth 2 parsed))
               (cmd (format "gh pr view %d -R %s --json state,statusCheckRollup,mergeable,mergedAt,updatedAt,title,headRefName,isDraft"
                            number full-repo)))
          (puthash url t decknix--hub-pr-pending-fetches)
          (condition-case err
              ;; Use pipe (not PTY) so gh doesn't detect a terminal
              ;; and try to open a pager, which hangs in the daemon.
              (let* ((process-connection-type nil)
                     (proc (start-process-shell-command
                            (format "hub-pr-%s-%d" (nth 1 parsed) number)
                            (generate-new-buffer " *hub-pr-fetch*")
                            cmd)))
                (set-process-sentinel
                 proc
                 (eval `(lambda (proc _event)
                          (when (memq (process-status proc) '(exit signal))
                            (unwind-protect
                                (let ((exit-code (process-exit-status proc))
                                      (output (when (buffer-live-p (process-buffer proc))
                                                (with-current-buffer (process-buffer proc)
                                                  (buffer-string)))))
                                  (if (/= exit-code 0)
                                      (message "hub-pr-fetch: %s exited %d: %s"
                                               ,url exit-code
                                               (string-trim (or output "")))
                                    (condition-case err
                                        (let* ((data (json-parse-string output
                                                       :object-type 'alist
                                                       :array-type 'list
                                                       :null-object nil
                                                       :false-object nil))
                                               (state (or (alist-get 'state data) "UNKNOWN"))
                                               (rollup (alist-get 'statusCheckRollup data))
                                               (ci-status
                                                (cond
                                                 ((null rollup) nil)
                                                 ((seq-every-p
                                                   (lambda (c)
                                                     (member (or (alist-get 'conclusion c)
                                                                 (alist-get 'status c))
                                                             '("SUCCESS" "COMPLETED" "NEUTRAL" "SKIPPED")))
                                                   rollup)
                                                  "pass")
                                                 ((seq-some
                                                   (lambda (c)
                                                     (member (or (alist-get 'status c) "")
                                                             '("IN_PROGRESS" "QUEUED" "PENDING")))
                                                   rollup)
                                                  "running")
                                                 (t "fail")))
                                               ;; Extract individual check details
                                               (check-details
                                                (when rollup
                                                  (mapcar
                                                   (lambda (c)
                                                     (list
                                                      (cons 'name (or (alist-get 'name c)
                                                                      (alist-get 'context c)
                                                                      "?"))
                                                      (cons 'conclusion
                                                            (or (alist-get 'conclusion c)
                                                                (alist-get 'status c)
                                                                "UNKNOWN"))))
                                                   rollup)))
                                               (result
                                                (list
                                                 (cons 'state state)
                                                 (cons 'draft (eq (alist-get 'isDraft data) t))
                                                 (cons 'ci-status ci-status)
                                                 (cons 'checks check-details)
                                                 (cons 'merged_at (alist-get 'mergedAt data))
                                                 (cons 'updated_at (alist-get 'updatedAt data))
                                                 (cons 'title (alist-get 'title data))
                                                 (cons 'branch (alist-get 'headRefName data))
                                                 (cons 'mergeable (alist-get 'mergeable data)))))
                                          (puthash ,url (cons (float-time) result)
                                                   decknix--hub-pr-cache))
                                      (error
                                       (message "hub-pr-fetch: parse error for %s: %s"
                                                ,url (error-message-string err))))))
                              ;; Always clear pending flag and clean up buffer
                              (remhash ,url decknix--hub-pr-pending-fetches)
                              (when (buffer-live-p (process-buffer proc))
                                (kill-buffer (process-buffer proc)))
                              ;; Schedule a single deferred sidebar refresh so we
                              ;; don't refresh N times for N concurrent fetches.
                              ;; The timer coalesces: if one is already pending
                              ;; the new one replaces it, so only the last fires.
                              (when (get-buffer "*agent-shell-sidebar*")
                                (when (timerp decknix--hub-pr-refresh-timer)
                                  (cancel-timer decknix--hub-pr-refresh-timer))
                                (setq decknix--hub-pr-refresh-timer
                                      (run-at-time 0.3 nil
                                        (lambda ()
                                          (setq decknix--hub-pr-refresh-timer nil)
                                          (when (get-buffer "*agent-shell-sidebar*")
                                            (ignore-errors
                                              (agent-shell-workspace-sidebar-refresh))))))))))
                       t)))
            (error
             ;; Process creation failed — clear pending flag
             (remhash url decknix--hub-pr-pending-fetches)
             (message "hub-pr-fetch: process error for %s: %s"
                      url (error-message-string err)))))))))

(defvar decknix--hub-pr-refresh-timer nil
  "Timer for coalesced sidebar refresh after PR status fetches.")

;; -- Repo HEAD status fetch (on-demand) --
;;
;; Linked repos (type=\"repo\") don't flow through the hub daemon;
;; we fetch their HEAD commit + combined CI state directly via
;; `gh api graphql' and cache the result per (repo, branch).
;;
;; The cache state (`decknix--hub-repo-cache' hash + TTL constant
;; + `-cache-save' / `-cache-restore') was carved out into
;; `agent-shell/hub/decknix-hub-repo-cache.el' as PR B.27, mirroring
;; the PR-cache extraction (B.24).  Forward declarations below keep
;; the rest of this file's byte-compile clean.  The async fetcher
;; (`decknix--hub-repo-fetch-async', defined below) and the
;; cache-reader / status orchestrator (`decknix--hub-repo-cache-get'
;; and `decknix--hub-repo-status', defined immediately after) stay
;; here because they call the fetcher.
;;
;; `decknix--hub-repo-cache-key' lives in
;; agent-shell/agent/decknix-agent-url-parse.el — required at
;; the top of this heredoc.

(declare-function decknix--hub-repo-cache-save "decknix-hub-repo-cache")
(declare-function decknix--hub-repo-cache-restore "decknix-hub-repo-cache")
(defvar decknix--hub-repo-cache)
(defvar decknix--hub-repo-cache-ttl)
(defvar decknix--hub-repo-cache-file)
(defvar decknix--hub-repo-pending-fetches)

(defun decknix--hub-repo-cache-get (url branch)
  "Return cached HEAD status for URL+BRANCH if valid, else nil.
Stale entries return with `(stale . t)' and trigger an async refresh,
matching the `decknix--hub-pr-cache-get' pattern."
  (let* ((key (decknix--hub-repo-cache-key url branch))
         (entry (and key (gethash key decknix--hub-repo-cache))))
    (when entry
      (let ((ts (car entry))
            (status (cdr entry)))
        (if (< (- (float-time) ts) decknix--hub-repo-cache-ttl)
            status
          (let ((stale-status (append status '((stale . t)))))
            (decknix--hub-repo-fetch-async url branch)
            stale-status))))))

(defun decknix--hub-repo-status (url branch)
  "Return the current HEAD status alist for URL+BRANCH.
Consults the cache first; on miss/stale kicks off an async fetch and
returns either stale data (with `(stale . t)') or a loading sentinel."
  (let ((key (decknix--hub-repo-cache-key url branch)))
    (when key
      (or (decknix--hub-repo-cache-get url branch)
          (progn
            (decknix--hub-repo-fetch-async url branch)
            (when (gethash key decknix--hub-repo-pending-fetches)
              '((state . "LOADING"))))))))

(defun decknix--hub-repo--handle-fetch-result (proc url branch key)
  "Parse PROC output, populate repo cache for URL+BRANCH under KEY.
Clears the pending flag and schedules a coalesced sidebar refresh.
Split out so the sentinel closure stays small — backquote capture of
large bodies is expensive under dynamic binding."
  (unwind-protect
      (let* ((exit-code (process-exit-status proc))
             (output (when (buffer-live-p (process-buffer proc))
                       (with-current-buffer (process-buffer proc)
                         (buffer-string)))))
        (if (/= exit-code 0)
            (message "hub-repo-fetch: %s@%s exited %d: %s"
                     url branch exit-code
                     (string-trim (or output "")))
          (condition-case err
              (let* ((data (json-parse-string output
                             :object-type 'alist
                             :array-type 'list
                             :null-object nil
                             :false-object nil))
                     (target (alist-get 'target
                              (alist-get 'ref
                               (alist-get 'repository
                                (alist-get 'data data)))))
                     (oid (alist-get 'oid target))
                     (committed-at (alist-get 'committedDate target))
                     (msg (alist-get 'messageHeadline target))
                     (rollup (alist-get 'statusCheckRollup target))
                     (rollup-state (and rollup
                                        (alist-get 'state rollup)))
                     (contexts (and rollup
                                    (alist-get 'nodes
                                     (alist-get 'contexts rollup))))
                     (ci-status
                      (pcase rollup-state
                        ("SUCCESS" "pass")
                        ("FAILURE" "fail")
                        ("ERROR" "fail")
                        ("PENDING" "running")
                        ("EXPECTED" "running")
                        (_ nil)))
                     (check-details
                      (when contexts
                        (mapcar
                         (lambda (c)
                           (list
                            (cons 'name (or (alist-get 'name c)
                                            (alist-get 'context c)
                                            "?"))
                            (cons 'conclusion
                                  (or (alist-get 'conclusion c)
                                      (alist-get 'state c)
                                      "UNKNOWN"))))
                         contexts)))
                     (result
                      (list
                       (cons 'sha oid)
                       (cons 'updated_at committed-at)
                       (cons 'title msg)
                       (cons 'branch branch)
                       (cons 'ci-status ci-status)
                       (cons 'checks check-details)
                       ;; Sentinel state so the renderer can
                       ;; distinguish repo rows from PR rows.
                       (cons 'state "HEAD"))))
                (when oid
                  (puthash key (cons (float-time) result)
                           decknix--hub-repo-cache)))
            (error
             (message "hub-repo-fetch: parse error for %s@%s: %s"
                      url branch (error-message-string err))))))
    (remhash key decknix--hub-repo-pending-fetches)
    (when (buffer-live-p (process-buffer proc))
      (kill-buffer (process-buffer proc)))
    ;; Coalesced refresh — shared with the PR-fetch timer so a
    ;; burst of PR+repo fetches collapses to a single redraw.
    (when (get-buffer "*agent-shell-sidebar*")
      (when (timerp decknix--hub-pr-refresh-timer)
        (cancel-timer decknix--hub-pr-refresh-timer))
      (setq decknix--hub-pr-refresh-timer
            (run-at-time 0.3 nil
              (lambda ()
                (setq decknix--hub-pr-refresh-timer nil)
                (when (get-buffer "*agent-shell-sidebar*")
                  (ignore-errors
                    (agent-shell-workspace-sidebar-refresh)))))))))

(defun decknix--hub-repo-fetch-async (url branch)
  "Fetch HEAD commit + combined CI state for URL+BRANCH asynchronously.
Populates `decknix--hub-repo-cache' and refreshes the sidebar on
completion.  Uses `gh api graphql' (one round-trip) and parses the
rollup into the same shape PR records use so downstream renderers
(CI column, DTSP) can consume it without branching."
  (let* ((key (decknix--hub-repo-cache-key url branch))
         (parsed (decknix--agent-repo-parse-url url)))
    (when (and key parsed branch
               (not (gethash key decknix--hub-repo-pending-fetches)))
      (let* ((owner (nth 0 parsed))
             (repo (nth 1 parsed))
             (gql (concat
                   "query($owner:String!,$repo:String!,$ref:String!){"
                   "repository(owner:$owner,name:$repo){"
                   "ref(qualifiedName:$ref){target{"
                   "... on Commit{oid committedDate messageHeadline "
                   "statusCheckRollup{state contexts(first:50){nodes{"
                   "__typename "
                   "... on CheckRun{name conclusion} "
                   "... on StatusContext{context state}"
                   "}}}}}}}}")))
        (puthash key t decknix--hub-repo-pending-fetches)
        (condition-case err
            (let ((proc (make-process
                         :name (format "hub-repo-%s-%s-%s"
                                       owner repo branch)
                         :buffer (generate-new-buffer
                                  " *hub-repo-fetch*")
                         :connection-type 'pipe
                         :command
                         (list "gh" "api" "graphql"
                               "-F" (format "owner=%s" owner)
                               "-F" (format "repo=%s" repo)
                               "-F" (format "ref=refs/heads/%s" branch)
                               "-f" (format "query=%s" gql)))))
              (set-process-sentinel
               proc
               (eval `(lambda (proc _event)
                        (when (memq (process-status proc) '(exit signal))
                          (decknix--hub-repo--handle-fetch-result
                           proc ,url ,branch ,key)))
                     t)))
          (error
           (remhash key decknix--hub-repo-pending-fetches)
           (message "hub-repo-fetch: process error for %s@%s: %s"
                    url branch (error-message-string err))))))))

;; -- Hub: worktree registry (#128) ---------------------------------
;; Cache-backed answers to "is there a clone of OWNER/REPO?" and
;; "is BRANCH already checked out in a worktree on that clone?".
;; Everything is async (`make-process') so a stale NFS mount can't
;; wedge redisplay.  The on-disk cache lives at
;; `~/.config/decknix/hub/worktrees.el' in the alist form spelt out
;; in `specs/sidebar-ret.md' §3.6.1 so external consumers (the `wt'
;; CLI from `specs/worktree-cli.md', a vim plugin) can read it
;; directly without going through Emacs.

(defcustom decknix-hub-clones nil
  "Explicit alist of (\"owner/repo\" . \"/path/to/clone\") overrides.
Takes precedence over auto-discovered clones (sessions, project.el).
Personal `decknix-config' may set this to pin a primary checkout when
multiple worktrees exist."
  :type '(alist :key-type string :value-type string)
  :group 'decknix)

(defcustom decknix-hub-eager-clone-probe nil
  "When non-nil, probe every known clone once on idle after startup.
Default `nil' keeps the registry strictly lazy.  Flip to `t' if the
first sidebar render after restart needs a warm cache."
  :type 'boolean
  :group 'decknix)

(defcustom decknix-hub-worktree-cache-ttl 60
  "TTL in seconds for cached `git worktree list --porcelain' probes."
  :type 'integer
  :group 'decknix)

(defvar decknix--hub-worktree-cache (make-hash-table :test 'equal)
  "Worktree registry: \"owner/repo\" -> plist (:primary :worktrees :ts :stale).
See `specs/sidebar-ret.md' §3.6.1 for the on-disk format.")

(defvar decknix--hub-worktree-cache-file
  (expand-file-name "~/.config/decknix/hub/worktrees.el")
  "Persistence file for `decknix--hub-worktree-cache'.")

(defvar decknix--hub-worktree-pending (make-hash-table :test 'equal)
  "Set of repo keys currently being probed.")

(defvar decknix--hub-worktree-clone-map (make-hash-table :test 'equal)
  "Memoised: workspace path -> \"owner/repo\" or :unknown.
Avoids re-running `git config --get remote.origin.url' on every
sidebar refresh for paths we have already classified.")

(defun decknix--hub-worktree-classify-dir (dir)
  "Return canonical \"owner/repo\" for DIR or :unknown.
Memoised in `decknix--hub-worktree-clone-map'."
  (let* ((canon (file-name-as-directory (expand-file-name dir)))
         (cached (gethash canon decknix--hub-worktree-clone-map)))
    (or cached
        (let ((repo (or (and (file-directory-p canon)
                             (decknix--hub-worktree-repo-from-url
                              (decknix--git-remote-url canon)))
                        :unknown)))
          (puthash canon repo decknix--hub-worktree-clone-map)
          repo))))

(defun decknix--hub-worktree-discover-from-sessions ()
  "Walk agent-sessions.json workspaces; return alist (REPO . PATH).
First match per repo wins; subsequent matches are dropped so explicit
overrides from `decknix-hub-clones' can override later in the merge."
  (let ((seen (make-hash-table :test 'equal))
        (out nil))
    (condition-case nil
        (let* ((store (decknix--agent-tags-read))
               (convs (and store
                           (decknix--agent-tags-conversations store))))
          (when convs
            (maphash
             (lambda (_k entry)
               (let ((ws (and (hash-table-p entry)
                              (gethash "workspace" entry))))
                 (when (and ws (stringp ws) (file-directory-p ws))
                   (let ((repo (decknix--hub-worktree-classify-dir ws)))
                     (when (and (stringp repo)
                                (not (gethash repo seen)))
                       (puthash repo t seen)
                       (push (cons repo ws) out))))))
             convs)))
      (error nil))
    out))

(defun decknix--hub-worktree-discover-clones ()
  "Return alist (REPO . PRIMARY-PATH) by merging discovery sources.
Priority: explicit `decknix-hub-clones' > cached `:primary' >
`agent-sessions.json' workspaces > `project.el' known projects.
All paths are normalised via `expand-file-name' so downstream
`git -C' invocations (no shell) see absolute paths."
  (let ((seen (make-hash-table :test 'equal))
        (out nil))
    ;; 1. Explicit defcustom (highest priority).
    (dolist (entry decknix-hub-clones)
      (let ((repo (decknix--hub-worktree-canonical-repo (car entry)))
            (path (decknix--hub-worktree-normalize-path (cdr entry))))
        (when (and repo path (not (gethash repo seen)))
          (puthash repo t seen)
          (push (cons repo path) out))))
    ;; 2. Cached entries' :primary (last-known-good across restarts).
    (maphash (lambda (repo entry)
               (let ((p (decknix--hub-worktree-normalize-path
                         (plist-get entry :primary))))
                 (when (and p (not (gethash repo seen)))
                   (puthash repo t seen)
                   (push (cons repo p) out))))
             decknix--hub-worktree-cache)
    ;; 3. Sessions.
    (dolist (entry (decknix--hub-worktree-discover-from-sessions))
      (unless (gethash (car entry) seen)
        (puthash (car entry) t seen)
        (push (cons (car entry)
                    (decknix--hub-worktree-normalize-path (cdr entry)))
              out)))
    ;; 4. project.el known projects (best-effort; no-op without it).
    (when (fboundp 'project-known-project-roots)
      (dolist (root (ignore-errors (project-known-project-roots)))
        (when (and (stringp root) (file-directory-p root))
          (let ((repo (decknix--hub-worktree-classify-dir root))
                (path (decknix--hub-worktree-normalize-path root)))
            (when (and (stringp repo) (not (gethash repo seen)))
              (puthash repo t seen)
              (push (cons repo path) out))))))
    (nreverse out)))

(defun decknix--hub-worktree--handle-probe-result (proc repo primary)
  "Sentinel target: parse PROC output, update cache for REPO @ PRIMARY.
Split out so the sentinel closure stays small (backquote capture under
dynamic binding is expensive for large bodies — same reasoning as
`decknix--hub-repo--handle-fetch-result')."
  (unwind-protect
      (let* ((exit-code (process-exit-status proc))
             (output (when (buffer-live-p (process-buffer proc))
                       (with-current-buffer (process-buffer proc)
                         (buffer-string)))))
        (cond
         ((/= exit-code 0)
          (let ((entry (gethash repo decknix--hub-worktree-cache)))
            (puthash repo
                     (plist-put
                      (or entry
                          (list :primary primary
                                :worktrees nil :ts 0))
                      :stale t)
                     decknix--hub-worktree-cache))
          (message "hub-worktree: probe %s exited %d: %s"
                   repo exit-code
                   (string-trim (or output ""))))
         (t
          (let ((wts (decknix--hub-worktree-parse-porcelain output)))
            (puthash repo
                     (list :primary primary
                           :worktrees wts
                           :ts (float-time)
                           :stale nil)
                     decknix--hub-worktree-cache)))))
    (remhash repo decknix--hub-worktree-pending)
    (when (buffer-live-p (process-buffer proc))
      (kill-buffer (process-buffer proc)))
    ;; Coalesced sidebar refresh (shares the PR-fetch timer).
    (when (get-buffer "*agent-shell-sidebar*")
      (when (timerp decknix--hub-pr-refresh-timer)
        (cancel-timer decknix--hub-pr-refresh-timer))
      (setq decknix--hub-pr-refresh-timer
            (run-at-time 0.3 nil
              (lambda ()
                (setq decknix--hub-pr-refresh-timer nil)
                (when (get-buffer "*agent-shell-sidebar*")
                  (ignore-errors
                    (agent-shell-workspace-sidebar-refresh)))))))))

(defun decknix-hub-worktree-registry-refresh (&optional repo)
  "Force re-probe REPO (or every discovered clone if nil).
Returns immediately; results land in `decknix--hub-worktree-cache'
asynchronously and trigger a coalesced sidebar refresh on completion."
  (interactive)
  (let ((targets
         (if repo
             (let* ((rk (decknix--hub-worktree-canonical-repo repo))
                    (entry (gethash rk decknix--hub-worktree-cache))
                    (p (decknix--hub-worktree-normalize-path
                        (or (plist-get entry :primary)
                            (cdr (assoc rk
                                        (decknix--hub-worktree-discover-clones)))))))
               (when p (list (cons rk p))))
           (decknix--hub-worktree-discover-clones))))
    (dolist (entry targets)
      (let ((rk (car entry))
            (primary (decknix--hub-worktree-normalize-path
                      (cdr entry))))
        (when (and rk primary
                   (not (gethash rk decknix--hub-worktree-pending))
                   (file-directory-p primary))
          (puthash rk t decknix--hub-worktree-pending)
          (condition-case err
              (let ((proc (make-process
                           :name (format "hub-wt-%s" rk)
                           :buffer (generate-new-buffer
                                    " *hub-worktree-probe*")
                           :connection-type 'pipe
                           :command (list "git" "-C" primary
                                          "worktree" "list"
                                          "--porcelain"))))
                (set-process-sentinel
                 proc
                 (eval `(lambda (proc _event)
                          (when (memq (process-status proc)
                                      '(exit signal))
                            (decknix--hub-worktree--handle-probe-result
                             proc ,rk ,primary)))
                       t)))
            (error
             (remhash rk decknix--hub-worktree-pending)
             (message "hub-worktree: spawn error for %s: %s"
                      rk (error-message-string err)))))))))

(defun decknix-hub-worktree-registry-get (repo)
  "Return the registry plist for REPO or nil.
Triggers an async refresh when the entry is missing or older than
`decknix-hub-worktree-cache-ttl'.  Returns the existing entry
(possibly stale) immediately so callers can render without blocking."
  (when (stringp repo)
    (let* ((rk (decknix--hub-worktree-canonical-repo repo))
           (entry (gethash rk decknix--hub-worktree-cache))
           (ts (or (plist-get entry :ts) 0)))
      (when (or (null entry)
                (> (- (float-time) ts)
                   decknix-hub-worktree-cache-ttl))
        (decknix-hub-worktree-registry-refresh rk))
      entry)))

(defun decknix-hub-worktree-find (repo branch)
  "Return the worktree path for REPO @ BRANCH or nil."
  (when (and repo branch)
    (let* ((entry (decknix-hub-worktree-registry-get repo))
           (worktrees (plist-get entry :worktrees)))
      (cdr (assoc branch worktrees)))))

(defun decknix-hub-worktree-list (repo)
  "Return ((BRANCH . PATH) ...) worktrees for REPO or nil."
  (plist-get (decknix-hub-worktree-registry-get repo) :worktrees))

(defun decknix-hub-worktree-clones ()
  "Return the alist of known (REPO . PRIMARY-PATH) clones."
  (decknix--hub-worktree-discover-clones))

(defun decknix-hub-worktree-primary (repo)
  "Return the primary clone path for REPO or nil."
  (when (stringp repo)
    (let ((rk (decknix--hub-worktree-canonical-repo repo)))
      (or (plist-get (decknix-hub-worktree-registry-get rk) :primary)
          (cdr (assoc rk (decknix--hub-worktree-discover-clones)))))))

(defun decknix--hub-worktree-live-workspaces ()
  "Return a hash table of normalised workspace dirs used by live sessions.
Keys are file-name-as-directory expanded paths; value is t.  Used by
`decknix--hub-worktree-row-badge' to mark the active session's branch
with `⎇*' instead of plain `⎇'."
  (let ((set (make-hash-table :test 'equal)))
    (when (fboundp 'agent-shell-buffers)
      (dolist (buf (agent-shell-buffers))
        (when (buffer-live-p buf)
          (let ((dir (with-current-buffer buf
                       default-directory)))
            (when (and dir (stringp dir))
              (puthash (file-name-as-directory
                        (expand-file-name dir))
                       t set))))))
    set))

(defun decknix--hub-worktree-row-badge (repo branch)
  "Return a 2-char propertized badge for REPO @ BRANCH (spec §3.6.3).
Glyphs:
  `⎇*' branch is live in some agent session (worktree path matches a
       buffer's `default-directory').
  `⎇ ' branch has its own worktree but no live session.
  `↓ ' repo has no local clone yet.
  `  ' otherwise (primary HEAD, branch ref only, missing context).
The badge always occupies 2 columns so adjacent rows align even when
the worktree state differs."
  (let* ((repo (and repo (stringp repo)
                    (decknix--hub-worktree-canonical-repo repo)))
         (primary (and repo (decknix-hub-worktree-primary repo)))
         (wt-path (and repo branch
                       (decknix-hub-worktree-find repo branch))))
    (cond
     ((not repo) "  ")
     ((not primary)
      (propertize "↓ "
                  'face '(:foreground "#5c6370" :weight bold)))
     ((not wt-path) "  ")
     ((file-equal-p wt-path primary) "  ")
     (t
      (let* ((live (decknix--hub-worktree-live-workspaces))
             (target (file-name-as-directory
                      (expand-file-name wt-path)))
             (in-use (gethash target live)))
        (if in-use
            (propertize "⎇*"
                        'face '(:foreground "#98c379" :weight bold))
          (propertize "⎇ "
                      'face '(:foreground "#61afef"))))))))



;; -- Persistence (mirrors decknix--hub-pr-cache pattern) -----------

(defun decknix--hub-worktree-cache-save ()
  "Persist the worktree cache to disk in the spec §3.6.1 alist form."
  (when (> (hash-table-count decknix--hub-worktree-cache) 0)
    (condition-case err
        (let (entries)
          (maphash (lambda (repo entry)
                     (push (cons repo entry) entries))
                   decknix--hub-worktree-cache)
          (make-directory (file-name-directory
                           decknix--hub-worktree-cache-file) t)
          (with-temp-file decknix--hub-worktree-cache-file
            (insert ";; Auto-generated worktree registry — do not edit\n")
            (insert ";; Format: ((\"owner/repo\" :primary PATH"
                    " :worktrees ((BRANCH . PATH) ...)"
                    " :ts FLOAT :stale BOOL) ...)\n")
            (prin1 entries (current-buffer))
            (insert "\n")))
      (error
       (message "hub-worktree-cache: save failed: %s"
                (error-message-string err))))))

(defun decknix--hub-worktree-cache-restore ()
  "Restore the worktree cache from disk."
  (when (file-exists-p decknix--hub-worktree-cache-file)
    (condition-case err
        (let ((entries
               (with-temp-buffer
                 (insert-file-contents
                  decknix--hub-worktree-cache-file)
                 (read (current-buffer)))))
          (when (listp entries)
            (dolist (entry entries)
              (when (and (consp entry) (stringp (car entry)))
                (puthash (car entry) (cdr entry)
                         decknix--hub-worktree-cache)))))
      (error
       (message "hub-worktree-cache: restore failed: %s"
                (error-message-string err))))))

;; -- Optional eager idle pass --------------------------------------

(defun decknix--hub-worktree-eager-pass ()
  "Probe every discovered clone once when the user is idle.
No-op unless `decknix-hub-eager-clone-probe' is non-nil."
  (when decknix-hub-eager-clone-probe
    (decknix-hub-worktree-registry-refresh)))

(defun decknix--hub-write-linked-prs ()
  "Write linked-prs.json to the hub directory for the daemon.
Collects linked PRs from all live agent-shell sessions, resolves
their branches from the PR cache, and writes a JSON file in the
same format as github-wip.json so the hub daemon can poll deploy
status for these branches."
  (when (and (fboundp 'agent-shell-buffers)
             (bound-and-true-p decknix--hub-dir))
    (let ((repo-map (make-hash-table :test 'equal)))
      ;; Collect linked PRs from all live sessions
      (dolist (buf (agent-shell-buffers))
        (when (buffer-live-p buf)
          (let ((ck (with-current-buffer buf
                      (decknix--agent-current-conv-key))))
            (when ck
              (dolist (pr (decknix--agent-linked-prs ck))
                (let* ((url (decknix--agent-pr-url-accessor pr "url"))
                       (parsed (when url (decknix--agent-pr-parse-url url))))
                  (when parsed
                    (let* ((owner (nth 0 parsed))
                           (repo (nth 1 parsed))
                           (number (nth 2 parsed))
                           (full-repo (format "%s/%s" owner repo))
                           ;; Get branch from PR cache
                           (status (when url (decknix--hub-pr-cache-get url)))
                           (branch (when status (alist-get 'branch status))))
                      (when branch
                        (let ((existing (gethash full-repo repo-map)))
                          (puthash full-repo
                                   (cons (list (cons 'number number)
                                               (cons 'branch branch))
                                         existing)
                                   repo-map)))))))))))
      ;; Build JSON structure matching github-wip.json format
      (let ((repos nil))
        (maphash (lambda (repo prs)
                   (push (list (cons 'repo repo)
                               (cons 'prs prs))
                         repos))
                 repo-map)
        (let ((json-data (json-encode
                          (list (cons 'repos repos)))))
          (condition-case err
              (with-temp-file (expand-file-name "linked-prs.json"
                                                decknix--hub-dir)
                (insert json-data "\n"))
            (error
             (message "hub: write linked-prs.json: %s"
                      (error-message-string err)))))))))


(defun decknix--hub-pr-status (url)
  "Look up live status of a GitHub PR URL.
Checks hub WIP/Reviews data and the async cache, preferring whichever
is more up-to-date.  Terminal states (MERGED, CLOSED) from the cache
always win over hub data showing OPEN, since the hub daemon may not
have polled GitHub yet after a merge/close.  Kicks off an async
`gh pr view' fetch if not found anywhere.

Hub results are mirrored into `decknix--hub-pr-cache' so that on
restart (before hub data loads or after the PR leaves WIP/Reviews)
the cache provides an immediate fallback instead of a bare spinner."
  (let ((hub-result (decknix--hub-pr-status-from-hub url))
        (cache-result (decknix--hub-pr-cache-get url)))
    (cond
     ;; Cache has a terminal state (MERGED/CLOSED) — always prefer it
     ;; over hub data, which may still show OPEN due to stale polling.
     ((and cache-result
           (member (alist-get 'state cache-result) '("MERGED" "CLOSED")))
      cache-result)
     ;; Hub data available — use it and mirror to cache
     (hub-result
      (puthash url (cons (float-time) hub-result)
               decknix--hub-pr-cache)
      hub-result)
     ;; Cache only (hub has no data for this PR).  If the cached
     ;; state is non-terminal, the PR has likely merged/closed
     ;; and fallen off the hub's WIP/Reviews lists — kick off an
     ;; async refresh so the cache picks up the new terminal state.
     ;; Use the shorter `decknix--hub-pr-cache-orphan-ttl' here
     ;; so the columnar state catches up within a single hub
     ;; cycle.  Still TTL-gated so each sidebar render (2s +
     ;; every hub-file change + every fetch completion) doesn't
     ;; spawn a fresh `gh pr view' per non-terminal PR — the
     ;; fetch-completion sentinel re-renders the sidebar, which
     ;; pegged Emacs at 100% CPU with 10+ linked PRs before
     ;; this guard.
     (cache-result
      (let ((entry (gethash url decknix--hub-pr-cache)))
        (when (and entry
                   (>= (- (float-time) (car entry))
                       decknix--hub-pr-cache-orphan-ttl)
                   (not (member (alist-get 'state cache-result)
                                '("MERGED" "CLOSED"))))
          (decknix--hub-pr-fetch-async url)))
      cache-result)
     ;; Nothing found — kick off async fetch
     (t
      (decknix--hub-pr-fetch-async url)
      ;; Return a loading sentinel so callers can show a spinner
      (when (gethash url decknix--hub-pr-pending-fetches)
        '((state . "LOADING")))))))

;; -- Hub: columnar PR row helpers --
;;
;; Column semantics (see /tmp/pr-row-mockups-v3.html):
;;   #N age state-word  CI  b  c  ✓  [⚠]  DTSP
;; State-word, age, and CI are always shown (even in pipeline mode);
;; bot/cmt/approval are only shown in `pr' or `both' mode;
;; DTSP is only shown in `pipeline' or `both' mode.
;; ⚠ is a conditional trailing flag on OPEN rows when GitHub reports
;; `mergeable = CONFLICTING'; it is omitted on non-conflict rows so
;; the DTSP column stays put for the common case.
;; Closed PRs render only the state word (all downstream columns
;; collapse because none of the signals apply).

(defun decknix--hub-state-word (state draft)
  "Return a padded, coloured state word for STATE and DRAFT.
OPEN renders in light blue (`#61afef'); DRAFT yellow; MERGED green;
CLOSED dim.  The returned string is padded to 6 columns so the
downstream glyph slots line up."
  (let* ((raw (cond ((string= state "MERGED")  "merged")
                    ((string= state "CLOSED")  "closed")
                    ((and (string= state "OPEN") draft) "draft")
                    ((string= state "OPEN")    "open")
                    ((string= state "LOADING") "load")
                    (t                         "?")))
         (face (cond ((string= state "MERGED")
                      '(:foreground "#98c379"))
                     ((string= state "CLOSED")
                      'font-lock-comment-face)
                     ((and (string= state "OPEN") draft)
                      '(:foreground "#e5c07b" :weight bold))
                     ((string= state "OPEN")
                      '(:foreground "#61afef" :weight bold))
                     ((string= state "LOADING")
                      'font-lock-comment-face)
                     (t 'font-lock-comment-face))))
    (propertize (format "%-6s" raw) 'face face)))

(defun decknix--hub-ci-column (_state ci)
  "Return the CI column glyph (`⟳') coloured by CI state.
Green = pass, red = fail, yellow = running, grey = idle/unknown.
For MERGED rows callers still get the real `ci-status' so an
in-flight default-branch build reads as yellow until cached."
  (let ((face (cond ((string= ci "pass")
                     '(:foreground "#98c379" :weight bold))
                    ((string= ci "fail")
                     '(:foreground "#e06c75" :weight bold))
                    ((string= ci "running")
                     '(:foreground "#e5c07b" :weight bold))
                    (t 'font-lock-comment-face))))
    (propertize "⟳" 'face face)))

(defun decknix--hub-bot-column (status)
  "Return the bot column glyph (`b') coloured by STATUS signals.
Yellow when a bot posted last and the action is still pending;
dim otherwise.  Phase 1a will extend this with explicit green/red
derived from per-bot review signatures."
  (let* ((state (or (alist-get 'state status) ""))
         (bot-pending (eq (alist-get 'bot_pending status) t))
         (face (cond ((string= state "MERGED")
                      'font-lock-comment-face)
                     (bot-pending
                      '(:foreground "#e5c07b" :weight bold))
                     (t 'font-lock-comment-face))))
    (propertize "b" 'face face)))

(defun decknix--hub-cmt-column (status)
  "Return the comments column glyph (`c') coloured by STATUS signals.

Tier 1 attention heuristic (per-thread isResolved + last-author):
- Yellow `c' (#e5c07b) when at least one inline review thread is
  unresolved AND the last commenter on it is not me.
- Bright green `c' (#98c379) when there are inline threads on the
  PR and none are actionable to me (all resolved, or I posted last
  in any unresolved one).
- For PRs with NO inline review threads, fall back to the legacy
  ladder: yellow on `needs_reply' (with `bot_pending' carved out
  for the `b' column), softer green on `replies_to_me', dim
  otherwise."
  (let* ((state (or (alist-get 'state status) ""))
         (needs-reply (eq (alist-get 'needs_reply status) t))
         (replies-to-me (eq (alist-get 'replies_to_me status) t))
         (bot-pending (eq (alist-get 'bot_pending status) t))
         (total-threads (alist-get 'total_threads status))
         (unresolved-threads (alist-get 'unresolved_threads status))
         (have-thread-data (and (numberp total-threads)
                                (> total-threads 0)))
         (face (cond ((string= state "MERGED")
                      'font-lock-comment-face)
                     ;; Tier 1: inline review threads exist — judge
                     ;; per-thread instead of via whole-PR last-author.
                     (have-thread-data
                      (cond ((and (numberp unresolved-threads)
                                  (> unresolved-threads 0))
                             '(:foreground "#e5c07b" :weight bold))
                            ;; All threads resolved or my-court — bright
                            ;; green so it stands out from `replies_to_me'.
                            (t
                             '(:foreground "#98c379" :weight bold))))
                     ;; Fallback ladder for PRs without inline threads:
                     ;; needs-reply dominates when it's a human asking
                     ;; (bot-pending already covers the bot-is-last case).
                     ((and needs-reply (not bot-pending))
                      '(:foreground "#e5c07b" :weight bold))
                     (replies-to-me
                      '(:foreground "#87d7af" :weight bold))
                     (t 'font-lock-comment-face))))
    (propertize "c" 'face face)))

(defun decknix--hub-approval-column (status)
  "Return the approval glyph (`✓'/`✗'/`?') coloured by STATUS.
Green `✓' = APPROVED, red `✗' = CHANGES_REQUESTED, yellow `?' =
review required / commented, dim `?' otherwise."
  (let* ((state (or (alist-get 'state status) ""))
         (kind (alist-get 'kind status))
         ;; Prefer the decision relevant to this PR's kind:
         ;; WIP (my PR) → overall review_decision
         ;; Review (their PR) → my own submitted state
         (decision (cond ((eq kind 'wip)
                          (alist-get 'review_decision status))
                         ((eq kind 'review)
                          (alist-get 'my_review status))
                         (t (or (alist-get 'review_decision status)
                                (alist-get 'my_review status)))))
         (glyph (cond ((equal decision "APPROVED")          "✓")
                      ((equal decision "CHANGES_REQUESTED") "✗")
                      (t                                    "?")))
         (face (cond ((string= state "MERGED")
                      'font-lock-comment-face)
                     ((equal decision "APPROVED")
                      '(:foreground "#98c379" :weight bold))
                     ((equal decision "CHANGES_REQUESTED")
                      '(:foreground "#e06c75" :weight bold))
                     ((member decision '("REVIEW_REQUIRED"
                                         "COMMENTED"
                                         "PENDING"))
                      '(:foreground "#e5c07b" :weight bold))
                     (t 'font-lock-comment-face))))
    (propertize glyph 'face face)))

(defun decknix--hub-pr-format-line (pr-link &optional width expand-mode grouped)
  "Format a single linked PR for sidebar display.
PR-LINK is a hash-table or alist from agent-sessions.json.
WIDTH is the available character width (default 40).
EXPAND-MODE controls what to show: `pr' (review columns only),
`pipeline' (deploy only), `both' (all), or non-nil (all).
When GROUPED is non-nil the caller is rendering a repo sub-header
already, so the repo prefix is omitted from the line.

Layout:
  <indent> #N <age> <state>  <CI>  <b> <c> <✓>  [⚠]  <DTSP>
CI and state are always shown; review columns follow in `pr'/`both',
DTSP follows in `pipeline'/`both'.  A trailing ⚠ appears on OPEN rows
when GitHub reports `mergeable = CONFLICTING'.  Closed PRs render only
the state word since every downstream signal is moot."
  (let* ((url (decknix--agent-pr-url-accessor pr-link "url"))
         (pr-type (decknix--agent-pr-url-accessor pr-link "type"))
         (parsed (decknix--agent-pr-parse-url url))
         (owner (nth 0 parsed))
         (repo (nth 1 parsed))
         (number (nth 2 parsed))
         (status (decknix--hub-pr-status url))
         (state (or (alist-get 'state status) "?"))
         (draft (eq (alist-get 'draft status) t))
         (ci (alist-get 'ci-status status))
         (stale (alist-get 'stale status))
         (merged-at (alist-get 'merged_at status))
         (_ (or width 40))
         ;; Resolve expand mode flags — state + age + CI always
         ;; visible; bot/cmt/approval only in `pr'/`both';
         ;; DTSP only in `pipeline'/`both'.
         (show-pr (memq expand-mode '(pr both t)))
         (show-pipeline (memq expand-mode '(pipeline both t)))
         ;; Repo label — capped when ungrouped, omitted when grouped
         (repo-label (if grouped
                         ""
                       (decknix--hub-repo-name-apply repo)))
         ;; Stale refresh indicator — dim ↻ shown at the left edge
         ;; when displaying cached data while a background refresh
         ;; is in flight.  Takes the place of leading whitespace.
         (refresh-str (if stale
                          (concat (propertize "↻" 'face 'font-lock-comment-face) " ")
                        "  "))
         ;; Age — right-aligned to 3 chars so everything after
         ;; lines up regardless of m/h/d suffix.
         (updated-at (alist-get 'updated_at status))
         (age-ts (or merged-at updated-at))
         (raw-age (if age-ts (decknix--hub-format-age age-ts) ""))
         (age-str (propertize (format "%3s" raw-age)
                              'face 'font-lock-comment-face))
         ;; Columns
         (state-word (decknix--hub-state-word state draft))
         (ci-col (decknix--hub-ci-column state ci))
         (bot-col (decknix--hub-bot-column status))
         (cmt-col (decknix--hub-cmt-column status))
         (approval-col (decknix--hub-approval-column status))
         ;; Conflict flag — trailing ⚠ on OPEN rows (draft or
         ;; not) when GitHub reports `mergeable = CONFLICTING'.
         ;; MERGED can't conflict; CLOSED short-circuits earlier.
         (mergeable (alist-get 'mergeable status))
         (conflict-col (when (and (equal mergeable "CONFLICTING")
                                  (string= state "OPEN"))
                         (propertize "⚠" 'face 'error)))
         ;; Deploy pipeline indicator — feature-branch for OPEN,
         ;; default-branch for MERGED.  Pass merged_at so envs
         ;; whose latest deploy finished before the PR merged
         ;; render grey (prevents false-positive greens).
         (branch (alist-get 'branch status))
         (repo-full (when (and owner repo)
                      (format "%s/%s" owner repo)))
         (deploy-branch (if (string= state "MERGED")
                            "__default__"
                          branch))
         (deploy-merged-at (when (string= state "MERGED") merged-at))
         (deploy-str
          (if (and show-pipeline
                   (member state '("OPEN" "MERGED"))
                   repo-full deploy-branch
                   (fboundp 'decknix--hub-deploy-indicator))
              (decknix--hub-deploy-indicator
               repo-full deploy-branch deploy-merged-at)
            ""))
         ;; Type prefix for subject PRs
         (type-prefix (if (string= pr-type "subject") "⊳ " ""))
         ;; Draft PRs dim the #N to mirror the comment-face
         ;; treatment in the WIP/Reviews sidebar sections.
         (num-str (if draft
                      (propertize (format "#%d" number)
                                  'face 'font-lock-comment-face)
                    (format "#%d" number)))
         ;; Assemble the signal zone (everything after the
         ;; state word).  Closed PRs skip it entirely; merged
         ;; PRs show dim placeholders until we implement the
         ;; supersede-detection cache (Phase 4).
         (dim-dot (propertize "·" 'face 'font-lock-comment-face))
         (signal-zone
          (cond
           ((string= state "CLOSED") "")
           ((string= state "MERGED")
            ;; CI still reflects the default-branch build for
            ;; the merge commit; review columns collapse since
            ;; bot/human/approval signals are moot post-merge.
            ;; Single-space separators keep the latter half
            ;; compact; `deploy-str' already has a leading space.
            (concat "  " ci-col
                    (if show-pr
                        (concat " " dim-dot " " dim-dot " " dim-dot)
                      "")
                    (if (and show-pipeline
                             (not (string-empty-p deploy-str)))
                        deploy-str
                      "")))
           (t
            (concat "  " ci-col
                    (if show-pr
                        (concat " " bot-col
                                " " cmt-col
                                " " approval-col)
                      "")
                    (if conflict-col
                        (concat " " conflict-col)
                      "")
                    (if (and show-pipeline
                             (not (string-empty-p deploy-str)))
                        deploy-str
                      ""))))))
    ;; Build the line then attach text properties for the unified
    ;; sidebar dispatcher (see specs/sidebar-ret.md §3.4).  Properties
    ;; cover every character including leading indent so that
    ;; (get-text-property (line-beginning-position) ...) resolves on
    ;; any column.  The conv-key property is set at the insertion
    ;; site since this formatter has no conversation context.
    ;; head-repo defaults to repo-full; fork PRs need daemon support
    ;; (headRepositoryOwner) before this can distinguish them — see #120.
    ;; wt-badge prepends the §3.6.3 worktree glyph (2-char slot,
    ;; consumes part of the leading indent so total width is
    ;; preserved on no-badge rows).
    (let* ((wt-badge (decknix--hub-worktree-row-badge
                      repo-full branch))
           (line (if grouped
                    (format "  %s%s%s%s %s %s%s"
                            wt-badge
                            refresh-str
                            type-prefix num-str
                            age-str
                            state-word
                            signal-zone)
                  (format "%s%s%s%s%s %s %s%s"
                          wt-badge
                          refresh-str
                          type-prefix repo-label num-str
                          age-str
                          state-word
                          signal-zone))))
      (propertize line
                  'decknix-hub-type 'linked-pr
                  'decknix-hub-url url
                  'decknix-hub-repo repo-full
                  'decknix-hub-number number
                  'decknix-hub-linked-kind (pcase pr-type
                                             ("authored" 'authored)
                                             ("subject" 'subject)
                                             (_ nil))
                  'decknix-hub-pr-state (pcase state
                                          ("OPEN" (if draft 'draft 'open))
                                          ("DRAFT" 'draft)
                                          ("MERGED" 'merged)
                                          ("CLOSED" 'closed)
                                          (_ nil))
                  'decknix-hub-ci-status ci
                  'decknix-hub-deploy-url nil
                  'decknix-hub-head-repo repo-full
                  'decknix-hub-head-branch branch))))

(defun decknix--hub-repo-format-line (repo-link &optional _width expand-mode grouped)
  "Format a single linked repo row for sidebar display.
REPO-LINK is a hash-table/alist with type=\"repo\" and a branch field.
EXPAND-MODE mirrors the PR formatter signature: `pipeline' / `both' / t
render the DTSP deploy column; `pr' / nil skip it (repos have no
bot/cmt/approval columns — there's no PR to review).
GROUPED=t omits the repo prefix (caller emits a repo sub-header).

Layout:
  grouped:    <indent> <branch> <sha7> <age>  <CI>  <DTSP>
  ungrouped:  <indent> <repo>   <branch> <sha7> <age>  <CI>  <DTSP>"
  (let* ((url (decknix--agent-pr-url-accessor repo-link "url"))
         (branch (or (decknix--agent-pr-url-accessor repo-link "branch")
                     "main"))
         (parsed (decknix--agent-repo-parse-url url))
         (owner (nth 0 parsed))
         (repo (nth 1 parsed))
         (repo-full (when (and owner repo)
                      (format "%s/%s" owner repo)))
         ;; Defensive: guard against early sidebar timers / stale
         ;; .eln caches where the repo-status subsystem isn't loaded yet.
         (status (and url
                      (fboundp 'decknix--hub-repo-status)
                      (decknix--hub-repo-status url branch)))
         (sha (alist-get 'sha status))
         (sha7 (if sha
                   (substring sha 0 (min 7 (length sha)))
                 "·······"))
         (ci (alist-get 'ci-status status))
         (stale (alist-get 'stale status))
         (committed-at (alist-get 'updated_at status))
         (raw-age (if committed-at
                      (decknix--hub-format-age committed-at)
                    ""))
         (age-str (propertize (format "%3s" raw-age)
                              'face 'font-lock-comment-face))
         (show-pipeline (memq expand-mode '(pipeline both t)))
         (repo-label (if grouped
                         ""
                       (decknix--hub-repo-name-apply repo)))
         (refresh-str (if stale
                          (concat (propertize "↻" 'face
                                              'font-lock-comment-face)
                                  " ")
                        "  "))
         ;; Branch name dim-keyword-ish so it reads as an
         ;; identifier but doesn't compete with the sha.
         (branch-str (propertize branch
                                 'face 'font-lock-keyword-face))
         (sha7-str (propertize sha7 'face 'font-lock-comment-face))
         (ci-col (decknix--hub-ci-column "HEAD" ci))
         (deploy-str
          (if (and show-pipeline repo-full branch
                   (fboundp 'decknix--hub-deploy-indicator))
              (decknix--hub-deploy-indicator repo-full branch nil)
            ""))
         (signal-zone
          (concat "  " ci-col
                  (if (and show-pipeline
                           (not (string-empty-p deploy-str)))
                      deploy-str
                    ""))))
    ;; Build the line then attach text properties for the unified
    ;; sidebar dispatcher (see specs/sidebar-ret.md §3.4).  head-repo
    ;; / head-branch mirror repo / branch so the worktree submenu
    ;; (#129) reads the same keys on every row type.  conv-key is
    ;; set at the insertion site in render-session-prs.  wt-badge
    ;; prepends the §3.6.3 worktree glyph (2-char slot, consumes
    ;; part of the leading indent so total width is preserved).
    (let* ((wt-badge (decknix--hub-worktree-row-badge
                      repo-full branch))
           (line (if grouped
                    (format "  %s%s%s %s %s%s"
                            wt-badge
                            refresh-str branch-str sha7-str age-str
                            signal-zone)
                  (format "%s%s%s %s %s %s%s"
                          wt-badge
                          refresh-str repo-label branch-str sha7-str
                          age-str signal-zone))))
      (propertize line
                  'decknix-hub-type 'linked-repo
                  'decknix-hub-url url
                  'decknix-hub-repo repo-full
                  'decknix-hub-branch branch
                  'decknix-hub-sha sha
                  'decknix-hub-linked-kind 'authored
                  'decknix-hub-ci-status ci
                  'decknix-hub-deploy-url nil
                  'decknix-hub-head-repo repo-full
                  'decknix-hub-head-branch branch))))

(defun decknix--hub-group-items-by-repo (items)
  "Group ITEMS (PR + repo link records) by owner/repo.
Returns a list of (REPO-FULL . ITEM-LIST) pairs, preserving input order.
Repo records use `decknix--agent-repo-parse-url'; PR records use
`decknix--agent-pr-parse-url'."
  (let (groups)
    (dolist (rec items)
      (let* ((url (decknix--agent-pr-url-accessor rec "url"))
             (tp (decknix--agent-pr-url-accessor rec "type"))
             (parsed (if (equal tp "repo")
                         (decknix--agent-repo-parse-url url)
                       (decknix--agent-pr-parse-url url)))
             (owner (nth 0 parsed))
             (repo (nth 1 parsed))
             (key (if (and owner repo)
                      (format "%s/%s" owner repo)
                    "unknown")))
        (let ((cell (assoc key groups)))
          (if cell
              (setcdr cell (append (cdr cell) (list rec)))
            (setq groups
                  (append groups (list (cons key (list rec)))))))))
    groups))

;; Alias preserved for existing callers that only deal with PRs.
(defalias 'decknix--hub-group-prs-by-repo
  'decknix--hub-group-items-by-repo)

(defun decknix--hub-item-recency-key (rec)
  "Return an ISO-8601 timestamp string for sorting REC by recency, or \"\".
For PRs uses `updated_at' from the live/cache status; for repos uses
`updated_at' (commit date) from the repo cache.  Missing / unfetched
items sort last."
  (let* ((url (decknix--agent-pr-url-accessor rec "url"))
         (tp (decknix--agent-pr-url-accessor rec "type"))
         ;; Guard against early sidebar timers firing before the repo
         ;; status subsystem is fully loaded (stale .eln caches, or a
         ;; daemon running pre-Phase-2 code that never saw these defuns).
         (status (cond
                  ((and (equal tp "repo")
                        (fboundp 'decknix--hub-repo-status))
                   (decknix--hub-repo-status
                    url
                    (or (decknix--agent-pr-url-accessor rec "branch")
                        "main")))
                  ((fboundp 'decknix--hub-pr-status)
                   (decknix--hub-pr-status url))
                  (t nil))))
    (or (alist-get 'updated_at status)
        (alist-get 'merged_at status)
        "")))

(defun decknix--hub-render-session-prs (conv-key expand-mode
                                                 &optional line-face extra-indent)
  "Insert grouped expanded linked-item lines for CONV-KEY.
Renders both linked PRs and linked repos, grouped by owner/repo.
Within each group, items are sorted by most-recent-activity first
(via `decknix--hub-item-recency-key').

EXPAND-MODE is forwarded to `decknix--hub-pr-format-line' and
`decknix--hub-repo-format-line'.
LINE-FACE, if non-nil, is applied uniformly to every inserted line
(used e.g. to dim lines for previous/greyed-out sessions).
EXTRA-INDENT is added to the repo sub-header indent.
Returns the number of lines inserted."
  (let ((inserted 0)
        (groups (decknix--hub-group-items-by-repo
                 (decknix--agent-linked-items conv-key)))
        (indent (or extra-indent "")))
    (dolist (g groups)
      (let* ((repo-full (car g))
             (repo (car (last (split-string repo-full "/"))))
             ;; Sort items within this group by recency (most
             ;; recent first).  ISO-8601 sorts lexicographically.
             ;; Use the Schwartzian / decorate-sort-undecorate
             ;; pattern so `decknix--hub-item-recency-key' is
             ;; evaluated exactly once per item (O(N)) rather
             ;; than from inside the sort predicate (O(N log N)).
             ;; Recency-key dispatches to `decknix--hub-pr-status'
             ;; / `decknix--hub-repo-status' and is not free; the
             ;; naive predicate was the hot path that pegged the
             ;; frame at 100% CPU whenever a repo group had a
             ;; handful of linked items (see #hub-loop).
             (items (mapcar #'cdr
                            (sort (mapcar
                                   (lambda (rec)
                                     (cons (decknix--hub-item-recency-key rec)
                                           rec))
                                   (cdr g))
                                  (lambda (a b)
                                    (string> (car a) (car b))))))
             (header (concat indent
                             (propertize (format "   %s" repo)
                                         'face 'font-lock-type-face))))
        (insert (if line-face
                    (propertize header 'face line-face)
                  header)
                "\n")
        (setq inserted (1+ inserted))
        (dolist (rec items)
          (let* ((tp (decknix--agent-pr-url-accessor rec "type"))
                 (line (if (equal tp "repo")
                           (decknix--hub-repo-format-line
                            rec nil expand-mode t)
                         (decknix--hub-pr-format-line
                          rec nil expand-mode t)))
                 (start (point)))
            (insert (if line-face
                        (propertize line 'face line-face)
                      line)
                    "\n")
            ;; Annotate row with its owning conversation so the
            ;; sidebar dispatcher can resolve session context from
            ;; any linked PR / repo row.  See specs/sidebar-ret.md §3.4.
            (when conv-key
              (put-text-property start (1- (point))
                                 'decknix-hub-conv-key conv-key))
            (setq inserted (1+ inserted))))))
    inserted))

(defun decknix--hub-pr-badge (conv-key)
  "Return a compact PR badge string for CONV-KEY, or empty string.
Shows count and summary like [2⬆ 1✓] (2 open, 1 merged)."
  (let ((prs (decknix--agent-linked-prs conv-key)))
    (if (not prs)
        ""
      (let ((n-open 0) (n-merged 0) (n-loading 0) (n-other 0))
        (dolist (pr prs)
          (let* ((url (decknix--agent-pr-url-accessor pr "url"))
                 (status (decknix--hub-pr-status url))
                 (state (or (alist-get 'state status) "?")))
            (cond
             ((string= state "MERGED") (cl-incf n-merged))
             ((string= state "OPEN") (cl-incf n-open))
             ((string= state "LOADING") (cl-incf n-loading))
             (t (cl-incf n-other)))))
        (let ((parts nil))
          (when (> n-open 0)
            (push (propertize (format "%d⬆" n-open)
                              'face 'font-lock-warning-face)
                  parts))
          (when (> n-merged 0)
            (push (propertize (format "%d✓" n-merged)
                              'face 'font-lock-string-face)
                  parts))
          (when (> n-loading 0)
            (push (propertize (format "%d⟳" n-loading)
                              'face '(:foreground "#e5c07b"))
                  parts))
          (when (> n-other 0)
            (push (propertize (format "%d?" n-other)
                              'face 'font-lock-comment-face)
                  parts))
          (if parts
              (format " [%s]" (string-join (nreverse parts) " "))
            ""))))))

;; -- Hub: session attention icons (📥 inbox / 📤 sent) --
;; Parallels the attention signals rendered on Requests/WIP rows, but
;; aggregated across all PRs linked to a conversation.  Surfaces
;; whether the live session still needs my input (review not yet
;; submitted, WIP has unanswered comments or CHANGES_REQUESTED) or
;; whether I have done my part and the ball is in the other court
;; (review submitted, WIP pushed and quiet).  Terminal PRs
;; (MERGED/CLOSED) are ignored so stale linked PRs do not add noise.
(defun decknix--hub-session-attention-icons (conv-key)
  "Return attention icons for a conversation's linked PRs.

Aggregates across every PR linked to CONV-KEY:
- 📥 N : N linked PRs awaiting my action (review pending, WIP needs reply
  or has CHANGES_REQUESTED).
- 📤 N : N linked PRs where I have acted and am awaiting others (review
  submitted, WIP pushed with no pending reply).
- ↩    : shown once when any linked PR has replies-to-me (cross-cutting).

Returns a leading-space string suitable for concatenation onto a sidebar
row, or an empty string when no linked PR is attention-worthy."
  (let ((prs (decknix--agent-linked-prs conv-key))
        (n-inbox 0)
        (n-sent 0)
        (any-replies nil))
    (when prs
      (dolist (pr prs)
        (let* ((url (decknix--agent-pr-url-accessor pr "url"))
               (status (and url (decknix--hub-pr-status-from-hub url)))
               (state (or (alist-get 'state status) ""))
               (kind (alist-get 'kind status)))
          ;; Skip terminal and unknown PRs — only active ones count
          (when (and status (member state '("OPEN" "DRAFT")))
            (when (eq (alist-get 'replies_to_me status) t)
              (setq any-replies t))
            (pcase kind
              ('review
               (if (alist-get 'my_review status)
                   (cl-incf n-sent)
                 (cl-incf n-inbox)))
              ('wip
               (let ((needs-reply (eq (alist-get 'needs_reply status) t))
                     (decision (alist-get 'review_decision status)))
                 (if (or needs-reply
                         (equal decision "CHANGES_REQUESTED"))
                     (cl-incf n-inbox)
                   (cl-incf n-sent)))))))))
    (let ((parts nil))
      (when (> n-inbox 0)
        (push (concat (decknix--hub-icon "📥" 'warning)
                      (propertize (format "%d" n-inbox)
                                  'face 'warning))
              parts))
      (when (> n-sent 0)
        (push (concat (decknix--hub-icon "📤" 'success)
                      (propertize (format "%d" n-sent)
                                  'face 'success))
              parts))
      (when any-replies
        (push (decknix--hub-icon
               "↩" '(:foreground "#87d7af" :weight bold))
              parts))
      (if parts
          (concat " " (string-join (nreverse parts) " "))
        ""))))

;; -- Hub: status hint when daemon not running --
(defun decknix--hub-has-data-p ()
  "Return non-nil if any hub data files exist and contain data."
  (or decknix--hub-reviews decknix--hub-wip
      decknix--hub-jira-tasks decknix--hub-teamcity-builds))

(defun decknix--hub-render-status-hint (line-num)
  "Show a setup hint when hub integration is enabled but no data exists.
Returns updated LINE-NUM."
  (unless (decknix--hub-has-data-p)
    (insert (propertize " Hub" 'face 'bold) "\n")
    (setq line-num (1+ line-num))
    (if (file-directory-p decknix--hub-dir)
        ;; Dir exists but no data — daemon may have just started
        (progn
          (insert (propertize "  waiting for data…"
                              'face 'font-lock-comment-face)
                  "\n")
          (setq line-num (1+ line-num)))
      ;; Dir doesn't exist — daemon not configured
      (insert (propertize "  not running — " 'face 'font-lock-comment-face)
              (propertize "? O" 'face 'font-lock-keyword-face)
              (propertize " for setup" 'face 'font-lock-comment-face)
              "\n")
      (setq line-num (1+ line-num)))
    (insert "\n")
    (setq line-num (1+ line-num)))
  line-num)

;; -- Hub: sidebar render helpers --
(defun decknix--hub-render-requests (line-num)
  "Render the Requests (PR reviews) section. Returns updated LINE-NUM.
Respects `decknix--hub-org-visibility' to show only items from enabled orgs."
  (let* ((data decknix--hub-reviews)
         (all-items (when data (alist-get 'items data)))
         (filtered (seq-filter
                    (lambda (item)
                      (and (decknix--hub-item-visible-p (alist-get 'repo item))
                           (decknix--hub-age-visible-p (alist-get 'created item))
                           (decknix--hub-ci-visible-p item)
                           (decknix--hub-mention-visible-p item)
                           (decknix--hub-bot-visible-p item)
                           (decknix--hub-requests-attention-visible-p item)))
                    (or all-items '())))
         (items (decknix--hub-sort-requests filtered)))
    (when items
      (decknix--sidebar-render-section-header
       (concat
        (format "Requests (%d)" (length items))
        ;; Mention badge — colour reflects current state:
        ;; me = yellow, team = blue, me+team = both glyphs.
        (pcase decknix--hub-mention-filter
          ('me      (concat " "
                            (decknix--hub-icon
                             "@" '(:foreground "#d7af5f" :weight bold))))
          ('team    (concat " "
                            (decknix--hub-icon
                             "@" '(:foreground "#61afef" :weight bold))))
          ('me+team (concat " "
                            (decknix--hub-icon
                             "@" '(:foreground "#d7af5f" :weight bold))
                            (decknix--hub-icon
                             "@" '(:foreground "#61afef" :weight bold))))
          (_        ""))
        (if decknix--hub-show-bots
            (concat " " (decknix--hub-icon "🤖" 'default))
          "")
        (if decknix--hub-requests-sort-reverse " ⇅" ""))
       'requests)
      (setq line-num (1+ line-num))
      (dolist (item items)
        (let* ((age (decknix--hub-format-age
                     (alist-get 'created item)))
               (repo-full (or (alist-get 'repo item) ""))
               ;; Show only repo name, not owner/repo
               (repo (car (last (split-string repo-full "/"))))
               (number (alist-get 'number item))
               (title (or (alist-get 'title item) ""))
               (ci (alist-get 'ci item))
               (mergeable (alist-get 'mergeable item))
               (ci-str (decknix--hub-ci-icon ci mergeable))
               (rev-str (decknix--hub-review-icon item))
               (status-str (if (string-empty-p rev-str)
                               ci-str
                             (concat ci-str rev-str)))
               ;; @ indicator — yellow when I am directly
               ;; requested / @-mentioned (`me'); blue when only
               ;; one of my teams is requested (`team').  When
               ;; both are true, prefer yellow (me precedence).
               (mention-me (decknix--hub-item-mentioned-p item))
               (mention-team (decknix--hub-item-team-requested-p item))
               (mention-str
                (cond
                 (mention-me
                  (decknix--hub-icon
                   "@" '(:foreground "#d7af5f" :weight bold)))
                 (mention-team
                  (decknix--hub-icon
                   "@" '(:foreground "#61afef" :weight bold)))
                 (t "")))
               (status-str (if (string-empty-p mention-str)
                               status-str
                             (concat status-str mention-str)))
               ;; Activity icons: 🤖 bot-pending, 💬 needs-reply, ↩ replies-to-me
               (reply-str (decknix--hub-activity-icons item))
               (status-str (if (string-empty-p reply-str)
                               status-str
                             (concat status-str reply-str)))
               ;; Active review indicator — shows when a live
               ;; agent session is already reviewing this PR
               (active-str (if (decknix--hub-request-has-live-session-p item)
                               (decknix--hub-icon "◉" '(:foreground "#87d7ff"))
                             ""))
               (status-str (if (string-empty-p active-str)
                               status-str
                             (concat status-str active-str)))
               (draft (alist-get 'draft item))
               (url (alist-get 'url item))
               ;; Truncate title to fit sidebar
               (max-title (max 8 (- (window-width) 18)))
               (short-title (if (> (length title) max-title)
                                (concat (substring title 0 (- max-title 1)) "…")
                              title))
               (age-face (cond
                          ((string-match-p "d$" age)
                           (if (>= (string-to-number age) 3)
                               'error 'warning))
                          (t 'font-lock-comment-face)))
               ;; Worktree badge for the repo (no branch context
               ;; on review items so this surfaces only `↓ ' /
               ;; `  ' — enough to flag missing local clones).
               (wt-badge (decknix--hub-worktree-row-badge
                          repo-full nil))
               (line (format "%s%3s %s#%d %s %s"
                             wt-badge
                             (propertize age 'face age-face)
                             (propertize (or repo "") 'face 'font-lock-type-face)
                             number
                             status-str
                             (if draft
                                 (propertize short-title 'face 'font-lock-comment-face)
                               short-title))))
          ;; Tint the row yellow when a live session is already
          ;; reviewing this PR (composes with per-column faces).
          (decknix--hub-request-tint-active line item)
          (insert (propertize line
                             'decknix-hub-url url
                             'decknix-hub-type 'review
                             'decknix-hub-repo repo-full
                             'decknix-hub-number number)
                  "\n")
          (setq line-num (1+ line-num))))
      (insert "\n")
      (setq line-num (1+ line-num))))
  line-num)
(defun decknix--hub-wip-placeholder-rows ()
  "Return alist ((REPO-FULL . ((BRANCH . PATH) ...)) ...) of
worktrees lacking a matching open PR in `decknix--hub-wip'.

Each `decknix-hub-worktree-clones' entry contributes one row per
worktree-listed branch whose path is not the primary clone and whose
branch does not already appear as a PR for the same repo in the WIP
data.  This lets the WIP section surface a freshly-created worktree
at t=0, before `gh pr create' has run or before GitHub's Search
index has caught up to a freshly-pushed PR.

Repo keys are canonicalised (lowercased) so the dedup against WIP
data is case-insensitive — `gh search prs' may return mixed casing
for `owner/repo' but the worktree registry stores lowercase."
  (let* ((data decknix--hub-wip)
         (all-repos (when data (alist-get 'repos data)))
         (existing (make-hash-table :test 'equal))
         (out nil))
    (dolist (repo-entry all-repos)
      (let* ((repo (decknix--hub-worktree-canonical-repo
                    (alist-get 'repo repo-entry)))
             (branches (delq nil
                             (mapcar (lambda (pr)
                                       (alist-get 'branch pr))
                                     (alist-get 'prs repo-entry)))))
        (when repo
          (puthash repo branches existing))))
    (dolist (clone (decknix-hub-worktree-clones))
      (let* ((repo (car clone))
             (primary (cdr clone))
             (worktrees (decknix-hub-worktree-list repo))
             (taken (gethash repo existing))
             rows)
        (dolist (wt worktrees)
          (let ((branch (car wt))
                (path (cdr wt)))
            (when (and branch path
                       (not (member branch taken))
                       (not (and primary
                                 (file-exists-p path)
                                 (file-exists-p primary)
                                 (file-equal-p path primary))))
              (push (cons branch path) rows))))
        (when rows
          (push (cons repo (nreverse rows)) out))))
    (nreverse out)))

(defun decknix--hub-render-wip-placeholder (line-num repo-full wt)
  "Render a single WIP placeholder row for WT under REPO-FULL.
WT is `(BRANCH . PATH)' from the worktree registry.  Returns updated
LINE-NUM.

Placeholder rows surface a local worktree that doesn't yet have an
open PR (or whose PR hasn't been picked up by the hub poller).  The
column shape mirrors a real WIP row so the worktree badge column,
age column, and title column stay aligned, but the `#N' + CI signal
zone collapses to the dim state-word `wip ' since none of those
signals exist for a branch-without-a-PR.  The row carries enough
text properties (`repo', `branch', `worktree-path') for the worktree
submenu to operate on it, but no `decknix-hub-url' so the row's
primary action is a no-op until a PR materialises."
  (let* ((branch (car wt))
         (path (cdr wt))
         (mtime (and path (file-exists-p path)
                     (file-attribute-modification-time
                      (file-attributes path))))
         (age (if mtime
                  (decknix--hub-format-age
                   (format-time-string "%FT%T%z" mtime))
                "?"))
         (wt-badge (decknix--hub-worktree-row-badge repo-full branch))
         (max-title (max 8 (- (window-width) 14)))
         (short-branch (if (> (length branch) max-title)
                           (concat (substring branch 0 (- max-title 1)) "…")
                         branch))
         (line (format "%s%3s %-4s %s"
                       wt-badge
                       (propertize age 'face 'font-lock-comment-face)
                       (propertize "wip" 'face 'font-lock-comment-face)
                       (propertize short-branch
                                   'face 'font-lock-comment-face))))
    (insert (propertize line
                        'decknix-hub-type 'wip-placeholder
                        'decknix-hub-repo repo-full
                        'decknix-hub-branch branch
                        'decknix-hub-worktree-path path)
            "\n")
    (1+ line-num)))

(defun decknix--hub-render-wip (line-num)
  "Render the WIP (my open PRs) section. Returns updated LINE-NUM.
Respects `decknix--hub-org-visibility'. Shows time since last update.
Honours `decknix--hub-wip-hide-linked' — PRs linked to a live
session are hidden (both from the header count and the listing).
Surfaces local worktrees lacking a matching open PR as dim
`wip' placeholder rows so a freshly-created worktree appears at
t=0 instead of waiting for the PR + GitHub Search indexing."
  (let* ((data decknix--hub-wip)
         (all-repos (when data (alist-get 'repos data)))
         ;; Compute live-linked set once; empty when toggle is off.
         (linked-set (when decknix--hub-wip-hide-linked
                       (decknix--hub-live-linked-pr-set)))
         (pr-visible-p
          (lambda (repo-full pr)
            (and (decknix--hub-age-visible-p (alist-get 'updated pr))
                 (decknix--hub-wip-attention-visible-p pr)
                 (not (decknix--hub-wip-pr-live-linked-p
                       repo-full (alist-get 'number pr) linked-set)))))
         ;; Filter repos by org, then filter PRs by age + link status
         (repos (seq-filter
                 (lambda (r)
                   (and (decknix--hub-item-visible-p (alist-get 'repo r))
                        (seq-some
                         (lambda (pr)
                           (funcall pr-visible-p
                                    (alist-get 'repo r) pr))
                         (alist-get 'prs r))))
                 (or all-repos '())))
         ;; Worktrees with no matching open PR — surfaced as
         ;; placeholder rows so newly-created worktrees show up
         ;; in WIP at t=0 instead of waiting for `gh pr create'
         ;; + GitHub Search indexing.
         (placeholders (decknix--hub-wip-placeholder-rows))
         ;; Repos with placeholders that are NOT already in
         ;; `repos' (no real PRs visible).  These get a fresh
         ;; sub-header below the PR-bearing repos.
         (real-repo-keys
          (let ((set (make-hash-table :test 'equal)))
            (dolist (r repos)
              (let ((k (decknix--hub-worktree-canonical-repo
                        (alist-get 'repo r))))
                (when k (puthash k t set))))
            set))
         (placeholder-only-repos
          (seq-filter
           (lambda (p)
             (and (decknix--hub-item-visible-p (car p))
                  (not (gethash (car p) real-repo-keys))))
           placeholders))
         (pr-total (cl-reduce #'+ (mapcar
                                  (lambda (r)
                                    (cl-count-if
                                     (lambda (pr)
                                       (funcall pr-visible-p
                                                (alist-get 'repo r) pr))
                                     (alist-get 'prs r)))
                                  repos)
                             :initial-value 0))
         (placeholder-total
          (apply #'+
                 (mapcar (lambda (p)
                           (if (decknix--hub-item-visible-p (car p))
                               (length (cdr p)) 0))
                         placeholders)))
         (total (+ pr-total placeholder-total)))
    (when (> total 0)
      (decknix--sidebar-render-section-header
       (format "WIP (%d)" total)
       'wip)
      (setq line-num (1+ line-num))
      (dolist (repo-entry repos)
        (let* ((repo-full (or (alist-get 'repo repo-entry) ""))
               (repo-key (decknix--hub-worktree-canonical-repo
                          repo-full))
               (repo (car (last (split-string repo-full "/"))))
               (prs (seq-filter
                     (lambda (pr) (funcall pr-visible-p repo-full pr))
                     (alist-get 'prs repo-entry)))
               (placeholder-branches
                (cdr (assoc repo-key placeholders))))
          (when (or prs placeholder-branches)
            ;; Repo sub-header
            (insert (propertize (format "  %s" repo)
                               'face 'font-lock-type-face)
                    "\n")
            (setq line-num (1+ line-num))
            ;; PRs under this repo
            (dolist (pr prs)
              (let* ((number (alist-get 'number pr))
                     (title (or (alist-get 'title pr) ""))
                     (pr-state (or (alist-get 'state pr) "OPEN"))
                     (merged-p (string= pr-state "MERGED"))
                     (ci (alist-get 'ci pr))
                     (mergeable (alist-get 'mergeable pr))
                     (ci-str (if merged-p
                                (decknix--hub-icon "⏣" 'font-lock-constant-face)
                              (decknix--hub-ci-icon ci mergeable)))
                     (draft (alist-get 'draft pr))
                     (branch (alist-get 'branch pr))
                     (url (alist-get 'url pr))
                     ;; TeamCity build status for this branch
                     (tc-build (when (fboundp 'decknix--hub-tc-build-for-branch)
                                 (decknix--hub-tc-build-for-branch branch)))
                     (tc-str (if tc-build
                                 (decknix--hub-tc-icon tc-build)
                               ""))
                     ;; Deploy pipeline indicator (DTSP).  Pass
                     ;; merged_at for merged PRs so envs whose
                     ;; last deploy predates the merge render as
                     ;; grey (not-yet-deployed).
                     (deploy-str
                      (if (fboundp 'decknix--hub-deploy-indicator)
                          (decknix--hub-deploy-indicator
                           repo-full branch
                           (when merged-p (alist-get 'merged_at pr)))
                        ""))
                     ;; Combine CI indicators: GH + TC + Deploy
                     (ci-str (concat ci-str
                                    (if (string-empty-p tc-str) "" tc-str)
                                    deploy-str))
                     ;; Review decision (approved/changes requested)
                     (rev-str (unless merged-p
                                (decknix--hub-wip-review-icon pr)))
                     (ci-str (if (and rev-str (not (string-empty-p rev-str)))
                                (concat ci-str rev-str)
                              ci-str))
                     ;; Reply needed indicator
                     (reply-str (unless merged-p
                                  (decknix--hub-wip-reply-icon pr)))
                     (ci-str (if (and reply-str (not (string-empty-p reply-str)))
                                (concat ci-str reply-str)
                              ci-str))
                     (age (decknix--hub-format-age
                           (or (alist-get 'merged_at pr)
                               (alist-get 'updated pr))))
                     (max-title (max 8 (- (window-width) 20)))
                     (short-title (if (> (length title) max-title)
                                      (concat (substring title 0 (- max-title 1)) "…")
                                    title))
                     ;; Merged PRs get dimmed styling
                     (title-face (cond (merged-p 'font-lock-comment-face)
                                       (draft 'font-lock-comment-face)
                                       (t nil)))
                     ;; Worktree badge — branch is in scope from
                     ;; the WIP record; surfaces `⎇*' / `⎇ ' /
                     ;; `↓ ' as defined in spec §3.6.3.
                     (wt-badge (decknix--hub-worktree-row-badge
                                repo-full branch))
                     (line (format "%s%3s #%d %s %s"
                                  wt-badge
                                  (propertize age 'face 'font-lock-comment-face)
                                  number
                                  ci-str
                                  (if title-face
                                      (propertize short-title
                                                 'face title-face)
                                    short-title))))
                (insert (propertize line
                                   'decknix-hub-url url
                                   'decknix-hub-type 'wip
                                   'decknix-hub-repo repo-full
                                   'decknix-hub-number number
                                   'decknix-hub-branch branch)
                        "\n")
                (setq line-num (1+ line-num))))
            ;; Worktree placeholder rows for branches with no
            ;; matching open PR yet — folded under the same
            ;; repo sub-header so a freshly-pushed branch
            ;; appears alongside the repo's other PRs while
            ;; the GitHub Search index catches up.
            (dolist (wt placeholder-branches)
              (setq line-num
                    (decknix--hub-render-wip-placeholder
                     line-num repo-full wt))))))
      ;; Repos that have only placeholder worktrees (no open
      ;; PRs in WIP yet) — render a fresh sub-header so these
      ;; show up at the bottom of the WIP section.
      (dolist (entry placeholder-only-repos)
        (let* ((repo-full (car entry))
               (repo (car (last (split-string repo-full "/")))))
          (insert (propertize (format "  %s" repo)
                              'face 'font-lock-type-face)
                  "\n")
          (setq line-num (1+ line-num))
          (dolist (wt (cdr entry))
            (setq line-num
                  (decknix--hub-render-wip-placeholder
                   line-num repo-full wt)))))
      (insert "\n")
      (setq line-num (1+ line-num))))
  line-num)

(defun decknix--hub-toggle-deploy-indicator ()
  "Toggle visibility of deployment pipeline indicators (DTSP) in WIP."
  (interactive)
  (setq decknix--hub-show-deploys (not decknix--hub-show-deploys))
  (when (get-buffer "*agent-shell-sidebar*")
    (agent-shell-workspace-sidebar-refresh))
  (message "Deploy indicators: %s"
           (if decknix--hub-show-deploys "shown" "hidden")))

(defun decknix--hub-render-tasks (line-num)
  "Render the Tasks (Jira) section. Returns updated LINE-NUM."
  (let* ((data decknix--hub-jira-tasks)
         (items (when data (alist-get 'items data))))
    (when items
      (decknix--sidebar-render-section-header
       (format "Tasks (%d)" (length items))
       'tasks)
      (setq line-num (1+ line-num))
      (dolist (item items)
        (let* ((key (or (alist-get 'key item) ""))
               (summary (or (alist-get 'summary item) ""))
               (status (or (alist-get 'status item) ""))
               (url (alist-get 'url item))
               ;; FIXME(arch-debt): priority / issue_type / parent_key
               ;; are present in the JSON payload but not yet
               ;; surfaced in the row; future PR can re-bind and
               ;; render them as a leading badge column.
               (icon (decknix--hub-task-status-icon status))
               ;; Truncate summary to fit sidebar
               (max-sum (max 8 (- (window-width) 16)))
               (short-sum (if (> (length summary) max-sum)
                              (concat (substring summary 0 (- max-sum 1)) "…")
                            summary))
               ;; Short status label
               (status-short (pcase (downcase status)
                               ("in progress" "WIP")
                               ("code review" "CR")
                               ("blocked" "BLK")
                               ("ready" "RDY")
                               (_ (upcase (substring status 0
                                                     (min 3 (length status)))))))
               (line (format " %s %s %s %s"
                             icon
                             (propertize key 'face 'font-lock-constant-face)
                             (propertize status-short
                                         'face 'font-lock-comment-face)
                             short-sum)))
          (insert (propertize line
                             'decknix-hub-url url
                             'decknix-hub-type 'task
                             'decknix-hub-jira-key key
                             'decknix-hub-jira-status status)
                  "\n")
          (setq line-num (1+ line-num))))
      (insert "\n")
      (setq line-num (1+ line-num))))
  line-num)

(provide 'decknix-agent-shell-hub)
;;; decknix-agent-shell-hub.el ends here
