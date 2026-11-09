#!/bin/bash
# ============================================================
# @name:        List Routers
# @description: Daftar router beserta IP publik, network publik, project, dan domain → CSV di /tmp
# @mutates:     no
# @requires:    admin, jq
# @tags:        network, router, report
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: list-routers.sh [--method auto|api|cli] [--output PATH] [--extended]
                       [--with-gateway-only]

Daftar SEMUA router di region aktif (semua project) beserta IP publik
gateway, network publik, project, dan domain, lalu tulis ke CSV.
Read-only: tidak ada resource yang diubah.

Opsi:
  --method M           auto (default) | api | cli
                         auto: "router list --long" jika output-nya lengkap
                               (external_fixed_ips), jika tidak api.
                               Dengan --extended selalu api.
                         api : GET /v2.0/routers langsung dengan curl (pagination)
                         cli : "router list --long -f json"; gagal dengan pesan
                               jelas jika output tidak lengkap. Tidak bisa
                               dipakai dengan --extended (OSC tidak menampilkan
                               created_at/updated_at di "router list").
  --output PATH        File CSV output (tidak boleh sudah ada; direktori harus ada)
  --extended           Tambah kolom: Project ID, Domain ID, Public Network ID,
                       Status, Admin State, SNAT, HA, Distributed, Created At,
                       Updated At (field yang tidak ada di region ini = kosong)
  --with-gateway-only  Hanya tulis router yang punya external gateway
  -h, --help           Tampilkan help

File default: /tmp/list-routers-<region>-<YYYYmmdd-HHMMSS>.csv (permission 600,
tidak pernah menimpa file yang sudah ada).
Kolom: Router ID,Router Name,Public IP,Public Network Name,Project Name,Domain Name
  Public IP     : semua IP gateway dipisah ";" (IPv4 dulu, IPv6 bentuk kanonik)
  Tanpa gateway : Public IP dan Public Network Name kosong
  Project/domain/network yang tidak ada lagi: "(not found: <id>)"; lookup yang
  gagal (mis. 403/503): "(lookup failed: <id>)" dan exit code 1.

Environment:
  OSOPS_OS_CMD              Perintah OpenStack CLI (default: openstack)
  OSOPS_CURL                Perintah curl (default: curl; opsional, metode api)
  OSOPS_ROUTER_PAGE_LIMIT   Ukuran halaman Neutron API (default kosong = tanpa limit)
  OSOPS_ROUTERS_OUTPUT_DIR  Direktori file default (default /tmp)
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

# Bentuk kanonik IP (ip_normalize)
# shellcheck source=../lib/netinfo.sh
if ! source "$OSOPS_HOME/lib/netinfo.sh" 2>/dev/null; then
    echo "❌ lib/netinfo.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi

# ============================================================
# Konfigurasi
# ============================================================

METHOD="auto"
OUTPUT=""
EXTENDED=0
GW_ONLY=0

if [[ -n "${OSOPS_OS_CMD:-}" ]]; then
    read -ra OS_CMD <<< "$OSOPS_OS_CMD"
else
    OS_CMD=(openstack)
fi

PAGE_LIMIT="${OSOPS_ROUTER_PAGE_LIMIT:-}"
OUTPUT_DIR="${OSOPS_ROUTERS_OUTPUT_DIR:-/tmp}"

REGION="-"
AUTH_HOST="-"
WORK_DIR=""
USED_METHOD="-"
CSV_FILE=""
PARTIAL=0
NETWORKS_STATE=""
PROJECTS_STATE=""
DOMAINS_STATE=""

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

last_error_line() {
    grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | cut -c1-300
}

# Region aman sebagai bagian nama file
safe_name() {
    local s="$1"
    s="${s//[^A-Za-z0-9._-]/_}"
    s="${s#.}"
    printf '%s' "${s:-unknown}"
}

# ============================================================
# OpenStack CLI wrapper (read-only: tidak ada os_run)
# ============================================================

