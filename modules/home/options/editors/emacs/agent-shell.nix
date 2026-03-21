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

  # == Custom auggie commands ==
  # Deployed to ~/.augment/commands/ via home.file (as symlinks).
  # User-created commands (regular files) coexist in the same directory
  # and are not affected by Nix. On `decknix switch`, Nix-managed ones
  # are refreshed; runtime-created ones persist.
  commandDir = ".augment/commands";

  commands = {
    "start.md" = ''
      ---
      description: Create a new session and rename it, optionally from a Jira ticket key
      argument-hint: [session name or JIRA-KEY]
      ---

      Create a new Augment session and rename it in one step.

      **Instructions:**

      1. **Parse the argument:** The user provides `$ARGUMENTS` which can be:
         - A **Jira ticket key** (e.g., `ALR-4268`, `ARC-10308`) — detected by matching the pattern `[A-Z]+-\d+`
         - A **plain session name** (e.g., "proptrack pubsub fix")
         - **Empty** — prompt the user for a name

      2. **If a Jira ticket key is detected:**
         - Fetch the ticket summary from Jira using the Jira API tool: `GET /issue/{key}` with fields `summary,status,assignee,parent`
         - If the ticket has a parent, also fetch the parent summary
         - Construct the session name as: `{KEY}: {parent summary or ticket summary}`
         - Display the ticket details briefly:
           ```
           📋 {KEY}: {summary}
           📌 Status: {status} | Assignee: {assignee or "Unassigned"}
           🏷️ Session: {constructed name}
           ```

      3. **Inform the user** that `/new` and `/rename` are built-in commands that cannot be invoked programmatically from within a session. Instead, provide the exact commands to run:

         ```
         To start this session, run these commands:

         /new
         /rename {session name}
         ```

         If the session name contains special characters, wrap it in quotes.

      4. **Offer to set up context** for the new session:
         - Ask if they'd like a brief summary of the current session to carry forward
         - If yes, generate a 3-5 bullet summary of key decisions, findings, and next steps from the current conversation
    '';

    "find-session.md" = ''
      ---
      description: Search all saved sessions by keyword and display matches for resuming
      argument-hint: <search term>
      ---

      Search through ALL auggie sessions (not just the last 10) and help the user find the one they want to resume.

      **Instructions:**

      1. Run this shell command to get all sessions as JSON:
         ```
         auggie session list --json -n 500 --all 2>/dev/null
         ```

      2. If the user provided a search term as `$ARGUMENTS`, filter the sessions where `firstUserMessage`, `lastUserMessage`, or any entry in `userMessages` contains that term (case-insensitive). If no search term was provided, show the most recent 30 sessions.

      3. Display the matching sessions in a clean, compact table. For each session show:
         - A number (starting from 1)
         - The session ID (first 8 characters)
         - When it was last modified (relative, e.g. "2h ago", "3d ago")
         - Number of exchanges
         - The first user message (truncated to 80 chars)
         Sort by most recently modified first.

      4. Ask the user which session they'd like to resume (by number or search term).

      5. When the user picks a session, tell them the exact command to run:
         ```
         auggie session resume <sessionId>
         ```
         **Note:** Session switching cannot be triggered programmatically from within an active session — the user must exit first (Ctrl+C or /exit) and then run the resume command.

      6. If no sessions match, suggest broadening the search or trying `/find-session` with no arguments to see recent sessions.

      **Important:** Use `python3` for JSON parsing. Keep output concise and scannable.
    '';

    "pivot-conversation.md" = ''
      ---
      description: Hard pivot — discard current plan and re-evaluate with new context
      argument-hint: [new direction or constraint]
      ---

      **[SYSTEM OVERRIDE: HARD PIVOT INITIATED]**

      Stop your current execution path immediately. I am injecting new information, constraints, or a change in direction that supersedes your previous plan.

      Please execute the following steps strictly in order:
      1. **Halt and Discard:** Discard the immediate next steps or tool calls you were just about to execute.
      2. **Ingest New Context:** Carefully review the new information I have provided in my prompt alongside this command.
      3. **Analyze the Impact:** Briefly explain (in 1-2 sentences) how this new information changes our current approach or invalidates your previous assumptions.
      4. **State the New Plan:** Provide a concise, bulleted list of the exact next steps you will take based on this pivot.
      5. **Wait for Approval:** Do NOT write any code, modify any files, or execute any terminal commands until I explicitly approve your new plan.
    '';

    "step-back.md" = ''
      ---
      description: Stop, summarize progress, and wait for direction
      ---

      Stop your current execution path.
      1. Summarize exactly what you have modified so far.
      2. List the specific errors or roadblocks you are encountering.
      3. Wait for my explicit direction before writing any more code or executing any more terminal commands.
    '';
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

    commands.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Nix-managed auggie custom commands (deployed to ~/.augment/commands/).";
    };

    context.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable the context panel for agent-shell sessions.
        Shows tracked issues, PRs, CI status, and review threads in the
        header-line. Provides C-c i sub-prefix for navigation and C-c I
        for a detailed transient panel. Requires gh CLI on PATH.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Deploy yasnippet snippets + auggie commands via home.file
    home.file =
      # Yasnippet snippet files → ~/.emacs.d/snippets/agent-shell-mode/
      (optionalAttrs cfg.templates.enable
        (mapAttrs'
          (name: text: nameValuePair "${snippetDir}/${name}" { inherit text; })
          snippets))
      //
      # Auggie custom commands → ~/.augment/commands/
      (optionalAttrs cfg.commands.enable
        (mapAttrs'
          (name: text: nameValuePair "${commandDir}/${name}" { inherit text; })
          commands));
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

        (defun decknix--agent-welcome-message (config)
          "Custom welcome message with a help hint.
        Reproduces the auggie welcome (ASCII art + shell-maker message)
        and appends a brief hint for discovering keybindings."
          (let* ((art (agent-shell--indent-string 4 (agent-shell-auggie--ascii-art)))
                 (base-msg (string-trim-left (shell-maker-welcome-message config) "\n"))
                 (original (concat "\n\n" art "\n\n" base-msg))
                 (hint (concat "  "
                               (propertize "C-c ? k" 'font-lock-face 'font-lock-keyword-face)
                               " keybindings  "
                               (propertize "C-c ? t" 'font-lock-face 'font-lock-keyword-face)
                               " tutorial  "
                               (propertize "C-c e" 'font-lock-face 'font-lock-keyword-face)
                               " compose")))
            (concat original "\n" hint "\n")))

        ;; Swap the :welcome-function in the agent config to use our
        ;; enhanced version.  We advise make-agent-config because the
        ;; welcome function is stored as a direct function reference
        ;; in the config alist (not called by symbol), so symbol-level
        ;; advice on agent-shell-auggie--welcome-message has no effect.
        (advice-add 'agent-shell-auggie-make-agent-config
                    :filter-return
                    (lambda (config)
                      (let ((cell (assq :welcome-function config)))
                        (when cell
                          (setcdr cell #'decknix--agent-welcome-message)))
                      config))

        (defun decknix--agent-help-show (name content)
          "Display CONTENT in a help buffer called NAME.
Press q to dismiss."
          (let ((buf (get-buffer-create name)))
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert content)
                (goto-char (point-min))
                (special-mode)))
            (display-buffer buf '(display-buffer-at-bottom
                                  (window-height . fit-window-to-buffer)))))

        (defun decknix-agent-help-keys ()
          "Show keybinding reference. Press q to dismiss."
          (interactive)
          (decknix--agent-help-show
           "*Agent Keys*"
           (concat
            (propertize "Agent Shell — Keybinding Reference\n"
                        'font-lock-face '(:weight bold :height 1.2))
            (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face)
            "\n\n"

            (propertize "Sessions  (C-c s …)\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c s s     Session picker (live + saved)\n"
            "  C-c s q     Quit session (saves automatically)\n"
            "  C-c s h     View history (C-u to pick any session)\n"
            "  C-c s y     Copy session ID (C-u for full ID)\n"
            "  C-c s d     Toggle short/full ID in header\n"
            "\n"

            (propertize "Input & Editing\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c e       Compose buffer (multi-line editor)\n"
            "  C-c r       Rename buffer\n"
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

            (propertize "Commands  (C-c c …)\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c c c     Pick & insert a slash command\n"
            "  C-c c n     Create new command\n"
            "  C-c c e     Edit existing command\n"
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
            "  C-c C-v     Pick model\n"
            "  C-c C-m     Pick mode\n"
            "\n"

            (propertize "Context  (C-c i …)\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c I       Full context panel\n"
            "  C-c i i     List tracked issues\n"
            "  C-c i p     List tracked PRs\n"
            "  C-c i c     Show CI status\n"
            "  C-c i r     Show review threads\n"
            "  C-c i a     Pin issue/PR to context\n"
            "  C-c i d     Unpin from context\n"
            "  C-c i g     Open in browser\n"
            "  C-c i f     Visit in forge\n"
            "\n"

            (propertize "Extensions\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c m       Manager dashboard\n"
            "  C-c w       Workspace tab toggle\n"
            "  C-c j       Jump to session needing attention\n"
            "  C-c A S     MCP server list\n"
            "\n"

            (propertize "Global  (C-c A …)\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c A a     Start / switch to agent\n"
            "  C-c A n     Force new session\n"
            "  C-c A s     Session picker\n"
            "  C-c A h     View history (C-u to pick)\n"
            "  C-c A e     Compose buffer\n"
            "  C-c A ? k   This keybinding reference\n"
            "\n"

            (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face) "\n"
            (propertize "Press q to close this buffer.\n"
                        'font-lock-face 'font-lock-comment-face))))

        (defun decknix-agent-help-tutorial ()
          "Show a tutorial with step-by-step guidance. Press q to dismiss."
          (interactive)
          (decknix--agent-help-show
           "*Agent Tutorial*"
           (concat
            (propertize "Agent Shell — Tutorial\n"
                        'font-lock-face '(:weight bold :height 1.2))
            (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face)
            "\n\n"

            (propertize "1. Getting Started\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  Type a prompt at the bottom and press RET to send.\n"
            "  Use S-RET to insert a newline without sending.\n"
            "  For longer prompts, press C-c e to open the compose buffer.\n"
            "  Press C-c C-c to interrupt a running response.\n"
            "\n"

            (propertize "2. Sessions\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  Each buffer is a separate agent session.\n"
            "  C-c s s opens the session picker to switch or resume.\n"
            "  C-c s q saves and quits the current session.\n"
            "  C-c s h opens the conversation history in a browser.\n"
            "  Sessions are saved automatically by auggie.\n"
            "\n"

            (propertize "3. Templates & Commands\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c t t inserts a yasnippet prompt template.\n"
            "  C-c c c inserts a custom slash command.\n"
            "  Both support tab-stop fields for filling in parameters.\n"
            "  Create your own with C-c t n (template) or C-c c n (command).\n"
            "\n"

            (propertize "4. Tags & Organisation\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c T t adds a tag to the current session.\n"
            "  C-c T l filters sessions by tag in the picker.\n"
            "  Tags are stored in ~/.config/agent-sessions.json.\n"
            "\n"

            (propertize "5. Context Awareness\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  The agent auto-detects issue/PR references in conversation.\n"
            "  C-c I opens the full context panel.\n"
            "  C-c i a pins an issue/PR; C-c i d unpins it.\n"
            "  C-c i g opens the item in your browser.\n"
            "\n"

            (propertize "6. Multi-Session Workflow\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c A n starts a new session from anywhere.\n"
            "  C-c m opens the manager dashboard.\n"
            "  C-c j jumps to a session needing attention.\n"
            "  C-c w toggles the workspace tab.\n"
            "\n"

            (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face) "\n"
            (propertize "Press q to close this buffer.\n"
                        'font-lock-face 'font-lock-comment-face))))

        (defun decknix-agent-help-functions ()
          "Show available slash commands and templates. Press q to dismiss."
          (interactive)
          (let* ((cmd-files (when (fboundp 'decknix--agent-command-files)
                              (decknix--agent-command-files)))
                 (cmd-text (if cmd-files
                               (mapconcat
                                (lambda (file)
                                  (format "  /%s  %s"
                                          (propertize (file-name-sans-extension
                                                       (file-name-nondirectory file))
                                                      'font-lock-face 'font-lock-function-name-face)
                                          (or (decknix--agent-command-description file) "")))
                                cmd-files "\n")
                             "  (none defined)"))
                 (tmpl-text (if (and (boundp 'yas-snippet-dirs) yas-snippet-dirs)
                                (let ((snippets nil))
                                  (dolist (dir yas-snippet-dirs)
                                    (let ((mode-dir (expand-file-name "agent-shell-mode" dir)))
                                      (when (file-directory-p mode-dir)
                                        (dolist (f (directory-files mode-dir nil "^[^.]"))
                                          (push f snippets)))))
                                  (if snippets
                                      (mapconcat
                                       (lambda (s)
                                         (format "  %s" (propertize s 'font-lock-face 'font-lock-function-name-face)))
                                       (sort (delete-dups snippets) #'string<) "\n")
                                    "  (none found)"))
                              "  (yasnippet not loaded)")))
            (decknix--agent-help-show
             "*Agent Functions*"
             (concat
              (propertize "Agent Shell — Functions & Templates\n"
                          'font-lock-face '(:weight bold :height 1.2))
              (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face)
              "\n\n"

              (propertize "Slash Commands  (C-c c c to insert)\n" 'font-lock-face '(:weight bold))
              (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
              cmd-text "\n\n"

              (propertize "Prompt Templates  (C-c t t to insert)\n" 'font-lock-face '(:weight bold))
              (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
              tmpl-text "\n\n"

              (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face) "\n"
              (propertize "Press q to close this buffer.\n"
                          'font-lock-face 'font-lock-comment-face)))))

        ;; == Help prefix map: C-c ? → sub-keys ==
        (define-prefix-command 'decknix-agent-help-map)

        ;; == Named prefix map: C-c A → "Agent" ==
        ;; Gives which-key / minibuffer a descriptive label instead of "+prefix"
        (define-prefix-command 'decknix-agent-prefix-map)
        (global-set-key (kbd "C-c A") 'decknix-agent-prefix-map)
        (with-eval-after-load 'which-key
          (which-key-add-key-based-replacements "C-c A" "Agent")
          (which-key-add-key-based-replacements "C-c A ?" "Help"))

        ;; Global keybindings under C-c A prefix
        ;; Only actions that make sense from OUTSIDE an agent-shell buffer.
        ;; Buffer-local bindings (C-c ...) handle in-buffer actions — no duplicates.
        (define-key decknix-agent-prefix-map (kbd "a") 'agent-shell)                      ; Start/switch to agent
        (define-key decknix-agent-prefix-map (kbd "n") 'agent-shell-new)                  ; Force new session
        (define-key decknix-agent-prefix-map (kbd "?") 'decknix-agent-help-map)           ; Help sub-prefix
        (define-key decknix-agent-help-map (kbd "k") 'decknix-agent-help-keys)            ; Keybindings
        (define-key decknix-agent-help-map (kbd "t") 'decknix-agent-help-tutorial)        ; Tutorial
        (define-key decknix-agent-help-map (kbd "f") 'decknix-agent-help-functions)       ; Functions/commands

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

        (defun decknix--agent-unsorted-table (candidates)
          "Wrap CANDIDATES in a completion table that preserves list order.
Prevents vertico/orderless from re-sorting alphabetically."
          (lambda (string pred action)
            (if (eq action 'metadata)
                '(metadata (display-sort-function . identity)
                           (cycle-sort-function . identity))
              (complete-with-action action candidates string pred))))

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
                                            (decknix--agent-unsorted-table
                                             (mapcar #'car all-entries))
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
                                            (decknix--agent-unsorted-table
                                             (mapcar #'car entries))
                                            nil t)))
            (or (cdr (assoc selection entries))
                (user-error "No session selected"))))

        (defun decknix-agent-session-history (&optional pick)
          "View conversation history for a session.
Without prefix argument PICK, shows history for the current session
if in an agent-shell buffer with a known session ID, otherwise
prompts to pick a session.
With \\[universal-argument], always prompts to pick a session.
Opens in xwidget-webkit (q to quit) or eww as fallback."
          (interactive "P")
          (let ((session-id
                 (if (and (not pick)
                          (derived-mode-p 'agent-shell-mode)
                          decknix--agent-auggie-session-id)
                     decknix--agent-auggie-session-id
                   (decknix--agent-session-pick-for-history))))
            (decknix--agent-session-open-share session-id)))

        (define-key decknix-agent-prefix-map (kbd "s") 'decknix-agent-session-picker)        ; Session picker
        (define-key decknix-agent-prefix-map (kbd "h") 'decknix-agent-session-history)       ; View history (C-u to pick)

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
                                   (decknix--agent-unsorted-table
                                    (mapcar #'car entries)) nil t))
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

        ;; == Session ID: shortened display, copy, toggle ==

        (defvar decknix--agent-show-full-session-id nil
          "When non-nil, show the full session ID in the header.
When nil (default), show only the first 8 characters.")

        (advice-add 'agent-shell--session-id-indicator
                    :filter-return
                    (lambda (result)
                      "Truncate the session ID to 8 chars unless full display is toggled on."
                      (if (and result (stringp result)
                               (not decknix--agent-show-full-session-id)
                               (> (length result) 8))
                          (propertize (substring (substring-no-properties result) 0 8)
                                     'font-lock-face 'font-lock-constant-face)
                        result)))

        (defun decknix--agent-get-session-id ()
          "Return the current ACP session ID, or nil."
          (when (derived-mode-p 'agent-shell-mode)
            (map-nested-elt (agent-shell--state) '(:session :id))))

        (defun decknix-agent-session-copy-id (&optional full)
          "Copy the session ID to the kill ring.
With prefix argument FULL (\\[universal-argument]), copy the full ID.
Otherwise copy the shortened 8-character hash."
          (interactive "P")
          (if-let ((id (decknix--agent-get-session-id)))
              (let ((result (if full id
                             (substring id 0 (min 8 (length id))))))
                (kill-new result)
                (message "Copied: %s" result))
            (user-error "No active session")))

        (defun decknix-agent-session-toggle-id-display ()
          "Toggle between showing short (8-char) and full session ID in the header."
          (interactive)
          (setq decknix--agent-show-full-session-id
                (not decknix--agent-show-full-session-id))
          ;; Force header refresh
          (when (derived-mode-p 'agent-shell-mode)
            (setq-local agent-shell--header-cache (make-hash-table :test 'equal))
            (force-mode-line-update))
          (message "Session ID display: %s"
                   (if decknix--agent-show-full-session-id "full" "short (8 chars)")))

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

        ;; == Custom commands: discovery, picker, authoring ==

        (defvar decknix--agent-command-dirs
          (list (expand-file-name "~/.augment/commands"))
          "Directories to scan for auggie custom commands.
        Project-level .augment/commands/ is added dynamically.")

        (defun decknix--agent-command-files ()
          "Return an alist of (name . path) for all available commands.
        Scans global and project-level command directories."
          (let ((dirs (copy-sequence decknix--agent-command-dirs))
                (result nil))
            ;; Add project-level .augment/commands/ if it exists
            (when-let* ((proj (project-current))
                        (root (project-root proj))
                        (proj-dir (expand-file-name ".augment/commands" root)))
              (when (file-directory-p proj-dir)
                (push proj-dir dirs)))
            (dolist (dir dirs)
              (when (file-directory-p dir)
                (dolist (file (directory-files dir t "\\.md\\'" t))
                  (let* ((name (file-name-sans-extension
                                (file-name-nondirectory file)))
                         (scope (if (string-prefix-p
                                     (expand-file-name "~/.augment") dir)
                                    "global" "project")))
                    (push (cons (format "/%s  (%s)" name scope) file) result)))))
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

        (defun decknix-agent-command-run ()
          "Pick a custom command and insert it as a slash command in the prompt.
        Shows commands from ~/.augment/commands/ and project .augment/commands/."
          (interactive)
          (let* ((cmds (decknix--agent-command-files))
                 (annotator (lambda (cand)
                              (when-let* ((file (cdr (assoc cand cmds))))
                                (format "  %s" (decknix--agent-command-description file)))))
                 (selection (completing-read
                             "Command: " (mapcar #'car cmds) nil t nil nil nil
                             `(annotation-function . ,annotator)))
                 (file (cdr (assoc selection cmds)))
                 (name (progn (string-match "^/\\([^ ]+\\)" selection)
                              (match-string 1 selection))))
            ;; Insert the slash command at the agent-shell prompt
            (if (derived-mode-p 'agent-shell-mode)
                (progn
                  (goto-char (point-max))
                  (insert (format "/%s " name)))
              (message "Copied: /%s (use in an agent-shell buffer)" name))))

        (defun decknix-agent-command-new ()
          "Create a new auggie custom command.
        Prompts for a name and opens a template in ~/.augment/commands/."
          (interactive)
          (let* ((name (read-string "Command name (no extension): "))
                 (name (string-trim name))
                 (file (expand-file-name
                        (format "~/.augment/commands/%s.md" name))))
            (when (string-empty-p name)
              (user-error "Name cannot be empty"))
            (when (file-exists-p file)
              (user-error "Command %s already exists — use edit instead" name))
            (find-file file)
            (insert (format "---\ndescription: %s\nargument-hint: [args]\n---\n\n" name))
            (message "New command: %s — write instructions, then save." name)))

        (defun decknix-agent-command-edit ()
          "Edit an existing auggie custom command."
          (interactive)
          (let* ((cmds (decknix--agent-command-files))
                 (selection (completing-read "Edit command: "
                                            (mapcar #'car cmds) nil t))
                 (file (cdr (assoc selection cmds))))
            (find-file file)))

        ;; C-c A c — commands sub-prefix ("Commands")
        (define-prefix-command 'decknix-agent-command-map)
        (define-key decknix-agent-prefix-map (kbd "c") 'decknix-agent-command-map)
        (with-eval-after-load 'which-key
          (which-key-add-key-based-replacements "C-c A c" "Commands"))
        (define-key decknix-agent-command-map (kbd "c") 'decknix-agent-command-run)    ; Pick & insert
        (define-key decknix-agent-command-map (kbd "n") 'decknix-agent-command-new)    ; New
        (define-key decknix-agent-command-map (kbd "e") 'decknix-agent-command-edit)   ; Edit

        ;; == MCP server listing ==

        (defun decknix-agent-mcp-list ()
          "Show configured MCP servers in a help buffer.
        Reads from ~/.augment/settings.json."
          (interactive)
          (let* ((settings-file (expand-file-name "~/.augment/settings.json"))
                 (json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'symbol)
                 (settings (if (file-exists-p settings-file)
                               (json-read-file settings-file)
                             nil))
                 (servers (alist-get 'mcpServers settings))
                 (buf (get-buffer-create "*MCP Servers*")))
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert
                 (propertize "MCP Server Configuration\n"
                             'font-lock-face '(:weight bold :height 1.2))
                 (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face)
                 "\n"
                 (propertize (format "Source: %s\n\n" settings-file)
                             'font-lock-face 'font-lock-comment-face))
                (if (null servers)
                    (insert "  No MCP servers configured.\n")
                  (dolist (server servers)
                    (let* ((name (symbol-name (car server)))
                           (config (cdr server))
                           (cmd (or (alist-get 'command config) "?"))
                           (args (alist-get 'args config))
                           (stype (or (alist-get 'type config) "stdio"))
                           (env (alist-get 'env config)))
                      (insert (propertize (format "  %s\n" name)
                                          'font-lock-face 'font-lock-function-name-face))
                      (insert (format "    type:    %s\n" stype))
                      (insert (format "    command: %s\n" cmd))
                      (when args
                        (insert (format "    args:    %s\n"
                                        (string-join (mapcar #'format args) " "))))
                      (when (and env (> (length env) 0))
                        (insert "    env:\n")
                        (dolist (e env)
                          (insert (format "      %s=%s\n"
                                          (symbol-name (car e)) (cdr e)))))
                      (insert "\n"))))
                (insert (propertize (make-string 52 ?═) 'font-lock-face 'font-lock-comment-face) "\n"
                        (propertize "Runtime changes (auggie mcp add) are temporary.\n"
                                    'font-lock-face 'font-lock-comment-face)
                        (propertize "To persist, edit Nix config and run decknix switch.\n"
                                    'font-lock-face 'font-lock-comment-face)
                        (propertize "Press q to close this buffer.\n"
                                    'font-lock-face 'font-lock-comment-face))
                (goto-char (point-min))
                (special-mode)))
            (display-buffer buf '(display-buffer-at-bottom
                                  (window-height . fit-window-to-buffer)))))

        (define-key decknix-agent-prefix-map (kbd "S") 'decknix-agent-mcp-list)           ; MCP servers
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
      + optionalString cfg.context.enable ''

        ;; == Context Panel: issues, PRs, CI status, reviews ==
        ;; Surfaces work context in the header-line with C-c i navigation.
        ;; Uses `gh` CLI for GitHub data fetching.

        ;; -- Data model --
        ;; Each buffer tracks a set of context items (issues, PRs).
        ;; Items can be auto-detected from conversation text or manually pinned.

        (defvar-local decknix--context-items nil
          "Alist of tracked context items for this agent-shell buffer.
Each entry is (ID . plist) where ID is e.g. \"#49\" or \"NC-1234\".
Plist keys: :type (issue|pr|jira), :repo, :number, :state, :title, :pinned, :url")

        (defvar-local decknix--context-ci nil
          "Plist of CI status for current branch. Keys: :status :name :elapsed :url")

        (defvar-local decknix--context-reviews nil
          "Plist of PR review status. Keys: :total :unresolved :url")

        (defvar-local decknix--context-branch nil
          "Current git branch name for context.")

        (defvar-local decknix--context-repo nil
          "Current GitHub owner/repo for context (e.g. \"ldeck/decknix\").")

        (defvar decknix--context-ci-timer nil
          "Timer for periodic CI status polling.")

        ;; -- Repository detection --
        (defun decknix--context-detect-repo ()
          "Detect GitHub owner/repo from the project's git remote."
          (let* ((default-directory (or (when (fboundp 'project-root)
                                          (when-let ((proj (project-current)))
                                            (project-root proj)))
                                        default-directory))
                 (url (string-trim
                       (shell-command-to-string "git remote get-url origin 2>/dev/null"))))
            (when (string-match "github\\.com[:/]\\([^/]+/[^/.]+\\)" url)
              (match-string 1 url))))

        ;; -- Reference detection from buffer text --
        (defun decknix--context-scan-buffer ()
          "Scan agent-shell buffer text for issue/PR references.
Returns an alist of (ID . plist) for newly detected items."
          (let ((found nil)
                (text (buffer-substring-no-properties (point-min) (point-max))))
            ;; GitHub issues/PRs: #123 or org/repo#123
            (with-temp-buffer
              (insert text)
              (goto-char (point-min))
              (while (re-search-forward
                      "\\(?:\\([A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\)\\)?#\\([0-9]+\\)" nil t)
                (let* ((repo (or (match-string 1) decknix--context-repo))
                       (num (match-string 2))
                       (id (if (match-string 1)
                               (format "%s#%s" repo num)
                             (format "#%s" num))))
                  (unless (assoc id found)
                    (push (cons id (list :type 'github :repo repo
                                         :number (string-to-number num)
                                         :state nil :title nil :pinned nil))
                          found))))
              ;; Jira tickets: PROJ-123
              (goto-char (point-min))
              (while (re-search-forward "\\b\\([A-Z][A-Z0-9]+-[0-9]+\\)\\b" nil t)
                (let ((id (match-string 1)))
                  (unless (or (assoc id found)
                              ;; Exclude false positives (common non-Jira patterns)
                              (string-match-p "\\`\\(HTTP\\|SHA\\|UTF\\|ISO\\)-" id))
                    (push (cons id (list :type 'jira :state nil :title nil :pinned nil))
                          found)))))
            found))

        ;; -- Merge detected items into tracked context --
        (defun decknix--context-refresh-detected ()
          "Scan buffer and merge newly detected items into context.
Preserves pinned items and previously fetched metadata."
          (let ((detected (decknix--context-scan-buffer)))
            ;; Add new items (don't overwrite existing with fetched metadata)
            (dolist (item detected)
              (unless (assoc (car item) decknix--context-items)
                (push item decknix--context-items)))))

        ;; -- Pin / unpin --
        (defun decknix-context-pin (id)
          "Manually pin an issue or PR ID to the current session context."
          (interactive "sPin issue/PR (e.g. #49, NC-1234, org/repo#12): ")
          (let ((entry (assoc id decknix--context-items)))
            (if entry
                (plist-put (cdr entry) :pinned t)
              ;; Detect type from format
              (let ((type (cond
                           ((string-match "\\`[A-Z][A-Z0-9]+-[0-9]+\\'" id) 'jira)
                           (t 'github))))
                (push (cons id (list :type type :pinned t :state nil :title nil))
                      decknix--context-items)))
            (decknix--context-update-header)
            (message "Pinned %s to context" id)))

        (defun decknix-context-unpin ()
          "Remove a tracked item from the session context."
          (interactive)
          (let* ((keys (mapcar #'car decknix--context-items))
                 (choice (completing-read "Unpin: " keys nil t)))
            (setq decknix--context-items
                  (assoc-delete-all choice decknix--context-items))
            (decknix--context-update-header)
            (message "Removed %s from context" choice)))
      ''
      + optionalString cfg.context.enable ''

        ;; -- GitHub data fetching via gh CLI --
        (defun decknix--context-gh-json (args)
          "Run gh CLI with ARGS, return parsed JSON or nil on error."
          (condition-case nil
              (let ((output (string-trim
                             (shell-command-to-string
                              (format "gh %s 2>/dev/null" args)))))
                (when (and output (not (string-empty-p output))
                           (string-prefix-p "{" output))
                  (json-read-from-string output)))
            (error nil)))

        (defun decknix--context-gh-json-array (args)
          "Run gh CLI with ARGS, return parsed JSON array or nil."
          (condition-case nil
              (let ((output (string-trim
                             (shell-command-to-string
                              (format "gh %s 2>/dev/null" args)))))
                (when (and output (not (string-empty-p output))
                           (string-prefix-p "[" output))
                  (json-read-from-string output)))
            (error nil)))

        (defun decknix--context-fetch-issue (repo number)
          "Fetch issue/PR metadata from GitHub for REPO #NUMBER."
          (let ((data (decknix--context-gh-json
                       (format "issue view %d --repo %s --json number,title,state,url,isPullRequest"
                               number repo))))
            (when data
              (let ((is-pr (eq (alist-get 'isPullRequest data) t)))
                (list :state (downcase (or (alist-get 'state data) "unknown"))
                      :title (alist-get 'title data)
                      :url (alist-get 'url data)
                      :type (if is-pr 'pr 'issue))))))

        (defun decknix--context-fetch-ci ()
          "Fetch latest CI run status for the current branch."
          (let* ((branch (or decknix--context-branch
                             (string-trim
                              (shell-command-to-string "git branch --show-current 2>/dev/null"))))
                 (repo (or decknix--context-repo (decknix--context-detect-repo)))
                 (data (decknix--context-gh-json
                        (format "run list --branch %s --repo %s --limit 1 --json status,conclusion,name,url,updatedAt"
                                (shell-quote-argument branch)
                                (shell-quote-argument (or repo ""))))))
            (when (and data (> (length data) 0))
              (let* ((run (if (vectorp data) (aref data 0) (car data)))
                     (status (alist-get 'status run))
                     (conclusion (alist-get 'conclusion run)))
                (setq decknix--context-ci
                      (list :status (cond
                                     ((string= status "completed")
                                      (if (string= conclusion "success") "pass" "fail"))
                                     ((string= status "in_progress") "running")
                                     (t status))
                            :name (alist-get 'name run)
                            :url (alist-get 'url run)))))))

        (defun decknix--context-fetch-reviews ()
          "Fetch unresolved review thread count for open PRs in context."
          (let ((unresolved 0) (total 0) (pr-url nil))
            (dolist (item decknix--context-items)
              (let ((props (cdr item)))
                (when (and (eq (plist-get props :type) 'pr)
                           (string= (plist-get props :state) "open"))
                  (let* ((repo (or (plist-get props :repo) decknix--context-repo))
                         (num (plist-get props :number))
                         (threads (decknix--context-gh-json-array
                                   (format "pr view %d --repo %s --json reviewThreads --jq '.reviewThreads'"
                                           num (shell-quote-argument (or repo ""))))))
                    (when threads
                      (setq pr-url (plist-get props :url))
                      (let ((vec (if (vectorp threads) threads (vconcat threads))))
                        (setq total (+ total (length vec)))
                        (dotimes (i (length vec))
                          (let ((thread (aref vec i)))
                            (unless (eq (alist-get 'isResolved thread) t)
                              (setq unresolved (1+ unresolved)))))))))))
            (setq decknix--context-reviews
                  (list :total total :unresolved unresolved :url pr-url))))
      ''
      + optionalString cfg.context.enable ''

        ;; -- Header-line rendering --
        (defun decknix--context-header-string ()
          "Build the header-line string showing tracked context."
          (let ((parts nil))
            ;; Issues
            (let ((issues (cl-remove-if-not
                           (lambda (item) (eq (plist-get (cdr item) :type) 'issue))
                           decknix--context-items)))
              (when issues
                (push (format "Issues: %s"
                              (mapconcat
                               (lambda (item)
                                 (let* ((id (car item))
                                        (state (plist-get (cdr item) :state)))
                                   (propertize id 'face
                                               (cond ((string= state "open") 'success)
                                                     ((string= state "closed") 'shadow)
                                                     (t 'default)))))
                               issues " "))
                      parts)))
            ;; PRs
            (let ((prs (cl-remove-if-not
                        (lambda (item) (eq (plist-get (cdr item) :type) 'pr))
                        decknix--context-items)))
              (when prs
                (push (format "PR: %s"
                              (mapconcat
                               (lambda (item)
                                 (let* ((id (car item))
                                        (state (plist-get (cdr item) :state)))
                                   (propertize id 'face
                                               (cond ((string= state "open") 'success)
                                                     ((string= state "merged") 'font-lock-constant-face)
                                                     ((string= state "closed") 'shadow)
                                                     (t 'default)))))
                               prs " "))
                      parts)))
            ;; CI
            (when decknix--context-ci
              (let ((st (plist-get decknix--context-ci :status)))
                (push (format "CI: %s"
                              (propertize
                               (cond ((string= st "pass") "\u2705")
                                     ((string= st "fail") "\u274c")
                                     ((string= st "running") "\ud83d\udd04")
                                     (t "?"))
                               'face (cond ((string= st "pass") 'success)
                                           ((string= st "fail") 'error)
                                           (t 'warning))))
                      parts)))
            ;; Reviews
            (when (and decknix--context-reviews
                       (plist-get decknix--context-reviews :url))
              (let ((unres (plist-get decknix--context-reviews :unresolved)))
                (when (> unres 0)
                  (push (propertize (format "Reviews: %d unresolved" unres)
                                    'face 'warning)
                        parts))))
            (if parts
                (concat " " (mapconcat #'identity (nreverse parts) "  |  "))
              nil)))

        (defun decknix--context-update-header ()
          "Update the header-line-format for the current agent-shell buffer."
          (when (derived-mode-p 'agent-shell-mode)
            (let ((ctx (decknix--context-header-string)))
              (setq-local header-line-format
                          (when ctx
                            (list (propertize " " 'display '(space :width 0.5))
                                  ctx))))))
      ''
      + optionalString cfg.context.enable ''

        ;; -- Full refresh (async-ish: fetch all data, update header) --
        (defun decknix--context-full-refresh ()
          "Refresh all context data and update header-line."
          (interactive)
          (unless decknix--context-repo
            (setq decknix--context-repo (decknix--context-detect-repo)))
          (unless decknix--context-branch
            (setq decknix--context-branch
                  (string-trim
                   (shell-command-to-string "git branch --show-current 2>/dev/null"))))
          ;; Scan buffer for new references
          (decknix--context-refresh-detected)
          ;; Fetch GitHub metadata for items missing state
          (dolist (item decknix--context-items)
            (let ((props (cdr item)))
              (when (and (memq (plist-get props :type) '(github issue pr))
                         (null (plist-get props :state)))
                (let* ((repo (or (plist-get props :repo) decknix--context-repo))
                       (num (plist-get props :number)))
                  (when (and repo num)
                    (let ((meta (decknix--context-fetch-issue repo num)))
                      (when meta
                        (plist-put props :state (plist-get meta :state))
                        (plist-put props :title (plist-get meta :title))
                        (plist-put props :url (plist-get meta :url))
                        (plist-put props :type (plist-get meta :type)))))))))
          ;; Fetch CI and reviews
          (decknix--context-fetch-ci)
          (decknix--context-fetch-reviews)
          ;; Update display
          (decknix--context-update-header))

        ;; -- CI polling timer --
        (defun decknix--context-start-ci-polling ()
          "Start polling CI status every 60 seconds."
          (when decknix--context-ci-timer
            (cancel-timer decknix--context-ci-timer))
          (setq decknix--context-ci-timer
                (run-with-timer 60 60
                                (lambda ()
                                  (when-let ((buf (cl-find-if
                                                   (lambda (b)
                                                     (with-current-buffer b
                                                       (derived-mode-p 'agent-shell-mode)))
                                                   (buffer-list))))
                                    (with-current-buffer buf
                                      (decknix--context-fetch-ci)
                                      (decknix--context-update-header)))))))

        ;; -- Persistence: save/restore pinned context items --
        ;; Piggybacks on the existing agent-sessions.json tag store.
        ;; Each session entry gains a "context" key with pinned items.

        (defun decknix--context-save ()
          "Save pinned context items for the current agent-shell session."
          (when-let ((session-id (when (boundp 'agent-shell-session-id)
                                   (symbol-value 'agent-shell-session-id))))
            (let* ((store (decknix--agent-tags-read))
                   (entry (or (gethash session-id store)
                              (make-hash-table :test 'equal)))
                   (pinned (cl-remove-if-not
                            (lambda (item) (plist-get (cdr item) :pinned))
                            decknix--context-items))
                   (serialized (mapcar (lambda (item)
                                         (list (cons "id" (car item))
                                               (cons "type" (symbol-name
                                                             (plist-get (cdr item) :type)))
                                               (cons "repo" (plist-get (cdr item) :repo))
                                               (cons "number" (plist-get (cdr item) :number))))
                                       pinned)))
              (puthash "context" serialized entry)
              (puthash session-id entry store)
              (decknix--agent-tags-write store))))

        (defun decknix--context-restore ()
          "Restore pinned context items for the current agent-shell session."
          (when-let ((session-id (when (boundp 'agent-shell-session-id)
                                   (symbol-value 'agent-shell-session-id))))
            (let* ((store (decknix--agent-tags-read))
                   (entry (gethash session-id store))
                   (saved (and entry (gethash "context" entry))))
              (when saved
                (dolist (item saved)
                  (let* ((id (cdr (assoc "id" item)))
                         (type (intern (or (cdr (assoc "type" item)) "github")))
                         (repo (cdr (assoc "repo" item)))
                         (num (cdr (assoc "number" item))))
                    (unless (assoc id decknix--context-items)
                      (push (cons id (list :type type :repo repo :number num
                                           :state nil :title nil :pinned t))
                            decknix--context-items))))))))

        ;; Auto-save context when killing agent-shell buffers
        (add-hook 'kill-buffer-hook
                  (lambda ()
                    (when (derived-mode-p 'agent-shell-mode)
                      (decknix--context-save))))

        ;; -- Detail panel (transient-style buffer) --
        (defun decknix-context-panel ()
          "Show a detailed context panel for the current session."
          (interactive)
          (decknix--context-full-refresh)
          (let ((buf (get-buffer-create "*Agent Context*"))
                (items decknix--context-items)
                (ci decknix--context-ci)
                (reviews decknix--context-reviews)
                (branch decknix--context-branch)
                (repo decknix--context-repo))
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert
                 (propertize "Agent Context Panel\n"
                             'font-lock-face '(:weight bold :height 1.2))
                 (propertize (make-string 52 ?\u2500) 'font-lock-face 'font-lock-comment-face)
                 "\n\n")
                ;; Issues
                (let ((issues (cl-remove-if-not
                               (lambda (i) (eq (plist-get (cdr i) :type) 'issue))
                               items)))
                  (insert (propertize "Issues\n" 'font-lock-face '(:weight bold))
                          (propertize (make-string 40 ?\u2500) 'font-lock-face 'font-lock-comment-face)
                          "\n")
                  (if issues
                      (dolist (item issues)
                        (let* ((id (car item))
                               (props (cdr item))
                               (pin (if (plist-get props :pinned) " \ud83d\udccc" "")))
                          (insert (format "  %-12s %-35s %s%s\n"
                                          id
                                          (or (plist-get props :title) "")
                                          (or (plist-get props :state) "?")
                                          pin))))
                    (insert "  (none detected)\n"))
                  (insert "\n"))
                ;; PRs
                (let ((prs (cl-remove-if-not
                            (lambda (i) (eq (plist-get (cdr i) :type) 'pr))
                            items)))
                  (insert (propertize "Pull Requests\n" 'font-lock-face '(:weight bold))
                          (propertize (make-string 40 ?\u2500) 'font-lock-face 'font-lock-comment-face)
                          "\n")
                  (if prs
                      (dolist (item prs)
                        (let* ((id (car item))
                               (props (cdr item))
                               (state (or (plist-get props :state) "?"))
                               (icon (cond ((string= state "merged") "\u2705")
                                           ((string= state "open") "\ud83d\udfe2")
                                           ((string= state "closed") "\ud83d\udd34")
                                           (t " "))))
                          (insert (format "  %s %-10s %-32s %s\n"
                                          icon id
                                          (or (plist-get props :title) "")
                                          state))))
                    (insert "  (none detected)\n"))
                  (insert "\n"))
                ;; Branch & CI
                (insert (propertize "Branch & CI\n" 'font-lock-face '(:weight bold))
                        (propertize (make-string 40 ?\u2500) 'font-lock-face 'font-lock-comment-face)
                        "\n")
                (when branch
                  (insert (format "  Branch: %s" branch))
                  (when repo (insert (format "  (%s)" repo)))
                  (insert "\n"))
                (if ci
                    (let ((st (plist-get ci :status)))
                      (insert (format "  CI:     %s %s\n"
                                      (cond ((string= st "pass") "\u2705 success")
                                            ((string= st "fail") "\u274c failed")
                                            ((string= st "running") "\ud83d\udd04 running")
                                            (t st))
                                      (or (plist-get ci :name) ""))))
                  (insert "  CI:     (not fetched)\n"))
                (insert "\n")
                ;; Reviews
                (insert (propertize "Reviews\n" 'font-lock-face '(:weight bold))
                        (propertize (make-string 40 ?\u2500) 'font-lock-face 'font-lock-comment-face)
                        "\n")
                (if reviews
                    (insert (format "  %d threads, %d unresolved\n"
                                    (plist-get reviews :total)
                                    (plist-get reviews :unresolved)))
                  (insert "  (no open PRs in context)\n"))
                (insert "\n"
                        (propertize (make-string 52 ?\u2500) 'font-lock-face 'font-lock-comment-face)
                        "\n"
                        (propertize "Press q to close.  C-c i g to open item in browser.\n"
                                    'font-lock-face 'font-lock-comment-face))
                (goto-char (point-min))
                (special-mode)))
            (display-buffer buf '(display-buffer-at-bottom
                                  (window-height . fit-window-to-buffer)))))

        ;; -- Navigation commands --
        (defun decknix-context-browse ()
          "Open a tracked context item in the browser."
          (interactive)
          (let* ((items (cl-remove-if
                         (lambda (i) (null (plist-get (cdr i) :url)))
                         decknix--context-items))
                 (choices (mapcar (lambda (i)
                                   (format "%s  %s" (car i)
                                           (or (plist-get (cdr i) :title) "")))
                                 items))
                 (choice (completing-read "Open in browser: " choices nil t))
                 (id (car (split-string choice "  ")))
                 (url (plist-get (cdr (assoc id decknix--context-items)) :url)))
            (when url (browse-url url))))

        (defun decknix-context-browse-ci ()
          "Open the latest CI run in the browser."
          (interactive)
          (if-let ((url (plist-get decknix--context-ci :url)))
              (browse-url url)
            (message "No CI run URL available. Try C-c i c to refresh.")))

        (defun decknix-context-forge-visit ()
          "Visit a tracked issue/PR in magit-forge."
          (interactive)
          (let* ((choices (mapcar (lambda (i)
                                   (format "%s  %s" (car i)
                                           (or (plist-get (cdr i) :title) "")))
                                 decknix--context-items))
                 (choice (completing-read "Visit in forge: " choices nil t))
                 (id (car (split-string choice "  ")))
                 (props (cdr (assoc id decknix--context-items)))
                 (num (plist-get props :number)))
            (if (and num (fboundp 'forge-visit-topic))
                (let ((repo (or (plist-get props :repo) decknix--context-repo)))
                  (message "Opening %s in forge..." id)
                  ;; Use forge-visit-topic if we can find it
                  (if-let ((url (plist-get props :url)))
                      (browse-url url)
                    (message "No URL for %s" id)))
              (message "No forge support for %s" id))))

        (defun decknix-context-list-issues ()
          "Show tracked issues in a completing-read picker."
          (interactive)
          (decknix--context-full-refresh)
          (let* ((issues (cl-remove-if-not
                          (lambda (i) (eq (plist-get (cdr i) :type) 'issue))
                          decknix--context-items))
                 (choices (mapcar (lambda (i)
                                   (format "%-12s %-6s %s"
                                           (car i)
                                           (or (plist-get (cdr i) :state) "?")
                                           (or (plist-get (cdr i) :title) "")))
                                 issues)))
            (if choices
                (let* ((choice (completing-read "Issue: " choices nil t))
                       (id (car (split-string (string-trim choice))))
                       (url (plist-get (cdr (assoc id decknix--context-items)) :url)))
                  (when url (browse-url url)))
              (message "No issues in context"))))

        (defun decknix-context-list-prs ()
          "Show tracked PRs in a completing-read picker."
          (interactive)
          (decknix--context-full-refresh)
          (let* ((prs (cl-remove-if-not
                       (lambda (i) (eq (plist-get (cdr i) :type) 'pr))
                       decknix--context-items))
                 (choices (mapcar (lambda (i)
                                   (format "%-12s %-6s %s"
                                           (car i)
                                           (or (plist-get (cdr i) :state) "?")
                                           (or (plist-get (cdr i) :title) "")))
                                 prs)))
            (if choices
                (let* ((choice (completing-read "PR: " choices nil t))
                       (id (car (split-string (string-trim choice))))
                       (url (plist-get (cdr (assoc id decknix--context-items)) :url)))
                  (when url (browse-url url)))
              (message "No PRs in context"))))

        (defun decknix-context-show-ci ()
          "Refresh and display CI status."
          (interactive)
          (decknix--context-fetch-ci)
          (decknix--context-update-header)
          (if decknix--context-ci
              (let ((st (plist-get decknix--context-ci :status))
                    (name (plist-get decknix--context-ci :name)))
                (message "CI: %s — %s"
                         (cond ((string= st "pass") "success")
                               ((string= st "fail") "FAILED")
                               ((string= st "running") "running...")
                               (t st))
                         (or name "unknown")))
            (message "No CI data available")))

        (defun decknix-context-show-reviews ()
          "Refresh and display PR review status."
          (interactive)
          (decknix--context-fetch-reviews)
          (decknix--context-update-header)
          (if decknix--context-reviews
              (message "Reviews: %d threads, %d unresolved"
                       (plist-get decknix--context-reviews :total)
                       (plist-get decknix--context-reviews :unresolved))
            (message "No open PRs in context")))

        ;; -- Global keybindings: C-c A i prefix --
        (define-prefix-command 'decknix-agent-context-map)
        (define-key decknix-agent-prefix-map (kbd "i") 'decknix-agent-context-map)
        (with-eval-after-load 'which-key
          (which-key-add-key-based-replacements "C-c A i" "Context"))
        (define-key decknix-agent-context-map (kbd "i") 'decknix-context-list-issues)
        (define-key decknix-agent-context-map (kbd "p") 'decknix-context-list-prs)
        (define-key decknix-agent-context-map (kbd "c") 'decknix-context-show-ci)
        (define-key decknix-agent-context-map (kbd "r") 'decknix-context-show-reviews)
        (define-key decknix-agent-context-map (kbd "a") 'decknix-context-pin)
        (define-key decknix-agent-context-map (kbd "d") 'decknix-context-unpin)
        (define-key decknix-agent-context-map (kbd "g") 'decknix-context-browse)
        (define-key decknix-agent-context-map (kbd "f") 'decknix-context-forge-visit)
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
                    ;; Keep prompt pinned to the bottom of the window
                    (setq-local comint-scroll-to-bottom-on-input t)
                    (setq-local comint-scroll-to-bottom-on-output t)
                    (setq-local comint-scroll-show-maximum-output t)
                    (local-set-key (kbd "TAB") 'yas-expand)
                    (local-set-key (kbd "<tab>") 'yas-expand)
                    ;; Buffer-local bindings — no C-c A prefix needed inside agent-shell.
                    ;; Native bindings: C-c C-c (interrupt), C-c C-v (model), C-c C-m (mode)
                    (local-set-key (kbd "C-c e") 'decknix-agent-compose)
                    (local-set-key (kbd "C-c ?") decknix-agent-help-map)
                    (local-set-key (kbd "C-c r") 'agent-shell-rename-buffer)
                    ;; C-c s — session sub-prefix
                    (let ((map (make-sparse-keymap)))
                      (define-key map (kbd "s") 'decknix-agent-session-picker)
                      (define-key map (kbd "q") 'decknix-agent-session-quit)
                      (define-key map (kbd "h") 'decknix-agent-session-history)
                      (define-key map (kbd "y") 'decknix-agent-session-copy-id)
                      (define-key map (kbd "d") 'decknix-agent-session-toggle-id-display)
                      (local-set-key (kbd "C-c s") map))
                    ;; Conditional bindings (may not be loaded)
                    (when (fboundp 'agent-shell-manager-toggle)
                      (local-set-key (kbd "C-c m") 'agent-shell-manager-toggle))
                    (when (fboundp 'agent-shell-workspace-toggle)
                      (local-set-key (kbd "C-c w") 'agent-shell-workspace-toggle))
                    (when (fboundp 'agent-shell-attention-jump)
                      (local-set-key (kbd "C-c j") 'agent-shell-attention-jump))
                    ;; C-c i — context sub-prefix in-buffer
                    (when (fboundp 'decknix-context-panel)
                      (let ((map (make-sparse-keymap)))
                        (define-key map (kbd "i") 'decknix-context-list-issues)
                        (define-key map (kbd "p") 'decknix-context-list-prs)
                        (define-key map (kbd "c") 'decknix-context-show-ci)
                        (define-key map (kbd "r") 'decknix-context-show-reviews)
                        (define-key map (kbd "a") 'decknix-context-pin)
                        (define-key map (kbd "d") 'decknix-context-unpin)
                        (define-key map (kbd "g") 'decknix-context-browse)
                        (define-key map (kbd "f") 'decknix-context-forge-visit)
                        (local-set-key (kbd "C-c i") map))
                      (local-set-key (kbd "C-c I") 'decknix-context-panel)
                      ;; Restore pinned items from previous session, then refresh
                      (decknix--context-restore)
                      (decknix--context-full-refresh)
                      (decknix--context-start-ci-polling))
                    ;; C-c t — template sub-prefix in-buffer
                    (when (fboundp 'yas-insert-snippet)
                      (let ((map (make-sparse-keymap)))
                        (define-key map (kbd "t") 'yas-insert-snippet)
                        (define-key map (kbd "n") 'yas-new-snippet)
                        (define-key map (kbd "e") 'yas-visit-snippet-file)
                        (local-set-key (kbd "C-c t") map)))
                    ;; C-c c — commands sub-prefix in-buffer
                    (let ((map (make-sparse-keymap)))
                      (define-key map (kbd "c") 'decknix-agent-command-run)
                      (define-key map (kbd "n") 'decknix-agent-command-new)
                      (define-key map (kbd "e") 'decknix-agent-command-edit)
                      (local-set-key (kbd "C-c c") map))
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
