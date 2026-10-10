#!/bin/bash
# ============================================================
# @name:        Delete Volume
# @description: Delete available Cinder volumes (single ID or list), including snapshots (--purge)
# @mutates:     yes
# @requires:    admin, jq
# @tags:        cinder, volume, snapshot, delete, purge, cleanup
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: delete-volume.sh [--id VOLUME_ID | --file PATH] [--no-confirm] [--dry-run]
                        [--interval DETIK] [--timeout MENIT]

Hapus volume Cinder berstatus "available" beserta seluruh snapshot-nya
(openstack volume delete --purge), satu per satu, lalu tunggu sampai
volume benar-benar hilang. Operasi ini PERMANEN dan tidak bisa dibatalkan.

Options:
  --id VOLUME_ID     Satu volume (UUID)
  --file PATH        File daftar volume ID (satu per baris, # = komentar)
  --no-confirm       Tanpa konfirmasi per volume: rencana lengkap ditampilkan
                     lalu SATU konfirmasi batch (ketik jumlah volume)
  --dry-run          Hanya validasi dan rencana, tanpa menghapus apa pun
  --interval DETIK   Interval polling penghapusan (default 3)
  --timeout MENIT    Batas waktu menunggu penghapusan per volume
                     (default 10; akhiran s untuk detik, mis. 90s)
  -h, --help         Tampilkan help

--id dan --file tidak bisa dipakai bersamaan. Tanpa argumen, mode input
dan mode konfirmasi ditanyakan secara interaktif.

Hanya volume berstatus "available" yang dihapus. Volume dengan status
lain, atau dengan snapshot berstatus selain available/error, dilewati
(tidak ada detach, reset-state, atau --force).

Konfirmasi per volume: y = hapus, n = lewati, q = hentikan batch.

Environment:
  OSOPS_OS_CMD   Perintah OpenStack CLI (default: openstack),
                 mis. "oc exec -n openstack openstackclient -- openstack"
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

INTERVAL=3
TIMEOUT_SPEC=10
TIMEOUT_SEC=600
DRY_RUN=0
NO_CONFIRM=0
INPUT_MODE=""
VOLUME_ID=""
INPUT_FILE=""
ACTION="delete-volume-purge"

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
RESULTS=()
SNAPS=()
declare -A COUNTS=()
declare -A PROJECT_CACHE=()
declare -A DOMAIN_CACHE=()
declare -A INFO=()
declare -A PLAN_SKIP=()
declare -A PLAN_SNAPKEY=()
N_LINES=0
N_DUP=0
N_INVALID=0
REPORT_FILE=""
BATCH_STARTED=0
CUR_IDX=0
CUR_DONE=0
DELETING=0
DEL_START=0
SNAPS_DELETED=0
GB_FREED=0
SNAP_GB_FREED=0
SKIP_REASON=""
CHOICE=""
RESULT=""
RESULT_MSG=""

# Info volume terakhir yang dibaca (validate_volume)
V_NAME="-" V_STATUS="-" V_SIZE="-" V_TYPE="-" V_CREATED="-" V_PROJECT_ID="-" V_ERR=""
P_NAME="-" P_DOMAIN="-"
SNAP_COUNT="-" SNAP_IDS="" SNAP_KEY="" SNAP_ERR="" SNAP_BAD_ID="" SNAP_BAD_STATUS=""

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

# Baris error terakhir yang tidak kosong dari file stderr
last_error_line() {
    grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | cut -c1-300
}

# ============================================================
# OpenStack CLI wrapper
# ============================================================

# Query (output ke stdout, tidak dicatat sebagai CMD)
os_cli() {
    "${OS_CMD[@]}" "$@"
}

# Aksi yang mengubah resource: dicatat (CMD) dan stderr disimpan di LOG_LAST_ERROR
os_run() {
    log_run "${OS_CMD[@]}" "$@"
}

# Hanya "not found" yang eksplisit untuk ID ini yang dianggap tidak ada.
# Error lain (auth, 5xx, endpoint) TIDAK boleh dianggap volume sudah hilang.
is_not_found() {
    local msg="${2,,}" id="${1,,}"
    [[ "$msg" == *"$id"* ]] || return 1
    [[ "$msg" == *"no volume with a name or id of"* ||
       "$msg" == *"could not be found"* ||
       "$msg" == *"(http 404)"* ]]
}

# ============================================================
# Setup: argumen dan dependency
# ============================================================

need_value() {
    [[ -n "${2:-}" ]] || die "$1 membutuhkan nilai."
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --id)         need_value "$1" "${2:-}"; VOLUME_ID="$2"; shift 2 ;;
            --file)       need_value "$1" "${2:-}"; INPUT_FILE="$2"; shift 2 ;;
            --interval)   need_value "$1" "${2:-}"; INTERVAL="$2"; shift 2 ;;
            --timeout)    need_value "$1" "${2:-}"; TIMEOUT_SPEC="$2"; shift 2 ;;
            --no-confirm) NO_CONFIRM=1; shift ;;
            --dry-run)    DRY_RUN=1; shift ;;
            *)            die "Parameter tidak dikenal: $1 (lihat --help)" ;;
        esac
    done

    [[ -n "$VOLUME_ID" && -n "$INPUT_FILE" ]] && die "--id dan --file tidak bisa dipakai bersamaan."
    [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "--interval harus bilangan bulat > 0 (detik)."

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

# ============================================================
# Input: satu ID atau file daftar volume ID
# ============================================================

# add_entry LINE — bersihkan (CR, komentar, spasi), buang duplikat, tandai UUID tidak valid
declare -A SEEN=()
add_entry() {
    local line="$1" key

    line="${line//$'\r'/}"
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && return 0

    N_LINES=$(( N_LINES + 1 ))
    key="${line,,}"

    if [[ -n "${SEEN[$key]+x}" ]]; then
        N_DUP=$(( N_DUP + 1 ))
        return 0
    fi
    SEEN[$key]=1

    if valid_uuid "$line"; then
        ENTRIES+=("$key")
    else
        N_INVALID=$(( N_INVALID + 1 ))
        ENTRIES+=("$line")
    fi
}

# Seluruh file dibaca ke array lebih dulu (mapfile): prompt di dalam loop
# batch tidak boleh ikut membaca file input.
load_ids() {
    local -a raw=()
    local line

    if [[ "$INPUT_MODE" == "id" ]]; then
        add_entry "$VOLUME_ID"
        return 0
    fi

    mapfile -t raw < "$INPUT_FILE"
    for line in "${raw[@]}"; do
        add_entry "$line"
    done

    return 0
}

choose_modes() {
    local answer

    if [[ -n "$VOLUME_ID" ]]; then
        INPUT_MODE="id"
    elif [[ -n "$INPUT_FILE" ]]; then
        INPUT_MODE="file"
    else
        has_tty || die "Tidak ada terminal untuk input interaktif; gunakan --id atau --file."
        echo "Mode input:"
        echo "  1. Satu volume ID"
        echo "  2. File daftar volume ID"
        ask answer "Pilih [1-2] (default 1): "
        case "$(trim "$answer")" in
            ""|1) INPUT_MODE="id"
                  ask VOLUME_ID "Volume ID: "
                  [[ -n "$(trim "$VOLUME_ID")" ]] || die "Volume ID tidak boleh kosong." ;;
            2)    INPUT_MODE="file"
                  ask INPUT_FILE "Path file daftar volume ID: " ;;
            *)    die "Pilihan mode input tidak valid: $answer" ;;
        esac
    fi

    if [[ "$INPUT_MODE" == "file" ]]; then
        INPUT_FILE="${INPUT_FILE/#\~/$HOME}"
        [[ -n "$INPUT_FILE" ]] || die "Path file tidak boleh kosong."
        [[ -f "$INPUT_FILE" && -r "$INPUT_FILE" ]] || \
            die "File '$INPUT_FILE' tidak ditemukan atau tidak bisa dibaca."
    fi

    if (( ! DRY_RUN && ! NO_CONFIRM )); then
        has_tty || die "Penghapusan butuh terminal interaktif (/dev/tty) untuk konfirmasi."
        echo "Mode konfirmasi:"
        echo "  1. Konfirmasi per volume"
        echo "  2. Tanpa konfirmasi per volume (rencana lengkap + satu konfirmasi batch)"
        ask answer "Pilih [1-2] (default 1): "
        case "$(trim "$answer")" in
            ""|1) ;;
            2)    NO_CONFIRM=1 ;;
            *)    die "Pilihan mode konfirmasi tidak valid: $answer" ;;
        esac
    fi

    return 0
}

