#!/bin/bash
# ============================================================
# @name:        Live Migrate Instances
# @description: Live migrate a list of instances to a target compute host with monitoring
# @mutates:     yes
# @requires:    admin, jq
# @tags:        nova, live-migration, rebalance, compute
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: live-migrate.sh [--file PATH] [--target HOST] [--dry-run]
                       [--interval DETIK] [--timeout MENIT] [--delay DETIK]

Live migration sekumpulan VM ke satu compute host tujuan, satu per satu,
dengan konfirmasi per VM, pemantauan progres, dan opsi abort.

Options:
  --file PATH        File daftar instance ID (satu per baris, # = komentar)
  --target HOST      Host tujuan (melewati picker; tetap divalidasi enabled/up)
  --dry-run          Hanya pre-check dan rencana, tanpa migrasi
  --interval DETIK   Interval polling (default 5)
  --timeout MENIT    Batas waktu per migrasi sebelum ditanya wait/abort
                     (default 30; akhiran s untuk detik, mis. 90s)
  --delay DETIK      Jeda antar migrasi (default 0)
  -h, --help         Tampilkan help

Tanpa argumen, semua input ditanyakan secara interaktif.

Environment:
  OSOPS_OS_CMD                Perintah OpenStack CLI (default: openstack),
                              mis. "oc exec -n openstack openstackclient -- openstack"
  OSOPS_COMPUTE_API_VERSION   Compute microversion (default 2.65, minimum 2.30)

Konfirmasi per VM: y = migrate, n = lewati, c = ganti host tujuan untuk
VM ini, q = hentikan batch. Saat pemantauan: a = abort (dengan konfirmasi).
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

# ============================================================
# Konfigurasi
# ============================================================

INTERVAL=5
TIMEOUT_SPEC=30
TIMEOUT_SEC=1800
DELAY=0
DRY_RUN=0
INPUT_FILE=""
TARGET=""

# Compute microversion (satu tempat, bisa di-override):
#   2.23 migration list per server, 2.24 abort migrasi running,
#   2.25 block migration otomatis, 2.30 host tujuan divalidasi scheduler,
#   2.65 abort migrasi queued/preparing.
# Tetap < 2.88 agar "hypervisor list --long" masih berisi vCPU/RAM.
COMPUTE_API_VERSION="${OSOPS_COMPUTE_API_VERSION:-2.65}"
MV_REQUIRED="2.30"
MV_ABORT_QUEUED="2.65"

# Wrapper OpenStack CLI. Array tidak bisa di-export, jadi override
# lewat string, mis. RHOSO: OSOPS_OS_CMD="oc exec -n openstack openstackclient -- openstack"
if [[ -n "${OSOPS_OS_CMD:-}" ]]; then
    read -ra OS_CMD <<< "$OSOPS_OS_CMD"
else
    OS_CMD=(openstack)
fi

US=$'\x1f'

# State batch (dipakai juga oleh on_interrupt)
ENTRIES=()
HOSTS=()
HOST_LABELS=()
RESULTS=()
declare -A COUNTS=()
declare -A PROJECT_NAMES=()
N_LINES=0
N_DUP=0
N_INVALID=0
REPORT_FILE=""
BATCH_STARTED=0
CUR_IDX=0
CUR_DONE=0
CUR_ID=""
CUR_NAME="-"
CUR_SRC="-"
CUR_DST="-"
MIGRATING=0
MON_START=0
ABORT_REQUESTED=0
MIG_BASE_ID=0
MIG_ID=""
MIG_STATUS=""
PROGRESS="-"
PICKED=""
CHOICE=""
SKIP_REASON=""
RESULT=""
RESULT_MSG=""
FAIL_MSG=""
POST_WARN=""

if [[ -t 1 ]]; then
    C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m' C_RESET=$'\e[0m'
else
    C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_RESET=""
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

# ask VAR PROMPT — semua prompt membaca dari /dev/tty (bukan stdin/file input)
# (nama lokal unik: printf -v harus mengisi variabel milik pemanggil)
ask() {
    local __ask_reply=""
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

valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# Nama host sama persis, atau sama nama pendeknya (sebelum titik pertama)
host_match() {
    [[ "$1" == "$2" || "${1%%.*}" == "${2%%.*}" ]]
}

# mv_ge A B => true jika microversion A >= B
mv_ge() {
    local a_maj="${1%%.*}" a_min="${1#*.}" b_maj="${2%%.*}" b_min="${2#*.}"
    (( a_maj > b_maj || (a_maj == b_maj && a_min >= b_min) ))
}

fmt_elapsed() {
    printf '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 ))
}

fmt_timeout() {
    if (( TIMEOUT_SEC % 60 == 0 )); then
        printf '%d menit' $(( TIMEOUT_SEC / 60 ))
    else
        printf '%d detik' "$TIMEOUT_SEC"
    fi
}

term_cols() {
    local size
    size="$(stty size < /dev/tty 2>/dev/null)" || size=""
    size="${size#* }"
    [[ "$size" =~ ^[0-9]+$ ]] && (( size > 20 )) || size=120
    printf '%s' "$size"
}

# ============================================================
# OpenStack CLI wrapper
# ============================================================

# Query (output ke stdout, tidak dicatat sebagai CMD)
os_cli() {
    "${OS_CMD[@]}" --os-compute-api-version "$COMPUTE_API_VERSION" "$@"
}

# Aksi yang mengubah resource: dicatat (CMD) dan stderr disimpan di LOG_LAST_ERROR
os_run() {
    log_run "${OS_CMD[@]}" --os-compute-api-version "$COMPUTE_API_VERSION" "$@"
}

# ============================================================
# Setup: argumen, dependency, microversion
# ============================================================

need_value() {
    [[ -n "${2:-}" ]] || die "$1 membutuhkan nilai."
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --file)     need_value "$1" "${2:-}"; INPUT_FILE="$2"; shift 2 ;;
            --target)   need_value "$1" "${2:-}"; TARGET="$2"; shift 2 ;;
            --interval) need_value "$1" "${2:-}"; INTERVAL="$2"; shift 2 ;;
            --timeout)  need_value "$1" "${2:-}"; TIMEOUT_SPEC="$2"; shift 2 ;;
            --delay)    need_value "$1" "${2:-}"; DELAY="$2"; shift 2 ;;
            --dry-run)  DRY_RUN=1; shift ;;
            *)          die "Parameter tidak dikenal: $1 (lihat --help)" ;;
        esac
    done

    [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "--interval harus bilangan bulat > 0 (detik)."
    [[ "$DELAY" =~ ^[0-9]+$ ]] || die "--delay harus bilangan bulat >= 0 (detik)."

    if [[ "$TIMEOUT_SPEC" =~ ^[1-9][0-9]*$ ]]; then
        TIMEOUT_SEC=$(( TIMEOUT_SPEC * 60 ))
    elif [[ "$TIMEOUT_SPEC" =~ ^([1-9][0-9]*)s$ ]]; then
        TIMEOUT_SEC="${BASH_REMATCH[1]}"
    else
        die "--timeout harus bilangan bulat > 0 (menit), atau detik dengan akhiran s."
    fi

    return 0
}

