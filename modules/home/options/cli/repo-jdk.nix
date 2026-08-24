# repo-jdk — resolve the JDK a repository declares, instead of assuming one.
#
# On a machine running both Nix and SDKMAN, the `java` that wins on PATH is an
# accident of shell-init ordering: SDKMAN sources late and prepends its
# `current` candidate, shadowing the Nix JDK the rest of the configuration
# assumes. Builds then run on a JDK their own build files never asked for, and
# it surfaces as something unhelpful — an annotation processor rejecting a class
# file version, say — rather than as "wrong Java".
#
# The fix is not to pin a different default. Different repositories legitimately
# need different JDKs (this org has services on 21 alongside a monolith on 25),
# so the only correct answer is per-repository: read what the repo declares, and
# run against that.
#
# Detection walks up from the working directory to the repository root and takes
# the first declaration it finds, preferring an explicit toolchain pin
# (.sdkmanrc, .tool-versions, .java-version, .mise.toml) over a build file's
# language level (Gradle jvmToolchain/JavaLanguageVersion, Maven
# maven.compiler.release).
#
# Resolution never downloads anything — it selects from JDKs already installed,
# preferring Nix-provided ones because they are the only origin that reproduces
# on a fresh machine.
#
#   repo-jdk                      # explain: what is declared, what is installed
#   repo-jdk version              # 25
#   repo-jdk home                 # /nix/store/...-zulu-ca-jdk-25.0.0
#   eval "$(repo-jdk env)"        # export JAVA_HOME/PATH into this shell
#   repo-jdk exec -- ./gradlew build
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf;

  cfg = config.decknix.cli.repoJdk;

  repoJdkScript = pkgs.writeShellScriptBin "repo-jdk" ''
    exec ${pkgs.python3}/bin/python3 ${./repo-jdk/repo_jdk.py} "$@"
  '';

in {
  options.decknix.cli.repoJdk = {
    enable = mkEnableOption "repo-jdk per-repository JDK resolution" // {
      default = true;
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ repoJdkScript ];

    # Register as a decknix subcommand: `decknix repo-jdk`
    decknix.cli.extensions.repo-jdk = {
      description = "Resolve the JDK a repository declares";
      command = "${repoJdkScript}/bin/repo-jdk";
    };
  };
}
