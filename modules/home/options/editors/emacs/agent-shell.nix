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
            "  In compose: C-c C-c submit, C-c C-k clear/close.\n"
            "  In compose: C-c C-s toggles sticky (stays open) / transient.\n"
            "  In compose: C-c k k interrupts the agent, C-c k C-c interrupts & submits.\n"
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
        ;; Register all C-c A sub-key descriptions with which-key.
        ;; Single consolidated block so which-key can display the full menu.
        (with-eval-after-load 'which-key
          (which-key-add-key-based-replacements
            "C-c A"   "Agent"
            "C-c A ?" "Help"
            "C-c A a" "start/switch"
            "C-c A n" "new session"
            "C-c A s" "session picker"
            "C-c A h" "history"
            "C-c A e" "compose"
            "C-c A T" "Tags"
            "C-c A c" "Commands"
            "C-c A t" "Templates"
            "C-c A i" "Context"
            "C-c A S" "MCP servers"
            "C-c A m" "manager"
            "C-c A w" "workspace"
            "C-c A j" "attention jump"))

        ;; Global keybindings under C-c A prefix
        ;; Only actions that make sense from OUTSIDE an agent-shell buffer.
        ;; Buffer-local bindings (C-c ...) handle in-buffer actions — no duplicates.
        (define-key decknix-agent-prefix-map (kbd "a") 'agent-shell)                      ; Start/switch to agent
        (define-key decknix-agent-prefix-map (kbd "n") 'decknix-agent-session-new)          ; New session (guided)
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
              (insert "{sessionId, created, modified,"
                      " exchangeCount: (.chatHistory | length),"
                      " firstUserMessage:"
                      " (.chatHistory[0].exchange.request_message[:200]"
                      " // \"\")}\n")))
          decknix--agent-session-jq-filter-file)

        (defun decknix--agent-session-jq-cmd ()
          "Shell command to extract session metadata directly from files.
Sorts by filesystem mtime (newest first), takes top 30, extracts
only the fields needed for the picker via parallel jq."
          (let ((jqf (decknix--agent-session-ensure-jq-filter)))
            (concat
             "ls -t " (shell-quote-argument decknix--agent-sessions-dir)
             "/*.json 2>/dev/null"
             " | head -30"
             " | xargs -P4 -I{} jq -Mc -f "
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

        (defun decknix--agent-session-resume (session-id history-count)
          "Resume SESSION-ID and pre-populate buffer with HISTORY-COUNT exchanges."
          ;; Invalidate cache so next picker invocation fetches fresh data
          (setq decknix--agent-session-cache-time 0)
          ;; Snapshot existing buffers so we can detect the new one
          (let ((before-buffers (buffer-list))
                (agent-shell-auggie-acp-command
                 (append agent-shell-auggie-acp-command
                         (list "--resume" session-id))))
            (agent-shell-start
             :config (agent-shell-auggie-make-agent-config))
            ;; agent-shell-start is async — it doesn't switch current-buffer.
            ;; Use a timer to find the new buffer and prepopulate it.
            (let ((sid session-id)
                  (n history-count)
                  (bufs before-buffers))
              (run-at-time
               1.5 nil
               (eval
                `(lambda ()
                   (let ((shell-buf (decknix--agent-find-new-shell-buffer ',bufs)))
                     (if shell-buf
                         (with-current-buffer shell-buf
                           (setq-local decknix--agent-auggie-session-id ,sid)
                           (decknix--agent-session-prepopulate ,sid ,n))
                       (message "Could not find agent-shell buffer for session %s"
                                (substring ,sid 0 8)))))
                t)))))

        (defun decknix-agent-session-picker (arg)
          "Pick from live agent-shell buffers and saved auggie sessions.
Live buffers are shown first, then saved sessions. Selecting a live
buffer switches to it; selecting a saved session resumes it in a
new agent-shell.

With prefix ARG, prompt for the number of history exchanges to show
when resuming a saved session (default: `decknix-agent-session-history-count')."
          (interactive "P")
          (let* ((history-count (if arg
                                   (read-number "History exchanges to show: "
                                                decknix-agent-session-history-count)
                                 decknix-agent-session-history-count))
                 (live-buffers (when (fboundp 'agent-shell-buffers)
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
               (decknix--agent-session-resume
                (alist-get 'sessionId (cdr chosen))
                history-count))
              ('new (decknix-agent-session-new)))))

        (defun decknix--agent-detect-workspace ()
          "Detect the best workspace directory for a new session.
Uses project root if available, otherwise `default-directory'."
          (or (when (fboundp 'project-root)
                (when-let ((proj (project-current)))
                  (project-root proj)))
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
          "Apply TAGS (list of strings) to SESSION-ID in the tag store."
          (when (and session-id tags)
            (let ((store (decknix--agent-tags-read))
                  (entry (make-hash-table :test 'equal)))
              (puthash "tags" tags entry)
              (puthash session-id entry store)
              (decknix--agent-tags-write store))))

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
                 (agent-shell-auggie-acp-command
                  (append agent-shell-auggie-acp-command
                          (list "--workspace-root" workspace))))
            (agent-shell-start
             :config (agent-shell-auggie-make-agent-config))
            ;; Invalidate session cache so next picker is fresh
            (setq decknix--agent-session-cache-time 0)
            ;; Post-creation: rename buffer, apply tags (using timers)
            (decknix--agent-session-new-post-create
             before-buffers name tags)
            (message "Starting agent session \"%s\" in %s…" name workspace)))

        (defvar decknix--session-new-pending nil
          "Pending post-creation data: (BEFORE-BUFFERS NAME TAGS).")

        (defun decknix--agent-session-new-post-create (before-buffers name tags)
          "Post-creation setup: rename buffer to NAME, apply TAGS.
BEFORE-BUFFERS is the buffer snapshot taken before agent-shell-start."
          ;; Store pending data in a global so timers can access it
          ;; without nested quasiquotes (default.el uses dynamic binding).
          (setq decknix--session-new-pending (list before-buffers name tags))
          (run-at-time 1.5 nil #'decknix--agent-session-new-finish))

        (defun decknix--agent-session-new-finish ()
          "Timer callback: rename new buffer and schedule tag application."
          (when decknix--session-new-pending
            (let* ((data decknix--session-new-pending)
                   (before-buffers (nth 0 data))
                   (name (nth 1 data))
                   (tags (nth 2 data))
                   (shell-buf (decknix--agent-find-new-shell-buffer before-buffers)))
              (setq decknix--session-new-pending nil)
              (when shell-buf
                (with-current-buffer shell-buf
                  (rename-buffer
                   (generate-new-buffer-name
                    (format "*Auggie: %s*" name))))
                ;; Schedule tag application (session ID may not be available yet)
                (when tags
                  (decknix--agent-session-new-schedule-tags shell-buf tags))))))

        (defvar decknix--session-new-tag-pending nil
          "Pending tag data: (BUF TAGS ATTEMPTS-LEFT).")

        (defun decknix--agent-session-new-schedule-tags (buf tags)
          "Schedule applying TAGS to the session in BUF once its ID is known."
          (setq decknix--session-new-tag-pending (list buf tags 5))
          (run-at-time 2.0 nil #'decknix--agent-session-new-try-tags))

        (defun decknix--agent-session-new-try-tags ()
          "Try to apply tags to a pending session. Retries if ID not yet available.
For new sessions, the session ID is extracted from the ACP state
\(agent-shell--state → :session :id\) since `decknix--agent-auggie-session-id'
is only set during session resume."
          (when decknix--session-new-tag-pending
            (let ((buf (nth 0 decknix--session-new-tag-pending))
                  (tags (nth 1 decknix--session-new-tag-pending))
                  (attempts-left (nth 2 decknix--session-new-tag-pending)))
              (cond
               ((not (buffer-live-p buf))
                (setq decknix--session-new-tag-pending nil))
               ;; Try buffer-local var first, then fall back to ACP state.
               ;; Guard with condition-case: shell-maker--config may be nil
               ;; if the timer fires before agent-shell fully initialises.
               ((let ((sid (with-current-buffer buf
                             (or decknix--agent-auggie-session-id
                                 (condition-case nil
                                     (map-nested-elt (agent-shell--state)
                                                     '(:session :id))
                                   (error nil))))))
                  (when (and sid (not (string-empty-p sid)))
                    ;; Persist for future use (tag mgmt, copy-id, etc.)
                    (with-current-buffer buf
                      (setq-local decknix--agent-auggie-session-id sid))
                    (decknix--agent-session-tags-for sid tags)
                    (setq decknix--session-new-tag-pending nil)
                    (message "Tags applied: [%s]" (string-join tags ", "))
                    t)))
               ((<= attempts-left 0)
                (setq decknix--session-new-tag-pending nil)
                (message "Could not apply tags: session ID not available"))
               (t
                (setf (nth 2 decknix--session-new-tag-pending) (1- attempts-left))
                (run-at-time 2.0 nil #'decknix--agent-session-new-try-tags))))))

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
                       (session-id (alist-get 'sessionId session)))
                  (decknix--agent-session-resume
                   session-id
                   decknix-agent-session-history-count))))))

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
        ;; Opens a buffer for composing multi-line prompts.
        ;; Supports sticky (persistent) and transient modes.
        ;; C-c C-c submits, C-c C-k cancels/clears, C-c C-s toggles sticky.
        ;; C-c k prefix: k = interrupt, C-c = interrupt + submit.

        (defvar-local decknix--compose-target-buffer nil
          "The agent-shell buffer to submit the composed prompt to.")

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

        (defvar decknix-agent-compose-mode-map
          (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'decknix-agent-compose-submit)
            (define-key map (kbd "C-c C-k") #'decknix-agent-compose-cancel)
            (define-key map (kbd "C-c C-q") #'decknix-agent-compose-close)
            (define-key map (kbd "C-c C-s") #'decknix-agent-compose-toggle-sticky)
            (define-key map (kbd "C-c k") decknix-agent-compose-interrupt-map)
            map)
          "Keymap for `decknix-agent-compose-mode'.")

        ;; which-key labels for compose mode keybindings
        (with-eval-after-load 'which-key
          (which-key-add-keymap-based-replacements decknix-agent-compose-mode-map
            "C-c C-c" "submit"
            "C-c C-k" "clear/cancel"
            "C-c C-q" "close"
            "C-c C-s" "toggle sticky"
            "C-c k"   "interrupt…")
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
          "Finish a compose action: clear if sticky, close if transient."
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
              ;; Clear or close the compose buffer
              (decknix--compose-finish)
              ;; Submit to the agent-shell buffer
              (when (buffer-live-p target)
                (with-current-buffer target
                  (goto-char (point-max))
                  (shell-maker-submit :input input))))))

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
rather than waiting for the current response to complete."
          (interactive)
          (let ((input (string-trim (buffer-string)))
                (target decknix--compose-target-buffer))
            (if (string-empty-p input)
                (user-error "Empty prompt — nothing to submit")
              ;; Interrupt the agent first
              (when (buffer-live-p target)
                (with-current-buffer target
                  (when (fboundp 'agent-shell-interrupt)
                    (let ((agent-shell-confirm-interrupt nil))
                      (agent-shell-interrupt)))))
              ;; Clear or close the compose buffer
              (decknix--compose-finish)
              ;; Submit after a brief delay to let the interrupt settle
              (let ((tgt target)
                    (inp input))
                (run-at-time
                 0.3 nil
                 (eval
                  `(lambda ()
                     (when (buffer-live-p ,tgt)
                       (with-current-buffer ,tgt
                         (goto-char (point-max))
                         (shell-maker-submit :input ,inp))))
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
                       (propertize " for actions (submit, interrupt, close, toggle sticky)"
                                   'font-lock-face 'font-lock-comment-face))))

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
                                   '((display-buffer-at-bottom)
                                     (window-height . 10)
                                     (dedicated . t))))
                  (select-window (get-buffer-window existing))
                  existing)
              ;; Create new compose buffer
              (let ((compose-buf (generate-new-buffer compose-name)))
                (display-buffer compose-buf
                                '((display-buffer-at-bottom)
                                  (window-height . 10)
                                  (dedicated . t)))
                (select-window (get-buffer-window compose-buf))
                (with-current-buffer compose-buf
                  (text-mode)
                  (decknix-agent-compose-mode 1)
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

        ;; C-c A c — commands sub-prefix ("Commands")
        (define-prefix-command 'decknix-agent-command-map)
        (define-key decknix-agent-prefix-map (kbd "c") 'decknix-agent-command-map)
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
                    (local-set-key (kbd "C-c E") 'decknix-agent-compose-interrupt)
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