os_cli() {
    "${OS_CMD[@]}" "$@"
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
            --method)            need_value "$1" "${2:-}"; METHOD="${2,,}"; shift 2 ;;
            --output)            need_value "$1" "${2:-}"; OUTPUT="$2"; shift 2 ;;
            --extended)          EXTENDED=1; shift ;;
            --with-gateway-only) GW_ONLY=1; shift ;;
            *)                   die "Opsi tidak dikenal: $1 (lihat --help)" ;;
        esac
    done

    case "$METHOD" in
        auto|api|cli) ;;
        *) die "--method harus auto, api, atau cli (dapat: $METHOD)." ;;
    esac
    if [[ "$METHOD" == "cli" ]] && (( EXTENDED )); then
        die "--extended butuh Created At/Updated At, yang tidak ada di output \"router list\" OSC; gunakan --method api atau auto."
    fi
    [[ -z "$PAGE_LIMIT" || "$PAGE_LIMIT" =~ ^[1-9][0-9]*$ ]] || \
        die "OSOPS_ROUTER_PAGE_LIMIT harus angka > 0 (dapat: $PAGE_LIMIT)."

    local dir
    if [[ -n "$OUTPUT" ]]; then
        [[ -e "$OUTPUT" || -L "$OUTPUT" ]] && die "File output sudah ada (tidak ditimpa): $OUTPUT"
        dir="$(dirname -- "$OUTPUT")"
    else
        dir="$OUTPUT_DIR"
    fi
    [[ -d "$dir" ]] || die "Direktori output tidak ada: $dir"
    [[ -w "$dir" ]] || die "Direktori output tidak bisa ditulis: $dir"
    return 0
}

require_deps() {
    command -v jq >/dev/null 2>&1 || \
        die "jq tidak ditemukan. Install jq terlebih dahulu (dnf/apt install jq)."
    command -v "${OS_CMD[0]}" >/dev/null 2>&1 || \
        die "OpenStack CLI tidak ditemukan: ${OS_CMD[0]}"
    if [[ "$METHOD" == "api" ]] && ! api_curl_available; then
        die "curl tidak ditemukan ($API_CURL); dibutuhkan untuk --method api."
    fi
    return 0
}

make_work_dir() {
    WORK_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/list-routers.XXXXXX")" || \
        die "Gagal membuat direktori sementara di ${TMPDIR:-/tmp}."
    API_WORK_DIR="$WORK_DIR"
}

# Dipanggil lib/logging.sh saat script keluar (normal, error, sinyal)
on_exit() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
    api_cleanup
    return 0
}

# Region: OS_REGION_NAME; tanpa itu (mis. OS_CLOUD / clouds.yaml) region
# endpoint network di catalog, jika hanya ada satu.
detect_region() {
    local host json
    REGION="${OS_REGION_NAME:-}"
    if [[ -z "$REGION" ]] && json="$(os_cli catalog show network -f json 2>/dev/null)"; then
        REGION="$(jq -r '[ (.endpoints // [])[] | (.region_id // .region // empty) ] | unique
                         | if length == 1 then .[0] else empty end' <<< "$json" 2>/dev/null)" || REGION=""
    fi
    REGION="${REGION:--}"
    host="${OS_AUTH_URL:-}"
    host="${host#*://}"
    host="${host%%/*}"
    [[ -z "$host" && -n "${OS_CLOUD:-}" ]] && host="clouds.yaml: $OS_CLOUD"
    AUTH_HOST="${host:--}"
    echo "🌐 Region  : $REGION (auth: $AUTH_HOST)"
    echo "🔧 Metode  : $METHOD"
    log_event CONTEXT "region=$REGION" "auth_host=$AUTH_HOST"
}

# ============================================================
# 1. Router
# ============================================================

# Normalisasi output "router list --long -f json" (OSC) dan GET /v2.0/routers
# ke {id, name, project_id, status, admin, ha, distributed, gw, created_at,
# updated_at, has_dates}. gw = object external_gateway_info, null = tanpa
# gateway, "INVALID" = tidak bisa diparse (string dari OSC lama).
# shellcheck disable=SC2016  # program jq, bukan ekspansi shell
JQ_NORM='
def tobool:
  if type == "boolean" then .
  elif type == "string" then (ascii_downcase
       | if IN("true", "up", "yes") then true elif IN("false", "down", "no") then false else null end)
  else null end;