# ============================================================
# Informasi volume, project/domain, snapshot
# ============================================================

# Satu panggilan "volume show -f json" (jq, default "-" untuk null).
# Return 0 = ada, 1 = tidak ditemukan, 2 = gagal dibaca (pesan di V_ERR).
get_volume() {
    local id="$1" json errf

    V_NAME="-" V_STATUS="-" V_SIZE="-" V_TYPE="-" V_CREATED="-" V_PROJECT_ID="-" V_ERR=""

    errf="$(mktemp)"
    if ! json="$(os_cli volume show "$id" -f json 2>"$errf")"; then
        V_ERR="$(last_error_line "$errf")"
        rm -f "$errf"
        is_not_found "$id" "$V_ERR" && return 1
        V_ERR="${V_ERR:-volume show gagal tanpa pesan}"
        return 2
    fi
    rm -f "$errf"

    if ! IFS="$US" read -r V_NAME V_STATUS V_SIZE V_TYPE V_CREATED V_PROJECT_ID < <(
        jq -r '
            def v: if . == null or . == "" then "-" else tostring end;
            [ .name, .status, .size, (.type // .volume_type), .created_at,
              ."os-vol-tenant-attr:tenant_id" ]
            | map(v) | join("\u001f")' <<< "$json" 2>/dev/null
    ); then
        V_ERR="output volume show bukan JSON yang valid"
        return 2
    fi

    return 0
}

# Nama domain (cache per batch) => D_NAME
resolve_domain() {
    local did="$1" json errf err name

    if [[ "$did" == "-" ]]; then
        D_NAME="-"
        return 0
    fi

    if [[ -z "${DOMAIN_CACHE[$did]+x}" ]]; then
        errf="$(mktemp)"
        if json="$(os_cli domain show "$did" -f json 2>"$errf")" &&
           name="$(jq -r '.name // empty' <<< "$json" 2>/dev/null)" && [[ -n "$name" ]]; then
            DOMAIN_CACHE[$did]="$name"
        else
            err="$(last_error_line "$errf")"
            if [[ "${err,,}" =~ no\ domain|could\ not\ be\ found|http\ 404 ]]; then
                DOMAIN_CACHE[$did]="$did (domain not found)"
            else
                DOMAIN_CACHE[$did]="$did (lookup failed)"
            fi
        fi
        rm -f "$errf"
    fi

    D_NAME="${DOMAIN_CACHE[$did]}"
}

# Nama project + domain (cache per batch) => P_NAME, P_DOMAIN.
# Project/domain yang sudah tidak ada (orphan) tidak menggagalkan script.
resolve_project() {
    local pid="$1" json errf err pname did

    if [[ "$pid" == "-" ]]; then
        P_NAME="-"
        P_DOMAIN="-"
        return 0
    fi

    if [[ -z "${PROJECT_CACHE[$pid]+x}" ]]; then
        errf="$(mktemp)"
        if json="$(os_cli project show "$pid" -f json 2>"$errf")" &&
           IFS="$US" read -r pname did < <(
               jq -r 'def v: if . == null or . == "" then "-" else tostring end;
                      [ .name, .domain_id ] | map(v) | join("\u001f")' <<< "$json" 2>/dev/null
           ); then
            resolve_domain "$did"
            PROJECT_CACHE[$pid]="$pname$US$D_NAME"
        else
            err="$(last_error_line "$errf")"
            if [[ "${err,,}" =~ no\ project|could\ not\ be\ found|http\ 404 ]]; then
                PROJECT_CACHE[$pid]="$pid (project not found)$US-"
            else
                PROJECT_CACHE[$pid]="$pid (lookup failed)$US-"
            fi
        fi
        rm -f "$errf"
    fi

    IFS="$US" read -r P_NAME P_DOMAIN <<< "${PROJECT_CACHE[$pid]}"
}

# Snapshot volume (semua project) => SNAPS (id US name US status US size US created),
# SNAP_COUNT, SNAP_IDS, SNAP_KEY (ID terurut), SNAP_BAD_*. Return 1 jika gagal.
list_snapshots() {
    local id="$1" json errf s sid sname sstatus
    local -a ids=()

    SNAPS=()
    SNAP_COUNT="-" SNAP_IDS="" SNAP_KEY="" SNAP_ERR="" SNAP_BAD_ID="" SNAP_BAD_STATUS=""

    errf="$(mktemp)"
    # --all-projects wajib: volume bisa milik project lain. --long untuk "Created At".
    if ! json="$(os_cli volume snapshot list --volume "$id" --all-projects --long -f json 2>"$errf")"; then
        SNAP_ERR="$(last_error_line "$errf")"
        SNAP_ERR="${SNAP_ERR:-snapshot list gagal tanpa pesan}"
        rm -f "$errf"
        return 1
    fi
    rm -f "$errf"

    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$json"; then
        SNAP_ERR="output snapshot list bukan JSON array"
        return 1
    fi

    mapfile -t SNAPS < <(
        jq -r 'def v: if . == null or . == "" then "-" else tostring end;
               sort_by(."Created At" // "") | .[]
               | [ .ID, .Name, .Status, .Size, ."Created At" ] | map(v) | join("\u001f")' <<< "$json"
    )

    SNAP_COUNT=${#SNAPS[@]}

    for s in "${SNAPS[@]}"; do
        IFS="$US" read -r sid sname sstatus _ <<< "$s"
        ids+=("$sid")
        if [[ -z "$SNAP_BAD_ID" && "$sstatus" != "available" && "$sstatus" != "error" ]]; then
            SNAP_BAD_ID="$sid"
            SNAP_BAD_STATUS="$sstatus"
        fi
    done

    if (( ${#ids[@]} > 0 )); then
        SNAP_IDS="$(IFS=,; printf '%s' "${ids[*]}")"
        SNAP_KEY="$(printf '%s\n' "${ids[@]}" | LC_ALL=C sort | paste -sd, -)"
    fi

    return 0
}

# Catat semua informasi volume + snapshot SEBELUM dihapus (setelah dihapus
# data ini tidak bisa diambil lagi dari API)
log_volume_info() {
    local id="$1" s sid sname sstatus ssize screated

    log_event VOLUME_INFO "resource=$id" "name=$V_NAME" "project_id=$V_PROJECT_ID" \
        "project=$P_NAME" "domain=$P_DOMAIN" "created_at=$V_CREATED" "status=$V_STATUS" \
        "size_gb=$V_SIZE" "type=$V_TYPE" "snapshots=$SNAP_COUNT"

    for s in "${SNAPS[@]}"; do
        IFS="$US" read -r sid sname sstatus ssize screated <<< "$s"
        log_event SNAPSHOT "volume=$id" "snapshot=$sid" "name=$sname" "status=$sstatus" \
            "size_gb=$ssize" "created_at=$screated"
    done
}

# Validasi tepat sebelum konfirmasi/eksekusi (state bisa berubah selama batch).
# SKIP_REASON kosong => volume boleh dihapus.
validate_volume() {
    local id="$1" rc=0

    SKIP_REASON=""
    SNAPS=()
    SNAP_COUNT="-" SNAP_IDS="" SNAP_KEY=""
    P_NAME="-" P_DOMAIN="-"

    if ! valid_uuid "$id"; then
        V_NAME="-" V_STATUS="-" V_SIZE="-" V_TYPE="-" V_CREATED="-" V_PROJECT_ID="-"
        SKIP_REASON="invalid id"
        remember_info "$id"
        return 0
    fi

    get_volume "$id" || rc=$?

    if (( rc == 1 )); then
        SKIP_REASON="not found"
    elif (( rc != 0 )); then
        SKIP_REASON="lookup failed: $V_ERR"
    else
        resolve_project "$V_PROJECT_ID"

        if [[ "$V_STATUS" != "available" ]]; then
            SKIP_REASON="not available, status=$V_STATUS"
        elif ! list_snapshots "$id"; then
            SKIP_REASON="snapshot list failed: $SNAP_ERR"
        elif [[ -n "$SNAP_BAD_ID" ]]; then
            SKIP_REASON="snapshot $SNAP_BAD_ID status=$SNAP_BAD_STATUS"
        fi

        log_volume_info "$id"
    fi

    remember_info "$id"
    return 0
}

# Info terakhir per volume (untuk baris NOT_PROCESSED / batch mismatch)
remember_info() {
    INFO[$1]="$V_NAME$US$P_NAME$US$P_DOMAIN$US$V_CREATED$US$V_STATUS$US$V_SIZE$US$SNAP_COUNT$US$SNAP_IDS"
}

load_info() {
    V_NAME="-" P_NAME="-" P_DOMAIN="-" V_CREATED="-" V_STATUS="-" V_SIZE="-" SNAP_COUNT="-" SNAP_IDS=""
    [[ -n "${INFO[$1]+x}" ]] || return 0
    IFS="$US" read -r V_NAME P_NAME P_DOMAIN V_CREATED V_STATUS V_SIZE SNAP_COUNT SNAP_IDS <<< "${INFO[$1]}"
}

print_snapshots() {
    local s sid sname sstatus ssize screated

    for s in "${SNAPS[@]}"; do
        IFS="$US" read -r sid sname sstatus ssize screated <<< "$s"
        printf '  - %s  %s  %s  %s GB  %s\n' "$sid" "$sname" "$sstatus" "$ssize" "$screated"
    done
}

show_info() {
    local id="$1"

    echo
    printf '%-12s: %s\n' "Volume ID" "$id"
    printf '%-12s: %s\n' "Volume Name" "$V_NAME"
    printf '%-12s: %s\n' "Project Name" "$P_NAME"
    printf '%-12s: %s\n' "Domain Name" "$P_DOMAIN"
    printf '%-12s: %s\n' "Created At" "$V_CREATED"
    printf '%-12s: %s / %s GB\n' "Status/Size" "$V_STATUS" "$V_SIZE"
    printf '%-12s: %s\n' "Volume Type" "$V_TYPE"
    printf '%-12s: %s\n' "Snapshots" "$SNAP_COUNT"
    print_snapshots

    if (( SNAP_COUNT > 0 )); then
        echo
        echo "${C_RED}${C_BOLD}⚠️  $SNAP_COUNT snapshot di atas IKUT DIHAPUS PERMANEN oleh --purge.${C_RESET}"
    fi
    echo
}

confirm_volume() {
    local answer

    ask answer "Hapus volume ini PERMANEN? [y]es / [N]o / [q]uit batch: "

    case "${answer,,}" in
        y|yes) CHOICE="y" ;;
        q)     CHOICE="q" ;;
        *)     CHOICE="n" ;;
    esac
}

# ============================================================
# Penghapusan dan polling
# ============================================================

# Pesan API dari stderr "volume delete" (LOG_LAST_ERROR) => DEL_ERR
delete_error_message() {
    local line

    DEL_ERR=""
    while IFS= read -r line; do
        if [[ "$line" == *"Failed to delete volume with name or ID"* ]]; then
            DEL_ERR="${line#*"': "}"
            break
        fi
    done <<< "$LOG_LAST_ERROR"

    if [[ -z "$DEL_ERR" ]]; then
        DEL_ERR="$(grep -v '^[[:space:]]*$' <<< "$LOG_LAST_ERROR" | head -n 1)" || DEL_ERR=""
    fi
    DEL_ERR="${DEL_ERR:-tidak ada pesan dari API}"
}

# Polling "volume show" sampai volume hilang (SUCCESS), error_deleting
# (FAILED), atau timeout (FAILED). Satu baris status diperbarui di tempat.
wait_deleted() {
    local id="$1" name="$2" deadline rc line cols last="deleting" shown

    deadline=$(( DEL_START + TIMEOUT_SEC ))
    cols="$(term_cols)"

    while true; do
        rc=0
        get_volume "$id" || rc=$?

        if (( rc == 1 )); then
            RESULT="SUCCESS"
            RESULT_MSG=""
            break
        elif (( rc == 0 )); then
            shown="$V_STATUS"
            if [[ "$V_STATUS" != "$last" ]]; then
                log_event DELETE_STATUS "resource=$id" "status=$V_STATUS" "elapsed=$(( SECONDS - DEL_START ))"
                last="$V_STATUS"
            fi
            if [[ "$V_STATUS" == "error_deleting" ]]; then
                RESULT="FAILED"
                RESULT_MSG="status=error_deleting"
                break
            fi
        else
            shown="? (gagal dibaca)"
            log_warn -q "volume show $id gagal saat polling: $V_ERR"
        fi

        line="[$name] status=$shown elapsed=$(fmt_elapsed $(( SECONDS - DEL_START ))) (timeout $(fmt_timeout))"
        printf '\r\e[K%s' "${line:0:cols-1}"

        if (( SECONDS >= deadline )); then
            RESULT="FAILED"
            RESULT_MSG="timeout, last status=$last"
            break
        fi

        sleep "$INTERVAL"
    done

    printf '\r\e[K'
    return 0
}

delete_volume() {
    local id="$1" name="$V_NAME" dur

    echo "🗑️  Menghapus $name ($id) dengan --purge..."
    DEL_START=$SECONDS

    if ! os_run volume delete --purge "$id"; then
        delete_error_message
        dur=$(( SECONDS - DEL_START ))
        echo "${C_RED}❌ $name: FAILED ($DEL_ERR)${C_RESET} [${dur}s]"
        record_result "$id" FAILED "$dur" "$DEL_ERR"
        return 0
    fi

    log_event DELETE_REQUESTED "resource=$id" "snapshots=$SNAP_COUNT"

    DELETING=1
    wait_deleted "$id" "$name"
    DELETING=0

    # Polling menimpa V_*: kembalikan info hasil validasi (sebelum dihapus)
    load_info "$id"
    dur=$(( SECONDS - DEL_START ))
    echo "$(result_color "$RESULT")➡️  $name: $RESULT${RESULT_MSG:+ ($RESULT_MSG)}${C_RESET} [${dur}s]"
    record_result "$id" "$RESULT" "$dur" "$RESULT_MSG"
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

    REPORT_FILE="$dir/delete-volume-${LOG_RUN_ID:-$(date +%Y%m%dT%H%M%S)-$$}-results.tsv"

    if ! ( umask 002; printf 'timestamp\tvolume_id\tname\tproject_name\tdomain_name\tcreated_at\tstatus\tsize_gb\tsnapshot_count\tsnapshot_ids\tresult\tduration_s\tmessage\n' > "$REPORT_FILE" ) 2>/dev/null; then
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
    local out f

    [[ -n "$REPORT_FILE" ]] || return 0

    out="$(date -Iseconds)"
    for f in "$@"; do
        out+=$'\t'"$(tsv_clean "$f")"
    done

    { printf '%s\n' "$out" >> "$REPORT_FILE"; } 2>/dev/null || true
    return 0
}

# record_result ID RESULT DURATION MSG — log + TSV (segera), info volume dari V_*/P_*/SNAP_*
record_result() {
    local id="$1" result="$2" dur="$3" msg="$4"

    if [[ "$result" == "NOT_PROCESSED" ]]; then
        # Bukan nilai log_result yang valid; dicatat sebagai event NOT_PROCESSED
        :
    else
        log_result "resource=$id" "action=$ACTION" "result=$result" "name=$V_NAME" \
            "project=$P_NAME" "snapshots=$SNAP_COUNT" "duration=$dur" "msg=$msg"
    fi

    tsv_row "$id" "$V_NAME" "$P_NAME" "$P_DOMAIN" "$V_CREATED" "$V_STATUS" "$V_SIZE" \
        "$SNAP_COUNT" "$SNAP_IDS" "$result" "$dur" "$msg"

    RESULTS+=("$id$US$V_NAME$US$P_NAME$US$SNAP_COUNT$US$V_SIZE$US$result$US$dur$US$msg")
    COUNTS[$result]=$(( ${COUNTS[$result]:-0} + 1 ))
    CUR_DONE=1

    if [[ "$result" == "SUCCESS" ]]; then
        [[ "$V_SIZE" =~ ^[0-9]+$ ]] && GB_FREED=$(( GB_FREED + V_SIZE ))
        if [[ "$SNAP_COUNT" =~ ^[0-9]+$ ]]; then
            SNAPS_DELETED=$(( SNAPS_DELETED + SNAP_COUNT ))
            snap_gb_add
        fi
    fi
    return 0
}

snap_gb_add() {
    local s ssize
    for s in "${SNAPS[@]}"; do
        IFS="$US" read -r _ _ _ ssize _ <<< "$s"
        [[ "$ssize" =~ ^[0-9]+$ ]] && SNAP_GB_FREED=$(( SNAP_GB_FREED + ssize ))
    done
    return 0
}

# Volume mulai index $1 tidak diproses (q / interrupt)
mark_not_processed() {
    local i id id_list="" n=0

    for (( i = $1; i < ${#ENTRIES[@]}; i++ )); do
        id="${ENTRIES[$i]}"
        load_info "$id"
        SNAPS=()
        record_result "$id" NOT_PROCESSED 0 "belum diproses"
        id_list+="${id_list:+,}$id"
        n=$(( n + 1 ))
    done

    if [[ -n "$id_list" ]]; then
        log_event NOT_PROCESSED "count=$n" "ids=$id_list"
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

# Kelompok alasan untuk tabel "TIDAK dihapus"
reason_group() {
    local result="$1" msg="$2"

    case "$result" in
        DECLINED)      printf 'Declined (dilewati operator)' ;;
        FAILED)        printf 'Failed' ;;
        ABORTED)       printf 'Interrupted (penghapusan mungkin tetap berjalan)' ;;
        NOT_PROCESSED) printf 'Not processed' ;;
        SKIPPED)
            case "$msg" in
                "not available"*)   printf 'Not available' ;;
                "not found")        printf 'Not found' ;;
                "invalid id")       printf 'Invalid id' ;;
                "snapshot "*status=*) printf 'Snapshot status' ;;
                *)                  printf 'Skipped (lainnya)' ;;
            esac
            ;;
        *)             printf 'Lainnya' ;;
    esac
}

