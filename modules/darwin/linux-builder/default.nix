{ config, lib, pkgs, ... }:

with lib;

# Linux remote builder (a NixOS VM under qemu/hvf) so macOS can build Linux
# derivations locally, e.g. `dockerTools` OCI images for the hermetic Nix
# container builds (ACME-539). The guest is aarch64-linux (native on Apple
# silicon), enough to build and run the image locally; the linux/amd64 deploy
# image is built natively in CI.
#
# Why on demand: nix-darwin runs the VM as an always-on LaunchDaemon. Its RAM
# is never handed back to macOS (no balloon), so after weeks of uptime the qemu
# process sat at a ~12 GB footprint, almost all compressed or swapped, on a
# 48 GB machine already deep in swap, for a builder used a few times a week.
#
# How: the VM's SSH forward moves to backendPort, and a socket-activated
# launchd job takes over the public port (31022, which nix-darwin's ssh config
# and `nix.buildMachines` hard-code). Each connection boots the VM if needed,
# waits for its SSH banner, then relays. A timer powers the guest off once no
# connection has touched it for idleMinutes. Nothing about the host key or the
# `linux-builder` ssh alias changes, so nix sees the same builder.

let
  cfg = config.decknix.linuxBuilder;
  label = "org.nixos.linux-builder";
  publicPort = 31022;
  stateDir = "/var/lib/linux-builder-on-demand";

  builderMachine = findFirst (m: m.hostName == "linux-builder") null config.nix.buildMachines;

  scriptEnv = ''
    export LINUX_BUILDER_BACKEND_PORT=${toString cfg.backendPort}
    export LINUX_BUILDER_LABEL=${label}
    export LINUX_BUILDER_STATE_DIR=${stateDir}
  '';

  activator = pkgs.writeShellApplication {
    name = "linux-builder-activator";
    runtimeInputs = [ pkgs.socat pkgs.coreutils pkgs.gnugrep ];
    text = scriptEnv + ''
      export LINUX_BUILDER_START_TIMEOUT=${toString cfg.startTimeoutSeconds}
    '' + builtins.readFile ./activator.sh;
  };

  # Installed system-wide so a manual graceful stop is one command.
  idleStop = pkgs.writeShellApplication {
    name = "linux-builder-stop";
    runtimeInputs = [ pkgs.openssh pkgs.coreutils pkgs.gnugrep ];
    text = scriptEnv + ''
      export LINUX_BUILDER_IDLE_MINUTES=${toString cfg.idleMinutes}
      export LINUX_BUILDER_HOST_KEY_B64=${escapeShellArg builderMachine.publicHostKey}
    '' + builtins.readFile ./idle-stop.sh;
  };
in
{
  options.decknix.linuxBuilder = {
    enable = mkOption {
      type = types.bool;
      default = config.decknix.adoption.components.linux-builder.enable;
      defaultText = literalExpression "config.decknix.adoption.components.linux-builder.enable";
      description = ''
        Run nix-darwin's Linux builder VM so Linux derivations build locally.
        Turning this off makes nix-darwin delete the VM's disk image on the
        next switch.
      '';
    };

    onDemand = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Boot the VM on the first build connection and power it off after
        idleMinutes without one. False restores nix-darwin's always-on daemon.
      '';
    };

    idleMinutes = mkOption {
      type = types.ints.positive;
      default = 20;
      description = "Minutes without a builder connection before the VM is powered off.";
    };

    startTimeoutSeconds = mkOption {
      type = types.ints.positive;
      default = 120;
      description = ''
        How long a connection waits for the VM to boot before failing, so a
        builder that will not start fails the nix build rather than hanging it.
      '';
    };

    backendPort = mkOption {
      type = types.port;
      default = 31023;
      description = "Host port the VM's own SSH forward listens on when onDemand is set.";
    };

    memoryMiB = mkOption {
      type = types.ints.positive;
      default = 6 * 1024;
      description = "Guest RAM in MiB.";
    };

    cores = mkOption {
      type = types.ints.positive;
      default = 6;
      description = "Guest vCPUs.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      nix.linux-builder = {
        enable = true;
        maxJobs = mkDefault 4;
        config.virtualisation = {
          inherit (cfg) cores;
          darwin-builder.diskSize = mkDefault (40 * 1024); # MiB: room for the JVM dep closure
          darwin-builder.memorySize = cfg.memoryMiB;
        };
      };
    }

    (mkIf cfg.onDemand {
      assertions = [{
        assertion = cfg.backendPort != publicPort;
        message = "decknix.linuxBuilder.backendPort must differ from ${toString publicPort}, which the activator owns.";
      }];

      # Only qemu's host-side forward moves; the guest system is unchanged, so
      # this needs no Linux builder to build.
      nix.linux-builder.config.virtualisation.darwin-builder.hostPort = cfg.backendPort;

      launchd.daemons.linux-builder.serviceConfig = {
        KeepAlive = mkForce false;
        RunAtLoad = mkForce false;
      };

      # Root only because kickstarting a system-domain job needs it. The script
      # takes no input from the socket; it only relays the bytes.
      launchd.daemons.linux-builder-activator.serviceConfig = {
        ProgramArguments = [ "${activator}/bin/linux-builder-activator" ];
        inetdCompatibility.Wait = false;
        Sockets.Listener = {
          SockNodeName = "127.0.0.1";
          SockServiceName = toString publicPort;
          SockFamily = "IPv4";
        };
      };

      launchd.daemons.linux-builder-idle-stop.serviceConfig = {
        ProgramArguments = [ "${idleStop}/bin/linux-builder-stop" "--if-idle" ];
        StartInterval = min 300 (cfg.idleMinutes * 60);
        StandardErrorPath = "/var/log/linux-builder-idle-stop.log";
      };

      environment.systemPackages = [ idleStop ];
    })
  ]);
}
