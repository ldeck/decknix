#!/usr/bin/env bash
set -e

# --- Configuration ---
REPO_URL="github:ldeck/decknix"
DEFAULT_REF="main"
TARGET_DIR="$HOME/.config/decknix"
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
BACKUP_SUFFIX=".before-decknix.${TIMESTAMP}"

# --- Non-interactive mode ---
# Enabled by: --non-interactive flag, or CI=true env var
# When enabled, all prompts use defaults or env var overrides:
#   DECKNIX_REF       — git ref to install (default: main)
#   DECKNIX_INSTALLER — nix installer choice: 1|2|3 (default: 1)
#   DECKNIX_USER      — system username (default: $(whoami))
#   DECKNIX_HOST      — hostname (default: $(hostname -s))
#   DECKNIX_ROLE      — user role (default: developer)
NON_INTERACTIVE=0

# --- Skip flags (set any to "1" to skip that phase) ---
# SKIP_NIX=1        — skip Nix installation check
# SKIP_PREFLIGHT=1  — skip pre-flight conflict resolution
# SKIP_INIT=1       — skip template initialisation
# SKIP_ACTIVATE=1   — skip system activation

# --- Parse arguments ---
for arg in "$@"; do
    case "$arg" in
        --non-interactive) NON_INTERACTIVE=1 ;;
    esac
done

# Auto-detect CI environments
if [ "${CI:-}" = "true" ] || [ "${CI:-}" = "1" ]; then
    NON_INTERACTIVE=1
fi

# --- Styling ---
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

function step()  { echo -e "\n${BLUE}${BOLD}==>${NC} ${BOLD}$1${NC}"; }
function info()  { echo -e "${GREEN}  ->${NC} $1"; }
function skip()  { echo -e "${YELLOW}  ⏭${NC} $1"; }
function warn()  { echo -e "${RED}  !!${NC} $1"; }

# --- 0. Version Selection ---
step "🚀 Decknix Bootstrap..."

if [ "$NON_INTERACTIVE" = "1" ]; then
    info "Running in non-interactive mode"
    TARGET_REF=${DECKNIX_REF:-$DEFAULT_REF}
else
    step "Which version of Decknix would you like to install?"
    info "  [Enter] for Default ($DEFAULT_REF)"
    info "  Or type a branch name / tag (e.g., 'v0.1.0', 'develop')"
    read -rp "Ref: " USER_REF
    TARGET_REF=${USER_REF:-$DEFAULT_REF}
fi

REPO_URL="${REPO_URL}/tree/${TARGET_REF}"
info "⬇️  Installing from reference: $TARGET_REF"

# --- 1. Install Nix ---
step "Phase 1: Checking Nix Installation"
if [ "${SKIP_NIX:-}" = "1" ]; then
    skip "Skipped (SKIP_NIX=1)"
elif command -v nix >/dev/null; then
    info "✅ Nix is already installed."