print_summary() {
    local r id name project snaps size result dur msg group n_ok=0 n_not=0
    local -a groups=(
        "Not available" "Not found" "Invalid id" "Snapshot status" "Skipped (lainnya)"
        "Declined (dilewati operator)" "Failed" "Interrupted (penghapusan mungkin tetap berjalan)"
        "Not processed" "Lainnya"
    )
    local -A grouped=() gcount=()

    for r in "${RESULTS[@]}"; do
        IFS="$US" read -r id name project snaps size result dur msg <<< "$r"
        if [[ "$result" == "SUCCESS" ]]; then
            n_ok=$(( n_ok + 1 ))
        else
            n_not=$(( n_not + 1 ))
            group="$(reason_group "$result" "$msg")"
            grouped[$group]+="$r"$'\n'
            gcount[$group]=$(( ${gcount[$group]:-0} + 1 ))
        fi
    done

    echo
    echo "=============================================================================================="
    echo "                                 Ringkasan Delete Volume"
    echo "=============================================================================================="
    echo "${C_GREEN}${C_BOLD}Volume yang berhasil dihapus ($n_ok)${C_RESET}"
    if (( n_ok > 0 )); then
        printf '%s%-36s %-24s %-24s %5s %8s %6s%s\n' "$C_BOLD" ID NAME PROJECT SNAPS SIZE DUR "$C_RESET"
        for r in "${RESULTS[@]}"; do
            IFS="$US" read -r id name project snaps size result dur msg <<< "$r"
            [[ "$result" == "SUCCESS" ]] || continue
            printf '%-36s %-24s %-24s %5s %8s %6s\n' "${id:0:36}" "${name:0:24}" "${project:0:24}" \
                "$snaps" "${size} GB" "${dur}s"
        done
    else
        echo "  (tidak ada)"
    fi

    echo
    echo "${C_RED}${C_BOLD}!!! Volume yang TIDAK dihapus ($n_not) !!!${C_RESET}"
    if (( n_not > 0 )); then
        for group in "${groups[@]}"; do
            [[ -n "${grouped[$group]:-}" ]] || continue
            echo "${C_YELLOW}▸ $group (${gcount[$group]})${C_RESET}"
            printf '  %s%-36s %-24s %-24s %-13s %s%s\n' "$C_BOLD" ID NAME PROJECT RESULT REASON "$C_RESET"
            while IFS="$US" read -r id name project snaps size result dur msg; do
                [[ -n "$id" ]] || continue
                printf '  %-36s %-24s %-24s %s%-13s%s %s\n' "${id:0:36}" "${name:0:24}" "${project:0:24}" \
                    "$(result_color "$result")" "$result" "$C_RESET" "${msg:0:100}"
            done <<< "${grouped[$group]}"
        done
    else
        echo "  (tidak ada)"
    fi

    echo
    for result in SUCCESS FAILED ABORTED DECLINED SKIPPED NOT_PROCESSED; do
        printf '%-18s: %d\n' "$result" "${COUNTS[$result]:-0}"
    done
    printf '%-18s: %d\n' "Snapshot terhapus" "$SNAPS_DELETED"
    printf '%-18s: %d GB volume (+ %d GB snapshot, nominal)\n' "Kapasitas bebas" "$GB_FREED" "$SNAP_GB_FREED"

    echo
    echo "Log     : ${LOG_FILE:-(logging nonaktif)}"
    echo "Laporan : ${REPORT_FILE:-(tidak ada)}"
    echo "=============================================================================================="

    log_event SUMMARY "success=${COUNTS[SUCCESS]:-0}" "failed=${COUNTS[FAILED]:-0}" \
        "aborted=${COUNTS[ABORTED]:-0}" "declined=${COUNTS[DECLINED]:-0}" \
        "skipped=${COUNTS[SKIPPED]:-0}" "not_processed=${COUNTS[NOT_PROCESSED]:-0}" \
        "snapshots_deleted=$SNAPS_DELETED" "gb_freed=$GB_FREED"
}

