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

        ;; Keybindings under C-c A prefix (agent-shell-command-map)
        (global-set-key (kbd "C-c A a") 'agent-shell)                      ; Start/switch to agent
        (global-set-key (kbd "C-c A n") 'agent-shell-new)                  ; Force new session
        (global-set-key (kbd "C-c A r") 'agent-shell-rename-buffer)        ; Rename session
        (global-set-key (kbd "C-c A k") 'agent-shell-interrupt)            ; Interrupt agent
        (global-set-key (kbd "C-c A v") 'agent-shell-set-session-model)    ; Pick model (minibuffer)
        (global-set-key (kbd "C-c A M") 'agent-shell-set-session-mode)     ; Pick mode (minibuffer)
        (global-set-key (kbd "C-c A ?") 'agent-shell-help-menu)            ; Transient help menu

        ;; == Session management: unified picker + clean quit ==

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
          "Format a one-line preview for a saved SESSION."
          (let* ((id (alist-get 'sessionId session))
                 (modified (alist-get 'modified session))
                 (exchanges (alist-get 'exchangeCount session 0))
                 (first-msg (alist-get 'firstUserMessage session ""))
                 (preview (car (split-string first-msg "\n" t)))
                 (truncated (truncate-string-to-width (or preview "") 60 nil nil "...")))
            (format "%-8s  %-8s  %3dx  %s"
                    (substring id 0 (min 8 (length id)))
                    (if modified (decknix--agent-session-time-ago modified) "?")
                    exchanges
                    truncated)))

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
                  :config (agent-shell-auggie-make-agent-config))))
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

        (global-set-key (kbd "C-c A s") 'decknix-agent-session-picker)  ; Session picker
        (global-set-key (kbd "C-c A q") 'decknix-agent-session-quit)    ; Quit session
      ''
      + optionalString cfg.manager.enable ''

        ;; == Manager: tabulated session dashboard ==
        (require 'agent-shell-manager)
        (global-set-key (kbd "C-c A m") 'agent-shell-manager-toggle)
        ;; Show manager at the bottom of the frame
        (setq agent-shell-manager-side 'bottom)
      ''
      + optionalString cfg.workspace.enable ''

        ;; == Workspace: dedicated tab-bar tab with sidebar ==
        (require 'agent-shell-workspace)
        (global-set-key (kbd "C-c A w") 'agent-shell-workspace-toggle)
      ''
      + optionalString cfg.attention.enable ''

        ;; == Attention: mode-line indicator + jump-to-pending ==
        (require 'agent-shell-attention)
        (agent-shell-attention-mode 1)

        ;; Show both pending and busy counts: AS:n/m
        (setq agent-shell-attention-render-function
              #'agent-shell-attention-render-active)

        ;; Jump to session needing attention
        (global-set-key (kbd "C-c A j") 'agent-shell-attention-jump)
      ''
      + optionalString cfg.templates.enable ''

        ;; == Yasnippet prompt templates ==
        ;; Register agent-shell-mode snippet directory
        (with-eval-after-load 'yasnippet
          (let ((dir (expand-file-name "~/${snippetDir}")))
            (unless (member dir yas-snippet-dirs)
              (push dir yas-snippet-dirs))
            (yas-load-directory dir)))

        ;; C-c A t — insert a prompt template via yasnippet
        (global-set-key (kbd "C-c A t") 'yas-insert-snippet)
      ''
      + ''

        ;; Disable line numbers in agent-shell buffers
        ;; Re-enable TAB for yasnippet expansion (no completion conflict here)
        (add-hook 'agent-shell-mode-hook
                  (lambda ()
                    (display-line-numbers-mode 0)
                    (local-set-key (kbd "TAB") 'yas-expand)
                    (local-set-key (kbd "<tab>") 'yas-expand)))
      '';
    };
  };
}