def gwparse:
  if . == null then null
  elif type == "object" then (if length == 0 then null else . end)
  elif type == "string" then
    (if IN("", "null", "None", "{}") then null
     else (try (fromjson | if type == "object" then (if length == 0 then null else . end)
                           elif . == null then null else "INVALID" end)
           catch "INVALID") end)
  else "INVALID" end;
def pick($a; $b): if has($a) then .[$a] elif has($b) then .[$b] else null end;
def norm:
  { id: ((.id // .ID // "") | tostring),
    name: ((.name // .Name // "") | tostring),
    project_id: ((.project_id // .tenant_id // .Project // "") | tostring),
    status: ((.status // .Status // "") | tostring),
    admin: (pick("admin_state_up"; "State") | tobool),
    ha: (pick("ha"; "HA") | tobool),
    distributed: (pick("distributed"; "Distributed") | tobool),
    has_gw_key: (has("external_gateway_info") or has("External gateway info")),
    gw: (pick("external_gateway_info"; "External gateway info") | gwparse),
    has_dates: (has("created_at") and has("updated_at")),
    created_at: ((.created_at // "") | tostring),
    updated_at: ((.updated_at // "") | tostring) };
def gw_complete:
  . == null
  or (type == "object" and ((.network_id // "") | tostring) != ""
      and ((.external_fixed_ips // null) | type) == "array"
      and all(.external_fixed_ips[]; type == "object" and ((.ip_address // "") | tostring) != ""));
'

# Output (CLI) lengkap untuk kolom yang diminta? Alasan di INCOMPLETE_REASON.
INCOMPLETE_REASON=""
check_complete() {
    local norm="$1"
    INCOMPLETE_REASON="$(jq -r "$JQ_NORM"'
        if length == 0 then ""
        elif any(.[]; .has_gw_key | not) then "key external_gateway_info tidak ada"
        elif any(.[]; .gw | gw_complete | not) then
          "external_gateway_info tidak lengkap (\([ .[] | select(.gw | gw_complete | not) ] | length) router tanpa external_fixed_ips/ip_address/network_id yang bisa diparse)"
        elif $ext == 1 and any(.[]; .has_dates | not) then "created_at/updated_at tidak ada"
        else "" end' --argjson ext "$EXTENDED" "$norm")"
    [[ -z "$INCOMPLETE_REASON" ]]
}

# fetch_cli OUT — normalized router list via CLI; return 1 = gagal/tidak lengkap
fetch_cli() {
    local out="$1" raw="$WORK_DIR/routers-cli.raw" errf="$WORK_DIR/routers-cli.err"
    # Tanpa --limit: SDK mengikuti semua halaman. Admin melihat router semua project.
    if ! os_cli router list --long -f json > "$raw" 2>"$errf"; then
        INCOMPLETE_REASON="router list gagal: $(last_error_line "$errf")"
        return 1
    fi
    if ! jq "$JQ_NORM"' if type == "array" then [ .[] | norm ] else error("bukan array") end' \
            "$raw" > "$out" 2>/dev/null; then
        INCOMPLETE_REASON="output router list tidak bisa diparse"
        return 1
    fi
    check_complete "$out"
}

# fetch_api OUT — GET /v2.0/routers (semua halaman); return 1 = gagal
fetch_api() {
    local out="$1" raw="$WORK_DIR/routers-api.raw" q=""
    api_setup network /v2.0 || return 1
    [[ -n "$PAGE_LIMIT" ]] && q="limit=$PAGE_LIMIT"
    api_collect routers "$q" routers "$raw" || return 1
    jq "$JQ_NORM"' [ .[] | norm ]' "$raw" > "$out" 2>/dev/null || {
        API_REASON="respons API router tidak bisa diparse"
        return 1
    }
    if ! check_complete "$out"; then
        API_REASON="respons API: $INCOMPLETE_REASON"
        return 1
    fi
    return 0
}

fetch_routers() {
    local out="$1"
    case "$METHOD" in
        cli)
            fetch_cli "$out" || die "Metode cli: $INCOMPLETE_REASON. Gunakan --method api (atau auto)."
            USED_METHOD="cli"
            ;;
        api)
            fetch_api "$out" || die "Metode api: $API_REASON"
            USED_METHOD="api"
            ;;
        auto)
            if (( EXTENDED )); then
                fetch_api "$out" || die "Metode api (wajib untuk --extended): $API_REASON"
                USED_METHOD="api"
                log_event METHOD method=api "reason=--extended butuh created_at/updated_at"
            elif fetch_cli "$out"; then
                USED_METHOD="cli"
                log_event METHOD method=cli "reason=router list memuat external_fixed_ips"
            else
                local cli_reason="$INCOMPLETE_REASON"
                warn "Output CLI tidak bisa dipakai ($cli_reason); mencoba metode api."
                fetch_api "$out" || die "Metode cli: $cli_reason; metode api: $API_REASON"
                USED_METHOD="api"
                log_event METHOD method=api "reason=fallback cli: $cli_reason"
            fi
            ;;
    esac
    echo "   Dipakai : $USED_METHOD — $(jq length "$out") router"
    log_result resource=routers action=lookup result=SUCCESS "method=$USED_METHOD" "count=$(jq length "$out")"
    return 0
}

# ============================================================
# 2. Lookup (sekali, selalu lewat CLI)
# ============================================================

# load_map NAME STATEVAR JQ CMD... — hasil jq di $WORK_DIR/NAME.json; gagal → {} + state fail
load_map() {
    local name="$1" statevar="$2" filter="$3" errf="$WORK_DIR/$1.err"
    shift 3
    if os_cli "$@" > "$WORK_DIR/$name.raw" 2>"$errf" &&
            jq "$filter" "$WORK_DIR/$name.raw" > "$WORK_DIR/$name.json" 2>/dev/null; then
        printf -v "$statevar" '%s' ok
        log_result "resource=$name" action=lookup result=SUCCESS "count=$(jq length "$WORK_DIR/$name.json")"
    else
        printf -v "$statevar" '%s' fail
        echo '{}' > "$WORK_DIR/$name.json"
        warn "Gagal mengambil $name ($(last_error_line "$errf")); kolom terkait berisi (lookup failed: <id>)."
        log_result "resource=$name" action=lookup result=FAILED "msg=$(last_error_line "$errf")"
        PARTIAL=1
    fi
    rm -f "$WORK_DIR/$name.raw"
    return 0
}

load_lookups() {
    echo "Mengambil network, project, domain ..."
    # Semua network (admin: termasuk network external milik project lain)
    load_map networks NETWORKS_STATE \
        '[ .[] | { key: (.ID // .id), value: (.Name // .name // "") } ] | from_entries' \
        network list -f json
    load_map projects PROJECTS_STATE \
        '[ .[] | { key: (.ID // .id), value: { name: (.Name // .name // ""),
                                               domain_id: (."Domain ID" // .domain_id // "") } } ] | from_entries' \
        project list --long -f json
    load_map domains DOMAINS_STATE \
        '[ .[] | { key: (.ID // .id), value: (.Name // .name // "") } ] | from_entries' \
        domain list -f json
    return 0
}

# Peta IPv6 → bentuk kanonik (lib/netinfo.sh); satu kali per alamat unik
canon_ipv6() {
    local routers="$1" out="$2" ip c
    : > "$WORK_DIR/v6.tsv"
    while IFS= read -r ip; do
        if c="$(ip_normalize "$ip")"; then
            printf '%s\t%s\n' "$ip" "$c" >> "$WORK_DIR/v6.tsv"
        else
            log_warn -q "IP gateway tidak valid (ditulis apa adanya): $ip"
        fi
    done < <(jq -r '[ .[] | .gw | objects | .external_fixed_ips[]?.ip_address | strings | select(test(":")) ] | unique | .[]' "$routers")
    jq -R 'split("\t") | { key: .[0], value: .[1] }' "$WORK_DIR/v6.tsv" | jq -s 'from_entries' > "$out"
}

# ============================================================
# 3. Baris CSV
# ============================================================

# Join router + lookup → objek baris (urut project, nama router, ID)
# shellcheck disable=SC2016  # program jq, bukan ekspansi shell
JQ_ROWS='
def ip4key: split(".") | map(tonumber? // 0);
def miss($state; $id): if $state == "fail" then "(lookup failed: \($id))" else "(not found: \($id))" end;
def b: if . == true then "true" elif . == false then "false" else "" end;
$N[0] as $N | $P[0] as $P | $D[0] as $D | $V6[0] as $V6
| [ .[]
    | (.gw | if type == "object" then . else null end) as $gw
    | ([ ($gw.external_fixed_ips // [])[] | .ip_address | strings ] | unique) as $ips
    | (($ips | map(select(test(":") | not)) | sort_by(ip4key))
       + ($ips | map(select(test(":")) | ($V6[.] // .)) | unique)) as $pub
    | (($gw.network_id // "") | tostring) as $nid
    | .project_id as $pid
    | ($P[$pid] // null) as $proj
    | (if $proj != null then ($proj.domain_id // "") else "" end) as $did
    | { id, name, has_gw: ($gw != null),
        public_ip: ($pub | join(";")),
        net_id: $nid,
        net_name: (if $nid == "" then "" else ($N[$nid] // miss($nstate; $nid)) end),
        project_id: $pid,
        project_missing: ($pid != "" and $proj == null and $pstate != "fail"),
        project_name: (if $pid == "" then "" elif $proj != null then $proj.name else miss($pstate; $pid) end),
        domain_id: $did,
        domain_missing: ($did != "" and $D[$did] == null and $dstate != "fail"),
        domain_name: (if $did == "" then "" else ($D[$did] // miss($dstate; $did)) end),
        status,
        admin: (if .admin == true then "UP" elif .admin == false then "DOWN" else "" end),
        snat: ($gw.enable_snat | if type == "string" then ascii_downcase else . end
               | if . == "true" then true elif . == "false" then false else . end | b),
        ha: (.ha | b), distributed: (.distributed | b),
        created_at, updated_at,
        lookup_failed: (($pid != "" and $proj == null and $pstate == "fail")
                        or ($did != "" and $D[$did] == null and $dstate == "fail")
                        or ($nid != "" and $N[$nid] == null and $nstate == "fail")) } ]
| sort_by([ (.project_name | ascii_downcase), (.name | ascii_downcase), .id ])
'

# shellcheck disable=SC2016
JQ_CSV='
.[]
| select($gwonly == 0 or .has_gw)
| [ .id, .name, .public_ip, .net_name, .project_name, .domain_name ]
  + (if $ext == 1 then [ .project_id, .domain_id, .net_id, .status, .admin, .snat, .ha,
                         .distributed, .created_at, .updated_at ] else [] end)
| map(. // "" | tostring)
| @csv'

CSV_HEADER="Router ID,Router Name,Public IP,Public Network Name,Project Name,Domain Name"
CSV_HEADER_EXT="Project ID,Domain ID,Public Network ID,Status,Admin State,SNAT,HA,Distributed,Created At,Updated At"

# write_csv ROWS — CSV_FILE. umask 077 + noclobber: permission 600, tidak menimpa file.
write_csv() {
    local rows="$1" header="$CSV_HEADER" base ts region n=1 errf="$WORK_DIR/csv.err"
    (( EXTENDED )) && header+=",$CSV_HEADER_EXT"

    jq -r --argjson gwonly "$GW_ONLY" --argjson ext "$EXTENDED" "$JQ_CSV" "$rows" > "$WORK_DIR/rows.csv" || \
        die "Gagal membuat baris CSV."

    if [[ -n "$OUTPUT" ]]; then
        CSV_FILE="$OUTPUT"
    else
        ts="$(date +%Y%m%d-%H%M%S)"
        region="$REGION"
        [[ "$region" == "-" ]] && region="unknown"
        base="${OUTPUT_DIR%/}/list-routers-$(safe_name "$region")-$ts"
        CSV_FILE="$base.csv"
        while [[ -e "$CSV_FILE" || -L "$CSV_FILE" ]]; do
            n=$(( n + 1 ))
            (( n <= 100 )) || die "Tidak bisa menentukan nama file output unik ($base-N.csv)."
            CSV_FILE="$base-$n.csv"
        done
    fi

    if ! ( umask 077; set -o noclobber
           { printf '%s\n' "$header"; cat "$WORK_DIR/rows.csv"; } > "$CSV_FILE" ) 2>"$errf"; then
        local msg
        msg="gagal menulis $CSV_FILE: $(last_error_line "$errf")"
        CSV_FILE=""
        die "$msg"
    fi
    chmod 600 "$CSV_FILE" 2>/dev/null || true
    return 0
}

# ============================================================
# 4. Ringkasan
# ============================================================

print_summary() {
    local rows="$1" stats total with without pmiss dmiss lfail written
    stats="$(jq -r --argjson gwonly "$GW_ONLY" '
        [ length,
          ([ .[] | select(.has_gw) ] | length),
          ([ .[] | select(.has_gw | not) ] | length),
          ([ .[] | select(.project_missing) ] | length),
          ([ .[] | select(.domain_missing) ] | length),
          ([ .[] | select(.lookup_failed) ] | length),
          ([ .[] | select($gwonly == 0 or .has_gw) ] | length)
        ] | map(tostring) | join(" ")' "$rows")"
    read -r total with without pmiss dmiss lfail written <<< "$stats"

    echo
    echo "${C_BOLD}── Ringkasan${C_RESET}"
    printf '  %-29s : %s\n' "Region" "$REGION"
    printf '  %-29s : %s\n' "Metode" "$USED_METHOD"
    printf '  %-29s : %s\n' "Total router" "$total"
    printf '  %-29s : %s\n' "Dengan gateway" "$with"
    printf '  %-29s : %s\n' "Tanpa gateway" "$without"
    printf '  %-29s : %s\n' "Project tidak ditemukan" "$pmiss"
    printf '  %-29s : %s\n' "Domain tidak ditemukan" "$dmiss"
    if (( PARTIAL )); then
        printf '  %-29s : %s\n' "Router dengan lookup gagal" "$lfail"
    fi
    printf '  %-29s : %s%s\n' "Ditulis ke CSV" "$written router" \
        "$( (( GW_ONLY )) && echo " (--with-gateway-only)")"
    printf '  %-29s : %s\n' "File CSV" "$CSV_FILE"
    if (( PARTIAL )); then
        echo "  ${C_RED}❌ Sebagian lookup gagal; lihat peringatan di atas (exit 1).${C_RESET}"
    else
        echo "  ${C_GREEN}✅ Selesai${C_RESET}"
    fi

    log_event SUMMARY "region=$REGION" "method=$USED_METHOD" "total=$total" "with_gateway=$with" \
        "without_gateway=$without" "project_not_found=$pmiss" "domain_not_found=$dmiss" \
        "lookup_failed=$lfail" "written=$written" "extended=$EXTENDED" "gateway_only=$GW_ONLY" \
        "file=$CSV_FILE" "partial=$PARTIAL"
}

main() {
    parse_args "$@"
    require_deps

    echo "========================================"
    echo "             List Routers"
    echo "========================================"

    log_event INPUT "method=$METHOD" "output=${OUTPUT:--}" "extended=$EXTENDED" "gateway_only=$GW_ONLY"
    log_event OPTIONS "os_cmd=${OS_CMD[*]}" "curl=$API_CURL" "page_limit=${PAGE_LIMIT:--}"

    LOG_EXIT_HOOK=on_exit
    make_work_dir
    detect_region

    local routers="$WORK_DIR/routers.json" rows="$WORK_DIR/rows.json"
    fetch_routers "$routers"
    load_lookups
    canon_ipv6 "$routers" "$WORK_DIR/v6.json"

    jq --slurpfile N "$WORK_DIR/networks.json" --slurpfile P "$WORK_DIR/projects.json" \
        --slurpfile D "$WORK_DIR/domains.json" --slurpfile V6 "$WORK_DIR/v6.json" \
        --arg nstate "$NETWORKS_STATE" --arg pstate "$PROJECTS_STATE" --arg dstate "$DOMAINS_STATE" \
        "$JQ_ROWS" "$routers" > "$rows" || die "Gagal menggabungkan data router."

    write_csv "$rows"
    print_summary "$rows"
    echo
    echo "Log : ${LOG_FILE:-(logging nonaktif)}"

    (( PARTIAL )) && exit 1
    return 0
}

main "$@"
