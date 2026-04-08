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
  #
  # IMPORTANT: We take the source/recipe from unstable but rebuild using the
  # local emacsPackages (which uses the same Emacs as the daemon). This ensures
  # native-compiled .eln files match the running Emacs build hash, avoiding
  # JIT recompilation at startup.

  shell-maker = pkgs.emacsPackages.trivialBuild {
    pname = "shell-maker";
    version = pkgs.unstable.emacsPackages.shell-maker.version;
    src = pkgs.unstable.emacsPackages.shell-maker.src;
    packageRequires = with pkgs.emacsPackages; [ markdown-mode ];
  };

  acp = pkgs.emacsPackages.trivialBuild {
    pname = "acp";
    version = pkgs.unstable.emacsPackages.acp.version;
    src = pkgs.unstable.emacsPackages.acp.src;
  };

  agent-shell = pkgs.emacsPackages.trivialBuild {
    pname = "agent-shell";
    version = pkgs.unstable.emacsPackages.agent-shell.version;
    src = pkgs.unstable.emacsPackages.agent-shell.src;
    packageRequires = [ shell-maker acp ] ++ (with pkgs.emacsPackages; [ markdown-mode ]);
  };

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

  # == User-level augment guidelines ==
  # Deployed to ~/.augment-guidelines via home.file (as a symlink).
  # Provides default formatting/response rules for Augment agents.
  guidelinesFile = ".augment-guidelines";
  guidelinesContent = ''
    # Augment Agent Guidelines (User-level)

    ## Markdown Table Formatting

    When printing markdown tables in responses:

    1. **Expand columns** — pad every cell so columns are fully aligned and easy to scan. Do not use minimal-width columns.
    2. **Check terminal width** — if any row would exceed ~80 characters, do NOT use a table. Instead, use one of these readable alternatives:
       - **Definition list style** — one item per block with a bold heading and indented details:
         ```
         **#19 — Editor profile tiering**
           Category: Editors
           Effort:   Large
           Status:   Open
         ```
       - **Sectioned list style** — group items under headings:
         ```
         ### Open Issues
         - **#19** Editor profile tiering (Editors, Large)
         - **#26** Secrets management (Core, Medium)
         ```
    3. **Never let content wrap or truncate** — if a table cell contains long text (descriptions, URLs, paths), switch to a non-table format.
  '';

  # == Yasnippet prompt templates ==
  # Deployed to ~/.emacs.d/snippets/<mode>/ via home.file
  # Note: ''${ escapes Nix interpolation to produce literal ${ for yasnippet fields
  snippetDir = ".emacs.d/snippets/agent-shell-mode";
  batchSnippetDir = ".emacs.d/snippets/decknix-batch-compose-mode";

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

  # == Yasnippet templates for batch compose mode ==
  # Deployed to ~/.emacs.d/snippets/decknix-batch-compose-mode/ via home.file
  batchSnippets = {
    group = mkSnippet "group" "---" ''
      --- ''${1:group-name}''${2: : ''${3:~/Code/}}
      ''${0}'';

    pr = mkSnippet "PR URL" "pr" ''
      https://github.com/''${1:owner}/''${2:repo}/pull/''${3:number}''${0}'';
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
      # Batch compose snippets → ~/.emacs.d/snippets/decknix-batch-compose-mode/
      (optionalAttrs cfg.templates.enable
        (mapAttrs'
          (name: text: nameValuePair "${batchSnippetDir}/${name}" { inherit text; })
          batchSnippets))
      //
      # Auggie custom commands → ~/.augment/commands/
      (optionalAttrs cfg.commands.enable
        (mapAttrs'
          (name: text: nameValuePair "${commandDir}/${name}" { inherit text; })
          commands))
      //
      # User-level augment guidelines → ~/.augment-guidelines
      { "${guidelinesFile}".text = guidelinesContent; };
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
            "  C-c s n     New session (guided)\n"
            "  C-c s q     Quit session (saves automatically)\n"
            "  C-c s h     View history (C-u to pick any session)\n"
            "  C-c s y     Copy session ID (C-u for full ID)\n"
            "  C-c s d     Toggle short/full ID in header\n"
            "\n"

            (propertize "Input & Editing\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c e       Compose buffer (multi-line editor)\n"
            "  C-c E       Interrupt agent + open compose\n"
            "              In compose: C-c C-s toggle sticky/transient\n"
            "              In compose: C-c k k interrupt, C-c k C-c interrupt+submit\n"
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

            (propertize "Tags — session  (C-c T …)\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c T l     Show this session's tags\n"
            "  C-c T a     Add tag (select or create new)\n"
            "  C-c T r     Remove tag from this session\n"
            "\n"
            (propertize "Tags — global  (C-c A T …)\n" 'font-lock-face '(:weight bold))
            (propertize (make-string 40 ?─) 'font-lock-face 'font-lock-comment-face) "\n"
            "  C-c A T l   List / filter sessions by tag\n"
            "  C-c A T e   Rename a tag across all sessions\n"
            "  C-c A T d   Delete tag globally\n"
            "  C-c A T c   Cleanup orphaned tags\n"
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
            "  C-c A c r   Review PR (quick action)\n"
            "  C-c A c B   Batch process (multi-session)\n"
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
            "  In compose: C-c C-c submit, C-c C-k clear/close.\n"
            "  In compose: C-c C-s toggles sticky (stays open) / transient.\n"
            "  In compose: C-c k k interrupts the agent, C-c k C-c interrupts & submits.\n"
            "  In compose: M-p / M-n cycle session prompts; M-P / M-N cycle all sessions.\n"
            "  In compose: M-r search all prompts (consult fuzzy match).\n"
            "  Press C-c C-c to interrupt a running response.\n"
            "  Press C-c E to interrupt and open the compose buffer.\n"
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
            "  C-c T l shows this conversation's tags.\n"
            "  C-c T a adds a tag (select existing or type new).\n"
            "  C-c T r removes a tag from this conversation.\n"
            "  C-c A T l filters conversations by tag (global).\n"
            "  Tags apply to the conversation (all sessions sharing the same start).\n"
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
            "  C-c A g greps all session content (ripgrep).\n"
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
        ;; Register all C-c A sub-key descriptions with which-key.
        ;; Single consolidated block so which-key can display the full menu.
        (with-eval-after-load 'which-key
          (which-key-add-key-based-replacements
            "C-c A"   "Agent"
            "C-c A ?" "Help"
            "C-c A a" "start/switch"
            "C-c A n" "new session"
            "C-c A s" "session picker"
            "C-c A g" "grep sessions"
            "C-c A h" "history"
            "C-c A e" "compose"
            "C-c A T" "Tags (global)"
            "C-c A c" "Commands"
            "C-c A c r" "review PR"
            "C-c A c B" "batch process"
            "C-c A c c" "run command"
            "C-c A c n" "new command"
            "C-c A c e" "edit command"
            "C-c A t" "Templates"
            "C-c A i" "Context"
            "C-c A S" "MCP servers"
            "C-c A m" "manager"
            "C-c A w" "workspace"
            "C-c A j" "attention jump"
            "C-c A q" "quit session"
            "C-c A R" "rename session"
            "C-c A r" "recent sessions"))

        ;; Global keybindings under C-c A prefix
        ;; Only actions that make sense from OUTSIDE an agent-shell buffer.
        ;; Buffer-local bindings (C-c ...) handle in-buffer actions — no duplicates.
        (define-key decknix-agent-prefix-map (kbd "a") 'agent-shell)                      ; Start/switch to agent
        (define-key decknix-agent-prefix-map (kbd "n") 'decknix-agent-session-new)          ; New session (guided)
        (define-key decknix-agent-prefix-map (kbd "q") 'decknix-agent-session-quit)         ; Quit/close session
        (define-key decknix-agent-prefix-map (kbd "?") 'decknix-agent-help-map)           ; Help sub-prefix
        (define-key decknix-agent-help-map (kbd "k") 'decknix-agent-help-keys)            ; Keybindings
        (define-key decknix-agent-help-map (kbd "t") 'decknix-agent-help-tutorial)        ; Tutorial
        (define-key decknix-agent-help-map (kbd "f") 'decknix-agent-help-functions)       ; Functions/commands

        ;; == Session management: unified picker + clean quit ==

        ;; Buffer-local var to track the auggie CLI session ID
        ;; (distinct from ACP session ID in agent-shell--state)
        (defvar-local decknix--agent-auggie-session-id nil
          "The auggie CLI session ID for this buffer, if known.")

        ;; Buffer-local var to track the workspace root for this session
        (defvar-local decknix--agent-session-workspace nil
          "The workspace root directory for this agent session, if set.")

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

        ;; == Session history pre-population ==
        ;; When resuming a session via --resume, the buffer is empty.
        ;; This reads the local session JSON and inserts recent exchanges
        ;; so the user has context of what happened before.

        (defun decknix--agent-session-file (session-id)
          "Return the path to the local session JSON for SESSION-ID."
          (expand-file-name (concat session-id ".json")
                            (expand-file-name "sessions" "~/.augment")))

        (defun decknix--agent-session-extract-history (session-id n)
          "Extract the last N user-visible exchanges from SESSION-ID's local JSON.
Returns a list of (USER-MSG . ASSISTANT-RESP) cons cells, oldest first.
Uses the top-level request_message and response_text fields of each
exchange, which are the user-facing summary strings."
          (let ((file (decknix--agent-session-file session-id)))
            (when (file-exists-p file)
              (condition-case err
                  (let* ((json-array-type 'list)
                         (json-object-type 'alist)
                         (json-key-type 'symbol)
                         (data (json-read-file file))
                         (history (alist-get 'chatHistory data))
                         (exchanges nil)
                         (count 0))
                    ;; Walk backwards through chatHistory to find user exchanges
                    (let ((i (1- (length history))))
                      (while (and (>= i 0) (< count n))
                        (let* ((entry (nth i history))
                               (ex (alist-get 'exchange entry))
                               (user-msg (alist-get 'request_message ex ""))
                               (resp-text (alist-get 'response_text ex "")))
                          ;; Only count exchanges with a non-empty user message
                          (when (and (stringp user-msg)
                                     (not (string-empty-p (string-trim user-msg))))
                            (push (cons user-msg resp-text) exchanges)
                            (setq count (1+ count))))
                        (setq i (1- i))))
                    exchanges)
                (error
                 (message "Failed to read session history: %s"
                          (error-message-string err))
                 nil)))))

        (defun decknix--agent-context-toggle ()
          "Toggle the visibility of the Context history section.
Switches between ▶ (collapsed) and ▼ (expanded)."
          (interactive)
          (let* ((inhibit-read-only t)
                 ;; Find the body region tagged with our symbol
                 (body-start (next-single-property-change
                              (point-min) 'decknix-context-body))
                 (body-end (when body-start
                             (next-single-property-change
                              body-start 'decknix-context-body))))
            (when (and body-start body-end)
              (let ((currently-hidden (get-text-property body-start 'invisible)))
                ;; Toggle invisible
                (put-text-property body-start body-end
                                  'invisible (not currently-hidden))
                ;; Swap the arrow in the header
                (save-excursion
                  (goto-char (point-min))
                  (when (re-search-forward "[▼▶]" body-start t)
                    (replace-match (if currently-hidden "▼" "▶"))))))))

        (defvar decknix--agent-context-header-map
          (let ((map (make-sparse-keymap)))
            (define-key map [mouse-1] #'decknix--agent-context-toggle)
            (define-key map (kbd "TAB") #'decknix--agent-context-toggle)
            (define-key map (kbd "RET") #'decknix--agent-context-toggle)
            map)
          "Keymap for the Context section header toggle.")

        (defun decknix--agent-session-prepopulate (session-id n)
          "Insert a collapsible Context section with the last N exchanges.
Inserts just before the prompt, matching the ▶/▼ toggle style of
agent-shell's built-in sections (Notices, Agent capabilities, etc.).
User messages shown in `font-lock-keyword-face', assistant responses
in `font-lock-doc-face'.  Section is expanded by default."
          (let ((exchanges (decknix--agent-session-extract-history session-id n)))
            (when exchanges
              (let ((inhibit-read-only t))
                (save-excursion
                  ;; Find the prompt — search backwards from end
                  (goto-char (point-max))
                  (let ((prompt-pos
                         (when (bound-and-true-p comint-prompt-regexp)
                           (re-search-backward comint-prompt-regexp nil t))))
                    (if prompt-pos
                        (goto-char prompt-pos)
                      ;; Fallback: insert before point-max
                      (goto-char (point-max))))
                  ;; Move to start of the prompt line
                  (beginning-of-line)
                  (let ((insert-pos (point)))
                    ;; Header: ▼ Context (N exchanges) — clickable/TAB-able
                    (insert (propertize
                             (format "▼ %s\n"
                                     (propertize
                                      (format "Context (%d exchange%s)"
                                              (length exchanges)
                                              (if (= (length exchanges) 1) "" "s"))
                                      'font-lock-face 'font-lock-doc-markup-face))
                             'read-only t
                             'rear-nonsticky t
                             'keymap decknix--agent-context-header-map))
                    ;; Body: exchanges with invisible toggling
                    (let ((body-start (point)))
                      (dolist (ex exchanges)
                        (let ((user (car ex))
                              (resp (cdr ex)))
                          ;; User message
                          (insert (propertize
                                   (format "\n❯ %s\n"
                                           (truncate-string-to-width
                                            user 500 nil nil "..."))
                                   'font-lock-face 'font-lock-keyword-face
                                   'read-only t
                                   'rear-nonsticky t))
                          ;; Assistant response
                          (when (and resp (not (string-empty-p resp)))
                            (insert (propertize
                                     (format "\n%s\n"
                                             (truncate-string-to-width
                                              resp 2000 nil nil
                                              "\n[...truncated]"))
                                     'font-lock-face 'font-lock-doc-face
                                     'read-only t
                                     'rear-nonsticky t)))))
                      (insert (propertize "\n" 'read-only t 'rear-nonsticky t))
                      ;; Tag the body region for toggling
                      (put-text-property body-start (point)
                                         'decknix-context-body t))))))))

        (defun decknix--agent-unsorted-table (candidates)
          "Wrap CANDIDATES in a completion table that preserves list order.
Prevents vertico/orderless from re-sorting alphabetically.
Uses eval with lexical-binding to create a proper closure
since default.el is evaluated under dynamic binding."
          (eval
           `(let ((cands ',candidates))
              (lambda (string pred action)
                (if (eq action 'metadata)
                    '(metadata (display-sort-function . identity)
                               (cycle-sort-function . identity))
                  (complete-with-action action cands string pred))))
           t))

        ;; -- Session list caching --
        ;; Reads session files directly from ~/.augment/sessions/ using
        ;; jq for metadata extraction. This is ~6x faster than `auggie
        ;; session list` which loads full chat history and emits terminal
        ;; escape codes that break async process output.

        (defvar decknix--agent-session-cache nil
          "Cached list of auggie sessions (alists).")

        (defvar decknix--agent-session-cache-time 0
          "Time when session cache was last updated (float-time).")

        (defvar decknix--agent-session-cache-ttl 120
          "Seconds before session cache is considered stale.")

        (defvar decknix--agent-session-refresh-proc nil
          "Process handle for async session list refresh.")

        (defvar decknix--agent-sessions-dir
          (expand-file-name "~/.augment/sessions")
          "Directory containing auggie session JSON files.")

        (defun decknix--agent-session-list ()
          "Return cached auggie sessions, refreshing async if stale.
On first call (empty cache), falls back to a synchronous fetch."
          (when (and (null decknix--agent-session-cache)
                     (= decknix--agent-session-cache-time 0))
            ;; First call ever: synchronous fetch so picker has data
            (decknix--agent-session-refresh-sync))
          ;; Trigger async refresh if stale
          (when (> (- (float-time) decknix--agent-session-cache-time)
                   decknix--agent-session-cache-ttl)
            (decknix--agent-session-refresh-async))
          decknix--agent-session-cache)

        (defvar decknix--agent-session-jq-filter-file nil
          "Path to temp file containing the jq filter for session extraction.")

        (defun decknix--agent-session-ensure-jq-filter ()
          "Create the jq filter file if it doesn't exist. Return its path."
          (unless (and decknix--agent-session-jq-filter-file
                      (file-exists-p decknix--agent-session-jq-filter-file))
            (setq decknix--agent-session-jq-filter-file
                  (make-temp-file "auggie-session-" nil ".jq"))
            (with-temp-file decknix--agent-session-jq-filter-file
              ;; Use try//default for chatHistory operations so that
              ;; files being actively written (mid-write parse errors)
              ;; still produce partial results instead of being silently
              ;; dropped from the session list.
              ;; Skip MCP startup errors when extracting firstUserMessage —
              ;; find the first real user message instead.
              (insert "{sessionId, created, modified,"
                      " exchangeCount: (try (.chatHistory | length) // 0),"
                      " firstUserMessage:"
                      " (try (first(.chatHistory[]"
                      " | .exchange.request_message"
                      " | select(. != null)"
                      " | select(startswith(\"\\u26a0\") | not)"
                      " | select(length > 0))[:200])"
                      " // \"\")}\n")))
          decknix--agent-session-jq-filter-file)

        (defun decknix--agent-session-jq-cmd ()
          "Shell command to extract session metadata directly from files.
Extracts only the fields needed for the picker via parallel jq,
then sorts by modified time (newest first)."
          (let ((jqf (decknix--agent-session-ensure-jq-filter)))
            (concat
             "find " (shell-quote-argument decknix--agent-sessions-dir)
             " -maxdepth 1 -name '*.json' -print0 2>/dev/null"
             " | xargs -0 -P8 -I{} jq -Mc -f "
             (shell-quote-argument jqf)
             " {} 2>/dev/null"
             " | jq -Msc 'sort_by(.modified) | reverse'")))

        (defun decknix--agent-session-parse (raw)
          "Parse RAW json string into session alists.
Handles process output that may contain trailing text after the JSON array."
          (condition-case nil
              (let* ((json-array-type 'list)
                     (json-object-type 'alist)
                     (json-key-type 'symbol)
                     (trimmed (string-trim raw))
                     ;; Process buffers append 'Process ... finished' — find last ']'
                     (end (when (string-prefix-p "[" trimmed)
                            (1+ (or (cl-position ?\] trimmed :from-end t) -1))))
                     (json-str (when (and end (> end 1))
                                 (substring trimmed 0 end))))
                (when json-str
                  (json-read-from-string json-str)))
            (error nil)))

        (defun decknix--agent-session-refresh-sync ()
          "Synchronous session list fetch (used on first call only)."
          (let ((result (decknix--agent-session-parse
                         (shell-command-to-string
                          (decknix--agent-session-jq-cmd)))))
            (setq decknix--agent-session-cache result
                  decknix--agent-session-cache-time (float-time))))

        (defun decknix--agent-session-refresh-async ()
          "Refresh session cache asynchronously without blocking."
          (when (or (null decknix--agent-session-refresh-proc)
                    (not (process-live-p decknix--agent-session-refresh-proc)))
            (let ((buf (generate-new-buffer " *auggie-session-list*")))
              (setq decknix--agent-session-refresh-proc
                    (start-process-shell-command
                     "auggie-session-list" buf
                     (decknix--agent-session-jq-cmd)))
              (set-process-sentinel
               decknix--agent-session-refresh-proc
               (eval
                `(lambda (proc _event)
                   (when (eq (process-status proc) 'exit)
                     (let ((pbuf (process-buffer proc)))
                       (when (buffer-live-p pbuf)
                         (let ((result (decknix--agent-session-parse
                                        (with-current-buffer pbuf
                                          (buffer-string)))))
                           (when result
                             (setq decknix--agent-session-cache result
                                   decknix--agent-session-cache-time
                                   (float-time))))
                         (kill-buffer pbuf)))))
                t)))))

        ;; Pre-fetch session list shortly after daemon starts
        (run-at-time 3 nil #'decknix--agent-session-refresh-async)

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

        (defvar decknix-agent-session-history-count 2
          "Default number of recent exchanges to show when resuming a session.
Use C-u prefix with the session picker to override.")

        (defun decknix--agent-find-new-shell-buffer (before-buffers)
          "Find the agent-shell buffer that was created after BEFORE-BUFFERS snapshot.
Returns the new buffer, or nil if not found."
          (seq-find (lambda (buf)
                      (and (buffer-live-p buf)
                           (not (memq buf before-buffers))
                           (with-current-buffer buf
                             (derived-mode-p 'agent-shell-mode))))
                    (buffer-list)))

        (defun decknix--agent-session-display-name (session)
          "Derive a short buffer display name from SESSION data.
Uses tags if available, otherwise truncates the first user message."
          (let* ((sid (alist-get 'sessionId session ""))
                 (first-msg (alist-get 'firstUserMessage session ""))
                 (conv-key (decknix--agent-conversation-key first-msg))
                 (tags (when conv-key (decknix--agent-tags-for-conv-key conv-key)))
                 (preview (car (split-string first-msg "\n" t))))
            (cond
             ;; If there are tags, use them as the name
             (tags (string-join tags "/"))
             ;; Otherwise use a truncated preview of the first message
             ((and preview (not (string-empty-p preview)))
              (truncate-string-to-width preview 40 nil nil "..."))
             ;; Fallback to session ID prefix
             (t (substring sid 0 (min 8 (length sid)))))))

        (defun decknix--agent-session-resume (session-id history-count
                                              &optional display-name workspace
                                              conv-key)
          "Resume SESSION-ID and pre-populate buffer with HISTORY-COUNT exchanges.
DISPLAY-NAME, if provided, is used to rename the buffer to *Auggie: NAME*.
WORKSPACE, if provided, sets --workspace-root and default-directory so the
agent operates in the original project directory.
CONV-KEY, if provided, is used to register the new session-id under the
existing conversation entry in the tag store."
          ;; Invalidate cache so next picker invocation fetches fresh data
          (setq decknix--agent-session-cache-time 0)
          ;; Snapshot existing buffers so we can detect the new one
          (let* ((resume-args (list "--resume" session-id))
                 (ws-args (when (and workspace (file-directory-p workspace))
                            (list "--workspace-root" workspace)))
                 (before-buffers (buffer-list))
                 (agent-shell-auggie-acp-command
                  (append agent-shell-auggie-acp-command ws-args resume-args)))
            ;; Set default-directory so agent-shell-cwd picks up the workspace
            (let ((default-directory (if (and workspace
                                              (file-directory-p workspace))
                                         workspace
                                       default-directory)))
              (agent-shell-start
               :config (agent-shell-auggie-make-agent-config)))
            ;; agent-shell-start is async — it doesn't switch current-buffer.
            ;; Use a timer to find the new buffer, rename it, and prepopulate.
            (let ((sid session-id)
                  (n history-count)
                  (bufs before-buffers)
                  (bname display-name)
                  (ws workspace)
                  (ck conv-key))
              ;; Register new session-id under the conversation immediately
              ;; so it appears in the session picker even before the buffer
              ;; is fully set up.
              (when ck
                (decknix--agent-register-session-id ck sid)
                ;; Bump recency so the conversation sorts to the top
                (decknix--agent-conv-touch ck))
              (run-at-time
               1.5 nil
               (eval
                `(lambda ()
                   (let ((shell-buf (decknix--agent-find-new-shell-buffer ',bufs)))
                     (if shell-buf
                         (with-current-buffer shell-buf
                           (setq-local decknix--agent-auggie-session-id ,sid)
                           ;; Restore workspace for the session picker display
                           (when ,ws
                             (setq-local decknix--agent-session-workspace ,ws))
                           ;; Rename buffer to match conversation identity
                           (when ,bname
                             (rename-buffer
                              (generate-new-buffer-name
                               (format "*Auggie: %s*" ,bname)))
                             (setq-local shell-maker--buffer-name-override
                                         (buffer-name)))
                           (decknix--agent-session-prepopulate ,sid ,n))
                       (message "Could not find agent-shell buffer for session %s"
                                (substring ,sid 0 8)))))
                t)))))

        (defun decknix--agent-session-group-by-conversation (sessions)
          "Group SESSIONS by conversation (shared firstUserMessage).
Returns a list of (CONV-KEY LATEST-SESSION ALL-SESSIONS) triples,
sorted by most recently interacted first.

Inter-group sort uses max(session.modified, conversation.lastAccessed)
so that tag/rename/resume operations bump a conversation to the top,
not just augment writing to the session file."
          (let ((groups (make-hash-table :test 'equal)))
            (dolist (s sessions)
              (let* ((first-msg (alist-get 'firstUserMessage s ""))
                     (conv-key (decknix--agent-conversation-key first-msg)))
                (when conv-key
                  (let ((existing (gethash conv-key groups)))
                    (puthash conv-key (cons s existing) groups)))))
            ;; Build result: (conv-key latest-session all-sessions)
            (let (result)
              (maphash (lambda (key sessions-list)
                         (let ((sorted (sort (copy-sequence sessions-list)
                                            (lambda (a b)
                                              (string> (or (alist-get 'modified a) "")
                                                       (or (alist-get 'modified b) ""))))))
                           (push (list key (car sorted) sorted) result)))
                       groups)
              ;; Sort by max(session.modified, lastAccessed) — any interaction
              ;; with a conversation (tagging, renaming, resuming) counts.
              (sort result (lambda (a b)
                             (let* ((mod-a (or (alist-get 'modified (cadr a)) ""))
                                    (mod-b (or (alist-get 'modified (cadr b)) ""))
                                    (acc-a (or (decknix--agent-conv-last-accessed (car a)) ""))
                                    (acc-b (or (decknix--agent-conv-last-accessed (car b)) ""))
                                    (eff-a (if (string> acc-a mod-a) acc-a mod-a))
                                    (eff-b (if (string> acc-b mod-b) acc-b mod-b)))
                               (string> eff-a eff-b)))))))

        (defun decknix--agent-conversation-preview (conv-group)
          "Format a one-line preview for a conversation CONV-GROUP.
CONV-GROUP is (CONV-KEY LATEST-SESSION ALL-SESSIONS)."
          (let* ((conv-key (car conv-group))
                 (latest (cadr conv-group))
                 (all (caddr conv-group))
                 (session-count (length all))
                 (id (alist-get 'sessionId latest))
                 (modified (alist-get 'modified latest))
                 (exchanges (alist-get 'exchangeCount latest 0))
                 (first-msg (alist-get 'firstUserMessage latest ""))
                 (preview (car (split-string first-msg "\n" t)))
                 (tags (decknix--agent-tags-for-conv-key conv-key))
                 (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
                 (count-str (if (> session-count 1)
                                (format " (%d sessions)" session-count)
                              ""))
                 (truncated (truncate-string-to-width (or preview "") 50 nil nil "...")))
            (format "%-8s  %-8s  %4dx  %s%s%s"
                    (substring id 0 (min 8 (length id)))
                    (if modified (decknix--agent-session-time-ago modified) "?")
                    exchanges
                    truncated
                    tag-str
                    count-str)))

        ;; ── Session picker (consult--multi) ──────────────────────────
        ;; Modelled after C-x b (consult-buffer): sectioned groups with
        ;; horizontal dividers — Live Sessions → Saved Sessions → New.

        (defun decknix--agent-session-live-label (buf)
          "Build a display label for live agent-shell buffer BUF."
          (let* ((ws (buffer-local-value
                      'decknix--agent-session-workspace buf))
                 (ws-short (when ws
                             (file-name-nondirectory
                              (directory-file-name ws))))
                 (tags (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (when (and (boundp 'decknix--agent-auggie-session-id)
                                      decknix--agent-auggie-session-id)
                             (decknix--agent-tags-for-session
                              decknix--agent-auggie-session-id)))))
                 (tag-str (when tags
                            (mapconcat (lambda (tg) (format "#%s" tg))
                                       tags " ")))
                 (detail (string-join (delq nil (list ws-short tag-str)) "  ")))
            (format "%s%s"
                    (buffer-name buf)
                    (if (string-empty-p detail) ""
                      (format "  — %s" detail)))))

        ;; We store a hash-table mapping candidate strings → payloads so that
        ;; each source's :action can look up the data for the selected string.
        (defvar decknix--session-picker-live-map nil
          "Candidate-string → buffer map for live source.")
        (defvar decknix--session-picker-saved-map nil
          "Candidate-string → session alist for saved source.")
        (defvar decknix--session-picker-expand nil
          "Non-nil shows all snapshots instead of collapsed conversations.")

        (defvar decknix--session-source-live
          (list :name     "Live Sessions"
                :narrow   ?l
                :category 'agent-session-live
                :face     'consult-buffer
                :items
                (lambda ()
                  (let* ((bufs (when (fboundp 'agent-shell-buffers)
                                 (agent-shell-buffers)))
                         ;; Exclude the current buffer — you're already in it.
                         ;; Most-recently-used ordering is preserved from
                         ;; agent-shell-buffers (which follows buffer-list order).
                         (cur (current-buffer))
                         (others (remq cur bufs))
                         (ht (make-hash-table :test 'equal))
                         (ordered nil))
                    (dolist (buf others)
                      (let ((key (decknix--agent-session-live-label buf)))
                        (puthash key buf ht)
                        (push key ordered)))
                    (setq decknix--session-picker-live-map ht)
                    ;; Preserve MRU buffer-list order (push reverses, nreverse restores)
                    (nreverse ordered)))
                :action
                (lambda (cand)
                  (when cand
                    (let ((buf (gethash cand decknix--session-picker-live-map)))
                      (when (and buf (buffer-live-p buf))
                        (switch-to-buffer buf))))))
          "Consult multi-source for live agent-shell buffers.")

        (defvar decknix--session-source-saved
          (list :name     "Saved Sessions"
                :narrow   ?s
                :category 'agent-session-saved
                :face     'consult-file
                :items
                (lambda ()
                  (let* ((sessions (decknix--agent-session-list))
                         (ht (make-hash-table :test 'equal))
                         (ordered nil))
                    (if decknix--session-picker-expand
                        ;; Expanded: all individual sessions (already newest-first)
                        ;; Pre-resolve workspace so :action doesn't need to
                        ;; re-derive conv-key (which can fail on large files).
                        (dolist (session sessions)
                          (let* ((first-msg (alist-get 'firstUserMessage session ""))
                                 (conv-key (decknix--agent-conversation-key first-msg))
                                 (workspace (when conv-key
                                              (decknix--agent-workspace-for-conv-key
                                               conv-key)))
                                 (entry (if workspace
                                            (cons (cons '__workspace workspace)
                                                  session)
                                          session))
                                 (key (decknix--agent-session-preview session)))
                            (puthash key entry ht)
                            (push key ordered)))
                      ;; Collapsed: one entry per conversation (default).
                      ;; group-by-conversation already computes conv-keys
                      ;; for grouping — reuse them to pre-resolve workspace.
                      (let ((groups (decknix--agent-session-group-by-conversation
                                    sessions)))
                        (dolist (group groups)
                          (let* ((conv-key (car group))
                                 (latest (cadr group))
                                 (workspace (when conv-key
                                              (decknix--agent-workspace-for-conv-key
                                               conv-key)))
                                 (entry (if workspace
                                            (cons (cons '__workspace workspace)
                                                  latest)
                                          latest))
                                 (key (decknix--agent-conversation-preview group)))
                            (puthash key entry ht)
                            (push key ordered)))))
                    (setq decknix--session-picker-saved-map ht)
                    ;; Return in newest-first order (push reverses, so nreverse)
                    (nreverse ordered)))
                :action
                (lambda (cand)
                  (when cand
                    (let* ((session (gethash cand decknix--session-picker-saved-map))
                           ;; Workspace was pre-resolved during :items
                           (workspace (alist-get '__workspace session)))
                      (when session
                        (let ((conv-key (decknix--agent-conversation-key
                                        (alist-get 'firstUserMessage
                                                   session ""))))
                          ;; If no stored workspace, prompt the user so the
                          ;; session opens in the right directory.
                          (unless workspace
                            (setq workspace
                                  (read-directory-name
                                   "Workspace for this session: "
                                   nil nil t))
                            ;; Persist for future resumes (best-effort)
                            (when (and conv-key workspace)
                              (decknix--agent-session-save-workspace-for-conv-key
                               conv-key workspace)))
                          (decknix--agent-session-resume
                           (alist-get 'sessionId session)
                           decknix-agent-session-history-count
                           (decknix--agent-session-display-name session)
                           workspace conv-key)))))))
          "Consult multi-source for saved auggie sessions.")

        (defvar decknix--session-source-new
          (list :name     "New"
                :narrow   ?n
                :category 'agent-session-new
                :face     'consult-bookmark
                :items    (lambda () (list "Start a new auggie session…"))
                :action   (lambda (_cand)
                            (decknix-agent-session-new)))
          "Consult multi-source for starting a new session.")

        (defun decknix-agent-session-picker (arg)
          "Pick from live agent-shell buffers and saved auggie sessions.
Sections are separated by dividers (like `consult-buffer' / C-x b):
  Live Sessions  — currently running agent buffers (most recent first)
  Saved Sessions — past conversations from ~/.augment/sessions
  New            — start a new session (fallback)

By default, saved sessions are collapsed by conversation.
With \\[universal-argument], shows all individual session snapshots."
          (interactive "P")
          (require 'consult)
          (setq decknix--session-picker-expand arg)
          (consult--multi (list decknix--session-source-live
                               decknix--session-source-saved
                               decknix--session-source-new)
                          :prompt (format "Agent session%s: "
                                          (if arg " (all snapshots)" ""))
                          :sort nil))

        ;; == Session grep: consult + ripgrep full-text search ==
        ;; Searches ALL content (user messages, agent responses, code blocks)
        ;; across every session JSON file using ripgrep.
        ;; C-c A g — type a search term, results narrow live.

        (defun decknix--agent-session-rg-search (term)
          "Search session files for TERM using ripgrep.
Returns a list of session alists for files containing TERM.
Uses rg -li for fast case-insensitive file matching, then
extracts metadata with jq for the matching files.

Uses `make-process' + `accept-process-output' instead of
`shell-command-to-string' so Emacs remains responsive to input.
This lets consult's `while-no-input' interrupt the search if the
user types more characters, preventing the cursor-freeze / [quit]
issue."
          (let* ((jqf (decknix--agent-session-ensure-jq-filter))
                 (sessions-dir (shell-quote-argument
                                (expand-file-name "sessions" "~/.augment")))
                 (cmd (format "%s -li %s %s 2>/dev/null | xargs jq -Mc -f %s 2>/dev/null | jq -Msc 'sort_by(.modified) | reverse'"
                              (or (executable-find "rg") "rg")
                              (shell-quote-argument term)
                              sessions-dir
                              (shell-quote-argument jqf)))
                 (output "")
                 (proc (make-process
                        :name "agent-grep-rg"
                        :buffer nil
                        :command (list "sh" "-c" cmd)
                        :noquery t
                        :connection-type 'pipe
                        :filter (lambda (_p o)
                                  (setq output (concat output o))))))
            ;; Yield to Emacs event loop between output chunks.
            ;; accept-process-output with a small timeout lets
            ;; while-no-input (used by consult) interrupt us if the
            ;; user types more characters — no more cursor freeze.
            (while (process-live-p proc)
              (accept-process-output proc 0.03))
            ;; Collect any trailing output
            (accept-process-output proc 0)
            (decknix--agent-session-parse output)))

        (defun decknix--agent-session-grep-candidate (session)
          "Build a candidate string for SESSION in grep results."
          (let* ((id (alist-get 'sessionId session))
                 (modified (alist-get 'modified session))
                 (exchanges (alist-get 'exchangeCount session 0))
                 (first-msg (alist-get 'firstUserMessage session ""))
                 (preview (car (split-string first-msg "\n" t)))
                 (tags (decknix--agent-tags-for-session id))
                 (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
                 (time-ago (if modified
                               (decknix--agent-session-time-ago modified)
                             "?"))
                 (msg-preview (truncate-string-to-width
                               (or preview "") 80 nil nil "...")))
            (format "%-8s  %-8s  %4dx%s  %s"
                    (substring id 0 (min 8 (length id)))
                    time-ago exchanges tag-str msg-preview)))

        (defun decknix--agent-session-grep-build-entries (sessions expand)
          "Build candidate entries from SESSIONS for grep results.
If EXPAND is non-nil, show all individual sessions.
Otherwise collapse by conversation."
          (if expand
              (mapcar (lambda (session)
                        (cons (decknix--agent-session-grep-candidate session)
                              (cons 'session session)))
                      sessions)
            (let ((conv-groups
                   (decknix--agent-session-group-by-conversation sessions)))
              (mapcar (lambda (group)
                        (let* ((conv-key (car group))
                               (latest (cadr group))
                               (all (caddr group))
                               (session-count (length all))
                               (id (alist-get 'sessionId latest))
                               (modified (alist-get 'modified latest))
                               (exchanges (alist-get 'exchangeCount latest 0))
                               (first-msg (alist-get 'firstUserMessage latest ""))
                               (preview (car (split-string first-msg "\n" t)))
                               (tags (decknix--agent-tags-for-conv-key conv-key))
                               (tag-str (if tags (format " [%s]" (string-join tags ", ")) ""))
                               (count-str (if (> session-count 1)
                                              (format " (%d sessions)" session-count)
                                            ""))
                               (time-ago (if modified
                                             (decknix--agent-session-time-ago modified)
                                           "?"))
                               (msg-preview (truncate-string-to-width
                                             (or preview "") 80 nil nil "...")))
                          (cons (format "%-8s  %-8s  %4dx%s%s  %s"
                                        (substring id 0 (min 8 (length id)))
                                        time-ago exchanges tag-str count-str
                                        msg-preview)
                                (cons 'session latest))))
                      conv-groups))))

        (defun decknix-agent-session-grep (arg)
          "Full-text grep across all session content using consult + ripgrep.
Type a search term and ripgrep searches ALL user messages, agent
responses, and code blocks in every session file (~1s for 200+ sessions).
Results narrow live as you type.

By default shows conversation-collapsed results (one per conversation).
With \\\\[universal-argument], shows all individual session snapshots."
          (interactive "P")
          (require 'consult)
          (let* ((expand arg)
                 ;; entries-cache: alist mapping candidate-string → (session . session-data)
                 ;; Rebuilt on each rg invocation; used for lookup after selection.
                 (entries-cache nil)
                 (selected
                  (consult--read
                   (consult--dynamic-collection
                     (eval
                      `(lambda (input)
                         (cond
                          ((or (null input) (< (length (string-trim input)) 2))
                           nil)
                          (t
                           (condition-case nil
                               (let* ((matches (decknix--agent-session-rg-search input))
                                      (entries (when matches
                                                 (decknix--agent-session-grep-build-entries
                                                  matches ,expand))))
                                 (setq entries-cache entries)
                                 (mapcar #'car entries))
                             (error nil)))))
                      t)
                     :min-input 2)
                   :prompt "Grep sessions: "
                   :sort nil
                   :require-match t))
                 (chosen (cdr (assoc selected entries-cache))))
            (when chosen
              (let* ((s (cdr chosen))
                     (first-msg (alist-get 'firstUserMessage s ""))
                     (conv-key (decknix--agent-conversation-key first-msg))
                     (workspace (when conv-key
                                  (decknix--agent-workspace-for-conv-key
                                   conv-key))))
                (unless workspace
                  (setq workspace
                        (read-directory-name
                         "Workspace for this session: " nil nil t))
                  (when (and conv-key workspace)
                    (decknix--agent-session-save-workspace-for-conv-key
                     conv-key workspace)))
                (decknix--agent-session-resume
                 (alist-get 'sessionId s)
                 decknix-agent-session-history-count
                 (decknix--agent-session-display-name s)
                 workspace conv-key)))))

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
  1. Saved workspaces in agent-sessions.json whose path ends in REPO
  2. Known workspace roots (`decknix-agent-workspace-roots') containing REPO
  3. Current project root
  4. `default-directory'"
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
           ;; 2. Check known workspace roots for REPO subdir
           (cl-loop for root in decknix-agent-workspace-roots
                    for candidate = (expand-file-name repo root)
                    when (file-directory-p candidate)
                    return (file-name-as-directory candidate))
           ;; 3. Current project root
           (when (fboundp 'project-root)
             (when-let ((proj (project-current)))
               (project-root proj)))
           ;; 4. Fallback
           default-directory))

        (defun decknix--agent-detect-branch (dir)
          "Detect the current git branch in DIR, or nil."
          (let ((default-directory dir))
            (let ((branch (string-trim
                           (shell-command-to-string
                            "git rev-parse --abbrev-ref HEAD 2>/dev/null"))))
              (unless (or (string-empty-p branch)
                          (string= branch "HEAD"))
                branch))))

        (defun decknix--agent-session-tags-for (session-id tags)
          "Apply TAGS (list of strings) to SESSION-ID in the tag store.
Looks up the conversation key for SESSION-ID and stores tags under it.
Falls back to v1 format (session-id keyed) if conv-key is not yet available."
          (when (and session-id tags)
            (let* ((conv-key (decknix--agent-conversation-key-for-session
                              session-id))
                   (store (decknix--agent-tags-read)))
              (if conv-key
                  ;; v2: store under conversations
                  (let* ((convs (decknix--agent-tags-conversations store))
                         (entry (or (gethash conv-key convs)
                                    (let ((h (make-hash-table :test 'equal)))
                                      (puthash "sessions" nil h)
                                      h))))
                    (puthash "tags" tags entry)
                    (let ((sids (gethash "sessions" entry)))
                      (cl-pushnew session-id sids :test #'string=)
                      (puthash "sessions" sids entry))
                    (puthash conv-key entry convs)
                    (decknix--agent-tags-write store))
                ;; v1 fallback: session-keyed (migration will fix later)
                (let ((entry (make-hash-table :test 'equal)))
                  (puthash "tags" tags entry)
                  (puthash session-id entry store)
                  (decknix--agent-tags-write store))))))

        (defun decknix--agent-store-metadata-by-conv-key (conv-key tags workspace)
          "Store TAGS and WORKSPACE directly under CONV-KEY in the tag store.
Use this when the conversation key is known at creation time (e.g., quickactions
where the first message is the command itself)."
          (when conv-key
            (let* ((store (decknix--agent-tags-read))
                   (convs (decknix--agent-tags-conversations store))
                   (entry (or (gethash conv-key convs)
                              (let ((h (make-hash-table :test 'equal)))
                                (puthash "sessions" nil h)
                                h))))
              (when tags
                (let ((existing (gethash "tags" entry)))
                  (dolist (tag tags)
                    (cl-pushnew tag existing :test #'string=))
                  (puthash "tags" existing entry)))
              (when workspace
                (puthash "workspace" workspace entry))
              ;; Bump recency
              (puthash "lastAccessed"
                       (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry)
              (puthash conv-key entry convs)
              (decknix--agent-tags-write store))))

        (defun decknix--agent-register-session-id (conv-key session-id)
          "Ensure SESSION-ID is in the sessions list for CONV-KEY.
This keeps all session snapshots (original + resumed) linked to
the same conversation."
          (when (and conv-key session-id)
            (let* ((store (decknix--agent-tags-read))
                   (convs (decknix--agent-tags-conversations store))
                   (entry (gethash conv-key convs)))
              (when entry
                (let ((sids (gethash "sessions" entry)))
                  (unless (and sids (member session-id sids))
                    (puthash "sessions"
                             (cons session-id (or sids '()))
                             entry)
                    (decknix--agent-tags-write store)))))))

        (defun decknix-agent-session-new (&optional quick)
          "Start a new agent session with guided setup.
Prompts for workspace directory, session name, and initial tags.

With prefix argument QUICK, skip prompts and use defaults:
workspace = project root, name = auto-generated, no tags."
          (interactive "P")
          (let* ((default-ws (decknix--agent-detect-workspace))
                 (workspace (if quick default-ws
                              (read-directory-name "Workspace: " default-ws nil t)))
                 (workspace (expand-file-name workspace))
                 (dir-name (file-name-nondirectory
                            (directory-file-name workspace)))
                 (branch (decknix--agent-detect-branch workspace))
                 (default-name (if branch
                                   (format "%s/%s" dir-name branch)
                                 dir-name))
                 (name (if quick default-name
                         (read-string (format "Session name [%s]: " default-name)
                                      nil nil default-name)))
                 (tags (unless quick
                         (let ((input (completing-read-multiple
                                       "Tags (comma-separated): "
                                       (decknix--agent-tags-all)
                                       nil nil)))
                           (mapcar #'string-trim
                                   (seq-remove #'string-empty-p input)))))
                 (before-buffers (buffer-list))
                 ;; Build an augmented command with --workspace-root.
                 ;; We must capture this in a closure rather than using a let-binding
                 ;; of agent-shell-auggie-acp-command, because the :client-maker
                 ;; lambda is stored in agent-shell--state and called later
                 ;; (when the first message is sent) — by which time a dynamic
                 ;; let-binding would have expired.
                 (augmented-cmd
                  (append agent-shell-auggie-acp-command
                          (list "--workspace-root" workspace)))
                 ;; Create config with a client-maker that closes over augmented-cmd.
                 ;; eval+backquote is needed because default.el uses dynamic binding.
                 (config
                  (let ((base (agent-shell-auggie-make-agent-config)))
                    (setf (alist-get :client-maker base)
                          (eval `(lambda (buffer)
                                   (agent-shell--make-acp-client
                                    :command ,(car augmented-cmd)
                                    :command-params ',(cdr augmented-cmd)
                                    :environment-variables
                                    (cond ((map-elt agent-shell-auggie-authentication :none)
                                           agent-shell-auggie-environment)
                                          ((map-elt agent-shell-auggie-authentication :login)
                                           agent-shell-auggie-environment)
                                          (t
                                           (error "Invalid Auggie authentication")))
                                    :context-buffer buffer)) t))
                    base)))
            ;; Set default-directory so agent-shell-cwd picks up the chosen
            ;; workspace instead of inheriting the calling buffer's directory
            ;; (which may be ~/ when invoked from the welcome screen).
            (let ((default-directory workspace))
              (agent-shell-start :config config))
            ;; Invalidate session cache so next picker is fresh
            (setq decknix--agent-session-cache-time 0)
            ;; Post-creation: rename buffer immediately, subscribe to prompt-ready for metadata
            (decknix--agent-session-new-post-create
             before-buffers name tags workspace)
            (message "Starting agent session \"%s\" in %s…" name workspace)))

        (defun decknix--agent-session-new-post-create
            (before-buffers name tags workspace &optional first-message)
          "Post-creation setup: rename buffer to NAME, apply TAGS, record WORKSPACE.
BEFORE-BUFFERS is the buffer snapshot taken before agent-shell-start.
Finds the new buffer immediately (agent-shell-start creates it synchronously),
renames it, and persists metadata.

FIRST-MESSAGE, if provided, is the text that will be sent as the first user
message (e.g., the quickaction command).  When available, metadata (tags +
workspace) is stored immediately using a conversation key derived from it.
Otherwise, metadata is deferred to the `prompt-ready' event and stored
once the first exchange completes.  All state is per-buffer — safe for
batch launches."
          (let ((shell-buf (decknix--agent-find-new-shell-buffer before-buffers)))
            (when shell-buf
              ;; Rename immediately — the buffer exists now
              (with-current-buffer shell-buf
                (rename-buffer
                 (generate-new-buffer-name
                  (format "*Auggie: %s*" name)))
                (setq-local shell-maker--buffer-name-override
                            (buffer-name))
                (when workspace
                  (setq-local decknix--agent-session-workspace workspace)))
              ;; Persist metadata.
              ;; When first-message is known (quickactions), we can derive the
              ;; conversation key NOW and store tags + workspace immediately.
              ;; Otherwise, defer to prompt-ready → first-exchange completion.
              (when (or tags workspace)
                (let ((conv-key (when first-message
                                  (decknix--agent-conversation-key first-message))))
                  (if conv-key
                      ;; Immediate storage — we know the conversation key
                      (progn
                        (decknix--agent-store-metadata-by-conv-key
                         conv-key tags workspace)
                        (when tags
                          (message "Tags applied: [%s]"
                                   (string-join tags ", "))))
                    ;; Deferred — subscribe to prompt-ready then derive
                    ;; conv-key from the comint input ring (the user's first
                    ;; message is there once the agent has responded).
                    ;; This avoids the stale-cache bug where the async session
                    ;; list refresh hasn't completed yet.
                    (agent-shell-subscribe-to
                     :shell-buffer shell-buf
                     :event 'prompt-ready
                     :on-event
                     (eval `(lambda (_event)
                              (when (buffer-live-p ,shell-buf)
                                (condition-case nil
                                    (with-current-buffer ,shell-buf
                                      ;; Get session ID
                                      (let ((sid (or decknix--agent-auggie-session-id
                                                     (when (and (boundp 'shell-maker--config)
                                                                shell-maker--config)
                                                       (map-nested-elt (agent-shell--state)
                                                                       '(:session :id))))))
                                        (when (and sid (stringp sid)
                                                  (not (string-empty-p sid)))
                                          (setq-local decknix--agent-auggie-session-id sid)
                                          ;; Derive conv-key from comint input ring
                                          ;; (the first user message) — reliable even
                                          ;; when session cache is stale.
                                          (let* ((ring (and (boundp 'comint-input-ring)
                                                           comint-input-ring))
                                                 (first-msg (when (and ring
                                                                       (ring-p ring)
                                                                       (> (ring-length ring) 0))
                                                              ;; Oldest entry = first message
                                                              (ring-ref ring
                                                                        (1- (ring-length ring)))))
                                                 (conv-key (when (and first-msg
                                                                      (not (string-empty-p first-msg)))
                                                             (decknix--agent-conversation-key
                                                              first-msg))))
                                            (if conv-key
                                                (progn
                                                  (decknix--agent-store-metadata-by-conv-key
                                                   conv-key ',tags ,workspace)
                                                  ;; Also register session-id under conv-key
                                                  (decknix--agent-register-session-id
                                                   conv-key sid)
                                                  (when ',tags
                                                    (message "Tags applied: [%s]"
                                                             (string-join ',tags ", "))))
                                              ;; Fallback: try the old cache-based path
                                              (when ',tags
                                                (decknix--agent-session-tags-for sid ',tags)
                                                (message "Tags applied: [%s]"
                                                         (string-join ',tags ", ")))
                                              (when ,workspace
                                                (decknix--agent-session-save-workspace
                                                 sid ,workspace)))))))
                                  (error nil))))
                           t))))))))

        (defun decknix-agent-session-quit ()
          "Cleanly quit the current agent-shell session.
Kills the buffer (which sends SIGHUP to auggie, saving the session).

If other live agent-shell sessions exist, offers to switch to one
via the session picker. Otherwise returns to the welcome screen
or *scratch*."
          (interactive)
          (unless (derived-mode-p 'agent-shell-mode)
            (user-error "Not in an agent-shell buffer"))
          (when (y-or-n-p "Quit this agent session? ")
            (let* ((buf (current-buffer))
                   (other-bufs (remq buf
                                     (when (fboundp 'agent-shell-buffers)
                                       (agent-shell-buffers)))))
              (cond
               ;; Other live sessions exist — offer to switch
               (other-bufs
                (kill-buffer buf)
                (if (= (length other-bufs) 1)
                    ;; Only one other — switch directly
                    (switch-to-buffer (car other-bufs))
                  ;; Multiple — open the session picker
                  (decknix-agent-session-picker nil)))
               ;; Last session — return to welcome or scratch
               (t
                (kill-buffer buf)
                (if (fboundp 'decknix-welcome)
                    (decknix-welcome)
                  (switch-to-buffer (get-buffer-create "*scratch*"))))))))

        (defun decknix-agent-session-recent ()
          "Quickly pick from recently used conversations.
Like `recentf' but for agent sessions — shows the most recent
conversations (newest first), annotated with workspace and tags."
          (interactive)
          (let* ((sessions (decknix--agent-session-list))
                 (groups (when sessions
                           (decknix--agent-session-group-by-conversation sessions)))
                 (live-conv-keys
                  (seq-filter
                   #'identity
                   (mapcar (lambda (buf)
                             (when (buffer-live-p buf)
                               (with-current-buffer buf
                                 (when (derived-mode-p 'agent-shell-mode)
                                   (ignore-errors (decknix--session-conv-id))))))
                           (if (fboundp 'agent-shell-buffers)
                               (agent-shell-buffers) nil))))
                 (candidates nil))
            ;; Build candidate list from conversation groups (already sorted newest first)
            (dolist (group groups)
              (let* ((conv-key (car group))
                     (latest (cadr group))
                     (name (decknix--agent-session-display-name latest))
                     (workspace (when conv-key
                                  (decknix--agent-workspace-for-conv-key conv-key)))
                     (ws-short (if workspace
                                   (if (string-match "/\\([^/]+\\)/?$"
                                                     (abbreviate-file-name workspace))
                                       (match-string 1 (abbreviate-file-name workspace))
                                     (abbreviate-file-name workspace))
                                 "?"))
                     (live-p (member conv-key live-conv-keys))
                     (label (format "%s%s"
                                    (if live-p "● " "  ")
                                    name)))
                (push (list label ws-short conv-key latest workspace live-p) candidates)))
            (setq candidates (nreverse candidates))
            (unless candidates
              (user-error "No saved sessions found"))
            ;; Build completion table with annotations
            (let* ((max-name (apply #'max (mapcar (lambda (c) (length (car c))) candidates)))
                   (annotator
                    (eval
                     `(lambda (cand)
                        (when-let ((entry (assoc cand ',candidates)))
                          (format "%s %s"
                                  (make-string (- ,(+ max-name 2) (length cand)) ?\s)
                                  (nth 1 entry))))
                     t))
                   (table (decknix--agent-unsorted-table
                           (mapcar #'car candidates)))
                   (selection
                    (let ((completion-extra-properties
                           (list :annotation-function annotator)))
                      (completing-read "Recent session: " table nil t))))
              (when-let ((entry (assoc selection candidates)))
                (let ((conv-key (nth 2 entry))
                      (session (nth 3 entry))
                      (workspace (nth 4 entry))
                      (live-p (nth 5 entry)))
                  (if live-p
                      ;; Already live — find and switch to the buffer
                      (let ((buf (seq-find
                                  (lambda (b)
                                    (when (buffer-live-p b)
                                      (with-current-buffer b
                                        (when (derived-mode-p 'agent-shell-mode)
                                          (equal conv-key
                                                 (ignore-errors
                                                   (decknix--session-conv-id)))))))
                                  (agent-shell-buffers))))
                        (if buf (switch-to-buffer buf)
                          (user-error "Live buffer not found")))
                    ;; Saved — resume
                    (let ((session-id (alist-get 'sessionId session))
                          (name (decknix--agent-session-display-name session)))
                      (unless workspace
                        (setq workspace
                              (read-directory-name "Workspace: " nil nil t)))
                      (decknix--agent-session-resume
                       session-id
                       decknix-agent-session-history-count
                       name workspace conv-key))))))))

        ;; Wire C-c A r globally
        (define-key decknix-agent-prefix-map (kbd "r") 'decknix-agent-session-recent)

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
        (define-key decknix-agent-prefix-map (kbd "g") 'decknix-agent-session-grep)          ; Grep all session content
        (define-key decknix-agent-prefix-map (kbd "h") 'decknix-agent-session-history)       ; View history (C-u to pick)

        ;; == Session tagging: metadata layer for session organisation ==
        ;; Tags are conversation-scoped, keyed by a conversation hash
        ;; derived from firstUserMessage (shared across all session snapshots).
        ;; Format v2:
        ;; {"conversations": {"conv-hash": {"tags": [...], "sessions": [...]}},
        ;;  "bookmarks": {"session-id": {"label": "...", "created": "..."}}}

        (defvar decknix--agent-tags-file
          (expand-file-name "~/.config/decknix/agent-sessions.json")
          "Path to the JSON file storing conversation tag metadata.")

        (defun decknix--agent-conversation-key (first-message)
          "Derive a stable conversation key from FIRST-MESSAGE.
        Uses SHA-256 hash truncated to 16 chars."
          (when (and first-message (not (string-empty-p first-message)))
            (substring (secure-hash 'sha256 first-message) 0 16)))

        (defun decknix--agent-conversation-key-for-session (session-id)
          "Look up the conversation key for SESSION-ID from cached session data."
          (let* ((sessions (decknix--agent-session-list))
                 (match (seq-find (lambda (s)
                                    (string= (alist-get 'sessionId s) session-id))
                                  sessions)))
            (when match
              (decknix--agent-conversation-key
               (alist-get 'firstUserMessage match "")))))

        ;; In-memory cache for the tag store to avoid repeated json-read-file.
        ;; Each call to decknix--agent-tags-read was doing disk I/O (called 29+
        ;; times from various functions).  Now we cache the parsed hash-table and
        ;; only re-read when the file's mtime changes.
        (defvar decknix--agent-tags-cache nil
          "In-memory cache of the tag store hash-table.")
        (defvar decknix--agent-tags-cache-mtime nil
          "File modification time when cache was last populated.")

        (defun decknix--agent-tags-read ()
          "Read the tag store, returning an in-memory cached hash-table.
Re-reads from disk only if the file has been modified externally.
Auto-migrates v1 (session-keyed) format to v2 (conversation-keyed)."
          ;; Check if cache is valid (file hasn't changed)
          (let ((current-mtime (and (file-exists-p decknix--agent-tags-file)
                                    (file-attribute-modification-time
                                     (file-attributes decknix--agent-tags-file)))))
            (when (or (null decknix--agent-tags-cache)
                      (not (equal current-mtime decknix--agent-tags-cache-mtime)))
              ;; Cache miss — read from disk
              (setq decknix--agent-tags-cache
                    (if (file-exists-p decknix--agent-tags-file)
                        (condition-case err
                            (let* ((json-object-type 'hash-table)
                                   (json-array-type 'list)
                                   (json-key-type 'string))
                              (json-read-file decknix--agent-tags-file))
                          (error
                           (message "Warning: could not read tag store: %s"
                                    (error-message-string err))
                           (make-hash-table :test 'equal)))
                      (make-hash-table :test 'equal)))
              (setq decknix--agent-tags-cache-mtime current-mtime)))
          (let ((store decknix--agent-tags-cache))
            ;; Auto-migrate v1 format: session-keyed entries → conversation-keyed.
            ;; Handles both initial migration (no "conversations" key) and
            ;; incremental migration (orphaned v1 entries coexisting with v2).
            (let ((convs (or (gethash "conversations" store)
                             (make-hash-table :test 'equal)))
                  (sessions (decknix--agent-session-list))
                  (old-entries nil)
                  (migrated 0))
              ;; Collect orphaned session-keyed entries (UUID keys with tags)
              (maphash (lambda (key val)
                         (when (and (hash-table-p val)
                                    (gethash "tags" val)
                                    (not (member key '("conversations" "bookmarks"))))
                           (push (cons key val) old-entries)))
                       store)
              (when old-entries
                ;; Resolve each old session → conversation and merge tags
                (dolist (entry old-entries)
                  (let* ((sid (car entry))
                         (data (cdr entry))
                         (match (seq-find
                                 (eval `(lambda (s)
                                          (string= (alist-get 'sessionId s) ,sid))
                                       t)
                                 sessions))
                         (conv-key (when match
                                     (decknix--agent-conversation-key
                                      (alist-get 'firstUserMessage match ""))))
                         (tags (gethash "tags" data)))
                    (when (and conv-key tags)
                      (let ((conv-entry (or (gethash conv-key convs)
                                            (let ((h (make-hash-table :test 'equal)))
                                              (puthash "tags" nil h)
                                              (puthash "sessions" nil h)
                                              h))))
                        ;; Merge tags
                        (let ((existing (gethash "tags" conv-entry)))
                          (dolist (tag tags)
                            (cl-pushnew tag existing :test #'string=))
                          (puthash "tags" existing conv-entry))
                        ;; Track session
                        (let ((sids (gethash "sessions" conv-entry)))
                          (cl-pushnew sid sids :test #'string=)
                          (puthash "sessions" sids conv-entry))
                        (puthash conv-key conv-entry convs)))
                    ;; Remove the old session-keyed entry regardless
                    (remhash sid store)
                    (setq migrated (1+ migrated))))
                ;; Write back the cleaned store
                (puthash "conversations" convs store)
                (unless (gethash "bookmarks" store)
                  (puthash "bookmarks" (make-hash-table :test 'equal) store))
                (decknix--agent-tags-write store)
                (message "Migrated %d v1 tag entries to conversation format" migrated)))
            store))

        (defun decknix--agent-tags-write (store)
          "Write STORE (hash-table) to the tag file and update in-memory cache."
          (let ((dir (file-name-directory decknix--agent-tags-file)))
            (unless (file-directory-p dir)
              (make-directory dir t))
            (with-temp-file decknix--agent-tags-file
              (let ((json-encoding-pretty-print t))
                (insert (json-encode store))))
            ;; Update cache so subsequent reads don't hit disk
            (setq decknix--agent-tags-cache store
                  decknix--agent-tags-cache-mtime
                  (file-attribute-modification-time
                   (file-attributes decknix--agent-tags-file)))))

        (defun decknix--agent-tags-conversations (store)
          "Get the conversations hash-table from STORE."
          (or (gethash "conversations" store)
              (let ((convs (make-hash-table :test 'equal)))
                (puthash "conversations" convs store)
                convs)))

        (defun decknix--agent-conv-touch (conv-key)
          "Stamp lastAccessed on CONV-KEY so it sorts to the top.
Called by user-facing operations (tag, rename, resume, create)
so that any interaction with a conversation bumps its recency,
not just augment writing to the session file."
          (when conv-key
            (let* ((store (decknix--agent-tags-read))
                   (convs (decknix--agent-tags-conversations store))
                   (entry (gethash conv-key convs)))
              (when entry
                (puthash "lastAccessed"
                         (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t)
                         entry)
                (decknix--agent-tags-write store)))))

        (defun decknix--agent-conv-last-accessed (conv-key)
          "Return the lastAccessed timestamp for CONV-KEY, or nil."
          (when conv-key
            (let* ((store (decknix--agent-tags-read))
                   (convs (decknix--agent-tags-conversations store))
                   (entry (gethash conv-key convs)))
              (when entry (gethash "lastAccessed" entry)))))

        (defun decknix--agent-tags-for-session (session-id)
          "Return the list of tags for the conversation containing SESSION-ID."
          (let* ((conv-key (decknix--agent-conversation-key-for-session session-id))
                 (store (decknix--agent-tags-read))
                 (convs (decknix--agent-tags-conversations store)))
            (when conv-key
              (let ((entry (gethash conv-key convs)))
                (when (hash-table-p entry)
                  (gethash "tags" entry))))))

        (defun decknix--agent-tags-for-conv-key (conv-key)
          "Return the list of tags for conversation CONV-KEY."
          (let* ((store (decknix--agent-tags-read))
                 (convs (decknix--agent-tags-conversations store)))
            (let ((entry (gethash conv-key convs)))
              (when (hash-table-p entry)
                (gethash "tags" entry)))))

        (defun decknix--agent-workspace-for-conv-key (conv-key)
          "Return the workspace directory for conversation CONV-KEY, or nil."
          (let* ((store (decknix--agent-tags-read))
                 (convs (decknix--agent-tags-conversations store)))
            (let ((entry (gethash conv-key convs)))
              (when (hash-table-p entry)
                (gethash "workspace" entry)))))

        (defun decknix--agent-session-save-workspace (session-id workspace)
          "Persist WORKSPACE for the conversation containing SESSION-ID.
Looks up the conversation key from cached session data, then stores
the workspace in the conversation entry alongside tags."
          (when (and session-id workspace)
            (let ((conv-key (decknix--agent-conversation-key-for-session
                             session-id)))
              (when conv-key
                (let* ((store (decknix--agent-tags-read))
                       (convs (decknix--agent-tags-conversations store))
                       (entry (or (gethash conv-key convs)
                                  (let ((h (make-hash-table :test 'equal)))
                                    (puthash "tags" nil h)
                                    (puthash "sessions" nil h)
                                    h))))
                  (puthash "workspace" workspace entry)
                  (puthash conv-key entry convs)
                  (decknix--agent-tags-write store))))))

        (defun decknix--agent-session-save-workspace-for-conv-key
            (conv-key workspace)
          "Persist WORKSPACE for CONV-KEY directly (no session-id lookup).
Used by the session picker when the user selects a workspace for a
conversation that had no workspace stored."
          (when (and conv-key workspace)
            (let* ((store (decknix--agent-tags-read))
                   (convs (decknix--agent-tags-conversations store))
                   (entry (or (gethash conv-key convs)
                              (let ((h (make-hash-table :test 'equal)))
                                (puthash "tags" nil h)
                                (puthash "sessions" nil h)
                                h))))
              (puthash "workspace" workspace entry)
              (puthash conv-key entry convs)
              (decknix--agent-tags-write store))))

        (defun decknix--agent-tags-all ()
          "Return a sorted list of all unique tags across all conversations."
          (let* ((store (decknix--agent-tags-read))
                 (convs (decknix--agent-tags-conversations store))
                 (all-tags nil))
            (maphash (lambda (_key entry)
                       (when (hash-table-p entry)
                         (dolist (tag (gethash "tags" entry))
                           (cl-pushnew tag all-tags :test #'string=))))
                     convs)
            (sort all-tags #'string<)))

        (defun decknix--agent-current-session-id ()
          "Get the auggie session ID for the current buffer, or nil."
          (when (derived-mode-p 'agent-shell-mode)
            decknix--agent-auggie-session-id))

        (defun decknix--agent-require-session-id ()
          "Get the current session ID or error."
          (or (decknix--agent-current-session-id)
              (user-error "No auggie session ID for this buffer (is it a resumed session?)")))

        (defun decknix--agent-require-conv-key ()
          "Get the conversation key for the current session, or error."
          (let* ((session-id (decknix--agent-require-session-id))
                 (conv-key (decknix--agent-conversation-key-for-session session-id)))
            (unless conv-key
              (user-error "Cannot determine conversation for session %s"
                          (substring session-id 0 8)))
            conv-key))

        (defun decknix-agent-tag-show ()
          "Show the tags for the current conversation."
          (interactive)
          (let* ((session-id (decknix--agent-require-session-id))
                 (tags (decknix--agent-tags-for-session session-id)))
            (if tags
                (message "Conversation tags: [%s]" (string-join tags ", "))
              (message "No tags on this conversation"))))

        (defun decknix-agent-tag-add ()
          "Add tags to the current conversation.
        Accepts comma-separated input for multiple tags at once.
        Shows all existing tags for completion. Type new names to create them."
          (interactive)
          (let* ((conv-key (decknix--agent-require-conv-key))
                 (session-id (decknix--agent-require-session-id))
                 (existing (decknix--agent-tags-all))
                 (current (decknix--agent-tags-for-conv-key conv-key))
                 ;; Show which tags are already applied via annotation
                 (annotator (eval
                             `(lambda (tag)
                                (if (member tag ',current) " (applied)" ""))
                             t))
                 (input (let ((completion-extra-properties
                               (list :annotation-function annotator)))
                          (completing-read "Add tag(s) (comma-separated): "
                                           existing nil nil)))
                 ;; Split on commas, trim whitespace, remove empties
                 (new-tags (seq-remove #'string-empty-p
                                       (mapcar #'string-trim
                                               (split-string input "," t)))))
            (unless new-tags
              (user-error "No tags provided"))
            (let* ((store (decknix--agent-tags-read))
                   (convs (decknix--agent-tags-conversations store))
                   (entry (or (gethash conv-key convs)
                              (let ((h (make-hash-table :test 'equal)))
                                (puthash "tags" nil h)
                                (puthash "sessions" nil h)
                                h)))
                   (tags (gethash "tags" entry))
                   (sids (gethash "sessions" entry))
                   (added nil)
                   (skipped nil))
              ;; Add each tag, tracking what was added vs already present
              (dolist (tag new-tags)
                (if (member tag tags)
                    (push tag skipped)
                  (setq tags (append tags (list tag)))
                  (push tag added)))
              (puthash "tags" tags entry)
              ;; Track this session in the conversation
              (cl-pushnew session-id sids :test #'string=)
              (puthash "sessions" sids entry)
              ;; Bump recency so this conversation sorts to the top
              (puthash "lastAccessed"
                       (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry)
              (puthash conv-key entry convs)
              (decknix--agent-tags-write store)
              ;; Report what happened
              (cond
               ((and added (not skipped))
                (message "Tagged: %s → [%s]"
                         (string-join (nreverse added) ", ")
                         (string-join tags ", ")))
               ((and added skipped)
                (message "Tagged: %s (already had: %s) → [%s]"
                         (string-join (nreverse added) ", ")
                         (string-join (nreverse skipped) ", ")
                         (string-join tags ", ")))
               (t
                (message "All tags already applied: [%s]"
                         (string-join tags ", ")))))))

        (defun decknix-agent-tag-remove ()
          "Remove a tag from the current conversation."
          (interactive)
          (let* ((conv-key (decknix--agent-require-conv-key))
                 (current (decknix--agent-tags-for-conv-key conv-key)))
            (unless current
              (user-error "This conversation has no tags"))
            (let* ((tag (completing-read "Remove tag: " current nil t))
                   (store (decknix--agent-tags-read))
                   (convs (decknix--agent-tags-conversations store))
                   (entry (gethash conv-key convs))
                   (remaining (remove tag (gethash "tags" entry))))
              (if remaining
                  (progn
                    (puthash "tags" remaining entry)
                    (puthash "lastAccessed"
                             (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry))
                (remhash conv-key convs))
              (decknix--agent-tags-write store)
              (message "Removed \"%s\" from conversation" tag))))

        (defun decknix-agent-tag-list ()
          "List conversations filtered by tag.
        Prompts for a tag, then shows the latest session per matching conversation."
          (interactive)
          (let* ((all-tags (decknix--agent-tags-all)))
            (unless all-tags
              (user-error "No tags defined yet"))
            (let* ((tag (completing-read "Filter by tag: " all-tags nil t))
                   (store (decknix--agent-tags-read))
                   (convs (decknix--agent-tags-conversations store))
                   (sessions (decknix--agent-session-list))
                   (conv-groups (decknix--agent-session-group-by-conversation sessions))
                   (matching nil))
              ;; Find conversations with this tag
              (maphash (lambda (conv-key entry)
                         (when (and (hash-table-p entry)
                                    (member tag (gethash "tags" entry)))
                           (push conv-key matching)))
                       convs)
              (unless matching
                (user-error "No conversations tagged \"%s\"" tag))
              ;; Build picker from latest session per matching conversation
              (let* ((entries
                      (cl-loop for conv-key in matching
                               for group = (seq-find
                                            (lambda (g) (string= (car g) conv-key))
                                            conv-groups)
                               when group
                               collect (let* ((latest (cadr group))
                                              (tags (decknix--agent-tags-for-conv-key conv-key))
                                              (tag-str (if tags (format " [%s]" (string-join tags ", ")) "")))
                                         (cons (format "%s%s"
                                                       (decknix--agent-session-preview latest)
                                                       tag-str)
                                               (cons 'session latest))))))
                (unless entries
                  (user-error "No sessions found for tag \"%s\"" tag))
                (let* ((selection (completing-read
                                   (format "Conversations tagged \"%s\": " tag)
                                   (decknix--agent-unsorted-table
                                    (mapcar #'car entries)) nil t))
                       (chosen (cdr (assoc selection entries)))
                       (session (cdr chosen))
                       (session-id (alist-get 'sessionId session)))
                  (let ((conv-key (decknix--agent-conversation-key
                                   (alist-get 'firstUserMessage
                                              session ""))))
                    (decknix--agent-session-resume
                     session-id
                     decknix-agent-session-history-count
                     (decknix--agent-session-display-name session)
                     nil conv-key)))))))

        (defun decknix-agent-tag-edit ()
          "Rename a tag across all conversations."
          (interactive)
          (let* ((all-tags (decknix--agent-tags-all)))
            (unless all-tags
              (user-error "No tags defined yet"))
            (let* ((old-tag (completing-read "Rename tag: " all-tags nil t))
                   (new-tag (string-trim
                             (read-string (format "Rename \"%s\" to: " old-tag) old-tag)))
                   (store (decknix--agent-tags-read))
                   (convs (decknix--agent-tags-conversations store))
                   (count 0))
              (when (string-empty-p new-tag)
                (user-error "Tag cannot be empty"))
              (when (string= old-tag new-tag)
                (user-error "Same name, nothing to do"))
              (maphash (lambda (_key entry)
                         (when (hash-table-p entry)
                           (let ((tags (gethash "tags" entry)))
                             (when (member old-tag tags)
                               (puthash "tags"
                                        (mapcar (lambda (tg) (if (string= tg old-tag) new-tag tg)) tags)
                                        entry)
                               (cl-incf count)))))
                       convs)
              (decknix--agent-tags-write store)
              (message "Renamed \"%s\" → \"%s\" across %d conversation%s"
                       old-tag new-tag count (if (= count 1) "" "s")))))

        (defun decknix-agent-tag-delete ()
          "Delete a tag from all conversations."
          (interactive)
          (let* ((all-tags (decknix--agent-tags-all)))
            (unless all-tags
              (user-error "No tags defined yet"))
            (let* ((tag (completing-read "Delete tag globally: " all-tags nil t)))
              (when (y-or-n-p (format "Delete tag \"%s\" from all conversations? " tag))
                (let* ((store (decknix--agent-tags-read))
                       (convs (decknix--agent-tags-conversations store))
                       (count 0)
                       (empties nil))
                  (maphash (lambda (key entry)
                             (when (hash-table-p entry)
                               (let ((tags (gethash "tags" entry)))
                                 (when (member tag tags)
                                   (let ((remaining (remove tag tags)))
                                     (if remaining
                                         (puthash "tags" remaining entry)
                                       (push key empties)))
                                   (cl-incf count)))))
                           convs)
                  (dolist (key empties) (remhash key convs))
                  (decknix--agent-tags-write store)
                  (message "Deleted \"%s\" from %d conversation%s"
                           tag count (if (= count 1) "" "s")))))))

        (defun decknix-agent-tag-cleanup ()
          "Remove conversation entries that have no matching sessions on disk."
          (interactive)
          (let* ((store (decknix--agent-tags-read))
                 (convs (decknix--agent-tags-conversations store))
                 (sessions (decknix--agent-session-list))
                 (conv-groups (decknix--agent-session-group-by-conversation sessions))
                 (live-keys (mapcar #'car conv-groups))
                 (orphans nil))
            (maphash (lambda (key _entry)
                       (unless (member key live-keys)
                         (push key orphans)))
                     convs)
            (if orphans
                (when (y-or-n-p (format "Remove %d orphaned conversation tag%s? "
                                        (length orphans)
                                        (if (= (length orphans) 1) "" "s")))
                  (dolist (key orphans) (remhash key convs))
                  (decknix--agent-tags-write store)
                  (message "Cleaned up %d orphaned conversation%s"
                           (length orphans)
                           (if (= (length orphans) 1) "" "s")))
              (message "No orphaned conversations found"))))

        ;; == Rename session/conversation ==
        ;; Persists the name into agent-sessions.json tags so it survives
        ;; restarts and appears correctly in the sidebar and picker.

        (defun decknix-agent-session-rename (new-name)
          "Rename the current conversation to NEW-NAME.
Updates the tags in agent-sessions.json (replacing all existing tags
with the new name) and renames the live buffer.  Works from any
agent-shell buffer."
          (interactive
           (let* ((conv-key (decknix--agent-require-conv-key))
                  (current-tags (decknix--agent-tags-for-conv-key conv-key))
                  (default (string-join current-tags "/")))
             (list (read-string (format "Rename conversation%s: "
                                        (if (string-empty-p default) ""
                                          (format " (%s)" default)))
                                default))))
          (when (string-empty-p (string-trim new-name))
            (user-error "Name cannot be empty"))
          (let* ((conv-key (decknix--agent-require-conv-key))
                 (session-id (decknix--agent-require-session-id))
                 (store (decknix--agent-tags-read))
                 (convs (decknix--agent-tags-conversations store))
                 (entry (or (gethash conv-key convs)
                            (let ((h (make-hash-table :test 'equal)))
                              (puthash "tags" nil h)
                              (puthash "sessions" nil h)
                              h)))
                 (sids (gethash "sessions" entry))
                 ;; Split new-name on "/" or "," to allow multi-tag names
                 (new-tags (seq-remove #'string-empty-p
                                       (mapcar #'string-trim
                                               (split-string new-name "[/,]" t)))))
            ;; Update tags
            (puthash "tags" new-tags entry)
            (cl-pushnew session-id sids :test #'string=)
            (puthash "sessions" sids entry)
            ;; Bump recency
            (puthash "lastAccessed"
                     (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t) entry)
            (puthash conv-key entry convs)
            (decknix--agent-tags-write store)
            ;; Rename the live buffer
            (let ((display (string-join new-tags "/")))
              (rename-buffer (format "*Auggie: %s*" display) t)
              (when (boundp 'shell-maker--buffer-name-override)
                (setq shell-maker--buffer-name-override (buffer-name)))
              ;; Refresh sidebar if visible
              (when (fboundp 'agent-shell-workspace-sidebar-refresh)
                (ignore-errors (agent-shell-workspace-sidebar-refresh)))
              (message "Renamed conversation → %s" display))))

        ;; Wire C-c A R globally
        (define-key decknix-agent-prefix-map (kbd "R") 'decknix-agent-session-rename)

        ;; Advise sidebar R to handle saved (non-live) sessions:
        ;; For saved sessions, resume first then rename.
        (advice-add 'agent-shell-workspace-sidebar-rename :around
          (lambda (orig-fn)
            "Handle rename for both live and saved sessions in sidebar."
            (let ((saved (get-text-property
                           (line-beginning-position)
                           'decknix-sidebar-saved-session)))
              (if saved
                  ;; Saved session: prompt for new name, update tags directly
                  (let* ((conv-key (get-text-property
                                     (line-beginning-position)
                                     'decknix-sidebar-saved-conv-key))
                         (current-tags (when conv-key
                                         (decknix--agent-tags-for-conv-key conv-key)))
                         (default (string-join (or current-tags '()) "/"))
                         (new-name (read-string
                                    (format "Rename '%s' to: " default)
                                    default)))
                    (when (string-empty-p (string-trim new-name))
                      (user-error "Name cannot be empty"))
                    (let* ((store (decknix--agent-tags-read))
                           (convs (decknix--agent-tags-conversations store))
                           (entry (gethash conv-key convs))
                           (new-tags (seq-remove
                                      #'string-empty-p
                                      (mapcar #'string-trim
                                              (split-string new-name "[/,]" t)))))
                      (when entry
                        (puthash "tags" new-tags entry)
                        (decknix--agent-tags-write store)
                        (agent-shell-workspace-sidebar-refresh)
                        (message "Renamed saved conversation → %s"
                                 (string-join new-tags "/")))))
                ;; Live session: use upstream rename, then persist to tags
                (funcall orig-fn)
                ;; After upstream rename, sync the new name to tags
                (when-let* ((buf (agent-shell-workspace-sidebar--buffer-at-point))
                            ((buffer-live-p buf)))
                  (with-current-buffer buf
                    (when (derived-mode-p 'agent-shell-mode)
                      (ignore-errors
                        (let* ((conv-key (decknix--agent-require-conv-key))
                               (short (agent-shell-workspace--short-name buf))
                               (new-tags (seq-remove
                                           #'string-empty-p
                                           (mapcar #'string-trim
                                                   (split-string short "[/,]" t))))
                               (store (decknix--agent-tags-read))
                               (convs (decknix--agent-tags-conversations store))
                               (entry (or (gethash conv-key convs)
                                          (let ((h (make-hash-table :test 'equal)))
                                            (puthash "tags" nil h)
                                            (puthash "sessions" nil h)
                                            h))))
                          (puthash "tags" new-tags entry)
                          (puthash conv-key entry convs)
                          (decknix--agent-tags-write store))))))))))

        ;; C-c A T — global tags sub-prefix ("Tags (global)")
        ;; Operations that affect tags across all sessions.
        (define-prefix-command 'decknix-agent-tags-global-map)
        (define-key decknix-agent-prefix-map (kbd "T") 'decknix-agent-tags-global-map)
        (define-key decknix-agent-tags-global-map (kbd "l") 'decknix-agent-tag-list)      ; List/filter sessions by tag
        (define-key decknix-agent-tags-global-map (kbd "e") 'decknix-agent-tag-edit)      ; Rename tag globally
        (define-key decknix-agent-tags-global-map (kbd "d") 'decknix-agent-tag-delete)    ; Delete tag globally
        (define-key decknix-agent-tags-global-map (kbd "c") 'decknix-agent-tag-cleanup)   ; Cleanup orphans

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
        ;; Opens a buffer for composing multi-line prompts.
        ;; Supports sticky (persistent) and transient modes.
        ;; C-c C-c submits, C-c C-k cancels/clears, C-c C-s toggles sticky.
        ;; C-c k prefix: k = interrupt, C-c = interrupt + submit.

        (defvar-local decknix--compose-target-buffer nil
          "The agent-shell buffer to submit the composed prompt to.")

        (defvar-local decknix--compose-history-index -1
          "Current position in the prompt history.
-1 means not navigating history (showing user's own input).")

        (defvar-local decknix--compose-saved-input nil
          "Saved user input before history navigation started.
Restored when cycling past the newest history entry.")

        (defvar-local decknix--compose-history-items nil
          "Prompts loaded so far (current ring + streamed sessions).")

        (defvar-local decknix--compose-history-seen nil
          "Hash table tracking prompts already in history-items (for dedup).")

        (defvar-local decknix--compose-history-file-queue nil
          "Remaining session files to load on-demand (newest first).")

        (defvar-local decknix--compose-history-exhausted nil
          "Non-nil when all session files have been processed.")

        ;; == On-demand per-file prompt extraction ==

        (defvar decknix--prompt-extract-jq-filter-file nil
          "Path to temp file containing the jq filter for single-file extraction.")

        (defun decknix--prompt-extract-ensure-jq-filter ()
          "Create the jq filter file for per-file prompt extraction."
          (unless (and decknix--prompt-extract-jq-filter-file
                      (file-exists-p decknix--prompt-extract-jq-filter-file))
            (setq decknix--prompt-extract-jq-filter-file
                  (make-temp-file "auggie-extract-" nil ".jq"))
            (with-temp-file decknix--prompt-extract-jq-filter-file
              (insert "[.chatHistory[].exchange.request_message"
                      " // \"\" | select(length > 0)] | reverse\n")))
          decknix--prompt-extract-jq-filter-file)

        (defun decknix--prompt-extract-from-file (file)
          "Extract user prompts from a single session FILE using jq.
Returns a list of non-empty strings, newest first."
          (condition-case nil
              (let* ((jqf (decknix--prompt-extract-ensure-jq-filter))
                     (raw (shell-command-to-string
                           (concat "jq -c -f "
                                   (shell-quote-argument jqf) " "
                                   (shell-quote-argument file)
                                   " 2>/dev/null")))
                     (trimmed (string-trim raw)))
                (when (and (not (string-empty-p trimmed))
                           (string-prefix-p "[" trimmed))
                  (let* ((json-array-type 'list)
                         (json-key-type 'symbol)
                         (msgs (json-read-from-string trimmed)))
                    (seq-filter (lambda (m)
                                  (and (stringp m)
                                       (not (string-empty-p (string-trim m)))))
                                msgs))))
            (error nil)))

        (defvar-local decknix--compose-history-local-only t
          "When non-nil, M-p/M-n only cycle the current session's prompts.
Set to nil by M-P/M-N to enable cross-session history navigation.")

        (defun decknix--compose-history-init ()
          "Initialize on-demand history for this compose buffer.
Populates items from comint-input-ring.  When
`decknix--compose-history-local-only' is non-nil (default / M-p/M-n),
only current-session prompts are loaded.  When nil (M-P/M-N), also
builds the cross-session file queue for on-demand streaming."
          (let ((seen (make-hash-table :test 'equal))
                (items nil)
                (current-session-id nil))
            ;; 1. Current session's comint-input-ring
            (when (and decknix--compose-target-buffer
                       (buffer-live-p decknix--compose-target-buffer))
              (with-current-buffer decknix--compose-target-buffer
                (setq current-session-id
                      (when (bound-and-true-p decknix--agent-auggie-session-id)
                        decknix--agent-auggie-session-id))
                (when (and (bound-and-true-p comint-input-ring)
                           (not (ring-empty-p comint-input-ring)))
                  (dotimes (i (ring-length comint-input-ring))
                    (let ((item (ring-ref comint-input-ring i)))
                      (when (and (stringp item)
                                 (not (string-empty-p (string-trim item)))
                                 (not (gethash item seen)))
                        (puthash item t seen)
                        (push item items)))))))
            (setq items (nreverse items))
            ;; 2. File queue: only when cross-session mode is active (M-P/M-N)
            (if decknix--compose-history-local-only
                ;; Local-only: no file queue, mark exhausted immediately
                (setq decknix--compose-history-items items
                      decknix--compose-history-seen seen
                      decknix--compose-history-file-queue nil
                      decknix--compose-history-exhausted t)
              ;; Cross-session: build file queue, exclude current session
              (let* ((dir decknix--agent-sessions-dir)
                     (exclude-file (when current-session-id
                                     (expand-file-name
                                      (concat current-session-id ".json") dir)))
                     ;; ls -t gives newest-first by mtime
                     (all-files
                      (split-string
                       (shell-command-to-string
                        (concat "ls -t "
                                (shell-quote-argument dir)
                                "/*.json 2>/dev/null"))
                       "\n" t))
                     (queue (if exclude-file
                                (seq-remove
                                 (lambda (f) (string= f exclude-file))
                                 all-files)
                              all-files)))
                (setq decknix--compose-history-items items
                      decknix--compose-history-seen seen
                      decknix--compose-history-file-queue queue
                      decknix--compose-history-exhausted (null queue))))))

        (defun decknix--compose-history-load-next-batch ()
          "Load prompts from the next session file(s) in the queue.
Keeps loading files until at least one new prompt is found or queue is empty.
Returns non-nil if new prompts were added."
          (let ((added nil))
            (while (and (not added) decknix--compose-history-file-queue)
              (let* ((file (pop decknix--compose-history-file-queue))
                     (msgs (decknix--prompt-extract-from-file file)))
                (dolist (msg msgs)
                  (unless (gethash msg decknix--compose-history-seen)
                    (puthash msg t decknix--compose-history-seen)
                    ;; Append to end of items list
                    (setq decknix--compose-history-items
                          (nconc decknix--compose-history-items (list msg)))
                    (setq added t)))))
            (when (null decknix--compose-history-file-queue)
              (setq decknix--compose-history-exhausted t))
            added))

        (defun decknix--compose-history-navigate-previous ()
          "Core implementation: move to the previous (older) prompt in history."
          ;; Initialize on first navigation
          (unless decknix--compose-history-seen
            (decknix--compose-history-init))
          (let ((items decknix--compose-history-items))
            ;; Save current input when starting navigation
            (when (= decknix--compose-history-index -1)
              (setq decknix--compose-saved-input
                    (buffer-substring-no-properties (point-min) (point-max))))
            ;; Try to move backward
            (let ((new-index (1+ decknix--compose-history-index)))
              (when (and (>= new-index (length items))
                         (not decknix--compose-history-exhausted))
                ;; Need more — load next session file(s)
                (decknix--compose-history-load-next-batch)
                (setq items decknix--compose-history-items))
              (if (>= new-index (length items))
                  (progn
                    (message "End of %s history (%d prompts)"
                             (if decknix--compose-history-local-only
                                 "session" "global")
                             (length items))
                    (ding))
                (setq decknix--compose-history-index new-index)
                (erase-buffer)
                (insert (nth new-index items))
                (goto-char (point-max))))))

        (defun decknix--compose-history-navigate-next ()
          "Core implementation: move to the next (newer) prompt in history."
          (cond
           ;; Already at current input
           ((= decknix--compose-history-index -1)
            (message "End of history") (ding))
           ;; Moving to current input (restore saved)
           ((= decknix--compose-history-index 0)
            (setq decknix--compose-history-index -1)
            (erase-buffer)
            (when decknix--compose-saved-input
              (insert decknix--compose-saved-input))
            (goto-char (point-max)))
           ;; Move forward (newer)
           (t
            (setq decknix--compose-history-index
                  (1- decknix--compose-history-index))
            (erase-buffer)
            (insert (nth decknix--compose-history-index
                         decknix--compose-history-items))
            (goto-char (point-max)))))

        (defun decknix-agent-compose-previous-input ()
          "Cycle to the previous prompt from the CURRENT session only.
Use M-P for cross-session history."
          (interactive)
          (when (not decknix--compose-history-local-only)
            ;; Switching from global → local: reset to rebuild
            (setq decknix--compose-history-local-only t
                  decknix--compose-history-seen nil))
          (decknix--compose-history-navigate-previous))

        (defun decknix-agent-compose-next-input ()
          "Cycle to the next (newer) prompt from the CURRENT session only.
Use M-N for cross-session history."
          (interactive)
          (decknix--compose-history-navigate-next))

        (defun decknix-agent-compose-previous-input-global ()
          "Cycle to the previous prompt across ALL sessions.
Starts with the current session, then streams from saved sessions on-demand."
          (interactive)
          (when decknix--compose-history-local-only
            ;; Switching from local → global: reset to rebuild with file queue
            (setq decknix--compose-history-local-only nil
                  decknix--compose-history-seen nil))
          (decknix--compose-history-navigate-previous))

        (defun decknix-agent-compose-next-input-global ()
          "Cycle to the next (newer) prompt across ALL sessions."
          (interactive)
          (decknix--compose-history-navigate-next))

        ;; == Consult-based prompt search (M-r) ==

        (defvar decknix--prompt-search-cache nil
          "Cached list of all user prompts for consult search (strings).")

        (defvar decknix--prompt-search-cache-time 0
          "Time when prompt search cache was last updated.")

        (defvar decknix--prompt-search-cache-ttl 300
          "Seconds before prompt search cache is stale (5 min).")

        (defvar decknix--prompt-search-refresh-proc nil
          "Process handle for async prompt search cache refresh.")

        (defun decknix--prompt-search-jq-cmd ()
          "Shell command to extract all user prompts from all sessions.
Outputs one JSON array per line (one per session file)."
          (let ((jqf (decknix--prompt-extract-ensure-jq-filter)))
            (concat
             "find " (shell-quote-argument decknix--agent-sessions-dir)
             " -maxdepth 1 -name '*.json' -print0 2>/dev/null"
             " | xargs -0 -P8 -I{}"
             " sh -c 'jq -c -f \"$1\" \"$2\" 2>/dev/null || true' _ "
             (shell-quote-argument jqf) " {}")))

        (defun decknix--prompt-search-parse (raw)
          "Parse RAW jq output into a flat deduplicated prompt list."
          (let ((seen (make-hash-table :test 'equal))
                (result nil))
            (dolist (line (split-string (string-trim raw) "\n" t))
              (condition-case nil
                  (let* ((json-array-type 'list)
                         (json-key-type 'symbol)
                         (msgs (json-read-from-string line)))
                    (dolist (msg msgs)
                      (when (and (stringp msg)
                                 (not (string-empty-p (string-trim msg)))
                                 (not (gethash msg seen)))
                        (puthash msg t seen)
                        (push msg result))))
                (error nil)))
            (nreverse result)))

        (defun decknix--prompt-search-refresh-sync ()
          "Synchronously build the prompt search cache."
          (message "Loading all prompt history for search…")
          (let ((result (decknix--prompt-search-parse
                         (shell-command-to-string
                          (decknix--prompt-search-jq-cmd)))))
            (setq decknix--prompt-search-cache result
                  decknix--prompt-search-cache-time (float-time))
            result))

        (defun decknix--prompt-search-refresh-async ()
          "Asynchronously refresh the prompt search cache."
          (when (or (null decknix--prompt-search-refresh-proc)
                    (not (process-live-p decknix--prompt-search-refresh-proc)))
            (let ((buf (generate-new-buffer " *auggie-prompt-search*")))
              (setq decknix--prompt-search-refresh-proc
                    (start-process-shell-command
                     "auggie-prompt-search" buf
                     (decknix--prompt-search-jq-cmd)))
              (set-process-sentinel
               decknix--prompt-search-refresh-proc
               (eval
                `(lambda (proc _event)
                   (when (eq (process-status proc) 'exit)
                     (let ((pbuf (process-buffer proc)))
                       (when (buffer-live-p pbuf)
                         (let ((result (decknix--prompt-search-parse
                                        (with-current-buffer pbuf
                                          (buffer-string)))))
                           (when result
                             (setq decknix--prompt-search-cache result
                                   decknix--prompt-search-cache-time
                                   (float-time))))
                         (kill-buffer pbuf)))))
                t)))))

        (defun decknix--prompt-search-get ()
          "Return all prompts for search, fetching if needed."
          (when (and (null decknix--prompt-search-cache)
                     (= decknix--prompt-search-cache-time 0))
            (decknix--prompt-search-refresh-sync))
          (when (> (- (float-time) decknix--prompt-search-cache-time)
                   decknix--prompt-search-cache-ttl)
            (decknix--prompt-search-refresh-async))
          ;; Also prepend current comint-input-ring entries
          (let ((seen (make-hash-table :test 'equal))
                (ring-items nil)
                (target (or decknix--compose-target-buffer
                            (when (derived-mode-p 'agent-shell-mode)
                              (current-buffer)))))
            (when (and target (buffer-live-p target))
              (with-current-buffer target
                (when (and (bound-and-true-p comint-input-ring)
                           (not (ring-empty-p comint-input-ring)))
                  (dotimes (i (ring-length comint-input-ring))
                    (let ((item (ring-ref comint-input-ring i)))
                      (when (and (stringp item)
                                 (not (string-empty-p (string-trim item)))
                                 (not (gethash item seen)))
                        (puthash item t seen)
                        (push item ring-items)))))))
            ;; Combine: current ring + saved (deduped)
            (let ((result (nreverse ring-items)))
              (dolist (msg decknix--prompt-search-cache)
                (unless (gethash msg seen)
                  (puthash msg t seen)
                  (push msg result)))
              (nreverse result))))

        ;; Pre-fetch prompt search cache on daemon start
        (run-at-time 5 nil #'decknix--prompt-search-refresh-async)

        (defun decknix--prompt-truncate-for-display (prompt max-len)
          "Truncate PROMPT to MAX-LEN chars, collapsing newlines to ↵."
          (let* ((collapsed (replace-regexp-in-string "[\n\r]+" " ↵ " prompt))
                 (trimmed (string-trim collapsed)))
            (if (<= (length trimmed) max-len)
                trimmed
              (concat (substring trimmed 0 (- max-len 1)) "…"))))

        (defun decknix-agent-compose-search-history ()
          "Search prompt history using consult with fuzzy matching.
Selected prompt replaces the compose buffer content.
Works in both compose buffers and agent-shell buffers."
          (interactive)
          (require 'consult)
          (let* ((all-prompts (decknix--prompt-search-get))
                 ;; Build candidates: truncated display → full prompt
                 (candidates
                  (mapcar (lambda (p)
                            (cons (decknix--prompt-truncate-for-display p 120) p))
                          all-prompts))
                 (selected
                  (consult--read
                   (mapcar #'car candidates)
                   :prompt "Search prompts: "
                   :sort nil
                   :require-match t
                   :category 'decknix-prompt
                   :history 'decknix--prompt-search-minibuffer-history))
                 (full-prompt (cdr (assoc selected candidates))))
            (when full-prompt
              ;; Insert into compose buffer or show in message
              (if (bound-and-true-p decknix-agent-compose-mode)
                  (progn
                    (erase-buffer)
                    (insert full-prompt)
                    (goto-char (point-max))
                    ;; Reset M-p/M-n state since we jumped
                    (setq decknix--compose-history-index -1
                          decknix--compose-saved-input nil
                          decknix--compose-history-items nil
                          decknix--compose-history-seen nil
                          decknix--compose-history-file-queue nil
                          decknix--compose-history-exhausted nil
                          decknix--compose-history-local-only t))
                ;; In agent-shell buffer: open compose with this prompt
                (let ((target (current-buffer)))
                  (decknix--compose-get-or-create target)
                  (erase-buffer)
                  (insert full-prompt)
                  (goto-char (point-max)))))))

        (defvar decknix--prompt-search-minibuffer-history nil
          "Minibuffer history for prompt search.")

        (defcustom decknix-agent-compose-sticky nil
          "When non-nil, the compose editor stays open after submit/cancel.
Toggle with \\[decknix-agent-compose-toggle-sticky] in the compose buffer."
          :type 'boolean
          :group 'decknix)

        (defvar-local decknix--compose-sticky nil
          "Buffer-local sticky state for this compose buffer.")

        (defvar decknix-agent-compose-interrupt-map
          (let ((map (make-sparse-keymap)))
            (define-key map (kbd "k") #'decknix-agent-compose-interrupt-agent)
            (define-key map (kbd "C-c") #'decknix-agent-compose-interrupt-and-submit)
            map)
          "Sub-keymap under C-c k in compose mode.
\\`k' interrupts the agent, \\`C-c' interrupts and submits.")

        ;; -- Compose → parent buffer forwarding commands --
        ;; These let you invoke parent agent-shell commands without
        ;; closing the compose window first.

        (defun decknix-compose--forward-to-parent (cmd)
          "Run CMD interactively in the compose target (parent) buffer."
          (when-let ((target (and (boundp 'decknix--compose-target-buffer)
                                  decknix--compose-target-buffer))
                     ((buffer-live-p target)))
            (with-current-buffer target
              (call-interactively cmd))))

        (defun decknix-compose-jump ()
          "Jump to next pending session (forwarded to parent)."
          (interactive)
          (if (fboundp 'agent-shell-attention-jump)
              (call-interactively 'agent-shell-attention-jump)
            (message "agent-shell-attention not loaded")))

        (defun decknix-compose-workspace-toggle ()
          "Toggle Agents workspace (forwarded to parent)."
          (interactive)
          (if (fboundp 'agent-shell-workspace-toggle)
              (call-interactively 'agent-shell-workspace-toggle)
            (message "agent-shell-workspace not loaded")))

        (defun decknix-compose-session-picker ()
          "Open session picker (forwarded to parent)."
          (interactive)
          (decknix-compose--forward-to-parent 'decknix-session-picker))

        (defun decknix-compose-context-panel ()
          "Open context panel (forwarded to parent)."
          (interactive)
          (when (fboundp 'decknix-context-panel)
            (decknix-compose--forward-to-parent 'decknix-context-panel)))

        (defun decknix-compose-tags ()
          "Show session tags (forwarded to parent)."
          (interactive)
          (when (fboundp 'decknix-session-tags-show)
            (decknix-compose--forward-to-parent 'decknix-session-tags-show)))

        (defvar decknix-agent-compose-mode-map
          (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'decknix-agent-compose-submit)
            (define-key map (kbd "C-c C-k") #'decknix-agent-compose-cancel)
            (define-key map (kbd "C-c C-q") #'decknix-agent-compose-close)
            (define-key map (kbd "C-c C-s") #'decknix-agent-compose-toggle-sticky)
            (define-key map (kbd "C-c k") decknix-agent-compose-interrupt-map)
            (define-key map (kbd "M-p") #'decknix-agent-compose-previous-input)
            (define-key map (kbd "M-n") #'decknix-agent-compose-next-input)
            (define-key map (kbd "M-P") #'decknix-agent-compose-previous-input-global)
            (define-key map (kbd "M-N") #'decknix-agent-compose-next-input-global)
            (define-key map (kbd "M-r") #'decknix-agent-compose-search-history)
            ;; Forward parent buffer commands
            (define-key map (kbd "C-c j") #'decknix-compose-jump)
            (define-key map (kbd "C-c w") #'decknix-compose-workspace-toggle)
            (define-key map (kbd "C-c s") #'decknix-compose-session-picker)
            (define-key map (kbd "C-c i") #'decknix-compose-context-panel)
            (define-key map (kbd "C-c T") #'decknix-compose-tags)
            map)
          "Keymap for `decknix-agent-compose-mode'.")

        ;; which-key labels for compose mode keybindings
        (with-eval-after-load 'which-key
          (which-key-add-keymap-based-replacements decknix-agent-compose-mode-map
            "C-c C-c" "submit"
            "C-c C-k" "clear/cancel"
            "C-c C-q" "close"
            "C-c C-s" "toggle sticky"
            "C-c k"   "interrupt…"
            "C-c j"   "jump pending"
            "C-c w"   "workspace"
            "C-c s"   "sessions"
            "C-c i"   "context"
            "C-c T"   "tags")
          (which-key-add-keymap-based-replacements decknix-agent-compose-interrupt-map
            "k"   "interrupt agent"
            "C-c" "interrupt+submit"))

        (define-minor-mode decknix-agent-compose-mode
          "Minor mode for composing agent-shell prompts.
\\<decknix-agent-compose-mode-map>
\\[decknix-agent-compose-submit] submit, \
\\[decknix-agent-compose-cancel] cancel/clear, \
\\[decknix-agent-compose-close] close, \
\\[decknix-agent-compose-toggle-sticky] toggle sticky.
C-c k k interrupt agent, C-c k C-c interrupt & submit."
          :lighter (:eval (if decknix--compose-sticky " Compose[sticky]" " Compose"))
          :keymap decknix-agent-compose-mode-map)

        (defun decknix--compose-finish ()
          "Finish a compose action: clear if sticky, close if transient.
Resets prompt history navigation state."
          ;; Reset all history navigation state (rebuilt on next M-p)
          (setq decknix--compose-history-index -1
                decknix--compose-saved-input nil
                decknix--compose-history-items nil
                decknix--compose-history-seen nil
                decknix--compose-history-file-queue nil
                decknix--compose-history-exhausted nil
                decknix--compose-history-local-only t)
          (if decknix--compose-sticky
              (progn
                (erase-buffer)
                (set-buffer-modified-p nil))
            (let ((win (selected-window)))
              (quit-restore-window win 'kill))))

        (defun decknix-agent-compose-submit ()
          "Submit the compose buffer content to the agent-shell.
If the agent is busy, warns the user and offers to interrupt first.
Use C-c k k to pre-emptively interrupt, then C-c C-c to submit cleanly."
          (interactive)
          (let ((input (string-trim (buffer-string)))
                (target decknix--compose-target-buffer))
            (if (string-empty-p input)
                (user-error "Empty prompt — nothing to submit")
              ;; Check if the agent is busy
              (when (and (buffer-live-p target)
                         (with-current-buffer target
                           (bound-and-true-p shell-maker--busy)))
                (unless (y-or-n-p
                         "Agent is busy — interrupt and submit? (C-c k k to pre-interrupt) ")
                  (user-error "Submit cancelled — agent is still processing"))
                ;; User said yes — interrupt first
                (with-current-buffer target
                  (when (fboundp 'agent-shell-interrupt)
                    (let ((agent-shell-confirm-interrupt nil))
                      (agent-shell-interrupt))))
                (sit-for 0.3))
              ;; Verify the agent process is alive before submitting
              (unless (and (buffer-live-p target)
                           (get-buffer-process target)
                           (process-live-p (get-buffer-process target)))
                (user-error "Agent process not running — wait for it to start or restart with C-c A a"))
              ;; Clear or close the compose buffer
              (decknix--compose-finish)
              ;; Submit to the agent-shell buffer
              (with-current-buffer target
                (goto-char (point-max))
                (shell-maker-submit :input input)))))

        (defun decknix-agent-compose-interrupt-agent ()
          "Pre-emptively interrupt the agent without submitting.
After interrupting, you can compose your message and submit with
\\[decknix-agent-compose-submit] without the busy prompt."
          (interactive)
          (let ((target decknix--compose-target-buffer))
            (if (and (buffer-live-p target)
                     (with-current-buffer target
                       (bound-and-true-p shell-maker--busy)))
                (progn
                  (with-current-buffer target
                    (when (fboundp 'agent-shell-interrupt)
                      (let ((agent-shell-confirm-interrupt nil))
                        (agent-shell-interrupt))))
                  (message "Agent interrupted. Compose your message and C-c C-c to submit."))
              (message "Agent is not busy."))))

        (defun decknix-agent-compose-interrupt-and-submit ()
          "Interrupt any in-progress agent response, then submit the compose buffer.
Use this when the agent is processing and you want to interject immediately
rather than waiting for the current response to complete.
The compose buffer is closed/cleared AFTER the submit, not before."
          (interactive)
          (let ((input (string-trim (buffer-string)))
                (target decknix--compose-target-buffer)
                (compose-buf (current-buffer)))
            (if (string-empty-p input)
                (user-error "Empty prompt — nothing to submit")
              ;; Interrupt the agent first
              (when (buffer-live-p target)
                (with-current-buffer target
                  (when (fboundp 'agent-shell-interrupt)
                    (let ((agent-shell-confirm-interrupt nil))
                      (agent-shell-interrupt)))))
              ;; Submit after a brief delay to let the interrupt settle,
              ;; then close/clear the compose buffer.
              (let ((tgt target)
                    (inp input)
                    (cbuf compose-buf))
                (run-at-time
                 0.3 nil
                 (eval
                  `(lambda ()
                     (when (and (buffer-live-p ,tgt)
                                (get-buffer-process ,tgt)
                                (process-live-p (get-buffer-process ,tgt)))
                       (with-current-buffer ,tgt
                         (goto-char (point-max))
                         (shell-maker-submit :input ,inp)))
                     ;; Now finish (clear/close) the compose buffer
                     (when (buffer-live-p ,cbuf)
                       (with-current-buffer ,cbuf
                         (decknix--compose-finish))))
                  t))))))

        (defun decknix-agent-compose-cancel ()
          "Cancel/clear the compose buffer without submitting.
Sticky mode: clears the buffer. Transient mode: closes the buffer."
          (interactive)
          (decknix--compose-finish)
          (message (if decknix--compose-sticky "Compose cleared." "Compose cancelled.")))

        (defun decknix-agent-compose-close ()
          "Close the compose buffer unconditionally (regardless of sticky mode)."
          (interactive)
          (let ((win (selected-window)))
            (quit-restore-window win 'kill))
          (message "Compose closed."))

        (defun decknix-agent-compose-toggle-sticky ()
          "Toggle sticky mode for the compose buffer.
Sticky: editor stays open after submit/cancel (content is cleared).
Transient: editor closes after submit/cancel."
          (interactive)
          (setq decknix--compose-sticky (not decknix--compose-sticky))
          (decknix--compose-update-header-line)
          (force-mode-line-update)
          (message "Compose: %s" (if decknix--compose-sticky "sticky (stays open)" "transient (closes on action)")))

        (defun decknix--compose-update-header-line ()
          "Update the header-line to reflect current sticky state.
Compact header — shows C-c as the action prefix and hints that
which-key will reveal bindings.  Full sequences shown via which-key
after pressing C-c."
          (setq-local header-line-format
                      (list
                       (propertize
                        (if decknix--compose-sticky " ● Compose [sticky]" " ○ Compose")
                        'font-lock-face (if decknix--compose-sticky
                                            'font-lock-constant-face
                                          'font-lock-comment-face))
                       (propertize "  " 'font-lock-face 'font-lock-comment-face)
                       (propertize "C-c" 'font-lock-face 'font-lock-keyword-face)
                       (propertize " actions  " 'font-lock-face 'font-lock-comment-face)
                       (propertize "M-p" 'font-lock-face 'font-lock-keyword-face)
                       (propertize "/" 'font-lock-face 'font-lock-comment-face)
                       (propertize "M-n" 'font-lock-face 'font-lock-keyword-face)
                       (propertize " cycle  " 'font-lock-face 'font-lock-comment-face)
                       (propertize "M-r" 'font-lock-face 'font-lock-keyword-face)
                       (propertize " search" 'font-lock-face 'font-lock-comment-face))))

        (defun decknix--compose-find-target ()
          "Find the agent-shell buffer to target for compose."
          (cond
           ;; Already in an agent-shell buffer
           ((derived-mode-p 'agent-shell-mode)
            (current-buffer))
           ;; In a compose buffer — return its target
           (decknix--compose-target-buffer
            decknix--compose-target-buffer)
           ;; Find the most recent agent-shell buffer
           ((and (fboundp 'agent-shell-buffers)
                 (agent-shell-buffers))
            (car (agent-shell-buffers)))
           (t (user-error
               "No agent-shell buffer found. Start one with C-c A a"))))

        (defun decknix--compose-display-action ()
          "Return a display-buffer action for the compose window.
Uses a bottom side-window so it never steals the workspace sidebar
or other side-windows."
          '((display-buffer-in-side-window)
            (side . bottom)
            (slot . 0)
            (window-height . 10)
            (preserve-size . (nil . t))))

        (defun decknix--compose-get-or-create (target)
          "Get the existing compose buffer for TARGET, or create a new one.
If a compose buffer already exists and is visible, just select it."
          (let* ((compose-name (format "*Compose: %s*" (buffer-name target)))
                 (existing (get-buffer compose-name)))
            (if (and existing (buffer-live-p existing))
                ;; Re-use existing compose buffer
                (progn
                  (unless (get-buffer-window existing)
                    (display-buffer existing
                                   (decknix--compose-display-action)))
                  (select-window (get-buffer-window existing))
                  existing)
              ;; Create new compose buffer
              (let ((compose-buf (generate-new-buffer compose-name)))
                (display-buffer compose-buf
                                (decknix--compose-display-action))
                (select-window (get-buffer-window compose-buf))
                (with-current-buffer compose-buf
                  (text-mode)
                  (decknix-agent-compose-mode 1)
                  ;; Enable yasnippet with agent-shell-mode snippets.
                  ;; The buffer is text-mode, so yas only sees text-mode
                  ;; snippets by default.  yas-activate-extra-mode adds
                  ;; agent-shell-mode's snippet table as well.
                  (when (fboundp 'yas-minor-mode)
                    (yas-minor-mode 1)
                    (yas-activate-extra-mode 'agent-shell-mode))
                  (setq-local decknix--compose-target-buffer target)
                  (setq-local decknix--compose-sticky decknix-agent-compose-sticky)
                  (decknix--compose-update-header-line)
                  (set-buffer-modified-p nil))
                compose-buf))))

        (defun decknix-agent-compose ()
          "Open or focus the compose buffer for writing a multi-line agent prompt.
The buffer opens at the bottom of the frame. Type your prompt
freely (RET for newlines), then:
  C-c C-c    submit (prompts if agent is busy)
  C-c k k    interrupt agent (pre-emptive)
  C-c k C-c  interrupt agent & submit immediately
  C-c C-k    cancel/clear
  C-c C-s    toggle sticky (stays open) / transient (closes)"
          (interactive)
          (let ((target (decknix--compose-find-target)))
            (decknix--compose-get-or-create target)))

        (defun decknix-agent-compose-interrupt ()
          "Interrupt the agent, then open the compose buffer.
Use this when the agent is mid-response and you want to interject."
          (interactive)
          (let ((target (decknix--compose-find-target)))
            ;; Interrupt if busy
            (when (and (buffer-live-p target)
                       (with-current-buffer target
                         (bound-and-true-p shell-maker--busy)))
              (with-current-buffer target
                (when (fboundp 'agent-shell-interrupt)
                  (let ((agent-shell-confirm-interrupt nil))
                    (agent-shell-interrupt))))
              (sit-for 0.3))
            ;; Open/focus compose
            (decknix--compose-get-or-create target)))

        (define-key decknix-agent-prefix-map (kbd "e") 'decknix-agent-compose)               ; Compose prompt
        (define-key decknix-agent-prefix-map (kbd "E") 'decknix-agent-compose-interrupt)      ; Interrupt + compose

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

        ;; == Quick actions: PR review, batch processing ==
        ;; DWIM workflows that create a session with pre-configured name,
        ;; tags, workspace, and auto-send a command.
        ;; Metadata enrichment (author, Jira key, etc.) is deferred to the
        ;; review command itself, keeping initiation instant.

        (defun decknix--agent-parse-pr-url (url)
          "Parse a GitHub PR URL into an alist with owner, repo, number.
Returns nil if URL is not a valid GitHub PR URL.
Handles: https://github.com/OWNER/REPO/pull/NUMBER[/...]"
          (when (string-match
                 "github\\.com/\\([^/]+\\)/\\([^/]+\\)/pull/\\([0-9]+\\)"
                 url)
            (list (cons 'owner (match-string 1 url))
                  (cons 'repo (match-string 2 url))
                  (cons 'number (match-string 3 url)))))

        (defun decknix--agent-clipboard-url ()
          "Return a GitHub PR URL from the kill ring or system clipboard, or nil."
          (let ((text (or (ignore-errors (current-kill 0 t))
                          (ignore-errors
                            (string-trim
                             (shell-command-to-string "pbpaste"))))))
            (when (and text (string-match-p "github\\.com/.*/pull/" text))
              (string-trim text))))

        (defun decknix--agent-quickaction-start (name tags workspace command)
          "Start a quick-action session with NAME, TAGS, WORKSPACE, and auto-send COMMAND.
Creates a new agent session, applies metadata, then subscribes to the
`prompt-ready' event to send COMMAND as soon as the ACP session is
fully established.  Returns immediately."
          (let* ((workspace (expand-file-name workspace))
                 (before-buffers (buffer-list))
                 (augmented-cmd
                  (append agent-shell-auggie-acp-command
                          (list "--workspace-root" workspace)))
                 (config
                  (let ((base (agent-shell-auggie-make-agent-config)))
                    (setf (alist-get :client-maker base)
                          (eval `(lambda (buffer)
                                   (agent-shell--make-acp-client
                                    :command ,(car augmented-cmd)
                                    :command-params ',(cdr augmented-cmd)
                                    :environment-variables
                                    (cond ((map-elt agent-shell-auggie-authentication :none)
                                           agent-shell-auggie-environment)
                                          ((map-elt agent-shell-auggie-authentication :login)
                                           agent-shell-auggie-environment)
                                          (t
                                           (error "Invalid Auggie authentication")))
                                    :context-buffer buffer)) t))
                    base)))
            (let ((default-directory workspace))
              (agent-shell-start :config config))
            (setq decknix--agent-session-cache-time 0)
            (decknix--agent-session-new-post-create
             before-buffers name tags workspace command)
            ;; Find the newly created shell buffer and subscribe to prompt-ready.
            ;; agent-shell-start creates the buffer synchronously (mode-hook fires
            ;; before it returns), so find-new-shell-buffer works immediately.
            (let ((shell-buf (decknix--agent-find-new-shell-buffer before-buffers)))
              (when shell-buf
                (agent-shell-subscribe-to
                 :shell-buffer shell-buf
                 :event 'prompt-ready
                 :on-event
                 (eval `(lambda (_event)
                          (when (buffer-live-p ,shell-buf)
                            (with-current-buffer ,shell-buf
                              (goto-char (point-max))
                              (shell-maker-submit :input ,command))
                            (message "Sent: %s"
                                     (truncate-string-to-width ,command 60))))
                       t))))))

        (defun decknix-agent-review-pr (url)
          "Start a PR review session for URL.
Parses the GitHub PR URL, creates a new session with auto-generated
name and tags, then sends /review-service-pr.  Metadata enrichment
\(author, Jira key, title\) is handled by the review command itself.

Interactively, prompts for URL (defaulting to clipboard if it
looks like a PR URL) and workspace (defaulting to current project)."
          (interactive
           (let* ((default-url (decknix--agent-clipboard-url))
                  (url (read-string
                        (if default-url
                            (format "PR URL [%s]: " default-url)
                          "PR URL: ")
                        nil nil default-url)))
             (list url)))
          ;; Parse and validate
          (let ((parsed (decknix--agent-parse-pr-url url)))
            (unless parsed
              (user-error "Not a valid GitHub PR URL: %s" url))
            (let* ((owner (alist-get 'owner parsed))
                   (repo (alist-get 'repo parsed))
                   (number (alist-get 'number parsed))
                   ;; Auto-generate session name: pr-<repo>-<number>
                   (name (format "pr-%s-%s" repo number))
                   ;; Tags: review + repo + PR number for distinguishability
                   (tags (list "review" repo (format "#%s" number)))
                   ;; Workspace: smart detection from PR URL
                   ;; Priority: saved workspace → workspace-roots → project root → cwd
                   (default-ws (decknix--agent-pr-detect-workspace owner repo))
                   (workspace (read-directory-name
                               (format "Workspace for %s/%s#%s: "
                                       owner repo number)
                               default-ws nil t))
                   ;; Confirm name
                   (name (read-string (format "Session name [%s]: " name)
                                      nil nil name))
                   (command (format "/review-service-pr %s" url)))
              (decknix--agent-quickaction-start name tags workspace command)
              (message "Starting review: %s/%s#%s" owner repo number))))

        ;; == Batch processing: launch multiple sessions from a compose editor ==
        ;; Syntax:
        ;;   --- <group-name> [: <workspace>]
        ;;   <url-or-item>
        ;;   <url-or-item>
        ;;
        ;;   --- <another-group> [: <workspace>]
        ;;   <url-or-item>
        ;;
        ;;   <ungrouped-url>          ← gets its own session
        ;;
        ;; Lines within a group share a single session.
        ;; Ungrouped lines each get their own session.
        ;; Default workspace is the current project root.

        (defvar decknix--batch-default-workspace nil
          "Default workspace for the current batch editor.")

        (defun decknix--batch-parse-buffer ()
          "Parse the batch editor buffer into a list of session specs.
Each spec is an alist with keys: name, workspace, items, grouped."
          (let ((specs nil)
                (current-group nil)
                (current-items nil)
                (current-ws decknix--batch-default-workspace)
                (current-name nil))
            (save-excursion
              (goto-char (point-min))
              (while (not (eobp))
                (let ((line (string-trim
                             (buffer-substring-no-properties
                              (line-beginning-position)
                              (line-end-position)))))
                  (cond
                   ;; Divider: --- <name> [: <workspace>]
                   ((string-match "^---\\s-+\\(.+\\)" line)
                    ;; Flush previous group if any
                    (when (and current-name current-items)
                      (push (list (cons 'name current-name)
                                  (cons 'workspace current-ws)
                                  (cons 'items (nreverse current-items))
                                  (cons 'grouped t))
                            specs))
                    ;; Parse new group header
                    (let ((header (match-string 1 line)))
                      (if (string-match "^\\(.+?\\)\\s-*:\\s-*\\(\\S-+.*\\)" header)
                          (progn
                            (setq current-name (string-trim (match-string 1 header)))
                            (setq current-ws (expand-file-name
                                              (string-trim (match-string 2 header)))))
                        (setq current-name (string-trim header))
                        (setq current-ws decknix--batch-default-workspace)))
                    (setq current-items nil))
                   ;; Empty line or comment — skip
                   ((or (string-empty-p line)
                        (string-prefix-p "#" line))
                    nil)
                   ;; Content line
                   (t
                    (if current-name
                        ;; Inside a group
                        (push line current-items)
                      ;; Ungrouped — each line is its own session
                      (let* ((parsed (decknix--agent-parse-pr-url line))
                             (auto-name (if parsed
                                            (format "pr-%s-%s"
                                                    (alist-get 'repo parsed)
                                                    (alist-get 'number parsed))
                                          (format "review-%s"
                                                  (substring
                                                   (secure-hash 'sha256 line)
                                                   0 8))))
                             ;; Auto-detect workspace from PR URL
                             (ws (if parsed
                                     (or (decknix--agent-pr-detect-workspace
                                          (alist-get 'owner parsed)
                                          (alist-get 'repo parsed))
                                         decknix--batch-default-workspace)
                                   decknix--batch-default-workspace)))
                        (push (list (cons 'name auto-name)
                                    (cons 'workspace ws)
                                    (cons 'items (list line))
                                    (cons 'grouped nil))
                              specs))))))
                (forward-line 1)))
            ;; Flush final group
            (when (and current-name current-items)
              (push (list (cons 'name current-name)
                          (cons 'workspace current-ws)
                          (cons 'items (nreverse current-items))
                          (cons 'grouped t))
                    specs))
            (nreverse specs)))

        (defvar decknix--batch-launch-results nil
          "List of (NAME STATUS BUFFER) for the most recent batch launch.")

        (defun decknix--batch-launch (specs)
          "Launch sessions for each spec in SPECS.
Each spec is an alist with name, workspace, items, grouped.
Grouped specs send all items as a single message.
Ungrouped specs send each item via /review-service-pr."
          (setq decknix--batch-launch-results nil)
          (dolist (spec specs)
            (let* ((name (alist-get 'name spec))
                   (items (alist-get 'items spec))
                   (grouped (alist-get 'grouped spec))
                   ;; Build the command to send
                   (command (if grouped
                                ;; Grouped: send all items as one message
                                (mapconcat
                                 (lambda (item)
                                   (format "/review-service-pr %s" item))
                                 items "\n")
                              ;; Ungrouped: single item
                              (format "/review-service-pr %s" (car items))))
                   ;; Tags: review + repo names + PR numbers from parsed URLs
                   (tags (let ((tag-list (list "review")))
                           (dolist (item items)
                             (let ((parsed (decknix--agent-parse-pr-url item)))
                               (when parsed
                                 (cl-pushnew (alist-get 'repo parsed)
                                             tag-list :test #'string=)
                                 (cl-pushnew (format "#%s" (alist-get 'number parsed))
                                             tag-list :test #'string=))))
                           tag-list))
                   ;; Workspace: for grouped items without explicit workspace,
                   ;; auto-detect from the first parseable PR URL
                   (workspace
                    (let ((ws (alist-get 'workspace spec)))
                      (if (and grouped
                               (string= ws decknix--batch-default-workspace))
                          ;; Try auto-detecting from the first PR URL
                          (or (cl-some
                               (lambda (item)
                                 (let ((parsed (decknix--agent-parse-pr-url item)))
                                   (when parsed
                                     (decknix--agent-pr-detect-workspace
                                      (alist-get 'owner parsed)
                                      (alist-get 'repo parsed)))))
                               items)
                              ws)
                        ws))))
              (condition-case err
                  (progn
                    (decknix--agent-quickaction-start name tags workspace command)
                    (push (list name "launched" nil) decknix--batch-launch-results))
                (error
                 (push (list name "failed" (error-message-string err))
                       decknix--batch-launch-results)))))
          (setq decknix--batch-launch-results
                (nreverse decknix--batch-launch-results))
          ;; Show summary
          (decknix--batch-show-summary))

        (defun decknix--batch-show-summary ()
          "Display a summary buffer of the batch launch results."
          (let ((buf (get-buffer-create "*Batch Launch*")))
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert (propertize "Batch Launch Summary\n"
                                    'font-lock-face '(:weight bold :height 1.2)))
                (insert (propertize (make-string 40 ?═)
                                    'font-lock-face 'font-lock-comment-face)
                        "\n\n")
                (dolist (result decknix--batch-launch-results)
                  (let ((name (nth 0 result))
                        (status (nth 1 result))
                        (err (nth 2 result)))
                    (insert (propertize
                             (if (string= status "launched") "✓ " "✗ ")
                             'font-lock-face
                             (if (string= status "launched")
                                 'success 'error))
                            (propertize name 'font-lock-face '(:weight bold))
                            (format "  — %s" status)
                            (if err (format " (%s)" err) "")
                            "\n")))
                (insert "\n"
                        (propertize (format "%d sessions launched"
                                           (length decknix--batch-launch-results))
                                    'font-lock-face 'font-lock-comment-face)
                        "\n\n"
                        (propertize "Press q to close.\n"
                                    'font-lock-face 'font-lock-comment-face))
                (special-mode)
                (goto-char (point-min))))
            (display-buffer buf
                            '((display-buffer-at-bottom)
                              (window-height . fit-window-to-buffer)))))

        ;; -- Batch compose minor mode for syntax highlighting --

        (defvar decknix-batch-compose-mode-map
          (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") 'decknix--batch-submit)
            (define-key map (kbd "C-c C-k") 'decknix--batch-cancel)
            map)
          "Keymap for `decknix-batch-compose-mode'.")

        (defun decknix--batch-submit ()
          "Parse and launch all sessions from the batch editor."
          (interactive)
          (let ((specs (decknix--batch-parse-buffer)))
            (if (null specs)
                (user-error "No items to process — add URLs or groups")
              (when (y-or-n-p (format "Launch %d session(s)? "
                                      (length specs)))
                (let ((buf (current-buffer)))
                  (decknix--batch-launch specs)
                  (when (buffer-live-p buf)
                    (kill-buffer buf)))))))

        (defun decknix--batch-cancel ()
          "Cancel the batch editor."
          (interactive)
          (when (y-or-n-p "Cancel batch? ")
            (kill-buffer (current-buffer))))

        (defvar decknix--batch-font-lock-keywords
          (list
           ;; --- divider lines (group headers)
           (list "^---\\s-+\\(.+?\\)\\(\\s-*:\\s-*\\(\\S-+.*\\)\\)?$"
                 '(0 'font-lock-keyword-face t)
                 '(1 'font-lock-function-name-face t)
                 '(3 'font-lock-string-face t t))
           ;; GitHub PR URLs
           (list "https?://github\\.com/[^ \t\n]+"
                 '(0 'link t))
           ;; Comments
           (list "^#.*$"
                 '(0 'font-lock-comment-face t)))
          "Font-lock keywords for batch compose mode.")

        (define-minor-mode decknix-batch-compose-mode
          "Minor mode for the batch session editor.
Provides syntax highlighting for --- dividers, URLs, and comments.
\\<decknix-batch-compose-mode-map>
\\[decknix--batch-submit]  Submit — parse and launch all sessions.
\\[decknix--batch-cancel]  Cancel — close without launching."
          :lighter " Batch"
          :keymap decknix-batch-compose-mode-map
          (if decknix-batch-compose-mode
              (progn
                (font-lock-add-keywords nil decknix--batch-font-lock-keywords)
                (setq-local header-line-format
                            (list
                             (propertize
                              " Batch: C-c C-c submit | C-c C-k cancel"
                              'face 'header-line)))
                ;; Enable yasnippet with batch-compose-mode snippets
                ;; (--- groups, PR URLs, workspace templates)
                (when (fboundp 'yas-minor-mode)
                  (yas-minor-mode 1)
                  (yas-activate-extra-mode 'decknix-batch-compose-mode))
                (font-lock-flush))
            (font-lock-remove-keywords nil decknix--batch-font-lock-keywords)
            (setq-local header-line-format nil)
            (font-lock-flush)))

        (defun decknix-agent-batch-process ()
          "Open a batch compose editor for launching multiple sessions.
Syntax:
  --- <group-name> [: <workspace>]
  <url>
  <url>

  --- <another-group> [: ~/other/path]
  <url>

  <ungrouped-url>

Lines within a --- group share a single session.
Ungrouped lines each get their own session.
Comments start with #."
          (interactive)
          (let* ((default-ws (decknix--agent-detect-workspace))
                 (buf (generate-new-buffer "*Batch Process*")))
            (display-buffer buf
                            '((display-buffer-at-bottom)
                              (window-height . 15)
                              (dedicated . t)))
            (select-window (get-buffer-window buf))
            (with-current-buffer buf
              (text-mode)
              (setq-local decknix--batch-default-workspace default-ws)
              (decknix-batch-compose-mode 1)
              ;; Insert template
              (insert (format "# Batch session launcher — workspace: %s\n"
                              default-ws)
                      "# Syntax: --- <name> [: <workspace>]\n"
                      "#         <url-per-line>\n"
                      "# Ungrouped URLs get individual sessions.\n"
                      "# C-c C-c to launch, C-c C-k to cancel.\n\n")
              (set-buffer-modified-p nil))))

        ;; C-c A c — commands sub-prefix ("Commands")
        (define-prefix-command 'decknix-agent-command-map)
        (define-key decknix-agent-prefix-map (kbd "c") 'decknix-agent-command-map)
        (define-key decknix-agent-command-map (kbd "c") 'decknix-agent-command-run)    ; Pick & insert
        (define-key decknix-agent-command-map (kbd "n") 'decknix-agent-command-new)    ; New
        (define-key decknix-agent-command-map (kbd "e") 'decknix-agent-command-edit)   ; Edit
        (define-key decknix-agent-command-map (kbd "r") 'decknix-agent-review-pr)      ; PR review
        (define-key decknix-agent-command-map (kbd "B") 'decknix-agent-batch-process)  ; Batch

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

        ;; -- Buffer isolation: teach workspace that compose/batch buffers
        ;; belong in the Agents tab.  Without this, opening compose
        ;; triggers the redirect rule which switches away from the Agents
        ;; tab and collapses the sidebar.
        (advice-add 'agent-shell-workspace--agent-buffer-p :around
          (lambda (orig-fn buffer)
            (or (funcall orig-fn buffer)
                (when (and buffer (buffer-live-p buffer))
                  (with-current-buffer buffer
                    (or (bound-and-true-p decknix-agent-compose-mode)
                        (bound-and-true-p decknix-batch-compose-mode)
                        (string-match-p "\\*Compose:.*\\*\\|\\*Batch" (buffer-name buffer))))))))

        ;; -- Agent kind & config: the upstream functions parse buffer names
        ;; expecting "<Kind> Agent @ <workspace>" but ours are "*Auggie: <name>*".
        ;; Advise to extract agent kind from agent-shell--state instead.
        (advice-add 'agent-shell-workspace--agent-kind :around
          (lambda (orig-fn buffer)
            (let ((result (funcall orig-fn buffer)))
              (if (not (string= result "-"))
                  result
                ;; Fallback: get from agent-shell state
                (or (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (when (boundp 'agent-shell--state)
                          (map-nested-elt agent-shell--state
                                          '(:agent-config :buffer-name)))))
                    "-")))))

        (advice-add 'agent-shell-workspace--buffer-config :around
          (lambda (orig-fn buffer)
            (or (funcall orig-fn buffer)
                ;; Fallback: get config from agent-shell state
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (when (and (derived-mode-p 'agent-shell-mode)
                               (boundp 'agent-shell--state))
                      (map-elt agent-shell--state :agent-config)))))))

        ;; -- Short-name: handle *Auggie: <name>* naming convention.
        ;; The default looks for " @ " which our buffers don't use.
        ;; Extract the part after "*Auggie: " and show tags when available.
        (advice-add 'agent-shell-workspace--short-name :around
          (lambda (orig-fn buffer)
            (let* ((name (buffer-name buffer))
                   ;; Match *Auggie: <name>* or *<Type>: <name>*
                   (short (if (string-match "\\*[^:]+: \\(.+\\)\\*" name)
                              (match-string 1 name)
                            (funcall orig-fn buffer)))
                   ;; Append tags if we have them
                   (tags (when (and (boundp 'decknix--sessions-data)
                                    decknix--sessions-data
                                    (fboundp 'decknix--session-conv-id))
                           (with-current-buffer buffer
                             (when-let ((cid (ignore-errors (decknix--session-conv-id)))
                                        (entry (assoc cid decknix--sessions-data)))
                               (cdr (assoc 'tags (cdr entry))))))))
              (if (and tags (> (length tags) 0))
                  (format "%s %s" short
                          (mapconcat (lambda (tag) (concat "#" tag)) tags " "))
                short))))

        ;; -- Sidebar width cycling (inspired by treemacs) --
        ;; W cycles: default (24) → fit-to-content → wide (48) → default.
        (defvar decknix--sidebar-width-state 'default
          "Current sidebar width state: default, fit, or wide.")

        (defun decknix-sidebar-cycle-width ()
          "Cycle sidebar width: default → fit-to-content → wide → default.
Like treemacs `W' / extra-wide-toggle."
          (interactive)
          (let* ((win (get-buffer-window
                       agent-shell-workspace-sidebar-buffer-name))
                 (default-w agent-shell-workspace-sidebar-width)
                 (wide-w (* 2 default-w)))
            (when (and win (window-live-p win))
              (pcase decknix--sidebar-width-state
                ('default
                 ;; Fit to content: measure longest line
                 (let ((max-len 0))
                   (with-current-buffer (window-buffer win)
                     (save-excursion
                       (goto-char (point-min))
                       (while (not (eobp))
                         (setq max-len
                               (max max-len (- (line-end-position)
                                               (line-beginning-position))))
                         (forward-line 1))))
                   (let ((fit-w (max default-w (+ max-len 2))))
                     (window-resize win (- fit-w (window-width win)) t)))
                 (setq decknix--sidebar-width-state 'fit)
                 (message "Sidebar: fit-to-content"))
                ('fit
                 (window-resize win (- wide-w (window-width win)) t)
                 (setq decknix--sidebar-width-state 'wide)
                 (message "Sidebar: wide (%d)" wide-w))
                ('wide
                 (window-resize win (- default-w (window-width win)) t)
                 (setq decknix--sidebar-width-state 'default)
                 (message "Sidebar: default (%d)" default-w))))))

        ;; -- Sidebar help command --
        (defun decknix-sidebar-help ()
          "Show sidebar keybinding help in minibuffer."
          (interactive)
          (message (concat
            "RET goto  c new  k kill  r restart  R rename  d del-killed  "
            "s switch  a/x/t tile  W width  g refresh  q quit")))

        ;; -- Enhanced sidebar render: live + saved sessions + key footer --
        ;; Override the upstream render to add saved sessions grouped by
        ;; workspace and a vertical key-help footer below the session lists.
        (defvar decknix--sidebar-max-saved 8
          "Maximum number of recent saved conversations to show in sidebar.")

        (defun decknix--sidebar-render-section-header (title)
          "Insert a section header TITLE into the sidebar."
          (insert (propertize (concat " " title) 'face 'bold) "\n"))

        (defun decknix--sidebar-render-footer ()
          "Insert vertical key-help footer at bottom of sidebar."
          (insert "\n")
          (let ((keys '(("RET" . "open")
                        ("c"   . "new session")
                        ("k"   . "kill")
                        ("r"   . "restart")
                        ("R"   . "rename")
                        ("s"   . "quick-switch")
                        ("a/x" . "tile add/rm")
                        ("t"   . "tile toggle")
                        ("W"   . "cycle width")
                        ("g"   . "refresh")
                        ("?"   . "help")
                        ("q"   . "quit"))))
            (dolist (kv keys)
              (insert (propertize
                       (format " %3s %s" (car kv) (cdr kv))
                       'face 'font-lock-comment-face)
                      "\n"))))

        (defun decknix--sidebar-abbreviate-workspace (path)
          "Abbreviate PATH for sidebar display."
          (if (null path) "?"
            (let ((abbr (abbreviate-file-name path)))
              ;; Extract last path component for compact display
              (if (string-match "/\\([^/]+\\)/?$" abbr)
                  (match-string 1 abbr)
                abbr))))

        (defun decknix--sidebar-saved-sessions ()
          "Return recent saved conversations as alist of (name workspace conv-key session).
Grouped by workspace, limited to `decknix--sidebar-max-saved'."
          (condition-case nil
              (let* ((sessions (decknix--agent-session-list))
                     (groups (when sessions
                               (decknix--agent-session-group-by-conversation
                                sessions)))
                     (result nil)
                     (count 0))
                ;; Collect up to max-saved conversations (already sorted newest first)
                (dolist (group groups)
                  (when (< count decknix--sidebar-max-saved)
                    (let* ((conv-key (car group))
                           (latest (cadr group))
                           (name (decknix--agent-session-display-name latest))
                           (workspace (when conv-key
                                        (decknix--agent-workspace-for-conv-key
                                         conv-key)))
                           (modified (alist-get 'modified latest)))
                      ;; Skip if this conversation is already live
                      (unless (seq-find
                               (lambda (buf)
                                 (when (buffer-live-p buf)
                                   (with-current-buffer buf
                                     (when (boundp 'agent-shell--state)
                                       (let* ((fm (alist-get 'firstUserMessage latest ""))
                                              (ck (decknix--agent-conversation-key fm)))
                                         (equal ck (ignore-errors
                                                     (decknix--session-conv-id))))))))
                               (agent-shell-buffers))
                        (push (list name workspace conv-key latest modified) result)
                        (setq count (1+ count))))))
                (nreverse result))
            (error nil)))

        (advice-add 'agent-shell-workspace-sidebar--render :override
          (lambda ()
            "Render sidebar with live sessions, saved sessions, and key footer."
            (let* ((buffers (sort (copy-sequence
                                   (seq-filter #'buffer-live-p (agent-shell-buffers)))
                                  (lambda (a b)
                                    (string< (agent-shell-workspace--short-name a)
                                             (agent-shell-workspace--short-name b)))))
                   (selected agent-shell-workspace-sidebar--selected-buffer)
                   (tiled agent-shell-workspace--tiled-buffers)
                   (inhibit-read-only t)
                   (target-line nil)
                   (max-name-width (when buffers
                                     (apply #'max
                                            (mapcar (lambda (buf)
                                                      (length
                                                       (agent-shell-workspace--short-name buf)))
                                                    buffers))))
                   (saved (decknix--sidebar-saved-sessions))
                   (line-num 0))
              (erase-buffer)

              ;; ── Live Sessions ──
              (decknix--sidebar-render-section-header
               (format "Live (%d)" (length buffers)))
              (setq line-num (1+ line-num)) ;; section header line
              (if (null buffers)
                  (progn
                    (insert (propertize "  (none)" 'face 'font-lock-comment-face) "\n")
                    (setq line-num (1+ line-num)))
                (dolist (buf buffers)
                  (let* ((agent-icon (agent-shell-workspace--agent-icon buf))
                         (status (agent-shell-workspace--track-status
                                  buf (agent-shell-workspace--buffer-status buf)))
                         (status-face (agent-shell-workspace--status-face status))
                         (short-name (agent-shell-workspace--short-name buf))
                         (tile-indicator (if (memq buf tiled) " ▫" ""))
                         (display-face (if (string= status "finished") "cyan" status-face))
                         (logo-box (agent-shell-workspace--make-logo-box
                                    agent-icon display-face))
                         (name-box (agent-shell-workspace--make-name-box
                                    short-name display-face max-name-width))
                         (name-box-styled
                          (if (string= status "waiting")
                              (propertize name-box 'face '(:background "#3a1515"))
                            name-box))
                         (selection-indicator (if (eq buf selected) ">" " "))
                         (line (concat selection-indicator " "
                                      logo-box name-box-styled tile-indicator)))
                    (setq line-num (1+ line-num))
                    (when (eq buf selected)
                      (setq target-line line-num))
                    (setq line (propertize line
                                          'agent-shell-workspace-buffer buf))
                    (insert line "\n"))))

              ;; ── Saved Sessions (grouped by workspace) ──
              (when saved
                (insert "\n")
                (setq line-num (1+ line-num)) ;; blank line
                (decknix--sidebar-render-section-header
                 (format "Recent (%d)" (length saved)))
                (setq line-num (1+ line-num)) ;; section header
                ;; Group by workspace for display
                (let ((by-ws (make-hash-table :test 'equal)))
                  (dolist (entry saved)
                    (let* ((ws (or (nth 1 entry) "unknown"))
                           (existing (gethash ws by-ws)))
                      (puthash ws (append existing (list entry)) by-ws)))
                  ;; Render each workspace group
                  (let ((ws-keys (sort (hash-table-keys by-ws) #'string<)))
                    (dolist (ws ws-keys)
                      ;; Workspace sub-header
                      (let ((ws-label (decknix--sidebar-abbreviate-workspace ws)))
                        (insert (propertize (format "  %s" ws-label)
                                           'face 'font-lock-type-face)
                                "\n")
                        (setq line-num (1+ line-num)))
                      ;; Sessions under this workspace
                      (dolist (entry (gethash ws by-ws))
                        (let* ((name (nth 0 entry))
                               (conv-key (nth 2 entry))
                               (session (nth 3 entry))
                               (modified (nth 4 entry))
                               (time-str (if modified
                                             (decknix--agent-session-time-ago modified)
                                           ""))
                               (display (format "   %-14s %s"
                                                (truncate-string-to-width
                                                 (or name "?") 14 nil nil "…")
                                                (propertize time-str
                                                            'face 'font-lock-comment-face))))
                          (insert (propertize display
                                             'decknix-sidebar-saved-session session
                                             'decknix-sidebar-saved-conv-key conv-key
                                             'decknix-sidebar-saved-workspace (nth 1 entry))
                                  "\n")
                          (setq line-num (1+ line-num))))))))

              ;; ── Key help footer ──
              (decknix--sidebar-render-footer)

              ;; Restore cursor
              (goto-char (point-min))
              (when target-line
                (forward-line (1- target-line))))))

        ;; -- Sidebar goto: handle both live and saved sessions --
        (advice-add 'agent-shell-workspace-sidebar-goto :around
          (lambda (orig-fn)
            "Open live buffer at point, or resume saved session."
            (let ((saved (get-text-property
                          (line-beginning-position)
                          'decknix-sidebar-saved-session)))
              (if saved
                  ;; Resume saved session
                  (let* ((conv-key (get-text-property
                                    (line-beginning-position)
                                    'decknix-sidebar-saved-conv-key))
                         (workspace (get-text-property
                                     (line-beginning-position)
                                     'decknix-sidebar-saved-workspace))
                         (session-id (alist-get 'sessionId saved))
                         (name (decknix--agent-session-display-name saved)))
                    (when session-id
                      ;; If no workspace, prompt
                      (unless workspace
                        (setq workspace
                              (read-directory-name "Workspace: " nil nil t)))
                      (let ((conv-key (decknix--agent-conversation-key
                                       (alist-get 'firstUserMessage
                                                  saved ""))))
                        (decknix--agent-session-resume
                         session-id
                         decknix-agent-session-history-count
                         name workspace conv-key))))
                ;; Default: live buffer
                (funcall orig-fn)))))

        ;; -- Summary header-line --
        (add-hook 'agent-shell-workspace-sidebar-mode-hook
          (lambda ()
            (setq header-line-format
                  '(:eval
                    (let* ((live (length (seq-filter #'buffer-live-p
                                                     (agent-shell-buffers))))
                           (saved-count (condition-case nil
                                            (length (decknix--agent-session-group-by-conversation
                                                     (decknix--agent-session-list)))
                                          (error 0))))
                      (propertize
                       (format " ● %d live  ◦ %d saved" live saved-count)
                       'face 'font-lock-keyword-face))))))

        ;; -- Bind keys in sidebar mode --
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "?") #'decknix-sidebar-help)
        (define-key agent-shell-workspace-sidebar-mode-map
          (kbd "W") #'decknix-sidebar-cycle-width)

        ;; which-key labels for sidebar mode
        (with-eval-after-load 'which-key
          (which-key-add-keymap-based-replacements agent-shell-workspace-sidebar-mode-map
            "c" "new agent"
            "k" "kill"
            "r" "restart"
            "R" "rename"
            "d" "delete killed"
            "s" "quick-switch"
            "a" "tile add"
            "x" "tile remove"
            "t" "tile toggle"
            "g" "refresh"
            "M" "cycle mode"
            "m" "set mode"
            "q" "quit"
            "?" "help"
            "W" "cycle width"
            "h" "help"))
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
          "Update the header-line-format for the current agent-shell buffer.
Delegates to the unified header which incorporates context data."
          (when (derived-mode-p 'agent-shell-mode)
            (decknix--header-update)))
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
        ;; Register snippet directories for agent-shell and batch-compose modes
        (with-eval-after-load 'yasnippet
          (dolist (dir (list (expand-file-name "~/${snippetDir}")
                             (expand-file-name "~/${batchSnippetDir}")))
            (unless (member dir yas-snippet-dirs)
              (push dir yas-snippet-dirs))
            (when (file-directory-p dir)
              (yas-load-directory dir))))

        ;; C-c A t — template sub-prefix ("Templates")
        (define-prefix-command 'decknix-agent-template-map)
        (define-key decknix-agent-prefix-map (kbd "t") 'decknix-agent-template-map)
        (define-key decknix-agent-template-map (kbd "t") 'yas-insert-snippet)       ; Insert
        (define-key decknix-agent-template-map (kbd "n") 'yas-new-snippet)          ; New
        (define-key decknix-agent-template-map (kbd "e") 'yas-visit-snippet-file)   ; Edit
      ''
      + ''

        ;; == Unified header-line: status + tags + workspace + context ==
        ;; Provides at-a-glance session identity and agent state in every
        ;; agent-shell buffer.  Merges with context panel data when available.
        ;; Refreshed every 2 seconds via a buffer-local timer to track
        ;; status transitions (working → ready → finished).

        (defvar-local decknix--header-timer nil
          "Buffer-local timer for refreshing the header-line.")

        (defvar-local decknix--header-prev-status nil
          "Previous raw status string, used to detect transitions.")

        (defun decknix--header-detect-status ()
          "Return the current agent status as a string.
Uses agent-shell-workspace's detection when available (richer states),
otherwise falls back to shell-maker--busy."
          (cond
           ;; Rich detection from agent-shell-workspace
           ((fboundp 'agent-shell-workspace--buffer-status)
            (agent-shell-workspace--buffer-status (current-buffer)))
           ;; Fallback: shell-maker busy flag
           ((bound-and-true-p shell-maker--busy) "working")
           ;; Check if process is alive
           ((and (get-buffer-process (current-buffer))
                 (process-live-p (get-buffer-process (current-buffer))))
            "ready")
           ((not (get-buffer-process (current-buffer))) "killed")
           (t "unknown")))

        (defun decknix--header-status-icon (status)
          "Return a status icon string for STATUS."
          (pcase status
            ("ready"        "●")
            ("finished"     "✔")
            ("working"      "◐")
            ("waiting"      "◉")
            ("initializing" "○")
            ("killed"       "✕")
            (_              "?")))

        (defun decknix--header-status-face (status)
          "Return a face for STATUS."
          (pcase status
            ("ready"        'success)
            ("finished"     '(:foreground "cyan" :weight bold))
            ("working"      'warning)
            ("waiting"      '(:foreground "red" :weight bold))
            ("initializing" 'font-lock-comment-face)
            ("killed"       'error)
            (_              'shadow)))

        (defun decknix--header-tags ()
          "Return the tag list for the current buffer's conversation, or nil."
          (when (and (boundp 'decknix--agent-auggie-session-id)
                     decknix--agent-auggie-session-id)
            (decknix--agent-tags-for-session
             decknix--agent-auggie-session-id)))

        (defun decknix--header-workspace-short ()
          "Return an abbreviated workspace path for the header-line."
          (when (and (boundp 'decknix--agent-session-workspace)
                     decknix--agent-session-workspace
                     (not (string-empty-p decknix--agent-session-workspace)))
            (abbreviate-file-name decknix--agent-session-workspace)))

        (defun decknix--header-upstream ()
          "Return agent-shell's text header string.
This embeds the upstream header (agent name, model, mode, workspace,
session ID, context/usage indicator, busy animation) so we inherit
any improvements to agent-shell--make-header automatically."
          (ignore-errors
            (when (fboundp 'agent-shell--make-header)
              (let ((agent-shell-header-style 'text))
                (agent-shell--make-header (agent-shell--state))))))

        (defun decknix--header-build ()
          "Build the unified header-line string for the current agent-shell buffer.
Embeds agent-shell's full header (agent name, model, mode, workspace,
busy animation) and appends decknix extras (status icon, tags, context panel)."
          (let* ((raw-status (decknix--header-detect-status))
                 ;; Track transitions: working → ready = finished
                 (status (cond
                          ((and (member decknix--header-prev-status
                                        '("working" "waiting"))
                                (string= raw-status "ready"))
                           "finished")
                          (t raw-status)))
                 (icon (decknix--header-status-icon status))
                 (face (decknix--header-status-face status))
                 (upstream (decknix--header-upstream))
                 (tags (decknix--header-tags))
                 (parts nil))
            ;; Clear "finished" once user returns to the buffer
            (when (and (string= status "finished")
                       (eq (current-buffer) (window-buffer (selected-window))))
              (setq status raw-status))
            ;; Update previous status for next cycle
            (when (member raw-status '("working" "waiting"))
              (setq decknix--header-prev-status raw-status))
            (when (not (member raw-status '("working" "waiting")))
              (setq decknix--header-prev-status nil))
            ;; 1. Status icon + label
            (push (propertize (format " %s %s" icon status)
                              'face face)
                  parts)
            ;; 2. Tags (stable width — before animated upstream)
            (when tags
              (push (propertize
                     (mapconcat (lambda (tg) (format "#%s" tg)) tags " ")
                     'face 'font-lock-type-face)
                    parts))
            ;; 3. Context panel items (stable — before animated upstream)
            (when (fboundp 'decknix--context-header-string)
              (let ((ctx (decknix--context-header-string)))
                (when ctx (push ctx parts))))
            ;; 4. Agent-shell upstream header (agent, model, mode,
            ;;    workspace, session-id, usage, busy animation)
            ;; Placed last so the animated busy indicator expands/contracts
            ;; at the right edge without shifting stable elements.
            (when (and upstream (not (string-empty-p upstream)))
              (push (string-trim upstream) parts))
            ;; Join with separator
            (mapconcat #'identity (nreverse parts) "  │  ")))

        (defun decknix--header-update ()
          "Update the header-line-format for the current agent-shell buffer."
          (when (derived-mode-p 'agent-shell-mode)
            (setq-local header-line-format
                        (list (decknix--header-build)))))

        (defun decknix--header-start-timer ()
          "Start a buffer-local 2-second timer to refresh the header-line."
          (when decknix--header-timer
            (cancel-timer decknix--header-timer))
          (let ((buf (current-buffer)))
            (setq decknix--header-timer
                  (run-with-timer
                   1 2
                   (eval
                    `(lambda ()
                       (when (buffer-live-p ,buf)
                         (with-current-buffer ,buf
                           (decknix--header-update))))
                    t)))))

        (defun decknix--header-stop-timer ()
          "Stop the header-line refresh timer."
          (when decknix--header-timer
            (cancel-timer decknix--header-timer)
            (setq decknix--header-timer nil)))

        ;; Prevent agent-shell's built-in header from overwriting ours.
        ;; agent-shell--update-header-and-mode-line is called from many
        ;; places (mode changes, session updates, busy indicator, etc.)
        ;; and sets header-line-format to its own value.  We override it
        ;; to use our unified header instead, which already incorporates
        ;; status, tags, workspace, and context panel data.
        (advice-add 'agent-shell--update-header-and-mode-line :override
          (lambda (&rest _args)
            "Use the unified decknix header instead of agent-shell's default."
            (when (derived-mode-p 'agent-shell-mode)
              (decknix--header-update)
              (force-mode-line-update))))

        ;; Guard all submit paths against a dead/missing process or config.
        ;; shell-maker-submit is the single entry point for sending input
        ;; (used by RET in the shell buffer, compose C-c C-c, and programmatic calls).
        ;; Without this, submitting before the process has started or after it
        ;; has exited produces: "Wrong type argument: processp, nil" or
        ;; "Wrong type argument: shell-maker-config, nil".
        ;; Uses :around advice so we can block the call entirely.
        (advice-add 'shell-maker-submit :around
                    (lambda (orig-fn &rest args)
                      (if (or (not (boundp 'shell-maker--config))
                              (null shell-maker--config)
                              (not (get-buffer-process (current-buffer)))
                              (not (process-live-p (get-buffer-process (current-buffer)))))
                          (user-error "Agent process not ready — wait for it to start or restart with C-c A a")
                        (apply orig-fn args))))

        ;; TAB dispatch: yas field → corfu complete → yas expand → completion.
        ;; local-set-key overrides both the yas-keymap minor-mode binding
        ;; AND corfu-map, so we must check for both explicitly.
        (defun decknix--agent-tab-dwim ()
          "Smart TAB: yasnippet fields, Corfu completion, snippet expansion, or CAPF.
Priority order:
1. Inside an active yasnippet field → advance to next field
2. Corfu popup visible → accept the selected completion
3. Try yasnippet expansion (returns non-nil on success)
4. Fall back to `completion-at-point'"
          (interactive)
          (cond
           ;; 1. Active snippet field — advance
           ((and (bound-and-true-p yas-minor-mode)
                 (yas--snippets-at-point))
            (yas-next-field-or-maybe-expand))
           ;; 2. Corfu popup visible — accept completion
           ((and (bound-and-true-p corfu-mode)
                 (boundp 'corfu--frame)
                 (frame-live-p corfu--frame)
                 (frame-visible-p corfu--frame))
            (corfu-complete))
           ;; 3. Try snippet expansion (yas-expand returns nil when nothing matched)
           ((and (bound-and-true-p yas-minor-mode)
                 (yas-expand)))
           ;; 4. Fall back to standard completion
           (t (completion-at-point))))

        ;; Disable line numbers in agent-shell buffers
        ;; TAB dispatches between snippet field navigation and expansion
        ;; In-buffer shortcuts: C-c x (no A prefix needed inside agent-shell)
        (add-hook 'agent-shell-mode-hook
                  (lambda ()
                    (display-line-numbers-mode 0)
                    ;; Disable cape-file in agent-shell buffers — synchronous
                    ;; filesystem scans freeze the cursor during typing.
                    (setq-local completion-at-point-functions
                                (remove #'cape-file completion-at-point-functions))
                    ;; Keep prompt pinned to the bottom of the window
                    (setq-local comint-scroll-to-bottom-on-input t)
                    (setq-local comint-scroll-to-bottom-on-output t)
                    (setq-local comint-scroll-show-maximum-output t)
                    (local-set-key (kbd "TAB") 'decknix--agent-tab-dwim)
                    (local-set-key (kbd "<tab>") 'decknix--agent-tab-dwim)
                    ;; Buffer-local bindings — no C-c A prefix needed inside agent-shell.
                    ;; Native bindings: C-c C-c (interrupt), C-c C-v (model), C-c C-m (mode)
                    (local-set-key (kbd "C-c e") 'decknix-agent-compose)
                    (local-set-key (kbd "C-c E") 'decknix-agent-compose-interrupt)
                    (local-set-key (kbd "C-c ?") decknix-agent-help-map)
                    (local-set-key (kbd "C-c r") 'agent-shell-rename-buffer)
                    ;; C-c s — session sub-prefix
                    (let ((map (make-sparse-keymap)))
                      (define-key map (kbd "s") 'decknix-agent-session-picker)
                      (define-key map (kbd "n") 'decknix-agent-session-new)
                      (define-key map (kbd "q") 'decknix-agent-session-quit)
                      (define-key map (kbd "h") 'decknix-agent-session-history)
                      (define-key map (kbd "y") 'decknix-agent-session-copy-id)
                      (define-key map (kbd "d") 'decknix-agent-session-toggle-id-display)
                      (local-set-key (kbd "C-c s") map))
                    ;; which-key labels for C-c s session sub-prefix
                    (when (fboundp 'which-key-add-key-based-replacements)
                      (which-key-add-key-based-replacements
                        "C-c s"   "session…"
                        "C-c s s" "picker (live+saved)"
                        "C-c s n" "new session"
                        "C-c s q" "quit session"
                        "C-c s h" "history"
                        "C-c s y" "copy session ID"
                        "C-c s d" "toggle ID display"))
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
                    ;; C-c T — session-scoped tags sub-prefix in-buffer
                    (let ((map (make-sparse-keymap)))
                      (define-key map (kbd "l") 'decknix-agent-tag-show)      ; List this session's tags
                      (define-key map (kbd "a") 'decknix-agent-tag-add)       ; Add tag (create or select)
                      (define-key map (kbd "r") 'decknix-agent-tag-remove)    ; Remove tag
                      (local-set-key (kbd "C-c T") map))
                    ;; Unified header-line: status + tags + workspace + context
                    (decknix--header-update)
                    (decknix--header-start-timer)
                    (add-hook 'kill-buffer-hook #'decknix--header-stop-timer nil t)))
      '';
    };
  };
}
