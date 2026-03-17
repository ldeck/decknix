{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.agentShell;

  # == Tiered package sourcing ==
  # Priority: stable nixpkgs > unstable nixpkgs > custom derivations
  #
  # From unstable (not yet in stable, or stable version too old):
  #   shell-maker, acp, agent-shell
  # Custom derivations (not in any nixpkgs channel):
  #   agent-shell-manager, agent-shell-workspace, agent-shell-attention

  inherit (pkgs.unstable.emacsPackages) shell-maker acp agent-shell;

  agent-shell-manager-el = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell-manager";
    version = "0-unstable-2026-03-17";
    src = pkgs.fetchFromGitHub {
      owner = "jethrokuan";
      repo = "agent-shell-manager";
      rev = "53b73f13ed1ac9d2de128465a8504a7265490ea7";
      hash = "sha256-JPB/OnOhYbM0LMirSYQhpB6hW8SAg0Ri6buU8tMP7rA=";
    };
    packageRequires = [ agent-shell ];
  };

  agent-shell-workspace-el = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell-workspace";
    version = "0-unstable-2026-03-17";
    src = pkgs.fetchFromGitHub {
      owner = "gveres";
      repo = "agent-shell-workspace";
      rev = "5d791c658b0692867c03a598ff4457599b5e20a5";
      hash = "sha256-durGK2f+Ovv5scbz4hv1k8nHeylgLNfHAR5tvQAifKI=";
    };
    packageRequires = [ agent-shell ];
  };

  agent-shell-attention-el = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell-attention";
    version = "0-unstable-2026-03-17";
    src = pkgs.fetchFromGitHub {
      owner = "ultronozm";
      repo = "agent-shell-attention.el";
      rev = "db89dc71e6e2ca5f0a6859ea9e9b183391614cea";
      hash = "sha256-bc5DjvGJnFBlsLtyYlN1hJQrcvK9khGaywtT37ACn+s=";
    };
    packageRequires = [ agent-shell ];
  };

  # == Yasnippet prompt templates for agent-shell-mode ==
  # Deployed to ~/.emacs.d/snippets/agent-shell-mode/ via home.file
  # Note: ''${ escapes Nix interpolation to produce literal ${ for yasnippet fields
  snippetDir = ".emacs.d/snippets/agent-shell-mode";

  mkSnippet = name: key: body: ''
    # -*- mode: snippet -*-
    # name: ${name}
    # key: ${key}
    # --
    ${body}
  '';

  snippets = {
    review = mkSnippet "review" "/review" ''
      Review `''${1:`(buffer-file-name (agent-shell--source-buffer))`}` for ''${2:$$$(yas-choose-value '("bugs" "performance" "readability" "security"))}.

      Focus on:
      - ''${3:specific concerns}

      ''${4:Additional context.}'';

    refactor = mkSnippet "refactor" "/refactor" ''
      Refactor ''${1:description} in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      Follow the ''${3:$$$(yas-choose-value '("extract method" "rename" "move" "inline" "simplify" "DRY up"))} pattern.

      Requirements:
      - ''${4:requirements}'';

    test = mkSnippet "test" "/test" ''
      Write tests for ''${1:function/module} in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      Cover:
      - ''${3:happy path}
      - ''${4:edge cases}
      - ''${5:error cases}

      Use the ''${6:existing test framework} already in the project.'';

    explain = mkSnippet "explain" "/explain" ''
      Explain how ''${1:code/concept} works in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      I want to understand:
      - ''${3:specific aspects}'';

    fix = mkSnippet "fix" "/fix" ''
      Fix the ''${1:error/issue} in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      Stack trace / error:
      ```
      ''${3:paste error here}
      ```

      ''${4:Additional context.}'';

    implement = mkSnippet "implement" "/implement" ''
      Implement ''${1:feature description}.

      Follow the pattern in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      Requirements:
      - ''${3:requirements}

      ''${4:Additional context.}'';

    debug = mkSnippet "debug" "/debug" ''
      Debug why ''${1:symptom} is happening in `''${2:`(buffer-file-name (agent-shell--source-buffer))`}`.

      Relevant logs:
      ```
      ''${3:paste logs here}
      ```

      What I've tried:
      - ''${4:steps taken}'';
  };

in
{
  options.programs.emacs.decknix.agentShell = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell.el ecosystem for auggie AI integration.";
    };

    manager.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell-manager (tabulated session dashboard).";
    };

    workspace.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell-workspace (dedicated tab-bar workspace).";
    };

    attention.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable agent-shell-attention (mode-line attention tracker).";
    };

    templates.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable yasnippet prompt templates for agent-shell (review, refactor, test, etc.).";
    };
  };

  config = mkIf cfg.enable {
    # Deploy yasnippet snippet files to ~/.emacs.d/snippets/agent-shell-mode/
    home.file = mkIf cfg.templates.enable
      (mapAttrs'
        (name: text: nameValuePair "${snippetDir}/${name}" { inherit text; })
        snippets);
    programs.emacs = {
      extraPackages = _epkgs:
        # Core (from unstable): agent-shell + acp + shell-maker + markdown-mode
        [ agent-shell acp shell-maker ]
        ++ (with pkgs.emacsPackages; [ markdown-mode ])
        # Add-ons
        ++ (optional cfg.manager.enable agent-shell-manager-el)
        ++ (optional cfg.workspace.enable agent-shell-workspace-el)
        ++ (optional cfg.attention.enable agent-shell-attention-el);

      extraConfig = ''
        ;;; Agent Shell Configuration (auggie AI integration)

        ;; Suppress native-comp warnings from popping up as buffers;
        ;; they are harmless and still logged to *Warnings*
        (setq native-comp-async-report-warnings-errors 'silent)

        ;; == Core: agent-shell with auggie defaults ==
        (require 'agent-shell)
        (require 'agent-shell-auggie)

        ;; Use auggie as the default agent (skip agent selection prompt)
        (setq agent-shell-preferred-agent-config 'auggie)

        ;; Session strategy: always start new (no built-in session prompt).
        ;; All session management (new/resume/switch) goes through our
        ;; custom picker at C-c A s instead.
        (setq agent-shell-session-strategy 'new)

        ;; Show model and mode in the mode-line (bottom bar) instead of
        ;; the graphical header, so it's always visible
        (setq agent-shell-header-style 'text)

        ;; Show session ID in header and session selection prompt
        (setq agent-shell-show-session-id t)

        ;; == Tutorial: welcome message + help buffer ==

        (defun decknix--agent-welcome-keybindings ()
          "Return a formatted string of key keybinding hints for the welcome message."
          (let ((bindings
                 '(("C-c e"   "Compose"    "Open multi-line prompt editor")
                   ("C-c s"   "Sessions"   "Pick / resume / start session")
                   ("C-c q"   "Quit"       "Save and quit session")
                   ("C-c h"   "History"    "View conversation history")
                   ("C-c t t" "Template"   "Insert a prompt template")
                   ("C-c T t" "Tag"        "Tag this session")
                   ("C-c T l" "By tag"     "Filter sessions by tag")
                   ("C-c ?"   "Help"       "Full keybinding reference"))))
            (mapconcat
             (lambda (b)
               (format "  %-8s  %-10s  %s"
                       (propertize (nth 0 b) 'font-lock-face 'font-lock-keyword-face)
                       (propertize (nth 1 b) 'font-lock-face 'font-lock-function-name-face)
                       (nth 2 b)))
             bindings "\n")))

        (defun decknix--agent-welcome-message (config)
          "Custom welcome message with keybinding hints.
        Wraps the default auggie welcome with a quick-reference card."
          (let ((original (agent-shell-auggie--welcome-message config))
                (divider (propertize (make-string 52 ?─)
                                    'font-lock-face 'font-lock-comment-face))
                (title (propertize " Quick Reference"
                                   'font-lock-face 'font-lock-comment-face)))
            (concat original "\n"
                    divider "\n"
                    title "\n\n"
                    (decknix--agent-welcome-keybindings) "\n\n"
                    divider "\n")))

        ;; Override the auggie welcome function with our enhanced version
        (advice-add 'agent-shell-auggie--welcome-message
                    :override #'decknix--agent-welcome-message)

        (defun decknix-agent-help ()
          "Show a help buffer with all agent-shell keybindings.
        Grouped by category. Press q to dismiss."
          (interactive)
          (let ((buf (get-buffer-create "*Agent Help*")))
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert
                 (propertize "Agent Shell — Keybinding Reference\n"
                             'font-lock-face '(:weight bold :height 1.2))
                 (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face)
                 "\n\n"

                 (propertize "Session Management\n" 'font-lock-face '(:weight bold))
                 (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
                 "  C-c s       Session picker (live + saved)\n"
                 "  C-c q       Quit session (saves automatically)\n"
                 "  C-c h       View history (current session)\n"
                 "  C-c H       View history (pick any session)\n"
                 "  C-c r       Rename buffer\n"
                 "  C-c A a     Start / switch to agent\n"
                 "  C-c A n     Force new session\n"
                 "  C-c A k     Interrupt agent\n"
                 "\n"

                 (propertize "Input & Editing\n" 'font-lock-face '(:weight bold))
                 (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
                 "  C-c e       Compose buffer (multi-line editor)\n"
                 "  RET         Send prompt (at end of input)\n"
                 "  S-RET       Insert newline in prompt\n"
                 "  C-c C-c     Interrupt running agent\n"
                 "  TAB         Expand yasnippet template\n"
                 "\n"

                 (propertize "Templates  (C-c t …)\n" 'font-lock-face '(:weight bold))
                 (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
                 "  C-c t t     Insert a prompt template\n"
                 "  C-c t n     Create new template\n"
                 "  C-c t e     Edit existing template\n"
                 "\n"

                 (propertize "Tags  (C-c T …)\n" 'font-lock-face '(:weight bold))
                 (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
                 "  C-c T t     Tag current session\n"
                 "  C-c T r     Remove tag\n"
                 "  C-c T l     List / filter by tag\n"
                 "  C-c T e     Rename a tag\n"
                 "  C-c T d     Delete tag globally\n"
                 "  C-c T c     Cleanup orphaned tags\n"
                 "\n"

                 (propertize "Model & Mode\n" 'font-lock-face '(:weight bold))
                 (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
                 "  C-c v       Pick model\n"
                 "  C-c M       Pick mode\n"
                 "  C-c C-v     Pick model (built-in)\n"
                 "  C-c C-m     Pick mode (built-in)\n"
                 "\n"

                 (propertize "Extensions\n" 'font-lock-face '(:weight bold))
                 (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
                 "  C-c m       Manager dashboard\n"
                 "  C-c w       Workspace tab toggle\n"
                 "  C-c j       Jump to session needing attention\n"
                 "\n"

                 (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face) "\n"
                 (propertize "Global prefix: C-c A <key>  (same commands from any buffer)\n"
                             'font-lock-face 'font-lock-comment-face)
                 (propertize "Press q to close this buffer.\n"
                             'font-lock-face 'font-lock-comment-face))
                (goto-char (point-min))
                (special-mode)))
            (display-buffer buf '(display-buffer-at-bottom
                                  (window-height . fit-window-to-buffer)))))

        ;; == Named prefix map: C-c A → "Agent" ==
        ;; Gives which-key / minibuffer a descriptive label instead of "+prefix"
        (define-prefix-command 'decknix-agent-prefix-map)
        (global-set-key (kbd "C-c A") 'decknix-agent-prefix-map)
        (with-eval-after-load 'which-key
          (which-key-add-key-based-replacements "C-c A" "Agent"))

        ;; Global keybindings under C-c A prefix
        (define-key decknix-agent-prefix-map (kbd "a") 'agent-shell)                      ; Start/switch to agent
        (define-key decknix-agent-prefix-map (kbd "n") 'agent-shell-new)                  ; Force new session
        (define-key decknix-agent-prefix-map (kbd "r") 'agent-shell-rename-buffer)        ; Rename session
        (define-key decknix-agent-prefix-map (kbd "k") 'agent-shell-interrupt)            ; Interrupt agent
        (define-key decknix-agent-prefix-map (kbd "v") 'agent-shell-set-session-model)    ; Pick model
        (define-key decknix-agent-prefix-map (kbd "M") 'agent-shell-set-session-mode)     ; Pick mode
        (define-key decknix-agent-prefix-map (kbd "?") 'decknix-agent-help)               ; Help reference

        ;; == Session management: unified picker + clean quit ==

        ;; Buffer-local var to track the auggie CLI session ID
        ;; (distinct from ACP session ID in agent-shell--state)
        (defvar-local decknix--agent-auggie-session-id nil
          "The auggie CLI session ID for this buffer, if known.")

        (defun decknix--agent-session-time-ago (iso-time)
          "Format ISO-TIME as a relative time string (e.g. \"2h ago\")."
          (let* ((time (date-to-time iso-time))
                 (delta (float-time (time-subtract (current-time) time)))
                 (minutes (/ delta 60))
                 (hours (/ delta 3600))
                 (days (/ delta 86400)))
            (cond ((< minutes 1) "just now")
                  ((< minutes 60) (format "%dm ago" (truncate minutes)))
                  ((< hours 24) (format "%dh ago" (truncate hours)))
                  ((< days 30) (format "%dd ago" (truncate days)))
                  (t (format-time-string "%Y-%m-%d" time)))))

        (defun decknix--agent-session-list ()
          "Fetch saved auggie sessions as a list of alists."
          (condition-case err
              (let* ((json-array-type 'list)
                     (json-object-type 'alist)
                     (json-key-type 'symbol)
                     (raw (shell-command-to-string
                           "auggie session list --json -n 30 2>/dev/null"))
                     (trimmed (string-trim raw)))
                (if (and (not (string-empty-p trimmed))
                         (string-prefix-p "[" trimmed))
                    (json-read-from-string trimmed)
                  nil))
            (error
             (message "Failed to fetch auggie sessions: %s" (error-message-string err))
             nil)))

        (defun decknix--agent-session-preview (session)
          "Format a one-line preview for a saved SESSION, including tags."
          (let* ((id (alist-get 'sessionId session))
                 (modified (alist-get 'modified session))
                 (exchanges (alist-get 'exchangeCount session 0))
                 (first-msg (alist-get 'firstUserMessage session ""))
                 (preview (car (split-string first-msg "\n" t)))
                 (tags (decknix--agent-tags-for-session id))
                 (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
                 (truncated (truncate-string-to-width (or preview "") 50 nil nil "...")))
            (format "%-8s  %-8s  %3dx  %s%s"
                    (substring id 0 (min 8 (length id)))
                    (if modified (decknix--agent-session-time-ago modified) "?")
                    exchanges
                    truncated
                    tag-str)))

        (defun decknix-agent-session-picker ()
          "Pick from live agent-shell buffers and saved auggie sessions.
Live buffers are shown first, then saved sessions. Selecting a live
buffer switches to it; selecting a saved session resumes it in a
new agent-shell."
          (interactive)
          (let* ((live-buffers (when (fboundp 'agent-shell-buffers)
                                 (agent-shell-buffers)))
                 (live-entries (mapcar (lambda (buf)
                                        (cons (format "[live]  %s" (buffer-name buf))
                                              (cons 'buffer buf)))
                                      live-buffers))
                 (saved-sessions (decknix--agent-session-list))
                 (saved-entries (mapcar (lambda (session)
                                         (cons (format "[saved] %s"
                                                       (decknix--agent-session-preview session))
                                               (cons 'session session)))
                                       saved-sessions))
                 (new-entry (list (cons "[new]   Start a new auggie session"
                                        (cons 'new nil))))
                 (all-entries (append new-entry live-entries saved-entries))
                 (selection (completing-read "Agent session: "
                                            (mapcar #'car all-entries)
                                            nil t))
                 (chosen (cdr (assoc selection all-entries))))
            (pcase (car chosen)
              ('buffer (switch-to-buffer (cdr chosen)))
              ('session
               (let* ((session (cdr chosen))
                      (session-id (alist-get 'sessionId session))
                      ;; Pass --resume to auggie so it resumes the saved session
                      (agent-shell-auggie-acp-command
                       (append agent-shell-auggie-acp-command
                               (list "--resume" session-id))))
                 (agent-shell-start
                  :config (agent-shell-auggie-make-agent-config))
                 ;; Store the auggie session ID in the new buffer
                 ;; (agent-shell-start switches to the new buffer)
                 (setq-local decknix--agent-auggie-session-id session-id)))
              ('new (agent-shell-start
                     :config (agent-shell-auggie-make-agent-config))))))

        (defun decknix-agent-session-quit ()
          "Cleanly quit the current agent-shell session.
Kills the buffer (which sends SIGHUP to auggie, saving the session)
and switches back to the previous buffer."
          (interactive)
          (unless (derived-mode-p 'agent-shell-mode)
            (user-error "Not in an agent-shell buffer"))
          (when (y-or-n-p "Quit this agent session? ")
            (let ((buf (current-buffer)))
              (previous-buffer)
              (kill-buffer buf))))

        (defun decknix--agent-session-open-share (session-id)
          "Generate a share link for SESSION-ID and open it in Emacs.
Uses xwidget-webkit if available, otherwise falls back to eww."
          (message "Generating share link for %s..." (substring session-id 0 8))
          (let* ((output (shell-command-to-string
                          (format "auggie session share %s 2>&1"
                                  (shell-quote-argument session-id))))
                 (url (when (string-match "https://[^ \t\n]+" output)
                        (match-string 0 output))))
            (if url
                (progn
                  (message "Opening %s" url)
                  (if (fboundp 'xwidget-webkit-browse-url)
                      (xwidget-webkit-browse-url url t)
                    (eww url t)))
              (user-error "Failed to generate share link: %s"
                          (string-trim output)))))

        (defun decknix--agent-session-pick-for-history ()
          "Prompt to pick a saved session and return its full ID."
          (let* ((sessions (decknix--agent-session-list))
                 (entries (mapcar (lambda (session)
                                   (cons (decknix--agent-session-preview session)
                                         (alist-get 'sessionId session)))
                                 sessions))
                 (selection (completing-read "View history for session: "
                                            (mapcar #'car entries)
                                            nil t)))
            (or (cdr (assoc selection entries))
                (user-error "No session selected"))))

        (defun decknix-agent-session-history ()
          "View conversation history for the current or a picked session.
If in an agent-shell buffer with a known session ID, shows that
session's history directly. Otherwise, prompts to pick a session.
Opens in xwidget-webkit (q to quit) or eww as fallback."
          (interactive)
          (let ((session-id
                 (if (and (derived-mode-p 'agent-shell-mode)
                          decknix--agent-auggie-session-id)
                     decknix--agent-auggie-session-id
                   (decknix--agent-session-pick-for-history))))
            (decknix--agent-session-open-share session-id)))

        (defun decknix-agent-session-history-pick ()
          "Always prompt to pick a session to view history for.
Like `decknix-agent-session-history' but always shows the picker,
even when in an agent-shell buffer with a known session."
          (interactive)
          (decknix--agent-session-open-share
           (decknix--agent-session-pick-for-history)))

        (define-key decknix-agent-prefix-map (kbd "s") 'decknix-agent-session-picker)        ; Session picker
        (define-key decknix-agent-prefix-map (kbd "q") 'decknix-agent-session-quit)          ; Quit session
        (define-key decknix-agent-prefix-map (kbd "h") 'decknix-agent-session-history)       ; View history (DWIM)
        (define-key decknix-agent-prefix-map (kbd "H") 'decknix-agent-session-history-pick)  ; View history (pick)

        ;; == Session tagging: metadata layer for session organisation ==
        ;; Tags are stored in a JSON file, keyed by auggie session ID.
        ;; Format: {"session-id": {"tags": ["refactor", "decknix"]}, ...}

        (defvar decknix--agent-tags-file
          (expand-file-name "~/.config/decknix/agent-sessions.json")
          "Path to the JSON file storing session tag metadata.")

        (defun decknix--agent-tags-read ()
          "Read the tag store from disk. Returns a hash-table."
          (if (file-exists-p decknix--agent-tags-file)
              (condition-case err
                  (let* ((json-object-type 'hash-table)
                         (json-array-type 'list)
                         (json-key-type 'string))
                    (json-read-file decknix--agent-tags-file))
                (error
                 (message "Warning: could not read tag store: %s" (error-message-string err))
                 (make-hash-table :test 'equal)))
            (make-hash-table :test 'equal)))

        (defun decknix--agent-tags-write (store)
          "Write STORE (hash-table) to the tag file."
          (let ((dir (file-name-directory decknix--agent-tags-file)))
            (unless (file-directory-p dir)
              (make-directory dir t))
            (with-temp-file decknix--agent-tags-file
              (let ((json-encoding-pretty-print t))
                (insert (json-encode store))))))

        (defun decknix--agent-tags-for-session (session-id)
          "Return the list of tags for SESSION-ID."
          (let* ((store (decknix--agent-tags-read))
                 (entry (gethash session-id store)))
            (if (hash-table-p entry)
                (gethash "tags" entry)
              nil)))

        (defun decknix--agent-tags-all ()
          "Return a sorted list of all unique tags across all sessions."
          (let ((store (decknix--agent-tags-read))
                (all-tags nil))
            (maphash (lambda (_id entry)
                       (when (hash-table-p entry)
                         (dolist (tag (gethash "tags" entry))
                           (cl-pushnew tag all-tags :test #'string=))))
                     store)
            (sort all-tags #'string<)))

        (defun decknix--agent-current-session-id ()
          "Get the auggie session ID for the current buffer, or nil."
          (when (derived-mode-p 'agent-shell-mode)
            decknix--agent-auggie-session-id))

        (defun decknix--agent-require-session-id ()
          "Get the current session ID or error."
          (or (decknix--agent-current-session-id)
              (user-error "No auggie session ID for this buffer (is it a resumed session?)")))

        (defun decknix-agent-tag-add ()
          "Add a tag to the current session.
        Prompts with existing tags for completion, or type a new one."
          (interactive)
          (let* ((session-id (decknix--agent-require-session-id))
                 (existing (decknix--agent-tags-all))
                 (current (decknix--agent-tags-for-session session-id))
                 (tag (completing-read
                       (format "Add tag to %s: " (substring session-id 0 8))
                       existing nil nil))
                 (tag (string-trim tag)))
            (when (string-empty-p tag)
              (user-error "Tag cannot be empty"))
            (if (member tag current)
                (message "Session already has tag \"%s\"" tag)
              (let* ((store (decknix--agent-tags-read))
                     (entry (or (gethash session-id store)
                                (let ((h (make-hash-table :test 'equal)))
                                  (puthash "tags" nil h) h)))
                     (tags (gethash "tags" entry)))
                (puthash "tags" (append tags (list tag)) entry)
                (puthash session-id entry store)
                (decknix--agent-tags-write store)
                (message "Tagged %s with \"%s\" → [%s]"
                         (substring session-id 0 8) tag
                         (string-join (gethash "tags" entry) ", "))))))

        (defun decknix-agent-tag-remove ()
          "Remove a tag from the current session."
          (interactive)
          (let* ((session-id (decknix--agent-require-session-id))
                 (current (decknix--agent-tags-for-session session-id)))
            (unless current
              (user-error "Session %s has no tags" (substring session-id 0 8)))
            (let* ((tag (completing-read
                         (format "Remove tag from %s: " (substring session-id 0 8))
                         current nil t))
                   (store (decknix--agent-tags-read))
                   (entry (gethash session-id store))
                   (remaining (remove tag (gethash "tags" entry))))
              (if remaining
                  (puthash "tags" remaining entry)
                (remhash session-id store))
              (decknix--agent-tags-write store)
              (message "Removed \"%s\" from %s" tag (substring session-id 0 8)))))

        (defun decknix-agent-tag-list ()
          "List sessions filtered by tag.
        Prompts for a tag, then shows matching sessions in the picker."
          (interactive)
          (let* ((all-tags (decknix--agent-tags-all)))
            (unless all-tags
              (user-error "No tags defined yet"))
            (let* ((tag (completing-read "Filter by tag: " all-tags nil t))
                   (store (decknix--agent-tags-read))
                   (sessions (decknix--agent-session-list))
                   (matching-ids nil))
              ;; Collect session IDs that have this tag
              (maphash (lambda (id entry)
                         (when (and (hash-table-p entry)
                                    (member tag (gethash "tags" entry)))
                           (push id matching-ids)))
                       store)
              (unless matching-ids
                (user-error "No sessions tagged \"%s\"" tag))
              ;; Filter saved sessions to only matching ones
              (let* ((filtered (seq-filter
                                (lambda (s) (member (alist-get 'sessionId s) matching-ids))
                                sessions))
                     (entries (mapcar (lambda (session)
                                       (let* ((id (alist-get 'sessionId session))
                                              (tags (decknix--agent-tags-for-session id))
                                              (tag-str (if tags (format " [%s]" (string-join tags ", ")) "")))
                                         (cons (format "%s%s"
                                                       (decknix--agent-session-preview session)
                                                       tag-str)
                                               (cons 'session session))))
                                     filtered)))
                (unless entries
                  (user-error "No active sessions match tag \"%s\" (sessions may have expired)" tag))
                (let* ((selection (completing-read
                                   (format "Sessions tagged \"%s\": " tag)
                                   (mapcar #'car entries) nil t))
                       (chosen (cdr (assoc selection entries)))
                       (session (cdr chosen))
                       (session-id (alist-get 'sessionId session))
                       (agent-shell-auggie-acp-command
                        (append agent-shell-auggie-acp-command
                                (list "--resume" session-id))))
                  (agent-shell-start
                   :config (agent-shell-auggie-make-agent-config))
                  (setq-local decknix--agent-auggie-session-id session-id))))))

        (defun decknix-agent-tag-edit ()
          "Rename a tag across all sessions."
          (interactive)
          (let* ((all-tags (decknix--agent-tags-all)))
            (unless all-tags
              (user-error "No tags defined yet"))
            (let* ((old-tag (completing-read "Rename tag: " all-tags nil t))
                   (new-tag (string-trim
                             (read-string (format "Rename \"%s\" to: " old-tag) old-tag)))
                   (store (decknix--agent-tags-read))
                   (count 0))
              (when (string-empty-p new-tag)
                (user-error "Tag cannot be empty"))
              (when (string= old-tag new-tag)
                (user-error "Same name, nothing to do"))
              (maphash (lambda (id entry)
                         (when (hash-table-p entry)
                           (let ((tags (gethash "tags" entry)))
                             (when (member old-tag tags)
                               (puthash "tags"
                                        (mapcar (lambda (tg) (if (string= tg old-tag) new-tag tg)) tags)
                                        entry)
                               (cl-incf count)))))
                       store)
              (decknix--agent-tags-write store)
              (message "Renamed \"%s\" → \"%s\" across %d session%s"
                       old-tag new-tag count (if (= count 1) "" "s")))))

        (defun decknix-agent-tag-delete ()
          "Delete a tag from all sessions."
          (interactive)
          (let* ((all-tags (decknix--agent-tags-all)))
            (unless all-tags
              (user-error "No tags defined yet"))
            (let* ((tag (completing-read "Delete tag globally: " all-tags nil t)))
              (when (y-or-n-p (format "Delete tag \"%s\" from all sessions? " tag))
                (let ((store (decknix--agent-tags-read))
                      (count 0)
                      (empties nil))
                  (maphash (lambda (id entry)
                             (when (hash-table-p entry)
                               (let ((tags (gethash "tags" entry)))
                                 (when (member tag tags)
                                   (let ((remaining (remove tag tags)))
                                     (if remaining
                                         (puthash "tags" remaining entry)
                                       (push id empties)))
                                   (cl-incf count)))))
                           store)
                  ;; Remove entries with no tags left
                  (dolist (id empties) (remhash id store))
                  (decknix--agent-tags-write store)
                  (message "Deleted \"%s\" from %d session%s"
                           tag count (if (= count 1) "" "s")))))))

        (defun decknix-agent-tag-cleanup ()
          "Remove tags for sessions that no longer exist in auggie."
          (interactive)
          (let* ((store (decknix--agent-tags-read))
                 (sessions (decknix--agent-session-list))
                 (live-ids (mapcar (lambda (s) (alist-get 'sessionId s)) sessions))
                 (orphans nil))
            (maphash (lambda (id _entry)
                       (unless (member id live-ids)
                         (push id orphans)))
                     store)
            (if orphans
                (when (y-or-n-p (format "Remove tags for %d orphaned session%s? "
                                        (length orphans) (if (= (length orphans) 1) "" "s")))
                  (dolist (id orphans) (remhash id store))
                  (decknix--agent-tags-write store)
                  (message "Cleaned up %d orphaned session%s"
                           (length orphans) (if (= (length orphans) 1) "" "s")))
              (message "No orphaned sessions found"))))

        ;; C-c A T — tags sub-prefix ("Tags")
        (define-prefix-command 'decknix-agent-tags-map)
        (define-key decknix-agent-prefix-map (kbd "T") 'decknix-agent-tags-map)
        (with-eval-after-load 'which-key
          (which-key-add-key-based-replacements "C-c A T" "Tags"))
        (define-key decknix-agent-tags-map (kbd "t") 'decknix-agent-tag-add)       ; Tag (add)
        (define-key decknix-agent-tags-map (kbd "r") 'decknix-agent-tag-remove)    ; Remove
        (define-key decknix-agent-tags-map (kbd "l") 'decknix-agent-tag-list)      ; List/filter
        (define-key decknix-agent-tags-map (kbd "e") 'decknix-agent-tag-edit)      ; Edit/rename
        (define-key decknix-agent-tags-map (kbd "d") 'decknix-agent-tag-delete)    ; Delete globally
        (define-key decknix-agent-tags-map (kbd "c") 'decknix-agent-tag-cleanup)   ; Cleanup orphans

        ;; == Compose buffer: magit-style prompt editing ==
        ;; Opens a temporary buffer for composing multi-line prompts.
        ;; C-c C-c submits, C-c C-k cancels. Like magit commit messages.

        (defvar-local decknix--compose-target-buffer nil
          "The agent-shell buffer to submit the composed prompt to.")

        (defvar decknix-agent-compose-mode-map
          (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'decknix-agent-compose-submit)
            (define-key map (kbd "C-c C-k") #'decknix-agent-compose-cancel)
            map)
          "Keymap for `decknix-agent-compose-mode'.")

        (define-minor-mode decknix-agent-compose-mode
          "Minor mode for composing agent-shell prompts.
\\<decknix-agent-compose-mode-map>
\\[decknix-agent-compose-submit] to submit, \
\\[decknix-agent-compose-cancel] to cancel."
          :lighter " Compose"
          :keymap decknix-agent-compose-mode-map)

        (defun decknix-agent-compose-submit ()
          "Submit the compose buffer content to the agent-shell."
          (interactive)
          (let ((input (string-trim (buffer-string)))
                (target decknix--compose-target-buffer)
                (compose-buf (current-buffer))
                (compose-win (selected-window)))
            (if (string-empty-p input)
                (user-error "Empty prompt — nothing to submit")
              ;; Close the compose window/buffer first
              (quit-restore-window compose-win 'kill)
              ;; Submit to the agent-shell buffer
              (when (buffer-live-p target)
                (with-current-buffer target
                  (goto-char (point-max))
                  (shell-maker-submit :input input))))))

        (defun decknix-agent-compose-cancel ()
          "Cancel the compose buffer without submitting."
          (interactive)
          (let ((compose-win (selected-window)))
            (quit-restore-window compose-win 'kill)
            (message "Compose cancelled.")))

        (defun decknix-agent-compose ()
          "Open a compose buffer for writing a multi-line agent prompt.
The buffer opens at the bottom of the frame. Type your prompt
freely (RET for newlines), then:
  C-c C-c  submit to the agent
  C-c C-k  cancel"
          (interactive)
          ;; Find the target agent-shell buffer
          (let* ((target (cond
                          ;; Already in an agent-shell buffer
                          ((derived-mode-p 'agent-shell-mode)
                           (current-buffer))
                          ;; Find the most recent agent-shell buffer
                          ((and (fboundp 'agent-shell-buffers)
                                (agent-shell-buffers))
                           (car (agent-shell-buffers)))
                          (t (user-error
                              "No agent-shell buffer found. Start one with C-c A a"))))
                 (compose-buf (generate-new-buffer
                               (format "*Compose: %s*" (buffer-name target)))))
            ;; Display at the bottom, sized for comfortable editing
            (display-buffer compose-buf
                           '((display-buffer-at-bottom)
                             (window-height . 10)
                             (dedicated . t)))
            (select-window (get-buffer-window compose-buf))
            (with-current-buffer compose-buf
              (text-mode)
              (decknix-agent-compose-mode 1)
              (setq-local decknix--compose-target-buffer target)
              (setq-local header-line-format
                          (substitute-command-keys
                           " Compose prompt → \\<decknix-agent-compose-mode-map>\
\\[decknix-agent-compose-submit] submit, \
\\[decknix-agent-compose-cancel] cancel"))
              (set-buffer-modified-p nil))))

        (define-key decknix-agent-prefix-map (kbd "e") 'decknix-agent-compose)               ; Compose prompt
      ''
      + optionalString cfg.manager.enable ''

        ;; == Manager: tabulated session dashboard ==
        (require 'agent-shell-manager)
        (define-key decknix-agent-prefix-map (kbd "m") 'agent-shell-manager-toggle)
        ;; Show manager at the bottom of the frame
        (setq agent-shell-manager-side 'bottom)
      ''
      + optionalString cfg.workspace.enable ''

        ;; == Workspace: dedicated tab-bar tab with sidebar ==
        (require 'agent-shell-workspace)
        (define-key decknix-agent-prefix-map (kbd "w") 'agent-shell-workspace-toggle)
      ''
      + optionalString cfg.attention.enable ''

        ;; == Attention: mode-line indicator + jump-to-pending ==
        (require 'agent-shell-attention)
        (agent-shell-attention-mode 1)

        ;; Show both pending and busy counts: AS:n/m
        (setq agent-shell-attention-render-function
              #'agent-shell-attention-render-active)

        ;; Jump to session needing attention
        (define-key decknix-agent-prefix-map (kbd "j") 'agent-shell-attention-jump)
      ''
      + optionalString cfg.templates.enable ''

        ;; == Yasnippet prompt templates ==
        ;; Register agent-shell-mode snippet directory
        (with-eval-after-load 'yasnippet
          (let ((dir (expand-file-name "~/${snippetDir}")))
            (unless (member dir yas-snippet-dirs)
              (push dir yas-snippet-dirs))
            (yas-load-directory dir)))

        ;; C-c A t — template sub-prefix ("Templates")
        (define-prefix-command 'decknix-agent-template-map)
        (define-key decknix-agent-prefix-map (kbd "t") 'decknix-agent-template-map)
        (with-eval-after-load 'which-key
          (which-key-add-key-based-replacements "C-c A t" "Templates"))
        (define-key decknix-agent-template-map (kbd "t") 'yas-insert-snippet)       ; Insert
        (define-key decknix-agent-template-map (kbd "n") 'yas-new-snippet)          ; New
        (define-key decknix-agent-template-map (kbd "e") 'yas-visit-snippet-file)   ; Edit
      ''
      + ''

        ;; Disable line numbers in agent-shell buffers
        ;; Re-enable TAB for yasnippet expansion (no completion conflict here)
        ;; In-buffer shortcuts: C-c x (no A prefix needed inside agent-shell)
        (add-hook 'agent-shell-mode-hook
                  (lambda ()
                    (display-line-numbers-mode 0)
                    (local-set-key (kbd "TAB") 'yas-expand)
                    (local-set-key (kbd "<tab>") 'yas-expand)
                    ;; Simplified in-buffer bindings (mirrors C-c A x globals)
                    (local-set-key (kbd "C-c e") 'decknix-agent-compose)
                    (local-set-key (kbd "C-c s") 'decknix-agent-session-picker)
                    (local-set-key (kbd "C-c q") 'decknix-agent-session-quit)
                    (local-set-key (kbd "C-c h") 'decknix-agent-session-history)
                    (local-set-key (kbd "C-c H") 'decknix-agent-session-history-pick)
                    (local-set-key (kbd "C-c ?") 'decknix-agent-help)
                    (local-set-key (kbd "C-c r") 'agent-shell-rename-buffer)
                    (local-set-key (kbd "C-c v") 'agent-shell-set-session-model)
                    (local-set-key (kbd "C-c M") 'agent-shell-set-session-mode)
                    ;; Conditional bindings (may not be loaded)
                    (when (fboundp 'agent-shell-manager-toggle)
                      (local-set-key (kbd "C-c m") 'agent-shell-manager-toggle))
                    (when (fboundp 'agent-shell-workspace-toggle)
                      (local-set-key (kbd "C-c w") 'agent-shell-workspace-toggle))
                    (when (fboundp 'agent-shell-attention-jump)
                      (local-set-key (kbd "C-c j") 'agent-shell-attention-jump))
                    ;; C-c t — template sub-prefix in-buffer
                    (when (fboundp 'yas-insert-snippet)
                      (let ((map (make-sparse-keymap)))
                        (define-key map (kbd "t") 'yas-insert-snippet)
                        (define-key map (kbd "n") 'yas-new-snippet)
                        (define-key map (kbd "e") 'yas-visit-snippet-file)
                        (local-set-key (kbd "C-c t") map)))
                    ;; C-c T — tags sub-prefix in-buffer
                    (let ((map (make-sparse-keymap)))
                      (define-key map (kbd "t") 'decknix-agent-tag-add)
                      (define-key map (kbd "r") 'decknix-agent-tag-remove)
                      (define-key map (kbd "l") 'decknix-agent-tag-list)
                      (define-key map (kbd "e") 'decknix-agent-tag-edit)
                      (define-key map (kbd "d") 'decknix-agent-tag-delete)
                      (define-key map (kbd "c") 'decknix-agent-tag-cleanup)
                      (local-set-key (kbd "C-c T") map))))
      '';
    };
  };
}
