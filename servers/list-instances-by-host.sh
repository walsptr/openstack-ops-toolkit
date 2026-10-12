#!/bin/bash
# ============================================================
# @name:        List Instances by Host
# @description: Export instances on selected compute hosts to CSV (for maintenance notice)
# @mutates:     no
# @requires:    admin, jq
# @tags:        nova, compute, host, maintenance, report, csv
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: list-instances-by-host.sh [--host HOST]... [--extended] [--output-dir PATH]
                                 [--method auto|api|cli] [--parallel N]

Daftar SEMUA instance (semua project) di compute host pilihan beserta pemiliknya
(project dan domain), untuk persiapan maintenance / notifikasi customer.
Read-only: tidak ada migrasi dan tidak ada resource yang diubah.

Per host ditulis dua file:
  <output-dir>/instances-<host>-<YYYYmmdd-HHMMSS>.csv   (permission 600)
  <output-dir>/instances-<host>-<YYYYmmdd-HHMMSS>.ids   daftar Instance ID,
      langsung bisa dipakai: servers/live-migrate.sh --file <file .ids>

Opsi:
  --host HOST        Compute host (bisa diulang; melewati picker). Harus ada di
                     daftar nova-compute; host yang tidak dikenal dilewati.
  --extended         Kolom tambahan: Status, Power State, Flavor, vCPU, RAM (MB),
                     IP Addresses, Availability Zone
  --output-dir PATH  Direktori output (default /tmp; harus sudah ada)
  --method M         auto (default) | api | cli
                       auto: tanpa --extended "server list" (sudah lengkap),
                             dengan --extended api; jika api gagal cli
                       api : Nova API (curl), host disaring di server
                       cli : "server show" per instance, paralel
  --parallel N       Jumlah proses paralel untuk metode cli (default 8, 1-64)
  -h, --help         Tampilkan help

Tanpa --host, host dipilih interaktif (fzf multi-select, fallback menu
bernomor) dan kolom tambahan ditanyakan. Tanpa terminal (cron), --host wajib.

Environment:
  OSOPS_OS_CMD                  Perintah OpenStack CLI (default: openstack)
  OSOPS_CURL                    Perintah curl (default: curl; opsional, metode api)
  OSOPS_FZF                     Perintah fzf (default: fzf; tidak ada = menu bernomor)
  OSOPS_COMPUTE_API_VERSION     Compute microversion (default 2.47: flavor tertanam)
  OSOPS_SERVER_PAGE_LIMIT       Ukuran halaman Nova API (default kosong = default server)
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

HOST_ARGS=()
EXTENDED=""          # "" = belum ditentukan | 0 | 1
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

FZF="${OSOPS_FZF:-fzf}"
# 2.47: detail flavor (vcpus, ram, original_name) tertanam di setiap server,
# tanpa lookup flavor (yang gagal untuk flavor yang sudah dihapus)
COMPUTE_API_VERSION="${OSOPS_COMPUTE_API_VERSION:-2.47}"
COMPUTE_MAX=""
FLAVOR_EMBEDDED=1
PAGE_LIMIT="${OSOPS_SERVER_PAGE_LIMIT:-}"

REGION="-"
AUTH_HOST="-"
WORK_DIR=""
XARGS_PID=""
US=$'\x1f'

# nova-compute: array JSON {host, zone, status, state, reason}
SVC_JSON="[]"
SEL_HOSTS=()
PICKED_INTERACTIVE=0

# Lookup bersama (sekali per run)
ALL_SERVERS_STATE=""   # "" | ok | fail — "server list" seluruh cloud
ALL_SERVERS_ERR=""
PROJECTS_STATE=""      # "" | ok | fail
DOMAINS_STATE=""       # "" | ok | fail
FLOATS_STATE=""        # "" | ok | fail

# Hasil per host
H_METHOD=""
H_NOTES=()
H_FAILED=0
H_FAIL_MSG=""
CSV_FILE=""
IDS_FILE=""
S_TOTAL=0
S_ORPHAN=0

ALL_RESULTS=()
ANY_FAILED=0
GRAND_TOTAL=0
GRAND_ORPHAN=0
GRAND_PROJECTS_FILE=""

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
    [[ "${1,,}" == "y" || "${1,,}" == "yes" ]]
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

# Nama host aman sebagai nama file
safe_name() {
    local s="$1"
    s="${s//[^A-Za-z0-9._-]/_}"
    s="${s#.}"
    printf '%s' "${s:-host}"
}

# mv_ge A B => true jika microversion A >= B
mv_ge() {
    local a_maj="${1%%.*}" a_min="${1#*.}" b_maj="${2%%.*}" b_min="${2#*.}"
    (( a_maj > b_maj || (a_maj == b_maj && a_min >= b_min) ))
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
            --host)       need_value "$1" "${2:-}"; HOST_ARGS+=("$2"); shift 2 ;;
            --extended)   EXTENDED=1; shift ;;
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
        die "OSOPS_SERVER_PAGE_LIMIT harus angka > 0 (dapat: $PAGE_LIMIT)."
    [[ "$COMPUTE_API_VERSION" =~ ^2\.[0-9]+$ ]] || \
        die "OSOPS_COMPUTE_API_VERSION tidak valid: $COMPUTE_API_VERSION"

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