else
    warn "↘️  Nix needs to be installed."

    if [ "$NON_INTERACTIVE" = "1" ]; then
        installer_choice=${DECKNIX_INSTALLER:-1}
        info "Using installer option $installer_choice (non-interactive)"
    else
        echo "Choose an installer:"
        echo "  1) 📗 ** Decknix supported**: Nix Community's nix-installer (Experimental fork of the Determinate Systems installer)"
        echo "  2) 📒 Official Nix Installer (Standard)"
        echo "  3) 📙 Determinate Systems (May be incompatible with nix-darwin configuration of decknix. TBD)"

        read -rp "Selection [1]: " installer_choice
        installer_choice=${installer_choice:-1}
    fi

    if [[ "$installer_choice" == "1" ]]; then
      info "Running Nix Community's nix-installer..."
      curl --proto '=https' --tlsv1.2 -sSf -L https://artifacts.nixos.org/experimental-installer | \
        sh -s -- install --no-confirm --extra-conf "trusted-users = $(whoami)"
    elif [[ "$installer_choice" == "2" ]]; then
      info "Running Official Installer..."
      sh <(curl -L https://nixos.org/nix/install)
    elif [[ "$installer_choice" == "3" ]]; then
        info "Running Determinate Systems Installer..."
        curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
    else
        info "Invalid nix installer option... exiting"
        exit 1
    fi

    # Source nix profile so we can use it immediately without restarting shell
    # shellcheck source=/dev/null
    if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    fi
fi

# --- 2. Nix-Darwin Pre-flight ---
step "Phase 2: Pre-flight Checks"
if [ "${SKIP_PREFLIGHT:-}" = "1" ]; then
    skip "Skipped (SKIP_PREFLIGHT=1)"
else
    CONFLICTS=("/etc/nix/nix.conf" "/etc/zshenv" "/etc/zshrc" "/etc/bashrc")

    for FILE in "${CONFLICTS[@]}"; do
        if [ -L "$FILE" ]; then
            info "✅ $FILE is a symlink (managed by nix-darwin)"
        elif [ -f "$FILE" ]; then
            warn "Found conflicting file: $FILE"
            sudo mv "$FILE" "$FILE$BACKUP_SUFFIX"
            info "Backed up to $FILE$BACKUP_SUFFIX"
        fi
    done
fi

# --- 3. Initialize Template ---
step "Phase 3: Initializing Decknix"
if [ "${SKIP_INIT:-}" = "1" ]; then
    skip "Skipped (SKIP_INIT=1)"
else
    # Helper: prompt for settings and write settings.nix
    # In non-interactive mode, uses env vars or auto-detected defaults.
    generate_settings() {
        local dir="$1"

        local detected_user detected_host detected_system
        detected_user=$(whoami)
        detected_host=$(hostname -s)
        detected_system=$(nix-instantiate --eval --expr 'builtins.currentSystem' --raw)

        if [ "$NON_INTERACTIVE" = "1" ]; then
            IN_USER=${DECKNIX_USER:-$detected_user}
            IN_HOST=${DECKNIX_HOST:-$detected_host}
            IN_ROLE=${DECKNIX_ROLE:-developer}
            info "Using settings from environment (non-interactive)"
        else
            echo ""
            echo "We need to configure your basic settings."

            read -rp "  Enter System Username [$detected_user]: " IN_USER
            IN_USER=${IN_USER:-$detected_user}

            read -rp "  Enter Hostname [$detected_host]: " IN_HOST
            IN_HOST=${IN_HOST:-$detected_host}

            read -rp "  Enter role [developer]: " IN_ROLE
            IN_ROLE=${IN_ROLE:-developer}
        fi

        info "Generating settings.nix..."
        info "-- username = $IN_USER"
        info "-- hostname = $IN_HOST"
        info "-- system   = $detected_system"
        info "-- role     = $IN_ROLE"
        cat <<EOF > "$dir/settings.nix"
{
  username = "$IN_USER";
  hostname = "$IN_HOST";
  system   = "$detected_system";
  role     = "$IN_ROLE";
}
EOF
    }

    if [ -d "$TARGET_DIR" ]; then
        if [ -f "$TARGET_DIR/flake.nix" ]; then
            info "✅ $TARGET_DIR already initialised."
        else
            warn "$TARGET_DIR exists but has no flake.nix — re-initialising template..."
            cd "$TARGET_DIR"
            nix \
              --extra-experimental-features "nix-command flakes" \
              flake init -t "$REPO_URL"
        fi

        # Recover missing settings.nix
        if [ ! -f "$TARGET_DIR/settings.nix" ]; then
            warn "settings.nix is missing — regenerating..."
            generate_settings "$TARGET_DIR"
        fi
    else
        mkdir -p "$TARGET_DIR"
        cd "$TARGET_DIR"

        info "Downloading template from $REPO_URL..."
        nix \
          --extra-experimental-features "nix-command flakes" \
          flake init -t "$REPO_URL"

        generate_settings "$TARGET_DIR"
    fi
fi

# --- 4. Activation ---
step "Phase 4: Activating System"
if [ "${SKIP_ACTIVATE:-}" = "1" ]; then
    skip "Skipped (SKIP_ACTIVATE=1)"
else
    cd "$TARGET_DIR"

    info "Building flake. This may take a few minutes..."
    info "You may be asked for your sudo password."

    # Use darwin-rebuild directly if already installed (re-run), otherwise bootstrap via nix run
    if command -v darwin-rebuild >/dev/null 2>&1; then
        ACTIVATE_CMD="sudo darwin-rebuild switch --flake .#default --impure"
    else
        ACTIVATE_CMD="sudo nix --extra-experimental-features 'nix-command flakes' run nix-darwin -- switch --flake .#default --impure"
    fi

    if eval "$ACTIVATE_CMD"; then
        echo ""
        echo -e "${GREEN}${BOLD}✨ Success! Decknix is installed.${NC}"
        echo ""
        echo "Next steps:"
        echo "  1. Close this terminal and open a new one."
        echo "  2. Run 'decknix help' to see available commands (or 'decknix-board' for issue tracking)."
        echo "  3. Explore your config in $TARGET_DIR"
    else
        echo ""
        warn "Activation Failed."
        echo "Troubleshooting:"
        echo "  - Check the error message above."
        echo "  - Ensure you have internet connectivity."
        echo "  - Open an issue at https://github.com/ldeck/decknix/issues"
        exit 1
    fi
fi