# ============================================================
# Keamanan operasional
# ============================================================

check_session() {
    local answer

    [[ -n "${TMUX:-}" || -n "${STY:-}" ]] && return 0

    warn "Tidak berjalan di dalam tmux/screen. Jika koneksi SSH putus, batch berhenti (penghapusan yang sudah diminta tetap dilanjutkan oleh Cinder)."
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

    LOCK_FILE="$dir/delete-volume.lock"
    ( umask 002; : >> "$LOCK_FILE" ) 2>/dev/null || true

    exec 9>>"$LOCK_FILE" || die "Tidak bisa membuka lock file: $LOCK_FILE"

    if ! flock -n 9; then
        holder="$(cat "$LOCK_FILE" 2>/dev/null)" || holder=""
        die "Delete volume lain sedang berjalan${holder:+ ($holder)}. Lock: $LOCK_FILE"
    fi

    printf 'pid=%s user=%s run=%s\n' "$$" "${SUDO_USER:-$(id -un)}" "${LOG_RUN_ID:--}" > "$LOCK_FILE" 2>/dev/null || true
    log_event LOCK "file=$LOCK_FILE"
}

# Dipanggil lib/logging.sh saat SIGINT/SIGTERM (sebelum exit 130/143)
on_interrupt() {
    local sig="$1" id

    printf '\n'

    if (( ! BATCH_STARTED )); then
        log_event INTERRUPT "signal=$sig" phase=setup
        return 0
    fi

    id="${ENTRIES[$CUR_IDX]}"

    if (( DELETING )); then
        load_info "$id"
        echo "${C_YELLOW}⚠️  Penghapusan $V_NAME ($id) TETAP BERJALAN di Cinder; hanya polling yang berhenti. Verifikasi manual: openstack volume show $id${C_RESET}"
        record_result "$id" ABORTED $(( SECONDS - DEL_START )) \
            "polling dihentikan ($sig); penghapusan tetap berjalan di Cinder, verifikasi manual"
        mark_not_processed $(( CUR_IDX + 1 ))
    else
        mark_not_processed $(( CUR_IDX + CUR_DONE ))
    fi

    log_event INTERRUPT "signal=$sig" "deleting=$DELETING"
    print_summary
    return 0
}

