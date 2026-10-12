#!/bin/bash
# ============================================================
# @name:        Collect Public Floating IPs
# @description: Export floating IPs allocated from public networks to a CSV file
# @mutates:     no
# @requires:    admin, jq
# @tags:        neutron, floating-ip, public, report, csv, audit
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: collect-public-fip.sh [--network NAMA|ID]... [--pattern TEKS] [--output-dir PATH]
                             [--method auto|api|cli] [--parallel N]

Kumpulkan SEMUA floating IP yang dialokasikan dari network publik (external)
pilihan, dari semua subnet di network tersebut, lalu tulis ke CSV (satu file
per network). Read-only: tidak ada resource yang diubah.

Opsi:
  --network N        Network publik (nama atau ID; bisa diulang). Melewati
                     picker dan pola, tetapi network harus external.
  --pattern TEKS     Pola nama network (regex jq, case-insensitive; default "pub")
  --output-dir PATH  Direktori output (default /tmp; harus sudah ada)
  --method M         auto (default) | api | cli
                       auto: "floating ip list" jika sudah memuat semua field,
                             jika tidak api, jika api gagal cli
                       api : request langsung ke Neutron API dengan curl
                       cli : "floating ip show" per floating IP, paralel
  --parallel N       Jumlah proses paralel untuk metode cli (default 8, 1-64)
  -h, --help         Tampilkan help

Tanpa --network, network dipilih interaktif (fzf multi-select, fallback menu
bernomor). Tanpa terminal (mis. cron), --network wajib.

File: <output-dir>/fip-<nama-network>-<YYYYmmdd-HHMMSS>.csv (permission 600)
Kolom: Floating ID,Floating IP Address,Project Name,Status,Instance ID,
       Instance Name,Created At,Updated At

Environment:
  OSOPS_OS_CMD                Perintah OpenStack CLI (default: openstack)
  OSOPS_CURL                  Perintah curl (default: curl; opsional, metode api)
  OSOPS_FZF                   Perintah fzf (default: fzf; tidak ada = menu bernomor)
  OSOPS_COMPUTE_API_VERSION   Compute microversion (default 2.1)
  OSOPS_FIP_PAGE_LIMIT        Ukuran halaman Neutron API (default kosong = tanpa limit)
EOF
}

for _arg in "$@"; do
    if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

# Logging terpusat (lib/logging.sh)
# shellcheck source=../lib/logging.sh
if ! source "${OSOPS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/logging.sh" 2>/dev/null; then
    echo "❌ lib/logging.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi
log_init

# Akses API langsung (token lewat stdin curl, endpoint dari catalog)
# shellcheck source=../lib/api.sh
if ! source "$OSOPS_HOME/lib/api.sh" 2>/dev/null; then
    echo "❌ lib/api.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi

# ============================================================
# Konfigurasi
# ============================================================

NET_ARGS=()
PATTERN="pub"
OUTPUT_DIR="/tmp"
METHOD="auto"
PARALLEL=8

# Jumlah device_id unik maksimum yang di-resolve dengan "server show" per ID;
# di atas ini satu "server list --all-projects"
SERVER_SHOW_MAX=20
# Jumlah port ID per request API (fallback tanpa extension fip-port-details)
PORT_BATCH=50

# Wrapper OpenStack CLI. Array tidak bisa di-export, jadi override
# lewat string, mis. RHOSO: OSOPS_OS_CMD="oc exec -n openstack openstackclient -- openstack"
if [[ -n "${OSOPS_OS_CMD:-}" ]]; then
    read -ra OS_CMD <<< "$OSOPS_OS_CMD"
else
    OS_CMD=(openstack)
fi

FZF="${OSOPS_FZF:-fzf}"
COMPUTE_API_VERSION="${OSOPS_COMPUTE_API_VERSION:-2.1}"
PAGE_LIMIT="${OSOPS_FIP_PAGE_LIMIT:-}"

REGION="-"
AUTH_HOST="-"
WORK_DIR=""
XARGS_PID=""

# Network external (dimuat sekali): array JSON {id, name, shared, subnets}
EXT_JSON="[]"
SEL_IDS=()
SEL_NAMES=()

# Lookup project/instance (dimuat sekali per run, dipakai semua network)
PROJECTS_STATE=""    # "" | ok | fail
SERVER_LIST_STATE="" # "" | ok | fail

# Hasil per network (diisi process_network)
NET_METHOD=""
NET_NOTES=()
NET_FAILED=0
NET_FAIL_MSG=""

ALL_RESULTS=()
ANY_FAILED=0

