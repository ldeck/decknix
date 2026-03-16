{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption types mkIf;

  cfg = config.decknix.cli.board;

  repos = builtins.concatStringsSep " " cfg.repos;

  boardScript = pkgs.writeShellScriptBin "decknix-board" ''
    set -euo pipefail

    # ── Colours ──────────────────────────────────────────────────────
    BOLD=$'\e[1m'
    DIM=$'\e[2m'
    RESET=$'\e[0m'
    RED=$'\e[31m'
    GREEN=$'\e[32m'
    YELLOW=$'\e[33m'
    BLUE=$'\e[34m'
    MAGENTA=$'\e[35m'
    CYAN=$'\e[36m'
    WHITE=$'\e[37m'
    BG_RED=$'\e[41m'
    BG_YELLOW=$'\e[43m'
    BG_BLUE=$'\e[44m'
    BG_GREEN=$'\e[42m'
    GREY=$'\e[90m'

    # Disable colours if not a terminal or --no-color
    if [[ ! -t 1 ]] || [[ "''${1:-}" == "--no-color" ]]; then
      BOLD="" DIM="" RESET="" RED="" GREEN="" YELLOW="" BLUE=""
      MAGENTA="" CYAN="" WHITE="" BG_RED="" BG_YELLOW="" BG_BLUE=""
      BG_GREEN="" GREY=""
    fi

    REPOS=(${repos})
    STATE="''${1:-open}"
    [[ "$STATE" == "--no-color" ]] && STATE="''${2:-open}"

    # ── Helpers ──────────────────────────────────────────────────────
    colorise_label() {
      local label="$1"
      case "$label" in
        "P0: critical")  printf "%s" "''${BG_RED}''${WHITE}''${BOLD} P0 ''${RESET}" ;;
        "P1: adoption")  printf "%s" "''${BG_YELLOW}''${WHITE}''${BOLD} P1 ''${RESET}" ;;
        "P2: polish")    printf "%s" "''${BG_BLUE}''${WHITE} P2 ''${RESET}" ;;
        bug)             printf "%s" "''${RED}bug''${RESET}" ;;
        enhancement)     printf "%s" "''${GREEN}enhancement''${RESET}" ;;
        documentation)   printf "%s" "''${CYAN}docs''${RESET}" ;;
        architecture)    printf "%s" "''${MAGENTA}arch''${RESET}" ;;
        bootstrap)       printf "%s" "''${YELLOW}bootstrap''${RESET}" ;;
        cli)             printf "%s" "''${BLUE}cli''${RESET}" ;;
        editors)         printf "%s" "''${GREEN}editors''${RESET}" ;;
        window-manager)  printf "%s" "''${MAGENTA}wm''${RESET}" ;;
        *)               printf "%s" "''${DIM}%s''${RESET}" "$label" ;;
      esac
    }

    extract_deps() {
      local body="$1"
      # Extract "#<num>" references from Depends on / Blocked by / Related lines
      echo "$body" | ${pkgs.gnugrep}/bin/grep -iE '(depends on|blocked by|blocks|related)' \
        | ${pkgs.gnugrep}/bin/grep -oE '(ldeck/decknix|UpsideRealty/experiment-decknix-config)?#[0-9]+' \
        | sort -u || true
    }

    separator() {
      printf "%s%s%s\n" "$DIM" "$(printf '─%.0s' {1..78})" "$RESET"
    }

    # ── Header ───────────────────────────────────────────────────────
    printf "\n%s%s DECKNIX ISSUE BOARD %s\n" "$BOLD" "$CYAN" "$RESET"
    printf "%s%s%s\n\n" "$DIM" "$(printf '═%.0s' {1..78})" "$RESET"

    for REPO in "''${REPOS[@]}"; do
      SHORT="$(basename "$REPO")"
      # Counts
      OPEN=$(${pkgs.gh}/bin/gh issue list -R "$REPO" -s open --json number -q 'length')
      CLOSED=$(${pkgs.gh}/bin/gh issue list -R "$REPO" -s closed --json number -q 'length' -L 1000)

      printf "%s%s %s %s  %s%s open%s  %s%s closed%s\n" \
        "$BOLD" "$WHITE" "$REPO" "$RESET" \
        "$GREEN" "$OPEN" "$RESET" \
        "$DIM" "$CLOSED" "$RESET"
      separator

      # Fetch issues
      ISSUES=$(${pkgs.gh}/bin/gh issue list -R "$REPO" -s "$STATE" \
        --json number,title,labels,body,state \
        -q '.[] | @base64' -L 200)

      if [[ -z "$ISSUES" ]]; then
        printf "  %sNo %s issues%s\n\n" "$DIM" "$STATE" "$RESET"
        continue
      fi

      while IFS= read -r ENCODED; do
        ROW=$(echo "$ENCODED" | base64 -d)
        NUM=$(echo "$ROW"   | ${pkgs.jq}/bin/jq -r '.number')
        TITLE=$(echo "$ROW" | ${pkgs.jq}/bin/jq -r '.title')
        LABELS=$(echo "$ROW" | ${pkgs.jq}/bin/jq -r '.labels[].name' 2>/dev/null)
        BODY=$(echo "$ROW"  | ${pkgs.jq}/bin/jq -r '.body // ""')
        IS_CLOSED=$(echo "$ROW" | ${pkgs.jq}/bin/jq -r '.state')

        # Number + title
        if [[ "$IS_CLOSED" == "CLOSED" ]]; then
          NUM_COL="$GREEN"
          STRIKE="$DIM"
        else
          NUM_COL="$YELLOW"
          STRIKE=""
        fi
        printf "  %s#%-4s%s %s%s%s" "$NUM_COL" "$NUM" "$RESET" "$STRIKE" "$TITLE" "$RESET"

        # Labels (inline)
        if [[ -n "$LABELS" ]]; then
          printf "  "
          while IFS= read -r LBL; do
            [[ -n "$LBL" ]] && { printf "["; colorise_label "$LBL"; printf "] "; }
          done <<< "$LABELS"
        fi
        printf "\n"

        # Dependencies
        DEPS=$(extract_deps "$BODY")
        if [[ -n "$DEPS" ]]; then
          DEP_LINE=$(echo "$DEPS" | tr '\n' ' ')
          printf "         %s↳ deps: %s%s\n" "$GREY" "$DEP_LINE" "$RESET"
        fi
      done <<< "$ISSUES"

      printf "\n"
    done

    # ── Footer ───────────────────────────────────────────────────────
    printf "%sUsage: decknix-board [open|closed|all] [--no-color]%s\n\n" "$DIM" "$RESET"
  '';

in {
  options.decknix.cli.board = {
    enable = mkEnableOption "decknix-board issue dashboard";

    repos = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "ldeck/decknix" "UpsideRealty/experiment-decknix-config" ];
      description = ''
        GitHub repositories to show on the board.
        Format: "owner/repo" (e.g., "ldeck/decknix").
        Multiple repos are displayed in sequence.
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ boardScript ];

    # Register as decknix subcommand: decknix board
    programs.decknix-cli.subtasks.board = {
      description = "Issue dashboard across repos";
      command = "${boardScript}/bin/decknix-board";
    };
  };
}

