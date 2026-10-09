#!/bin/bash

# ============================================================
# OpenStack Ops Toolkit - TUI (k9s-style)
# ============================================================
#
# Resource browser interaktif berbasis fzf:
#   - View resource OpenStack (servers, volumes, networks, ...)
#   - Command palette ":" untuk pindah view
#   - Drill-down (Enter) & back (Esc), multi-select (Tab)
#   - Describe pane live + aksi server dengan konfirmasi
#   - View "scripts" untuk menjalankan operational scripts
#
# Jika fzf tidak tersedia, fallback ke menu script bernomor.

DEFAULT_WORKDIR="/opt/openstack-ops-toolkit"
# OOT_WORKDIR diset saat TUI berjalan, agar perintah internal (fzf) memakai workdir yang sama
WORKDIR="${OOT_WORKDIR:-$DEFAULT_WORKDIR}"
RC_FILE=""
USE_FZF=1
START_VIEW="servers"

SELF="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

# Warna
if [[ -t 1 || -n "${OOT_COLOR:-}" ]]; then
    C_BOLD=$'\e[1m'
    C_DIM=$'\e[2m'
    C_CYAN=$'\e[36m'
    C_GREEN=$'\e[32m'
    C_RED=$'\e[31m'
    C_YELLOW=$'\e[33m'
    C_MAGENTA=$'\e[35m'
    C_RESET=$'\e[0m'
else
    C_BOLD="" C_DIM="" C_CYAN="" C_GREEN="" C_RED="" C_YELLOW="" C_MAGENTA="" C_RESET=""
fi

# ============================================================
# View registry
# ============================================================
#
# Setiap view mendefinisikan:
#   V_TITLE     Judul view
#   V_ALIASES   Alias untuk command palette
#   V_LIST      Perintah list (tanpa "openstack")
#   V_COLS      Kolom yang ditampilkan; kolom pertama = ID untuk describe
#   V_SHOW      Perintah show untuk describe (kosong = tidak tersedia)
#   V_ALLPROJ   1 jika mendukung --all-projects (Ctrl-A)
#   V_KEYCOL    Kolom yang dipakai sebagai key drill-down (default ID)
#   V_DRILL     "view|flag|extra args" untuk Enter (drill-down)
#   V_ACTIONS   Jenis aksi tambahan (server)

VIEWS=(
    servers volumes floatingips networks subnets ports routers
    secgroups images flavors projects users hypervisors
    compute-services network-agents volume-services scripts
)

