;;; decknix-agent-shell-workspace.el --- Workspace sidebar + sessions UI -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, workspace, sidebar

;;; Commentary:
;;
;; Workspace module extracted from agent-shell.nix as part of PR
;; B-Bulk.3.  Verbatim move of 197 declarations (3,543 lines of forms
;; + commentary) covering the workspace tab-bar tab + sidebar
;; rendering, session row-action menus, worktree submenu, transient
;; toggles, the `decknix--sb-stub' macro and its nine placeholder
;; suffix expansions, sidebar previous/saved sessions persistence, etc.
;;
;; This module is loaded only when
;; `programs.emacs.decknix.agentShell.workspace.enable' is non-nil
;; (the corresponding `(require ...)' lives in the same
;; `optionalString cfg.workspace.enable' block in agent-shell.nix).
;; The 14 cross-feature `fboundp' guards on hub symbols continue to
;; short-circuit when hub.enable=false because the hub bulk module
;; is never loaded and its symbols stay undefined.
;;
;; Side-effects that depend on heredoc-resident runtime state (the
;; `(define-key agent-shell-workspace-sidebar-mode-map ...)' calls,
;; the `with-eval-after-load' wiring, `add-hook' for state save /
;; restore, and the various `advice-add' calls) stay in the heredoc
;; immediately after the require so symbols resolve at byte-compile
;; time.

;; FIXME(arch-debt): this module is a verbatim 197-form bulk
;; extraction.  Follow-up PRs (B.22+) should slice it into
;; individually-tested sub-modules (sidebar render, row actions,
;; worktree submenu, toggles transient, state persistence) using the
;; standard `mkEmacsTestedPackage' pattern.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'transient)

