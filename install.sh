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

# Versi minimum
BASH_MIN_MAJOR=4
FZF_MIN_VERSION="0.20.0"   # versi terlama yang sudah dites dengan TUI main.sh

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
    echo "Usage: install.sh [--skip-checks]"
    echo
    echo "Options:"
    echo "  --skip-checks     Lewati pengecekan requirement (tidak disarankan)"
    echo "  -y, --yes         Deprecated, tidak berpengaruh (installer tidak lagi bertanya)"
    echo "  -h, --help        Tampilkan help"
    echo
    echo "Script ditemukan otomatis dari header metadata (@name)."
    echo "scripts.env yang sudah ada tidak pernah diubah."
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

    for tool in awk sed grep find sort head wc basename dirname realpath install; do
        command -v "$tool" >/dev/null 2>&1 || missing_core+=("$tool")
    done

    if (( ${#missing_core[@]} == 0 )); then
        req_ok "core utils" "awk sed grep find sort head wc basename dirname realpath install"
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

# Laporkan entry scripts.env yang redundan: path sama dengan script hasil
# discovery dan nama sama dengan @name. File TIDAK diubah.
report_redundant_env() {
    local env_file="$1"
    local -A discovered=()
    local rec rel name line p abs
    local redundant=()

    for rec in "${DISCOVERED[@]}"; do
        IFS="$RS" read -r _ rel _ name _ <<< "$rec"
        discovered["$(realpath -m -s -- "$INSTALL_DIR/$rel")"]="$name"
    done

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line%%[[:space:]]#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "$line" || "$line" == \#* || "$line" == !* || "$line" != *,* ]] && continue

        name="${line%,*}"
        name="${name%"${name##*[![:space:]]}"}"
        p="${line##*,}"
        p="${p#"${p%%[![:space:]]*}"}"

        [[ "$p" != /* ]] && p="$INSTALL_DIR/$p"
        abs="$(realpath -m -s -- "$p")"

        if [[ -n "${discovered[$abs]+x}" && "${discovered[$abs]}" == "$name" ]]; then
            redundant+=("$line")
        fi
    done < "$env_file"

    if (( ${#redundant[@]} > 0 )); then
        echo
        warn "Entry berikut di scripts.env redundan (sudah ditemukan otomatis via @name):"
        printf '     %s\n' "${redundant[@]}"
        info "Entry tersebut bisa dihapus. File tidak diubah oleh installer."
        echo
    fi

    return 0
}

# ============================================================
# Parse arguments
# ============================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            # Deprecated: dulu untuk append entry scripts.env, kini tidak berpengaruh
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

    exec sudo bash "$SCRIPT_DIR/install.sh" --checked
fi

# ============================================================
# Validate source files
# ============================================================

info "Checking installation files..."

[[ -f "$MAIN_SCRIPT" ]] || \
    error "main.sh not found: $MAIN_SCRIPT"

# Discovery script ber-@name di source (parser yang sama dengan main.sh)
RS=$'\x1f'
mapfile -t DISCOVERED < <(bash "$MAIN_SCRIPT" --discover "$SCRIPT_DIR")

(( ${#DISCOVERED[@]} > 0 )) || \
    error "Tidak ada script ber-@name di source: $SCRIPT_DIR"

success "Installation files are valid (${#DISCOVERED[@]} script ditemukan)."

# ============================================================
# Create workdir
# ============================================================

info "Creating workdir..."

mkdir -p "$INSTALL_DIR"

success "Workdir ready: $INSTALL_DIR"

# ============================================================
# Install operational scripts
# ============================================================

# Kategori = direktori top-level yang berisi script ber-@name (dinamis).
# lib/ ikut di-copy jika ada, karena script bisa memakai helper di sana.
mapfile -t CATEGORY_DIRS < <(
    for rec in "${DISCOVERED[@]}"; do
        IFS="$RS" read -r _ rel _ <<< "$rec"
        echo "${rel%%/*}"
    done | sort -u
    [[ -d "$SCRIPT_DIR/lib" ]] && echo "lib"
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
# scripts.env (opsional, override lokal) — tidak pernah ditimpa
# ============================================================

if [[ -f "$INSTALL_DIR/scripts.env" ]]; then

    info "Existing scripts.env detected (override lokal), tidak diubah."

    report_redundant_env "$INSTALL_DIR/scripts.env"

else

    info "Tidak ada scripts.env (opsional). Lihat scripts.env.example untuk override."

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
if [[ -f "$INSTALL_DIR/scripts.env" ]]; then
    chmod 0644 "$INSTALL_DIR/scripts.env"
fi

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
echo "Override (opsional):"
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
