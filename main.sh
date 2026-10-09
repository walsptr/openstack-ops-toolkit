#!/bin/bash

# ============================================================
# OpenStack Ops Toolkit - TUI Script Launcher (k9s-style)
# ============================================================
#
# Launcher interaktif untuk operational scripts yang terdaftar
# di scripts.env. Tampilan terinspirasi k9s: info panel & key
# hints di atas, tabel script, dan detail pane di bawah.
# Fitur search hanya untuk mencari script.
#
# Jika fzf tidak tersedia, fallback ke menu bernomor biasa.

DEFAULT_WORKDIR="/opt/openstack-ops-toolkit"
# OOT_WORKDIR diset saat TUI berjalan, agar perintah internal (fzf) memakai workdir yang sama
WORKDIR="${OOT_WORKDIR:-$DEFAULT_WORKDIR}"
RC_FILE=""
USE_FZF=1

SELF="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

# Warna
if [[ -t 1 || -n "${OOT_COLOR:-}" ]]; then
    C_BOLD=$'\e[1m'
    C_DIM=$'\e[2m'
    C_CYAN=$'\e[36m'
    C_BLUE=$'\e[94m'
    C_GREEN=$'\e[32m'
    C_RED=$'\e[31m'
    C_YELLOW=$'\e[33m'
    C_ORANGE=$'\e[38;5;208m'
    C_MAGENTA=$'\e[35m'
    C_RESET=$'\e[0m'
else
    C_BOLD="" C_DIM="" C_CYAN="" C_BLUE="" C_GREEN="" C_RED=""
    C_YELLOW="" C_ORANGE="" C_MAGENTA="" C_RESET=""
fi

# ============================================================
# Helpers
# ============================================================

usage() {
    echo "Usage: openstack-ops-toolkit [--workdir PATH] [--rc FILE] [--no-fzf]"
    echo
    echo "Options:"
    echo "  --workdir PATH    Gunakan custom working directory"
    echo "  --rc FILE         OpenStack RC file (skip prompt)"
    echo "  --no-fzf          Menu bernomor biasa (tanpa TUI)"
    echo "  -h, --help        Tampilkan help"
    echo
    echo "Default workdir:"
    echo "  $DEFAULT_WORKDIR"
    echo
    echo "Tekan '?' di dalam TUI untuk daftar keyboard shortcut."
}

error() {
    echo "${C_RED}❌ $1${C_RESET}" >&2
}

pause() {
    echo
    read -rp "↩️  Tekan Enter untuk kembali..." _ || true
}

pager() {
    if [[ -n "${PAGER:-}" ]]; then
        $PAGER "$@"
    else
        less -R "$@"
    fi
}