# ============================================================
# Batch
# ============================================================

# Mode konfirmasi per volume
run_per_volume() {
    local total=${#ENTRIES[@]} i id key

    BATCH_STARTED=1

    for (( i = 0; i < total; i++ )); do
        id="${ENTRIES[$i]}"
        CUR_IDX=$i
        CUR_DONE=0

        echo
        echo "${C_CYAN}──── [$(( i + 1 ))/$total] $id ────${C_RESET}"

        validate_volume "$id"

        if [[ -n "$SKIP_REASON" ]]; then
            echo "⏭️  SKIPPED ($SKIP_REASON)"
            record_result "$id" SKIPPED 0 "$SKIP_REASON"
            continue
        fi

        show_info "$id"
        confirm_volume

        case "$CHOICE" in
            n)
                echo "⏭️  Dilewati."
                log_event DECISION "resource=$id" decision=declined
                record_result "$id" DECLINED 0 "dilewati operator"
                ;;
            q)
                echo "🛑 Batch dihentikan oleh operator."
                log_event DECISION "resource=$id" decision=quit
                mark_not_processed "$i"
                break
                ;;
            y)
                log_event DECISION "resource=$id" decision=delete
                # State bisa berubah selama prompt: validasi ulang, dan jangan
                # hapus snapshot yang tidak ditampilkan saat konfirmasi.
                key="$SNAP_KEY"
                validate_volume "$id"
                if [[ -z "$SKIP_REASON" && "$SNAP_KEY" != "$key" ]]; then
                    SKIP_REASON="snapshots changed since confirmation"
                fi
                if [[ -n "$SKIP_REASON" ]]; then
                    echo "⏭️  SKIPPED ($SKIP_REASON)"
                    record_result "$id" SKIPPED 0 "$SKIP_REASON"
                    continue
                fi
                delete_volume "$id"
                ;;
        esac
    done

    return 0
}

