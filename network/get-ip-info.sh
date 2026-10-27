#!/bin/bash
# ============================================================
# @name:        IP Information
# @description: Find who uses an IP: floating IPs and port fixed IPs (single IP or list)
# @mutates:     no
# @requires:    admin, jq
# @tags:        neutron, ip, port, floating-ip, lookup, troubleshooting
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: get-ip-info.sh [--ip IP]... [--file PATH] [--network NAMA|ID] [--project NAMA|ID]
                      [--deep] [--csv] [--output-dir PATH] [--method auto|api|cli]
                      [--parallel N]

Cari siapa yang memakai sebuah IP: floating IP dan fixed IP di port (IP private
instance, router gateway/interface, DHCP, VIP load balancer, dll.), di semua
project. Satu IP bisa punya beberapa hasil (CIDR private yang sama dipakai di
banyak project). Read-only: tidak ada resource yang diubah.

Opsi:
  --ip IP            IP yang dicari (IPv4/IPv6; bisa diulang)
  --file PATH        Daftar IP, satu per baris (# komentar dan baris kosong
                     diabaikan, duplikat dihapus)
  --network N        Batasi ke network ini (nama atau ID): port di network itu,
                     floating IP dari network itu atau terasosiasi ke port di
                     network itu, subnet di network itu
  --project P        Batasi ke project ini (nama atau ID)
  --deep             Juga cari di allowed address pairs semua port (alamat persis
                     atau CIDR IPv4 yang mencakup IP). Lebih lambat.
  --csv              Simpan hasil ke CSV
  --output-dir PATH  Direktori CSV (default /tmp; harus sudah ada)
  --method M         auto (default) | api | cli — cara mengambil port/floating IP
                       auto: api (curl ke Neutron) jika bisa, jika tidak cli
                       api : request langsung ke Neutron API dengan curl
                       cli : "list" lalu "show" per resource yang cocok, paralel
  --parallel N       Jumlah proses paralel untuk "show" (default 8, 1-64)
  -h, --help         Tampilkan help

Tanpa --ip/--file: sumber input dan penyimpanan CSV ditanyakan interaktif.
Sampai 20 IP dicari per IP; lebih dari itu semua port dan floating IP diambil
sekali lalu dicocokkan lokal (hasilnya sama).

Tipe hasil (Match Type): FLOATING_IP, FIXED_IP, ALLOWED_ADDRESS_PAIR (--deep),
SUBNET_ONLY (tidak ada port, tetapi IP berada di CIDR subnet), NOT_FOUND, INVALID.

File: <output-dir>/ip-info-<YYYYmmdd-HHMMSS>.csv (permission 600), satu baris per
kecocokan, urutan mengikuti input.

Exit code: 0 selesai; 1 error, lookup tidak lengkap, atau (satu IP) tidak
ditemukan / tidak valid.

Environment:
  OSOPS_OS_CMD                Perintah OpenStack CLI (default: openstack)
  OSOPS_CURL                  Perintah curl (default: curl; opsional, metode api)
  OSOPS_COMPUTE_API_VERSION   Compute microversion (default 2.1)
  OSOPS_IPINFO_PER_IP_MAX     Batas jumlah IP untuk pencarian per IP (default 20)
  OSOPS_IPINFO_STRATEGY       auto (default) | per-ip | bulk
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

# Validasi IP, CIDR, label device_owner
# shellcheck source=../lib/netinfo.sh
if ! source "$OSOPS_HOME/lib/netinfo.sh" 2>/dev/null; then
    echo "❌ lib/netinfo.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi

# ============================================================
# Konfigurasi
# ============================================================

IP_ARGS=()
FILE_ARG=""
NETWORK_ARG=""
PROJECT_ARG=""
DEEP=0
CSV=""               # "" = belum ditentukan | 0 | 1
OUTPUT_DIR="/tmp"
METHOD="auto"
PARALLEL=8

# Wrapper OpenStack CLI. Array tidak bisa di-export, jadi override
# lewat string, mis. RHOSO: OSOPS_OS_CMD="oc exec -n openstack openstackclient -- openstack"
if [[ -n "${OSOPS_OS_CMD:-}" ]]; then
    read -ra OS_CMD <<< "$OSOPS_OS_CMD"
else
    OS_CMD=(openstack)
fi

# 2.1 cukup: server show/list memuat name, status, dan host (admin)
COMPUTE_API_VERSION="${OSOPS_COMPUTE_API_VERSION:-2.1}"
PER_IP_MAX="${OSOPS_IPINFO_PER_IP_MAX:-20}"
STRATEGY_ENV="${OSOPS_IPINFO_STRATEGY:-auto}"
# Jumlah ID per request API (?id=..&id=..)
API_BATCH=50
# Jumlah instance unik maksimum untuk "server show" per ID; di atas ini
# satu "server list --all-projects"
SERVER_SHOW_MAX=20

REGION="-"
AUTH_HOST="-"
WORK_DIR=""
XARGS_PID=""
US=$'\x1f'

INPUT_SOURCE=""      # args | interactive
SINGLE=0             # satu IP (mode lama "Single"): tidak ditemukan → exit 1
STRATEGY=""          # per-ip | bulk
USED_METHOD=""       # api | cli
NOTES=()
NET_ID=""
PROJ_ID=""
CSV_FILE=""
PARTIAL=0            # ada lookup yang gagal (hasil tidak lengkap)

# Lookup bersama: "" | ok | fail
NETWORKS_STATE=""
PROJECTS_STATE=""
DOMAINS_STATE=""
SUBNETS_STATE=""
ROUTERS_STATE="ok"
SERVERS_STATE="ok"

# Statistik input
N_LINES=0
N_VALID=0
N_INVALID=0
N_DUP=0

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

is_yes() {
    [[ "${1,,}" =~ ^(y|ya|yes)$ ]]
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
            --ip)         need_value "$1" "${2:-}"; IP_ARGS+=("$2"); shift 2 ;;
            --file)       need_value "$1" "${2:-}"; FILE_ARG="$2"; shift 2 ;;
            --network)    need_value "$1" "${2:-}"; NETWORK_ARG="$2"; shift 2 ;;
            --project)    need_value "$1" "${2:-}"; PROJECT_ARG="$2"; shift 2 ;;
            --deep)       DEEP=1; shift ;;
            --csv)        CSV=1; shift ;;
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
    case "$STRATEGY_ENV" in
        auto|per-ip|bulk) ;;
        *) die "OSOPS_IPINFO_STRATEGY harus auto, per-ip, atau bulk (dapat: $STRATEGY_ENV)." ;;
    esac
    if [[ ! "$PARALLEL" =~ ^[0-9]+$ ]] || (( PARALLEL < 1 || PARALLEL > 64 )); then
        die "--parallel harus angka 1-64 (dapat: $PARALLEL)."
    fi
    [[ "$PER_IP_MAX" =~ ^[0-9]+$ ]] || die "OSOPS_IPINFO_PER_IP_MAX harus angka (dapat: $PER_IP_MAX)."

    [[ -d "$OUTPUT_DIR" ]] || die "Direktori output tidak ada: $OUTPUT_DIR"
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
    WORK_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/get-ip-info.XXXXXX")" || \
        die "Gagal membuat direktori sementara di ${TMPDIR:-/tmp}."
    API_WORK_DIR="$WORK_DIR"
}

# Dipanggil lib/logging.sh saat script keluar (normal, error, sinyal)
# shellcheck disable=SC2329  # dipanggil lewat LOG_EXIT_HOOK
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
# 1. Input
# ============================================================