require_deps() {
    command -v jq >/dev/null 2>&1 || \
        die "jq tidak ditemukan. Install jq terlebih dahulu (dnf/apt install jq)."
    command -v "${OS_CMD[0]}" >/dev/null 2>&1 || \
        die "OpenStack CLI tidak ditemukan: ${OS_CMD[0]}"
    if (( ! DRY_RUN )); then
        command -v flock >/dev/null 2>&1 || \
            die "flock (util-linux) tidak ditemukan."
    fi
    return 0
}

check_microversion() {
    local json="" max=""

    [[ "$COMPUTE_API_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || \
        die "OSOPS_COMPUTE_API_VERSION tidak valid: $COMPUTE_API_VERSION"
    mv_ge "$COMPUTE_API_VERSION" "$MV_REQUIRED" || \
        die "Compute microversion $COMPUTE_API_VERSION < $MV_REQUIRED (host tujuan harus divalidasi scheduler)."

    if json="$(os_cli versions show --service compute -f json 2>/dev/null)"; then
        max="$(jq -r '
            [ .[] | select((."Status" // "" | ascii_upcase) == "CURRENT")
                  | ."Max Microversion" | select(. != null and . != "") ]
            | first // empty' <<< "$json" 2>/dev/null)" || max=""
    fi

    if [[ -z "$max" ]]; then
        warn "Max compute microversion cloud tidak bisa dicek, memakai $COMPUTE_API_VERSION."
    else
        mv_ge "$max" "$MV_REQUIRED" || \
            die "Cloud hanya mendukung compute microversion $max (< $MV_REQUIRED): live migration ke host tertentu tidak bisa divalidasi scheduler."

        if ! mv_ge "$max" "$COMPUTE_API_VERSION"; then
            warn "Max compute microversion cloud $max < $COMPUTE_API_VERSION, memakai $max."
            COMPUTE_API_VERSION="$max"
        fi
    fi

    if ! mv_ge "$COMPUTE_API_VERSION" "$MV_ABORT_QUEUED"; then
        warn "Microversion $COMPUTE_API_VERSION < $MV_ABORT_QUEUED: abort hanya bisa untuk migrasi berstatus running (bukan queued/preparing)."
    fi

    log_event MICROVERSION "compute_api_version=$COMPUTE_API_VERSION" "cloud_max=${max:--}"
    return 0
}

# ============================================================
# Input: daftar instance ID
# ============================================================

# Seluruh file dibaca ke array lebih dulu (mapfile): prompt di dalam loop
# batch tidak boleh ikut membaca file input.
load_ids() {
    local -a raw=()
    local -A seen=()
    local line key

    mapfile -t raw < "$INPUT_FILE"

    for line in "${raw[@]}"; do
        line="${line//$'\r'/}"
        line="${line%%#*}"
        line="$(trim "$line")"
        [[ -z "$line" ]] && continue

        N_LINES=$(( N_LINES + 1 ))
        key="${line,,}"

        if [[ -n "${seen[$key]+x}" ]]; then
            N_DUP=$(( N_DUP + 1 ))
            continue
        fi
        seen[$key]=1

        if valid_uuid "$line"; then
            ENTRIES+=("$key")
        else
            N_INVALID=$(( N_INVALID + 1 ))
            ENTRIES+=("$line")
        fi
    done

    return 0
}

# ============================================================
# Host tujuan
# ============================================================

load_hosts() {
    local svc hyp h stats

    svc="$(os_cli compute service list --service nova-compute -f json)" || \
        die "Gagal mengambil daftar compute service."

    mapfile -t HOSTS < <(
        jq -r '.[] | select((.Status // "" | ascii_downcase) == "enabled"
                            and (.State // "" | ascii_downcase) == "up") | .Host' <<< "$svc" | sort -u
    )

    (( ${#HOSTS[@]} > 0 )) || die "Tidak ada compute host nova-compute yang enabled dan up."

    # Utilisasi opsional: field vCPU/RAM tidak ada di microversion >= 2.88
    hyp="$(os_cli hypervisor list --long -f json 2>/dev/null)" || hyp="[]"

    HOST_LABELS=()
    for h in "${HOSTS[@]}"; do
        stats="$(jq -r --arg h "$h" '
            def short: split(".")[0];
            [ .[] | select((."Hypervisor Hostname" // "") as $n
                           | $n == $h or ($n | short) == ($h | short)) ][0]
            | if . == null or ."vCPUs" == null or ."vCPUs Used" == null
                 or ."Memory MB" == null or ."Memory MB Used" == null then empty
              else "vCPU \(."vCPUs Used")/\(."vCPUs")  RAM \(((."Memory MB Used") / 1024 * 10 | floor) / 10)/\(((."Memory MB") / 1024 * 10 | floor) / 10) GiB"
              end' <<< "$hyp" 2>/dev/null)" || stats=""
        HOST_LABELS+=("$(printf '%-32s %s' "$h" "$stats")")
    done

    return 0
}

is_valid_host() {
    local h
    for h in "${HOSTS[@]}"; do
        [[ "$h" == "$1" ]] && return 0
    done
    return 1
}

# Picker host (fzf, fallback menu bernomor). Hasil di PICKED.
pick_target() {
    local title="$1" line="" answer i

    PICKED=""

    if command -v fzf >/dev/null 2>&1; then
        line="$(printf '%s\n' "${HOST_LABELS[@]}" |
            fzf --layout=reverse --border --info=inline --height=40% \
                --prompt='🎯 host > ' --header="$title")" || line=""
        PICKED="${line%% *}"
    else
        echo
        echo "$title"
        for i in "${!HOST_LABELS[@]}"; do
            printf '  %2d. %s\n' $(( i + 1 )) "${HOST_LABELS[$i]}"
        done
        ask answer "Pilih host [1-${#HOSTS[@]}]: "
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#HOSTS[@]} )); then
            PICKED="${HOSTS[$((answer - 1))]}"
        fi
    fi

    [[ -n "$PICKED" ]]
}

# ============================================================
# State server & pre-check
# ============================================================

# Satu panggilan "server show" (jq, default "-" untuk null). Return 1 jika
# server tidak bisa dibaca (pesan di ST_ERR).
get_state() {
    local id="$1" json errf

    ST_NAME="-" ST_STATUS="-" ST_TASK="-" ST_LOCKED="-" ST_HOST="-" ST_POWER="-"
    ST_PROJECT="-" ST_FLAVOR="-" ST_VCPUS="-" ST_RAM="-" ST_IMAGE="-" ST_ERR=""

    errf="$(mktemp)"
    if ! json="$(os_cli server show "$id" -f json 2>"$errf")"; then
        ST_ERR="$(tail -n 1 "$errf")"
        rm -f "$errf"
        return 1
    fi
    rm -f "$errf"

    if ! IFS="$US" read -r ST_NAME ST_STATUS ST_TASK ST_LOCKED ST_HOST ST_POWER \
            ST_PROJECT ST_FLAVOR ST_VCPUS ST_RAM ST_IMAGE < <(
        jq -r '
            def v: if . == null or . == "" then "-" else tostring end;
            (if (.flavor | type) == "object" then .flavor else {} end) as $f
            | [ .name, .status, ."OS-EXT-STS:task_state", .locked,
                ."OS-EXT-SRV-ATTR:host", ."OS-EXT-STS:power_state", .project_id,
                (if (.flavor | type) == "object" then ($f.original_name // $f.name) else .flavor end),
                $f.vcpus, $f.ram, .image ]
            | map(v) | join("\u001f")' <<< "$json" 2>/dev/null
    ); then
        ST_ERR="output server show bukan JSON yang valid"
        return 1
    fi

    return 0
}

# SKIP_REASON kosong => VM boleh di-migrate ke $2
precheck() {
    local id="$1" dst="$2"

    SKIP_REASON=""

    if ! get_state "$id"; then
        SKIP_REASON="not found"
    elif [[ "$ST_STATUS" != "ACTIVE" ]]; then
        SKIP_REASON="status=$ST_STATUS"
    elif [[ "$ST_TASK" != "-" ]]; then
        SKIP_REASON="busy: $ST_TASK"
    elif [[ "${ST_LOCKED,,}" == "true" ]]; then
        SKIP_REASON="locked"
    elif [[ "$ST_HOST" == "$dst" ]]; then
        SKIP_REASON="already on target"
    fi

    return 0
}

project_label() {
    local p="$1" name

    if [[ "$p" == "-" ]]; then
        PROJECT_LABEL="-"
        return 0
    fi

    if [[ -z "${PROJECT_NAMES[$p]+x}" ]]; then
        name="$(os_cli project show "$p" -f value -c name 2>/dev/null)" || name=""
        PROJECT_NAMES[$p]="${name:--}"
    fi

    PROJECT_LABEL="${PROJECT_NAMES[$p]} ($p)"
}

show_summary() {
    local id="$1" dst="$2" flavor disk

    project_label "$ST_PROJECT"

    flavor="$ST_FLAVOR"
    if [[ "$ST_VCPUS" != "-" ]]; then
        flavor+=" (${ST_VCPUS} vCPU, ${ST_RAM} MB RAM)"
    fi

    if [[ "$ST_IMAGE" == "-" || "$ST_IMAGE" == N/A* ]]; then
        disk="boot from volume"
    else
        disk="disk lokal (block migration, bisa lebih lama)"
    fi

    echo
    printf '%-12s: %s\n' "Name" "$ST_NAME"
    printf '%-12s: %s\n' "ID" "$id"
    printf '%-12s: %s\n' "Project" "$PROJECT_LABEL"
    printf '%-12s: %s\n' "Flavor" "$flavor"
    printf '%-12s: %s\n' "Host asal" "$ST_HOST"
    printf '%-12s: %s%s%s\n' "Host tujuan" "$C_BOLD" "$dst" "$C_RESET"
    printf '%-12s: %s\n' "Disk" "$disk"
    echo
}

confirm_vm() {
    local answer

    ask answer "Migrate VM ini? [y]es / [N]o / [c]hange target / [q]uit batch: "

    case "${answer,,}" in
        y|yes) CHOICE="y" ;;
        c)     CHOICE="c" ;;
        q)     CHOICE="q" ;;
        *)     CHOICE="n" ;;
    esac
}

# ============================================================
# Migrasi, pemantauan, abort
# ============================================================

# Migrasi live terbaru (Id > MIG_BASE_ID) => MIG_ID, MIG_STATUS (kosong jika belum ada)
fetch_migration() {
    local id="$1" json

    MIG_ID=""
    MIG_STATUS=""

    json="$(os_cli server migration list --server "$id" --type live-migration -f json 2>/dev/null)" || return 0

    IFS="$US" read -r MIG_ID MIG_STATUS < <(
        jq -r --argjson base "${MIG_BASE_ID:-0}" '
            [ .[] | select(.Id != null and (.Id | tonumber) > $base) ]
            | sort_by(.Id | tonumber) | last
            | if . == null then "\u001f" else "\(.Id)\u001f\(.Status // "-")" end' <<< "$json" 2>/dev/null
    ) || true

    return 0
}

# Progres dari memory_total_bytes/memory_remaining_bytes => PROGRESS ("-" jika belum ada)
fetch_progress() {
    local id="$1" mid="$2" json

    PROGRESS="-"
    json="$(os_cli server migration show "$id" "$mid" -f json 2>/dev/null)" || return 0

    PROGRESS="$(jq -r '
        (."Memory Total Bytes" | tonumber? // 0) as $t
        | (."Memory Remaining Bytes" | tonumber? // null) as $r
        | if $t > 0 and $r != null then "\((($t - $r) * 100 / $t) | floor)%" else "-" end' <<< "$json" 2>/dev/null)" || PROGRESS="-"

    return 0
}

abort_migration() {
    local id="$1" name="$2" answer

    ask answer "Yakin abort live migration $name? [y/N]: "
    if ! is_yes "$answer"; then
        echo "Abort dibatalkan, pemantauan dilanjutkan."
        log_event DECISION "resource=$id" abort=declined
        return 0
    fi
    log_event DECISION "resource=$id" abort=confirmed

    fetch_migration "$id"

    case "$MIG_STATUS" in
        running) ;;
        queued|preparing)
            if ! mv_ge "$COMPUTE_API_VERSION" "$MV_ABORT_QUEUED"; then
                warn "Migrasi berstatus $MIG_STATUS hanya bisa di-abort dengan microversion >= $MV_ABORT_QUEUED. Coba lagi saat status running."
                return 0
            fi
            ;;
        *)
            warn "Tidak ada migrasi aktif (queued/preparing/running) untuk di-abort (status: ${MIG_STATUS:--})."
            return 0
            ;;
    esac

    if os_run server migration abort "$id" "$MIG_ID"; then
        ABORT_REQUESTED=1
        echo "🛑 Abort diminta. Menunggu Nova menyelesaikan abort..."
        log_event ABORT_REQUESTED "resource=$id" "migration_id=$MIG_ID" "migration_status=$MIG_STATUS"
    else
        warn "Abort ditolak: ${LOG_LAST_ERROR:-tidak ada pesan dari API}. Pemantauan dilanjutkan."
    fi

    return 0
}

timeout_prompt() {
    local id="$1" name="$2" answer

    warn "Migrasi $name melewati batas waktu $(fmt_timeout) (elapsed $(fmt_elapsed $(( SECONDS - MON_START ))), migration=${MIG_STATUS:--}, progress=$PROGRESS)."
    log_event TIMEOUT "resource=$id" "elapsed=$(( SECONDS - MON_START ))" "migration_status=${MIG_STATUS:--}" "progress=$PROGRESS"

    ask answer "[W]ait $(fmt_timeout) lagi / [a]bort: "

    if [[ "${answer,,}" == "a" ]]; then
        log_event DECISION "resource=$id" timeout=abort
        abort_migration "$id" "$name"
    else
        log_event DECISION "resource=$id" timeout=wait
        echo "Menunggu $(fmt_timeout) lagi..."
    fi
}

# Pantau sampai task_state kosong. Satu baris status diperbarui di tempat.
monitor() {
    local id="$1" name="$2" key line cols deadline last_status="" errors=0

    MON_START=$SECONDS
    deadline=$(( MON_START + TIMEOUT_SEC ))
    PROGRESS="-"
    MIG_ID=""
    MIG_STATUS=""
    cols="$(term_cols)"

    while true; do
        if ! get_state "$id"; then
            errors=$(( errors + 1 ))
            if (( errors >= 5 )); then
                printf '\n'
                warn "Server $id tidak bisa dibaca 5x berturut-turut: ${ST_ERR:-?}"
                break
            fi
        else
            errors=0
            [[ "$ST_TASK" == "-" ]] && break

            fetch_migration "$id"
            if [[ -n "$MIG_STATUS" && "$MIG_STATUS" != "$last_status" ]]; then
                log_event MIGRATION_STATUS "resource=$id" "migration_id=$MIG_ID" \
                    "status=$MIG_STATUS" "elapsed=$(( SECONDS - MON_START ))"
                last_status="$MIG_STATUS"
            fi

            if [[ "$MIG_STATUS" == "running" ]]; then
                fetch_progress "$id" "$MIG_ID"
            fi
        fi

        line="[$name] status=$ST_STATUS migration=${MIG_STATUS:--} progress=$PROGRESS"
        line+=" elapsed=$(fmt_elapsed $(( SECONDS - MON_START )))"
        (( ABORT_REQUESTED )) && line+="  (abort diminta)"
        line+="  [a] abort"
        printf '\r\e[K%s' "${line:0:cols-1}"

        if (( SECONDS >= deadline )); then
            printf '\n'
            timeout_prompt "$id" "$name"
            deadline=$(( SECONDS + TIMEOUT_SEC ))
            continue
        fi

        key=""
        read -rsn1 -t "$INTERVAL" key < /dev/tty || key=""

        if [[ "$key" == [aA] ]]; then
            printf '\n'
            abort_migration "$id" "$name"
        fi
    done

    printf '\n'
}

# Pesan error dari server event (action live-migration terbaru) => FAIL_MSG
failure_message() {
    local id="$1" events req show

    FAIL_MSG=""

    events="$(os_cli server event list "$id" -f json 2>/dev/null)" || return 0
    req="$(jq -r '[ .[] | select((.Action // "") == "live-migration") ]
                  | sort_by(."Start Time" // "") | last | ."Request ID" // empty' <<< "$events" 2>/dev/null)" || req=""
    [[ -n "$req" ]] || return 0

    show="$(os_cli server event show "$id" "$req" -f json 2>/dev/null)" || return 0
    FAIL_MSG="$(jq -r '
        [ (.message // empty),
          ( (.events // [])[]
            | select((.result // "") | test("error|fail"; "i"))
            | "\(.event): \(.result)"
              + (if (.traceback // "") != ""
                 then " - " + (.traceback | split("\n") | map(select(test("\\S"))) | last)
                 else "" end) ) ]
        | map(select(. != null and . != "")) | join("; ")' <<< "$show" 2>/dev/null)" || FAIL_MSG=""

    return 0
}

# RESULT & RESULT_MSG dari state akhir server
determine_result() {
    local id="$1" src="$2" dst="$3"

    RESULT_MSG=""

    if ! get_state "$id"; then
        RESULT="FAILED"
        RESULT_MSG="server tidak bisa dibaca setelah migrasi: ${ST_ERR:-?}"
        return 0
    fi

    if [[ "$ST_STATUS" == "ERROR" ]]; then
        failure_message "$id"
        RESULT="FAILED"
        RESULT_MSG="status=ERROR${FAIL_MSG:+; $FAIL_MSG}"
    elif [[ "$ST_HOST" == "$dst" ]]; then
        RESULT="SUCCESS"
        (( ABORT_REQUESTED )) && RESULT_MSG="abort terlambat, migrasi sudah selesai"
        if [[ "$ST_STATUS" != "ACTIVE" ]]; then
            RESULT_MSG+="${RESULT_MSG:+; }status=$ST_STATUS"
            warn "$ST_NAME ada di host tujuan tetapi status=$ST_STATUS."
        fi
    elif [[ "$ST_HOST" == "$src" ]]; then
        if (( ABORT_REQUESTED )); then
            RESULT="ABORTED"
            RESULT_MSG="migrasi di-abort operator, VM tetap di host asal"
        else
            failure_message "$id"
            RESULT="FAILED"
            RESULT_MSG="migrasi gagal, VM tetap di host asal (rollback)${FAIL_MSG:+; $FAIL_MSG}"
        fi
    else
        RESULT="SUCCESS"
        RESULT_MSG="host berubah ke $ST_HOST, bukan host tujuan $dst"
        warn "$ST_NAME pindah ke $ST_HOST, bukan host tujuan $dst."
    fi

    return 0
}

# Post-check setelah SUCCESS (hanya warning) => POST_WARN
postcheck() {
    local id="$1" dst="$2" p bh
    local -a ports=() warns=()

    POST_WARN=""

    if get_state "$id"; then
        if [[ "$ST_POWER" != "1" && "${ST_POWER,,}" != "running" ]]; then
            warns+=("power_state=$ST_POWER")
        fi
    fi

    if mapfile -t ports < <(os_cli port list --server "$id" -f value -c ID 2>/dev/null); then
        for p in "${ports[@]}"; do
            [[ -n "$p" ]] || continue
            bh="$(os_cli port show "$p" -f json 2>/dev/null |
                jq -r '.binding_host_id // ."binding:host_id" // "-"' 2>/dev/null)" || bh="?"
            host_match "$bh" "$dst" || warns+=("port $p binding_host_id=$bh")
        done
    else
        warns+=("port list gagal")
    fi

    if (( ${#warns[@]} > 0 )); then
        POST_WARN="$(printf '%s; ' "${warns[@]}")"
        POST_WARN="${POST_WARN%; }"
    fi

    return 0
}

# ============================================================
# Laporan
# ============================================================

init_report() {
    local dir

    if [[ -n "$LOG_FILE" ]]; then
        dir="$(dirname "$LOG_FILE")"
    else
        dir="${TMPDIR:-/tmp}"
    fi

    REPORT_FILE="$dir/live-migrate-${LOG_RUN_ID:-$(date +%Y%m%dT%H%M%S)-$$}-results.tsv"

    if ! ( umask 002; printf 'timestamp\tserver_id\tname\tsrc_host\tdst_host\tresult\tduration_s\tmessage\n' > "$REPORT_FILE" ) 2>/dev/null; then
        warn "Gagal membuat file laporan: $REPORT_FILE"
        REPORT_FILE=""
    fi

    log_event REPORT "file=${REPORT_FILE:--}"
}

tsv_clean() {
    local s="${1//$'\t'/ }"
    s="${s//$'\n'/ }"
    printf '%s' "${s//$'\r'/ }"
}

tsv_row() {
    [[ -n "$REPORT_FILE" ]] || return 0
    {
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" \
            "$(tsv_clean "$1")" "$(tsv_clean "$2")" "$(tsv_clean "$3")" "$(tsv_clean "$4")" \
            "$5" "$6" "$(tsv_clean "$7")" >> "$REPORT_FILE"
    } 2>/dev/null || true
    return 0
}

# record_result ID NAME SRC DST RESULT DURATION MSG — log + TSV (segera)
record_result() {
    log_result "resource=$1" "name=$2" "src=$3" "dst=$4" "result=$5" "duration=$6" "msg=$7"
    tsv_row "$@"
    RESULTS+=("$1$US$2$US$3$US$4$US$5$US$6$US$7")
    COUNTS[$5]=$(( ${COUNTS[$5]:-0} + 1 ))
    CUR_DONE=1
}

# VM mulai index $1 tidak diproses (q / interrupt)
mark_not_processed() {
    local i ids=""

    for (( i = $1; i < ${#ENTRIES[@]}; i++ )); do
        tsv_row "${ENTRIES[$i]}" "-" "-" "-" "NOT_PROCESSED" 0 "belum diproses"
        RESULTS+=("${ENTRIES[$i]}$US-$US-$US-${US}NOT_PROCESSED${US}0${US}belum diproses")
        COUNTS[NOT_PROCESSED]=$(( ${COUNTS[NOT_PROCESSED]:-0} + 1 ))
        ids+="${ids:+,}${ENTRIES[$i]}"
    done

    if [[ -n "$ids" ]]; then
        log_event NOT_PROCESSED "count=${COUNTS[NOT_PROCESSED]}" "ids=$ids"
    fi
    return 0
}

result_color() {
    case "$1" in
        SUCCESS)         printf '%s' "$C_GREEN" ;;
        FAILED|ABORTED)  printf '%s' "$C_RED" ;;
        *)               printf '%s' "$C_YELLOW" ;;
    esac
}

print_summary() {
    local r id name src dst result dur msg

    echo
    echo "========================================================================================"
    echo "                              Ringkasan Live Migration"
    echo "========================================================================================"
    printf '%s%-20s %-36s %-18s %-18s %-13s %5s  %s%s\n' "$C_BOLD" \
        NAME ID SRC DST RESULT DUR MESSAGE "$C_RESET"

    for r in "${RESULTS[@]}"; do
        IFS="$US" read -r id name src dst result dur msg <<< "$r"
        printf '%-20s %-36s %-18s %-18s %s%-13s%s %5s  %s\n' \
            "${name:0:20}" "${id:0:36}" "${src:0:18}" "${dst:0:18}" \
            "$(result_color "$result")" "$result" "$C_RESET" "${dur}s" "${msg:0:80}"
    done

    echo
    for result in SUCCESS FAILED ABORTED DECLINED SKIPPED NOT_PROCESSED; do
        printf '%-14s: %d\n' "$result" "${COUNTS[$result]:-0}"
    done

    echo
    echo "Log     : ${LOG_FILE:-(logging nonaktif)}"
    echo "Laporan : ${REPORT_FILE:-(tidak ada)}"
    echo "========================================================================================"
}

# ============================================================
# Keamanan operasional
# ============================================================

check_session() {
    local answer

    [[ -n "${TMUX:-}" || -n "${STY:-}" ]] && return 0

    warn "Tidak berjalan di dalam tmux/screen. Jika koneksi SSH putus, pemantauan berhenti (migrasi yang sedang berjalan tetap dilanjutkan oleh Nova)."
    ask answer "Tetap lanjut? [y/N]: "

    if ! is_yes "$answer"; then
        log_event DECISION session=no-tmux decision=cancel
        echo "❌ Dibatalkan. Jalankan ulang di dalam tmux/screen."
        exit 0
    fi

    log_event DECISION session=no-tmux decision=continue
    return 0
}

acquire_lock() {
    local dir holder

    if [[ -n "$LOG_FILE" ]]; then
        dir="$(dirname "$LOG_FILE")"
    else
        dir="${TMPDIR:-/tmp}"
    fi

    LOCK_FILE="$dir/live-migrate.lock"
    ( umask 002; : >> "$LOCK_FILE" ) 2>/dev/null || true

    exec 9>>"$LOCK_FILE" || die "Tidak bisa membuka lock file: $LOCK_FILE"

    if ! flock -n 9; then
        holder="$(cat "$LOCK_FILE" 2>/dev/null)" || holder=""
        die "Live migration lain sedang berjalan${holder:+ ($holder)}. Lock: $LOCK_FILE"
    fi

    printf 'pid=%s user=%s run=%s\n' "$$" "${SUDO_USER:-$(id -un)}" "${LOG_RUN_ID:--}" > "$LOCK_FILE" 2>/dev/null || true
    log_event LOCK "file=$LOCK_FILE"
}

# Dipanggil lib/logging.sh saat SIGINT/SIGTERM (sebelum exit 130/143)
on_interrupt() {
    local sig="$1" answer="" note

    printf '\n'

    if (( ! BATCH_STARTED )); then
        log_event INTERRUPT "signal=$sig" phase=setup
        return 0
    fi

    if (( MIGRATING )); then
        echo "${C_YELLOW}⚠️  Live migration $CUR_NAME ($CUR_ID) TETAP BERJALAN di Nova; hanya pemantauan yang berhenti.${C_RESET}"
        note="pemantauan dihentikan ($sig); migrasi tetap berjalan di Nova, verifikasi manual"

        if has_tty; then
            printf 'Abort migrasi ini sebelum keluar? [y/N] (30 detik): ' > /dev/tty
            read -r -t 30 answer < /dev/tty || answer=""
        fi

        if is_yes "$answer"; then
            log_event DECISION "resource=$CUR_ID" abort=confirmed phase=interrupt
            fetch_migration "$CUR_ID"
            if [[ -n "$MIG_ID" ]] && os_run server migration abort "$CUR_ID" "$MIG_ID"; then
                note="pemantauan dihentikan ($sig); abort diminta, verifikasi manual"
            else
                note="pemantauan dihentikan ($sig); abort gagal: ${LOG_LAST_ERROR:-tidak ada migrasi aktif}; verifikasi manual"
            fi
        fi

        record_result "$CUR_ID" "$CUR_NAME" "$CUR_SRC" "$CUR_DST" ABORTED \
            $(( SECONDS - MON_START )) "$note"
        mark_not_processed $(( CUR_IDX + 1 ))
    else
        mark_not_processed $(( CUR_IDX + CUR_DONE ))
    fi

    log_event INTERRUPT "signal=$sig" "migrating=$MIGRATING"
    print_summary
    return 0
}

# ============================================================
# Batch
# ============================================================

migrate_vm() {
    local id="$1" dst="$2" src="$ST_HOST" name="$ST_NAME" start dur

    CUR_SRC="$src"
    CUR_DST="$dst"
    ABORT_REQUESTED=0

    # Migrasi lama server ini diabaikan saat mencari migrasi yang baru dimulai
    MIG_BASE_ID=0
    fetch_migration "$id"
    MIG_BASE_ID="${MIG_ID:-0}"

    echo "🚀 Live migrate $name: $src → $dst"
    start=$SECONDS

    if ! os_run server migrate --live-migration --host "$dst" "$id"; then
        echo "${C_RED}❌ Perintah migrate gagal.${C_RESET}"
        record_result "$id" "$name" "$src" "$dst" FAILED $(( SECONDS - start )) \
            "migrate ditolak: ${LOG_LAST_ERROR:-tidak ada pesan}"
        return 0
    fi

    MIGRATING=1
    monitor "$id" "$name"
    MIGRATING=0

    determine_result "$id" "$src" "$dst"
    dur=$(( SECONDS - start ))

    if [[ "$RESULT" == "SUCCESS" ]]; then
        postcheck "$id" "$dst"
        if [[ -n "$POST_WARN" ]]; then
            warn "Post-check $name: $POST_WARN"
            RESULT_MSG+="${RESULT_MSG:+; }postcheck: $POST_WARN"
        fi
    fi

    echo "$(result_color "$RESULT")➡️  $name: $RESULT${RESULT_MSG:+ ($RESULT_MSG)}${C_RESET} [${dur}s]"
    record_result "$id" "$name" "$src" "$dst" "$RESULT" "$dur" "$RESULT_MSG"
}

run_batch() {
    local total=${#ENTRIES[@]} i id dst

    BATCH_STARTED=1

    for (( i = 0; i < total; i++ )); do
        id="${ENTRIES[$i]}"
        CUR_IDX=$i
        CUR_DONE=0
        CUR_ID="$id"
        CUR_NAME="-"
        dst="$TARGET"

        echo
        echo "${C_CYAN}──── [$(( i + 1 ))/$total] $id ────${C_RESET}"

        if ! valid_uuid "$id"; then
            echo "⏭️  SKIPPED (invalid id)"
            record_result "$id" "-" "-" "$dst" SKIPPED 0 "invalid id"
            continue
        fi

        # Pre-check tepat sebelum konfirmasi (state bisa berubah selama batch)
        while true; do
            precheck "$id" "$dst"

            if [[ -n "$SKIP_REASON" ]]; then
                CHOICE="skip"
                break
            fi

            CUR_NAME="$ST_NAME"
            show_summary "$id" "$dst"
            confirm_vm

            [[ "$CHOICE" == "c" ]] || break

            if pick_target "Host tujuan untuk $ST_NAME saja"; then
                dst="$PICKED"
                log_event DECISION "resource=$id" decision=change-target "dst=$dst"
            fi
        done

        case "$CHOICE" in
            skip)
                echo "⏭️  SKIPPED ($SKIP_REASON)"
                record_result "$id" "$ST_NAME" "$ST_HOST" "$dst" SKIPPED 0 "$SKIP_REASON"
                ;;
            n)
                echo "⏭️  Dilewati."
                log_event DECISION "resource=$id" decision=declined
                record_result "$id" "$ST_NAME" "$ST_HOST" "$dst" DECLINED 0 "dilewati operator"
                ;;
            q)
                echo "🛑 Batch dihentikan oleh operator."
                log_event DECISION "resource=$id" decision=quit
                mark_not_processed "$i"
                break
                ;;
            y)
                log_event DECISION "resource=$id" decision=migrate "dst=$dst"
                migrate_vm "$id" "$dst"

                if (( DELAY > 0 && i < total - 1 )); then
                    echo "⏳ Jeda $DELAY detik sebelum VM berikutnya..."
                    sleep "$DELAY"
                fi
                ;;
        esac
    done

    return 0
}

run_dry() {
    local id plan name src will=0 skip=0

    echo
    echo "${C_BOLD}Rencana (dry-run, tanpa migrasi) — host tujuan: $TARGET${C_RESET}"
    printf '%s%-36s %-24s %-20s %-20s %s%s\n' "$C_BOLD" ID NAME SRC DST PLAN "$C_RESET"

    for id in "${ENTRIES[@]}"; do
        name="-"
        src="-"

        if ! valid_uuid "$id"; then
            plan="SKIP (invalid id)"
        else
            precheck "$id" "$TARGET"
            name="$ST_NAME"
            src="$ST_HOST"
            if [[ -n "$SKIP_REASON" ]]; then
                plan="SKIP ($SKIP_REASON)"
            else
                plan="WILL MIGRATE"
            fi
        fi

        if [[ "$plan" == "WILL MIGRATE" ]]; then
            will=$(( will + 1 ))
        else
            skip=$(( skip + 1 ))
        fi

        log_info "PLAN dry_run=true resource=$id name=$name src=$src dst=$TARGET plan=\"$plan\""
        printf '%-36s %-24s %-20s %-20s %s\n' "${id:0:36}" "${name:0:24}" "${src:0:20}" "${TARGET:0:20}" "$plan"
    done

    echo
    echo "WILL MIGRATE : $will"
    echo "SKIP         : $skip"
    echo "Log          : ${LOG_FILE:-(logging nonaktif)}"
    log_info "PLAN_SUMMARY dry_run=true will_migrate=$will skip=$skip"
}

# ============================================================
# Main
# ============================================================

main() {
    parse_args "$@"
    require_deps

    echo "========================================"
    echo "       Live Migrate Instances"
    echo "========================================"

    log_event OPTIONS "dry_run=$DRY_RUN" "interval=$INTERVAL" "timeout_s=$TIMEOUT_SEC" \
        "delay=$DELAY" "target=${TARGET:--}" "os_cmd=${OS_CMD[*]}"

    check_microversion

    # File input
    if [[ -z "$INPUT_FILE" ]]; then
        has_tty || die "Tidak ada terminal untuk input interaktif; gunakan --file."
        ask INPUT_FILE "Path file daftar instance ID: "
    fi
    INPUT_FILE="${INPUT_FILE/#\~/$HOME}"

    [[ -n "$INPUT_FILE" ]] || die "Path file tidak boleh kosong."
    [[ -f "$INPUT_FILE" && -r "$INPUT_FILE" ]] || \
        die "File '$INPUT_FILE' tidak ditemukan atau tidak bisa dibaca."

    load_ids
    (( ${#ENTRIES[@]} > 0 )) || die "Tidak ada instance ID di dalam file."

    echo "📄 Input   : $INPUT_FILE"
    echo "🔢 ID      : ${#ENTRIES[@]} unik ($(( ${#ENTRIES[@]} - N_INVALID )) valid, $N_INVALID tidak valid), $N_DUP duplikat diabaikan"
    log_event INPUT "input_file=$INPUT_FILE" "lines=$N_LINES" "unique=${#ENTRIES[@]}" \
        "valid=$(( ${#ENTRIES[@]} - N_INVALID ))" "invalid=$N_INVALID" "duplicates=$N_DUP"

    # Host tujuan (sekali untuk seluruh batch)
    load_hosts

    if [[ -n "$TARGET" ]]; then
        is_valid_host "$TARGET" || \
            die "Host tujuan '$TARGET' tidak ditemukan atau tidak enabled/up (nova-compute)."
        log_event TARGET "dst=$TARGET" source=argument
    else
        has_tty || die "Tidak ada terminal untuk memilih host; gunakan --target."
        pick_target "Pilih host tujuan (untuk seluruh batch)" || die "Host tujuan tidak dipilih."
        TARGET="$PICKED"
        log_event TARGET "dst=$TARGET" source=picker
    fi

    echo "🎯 Tujuan  : $TARGET"
    echo "🔧 API     : compute microversion $COMPUTE_API_VERSION"

    if (( DRY_RUN )); then
        run_dry
        return 0
    fi

    has_tty || die "Migrasi butuh terminal interaktif (/dev/tty) untuk konfirmasi per VM."

    check_session
    acquire_lock
    init_report

    LOG_INTERRUPT_HOOK=on_interrupt
    run_batch
    LOG_INTERRUPT_HOOK=""

    print_summary

    (( ${COUNTS[FAILED]:-0} == 0 ))
}

main "$@"
