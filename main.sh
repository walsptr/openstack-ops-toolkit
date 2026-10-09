#!/bin/bash

# ============================================================
# OpenStack Ops Toolkit - TUI Script Launcher (k9s-style)
# ============================================================
#
# Launcher interaktif untuk operational scripts. Script ditemukan
# otomatis (auto-discovery) dengan memindai direktori kategori di
# workdir dan membaca metadata di header script (@name, @description,
# @mutates, @requires, @tags). scripts.env bersifat opsional sebagai
# file override lokal (rename, hide, custom script).
#
# Tampilan terinspirasi k9s: info panel & key hints di atas, tabel
# script, dan detail pane di bawah. Fitur search hanya untuk mencari
# script. Jika fzf tidak tersedia, fallback ke menu bernomor biasa.

DEFAULT_WORKDIR="/opt/openstack-ops-toolkit"
# OOT_WORKDIR diset saat TUI berjalan, agar perintah internal (fzf) memakai workdir yang sama
WORKDIR="${OOT_WORKDIR:-$DEFAULT_WORKDIR}"
RC_FILE=""
USE_FZF=1
LIST_ONLY=0

# Separator field internal (non-whitespace, agar field kosong tidak hilang saat read)
RS=$'\x1f'

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
    echo "Usage: openstack-ops-toolkit [--workdir PATH] [--rc FILE] [--no-fzf] [--list]"
    echo
    echo "Options:"
    echo "  --workdir PATH    Gunakan custom working directory"
    echo "  --rc FILE         OpenStack RC file (skip prompt)"
    echo "  --no-fzf          Menu bernomor biasa (tanpa TUI)"
    echo "  --list            Cetak daftar script sebagai tabel Markdown lalu keluar"
    echo "  -h, --help        Tampilkan help"
    echo
    echo "Default workdir:"
    echo "  $DEFAULT_WORKDIR"
    echo
    echo "Script ditemukan otomatis dari header metadata (@name) di"
    echo "direktori kategori workdir. scripts.env bersifat opsional (override)."
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

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Normalisasi path (relatif terhadap WORKDIR) tanpa resolve symlink
resolve_path() {
    local p="${1/#\~/$HOME}"
    [[ "$p" != /* ]] && p="$WORKDIR/$p"
    realpath -m -s -- "$p" 2>/dev/null || printf '%s' "$p"
}

# ============================================================
# Script discovery & metadata
# ============================================================
#
# Metadata dibaca dari blok header di awal file:
#
#   #!/bin/bash
#   # ============================================================
#   # @name:        List Orphan Ports
#   # @description: List ports that are not attached to any device
#   # @mutates:     no
#   # @requires:    admin
#   # @tags:        neutron, port, cleanup
#   # ============================================================
#
# Blok header = baris comment setelah shebang (baris kosong diabaikan),
# berhenti di baris pertama yang bukan comment.
#
# Record internal (dipisah RS):
#   path  rel  category  name  mutates  requires  tags  description  source  warn

# Parse header satu atau lebih file.
# Output per file: path RS name RS mutates RS requires RS tags RS description RS warn
parse_headers() {
    (( $# == 0 )) && return 0

    awk -v OFS="$RS" '
        function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }

        function flush(   m, w, d) {
            if (file == "") return
            m = tolower(mutates)
            w = ""
            if (m == "") {
                m = "no"
            } else if (m != "yes" && m != "no") {
                w = "@mutates tidak valid (\"" mutates "\"), dianggap yes"
                m = "yes"
            }
            d = (desc != "") ? desc : fallback
            print file, name, m, requires, tags, d, w
        }

        FNR == 1 {
            flush()
            file = FILENAME
            name = mutates = requires = tags = desc = fallback = ""
            inhdr = 1
            if ($0 ~ /^#!/) next
        }

        !inhdr { next }

        {
            line = $0
            sub(/\r$/, "", line)

            if (line ~ /^[ \t]*$/) next
            if (line !~ /^[ \t]*#/) { inhdr = 0; next }

            sub(/^[ \t]*#+[ \t]?/, "", line)
            gsub(/[\t\037]/, " ", line)

            # Separator "# ====" / "# ----"
            if (line ~ /^[ \t]*[=-]+[ \t]*$/) next

            if (match(line, /^[ \t]*@[A-Za-z_-]+[ \t]*:/)) {
                key = substr(line, RSTART, RLENGTH)
                val = trim(substr(line, RSTART + RLENGTH))
                gsub(/[ \t@:]/, "", key)
                key = tolower(key)

                if (key == "name") name = val
                else if (key == "description") desc = val
                else if (key == "mutates") mutates = val
                else if (key == "requires") requires = val
                else if (key == "tags") tags = val
                next
            }

            # Fallback deskripsi: baris comment pertama yang bukan tag
            if (fallback == "") fallback = trim(line)
        }

        END { flush() }
    ' "$@"
}

# Discovery: pindai *.sh di subdirektori ROOT (abaikan lib/ dan direktori
# tersembunyi). File tanpa @name dianggap helper dan tidak didaftarkan.
discover_records() {
    local root="$1"
    local f rel
    local -a files=()

    while IFS= read -r -d '' f; do
        rel="${f#"$root"/}"
        # File di root workdir (main.sh, install.sh) bukan operational script
        [[ "$rel" == */* ]] || continue
        [[ -r "$f" ]] || continue
        files+=("$f")
    done < <(
        find "$root" -mindepth 1 \
            \( -type d \( -name '.*' -o -name lib \) -prune \) -o \
            \( -type f -name '*.sh' ! -name '.*' -print0 \) 2>/dev/null
    )

    (( ${#files[@]} == 0 )) && return 0

    local file name m req tags desc warn
    while IFS="$RS" read -r file name m req tags desc warn; do
        [[ -z "$name" ]] && continue
        rel="${file#"$root"/}"
        printf '%s\n' "$file$RS$rel$RS${rel%%/*}$RS$name$RS$m$RS$req$RS$tags$RS$desc${RS}discovered$RS$warn"
    done < <(parse_headers "${files[@]}")
}

# Discovery + override scripts.env, diurutkan (kategori, nama, path).
#
# Semantik scripts.env (opsional):
#   Display Name,path   path sudah ditemukan  => ganti nama tampilan
#                       path tidak ditemukan  => entry baru, kategori "custom"
#   !path               sembunyikan script
#   # comment           diabaikan (juga comment di akhir baris)
script_records() {
    local env_file="$WORKDIR/scripts.env"
    local -a recs=()
    local -A idx=() hidden=()
    local rec i=0

    while IFS= read -r rec; do
        recs+=("$rec")
        idx["${rec%%"$RS"*}"]=$i
        i=$((i + 1))
    done < <(discover_records "$WORKDIR")

    if [[ -f "$env_file" ]]; then
        local line p abs oname
        local path rel cat name m req tags desc src warn

        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            # Comment di akhir baris
            line="${line%%[[:space:]]#*}"
            line="$(trim "$line")"

            [[ -z "$line" || "$line" == \#* ]] && continue

            # !path => hide
            if [[ "$line" == !* ]]; then
                p="$(trim "${line#!}")"
                [[ -n "$p" ]] && hidden["$(resolve_path "$p")"]=1
                continue
            fi

            [[ "$line" == *,* ]] || continue

            # Split di koma terakhir (nama boleh mengandung koma)
            oname="$(trim "${line%,*}")"
            p="$(trim "${line##*,}")"
            [[ -z "$oname" || -z "$p" ]] && continue

            abs="$(resolve_path "$p")"

            if [[ -n "${idx[$abs]+x}" ]]; then
                # Rename (termasuk format lama: entry identik => tidak duplikat)
                i=${idx[$abs]}
                IFS="$RS" read -r path rel cat name m req tags desc src warn <<< "${recs[$i]}"
                recs[i]="$path$RS$rel$RS$cat$RS$oname$RS$m$RS$req$RS$tags$RS$desc$RS$src$RS$warn"
            else
                # Custom script (di luar discovery)
                name="" m="" req="" tags="" desc="" warn=""
                if [[ -r "$abs" ]]; then
                    IFS="$RS" read -r _ name m req tags desc warn < <(parse_headers "$abs")
                else
                    desc="⚠️  script tidak ditemukan"
                fi
                recs+=("$abs$RS$p${RS}custom$RS$oname$RS${m:-no}$RS$req$RS$tags$RS$desc${RS}custom$RS$warn")
                idx["$abs"]=$(( ${#recs[@]} - 1 ))
            fi
        done < "$env_file"
    fi

    for rec in "${recs[@]}"; do
        [[ -n "${hidden[${rec%%"$RS"*}]+x}" ]] && continue
        printf '%s\n' "$rec"
    done | LC_ALL=C sort -f -t "$RS" -k3,3 -k4,4 -k2,2
}

# Muat hasil script_records ke array paralel S_*
load_scripts() {
    S_PATH=() S_REL=() S_CAT=() S_NAME=() S_MUT=()
    S_REQ=() S_TAGS=() S_DESC=() S_SRC=() S_WARN=()

    local path rel cat name m req tags desc src warn
    while IFS="$RS" read -r path rel cat name m req tags desc src warn; do
        S_PATH+=("$path")
        S_REL+=("$rel")
        S_CAT+=("$cat")
        S_NAME+=("$name")
        S_MUT+=("$m")
        S_REQ+=("$req")
        S_TAGS+=("$tags")
        S_DESC+=("$desc")
        S_SRC+=("$src")
        S_WARN+=("$warn")
    done < <(script_records)
}

# Index script berdasarkan path absolut
find_index() {
    local i
    for i in "${!S_PATH[@]}"; do
        if [[ "${S_PATH[$i]}" == "$1" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# ============================================================
# Internal commands (dipanggil oleh fzf / installer)
# ============================================================

# --rows : tabel script untuk fzf
# Output per baris: PATH <TAB> NAMA <TAB> tampilan
# Baris pertama adalah header tabel (fzf --header-lines=1).
# Kolom TAGS di paling kanan dan tidak dipotong agar ikut fuzzy search.
cmd_rows() {
    local i w_name=4 w_cat=8 w_desc=11 desc mut

    load_scripts

    for i in "${!S_PATH[@]}"; do
        [[ -f "${S_PATH[$i]}" ]] || S_DESC[i]="⚠️  script tidak ditemukan"

        (( ${#S_NAME[$i]} > w_name )) && w_name=${#S_NAME[$i]}
        (( ${#S_CAT[$i]} > w_cat )) && w_cat=${#S_CAT[$i]}
        (( ${#S_DESC[$i]} > w_desc )) && w_desc=${#S_DESC[$i]}
    done

    (( w_name > 40 )) && w_name=40
    (( w_cat > 14 )) && w_cat=14
    (( w_desc > 60 )) && w_desc=60

    printf 'PATH\tNAME\t%s%-*s  %-*s  %-7s  %-*s  %s%s\n' \
        "$C_BOLD$C_CYAN" "$w_name" "NAME" "$w_cat" "CATEGORY" "MUTATES" \
        "$w_desc" "DESCRIPTION" "TAGS" "$C_RESET"

    for i in "${!S_PATH[@]}"; do
        printf -v mut '%-7s' "${S_MUT[$i]}"
        if [[ "${S_MUT[$i]}" == "yes" ]]; then
            mut="$C_RED$C_BOLD$mut$C_RESET"
        else
            mut="$C_DIM$mut$C_RESET"
        fi

        printf -v desc '%-*s' "$w_desc" "$(trunc "${S_DESC[$i]}" "$w_desc")"

        printf '%s\t%s\t%-*s  %s%-*s%s  %s  %s%s%s  %s%s%s\n' \
            "${S_PATH[$i]}" "${S_NAME[$i]}" \
            "$w_name" "$(trunc "${S_NAME[$i]}" "$w_name")" \
            "$C_MAGENTA" "$w_cat" "$(trunc "${S_CAT[$i]}" "$w_cat")" "$C_RESET" \
            "$mut" \
            "$C_DIM" "$desc" "$C_RESET" \
            "$C_CYAN" "${S_TAGS[$i]}" "$C_RESET"
    done

    (( ${#S_PATH[@]} == 0 )) && printf -- '-\t-\t(tidak ada script ber-@name di %s)\n' "$WORKDIR"
    return 0
}

# --preview PATH : detail pane
cmd_preview() {
    local path="$1"
    local i

    [[ -z "$path" || "$path" == "-" ]] && return 0

    load_scripts
    if ! i="$(find_index "$path")"; then
        echo "${C_DIM}(script tidak lagi terdaftar — tekan Ctrl-R)${C_RESET}"
        return 0
    fi

    echo "${C_BOLD}${C_CYAN}${S_NAME[$i]}${C_RESET}"
    echo "${C_DIM}────────────────────────────────────────${C_RESET}"

    if [[ ! -f "$path" ]]; then
        echo "${C_RED}⚠️  Script tidak ditemukan:${C_RESET}"
        echo "   $path"
        return 0
    fi

    local origin=""
    [[ "${S_SRC[$i]}" == "custom" ]] && origin=" ${C_DIM}(custom, dari scripts.env)${C_RESET}"

    echo "${C_ORANGE}Category :${C_RESET} ${S_CAT[$i]}${origin}"
    echo "${C_ORANGE}Path     :${C_RESET} $path"
    if [[ "${S_MUT[$i]}" == "yes" ]]; then
        echo "${C_ORANGE}Mutates  :${C_RESET} ${C_RED}${C_BOLD}⚠️  yes — mengubah resource (konfirmasi sebelum dijalankan)${C_RESET}"
    else
        echo "${C_ORANGE}Mutates  :${C_RESET} ${C_GREEN}no${C_RESET} ${C_DIM}(read-only)${C_RESET}"
    fi
    echo "${C_ORANGE}Requires :${C_RESET} ${S_REQ[$i]:--}"
    echo "${C_ORANGE}Tags     :${C_RESET} ${S_TAGS[$i]:--}"
    echo "${C_ORANGE}Lines    :${C_RESET} $(wc -l < "$path")"
    [[ -n "${S_WARN[$i]}" ]] && echo "${C_YELLOW}⚠️  ${S_WARN[$i]}${C_RESET}"
    echo

    echo "${C_ORANGE}Description:${C_RESET}"
    if [[ -n "${S_DESC[$i]}" ]]; then
        echo "  ${S_DESC[$i]}"
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

# --list : tabel Markdown (untuk README & CI)
md_escape() {
    printf '%s' "${1//|/\\|}"
}

cmd_list() {
    local i

    load_scripts

    if (( ${#S_PATH[@]} == 0 )); then
        error "Tidak ada script ber-@name di $WORKDIR"
        return 1
    fi

    echo "| Name | Category | Path | Mutates | Description |"
    echo "|---|---|---|---|---|"
    for i in "${!S_PATH[@]}"; do
        printf '| %s | %s | `%s` | %s | %s |\n' \
            "$(md_escape "${S_NAME[$i]}")" \
            "$(md_escape "${S_CAT[$i]}")" \
            "$(md_escape "${S_REL[$i]}")" \
            "${S_MUT[$i]}" \
            "$(md_escape "${S_DESC[$i]}")"
    done
}

case "${1:-}" in
    --rows)
        cmd_rows
        exit 0
        ;;
    --preview)
        cmd_preview "${2:-}"
        exit 0
        ;;
    --discover)
        # Dipakai install.sh: record hasil discovery (tanpa override)
        [[ -d "${2:-}" ]] || exit 1
        discover_records "$(realpath "$2")"
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

  Ketik            Cari script (fuzzy: nama, kategori, deskripsi, tags).
                   Awali dengan ' untuk exact match
  Up/Down          Pindah baris
  Enter            Jalankan script terpilih
  Ctrl-E           Lihat source script lengkap di pager
  Ctrl-R           Discovery ulang script (dan scripts.env)
  Ctrl-O           Ganti OpenStack RC file (context)
  Alt-P            Tampilkan/sembunyikan detail pane
  Ctrl-D / Ctrl-U  Scroll detail pane
  Esc              Hapus filter pencarian
  ?                Help ini
  Ctrl-C           Keluar

Script dengan MUTATES = yes mengubah resource OpenStack dan
selalu meminta konfirmasi sebelum dijalankan.

Ctrl-C saat script berjalan hanya menghentikan script tersebut,
lalu kembali ke TUI.

(q untuk menutup)
EOF
}

# Jalankan script berdasarkan index di array S_*
run_script() {
    local i="$1"
    local name="${S_NAME[$i]}"
    local path="${S_PATH[$i]}"

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

    # Konfirmasi level launcher untuk script yang mengubah resource
    # (tambahan, bukan pengganti konfirmasi di dalam script)
    if [[ "${S_MUT[$i]}" == "yes" ]]; then
        local confirm
        echo "${C_RED}${C_BOLD}⚠️  Script ini MENGUBAH resource OpenStack.${C_RESET}"
        echo
        echo "Requires : ${S_REQ[$i]:--}"
        echo "Context  : $(basename "${RC_FILE:-?}")  /  ${OS_PROJECT_NAME:-${OS_PROJECT_ID:-?}}"
        [[ -n "${S_WARN[$i]}" ]] && echo "${C_YELLOW}⚠️  ${S_WARN[$i]}${C_RESET}"
        echo

        read -rp "Lanjutkan menjalankan script ini? [y/N]: " confirm || confirm=""
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            FLASH="${C_YELLOW}Dibatalkan: $name${C_RESET}"
            return
        fi
        echo
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

# Output: index script terpilih
menu_plain() {
    local filter="" input i shown=() haystack mark

    while true; do
        shown=()
        echo >&2
        echo "${C_BOLD}📜 Daftar script${filter:+ (filter: \"$filter\")}:${C_RESET}" >&2
        echo >&2

        for i in "${!S_PATH[@]}"; do
            haystack="${S_NAME[$i]} ${S_CAT[$i]} ${S_DESC[$i]} ${S_TAGS[$i]}"
            if [[ -z "$filter" || "${haystack,,}" == *"${filter,,}"* ]]; then
                shown+=("$i")
                mark=""
                [[ "${S_MUT[$i]}" == "yes" ]] && mark="  ${C_RED}⚠️  mutates${C_RESET}"
                printf '  %2d. %-32s %s[%s]%s%s\n' "${#shown[@]}" "${S_NAME[$i]}" \
                    "$C_MAGENTA" "${S_CAT[$i]}" "$C_RESET" "$mark" >&2
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

        if (( ${#S_PATH[@]} == 0 )); then
            error "Tidak ada script ber-@name di $WORKDIR"
            exit 1
        fi

        echo
        echo "🌐 Context: $(basename "$RC_FILE")  👤 ${OS_USERNAME:-?}  📁 ${OS_PROJECT_NAME:-?}"
        choice="$(menu_plain)" || { echo; echo "👋 Bye."; exit 0; }

        FLASH=""
        run_script "$choice"
        [[ -n "$FLASH" ]] && echo "$FLASH"

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
    local sel_path idx

    FLASH=""
    rows_cmd="bash $(printf '%q' "$SELF") --rows"
    preview="bash $(printf '%q' "$SELF") --preview {1}"

    while true; do
        load_scripts
        header="$(build_header "${#S_PATH[@]}")"
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
        sel_path=""
        if [[ -n "${lines[2]:-}" ]]; then
            sel_path="${lines[2]%%$'\t'*}"
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
                [[ -z "$sel_path" ]] && continue
                # Muat ulang: daftar bisa berubah lewat Ctrl-R di dalam fzf
                load_scripts
                if idx="$(find_index "$sel_path")"; then
                    run_script "$idx"
                else
                    FLASH="${C_YELLOW}Script tidak lagi terdaftar${C_RESET}"
                fi
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

        --list)
            LIST_ONLY=1
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

# ============================================================
# Validate workdir
# ============================================================

# Expand ~ jika digunakan
WORKDIR="${WORKDIR/#\~/$HOME}"

if [[ ! -d "$WORKDIR" ]]; then
    error "Workdir tidak ditemukan: $WORKDIR"
    exit 1
fi

# Absolute & canonical (discovery membandingkan path)
WORKDIR="$(realpath "$WORKDIR")"

# --list: cukup discovery, tanpa autentikasi / fzf
if (( LIST_ONLY )); then
    cmd_list
    exit $?
fi

load_scripts

if (( ${#S_PATH[@]} == 0 )); then
    error "Tidak ada script ber-@name di workdir: $WORKDIR"
    echo
    echo "Tambahkan header metadata ke script di direktori kategori, mis.:"
    echo "  # @name:        List Orphan Ports"
    echo "  # @description: List ports that are not attached to any device"
    echo
    echo "atau arahkan --workdir ke direktori toolkit yang benar."
    exit 1
fi

if (( USE_FZF )) && ! command -v fzf >/dev/null 2>&1; then
    echo "${C_YELLOW}⚠️  fzf tidak ditemukan, menggunakan menu biasa.${C_RESET}"
    echo "   Install fzf untuk TUI (dnf/apt install fzf)."
    echo
    USE_FZF=0
fi

echo "========================================"
echo "       OpenStack Ops Toolkit"
echo "========================================"
echo
echo "📂 Workdir  : $WORKDIR"
echo "📜 Scripts  : ${#S_PATH[@]} ditemukan"
if [[ -f "$WORKDIR/scripts.env" ]]; then
    echo "📄 Override : $WORKDIR/scripts.env"
else
    echo "📄 Override : (tidak ada scripts.env)"
fi
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

if (( USE_FZF )); then
    tui_loop
else
    plain_loop
fi