view_def() {
    V_TITLE="" V_ALIASES="" V_SHOW=() V_ALLPROJ=0 V_KEYCOL="ID" V_DRILL="" V_ACTIONS=""
    V_LIST=() V_COLS=()

    case "$1" in
        servers)
            V_TITLE="Servers"; V_ALIASES="server srv vm instances"
            V_LIST=(server list); V_COLS=(ID Name Status Networks Image Flavor)
            V_SHOW=(server show); V_ALLPROJ=1
            V_DRILL="ports|--server|"; V_ACTIONS="server"
            ;;
        volumes)
            V_TITLE="Volumes"; V_ALIASES="volume vol"
            V_LIST=(volume list); V_COLS=(ID Name Status Size "Attached to")
            V_SHOW=(volume show); V_ALLPROJ=1
            ;;
        floatingips)
            V_TITLE="Floating IPs"; V_ALIASES="fip floating"
            V_LIST=(floating ip list)
            V_COLS=(ID "Floating IP Address" "Fixed IP Address" Port Project)
            V_SHOW=(floating ip show)
            ;;
        networks)
            V_TITLE="Networks"; V_ALIASES="network net"
            V_LIST=(network list); V_COLS=(ID Name Subnets)
            V_SHOW=(network show); V_DRILL="ports|--network|"
            ;;
        subnets)
            V_TITLE="Subnets"; V_ALIASES="subnet"
            V_LIST=(subnet list); V_COLS=(ID Name Network Subnet)
            V_SHOW=(subnet show)
            ;;
        ports)
            V_TITLE="Ports"; V_ALIASES="port"
            V_LIST=(port list); V_COLS=(ID Name "MAC Address" "Fixed IP Addresses" Status)
            V_SHOW=(port show)
            ;;
        routers)
            V_TITLE="Routers"; V_ALIASES="router rt"
            V_LIST=(router list); V_COLS=(ID Name Status State Project)
            V_SHOW=(router show); V_DRILL="ports|--router|"
            ;;
        secgroups)
            V_TITLE="Security Groups"; V_ALIASES="sg secgroup security"
            V_LIST=(security group list); V_COLS=(ID Name Description Project)
            V_SHOW=(security group show)
            ;;
        images)
            V_TITLE="Images"; V_ALIASES="image img"
            V_LIST=(image list); V_COLS=(ID Name Status)
            V_SHOW=(image show)
            ;;
        flavors)
            V_TITLE="Flavors"; V_ALIASES="flavor fl"
            V_LIST=(flavor list --all); V_COLS=(ID Name RAM Disk VCPUs "Is Public")
            V_SHOW=(flavor show)
            ;;
        projects)
            V_TITLE="Projects"; V_ALIASES="project proj tenant"
            V_LIST=(project list); V_COLS=(ID Name)
            V_SHOW=(project show); V_DRILL="servers|--project|--all-projects"
            ;;
        users)
            V_TITLE="Users"; V_ALIASES="user usr"
            V_LIST=(user list); V_COLS=(ID Name)
            V_SHOW=(user show)
            ;;
        hypervisors)
            V_TITLE="Hypervisors"; V_ALIASES="hypervisor hv host"
            V_LIST=(hypervisor list)
            V_COLS=(ID "Hypervisor Hostname" "Hypervisor Type" "Host IP" State)
            V_SHOW=(hypervisor show); V_KEYCOL="Hypervisor Hostname"
            V_DRILL="servers|--host|--all-projects"
            ;;
        compute-services)
            V_TITLE="Compute Services"; V_ALIASES="svc nova compute"
            V_LIST=(compute service list)
            V_COLS=(ID Binary Host Zone Status State "Updated At")
            ;;
        network-agents)
            V_TITLE="Network Agents"; V_ALIASES="agents neutron"
            V_LIST=(network agent list)
            V_COLS=(ID "Agent Type" Host "Availability Zone" Alive State Binary)
            V_SHOW=(network agent show)
            ;;
        volume-services)
            V_TITLE="Volume Services"; V_ALIASES="cinder vsvc"
            V_LIST=(volume service list)
            V_COLS=(Host Binary Zone Status State "Updated At")
            ;;
        scripts)
            V_TITLE="Ops Scripts"; V_ALIASES="script run ops"
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================
# Table formatter (OpenStack JSON -> baris fzf)
# ============================================================
#
# Output per baris: ID <TAB> KEY <TAB> tampilan-rata
# Baris pertama adalah header (fzf --header-lines=1).

read -r -d '' PY_TABLE <<'PYEOF'
import json, sys

key_col = sys.argv[1]
cols = sys.argv[2:]
MAXW = 40

C = {"g": "\033[32m", "r": "\033[31m", "y": "\033[33m", "h": "\033[1;36m", "x": "\033[0m"}
GOOD = {"ACTIVE", "AVAILABLE", "IN-USE", "UP", "TRUE", "ENABLED", ":-)"}
BAD = {"ERROR", "DOWN", "FALSE", "DISABLED", "XXX", "ERROR_DELETING", "FAILED", "KILLED"}
STATUS_COLS = {"status", "state", "alive"}

