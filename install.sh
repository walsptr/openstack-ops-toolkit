#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# ============================================================
# OpenStack Ops Toolkit Installer
# ============================================================

INSTALL_DIR="/opt/openstack-ops-toolkit"
BIN_PATH="/usr/local/bin/openstack-ops-toolkit"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MAIN_SCRIPT="$SCRIPT_DIR/main.sh"
ENV_EXAMPLE="$SCRIPT_DIR/scripts.env.example"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

# ============================================================
# Re-run installer with sudo
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    echo "🔐 Root privileges are required."
    echo "   Re-running installer with sudo..."
    echo

    exec sudo "$0" "$@"
fi

# ============================================================
# Functions
# ============================================================

error() {
    echo "❌ ERROR: $1"
    exit 1
}

info() {
    echo "ℹ️  $1"
}

success() {
    echo "✅ $1"
}

# ============================================================
# Header
# ============================================================

echo
echo "========================================"
echo "   OpenStack Ops Toolkit Installer"
echo "========================================"
echo

# ============================================================
# Validate source files
# ============================================================

info "Checking installation files..."

[[ -f "$MAIN_SCRIPT" ]] || \
    error "main.sh not found: $MAIN_SCRIPT"

[[ -f "$ENV_EXAMPLE" ]] || \
    error "scripts.env.example not found: $ENV_EXAMPLE"

[[ -d "$SCRIPTS_DIR" ]] || \
    error "scripts directory not found: $SCRIPTS_DIR"

success "Installation files are valid."

# ============================================================
# Create workdir
# ============================================================

info "Creating workdir..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/scripts"

success "Workdir ready: $INSTALL_DIR"

# ============================================================
# Install operational scripts
# ============================================================

info "Installing operational scripts..."

cp -a "$SCRIPTS_DIR/." "$INSTALL_DIR/scripts/"

# Make shell scripts executable
find "$INSTALL_DIR/scripts" \
    -type f \
    -name "*.sh" \
    -exec chmod 0755 {} \;

success "Operational scripts installed."

# ============================================================
# Install scripts.env
# ============================================================

if [[ -f "$INSTALL_DIR/scripts.env" ]]; then

    info "Existing scripts.env detected."
    info "Keeping existing configuration."

else

    info "Creating scripts.env from scripts.env.example..."

    cp "$ENV_EXAMPLE" "$INSTALL_DIR/scripts.env"
    chmod 0644 "$INSTALL_DIR/scripts.env"

    success "scripts.env created."

fi

# ============================================================
# Install main command
# ============================================================

info "Installing command..."

install -m 0755 \
    "$MAIN_SCRIPT" \
    "$BIN_PATH"

success "Command installed: $BIN_PATH"

# ============================================================
# Permissions
# ============================================================

chmod 0755 "$INSTALL_DIR"
chmod 0644 "$INSTALL_DIR/scripts.env"

# ============================================================
# Final summary
# ============================================================

echo
echo "========================================"
echo "       Installation Completed"
echo "========================================"
echo
echo "Workdir:"
echo "  $INSTALL_DIR"
echo
echo "Configuration:"
echo "  $INSTALL_DIR/scripts.env"
echo
echo "Scripts:"
echo "  $INSTALL_DIR/scripts/"
echo
echo "Command:"
echo "  $BIN_PATH"
echo
echo "Usage:"
echo "  openstack-ops-toolkit"
echo
echo "Custom workdir:"
echo "  openstack-ops-toolkit --workdir /path/to/workdir"
echo
