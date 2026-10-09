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

# Versi minimum
BASH_MIN_MAJOR=4
FZF_MIN_VERSION="0.20.0"   # versi terlama yang sudah dites dengan TUI main.sh

ASSUME_YES=0
SKIP_CHECKS=0
CHECKED=0

# ============================================================
# Functions
# ============================================================

error() {
    echo "❌ ERROR: $1" >&2
    exit 1
}

info() {
    echo "ℹ️  $1"
}

success() {
    echo "✅ $1"
}

warn() {
    echo "⚠️  $1"
}

usage() {
    echo "Usage: install.sh [--yes] [--skip-checks]"
    echo
    echo "Options:"
    echo "  -y, --yes         Non-interaktif: otomatis tambahkan entry baru ke scripts.env"
    echo "  --skip-checks     Lewati pengecekan requirement (tidak disarankan)"
    echo "  -h, --help        Tampilkan help"
}

# version_ge A B  => true jika A >= B
version_ge() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

# Saran perintah install berdasarkan package manager
pkg_hint() {
    local pkg_dnf="$1"
    local pkg_apt="$2"

    if command -v dnf >/dev/null 2>&1; then
        echo "sudo dnf install -y $pkg_dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "sudo yum install -y $pkg_dnf"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "sudo apt-get install -y $pkg_apt"
    else
        echo "install package: $pkg_dnf"
    fi
}

# ============================================================
# Requirement checks
# ============================================================

MISSING=0

req_ok() {
    printf '  ✅ %-22s %s\n' "$1" "$2"
}

req_missing() {
    printf '  ❌ %-22s %s\n' "$1" "$2"
    printf '     %-22s ↳ %s\n' "" "$3"
    MISSING=$((MISSING + 1))
}

req_optional() {
    printf '  ⚠️  %-21s %s\n' "$1" "$2"
    printf '     %-22s ↳ %s\n' "" "$3"
}