# Validasi semua volume dan cetak tabel rencana (dipakai --no-confirm dan --dry-run).
# Hasil: PLAN_SKIP[id] (alasan, kosong = akan dihapus), PLAN_SNAPKEY[id], PLAN_WILL.
build_plan() {
    local id plan will_snaps=0 will_gb=0 skip=0

    PLAN_WILL=0

    echo
    echo "${C_BOLD}Rencana${C_RESET} $( (( DRY_RUN )) && echo '(dry-run, tanpa penghapusan)')"
    printf '%s%-36s %-24s %-24s %5s %8s  %s%s\n' "$C_BOLD" ID NAME PROJECT SNAPS SIZE PLAN "$C_RESET"

    for id in "${ENTRIES[@]}"; do
        validate_volume "$id"
        PLAN_SKIP[$id]="$SKIP_REASON"
        PLAN_SNAPKEY[$id]="$SNAP_KEY"

        if [[ -z "$SKIP_REASON" ]]; then
            plan="${C_RED}WILL DELETE${C_RESET}"
            PLAN_WILL=$(( PLAN_WILL + 1 ))
            will_snaps=$(( will_snaps + SNAP_COUNT ))
            [[ "$V_SIZE" =~ ^[0-9]+$ ]] && will_gb=$(( will_gb + V_SIZE ))
        else
            plan="SKIP ($SKIP_REASON)"
            skip=$(( skip + 1 ))
        fi

        if (( DRY_RUN )); then
            log_info "PLAN dry_run=true resource=$id name=\"$V_NAME\" project=\"$P_NAME\" snapshots=$SNAP_COUNT size_gb=$V_SIZE plan=\"${SKIP_REASON:-WILL DELETE}\""
        fi

        printf '%-36s %-24s %-24s %5s %8s  %s\n' "${id:0:36}" "${V_NAME:0:24}" "${P_NAME:0:24}" \
            "$SNAP_COUNT" "${V_SIZE} GB" "$plan"
        [[ -z "$SKIP_REASON" ]] && print_snapshots
    done

    echo
    echo "${C_BOLD}Akan dihapus : $PLAN_WILL volume, $will_snaps snapshot ikut terhapus (--purge), $will_gb GB volume${C_RESET}"
    echo "Dilewati     : $skip volume"
    if (( will_snaps > 0 )); then
        echo "${C_RED}⚠️  Snapshot yang tercantum di atas IKUT DIHAPUS PERMANEN.${C_RESET}"
    fi

    log_event PLAN_SUMMARY "dry_run=$DRY_RUN" "will_delete=$PLAN_WILL" "snapshots=$will_snaps" \
        "size_gb=$will_gb" "skip=$skip"
}