# Maksimum compute microversion cloud. Di bawah versi yang di-pin (2.47):
# pakai 2.1, kolom Flavor berisi flavor ID dan vCPU/RAM kosong.
check_microversion() {
    local json
    if json="$(os_cli versions show --service compute -f json 2>/dev/null)"; then
        COMPUTE_MAX="$(jq -r '[ .[] | select((.Status // "" | ascii_upcase) == "CURRENT")
                                     | ."Max Microversion" // empty | tostring ] | first // empty' <<< "$json" 2>/dev/null)" || COMPUTE_MAX=""
    fi
    if [[ "$COMPUTE_MAX" =~ ^2\.[0-9]+$ ]] && ! mv_ge "$COMPUTE_MAX" "$COMPUTE_API_VERSION"; then
        warn "Compute API maksimum $COMPUTE_MAX < $COMPUTE_API_VERSION: memakai 2.1 (kolom Flavor berisi flavor ID, vCPU/RAM kosong)."
        COMPUTE_API_VERSION="2.1"
    fi
    mv_ge "$COMPUTE_API_VERSION" 2.47 || FLAVOR_EMBEDDED=0
    log_event MICROVERSION "compute_max=${COMPUTE_MAX:--}" "used=$COMPUTE_API_VERSION" "flavor_embedded=$FLAVOR_EMBEDDED"
    return 0
}