def fmt(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "True" if v else "False"
    if isinstance(v, dict):
        if "ip_address" in v:
            return str(v["ip_address"])
        if "server_id" in v:
            return str(v["server_id"])
        return "; ".join("%s=%s" % (k, fmt(x)) for k, x in v.items())
    if isinstance(v, (list, tuple)):
        return ", ".join(fmt(x) for x in v)
    return str(v).replace("\t", " ").replace("\n", " ")

def cut(s, w):
    return s if len(s) <= w else s[: w - 1] + "…"

def paint(col, val, padded):
    if col.lower() not in STATUS_COLS:
        return padded
    v = val.strip().upper()
    if v in GOOD:
        return C["g"] + padded + C["x"]
    if v in BAD:
        return C["r"] + padded + C["x"]
    if v:
        return C["y"] + padded + C["x"]
    return padded

try:
    data = json.load(sys.stdin)
except Exception as e:
    print("-\t-\tERROR")
    print("-\t-\t❌ Gagal parse output: %s" % e)
    sys.exit(0)

if isinstance(data, dict):
    data = [data]

rows = [[fmt(r.get(c, "")) for c in cols] for r in data]
widths = [min(MAXW, max([len(c)] + [len(r[i]) for r in rows])) for i, c in enumerate(cols)]

def render(cells, header=False):
    out = []
    last = len(cells) - 1
    for i, (c, val) in enumerate(zip(cols, cells)):
        txt = cut(val, widths[i])
        padded = txt if i == last else txt.ljust(widths[i])
        out.append(C["h"] + padded + C["x"] if header else paint(c, txt, padded))
    return "  ".join(out)

print("ID\tKEY\t" + render([c.upper() for c in cols], header=True))
for raw, cells in zip(data, rows):
    print("%s\t%s\t%s" % (fmt(raw.get(cols[0], "")) or "-", fmt(raw.get(key_col, "")) or "-", render(cells)))

if not rows:
    print("-\t-\t(kosong)")
PYEOF

# ============================================================
# Helpers
# ============================================================

usage() {
    echo "Usage: openstack-ops-toolkit [--workdir PATH] [--rc FILE] [--view NAME] [--no-fzf]"
    echo
    echo "Options:"
    echo "  --workdir PATH    Gunakan custom working directory"
    echo "  --rc FILE         OpenStack RC file (skip prompt)"
    echo "  --view NAME       View awal (default: $START_VIEW)"
    echo "  --no-fzf          Menu script bernomor biasa (tanpa TUI)"
    echo "  -h, --help        Tampilkan help"
    echo
    echo "Views:"
    echo "  ${VIEWS[*]}"
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

# --rows VIEW ALLPROJ [extra args...]
cmd_rows() {
    local view="$1"
    local allproj="$2"
    shift 2

    if [[ "$view" == "scripts" ]]; then
        local i category
        load_scripts

        printf 'ID\tKEY\t%s%-40s  %s%s\n' "$C_BOLD$C_CYAN" "SCRIPT" "CATEGORY" "$C_RESET"
        for i in "${!names[@]}"; do
            category="$(basename "$(dirname "${paths[$i]}")")"
            printf '%s\t%s\t%-40s  %s\n' "${paths[$i]}" "${names[$i]}" "${names[$i]}" "${C_DIM}${category}${C_RESET}"
        done
        (( ${#names[@]} == 0 )) && printf -- '-\t-\t(scripts.env kosong)\n'
        return 0
    fi

    view_def "$view" || { printf 'ID\tKEY\tERROR\n-\t-\t❌ View tidak dikenal: %s\n' "$view"; return 0; }

    # Refresh = buang cache describe untuk view ini
    [[ -n "${OOT_CACHE:-}" ]] && rm -f "$OOT_CACHE/$view".* 2>/dev/null

    local cmd=(openstack "${V_LIST[@]}" -f json)
    local c
    for c in "${V_COLS[@]}"; do
        cmd+=(-c "$c")
    done
    # Drill-down bisa sudah membawa --all-projects
    if (( allproj && V_ALLPROJ )) && [[ " $* " != *" --all-projects "* ]]; then
        cmd+=(--all-projects)
    fi
    cmd+=("$@")

    local out
    if ! out="$("${cmd[@]}" 2>&1)"; then
        printf 'ID\tKEY\tERROR\n'
        printf -- '-\t-\t❌ %s\n' "openstack ${V_LIST[*]} $* gagal:"
        head -n 5 <<< "$out" | sed 's/^/-\t-\t   /'
        return 0
    fi

    python3 -c "$PY_TABLE" "$V_KEYCOL" "${V_COLS[@]}" <<< "$out"
}

# --describe VIEW ID  (hasil di-cache per sesi)
cmd_describe() {
    local view="$1"
    local id="$2"

    [[ -z "$id" || "$id" == "-" || "$id" == "ID" ]] && return 0
    view_def "$view" || return 0

    if (( ${#V_SHOW[@]} == 0 )); then
        echo "${C_DIM}(describe tidak tersedia untuk view ini)${C_RESET}"
        return 0
    fi

    local cache=""
    if [[ -n "${OOT_CACHE:-}" && -d "$OOT_CACHE" ]]; then
        cache="$OOT_CACHE/$view.${id//[^A-Za-z0-9._-]/_}"
        if [[ -s "$cache" ]]; then
            cat "$cache"
            return 0
        fi
    fi

    local out
    if out="$(openstack "${V_SHOW[@]}" "$id" -f yaml 2>/dev/null)"; then
        if command -v bat >/dev/null 2>&1; then
            out="$(bat --color=always --style=plain --paging=never --language=yaml <<< "$out")"
        elif command -v batcat >/dev/null 2>&1; then
            out="$(batcat --color=always --style=plain --paging=never --language=yaml <<< "$out")"
        fi
    elif ! out="$(openstack "${V_SHOW[@]}" "$id" 2>&1)"; then
        echo "${C_RED}❌ Gagal describe $id${C_RESET}"
        echo "$out"
        return 0
    fi

    [[ -n "$cache" ]] && printf '%s\n' "$out" > "$cache"
    printf '%s\n' "$out"
}

# --preview NAME PATH  (preview untuk view scripts)
cmd_preview_script() {
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

    echo "${C_BOLD}Category :${C_RESET} $(basename "$(dirname "$path")")"
    echo "${C_BOLD}Path     :${C_RESET} $path"
    echo "${C_BOLD}Lines    :${C_RESET} $(wc -l < "$path")"
    echo

    local desc
    desc="$(script_description "$path")"
    echo "${C_BOLD}Description:${C_RESET}"
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
        shift
        cmd_rows "$@"
        exit 0
        ;;
    --describe)
        cmd_describe "${2:-}" "${3:-}"
        exit 0
        ;;
    --preview)
        cmd_preview_script "${2:-}" "${3:-}"
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

# Ganti context (seperti :ctx di k9s). Jika gagal, kembali ke RC lama.
switch_context() {
    local old_rc="$RC_FILE"

    clear
    if ! select_rc_file; then
        RC_FILE="$old_rc"
        FLASH="${C_YELLOW}Context tidak berubah${C_RESET}"
        return
    fi

    if load_rc "$RC_FILE"; then
        rm -f "$OOT_CACHE"/* 2>/dev/null
        FLASH="${C_GREEN}Context: $(basename "$RC_FILE")${C_RESET}"
    else
        pause
        RC_FILE="$old_rc"
        load_rc "$old_rc" >/dev/null 2>&1
        FLASH="${C_RED}Gagal ganti context, tetap di $(basename "$old_rc")${C_RESET}"
    fi
}

context_line() {
    printf '%s' "${C_MAGENTA}⎈ $(basename "${RC_FILE:-?}")${C_RESET}"
    printf '  👤 %s  📁 %s  🌍 %s  %s' \
        "${OS_USERNAME:-?}" \
        "${OS_PROJECT_NAME:-${OS_PROJECT_ID:-?}}" \
        "${OS_REGION_NAME:--}" \
        "${C_DIM}${OS_AUTH_URL:-?}${C_RESET}"
}

# ============================================================
# Actions
# ============================================================

show_help() {
    pager <<EOF
${C_BOLD}OpenStack Ops Toolkit - Keyboard Shortcuts${C_RESET}

${C_BOLD}Navigasi${C_RESET}
  Ketik            Filter (fuzzy). Awali dengan ' untuk exact match
  Up/Down          Pindah baris
  Tab / Shift-Tab  Tandai baris (multi-select untuk aksi massal)
  Enter            Drill-down (lihat di bawah) / describe / run script
  Esc              Kembali ke view sebelumnya
  :                Command palette (pindah view, ganti context, quit)
  ?                Help ini
  Ctrl-C           Keluar

${C_BOLD}Umum${C_RESET}
  Ctrl-R           Refresh (reload dari API)
  Ctrl-A           Toggle --all-projects (servers, volumes)
  Ctrl-E           Describe lengkap di pager
  Alt-P            Tampilkan/sembunyikan describe pane
  Ctrl-D / Ctrl-U  Scroll describe pane

${C_BOLD}Servers${C_RESET}
  Alt-S            Start server terpilih     (konfirmasi)
  Alt-X            Stop server terpilih      (konfirmasi)
  Alt-B            Reboot (soft) terpilih    (konfirmasi)
  Alt-L            Console log
  Alt-U            Console URL

${C_BOLD}Drill-down (Enter)${C_RESET}
  projects    -> servers milik project
  hypervisors -> servers di host tersebut
  servers     -> ports milik server
  networks    -> ports di network
  routers     -> ports router

${C_BOLD}Command palette${C_RESET}
  :servers :volumes :fip :net :subnets :ports :routers :sg :images
  :flavors :projects :users :hv :svc :agents :cinder :scripts
  :ctx (ganti RC/context)  :help  :quit

(q untuk menutup)
EOF
}

# Command palette. Output: nama view / ctx / help / quit
palette() {
    local v rows=()

    for v in "${VIEWS[@]}"; do
        view_def "$v"
        rows+=("$(printf '%s\t%-18s %-30s %s' "$v" "$v" "${C_DIM}${V_ALIASES}${C_RESET}" "$V_TITLE")")
    done
    rows+=("$(printf 'ctx\t%-18s %-30s %s' "ctx" "${C_DIM}context rc${C_RESET}" "Ganti OpenStack RC / context")")
    rows+=("$(printf 'help\t%-18s %-30s %s' "help" "${C_DIM}?${C_RESET}" "Keyboard shortcuts")")
    rows+=("$(printf 'quit\t%-18s %-30s %s' "quit" "${C_DIM}q exit${C_RESET}" "Keluar")")

    printf '%s\n' "${rows[@]}" |
    fzf --ansi --layout=reverse --border --info=inline \
        --delimiter=$'\t' --with-nth=2 \
        --prompt=': ' \
        --header="$(context_line)" \
        --tiebreak=begin,index |
    cut -f1
}

# Aksi pada server terpilih: start / stop / reboot
server_action() {
    local action="$1"
    shift
    local ids=("$@")

    clear
    echo "========================================"
    echo "  ⚠️  server $action — ${#ids[@]} server"
    echo "========================================"
    echo
    printf '  %s\n' "${SELECTED_DISPLAY[@]}"
    echo
    echo "Context: $(basename "$RC_FILE")  /  ${OS_PROJECT_NAME:-?}"
    echo

    local confirm
    read -rp "Lanjutkan server $action? [y/N]: " confirm || confirm=""
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        FLASH="${C_YELLOW}server $action dibatalkan${C_RESET}"
        return
    fi

    local id ok=0 fail=0
    for id in "${ids[@]}"; do
        echo -n "🚀 server $action $id ... "
        if openstack server "$action" "$id"; then
            echo "${C_GREEN}OK${C_RESET}"
            ok=$((ok + 1))
        else
            echo "${C_RED}FAILED${C_RESET}"
            fail=$((fail + 1))
        fi
    done

    if (( fail > 0 )); then
        FLASH="${C_RED}server $action: $ok OK, $fail gagal${C_RESET}"
        pause
    else
        FLASH="${C_GREEN}server $action: $ok OK${C_RESET}"
    fi
}

console_log() {
    clear
    echo "⏳ Mengambil console log $1 ..."
    openstack console log show --lines 1000 "$1" 2>&1 | pager +G
}

console_url() {
    clear
    echo "🖥️  Console URL untuk $1"
    echo
    openstack console url show "$1" -f value -c url 2>&1
    pause
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
# Plain menu (fallback tanpa fzf): hanya scripts
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
        echo "🌐 $(context_line)"
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

# View stack (untuk drill-down / back)
S_VIEW=()
S_ARGS=()
S_TITLE=()
S_QUERY=()

push_view() {
    S_VIEW+=("$1")
    S_ARGS+=("$2")
    S_TITLE+=("$3")
    S_QUERY+=("")
}

pop_view() {
    local n=${#S_VIEW[@]}
    (( n <= 1 )) && return 1
    unset 'S_VIEW[n-1]' 'S_ARGS[n-1]' 'S_TITLE[n-1]' 'S_QUERY[n-1]'
    S_VIEW=("${S_VIEW[@]}")
    S_ARGS=("${S_ARGS[@]}")
    S_TITLE=("${S_TITLE[@]}")
    S_QUERY=("${S_QUERY[@]}")
}

reset_view() {
    S_VIEW=() S_ARGS=() S_TITLE=() S_QUERY=()
    view_def "$1"
    push_view "$1" "" "$V_TITLE"
}

breadcrumb() {
    local i out=""
    for i in "${!S_TITLE[@]}"; do
        if (( i == ${#S_TITLE[@]} - 1 )); then
            out+="${C_BOLD}${C_CYAN}${S_TITLE[$i]}${C_RESET}"
        else
            out+="${C_DIM}${S_TITLE[$i]} ›${C_RESET} "
        fi
    done
    printf '%s' "$out"
}

tui_loop() {
    local ALL_PROJECTS=0
    FLASH=""

    reset_view "$START_VIEW"

    local top view args rows_cmd header hints out rc query key
    local preview expect_keys target line id k disp
    local d_view d_flag d_extra d_key d_args
    local -a lines

    while true; do
        top=$(( ${#S_VIEW[@]} - 1 ))
        view="${S_VIEW[$top]}"
        args="${S_ARGS[$top]}"
        view_def "$view"

        rows_cmd="bash $(printf '%q' "$SELF") --rows $(printf '%q' "$view") $ALL_PROJECTS $args"

        # Header (k9s-style): context, breadcrumb + flash, key hints
        header="$(context_line)"$'\n'
        header+="📋 $(breadcrumb)"
        if (( V_ALLPROJ )); then
            header+="  ${C_DIM}all-projects:${C_RESET} "
            (( ALL_PROJECTS )) && header+="${C_GREEN}on${C_RESET}" || header+="off"
        fi
        [[ -n "$FLASH" ]] && header+="  │ $FLASH"
        header+=$'\n'

        if [[ "$view" == "scripts" ]]; then
            hints="<enter> run  <ctrl-e> source  <:> views  <?> help  <esc> back"
            preview="bash $(printf '%q' "$SELF") --preview {2} {1}"
        else
            if [[ -n "$V_DRILL" ]]; then
                hints="<enter> ${V_DRILL%%|*}  "
            else
                hints="<enter> describe  "
            fi
            hints+="<ctrl-e> describe  <ctrl-r> refresh  "
            (( V_ALLPROJ )) && hints+="<ctrl-a> all-proj  "
            hints+="<:> views  <?> help  <esc> back"
            if [[ "$V_ACTIONS" == "server" ]]; then
                hints+=$'\n'"<alt-s> start  <alt-x> stop  <alt-b> reboot  <alt-l> console-log  <alt-u> console-url  <tab> mark"
            fi
            preview="bash $(printf '%q' "$SELF") --describe $(printf '%q' "$view") {1}"
        fi
        header+="${C_DIM}${hints}${C_RESET}"

        FLASH=""
        expect_keys="esc,ctrl-c,:,?,ctrl-a,ctrl-e,alt-s,alt-x,alt-b,alt-l,alt-u"

        out="$(
            bash -c "$rows_cmd" |
            SHELL=/bin/bash fzf \
                --ansi --multi \
                --layout=reverse --border --info=inline \
                --delimiter=$'\t' --with-nth=3 \
                --header-lines=1 \
                --header="$header" \
                --prompt="$view> " \
                --query="${S_QUERY[$top]}" \
                --print-query \
                --tiebreak=index \
                --expect="$expect_keys" \
                --preview="$preview" \
                --preview-window='down:45%:wrap' \
                --bind="ctrl-r:reload($rows_cmd)" \
                --bind='alt-p:toggle-preview' \
                --bind='ctrl-d:preview-page-down,ctrl-u:preview-page-up'
        )"
        rc=$?

        mapfile -t lines <<< "$out"
        query="${lines[0]:-}"
        key="${lines[1]:-}"
        S_QUERY[$top]="$query"

        # Esc/Ctrl-C yang tidak tertangkap --expect
        if (( rc == 130 )) && [[ -z "$key" ]]; then
            key="ctrl-c"
        fi

        # Baris terpilih -> ID, KEY, tampilan
        SELECTED_ID=() SELECTED_KEY=() SELECTED_DISPLAY=()
        for line in "${lines[@]:2}"; do
            [[ -z "$line" ]] && continue
            IFS=$'\t' read -r id k disp <<< "$line"
            [[ "$id" == "-" ]] && continue
            SELECTED_ID+=("$id")
            SELECTED_KEY+=("$k")
            SELECTED_DISPLAY+=("$(sed 's/\x1b\[[0-9;]*m//g' <<< "$disp")")
        done

        case "$key" in
            ctrl-c)
                clear
                echo "👋 Bye."
                return 0
                ;;

            esc)
                pop_view || true
                ;;

            :)
                target="$(palette)"
                case "$target" in
                    "")    ;;
                    quit)  clear; echo "👋 Bye."; return 0 ;;
                    help)  show_help ;;
                    ctx)   switch_context ;;
                    *)     reset_view "$target" ;;
                esac
                ;;

            \?)
                show_help
                ;;

            ctrl-a)
                if (( V_ALLPROJ )); then
                    ALL_PROJECTS=$(( 1 - ALL_PROJECTS ))
                else
                    FLASH="${C_YELLOW}--all-projects tidak tersedia di view ini${C_RESET}"
                fi
                ;;

            ctrl-e)
                (( ${#SELECTED_ID[@]} == 0 )) && continue
                if [[ "$view" == "scripts" ]]; then
                    pager "${SELECTED_ID[0]}"
                else
                    cmd_describe "$view" "${SELECTED_ID[0]}" | pager
                fi
                ;;

            alt-s|alt-x|alt-b|alt-l|alt-u)
                if [[ "$V_ACTIONS" != "server" ]]; then
                    FLASH="${C_YELLOW}Aksi hanya tersedia di view servers${C_RESET}"
                    continue
                fi
                (( ${#SELECTED_ID[@]} == 0 )) && continue

                case "$key" in
                    alt-s) server_action start "${SELECTED_ID[@]}" ;;
                    alt-x) server_action stop "${SELECTED_ID[@]}" ;;
                    alt-b) server_action reboot "${SELECTED_ID[@]}" ;;
                    alt-l) console_log "${SELECTED_ID[0]}" ;;
                    alt-u) console_url "${SELECTED_ID[0]}" ;;
                esac
                ;;

            "")
                # Enter
                (( ${#SELECTED_ID[@]} == 0 )) && continue

                if [[ "$view" == "scripts" ]]; then
                    run_script "${SELECTED_KEY[0]}" "${SELECTED_ID[0]}"
                elif [[ -n "$V_DRILL" ]]; then
                    IFS='|' read -r d_view d_flag d_extra <<< "$V_DRILL"
                    d_key="${SELECTED_KEY[0]}"
                    d_args="$d_extra $(printf '%q' "$d_flag") $(printf '%q' "$d_key")"
                    view_def "$d_view"
                    push_view "$d_view" "$d_args" "$V_TITLE(${view%s}=${d_key})"
                else
                    cmd_describe "$view" "${SELECTED_ID[0]}" | pager
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

        --view)
            if ! view_def "${2:-}"; then
                error "View tidak dikenal: ${2:-}"
                echo "   Views: ${VIEWS[*]}"
                exit 1
            fi
            START_VIEW="$2"
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
    echo "${C_YELLOW}⚠️  fzf tidak ditemukan, menggunakan menu script biasa.${C_RESET}"
    echo "   Install fzf untuk TUI (dnf/apt install fzf)."
    echo
    USE_FZF=0
fi

if (( USE_FZF )) && ! command -v python3 >/dev/null 2>&1; then
    echo "${C_YELLOW}⚠️  python3 tidak ditemukan, TUI resource view tidak bisa digunakan.${C_RESET}"
    echo "   Menggunakan menu script biasa."
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
OOT_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/oot-cache.XXXXXX")"
export OOT_CACHE
trap 'rm -rf "$OOT_CACHE"' EXIT

# Ctrl-C saat script/aksi berjalan hanya menghentikan proses tersebut,
# lalu kembali ke TUI (trap tidak diwariskan sebagai "ignore").
trap ':' INT

declare -a names
declare -a paths

if (( USE_FZF )); then
    tui_loop
else
    plain_loop
fi