check_requirements() {
    local version

    echo "🔍 Checking requirements..."
    echo

    echo "Required:"

    # bash
    if (( BASH_VERSINFO[0] >= BASH_MIN_MAJOR )); then
        req_ok "bash" "$BASH_VERSION"
    else
        req_missing "bash" "$BASH_VERSION (butuh >= $BASH_MIN_MAJOR.0)" \
            "$(pkg_hint bash bash)"
    fi

    # OpenStack client
    if command -v openstack >/dev/null 2>&1; then
        version="$(openstack --version 2>&1 | awk '{print $NF}')"
        req_ok "openstack" "${version:-unknown} ($(command -v openstack))"
    else
        req_missing "openstack" "python-openstackclient tidak ditemukan" \
            "$(pkg_hint python3-openstackclient python3-openstackclient)  atau  pip install python-openstackclient"
    fi

    # python3 (formatter tabel resource view di TUI)
    if command -v python3 >/dev/null 2>&1; then
        req_ok "python3" "$(python3 --version 2>&1 | awk '{print $2}')"
    else
        req_missing "python3" "tidak ditemukan" "$(pkg_hint python3 python3)"
    fi

    # fzf
    if command -v fzf >/dev/null 2>&1; then
        version="$(fzf --version 2>/dev/null | awk '{print $1}')"

        if [[ -n "$version" ]] && version_ge "$version" "$FZF_MIN_VERSION"; then
            req_ok "fzf" "$version"
        else
            req_missing "fzf" "${version:-unknown} (butuh >= $FZF_MIN_VERSION)" \
                "upgrade fzf: https://github.com/junegunn/fzf/releases"
        fi
    else
        req_missing "fzf" "tidak ditemukan" "$(pkg_hint fzf fzf)"
    fi

    # Core utilities yang dipakai main.sh & scripts
    local tool
    local missing_core=()

    for tool in awk sed grep find sort cut realpath install; do
        command -v "$tool" >/dev/null 2>&1 || missing_core+=("$tool")
    done

    if (( ${#missing_core[@]} == 0 )); then
        req_ok "core utils" "awk sed grep find sort cut realpath install"
    else
        req_missing "core utils" "tidak ditemukan: ${missing_core[*]}" \
            "$(pkg_hint "coreutils findutils gawk sed grep" "coreutils findutils gawk sed grep")"
    fi

    # sudo (hanya jika bukan root)
    if [[ "$EUID" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            req_ok "sudo" "$(command -v sudo)"
        else
            req_missing "sudo" "tidak ditemukan (atau jalankan installer sebagai root)" \
                "$(pkg_hint sudo sudo)"
        fi
    fi

    echo
    echo "Optional:"

    # cinder client (dipakai volumes/import-vol-from-netapp.sh)
    if command -v cinder >/dev/null 2>&1; then
        req_ok "cinder" "$(command -v cinder)"
    else
        req_optional "cinder" "tidak ditemukan (dibutuhkan 'Import Volume from NetApp')" \
            "$(pkg_hint python3-cinderclient python3-cinderclient)  atau  pip install python-cinderclient"
    fi

    # bat (syntax highlight di preview)
    if command -v bat >/dev/null 2>&1 || command -v batcat >/dev/null 2>&1; then
        req_ok "bat" "syntax highlight preview"
    else
        req_optional "bat" "tidak ditemukan (preview tanpa syntax highlight)" \
            "$(pkg_hint bat bat)"
    fi

    # pager untuk Ctrl-E
    if command -v "${PAGER:-less}" >/dev/null 2>&1; then
        req_ok "pager" "${PAGER:-less}"
    else
        req_optional "pager" "${PAGER:-less} tidak ditemukan (Ctrl-E view source)" \
            "$(pkg_hint less less)"
    fi

    echo

    if (( MISSING > 0 )); then
        error "$MISSING requirement belum terpenuhi. Install terlebih dahulu, lalu jalankan ulang installer."
    fi

    success "All required dependencies are installed."
    echo
}

# Print path script dari file scripts.env (format: Nama,path)
env_paths() {
    local line path

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || "$line" == \#* || "$line" != *,* ]] && continue

        path="${line##*,}"
        path="${path//[[:space:]]/}"
        [[ -n "$path" ]] && echo "$path"
    done < "$1"

    return 0
}

# Tambahkan entry dari scripts.env.example yang belum ada di scripts.env
sync_scripts_env() {
    local env_file="$1"
    local line path
    local missing=()
    local -A existing=()

    # Path script yang sudah terdaftar
    while IFS= read -r path; do
        existing["$path"]=1
    done < <(env_paths "$env_file")

    # Cocokkan berdasarkan path script
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || "$line" == \#* || "$line" != *,* ]] && continue

        path="${line##*,}"
        path="${path//[[:space:]]/}"

        [[ -n "${existing[$path]:-}" ]] || missing+=("$line")
    done < "$ENV_EXAMPLE"

    if (( ${#missing[@]} == 0 )); then
        info "scripts.env sudah berisi semua script."
        return 0
    fi

    echo
    warn "Script baru yang belum terdaftar di scripts.env:"
    printf '     %s\n' "${missing[@]}"
    echo

    local answer="n"

    if (( ASSUME_YES )); then
        answer="y"
    elif [[ -t 0 ]]; then
        read -rp "   Tambahkan ke scripts.env? [Y/n]: " answer
        answer="${answer:-y}"
    else
        info "Non-interaktif: lewati (gunakan --yes untuk menambahkan otomatis)."
    fi

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        # Pastikan file diakhiri newline sebelum append
        [[ -s "$env_file" && -n "$(tail -c1 "$env_file")" ]] && echo >> "$env_file"
        printf '%s\n' "${missing[@]}" >> "$env_file"
        success "${#missing[@]} entry ditambahkan ke scripts.env."
    fi
}

# ============================================================
# Parse arguments
# ============================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            ASSUME_YES=1
            ;;
        --skip-checks)
            SKIP_CHECKS=1
            ;;
        --checked)
            # Internal: requirement sudah dicek sebelum re-exec sudo
            CHECKED=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ Parameter tidak dikenal: $1" >&2
            echo
            usage
            exit 1
            ;;
    esac
    shift
done

# ============================================================
# Header
# ============================================================

if (( ! CHECKED )); then
    echo
    echo "========================================"
    echo "   OpenStack Ops Toolkit Installer"
    echo "========================================"
    echo
fi

# ============================================================
# Check requirements
# (dijalankan sebelum sudo, karena PATH user—mis. venv
#  openstack client—tidak terbawa oleh sudo secure_path)
# ============================================================

if (( ! CHECKED )); then
    if (( SKIP_CHECKS )); then
        warn "Requirement check dilewati (--skip-checks)."
        echo
    else
        check_requirements
    fi
fi

# ============================================================
# Re-run installer with sudo
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    echo "🔐 Root privileges are required."
    echo "   Re-running installer with sudo..."
    echo

    args=(--checked)
    (( ASSUME_YES )) && args+=(--yes)

    exec sudo bash "$SCRIPT_DIR/install.sh" "${args[@]}"
fi

# ============================================================
# Validate source files
# ============================================================

info "Checking installation files..."

[[ -f "$MAIN_SCRIPT" ]] || \
    error "main.sh not found: $MAIN_SCRIPT"

[[ -f "$ENV_EXAMPLE" ]] || \
    error "scripts.env.example not found: $ENV_EXAMPLE"

# Semua script di scripts.env.example harus ada di source
while IFS= read -r path; do
    [[ "$path" == /* ]] && continue

    [[ -f "$SCRIPT_DIR/$path" ]] || \
        error "Script di scripts.env.example tidak ditemukan: $path"
done < <(env_paths "$ENV_EXAMPLE")

success "Installation files are valid."

# ============================================================
# Create workdir
# ============================================================

info "Creating workdir..."

mkdir -p "$INSTALL_DIR"

success "Workdir ready: $INSTALL_DIR"

# ============================================================
# Install operational scripts
# ============================================================

# Kategori = direktori top-level (non-hidden) di source,
# mis. compute/, identity/, network/, volumes/
mapfile -t CATEGORY_DIRS < <(
    find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort
)

if [[ "$(realpath "$SCRIPT_DIR")" == "$(realpath "$INSTALL_DIR")" ]]; then

    info "Source berada di workdir ($INSTALL_DIR), skip copy scripts."

else

    info "Installing operational scripts..."

    for dir in "${CATEGORY_DIRS[@]}"; do
        mkdir -p "$INSTALL_DIR/$dir"
        cp -R "$SCRIPT_DIR/$dir/." "$INSTALL_DIR/$dir/"
        echo "     → $dir/"
    done

    success "Operational scripts installed."

fi

# Make shell scripts executable
for dir in "${CATEGORY_DIRS[@]}"; do
    [[ -d "$INSTALL_DIR/$dir" ]] || continue
    find "$INSTALL_DIR/$dir" -type f -name "*.sh" -exec chmod 0755 {} \;
done

# ============================================================
# Install scripts.env
# ============================================================

if [[ -f "$INSTALL_DIR/scripts.env" ]]; then

    info "Existing scripts.env detected."
    info "Keeping existing configuration."

    sync_scripts_env "$INSTALL_DIR/scripts.env"

else

    info "Creating scripts.env from scripts.env.example..."

    cp "$ENV_EXAMPLE" "$INSTALL_DIR/scripts.env"

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
for dir in "${CATEGORY_DIRS[@]}"; do
    echo "  $INSTALL_DIR/$dir/"
done
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
echo "Non-interactive login:"
echo "  openstack-ops-toolkit --rc ~/admin-openrc.sh"
echo