if [[ -t 1 ]]; then
    C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m' C_RESET=$'\e[0m'
else
    C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_RESET=""
fi

# ============================================================
# Helpers
# ============================================================

die() {
    echo "${C_RED}❌ $1${C_RESET}"
    log_error -q "$1"
    exit "${2:-1}"
}

warn() {
    echo "${C_YELLOW}⚠️  $1${C_RESET}"
    log_warn -q "$1"
}

note() {
    echo "ℹ️  $1"
}

has_tty() {
    ( : < /dev/tty ) 2>/dev/null
}

# ask VAR PROMPT — semua prompt membaca dari /dev/tty
# (nama lokal unik: printf -v harus mengisi variabel milik pemanggil)
ask() {
    local __ask_reply=""
    has_tty || die "Butuh terminal interaktif (/dev/tty) untuk input: $2"
    printf '%s' "$2" > /dev/tty
    IFS= read -r __ask_reply < /dev/tty || __ask_reply=""
    printf -v "$1" '%s' "$__ask_reply"
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

last_error_line() {
    grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | cut -c1-300
}

is_uuidish() {
    [[ "$1" =~ ^[0-9A-Za-z-]+$ ]]
}

# Pesan "tidak ditemukan" dari OSC/API (bukan error lain seperti 5xx/auth)
is_not_found() {
    grep -qiE 'no .* (found|exists)|could not be found|not found|\(HTTP 404\)' "$1" 2>/dev/null
}

# Nama network aman sebagai nama file
safe_name() {
    local s="$1"
    s="${s//[^A-Za-z0-9._-]/_}"
    s="${s#.}"
    printf '%s' "${s:-network}"
}

# ============================================================
# OpenStack CLI wrapper (read-only: tidak ada os_run)
# ============================================================

os_cli() {
    "${OS_CMD[@]}" "$@"
}

# Seperti os_cli dengan compute microversion yang di-pin
os_compute() {
    "${OS_CMD[@]}" --os-compute-api-version "$COMPUTE_API_VERSION" "$@"
}

# ============================================================
# Setup: argumen, dependency, region
# ============================================================

need_value() {
    [[ -n "${2:-}" ]] || die "$1 membutuhkan nilai."
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --network)    need_value "$1" "${2:-}"; NET_ARGS+=("$2"); shift 2 ;;
            --pattern)    need_value "$1" "${2:-}"; PATTERN="$2"; shift 2 ;;
            --output-dir) need_value "$1" "${2:-}"; OUTPUT_DIR="$2"; shift 2 ;;
            --method)     need_value "$1" "${2:-}"; METHOD="${2,,}"; shift 2 ;;
            --parallel)   need_value "$1" "${2:-}"; PARALLEL="$2"; shift 2 ;;
            *)            die "Opsi tidak dikenal: $1 (lihat --help)" ;;
        esac
    done

    case "$METHOD" in
        auto|api|cli) ;;
        *) die "--method harus auto, api, atau cli (dapat: $METHOD)." ;;
    esac
    if [[ ! "$PARALLEL" =~ ^[0-9]+$ ]] || (( PARALLEL < 1 || PARALLEL > 64 )); then
        die "--parallel harus angka 1-64 (dapat: $PARALLEL)."
    fi
    [[ -z "$PAGE_LIMIT" || "$PAGE_LIMIT" =~ ^[1-9][0-9]*$ ]] || \
        die "OSOPS_FIP_PAGE_LIMIT harus angka > 0 (dapat: $PAGE_LIMIT)."
    jq -n --arg p "$PATTERN" '"x" | test($p; "i")' >/dev/null 2>&1 || \
        die "--pattern bukan regex yang valid: $PATTERN"

    [[ -d "$OUTPUT_DIR" ]] || die "Direktori output tidak ada: $OUTPUT_DIR"
    [[ -w "$OUTPUT_DIR" ]] || die "Direktori output tidak bisa ditulis: $OUTPUT_DIR"
    OUTPUT_DIR="${OUTPUT_DIR%/}"
    [[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="/"
    return 0
}

require_deps() {
    command -v jq >/dev/null 2>&1 || \
        die "jq tidak ditemukan. Install jq terlebih dahulu (dnf/apt install jq)."
    command -v "${OS_CMD[0]}" >/dev/null 2>&1 || \
        die "OpenStack CLI tidak ditemukan: ${OS_CMD[0]}"
    command -v xargs >/dev/null 2>&1 || die "xargs tidak ditemukan (findutils)."
    if [[ "$METHOD" == "api" ]] && ! api_curl_available; then
        die "curl tidak ditemukan ($API_CURL); dibutuhkan untuk --method api."
    fi
    return 0
}

detect_region() {
    local host
    REGION="${OS_REGION_NAME:--}"
    host="${OS_AUTH_URL:--}"
    host="${host#*://}"
    host="${host%%/*}"
    AUTH_HOST="${host:--}"
    echo "🌐 Region  : $REGION (auth: $AUTH_HOST)"
    log_event CONTEXT "region=$REGION" "auth_host=$AUTH_HOST"
}

make_work_dir() {
    WORK_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/collect-public-fip.XXXXXX")" || \
        die "Gagal membuat direktori sementara di ${TMPDIR:-/tmp}."
    API_WORK_DIR="$WORK_DIR"
}

# Dipanggil lib/logging.sh saat script keluar (normal, error, sinyal)
on_exit() {
    if [[ -n "$XARGS_PID" ]]; then
        kill "$XARGS_PID" 2>/dev/null || true
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
    api_cleanup
    return 0
}

# ============================================================
# 1. Network publik
# ============================================================

# Semua external network: EXT_JSON = [{id, name, shared, subnets}]
find_networks() {
    local json errf
    errf="$WORK_DIR/net.err"
    json="$(os_cli network list --external --long -f json 2>"$errf")" || \
        die "Gagal mengambil daftar external network: $(last_error_line "$errf")"
    EXT_JSON="$(jq -c '[ .[] | { id: (.ID // .id),
                                  name: (.Name // .name // ""),
                                  shared: (.Shared // .shared // false),
                                  subnets: ((.Subnets // .subnets // []) | if type == "array" then length
                                            elif type == "string" then (split(",") | map(select(length > 0)) | length)
                                            else 0 end) } ]
                          | sort_by(.name | ascii_downcase)' <<< "$json" 2>/dev/null)" || \
        die "Output network list tidak bisa diparse."
    return 0
}

print_networks() {
    jq -r '.[] | "  \(.name)  \(.id)  shared=\(.shared)  subnets=\(.subnets)"' <<< "$1"
}

# --network: nama atau ID, harus external; nama ganda = error
resolve_network_args() {
    local arg m n
    local -A seen=()

    for arg in "${NET_ARGS[@]}"; do
        m="$(jq -c --arg a "$arg" '[ .[] | select(.id == $a) ] as $byid
                                   | if ($byid | length) > 0 then $byid else [ .[] | select(.name == $a) ] end' <<< "$EXT_JSON")"
        n="$(jq 'length' <<< "$m")"
        if (( n == 0 )); then
            echo "External network yang tersedia:"
            print_networks "$EXT_JSON"
            die "Network '$arg' tidak ditemukan atau bukan external network."
        fi
        if (( n > 1 )); then
            echo "Network bernama '$arg':"
            print_networks "$m"
            die "Nama network '$arg' ambigu ($n network); gunakan ID."
        fi
        local id name
        id="$(jq -r '.[0].id' <<< "$m")"
        name="$(jq -r '.[0].name' <<< "$m")"
        [[ -n "${seen[$id]+x}" ]] && continue
        seen[$id]=1
        SEL_IDS+=("$id")
        SEL_NAMES+=("$name")
    done
    return 0
}

# Picker multi-select: fzf jika ada, fallback menu bernomor. Hasil di SEL_IDS/SEL_NAMES.
select_networks() {
    local matched="$1" n i answer tries=0
    local -a ids=() names=() labels=() picked=()

    mapfile -t ids < <(jq -r '.[].id' <<< "$matched")
    mapfile -t names < <(jq -r '.[].name' <<< "$matched")
    mapfile -t labels < <(jq -r '.[] | [.name, .id, (if .shared then "yes" else "no" end), (.subnets | tostring)]
                                     | "\(.[0] | .[0:32] | . + " " * (32 - length))  \(.[1])  shared=\(.[2] + " " * (3 - (.[2] | length)))  subnets=\(.[3])"' <<< "$matched")
    n=${#ids[@]}

    if command -v "$FZF" >/dev/null 2>&1; then
        local out
        out="$(for i in "${!ids[@]}"; do printf '%s\t%s\n' "$i" "${labels[$i]}"; done |
            "$FZF" --multi --layout=reverse --border --info=inline --height=40% \
                --delimiter=$'\t' --with-nth=2.. --prompt='🌐 network > ' \
                --header='TAB = pilih/lepas, Enter = konfirmasi, Esc = batal')" || out=""
        while IFS=$'\t' read -r i _; do
            [[ "$i" =~ ^[0-9]+$ ]] && picked+=("$i")
        done <<< "$out"
    else
        echo
        echo "${C_BOLD}External network yang cocok dengan pola '$PATTERN':${C_RESET}"
        printf '      %-32s  %-36s  %-10s  %s\n' "NAMA" "ID" "SHARED" "SUBNET"
        for i in "${!labels[@]}"; do
            printf '  %2d. %s\n' $(( i + 1 )) "${labels[$i]}"
        done
        while true; do
            tries=$(( tries + 1 ))
            (( tries <= 5 )) || die "Network wajib dipilih."
            ask answer "Pilih network [nomor dipisah koma, mis. 1,3, atau 'all'; kosong = batal]: "
            answer="$(trim "$answer")"
            picked=()
            [[ -z "$answer" ]] && break
            if [[ "${answer,,}" == "all" ]]; then
                picked=("${!ids[@]}")
                break
            fi
            local ok=1 tok
            local -a toks=()
            IFS=',' read -ra toks <<< "$answer"
            for tok in "${toks[@]}"; do
                tok="$(trim "$tok")"
                if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= n )); then
                    picked+=($(( tok - 1 )))
                else
                    ok=0
                fi
            done
            (( ok && ${#picked[@]} > 0 )) && break
            echo "${C_YELLOW}⚠️  Pilihan tidak valid: $answer${C_RESET}"
        done
    fi

    local -A seen=()
    for i in "${picked[@]}"; do
        [[ -n "${seen[$i]+x}" ]] && continue
        seen[$i]=1
        SEL_IDS+=("${ids[$i]}")
        SEL_NAMES+=("${names[$i]}")
    done
    return 0
}

choose_networks() {
    local matched count

    log_event INPUT "pattern=$PATTERN" "networks_arg=${NET_ARGS[*]:-}" "method=$METHOD" \
        "parallel=$PARALLEL" "output_dir=$OUTPUT_DIR"

    if (( ${#NET_ARGS[@]} > 0 )); then
        resolve_network_args
    else
        matched="$(jq -c --arg p "$PATTERN" '[ .[] | select(.name | test($p; "i")) ]' <<< "$EXT_JSON")"
        count="$(jq 'length' <<< "$matched")"
        if (( count == 0 )); then
            echo "${C_YELLOW}⚠️  Tidak ada external network yang namanya cocok dengan pola '$PATTERN'.${C_RESET}"
            if [[ "$EXT_JSON" == "[]" ]]; then
                echo "Tidak ada external network di region ini."
            else
                echo "External network yang tersedia:"
                print_networks "$EXT_JSON"
            fi
            log_warn -q "tidak ada external network yang cocok dengan pola '$PATTERN'"
            exit 1
        fi
        has_tty || die "Tidak ada terminal untuk memilih network; gunakan --network (mis. dari cron)."
        select_networks "$matched"
    fi

    if (( ${#SEL_IDS[@]} == 0 )); then
        echo "Tidak ada network dipilih. Selesai."
        log_event DECISION selection=none
        exit 0
    fi

    local i
    for i in "${!SEL_IDS[@]}"; do
        log_event DECISION "network_id=${SEL_IDS[$i]}" "network_name=${SEL_NAMES[$i]}"
    done
    return 0
}

# ============================================================
# 2. Ambil floating IP
# ============================================================

# Normalisasi output list/show/API ke {id, ip, project_id, status, port_id,
# details, device_owner, device_id, created_at, updated_at}. port_details bisa
# object (API) atau string "k='v', ..." (OSC show -f json memformat dict).
# shellcheck disable=SC2016  # program jq, bukan ekspansi shell
JQ_NORM='
def pd_get($k):
  if type == "object" then (.[$k] // "" | tostring)
  elif type == "string" then ((capture($k + "=\u0027(?<v>[^\u0027]*)\u0027") | .v) // "")
  else "" end;
def norm:
  (if has("port_details") then .port_details elif has("Port Details") then ."Port Details" else null end) as $pd
  | ((.port_id // .Port // "") | tostring) as $port
  | { id: (.id // .ID // ""),
      ip: (.floating_ip_address // ."Floating IP Address" // ""),
      project_id: (.project_id // .tenant_id // .Project // ""),
      status: (.status // .Status // ""),
      port_id: $port,
      details: ($port == "" or ($pd != null and $pd != "")),
      device_owner: ($pd | pd_get("device_owner")),
      device_id: ($pd | pd_get("device_id")),
      created_at: (.created_at // ."Created At" // ""),
      updated_at: (.updated_at // ."Updated At" // "") };
'

# Output "floating ip list" sudah memuat semua field yang dibutuhkan?
list_has_all_fields() {
    jq -e 'length == 0 or (.[0] | (has("port_details") or has("Port Details"))
                                and (has("created_at") or has("Created At"))
                                and (has("updated_at") or has("Updated At")))' "$1" >/dev/null 2>&1
}

# fetch_list NET_ID OUT [--long] — "floating ip list" satu network
fetch_list() {
    local net="$1" out="$2" errf="$2.err"
    shift 2
    if ! os_cli floating ip list --network "$net" "$@" -f json > "$out" 2>"$errf"; then
        NET_FAIL_MSG="floating ip list gagal: $(last_error_line "$errf")"
        return 1
    fi
    jq -e 'type == "array"' "$out" >/dev/null 2>&1 || { NET_FAIL_MSG="output floating ip list tidak valid"; return 1; }
}

# --- metode api ---

fetch_api() {
    local net="$1" out="$2" q
    api_setup network /v2.0 || return 1
    q="floating_network_id=$net"
    [[ -n "$PAGE_LIMIT" ]] && q+="&limit=$PAGE_LIMIT"
    api_collect floatingips "$q" floatingips "$out"
}

# --- metode cli (paralel) ---

# parallel_show DIR LABEL CMD... — jalankan "CMD <id> -f json" untuk setiap ID di
# DIR/ids (satu per baris) dengan xargs -P. Hasil: DIR/<id>.json atau DIR/<id>.err.
parallel_show() {
    local dir="$1" label="$2" total done_n
    shift 2

    total="$(grep -c . "$dir/ids" || true)"
    (( total > 0 )) || return 0

    # shellcheck disable=SC2016  # dievaluasi oleh bash -c, bukan di sini
    xargs -P "$PARALLEL" -n 1 -a "$dir/ids" bash -c '
        d="$1"; shift
        id="${!#}"
        set -- "${@:1:$#-1}"
        if "$@" "$id" -f json > "$d/$id.tmp" 2> "$d/$id.err"; then
            mv "$d/$id.tmp" "$d/$id.json"
            rm -f "$d/$id.err"
        else
            rm -f "$d/$id.tmp"
        fi
        : > "$d/$id.done"
    ' _ "$dir" "$@" &
    XARGS_PID=$!

    while kill -0 "$XARGS_PID" 2>/dev/null; do
        done_n="$(find "$dir" -maxdepth 1 -name '*.done' | wc -l)"
        [[ -t 1 ]] && printf '\r  %s: %d/%d' "$label" "$done_n" "$total"
        sleep 0.5
    done
    wait "$XARGS_PID" 2>/dev/null || true
    XARGS_PID=""
    done_n="$(find "$dir" -maxdepth 1 -name '*.done' | wc -l)"
    [[ -t 1 ]] && printf '\r'
    printf '  %s: %d/%d selesai\n' "$label" "$done_n" "$total"
    return 0
}

# fetch_cli NET_ID LIST_JSON OUT — "floating ip show" per ID (paralel)
fetch_cli() {
    local net="$1" list="$2" out="$3" dir="$WORK_DIR/show-$1" id gone=0 failed=0
    rm -rf "$dir"
    mkdir -p "$dir"

    jq -r '.[] | (.ID // .id)' "$list" > "$dir/ids.all"
    : > "$dir/ids"
    while IFS= read -r id; do
        if is_uuidish "$id"; then echo "$id" >> "$dir/ids"; else failed=$(( failed + 1 )); fi
    done < "$dir/ids.all"

    parallel_show "$dir" "floating ip show" "${OS_CMD[@]}" floating ip show

    while IFS= read -r id; do
        [[ -f "$dir/$id.json" ]] && continue
        if is_not_found "$dir/$id.err"; then
            gone=$(( gone + 1 ))
            log_event SKIPPED "resource=$id" "reason=floating IP sudah tidak ada saat show"
        else
            failed=$(( failed + 1 ))
            log_warn -q "floating ip show $id gagal: $(last_error_line "$dir/$id.err")"
        fi
    done < "$dir/ids"

    jq -s '.' "$dir"/*.json > "$out" 2>/dev/null || echo '[]' > "$out"
    if (( gone > 0 )); then
        NET_NOTES+=("$gone floating IP terhapus selama proses (dilewati)")
    fi
    if (( failed > 0 )); then
        NET_FAILED=1
        NET_FAIL_MSG="$failed floating ip show gagal (data tidak lengkap)"
        warn "$NET_FAIL_MSG"
    fi
    return 0
}

# fetch_fips NET_ID OUT — pilih metode, hasil dinormalisasi di OUT
fetch_fips() {
    local net="$1" out="$2" raw="$WORK_DIR/raw-$1.json" list="$WORK_DIR/list-$1.json"

    case "$METHOD" in
        api)
            fetch_api "$net" "$raw" || { NET_FAIL_MSG="metode api: $API_REASON"; return 1; }
            NET_METHOD="api"
            ;;
        cli)
            fetch_list "$net" "$list" || return 1
            fetch_cli "$net" "$list" "$raw"
            NET_METHOD="cli"
            ;;
        auto)
            fetch_list "$net" "$list" --long || return 1
            if list_has_all_fields "$list"; then
                cp "$list" "$raw"
                NET_METHOD="list"
                log_event METHOD "network_id=$net" method=list "reason=floating ip list memuat semua field"
            elif fetch_api "$net" "$raw"; then
                NET_METHOD="api"
                log_event METHOD "network_id=$net" method=api \
                    "reason=floating ip list tidak memuat port_details/created_at/updated_at"
            else
                NET_METHOD="cli"
                NET_NOTES+=("fallback ke cli: $API_REASON")
                warn "Metode api tidak bisa dipakai ($API_REASON); fallback ke cli."
                log_event METHOD "network_id=$net" method=cli "reason=fallback api: $API_REASON"
                fetch_cli "$net" "$list" "$raw"
            fi
            ;;
    esac

    jq "$JQ_NORM"' [ .[] | norm ]' "$raw" > "$out" 2>/dev/null || {
        NET_FAIL_MSG="data floating IP tidak bisa diparse"
        return 1
    }
    return 0
}

# Extension fip-port-details tidak aktif: ambil device_owner/device_id dari port
fill_port_details() {
    local fips="$1" dir="$WORK_DIR/ports" ports="$WORK_DIR/ports.json" n id failed=0
    local -a ids=()

    mapfile -t ids < <(jq -r '[ .[] | select(.details | not) | .port_id ] | unique | .[]' "$fips")
    n=${#ids[@]}
    (( n > 0 )) || return 0

    NET_NOTES+=("port_details tidak tersedia (extension fip-port-details?); $n port diambil terpisah")
    log_event PORT_LOOKUP "count=$n" "method=$NET_METHOD"

    rm -rf "$dir"
    mkdir -p "$dir"
    echo '[]' > "$ports"

    if [[ "$NET_METHOD" == "api" ]] || { [[ "$METHOD" != "cli" ]] && api_setup network /v2.0; }; then
        local i q
        local -a batch_files=()
        for (( i = 0; i < n; i += PORT_BATCH )); do
            q="fields=id&fields=device_owner&fields=device_id"
            for id in "${ids[@]:i:PORT_BATCH}"; do q+="&id=$id"; done
            if ! api_collect ports "$q" ports "$dir/b$i.json"; then
                failed=1
                break
            fi
            batch_files+=("$dir/b$i.json")
        done
        (( failed == 0 )) && jq -s '[ .[][] ]' "${batch_files[@]}" > "$ports"
    else
        printf '%s\n' "${ids[@]}" | while IFS= read -r id; do is_uuidish "$id" && echo "$id"; done > "$dir/ids"
        parallel_show "$dir" "port show" "${OS_CMD[@]}" port show
        for id in "${ids[@]}"; do
            if [[ ! -f "$dir/$id.json" ]] && ! is_not_found "$dir/$id.err"; then
                failed=1
            fi
        done
        jq -s '.' "$dir"/*.json > "$ports" 2>/dev/null || echo '[]' > "$ports"
    fi

    if (( failed )); then
        NET_FAILED=1
        NET_FAIL_MSG="lookup port gagal (kolom instance tidak lengkap)"
        warn "$NET_FAIL_MSG"
    fi

    # Port tidak ditemukan = tidak terasosiasi ke device; lookup gagal = "?"
    jq --slurpfile p "$ports" --argjson failed "$failed" '
        ($p[0] | map({ key: .id, value: . }) | from_entries) as $m
        | map(if .details then .
              elif $m[.port_id] then .device_owner = ($m[.port_id].device_owner // "")
                                   | .device_id = ($m[.port_id].device_id // "") | .details = true
              elif $failed == 1 then .device_owner = "?"
              else .details = true end)' "$fips" > "$fips.tmp" && mv "$fips.tmp" "$fips"
    return 0
}

# ============================================================
# 3. Project dan instance
# ============================================================

# Peta project ID → nama (satu "project list", sekali per run)
resolve_projects() {
    local errf="$WORK_DIR/projects.err"
    [[ -n "$PROJECTS_STATE" ]] && return 0
    if os_cli project list -f json > "$WORK_DIR/projects.raw" 2>"$errf" &&
            jq '[ .[] | { key: (.ID // .id), value: (.Name // .name) } ] | from_entries' \
                "$WORK_DIR/projects.raw" > "$WORK_DIR/projects.json" 2>/dev/null; then
        PROJECTS_STATE="ok"
        log_result resource=projects action=lookup result=SUCCESS "count=$(jq length "$WORK_DIR/projects.json")"
    else
        PROJECTS_STATE="fail"
        echo '{}' > "$WORK_DIR/projects.json"
        warn "Gagal mengambil daftar project ($(last_error_line "$errf")); kolom Project Name berisi project ID."
        log_result resource=projects action=lookup result=FAILED "msg=$(last_error_line "$errf")"
    fi
    return 0
}

# Peta instance ID → nama untuk device_id compute:* di FIPS. Cache lintas network
# (instances.json) hanya berisi hasil pasti: nama atau "(not found)". Lookup yang
# gagal (bukan not found) → "(lookup failed)" di inst-net.json, network FAILED.
resolve_instances() {
    local fips="$1" map="$WORK_DIR/instances.json" n id dir errf
    local -a ids=() failed_ids=()

    [[ -f "$map" ]] || echo '{}' > "$map"
    mapfile -t ids < <(jq -r --slurpfile m "$map" '
        [ .[] | select((.device_owner | startswith("compute:")) and .device_id != "") | .device_id ]
        | unique | map(select($m[0][.] == null)) | .[]' "$fips")
    n=${#ids[@]}
    (( n > 0 )) || return 0

    if (( n <= SERVER_SHOW_MAX )) && [[ "$SERVER_LIST_STATE" != "ok" ]]; then
        dir="$WORK_DIR/servers-$RANDOM"
        mkdir -p "$dir"
        for id in "${ids[@]}"; do is_uuidish "$id" && echo "$id"; done > "$dir/ids"
        log_event INSTANCE_LOOKUP method=server-show "count=$n"
        parallel_show "$dir" "server show" "${OS_CMD[@]}" --os-compute-api-version "$COMPUTE_API_VERSION" server show
        for id in "${ids[@]}"; do
            if [[ -f "$dir/$id.json" ]]; then
                jq --arg i "$id" --slurpfile s "$dir/$id.json" '.[$i] = ($s[0].name // "")' "$map" > "$map.tmp"
                mv "$map.tmp" "$map"
            elif [[ -f "$dir/$id.err" ]] && is_not_found "$dir/$id.err"; then
                jq --arg i "$id" '.[$i] = "(not found)"' "$map" > "$map.tmp"
                mv "$map.tmp" "$map"
            else
                failed_ids+=("$id")
                log_warn -q "server show $id gagal: $(last_error_line "$dir/$id.err")"
            fi
        done
    else
        if [[ -z "$SERVER_LIST_STATE" ]]; then
            errf="$WORK_DIR/servers.err"
            log_event INSTANCE_LOOKUP method=server-list "count=$n"
            echo "  server list --all-projects ..."
            # Tanpa --limit: OSC/SDK mengikuti semua halaman (--limit mematikan pagination)
            if os_compute server list --all-projects -n -f json -c ID -c Name > "$WORK_DIR/servers.raw" 2>"$errf" &&
                    jq '[ .[] | { key: (.ID // .id), value: (.Name // .name // "") } ] | from_entries' \
                        "$WORK_DIR/servers.raw" > "$WORK_DIR/servers.json" 2>/dev/null; then
                SERVER_LIST_STATE="ok"
                log_result resource=servers action=lookup result=SUCCESS "count=$(jq length "$WORK_DIR/servers.json")"
            else
                SERVER_LIST_STATE="fail"
                warn "server list --all-projects gagal: $(last_error_line "$errf")"
                log_result resource=servers action=lookup result=FAILED "msg=$(last_error_line "$errf")"
            fi
        fi
        if [[ "$SERVER_LIST_STATE" == "ok" ]]; then
            printf '%s\n' "${ids[@]}" | jq -R . | jq -s --slurpfile s "$WORK_DIR/servers.json" --slurpfile m "$map" '
                reduce .[] as $i ($m[0]; .[$i] = ($s[0][$i] // "(not found)"))' > "$map.tmp" && mv "$map.tmp" "$map"
        else
            failed_ids=("${ids[@]}")
        fi
    fi

    if (( ${#failed_ids[@]} > 0 )); then
        NET_FAILED=1
        NET_FAIL_MSG="lookup instance gagal untuk ${#failed_ids[@]} ID"
        warn "$NET_FAIL_MSG"
        printf '%s\n' "${failed_ids[@]}" | jq -R . | jq -s --slurpfile m "$map" '
            reduce .[] as $i ($m[0]; .[$i] = "(lookup failed)")' > "$WORK_DIR/inst-net.json"
    fi
    return 0
}

# ============================================================
# 4-5. Baris CSV
# ============================================================

# Instance hanya diisi untuk device_owner "compute:*" (tidak bergantung status FIP)
# shellcheck disable=SC2016  # program jq, bukan ekspansi shell
JQ_ROWS='
def ipkey: if test(":") then [1, .] else [0, (split(".") | map(tonumber? // 0))] end;
def pname($p; $state):
  if . == "" then ""
  elif $p[.] != null then $p[.]
  elif $state == "fail" then . + " (lookup failed)"
  else . + " (not found)" end;
sort_by(.ip | ipkey)
| .[]
| (if (.device_owner | startswith("compute:")) and .device_id != "" then
     [ .device_id, ($inst[0][.device_id] // "(not found)") ]
   elif .device_owner == "?" then [ "", "(lookup failed)" ]
   else [ "", "" ] end) as $i
| [ .id, .ip, (.project_id | pname($proj[0]; $pstate)), .status, $i[0], $i[1],
    (.created_at // "" | tostring), (.updated_at // "" | tostring) ]
| map(. // "" | tostring)
| @csv'

CSV_HEADER="Floating ID,Floating IP Address,Project Name,Status,Instance ID,Instance Name,Created At,Updated At"

# write_csv FIPS NET_ID NET_NAME — set CSV_FILE. Permission 600, tidak menimpa file.
write_csv() {
    local fips="$1" net="$2" name="$3" ts base inst="$WORK_DIR/instances.json"

    [[ -f "$WORK_DIR/inst-net.json" ]] && inst="$WORK_DIR/inst-net.json"
    jq -r --slurpfile proj "$WORK_DIR/projects.json" --slurpfile inst "$inst" \
        --arg pstate "$PROJECTS_STATE" "$JQ_ROWS" "$fips" > "$WORK_DIR/rows.csv" || return 1

    ts="$(date +%Y%m%d-%H%M%S)"
    base="$OUTPUT_DIR/fip-$(safe_name "$name")"
    CSV_FILE="$base-$ts.csv"
    if [[ -e "$CSV_FILE" ]]; then
        CSV_FILE="$base-${net:0:8}-$ts.csv"
    fi

    # umask 077 + noclobber: file baru dengan permission 600, file lama tidak ditimpa
    if ! ( umask 077; set -o noclobber
           { printf '%s\n' "$CSV_HEADER"; cat "$WORK_DIR/rows.csv"; } > "$CSV_FILE" ) 2>"$WORK_DIR/csv.err"; then
        NET_FAIL_MSG="gagal menulis $CSV_FILE: $(last_error_line "$WORK_DIR/csv.err")"
        CSV_FILE=""
        return 1
    fi
    chmod 600 "$CSV_FILE" 2>/dev/null || true
    return 0
}

# ============================================================
# 6. Ringkasan
# ============================================================

# print_summary FIPS NET_ID NET_NAME DURATION
print_summary() {
    local fips="$1" net="$2" name="$3" dur="$4" stats inst="$WORK_DIR/instances.json" note
    [[ -f "$WORK_DIR/inst-net.json" ]] && inst="$WORK_DIR/inst-net.json"

    stats="$(jq -r --slurpfile inst "$inst" '
        def is_inst: (.device_owner | startswith("compute:")) and .device_id != "";
        [ length,
          ([ group_by(.status)[] | "\(.[0].status // "-")=\(length)" ] | join("  ")),
          ([ .[] | select(is_inst) ] | length),
          ([ .[] | select(.port_id != "" and (is_inst | not)) ] | length),
          ([ .[] | select(.port_id == "") ] | length),
          ([ .[] | select(is_inst) | .device_id ] | unique | map(select($inst[0][.] == "(not found)")) | length)
        ] | map(tostring) | join("\u001f")' "$fips")"
    IFS=$'\x1f' read -r S_TOTAL S_STATUS S_INST S_OTHER S_FREE S_NOTFOUND <<< "$stats"

    echo
    echo "${C_BOLD}── $name ($net)${C_RESET}"
    printf '  %-27s : %s\n' "Region" "$REGION"
    printf '  %-27s : %s\n' "Metode" "$NET_METHOD"
    printf '  %-27s : %s\n' "Total floating IP" "$S_TOTAL"
    printf '  %-27s : %s\n' "Per status" "${S_STATUS:--}"
    printf '  %-27s : %s\n' "Terasosiasi ke instance" "$S_INST"
    printf '  %-27s : %s\n' "Terasosiasi ke non-instance" "$S_OTHER (router/LB/dll.)"
    printf '  %-27s : %s\n' "Tidak terasosiasi" "$S_FREE"
    printf '  %-27s : %s\n' "Instance (not found)" "$S_NOTFOUND"
    printf '  %-27s : %ss\n' "Durasi" "$dur"
    printf '  %-27s : %s\n' "File CSV" "${CSV_FILE:--}"
    for note in "${NET_NOTES[@]}"; do
        printf '  %-27s : %s\n' "Catatan" "$note"
    done
    if (( NET_FAILED )); then
        echo "  ${C_RED}❌ FAILED: $NET_FAIL_MSG${C_RESET}"
    else
        echo "  ${C_GREEN}✅ Selesai${C_RESET}"
    fi
}

# ============================================================
# Proses per network
# ============================================================

process_network() {
    local net="$1" name="$2" start=$SECONDS dur fips="$WORK_DIR/fips-$1.json" result msg

    NET_METHOD="-" NET_NOTES=() NET_FAILED=0 NET_FAIL_MSG="" CSV_FILE=""
    rm -f "$WORK_DIR/inst-net.json"

    echo
    echo "${C_BOLD}▶ $name ($net)${C_RESET}"

    if ! fetch_fips "$net" "$fips"; then
        dur=$(( SECONDS - start ))
        echo "  ${C_RED}❌ $NET_FAIL_MSG${C_RESET}"
        log_result "resource=$net" action=collect-public-fip result=FAILED "name=$name" \
            "method=$NET_METHOD" count=0 file=- "duration=${dur}s" "msg=$NET_FAIL_MSG"
        ALL_RESULTS+=("$name|FAILED|0|-")
        ANY_FAILED=1
        return 0
    fi
    echo "  Metode: $NET_METHOD — $(jq length "$fips") floating IP"

    fill_port_details "$fips"
    resolve_projects
    resolve_instances "$fips"

    if ! write_csv "$fips" "$net" "$name"; then
        NET_FAILED=1
        [[ -n "$NET_FAIL_MSG" ]] || NET_FAIL_MSG="gagal membuat baris CSV"
    fi
    dur=$(( SECONDS - start ))
    print_summary "$fips" "$net" "$name" "$dur"

    result=SUCCESS
    msg="ok"
    (( ${#NET_NOTES[@]} > 0 )) && msg="$(IFS=';'; echo "${NET_NOTES[*]}")"
    if (( NET_FAILED )); then
        result=FAILED
        msg="$NET_FAIL_MSG"
        ANY_FAILED=1
    fi
    log_result "resource=$net" action=collect-public-fip "result=$result" "name=$name" \
        "method=$NET_METHOD" "count=$S_TOTAL" "file=${CSV_FILE:--}" "duration=${dur}s" "msg=$msg"
    ALL_RESULTS+=("$name|$result|$S_TOTAL|${CSV_FILE:--}")
    return 0
}

main() {
    parse_args "$@"
    require_deps

    echo "========================================"
    echo "       Collect Public Floating IPs"
    echo "========================================"

    log_event OPTIONS "os_cmd=${OS_CMD[*]}" "curl=$API_CURL" "compute_api=$COMPUTE_API_VERSION" \
        "page_limit=${PAGE_LIMIT:--}"

    LOG_EXIT_HOOK=on_exit
    make_work_dir
    detect_region
    find_networks
    choose_networks

    local i r name res cnt file
    for i in "${!SEL_IDS[@]}"; do
        process_network "${SEL_IDS[$i]}" "${SEL_NAMES[$i]}"
    done

    if (( ${#ALL_RESULTS[@]} > 1 )); then
        echo
        echo "========================================"
        echo "Ringkasan ($REGION)"
        for r in "${ALL_RESULTS[@]}"; do
            IFS='|' read -r name res cnt file <<< "$r"
            printf '  %-8s %-24s %6s FIP  %s\n' "$res" "$name" "$cnt" "$file"
        done
    fi
    echo
    echo "Log : ${LOG_FILE:-(logging nonaktif)}"

    log_event SUMMARY "networks=${#SEL_IDS[@]}" "failed=$ANY_FAILED"
    (( ANY_FAILED )) && exit 1
    return 0
}

main "$@"