;; Forward declarations for symbols defined in the heredoc, in
;; agent-shell-workspace upstream, in helper modules, or in the
;; per-feature bulk modules (main, hub, context).
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")
(declare-function agent-shell-workspace-sidebar-mode-map "ext:agent-shell-workspace")
(declare-function agent-shell-workspace-toggle "ext:agent-shell-workspace")
(declare-function agent-shell-workspace--get-sidebar-buffer "ext:agent-shell-workspace")
(declare-function agent-shell-buffers "ext:agent-shell")
(declare-function agent-shell-rename-buffer "ext:agent-shell")
(declare-function shell-maker--busy "ext:shell-maker")
;; Helpers in already-extracted modules.
(declare-function decknix--agent-pr-parse-url "decknix-agent-url-parse")
(declare-function decknix--agent-parse-pr-url "decknix-agent-url-parse")
(declare-function decknix--agent-repo-parse-url "decknix-agent-url-parse")
(declare-function decknix--agent-pr-url-accessor "decknix-agent-url-parse")
(declare-function decknix--hub-repo-cache-key "decknix-agent-url-parse")
(declare-function decknix--agent-session-time-ago "decknix-agent-format")
(declare-function decknix--agent-session-time-compact "decknix-agent-format")
(declare-function decknix--prompt-truncate-for-display "decknix-agent-format")
(declare-function decknix--agent-conversation-key-raw "decknix-agent-parse")
(declare-function decknix--agent-session-parse "decknix-agent-parse")
(declare-function decknix--vcs-kind "decknix-agent-vcs")
(declare-function decknix--sidebar-abbreviate-workspace "decknix-sidebar-format")
(declare-function decknix--sidebar-session-age-visible-p "decknix-sidebar-format")
(declare-function decknix--hub-age-presets "decknix-hub-age-presets")
(declare-function decknix--hub-age-filter-cycle "decknix-hub-age-presets")
(declare-function decknix--hub-age-filter-label "decknix-hub-age-presets")
;; Bulk hub module symbols (gated by cfg.hub.enable).
(declare-function decknix--hub-render-requests "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-render-wip "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-render-status-hint "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-render-tasks "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-write-linked-prs "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-pr-fetch-async "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-repo-fetch-async "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-has-data-p "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-pr-status "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-deploy-indicator "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-tc-build-for-branch "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-repo-status "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-org-filter-summary "decknix-hub-org-filter")
(declare-function decknix--hub-org-filter-dispatch "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-refresh-all "ext:decknix-agent-shell-hub")
;; Main module symbols (always loaded).
(declare-function decknix--header-update "ext:decknix-agent-shell-main")
(declare-function decknix--agent-buffer-session-id "ext:decknix-agent-shell-main")
(declare-function decknix--agent-tags-read "ext:decknix-agent-shell-main")
(declare-function decknix--agent-tags-write "ext:decknix-agent-shell-main")
(declare-function decknix--agent-current-conv-key "ext:decknix-agent-shell-main")
(declare-function decknix--agent-linked-prs "ext:decknix-agent-shell-main")
(declare-function decknix--agent-linked-items "ext:decknix-agent-shell-main")
(declare-function decknix--agent-tags-conversations "ext:decknix-agent-shell-main")
(declare-function decknix--git-remote-url "decknix-agent-vcs")
(declare-function decknix-agent-link-pr "ext:decknix-agent-shell-main")
(declare-function decknix-agent-link-repo "ext:decknix-agent-shell-main")
(declare-function decknix-agent-unlink-pr "ext:decknix-agent-shell-main")
(declare-function decknix-agent-review "ext:decknix-agent-shell-main")
(declare-function decknix--agent-quickaction-start "ext:decknix-agent-shell-main"
                  (name tags workspace command &optional model))
(defvar decknix-agent-review-pr-model)
(declare-function decknix--agent-conversation-set-hidden "ext:decknix-agent-shell-main")
(declare-function decknix--agent-conversation-key-for-session "decknix-agent-conv-resolve")
(declare-function decknix--agent-tags-for-conv-key "ext:decknix-agent-shell-main")
(declare-function decknix--agent-find-live-buffer-for-conv-key "ext:decknix-agent-shell-main")
(declare-function decknix--agent-workspace-for-conv-key "ext:decknix-agent-shell-main")
(declare-function decknix--agent-session-display-name "ext:decknix-agent-shell-main")
(declare-function decknix--agent-session-group-by-conversation "ext:decknix-agent-shell-main")
(declare-function decknix--agent-session-list "decknix-agent-session-cache")
(declare-function decknix--agent-unsorted-table "ext:decknix-agent-shell-main")
;; More bulk hub module symbols.
(declare-function decknix--hub-item-visible-p "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-ci-visible-p "decknix-hub-ci-filter")
(declare-function decknix--hub-ci-filter-summary "decknix-hub-ci-filter")
(declare-function decknix--hub-sort-requests "decknix-hub-attention-filter")
(declare-function decknix--hub-requests-attention-visible-p "decknix-hub-attention-filter")
(declare-function decknix--hub-requests-reviewed-visible-p "decknix-hub-attention-filter")
(declare-function decknix--hub-wip-attention-visible-p "decknix-hub-attention-filter")
(declare-function decknix--hub-request-has-live-session-p "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-request-tint-active "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-pr-badge "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-format-age "decknix-hub-icons")
(declare-function decknix--hub-review-icon "decknix-hub-icons")
(declare-function decknix--hub-wip-review-icon "decknix-hub-icons")
(declare-function decknix--hub-wip-reply-icon "decknix-hub-icons")
(declare-function decknix--hub-icon "decknix-hub-ci")
(declare-function decknix--hub-ci-icon "decknix-hub-ci")
(declare-function decknix--hub-ci-classify "decknix-hub-ci")
(declare-function decknix--hub-request-ready-p "decknix-hub-ready-filter")
(declare-function decknix--hub-review-ready-requests "decknix-hub-ready-filter")
(declare-function decknix--hub-review-entries "decknix-hub-ready-filter")
(declare-function decknix--hub-mention-visible-p "decknix-hub-mention-bot")
(declare-function decknix--hub-mention-filter-label "decknix-hub-mention-bot")
(declare-function decknix--hub-mention-filter-normalize "decknix-hub-mention-bot")
(declare-function decknix--hub-bot-visible-p "decknix-hub-mention-bot")
(declare-function decknix--hub-show-bots-label "decknix-hub-mention-bot")
(declare-function decknix--hub-show-bots-normalize "decknix-hub-mention-bot")
(declare-function decknix--hub-cycle-bot-filter "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-age-visible-p "decknix-hub-age-presets")
(declare-function decknix--hub-worktree-canonical-repo "decknix-hub-worktree-parse")
(declare-function decknix-hub-worktree-list "ext:decknix-agent-shell-main")
(declare-function decknix-hub-worktree-find "ext:decknix-agent-shell-main")
(declare-function decknix-hub-worktree-primary "ext:decknix-agent-shell-main")
;; Sidebar-toggles symbols (in decknix-sidebar-toggles).
(declare-function decknix-sidebar-toggle-saved-sessions "decknix-sidebar-toggles")
(declare-function decknix-sidebar-toggle-sessions-hide-unknown "decknix-sidebar-toggles")
(declare-function decknix--sidebar-session-workspace-visible-p
                  "decknix-sidebar-toggles" (workspace))
(declare-function decknix-sidebar-toggle-sessions-hide-live "decknix-sidebar-toggles")
(declare-function decknix-sidebar-toggle-hidden "decknix-sidebar-toggles")
(declare-function decknix-sidebar-cycle-sessions-age-filter "decknix-sidebar-toggles")
(declare-function decknix--sidebar-sessions-age-label "decknix-sidebar-toggles")
;; Worktree toggle commands + label helper (§3.6.12).
(declare-function decknix-sidebar-cycle-wt-age-filter "decknix-sidebar-toggles")
(declare-function decknix-sidebar-toggle-wt-hide-clean "decknix-sidebar-toggles")
(declare-function decknix-sidebar-toggle-wt-live-only "decknix-sidebar-toggles")
(declare-function decknix-sidebar-toggle-wt-hide-merged "decknix-sidebar-toggles")
(declare-function decknix-sidebar-toggle-wt-hide-placeholders "decknix-sidebar-toggles")
(declare-function decknix-sidebar-toggle-wt-group-by-repo "decknix-sidebar-toggles")
(declare-function decknix--sidebar-wt-age-label "decknix-sidebar-toggles")
;; Workspace upstream symbols + xwidget.
(declare-function agent-shell-workspace--tile "ext:agent-shell-workspace")
(declare-function agent-shell-workspace--untile "ext:agent-shell-workspace")
(declare-function agent-shell-workspace-sidebar-toggle-quick-switch "ext:agent-shell-workspace")
(declare-function agent-shell-workspace-sidebar-goto "ext:agent-shell-workspace")
(declare-function agent-shell-workspace-sidebar--buffer-at-point "ext:agent-shell-workspace")
(declare-function consult--read "ext:consult")
(declare-function xwidget-webkit-current-session "xwidget")
(declare-function xwidget-webkit-execute-script-rv "xwidget")

;; Forward defvars for heredoc-resident state.
(defvar decknix-agent-prefix-map)
(defvar decknix--sidebar-state-file)
(defvar decknix--sidebar-refresh-suspended)
(defvar decknix--sidebar-tile-count)
(defvar decknix--sidebar-show-progress)
(defvar decknix--sidebar-sessions-age-filter)
(defvar decknix--hub-org-visibility)
(defvar decknix--hub-show-bots)
(defvar decknix--hub-show-bots-cycle)
(defvar decknix--hub-mention-filter)
(defvar decknix--hub-mention-filter-cycle)
(defvar decknix--hub-requests-hide-needs-reply)
(defvar decknix--hub-requests-hide-bot-pending)
(defvar decknix--hub-requests-only-my-replies)
(defvar decknix--hub-requests-sort-reverse)
;; Picker-scoped toggle state for `decknix-sidebar-nav-requests-consult'.
;; These variables are only ever `let'-bound by the picker entry point
;; and read back inside `decknix--hub-completing-read-with-mention-toggle'
;; via `symbol-value' / `set'.  They MUST be `defvar'd with an initialiser
;; here so the `let' establishes a dynamic binding under
;; `lexical-binding: t' — without it the symbol's value cell stays empty
;; and the helper raises "Symbol's value as variable is void".
(defvar decknix--req-mention-only nil)
(defvar decknix--req-ready-only nil)
(defvar decknix--hub-wip-hide-needs-reply)
(defvar decknix--hub-wip-hide-bot-pending)
(defvar decknix--hub-wip-only-my-replies)
(defvar decknix--hub-wip-hide-linked)
(defvar decknix--hub-wip-hide-terminal)
(defvar decknix--hub-expand-prs)
(defvar decknix--hub-symbol-style)
(defvar decknix--hub-repo-name-cap)
(defvar decknix--hub-deploys)
(defvar decknix--hub-show-deploys)
(defvar decknix--hub-wip)
(defvar decknix--hub-reviews)
(defvar decknix-hub-eager-clone-probe)
(defvar decknix--sidebar-previous-sessions)
(declare-function decknix--sidebar-previous-dedupe "decknix-sidebar-previous")
;; Eager live-sessions persistence layer (own carved package).  The
;; bulk wires the lifecycle hooks (record / forget) and the startup
;; snapshot; the pure read/write/dedupe lives in the package itself.
(declare-function decknix--live-sessions-record
                  "decknix-agent-live-sessions" (entry))
(declare-function decknix--live-sessions-forget
                  "decknix-agent-live-sessions" (conv-key sid))
(declare-function decknix--live-sessions-snapshot-and-truncate
                  "decknix-agent-live-sessions" ())
(declare-function decknix--live-sessions-dismiss
                  "decknix-agent-live-sessions" (key))
(declare-function decknix--live-sessions-dismissed-read
                  "decknix-agent-live-sessions" ())
(declare-function decknix--live-sessions-filter-dismissed
                  "decknix-agent-live-sessions" (entries dismissed))
(declare-function decknix--live-sessions-entry-key
                  "decknix-agent-live-sessions" (entry))
(declare-function decknix--live-sessions-write
                  "decknix-agent-live-sessions" (entries))
(defvar decknix--sidebar-show-keys)
(defvar agent-shell-workspace-sidebar-buffer-name)
(declare-function decknix--agent-session-resume "ext:decknix-agent-shell-main")
(declare-function decknix--agent-latest-session-id-for-conv-key "decknix-agent-conv-resolve")
(declare-function decknix--hub-render-session-prs "ext:decknix-agent-shell-hub")
(declare-function decknix--hub-session-attention-icons "ext:decknix-agent-shell-hub")
(defvar agent-shell-display-action)
(defvar agent-shell-workspace-sidebar-width)
(defvar decknix--sidebar-display-mode)



;; -- xwidget-webkit URL opener --
;; Opens URLs in xwidget-webkit (in-Emacs browser) when available,
;; falling back to the system browser.  Used for hub items (PRs, etc.).

(defvar decknix--use-xwidget-webkit t
  "When non-nil, open hub URLs in xwidget-webkit instead of external browser.
Set to nil to always use the system browser.")

(defvar decknix--webkit-shared-buffer nil
  "Buffer holding the shared xwidget-webkit session, or nil.
`decknix--open-url' reuses this buffer so consecutive opens land
in one WebKit window rather than spawning a buffer per URL.
Pass NEW-SESSION non-nil (e.g., a prefix arg) to force a fresh
session.")

(defun decknix--open-url (url &optional new-session)
  "Open URL in xwidget-webkit or external browser based on preference.
With NEW-SESSION non-nil, force a new WebKit buffer rather than
reusing `decknix--webkit-shared-buffer'."
  (if (and decknix--use-xwidget-webkit
           (fboundp 'xwidget-webkit-browse-url))
      (let ((reuse (and (not new-session)
                        decknix--webkit-shared-buffer
                        (buffer-live-p decknix--webkit-shared-buffer))))
        (if reuse
            ;; Drive the existing session to the new URL and surface it.
            (with-current-buffer decknix--webkit-shared-buffer
              (xwidget-webkit-browse-url url)
              (display-buffer (current-buffer)))
          ;; Spawn a fresh session and remember it for next time.
          (xwidget-webkit-browse-url url t)
          (setq decknix--webkit-shared-buffer
                (or (get-buffer "*xwidget-webkit*")
                    (seq-find
                     (lambda (b)
                       (string-match-p "\\*xwidget-webkit"
                                       (buffer-name b)))
                     (buffer-list)))))
        ;; If in the Agents tab, focus the webkit buffer in the main
        ;; (non-side) window so the sidebar keeps its row selection.
        (when (and (fboundp 'agent-shell-workspace--in-agents-tab-p)
                   (agent-shell-workspace--in-agents-tab-p))
          (let ((target nil))
            (walk-windows
             (lambda (win)
               (when (and (not target)
                          (not (window-parameter win 'window-side)))
                 (setq target win)))
             nil nil)
            (when target
              (select-window target)))))
    (browse-url url)))

;; -- xwidget-webkit: helper commands --
;; Top-level defuns so they're discoverable via M-x and apropos.
;; Each operates on the current xwidget-webkit session.

(defun decknix--webkit-copy-url ()
  "Copy the current xwidget-webkit URL to the kill ring."
  (interactive)
  (let ((url (xwidget-webkit-uri (xwidget-webkit-current-session))))
    (kill-new url)
    (message "Copied URL: %s" url)))

(defun decknix--webkit-copy-as-markdown ()
  "Copy the current page as a markdown link `[title](url)`.
Useful for pasting into PR review notes or follow-up stashes."
  (interactive)
  (let* ((session (xwidget-webkit-current-session))
         (url (xwidget-webkit-uri session))
         (raw (ignore-errors
                (xwidget-webkit-execute-script-rv
                 session "document.title")))
         (title (if (and (stringp raw) (not (string-empty-p raw)))
                    raw url))
         (md (format "[%s](%s)" title url)))
    (kill-new md)
    (message "Copied: %s" md)))

(defun decknix--webkit-open-external ()
  "Open the current xwidget-webkit URL in the system browser."
  (interactive)
  (let ((url (xwidget-webkit-uri (xwidget-webkit-current-session))))
    (browse-url url)
    (message "Opened in browser: %s" url)))

(defun decknix--webkit-switch-to-eww ()
  "Open the current xwidget-webkit URL in EWW.
EWW renders the page into a real Emacs buffer so consult-line,
embark, region kill, occur and other buffer-oriented commands all
work natively — useful for read-mode browsing."
  (interactive)
  (let ((url (xwidget-webkit-uri (xwidget-webkit-current-session))))
    (eww url)))

(defun decknix--webkit-focus-input ()
  "Focus the first visible text input or textarea on the current page."
  (interactive)
  (xwidget-webkit-execute-script
   (xwidget-webkit-current-session)
   "(function(){var sel='input:not([type=hidden]):not([type=submit]):not([type=button]),textarea';var els=Array.from(document.querySelectorAll(sel)).filter(function(e){return e.offsetParent!==null;});if(els[0]){els[0].focus();els[0].scrollIntoView({block:'center'});}})()"))

(defun decknix--webkit-next-focusable ()
  "Move focus to the next link, button, or input on the current page."
  (interactive)
  (xwidget-webkit-execute-script
   (xwidget-webkit-current-session)
   "(function(){var sel='a[href],button,input:not([type=hidden]),textarea,select';var els=Array.from(document.querySelectorAll(sel)).filter(function(e){return e.offsetParent!==null;});if(els.length===0)return;var i=els.indexOf(document.activeElement);var next=els[(i+1)%els.length];if(next){next.focus();next.scrollIntoView({block:'center'});}})()"))

(defun decknix--webkit-prev-focusable ()
  "Move focus to the previous link, button, or input on the current page."
  (interactive)
  (xwidget-webkit-execute-script
   (xwidget-webkit-current-session)
   "(function(){var sel='a[href],button,input:not([type=hidden]),textarea,select';var els=Array.from(document.querySelectorAll(sel)).filter(function(e){return e.offsetParent!==null;});if(els.length===0)return;var i=els.indexOf(document.activeElement);var prev=els[(i-1+els.length)%els.length];if(prev){prev.focus();prev.scrollIntoView({block:'center'});}})()"))

;; -- xwidget-webkit: consult-line over page innerText --
;; Bridges Emacs's `consult--read' UI to the WebKit DOM so in-page
;; search feels like consult-line in any other buffer (vertical
;; candidate list, live preview, narrowing) instead of the single-
;; line JS-bridged isearch shim.
;;
;; The two JS-bridge primitives (`decknix--webkit-page-text',
;; `decknix--webkit-find-in-page') and the shared search history
;; defvar (`decknix--webkit-search-history') live in
;; `agent-shell/webkit/decknix-webkit-page.el', packaged as
;; `decknix-webkit-page-el'.  The interactive `consult-line'
;; command stays here because it wires the consult UI and is
;; keymap-bound to the WebKit major-mode in the heredoc.
(declare-function decknix--webkit-page-text    "decknix-webkit-page")
(declare-function decknix--webkit-find-in-page "decknix-webkit-page" (needle))
(defvar decknix--webkit-search-history)

(defun decknix-webkit-consult-line ()
  "Find a line on the current xwidget-webkit page using `consult--read'.
Pulls the page's `innerText', splits into lines, and offers them
as a vertical candidate list with live preview \u2014 selecting a line
scrolls the WebKit view to it via `window.find' and highlights it
natively in the page.

Each line is annotated with its line number so duplicate lines
remain distinguishable in the completion UI; live-preview during
candidate movement uses the line text as the search needle."
  (interactive)
  (unless (derived-mode-p 'xwidget-webkit-mode)
    (user-error "Not in an xwidget-webkit buffer"))
  (unless (require 'consult nil t)
    (user-error "consult is not available"))
  (let* ((text (decknix--webkit-page-text))
         (raw-lines (and text (split-string text "\n" t)))
         (counter 0)
         (candidates
          (delq nil
                (mapcar
                 (lambda (raw)
                   (cl-incf counter)
                   (let ((trimmed (string-trim raw)))
                     (when (>= (length trimmed) 2)
                       ;; Stash the trimmed line in a text property
                       ;; so the :state callback can fetch it
                       ;; directly without parsing the prefix.
                       (propertize
                        (format "%5d  %s" counter trimmed)
                        'decknix-webkit-line trimmed))))
                 raw-lines))))
    (cond
     ((null text)
      (user-error
       "Page has no text yet \u2014 wait for it to finish loading"))
     ((null candidates)
      (user-error "Page has no usable lines to search"))
     (t
      (consult--read
       candidates
       :prompt "Find on page: "
       :category 'decknix-webkit-line
       :require-match nil
       :sort nil
       :history 'decknix--webkit-search-history
       :state
       (lambda (action cand)
         (when (and (eq action 'preview)
                    (stringp cand)
                    (not (string-empty-p cand)))
           (let ((line (or (get-text-property
                            0 'decknix-webkit-line cand)
                           cand)))
             (decknix--webkit-find-in-page line)))))))))

;; Sidebar width cycling (PR B.35) — moved out of this file into
;; agent-shell/sidebar/decknix-sidebar-width.el, packaged as
;; `decknix-sidebar-width-el'.  Owns the cycle state defvar
;; (`decknix--sidebar-width-state') and the two commands that
;; mutate it (`decknix--sidebar-apply-width' applied as advice on
;; the sidebar opener; `decknix-sidebar-cycle-width' bound to `W'
;; in the toggles transient).  Forward declarations here so the
;; transient suffix labels and the persistence read/write sites
;; (~5 references in this file) byte-compile clean.
(defvar decknix--sidebar-width-state)
(declare-function decknix--sidebar-apply-width "decknix-sidebar-width")
(declare-function decknix-sidebar-cycle-width "decknix-sidebar-width")

;; == Forward declarations for byte-compile hygiene ==
;;
;; Defvars and defuns below now live in extracted .el modules
;; (see the `let' block at the top: `decknix-progress-el',
;; `decknix-sidebar-toggles-el', `decknix-hub-age-presets-el',
;; `decknix-hub-teamcity-el', `decknix-hub-org-filter-el',
;; `decknix-hub-jira-tasks-el', `decknix-hub-ci-el',
;; `decknix-hub-mention-bot-el', `decknix-hub-worktree-parse-el',
;; `decknix-agent-url-parse-el', `decknix-hub-icons-el',
;; `decknix-hub-pr-lookup-el').
;; This heredoc references them inside transient suffix lambdas
;; (just below) and Requests / WIP / sessions render code (much
;; further down) at byte-compile time, before the `(require ...)'
;; calls execute, so without these declarations the compiler
;; emits "reference to free variable" / "function not known"
;; warnings on every read site.  A no-init `(defvar X)' is a
;; pure compiler hint — it does NOT bind a value, so module
;; load order remains the source of truth at runtime.  The
;; `declare-function' lines play the same role for symbols
;; whose function cell lives in an extracted module.
(defvar decknix--sidebar-show-progress)
(defvar decknix--sidebar-show-hidden)
(defvar decknix--sidebar-sessions-hide-live)
(defvar decknix--sidebar-sessions-hide-unknown)
(defvar decknix--hub-show-saved-sessions)
(defvar decknix--hub-age-filter)
(defvar decknix--hub-age-presets)
(defvar decknix--hub-org-visibility)
(defvar decknix--hub-mention-filter)
(defvar decknix--hub-mention-filter-cycle)
(defvar decknix--hub-show-bots)
(defvar decknix--hub-show-bots-cycle)
(defvar decknix--hub-bot-patterns)

;; Transient suffix descriptions that show live state
(transient-define-suffix decknix-sidebar-transient--quick-switch ()
  :key "S"
  :description
  (lambda ()
    (format "Quick-switch  %s"
            (propertize
             (if (and (boundp 'agent-shell-workspace-sidebar--quick-switch)
                      agent-shell-workspace-sidebar--quick-switch)
                 "[on]" "[off]")
             'face (if (and (boundp 'agent-shell-workspace-sidebar--quick-switch)
                            agent-shell-workspace-sidebar--quick-switch)
                       'success 'font-lock-comment-face))))
  (interactive)
  (call-interactively #'agent-shell-workspace-sidebar-toggle-quick-switch))

;; Sidebar tile-cycle helpers (PR B.29) -- moved out of this file
;; into agent-shell/sidebar/decknix-sidebar-tile.el, packaged as
;; `decknix-sidebar-tile-el'.  Owns the desired-count defvar, the
;; current-count reader, the one-shot apply helper, the interactive
;; cycle command, and the sidebar-refresh hook that re-tiles once
;; enough live buffers exist.
;;
;; The persistence layer (read/write `decknix--sidebar-tile-count'
;; into `decknix--sidebar-state-file') stays in this file as part
;; of the broader sidebar-state save/restore cluster.  Forward
;; declarations + the existing `defvar' at line 159 keep the
;; persistence and transient call sites in this file resolving
;; clean against the moved symbols.
(declare-function decknix--sidebar-tile-current-count
                  "decknix-sidebar-tile" ())
(declare-function decknix--sidebar-tile-apply
                  "decknix-sidebar-tile" (n))
(declare-function decknix-sidebar-tile-cycle
                  "decknix-sidebar-tile" ())
(declare-function decknix--sidebar-maybe-apply-tile-pref
                  "decknix-sidebar-tile" ())

(transient-define-suffix decknix-sidebar-transient--tile-cycle ()
  :key "t"
  :description
  (lambda ()
    ;; Mirror the footer's `tile' label.  Reads the buffer-local
    ;; `agent-shell-workspace--tiled' flag from the upstream
    ;; sidebar buffer (`*Agent Sidebar*') and shows the desired
    ;; cycle position so the toggle shape is visible at a glance.
    (let* ((n decknix--sidebar-tile-count)
           (active (> (decknix--sidebar-tile-current-count) 0))
           (label (cond ((= n 0) "[off]")
                        (active (format "[%d]" n))
                        (t (format "[%d pending]" n)))))
      (format "tile          %s"
              (propertize label
                          'face (if active 'success 'font-lock-comment-face)))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-tile-cycle))

(transient-define-suffix decknix-sidebar-transient--display-mode ()
  :key "d"
  :description
  (lambda ()
    (format "Display mode  %s"
            (propertize
             (format "[%s]" (symbol-name decknix--sidebar-display-mode))
             'face 'font-lock-constant-face)))
  (interactive)
  (call-interactively #'decknix-sidebar-cycle-display-mode))

(transient-define-suffix decknix-sidebar-transient--hidden-toggle ()
  :key "H"
  :description
  (lambda ()
    (format "Hidden        %s"
            (propertize
             (if decknix--sidebar-show-hidden "[shown]" "[hidden]")
             'face (if decknix--sidebar-show-hidden
                       'warning 'font-lock-comment-face))))
  (interactive)
  (call-interactively #'decknix-sidebar-toggle-hidden))

(transient-define-suffix decknix-sidebar-transient--sessions-age ()
  :key "a"
  :description
  (lambda ()
    (let ((label (decknix--sidebar-sessions-age-label)))
      (format "age           %s"
              (propertize
               (format "[%s]" label)
               'face (if (string= label "all")
                         'font-lock-comment-face
                       'font-lock-constant-face)))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-cycle-sessions-age-filter))

(transient-define-suffix decknix-sidebar-transient--sessions-hide-live ()
  :key "V"
  :description
  (lambda ()
    (format "live-backed   %s"
            (propertize
             (if decknix--sidebar-sessions-hide-live "[hidden]" "[dim]")
             'face (if decknix--sidebar-sessions-hide-live
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-toggle-sessions-hide-live))

(transient-define-suffix decknix-sidebar-transient--sessions-hide-unknown ()
  :key "U"
  :description
  (lambda ()
    (format "unknown-ws    %s"
            (propertize
             (if decknix--sidebar-sessions-hide-unknown "[hide]" "[show]")
             'face (if decknix--sidebar-sessions-hide-unknown
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-toggle-sessions-hide-unknown))

(transient-define-suffix decknix-sidebar-transient--show-saved-sessions ()
  :key "h"
  :description
  (lambda ()
    (format "saved         %s"
            (propertize
             (if decknix--hub-show-saved-sessions "[show]" "[hide]")
             'face (if decknix--hub-show-saved-sessions
                       'font-lock-comment-face
                     'font-lock-constant-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-toggle-saved-sessions))

(transient-define-suffix decknix-sidebar-transient--width ()
  :key "W"
  :description
  (lambda ()
    (format "Width         %s"
            (propertize
             (format "[%s]" (symbol-name decknix--sidebar-width-state))
             'face 'font-lock-constant-face)))
  (interactive)
  (call-interactively #'decknix-sidebar-cycle-width))

;; -- Worktrees toggle suffixes (§3.6.12) --
;; Ordered alphabetically by display label to match the sidebar footer.

(transient-define-suffix decknix-sidebar-transient--wt-age-filter ()
  :key "a"
  :description
  (lambda ()
    (let ((label (if (fboundp 'decknix--sidebar-wt-age-label)
                     (decknix--sidebar-wt-age-label)
                   "all")))
      (format "age           %s"
              (propertize
               (format "[%s]" label)
               'face (if (string= label "all")
                         'font-lock-comment-face
                       'font-lock-constant-face)))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-cycle-wt-age-filter))

(transient-define-suffix decknix-sidebar-transient--wt-hide-clean ()
  :key "d"
  :description
  (lambda ()
    (format "dirty-only    %s"
            (propertize
             (if (and (boundp 'decknix--sidebar-wt-hide-clean)
                      decknix--sidebar-wt-hide-clean)
                 "[on]" "[off]")
             'face (if (and (boundp 'decknix--sidebar-wt-hide-clean)
                            decknix--sidebar-wt-hide-clean)
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-toggle-wt-hide-clean))

(transient-define-suffix decknix-sidebar-transient--wt-live-only ()
  :key "l"
  :description
  (lambda ()
    (format "live-only     %s"
            (propertize
             (if (and (boundp 'decknix--sidebar-wt-live-only)
                      decknix--sidebar-wt-live-only)
                 "[on]" "[off]")
             'face (if (and (boundp 'decknix--sidebar-wt-live-only)
                            decknix--sidebar-wt-live-only)
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-toggle-wt-live-only))

(transient-define-suffix decknix-sidebar-transient--wt-hide-merged ()
  :key "o"
  :description
  (lambda ()
    (format "merged        %s"
            (propertize
             (if (and (boundp 'decknix--sidebar-wt-hide-merged)
                      decknix--sidebar-wt-hide-merged)
                 "[hide]" "[show]")
             'face (if (and (boundp 'decknix--sidebar-wt-hide-merged)
                            decknix--sidebar-wt-hide-merged)
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-toggle-wt-hide-merged))

(transient-define-suffix decknix-sidebar-transient--wt-hide-placeholders ()
  :key "p"
  :description
  (lambda ()
    (format "placeholders  %s"
            (propertize
             (if (and (boundp 'decknix--sidebar-wt-hide-placeholders)
                      decknix--sidebar-wt-hide-placeholders)
                 "[hide]" "[show]")
             'face (if (and (boundp 'decknix--sidebar-wt-hide-placeholders)
                            decknix--sidebar-wt-hide-placeholders)
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-toggle-wt-hide-placeholders))

(transient-define-suffix decknix-sidebar-transient--wt-group-by-repo ()
  :key "r"
  :description
  (lambda ()
    (format "repo-grouped  %s"
            (propertize
             (if (and (boundp 'decknix--sidebar-wt-group-by-repo)
                      decknix--sidebar-wt-group-by-repo)
                 "[on]" "[off]")
             'face (if (and (boundp 'decknix--sidebar-wt-group-by-repo)
                            decknix--sidebar-wt-group-by-repo)
                       'font-lock-constant-face
                     'font-lock-comment-face))))
  :transient t
  (interactive)
  (call-interactively #'decknix-sidebar-toggle-wt-group-by-repo))

(transient-define-prefix decknix-sidebar-toggles-transient ()
  "Sidebar toggles grouped by section.
Suffixes within each section are ordered alphabetically by their
display label (case-insensitive) to match the sidebar footer,
which advertises toggles by label only (no keys)."
  :transient-suffix 'transient--do-stay
  ["Global"
   (decknix-sidebar-transient--org-filter)       ;; Org filter
   (decknix-sidebar-transient--width)]           ;; Width
  ["Requests"
   ;; Order matches the sidebar footer: alphabetical text labels
   ;; (age, bots, ci, mention, reviewed, sort) then emoji-led labels by
   ;; code-point (↩, 💬, 🤖).
   (decknix-sidebar-transient--age-filter)       ;; age
   (decknix-sidebar-transient--bot-filter)       ;; bots
   (decknix-sidebar-transient--ci-filter)        ;; ci
   (decknix-sidebar-transient--mention-filter)   ;; mention
   (decknix-sidebar-transient--req-reviewed)     ;; reviewed
   (decknix-sidebar-transient--req-sort)         ;; sort
   (decknix-sidebar-transient--req-my-replies)   ;; ↩
   (decknix-sidebar-transient--req-needs-reply)  ;; 💬
   (decknix-sidebar-transient--req-bot-pending)] ;; 🤖
  ["Live"
   (decknix-sidebar-transient--display-mode)     ;; Display mode
   (decknix-sidebar-transient--hidden-toggle)    ;; Hidden
   (decknix-sidebar-transient--show-progress)    ;; progress
   (decknix-sidebar-transient--quick-switch)     ;; Quick-switch
   (decknix-sidebar-transient--repo-name-cap)    ;; repo name
   (decknix-sidebar-transient--expand-prs)       ;; session PRs
   (decknix-sidebar-transient--symbol-style)     ;; symbols
   (decknix-sidebar-transient--tile-cycle)]      ;; Tile cycle (off/2/3/4)
  ["WIP"
   (decknix-sidebar-transient--wip-bot-pending)  ;; bot review
   (decknix-sidebar-transient--wip-needs-reply)  ;; comments
   (decknix-sidebar-transient--wip-hide-linked)  ;; hide linked
   (decknix-sidebar-transient--deploy-indicator) ;; pipeline
   (decknix-sidebar-transient--wip-my-replies)   ;; replies
   (decknix-sidebar-transient--wip-hide-terminal)] ;; stale (#137)
  ["Sessions"
   ;; Alphabetical by display label (case-insensitive):
   ;; age, live-backed, saved, unknown-ws.
   (decknix-sidebar-transient--sessions-age)          ;; age
   (decknix-sidebar-transient--sessions-hide-live)    ;; live-backed
   (decknix-sidebar-transient--show-saved-sessions)   ;; saved
   (decknix-sidebar-transient--sessions-hide-unknown)];; unknown-ws
  ["Worktrees"
   ;; Alphabetical by display label: age, dirty-only, live-only,
   ;; merged, placeholders, repo-grouped.
   (decknix-sidebar-transient--wt-age-filter)         ;; age
   (decknix-sidebar-transient--wt-hide-clean)         ;; dirty-only
   (decknix-sidebar-transient--wt-live-only)          ;; live-only
   (decknix-sidebar-transient--wt-hide-merged)        ;; merged
   (decknix-sidebar-transient--wt-hide-placeholders)  ;; placeholders
   (decknix-sidebar-transient--wt-group-by-repo)]     ;; repo-grouped
  ["" ("q" "Done" transient-quit-one)])

(defun decknix-sidebar-refresh ()
  "Refresh the sidebar, first updating the worktree registry via `decknix wt refresh'.
Fires the CLI asynchronously; the sidebar redraws immediately (optimistic)
and again once the registry write completes."
  (interactive)
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh))
  (decknix--wt-cli-async
   (list "refresh")
   (lambda (_out)
     (when (fboundp 'agent-shell-workspace-sidebar-refresh)
       (agent-shell-workspace-sidebar-refresh)))))

(transient-define-prefix decknix-sidebar-transient ()
  "Sidebar actions and toggles."
  ["Navigate"
   ("r"   "Requests"      decknix-sidebar-goto-requests)
   ("w"   "WIP"           decknix-sidebar-goto-wip)
   ("l"   "Live"          decknix-sidebar-goto-live)
   ("p"   "Previous"      decknix-sidebar-goto-previous)
   ("s"   "Sessions…"     decknix-sidebar-sessions)]
  ["Quick"
   ;; Sorted alphabetically by description (case-insensitive).
   ("c"   "New session"   agent-shell-workspace-sidebar-new)
   ("RET" "Open / goto"   agent-shell-workspace-sidebar-goto)
   ("q"   "Quit sidebar"  quit-window)
   ("g"   "Refresh"       decknix-sidebar-refresh)]
  ["Actions (a …)"
   ("a r" "Restart"       agent-shell-workspace-sidebar-restart)
   ("a R" "Rename"        agent-shell-workspace-sidebar-rename)
   ("a k" "Kill"          agent-shell-workspace-sidebar-kill)
   ("a d" "Delete killed" agent-shell-workspace-sidebar-delete-killed)
   ("a w" "Set workspace" decknix-sidebar-set-workspace)
   ("a h" "Hide"          decknix-sidebar-hide-conversation)
   ("a u" "Unhide"        decknix-sidebar-unhide-at-point)
   ("a M" "Merge conv"    decknix-sidebar-merge-conversation)
   ("a m" "Set mode"      agent-shell-workspace-sidebar-set-mode)
   ("a a" "Add tile"      agent-shell-workspace-tile-add)
   ("a x" "Remove tile"   agent-shell-workspace-tile-remove)]
  ["" ("T" "Toggles…"     decknix-sidebar-toggles-transient)])

;; -- Enhanced sidebar render: live + saved sessions + key footer --
;; Override the upstream render to add saved sessions grouped by
;; workspace and a vertical key-help footer below the session lists.
(defvar decknix--sidebar-max-saved 8
  "Maximum number of recent saved conversations to show in sidebar.")

(defvar decknix--sidebar-display-mode 'name
  "What to show for saved sessions in the sidebar.
Valid values: `name' (tags/preview), `tags' (raw tags), `both' (tags + name).")

;; Sidebar render primitives carved out into
;; agent-shell/sidebar/decknix-sidebar-format.el (PR B.26).
;; Forward declarations keep the rest of this file's byte-compile
;; clean.  All four are pure formatters that `insert' into the
;; current buffer; the heredoc and hub-bulk continue to call them
;; via these declares.
(declare-function decknix--sidebar-render-section-header
                  "decknix-sidebar-format")
(declare-function decknix--sidebar-render-key-group
                  "decknix-sidebar-format")
(declare-function decknix--sidebar-render-key-group-inline
                  "decknix-sidebar-format")
(declare-function decknix--sidebar-render-key-groups-side-by-side
                  "decknix-sidebar-format")

;; -- Sidebar footer Navigate / Quick key alists (PR B.41) --
;; Moved out of this file into
;; agent-shell/sidebar/decknix-sidebar-footer-keys.el, packaged
;; as `decknix-sidebar-footer-keys-el'.  Owns the two pure data
;; builders consumed by the footer renderer at the single call
;; site below (~line 1006).  The third section
;; (`decknix--sidebar-footer-toggle-keys') stays here because it
;; pulls in ~15 hub-bulk free vars and faces -- a follow-up slice
;; would also need to move the toggle state vars.
(declare-function decknix--sidebar-footer-nav-keys
                  "decknix-sidebar-footer-keys")
(declare-function decknix--sidebar-footer-quick-keys
                  "decknix-sidebar-footer-keys")

(defun decknix--sidebar-footer-toggle-keys ()
  "Build the Toggles sections for the footer.
Returns a list of (HEADING . KEYS-ALIST) for sectioned display.
Each section has a heading and its toggle key/value pairs.
All toggle keys are accessed via the T transient prefix."
  ;; Items within each section are ordered alphabetically by
  ;; their short label (the text shown in the sidebar); the key
  ;; is intentionally hidden in the footer (press T for keys).
  ;; Emoji-only labels sort after text labels by code-point.
  (let ((global
         (list
          (cons "O" (format "org %s"
                        (if (fboundp 'decknix--hub-org-filter-summary)
                            (let ((summary (decknix--hub-org-filter-summary)))
                              (propertize
                               (format "[%s]" summary)
                               'face (if (string= summary "all")
                                         'font-lock-comment-face
                                       'font-lock-constant-face)))
                          (propertize "[off]" 'face 'font-lock-comment-face))))
          (cons "W" (format "width %s"
                        (propertize
                         (format "[%s]" (symbol-name decknix--sidebar-width-state))
                         'face 'font-lock-constant-face)))))
        (requests
         (when (fboundp 'decknix--hub-org-filter-dispatch)
           ;; Canonical Requests order: alphabetical text labels
           ;; first (age, bots, ci, mention, sort) then emoji-led
           ;; labels by code-point (↩, 💬, 🤖).  The transient mirrors
           ;; the same sequence so the footer and the `T' menu look
           ;; identical except for the visible shortcut keys.
           (list
            (cons "F" (concat "age "
                          (let ((label (decknix--hub-age-filter-label)))
                            (propertize
                             (format "[%s]" label)
                             'face (if (string= label "all")
                                       'font-lock-comment-face
                                     'font-lock-constant-face)))))
            (cons "B" (concat "bots "
                          (let ((label (decknix--hub-show-bots-label)))
                            (propertize
                             (format "[%s]" label)
                             'face (if (string= label "hide")
                                       'font-lock-comment-face
                                     'font-lock-constant-face)))))
            (cons "C" (concat
                        "ci "
                        (propertize "[" 'face 'font-lock-comment-face)
                        ;; Summary already carries per-icon faces
                        ;; (status colour when enabled, shadow when
                        ;; disabled) — don't re-propertize.
                        (decknix--hub-ci-filter-summary)
                        (propertize "]" 'face 'font-lock-comment-face)))
            (cons "@" (concat "mention "
                          (let ((label (decknix--hub-mention-filter-label)))
                            (propertize
                             (format "[%s]" label)
                             'face (if (string= label "off")
                                       'font-lock-comment-face
                                     'font-lock-constant-face)))))
            (cons "s" (concat "sort "
                          (propertize
                           (if decknix--hub-requests-sort-reverse "[new→old]" "[old→new]")
                           'face (if decknix--hub-requests-sort-reverse
                                     'font-lock-constant-face
                                   'font-lock-comment-face))))
            (cons "M" (concat "↩ "
                          (propertize
                           (if decknix--hub-requests-only-my-replies "[only]" "[all]")
                           'face (if decknix--hub-requests-only-my-replies
                                     'font-lock-constant-face
                                   'font-lock-comment-face))))
            (cons "c" (concat
                          (decknix--hub-icon "💬" 'default)
                          " "
                          (propertize
                           (if decknix--hub-requests-hide-needs-reply "[hide]" "[show]")
                           'face (if decknix--hub-requests-hide-needs-reply
                                     'font-lock-constant-face
                                   'font-lock-comment-face))))
            (cons "b" (concat
                          (decknix--hub-icon "🤖" 'default)
                          " "
                          (propertize
                           (if decknix--hub-requests-hide-bot-pending "[hide]" "[show]")
                           'face (if decknix--hub-requests-hide-bot-pending
                                     'font-lock-constant-face
                                   'font-lock-comment-face)))))))
        (live
         (list
          (cons "d" (format "display %s"
                        (propertize
                         (format "[%s]" (symbol-name decknix--sidebar-display-mode))
                         'face 'font-lock-constant-face)))
          (cons "H" (format "hidden %s"
                        (propertize
                         (if decknix--sidebar-show-hidden "[shown]" "[hidden]")
                         'face (if decknix--sidebar-show-hidden
                                   'warning 'font-lock-comment-face))))
          (cons "E" (format "PRs %s"
                        (propertize
                         (pcase decknix--hub-expand-prs
                           ('nil "[off]")
                           ('pr "[PR]")
                           ('pipeline "[pipe]")
                           ('both "[both]")
                           (_ "[off]"))
                         'face (if decknix--hub-expand-prs
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))
          (cons "p" (format "progress %s"
                        (propertize
                         (if (and (boundp 'decknix--sidebar-show-progress)
                                  decknix--sidebar-show-progress)
                             "[on]" "[off]")
                         'face (if (and (boundp 'decknix--sidebar-show-progress)
                                        decknix--sidebar-show-progress)
                                   'success 'font-lock-comment-face))))
          (cons "S" (format "quick %s"
                        (propertize
                         (if (and (boundp 'agent-shell-workspace-sidebar--quick-switch)
                                  agent-shell-workspace-sidebar--quick-switch)
                             "[on]" "[off]")
                         'face (if (and (boundp 'agent-shell-workspace-sidebar--quick-switch)
                                        agent-shell-workspace-sidebar--quick-switch)
                                   'success 'font-lock-comment-face))))
          (cons "N" (format "repo %s"
                        (propertize
                         (format "[%s]"
                                 (if (boundp 'decknix--hub-repo-name-cap)
                                     decknix--hub-repo-name-cap
                                   "short"))
                         'face 'font-lock-constant-face)))
          (cons "y" (format "symbols %s"
                        (propertize
                         (format "[%s]"
                                 (if (boundp 'decknix--hub-symbol-style)
                                     decknix--hub-symbol-style
                                   "ascii"))
                         'face 'font-lock-constant-face)))
          (cons "t" (format "tile %s"
                        (let* ((n decknix--sidebar-tile-count)
                               (active (> (decknix--sidebar-tile-current-count) 0))
                               (label (cond ((= n 0) "[off]")
                                            (active (format "[%d]" n))
                                            (t (format "[%d pending]" n)))))
                          (propertize label
                                      'face (if active 'success 'font-lock-comment-face)))))))
        (wip
         (list
          (cons "L" (format "linked %s"
                        (propertize
                         (if (and (boundp 'decknix--hub-wip-hide-linked)
                                  decknix--hub-wip-hide-linked)
                             "[hide]" "[show]")
                         'face (if (and (boundp 'decknix--hub-wip-hide-linked)
                                        decknix--hub-wip-hide-linked)
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))
          (cons "P" (format "pipe %s"
                        (propertize
                         (if decknix--hub-show-deploys "[show]" "[hide]")
                         'face (if decknix--hub-show-deploys
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))
          (cons "r" (format "↩ %s"
                        (propertize
                         (if decknix--hub-wip-only-my-replies "[only]" "[all]")
                         'face (if decknix--hub-wip-only-my-replies
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))
          (cons "n" (format "%s %s"
                        (decknix--hub-icon "💬" 'default)
                        (propertize
                         (if decknix--hub-wip-hide-needs-reply "[hide]" "[show]")
                         'face (if decknix--hub-wip-hide-needs-reply
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))
          (cons "u" (format "%s %s"
                        (decknix--hub-icon "🤖" 'default)
                        (propertize
                         (if decknix--hub-wip-hide-bot-pending "[hide]" "[show]")
                         'face (if decknix--hub-wip-hide-bot-pending
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))
          ;; Issue #137: terminal-state filter (MERGED / CLOSED).
          (cons "m" (format "stale %s"
                        (propertize
                         (if (and (boundp 'decknix--hub-wip-hide-terminal)
                                  decknix--hub-wip-hide-terminal)
                             "[hide]" "[show]")
                         'face (if (and (boundp 'decknix--hub-wip-hide-terminal)
                                        decknix--hub-wip-hide-terminal)
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))))
        (sessions
         (list
          (cons "a" (format "age %s"
                        (let ((label (decknix--sidebar-sessions-age-label)))
                          (propertize
                           (format "[%s]" label)
                           'face (if (string= label "all")
                                     'font-lock-comment-face
                                   'font-lock-constant-face)))))
          (cons "V" (format "live-backed %s"
                        (propertize
                         (if decknix--sidebar-sessions-hide-live "[hide]" "[dim]")
                         'face (if decknix--sidebar-sessions-hide-live
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))
          (cons "h" (format "saved %s"
                        (propertize
                         (if decknix--hub-show-saved-sessions "[show]" "[hide]")
                         'face (if decknix--hub-show-saved-sessions
                                   'font-lock-comment-face
                                 'font-lock-constant-face))))
          (cons "U" (format "unknown-ws %s"
                        (propertize
                         (if decknix--sidebar-sessions-hide-unknown "[hide]" "[show]")
                         'face (if decknix--sidebar-sessions-hide-unknown
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))))
        (worktrees
         ;; Alphabetical by display label: age, dirty-only, live-only,
         ;; merged, placeholders, repo-grouped.
         (list
          (cons "a" (format "age %s"
                        (let ((label (if (fboundp 'decknix--sidebar-wt-age-label)
                                         (decknix--sidebar-wt-age-label)
                                       "all")))
                          (propertize
                           (format "[%s]" label)
                           'face (if (string= label "all")
                                     'font-lock-comment-face
                                   'font-lock-constant-face)))))
          (cons "d" (format "dirty-only %s"
                        (propertize
                         (if (and (boundp 'decknix--sidebar-wt-hide-clean)
                                  decknix--sidebar-wt-hide-clean)
                             "[on]" "[off]")
                         'face (if (and (boundp 'decknix--sidebar-wt-hide-clean)
                                        decknix--sidebar-wt-hide-clean)
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))
          (cons "l" (format "live-only %s"
                        (propertize
                         (if (and (boundp 'decknix--sidebar-wt-live-only)
                                  decknix--sidebar-wt-live-only)
                             "[on]" "[off]")
                         'face (if (and (boundp 'decknix--sidebar-wt-live-only)
                                        decknix--sidebar-wt-live-only)
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))
          (cons "o" (format "merged %s"
                        (propertize
                         (if (and (boundp 'decknix--sidebar-wt-hide-merged)
                                  decknix--sidebar-wt-hide-merged)
                             "[hide]" "[show]")
                         'face (if (and (boundp 'decknix--sidebar-wt-hide-merged)
                                        decknix--sidebar-wt-hide-merged)
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))
          (cons "p" (format "placeholders %s"
                        (propertize
                         (if (and (boundp 'decknix--sidebar-wt-hide-placeholders)
                                  decknix--sidebar-wt-hide-placeholders)
                             "[hide]" "[show]")
                         'face (if (and (boundp 'decknix--sidebar-wt-hide-placeholders)
                                        decknix--sidebar-wt-hide-placeholders)
                                   'font-lock-constant-face
                                 'font-lock-comment-face))))
          (cons "r" (format "repo-grouped %s"
                        (propertize
                         (if (and (boundp 'decknix--sidebar-wt-group-by-repo)
                                  decknix--sidebar-wt-group-by-repo)
                             "[on]" "[off]")
                         'face (if (and (boundp 'decknix--sidebar-wt-group-by-repo)
                                        decknix--sidebar-wt-group-by-repo)
                                   'font-lock-constant-face
                                 'font-lock-comment-face)))))))
    ;; Return as sectioned list
    (delq nil
          (list
           (cons "Global" global)
           (when requests (cons "Requests" requests))
           (cons "Live" live)
           (cons "WIP" wip)
           (cons "Sessions" sessions)
           (cons "Worktrees" worktrees)))))

(defun decknix--sidebar-render-toggle-sections (sections &optional col-width)
  "Render toggle SECTIONS with sub-headings.
SECTIONS is a list of (HEADING . KEYS-ALIST) from footer-toggle-keys.
When COL-WIDTH is non-nil and >= 24, sections are split into two
independent columns (odd-indexed left, even-indexed right) that flow
without padding — each column's sub-headings appear immediately after
the previous section in that same column, regardless of the other
column's height.  When nil, sections stack vertically (compact)."
  (insert (propertize " Toggles" 'face 'bold) "\n")
  (if (and col-width (>= col-width 24))
      ;; Two-column rendering with independent flow.
      ;; Split sections into left (0, 2, …) and right (1, 3, …).
      ;; Keys are omitted — the T transient shows them interactively.
      (let (left-lines right-lines)
        (seq-do-indexed
         (lambda (section idx)
           (let* ((heading (car section))
                  (keys (cdr section))
                  (lines
                   (cons (propertize (format " %s" heading) 'face 'success)
                         (mapcar
                          (lambda (kv)
                            ;; Show only the value (label + state),
                            ;; not the shortcut key — press T for keys.
                            ;; Indent items 3 spaces beyond heading;
                            ;; use comment face to match Navigate/Quick
                            ;; item sizing.  Build via `concat' so any
                            ;; per-glyph faces inside the value (CI
                            ;; status icons, mention indicator) are
                            ;; preserved instead of being clobbered by
                            ;; a wrapping `propertize'.  Append the
                            ;; comment face so it only fills the
                            ;; un-faced portions (the indent and any
                            ;; plain text); explicit per-icon faces
                            ;; already on the inner string take
                            ;; precedence.
                            (let ((line (concat "   " (cdr kv))))
                              (add-face-text-property
                               0 (length line)
                               'font-lock-comment-face t line)
                              line))
                          keys))))
             (if (= (% idx 2) 0)
                 (setq left-lines (append left-lines lines))
               (setq right-lines (append right-lines lines)))))
         sections)
        ;; Pad the shorter column
        (let ((max-rows (max (length left-lines) (length right-lines))))
          (while (< (length left-lines) max-rows)
            (setq left-lines (append left-lines (list ""))))
          (while (< (length right-lines) max-rows)
            (setq right-lines (append right-lines (list "")))))
        ;; Render side by side
        (cl-mapc
         (lambda (l r)
           (let* ((l-visible (length (substring-no-properties l)))
                  (pad (max 1 (- col-width l-visible))))
             (insert l (make-string pad ?\s) r "\n")))
         left-lines right-lines))
    ;; Compact vertical fallback (indented sub-headings)
    ;; Keys omitted here too — press T for the interactive transient.
    (dolist (section sections)
      (let ((heading (car section))
            (keys (cdr section)))
        (insert (propertize (format "   %s" heading)
                            'face '(:inherit font-lock-type-face :weight normal))
                "\n")
        (dolist (kv keys)
          ;; Same face-preserving construction as the wide branch.
          (let ((line (concat "     " (cdr kv))))
            (add-face-text-property
             0 (length line)
             'font-lock-comment-face t line)
            (insert line "\n")))))))

(defun decknix--sidebar-render-footer ()
  "Insert responsive key listing or compact hint depending on toggle.
When the sidebar is wide enough (>=48 cols), Navigate and Quick render
side-by-side with Toggles below.  When narrow, all groups render with
items inline (horizontal).  Press K to toggle, ? for full transient."
  (insert "\n")
  (if decknix--sidebar-show-keys
      (let* ((win (get-buffer-window (current-buffer)))
             (w (if (and win (window-live-p win))
                    (window-body-width win) 30))
             (nav-keys (decknix--sidebar-footer-nav-keys))
             (quick-keys (decknix--sidebar-footer-quick-keys))
             (toggle-sections (decknix--sidebar-footer-toggle-keys))
             (wide-p (>= w 48)))
        (if wide-p
            ;; ── Wide: Navigate | Quick  side by side, then toggle
            ;;   sections paired 2-wide so Global+Requests and
            ;;   Live+WIP fit on shared rows. ──
            (let ((col (/ w 2)))
              (decknix--sidebar-render-key-groups-side-by-side
               "Navigate" nav-keys "Quick" quick-keys col)
              (decknix--sidebar-render-toggle-sections
               toggle-sections col))
          ;; ── Narrow: all groups inline, toggles stack vertically ──
          (decknix--sidebar-render-key-group-inline "Navigate" nav-keys)
          (decknix--sidebar-render-key-group-inline "Quick" quick-keys)
          (decknix--sidebar-render-toggle-sections toggle-sections))
        ;; Trailing hint (always)
        (insert (propertize " K " 'face 'font-lock-keyword-face)
                (propertize "hide" 'face 'font-lock-comment-face)
                "  "
                (propertize "? " 'face 'font-lock-keyword-face)
                (propertize "all + state" 'face 'font-lock-comment-face)
                "\n"))
    ;; Keys hidden: compact hint
    (insert (propertize " ?" 'face 'font-lock-keyword-face)
            (propertize " actions  " 'face 'font-lock-comment-face)
            (propertize "K" 'face 'font-lock-keyword-face)
            (propertize " show keys" 'face 'font-lock-comment-face)
            "\n")))

;; `decknix--sidebar-abbreviate-workspace' and
;; `decknix--sidebar-session-age-visible-p' live in
;; agent-shell/sidebar/decknix-sidebar-format.el — required
;; alongside the other sidebar packages above.

(defun decknix--sidebar-saved-sessions ()
  "Return recent saved conversations as list of tuples.
Each tuple is (NAME WORKSPACE CONV-KEY SESSION MODIFIED LIVE-P),
where LIVE-P is non-nil when the conversation is already backed by
a live buffer.

Respects these toggles:
- `decknix--sidebar-show-hidden' — include hidden conversations.
- `decknix--sidebar-sessions-hide-live' — drop live-backed entries.
- `decknix--sidebar-sessions-age-filter' — drop entries older than
  the configured window.
- `decknix--sidebar-sessions-hide-unknown' — drop entries without a
  resolvable workspace OR whose workspace directory has been
  deleted from disk (#139, e.g. a `git worktree remove' that ran
  after the session was archived).

Cap of `decknix--sidebar-max-saved' applied after all filters so
the visible count matches the heading."
  (condition-case nil
      (let* ((sessions (decknix--agent-session-list))
             (groups (when sessions
                       (decknix--agent-session-group-by-conversation
                        sessions decknix--sidebar-show-hidden)))
             (result nil)
             (count 0))
        (dolist (group groups)
          (when (< count decknix--sidebar-max-saved)
            (let* ((conv-key (car group))
                   (latest (cadr group))
                   (name (decknix--agent-session-display-name latest))
                   (workspace (when conv-key
                                (decknix--agent-workspace-for-conv-key
                                 conv-key)))
                   (modified (alist-get 'modified latest))
                   (live-p (and conv-key
                                (decknix--agent-find-live-buffer-for-conv-key
                                 conv-key))))
              (when (and
                     ;; hide-live filter
                     (or (not decknix--sidebar-sessions-hide-live)
                         (not live-p))
                     ;; age filter
                     (decknix--sidebar-session-age-visible-p modified)
                     ;; unknown-workspace filter (#139: also drops
                     ;; rows whose workspace dir vanished from disk)
                     (decknix--sidebar-session-workspace-visible-p
                      workspace))
                (push (list name workspace conv-key latest modified
                            (and live-p t))
                      result)
                (setq count (1+ count))))))
        (nreverse result))
    (error nil)))

;; -- Summary header-line --
;; The header-line `:eval' form runs on *every* redisplay of any
;; visible sidebar buffer (many times per second under typing /
;; window-configuration churn).  Computing `saved-count' directly
;; calls `decknix--agent-session-group-by-conversation', which
;; iterates every known session and, per session, invokes
;; `decknix--agent-conv-resolve-key' and
;; `decknix--agent-conversation-hidden-p' — both of which call
;; `decknix--agent-tags-read', which runs `file-exists-p' +
;; `file-attributes' to mtime-check the tag store on every call
;; (even when the in-memory cache is warm).  With N saved
;; conversations that becomes O(N) stat syscalls + regex-heavy
;; `expand-file-name'/`find-file-name-handler' work per redisplay,
;; and the sidebar frame pegs at 100% CPU (see #hub-loop / sample
;; showing 1618/2237 samples inside this chain).
;;
;; Cache the scalar count with a short TTL.  The sidebar itself
;; refreshes every 2s and on hub file-notify events, so a 2s TTL
;; matches the user-visible refresh cadence while capping the
;; redisplay-driven recomputes at 0.5 Hz.
(defvar decknix--sidebar-saved-count-cache nil
  "Cached length of `decknix--agent-session-group-by-conversation'.
Refreshed lazily by `decknix--sidebar-saved-count'; see the header-line
comment for why this is cached.")

(defvar decknix--sidebar-saved-count-cache-time 0.0
  "`float-time' when `decknix--sidebar-saved-count-cache' was last set.")

(defconst decknix--sidebar-saved-count-ttl 2.0
  "Seconds to trust the cached saved-count before recomputing.")

(defun decknix--sidebar-saved-count ()
  "Return the number of saved conversations, cached with a short TTL."
  (if (and decknix--sidebar-saved-count-cache
           (< (- (float-time) decknix--sidebar-saved-count-cache-time)
              decknix--sidebar-saved-count-ttl))
      decknix--sidebar-saved-count-cache
    (setq decknix--sidebar-saved-count-cache-time (float-time))
    (setq decknix--sidebar-saved-count-cache
          (condition-case nil
              (length (decknix--agent-session-group-by-conversation
                       (decknix--agent-session-list)))
            (error 0)))))

;; -- New sidebar commands --
(defun decknix-sidebar-cycle-display-mode ()
  "Cycle sidebar display mode: name → tags → both → name."
  (interactive)
  (setq decknix--sidebar-display-mode
        (pcase decknix--sidebar-display-mode
          ('name 'tags)
          ('tags 'both)
          ('both 'name)
          (_ 'name)))
  (message "Sidebar display: %s" decknix--sidebar-display-mode)
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (agent-shell-workspace-sidebar-refresh)))

(defun decknix-sidebar-set-workspace ()
  "Set or change the workspace for the saved session at point."
  (interactive)
  (let ((conv-key (get-text-property
                   (line-beginning-position)
                   'decknix-sidebar-saved-conv-key)))
    (unless conv-key
      (user-error "No saved session at point"))
    (let* ((new-ws (read-directory-name "Workspace: " nil nil t))
           (store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           (entry (gethash conv-key convs)))
      (when entry
        (puthash "workspace" new-ws entry)
        (puthash "lastAccessed"
                 (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry)
        (decknix--agent-tags-write store)
        (message "Workspace set to %s"
                 (abbreviate-file-name new-ws))
        (when (fboundp 'agent-shell-workspace-sidebar-refresh)
          (agent-shell-workspace-sidebar-refresh))))))

(defun decknix-sidebar-hide-conversation ()
  "Hide the saved conversation at point from all session lists.
Hidden conversations (e.g., automated git hook reviews) are excluded
from the sidebar, session picker, and recent sessions.  Use
`decknix-sidebar-unhide-conversation' or set hidden=false in
agent-sessions.json to restore."
  (interactive)
  (let ((conv-key (get-text-property
                    (line-beginning-position)
                    'decknix-sidebar-saved-conv-key)))
    (unless conv-key
      (user-error "No saved session at point"))
    (when (yes-or-no-p "Hide this conversation from all session lists? ")
      (decknix--agent-conversation-set-hidden conv-key t)
      (agent-shell-workspace-sidebar-refresh)
      (message "Conversation hidden"))))

(defun decknix-sidebar-merge-conversation ()
  "Merge the conversation at point into another conversation.
Sets a mergedInto redirect so the source conversation resolves to
the target.  Sessions and tags are moved to the target."
  (interactive)
  (let ((source-key
         (or (get-text-property (line-beginning-position)
                                'decknix-sidebar-saved-conv-key)
             (let ((prev (get-text-property (line-beginning-position)
                                            'decknix-previous-session)))
               (when prev (alist-get 'conv-key prev))))))
    (unless source-key
      (user-error "No conversation at point"))
    (let* ((store (decknix--agent-tags-read))
           (convs (decknix--agent-tags-conversations store))
           ;; Build completion candidates: all conversations except source
           ;; and those that already have mergedInto set (avoid chains)
           (candidates nil))
      (maphash
       (lambda (key val)
         (when (and (hash-table-p val)
                    (not (string= key source-key))
                    (not (gethash "mergedInto" val))
                    (not (gethash "hidden" val)))
           (let* ((tags (gethash "tags" val))
                  (ws (gethash "workspace" val))
                  (nsessions (length (gethash "sessions" val)))
                  (label (format "%s  %s  (%d sessions)"
                                 (if tags
                                     (mapconcat (lambda (tag) (concat "#" tag))
                                                tags " ")
                                   "(no tags)")
                                 (or ws "")
                                 nsessions)))
             (push (cons label key) candidates))))
       convs)
      (unless candidates
        (user-error "No other conversations to merge into"))
      ;; Sort by label
      (setq candidates (sort candidates
                             (lambda (a b) (string< (car a) (car b)))))
      (let* ((choice (completing-read "Merge into: " candidates nil t))
             (target-key (cdr (assoc choice candidates))))
        (when (yes-or-no-p
               (format "Merge this conversation into %s? " choice))
          (let* ((src-entry (gethash source-key convs))
                 (tgt-entry (gethash target-key convs))
                 ;; Move sessions
                 (src-sessions (when (hash-table-p src-entry)
                                 (gethash "sessions" src-entry)))
                 (tgt-sessions (when (hash-table-p tgt-entry)
                                 (gethash "sessions" tgt-entry)))
                 ;; Merge tags
                 (src-tags (when (hash-table-p src-entry)
                            (gethash "tags" src-entry)))
                 (tgt-tags (when (hash-table-p tgt-entry)
                             (gethash "tags" tgt-entry))))
            ;; Add source sessions to target
            (dolist (sid (or src-sessions '()))
              (cl-pushnew sid tgt-sessions :test #'string=))
            (puthash "sessions" tgt-sessions tgt-entry)
            ;; Merge tags
            (dolist (tag (or src-tags '()))
              (cl-pushnew tag tgt-tags :test #'string=))
            (puthash "tags" tgt-tags tgt-entry)
            ;; Set redirect
            (puthash "mergedInto" target-key src-entry)
            (decknix--agent-tags-write store)
            ;; Also update previous-sessions list if the source
            ;; was a previous session — remove it since it now
            ;; resolves to the target
            (setq decknix--sidebar-previous-sessions
                  (seq-filter
                   (lambda (e)
                     (not (equal (alist-get 'conv-key e) source-key)))
                   decknix--sidebar-previous-sessions))
            (agent-shell-workspace-sidebar-refresh)
            (message "Conversation merged")))))))

;; -- Session transient --
(transient-define-prefix decknix-sidebar-sessions ()
  "Session operations."
  ["Sessions"
   ("s" "Search (picker)" decknix-agent-session-picker)
   ("g" "Grep"           decknix-agent-session-grep)
   ("r" "Recent"         decknix-agent-session-recent)]
  ["Previous"
   ("p" "Restore…"        decknix-sidebar-goto-previous)
   ("P" "Restore all"     decknix--sidebar-restore-all-previous)])

;; -- Actions prefix keymap (a …) --
;; Displaced commands that gave up their top-level keys to
;; section navigation (r → Requests, w → WIP, a → actions).
(transient-define-prefix decknix-sidebar-actions ()
  "Agent actions on the session at point."
  ["Agent"
   ("r" "Restart"       agent-shell-workspace-sidebar-restart)
   ("R" "Rename"        agent-shell-workspace-sidebar-rename)
   ("k" "Kill"          agent-shell-workspace-sidebar-kill)
   ("d" "Delete killed" agent-shell-workspace-sidebar-delete-killed)
   ("w" "Set workspace" decknix-sidebar-set-workspace)
   ("h" "Hide"          decknix-sidebar-hide-conversation)
   ("M" "Merge conv"    decknix-sidebar-merge-conversation)
   ("m" "Set mode"      agent-shell-workspace-sidebar-set-mode)
   ("v" "Review"        decknix-sidebar-review-at-point)]
  ["Tiling"
   ("a" "Add tile"      agent-shell-workspace-tile-add)
   ("x" "Remove tile"   agent-shell-workspace-tile-remove)]
  ["Worktree"
   ("F" "Clean fork remotes" decknix--sb-act-clean-fork-remotes)])

;; -- Section navigation: item pickers --
;; Each section key opens a transient showing lettered items.

;; Letter keys for item indexing (a-z)
(defvar decknix--nav-keys
  (mapcar #'char-to-string (number-sequence ?a ?z))
  "Single-letter keys a–z for item selection in section transients.")

;; Sidebar nav transient item-command factory (PR B.38) --
;; moved out of this file into
;; agent-shell/sidebar/decknix-sidebar-nav-cmd.el, packaged as
;; `decknix-sidebar-nav-cmd-el'.  Owns the single defun
;; `decknix--nav-make-item-cmd' called from the four section
;; transients in this file (`decknix-sidebar-nav-requests-
;; consult' / `-wip-consult' / `-live-consult' / `-previous-
;; consult') to mint a transient suffix per visible row.
;; Forward declaration here so those call sites byte-compile
;; clean.
(declare-function decknix--nav-make-item-cmd
                  "decknix-sidebar-nav-cmd" (item-data action-fn))

;; -- Item action menus --
;; Uses read-char-choice after a short delay to avoid conflicts
;; with the transient exit hook / sidebar restore.

(defun decknix--nav-hub-start-review (url)
  "Start a PR review session for URL without prompting.
Auto-detects workspace and generates session name from the URL.
Prompts for workspace if auto-detection fails.
Overrides `agent-shell-display-action' to target the main window,
preventing extra splits when called from the sidebar."
  (let ((parsed (decknix--agent-parse-pr-url url)))
    (if (not parsed)
        (message "Not a valid PR URL: %s" url)
      (let* ((owner (alist-get 'owner parsed))
             (repo (alist-get 'repo parsed))
             (number (alist-get 'number parsed))
             (name (format "pr-%s-%s" repo number))
             (tags (list "review" repo (format "#%s" number)))
             (detected (when (fboundp 'decknix--agent-pr-detect-workspace)
                         (decknix--agent-pr-detect-workspace owner repo)))
             (workspace (or detected
                            (read-directory-name
                             (format "Workspace for %s/%s: " owner repo)
                             nil nil t)))
             (command (format "/review-service-pr %s" url))
             ;; Target main window to avoid sidebar splits
             (main (window-main-window (selected-frame))))
        (when (and main (window-live-p main))
          (select-window main))
        (decknix--agent-quickaction-start name tags workspace command
                                          decknix-agent-review-pr-model)
        (message "Starting review: %s/%s#%s" owner repo number)))))

;; PR B.51: `decknix--hub-review-ready-requests' and
;; `decknix--hub-review-entries' carved into
;; `decknix-hub-ready-filter' (agent-shell/hub/) alongside
;; `decknix--hub-request-ready-p' (B.50).  The reader returns the
;; ready subset of `decknix--hub-reviews'; the entry builder turns
;; that subset into the `(LABEL . ITEM)' cons cells the `r' picker
;; consumes.  Both forward-declared at the top of this file.

(defun decknix--hub-launch-review-items (items split-p)
  "Launch review sessions for ITEMS.
When SPLIT-P is non-nil, tile subsequent reviews side-by-side."
  (let ((launched 0)
        (count (length items)))
    (dolist (item items)
      (let ((url (alist-get 'url item)))
        (when url
          (if (and split-p (> launched 0))
              (decknix--nav-hub-start-review-split url)
            (decknix--nav-hub-start-review url))
          (setq launched (1+ launched))
          (when (> count 1) (sit-for 0.3)))))
    (message "Launched %d review%s%s"
             launched (if (= launched 1) "" "s")
             (if split-p " [split]" ""))))

(defun decknix-hub-launch-reviews (arg)
  "Launch review sessions for ready PRs.

R         — pick one via consult, prompt for layout
C-u R     — launch ALL ready reviews, prompt for layout
C-u N R   — pick N via consult (embark-select to mark, RET to confirm),
    then prompt for layout
C-u C-u R — like R but filtered to @-mentioned items only.
During completion: M-m toggles @-mention, M-b toggles bots, M-s
reverses sort direction.  All three are scoped to the picker."
  (interactive "P")
  ;; Shadow the three toggle variables so M-m / M-b / M-s mutations
  ;; stay local to this picker session and never leak into the
  ;; sidebar's global filter or sort state.
  (let ((decknix--rev-mention-only (equal arg '(16)))  ;; C-u C-u
        (decknix--hub-show-bots (and (boundp 'decknix--hub-show-bots)
                                     decknix--hub-show-bots))
        (decknix--hub-requests-sort-reverse
         (and (boundp 'decknix--hub-requests-sort-reverse)
              decknix--hub-requests-sort-reverse)))
    (catch 'decknix--rev-done
      (while t
        (let ((entries (decknix--hub-review-entries
                        decknix--rev-mention-only)))
          (if (not entries)
              (progn
                (message "No review-ready requests%s"
                         (if decknix--rev-mention-only
                             " (with @-mention)" ""))
                (throw 'decknix--rev-done nil))
            (cond
             ;; C-u: launch all
             ((equal arg '(4))
              (let* ((count (length entries))
                     (choice (read-char-choice
                              (format "Launch all %d review%s: [s]plit  [r]eplace  [q]uit "
                                      count (if (= count 1) "" "s"))
                              '(?s ?r ?q))))
                (unless (eq choice ?q)
                  (decknix--hub-launch-review-items
                   (mapcar #'cdr entries) (eq choice ?s))))
              (throw 'decknix--rev-done nil))
             ;; Numeric prefix (C-u N): multi-select via embark
             ((and (integerp arg) (> arg 1))
              (let ((selected nil)
                    (remaining (mapcar #'car entries)))
                ;; Collect up to ARG selections
                (catch 'done
                  (dotimes (i arg)
                    (if (not remaining)
                        (throw 'done nil)
                      (let* ((prompt (format "Review %d/%d (%d ready): "
                                            (1+ i) arg (length remaining)))
                             (choice (completing-read prompt remaining nil t)))
                        (when choice
                          (push (cdr (assoc choice entries)) selected)
                          (setq remaining (delete choice remaining)))))))
                (setq selected (nreverse selected))
                (when selected
                  (let* ((count (length selected))
                         (choice (read-char-choice
                                  (format "%d review%s: [s]plit  [r]eplace  [q]uit "
                                          count (if (= count 1) "" "s"))
                                  '(?s ?r ?q))))
                    (unless (eq choice ?q)
                      (decknix--hub-launch-review-items
                       selected (eq choice ?s))))))
              (throw 'decknix--rev-done nil))
             ;; No prefix (or C-u C-u): single pick with M-m / M-b toggles
             (t
              (let* ((prompt (format "Review (%d ready): "
                                     (length entries)))
                     (result (decknix--hub-completing-read-with-mention-toggle
                              prompt entries 'decknix--rev-mention-only)))
                (cond
                 ;; M-m / M-b: loop so the outer `while' rebuilds
                 ;; `entries' with the updated filter state.
                 ((eq result 'retry) nil)
                 ;; C-g / ESC: exit cleanly.
                 ((null result)
                  (throw 'decknix--rev-done nil))
                 ;; C-SPC multi-select: launch reviews for every
                 ;; marked candidate with one aggregate confirmation.
                 ((eq (car-safe result) 'multi)
                  (let* ((labels (cdr result))
                         (items (delq nil
                                      (mapcar
                                       (lambda (lbl)
                                         (cdr (assoc lbl entries)))
                                       labels)))
                         (count (length items))
                         (choice (and (> count 0)
                                      (read-char-choice
                                       (format "Launch %d review%s: [s]plit  [r]eplace  [q]uit "
                                               count
                                               (if (= count 1) "" "s"))
                                       '(?s ?r ?q)))))
                    (when (and choice (not (eq choice ?q)))
                      (decknix--hub-launch-review-items
                       items (eq choice ?s))))
                  (throw 'decknix--rev-done nil))
                 ;; RET: hand off to the rich action transient so
                 ;; Review / Review (split) / Open / Browser /
                 ;; Copy URL / WIP ops are all one keypress away.
                 ;; Batch mode (C-u R, numeric prefix) keeps the
                 ;; compact [s]plit/[r]eplace prompt above.
                 (t
                  (let* ((base (cdr (assoc (car result) entries)))
                         (item (if (assq 'decknix-type base) base
                                 (cons (cons 'decknix-type 'review)
                                       base))))
                    (when item
                      (decknix--nav-hub-item-actions item))
                    (throw 'decknix--rev-done nil)))))))))))))

(defun decknix--nav-hub-start-review-split (url)
  "Start a PR review session for URL in a new split window.
Like `decknix--nav-hub-start-review' but splits the main window so
the review appears side-by-side with the current buffer."
  (let ((parsed (decknix--agent-parse-pr-url url)))
    (if (not parsed)
        (message "Not a valid PR URL: %s" url)
      (let* ((owner (alist-get 'owner parsed))
             (repo (alist-get 'repo parsed))
             (number (alist-get 'number parsed))
             (name (format "pr-%s-%s" repo number))
             (tags (list "review" repo (format "#%s" number)))
             (detected (when (fboundp 'decknix--agent-pr-detect-workspace)
                         (decknix--agent-pr-detect-workspace owner repo)))
             (workspace (or detected
                            (read-directory-name
                             (format "Workspace for %s/%s: " owner repo)
                             nil nil t)))
             (command (format "/review-service-pr %s" url))
             ;; Split the main window horizontally (side-by-side)
             (main (window-main-window (selected-frame)))
             (new-win (when (and main (window-live-p main))
                        (split-window main nil 'right)))
             (agent-shell-display-action
              (if (and new-win (window-live-p new-win))
                  (eval `(cons (lambda (buffer alist)
                                 (let ((win ,new-win))
                                   (when (window-live-p win)
                                     (window--display-buffer
                                      buffer win 'reuse alist))))
                               nil)
                        t)
                agent-shell-display-action)))
        (when (and new-win (window-live-p new-win))
          (select-window new-win))
        (decknix--agent-quickaction-start name tags workspace command
                                          decknix-agent-review-pr-model)
        (message "Starting review (split): %s/%s#%s"
                 owner repo number)))))

;; -- Hub item action transient --
;; Restores the rich sub-option menu that appears after picking an item
;; from the Requests / WIP pickers or from the sidebar RET handler.
;; The selected item is stashed in `decknix--hub-action-item' so suffix
;; commands can read it without needing closure support (default.el is
;; evaluated under dynamic binding).

(defvar decknix--hub-action-item nil
  "Hub item currently driving `decknix--hub-item-transient'.")

(defun decknix--hub-action-wip-p ()
  "Return non-nil when the current hub action item is a WIP PR."
  (eq (alist-get 'decknix-type decknix--hub-action-item) 'wip))

(defun decknix--hub-action-description ()
  "Return a short header string describing the current hub action item."
  (let* ((repo (or (alist-get 'repo decknix--hub-action-item) ""))
         (short (car (last (split-string repo "/"))))
         (number (alist-get 'number decknix--hub-action-item))
         (title (or (alist-get 'title decknix--hub-action-item) ""))
         (trim (if (> (length title) 60)
                   (concat (substring title 0 59) "…")
                 title)))
    (format "%s#%s  %s"
            (propertize short 'face 'font-lock-type-face)
            number
            (propertize trim 'face 'italic))))

(transient-define-suffix decknix--hub-action-open ()
  "Open the current hub item in Emacs (xwidget-webkit or EWW)."
  :description "Open here"
  (interactive)
  (when-let ((url (alist-get 'url decknix--hub-action-item)))
    (decknix--open-url url)))

(transient-define-suffix decknix--hub-action-browser ()
  "Open the current hub item in an external browser."
  :description "Open in browser"
  (interactive)
  (when-let ((url (alist-get 'url decknix--hub-action-item)))
    (browse-url url)))

(transient-define-suffix decknix--hub-action-copy-url ()
  "Copy the current hub item's URL to the kill ring."
  :description "Copy URL"
  (interactive)
  (when-let ((url (alist-get 'url decknix--hub-action-item)))
    (kill-new url)
    (message "Copied: %s" url)))

(transient-define-suffix decknix--hub-action-review ()
  "Start a PR review session for the current hub item."
  :description "Start review"
  (interactive)
  (when-let ((url (alist-get 'url decknix--hub-action-item)))
    (decknix--nav-hub-start-review url)))

(transient-define-suffix decknix--hub-action-review-split ()
  "Start a PR review session in a split window."
  :description "Start review (split)"
  (interactive)
  (when-let ((url (alist-get 'url decknix--hub-action-item)))
    (decknix--nav-hub-start-review-split url)))

(transient-define-suffix decknix--hub-action-merge ()
  "Merge the current WIP PR via gh CLI."
  :description "Merge"
  (interactive)
  (decknix--hub-wip-merge
   (alist-get 'repo decknix--hub-action-item)
   (alist-get 'number decknix--hub-action-item)))

(transient-define-suffix decknix--hub-action-close ()
  "Close the current WIP PR via gh CLI."
  :description "Close"
  (interactive)
  (decknix--hub-wip-close
   (alist-get 'repo decknix--hub-action-item)
   (alist-get 'number decknix--hub-action-item)))

(transient-define-suffix decknix--hub-action-comment ()
  "Add a comment to the current WIP PR via gh CLI."
  :description "Comment"
  (interactive)
  (decknix--hub-wip-comment
   (alist-get 'repo decknix--hub-action-item)
   (alist-get 'number decknix--hub-action-item)))

(transient-define-prefix decknix--hub-item-transient ()
  "Actions for the hub item stored in `decknix--hub-action-item'."
  [:description decknix--hub-action-description
   ["Navigate"
    ("o" decknix--hub-action-open)
    ("b" decknix--hub-action-browser)
    ("c" decknix--hub-action-copy-url)]
   ["Review"
    ("r" decknix--hub-action-review)
    ("s" decknix--hub-action-review-split)]
   ["WIP"
    :if decknix--hub-action-wip-p
    ("m" decknix--hub-action-merge)
    ("l" decknix--hub-action-close)
    ("M" decknix--hub-action-comment)]]
  [("q" "Cancel" transient-quit-one)])

(defun decknix--nav-hub-item-actions (item)
  "Show the action transient for a hub ITEM (review or WIP PR).
Defers the transient by a small delay so the picker's minibuffer is
fully torn down before the menu appears (otherwise the transient can
fight with vertico/consult cleanup and fail to display).  Selects the
main window before showing the transient so it anchors there rather
than the dedicated sidebar (where it cannot open a buffer) — matches
the pattern used by `decknix--sidebar-call-transient'.

The transient is invoked via `call-interactively' from the timer so
transient gets the interactive command context it needs; calling the
prefix as a plain function from a timer can leave the transient
unable to display."
  (setq decknix--hub-action-item item)
  (run-at-time
   0.05 nil
   (lambda ()
     (let ((main (window-main-window (selected-frame))))
       (when (and main (window-live-p main))
         (select-window main)))
     (add-hook 'transient-exit-hook
               #'decknix--sidebar-restore-after-transient)
     (call-interactively #'decknix--hub-item-transient))))

;; -- WIP PR actions via gh CLI --

(defcustom decknix--hub-pr-comment-presets
  '("@dependabot rebase"
    "@dependabot recreate"
    "@dependabot merge"
    "@dependabot squash and merge"
    "auggie review"
    "auggie review --all"
    "@copilot review"
    "please rebase on main")
  "Preset comment bodies offered by `decknix--hub-wip-comment'.
Shown as completions in the minibuffer; free-form text is always
accepted regardless of whether it matches a preset."
  :type '(repeat string)
  :group 'decknix)

(defun decknix--hub-wip-merge (repo number)
  "Merge PR NUMBER in REPO via gh CLI.
Prompts for merge method: rebase, squash, or merge commit."
  (let* ((method (read-char-choice
                  (format "Merge %s#%d: [r]ebase [s]quash [m]erge [q]uit"
                          (car (last (split-string repo "/"))) number)
                  '(?r ?s ?m ?q))))
    (pcase method
      (?q (message "Cancelled"))
      (_
       (let ((flag (pcase method
                     (?r "--rebase")
                     (?s "--squash")
                     (?m "--merge"))))
         (when (yes-or-no-p
                (format "Merge %s#%d with %s?"
                        repo number (substring flag 2)))
           (decknix--hub-gh-async
            "merge" repo number
            (list "pr" "merge" (number-to-string number)
                  "-R" repo flag "--delete-branch"))))))))

(defun decknix--hub-wip-close (repo number)
  "Close PR NUMBER in REPO via gh CLI."
  (when (yes-or-no-p (format "Close %s#%d?" repo number))
    (decknix--hub-gh-async
     "close" repo number
     (list "pr" "close" (number-to-string number)
           "-R" repo))))

(defun decknix--hub-wip-comment (repo number)
  "Add a comment to PR NUMBER in REPO via gh CLI.
Offers preset comment bodies from `decknix--hub-pr-comment-presets'
via `completing-read'; type any text to enter a free-form comment
instead.  Presets are not enforced — arbitrary input is always accepted."
  (let* ((short (car (last (split-string repo "/"))))
         (prompt (format "Comment on %s#%d: " short number))
         (body (completing-read prompt decknix--hub-pr-comment-presets
                                nil nil nil nil nil)))
    (when (and body (not (string-empty-p (string-trim body))))
      (decknix--hub-gh-async
       "comment" repo number
       (list "pr" "comment" (number-to-string number)
             "-R" repo "--body" body)))))

(defun decknix--hub-gh-async (action repo number args)
  "Run gh CLI with ARGS asynchronously for ACTION on REPO#NUMBER.
Shows result in the echo area and triggers a hub refresh on success."
  (let* ((short-repo (car (last (split-string repo "/"))))
         (label (format "%s %s#%d" action short-repo number))
         (buf-name (format " *hub-%s*" label)))
    (message "%s: running..." label)
    (let ((proc (apply #'start-process
                       buf-name buf-name "gh" args)))
      (set-process-sentinel
       proc
       (eval `(lambda (proc event)
                (let ((exit-code (process-exit-status proc))
                      (output (with-current-buffer (process-buffer proc)
                                (string-trim (buffer-string)))))
                  (if (= exit-code 0)
                      (progn
                        (message "%s: done%s" ,label
                                 (if (string-empty-p output) ""
                                   (format " — %s" output)))
                        ;; Trigger hub refresh to update sidebar
                        (when (fboundp 'decknix--hub-refresh-all)
                          (run-at-time 2 nil #'decknix--hub-refresh-all)))
                    (message "%s: failed (exit %d) %s"
                             ,label exit-code output))
                  (when (buffer-live-p (process-buffer proc))
                    (kill-buffer (process-buffer proc)))))
             t)))))

(defun decknix--nav-display-in-main (buf)
  "Display BUF in the main (non-side) window, matching sidebar RET behaviour."
  (when (buffer-live-p buf)
    ;; Update sidebar selection
    (when (boundp 'agent-shell-workspace-sidebar--selected-buffer)
      (setq agent-shell-workspace-sidebar--selected-buffer buf))
    (when (fboundp 'agent-shell-workspace--clear-finished)
      (agent-shell-workspace--clear-finished buf))
    ;; Find a non-side, non-sidebar window and display there
    (let ((target nil))
      (walk-windows
       (lambda (win)
         (when (and (not target)
                    (not (window-parameter win 'window-side))
                    (not (string= (buffer-name (window-buffer win))
                                  (or (bound-and-true-p
                                       agent-shell-workspace-sidebar-buffer-name)
                                      "*Agent Sidebar*"))))
           (setq target win)))
       nil nil)
      (when target
        (set-window-buffer target buf)
        (select-window target)))
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))))

(defun decknix--nav-live-item-actions (buf)
  "Show an action menu for a live session buffer BUF."
  (let ((name (buffer-name buf)))
    (run-at-time 0.05 nil
      (eval `(lambda ()
               (when (buffer-live-p ,buf)
                 (let ((choice (read-char-choice
                                ,(format "%s: [s]witch [k]ill [r]estart [q]uit" name)
                                '(?s ?k ?r ?q))))
                   (pcase choice
                     (?s (decknix--nav-display-in-main ,buf))
                     (?k (when (buffer-live-p ,buf)
                           (kill-buffer ,buf)
                           (when (fboundp 'agent-shell-workspace-sidebar-refresh)
                             (agent-shell-workspace-sidebar-refresh))))
                     (?r (when (buffer-live-p ,buf)
                           (with-current-buffer ,buf
                             (when (fboundp 'agent-shell-restart)
                               (agent-shell-restart)))))
                     (?q (message "Cancelled")))))) t))))

;; -- Section: Requests --
(defun decknix--nav-requests-children (_)
  "Generate transient children for hub Requests items."
  (if (not (and (boundp 'decknix--hub-reviews) decknix--hub-reviews))
      (list (transient-parse-suffix transient--prefix
              '("q" "No requests" ignore)))
    (let* ((all-items (alist-get 'items decknix--hub-reviews))
           (items (seq-filter
                   (lambda (item)
                     (and (decknix--hub-item-visible-p (alist-get 'repo item))
                          (decknix--hub-age-visible-p (alist-get 'created item))
                          (decknix--hub-ci-visible-p item)
                          (decknix--hub-mention-visible-p item)
                          (decknix--hub-bot-visible-p item)
                          (decknix--hub-requests-attention-visible-p item)
                          (decknix--hub-requests-reviewed-visible-p item)))
                   (or all-items '())))
           (keys decknix--nav-keys))
      (append
       (cl-loop for item in items
                for key in keys
                collect
                (let* ((age (decknix--hub-format-age
                             (alist-get 'created item)))
                       (repo-full (or (alist-get 'repo item) ""))
                       (repo (car (last (split-string repo-full "/"))))
                       (number (alist-get 'number item))
                       (title (or (alist-get 'title item) ""))
                       (ci-str (decknix--hub-ci-icon (alist-get 'ci item)
                                                      (alist-get 'mergeable item)))
                       (rev-str (decknix--hub-review-icon item))
                       (status-str (if (string-empty-p rev-str)
                                       ci-str
                                     (concat ci-str rev-str)))
                       (active-str (if (decknix--hub-request-has-live-session-p item)
                                       (decknix--hub-icon "◉" '(:foreground "#87d7ff"))
                                     ""))
                       (status-str (if (string-empty-p active-str)
                                       status-str
                                     (concat status-str active-str)))
                       (short (if (> (length title) 30)
                                  (concat (substring title 0 29) "…")
                                title))
                       (tagged (cons (cons 'decknix-type 'review) item))
                       (cmd (decknix--nav-make-item-cmd
                             tagged #'decknix--nav-hub-item-actions))
                       (label (format "%3s %s#%d %s %s"
                                      age repo number status-str short)))
                  ;; Tint the transient suffix label yellow when
                  ;; a live session is already reviewing this PR.
                  (decknix--hub-request-tint-active label item)
                  (transient-parse-suffix
                   transient--prefix
                   (list key label cmd))))
       (list (transient-parse-suffix transient--prefix
               '("q" "Back" transient-quit-one)))))))

;; -- Consult-based section pickers --
;; All section navigation (r, w, l, p) uses consult for filtering.

(defvar decknix--hub-picker-captured-selections nil
  "Transient capture cell for `embark-selected-candidates'.
Set by a minibuffer-exit-hook inside
`decknix--hub-completing-read-with-mention-toggle' and read back by
the caller after `completing-read' returns.  Reset at the start of
each picker invocation so stale values never leak across calls.")

(defun decknix--hub-completing-read-with-mention-toggle
    (prompt entries mention-only-var &optional ready-only-var)
  "Run `completing-read' on ENTRIES with live filter toggles.
PROMPT is the base prompt string.  MENTION-ONLY-VAR is a symbol naming
the variable that holds the current mention-only state.  READY-ONLY-VAR,
when non-nil, names a variable holding the `ready-for-review' filter
state — enabling M-r as an additional live toggle.

M-m toggles MENTION-ONLY-VAR; M-r (when enabled) toggles READY-ONLY-VAR;
M-b cycles `decknix--hub-show-bots' (hide → show → mentioned → hide);
M-s toggles `decknix--hub-requests-sort-reverse'.  Each aborts the
current completing-read and returns the sentinel symbol `retry' so the
caller can rebuild ENTRIES and re-invoke this function.

C-SPC marks the current candidate via `embark-select' (multi-select).
When selections exist on RET the function returns a `multi' result so
callers can iterate the chosen action over every selected item.

Callers should let-bind `decknix--hub-show-bots' and
`decknix--hub-requests-sort-reverse' before invoking this function so
M-b / M-s toggles stay picker-scoped and do not leak into the global
sidebar filter or sort state.

Returns one of:
  (CHOICE . MENTION-ONLY)    on a single selection,
  (multi . LABELS)           on a multi-select (>=1 marked),
  `retry'                    when any toggle was pressed,
  nil                        when the user cancelled (C-g / ESC)."
  (setq decknix--hub-picker-captured-selections nil)
  (let* ((mo (symbol-value mention-only-var))
         (ro (and ready-only-var
                  (symbol-value ready-only-var)))
         (bots (and (boundp 'decknix--hub-show-bots)
                    decknix--hub-show-bots))
         (rev (and (boundp 'decknix--hub-requests-sort-reverse)
                   decknix--hub-requests-sort-reverse))
         (hints (concat (if mo "@ " "")
                        (if ro "✓ " "")
                        (pcase bots
                          ('show      "🤖 ")
                          ('mentioned "🤖@ ")
                          (_          ""))
                        (if rev "⇅ " "")))
         (full-prompt (format "%s%s(M-m@ %sM-b🤖 M-s⇅ C-SPC✓) "
                              prompt hints
                              (if ready-only-var "M-r✓ " "")))
         (retry nil)
         ;; Plain lambdas under `lexical-binding: t' are real
         ;; closures over `retry', `mention-only-var',
         ;; `ready-only-var' and the *-fn vars below.  Do NOT wrap
         ;; them in `(eval `(lambda ...) t)' — that evaluates the
         ;; form under an empty lexical environment, so `setq retry'
         ;; would mutate a stray global instead of the outer let's
         ;; binding and the `condition-case' handler at the bottom
         ;; of this function would always observe nil → the picker
         ;; treats every toggle as a cancel and closes.
         (mention-fn
          (lambda ()
            (interactive)
            (set mention-only-var
                 (not (symbol-value mention-only-var)))
            (setq retry t)
            (abort-recursive-edit)))
         (ready-fn
          (when ready-only-var
            (lambda ()
              (interactive)
              (set ready-only-var
                   (not (symbol-value ready-only-var)))
              (setq retry t)
              (abort-recursive-edit))))
         (bot-fn
          (lambda ()
            (interactive)
            (when (and (boundp 'decknix--hub-show-bots)
                       (boundp 'decknix--hub-show-bots-cycle))
              (let* ((cycle decknix--hub-show-bots-cycle)
                     (rest (or (cdr (memq decknix--hub-show-bots cycle))
                               cycle)))
                (setq decknix--hub-show-bots (car rest))))
            (setq retry t)
            (abort-recursive-edit)))
         (sort-fn
          (lambda ()
            (interactive)
            (when (boundp 'decknix--hub-requests-sort-reverse)
              (setq decknix--hub-requests-sort-reverse
                    (not decknix--hub-requests-sort-reverse)))
            (setq retry t)
            (abort-recursive-edit)))
         ;; Attach bindings to the *existing* minibuffer map (the
         ;; one Vertico has already installed) rather than replacing
         ;; it.  Replacing the map stripped Vertico's next-line /
         ;; previous-line remaps, causing up/down to fall through
         ;; to minibuffer history navigation instead of cycling
         ;; candidates.
         (setup-fn
          (lambda ()
            (local-set-key (kbd "M-m") mention-fn)
            (when ready-fn
              (local-set-key (kbd "M-r") ready-fn))
            (local-set-key (kbd "M-b") bot-fn)
            (local-set-key (kbd "M-s") sort-fn)
            (when (fboundp 'embark-select)
              (local-set-key (kbd "C-SPC") 'embark-select))
            ;; Capture embark selections at exit time;
            ;; `embark-selected-candidates' is buffer-local
            ;; to the minibuffer so we must read it before
            ;; completing-read returns.
            (add-hook 'minibuffer-exit-hook
              (lambda ()
                (when (fboundp 'embark-selected-candidates)
                  (setq decknix--hub-picker-captured-selections
                        (embark-selected-candidates))))
              nil t))))
    (condition-case nil
        ;; Wrap the candidate labels in an unsorted completion
        ;; table so Vertico/orderless do not re-sort them — the
        ;; caller has already applied the shared
        ;; `decknix--hub-sort-requests' ordering (honouring
        ;; `decknix--hub-requests-sort-reverse', which M-s
        ;; flips ephemerally).  Without this wrapper, the
        ;; picker's display order would ignore the let-bound
        ;; sort flag even though the prompt hint correctly
        ;; reflects it.
        (let ((choice (minibuffer-with-setup-hook setup-fn
                        (completing-read full-prompt
                          (decknix--agent-unsorted-table
                           (mapcar #'car entries))
                          nil t)))
              (sel decknix--hub-picker-captured-selections))
          (setq decknix--hub-picker-captured-selections nil)
          (cond
           ;; One or more candidates marked with C-SPC.
           ((and sel (listp sel) (> (length sel) 0))
            (cons 'multi sel))
           (t (cons choice mo))))
      (quit (if retry 'retry nil)))))

(defun decknix-sidebar-nav-requests-consult (&optional mention-only limit)
  "Pick a PR review request via consult completion with filtering.
Each candidate shows age, repo, PR number, CI status, and title —
matching the sidebar rendering style.
When MENTION-ONLY is non-nil, show only @-mentioned items.
When LIMIT is a positive integer, show at most that many items.
During completion: M-m toggles @-mention, M-r toggles ready-for-review
(CI passing, not conflicting, not draft, not yet reviewed by me),
M-b toggles bot-author visibility (dependabot/renovate), M-s reverses
sort direction.  All four toggles are scoped to this picker session
and never leak into the sidebar's global filters or sort state.
Interactively: \\[universal-argument] N r limits to N items;
       \\[universal-argument] \\[universal-argument] r shows @-mentioned only."
  (interactive)
  ;; Shadow the toggle variables so M-m / M-r / M-b / M-s mutations
  ;; stay local to this picker session — the sidebar's own filter
  ;; and sort state is restored as soon as this `let' unwinds.
  ;; `decknix--sidebar-refresh-suspended' freezes sidebar re-renders
  ;; while the picker is open so 2-second timer ticks don't paint
  ;; the sidebar with the picker's local toggle state.
  (let ((decknix--sidebar-refresh-suspended t)
        (decknix--req-mention-only mention-only)
        (decknix--req-ready-only nil)
        (decknix--hub-show-bots (and (boundp 'decknix--hub-show-bots)
                                     decknix--hub-show-bots))
        (decknix--hub-requests-sort-reverse
         (and (boundp 'decknix--hub-requests-sort-reverse)
              decknix--hub-requests-sort-reverse)))
    (catch 'decknix--req-done
      (while t
        (let* ((mo decknix--req-mention-only)
               (ro decknix--req-ready-only)
               (all-items (when (boundp 'decknix--hub-reviews)
                            (alist-get 'items decknix--hub-reviews)))
               (filtered (seq-filter
                          (lambda (item)
                            (and (decknix--hub-item-visible-p (alist-get 'repo item))
                                 (decknix--hub-age-visible-p (alist-get 'created item))
                                 (decknix--hub-ci-visible-p item)
                                 (decknix--hub-mention-visible-p item)
                                 (decknix--hub-bot-visible-p item)
                                 (decknix--hub-requests-attention-visible-p item)
                                 ;; Extra @-mention filter when requested
                                 (or (not mo)
                                     (eq (alist-get 'mentioned item) t))
                                 ;; Extra ready-for-review filter
                                 (or (not ro)
                                     (decknix--hub-request-ready-p item))))
                          (or all-items '())))
               ;; Apply shared sort so picker and sidebar stay aligned.
               (sorted (decknix--hub-sort-requests filtered))
               ;; Apply count limit
               (items (if (and limit (integerp limit) (> limit 0))
                          (seq-take sorted limit)
                        sorted)))
          (if (not items)
              ;; Keep the picker open with a synthetic placeholder so
              ;; the user can adjust M-m / M-r / M-b / M-s toggles or
              ;; C-g to quit — instead of the picker closing on them
              ;; the moment a filter produces zero matches.
              (let* ((entries
                      (list (cons (propertize
                                   "(no matches — M-m/M-r/M-b/M-s to adjust, C-g to quit)"
                                   'face 'font-lock-comment-face)
                                  nil)))
                     (prompt (format "Request [0%s%s]: "
                                     (if mo " @" "")
                                     (if ro " ✓" "")))
                     (result (decknix--hub-completing-read-with-mention-toggle
                              prompt entries
                              'decknix--req-mention-only
                              'decknix--req-ready-only)))
                (cond
                 ;; Toggle pressed — loop to rebuild.
                 ((eq result 'retry) nil)
                 ;; C-g / ESC — exit cleanly.
                 ((null result)
                  (throw 'decknix--req-done nil))
                 ;; RET on the placeholder — loop so the user can
                 ;; pick a toggle.
                 (t nil)))
            (let* ((entries
                    (mapcar
                     (lambda (item)
                       (let* ((age (decknix--hub-format-age
                                    (alist-get 'created item)))
                              (repo-full (or (alist-get 'repo item) ""))
                              (repo (car (last (split-string repo-full "/"))))
                              (number (alist-get 'number item))
                              (title (or (alist-get 'title item) ""))
                              (ci-str (decknix--hub-ci-icon
                                       (alist-get 'ci item)
                                       (alist-get 'mergeable item)))
                              (rev-str (decknix--hub-review-icon item))
                              (status-str (if (string-empty-p rev-str)
                                              ci-str
                                            (concat ci-str rev-str)))
                              ;; @-mention indicator
                              (mention-str (if (eq (alist-get 'mentioned item) t)
                                               (propertize "@"
                                                 'face '(:foreground "#d7af5f" :weight bold))
                                             ""))
                              (status-str (if (string-empty-p mention-str)
                                              status-str
                                            (concat status-str mention-str)))
                              ;; Active session indicator
                              (active-str (if (decknix--hub-request-has-live-session-p item)
                                              (propertize "◉"
                                                'face '(:foreground "#87d7ff"))
                                            ""))
                              (status-str (if (string-empty-p active-str)
                                              status-str
                                            (concat status-str active-str)))
                              ;; Age colouring matching sidebar
                              (age-face (cond
                                         ((string-match-p "d$" age)
                                          (if (>= (string-to-number age) 3)
                                              'error 'warning))
                                         (t 'font-lock-comment-face)))
                              (label (format " %3s %s#%d %s %s"
                                             (propertize age 'face age-face)
                                             (propertize (or repo "") 'face 'font-lock-type-face)
                                             number
                                             status-str
                                             title)))
                         ;; Tint the picker label yellow when a
                         ;; live session is already reviewing this PR.
                         (decknix--hub-request-tint-active label item)
                         (cons label item)))
                     items))
                   (prompt (format "Request [%d%s%s%s]: "
                                   (length items)
                                   (if (and limit (integerp limit) (> limit 0))
                                       (format " ≤%d" limit)
                                     "")
                                   (if mo " @" "")
                                   (if ro " ✓" "")))
                   (result (decknix--hub-completing-read-with-mention-toggle
                            prompt entries
                            'decknix--req-mention-only
                            'decknix--req-ready-only)))
              (cond
               ;; M-m / M-r / M-b / M-s: loop so the outer `while'
               ;; rebuilds `entries' with the updated filter state
               ;; and re-opens the picker with fresh candidates.
               ((eq result 'retry) nil)
               ;; C-g / ESC: exit cleanly.
               ((null result)
                (throw 'decknix--req-done nil))
               ;; C-SPC multi-select: launch reviews for every marked
               ;; candidate with one aggregate confirmation.
               ((eq (car-safe result) 'multi)
                (let* ((labels (cdr result))
                       (items
                        (delq nil
                              (mapcar
                               (lambda (lbl)
                                 (let ((base (cdr (assoc lbl entries))))
                                   (when base
                                     (if (assq 'decknix-type base) base
                                       (cons (cons 'decknix-type 'review)
                                             base)))))
                               labels)))
                       (count (length items))
                       (choice (and (> count 0)
                                    (read-char-choice
                                     (format "Launch %d review%s: [s]plit  [r]eplace  [q]uit "
                                             count
                                             (if (= count 1) "" "s"))
                                     '(?s ?r ?q)))))
                  (when (and choice (not (eq choice ?q)))
                    (decknix--hub-launch-review-items
                     items (eq choice ?s))))
                (throw 'decknix--req-done nil))
               ;; RET: hand off to the rich action transient.
               (t
                (let ((item (cdr (assoc (car result) entries))))
                  (when item
                    (let ((tagged (cons (cons 'decknix-type 'review) item)))
                      (decknix--nav-hub-item-actions tagged)))
                  (throw 'decknix--req-done nil)))))))))))

(defun decknix-sidebar-nav-wip-consult ()
  "Pick a WIP PR via consult completion with filtering."
  (interactive)
  (let* ((data (when (boundp 'decknix--hub-wip) decknix--hub-wip))
         (all-repos (when data (alist-get 'repos data)))
         (entries nil))
    ;; Flatten repos → PRs into a single list of labelled entries
    (dolist (repo-entry all-repos)
      (let* ((repo-full (or (alist-get 'repo repo-entry) ""))
             (repo (car (last (split-string repo-full "/")))))
        (when (decknix--hub-item-visible-p repo-full)
          (dolist (pr (alist-get 'prs repo-entry))
            (when (and (decknix--hub-age-visible-p (alist-get 'updated pr))
                       (decknix--hub-wip-attention-visible-p pr))
              (let* ((number (alist-get 'number pr))
                     (title (or (alist-get 'title pr) ""))
                     (pr-state (or (alist-get 'state pr) "OPEN"))
                     (merged-p (string= pr-state "MERGED"))
                     (ci (alist-get 'ci pr))
                     (mergeable (alist-get 'mergeable pr))
                     (ci-str (if merged-p
                                (decknix--hub-icon "⏣" 'font-lock-constant-face)
                              (decknix--hub-ci-icon ci mergeable)))
                     (rev-str (unless merged-p
                                (decknix--hub-wip-review-icon pr)))
                     (reply-str (unless merged-p
                                  (decknix--hub-wip-reply-icon pr)))
                     (status-str (concat ci-str
                                         (or rev-str "")
                                         (or reply-str "")))
                     (age (decknix--hub-format-age
                           (or (alist-get 'merged_at pr)
                               (alist-get 'updated pr))))
                     (label (format "%3s %s#%d %s %s"
                                   age repo number status-str title))
                     (tagged (append
                              (list (cons 'decknix-type 'wip)
                                    (cons 'repo repo-full))
                              pr)))
                (push (cons label tagged) entries)))))))
    (if (not entries)
        (message "No WIP items")
      (setq entries (nreverse entries))
      (let* ((choice (completing-read "WIP: "
                       (mapcar #'car entries) nil t))
             (item (cdr (assoc choice entries))))
        (when item
          (decknix--nav-hub-item-actions item))))))

(defun decknix-sidebar-nav-live-consult ()
  "Pick a live agent-shell session via consult completion."
  (interactive)
  (let* ((buffers (seq-filter #'buffer-live-p
                              (when (fboundp 'agent-shell-buffers)
                                (agent-shell-buffers))))
         (entries
          (mapcar
           (lambda (buf)
             (let* ((name (buffer-name buf))
                    (short (replace-regexp-in-string
                            "\\`\\*[^:]*: *\\|\\*\\'" "" name))
                    ;; Add workspace info for disambiguation
                    (ws (when (buffer-live-p buf)
                          (with-current-buffer buf
                            (abbreviate-file-name default-directory))))
                    (label (if ws
                               (format "%s  @%s" short
                                       (if (string-match "/\\([^/]+\\)/?$" ws)
                                           (match-string 1 ws) ws))
                             short)))
               (cons label buf)))
           buffers)))
    (if (not entries)
        (message "No live sessions")
      (let* ((choice (completing-read "Live: "
                       (mapcar #'car entries) nil t))
             (buf (cdr (assoc choice entries))))
        (when buf
          (decknix--nav-live-item-actions buf))))))

(defvar decknix--sidebar-previous-restore-mode nil
  "Internal flag: nil = single restore, \\='all = restore all visible.")
(defvar decknix--sidebar-previous-visible-candidates nil
  "Captured list of visible candidate strings from vertico at M-RET time.")

(defun decknix-sidebar-nav-previous-consult ()
  "Pick previous sessions to restore via completing-read.
RET restores the selected session.  M-RET restores all currently
visible (filtered) candidates.  C-g cancels."
  (interactive)
  (let* ((live-bufs (seq-filter #'buffer-live-p
                                (when (fboundp 'agent-shell-buffers)
                                  (agent-shell-buffers))))
         (live-sids (mapcar #'decknix--agent-buffer-session-id
                             live-bufs))
         (live-conv-keys
          (delq nil
                (mapcar (lambda (b)
                          (with-current-buffer b
                            (and (bound-and-true-p decknix--agent-conv-key)
                                 decknix--agent-conv-key)))
                        live-bufs)))
         ;; Same filter as the sidebar renderer: drop live, dedupe
         ;; by conv-key so each conversation shows exactly once.
         (prev (decknix--sidebar-previous-dedupe
                (seq-filter
                 (lambda (e)
                   (let ((sid (alist-get 'session-id e))
                         (ck (alist-get 'conv-key e)))
                     (and (not (member sid live-sids))
                          (not (and ck (member ck live-conv-keys))))))
                 (or decknix--sidebar-previous-sessions '()))))
         (entries
          (mapcar
           (lambda (entry)
             (let* ((name (or (alist-get 'name entry) "unknown"))
                    (short (if (string-match "\\*Auggie: \\(.*\\)\\*" name)
                               (match-string 1 name) name))
                    (ws (alist-get 'workspace entry))
                    (tags (alist-get 'tags entry))
                    (ws-str (if ws
                                (let ((abbr (abbreviate-file-name ws)))
                                  (if (string-match "/\\([^/]+\\)/?$" abbr)
                                      (match-string 1 abbr) abbr))
                              "?"))
                    (tag-str (if tags
                                (mapconcat
                                 (lambda (tg) (concat "#" tg)) tags " ")
                              ""))
                    (label (format "%s  @%s %s" short ws-str tag-str)))
               (cons label entry)))
           prev)))
    (if (not entries)
        (message "No previous sessions")
      (setq decknix--sidebar-previous-restore-mode nil)
      (setq decknix--sidebar-previous-visible-candidates nil)
      (let* ((choice
              (minibuffer-with-setup-hook
                  (lambda ()
                    (let ((map (make-sparse-keymap)))
                      (define-key map (kbd "M-RET")
                        (lambda () (interactive)
                          (setq decknix--sidebar-previous-restore-mode 'all)
                          ;; Capture vertico's filtered candidates while
                          ;; still inside the minibuffer (they are
                          ;; buffer-local and vanish on exit).
                          (setq decknix--sidebar-previous-visible-candidates
                                (when (boundp 'vertico--candidates)
                                  (copy-sequence vertico--candidates)))
                          (exit-minibuffer)))
                      (use-local-map
                       (make-composed-keymap map (current-local-map)))))
                (completing-read
                 "Restore (RET=one  M-RET=all visible  C-g=cancel): "
                 (mapcar #'car entries) nil t)))
             (all-labels (mapcar #'car entries)))
        (if (eq decknix--sidebar-previous-restore-mode 'all)
            ;; Restore all candidates that matched the filter at
            ;; the time M-RET was pressed.
            (let* ((visible (or decknix--sidebar-previous-visible-candidates
                               all-labels))
                   (to-restore (seq-filter
                                #'identity
                                (mapcar (lambda (lbl)
                                          (cdr (assoc lbl entries)))
                                        visible))))
              (if (null to-restore)
                  (message "No matching sessions")
                ;; Restore first with focus, rest without
                (decknix--sidebar-restore-previous-session
                 (car to-restore) t)
                (dolist (entry (cdr to-restore))
                  (decknix--sidebar-restore-previous-session entry))
                (message "Restored %d session%s"
                         (length to-restore)
                         (if (= (length to-restore) 1) "" "s"))))
          ;; Single selection: restore just the chosen one
          (let ((entry (cdr (assoc choice entries))))
            (when entry
              (decknix--sidebar-restore-previous-session
               entry t))))))))

(transient-define-prefix decknix-sidebar-nav-requests-keys ()
  "Pick a PR review request via shortcut keys."
  [:class transient-column
   :setup-children decknix--nav-requests-children])

;; -- Section: WIP --
(defun decknix--nav-wip-children (_)
  "Generate transient children for hub WIP items."
  (if (not (and (boundp 'decknix--hub-wip) decknix--hub-wip))
      (list (transient-parse-suffix transient--prefix
              '("q" "No WIP items" ignore)))
    (let* ((all-repos (alist-get 'repos decknix--hub-wip))
           (repos (seq-filter
                   (lambda (r)
                     (and (decknix--hub-item-visible-p (alist-get 'repo r))
                          (seq-some
                           (lambda (pr)
                             (and (decknix--hub-age-visible-p (alist-get 'updated pr))
                                  (decknix--hub-wip-attention-visible-p pr)))
                           (alist-get 'prs r))))
                   (or all-repos '())))
           (keys decknix--nav-keys)
           (idx 0)
           (children nil))
      ;; Flatten: repo headers (visual) + PR items (selectable)
      (dolist (repo-entry repos)
        (let* ((repo-full (or (alist-get 'repo repo-entry) ""))
               (repo (car (last (split-string repo-full "/")))))
          (dolist (pr (seq-filter
                       (lambda (pr)
                         (and (decknix--hub-age-visible-p (alist-get 'updated pr))
                              (decknix--hub-wip-attention-visible-p pr)))
                       (alist-get 'prs repo-entry)))
            (when (< idx (length keys))
              (let* ((key (nth idx keys))
                     (number (alist-get 'number pr))
                     (title (or (alist-get 'title pr) ""))
                     (ci-str (decknix--hub-ci-icon (alist-get 'ci pr)
                                                   (alist-get 'mergeable pr)))
                     (rev-str (decknix--hub-wip-review-icon pr))
                     (reply-str (decknix--hub-wip-reply-icon pr))
                     (status-str (concat ci-str rev-str reply-str))
                     (age (decknix--hub-format-age
                           (alist-get 'updated pr)))
                     (short (if (> (length title) 28)
                                (concat (substring title 0 27) "…")
                              title))
                     (tagged (append
                              (list (cons 'decknix-type 'wip)
                                    (cons 'repo repo-full))
                              pr))
                     (cmd (decknix--nav-make-item-cmd
                           tagged #'decknix--nav-hub-item-actions)))
                (push (transient-parse-suffix
                       transient--prefix
                       (list key
                             (format "%3s %s#%d %s %s"
                                     age repo number status-str short)
                             cmd))
                      children)
                (setq idx (1+ idx)))))))
      (append (nreverse children)
              (list (transient-parse-suffix transient--prefix
                      '("q" "Back" transient-quit-one)))))))

(transient-define-prefix decknix-sidebar-nav-wip ()
  "Pick a WIP PR."
  [:class transient-column
   :setup-children decknix--nav-wip-children])

;; -- Section: Live sessions --
(defun decknix--nav-live-children (_)
  "Generate transient children for live agent-shell sessions."
  (let* ((buffers (seq-filter #'buffer-live-p
                              (when (fboundp 'agent-shell-buffers)
                                (agent-shell-buffers))))
         (keys decknix--nav-keys))
    (if (null buffers)
        (list (transient-parse-suffix transient--prefix
                '("q" "No live sessions" ignore)))
      (append
       (cl-loop for buf in buffers
                for key in keys
                collect
                (let* ((name (buffer-name buf))
                       ;; Strip *Auggie: prefix and trailing *
                       (short (replace-regexp-in-string
                               "\\`\\*[^:]*: *\\|\\*\\'" "" name))
                       (short (if (> (length short) 35)
                                  (concat (substring short 0 34) "…")
                                short))
                       (cmd (decknix--nav-make-item-cmd
                             buf #'decknix--nav-live-item-actions)))
                  (transient-parse-suffix
                   transient--prefix
                   (list key short cmd))))
       (list (transient-parse-suffix transient--prefix
               '("q" "Back" transient-quit-one)))))))

(transient-define-prefix decknix-sidebar-nav-live ()
  "Pick a live agent session."
  [:class transient-column
   :setup-children decknix--nav-live-children])

;; -- Section: Previous sessions --
(defun decknix--nav-previous-children (_)
  "Generate transient children for previous (restorable) sessions."
  (let* ((live-bufs (seq-filter #'buffer-live-p
                                (when (fboundp 'agent-shell-buffers)
                                  (agent-shell-buffers))))
         (live-sids (mapcar #'decknix--agent-buffer-session-id
                             live-bufs))
         (prev (seq-filter
                (lambda (e)
                  (not (member (alist-get 'session-id e) live-sids)))
                (or decknix--sidebar-previous-sessions '())))
         (keys decknix--nav-keys))
    (if (null prev)
        (list (transient-parse-suffix transient--prefix
                '("q" "No previous sessions" ignore)))
      (append
       (list (transient-parse-suffix transient--prefix
               (list "A" "Restore all"
                     #'decknix--sidebar-restore-all-previous)))
       (cl-loop for entry in prev
                for key in keys
                collect
                (let* ((name (or (alist-get 'name entry) "unknown"))
                       (short (if (string-match "\\*Auggie: \\(.*\\)\\*" name)
                                  (match-string 1 name)
                                name))
                       (short (if (> (length short) 35)
                                  (concat (substring short 0 34) "…")
                                short))
                       (cmd (decknix--nav-make-item-cmd
                             entry #'decknix--nav-previous-item-actions)))
                  (transient-parse-suffix
                   transient--prefix
                   (list key
                         (propertize short 'face 'font-lock-comment-face)
                         cmd))))
       (list (transient-parse-suffix transient--prefix
               '("q" "Back" transient-quit-one)))))))

(transient-define-prefix decknix-sidebar-nav-previous ()
  "Pick a previous session to restore."
  [:class transient-column
   :setup-children decknix--nav-previous-children])

;; -- Sidebar → transient helper --
;; Now that isolation no longer redirects transient buffers, the
;; transient renders fine from the sidebar.  We just need to
;; re-focus the sidebar after the transient exits.

(defun decknix--sidebar-restore-after-transient ()
  "One-shot hook: re-focus the sidebar after a transient exits.
Also resumes sidebar refreshes that `decknix--sidebar-call-transient'
suspended for the duration of the transient — without this clear
the sidebar would freeze permanently after any RET / a / T menu."
  (remove-hook 'transient-exit-hook #'decknix--sidebar-restore-after-transient)
  ;; Always clear the suspend flag, even if we exit through
  ;; an unusual code path (C-g, error in a suffix, etc.).
  (setq decknix--sidebar-refresh-suspended nil)
  (when (and (fboundp 'agent-shell-workspace--in-agents-tab-p)
             (agent-shell-workspace--in-agents-tab-p))
    ;; Re-show sidebar if it was somehow destroyed
    (when (fboundp 'agent-shell-workspace-sidebar-show)
      (agent-shell-workspace-sidebar-show))
    ;; Focus the sidebar
    (when-let ((sw (get-buffer-window
                    agent-shell-workspace-sidebar-buffer-name)))
      (select-window sw)))
  ;; Run a single refresh so the sidebar catches up on anything
  ;; that changed while suspended (new live session, mention
  ;; cleared, hub data updated).
  (when (fboundp 'agent-shell-workspace-sidebar-refresh)
    (ignore-errors (agent-shell-workspace-sidebar-refresh))))

(defun decknix--sidebar-call-transient (cmd)
  "Invoke transient CMD from the main window to preserve the sidebar.
Selects the main window so transient anchors there and any buffer
changes (e.g., session resume) land in the main area instead of
trying to split the dedicated sidebar.  The isolation advice above
ensures the transient buffer is allowed in the Agents tab (so the
sidebar no longer collapses on tab-switch).

Sets `decknix--sidebar-refresh-suspended' for the lifetime of the
transient so 2-second refresh ticks and hub file-notify callbacks
do not redraw the sidebar (and reset point to top-left) while a
row's Action Menu is open — `decknix--sidebar-restore-after-transient'
clears the flag and triggers a single catch-up refresh on exit."
  ;; Select the main window so transient and its actions display there
  (let ((main (window-main-window (selected-frame))))
    (when (and main (window-live-p main))
      (select-window main)))
  ;; Freeze the sidebar.  call-interactively returns immediately
  ;; once the transient is set up — the modal interaction lives
  ;; on the transient state machine, so we cannot use a `let'
  ;; binding here; the exit hook is responsible for clearing.
  (setq decknix--sidebar-refresh-suspended t)
  (add-hook 'transient-exit-hook #'decknix--sidebar-restore-after-transient)
  (call-interactively cmd))

;; -- Dispatch commands for section keys --
(defun decknix-sidebar-goto-requests (arg)
  "Navigate to hub Requests items via consult.
With \\[universal-argument] N, show at most N items.
With \\[universal-argument] \\[universal-argument], show @-mentioned only."
  (interactive "P")
  (if (and (fboundp 'decknix--hub-has-data-p) (decknix--hub-has-data-p))
      (let ((mention-only (equal arg '(16)))  ;; C-u C-u
            (limit (and (integerp arg) arg)))  ;; C-u N
        (decknix-sidebar-nav-requests-consult mention-only limit))
    (message "Hub: no data — enable with decknix.services.hub.enable = true")))

(defun decknix-sidebar-goto-wip ()
  "Navigate to hub WIP items via consult."
  (interactive)
  (if (and (fboundp 'decknix--hub-has-data-p) (decknix--hub-has-data-p))
      (decknix-sidebar-nav-wip-consult)
    (message "Hub: no data — enable with decknix.services.hub.enable = true")))

(defun decknix-sidebar-goto-live ()
  "Navigate to live sessions via consult."
  (interactive)
  (decknix-sidebar-nav-live-consult))

(defun decknix-sidebar-goto-previous ()
  "Navigate to previous (restorable) sessions via consult."
  (interactive)
  (if decknix--sidebar-previous-sessions
      (decknix-sidebar-nav-previous-consult)
    (message "No previous sessions")))

;; == Unified RET dispatcher (#123) ==
;; RET on any actionable row opens a row-specific action transient
;; (Action Menu).  M-RET / C-u RET runs the row's primary action
;; directly (typically "open URL").  Hub rows are routed via
;; `decknix-hub-type'; non-hub rows (sessions, headers) fall through
;; to the existing `agent-shell-workspace-sidebar-goto' handler.
;; See `specs/sidebar-ret.md' §3.2.1, §3.3.

(defvar decknix--sidebar-action-context nil
  "Alist of `decknix-hub-*' text properties for the active row.
Set by `decknix-sidebar-ret' immediately before invoking a row
transient; suffixes read it via `decknix--sidebar-action-prop'.")

(defun decknix--sidebar-row-context ()
  "Return an alist of `decknix-hub-*' properties at line beginning.
Returns nil when the row carries no hub properties (e.g. a session,
section header, or workspace sub-header)."
  (let* ((pos (line-beginning-position))
         (type (get-text-property pos 'decknix-hub-type)))
    (when type
      (let (ctx)
        (dolist (prop '(decknix-hub-type
                        decknix-hub-url
                        decknix-hub-repo
                        decknix-hub-number
                        decknix-hub-branch
                        decknix-hub-sha
                        decknix-hub-linked-kind
                        decknix-hub-pr-state
                        decknix-hub-ci-status
                        decknix-hub-deploy-url
                        decknix-hub-head-repo
                        decknix-hub-head-branch
                        decknix-hub-conv-key
                        decknix-hub-jira-key
                        decknix-hub-jira-status))
          (let ((v (get-text-property pos prop)))
            (when v (push (cons prop v) ctx))))
        ctx))))

(defun decknix--sidebar-action-prop (key)
  "Return KEY from the active row's context alist."
  (alist-get key decknix--sidebar-action-context))

(defun decknix--sidebar-action-description ()
  "One-line label for the active row, used as the transient header."
  (let* ((repo (decknix--sidebar-action-prop 'decknix-hub-repo))
         (num  (decknix--sidebar-action-prop 'decknix-hub-number))
         (jk   (decknix--sidebar-action-prop 'decknix-hub-jira-key))
         (br   (decknix--sidebar-action-prop 'decknix-hub-branch))
         (url  (decknix--sidebar-action-prop 'decknix-hub-url)))
    (cond
     (jk (format "Task %s" jk))
     ((and repo num) (format "%s#%s" repo num))
     ((and repo br)  (format "%s @ %s" repo br))
     (url url)
     (t "(unknown row)"))))

;; -- Concrete suffixes (verbs with backing implementations) --

(transient-define-suffix decknix--sb-act-open ()
  "Open the row's URL in xwidget/EWW."
  :description "Open here"
  (interactive)
  (let ((url (decknix--sidebar-action-prop 'decknix-hub-url)))
    (if url (decknix--open-url url) (message "No URL"))))

(transient-define-suffix decknix--sb-act-browser ()
  "Open the row's URL in the system browser."
  :description "Open in browser"
  (interactive)
  (let ((url (decknix--sidebar-action-prop 'decknix-hub-url)))
    (if url (browse-url url) (message "No URL"))))

(transient-define-suffix decknix--sb-act-copy-url ()
  "Copy the row's URL to the kill-ring."
  :description "Copy URL"
  (interactive)
  (let ((url (decknix--sidebar-action-prop 'decknix-hub-url)))
    (if url (progn (kill-new url) (message "Copied: %s" url))
      (message "No URL"))))

(transient-define-suffix decknix--sb-act-review ()
  "Start an agent review session for the row's PR URL."
  :description "Start review session"
  (interactive)
  (let ((url (decknix--sidebar-action-prop 'decknix-hub-url)))
    (if (and url (fboundp 'decknix--nav-hub-start-review))
        (decknix--nav-hub-start-review url)
      (message "No URL"))))

(transient-define-suffix decknix--sb-act-review-split ()
  "Start a review session in a split window."
  :description "Start review (split)"
  (interactive)
  (let ((url (decknix--sidebar-action-prop 'decknix-hub-url)))
    (if (and url (fboundp 'decknix--nav-hub-start-review-split))
        (decknix--nav-hub-start-review-split url)
      (message "No URL"))))

(transient-define-suffix decknix--sb-act-merge ()
  "Merge the active PR via gh CLI."
  :description "Merge"
  (interactive)
  (let ((repo (decknix--sidebar-action-prop 'decknix-hub-repo))
        (num  (decknix--sidebar-action-prop 'decknix-hub-number)))
    (if (and repo num (fboundp 'decknix--hub-wip-merge))
        (decknix--hub-wip-merge repo num)
      (message "No PR context"))))

(transient-define-suffix decknix--sb-act-close ()
  "Close the active PR via gh CLI."
  :description "Close"
  (interactive)
  (let ((repo (decknix--sidebar-action-prop 'decknix-hub-repo))
        (num  (decknix--sidebar-action-prop 'decknix-hub-number)))
    (if (and repo num (fboundp 'decknix--hub-wip-close))
        (decknix--hub-wip-close repo num)
      (message "No PR context"))))

(transient-define-suffix decknix--sb-act-comment ()
  "Add a comment to the active PR/issue via gh CLI."
  :description "Comment"
  (interactive)
  (let ((repo (decknix--sidebar-action-prop 'decknix-hub-repo))
        (num  (decknix--sidebar-action-prop 'decknix-hub-number)))
    (if (and repo num (fboundp 'decknix--hub-wip-comment))
        (decknix--hub-wip-comment repo num)
      (message "No PR context"))))

(transient-define-suffix decknix--sb-act-copy-jira-key ()
  "Copy the active task's Jira key to the kill-ring."
  :description "Copy Jira key"
  (interactive)
  (let ((k (decknix--sidebar-action-prop 'decknix-hub-jira-key)))
    (if k (progn (kill-new k) (message "Copied: %s" k))
      (message "No Jira key"))))

(transient-define-suffix decknix--sb-act-unlink ()
  "Unlink this PR / repo from its owning agent session."
  :description "Unlink from session"
  (interactive)
  (let* ((conv-key (decknix--sidebar-action-prop 'decknix-hub-conv-key))
         (url      (decknix--sidebar-action-prop 'decknix-hub-url))
         (type     (decknix--sidebar-action-prop 'decknix-hub-type))
         (branch   (decknix--sidebar-action-prop 'decknix-hub-branch)))
    (cond
     ((not conv-key)
      (message "Row not associated with a session"))
     ((eq type 'linked-repo)
      (when (fboundp 'decknix--agent-unlink-repo)
        (decknix--agent-unlink-repo conv-key url branch)))
     (t
      (when (fboundp 'decknix--agent-unlink-pr)
        (decknix--agent-unlink-pr conv-key url))))))

;; -- Stub suffixes (verbs pending follow-up issues) --
;; Placeholders preserve the spec's stable menu shape so the
;; transient layout doesn't shift when each verb lands.

(defmacro decknix--sb-stub (name desc &optional issue)
  "Define a placeholder transient suffix NAME with DESC.
ISSUE, when supplied, is appended as `(#NNN)' to the echo-area
message so users can find the tracking ticket."
  `(transient-define-suffix ,name ()
     :description ,desc
     (interactive)
     (message "%s — pending%s"
              ,desc
              ,(if issue (format " (#%s)" issue) ""))))

(decknix--sb-stub decknix--sb-act-investigate    "Start investigate session")
(decknix--sb-stub decknix--sb-act-review-comment "Review-comment on PR")
(decknix--sb-stub decknix--sb-act-jump-ci        "Jump to CI run")
(decknix--sb-stub decknix--sb-act-jump-deploy    "Jump to deploy")
(decknix--sb-stub decknix--sb-act-transition     "Transition status")
(decknix--sb-stub decknix--sb-act-align-jira     "Align Jira with code")
(decknix--sb-stub decknix--sb-act-analyze        "Analyze (AI)")
(decknix--sb-stub decknix--sb-act-spec           "Define/update spec")
(decknix--sb-stub decknix--sb-act-reveal         "Reveal in Sessions picker")

;; -- Inapt-if predicates (dim, don't hide, per spec §3.1) --

(defun decknix--sb-act-deploy-absent-p ()
  "Non-nil when the active row has no deploy URL (D verb dimmed)."
  (not (decknix--sidebar-action-prop 'decknix-hub-deploy-url)))

(defun decknix--sb-act-not-authored-p ()
  "Non-nil when the active linked PR is not authored by the user."
  (not (eq (decknix--sidebar-action-prop 'decknix-hub-linked-kind)
           'authored)))

;; -- Five hub-row transients (spec §3.2.1) --

(transient-define-prefix decknix-sidebar-request-menu ()
  "Action menu for a Requests row (PR review awaiting me).
Per spec §3.7, review verbs (`r s c R') and the worktree submenu
live under the uppercase category keys `R Review…' / `W Worktree…'
— a one-tap step costs +1 keypress vs. the pre-§3.7 layout but
unifies the menu with the sidebar-global `R W S' fast-paths.
`M comment' mirrors the Task menu so quick comments (dependabot rebase,
auggie review, etc.) are one tap from any PR row."
  [:description decknix--sidebar-action-description
   ["Navigate"
    ("o" decknix--sb-act-open)
    ("b" decknix--sb-act-browser)
    ("c" decknix--sb-act-copy-url)]
   ["Submenus"
    ("R" decknix--sb-act-review-submenu)
    ("W" decknix--sb-act-worktree)]
   ["Direct"
    ("M" decknix--sb-act-comment)]
   ["Pipeline"
    ("C" decknix--sb-act-jump-ci)]
   ["Other"
    ("L" decknix--sb-act-reveal)]]
  [("q" "Cancel" transient-quit-one)])

(transient-define-prefix decknix-sidebar-wip-menu ()
  "Action menu for a WIP row (my open PR).
Per spec §3.7, review verbs and the worktree submenu live under
the uppercase category keys `R Review…' / `W Worktree…'.
`M comment' mirrors the Task and Request menus for quick PR comments."
  [:description decknix--sidebar-action-description
   ["Navigate"
    ("o" decknix--sb-act-open)
    ("b" decknix--sb-act-browser)
    ("c" decknix--sb-act-copy-url)]
   ["Submenus"
    ("R" decknix--sb-act-review-submenu)
    ("W" decknix--sb-act-worktree)]
   ["Status"
    ("m" decknix--sb-act-merge)
    ("x" decknix--sb-act-close)
    ("M" decknix--sb-act-comment)]
   ["Pipeline"
    ("C" decknix--sb-act-jump-ci)
    ("D" decknix--sb-act-jump-deploy
     :inapt-if decknix--sb-act-deploy-absent-p)]
   ["Other"
    ("L" decknix--sb-act-reveal)]]
  [("q" "Cancel" transient-quit-one)])

(transient-define-prefix decknix-sidebar-task-menu ()
  "Action menu for a Tasks row (Jira issue).
Per spec §3.7, `i investigate' graduated into `S Session…'.  The
spec verb moved from uppercase `S' to lowercase `s' to free `S'
for the Session category key.  `M comment' stays at top level
because Tasks have no Review submenu to receive it."
  [:description decknix--sidebar-action-description
   ["Navigate"
    ("o" decknix--sb-act-open)
    ("b" decknix--sb-act-browser)
    ("c" decknix--sb-act-copy-url)]
   ["Submenus"
    ("S" decknix--sb-act-session-submenu)]
   ["Direct"
    ("M" decknix--sb-act-comment)]
   ["Jira"
    ("k" decknix--sb-act-copy-jira-key)
    ("t" decknix--sb-act-transition)
    ("A" decknix--sb-act-align-jira)
    ("y" decknix--sb-act-analyze)
    ("s" decknix--sb-act-spec)]]
  [("q" "Cancel" transient-quit-one)])

(transient-define-prefix decknix-sidebar-linked-pr-menu ()
  "Action menu for a linked PR row (under a session).
Per spec §3.7, review verbs (`r s c R') and unlink (`u') graduated
into `R Review…' and `S Session…'.  Worktree moved from `w' to
the canonical uppercase `W'."
  [:description decknix--sidebar-action-description
   ["Navigate"
    ("o" decknix--sb-act-open)
    ("b" decknix--sb-act-browser)
    ("c" decknix--sb-act-copy-url)]
   ["Submenus"
    ("R" decknix--sb-act-review-submenu)
    ("W" decknix--sb-act-worktree)
    ("S" decknix--sb-act-session-submenu)]
   ["Status"
    ("m" decknix--sb-act-merge
     :inapt-if decknix--sb-act-not-authored-p)
    ("x" decknix--sb-act-close
     :inapt-if decknix--sb-act-not-authored-p)
    ("M" decknix--sb-act-comment)]
   ["Pipeline"
    ("C" decknix--sb-act-jump-ci)
    ("D" decknix--sb-act-jump-deploy
     :inapt-if decknix--sb-act-deploy-absent-p)]
   ["Other"
    ("L" decknix--sb-act-reveal)]]
  [("q" "Cancel" transient-quit-one)])

(transient-define-prefix decknix-sidebar-linked-repo-menu ()
  "Action menu for a linked repo row (under a session).
Per spec §3.7, `i investigate' and `u unlink' graduated into
`S Session…'; worktree moved from `w' to `W'."
  [:description decknix--sidebar-action-description
   ["Navigate"
    ("o" decknix--sb-act-open)
    ("b" decknix--sb-act-browser)
    ("c" decknix--sb-act-copy-url)]
   ["Submenus"
    ("W" decknix--sb-act-worktree)
    ("S" decknix--sb-act-session-submenu)]
   ["Pipeline"
    ("C" decknix--sb-act-jump-ci)
    ("D" decknix--sb-act-jump-deploy
     :inapt-if decknix--sb-act-deploy-absent-p)]
   ["Other"
    ("L" decknix--sb-act-reveal)]]
  [("q" "Cancel" transient-quit-one)])

;; -- Worktree submenu (#129; spec §3.6.4) --
;; Surfaces the registry from #128 as a stable-shape transient.
;; All 8 verbs are always rendered; verbs that don't apply for the
;; current `(repo, branch, state)' are dimmed via `:inapt-if'.

(defun decknix--sb-act-wt-repo ()
  "Return canonical \"owner/repo\" for the active row, or nil."
  (let ((r (or (decknix--sidebar-action-prop 'decknix-hub-head-repo)
               (decknix--sidebar-action-prop 'decknix-hub-repo))))
    (when (and r (stringp r))
      (decknix--hub-worktree-canonical-repo r))))

(defun decknix--sb-act-wt-branch ()
  "Return the branch the active row points at, or nil."
  (or (decknix--sidebar-action-prop 'decknix-hub-head-branch)
      (decknix--sidebar-action-prop 'decknix-hub-branch)))

(defun decknix--sb-act-wt-primary ()
  "Return the primary clone path for the active row's repo, or nil."
  (let ((repo (decknix--sb-act-wt-repo)))
    (and repo (decknix-hub-worktree-primary repo))))

(defun decknix--sb-act-wt-path ()
  "Return the worktree path for the active (repo, branch), or nil."
  (let ((repo (decknix--sb-act-wt-repo))
        (branch (decknix--sb-act-wt-branch)))
    (and repo branch (decknix-hub-worktree-find repo branch))))

(defun decknix--sb-act-wt-state ()
  "Return one of `in-worktree', `primary-head', `branch-ref-only',
or `no-clone' for the active row.  `branch-ref-only' covers the case
where the clone exists but the branch isn't checked out anywhere
locally; the registry only tracks worktrees, so this is a reasonable
fallback (a more accurate detector would shell out to
`git rev-parse --verify' but that is deferred to #130)."
  (let* ((repo (decknix--sb-act-wt-repo))
         (branch (decknix--sb-act-wt-branch))
         (primary (and repo (decknix-hub-worktree-primary repo)))
         (worktrees (and repo (decknix-hub-worktree-list repo)))
         (wt (and branch (cdr (assoc branch worktrees)))))
    (cond
     ((not primary) 'no-clone)
     ((and wt (file-equal-p wt primary)) 'primary-head)
     (wt 'in-worktree)
     (t 'branch-ref-only))))

(defun decknix--sb-act-wt-sibling-path (primary branch)
  "Compute the sibling worktree layout path for PRIMARY @ BRANCH.
Layout: <primary-parent>/<primary-basename>-worktrees/<sanitised-branch>.
Slashes in BRANCH are replaced with dashes so nested branch names
(e.g. feature/foo) don't create extra directory levels."
  (when (and primary branch)
    (let* ((primary (directory-file-name (expand-file-name primary)))
           (parent (file-name-directory primary))
           (base (file-name-nondirectory primary))
           (safe-branch (replace-regexp-in-string "/" "-" branch)))
      (expand-file-name
       (concat base "-worktrees/" safe-branch)
       parent))))

(defun decknix--sb-act-wt-sessions-using (path)
  "Return list of (CONV-KEY . WORKSPACE) where workspace = PATH.
Walks `agent-sessions.json' so the interlock survives Emacs restarts
(live-only would miss saved sessions that haven't been resumed yet)."
  (let ((target (file-name-as-directory (expand-file-name path)))
        (out nil))
    (condition-case nil
        (let* ((store (decknix--agent-tags-read))
               (convs (and store
                           (decknix--agent-tags-conversations store))))
          (when convs
            (maphash
             (lambda (k entry)
               (let ((ws (and (hash-table-p entry)
                              (gethash "workspace" entry))))
                 (when (and ws (stringp ws)
                            (file-equal-p
                             (file-name-as-directory
                              (expand-file-name ws))
                             target))
                   (push (cons k ws) out))))
             convs)))
      (error nil))
    out))

;; -- Inapt predicates --

(defun decknix--sb-act-wt-no-worktree-p ()
  "Non-nil when the active (repo, branch) has no worktree.
Used for verbs that operate on an existing worktree: o, x, r, c."
  (null (decknix--sb-act-wt-path)))

(defun decknix--sb-act-wt-no-clone-p ()
  "Non-nil when the active row's repo has no local clone.
Used for verbs that need a clone: n, p, d, s (s only when no clone
*and* no worktree — but with no clone there's nowhere to create one)."
  (null (decknix--sb-act-wt-primary)))

(defun decknix--sb-act-wt-create-disabled-p ()
  "Non-nil when `n' Create worktree should be dimmed.
Disabled when there is no clone OR when the branch already has a
worktree (no point creating it again)."
  (or (decknix--sb-act-wt-no-clone-p)
      (decknix--sb-act-wt-path)))

(defun decknix--sb-act-wt-no-context-p ()
  "Non-nil when the active row has no (repo, branch) context.
Used to dim every verb on rows that don't carry head-repo/head-branch
properties yet (rare — most hub rows do, but e.g. headers wouldn't)."
  (or (null (decknix--sb-act-wt-repo))
      (null (decknix--sb-act-wt-branch))))

;; -- Async wrappers (git and decknix wt CLI) --

(defun decknix--wt-cli-async (args on-success)
  "Run `decknix wt ARGS' asynchronously.
ARGS is a list of strings (e.g. '(\"prune\" \"--repo\" \"owner/repo\")).
ON-SUCCESS is a function of one argument (stdout string) called on
exit-0.  Errors are reported via `message'."
  (let ((buf (generate-new-buffer " *decknix-wt*")))
    (condition-case err
        (let ((proc (apply #'make-process
                           :name "decknix-wt"
                           :buffer buf
                           :connection-type 'pipe
                           :command (append (list "decknix" "wt") args)
                           nil)))
          (set-process-sentinel
           proc
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (let* ((code (process-exit-status proc))
                      (out (when (buffer-live-p (process-buffer proc))
                             (with-current-buffer (process-buffer proc)
                               (buffer-string)))))
                 (unwind-protect
                     (cond
                      ((zerop code)
                       (when on-success
                         (funcall on-success (or out ""))))
                      (t
                       (message "decknix wt %s failed (%d): %s"
                                (car args) code
                                (string-trim (or out "")))))
                   (when (buffer-live-p (process-buffer proc))
                     (kill-buffer (process-buffer proc)))))))))
      (error
       (when (buffer-live-p buf) (kill-buffer buf))
       (message "decknix wt spawn error: %s" (error-message-string err))))))

(defun decknix--hub-worktree-git-async (primary args repo on-success)
  "Run `git -C PRIMARY ARGS' asynchronously for REPO.
On exit-0 invokes ON-SUCCESS (a function of one argument: stdout).
Always refreshes the registry for REPO when the process exits."
  (let* ((primary (expand-file-name primary))
         (buf (generate-new-buffer " *hub-worktree-git*")))
    (condition-case err
        (let ((proc (apply #'make-process
                           :name (format "hub-wt-git-%s" repo)
                           :buffer buf
                           :connection-type 'pipe
                           :command (append (list "git" "-C" primary)
                                            args)
                           nil)))
          (set-process-sentinel
           proc
           (eval `(lambda (proc _event)
                    (when (memq (process-status proc) '(exit signal))
                      (let* ((code (process-exit-status proc))
                             (out (when (buffer-live-p
                                         (process-buffer proc))
                                    (with-current-buffer
                                        (process-buffer proc)
                                      (buffer-string)))))
                        (unwind-protect
                            (cond
                             ((zerop code)
                              (when ',on-success
                                (funcall ,on-success
                                         (or out ""))))
                             (t
                              (message "git %s failed (%d): %s"
                                       ',(car args) code
                                       (string-trim
                                        (or out "")))))
                          (when (buffer-live-p
                                 (process-buffer proc))
                            (kill-buffer (process-buffer proc)))
                          (decknix-hub-worktree-registry-refresh
                           ,repo)))))
                 t)))
      (error
       (when (buffer-live-p buf) (kill-buffer buf))
       (message "git spawn error: %s" (error-message-string err))))))

;; -- Suffixes (the 8 worktree verbs) --

(transient-define-suffix decknix--sb-act-wt-open ()
  "Open the worktree directory in dired."
  :description "Open worktree"
  :inapt-if #'decknix--sb-act-wt-no-worktree-p
  (interactive)
  (let ((path (decknix--sb-act-wt-path)))
    (if path
        (dired (expand-file-name path))
      (message "No worktree for this branch — press n to create one"))))

(transient-define-suffix decknix--sb-act-wt-new ()
  "Create a new worktree for the active (repo, branch).
Layout: <primary>-worktrees/<branch>.  Branch name is taken from the
active row; minibuffer prompt confirms the branch and target path."
  :description "Create worktree"
  :inapt-if #'decknix--sb-act-wt-create-disabled-p
  (interactive)
  (let* ((repo (decknix--sb-act-wt-repo))
         (branch (decknix--sb-act-wt-branch))
         (primary (decknix--sb-act-wt-primary))
         (default-path (decknix--sb-act-wt-sibling-path primary branch))
         (path (read-file-name
                (format "Worktree for %s @ %s: " repo branch)
                (file-name-directory default-path)
                nil nil
                (file-name-nondirectory default-path))))
    (when (file-exists-p path)
      (user-error "Path already exists: %s" path))
    (make-directory (file-name-directory path) t)
    (decknix--hub-worktree-git-async
     primary
     (list "worktree" "add" (expand-file-name path) branch)
     repo
     (eval `(lambda (_out)
              (message "Worktree created: %s" ,path))
           t))))

(transient-define-suffix decknix--sb-act-wt-session ()
  "Start an agent session rooted at the worktree.
If no worktree exists yet, create one first (sibling layout) and
start the session in the resulting path."
  :description "Start session in worktree"
  :inapt-if #'decknix--sb-act-wt-no-clone-p
  (interactive)
  (let* ((repo (decknix--sb-act-wt-repo))
         (branch (decknix--sb-act-wt-branch))
         (primary (decknix--sb-act-wt-primary))
         (existing (decknix--sb-act-wt-path)))
    (cond
     (existing
      (decknix--agent-quickaction-start
       (format "%s-%s"
               (replace-regexp-in-string "/" "-" repo)
               (replace-regexp-in-string "/" "-" branch))
       (list (replace-regexp-in-string "/" "-" branch))
       existing nil))
     (t
      (let ((path (decknix--sb-act-wt-sibling-path primary branch)))
        (when (file-exists-p path)
          (user-error "Path already exists: %s" path))
        (make-directory (file-name-directory path) t)
        (decknix--hub-worktree-git-async
         primary
         (list "worktree" "add" (expand-file-name path) branch)
         repo
         (eval `(lambda (_out)
                  (decknix--agent-quickaction-start
                   ,(format "%s-%s"
                            (replace-regexp-in-string "/" "-" repo)
                            (replace-regexp-in-string "/" "-" branch))
                   ',(list (replace-regexp-in-string "/" "-" branch))
                   ,path nil))
               t)))))))

(transient-define-suffix decknix--sb-act-wt-remove ()
  "Remove the worktree for the active (repo, branch).
Aborts if any saved session's workspace points at the worktree.
Prefix arg overrides the dirty/session guard via `git worktree remove --force'."
  :description "Remove worktree"
  :inapt-if #'decknix--sb-act-wt-no-worktree-p
  (interactive)
  (let* ((repo (decknix--sb-act-wt-repo))
         (primary (decknix--sb-act-wt-primary))
         (path (decknix--sb-act-wt-path))
         (force current-prefix-arg)
         (sessions (decknix--sb-act-wt-sessions-using path)))
    (cond
     ((and sessions (not force))
      (message "Aborted: %d session(s) use this workspace; C-u x to force"
               (length sessions)))
     ((not (yes-or-no-p (format "Remove worktree %s? " path))) nil)
     (t
      (decknix--hub-worktree-git-async
       primary
       (append (list "worktree" "remove")
               (when force (list "--force"))
               (list (expand-file-name path)))
       repo
       (eval `(lambda (_out)
                (message "Worktree removed: %s" ,path))
             t))))))

(transient-define-suffix decknix--sb-act-wt-reveal ()
  "Reveal the worktree directory in macOS Finder."
  :description "Reveal in Finder"
  :inapt-if #'decknix--sb-act-wt-no-worktree-p
  (interactive)
  (let ((path (decknix--sb-act-wt-path)))
    (if path
        (call-process "open" nil 0 nil (expand-file-name path))
      (message "No worktree for this branch"))))

(transient-define-suffix decknix--sb-act-wt-prune ()
  "Prune stale worktree records for the active row's primary clone.
Calls `decknix wt prune' which cleans both the registry and git
worktree metadata.  Prefix arg adds --dry-run."
  :description "Prune stale worktrees"
  :inapt-if #'decknix--sb-act-wt-no-clone-p
  (interactive)
  (let* ((repo (decknix--sb-act-wt-repo))
         (dry-run current-prefix-arg)
         (args (append (list "prune" "--repo" repo)
                       (when dry-run (list "--dry-run")))))
    (decknix--wt-cli-async
     args
     (lambda (out)
       (let ((trimmed (string-trim (or out ""))))
         (if (string-empty-p trimmed)
             (message "Pruned %s: nothing to remove" repo)
           (message "Pruned %s:\n%s" repo trimmed)))))))

(transient-define-suffix decknix--sb-act-wt-status ()
  "Show git status for the worktree (or the primary clone if none).
Uses `magit-status' when available; falls back to `vc-dir' otherwise."
  :description "Status summary"
  :inapt-if #'decknix--sb-act-wt-no-clone-p
  (interactive)
  (let* ((path (or (decknix--sb-act-wt-path)
                   (decknix--sb-act-wt-primary))))
    (cond
     ((not path) (message "No clone for this repo"))
     ((fboundp 'magit-status) (magit-status (expand-file-name path)))
     (t (vc-dir (expand-file-name path))))))

(transient-define-suffix decknix--sb-act-wt-copy ()
  "Copy the worktree path to the kill-ring."
  :description "Copy worktree path"
  :inapt-if #'decknix--sb-act-wt-no-worktree-p
  (interactive)
  (let ((path (decknix--sb-act-wt-path)))
    (if path
        (let ((expanded (expand-file-name path)))
          (kill-new expanded)
          (message "Copied: %s" expanded))
      (message "No worktree for this branch"))))

;; -- Header + transient --

(defun decknix--sb-act-wt-description ()
  "Header label for the worktree submenu: `repo @ branch — <state>'."
  (let* ((repo (decknix--sb-act-wt-repo))
         (branch (decknix--sb-act-wt-branch))
         (state (decknix--sb-act-wt-state))
         (state-str
          (pcase state
            ('in-worktree     "in worktree")
            ('primary-head    "primary HEAD")
            ('branch-ref-only "branch ref only")
            ('no-clone        "no local clone")
            (_                "unknown"))))
    (cond
     ((and repo branch) (format "%s @ %s — %s" repo branch state-str))
     (repo (format "%s — %s" repo state-str))
     (t "Worktree (no repo context)"))))

(transient-define-suffix decknix--sb-act-clean-fork-remotes ()
  "Clean orphan fork remotes from all live clones.
Prefix arg runs `--dry-run' (shows what would be removed without acting)."
  :description "Clean fork remotes"
  (interactive)
  (let* ((dry-run current-prefix-arg)
         (args (append (list "clean-fork-remotes")
                       (when dry-run (list "--dry-run")))))
    (if (or dry-run
            (yes-or-no-p "Remove orphan fork remotes from all live clones? "))
        (decknix--wt-cli-async
         args
         (lambda (out)
           (let ((trimmed (string-trim (or out ""))))
             (if (string-empty-p trimmed)
                 (message "Clean fork remotes: nothing to remove")
               (message "Clean fork remotes:\n%s" trimmed)))))
      (message "Cancelled"))))

;; -- Cross-worktree hygiene transient (spec §3.6.11) --
;;
;; Three read-only / confirmation-gated verbs surface the "what's safe
;; to delete?" audit workflow across ALL repos — not just the one the
;; active sidebar row happens to resolve.
;;
;; Implementation note: `decknix--hyg-audit' and `decknix--hyg-orphans'
;; surface their output in a dedicated *decknix wt …* buffer rather than
;; the minibuffer so multi-line reports are readable.  `decknix--hyg-prune-all'
;; uses message so the result stays ephemeral (it's a short summary).

(defun decknix--hyg-display-output (buf-name out)
  "Show OUT in a buffer named BUF-NAME, or echo a no-results notice."
  (let ((trimmed (string-trim (or out ""))))
    (if (string-empty-p trimmed)
        (message "%s: nothing to report" buf-name)
      (with-current-buffer (get-buffer-create buf-name)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert trimmed)
          (goto-char (point-min)))
        (display-buffer (current-buffer))))))

(transient-define-suffix decknix--hyg-audit ()
  "Dry-run report: stale / dirty / orphan-fork / branch-deleted-upstream.
Calls `decknix wt audit'; output appears in *decknix wt audit* buffer."
  :description "Audit (dry-run report)"
  (interactive)
  (message "Running audit…")
  (decknix--wt-cli-async
   (list "audit")
   (lambda (out)
     (decknix--hyg-display-output "*decknix wt audit*" out))))

(transient-define-suffix decknix--hyg-orphans ()
  "List worktrees whose upstream branch has been deleted.
Calls `decknix wt orphans'; output appears in *decknix wt orphans* buffer."
  :description "List orphan branches"
  (interactive)
  (message "Checking for orphan branches…")
  (decknix--wt-cli-async
   (list "orphans")
   (lambda (out)
     (decknix--hyg-display-output "*decknix wt orphans*" out))))

(transient-define-suffix decknix--hyg-prune-all ()
  "Prune stale worktree records across ALL repos.
Calls `decknix wt prune' (no --repo) to sweep every registered clone.
Prefix arg adds --dry-run to preview without mutating state."
  :description "Prune stale (all repos)"
  (interactive)
  (let* ((dry-run current-prefix-arg)
         (args (append (list "prune")
                       (when dry-run (list "--dry-run")))))
    (decknix--wt-cli-async
     args
     (lambda (out)
       (let ((trimmed (string-trim (or out ""))))
         (if (string-empty-p trimmed)
             (message "Prune (all repos): nothing to remove")
           (message "Prune (all repos):\n%s" trimmed)))))))

(transient-define-prefix decknix-worktree-hygiene ()
  "Cross-worktree hygiene transient (spec §3.6.11).
Read-only verbs (a, o) produce reports; prune (p) mutates but with
confirmation; fork-remotes (f) also prompts.
Also accessible as `M-x decknix-worktree-hygiene' from any buffer."
  ["Audit"
   ("a" decknix--hyg-audit)
   ("o" decknix--hyg-orphans)]
  ["Prune"
   ("p" decknix--hyg-prune-all)
   ("f" decknix--sb-act-clean-fork-remotes)]
  [("q" "Cancel" transient-quit-one)])

(transient-define-prefix decknix-sidebar-worktree-menu ()
  "Worktree submenu (#129; spec §3.6.4).
Eight verbs with stable layout; verbs that don't apply for the
current `(repo, branch, state)' are dimmed via `:inapt-if'.
Press H to open the cross-repo hygiene transient (spec §3.6.11)."
  [:description decknix--sb-act-wt-description
   ["Worktree"
    ("o" decknix--sb-act-wt-open)
    ("n" decknix--sb-act-wt-new)
    ("s" decknix--sb-act-wt-session)
    ("x" decknix--sb-act-wt-remove)]
   ["Inspect"
    ("r" decknix--sb-act-wt-reveal)
    ("d" decknix--sb-act-wt-status)
    ("c" decknix--sb-act-wt-copy)
    ("p" decknix--sb-act-wt-prune)]]
  [("H" "Hygiene…" decknix-worktree-hygiene)
   ("q" "Cancel" transient-quit-one)])

(transient-define-suffix decknix--sb-act-worktree ()
  "Open the worktree submenu for the active row."
  :description "Worktree…"
  :inapt-if #'decknix--sb-act-wt-no-context-p
  (interactive)
  (decknix--sidebar-call-transient #'decknix-sidebar-worktree-menu))

;; -- Category submenus (Magit-inspired; spec §3.7) --
;;
;; The Action Menu (RET) advertises uppercase category keys
;; — `R Review… / W Worktree… / S Session…' — that mirror
;; the sidebar-global section keys (`r w l p s').  Pressing
;; the uppercase letter at the sidebar-global level (without
;; opening the Action Menu first) routes straight to the
;; row's matching submenu, giving power users a one-tap path
;; while RET stays the discoverable hub for everyone else.
;;
;; The submenus inherit `decknix--sidebar-action-context'
;; from the dispatching command (RET-via-row-menu or the
;; sidebar-global `R W S' handlers), so suffixes always have
;; a populated context regardless of entry point.

(defun decknix--sb-act-review-rows-p ()
  "Non-nil when the active row supports review verbs."
  (memq (decknix--sidebar-action-prop 'decknix-hub-type)
        '(review wip wip-placeholder linked-pr)))

(defun decknix--sb-act-no-review-p ()
  "Inapt predicate: dim Review submenu entry on rows without review."
  (not (decknix--sb-act-review-rows-p)))

(defun decknix--sb-act-session-rows-p ()
  "Non-nil when the active row supports session verbs.
Phase 1 covers `unlink' (linked-pr/linked-repo) and `investigate'
(task/linked-repo).  Phase 2 will add link/move-to-session for
review/wip rows; until then those rows have no session verbs."
  (memq (decknix--sidebar-action-prop 'decknix-hub-type)
        '(task linked-pr linked-repo)))

(defun decknix--sb-act-no-session-p ()
  "Inapt predicate: dim Session submenu entry on rows without session verbs."
  (not (decknix--sb-act-session-rows-p)))

(defun decknix--sb-act-not-task-p ()
  "Non-nil when the active row is not a task (for `i' investigate)."
  (not (eq (decknix--sidebar-action-prop 'decknix-hub-type) 'task)))

(defun decknix--sb-act-not-linked-p ()
  "Non-nil when the active row is not linked to a session."
  (not (decknix--sidebar-action-prop 'decknix-hub-conv-key)))

(transient-define-prefix decknix-sidebar-review-menu ()
  "Review submenu (spec §3.7).
Four verbs with stable layout; the whole menu is meaningful only
on rows that carry a PR URL (Request, WIP, WIP-placeholder, Linked
PR).  Sidebar-global `R' and the in-menu `R Review…' entry both
route here."
  [:description decknix--sidebar-action-description
   ["Review"
    ("r" decknix--sb-act-review)
    ("s" decknix--sb-act-review-split)
    ("c" decknix--sb-act-comment)
    ("R" decknix--sb-act-review-comment)]]
  [("q" "Cancel" transient-quit-one)])

(transient-define-suffix decknix--sb-act-review-submenu ()
  "Open the review submenu for the active row."
  :description "Review…"
  :inapt-if #'decknix--sb-act-no-review-p
  (interactive)
  (decknix--sidebar-call-transient #'decknix-sidebar-review-menu))

(transient-define-prefix decknix-sidebar-session-menu ()
  "Session submenu (spec §3.7).
Stable-shape skeleton — Phase 1 hosts the verbs that graduated from
top-level (`u' unlink, `i' investigate).  Phase 2 will add `l'
link-to-session and `m' move-to-session.  Sidebar-global `S' and the
in-menu `S Session…' entry both route here."
  [:description decknix--sidebar-action-description
   ["Session"
    ("u" decknix--sb-act-unlink :inapt-if decknix--sb-act-not-linked-p)
    ("i" decknix--sb-act-investigate :inapt-if decknix--sb-act-not-task-p)]]
  [("q" "Cancel" transient-quit-one)])

(transient-define-suffix decknix--sb-act-session-submenu ()
  "Open the session submenu for the active row."
  :description "Session…"
  :inapt-if #'decknix--sb-act-no-session-p
  (interactive)
  (decknix--sidebar-call-transient #'decknix-sidebar-session-menu))


;; -- Dispatcher and primary action --

(defun decknix-sidebar-ret ()
  "Open the action menu for the row at point.
Hub rows (Request, WIP, Task, Linked PR, Linked Repo) get a row-
specific transient.  Other rows fall through to the existing
primary-action handler so sessions and headers behave as before
until #125/#126/#127 land.  M-RET / C-u RET runs the primary action
directly — see `decknix-sidebar-primary-action'."
  (interactive)
  (let* ((ctx (decknix--sidebar-row-context))
         (type (alist-get 'decknix-hub-type ctx))
         (cmd (pcase type
                ('review            #'decknix-sidebar-request-menu)
                ('wip               #'decknix-sidebar-wip-menu)
                ;; Placeholder rows reuse the WIP menu — only the
                ;; worktree submenu (`w') is meaningful since
                ;; there is no PR yet, but the URL-dependent
                ;; verbs all degrade to a "No URL" message rather
                ;; than crashing, so the stable-shape policy
                ;; (spec §3.2.1) is preserved.
                ('wip-placeholder   #'decknix-sidebar-wip-menu)
                ('task              #'decknix-sidebar-task-menu)
                ('linked-pr         #'decknix-sidebar-linked-pr-menu)
                ('linked-repo       #'decknix-sidebar-linked-repo-menu))))
    (cond
     ((and ctx cmd)
      (setq decknix--sidebar-action-context ctx)
      (decknix--sidebar-call-transient cmd))
     (t
      (call-interactively #'agent-shell-workspace-sidebar-goto)))))

(defun decknix-sidebar-primary-action ()
  "Run the row's primary action directly (M-RET / C-u RET).
For hub rows: open the URL in xwidget/EWW.  For other rows: defer to
`agent-shell-workspace-sidebar-goto' which handles sessions and
headers."
  (interactive)
  (let* ((ctx (decknix--sidebar-row-context))
         (url (alist-get 'decknix-hub-url ctx)))
    (if (and ctx url)
        (decknix--open-url url)
      (call-interactively #'agent-shell-workspace-sidebar-goto))))

;; v = review the last exchange of the live session at point.
;; C-u v captures the full session history instead of just the
;; last prompt/response.  Delegates to `decknix-agent-review'
;; with the sidebar's buffer-at-point as the current buffer so
;; session/workspace context are picked up correctly.
(defun decknix-sidebar-review-at-point (&optional all)
  "Open a review buffer for the agent session at point.
With prefix ALL, capture the full history (see `decknix-agent-review')."
  (interactive "P")
  (let ((buffer (agent-shell-workspace-sidebar--buffer-at-point)))
    (unless (and buffer (buffer-live-p buffer))
      (user-error "No live agent buffer at point"))
    (with-current-buffer buffer
      (decknix-agent-review all))))

;; == Category submenu fast-paths (spec §3.7) ==
;; `R W S' at sidebar-global level skip the Action Menu hub
;; and open the row's matching submenu directly.  Mirrors the
;; uppercase category keys advertised inside the Action Menu
;; (RET) so muscle memory carries from "open menu, see R" to
;; "press R from anywhere on the row".  Lowercase `r w l p s'
;; keep their existing sidebar-global meaning (section nav,
;; sessions transient) — the uppercase set is purely additive.

(defun decknix--sidebar-open-category (cmd applies-p label)
  "Open submenu CMD for the row at point if APPLIES-P, else explain.
LABEL names the category for the user-facing message."
  (let* ((ctx (decknix--sidebar-row-context))
         (type (alist-get 'decknix-hub-type ctx)))
    (cond
     ((null type)
      (message "No actionable row at point"))
     ((not (funcall applies-p type))
      (message "No %s actions on this %s row" label type))
     (t
      (setq decknix--sidebar-action-context ctx)
      (decknix--sidebar-call-transient cmd)))))

(defun decknix-sidebar-open-review-menu ()
  "Open the Review submenu for the hub row at point (spec §3.7).
Bound to `R' at sidebar-global level."
  (interactive)
  (decknix--sidebar-open-category
   #'decknix-sidebar-review-menu
   (lambda (type)
     (memq type '(review wip wip-placeholder linked-pr)))
   "review"))

(defun decknix-sidebar-open-worktree-menu ()
  "Open the Worktree submenu for the hub row at point (spec §3.7).
Bound to `W' at sidebar-global level."
  (interactive)
  (decknix--sidebar-open-category
   #'decknix-sidebar-worktree-menu
   (lambda (type)
     (memq type '(review wip wip-placeholder linked-pr linked-repo)))
   "worktree"))

(defun decknix-sidebar-open-session-menu ()
  "Open the Session submenu for the hub row at point (spec §3.7).
Bound to `S' at sidebar-global level."
  (interactive)
  (decknix--sidebar-open-category
   #'decknix-sidebar-session-menu
   (lambda (type)
     (memq type '(task linked-pr linked-repo)))
   "session"))

;; == Sidebar state persistence ==
;; Saves toggle states and previous live sessions across restarts.
;; File: ~/.config/decknix/sidebar-state.el (s-expression format).

(defvar decknix--sidebar-state-file
  (expand-file-name "~/.config/decknix/sidebar-state.el")
  "Path to the file storing sidebar toggle states and previous sessions.")

;; `decknix--sidebar-previous-sessions' (the in-memory list) and
;; `decknix--sidebar-previous-dedupe' (the pure dedupe) carved out
;; into `agent-shell/sidebar/decknix-sidebar-previous.el' as PR B.23.
;; Forward declarations live at the top of this module so the
;; remaining call sites here byte-compile clean.

(defun decknix--sidebar-state-save ()
  "Save sidebar toggle states to disk.
Live-session tracking now lives in the dedicated
`decknix--live-sessions-file' (eagerly updated via lifecycle hooks);
this saver only writes UI preferences so a fresh-daemon idle save
cannot clobber the Previous Sessions snapshot."
  (let* ((state
          (list
           (cons 'display-mode decknix--sidebar-display-mode)
           (cons 'width-state decknix--sidebar-width-state)
           (cons 'show-keys decknix--sidebar-show-keys)
           (cons 'quick-switch
                 (and (boundp 'agent-shell-workspace-sidebar--quick-switch)
                      agent-shell-workspace-sidebar--quick-switch))
           (cons 'age-filter
                 (when (boundp 'decknix--hub-age-filter)
                   decknix--hub-age-filter))
           (cons 'org-visibility
                 (when (and (boundp 'decknix--hub-org-visibility)
                            decknix--hub-org-visibility)
                   ;; Serialise hash-table as alist for prin1
                   (let (pairs)
                     (maphash (lambda (k v) (push (cons k v) pairs))
                              decknix--hub-org-visibility)
                     pairs)))
           (cons 'ci-filter
                 (when (boundp 'decknix--hub-ci-filter)
                   decknix--hub-ci-filter))
           (cons 'mention-filter
                 (when (boundp 'decknix--hub-mention-filter)
                   decknix--hub-mention-filter))
           (cons 'show-bots
                 (when (boundp 'decknix--hub-show-bots)
                   decknix--hub-show-bots))
           (cons 'requests-sort-reverse
                 (when (boundp 'decknix--hub-requests-sort-reverse)
                   decknix--hub-requests-sort-reverse))
           (cons 'expand-prs
                 (when (boundp 'decknix--hub-expand-prs)
                   decknix--hub-expand-prs))
           (cons 'show-deploys
                 (when (boundp 'decknix--hub-show-deploys)
                   decknix--hub-show-deploys))
           (cons 'sessions-hide-live
                 decknix--sidebar-sessions-hide-live)
           (cons 'sessions-age-filter
                 decknix--sidebar-sessions-age-filter)
           (cons 'sessions-hide-unknown
                 decknix--sidebar-sessions-hide-unknown)
           (cons 'show-saved-sessions
                 (when (boundp 'decknix--hub-show-saved-sessions)
                   decknix--hub-show-saved-sessions))
           (cons 'tile-count
                 (when (boundp 'decknix--sidebar-tile-count)
                   decknix--sidebar-tile-count))
           (cons 'show-progress
                 (when (boundp 'decknix--sidebar-show-progress)
                   decknix--sidebar-show-progress))
           ;; Worktree toggles (§3.6.12)
           (cons 'wt-live-only
                 (when (boundp 'decknix--sidebar-wt-live-only)
                   decknix--sidebar-wt-live-only))
           (cons 'wt-group-by-repo
                 (when (boundp 'decknix--sidebar-wt-group-by-repo)
                   decknix--sidebar-wt-group-by-repo))
           (cons 'wt-age-filter
                 (when (boundp 'decknix--sidebar-wt-age-filter)
                   decknix--sidebar-wt-age-filter))
           (cons 'wt-hide-clean
                 (when (boundp 'decknix--sidebar-wt-hide-clean)
                   decknix--sidebar-wt-hide-clean))
           (cons 'wt-hide-placeholders
                 (when (boundp 'decknix--sidebar-wt-hide-placeholders)
                   decknix--sidebar-wt-hide-placeholders))
           (cons 'wt-hide-merged
                 (when (boundp 'decknix--sidebar-wt-hide-merged)
                   decknix--sidebar-wt-hide-merged)))))
    (make-directory (file-name-directory decknix--sidebar-state-file) t)
    (with-temp-file decknix--sidebar-state-file
      (insert ";; Auto-generated — do not edit\n")
      (prin1 state (current-buffer))
      (insert "\n"))))

(defun decknix--sidebar-state-restore ()
  "Restore sidebar toggle states and previous sessions from disk."
  (when (file-exists-p decknix--sidebar-state-file)
    (condition-case err
        (let ((state (with-temp-buffer
                       (insert-file-contents decknix--sidebar-state-file)
                       (read (current-buffer)))))
          (when-let ((dm (alist-get 'display-mode state)))
            (setq decknix--sidebar-display-mode dm))
          (when-let ((ws (alist-get 'width-state state)))
            (setq decknix--sidebar-width-state ws))
          (let ((sk (alist-get 'show-keys state 'missing)))
            (unless (eq sk 'missing)
              (setq decknix--sidebar-show-keys sk)))
          (let ((sp (alist-get 'show-progress state 'missing)))
            (unless (eq sp 'missing)
              (when (boundp 'decknix--sidebar-show-progress)
                (setq decknix--sidebar-show-progress sp))))
          (let ((qs (alist-get 'quick-switch state)))
            (when (and qs (boundp 'agent-shell-workspace-sidebar--quick-switch))
              (setq agent-shell-workspace-sidebar--quick-switch t)))
          ;; Hub toggles (restored even if hub loads later)
          (let ((af (alist-get 'age-filter state)))
            (when (and af (boundp 'decknix--hub-age-filter))
              (setq decknix--hub-age-filter af)))
          ;; Org visibility: restore from alist → hash-table
          ;; Also supports legacy 'org-hidden key for backward compat
          (when-let ((ov (or (alist-get 'org-visibility state)
                             (alist-get 'org-hidden state))))
            (when (and (listp ov)
                       (boundp 'decknix--hub-org-visibility))
              (let ((ht (make-hash-table :test 'equal)))
                (dolist (pair ov)
                  (when (consp pair)
                    (puthash (car pair) (cdr pair) ht)))
                (setq decknix--hub-org-visibility ht))))
          ;; CI filter: restore list of visible statuses
          (let ((cf (alist-get 'ci-filter state)))
            (when (and cf (listp cf)
                       (boundp 'decknix--hub-ci-filter))
              (setq decknix--hub-ci-filter cf)))
          ;; Mention filter: restore toggle (4-state cycle).
          ;; Migrates legacy boolean state via normalize helper:
          ;; `t' → `me'; anything unrecognised → `nil'.
          (when (boundp 'decknix--hub-mention-filter)
            (setq decknix--hub-mention-filter
                  (decknix--hub-mention-filter-normalize
                   (alist-get 'mention-filter state))))
          ;; Bot filter: restore toggle (3-state cycle).
          ;; Migrates legacy boolean state via normalize helper:
          ;; `t' → `show'; anything unrecognised → `nil'.
          (when (boundp 'decknix--hub-show-bots)
            (setq decknix--hub-show-bots
                  (decknix--hub-show-bots-normalize
                   (alist-get 'show-bots state))))
          ;; Requests sort direction: restore toggle
          (when (boundp 'decknix--hub-requests-sort-reverse)
            (setq decknix--hub-requests-sort-reverse
                  (alist-get 'requests-sort-reverse state)))
          ;; PR expand: restore toggle (normalise legacy boolean t → pr)
          (when (boundp 'decknix--hub-expand-prs)
            (let ((val (alist-get 'expand-prs state)))
              (setq decknix--hub-expand-prs
                    (if (eq val t) 'pr val))))
          ;; Deploy indicator: restore toggle
          (let ((sd (alist-get 'show-deploys state 'missing)))
            (unless (eq sd 'missing)
              (when (boundp 'decknix--hub-show-deploys)
                (setq decknix--hub-show-deploys sd))))
          ;; Saved-sessions visibility: restore toggle.  Use
          ;; the missing sentinel so absence of the key in
          ;; older state files leaves the default (`t') intact
          ;; rather than silently flipping to nil.
          (let ((sv (alist-get 'show-saved-sessions state 'missing)))
            (unless (eq sv 'missing)
              (when (boundp 'decknix--hub-show-saved-sessions)
                (setq decknix--hub-show-saved-sessions sv))))
          ;; Tile count preference: restore as integer 0/2/3/4.
          ;; Auto-apply runs from the sidebar refresh path so
          ;; resuming Previous sessions naturally engages the
          ;; preferred layout once enough buffers exist.
          (let ((tc (alist-get 'tile-count state)))
            (when (and (integerp tc)
                       (boundp 'decknix--sidebar-tile-count))
              (setq decknix--sidebar-tile-count tc)))
          ;; Worktree toggles (§3.6.12): use `missing' sentinel so
          ;; absent keys in older state files leave the defaults intact.
          (let ((wlo (alist-get 'wt-live-only state 'missing)))
            (unless (eq wlo 'missing)
              (when (boundp 'decknix--sidebar-wt-live-only)
                (setq decknix--sidebar-wt-live-only wlo))))
          (let ((wgr (alist-get 'wt-group-by-repo state 'missing)))
            (unless (eq wgr 'missing)
              (when (boundp 'decknix--sidebar-wt-group-by-repo)
                (setq decknix--sidebar-wt-group-by-repo wgr))))
          (let ((waf (alist-get 'wt-age-filter state 'missing)))
            (unless (eq waf 'missing)
              (when (boundp 'decknix--sidebar-wt-age-filter)
                (setq decknix--sidebar-wt-age-filter waf))))
          (let ((whc (alist-get 'wt-hide-clean state 'missing)))
            (unless (eq whc 'missing)
              (when (boundp 'decknix--sidebar-wt-hide-clean)
                (setq decknix--sidebar-wt-hide-clean whc))))
          (let ((whp (alist-get 'wt-hide-placeholders state 'missing)))
            (unless (eq whp 'missing)
              (when (boundp 'decknix--sidebar-wt-hide-placeholders)
                (setq decknix--sidebar-wt-hide-placeholders whp))))
          (let ((whm (alist-get 'wt-hide-merged state 'missing)))
            (unless (eq whm 'missing)
              (when (boundp 'decknix--sidebar-wt-hide-merged)
                (setq decknix--sidebar-wt-hide-merged whm)))))
      (error
       (message "sidebar-state: restore failed: %s" (error-message-string err))))))

;; -- Previous sessions: snapshot-and-truncate handoff --
;;
;; This is the new startup contract that replaces the legacy
;; `previous-sessions' branch above (removed in PR live-sessions):
;; read the eagerly-maintained `decknix--live-sessions-file', freeze
;; its contents in `decknix--sidebar-previous-sessions' for the rest
;; of this Emacs run, then truncate the file so the lifecycle hooks
;; in this run rebuild the live set from zero.  See
;; `agent-shell/live-sessions/decknix-agent-live-sessions.el' for
;; the full design rationale (eager add / forget hooks, shutdown
;; suppression flag, atomic writes).
;;
;; Migration: when the live file is missing/empty (typical on the
;; first boot after deploy) but the legacy `sidebar-state.el' still
;; carries a `previous-sessions' field, lift it across once so the
;; user's Previous list isn't lost during the cutover.
(defun decknix--sidebar-snapshot-previous-from-live ()
  "Freeze the prior run's live set as this run's Previous Sessions list.
Reads the eagerly-maintained live-sessions file, snapshots it into
`decknix--sidebar-previous-sessions' (deduped + filtered through the
persisted dismissed-keys set), then truncates the live file so this
run's lifecycle hooks rebuild it from zero.

When the live file is missing (first start after deploy), falls back
to lifting the legacy `previous-sessions' field out of
`decknix--sidebar-state-file' so users do not lose their list during
the cutover."
  (let* ((live (decknix--live-sessions-snapshot-and-truncate))
         (snapshot
          (or live
              ;; One-time legacy migration: pull the field out of
              ;; sidebar-state.el if it was written by a pre-cutover
              ;; build.  No-op once the new saver stops emitting it.
              (and (file-exists-p decknix--sidebar-state-file)
                   (condition-case nil
                       (let ((state (with-temp-buffer
                                      (insert-file-contents
                                       decknix--sidebar-state-file)
                                      (read (current-buffer)))))
                         (alist-get 'previous-sessions state))
                     (error nil)))))
         (dismissed (decknix--live-sessions-dismissed-read)))
    (setq decknix--sidebar-previous-sessions
          (decknix--live-sessions-filter-dismissed
           (decknix--sidebar-previous-dedupe (or snapshot '()))
           dismissed))))

;; -- Lifecycle hook entry points (called from agent-shell.nix) --

(defun decknix--sidebar-record-buffer-as-live (&optional buf)
  "Record BUF (default: current buffer) into the live-sessions file.
Best-effort: writes whatever conv-key / sid / workspace are currently
known.  The writer is idempotent on conv-key (or sid as fallback) so
the agent-shell-mode-hook safely calls this twice — once at mode
entry, once after a delay — without producing duplicate rows."
  (let ((b (or buf (current-buffer))))
    (when (and b (buffer-live-p b))
      (with-current-buffer b
        (when (derived-mode-p 'agent-shell-mode)
          (let* ((sid (decknix--agent-buffer-session-id))
                 (conv-key
                  (or (and (bound-and-true-p decknix--agent-conv-key)
                           decknix--agent-conv-key)
                      (and sid
                           (ignore-errors
                             (decknix--agent-conversation-key-for-session sid)))))
                 (tags (when conv-key
                         (decknix--agent-tags-for-conv-key conv-key)))
                 (ws (or (when conv-key
                           (decknix--agent-workspace-for-conv-key conv-key))
                         (expand-file-name default-directory))))
            ;; Need at least one identifier to be addressable on disk.
            (when (or sid conv-key)
              (decknix--live-sessions-record
               (list (cons 'session-id sid)
                     (cons 'name (buffer-name b))
                     (cons 'workspace ws)
                     (cons 'conv-key conv-key)
                     (cons 'tags tags))))))))))

(defun decknix--sidebar-forget-buffer-as-live ()
  "Remove the current buffer's row from the live-sessions file.
Wired into `kill-buffer-hook' as a buffer-local hook.  No-ops during
shutdown via `decknix--live-sessions-suppress-write' so the buffer-
kill cascade triggered by `kill-emacs' does not erase the file the
next start needs to read as Previous Sessions."
  (when (derived-mode-p 'agent-shell-mode)
    (let* ((sid (decknix--agent-buffer-session-id))
           (conv-key
            (or (and (bound-and-true-p decknix--agent-conv-key)
                     decknix--agent-conv-key)
                (and sid
                     (ignore-errors
                       (decknix--agent-conversation-key-for-session sid))))))
      (when (or sid conv-key)
        (decknix--live-sessions-forget conv-key sid)))))

;; -- Previous sessions: sidebar rendering --
(defun decknix--sidebar-render-previous-sessions (line-num)
  "Render greyed-out previous live sessions after the Live section.
Returns updated LINE-NUM."
  (let* ((live-bufs (seq-filter #'buffer-live-p (agent-shell-buffers)))
         (live-sids (mapcar #'decknix--agent-buffer-session-id
                             live-bufs))
         (live-conv-keys
          (delq nil
                (mapcar (lambda (b)
                          (with-current-buffer b
                            (and (bound-and-true-p decknix--agent-conv-key)
                                 decknix--agent-conv-key)))
                        live-bufs)))
         ;; Filter out sessions that are already live (match by sid
         ;; OR conv-key — a live buffer may hold a newer snapshot
         ;; than the saved stored-sid), then collapse duplicates
         ;; sharing a conv-key down to one row.
         (prev (decknix--sidebar-previous-dedupe
                (seq-filter
                 (lambda (entry)
                   (let ((sid (alist-get 'session-id entry))
                         (ck (alist-get 'conv-key entry)))
                     (and (not (member sid live-sids))
                          (not (and ck (member ck live-conv-keys))))))
                 decknix--sidebar-previous-sessions))))
    (when prev
      (insert "\n")
      (setq line-num (1+ line-num))
      (decknix--sidebar-render-section-header
       (format "Previous (%d)" (length prev))
       'previous)
      (setq line-num (1+ line-num))
      (dolist (entry prev)
        (let* ((name (or (alist-get 'name entry) "unknown"))
               ;; Strip *Auggie: ... * wrapper if present
               (short (if (string-match "\\*Auggie: \\(.*\\)\\*" name)
                          (match-string 1 name)
                        name))
               (prev-conv-key (alist-get 'conv-key entry))
               (pr-badge (if prev-conv-key
                             (decknix--hub-pr-badge prev-conv-key)
                           ""))
               (attention-icons
                (if prev-conv-key
                    (decknix--hub-session-attention-icons prev-conv-key)
                  ""))
               (progress-badge
                (if (and decknix--sidebar-show-progress
                         prev-conv-key
                         (fboundp 'decknix-progress--sidebar-badge))
                    (decknix-progress--sidebar-badge prev-conv-key)
                  ""))
               (line (concat "  "
                             (propertize "○" 'face 'font-lock-comment-face)
                             " "
                             (propertize short 'face 'font-lock-comment-face)
                             pr-badge attention-icons progress-badge)))
          (setq line (propertize line
                                'decknix-previous-session entry))
          (insert line "\n")
          (setq line-num (1+ line-num))
          ;; Expanded PR lines when toggle is on — grouped by repo
          (when (and decknix--hub-expand-prs prev-conv-key)
            (setq line-num
                  (+ line-num
                     (decknix--hub-render-session-prs
                      prev-conv-key decknix--hub-expand-prs
                      'font-lock-comment-face))))))))
  line-num)

;; -- Previous sessions: restore action --
(defun decknix--sidebar-restore-previous-session (entry &optional focus)
  "Resume the previous session described by ENTRY.
When FOCUS is non-nil (or called interactively), switch to the restored
session buffer in the main window after a short delay.

The stored `session-id' in ENTRY is a snapshot of the conversation at
save time; auggie writes a new session file on every interrupt/compose
so by the time the user restores, a newer snapshot for the same
conv-key usually exists.  Resuming the stored session-id would drop
anything added after save, so we first resolve conv-key → latest
session-id and pass that to `--resume'.  The stored sid is used only
as a fallback when no newer snapshot is found (e.g. conv-key missing
or the session list is stale)."
  (let* ((stored-sid (alist-get 'session-id entry))
         (name (alist-get 'name entry))
         (workspace (alist-get 'workspace entry))
         (conv-key (alist-get 'conv-key entry))
         (sid (or (decknix--agent-latest-session-id-for-conv-key conv-key)
                  stored-sid))
         ;; Strip *Auggie: ... * wrapper
         (display-name (if (and name (string-match "\\*Auggie: \\(.*\\)\\*" name))
                           (match-string 1 name)
                         name)))
    (if (not sid)
        (message "Cannot restore: no session ID")
      ;; Select main window so resume captures it as the target
      (let ((main (window-main-window (selected-frame))))
        (when (and main (window-live-p main))
          (select-window main)))
      ;; resume now handles display-action override internally
      (let ((new-buf (decknix--agent-session-resume
                      sid 20 display-name workspace conv-key)))
        ;; Remove from previous list since it's now live.  When
        ;; the entry has a conv-key, clear ALL entries sharing
        ;; that key — auggie writes multiple on-disk snapshots
        ;; per conversation, so the saved state file may carry
        ;; two rows (different sids, same conv-key) that both
        ;; resolve to the same live buffer.  Sid matching is
        ;; kept as a fallback for conv-key-less entries.
        (setq decknix--sidebar-previous-sessions
              (seq-filter (lambda (e)
                            (let ((esid (alist-get 'session-id e))
                                  (eck (alist-get 'conv-key e)))
                              (not (or (and conv-key eck
                                            (equal eck conv-key))
                                       (equal esid stored-sid)
                                       (equal esid sid)))))
                          decknix--sidebar-previous-sessions))
        (when (fboundp 'agent-shell-workspace-sidebar-refresh)
          (agent-shell-workspace-sidebar-refresh))
        ;; Ensure focus moves to the restored buffer after async
        ;; setup (rename, prepopulate) completes.
        (when (and focus new-buf)
          (run-at-time 2.0 nil
            (eval `(lambda ()
                     (let ((buf ,new-buf))
                       (when (and buf (buffer-live-p buf))
                         (let ((main (window-main-window (selected-frame))))
                           (when (and main (window-live-p main))
                             (set-window-buffer main buf)
                             (select-window main)
                             (with-current-buffer buf
                               (goto-char (point-max)))
                             (set-window-point main (point-max))))))) t)))))))

(defun decknix--sidebar-restore-all-previous ()
  "Restore all previous live sessions.
Focuses the first restored session in the main window."
  (interactive)
  (let ((entries (copy-sequence decknix--sidebar-previous-sessions)))
    (if (null entries)
        (message "No previous sessions to restore")
      ;; Restore first one with focus, rest without
      (decknix--sidebar-restore-previous-session (car entries) t)
      (dolist (entry (cdr entries))
        (decknix--sidebar-restore-previous-session entry))
      (message "Restored %d sessions" (length entries)))))

;; -- Previous session actions --
(defun decknix--nav-previous-item-actions (entry)
  "Show an action menu for a previous session ENTRY."
  (let ((name (or (alist-get 'name entry) "unknown")))
    (run-at-time 0.05 nil
      (eval `(lambda ()
               (let ((choice (read-char-choice
                              ,(format "%s: [r]estore [d]ismiss [q]uit"
                                       (if (string-match "\\*Auggie: \\(.*\\)\\*" name)
                                           (match-string 1 name)
                                         name))
                              '(?r ?d ?q))))
                 (pcase choice
                   (?r (decknix--sidebar-restore-previous-session ',entry t))
                   (?d
                    ;; Persist the dismissal so it survives restarts:
                    ;; previously this was a setq on the in-memory
                    ;; list, which the next idle save would reset
                    ;; against the live set anyway — and now that
                    ;; previous-sessions has its own snapshot file,
                    ;; the dismissal needs its own file too.
                    (let ((key
                           (decknix--live-sessions-entry-key ',entry)))
                      (when key
                        (decknix--live-sessions-dismiss key)))
                    (setq decknix--sidebar-previous-sessions
                          (seq-filter
                           (lambda (e)
                             (not (equal (alist-get 'session-id e)
                                         ',(alist-get 'session-id entry))))
                           decknix--sidebar-previous-sessions))
                    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
                      (agent-shell-workspace-sidebar-refresh))
                    (message "Dismissed"))
                   (?q (message "Cancelled"))))) t))))

(provide 'decknix-agent-shell-workspace)
;;; decknix-agent-shell-workspace.el ends here