# Catat volume yang dilewati di rencana tanpa query ulang
record_planned_skip() {
    local id="$1"
    load_info "$id"
    SNAPS=()
    echo "⏭️  SKIPPED (${PLAN_SKIP[$id]})"
    record_result "$id" SKIPPED 0 "${PLAN_SKIP[$id]}"
}

# Mode tanpa konfirmasi per volume: rencana + satu konfirmasi batch
run_no_confirm() {
    local total=${#ENTRIES[@]} i id answer

    build_plan

    if (( PLAN_WILL > 0 )); then
        echo
        ask answer "Ketik jumlah volume yang akan dihapus untuk konfirmasi (kosong = batal): "
        answer="$(trim "$answer")"

        if [[ "$answer" != "$PLAN_WILL" ]]; then
            log_event DECISION decision=batch-cancel "expected=$PLAN_WILL" "typed=$answer"
            echo "❌ Konfirmasi tidak cocok ($answer ≠ $PLAN_WILL). Tidak ada volume yang dihapus."
            BATCH_STARTED=1
            for (( i = 0; i < total; i++ )); do
                id="${ENTRIES[$i]}"
                CUR_IDX=$i
                if [[ -n "${PLAN_SKIP[$id]}" ]]; then
                    record_planned_skip "$id"
                else
                    load_info "$id"
                    SNAPS=()
                    record_result "$id" DECLINED 0 "batch confirmation mismatch"
                fi
            done
            return 0
        fi
        log_event DECISION decision=batch-confirm "count=$PLAN_WILL"
    else
        echo "Tidak ada volume yang bisa dihapus."
    fi

    BATCH_STARTED=1

    for (( i = 0; i < total; i++ )); do
        id="${ENTRIES[$i]}"
        CUR_IDX=$i
        CUR_DONE=0

        echo
        echo "${C_CYAN}──── [$(( i + 1 ))/$total] $id ────${C_RESET}"

        if [[ -n "${PLAN_SKIP[$id]}" ]]; then
            record_planned_skip "$id"
            continue
        fi

        # Validasi ulang tepat sebelum menghapus (state bisa berubah)
        validate_volume "$id"
        if [[ -z "$SKIP_REASON" && "$SNAP_KEY" != "${PLAN_SNAPKEY[$id]}" ]]; then
            SKIP_REASON="snapshots changed since plan"
        fi
        if [[ -n "$SKIP_REASON" ]]; then
            echo "⏭️  SKIPPED ($SKIP_REASON)"
            record_result "$id" SKIPPED 0 "$SKIP_REASON"
            continue
        fi

        delete_volume "$id"
    done

    return 0
}

# ============================================================
# Main
# ============================================================

main() {
    parse_args "$@"
    require_deps

    echo "========================================"
    echo "            Delete Volume"
    echo "========================================"

    choose_modes
    load_ids
    (( ${#ENTRIES[@]} > 0 )) || die "Tidak ada volume ID di dalam input."

    if [[ "$INPUT_MODE" == "file" ]]; then
        echo "📄 Input   : $INPUT_FILE"
        log_event INPUT input_mode=file "input_file=$INPUT_FILE" "lines=$N_LINES" \
            "unique=${#ENTRIES[@]}" "valid=$(( ${#ENTRIES[@]} - N_INVALID ))" \
            "invalid=$N_INVALID" "duplicates=$N_DUP"
    else
        log_event INPUT input_mode=id "volume_id=${ENTRIES[0]}"
    fi
    echo "🔢 ID      : ${#ENTRIES[@]} unik ($(( ${#ENTRIES[@]} - N_INVALID )) valid, $N_INVALID tidak valid), $N_DUP duplikat diabaikan"

    log_event OPTIONS "dry_run=$DRY_RUN" "confirm_mode=$( (( NO_CONFIRM )) && echo batch || echo per-volume )" \
        "interval=$INTERVAL" "timeout_s=$TIMEOUT_SEC" "os_cmd=${OS_CMD[*]}"

    if (( DRY_RUN )); then
        build_plan
        echo "Log          : ${LOG_FILE:-(logging nonaktif)}"
        return 0
    fi

    has_tty || die "Penghapusan butuh terminal interaktif (/dev/tty) untuk konfirmasi."
    echo "✅ Mode    : $( (( NO_CONFIRM )) && echo 'tanpa konfirmasi per volume (konfirmasi batch)' || echo 'konfirmasi per volume')"

    [[ "$INPUT_MODE" == "file" ]] && check_session
    acquire_lock
    init_report

    LOG_INTERRUPT_HOOK=on_interrupt
    if (( NO_CONFIRM )); then
        run_no_confirm
    else
        run_per_volume
    fi
    LOG_INTERRUPT_HOOK=""

    print_summary

    (( ${COUNTS[FAILED]:-0} == 0 ))
}

main "$@"
