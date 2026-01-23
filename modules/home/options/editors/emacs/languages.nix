{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.languages;
in
{
  options.programs.emacs.decknix.languages = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable language mode configurations for syntax highlighting and editing.";
    };

    # === Tier 1: Primary Languages ===
    kotlin = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Kotlin mode for .kt and .kts files.";
      };
    };

    java = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Java mode enhancements (built-in mode with extras).";
      };
    };

    scala = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Scala mode for .scala and .sc files.";
      };
    };

    sql = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable SQL mode enhancements with indentation.";
      };
    };

    terraform = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Terraform/HCL mode for .tf and .hcl files.";
      };
    };

    shell = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable shell script modes (bash, zsh, fish).";
      };
    };

    nix = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Nix mode for .nix files.";
      };
    };

    python = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Python mode enhancements.";
      };
    };

    # === Tier 2: Config & Data Formats ===
    json = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable JSON mode for .json files.";
      };
    };

    yaml = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable YAML mode for .yml and .yaml files.";
      };
    };

    toml = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable TOML mode for .toml files.";
      };
    };

    xml = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable XML/nXML mode enhancements.";
      };
    };

    markdown = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Markdown mode for .md files.";
      };
    };

    # === Tier 3: Web & Frontend ===
    web = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable web-mode for HTML, CSS, and templates.";
      };
    };

    javascript = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable JavaScript/TypeScript modes.";
      };
    };

    # === Tier 4: Additional Languages ===
    rust = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Rust mode for .rs files.";
      };
    };

    go = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Go mode for .go files.";
      };
    };

    protobuf = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Protocol Buffers mode for .proto files.";
      };
    };

    thrift = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Thrift/IDL mode for .thrift files.";
      };
    };

    graphql = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable GraphQL mode for .graphql files.";
      };
    };

    docker = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Dockerfile mode.";
      };
    };

    groovy = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Groovy mode for .groovy and legacy .gradle files.";
      };
    };

    lua = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Lua mode for .lua files.";
      };
    };

    # === Lisp Family ===
    lisp = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Lisp modes (Common Lisp, Scheme, Clojure, Racket).";
      };
    };

    # === Build Tools & Config ===
    build = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable build tool modes (Makefile, CMake, Just, Gradle, Maven).";
      };
    };

    config = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable config file modes (editorconfig, gitignore, etc).";
      };
    };
  };

  config = mkIf cfg.enable {
    programs.emacs = {
      extraPackages = epkgs: with epkgs;
        # Tier 1: Primary Languages
        (optionals cfg.kotlin.enable [ kotlin-mode kotlin-ts-mode ])
        ++ (optionals cfg.java.enable [ eglot-java ])
        ++ (optionals cfg.scala.enable [ scala-mode scala-ts-mode sbt-mode ])
        ++ (optionals cfg.sql.enable [ sql-indent ])
        ++ (optionals cfg.terraform.enable [ terraform-mode hcl-mode ])
        ++ (optionals cfg.shell.enable [ fish-mode shfmt ])
        ++ (optionals cfg.nix.enable [ nix-mode ])
        # python-mode is built-in

        # Tier 2: Config & Data Formats
        ++ (optionals cfg.json.enable [ json-mode ])
        ++ (optionals cfg.yaml.enable [ yaml-mode yaml-pro ])
        ++ (optionals cfg.toml.enable [ toml-mode ])
        # nxml-mode is built-in
        ++ (optionals cfg.markdown.enable [ markdown-mode ])

        # Tier 3: Web & Frontend
        ++ (optionals cfg.web.enable [ web-mode less-css-mode scss-mode ])
        ++ (optionals cfg.javascript.enable [ js2-mode typescript-mode rjsx-mode vue-mode svelte-mode ])

        # Tier 4: Additional Languages
        ++ (optionals cfg.rust.enable [ rust-mode ])
        ++ (optionals cfg.go.enable [ go-mode ])
        ++ (optionals cfg.protobuf.enable [ protobuf-mode ])
        ++ (optionals cfg.thrift.enable [ thrift ])
        ++ (optionals cfg.graphql.enable [ graphql-mode ])
        ++ (optionals cfg.docker.enable [ dockerfile-mode ])
        ++ (optionals cfg.groovy.enable [ groovy-mode ])
        ++ (optionals cfg.lua.enable [ lua-mode ])

        # Lisp Family
        ++ (optionals cfg.lisp.enable [
          paredit
          rainbow-delimiters
          clojure-mode
          cider
          sly                    # Modern Common Lisp IDE (better than SLIME)
          geiser                 # Scheme support
          racket-mode
        ])

        # Build Tools
        ++ (optionals cfg.build.enable [
          cmake-mode
          just-mode
          gradle-mode
          mvn               # Maven commands
          maven-test-mode
          bazel
        ])

        # Cargo for Rust (if rust enabled)
        ++ (optionals cfg.rust.enable [ cargo ])

        # Config Files
        ++ (optionals cfg.config.enable [
          editorconfig
          apache-mode
        ]);

      extraConfig = ''
        ;;; Language Mode Configuration
        ;;; Generated by decknix - provides syntax highlighting for code blocks

      '' + optionalString cfg.kotlin.enable ''
        ;; == Kotlin ==
        (use-package kotlin-mode
          :mode ("\\.kt\\'" "\\.kts\\'")
          :config
          (setq kotlin-tab-width 4))

      '' + optionalString cfg.scala.enable ''
        ;; == Scala ==
        (use-package scala-mode
          :mode "\\.\\(scala\\|sbt\\|sc\\)\\'"
          :config
          (setq scala-indent:use-javadoc-style t))

      '' + optionalString cfg.sql.enable ''
        ;; == SQL ==
        (use-package sql-indent
          :hook (sql-mode . sqlind-minor-mode))

      '' + optionalString cfg.terraform.enable ''
        ;; == Terraform/HCL ==
        (use-package terraform-mode
          :mode ("\\.tf\\'" "\\.tfvars\\'"))
        (use-package hcl-mode
          :mode "\\.hcl\\'")

      '' + optionalString cfg.shell.enable ''
        ;; == Shell Scripts ==
        ;; sh-mode is built-in, just configure it
        (add-to-list 'auto-mode-alist '("\\.zsh\\'" . sh-mode))
        (add-to-list 'auto-mode-alist '("\\.bash\\'" . sh-mode))
        (add-hook 'sh-mode-hook
                  (lambda ()
                    (setq sh-basic-offset 2
                          sh-indentation 2)))
        (use-package fish-mode
          :mode "\\.fish\\'")

      '' + optionalString cfg.nix.enable ''
        ;; == Nix ==
        (use-package nix-mode
          :mode "\\.nix\\'"
          :config
          (setq nix-indent-function 'nix-indent-line))

      '' + optionalString cfg.python.enable ''
        ;; == Python ==
        ;; python-mode is built-in
        (add-hook 'python-mode-hook
                  (lambda ()
                    (setq python-indent-offset 4
                          tab-width 4)))

      '' + optionalString cfg.json.enable ''
        ;; == JSON ==
        (use-package json-mode
          :mode "\\.json\\'"
          :config
          (setq js-indent-level 2))

      '' + optionalString cfg.yaml.enable ''
        ;; == YAML ==
        (use-package yaml-mode
          :mode ("\\.ya?ml\\'" "\\.yml\\.j2\\'"))

      '' + optionalString cfg.toml.enable ''
        ;; == TOML ==
        (use-package toml-mode
          :mode ("\\.toml\\'" "Cargo\\.lock\\'"))

      '' + optionalString cfg.xml.enable ''
        ;; == XML ==
        ;; nxml-mode is built-in and excellent
        (setq nxml-child-indent 2
              nxml-attribute-indent 2
              nxml-slash-auto-complete-flag t)
        (add-to-list 'auto-mode-alist '("\\.pom\\'" . nxml-mode))
        (add-to-list 'auto-mode-alist '("\\.xsd\\'" . nxml-mode))
        (add-to-list 'auto-mode-alist '("\\.xslt\\'" . nxml-mode))

      '' + optionalString cfg.markdown.enable ''
        ;; == Markdown ==
        (use-package markdown-mode
          :mode (("\\.md\\'" . markdown-mode)
                 ("\\.markdown\\'" . markdown-mode)
                 ("README\\.md\\'" . gfm-mode))
          :config
          (setq markdown-command "pandoc"
                markdown-fontify-code-blocks-natively t))

      '' + optionalString cfg.web.enable ''
        ;; == Web Mode (HTML, CSS, Templates) ==
        (use-package web-mode
          :mode ("\\.html?\\'" "\\.erb\\'" "\\.hbs\\'" "\\.ejs\\'"
                 "\\.j2\\'" "\\.jinja2\\'" "\\.mustache\\'"
                 "\\.vue\\'" "\\.svelte\\'")
          :config
          (setq web-mode-markup-indent-offset 2
                web-mode-css-indent-offset 2
                web-mode-code-indent-offset 2
                web-mode-enable-auto-pairing t
                web-mode-enable-css-colorization t))
        (use-package scss-mode
          :mode "\\.scss\\'")
        (use-package less-css-mode
          :mode "\\.less\\'")

      '' + optionalString cfg.javascript.enable ''
        ;; == JavaScript/TypeScript ==
        (use-package js2-mode
          :mode "\\.js\\'"
          :config
          (setq js2-basic-offset 2
                js-indent-level 2))
        (use-package typescript-mode
          :mode "\\.tsx?\\'"
          :config
          (setq typescript-indent-level 2))
        (use-package rjsx-mode
          :mode "\\.jsx\\'")

      '' + optionalString cfg.rust.enable ''
        ;; == Rust ==
        (use-package rust-mode
          :mode "\\.rs\\'"
          :config
          (setq rust-format-on-save nil))  ; Set to t if you want auto-format

        ;; Cargo - Rust package manager integration
        ;; M-x cargo-* commands: cargo-build, cargo-run, cargo-test, cargo-bench, etc.
        (use-package cargo
          :hook (rust-mode . cargo-minor-mode)
          :config
          ;; Cargo.toml is handled by toml-mode for editing
          ;; cargo-minor-mode adds C-c C-c prefix keybindings:
          ;; C-c C-c C-b - cargo-build
          ;; C-c C-c C-r - cargo-run
          ;; C-c C-c C-t - cargo-test
          ;; C-c C-c C-c - cargo-clippy
          (setq cargo-process--command-flags "--color always"))

      '' + optionalString cfg.go.enable ''
        ;; == Go ==
        (use-package go-mode
          :mode "\\.go\\'"
          :config
          (add-hook 'before-save-hook 'gofmt-before-save))

      '' + optionalString cfg.protobuf.enable ''
        ;; == Protocol Buffers ==
        (use-package protobuf-mode
          :mode "\\.proto\\'")

      '' + optionalString cfg.thrift.enable ''
        ;; == Thrift/IDL ==
        (use-package thrift
          :mode "\\.thrift\\'")
        ;; Also handle .avsc (Avro schema) as JSON
        (add-to-list 'auto-mode-alist '("\\.avsc\\'" . json-mode))
        (add-to-list 'auto-mode-alist '("\\.avdl\\'" . java-mode))  ; Avro IDL similar to Java

      '' + optionalString cfg.graphql.enable ''
        ;; == GraphQL ==
        (use-package graphql-mode
          :mode ("\\.graphql\\'" "\\.gql\\'"))

      '' + optionalString cfg.docker.enable ''
        ;; == Docker ==
        (use-package dockerfile-mode
          :mode ("Dockerfile\\'" "\\.dockerfile\\'"))

      '' + optionalString cfg.groovy.enable ''
        ;; == Groovy (for legacy Gradle files) ==
        (use-package groovy-mode
          :mode ("\\.groovy\\'" "\\.gradle\\'"))

      '' + optionalString cfg.lua.enable ''
        ;; == Lua ==
        (use-package lua-mode
          :mode "\\.lua\\'"
          :config
          (setq lua-indent-level 2))

      '' + optionalString cfg.lisp.enable ''
        ;; == Lisp Family ==

        ;; Rainbow delimiters for all Lisp modes
        (use-package rainbow-delimiters
          :hook ((emacs-lisp-mode . rainbow-delimiters-mode)
                 (lisp-mode . rainbow-delimiters-mode)
                 (scheme-mode . rainbow-delimiters-mode)
                 (clojure-mode . rainbow-delimiters-mode)
                 (racket-mode . rainbow-delimiters-mode)))

        ;; Paredit for structured editing
        (use-package paredit
          :hook ((emacs-lisp-mode . paredit-mode)
                 (lisp-mode . paredit-mode)
                 (scheme-mode . paredit-mode)
                 (clojure-mode . paredit-mode)
                 (racket-mode . paredit-mode)))

        ;; Clojure
        (use-package clojure-mode
          :mode (("\\.clj\\'" . clojure-mode)
                 ("\\.cljs\\'" . clojurescript-mode)
                 ("\\.cljc\\'" . clojurec-mode)
                 ("\\.edn\\'" . clojure-mode)))
        (use-package cider
          :hook (clojure-mode . cider-mode))

        ;; Common Lisp with SLY (modern SLIME alternative)
        (use-package sly
          :config
          (setq inferior-lisp-program "sbcl"))

        ;; Scheme with Geiser
        (use-package geiser
          :config
          (setq geiser-active-implementations '(guile racket)))

        ;; Racket
        (use-package racket-mode
          :mode "\\.rkt\\'")

      '' + optionalString cfg.build.enable ''
        ;; == Build Tools ==

        ;; CMake
        (use-package cmake-mode
          :mode ("CMakeLists\\.txt\\'" "\\.cmake\\'"))

        ;; Just (command runner)
        (use-package just-mode
          :mode ("justfile\\'" "\\.just\\'"))

        ;; Gradle - only enable in gradle project directories, not globally
        ;; Use M-x gradle-build, gradle-test, etc. when in a gradle project
        (use-package gradle-mode
          :commands (gradle-build gradle-test gradle-single-test gradle-execute)
          :config
          ;; Don't auto-enable as a minor mode globally
          ;; Instead, manually enable with M-x gradle-mode in gradle projects
          (setq gradle-use-gradlew t))  ; Prefer ./gradlew over gradle

        ;; Maven - M-x mvn for running maven commands
        (use-package mvn
          :commands (mvn mvn-compile mvn-test mvn-clean mvn-package)
          :config
          ;; pom.xml is handled by nxml-mode for editing
          ;; Use M-x mvn-* commands for running maven
          (setq mvn-build-command "mvn"))

        (use-package maven-test-mode
          :commands (maven-test-mode maven-test-toggle-between-test-and-class)
          :config
          ;; Enable in Java files within Maven projects (has pom.xml)
          (defun decknix--maybe-enable-maven-test-mode ()
            "Enable maven-test-mode if in a Maven project."
            (when (locate-dominating-file default-directory "pom.xml")
              (maven-test-mode 1)))
          (add-hook 'java-mode-hook #'decknix--maybe-enable-maven-test-mode))

        ;; Bazel
        (use-package bazel
          :mode (("BUILD\\'" . bazel-build-mode)
                 ("WORKSPACE\\'" . bazel-workspace-mode)
                 ("\\.bzl\\'" . bazel-starlark-mode)))

        ;; Makefile is built-in
        (add-to-list 'auto-mode-alist '("Makefile.*\\'" . makefile-mode))
        (add-to-list 'auto-mode-alist '("\\.mk\\'" . makefile-mode))

      '' + optionalString cfg.config.enable ''
        ;; == Config Files ==

        ;; EditorConfig
        (use-package editorconfig
          :config
          (editorconfig-mode 1))

        ;; Git files (built-in conf-mode)
        (add-to-list 'auto-mode-alist '("\\.gitignore\\'" . conf-mode))
        (add-to-list 'auto-mode-alist '("\\.gitattributes\\'" . conf-mode))
        (add-to-list 'auto-mode-alist '("\\.gitconfig\\'" . conf-mode))
        (add-to-list 'auto-mode-alist '("\\.env\\'" . conf-mode))
        (add-to-list 'auto-mode-alist '("\\.env\\..*\\'" . conf-mode))

        ;; Properties files
        (add-to-list 'auto-mode-alist '("\\.properties\\'" . conf-javaprop-mode))

        ;; Apache/Nginx configs
        (use-package apache-mode
          :mode ("\\.htaccess\\'" "httpd\\.conf\\'" "apache.*\\.conf\\'"))

        ;; SSH config
        (add-to-list 'auto-mode-alist '("config\\'" . conf-mode))
        (add-to-list 'auto-mode-alist '("known_hosts\\'" . conf-mode))

      '' + ''
        ;; == Font-lock for org-mode source blocks ==
        ;; Enable native syntax highlighting in org source blocks
        (setq org-src-fontify-natively t
              org-src-tab-acts-natively t
              org-src-preserve-indentation t)
      '';
    };
  };
}