make_work_dir() {
    WORK_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/list-instances-by-host.XXXXXX")" || \
        die "Gagal membuat direktori sementara di ${TMPDIR:-/tmp}."
    API_WORK_DIR="$WORK_DIR"
    GRAND_PROJECTS_FILE="$WORK_DIR/grand-projects.txt"
    : > "$GRAND_PROJECTS_FILE"
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
# 1. Compute host
# ============================================================

# Semua nova-compute, TANPA filter status (host maintenance sering disabled/down)
list_hosts() {
    local json errf="$WORK_DIR/svc.err"
    json="$(os_cli compute service list --service nova-compute --long -f json 2>"$errf")" || \
        die "Gagal mengambil daftar compute service: $(last_error_line "$errf")"
    SVC_JSON="$(jq -c '[ .[] | { host: (.Host // .host // ""), zone: (.Zone // .zone // "-"),
                                  status: (.Status // .status // "-"), state: (.State // .state // "-"),
                                  reason: ((."Disabled Reason" // .disabled_reason // "") | tostring) } ]
                        | map(select(.host != "")) | unique_by(.host) | sort_by(.host | ascii_downcase)' \
                    <<< "$json" 2>/dev/null)" || die "Output compute service list tidak bisa diparse."
    [[ "$SVC_JSON" != "[]" ]] || die "Tidak ada service nova-compute di region ini."
    return 0
}

svc_field() {
    jq -r --arg h "$1" --arg f "$2" '[ .[] | select(.host == $h) ][0][$f] // "-"' <<< "$SVC_JSON"
}

# --host: nama persis, atau nama pendek (sebelum titik pertama) yang cocok dengan
# tepat satu host. Tidak dikenal/ambigu → dilewati dengan pesan.
resolve_host_args() {
    local arg m n h
    local -A seen=()

    for arg in "${HOST_ARGS[@]}"; do
        m="$(jq -c --arg a "$arg" '[ .[] | select(.host == $a) ] as $x
                                   | if ($x | length) > 0 then $x
                                     else [ .[] | select((.host | split(".")[0]) == ($a | split(".")[0])) ] end' <<< "$SVC_JSON")"
        n="$(jq 'length' <<< "$m")"
        if (( n == 0 )); then
            warn "Host '$arg' tidak ada di daftar nova-compute; dilewati."
            log_result "resource=$arg" action=list-instances-by-host result=SKIPPED "msg=bukan host nova-compute"
            ALL_RESULTS+=("$arg|SKIPPED|0|0|-")
            continue
        fi
        if (( n > 1 )); then
            warn "Host '$arg' ambigu ($(jq -r '[ .[].host ] | join(", ")' <<< "$m")); gunakan nama lengkap. Dilewati."
            log_result "resource=$arg" action=list-instances-by-host result=SKIPPED "msg=nama host ambigu"
            ALL_RESULTS+=("$arg|SKIPPED|0|0|-")
            continue
        fi
        h="$(jq -r '.[0].host' <<< "$m")"
        [[ -n "${seen[$h]+x}" ]] && continue
        seen[$h]=1
        SEL_HOSTS+=("$h")
    done
    return 0
}

# Picker multi-select: fzf jika ada, fallback menu bernomor. Hasil di SEL_HOSTS.
select_hosts() {
    local n i answer tries=0 out
    local -a hosts=() labels=() picked=()

    mapfile -t hosts < <(jq -r '.[].host' <<< "$SVC_JSON")
    mapfile -t labels < <(jq -r '.[] | [ .host, .zone, .status, .state ]
        as $c | "\($c[0] | .[0:40] | . + " " * (40 - length))  \($c[1] | .[0:16] | . + " " * (16 - length))  \($c[2] | . + " " * (9 - length))  \($c[3] | . + " " * (5 - length))"
        + (if .reason != "" and .reason != "null" then "  (\(.reason))" else "" end)' <<< "$SVC_JSON")
    n=${#hosts[@]}

    if command -v "$FZF" >/dev/null 2>&1; then
        out="$(for i in "${!hosts[@]}"; do printf '%s\t%s\n' "$i" "${labels[$i]}"; done |
            "$FZF" --multi --layout=reverse --border --info=inline --height=50% \
                --delimiter=$'\t' --with-nth=2.. --prompt='🖥️  host > ' \
                --header=$'TAB = pilih/lepas, Enter = konfirmasi, Esc = batal\nHOST                                      ZONE              STATUS     STATE')" || out=""
        while IFS=$'\t' read -r i _; do
            [[ "$i" =~ ^[0-9]+$ ]] && picked+=("$i")
        done <<< "$out"
    else
        echo
        echo "${C_BOLD}Compute host (nova-compute):${C_RESET}"
        printf '      %-40s  %-16s  %-9s  %s\n' "HOST" "ZONE" "STATUS" "STATE"
        for i in "${!labels[@]}"; do
            printf '  %2d. %s\n' $(( i + 1 )) "${labels[$i]}"
        done
        while true; do
            tries=$(( tries + 1 ))
            (( tries <= 5 )) || die "Host wajib dipilih."
            ask answer "Pilih host [nomor dipisah koma, mis. 1,3, atau 'all'; kosong = batal]: "
            answer="$(trim "$answer")"
            picked=()
            [[ -z "$answer" ]] && break
            if [[ "${answer,,}" == "all" ]]; then
                picked=("${!hosts[@]}")
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
        SEL_HOSTS+=("${hosts[$i]}")
    done
    return 0
}

choose_hosts() {
    log_event INPUT "hosts_arg=${HOST_ARGS[*]:-}" "extended=${EXTENDED:-ask}" "method=$METHOD" \
        "parallel=$PARALLEL" "output_dir=$OUTPUT_DIR"

    if (( ${#HOST_ARGS[@]} > 0 )); then
        resolve_host_args
        if (( ${#SEL_HOSTS[@]} == 0 )); then
            echo "Host nova-compute yang tersedia:"
            jq -r '.[] | "  \(.host)  zone=\(.zone)  \(.status)/\(.state)"' <<< "$SVC_JSON"
            die "Tidak ada host valid untuk diproses."
        fi
    else
        has_tty || die "Tidak ada terminal untuk memilih host; gunakan --host (mis. dari cron)."
        PICKED_INTERACTIVE=1
        select_hosts
        if (( ${#SEL_HOSTS[@]} == 0 )); then
            echo "Tidak ada host dipilih. Selesai."
            log_event DECISION selection=none
            exit 0
        fi
    fi

    local h
    for h in "${SEL_HOSTS[@]}"; do
        log_event DECISION "host=$h" "service_status=$(svc_field "$h" status)" "service_state=$(svc_field "$h" state)"
    done
    return 0
}

# Kolom tambahan: ditanyakan hanya pada mode interaktif (picker); default tidak
choose_extended() {
    local answer=""
    if [[ -z "$EXTENDED" ]]; then
        EXTENDED=0
        if (( PICKED_INTERACTIVE )); then
            ask answer "Tambahkan kolom tambahan (status, power state, flavor, vCPU, RAM, IP, AZ)? [y/N]: "
            is_yes "$(trim "$answer")" && EXTENDED=1
        fi
    fi
    log_event DECISION "extended=$EXTENDED"
    return 0
}

# ============================================================
# 2. Ambil instance
# ============================================================

# Normalisasi output API / server show / server list ke
# {id, name, project_id, status, power, flavor, vcpus, ram, addresses: [{net, addr, floating}], az, host}.
# addresses API: [{addr, "OS-EXT-IPS:type"}]; server show/list: list string (floating
# ditandai dari daftar floating IP $floats), atau string "net=ip, ip; net2=ip".
# shellcheck disable=SC2016  # program jq, bukan ekspansi shell
JQ_NORM='
def addrs($floats):
  if type == "object" then
    [ to_entries[] | .key as $n | (.value // [])[]
      | if type == "object" then { net: $n, addr: (.addr // ""), floating: ((."OS-EXT-IPS:type" // "") == "floating") }
        else { net: $n, addr: tostring, floating: (tostring as $a | $floats | index($a) != null) } end ]
  elif type == "string" and . != "" then
    [ split("; ")[] | capture("^(?<n>[^=]+)=(?<v>.*)$")? | .n as $n
      | (.v | split(", ")[]) | { net: $n, addr: ., floating: (. as $a | $floats | index($a) != null) } ]
  else [] end;
def flav:
  if type == "object" then { name: (.original_name // .name // .id // ""), vcpus: (.vcpus // ""), ram: (.ram // "") }
  elif type == "string" then { name: ., vcpus: "", ram: "" }
  else { name: "", vcpus: "", ram: "" } end;
def norm($floats):
  ((.flavor // .Flavor) | flav) as $f
  | { id: (.id // .ID // ""),
      name: (.name // .Name // ""),
      project_id: (.tenant_id // .project_id // ."Project ID" // ""),
      status: (.status // .Status // ""),
      power: (."OS-EXT-STS:power_state" // ."Power State" // .power_state // null),
      flavor: $f.name, vcpus: $f.vcpus, ram: $f.ram,
      addresses: ((.addresses // .Networks // null) | addrs($floats)),
      az: (."OS-EXT-AZ:availability_zone" // ."Availability Zone" // .availability_zone // ""),
      host: (."OS-EXT-SRV-ATTR:host" // .Host // .compute_host // "") };
'

# "server list" seluruh cloud (sekali per run, dipakai semua host). --host OSC
# TIDAK dipakai: di OSC 7.1.2 / openstacksdk 4.0.0 hasilnya selalu kosong (SDK
# menyaring ulang di client pada atribut "host" yang selalu None).
# Tanpa --limit: SDK mengikuti semua halaman (--limit mematikan pagination).
load_all_servers() {
    local errf="$WORK_DIR/allservers.err"
    case "$ALL_SERVERS_STATE" in
        ok)   return 0 ;;
        fail) return 1 ;;
    esac
    echo "  server list --all-projects (seluruh cloud, sekali per run) ..."
    if os_compute server list --all-projects --long -n -c ID -c Name -c "Project ID" -c Status \
            -c "Power State" -c "Availability Zone" -c Host -f json > "$WORK_DIR/allservers.json" 2>"$errf" &&
            jq -e 'type == "array"' "$WORK_DIR/allservers.json" >/dev/null 2>&1; then
        ALL_SERVERS_STATE="ok"
        log_result resource=servers action=lookup result=SUCCESS "count=$(jq length "$WORK_DIR/allservers.json")"
        return 0
    fi
    ALL_SERVERS_STATE="fail"
    ALL_SERVERS_ERR="server list gagal: $(last_error_line "$errf")"
    log_result resource=servers action=lookup result=FAILED "msg=$ALL_SERVERS_ERR"
    return 1
}

# Output list memuat semua field yang dibutuhkan mode ini?
list_has_all_fields() {
    jq -e --argjson ext "$EXTENDED" '
        length == 0 or (.[0] | (has("ID") or has("id")) and (has("Name") or has("name"))
                               and (has("Project ID") or has("project_id") or has("tenant_id"))
                               and ($ext == 0 or ((.flavor | type) == "object" and (.flavor | has("vcpus"))
                                                  and has("addresses"))))' "$1" >/dev/null 2>&1
}

# host_servers HOST OUT — instance HOST dari list seluruh cloud
host_servers() {
    jq --arg h "$1" '[ .[] | select((.Host // ."OS-EXT-SRV-ATTR:host" // "") == $h) ]' \
        "$WORK_DIR/allservers.json" > "$2"
}

# --- metode api ---

api_compute_setup() {
    api_setup compute || return 1
    # Endpoint compute di catalog biasanya sudah memuat versi (/v2.1 atau
    # /v2.1/<project_id>); tambahkan /v2.1 jika belum
    if [[ ! "$API_ENDPOINT" =~ /v2(\.[0-9]+)?(/[0-9a-fA-F-]+)?$ ]]; then
        API_ENDPOINT="$API_ENDPOINT/v2.1"
    fi
    API_HEADERS=("OpenStack-API-Version: compute $COMPUTE_API_VERSION"
                 "X-OpenStack-Nova-API-Version: $COMPUTE_API_VERSION")
    return 0
}

fetch_api() {
    local host="$1" out="$2" q
    api_compute_setup || return 1
    q="all_tenants=1&host=$(jq -rn --arg h "$host" '$h | @uri')"
    [[ -n "$PAGE_LIMIT" ]] && q+="&limit=$PAGE_LIMIT"
    api_collect servers/detail "$q" servers "$out" || return 1
    # Saring ulang di sini: hanya instance yang benar-benar di host ini
    jq --arg h "$host" '[ .[] | select((."OS-EXT-SRV-ATTR:host" // "") == $h) ]' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
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

# Daftar floating IP (sekali per run) untuk menandai alamat floating di metode cli
load_floats() {
    local errf="$WORK_DIR/floats.err"
    [[ -n "$FLOATS_STATE" ]] && return 0
    if os_cli floating ip list -f json > "$WORK_DIR/floats.raw" 2>"$errf" &&
            jq '[ .[] | (."Floating IP Address" // .floating_ip_address // empty) ]' \
                "$WORK_DIR/floats.raw" > "$WORK_DIR/floats.json" 2>/dev/null; then
        FLOATS_STATE="ok"
    else
        FLOATS_STATE="fail"
        echo '[]' > "$WORK_DIR/floats.json"
        warn "Gagal mengambil daftar floating IP ($(last_error_line "$errf")); penanda (floating) tidak tersedia."
    fi
    return 0
}

# fetch_cli HOST OUT — ID dari list seluruh cloud, lalu "server show" paralel
fetch_cli() {
    local host="$1" out="$2" dir="$WORK_DIR/show-$RANDOM" id gone=0 moved=0 failed=0

    load_all_servers || { H_FAIL_MSG="metode cli: $ALL_SERVERS_ERR"; return 1; }
    mkdir -p "$dir"
    host_servers "$host" "$dir/list.json"
    jq -r '.[] | (.ID // .id)' "$dir/list.json" | while IFS= read -r id; do
        is_uuidish "$id" && echo "$id"
    done > "$dir/ids"

    parallel_show "$dir" "server show" "${OS_CMD[@]}" --os-compute-api-version "$COMPUTE_API_VERSION" server show

    while IFS= read -r id; do
        if [[ -f "$dir/$id.json" ]]; then
            # Pindah host di antara list dan show (mis. sedang migrasi): tidak dihitung
            if [[ "$(jq -r '."OS-EXT-SRV-ATTR:host" // .compute_host // ""' "$dir/$id.json")" != "$host" ]]; then
                moved=$(( moved + 1 ))
                log_event SKIPPED "resource=$id" "reason=instance tidak lagi di host $host saat show"
                rm -f "$dir/$id.json"
            fi
        elif is_not_found "$dir/$id.err"; then
            gone=$(( gone + 1 ))
            log_event SKIPPED "resource=$id" "reason=instance sudah tidak ada saat show"
        else
            failed=$(( failed + 1 ))
            log_warn -q "server show $id gagal: $(last_error_line "$dir/$id.err")"
        fi
    done < "$dir/ids"

    find "$dir" -maxdepth 1 -name '*.json' ! -name 'list.json' -print0 | xargs -0 -r cat | jq -s '.' > "$out" 2>/dev/null || echo '[]' > "$out"
    (( gone > 0 )) && H_NOTES+=("$gone instance terhapus selama proses (dilewati)")
    (( moved > 0 )) && H_NOTES+=("$moved instance pindah host selama proses (dilewati)")
    if (( failed > 0 )); then
        H_FAILED=1
        H_FAIL_MSG="$failed server show gagal (data tidak lengkap)"
        warn "$H_FAIL_MSG"
    fi
    return 0
}

# fetch_instances HOST OUT — pilih metode, hasil dinormalisasi di OUT
fetch_instances() {
    local host="$1" out="$2" raw="$WORK_DIR/raw-$RANDOM.json"

    case "$METHOD" in
        api)
            fetch_api "$host" "$raw" || { H_FAIL_MSG="metode api: $API_REASON"; return 1; }
            H_METHOD="api"
            ;;
        cli)
            fetch_cli "$host" "$raw" || return 1
            H_METHOD="cli"
            ;;
        auto)
            if (( EXTENDED == 0 )) && load_all_servers && host_servers "$host" "$raw" && list_has_all_fields "$raw"; then
                H_METHOD="list"
                log_event METHOD "host=$host" method=list "reason=server list memuat semua field (mode default)"
            else
                local why="mode --extended butuh flavor/addresses lengkap"
                (( EXTENDED == 0 )) && why="server list tidak lengkap/gagal"
                if fetch_api "$host" "$raw"; then
                    H_METHOD="api"
                    log_event METHOD "host=$host" method=api "reason=$why"
                else
                    H_METHOD="cli"
                    H_NOTES+=("fallback ke cli: $API_REASON")
                    warn "Metode api tidak bisa dipakai ($API_REASON); fallback ke cli."
                    log_event METHOD "host=$host" method=cli "reason=fallback api: $API_REASON"
                    fetch_cli "$host" "$raw" || return 1
                fi
            fi
            ;;
    esac

    if [[ "$H_METHOD" == "cli" ]] && (( EXTENDED )); then
        load_floats
    fi
    [[ -f "$WORK_DIR/floats.json" ]] || echo '[]' > "$WORK_DIR/floats.json"

    jq --slurpfile fl "$WORK_DIR/floats.json" "$JQ_NORM"' [ .[] | norm($fl[0]) ]' "$raw" > "$out" 2>/dev/null || {
        H_FAIL_MSG="data instance tidak bisa diparse"
        return 1
    }
    return 0
}

# ============================================================
# 3. Project dan domain
# ============================================================

# Peta project ID → {name, domain_id} dan domain ID → nama (satu panggilan masing-masing)
resolve_projects() {
    local errf="$WORK_DIR/projects.err"
    [[ -n "$PROJECTS_STATE" ]] && return 0
    PROJECTS_STATE="fail"
    DOMAINS_STATE="fail"
    if ! os_cli project list --long -f json > "$WORK_DIR/projects.raw" 2>"$errf" ||
            ! jq '[ .[] | { key: (.ID // .id), value: { name: (.Name // .name // ""),
                                                       domain_id: (."Domain ID" // .domain_id // "") } } ] | from_entries' \
                "$WORK_DIR/projects.raw" > "$WORK_DIR/projects.json" 2>/dev/null; then
        echo '{}' > "$WORK_DIR/projects.json"
        echo '{}' > "$WORK_DIR/domains.json"
        warn "Gagal mengambil daftar project: $(last_error_line "$errf")"
        log_result resource=projects action=lookup result=FAILED "msg=$(last_error_line "$errf")"
        return 0
    fi
    log_result resource=projects action=lookup result=SUCCESS "count=$(jq length "$WORK_DIR/projects.json")"
    PROJECTS_STATE="ok"

    errf="$WORK_DIR/domains.err"
    if ! os_cli domain list -f json > "$WORK_DIR/domains.raw" 2>"$errf" ||
            ! jq '[ .[] | { key: (.ID // .id), value: (.Name // .name // "") } ] | from_entries' \
                "$WORK_DIR/domains.raw" > "$WORK_DIR/domains.json" 2>/dev/null; then
        echo '{}' > "$WORK_DIR/domains.json"
        warn "Gagal mengambil daftar domain: $(last_error_line "$errf")"
        log_result resource=domains action=lookup result=FAILED "msg=$(last_error_line "$errf")"
        DOMAINS_STATE="fail"
        return 0
    fi
    log_result resource=domains action=lookup result=SUCCESS "count=$(jq length "$WORK_DIR/domains.json")"
    DOMAINS_STATE="ok"
    return 0
}

# ============================================================
# 4-5. Baris CSV dan file .ids
# ============================================================

# Join project/domain, format kolom, urutkan (Project Name, Instance Name, ID).
# Project tidak ditemukan → "(not found)" (atau "(lookup failed)" jika project
# list gagal), domain kosong. Domain tidak ditemukan → "(not found)" (atau
# "(lookup failed)" jika domain list gagal).
# shellcheck disable=SC2016  # program jq, bukan ekspansi shell
JQ_ENRICH='
def power_text:
  if . == null or . == "" then ""
  elif type == "number" or test("^[0-9]+$") then
    ({ "0": "NOSTATE", "1": "Running", "3": "Paused", "4": "Shutdown", "6": "Crashed", "7": "Suspended" }[tostring]
     // tostring)
  else tostring end;
def fmt_addresses:
  . as $a
  | [ $a | map(.net) | unique[] as $n
      | "\($n): " + ([ $a[] | select(.net == $n) | .addr + (if .floating then " (floating)" else "" end) ] | join(", ")) ]
  | join("; ");
map(
  ($proj[0][.project_id]) as $p
  | . + { project_name: (if .project_id == "" then ""
                         elif $p != null then $p.name
                         elif $pstate == "fail" then "(lookup failed)"
                         else "(not found)" end),
          domain_id: (if $p != null then $p.domain_id else "" end),
          orphan: (.project_id != "" and $p == null and $pstate != "fail") }
  | . + { domain_name: (if .domain_id == "" then ""
                        elif $dom[0][.domain_id] != null then $dom[0][.domain_id]
                        elif $dstate == "fail" then "(lookup failed)"
                        else "(not found)" end),
          power_text: (.power | power_text),
          addr_text: (.addresses | fmt_addresses) })
| sort_by([ (.project_name | ascii_downcase), (.name | ascii_downcase), .id ])
'

# shellcheck disable=SC2016
JQ_ROWS='
.[]
| [ .id, .name, .project_id, .project_name, .domain_id, .domain_name ]
  + (if $ext == 1 then [ .status, .power_text, .flavor, (.vcpus | tostring), (.ram | tostring), .addr_text, .az ]
     else [] end)
| map(. // "" | tostring)
| @csv'

CSV_HEADER="Instance ID,Instance Name,Project ID,Project Name,Domain ID,Domain Name"
CSV_HEADER_EXT="Status,Power State,Flavor,vCPU,RAM (MB),IP Addresses,Availability Zone"

# write_files HOST ENRICHED — CSV + .ids (nama dasar sama, permission 600, tidak menimpa)
write_files() {
    local host="$1" rows="$2" ts base header count
    ts="$(date +%Y%m%d-%H%M%S)"
    base="$OUTPUT_DIR/instances-$(safe_name "$host")-$ts"
    [[ -e "$base.csv" || -e "$base.ids" ]] && base="$base-$RANDOM"
    CSV_FILE="$base.csv"
    IDS_FILE="$base.ids"

    header="$CSV_HEADER"
    (( EXTENDED )) && header+=",$CSV_HEADER_EXT"
    jq -r --argjson ext "$EXTENDED" "$JQ_ROWS" "$rows" > "$WORK_DIR/rows.csv" || return 1
    count="$(jq length "$rows")"

    # umask 077 + noclobber: file baru dengan permission 600, file lama tidak ditimpa
    if ! ( umask 077; set -o noclobber
           { printf '%s\n' "$header"; cat "$WORK_DIR/rows.csv"; } > "$CSV_FILE"
           { printf '# host=%s generated=%s count=%s source=list-instances-by-host\n' \
                 "$host" "$(date -Iseconds)" "$count"
             jq -r '.[].id' "$rows"; } > "$IDS_FILE" ) 2>"$WORK_DIR/write.err"; then
        H_FAIL_MSG="gagal menulis file output: $(last_error_line "$WORK_DIR/write.err")"
        return 1
    fi
    chmod 600 "$CSV_FILE" "$IDS_FILE" 2>/dev/null || true
    return 0
}

# ============================================================
# 6. Ringkasan
# ============================================================

print_summary() {
    local host="$1" rows="$2" dur="$3" note line

    echo
    echo "${C_BOLD}── $host${C_RESET}"
    printf '  %-20s : %s / %s%s\n' "Service" "$(svc_field "$host" status)" "$(svc_field "$host" state)" \
        "$(r="$(svc_field "$host" reason)"; [[ -n "$r" && "$r" != "-" && "$r" != "null" ]] && printf ' (%s)' "$r")"
    printf '  %-20s : %s\n' "Zone" "$(svc_field "$host" zone)"
    printf '  %-20s : %s\n' "Region" "$REGION"
    printf '  %-20s : %s\n' "Metode" "$H_METHOD"
    printf '  %-20s : %ss\n' "Durasi" "$dur"
    printf '  %-20s : %s\n' "Total instance" "$S_TOTAL"

    if (( S_TOTAL == 0 )); then
        echo "  ${C_YELLOW}ℹ️  Tidak ada instance di host ini (CSV hanya berisi header).${C_RESET}"
    else
        printf '  %-20s : %s\n' "Per status" \
            "$(jq -r '[ group_by(.status)[] | "\(.[0].status // "-")=\(length)" ] | join("  ")' "$rows")"
        if (( EXTENDED )); then
            printf '  %-20s : %s\n' "Per power state" \
                "$(jq -r '[ group_by(.power_text)[] | "\(.[0].power_text | if . == "" then "-" else . end)=\(length)" ] | join("  ")' "$rows")"
        fi
        echo
        echo "  Instance per project ($(jq '[ .[].project_id ] | unique | length' "$rows") project):"
        printf '    %-32s  %-20s  %s\n' "PROJECT" "DOMAIN" "JUMLAH"
        while IFS="$US" read -r -a line; do
            printf '    %-32s  %-20s  %s\n' "${line[0]}" "${line[1]:--}" "${line[2]}"
        done < <(jq -r '[ group_by(.project_id)[]
                          | { p: (.[0].project_name + (if .[0].orphan then " [" + .[0].project_id[0:8] + "]" else "" end)),
                              d: .[0].domain_name, n: length } ]
                        | sort_by(.p | ascii_downcase)[] | [ .p, .d, (.n | tostring) ] | join("\u001f")' "$rows")
    fi

    if (( S_ORPHAN > 0 )); then
        echo
        echo "  ${C_RED}${C_BOLD}⚠️  $S_ORPHAN instance dengan project (not found)${C_RESET}${C_RED} — project sudah dihapus, VM masih ada; perlu penanganan khusus.${C_RESET}"
    fi

    echo
    printf '  %-20s : %s\n' "File CSV" "${CSV_FILE:--}"
    printf '  %-20s : %s\n' "File ID" "${IDS_FILE:--}"
    [[ -n "$IDS_FILE" ]] && (( S_TOTAL > 0 )) && \
        echo "  ➡️  Untuk migrasi: servers/live-migrate.sh --file $IDS_FILE"
    for note in "${H_NOTES[@]}"; do
        printf '  %-20s : %s\n' "Catatan" "$note"
    done
    if (( H_FAILED )); then
        echo "  ${C_RED}❌ FAILED: $H_FAIL_MSG${C_RESET}"
    else
        echo "  ${C_GREEN}✅ Selesai${C_RESET}"
    fi
}

# ============================================================
# Proses per host
# ============================================================

process_host() {
    local host="$1" start=$SECONDS dur raw="$WORK_DIR/inst.json" rows="$WORK_DIR/rows.json" result msg

    H_METHOD="-" H_NOTES=() H_FAILED=0 H_FAIL_MSG="" CSV_FILE="" IDS_FILE="" S_TOTAL=0 S_ORPHAN=0

    echo
    echo "${C_BOLD}▶ $host${C_RESET} ($(svc_field "$host" status)/$(svc_field "$host" state))"

    if ! fetch_instances "$host" "$raw"; then
        dur=$(( SECONDS - start ))
        echo "  ${C_RED}❌ $H_FAIL_MSG${C_RESET}"
        log_result "resource=$host" action=list-instances-by-host result=FAILED "method=$H_METHOD" \
            count=0 orphans=0 file=- "duration=${dur}s" "msg=$H_FAIL_MSG"
        ALL_RESULTS+=("$host|FAILED|0|0|-")
        ANY_FAILED=1
        return 0
    fi
    echo "  Metode: $H_METHOD — $(jq length "$raw") instance"

    resolve_projects
    if [[ "$PROJECTS_STATE" == "fail" || "$DOMAINS_STATE" == "fail" ]]; then
        H_FAILED=1
        H_FAIL_MSG="lookup project/domain gagal (pemilik instance tidak lengkap)"
    fi

    jq --slurpfile proj "$WORK_DIR/projects.json" --slurpfile dom "$WORK_DIR/domains.json" \
        --arg pstate "$PROJECTS_STATE" --arg dstate "$DOMAINS_STATE" "$JQ_ENRICH" "$raw" > "$rows"
    S_TOTAL="$(jq length "$rows")"
    S_ORPHAN="$(jq '[ .[] | select(.orphan) ] | length' "$rows")"

    if ! write_files "$host" "$rows"; then
        H_FAILED=1
        [[ -n "$H_FAIL_MSG" ]] || H_FAIL_MSG="gagal membuat file output"
        CSV_FILE="" IDS_FILE=""
    fi
    dur=$(( SECONDS - start ))
    print_summary "$host" "$rows" "$dur"

    jq -r '.[] | .project_id' "$rows" >> "$GRAND_PROJECTS_FILE"
    GRAND_TOTAL=$(( GRAND_TOTAL + S_TOTAL ))
    GRAND_ORPHAN=$(( GRAND_ORPHAN + S_ORPHAN ))

    result=SUCCESS
    msg="ok"
    (( S_TOTAL == 0 )) && msg="tidak ada instance"
    (( ${#H_NOTES[@]} > 0 )) && msg="$(IFS=';'; echo "${H_NOTES[*]}")"
    if (( H_FAILED )); then
        result=FAILED
        msg="$H_FAIL_MSG"
        ANY_FAILED=1
    fi
    log_result "resource=$host" action=list-instances-by-host "result=$result" "method=$H_METHOD" \
        "extended=$EXTENDED" "count=$S_TOTAL" "orphans=$S_ORPHAN" "file=${CSV_FILE:--}" \
        "ids_file=${IDS_FILE:--}" "duration=${dur}s" "msg=$msg"
    ALL_RESULTS+=("$host|$result|$S_TOTAL|$S_ORPHAN|${CSV_FILE:--}")
    return 0
}

main() {
    parse_args "$@"
    require_deps

    echo "========================================"
    echo "        List Instances by Host"
    echo "========================================"

    log_event OPTIONS "os_cmd=${OS_CMD[*]}" "curl=$API_CURL" "compute_api=$COMPUTE_API_VERSION" \
        "page_limit=${PAGE_LIMIT:--}"

    LOG_EXIT_HOOK=on_exit
    make_work_dir
    detect_region
    list_hosts
    choose_hosts
    choose_extended
    check_microversion

    local h r name res cnt orph file
    for h in "${SEL_HOSTS[@]}"; do
        process_host "$h"
    done

    echo
    echo "========================================"
    if (( ${#ALL_RESULTS[@]} > 1 )); then
        echo "Ringkasan ($REGION)"
        for r in "${ALL_RESULTS[@]}"; do
            IFS='|' read -r name res cnt orph file <<< "$r"
            printf '  %-8s %-32s %6s instance  %s orphan  %s\n' "$res" "$name" "$cnt" "$orph" "$file"
        done
        printf '  %-41s %6s instance, %s project unik, %s orphan\n' "Total" "$GRAND_TOTAL" \
            "$(sort -u "$GRAND_PROJECTS_FILE" | grep -c . || true)" "$GRAND_ORPHAN"
    fi
    echo "ℹ️  Data adalah snapshot saat eksekusi; instance bisa sedang bermigrasi atau berubah."
    echo "Log : ${LOG_FILE:-(logging nonaktif)}"

    log_event SUMMARY "hosts=${#SEL_HOSTS[@]}" "total=$GRAND_TOTAL" "orphans=$GRAND_ORPHAN" "failed=$ANY_FAILED"
    (( ANY_FAILED )) && exit 1
    return 0
}

main "$@"