RAW_INPUT=()

# read_ip_file PATH — mapfile (bukan while read: prompt bisa memakan input)
read_ip_file() {
    local path="$1" line
    local -a lines=()

    [[ -f "$path" && -r "$path" ]] || die "File '$path' tidak ditemukan atau tidak bisa dibaca."
    mapfile -t lines < "$path"
    for line in "${lines[@]}"; do
        line="$(trim "${line//$'\r'/}")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        RAW_INPUT+=("$line")
    done
    return 0
}

choose_input() {
    local mode ip path answer

    if (( ${#IP_ARGS[@]} > 0 )) || [[ -n "$FILE_ARG" ]]; then
        INPUT_SOURCE="args"
        local a
        for a in "${IP_ARGS[@]}"; do
            a="$(trim "$a")"
            [[ -n "$a" ]] && RAW_INPUT+=("$a")
        done
        [[ -n "$FILE_ARG" ]] && read_ip_file "$FILE_ARG"
        (( ${#IP_ARGS[@]} == 1 )) && [[ -z "$FILE_ARG" ]] && SINGLE=1
        [[ -n "$CSV" ]] || CSV=0
    else
        INPUT_SOURCE="interactive"
        has_tty || die "Tidak ada terminal untuk input; gunakan --ip atau --file (mis. dari cron)."
        echo
        echo "Sumber input:"
        echo "  1. Satu IP"
        echo "  2. Daftar IP dari file"
        ask mode "Pilih [1-2]: "
        case "$(trim "$mode")" in
            1)
                ask ip "Masukkan IP: "
                ip="$(trim "$ip")"
                [[ -n "$ip" ]] || die "IP tidak boleh kosong."
                RAW_INPUT=("$ip")
                SINGLE=1
                ;;
            2)
                ask path "Path file daftar IP: "
                FILE_ARG="$(trim "$path")"
                [[ -n "$FILE_ARG" ]] || die "Path file tidak boleh kosong."
                read_ip_file "$FILE_ARG"
                ;;
            *)
                die "Pilihan tidak valid: $mode"
                ;;
        esac
        if [[ -z "$CSV" ]]; then
            # Default mengikuti perilaku lama: daftar dari file → CSV
            if (( SINGLE )); then
                ask answer "Simpan hasil ke CSV di $OUTPUT_DIR? [y/N]: "
                if is_yes "$(trim "$answer")"; then CSV=1; else CSV=0; fi
            else
                ask answer "Simpan hasil ke CSV di $OUTPUT_DIR? [Y/n]: "
                answer="$(trim "$answer")"
                if [[ -z "$answer" ]] || is_yes "$answer"; then CSV=1; else CSV=0; fi
            fi
            log_event DECISION "csv=$CSV"
        fi
    fi

    (( ${#RAW_INPUT[@]} > 0 )) || die "Tidak ada IP di input${FILE_ARG:+ (file: $FILE_ARG)}."
    if (( CSV )); then
        [[ -w "$OUTPUT_DIR" ]] || die "Direktori output tidak bisa ditulis: $OUTPUT_DIR"
    fi
    log_event INPUT "source=$INPUT_SOURCE" "ip_args=${#IP_ARGS[@]}" "input_file=${FILE_ARG:--}" \
        "network=${NETWORK_ARG:--}" "project=${PROJECT_ARG:--}" "deep=$DEEP" "csv=$CSV" \
        "output_dir=$OUTPUT_DIR" "method=$METHOD" "parallel=$PARALLEL"
    return 0
}

# Validasi + kanonisasi + hapus duplikat (urutan input dipertahankan).
# Hasil: $WORK_DIR/queries.json [{q, ip, valid}] dan $WORK_DIR/ips.json
build_queries() {
    local raw ip key
    local -A seen=()

    : > "$WORK_DIR/queries.tsv"
    N_LINES=${#RAW_INPUT[@]}
    for raw in "${RAW_INPUT[@]}"; do
        if ip="$(ip_normalize "$raw")"; then
            key="ip:$ip"
        else
            ip=""
            key="raw:$raw"
        fi
        if [[ -n "${seen[$key]+x}" ]]; then
            N_DUP=$(( N_DUP + 1 ))
            continue
        fi
        seen[$key]=1
        if [[ -n "$ip" ]]; then
            N_VALID=$(( N_VALID + 1 ))
            printf '%s%s%s\n' "$ip" "$US" "$ip" >> "$WORK_DIR/queries.tsv"
        else
            N_INVALID=$(( N_INVALID + 1 ))
            printf '%s%s\n' "${raw//$US/}" "$US" >> "$WORK_DIR/queries.tsv"
        fi
    done
    jq -R -s '[ split("\n")[] | select(length > 0) | split("\u001f")
               | { q: .[0], ip: (.[1] // ""), valid: ((.[1] // "") != "") } ]' \
        "$WORK_DIR/queries.tsv" > "$WORK_DIR/queries.json"
    jq '[ .[] | select(.valid) | .ip ]' "$WORK_DIR/queries.json" > "$WORK_DIR/ips.json"

    log_event INPUT_STATS "lines=$N_LINES" "valid=$N_VALID" "invalid=$N_INVALID" "duplicate=$N_DUP"
    echo "IP: $N_VALID valid, $N_INVALID tidak valid, $N_DUP duplikat dilewati"
    return 0
}

# ============================================================
# 2. Lookup bersama (sekali per run, selalu lewat CLI)
# ============================================================

# load_map NAME STATEVAR EMPTY JQ CMD... — simpan hasil jq ke $WORK_DIR/NAME.json;
# gagal → EMPTY ({} / []) dan state fail
load_map() {
    local name="$1" statevar="$2" empty="$3" filter="$4" errf="$WORK_DIR/$1.err"
    shift 4
    if os_cli "$@" > "$WORK_DIR/$name.raw" 2>"$errf" &&
            jq "$filter" "$WORK_DIR/$name.raw" > "$WORK_DIR/$name.json" 2>/dev/null; then
        printf -v "$statevar" '%s' ok
        log_result "resource=$name" action=lookup result=SUCCESS "count=$(jq length "$WORK_DIR/$name.json")"
    else
        printf -v "$statevar" '%s' fail
        echo "$empty" > "$WORK_DIR/$name.json"
        warn "Gagal mengambil $name ($(last_error_line "$errf")); kolom terkait berisi (lookup failed)."
        log_result "resource=$name" action=lookup result=FAILED "msg=$(last_error_line "$errf")"
        PARTIAL=1
    fi
    return 0
}

load_lookups() {
    echo "Mengambil network, subnet, project, domain ..."
    load_map networks NETWORKS_STATE '{}' \
        '[ .[] | { key: (.ID // .id), value: (.Name // .name // "") } ] | from_entries' \
        network list -f json
    # shellcheck disable=SC2016
    load_map subnets SUBNETS_STATE '[]' \
        '[ .[] | { id: (.ID // .id // ""), name: (.Name // .name // ""),
                   network_id: (.Network // .network_id // ""), cidr: (.Subnet // .cidr // ""),
                   project_id: (.Project // .project_id // ""), gateway_ip: (.Gateway // .gateway_ip // ""),
                   allocation_pools: (."Allocation Pools" // .allocation_pools // []) } ]' \
        subnet list --long -f json
    load_map projects PROJECTS_STATE '{}' \
        '[ .[] | { key: (.ID // .id), value: { name: (.Name // .name // ""),
                                               domain_id: (."Domain ID" // .domain_id // "") } } ] | from_entries' \
        project list --long -f json
    load_map domains DOMAINS_STATE '{}' \
        '[ .[] | { key: (.ID // .id), value: (.Name // .name // "") } ] | from_entries' \
        domain list -f json
    return 0
}

# resolve_filter KIND ARG MAPFILE STATE — set FILTER_ID (cocok ID atau nama; ambigu = error)
FILTER_ID=""
resolve_filter() {
    local kind="$1" arg="$2" map="$3" state="$4" m n
    [[ "$state" == "ok" ]] || die "Daftar $kind gagal diambil; --$kind tidak bisa di-resolve."
    m="$(jq -c --arg a "$arg" '
        if has($a) then [ $a ]
        else [ to_entries[] | select((.value | if type == "object" then .name else . end) == $a) | .key ] end' "$map")"
    n="$(jq length <<< "$m")"
    (( n > 0 )) || die "${kind^} '$arg' tidak ditemukan."
    (( n == 1 )) || die "Nama $kind '$arg' ambigu ($n: $(jq -r 'join(", ")' <<< "$m")); gunakan ID."
    FILTER_ID="$(jq -r '.[0]' <<< "$m")"
    return 0
}

resolve_filters() {
    if [[ -n "$NETWORK_ARG" ]]; then
        resolve_filter network "$NETWORK_ARG" "$WORK_DIR/networks.json" "$NETWORKS_STATE"
        NET_ID="$FILTER_ID"
        log_event FILTER "network=$NETWORK_ARG" "network_id=$NET_ID"
    fi
    if [[ -n "$PROJECT_ARG" ]]; then
        resolve_filter project "$PROJECT_ARG" "$WORK_DIR/projects.json" "$PROJECTS_STATE"
        PROJ_ID="$FILTER_ID"
        log_event FILTER "project=$PROJECT_ARG" "project_id=$PROJ_ID"
    fi
    return 0
}

# ============================================================
# 3. Ambil floating IP dan port
# ============================================================

# Normalisasi output API / show / list ke bentuk Neutron API.
# fixed_ips / allowed_address_pairs: list of dict (-f json) atau string
# "ip_address='..', subnet_id='..'" (format lama OSC); tanda kutip dicocokkan dengan ".".
# shellcheck disable=SC2016  # program jq, bukan ekspansi shell
JQ_NORM='
def str: if . == null then "" else tostring end;
def ipl:
  if type == "array" then map({ ip_address: (.ip_address | str | ascii_downcase), subnet_id: (.subnet_id | str) })
  elif type == "string" then [ scan("ip_address=.([0-9A-Fa-f.:/]*)., subnet_id=.([0-9A-Za-z-]*).") ]
                             | map({ ip_address: (.[0] | ascii_downcase), subnet_id: .[1] })
  else [] end;
def aapl:
  if type == "array" then map({ ip_address: (.ip_address | str | ascii_downcase), mac_address: (.mac_address | str) })
  elif type == "string" then [ scan("ip_address=.([0-9A-Fa-f.:/]*).") ] | map({ ip_address: (.[0] | ascii_downcase), mac_address: "" })
  else [] end;
def norm_port: {
  id: (.id // .ID | str), name: (.name // .Name | str),
  mac_address: (.mac_address // ."MAC Address" | str), status: (.status // .Status | str),
  network_id: (.network_id | str), project_id: (.project_id // .tenant_id | str),
  device_owner: (.device_owner // ."Device Owner" | str), device_id: (.device_id | str),
  fixed_ips: ((.fixed_ips // ."Fixed IP Addresses") | ipl),
  allowed_address_pairs: (.allowed_address_pairs | aapl),
  created_at: (.created_at | str), updated_at: (.updated_at | str) };
def norm_fip: {
  id: (.id // .ID | str),
  floating_ip_address: (.floating_ip_address // ."Floating IP Address" | str | ascii_downcase),
  floating_network_id: (.floating_network_id // ."Floating Network" | str),
  fixed_ip_address: (.fixed_ip_address // ."Fixed IP Address" | str | ascii_downcase),
  port_id: (.port_id // .Port | str), project_id: (.project_id // .tenant_id // .Project | str),
  status: (.status // .Status | str),
  created_at: (.created_at | str), updated_at: (.updated_at | str) };
'

# Gabungkan file JSON array (hasil list/API) → array unik ternormalisasi
# norm_merge KIND(port|fip) OUT FILES...
norm_merge() {
    local kind="$1" out="$2"
    shift 2
    if (( $# == 0 )); then
        echo '[]' > "$out"
        return 0
    fi
    jq -s "$JQ_NORM"" [ .[][] | norm_$kind ] | unique_by(.id)" "$@" > "$out"
}

# --- metode api ---

api_q() {
    local s="$1"
    s="${s//:/%3A}"
    printf '%s' "$s"
}

# api_by_ids PATH KEY IDSFILE OUTPREFIX — ?id=..&id=.. per batch; cetak file hasil
api_by_ids() {
    local path="$1" key="$2" idsf="$3" prefix="$4" i q id
    local -a ids=()
    mapfile -t ids < "$idsf"
    for (( i = 0; i < ${#ids[@]}; i += API_BATCH )); do
        q=""
        for id in "${ids[@]:i:API_BATCH}"; do
            is_uuidish "$id" && q+="${q:+&}id=$id"
        done
        [[ -n "$q" ]] || continue
        api_collect "$path" "$q" "$key" "$prefix-$i.json" || return 1
        echo "$prefix-$i.json"
    done
    return 0
}

fetch_api() {
    local dir="$WORK_DIR/api" i=0 ip q
    local -a ff=() pf=() ips=()
    rm -rf "$dir"
    mkdir -p "$dir"

    api_setup network /v2.0 || return 1
    mapfile -t ips < <(jq -r '.[]' "$WORK_DIR/ips.json")

    if [[ "$STRATEGY" == "bulk" ]]; then
        echo "  Mengambil semua floating IP (api) ..."
        api_collect floatingips "" floatingips "$dir/fips-all.json" || return 1
        ff+=("$dir/fips-all.json")
    else
        for ip in "${ips[@]}"; do
            i=$(( i + 1 ))
            [[ -t 1 ]] && printf '\r  [%d/%d] %s          ' "$i" "${#ips[@]}" "$ip"
            q="$(api_q "$ip")"
            api_collect floatingips "floating_ip_address=$q" floatingips "$dir/fa-$i.json" || return 1
            api_collect floatingips "fixed_ip_address=$q" floatingips "$dir/fb-$i.json" || return 1
            ff+=("$dir/fa-$i.json" "$dir/fb-$i.json")
            if (( ! DEEP )); then
                api_collect ports "fixed_ips=ip_address%3D$q" ports "$dir/p-$i.json" || return 1
                pf+=("$dir/p-$i.json")
            fi
        done
        [[ -t 1 ]] && printf '\r%60s\r' ''
        echo "  Pencarian per IP (api): ${#ips[@]} IP"
    fi

    if [[ "$STRATEGY" == "bulk" || "$DEEP" == 1 ]]; then
        echo "  Mengambil semua port (api) ..."
        api_collect ports "" ports "$dir/ports-all.json" || return 1
        pf+=("$dir/ports-all.json")
    fi

    norm_merge fip "$WORK_DIR/fips.json" "${ff[@]}"
    norm_merge port "$WORK_DIR/ports.json" "${pf[@]}"

    # Port milik floating IP yang cocok tapi belum terambil (per IP)
    jq -r --slurpfile p "$WORK_DIR/ports.json" '
        ($p[0] | map({ key: .id, value: 1 }) | from_entries) as $have
        | [ .[] | .port_id | select(. != "" and $have[.] == null) ] | unique[]' \
        "$WORK_DIR/fips.json" > "$dir/missing-ports"
    if [[ -s "$dir/missing-ports" ]]; then
        api_by_ids ports ports "$dir/missing-ports" "$dir/pm" > "$dir/pm-files" || return 1
        mapfile -t pf < "$dir/pm-files"
        if (( ${#pf[@]} > 0 )); then
            norm_merge port "$dir/extra-ports.json" "${pf[@]}"
            jq -s '[ .[][] ] | unique_by(.id)' "$WORK_DIR/ports.json" "$dir/extra-ports.json" > "$dir/ports.tmp"
            mv "$dir/ports.tmp" "$WORK_DIR/ports.json"
        fi
    fi
    return 0
}

# --- metode cli ---

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

# cli_list OUT ARGS... — "list" read-only; gagal = die (hasil tidak bisa dipercaya)
cli_list() {
    local out="$1" errf="$1.err"
    shift
    os_cli "$@" > "$out" 2>"$errf" || die "${*:1:3} gagal: $(last_error_line "$errf")"
    jq -e 'type == "array"' "$out" >/dev/null 2>&1 || die "Output ${*:1:3} tidak valid."
}

# show_merge KIND LISTJSON OUT CMD... — "show" per ID dari LISTJSON (ternormalisasi).
# Berhasil → data show; not found → dibuang; gagal → data list + _partial.
show_merge() {
    local kind="$1" list="$2" out="$3" dir="$WORK_DIR/show-${1// /-}" id gone=0 failed=0
    shift 3
    rm -rf "$dir"
    mkdir -p "$dir"

    jq -r '.[].id' "$list" | while IFS= read -r id; do is_uuidish "$id" && echo "$id"; done > "$dir/ids"
    parallel_show "$dir" "$kind show" "$@"

    : > "$dir/gone"
    : > "$dir/failed"
    while IFS= read -r id; do
        [[ -f "$dir/$id.json" ]] && continue
        if is_not_found "$dir/$id.err"; then
            gone=$(( gone + 1 ))
            echo "$id" >> "$dir/gone"
            log_event SKIPPED "resource=$id" "reason=$kind sudah tidak ada saat show"
        else
            failed=$(( failed + 1 ))
            echo "$id" >> "$dir/failed"
            log_warn -q "$kind show $id gagal: $(last_error_line "$dir/$id.err")"
        fi
    done < "$dir/ids"

    local norm="port"
    [[ "$kind" == "floating ip" ]] && norm="fip"
    jq -s "$JQ_NORM"" [ .[] | norm_$norm ]" "$dir"/*.json > "$dir/shown.json" 2>/dev/null || echo '[]' > "$dir/shown.json"
    jq --slurpfile s "$dir/shown.json" --rawfile g "$dir/gone" '
        ($s[0] | map({ key: .id, value: . }) | from_entries) as $m
        | ($g | split("\n") | map(select(length > 0)) | map({ key: ., value: 1 }) | from_entries) as $gone
        | [ .[] | if $m[.id] then $m[.id] elif $gone[.id] then empty else . + { _partial: true } end ]' \
        "$list" > "$out"

    if (( gone > 0 )); then
        NOTES+=("$gone $kind terhapus selama proses (dilewati)")
    fi
    if (( failed > 0 )); then
        PARTIAL=1
        warn "$failed $kind show gagal (data tidak lengkap)"
    fi
    return 0
}

# --deep dengan cli butuh "port show" untuk SEMUA port
confirm_deep_cli() {
    local n="$1" est answer
    est=$(( (n * 3 / 2 + PARALLEL - 1) / PARALLEL ))
    warn "--deep dengan metode cli: $n port akan di-'port show' satu per satu (paralel $PARALLEL, perkiraan ~$(( est / 60 )) menit $(( est % 60 )) detik)."
    if has_tty; then
        ask answer "Lanjutkan? [y/N]: "
        if ! is_yes "$(trim "$answer")"; then
            log_event DECISION deep_cli=declined "ports=$n"
            echo "Dibatalkan. Gunakan --method api atau jalankan tanpa --deep."
            exit 0
        fi
        log_event DECISION deep_cli=confirmed "ports=$n"
    fi
    return 0
}

fetch_cli() {
    local dir="$WORK_DIR/cli" i=0 ip n
    local -a ff=() pf=() ips=()
    rm -rf "$dir"
    mkdir -p "$dir"
    mapfile -t ips < <(jq -r '.[]' "$WORK_DIR/ips.json")

    if (( DEEP )) || [[ "$STRATEGY" == "bulk" ]]; then
        echo "  Mengambil semua port (port list --long) ..."
        cli_list "$dir/ports-all.json" port list --long -f json
        if (( DEEP )); then
            n="$(jq length "$dir/ports-all.json")"
            confirm_deep_cli "$n"
            pf+=("$dir/ports-all.json")
        else
            jq --slurpfile q "$WORK_DIR/ips.json" '
                ($q[0] | map({ key: ., value: 1 }) | from_entries) as $want
                | [ .[] | select(any((."Fixed IP Addresses" // .fixed_ips // [])
                                     | if type == "array" then .[] | (.ip_address // "" | ascii_downcase)
                                       else scan("ip_address=.([0-9A-Fa-f.:/]*).") | .[0] | ascii_downcase end;
                                     $want[.] != null)) ]' \
                "$dir/ports-all.json" > "$dir/ports-cand.json"
            pf+=("$dir/ports-cand.json")
        fi
    fi

    if [[ "$STRATEGY" == "bulk" ]]; then
        echo "  Mengambil semua floating IP (floating ip list --long) ..."
        cli_list "$dir/fips-all.json" floating ip list --long -f json
        # Kandidat: alamat floating == IP, atau terasosiasi ke IP itu (fixed)
        jq --slurpfile q "$WORK_DIR/ips.json" '
            ($q[0] | map({ key: ., value: 1 }) | from_entries) as $want
            | [ .[] | select($want[(."Floating IP Address" // .floating_ip_address // "" | ascii_downcase)] != null
                             or $want[(."Fixed IP Address" // .fixed_ip_address // "" | ascii_downcase)] != null) ]' \
            "$dir/fips-all.json" > "$dir/fips-cand.json"
        ff+=("$dir/fips-cand.json")
    else
        for ip in "${ips[@]}"; do
            i=$(( i + 1 ))
            [[ -t 1 ]] && printf '\r  [%d/%d] %s          ' "$i" "${#ips[@]}" "$ip"
            cli_list "$dir/fa-$i.json" floating ip list --floating-ip-address "$ip" --long -f json
            cli_list "$dir/fb-$i.json" floating ip list --fixed-ip-address "$ip" --long -f json
            ff+=("$dir/fa-$i.json" "$dir/fb-$i.json")
            if (( ! DEEP )); then
                cli_list "$dir/p-$i.json" port list --fixed-ip "ip-address=$ip" --long -f json
                pf+=("$dir/p-$i.json")
            fi
        done
        [[ -t 1 ]] && printf '\r%60s\r' ''
        echo "  Pencarian per IP (cli): ${#ips[@]} IP"
    fi

    norm_merge fip "$dir/fips-list.json" "${ff[@]}"
    norm_merge port "$dir/ports-list.json" "${pf[@]}"
    # Port dari floating IP kandidat yang belum ada di daftar (hanya ID)
    jq --slurpfile f "$dir/fips-list.json" '
        (map({ key: .id, value: 1 }) | from_entries) as $have
        | [ $f[0][] | .port_id | select(. != "" and $have[.] == null) ] | unique
        | map({ id: ., name: "", mac_address: "", status: "", network_id: "", project_id: "",
                device_owner: "", device_id: "", fixed_ips: [], allowed_address_pairs: [],
                created_at: "", updated_at: "" })' \
        "$dir/ports-list.json" > "$dir/ports-extra.json"
    jq -s '[ .[][] ] | unique_by(.id)' "$dir/ports-list.json" "$dir/ports-extra.json" > "$dir/ports-cand-all.json"

    show_merge "floating ip" "$dir/fips-list.json" "$WORK_DIR/fips.json" "${OS_CMD[@]}" floating ip show
    show_merge port "$dir/ports-cand-all.json" "$WORK_DIR/ports.json" "${OS_CMD[@]}" port show
    return 0
}

choose_strategy() {
    local why
    if [[ "$STRATEGY_ENV" != "auto" ]]; then
        STRATEGY="$STRATEGY_ENV"
        why="OSOPS_IPINFO_STRATEGY"
    elif (( N_VALID > PER_IP_MAX )); then
        STRATEGY="bulk"
        why="$N_VALID IP > $PER_IP_MAX"
    else
        STRATEGY="per-ip"
        why="$N_VALID IP <= $PER_IP_MAX"
    fi
    log_event STRATEGY "strategy=$STRATEGY" "reason=$why" "deep=$DEEP"
    return 0
}

fetch_data() {
    case "$METHOD" in
        api)
            fetch_api || die "Metode api gagal: $API_REASON"
            USED_METHOD="api"
            ;;
        cli)
            USED_METHOD="cli"
            fetch_cli
            ;;
        auto)
            if fetch_api; then
                USED_METHOD="api"
            else
                USED_METHOD="cli"
                NOTES+=("fallback ke cli: $API_REASON")
                warn "Metode api tidak bisa dipakai ($API_REASON); fallback ke cli."
                fetch_cli
            fi
            ;;
    esac
    log_event METHOD "method=$USED_METHOD" "strategy=$STRATEGY" \
        "fips=$(jq length "$WORK_DIR/fips.json")" "ports=$(jq length "$WORK_DIR/ports.json")"
    return 0
}

# ============================================================
# 4. Pencocokan (jq): satu program untuk semua strategi/metode
# ============================================================

# Hasil mentah per query: {q, ip, matches: [{type, fip, port, fixed_ip, subnet, pool}]}
# shellcheck disable=SC2016  # program jq, bukan ekspansi shell
JQ_MATCH='
$fips[0] as $F | $ports[0] as $P | $subnets[0] as $S
| ($P | map({ key: .id, value: . }) | from_entries) as $pid
| (reduce $P[] as $p ({}; reduce ($p.fixed_ips[].ip_address) as $a (.; .[$a] += [ $p.id ]))) as $byfixed
| (reduce $F[] as $f ({}; .[$f.floating_ip_address] += [ $f ])) as $byaddr
| (reduce $F[] as $f ({}; if $f.port_id != "" then .["\($f.port_id)|\($f.fixed_ip_address)"] += [ $f ] else . end)) as $byportip
| (if $deep then
     reduce $P[] as $p ({}; reduce ($p.allowed_address_pairs[].ip_address | select(contains("/") | not)) as $a
                              (.; .[$a] += [ $p.id ]))
   else {} end) as $byaap
| (if $deep then [ $P[] | select(any(.allowed_address_pairs[]; .ip_address | contains("/"))) ] else [] end) as $aapcidr
| def partial_or($v; $want): $v == $want or ((._partial // false) and $v == "");
  def port_ok: ($net == "" or partial_or(.network_id; $net)) and ($proj == "" or partial_or(.project_id; $proj));
  def fip_ok: ($net == "" or .floating_network_id == $net or (($pid[.port_id].network_id // "") == $net))
              and ($proj == "" or .project_id == $proj);
  def aap_hit($ip): .ip_address == $ip or ((.ip_address | contains("/")) and (.ip_address | cidr4_contains($ip)));
  def fip_for($p; $ip): ($byportip["\($p.id)|\($ip)"] // [])[0];
  [ $queries[0][]
    | . as $qq
    | if ($qq.valid | not) then { q: $qq.q, ip: "", matches: [ { type: "INVALID" } ] }
      else $qq.ip as $ip
      | [ ($byaddr[$ip] // [])[] | select(fip_ok) ] | sort_by(.id) as $fm
      | ($fm | map(.id)) as $fmids
      | [ ($byfixed[$ip] // []) | unique[] | $pid[.]
          | select(port_ok)
          # Port internal milik floating IP yang sudah cocok (device_owner network:floatingip)
          | select((.device_owner == "network:floatingip" and (.device_id as $d | $fmids | index($d) != null)) | not) ]
        | sort_by(.project_id, .id) as $pm
      | (if $deep then
           [ (($byaap[$ip] // []) | unique[] | $pid[.]),
             ($aapcidr[] | select(any(.allowed_address_pairs[]; aap_hit($ip)))) ]
           | unique_by(.id) | map(select(port_ok)) | sort_by(.project_id, .id)
         else [] end) as $am
      | [ ($fm[] | { type: "FLOATING_IP", fip: .,
                     port: (if .port_id == "" then null else ($pid[.port_id] // { id: .port_id, _missing: true }) end),
                     fixed_ip: .fixed_ip_address }),
          ($pm[] | { type: "FIXED_IP", port: ., fixed_ip: $ip, fip: fip_for(.; $ip) }),
          ($am[] | { type: "ALLOWED_ADDRESS_PAIR", port: .,
                     fixed_ip: ([ .allowed_address_pairs[] | select(aap_hit($ip)) ][0].ip_address),
                     fip: fip_for(.; $ip) }) ] as $m
      | if ($m | length) > 0 then { q: $qq.q, ip: $ip, matches: $m }
        else
          [ $S[] | select(.cidr | cidr4_contains($ip))
                 | select($net == "" or .network_id == $net) | select($proj == "" or .project_id == $proj) ]
          | sort_by(.project_id, .id) as $sm
          | if ($sm | length) > 0 then
              { q: $qq.q, ip: $ip, matches: [ $sm[] | { type: "SUBNET_ONLY", subnet: .,
                  pool: (if .gateway_ip == $ip then "No port (subnet gateway IP)"
                         elif (.allocation_pools | in_pools($ip)) then "No port (in allocation pool)"
                         else "No port (outside allocation pool)" end) } ] }
            else { q: $qq.q, ip: $ip, matches: [ { type: "NOT_FOUND" } ] } end
        end
      end ]
'

run_match() {
    jq -n --slurpfile queries "$WORK_DIR/queries.json" --slurpfile fips "$WORK_DIR/fips.json" \
        --slurpfile ports "$WORK_DIR/ports.json" --slurpfile subnets "$WORK_DIR/subnets.json" \
        --arg net "$NET_ID" --arg proj "$PROJ_ID" --argjson deep "$( (( DEEP )) && echo true || echo false)" \
        "$NETINFO_JQ$JQ_MATCH" > "$WORK_DIR/matches.json" || die "Pencocokan data gagal (jq)."
    return 0
}

# ============================================================
# 5. Resolve device: instance, router, load balancer
# ============================================================

device_ids() {
    jq -r --arg kind "$1" '
        [ .[].matches[] | .port // empty | select((._partial // false) | not)
          | select(.device_id != "")
          | if $kind == "server" then select(.device_owner | startswith("compute:"))
            elif $kind == "router" then select(.device_owner | IN("network:router_gateway", "network:router_interface",
                     "network:router_interface_distributed", "network:ha_router_replicated_interface"))
            else select(.device_owner == "Octavia") | .device_id |= ltrimstr("lb-") end
          | .device_id ] | unique[]' "$WORK_DIR/matches.json"
}

resolve_servers() {
    local map="$WORK_DIR/servers.json" dir="$WORK_DIR/servers" errf id
    local -a ids=()
    echo '{}' > "$map"
    mapfile -t ids < <(device_ids server)
    (( ${#ids[@]} > 0 )) || return 0

    if (( ${#ids[@]} <= SERVER_SHOW_MAX )); then
        mkdir -p "$dir"
        for id in "${ids[@]}"; do is_uuidish "$id" && echo "$id"; done > "$dir/ids"
        log_event INSTANCE_LOOKUP method=server-show "count=${#ids[@]}"
        parallel_show "$dir" "server show" "${OS_CMD[@]}" --os-compute-api-version "$COMPUTE_API_VERSION" server show
        for id in "${ids[@]}"; do
            if [[ -f "$dir/$id.json" ]]; then
                jq --arg i "$id" --slurpfile s "$dir/$id.json" '.[$i] = ($s[0] | {
                        name: (.name // .Name // ""), status: (.status // .Status // ""),
                        host: (."OS-EXT-SRV-ATTR:host" // .compute_host // .host // .Host // "") })' \
                    "$map" > "$map.tmp" && mv "$map.tmp" "$map"
            elif ! is_not_found "$dir/$id.err"; then
                SERVERS_STATE="fail"
                PARTIAL=1
                log_warn -q "server show $id gagal: $(last_error_line "$dir/$id.err")"
            fi
        done
        [[ "$SERVERS_STATE" == "fail" ]] && warn "Sebagian lookup instance gagal (lihat log)."
    else
        errf="$WORK_DIR/servers.err"
        log_event INSTANCE_LOOKUP method=server-list "count=${#ids[@]}"
        echo "  server list --all-projects ..."
        # Tanpa --limit: OSC/SDK mengikuti semua halaman (--limit mematikan pagination)
        if os_compute server list --all-projects --long -n -f json -c ID -c Name -c Status -c Host \
                > "$WORK_DIR/servers.raw" 2>"$errf" &&
                jq '[ .[] | { key: (.ID // .id), value: { name: (.Name // .name // ""), status: (.Status // .status // ""),
                                                          host: (.Host // .host // "") } } ] | from_entries' \
                    "$WORK_DIR/servers.raw" > "$map" 2>/dev/null; then
            log_result resource=servers action=lookup result=SUCCESS "count=$(jq length "$map")"
        else
            SERVERS_STATE="fail"
            PARTIAL=1
            echo '{}' > "$map"
            warn "server list --all-projects gagal: $(last_error_line "$errf")"
            log_result resource=servers action=lookup result=FAILED "msg=$(last_error_line "$errf")"
        fi
    fi
    return 0
}

resolve_routers() {
    echo '{}' > "$WORK_DIR/routers.json"
    [[ -n "$(device_ids router)" ]] || return 0
    load_map routers ROUTERS_STATE '{}' \
        '[ .[] | { key: (.ID // .id), value: (.Name // .name // "") } ] | from_entries' \
        router list -f json
}

# Plugin Octavia opsional: tanpa plugin nama port dipakai (berisi ID load balancer)
resolve_lbs() {
    local map="$WORK_DIR/lbs.json" dir="$WORK_DIR/lbs" id
    local -a ids=()
    echo '{}' > "$map"
    mapfile -t ids < <(device_ids lb)
    (( ${#ids[@]} > 0 )) || return 0

    if ! os_cli loadbalancer show --help >/dev/null 2>&1; then
        NOTES+=("plugin Octavia (loadbalancer) tidak tersedia; nama port dipakai sebagai nama load balancer")
        log_event LB_LOOKUP plugin=no "count=${#ids[@]}"
        return 0
    fi
    log_event LB_LOOKUP plugin=yes "count=${#ids[@]}"
    mkdir -p "$dir"
    for id in "${ids[@]}"; do is_uuidish "$id" && echo "$id"; done > "$dir/ids"
    parallel_show "$dir" "loadbalancer show" "${OS_CMD[@]}" loadbalancer show
    for id in "${ids[@]}"; do
        if [[ -f "$dir/$id.json" ]]; then
            jq --arg i "$id" --slurpfile s "$dir/$id.json" '.[$i] = ($s[0].name // "")' "$map" > "$map.tmp" && mv "$map.tmp" "$map"
        elif ! is_not_found "$dir/$id.err"; then
            log_warn -q "loadbalancer show $id gagal: $(last_error_line "$dir/$id.err")"
        fi
    done
    return 0
}

# ============================================================
# 6. Hasil: record per kecocokan (field string, sama untuk terminal dan CSV)
# ============================================================

# shellcheck disable=SC2016  # program jq, bukan ekspansi shell
JQ_ENRICH='
$networks[0] as $N | $projects[0] as $PR | $domains[0] as $D | $servers[0] as $SV
| $routers[0] as $R | $lbs[0] as $LB
| ($subnets[0] | map({ key: .id, value: . }) | from_entries) as $SB
| def lf($state): if $state == "fail" then "(lookup failed)" else "(not found)" end;
  def netname($id): if $id == "" then "" else ($N[$id] // lf($st.networks)) end;
  def proj($id):
    if $id == "" then { id: "", name: "", domain: "" }
    elif $PR[$id] != null then $PR[$id] as $p
      | { id: $id, name: $p.name,
          domain: (if $p.domain_id == "" then "" else ($D[$p.domain_id] // lf($st.domains)) end) }
    else { id: $id, name: lf($st.projects), domain: lf($st.projects) } end;
  def subnet_of($p; $ip):
    ([ $p.fixed_ips[]? | select(.ip_address == $ip) ][0].subnet_id)
    // ([ $p.fixed_ips[]? | .subnet_id | select(($SB[.].cidr // "") | cidr4_contains($ip)) ][0])
    // ($p.fixed_ips[0].subnet_id) // "";
  def device($p):
    if $p == null then { type: "Not associated", id: "", name: "", host: "", status: "" }
    elif ($p._missing // false) then { type: "(port not found)", id: "", name: "", host: "", status: "" }
    elif ($p._partial // false) and $p.device_id == "" then
      { type: (if $p.device_owner == "" then "(lookup failed)" else device_type($p.device_owner; "") end),
        id: "", name: "(lookup failed)", host: "", status: "" }
    else $p.device_owner as $o | $p.device_id as $d
      | if ($o | startswith("compute:")) then ($SV[$d] // null) as $s
          | { type: device_type($o; ($s.name // "")), id: $d,
              name: (if $s != null then $s.name elif $d == "" then "" else lf($st.servers) end),
              host: ($s.host // ""), status: ($s.status // "") }
        elif ($o | IN("network:router_gateway", "network:router_interface",
                      "network:router_interface_distributed", "network:ha_router_replicated_interface")) then
          { type: device_type($o; ""), id: $d,
            name: (if $d == "" then "" else ($R[$d] // lf($st.routers)) end), host: "", status: "" }
        elif $o == "Octavia" then
          { type: device_type($o; ""), id: $d, name: ($LB[$d | ltrimstr("lb-")] // $p.name), host: "", status: "" }
        else { type: device_type($o; ""), id: $d, name: "", host: "", status: "" } end
    end;
  def portside($p; $ip):
    if $p == null then { port_id: "", port_name: "", mac: "", port_status: "", network_id: "", subnet_id: "" }
    else subnet_of($p; $ip) as $sid
      | { port_id: $p.id, port_name: ($p.name // ""), mac: ($p.mac_address // ""), port_status: ($p.status // ""),
          network_id: ($p.network_id // ""), subnet_id: $sid } end;
  def fipside($f):
    if $f == null then { fip_id: "", fip: "", fip_status: "", fip_network: "" }
    else { fip_id: $f.id, fip: $f.floating_ip_address, fip_status: $f.status,
           fip_network: netname($f.floating_network_id) } end;
  def finish:
    . + { network_name: netname(.network_id), subnet_cidr: (if .subnet_id == "" then "" else ($SB[.subnet_id].cidr // "") end) }
    | . + (proj(.project_id) | { project_name: .name, domain_name: .domain });
  def empty_rec($q; $t):
    { query: $q, match_type: $t, device_type: "", device_id: "", device_name: "", compute_host: "", device_status: "",
      port_id: "", port_name: "", mac: "", port_status: "", network_id: "", network_name: "", subnet_id: "",
      subnet_cidr: "", fixed_ip: "", fip_id: "", fip: "", fip_status: "", fip_network: "",
      project_id: "", project_name: "", domain_name: "", created_at: "", updated_at: "", incomplete: false };
  [ .[] | . as $r | (if $r.ip == "" then $r.q else $r.ip end) as $q
    | { query: $q, matches: [ $r.matches[] | . as $m
        | if $m.type == "FLOATING_IP" then
            device($m.port) as $dv
            | empty_rec($q; $m.type) + portside($m.port; ($m.fixed_ip // "")) + fipside($m.fip)
              + { device_type: $dv.type, device_id: $dv.id, device_name: $dv.name, compute_host: $dv.host,
                  device_status: $dv.status, fixed_ip: ($m.fixed_ip // ""), project_id: $m.fip.project_id,
                  created_at: $m.fip.created_at, updated_at: $m.fip.updated_at,
                  incomplete: (($m.fip._partial // false) or ($m.port._partial // false)) }
            # Floating IP tanpa port: Network Name = network floating IP
            | if $m.port == null then .network_id = $m.fip.floating_network_id else . end
            | finish
          elif ($m.type == "FIXED_IP" or $m.type == "ALLOWED_ADDRESS_PAIR") then
            device($m.port) as $dv
            | empty_rec($q; $m.type) + portside($m.port; $r.ip) + fipside($m.fip)
              + { device_type: $dv.type, device_id: $dv.id, device_name: $dv.name, compute_host: $dv.host,
                  device_status: $dv.status, fixed_ip: ($m.fixed_ip // ""), project_id: $m.port.project_id,
                  created_at: $m.port.created_at, updated_at: $m.port.updated_at,
                  incomplete: (($m.port._partial // false) or ($m.fip._partial // false)) }
            | finish
          elif $m.type == "SUBNET_ONLY" then
            empty_rec($q; $m.type)
              + { device_type: $m.pool, network_id: $m.subnet.network_id, subnet_id: $m.subnet.id,
                  project_id: $m.subnet.project_id }
            | finish
          elif $m.type == "NOT_FOUND" then
            empty_rec($q; $m.type) + { incomplete: ($st.subnets == "fail") }
          else empty_rec($q; $m.type) end ] } ]
'

run_enrich() {
    local st
    st="$(jq -n --arg n "$NETWORKS_STATE" --arg p "$PROJECTS_STATE" --arg d "$DOMAINS_STATE" \
        --arg s "$SUBNETS_STATE" --arg r "$ROUTERS_STATE" --arg v "$SERVERS_STATE" \
        '{ networks: $n, projects: $p, domains: $d, subnets: $s, routers: $r, servers: $v }')"
    jq --slurpfile networks "$WORK_DIR/networks.json" --slurpfile projects "$WORK_DIR/projects.json" \
        --slurpfile domains "$WORK_DIR/domains.json" --slurpfile servers "$WORK_DIR/servers.json" \
        --slurpfile routers "$WORK_DIR/routers.json" --slurpfile lbs "$WORK_DIR/lbs.json" \
        --slurpfile subnets "$WORK_DIR/subnets.json" --argjson st "$st" \
        "$NETINFO_JQ$JQ_ENRICH" "$WORK_DIR/matches.json" > "$WORK_DIR/results.json" || \
        die "Menyusun hasil gagal (jq)."
    return 0
}

# ============================================================
# 7. Output terminal, CSV, ringkasan, log
# ============================================================

# shellcheck disable=SC2016  # program jq, bukan ekspansi shell
JQ_PRINT='
def v: if . == null or . == "" then "-" else . end;
def line($k; $v): "      \($k + (" " * (13 - ($k | length)))): \($v)";
def withid($name; $id): if $id == "" then ($name | v) elif ($name // "") == "" then $id else "\($name) (\($id))" end;
.[] | . as $r | ($r.matches | length) as $n | $r.matches[0].match_type as $t0
| "",
  (if $t0 == "INVALID" then "\($b)━━ \($r.query)\($x) — format IP tidak valid (INVALID)"
   elif $t0 == "NOT_FOUND" then "\($b)━━ \($r.query)\($x) — tidak ditemukan (NOT_FOUND)"
     + (if $r.matches[0].incomplete then "  ⚠️  daftar subnet gagal diambil" else "" end)
   elif $t0 == "SUBNET_ONLY" then "\($b)━━ \($r.query)\($x) — tidak ada port; IP berada di \($n) subnet"
   else "\($b)━━ \($r.query)\($x) — \($n) kecocokan" end),
  ( $r.matches | to_entries[] | .key as $i | .value as $m
    | select($m.match_type | IN("INVALID", "NOT_FOUND") | not)
    | "  [\($i + 1)] \($m.match_type) · \($m.device_type | v)"
        + (if $m.incomplete then "  ⚠️  data tidak lengkap (lookup gagal)" else "" end),
      (if $m.match_type == "SUBNET_ONLY" then
         line("Subnet"; withid($m.subnet_cidr; $m.subnet_id)),
         line("Network"; withid($m.network_name; $m.network_id))
       else
         line("Device"; withid($m.device_name; $m.device_id)),
         (if $m.compute_host != "" or $m.device_status != "" then
            line("Host"; "\($m.compute_host | v)  (status \($m.device_status | v))") else empty end),
         line("Port"; "\($m.port_id | v)  name=\($m.port_name | v)  status=\($m.port_status | v)  mac=\($m.mac | v)"),
         line("Network"; withid($m.network_name; $m.network_id) + "  subnet=\($m.subnet_cidr | v)"),
         line(if $m.match_type == "ALLOWED_ADDRESS_PAIR" then "Addr. pair" else "Fixed IP" end; $m.fixed_ip | v),
         line("Floating IP"; if $m.fip == "" then "-"
              else "\($m.fip)  status=\($m.fip_status | v)  id=\($m.fip_id)  network=\($m.fip_network | v)" end)
       end),
      line("Project"; withid($m.project_name; $m.project_id) + "  domain=\($m.domain_name | v)"),
      (if $m.created_at != "" or $m.updated_at != "" then
         line("Created"; "\($m.created_at | v)  updated=\($m.updated_at | v)") else empty end) )
'

print_results() {
    jq -r --arg b "$C_BOLD" --arg x "$C_RESET" "$JQ_PRINT" "$WORK_DIR/results.json"
}

CSV_HEADER="Query IP,Match Type,Device Type,Device ID,Device Name,Compute Host,Port ID,MAC Address,Port Status,Network Name,Subnet CIDR,Fixed IP,Floating IP ID,Floating IP,Floating IP Status,Project ID,Project Name,Domain Name,Created At,Updated At"

# Satu baris per kecocokan, urutan input. Permission 600, tidak menimpa file.
write_csv() {
    local ts base i=1
    jq -r '.[].matches[]
        | [ .query, .match_type, .device_type, .device_id, .device_name, .compute_host, .port_id, .mac,
            .port_status, .network_name, .subnet_cidr, .fixed_ip, .fip_id, .fip, .fip_status,
            .project_id, .project_name, .domain_name, .created_at, .updated_at ]
        | map(. // "" | tostring) | @csv' "$WORK_DIR/results.json" > "$WORK_DIR/rows.csv" || return 1

    ts="$(date +%Y%m%d-%H%M%S)"
    base="$OUTPUT_DIR/ip-info-$ts"
    CSV_FILE="$base.csv"
    while [[ -e "$CSV_FILE" ]]; do
        i=$(( i + 1 ))
        CSV_FILE="$base-$i.csv"
    done

    # umask 077 + noclobber: file baru dengan permission 600, file lama tidak ditimpa
    if ! ( umask 077; set -o noclobber
           { printf '%s\n' "$CSV_HEADER"; cat "$WORK_DIR/rows.csv"; } > "$CSV_FILE" ) 2>"$WORK_DIR/csv.err"; then
        warn "Gagal menulis $CSV_FILE: $(last_error_line "$WORK_DIR/csv.err")"
        CSV_FILE=""
        return 1
    fi
    chmod 600 "$CSV_FILE" 2>/dev/null || true
    return 0
}

# log_result per IP: SUCCESS (lookup selesai, apa pun hasilnya), SKIPPED (INVALID),
# FAILED (data tidak lengkap)
log_per_ip() {
    local q res n types
    while IFS="$US" read -r q res n types; do
        if [[ "$res" == "SKIPPED" ]]; then
            log_result "resource=$q" action=lookup result=SKIPPED "reason=format IP tidak valid"
        else
            log_result "resource=$q" action=lookup "result=$res" "matches=$n" "types=$types"
        fi
    done < <(jq -r '.[] | [ .query,
            (if .matches[0].match_type == "INVALID" then "SKIPPED"
             elif any(.matches[]; .incomplete) then "FAILED" else "SUCCESS" end),
            ([ .matches[] | select(.match_type | IN("FLOATING_IP", "FIXED_IP", "ALLOWED_ADDRESS_PAIR")) ] | length | tostring),
            ([ .matches[].match_type ] | unique | join(",")) ] | join("\u001f")' "$WORK_DIR/results.json")
    return 0
}

TYPES=(FLOATING_IP FIXED_IP ALLOWED_ADDRESS_PAIR SUBNET_ONLY NOT_FOUND INVALID)

print_summary() {
    local dur="$1" t c stats total_matches show=0 note deep_txt=""
    (( DEEP )) && deep_txt=" (--deep)"
    local -a kv=()

    stats="$(jq -r '[ ($ARGS.positional[] as $t | [ .[] | select(any(.matches[]; .match_type == $t)) ] | length),
                      ([ .[].matches[] | select(.match_type | IN("FLOATING_IP", "FIXED_IP", "ALLOWED_ADDRESS_PAIR")) ] | length) ]
                    | map(tostring) | join(" ")' "$WORK_DIR/results.json" --args "${TYPES[@]}")"
    read -ra kv <<< "$stats"
    total_matches="${kv[${#TYPES[@]}]}"

    (( SINGLE == 0 )) && show=1
    if (( show )); then
        echo
        echo "========================================"
        echo "${C_BOLD}Ringkasan ($REGION)${C_RESET}"
        printf '  %-22s : %s\n' "IP dicari" "$(( N_VALID + N_INVALID )) (valid $N_VALID, invalid $N_INVALID, duplikat $N_DUP)"
        for t in "${!TYPES[@]}"; do
            [[ "${TYPES[$t]}" == "ALLOWED_ADDRESS_PAIR" ]] && (( ! DEEP )) && continue
            printf '  %-22s : %s IP\n' "${TYPES[$t]}" "${kv[$t]}"
        done
        printf '  %-22s : %s\n' "Total kecocokan" "$total_matches"
        printf '  %-22s : %s\n' "Strategi / metode" "$STRATEGY / $USED_METHOD$deep_txt"
        printf '  %-22s : %ss\n' "Durasi" "$dur"
    fi
    if (( CSV )); then
        echo
        printf '  %-22s : %s\n' "File CSV" "${CSV_FILE:-(gagal ditulis)}"
    fi
    for note in "${NOTES[@]}"; do
        note "$note"
    done
    if (( PARTIAL )); then
        echo "${C_RED}❌ Sebagian lookup gagal: hasil tidak lengkap (lihat log).${C_RESET}"
    else
        echo "${C_GREEN}✅ Selesai${C_RESET}"
    fi

    local -a counts=()
    for t in "${!TYPES[@]}"; do
        c="${TYPES[$t],,}"
        counts+=("$c=${kv[$t]}")
    done
    log_event SUMMARY "ips=$(( N_VALID + N_INVALID ))" "valid=$N_VALID" "invalid=$N_INVALID" "duplicate=$N_DUP" \
        "${counts[@]}" "matches=$total_matches" "strategy=$STRATEGY" "method=$USED_METHOD" "deep=$DEEP" \
        "partial=$PARTIAL" "duration=${dur}s" "csv=${CSV_FILE:--}"
    return 0
}

main() {
    local start=$SECONDS rc=0 t0

    parse_args "$@"
    require_deps

    echo "========================================"
    echo "            IP Information"
    echo "========================================"

    log_event OPTIONS "os_cmd=${OS_CMD[*]}" "curl=$API_CURL" "compute_api=$COMPUTE_API_VERSION" \
        "per_ip_max=$PER_IP_MAX" "strategy_env=$STRATEGY_ENV"

    LOG_EXIT_HOOK=on_exit
    make_work_dir
    detect_region
    choose_input
    build_queries

    if (( N_VALID > 0 )); then
        load_lookups
        resolve_filters
        choose_strategy
        if (( DEEP )); then echo "Strategi: $STRATEGY + --deep"; else echo "Strategi: $STRATEGY"; fi
        fetch_data
    else
        STRATEGY="-"
        USED_METHOD="-"
        echo '[]' > "$WORK_DIR/fips.json"
        echo '[]' > "$WORK_DIR/ports.json"
        echo '[]' > "$WORK_DIR/subnets.json"
        for t0 in networks projects domains; do echo '{}' > "$WORK_DIR/$t0.json"; done
    fi

    run_match
    resolve_servers
    resolve_routers
    resolve_lbs
    run_enrich

    print_results
    if (( CSV )); then
        write_csv || PARTIAL=1
    fi
    log_per_ip
    print_summary "$(( SECONDS - start ))"
    echo
    echo "Log : ${LOG_FILE:-(logging nonaktif)}"

    (( PARTIAL )) && rc=1
    if (( SINGLE )); then
        t0="$(jq -r '.[0].matches[0].match_type' "$WORK_DIR/results.json")"
        [[ "$t0" == "NOT_FOUND" || "$t0" == "INVALID" ]] && rc=1
    fi
    exit "$rc"
}

main "$@"
