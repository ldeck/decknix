#!/usr/bin/env bash
set -e

# --- Configuration ---
REPO_URL="github:ldeck/decknix"
DEFAULT_REF="main"
TARGET_DIR="$HOME/decknix"
BACKUP_SUFFIX=".before-decknix"

# --- Styling ---
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

function step() { echo -e "\n${BLUE}${BOLD}==>${NC} ${BOLD}$1${NC}"; }
function info() { echo -e "${GREEN}  ->${NC} $1"; }
function warn() { echo -e "${RED}  !!${NC} $1"; }

# --- 0. Version Selection ---
step "🚀 Decknix Bootstrap..."
step "Which version of Decknix would you like to install?"
info "  [Enter] for Default ($DEFAULT_REF)"
info "  Or type a branch name / tag (e.g., 'v0.1.0', 'develop')"
read -p "Ref: " USER_REF
TARGET_REF=${USER_REF:-$DEFAULT_REF}
REPO_URL="${REPO_URL}/tree/${TARGET_REF}"

info "⬇️  Installing from reference: $TARGET_REF"

# --- 1. Install Nix ---
step "Phase 1: Checking Nix Installation"
if command -v nix >/dev/null; then
    info "✅ Nix is already installed."
else
    warn "↘️  Nix needs to be installed."
    echo "Choose an installer:"
    echo "  1) 📗 ** Decknix supported**: Nix Community's nix-installer (Experimental fork of the Determinate Systems installer)"
    echo "  2) 📒 Official Nix Installer (Standard)"
    echo "  3) 📙 Determinate Systems (May be incompatible with nix-darwin configuration of decknix. TBD)"

    read -p "Selection [1]: " installer_choice
    installer_choice=${installer_choice:-1}

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
    if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    fi
fi

# --- 2. Nix-Darwin Pre-flight ---
step "Phase 2: Pre-flight Checks"
CONFLICTS=("/etc/nix/nix.conf" "/etc/zshenv" "/etc/zshrc" "/etc/bashrc")

for FILE in "${CONFLICTS[@]}"; do
    if [ -f "$FILE" ] && [ ! -L "$FILE" ]; then
        warn "Found conflicting file: $FILE"
        sudo mv "$FILE" "$FILE$BACKUP_SUFFIX"
        info "Moved to $FILE$BACKUP_SUFFIX"
    fi
done

# --- 3. Initialize Template ---
step "Phase 3: Initializing Decknix"

if [ -d "$TARGET_DIR" ]; then
    info "Directory $TARGET_DIR already exists. Skipping init."
else
    mkdir -p "$TARGET_DIR"
    cd "$TARGET_DIR"

    info "Downloading template from $REPO_URL..."
    # We use 'nix flake init' which is cleaner than git clone for templates
    nix \
      --extra-experimental-features "nix-command flakes" \
      flake init -t "$REPO_URL"

    # --- INTERACTIVE SETUP (The Magic Step) ---
    echo ""
    echo "We need to configure your basic settings."

    DEFAULT_USER=$(whoami)
    DEFAULT_HOST=$(hostname -s)
    DEFAULT_SYSTEM=$(nix-instantiate --eval --expr 'builtins.currentSystem' --raw)
    DEFAULT_ROLE=developer

    read -p "  Enter System Username [$DEFAULT_USER]: " IN_USER
    IN_USER=${IN_USER:-$DEFAULT_USER}

    read -p "  Enter Hostname [$DEFAULT_HOST]: " IN_HOST
    IN_HOST=${IN_HOST:-$DEFAULT_HOST}

    read -p "  Enter role [$DEFAULT_ROLE]: " IN_ROLE
    IN_ROLE=${IN_ROLE:-$DEFAULT_ROLE}

    info "Generating settings.nix..."
    info "-- username = $DEFAULT_USER"
    info "-- hostname = $DEFAULT_HOST"
    info "-- system   = $DEFAULT_SYSTEM"
    info "-- role     = $DEFAULT_ROLE"
    cat <<EOF > settings.nix
{
  username = "$IN_USER";
  hostname = "$IN_HOST";
  system   = "$DEFAULT_SYSTEM";
  role     = "developer";
}
EOF
fi

# --- 4. Activation ---
step "Phase 4: Activating System"
cd "$TARGET_DIR"

info "Building flake. This may take a few minutes..."
info "You may be asked for your sudo password."

if sudo nix --extra-experimental-features "nix-command flakes" run nix-darwin -- switch --flake .#default --impure; then
    # --- 5. Success ---
    echo ""
    echo -e "${GREEN}${BOLD}✨ Success! Decknix is installed.${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Close this terminal and open a new one."
    echo "  2. Run 'dnx help' to see available commands."
    echo "  3. Explore your config in $TARGET_DIR"
else
    # --- 6. Failure ---
    echo ""
    warn "Activation Failed."
    echo "Troubleshooting:"
    echo "  - Check the error message above."
    echo "  - Ensure you have internet connectivity."
    echo "  - Open an issue at [https://github.com/ldeck/decknix/issues](https://github.com/ldeck/decknix/issues)"
    exit 1
fi

