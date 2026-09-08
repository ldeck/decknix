{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.lsp;

  # Kotlin LSP choice.  JetBrains' official kotlin-lsp is IntelliJ-powered and
  # is the only server that resolves modern Gradle monorepos — centralised
  # repos, Google Artifact Registry, JDK 25, Kotlin 2.3 (fwcd's 1.3.13 cannot;
  # see #170).  We are NOT using it yet: see `useJetBrainsLsp' below.
  # Our own derivation (pkgs/kotlin-lsp), NOT the nix-casks input.  That input
  # resolved and built while shipping a 0 MB stub with a dangling symlink, so
  # "the attribute exists" told us nothing.  This one unpacks the standalone
  # archive and wraps `bin/intellij-server'; verified by running it
  # (`--version' -> LS-262.9593.0), not by building it.
  jetbrainsKotlinLsp =
    let drv = pkgs.callPackage ../../../../../pkgs/kotlin-lsp { };
    in if pkgs.stdenv.hostPlatform.system == "aarch64-darwin" then drv else null;
  useJetBrainsKotlin =
    cfg.kotlin.enable && cfg.kotlin.useJetBrainsLsp && jetbrainsKotlinLsp != null;
  kotlinPkg = if useJetBrainsKotlin then jetbrainsKotlinLsp else pkgs.kotlin-language-server;
  # The java-debug plugin jar.  jdtls loads it as an OSGi bundle and only
  # then advertises `vscode.java.resolveClasspath' /
  # `vscode.java.startDebugSession' -- the two commands dape's `jdtls'
  # config drives.  Without the bundle dape refuses with "Jdtls instance
  # does not bundle java-debug-server", which is why JVM debugging is a
  # jdtls CONFIGURATION problem rather than a dape one.
  javaDebugExt = pkgs.vscode-extensions.vscjava.vscode-java-debug;
  javaDebugBundle =
    "${javaDebugExt}/share/vscode/extensions/vscjava.vscode-java-debug/server/"
    + "com.microsoft.java.debug.plugin-0.53.1.jar";

  # jdtls is registered with a SUBCLASS when JVM debugging is on, purely so
  # `eglot-initialization-options' can carry the java-debug bundle.  Eglot
  # has no per-server initializationOptions slot on a plain contact, so the
  # subclass is the seam.  Without debugging it stays a plain contact --
  # same server, one less moving part.
  jdtlsServerElisp =
    if (cfg.dap.enable && cfg.dapAdapters.jvm) then ''
          ;; Subclass so jdtls receives `:bundles' at initialize.  Loading
          ;; the java-debug OSGi bundle is what makes jdtls advertise
          ;; `vscode.java.resolveClasspath' and `vscode.java.startDebugSession',
          ;; the two commands dape's `jdtls' config calls.  Without it dape
          ;; refuses with "Jdtls instance does not bundle java-debug-server".
          (defclass decknix-eglot-jdtls (eglot-lsp-server) ()
            :documentation "jdtls with the java-debug bundle loaded.")
          (cl-defmethod eglot-initialization-options
            ((server decknix-eglot-jdtls))
            (ignore server)
            (list :bundles (vector "${javaDebugBundle}")))
          (add-to-list 'eglot-server-programs
                       '((java-mode java-ts-mode) decknix-eglot-jdtls "jdtls"))
    '' else ''
          (add-to-list 'eglot-server-programs
                       '((java-mode java-ts-mode) . ("jdtls")))
    '';

  # Tree-sitter grammars, packaged the way Emacs expects to find them:
  # `$out/lib/libtree-sitter-<lang>.dylib'.  Curated rather than
  # `with-all-grammars' (128 grammars) -- only languages that have BOTH a
  # working `-ts-mode' and a real presence in this workspace.
  treesitGrammars = pkgs.emacsPackages.treesit-grammars.with-grammars (g: with g; [
    tree-sitter-kotlin tree-sitter-java tree-sitter-rust tree-sitter-go
    tree-sitter-bash tree-sitter-json tree-sitter-yaml tree-sitter-toml
    tree-sitter-dockerfile
  ]);

  # Remap classic modes to their tree-sitter variants.  Installing grammars
  # changes nothing on its own -- files still open in the classic mode --
  # so this is the half that makes them take effect.  Guarded by
  # `treesit-ready-p' so a missing grammar degrades to the classic mode
  # instead of erroring on every file of that type.
  treesitRemapElisp = optionalString cfg.treesit.remapModes ''
        ;; The grammar language is named EXPLICITLY rather than derived from
        ;; the mode name.  Deriving it needed `string-remove-suffix' (subr-x,
        ;; not autoloaded) and would silently break for any mode whose name
        ;; does not match its grammar -- a rule that holds for these four and
        ;; nothing guarantees for the next one.
        (dolist (spec (list (list 'java-mode   'java-ts-mode   'java)
                            (list 'rust-mode   'rust-ts-mode   'rust)
                            (list 'go-mode     'go-ts-mode     'go)
                            (list 'kotlin-mode 'kotlin-ts-mode 'kotlin)))
          (let ((classic (nth 0 spec))
                (ts (nth 1 spec))
                (lang (nth 2 spec)))
            (when (and (fboundp ts) (treesit-ready-p lang t))
              (add-to-list 'major-mode-remap-alist (cons classic ts)))))
  '';

  # Eglot server-programs command for Kotlin (elisp list literal).
  kotlinServerElisp =
    if useJetBrainsKotlin then ''("kotlin-lsp" "--stdio")'' else ''("kotlin-language-server")'';
in
{
  options.programs.emacs.decknix.lsp = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable LSP (Language Server Protocol) support via Eglot.
        This provides IDE features like completions, go-to-definition,
        refactoring, and diagnostics for supported languages.
      '';
    };

    # === Language Server Options ===
    kotlin.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Kotlin LSP support.";
    };

    kotlin.useJetBrainsLsp = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Use JetBrains' official kotlin-lsp instead of fwcd/kotlin-language-server.

        OFF by default because the nix-casks route is BROKEN, and turning it on
        breaks Kotlin LSP entirely rather than degrading it.  nix-casks
        auto-generates the cask's `binary' stanza but never unpacks the `.sit'
        payload: the derivation builds, the attribute resolves
        (`kotlin-lsp-262.9593.0'), and the output is a 0 MB stub whose
        `bin/kotlin-lsp' is a DANGLING symlink to a `kotlin-server-*/kotlin-lsp.sh'
        that was never extracted.  Eglot then reports

            [eglot] (warning) Searching for program: No such file or directory, kotlin-lsp

        and no Kotlin server runs at all, even though fwcd's is installed.
        Verifying that the attribute resolved was not evidence the binary worked.

        Re-enabling this needs a real derivation, not this input.  The groundwork:
        JetBrains' standalone archive
        (`kotlin-server-<ver>-aarch64.sit', linked from the Kotlin/kotlin-lsp
        release notes) is despite its extension a plain ZIP (`PK\x03\x04'), so
        `unzip' unpacks it — no StuffIt handling required — and it ships the
        `kotlin-lsp.sh' launcher meant for editors other than VS Code.  Note the
        VS Code `.vsix' build is NOT a substitute: it launches
        `intellij-server --socket 0', i.e. TCP on an ephemeral port, not stdio,
        so `kotlinServerElisp' above would also need rewriting for it.
      '';
    };

    dapAdapters = {
      jvm = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Load the java-debug bundle into jdtls so dape can drive it.

          dape ships a `jdtls' debug config, but it refuses unless the jdtls
          instance advertises `vscode.java.resolveClasspath' -- a command that
          only appears once the java-debug OSGi bundle is loaded.  So this is
          jdtls configuration, not dape configuration, which is why the
          `C-c d' keymap has existed for a while with nothing to attach to.

          Java only.  Kotlin is NOT covered: dape's jdtls config is bound to
          `java-mode'/`java-ts-mode', and jdtls does not resolve Kotlin main
          classes.  Debugging the monolith therefore still means attaching to
          a JDWP port rather than launching from the editor.
        '';
      };

      rust = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Install lldb, whose `lldb-dap' backs dape's `lldb-dap' config.

          `codelldb' is the richer adapter and dape supports it too, but it is
          a large Rust build from a VS Code extension; lldb-dap is already
          part of a toolchain we can install cheaply.  Swap if the extra
          formatting and expression support proves worth the build.
        '';
      };

      go = mkOption {
        type = types.bool;
        default = true;
        description = "Install delve, which backs dape's `dlv' config.";
      };
    };

    treesit = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Install tree-sitter grammars and put them on `treesit-extra-load-path'.

          Without this, every `*-ts-mode' referenced in `eglot-server-programs'
          is wired to a mode that cannot load: the grammar is missing, the mode
          errors on entry, and the server is attached to something that never
          activates.  Grammars come from nixpkgs rather than
          `treesit-install-language-grammar', which compiles at runtime and
          would not reproduce on a fresh machine.
        '';
      };

      remapModes = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Remap major modes to their tree-sitter variants where both the mode
          and its grammar are present (Kotlin, Java, Rust, Go).

          Installing grammars alone changes nothing: files still open in the
          classic mode.  This is the half that makes them take effect.

          Turn off if a `-ts-mode' proves less capable than its classic
          counterpart -- notably `kotlin-ts-mode', which is third-party and
          less exercised than `kotlin-mode' on the monolith.
        '';
      };
    };

    terraform.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install terraform-ls and wire it as the Eglot server for `.tf' files.

        The largest unsupported surface in the workspace: 334 `.tf' files
        against 3 `Cargo.toml', concentrated in `terraform-platform' where a
        great deal of the real work happens.
      '';
    };

    rust.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install rust-analyzer and wire it as the Eglot server for Rust.

        Distinct from `languages.rust.enable', which only provides the major
        mode.  That option's name implied LSP support it never delivered:
        highlighting without navigation.
      '';
    };

    go.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install gopls and wire it as the Eglot server for Go.

        Distinct from `languages.go.enable', which only provides the major
        mode -- see `rust.enable' above for the same trap.
      '';
    };

    java.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Java LSP support via eglot-java (uses jdt-language-server).";
    };

    nix.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install nixd and wire it as the Eglot server for Nix files, so
        flake/home-manager configs get completion, go-to-definition, and
        diagnostics.  nixd resolves flake attrs (unlike the lighter `nil').
      '';
    };

    # === Debug Adapter Protocol ===
    dap.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable DAP (Debug Adapter Protocol) support via dape.";
    };

    # === UI Enhancements ===
    eldocBox.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable eldoc-box for enhanced documentation popups.";
    };
  };

  config = mkIf cfg.enable {
    # Install language servers via Nix
    home.packages =
      (optionals cfg.kotlin.enable [ kotlinPkg ])
      ++ (optionals cfg.java.enable [ pkgs.jdt-language-server ])
      ++ (optionals cfg.nix.enable [ pkgs.nixd ])
      ++ (optionals cfg.terraform.enable [ pkgs.terraform-ls ])
      ++ (optionals cfg.rust.enable [ pkgs.rust-analyzer ])
      ++ (optionals cfg.go.enable [ pkgs.gopls ])
      ++ (optionals cfg.treesit.enable [ treesitGrammars ])
      ++ (optionals (cfg.dap.enable && cfg.dapAdapters.jvm) [ javaDebugExt ])
      ++ (optionals (cfg.dap.enable && cfg.dapAdapters.rust) [ pkgs.lldb ])
      ++ (optionals (cfg.dap.enable && cfg.dapAdapters.go) [ pkgs.delve ]);

    programs.emacs = {
      extraPackages = epkgs: with epkgs;
        # Eglot is built-in to Emacs 29+, but we ensure it's available.
        # (eglot-java dropped — Java is driven directly via jdtls, see below.)
        [ eglot ]
        ++ (optionals cfg.eldocBox.enable [ eldoc-box ])
        ++ (optionals cfg.dap.enable [ dape ]);

      extraConfig = ''
        ;;; LSP Configuration (Eglot)
        ;;; Generated by decknix - provides IDE features via Language Server Protocol

        ;; == Eglot: Built-in LSP client ==
        (use-package eglot
          :commands (eglot eglot-ensure)
          :hook ((kotlin-mode . eglot-ensure)
                 (kotlin-ts-mode . eglot-ensure)
                 (java-mode . eglot-ensure)
                 (java-ts-mode . eglot-ensure)
                 (nix-mode . eglot-ensure)
                 (terraform-mode . eglot-ensure)
                 (rust-mode . eglot-ensure)
                 (rust-ts-mode . eglot-ensure)
                 (go-mode . eglot-ensure)
                 (go-ts-mode . eglot-ensure))
          :config
          ;; Performance tuning
          (setq eglot-events-buffer-size 0           ; Disable events buffer for performance
                eglot-autoshutdown t                 ; Shutdown server when last buffer closed
                eglot-sync-connect nil               ; Don't block on connection
                ;; Big monorepos (e.g. upside) make the server resolve a huge
                ;; Gradle classpath during `initialize'; the 30s default is
                ;; far too short and Eglot gives up ("timed out after 30s").
                ;; Allow up to 5 min for the handshake.  Async connect means
                ;; this does not block Emacs — the buffer just isn't
                ;; LSP-managed until the server answers.
                eglot-connect-timeout 300
                eglot-extend-to-xref t)              ; Use LSP for xref

          ;; Keybindings (using C-c l prefix for LSP commands)
          :bind (:map eglot-mode-map
                 ("C-c l r" . eglot-rename)
                 ("C-c l a" . eglot-code-actions)
                 ("C-c l f" . eglot-format)
                 ("C-c l F" . eglot-format-buffer)
                 ("C-c l d" . eldoc)
                 ("C-c l i" . eglot-find-implementation)
                 ("C-c l t" . eglot-find-typeDefinition)
                 ("C-c l h" . eglot-inlay-hints-mode)))

      '' + optionalString cfg.kotlin.enable ''
        ;; == Kotlin Language Server ==
        ;; JetBrains kotlin-lsp (nix-casks) where available, else fwcd — the
        ;; command is chosen in lsp.nix (`kotlinServerElisp').
        (with-eval-after-load 'eglot
          (add-to-list 'eglot-server-programs
                       '((kotlin-mode kotlin-ts-mode) . ${kotlinServerElisp})))

      '' + optionalString cfg.nix.enable ''
        ;; == Nix Language Server (nixd) ==
        ;; nixd is installed via Nix; resolves flake attrs (unlike `nil').
        ;; `nix-mode' only: `nix-ts-mode' is a separate package that is NOT
        ;; installed, so listing it wired nixd to a mode that could never
        ;; load.  Harmless in effect, misleading in the config -- it read as
        ;; though tree-sitter Nix was supported.
        (with-eval-after-load 'eglot
          (add-to-list 'eglot-server-programs
                       '(nix-mode . ("nixd"))))

      '' + optionalString cfg.treesit.enable ''
        ;; == Tree-sitter grammars ==
        ;; Emacs looks for `libtree-sitter-<lang>.dylib' on
        ;; `treesit-extra-load-path'.  The nixpkgs helper lays the grammars
        ;; out under that exact naming, so this is a single path entry
        ;; rather than a pile of symlinks we would have to maintain.
        ;; `require' first: both `treesit-extra-load-path' and
        ;; `treesit-ready-p' are autoload-less members of `treesit', so
        ;; touching either before it loads is a void-variable/void-function
        ;; error at startup.  Verified the hard way in batch.
        (require 'treesit)
        (add-to-list 'treesit-extra-load-path "${treesitGrammars}/lib")
${treesitRemapElisp}
      '' + optionalString cfg.terraform.enable ''
        ;; == Terraform Language Server ==
        ;; The workspace's largest unsupported surface until now: 334 .tf
        ;; files, nearly all in `terraform-platform'.
        (with-eval-after-load 'eglot
          (add-to-list 'eglot-server-programs
                       '(terraform-mode . ("terraform-ls" "serve"))))

      '' + optionalString cfg.rust.enable ''
        ;; == Rust Language Server (rust-analyzer) ==
        ;; `languages.rust.enable' only ever added the major mode, so Rust
        ;; buffers had highlighting and no navigation while the option name
        ;; suggested otherwise.  This is the half that was missing.
        (with-eval-after-load 'eglot
          (add-to-list 'eglot-server-programs
                       '((rust-mode rust-ts-mode) . ("rust-analyzer"))))

      '' + optionalString cfg.go.enable ''
        ;; == Go Language Server (gopls) ==
        ;; Same gap as Rust: the mode was enabled, the server never was.
        (with-eval-after-load 'eglot
          (add-to-list 'eglot-server-programs
                       '((go-mode go-ts-mode) . ("gopls"))))

      '' + optionalString cfg.java.enable ''
        ;; == Java Language Server (jdtls, driven directly) ==
        ;; The nix `jdtls' is a Python launcher for eclipse.jdt.ls that speaks
        ;; LSP over stdio and manages its own -data dir, so Eglot drives it
        ;; directly — mirroring the Kotlin setup.  We deliberately do NOT use
        ;; `eglot-java': it expects to locate/download its own jdt.ls bundle
        ;; and never wires the nix `jdtls' into `eglot-server-programs', so
        ;; Eglot silently failed to connect on java-mode buffers (verified on
        ;; the upside monolith).  jdtls imports the Gradle project itself; the
        ;; java-mode `eglot-ensure' hook above starts it.
        (with-eval-after-load 'eglot
${jdtlsServerElisp})

      '' + optionalString cfg.eldocBox.enable ''
        ;; == Eldoc-box: Enhanced documentation popups ==
        (use-package eldoc-box
          :hook (eglot-managed-mode . eldoc-box-hover-mode)
          :bind (:map eglot-mode-map
                 ("C-c l k" . eldoc-box-help-at-point))
          :config
          (setq eldoc-box-clear-with-C-g t
                eldoc-box-max-pixel-width 600
                eldoc-box-max-pixel-height 400))

      '' + optionalString cfg.dap.enable ''
        ;; == Dape: Debug Adapter Protocol ==
        (use-package dape
          :commands (dape dape-breakpoint-toggle)
          :bind (("C-c d d" . dape)
                 ("C-c d b" . dape-breakpoint-toggle)
                 ("C-c d B" . dape-breakpoint-remove-all)
                 ("C-c d n" . dape-next)
                 ("C-c d s" . dape-step-in)
                 ("C-c d o" . dape-step-out)
                 ("C-c d c" . dape-continue)
                 ("C-c d r" . dape-restart)
                 ("C-c d q" . dape-quit))
          :config
          ;; Save buffers on startup
          (add-hook 'dape-on-start-hooks (lambda () (save-some-buffers t t)))

          ;; Kotlin debug adapter (kotlin-debug-adapter)
          ;; Note: Requires kotlin-debug-adapter to be installed separately
          (add-to-list 'dape-configs
                       '(kotlin-debug
                         modes (kotlin-mode kotlin-ts-mode)
                         command "kotlin-debug-adapter"
                         :type "kotlin"
                         :request "launch"
                         :mainClass (lambda () (read-string "Main class: "))
                         :projectRoot (lambda () (project-root (project-current t))))))

      '' + ''
        ;; == Completion integration ==
        ;; Eglot integrates with completion-at-point, which Corfu uses
        ;; No additional configuration needed - just works with the completion stack
      '';
    };
  };
}