# Potong string ke panjang maksimum
trunc() {
    local s="$1"
    local w="$2"

    if (( ${#s} > w )); then
        printf '%s…' "${s:0:w-1}"
    else
        printf '%s' "$s"
    fi
}

# Ambil deskripsi dari blok komentar pertama di script
script_description() {
    awk '
        NR == 1 && /^#!/ { next }
        /^#/ {
            if ($0 ~ /^#[[:space:]]*[=-]+[[:space:]]*$/) { started = 1; next }
            line = $0
            sub(/^#[[:space:]]?/, "", line)
            if (line != "") { print line; found = 1 }
            started = 1
            next
        }
        started && found { exit }
        /^[[:space:]]*$/ { next }
        { if (found) exit }
    ' "$1" 2>/dev/null
}

# Baca scripts.env ke array names[] dan paths[]
# Format: Nama Script,relative/or/absolute/path.sh
load_scripts() {
    names=()
    paths=()

    local list_file="$WORKDIR/scripts.env"
    local line name path

    [[ -f "$list_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip baris kosong & komentar
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" != *,* ]] && continue

        # Split di koma terakhir (nama boleh mengandung koma)
        name="${line%,*}"
        path="${line##*,}"

        name="${name%"${name##*[![:space:]]}"}"
        path="${path#"${path%%[![:space:]]*}"}"

        [[ -z "$name" || -z "$path" ]] && continue

        # Path relatif di-resolve terhadap WORKDIR
        [[ "$path" != /* ]] && path="$WORKDIR/$path"

        names+=("$name")
        paths+=("$path")
    done < "$list_file"
}

# ============================================================
# Internal commands (dipanggil oleh fzf: reload / preview)
# ============================================================

# --rows : tabel script untuk fzf
# Output per baris: PATH <TAB> NAMA <TAB> tampilan
# Baris pertama adalah header tabel (fzf --header-lines=1).
cmd_rows() {
    local i w_name=4 w_cat=8 category desc
    local -a cats descs

    load_scripts

    for i in "${!names[@]}"; do
        category="$(basename "$(dirname "${paths[$i]}")")"
        desc="$(script_description "${paths[$i]}" | head -n1)"
        [[ -f "${paths[$i]}" ]] || desc="⚠️  script tidak ditemukan"

        cats+=("$category")
        descs+=("$desc")

        (( ${#names[$i]} > w_name )) && w_name=${#names[$i]}
        (( ${#category} > w_cat )) && w_cat=${#category}
    done

    (( w_name > 40 )) && w_name=40
    (( w_cat > 14 )) && w_cat=14

    printf 'PATH\tNAME\t%s%-*s  %-*s  %s%s\n' \
        "$C_BOLD$C_CYAN" "$w_name" "NAME" "$w_cat" "CATEGORY" "DESCRIPTION" "$C_RESET"

    for i in "${!names[@]}"; do
        printf '%s\t%s\t%-*s  %s%-*s%s  %s%s%s\n' \
            "${paths[$i]}" "${names[$i]}" \
            "$w_name" "$(trunc "${names[$i]}" "$w_name")" \
            "$C_MAGENTA" "$w_cat" "$(trunc "${cats[$i]}" "$w_cat")" "$C_RESET" \
            "$C_DIM" "$(trunc "${descs[$i]}" 60)" "$C_RESET"
    done

    (( ${#names[@]} == 0 )) && printf -- '-\t-\t(tidak ada script di %s)\n' "$WORKDIR/scripts.env"
    return 0
}

# --preview NAME PATH : detail pane
cmd_preview() {
    local name="$1"
    local path="$2"

    [[ -z "$path" || "$path" == "-" ]] && return 0

    echo "${C_BOLD}${C_CYAN}${name}${C_RESET}"
    echo "${C_DIM}────────────────────────────────────────${C_RESET}"

    if [[ ! -f "$path" ]]; then
        echo "${C_RED}⚠️  Script tidak ditemukan:${C_RESET}"
        echo "   $path"
        return 0
    fi

    echo "${C_ORANGE}Category :${C_RESET} $(basename "$(dirname "$path")")"
    echo "${C_ORANGE}Path     :${C_RESET} $path"
    echo "${C_ORANGE}Lines    :${C_RESET} $(wc -l < "$path")"
    echo

    local desc
    desc="$(script_description "$path")"
    echo "${C_ORANGE}Description:${C_RESET}"
    if [[ -n "$desc" ]]; then
        sed 's/^/  /' <<< "$desc"
    else
        echo "  ${C_DIM}(tidak ada deskripsi)${C_RESET}"
    fi
    echo
    echo "${C_DIM}──────────────── source ────────────────${C_RESET}"

    if command -v bat >/dev/null 2>&1; then
        bat --color=always --style=numbers --paging=never --language=bash "$path"
    elif command -v batcat >/dev/null 2>&1; then
        batcat --color=always --style=numbers --paging=never --language=bash "$path"
    else
        cat -n "$path"
    fi
}

case "${1:-}" in
    --rows)
        cmd_rows
        exit 0
        ;;
    --preview)
        cmd_preview "${2:-}" "${3:-}"
        exit 0
        ;;
esac

# ============================================================
# OpenStack context (RC file)
# ============================================================

# Pilih RC file: fzf picker (dengan kandidat otomatis) atau prompt manual
select_rc_file() {
    local candidates=()

    if (( USE_FZF )); then
        mapfile -t candidates < <(
            find "$HOME" "$WORKDIR" -maxdepth 3 -type f \
                \( -iname '*openrc*' -o -iname '*rc.sh' -o -iname '*-rc' \) \
                ! -path '*/.git/*' 2>/dev/null | sort -u
        )
    fi

    if (( USE_FZF )) && (( ${#candidates[@]} > 0 )); then
        local out rc query selected
        out="$(
            printf '%s\n' "${candidates[@]}" |
            fzf --layout=reverse --border --info=inline \
                --prompt='🔐 RC file > ' \
                --header=$'Pilih OpenStack RC file, atau ketik path lalu Enter\nEsc: batal' \
                --print-query \
                --preview='grep -E "^[[:space:]]*export[[:space:]]+OS_" {} | grep -viE "PASSWORD|SECRET|TOKEN"' \
                --preview-window='down:40%:wrap'
        )"
        rc=$?

        (( rc == 130 )) && return 1

        query="$(sed -n '1p' <<< "$out")"
        selected="$(sed -n '2p' <<< "$out")"
        RC_FILE="${selected:-$query}"
    else
        read -erp "🔐 Masukkan path OpenStack RC file: " RC_FILE || return 1
    fi

    [[ -n "$RC_FILE" ]]
}

# Load RC file & verifikasi credential.
# Variabel OS_* lama dibersihkan agar context tidak tercampur.
load_rc() {
    local file="${1/#\~/$HOME}"

    if [[ ! -f "$file" ]]; then
        error "RC file tidak ditemukan: $file"
        return 1
    fi

    local var
    for var in $(compgen -e | grep '^OS_'); do
        unset "$var"
    done

    echo "🔑 Loading OpenStack RC: $file"
    # shellcheck disable=SC1090
    source "$file"

    echo "⏳ Verifying credential..."
    if ! openstack token issue >/dev/null 2>&1; then
        error "Gagal melakukan autentikasi OpenStack."
        echo "   Periksa isi RC file atau credential OpenStack."
        return 1
    fi

    RC_FILE="$file"
    echo "${C_GREEN}✅ OpenStack authentication berhasil.${C_RESET}"
}

# Ganti RC file tanpa keluar dari TUI. Jika gagal, kembali ke RC lama.
switch_context() {
    local old_rc="$RC_FILE"

    clear
    if ! select_rc_file; then
        RC_FILE="$old_rc"
        FLASH="${C_YELLOW}Context tidak berubah${C_RESET}"
        return
    fi

    if load_rc "$RC_FILE"; then
        FLASH="${C_GREEN}Context: $(basename "$RC_FILE")${C_RESET}"
    else
        pause
        RC_FILE="$old_rc"
        load_rc "$old_rc" >/dev/null 2>&1
        FLASH="${C_RED}Gagal ganti context, tetap di $(basename "$old_rc")${C_RESET}"
    fi
}

# ============================================================
# Header (k9s-style): info panel | key hints | logo
# ============================================================

build_header() {
    local total="$1"

    local auth_host="${OS_AUTH_URL:-?}"
    auth_host="${auth_host#*://}"
    auth_host="${auth_host%%/*}"

    local -a info_k=("Context:" "Cloud:" "Region:" "User:" "Project:")
    local -a info_v=(
        "$(basename "${RC_FILE:-?}")"
        "$auth_host"
        "${OS_REGION_NAME:--}"
        "${OS_USERNAME:-?}"
        "${OS_PROJECT_NAME:-${OS_PROJECT_ID:-?}}"
    )

    local -a keys1=("<enter>" "<ctrl-e>" "<ctrl-r>" "<ctrl-o>" "<?>")
    local -a desc1=("Run" "Source" "Reload" "Context" "Help")
    local -a keys2=("<alt-p>" "<ctrl-d>" "<ctrl-u>" "<esc>" "<ctrl-c>")
    local -a desc2=("Preview" "Preview down" "Preview up" "Clear filter" "Quit")

    local -a logo=(
        '  ___   ___  _____ '
        ' / _ \ / _ \|_   _|'
        '| (_) | (_) | | |  '
        ' \___/ \___/  |_|  '
        ''
    )

    local i out=""
    for i in 0 1 2 3 4; do
        out+="$(printf '%s%-9s%s %s%-28s%s  %s%-9s%s %-8s  %s%-9s%s %-13s  %s%s%s' \
            "$C_ORANGE" "${info_k[$i]}" "$C_RESET" \
            "$C_BOLD" "$(trunc "${info_v[$i]}" 28)" "$C_RESET" \
            "$C_BLUE" "${keys1[$i]}" "$C_RESET" "${desc1[$i]}" \
            "$C_BLUE" "${keys2[$i]}" "$C_RESET" "${desc2[$i]}" \
            "$C_ORANGE" "${logo[$i]}" "$C_RESET")"
        out+=$'\n'
    done

    # Title bar: ─── Scripts(all)[N] ───  │ flash
    out+="${C_DIM}────${C_RESET} ${C_CYAN}${C_BOLD}Scripts${C_RESET}(${C_MAGENTA}all${C_RESET})[${C_BOLD}${total}${C_RESET}] ${C_DIM}────${C_RESET}"
    [[ -n "$FLASH" ]] && out+="  $FLASH"

    printf '%s' "$out"
}

# ============================================================
# Actions
# ============================================================

show_help() {
    pager <<EOF
${C_BOLD}OpenStack Ops Toolkit - Keyboard Shortcuts${C_RESET}

  Ketik            Cari script (fuzzy). Awali dengan ' untuk exact match
  Up/Down          Pindah baris
  Enter            Jalankan script terpilih
  Ctrl-E           Lihat source script lengkap di pager
  Ctrl-R           Reload daftar script dari scripts.env
  Ctrl-O           Ganti OpenStack RC file (context)
  Alt-P            Tampilkan/sembunyikan detail pane
  Ctrl-D / Ctrl-U  Scroll detail pane
  Esc              Hapus filter pencarian
  ?                Help ini
  Ctrl-C           Keluar

Ctrl-C saat script berjalan hanya menghentikan script tersebut,
lalu kembali ke TUI.

(q untuk menutup)
EOF
}

run_script() {
    local name="$1"
    local path="$2"

    clear
    echo "========================================"
    echo "🚀 $name"
    echo "📂 $path"
    echo "========================================"
    echo

    if [[ ! -f "$path" ]]; then
        error "Script tidak ditemukan: $path"
        FLASH="${C_RED}Script tidak ditemukan: $name${C_RESET}"
        pause
        return
    fi

    bash "$path"
    local rc=$?

    echo
    if (( rc == 0 )); then
        echo "${C_GREEN}✅ Selesai: $name${C_RESET}"
        FLASH="${C_GREEN}✅ $name selesai${C_RESET}"
    else
        echo "${C_YELLOW}⚠️  $name selesai dengan exit code $rc${C_RESET}"
        FLASH="${C_YELLOW}⚠️  $name exit code $rc${C_RESET}"
    fi

    pause
}

# ============================================================
# Plain menu (fallback tanpa fzf)
# ============================================================

menu_plain() {
    local filter="" input i shown=()

    while true; do
        shown=()
        echo >&2
        echo "${C_BOLD}📜 Daftar script${filter:+ (filter: \"$filter\")}:${C_RESET}" >&2
        echo >&2

        for i in "${!names[@]}"; do
            if [[ -z "$filter" || "${names[$i],,}" == *"${filter,,}"* ]]; then
                shown+=("$i")
                printf '  %2d. %s\n' "${#shown[@]}" "${names[$i]}" >&2
            fi
        done

        if (( ${#shown[@]} == 0 )); then
            echo "  ${C_DIM}(tidak ada yang cocok)${C_RESET}" >&2
        fi

        echo >&2
        # EOF (stdin ditutup) => keluar
        read -erp "➡️  Nomor / kata kunci filter / q untuk keluar: " input || return 1

        case "$input" in
            q|Q|quit|exit)
                return 1
                ;;
            "")
                filter=""
                ;;
            *[!0-9]*)
                filter="$input"
                ;;
            *)
                if (( input >= 1 && input <= ${#shown[@]} )); then
                    echo "${shown[$((input - 1))]}"
                    return 0
                fi
                echo "${C_RED}❌ Pilihan tidak valid!${C_RESET}" >&2
                ;;
        esac
    done
}

plain_loop() {
    local choice again

    while true; do
        load_scripts

        if (( ${#names[@]} == 0 )); then
            error "Tidak ada script valid di $WORKDIR/scripts.env!"
            exit 1
        fi

        echo
        echo "🌐 Context: $(basename "$RC_FILE")  👤 ${OS_USERNAME:-?}  📁 ${OS_PROJECT_NAME:-?}"
        choice="$(menu_plain)" || { echo; echo "👋 Bye."; exit 0; }

        run_script "${names[$choice]}" "${paths[$choice]}"

        # EOF (stdin ditutup) => keluar, hindari loop tanpa akhir
        read -rp "↩️  Enter untuk kembali ke menu, q untuk keluar: " again || again="q"
        [[ "$again" =~ ^[Qq]$ ]] && { echo "👋 Bye."; exit 0; }
    done
}

# ============================================================
# TUI main loop
# ============================================================

tui_loop() {
    local query="" key out rc header rows_cmd preview
    local -a lines
    local sel_path sel_name

    FLASH=""
    rows_cmd="bash $(printf '%q' "$SELF") --rows"
    preview="bash $(printf '%q' "$SELF") --preview {2} {1}"

    while true; do
        load_scripts
        header="$(build_header "${#names[@]}")"
        FLASH=""

        out="$(
            bash -c "$rows_cmd" |
            SHELL=/bin/bash fzf \
                --ansi \
                --layout=reverse --border --info=inline \
                --delimiter=$'\t' --with-nth=3 \
                --header-lines=1 \
                --header="$header" \
                --prompt='🔎 scripts> ' \
                --query="$query" \
                --print-query \
                --expect='esc,ctrl-c,ctrl-e,ctrl-o,?' \
                --preview="$preview" \
                --preview-window='down:50%:wrap' \
                --bind="ctrl-r:reload($rows_cmd)" \
                --bind='alt-p:toggle-preview' \
                --bind='ctrl-d:preview-page-down,ctrl-u:preview-page-up'
        )"
        rc=$?

        mapfile -t lines <<< "$out"
        query="${lines[0]:-}"
        key="${lines[1]:-}"
        sel_path="" sel_name=""
        if [[ -n "${lines[2]:-}" ]]; then
            IFS=$'\t' read -r sel_path sel_name _ <<< "${lines[2]}"
            [[ "$sel_path" == "-" ]] && sel_path=""
        fi

        # Esc/Ctrl-C yang tidak tertangkap --expect
        (( rc == 130 )) && [[ -z "$key" ]] && key="ctrl-c"

        case "$key" in
            ctrl-c)
                clear
                echo "👋 Bye."
                return 0
                ;;
            esc)
                query=""
                ;;
            ctrl-o)
                switch_context
                ;;
            \?)
                show_help
                ;;
            ctrl-e)
                [[ -n "$sel_path" && -f "$sel_path" ]] && pager "$sel_path"
                ;;
            "")
                [[ -n "$sel_path" ]] && run_script "$sel_name" "$sel_path"
                ;;
        esac
    done
}

# ============================================================
# Parse arguments
# ============================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workdir)
            if [[ -z "${2:-}" ]]; then
                error "--workdir membutuhkan path."
                exit 1
            fi
            WORKDIR="$2"
            shift 2
            ;;

        --rc)
            if [[ -z "${2:-}" ]]; then
                error "--rc membutuhkan path RC file."
                exit 1
            fi
            RC_FILE="$2"
            shift 2
            ;;

        --no-fzf)
            USE_FZF=0
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            error "Parameter tidak dikenal: $1"
            echo
            usage
            exit 1
            ;;
    esac
done

if (( USE_FZF )) && ! command -v fzf >/dev/null 2>&1; then
    echo "${C_YELLOW}⚠️  fzf tidak ditemukan, menggunakan menu biasa.${C_RESET}"
    echo "   Install fzf untuk TUI (dnf/apt install fzf)."
    echo
    USE_FZF=0
fi

# ============================================================
# Validate workdir & scripts.env
# ============================================================

# Expand ~ jika digunakan
WORKDIR="${WORKDIR/#\~/$HOME}"

# Convert relative path menjadi absolute path
if [[ "$WORKDIR" != /* ]]; then
    ABS_WORKDIR="$(realpath "$WORKDIR" 2>/dev/null)"

    if [[ -z "$ABS_WORKDIR" ]]; then
        error "Workdir tidak valid: $WORKDIR"
        exit 1
    fi

    WORKDIR="$ABS_WORKDIR"
fi

if [[ ! -d "$WORKDIR" ]]; then
    error "Workdir tidak ditemukan: $WORKDIR"
    exit 1
fi

# scripts.env WAJIB berada di dalam WORKDIR
if [[ ! -f "$WORKDIR/scripts.env" ]]; then
    error "File scripts.env tidak ditemukan!"
    echo
    echo "Expected:"
    echo "  $WORKDIR/scripts.env"
    exit 1
fi

echo "========================================"
echo "       OpenStack Ops Toolkit"
echo "========================================"
echo
echo "📂 Workdir : $WORKDIR"
echo "📄 Config  : $WORKDIR/scripts.env"
echo

if ! command -v openstack >/dev/null 2>&1; then
    error "openstack CLI tidak ditemukan. Install python-openstackclient."
    exit 1
fi

# ============================================================
# OpenStack authentication
# ============================================================

if [[ -z "$RC_FILE" ]]; then
    if ! select_rc_file; then
        error "RC file tidak dipilih."
        exit 1
    fi
fi

load_rc "$RC_FILE" || exit 1

# ============================================================
# Run
# ============================================================

# Dibutuhkan oleh perintah internal yang dipanggil fzf
export OOT_WORKDIR="$WORKDIR"
export OOT_COLOR=1

# Ctrl-C saat script berjalan hanya menghentikan script tersebut,
# lalu kembali ke TUI (trap tidak diwariskan sebagai "ignore").
trap ':' INT

declare -a names
declare -a paths

if (( USE_FZF )); then
    tui_loop
else
    plain_loop
fi
