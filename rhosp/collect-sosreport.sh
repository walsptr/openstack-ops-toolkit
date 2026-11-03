#!/bin/bash
# ============================================================
# @name:        Collect sosreport
# @description: Collect sosreport from selected RHOSP nodes (disables fencing safely when needed)
# @mutates:     yes
# @requires:    rhosp-undercloud, jq, ansible-inventory
# @platform:    rhosp
# @tags:        rhosp, sosreport, support, pacemaker, stonith, instance-ha, troubleshooting
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: collect-sosreport.sh [--inventory PATH] [--node HOST]... [--role ROLE]...
                            [--include-undercloud] [--case-id ID] [--dest DIR]
                            [--parallel N] [--timeout MENIT] [--keep-remote]
                            [--dry-run]

Kumpulkan sosreport dari node RHOSP 17.1. Dijalankan di undercloud sebagai
user stack; node overcloud diakses lewat SSH (user dari inventory, default
tripleo-admin). Perintah di setiap node:

  sudo sosreport --batch --all-logs --threads=1 [--case-id ID]

Jika ada node terpilih yang anggota cluster Pacemaker (controller, atau
compute Instance HA sebagai remote node), fencing (stonith-enabled)
di-disable sementara dan dipulihkan ke nilai awalnya segera setelah
sosreport semua node cluster selesai (juga saat error atau Ctrl-C).

Options:
  --inventory PATH       File inventory (melewati pencarian otomatis)
  --node HOST            Node target (bisa diulang)
  --role ROLE            Semua node dalam role (bisa diulang)
  --include-undercloud   Ikut kumpulkan sosreport undercloud (dijalankan lokal)
  --case-id ID           Tambahkan --case-id ID ke perintah sosreport
  --dest DIR             Direktori tujuan di undercloud (default /tmp, harus sudah ada)
  --parallel N           Jumlah node yang dikumpulkan bersamaan (default 1)
  --timeout MENIT        Batas waktu sosreport per node (default 60)
  --keep-remote          Jangan tawarkan menghapus file sosreport di node
  --dry-run              Pre-check dan rencana saja: tanpa mengubah fencing,
                         tanpa sosreport, tanpa menyalin
  -h, --help             Tampilkan help

Tanpa --node/--role, node dipilih lewat picker (fzf, atau menu bernomor).

Pencarian inventory: --inventory, /home/stack/inventory.yaml, lalu
/home/stack/overcloud-deploy/*/tripleo-ansible-inventory.yaml.

Environment (terutama untuk tes):
  OSOPS_SSH, OSOPS_SCP, OSOPS_ANSIBLE_INVENTORY, OSOPS_FZF
                               perintah pengganti ssh/scp/ansible-inventory/fzf
  OSOPS_RHOSP_RELEASE_FILE     default /etc/rhosp-release
  OSOPS_STACK_HOME             default /home/stack (pencarian inventory)
  OSOPS_SOS_LOCAL_DIR          lokasi hasil sosreport undercloud (default /var/tmp)
  OSOPS_SOS_MIN_FREE_GB        /var/tmp node di bawah ini => ditanya (default 5)
  OSOPS_SOS_MIN_FREE_HARD_GB   /var/tmp node di bawah ini => SKIPPED (default 1)
  OSOPS_SOS_DEST_GB_PER_NODE   peringatan ruang --dest per node (default 2)
  OSOPS_SOS_PROGRESS_INTERVAL  interval tampilan progres dalam detik (default 10)
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

INVENTORY=""
NODE_ARGS=()
ROLE_ARGS=()
INCLUDE_UC=0
CASE_ID=""
DEST="/tmp"
PARALLEL=1
TIMEOUT_MIN=60
KEEP_REMOTE=0
DRY_RUN=0

RHOSP_RELEASE_FILE="${OSOPS_RHOSP_RELEASE_FILE:-/etc/rhosp-release}"
STACK_HOME="${OSOPS_STACK_HOME:-/home/stack}"
REMOTE_SOS_DIR="/var/tmp"
LOCAL_SOS_DIR="${OSOPS_SOS_LOCAL_DIR:-/var/tmp}"
MIN_FREE_GB="${OSOPS_SOS_MIN_FREE_GB:-5}"
MIN_FREE_HARD_GB="${OSOPS_SOS_MIN_FREE_HARD_GB:-1}"
DEST_GB_PER_NODE="${OSOPS_SOS_DEST_GB_PER_NODE:-2}"
PROGRESS_INTERVAL="${OSOPS_SOS_PROGRESS_INTERVAL:-10}"

# Batas waktu (detik) perintah SSH pendek dan pemulihan fencing per controller
SSH_TIMEOUT=120
RESTORE_TIMEOUT=60

# Perintah eksternal (override lewat env string, mis. untuk stub di tes)
read -ra SSH_CMD <<< "${OSOPS_SSH:-ssh}"
read -ra SCP_CMD <<< "${OSOPS_SCP:-scp}"
read -ra ANSIBLE_INV_CMD <<< "${OSOPS_ANSIBLE_INVENTORY:-ansible-inventory}"
read -ra FZF_CMD <<< "${OSOPS_FZF:-fzf}"

US=$'\x1f'

if [[ -t 1 ]]; then
    C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m' C_RESET=$'\e[0m'
else
    C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_RESET=""
fi

# Node dari inventory (array paralel, index = node). Undercloud (lokal)
# ditambahkan di akhir dengan N_LOCAL=1.
N_NAME=() N_ROLE=() N_IP=() N_USER=() N_KEY=() N_PORT=() N_CANON=()
N_PCMK=() N_PCMKR=() N_LOCAL=()
# State per node
N_SEL=() N_HK=() N_RELEASE=() N_SOS_RPM=() N_EPOCH=() N_FREE_KB=()
N_CLUSTER=() N_MEMBER=() N_RESULT=() N_MSG=() N_REMOTE=() N_REMOTE_SUM=()
N_SHA=() N_LOCALF=() N_SIZE=() N_DUR=() N_METHOD=() N_LOGGED=()
N_PH_T0=() N_SOSDONE=()
declare -A IDX_BY_NAME=()
UC_IDX=-1
UC_NAME=""
SEL=()
CTRL_LIST=()

UC_RELEASE=""
INV_SOURCE=""
WORK_DIR=""
INV_JSON=""
LOCK_FILE=""
STATE_FILE=""
REPORT_FILE=""
REPORT_READY=0
FINALIZED=0

# Cluster / fencing
CLUSTER_KNOWN=0
CLUSTER_NAME=""
PCS_CTRL=-1
CLUSTER_UNHEALTHY=0
NEED_FENCING=0
FENCING_ORIG=""          # true | false | unset (nilai sebelum script)
FENCING_STATE="none"     # none | already-false | declined | unknown | disabled | disable-failed | statefile-failed | carried
FENCING_RESTORE=0        # 1 = script ini wajib memulihkan fencing
FENCING_RESTORED=0       # 0 belum, 1 berhasil, 2 gagal
STALE_ORIG=""            # nilai awal dari state file sisa (opsi "s")
STALE_CTRL=""
STONITH_VAL=""
INTERRUPTED=0

declare -A WORKER_PIDS=()   # pid -> index node
RUNNING_NAMES=""

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

info() {
    echo "${C_CYAN}ℹ️  $1${C_RESET}"
}

# Peringatan menonjol (kotak merah)
big_warning() {
    local line
    echo
    echo "${C_RED}${C_BOLD}╔══════════════════════════════════════════════════════════════════════╗${C_RESET}"
    for line in "$@"; do
        echo "${C_RED}${C_BOLD}║${C_RESET} $line"
    done
    echo "${C_RED}${C_BOLD}╚══════════════════════════════════════════════════════════════════════╝${C_RESET}"
    echo
}

has_tty() {
    ( : < /dev/tty ) 2>/dev/null
}

# ask VAR PROMPT — prompt dari /dev/tty (nama lokal unik untuk printf -v)
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

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

fmt_dur() {
    local s="${1:-0}"
    if (( s >= 3600 )); then
        printf '%d:%02d:%02d' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
    else
        printf '%02d:%02d' $(( s / 60 )) $(( s % 60 ))
    fi
}

# human_kb KB — ukuran yang mudah dibaca
human_kb() {
    awk -v k="${1:-0}" 'BEGIN {
        if (k >= 1048576) printf "%.1f GiB", k / 1048576
        else if (k >= 1024) printf "%.1f MiB", k / 1024
        else printf "%d KiB", k }'
}

human_bytes() {
    [[ -n "${1:-}" ]] || { printf -- '-'; return 0; }
    awk -v b="$1" 'BEGIN {
        if (b >= 1073741824) printf "%.1fG", b / 1073741824
        else if (b >= 1048576) printf "%.1fM", b / 1048576
        else if (b >= 1024) printf "%.1fK", b / 1024
        else printf "%dB", b }'
}

# Versi singkat dari isi rhosp-release ("... release 17.1.4 (Wallaby)" => 17.1.4)
release_version() {
    local v
    v="$(grep -oE '[0-9]+(\.[0-9]+)+' <<< "${1:-}" | head -n 1)" || v=""
    printf '%s' "${v:--}"
}

is_ip() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ || "$1" == *:* ]]
}

short_name() {
    local s="${1,,}"
    printf '%s' "${s%%.*}"
}

is_controller_role() {
    [[ "${N_ROLE[$1],,}" == *controller* ]]
}

# Node terpilih yang belum punya hasil (masih akan diproses)
pending() {
    [[ "${N_SEL[$1]}" == 1 && -z "${N_RESULT[$1]}" ]]
}

set_result() {
    N_RESULT[$1]="$2"
    N_MSG[$1]="$3"
}

# ============================================================
# SSH / SCP wrapper (satu-satunya jalur ke node)
# ============================================================

SSH_OPTS=()

build_ssh_opts() {
    local i="$1" port_flag="$2"

    SSH_OPTS=(
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o ServerAliveInterval=15
        -o "StrictHostKeyChecking=${N_HK[$i]:-yes}"
    )
    [[ -n "${N_KEY[$i]}" && -r "${N_KEY[$i]}" ]] && SSH_OPTS+=(-i "${N_KEY[$i]}")
    [[ -n "${N_PORT[$i]}" ]] && SSH_OPTS+=("$port_flag" "${N_PORT[$i]}")
    return 0
}

# ssh_node IDX TIMEOUT_DETIK REMOTE_CMD — stdout/stderr perintah remote apa adanya.
# Tanpa -t, stdin dari /dev/null; timeout lokal sebagai pengaman.
ssh_node() {
    local i="$1" t="$2" cmd="$3"
    build_ssh_opts "$i" -p
    timeout --kill-after=10 "$t" \
        "${SSH_CMD[@]}" "${SSH_OPTS[@]}" -- "${N_USER[$i]}@${N_IP[$i]}" "$cmd" < /dev/null
}

# scp_fetch IDX REMOTE_PATH LOCAL_PATH
scp_fetch() {
    local i="$1" src="$2" dst="$3" host
    host="${N_IP[$i]}"
    [[ "$host" == *:* ]] && host="[$host]"
    build_ssh_opts "$i" -P
    timeout --kill-after=10 $(( TIMEOUT_MIN * 60 )) \
        "${SCP_CMD[@]}" -q "${SSH_OPTS[@]}" -- "${N_USER[$i]}@$host:$src" "$dst" < /dev/null
}

# Klasifikasi kegagalan SSH dari stderr => alasan SKIPPED
ssh_fail_reason() {
    local err="$1" rc="$2"
    if [[ "$err" == *"REMOTE HOST IDENTIFICATION HAS CHANGED"* || "$err" == *"Host key verification failed"* ]]; then
        printf 'host key mismatch'
    elif [[ "$err" == *"Permission denied"* ]]; then
        printf 'ssh auth failed'
    elif (( rc == 124 || rc == 137 )); then
        printf 'unreachable (timeout)'
    else
        printf 'unreachable'
    fi
}

# ============================================================
# 1. Environment
# ============================================================

check_environment() {
    local answer tool user

    if [[ ! -f "$RHOSP_RELEASE_FILE" ]]; then
        die "Script ini hanya untuk undercloud RHOSP: $RHOSP_RELEASE_FILE tidak ditemukan."
    fi

    UC_RELEASE="$(head -n 1 "$RHOSP_RELEASE_FILE" 2>/dev/null)" || UC_RELEASE=""
    UC_RELEASE="$(trim "$UC_RELEASE")"
    echo "🏷️  RHOSP undercloud : ${UC_RELEASE:-(kosong)}"
    log_event ENV "rhosp_release=$UC_RELEASE" "release_file=$RHOSP_RELEASE_FILE"

    if [[ ! "$UC_RELEASE" =~ release[[:space:]]+17\.1([^0-9]|$) ]]; then
        warn "Script ini dirancang untuk RHOSP 17.1. Pada versi lain struktur inventory dan perilaku pcs bisa berbeda."
        ask answer "Tetap lanjut di versi ini? [y/N]: "
        if ! is_yes "$answer"; then
            log_event DECISION release_mismatch=cancel
            echo "❌ Dibatalkan."
            exit 0
        fi
        log_event DECISION release_mismatch=continue
    fi

    user="$(id -un)"
    if [[ "$user" != "stack" ]]; then
        warn "Script dijalankan sebagai '$user', bukan 'stack'. Key SSH (~/.ssh/id_rsa) dan known_hosts yang dipakai milik user ini."
        ask answer "Tetap lanjut sebagai $user? [y/N]: "
        if ! is_yes "$answer"; then
            log_event DECISION user_mismatch=cancel "user=$user"
            echo "❌ Dibatalkan."
            exit 0
        fi
        log_event DECISION user_mismatch=continue "user=$user"
    fi

    command -v jq >/dev/null 2>&1 || die "jq tidak ditemukan. Install jq (dnf install jq)."
    command -v "${ANSIBLE_INV_CMD[0]}" >/dev/null 2>&1 || \
        die "ansible-inventory tidak ditemukan (${ANSIBLE_INV_CMD[0]}). Jalankan di undercloud."
    for tool in "${SSH_CMD[0]}" "${SCP_CMD[0]}" timeout sha256sum; do
        command -v "$tool" >/dev/null 2>&1 || die "$tool tidak ditemukan."
    done
    if (( ! DRY_RUN )); then
        command -v flock >/dev/null 2>&1 || die "flock (util-linux) tidak ditemukan."
    fi

    [[ -d "$DEST" ]] || die "Direktori tujuan tidak ada: $DEST (buat dulu, script tidak membuatnya)."
    [[ -w "$DEST" ]] || die "Direktori tujuan tidak bisa ditulis: $DEST"
    DEST="$(realpath -- "$DEST")"
    log_event INPUT "dest=$DEST" "parallel=$PARALLEL" "timeout_min=$TIMEOUT_MIN" \
        "case_id=${CASE_ID:--}" "keep_remote=$KEEP_REMOTE" "dry_run=$DRY_RUN" \
        "include_undercloud=$INCLUDE_UC"
    return 0
}

check_session() {
    local answer

    [[ -n "${TMUX:-}" || -n "${STY:-}" ]] && return 0

    warn "Tidak berjalan di dalam tmux/screen. Jika koneksi SSH ke undercloud putus saat fencing di-disable, pemulihan bergantung pada trap dan state file."
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
    local holder

    [[ -n "$LOG_FILE" ]] || die "Logging nonaktif: lock dan state file fencing tidak bisa dibuat. Periksa direktori log."

    LOCK_FILE="$(dirname "$LOG_FILE")/collect-sosreport.lock"
    ( umask 002; : >> "$LOCK_FILE" ) 2>/dev/null || true
    exec 9>>"$LOCK_FILE" || die "Tidak bisa membuka lock file: $LOCK_FILE"

    if ! flock -n 9; then
        holder="$(cat "$LOCK_FILE" 2>/dev/null)" || holder=""
        die "collect-sosreport lain sedang berjalan${holder:+ ($holder)}. Lock: $LOCK_FILE"
    fi

    printf 'pid=%s user=%s run=%s\n' "$$" "${SUDO_USER:-$(id -un)}" "${LOG_RUN_ID:--}" > "$LOCK_FILE" 2>/dev/null || true
    log_event LOCK "file=$LOCK_FILE"
}

# ============================================================
# 2. Inventory
# ============================================================

find_inventory() {
    local default="$STACK_HOME/inventory.yaml"
    local pattern="$STACK_HOME/overcloud-deploy/*/tripleo-ansible-inventory.yaml"
    local -a stacks=()
    local i choice

    if [[ -n "$INVENTORY" ]]; then
        [[ -f "$INVENTORY" && -r "$INVENTORY" ]] || die "Inventory tidak ditemukan atau tidak bisa dibaca: $INVENTORY"
        INV_SOURCE="option"
    elif [[ -f "$default" && -r "$default" ]]; then
        INVENTORY="$default"
        INV_SOURCE="default"
    else
        mapfile -t stacks < <(compgen -G "$pattern" | LC_ALL=C sort)

        if (( ${#stacks[@]} == 0 )); then
            echo "${C_RED}❌ Inventory tidak ditemukan. Path yang sudah dicek:${C_RESET}"
            echo "   - $default"
            echo "   - $pattern"
            echo "   Gunakan --inventory <path>."
            log_error -q "inventory tidak ditemukan: $default, $pattern"
            exit 1
        fi

        if (( ${#stacks[@]} == 1 )); then
            INVENTORY="${stacks[0]}"
        else
            echo "📚 Ditemukan beberapa stack di $STACK_HOME/overcloud-deploy:"
            for i in "${!stacks[@]}"; do
                printf '  %d) %s\n' $(( i + 1 )) "$(basename "$(dirname "${stacks[$i]}")")"
            done
            while true; do
                ask choice "Pilih stack [1-${#stacks[@]}]: "
                if is_uint "$choice" && (( choice >= 1 && choice <= ${#stacks[@]} )); then
                    break
                fi
                echo "${C_RED}❌ Pilihan tidak valid.${C_RESET}"
            done
            INVENTORY="${stacks[$(( choice - 1 ))]}"
        fi
        INV_SOURCE="stack"
    fi

    echo "📒 Inventory        : $INVENTORY"
    log_event INPUT "inventory=$INVENTORY" "source=$INV_SOURCE"
}

# Program jq: hanya field yang dibutuhkan yang keluar dari hostvars
# (aturan data sensitif: hostvars tidak pernah dicetak/di-log utuh).
# Baris "U<US>nama" untuk undercloud, "N<US>..." untuk node overcloud.
# shellcheck disable=SC2016  # variabel jq, bukan shell
JQ_NODES='
def members($g): ((.[$g].hosts // []) + ([(.[$g].children // [])[] as $c | members($c)] | add // []));
def uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
def clean: if . == null then "" else tostring | gsub("[\u001f\t\r\n]"; " ") end;
. as $root
| ((members("Undercloud") + members("undercloud")) | uniq) as $uc
| ((if has("allovercloud") then members("allovercloud")
    else ((._meta.hostvars // {} | keys) + members("all")) end)
   | uniq | map(. as $h | select($uc | any(.[]; . == $h) | not))) as $oc
| (if has("allovercloud") then (.allovercloud.children // [])
   elif has("overcloud") then (.overcloud.children // [])
   else [] end) as $rg
| [ $rg[] as $c | {g: $c, m: members($c)} ] as $rgm
| members("pacemaker") as $pm
| members("pacemaker_remote") as $pmr
| ( $uc[] | "U\u001f" + clean ),
  ( $oc[] as $h
    | ($root._meta.hostvars[$h] // {}) as $hv
    | [ "N", $h,
        ($hv.tripleo_role_name // ([ $rgm[] | select(.m | any(.[]; . == $h)) | .g ][0]) // "unknown"),
        ($hv.ansible_host // $h),
        ($hv.ansible_ssh_user // $hv.ansible_user // "tripleo-admin"),
        ($hv.ansible_ssh_private_key_file // $hv.ansible_private_key_file // ""),
        ($hv.ansible_port // $hv.ansible_ssh_port // ""),
        ($hv.canonical_hostname // ""),
        (if $pm | any(.[]; . == $h) then "1" else "0" end),
        (if $pmr | any(.[]; . == $h) then "1" else "0" end)
      ] | map(clean) | join("\u001f") )
'

add_node() {
    local i=${#N_NAME[@]}
    N_NAME+=("$1") N_ROLE+=("$2") N_IP+=("$3") N_USER+=("$4") N_KEY+=("$5")
    N_PORT+=("$6") N_CANON+=("$7") N_PCMK+=("$8") N_PCMKR+=("$9") N_LOCAL+=("${10}")
    N_SEL+=(0) N_HK+=("") N_RELEASE+=("") N_SOS_RPM+=("") N_EPOCH+=("") N_FREE_KB+=("")
    N_CLUSTER+=(0) N_MEMBER+=("") N_RESULT+=("") N_MSG+=("") N_REMOTE+=("") N_REMOTE_SUM+=("")
    N_SHA+=("") N_LOCALF+=("") N_SIZE+=("") N_DUR+=(0) N_METHOD+=("") N_LOGGED+=(0)
    N_PH_T0+=(0) N_SOSDONE+=(0)
    IDX_BY_NAME["${1,,}"]=$i
}

load_nodes() {
    local -a lines=()
    local line kind name role ip user key port canon pm pmr n_ctrl=0 n_comp=0 n_bad=0
    local rc=0 errfile="$WORK_DIR/ansible-inventory.err"

    INV_JSON="$WORK_DIR/inventory.json"
    "${ANSIBLE_INV_CMD[@]}" -i "$INVENTORY" --list > "$INV_JSON" 2> "$errfile" || rc=$?
    if (( rc != 0 )); then
        echo "${C_RED}❌ ansible-inventory gagal (rc=$rc):${C_RESET}"
        tail -n 5 "$errfile" | sed 's/^/   /'
        log_error -q "ansible-inventory gagal rc=$rc inventory=$INVENTORY"
        exit 1
    fi

    if ! jq -r "$JQ_NODES" "$INV_JSON" > "$WORK_DIR/nodes.lst" 2> "$errfile"; then
        die "Output ansible-inventory --list tidak bisa diproses jq: $(head -c 300 "$errfile")"
    fi
    mapfile -t lines < "$WORK_DIR/nodes.lst"

    for line in "${lines[@]}"; do
        IFS="$US" read -r kind name role ip user key port canon pm pmr <<< "$line"
        if [[ "$kind" == "U" ]]; then
            [[ -z "$UC_NAME" ]] && UC_NAME="$name"
            continue
        fi

        # Validasi sebelum dipakai di argumen ssh (cegah opsi/karakter aneh)
        if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || ! "$ip" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ \
              || ! "$user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ || ( -n "$port" && ! "$port" =~ ^[0-9]+$ ) ]]; then
            n_bad=$(( n_bad + 1 ))
            warn "Host inventory dengan hostname/IP/user/port tidak valid dilewati: ${name//[^A-Za-z0-9._-]/?}"
            continue
        fi
        [[ -n "${IDX_BY_NAME[${name,,}]+x}" ]] && continue

        key="${key/#\~/$HOME}"
        [[ -z "$key" ]] && key="$HOME/.ssh/id_rsa"

        add_node "$name" "$role" "$ip" "$user" "$key" "$port" "$canon" "${pm:-0}" "${pmr:-0}" 0
        [[ "$pm" == 1 ]] && n_ctrl=$(( n_ctrl + 1 ))
        [[ "$pmr" == 1 ]] && n_comp=$(( n_comp + 1 ))
    done

    (( ${#N_NAME[@]} > 0 )) || die "Tidak ada node overcloud di inventory: $INVENTORY"

    # Undercloud (lokal), tidak lewat SSH
    UC_IDX=${#N_NAME[@]}
    add_node "${UC_NAME:-undercloud}" "Undercloud" "localhost" "$(id -un)" "" "" "" 0 0 1

    # Controller untuk pcs: grup pacemaker, fallback role "controller"
    local i
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        [[ "${N_PCMK[$i]}" == 1 ]] && CTRL_LIST+=("$i")
    done
    if (( ${#CTRL_LIST[@]} == 0 )); then
        for i in "${!N_NAME[@]}"; do
            (( N_LOCAL[i] )) && continue
            is_controller_role "$i" && CTRL_LIST+=("$i")
        done
    fi

    echo "🖥️  Node overcloud   : $(( ${#N_NAME[@]} - 1 )) (pacemaker: $n_ctrl, pacemaker_remote: $n_comp)"
    log_event INVENTORY "file=$INVENTORY" "nodes=$(( ${#N_NAME[@]} - 1 ))" "pacemaker=$n_ctrl" \
        "pacemaker_remote=$n_comp" "invalid=$n_bad" "undercloud=${UC_NAME:--}"
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        log_event NODE "host=${N_NAME[$i]}" "role=${N_ROLE[$i]}" "ip=${N_IP[$i]}" "user=${N_USER[$i]}" \
            "key=${N_KEY[$i]}" "port=${N_PORT[$i]:--}" "pacemaker=${N_PCMK[$i]}" "pacemaker_remote=${N_PCMKR[$i]}"
    done
    return 0
}

# ============================================================
# 4. Pilih node
# ============================================================

select_idx() {
    if (( N_SEL[$1] == 0 )); then
        N_SEL[$1]=1
        SEL+=("$1")
    fi
}

select_role() {
    local role="${1,,}" i found=1
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        if [[ "${N_ROLE[$i],,}" == "$role" ]]; then
            select_idx "$i"
            found=0
        fi
    done
    return "$found"
}

# Role unik sesuai urutan inventory
list_roles() {
    local i
    local -A seen=()
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        [[ -n "${seen[${N_ROLE[$i]}]+x}" ]] && continue
        seen["${N_ROLE[$i]}"]=1
        printf '%s\n' "${N_ROLE[$i]}"
    done
    return 0
}

role_count() {
    local i n=0
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        [[ "${N_ROLE[$i]}" == "$1" ]] && n=$(( n + 1 ))
    done
    printf '%d' "$n"
}

# Terapkan pilihan dari picker: role:<Role> | uc | node:<idx>
apply_pick() {
    case "$1" in
        role:*) select_role "${1#role:}" || true ;;
        uc)     select_idx "$UC_IDX" ;;
        node:*) select_idx "${1#node:}" ;;
    esac
}

picker_entries() {
    local role i
    P_KEY=() P_LABEL=()
    while IFS= read -r role; do
        P_KEY+=("role:$role")
        P_LABEL+=("[semua $role] ($(role_count "$role") node)")
    done < <(list_roles)
    P_KEY+=("uc")
    P_LABEL+=("Undercloud (lokal)")
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        P_KEY+=("node:$i")
        P_LABEL+=("$(printf '%-28s %-20s %s' "${N_NAME[$i]}" "${N_ROLE[$i]}" "${N_IP[$i]}")")
    done
    return 0
}

pick_fzf() {
    local out rc=0 line i
    local -a picked=()

    out="$(
        for i in "${!P_KEY[@]}"; do
            printf '%s\t%s\n' "${P_KEY[$i]}" "${P_LABEL[$i]}"
        done | "${FZF_CMD[@]}" --multi --layout=reverse --border --info=inline \
            --delimiter=$'\t' --with-nth=2.. \
            --prompt='🖥️  node> ' \
            --header=$'Tab: pilih/batal pilih (multi), Enter: selesai, Esc: batal\nHOSTNAME                     ROLE                 IP'
    )" || rc=$?

    (( rc == 0 )) || return 1
    mapfile -t picked <<< "$out"
    for line in "${picked[@]}"; do
        [[ -n "$line" ]] && apply_pick "${line%%$'\t'*}"
    done
    return 0
}

pick_menu() {
    local input tok a b k i ok
    local -a toks=()

    echo
    echo "${C_BOLD}Pilih node:${C_RESET}"
    for i in "${!P_KEY[@]}"; do
        printf '  %2d) %s\n' $(( i + 1 )) "${P_LABEL[$i]}"
    done

    while true; do
        ask input "Nomor (mis. 1 4 5, 3-6, a = semua node overcloud, kosong = batal): "
        input="$(trim "$input")"
        [[ -z "$input" ]] && return 1

        read -ra toks <<< "${input//,/ }"
        ok=1
        for tok in "${toks[@]}"; do
            if [[ "${tok,,}" == "a" ]]; then
                continue
            elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
                (( a >= 1 && b <= ${#P_KEY[@]} && a <= b )) || ok=0
            elif is_uint "$tok"; then
                (( tok >= 1 && tok <= ${#P_KEY[@]} )) || ok=0
            else
                ok=0
            fi
        done
        (( ok )) && break
        echo "${C_RED}❌ Input tidak valid: $input${C_RESET}"
    done

    for tok in "${toks[@]}"; do
        if [[ "${tok,,}" == "a" ]]; then
            for i in "${!N_NAME[@]}"; do
                (( N_LOCAL[i] )) || select_idx "$i"
            done
        elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for (( k = BASH_REMATCH[1]; k <= BASH_REMATCH[2]; k++ )); do
                apply_pick "${P_KEY[$(( k - 1 ))]}"
            done
        else
            apply_pick "${P_KEY[$(( tok - 1 ))]}"
        fi
    done
    return 0
}

select_nodes() {
    local n r i found names=""

    if (( ${#NODE_ARGS[@]} > 0 || ${#ROLE_ARGS[@]} > 0 )); then
        for n in "${NODE_ARGS[@]}"; do
            found="${IDX_BY_NAME[${n,,}]:-}"
            [[ -n "$found" ]] && (( N_LOCAL[found] )) && found=""
            if [[ -z "$found" ]]; then
                # Juga cocokkan short name dari canonical_hostname
                for i in "${!N_NAME[@]}"; do
                    (( N_LOCAL[i] )) && continue
                    if [[ -n "${N_CANON[$i]}" && ( "${N_CANON[$i],,}" == "${n,,}" || "$(short_name "${N_CANON[$i]}")" == "${n,,}" ) ]]; then
                        found="$i"
                        break
                    fi
                done
            fi
            if [[ -n "$found" ]]; then
                select_idx "$found"
            else
                warn "Node tidak dikenal di inventory, dilewati: $n"
            fi
        done
        for r in "${ROLE_ARGS[@]}"; do
            if ! select_role "$r"; then
                warn "Role tidak dikenal di inventory, dilewati: $r (role yang ada: $(list_roles | paste -sd, -))"
            fi
        done
        (( INCLUDE_UC )) && select_idx "$UC_IDX"
    else
        (( INCLUDE_UC )) && select_idx "$UC_IDX"
        picker_entries
        if command -v "${FZF_CMD[0]}" >/dev/null 2>&1; then
            pick_fzf || true
        else
            pick_menu || true
        fi
    fi

    if (( ${#SEL[@]} == 0 )); then
        echo "Tidak ada node yang dipilih."
        log_event SELECT selected=0
        exit 0
    fi

    for i in "${SEL[@]}"; do
        names+="${names:+,}${N_NAME[$i]}"
    done
    echo "✅ Node terpilih     : ${#SEL[@]} (${names})"
    log_event SELECT "selected=${#SEL[@]}" "nodes=$names"
}

# ============================================================
# 5. Host key SSH
# ============================================================

host_key_known() {
    local i="$1" host="${N_IP[$1]}" f
    [[ -n "${N_PORT[$i]}" && "${N_PORT[$i]}" != 22 ]] && host="[$host]:${N_PORT[$i]}"
    for f in "$HOME/.ssh/known_hosts" /etc/ssh/ssh_known_hosts; do
        [[ -r "$f" ]] || continue
        ssh-keygen -F "$host" -f "$f" >/dev/null 2>&1 && return 0
    done
    return 1
}

# check_host_keys LABEL IDX... — host yang belum dikenal: satu konfirmasi
# untuk StrictHostKeyChecking=accept-new; yang dikenal: yes; ditolak: reject.
check_host_keys() {
    local label="$1" i answer names=""
    local -a unknown=()
    shift

    for i in "$@"; do
        (( N_LOCAL[i] )) && continue
        [[ -n "${N_HK[$i]}" ]] && continue
        if command -v ssh-keygen >/dev/null 2>&1 && host_key_known "$i"; then
            N_HK[i]="yes"
        else
            unknown+=("$i")
        fi
    done

    (( ${#unknown[@]} == 0 )) && return 0

    echo
    warn "Host key SSH belum dikenal di known_hosts ($label):"
    for i in "${unknown[@]}"; do
        printf '     %-28s %s\n' "${N_NAME[$i]}" "${N_IP[$i]}"
        names+="${names:+,}${N_NAME[$i]}"
    done
    echo "   Jika diterima, key disimpan ke ~/.ssh/known_hosts saat koneksi pertama"
    echo "   (StrictHostKeyChecking=accept-new). Key yang BERUBAH tetap ditolak."
    ask answer "Terima host key baru untuk ${#unknown[@]} host ini? [y/N]: "

    if is_yes "$answer"; then
        for i in "${unknown[@]}"; do
            N_HK[i]="accept-new"
        done
        log_event DECISION hostkeys=accept-new "hosts=$names"
    else
        for i in "${unknown[@]}"; do
            N_HK[i]="reject"
        done
        log_event DECISION hostkeys=reject "hosts=$names"
    fi
    return 0
}

# Catat fingerprint host key yang baru diterima (setelah koneksi pertama)
log_accepted_key() {
    local i="$1" host="${N_IP[$1]}" fp
    [[ "${N_HK[$i]}" == "accept-new" ]] || return 0
    [[ -n "${N_PORT[$i]}" && "${N_PORT[$i]}" != 22 ]] && host="[$host]:${N_PORT[$i]}"
    fp="$(ssh-keygen -l -F "$host" -f "$HOME/.ssh/known_hosts" 2>/dev/null | awk '!/^#/ {print $3 "/" $2; exit}')" || fp=""
    log_event HOSTKEY_ACCEPTED "host=${N_NAME[$i]}" "ip=${N_IP[$i]}" "fingerprint=${fp:--}"
}

# ============================================================
# 7. Pre-check
# ============================================================

# shellcheck disable=SC2016  # dievaluasi di node
REMOTE_PRECHECK='echo __OSOPS_PRECHECK__
printf "release=%s\n" "$(head -n 1 /etc/rhosp-release 2>/dev/null)"
printf "sos_rpm=%s\n" "$(rpm -q sos 2>/dev/null | head -n 1)"
printf "sosreport=%s\n" "$(command -v sosreport 2>/dev/null)"
if sudo -n true >/dev/null 2>&1; then echo sudo=ok; else echo sudo=fail; fi
printf "free_kb=%s\n" "$(df -Pk /var/tmp 2>/dev/null | awk "NR==2 {print \$4}")"
printf "epoch=%s\n" "$(date +%s)"'

# Parse output pre-check (key=value) ke variabel PC_*
parse_precheck() {
    local line
    PC_OK=0 PC_RELEASE="" PC_RPM="" PC_SOS="" PC_SUDO="" PC_FREE="" PC_EPOCH=""
    while IFS= read -r line; do
        case "$line" in
            __OSOPS_PRECHECK__) PC_OK=1 ;;
            release=*)   PC_RELEASE="$(trim "${line#release=}")" ;;
            sos_rpm=*)   PC_RPM="${line#sos_rpm=}" ;;
            sosreport=*) PC_SOS="${line#sosreport=}" ;;
            sudo=*)      PC_SUDO="${line#sudo=}" ;;
            free_kb=*)   PC_FREE="${line#free_kb=}" ;;
            epoch=*)     PC_EPOCH="${line#epoch=}" ;;
        esac
    done <<< "$1"
}

precheck_local() {
    local out
    out="$(
        echo __OSOPS_PRECHECK__
        printf 'release=%s\n' "$UC_RELEASE"
        printf 'sos_rpm=%s\n' "$(rpm -q sos 2>/dev/null | head -n 1)"
        printf 'sosreport=%s\n' "$(command -v sosreport 2>/dev/null)"
        if sudo -n true >/dev/null 2>&1; then echo sudo=ok; else echo sudo=fail; fi
        printf 'free_kb=%s\n' "$(df -Pk "$LOCAL_SOS_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
        printf 'epoch=%s\n' "$(date +%s)"
    )" || true
    parse_precheck "$out"
}

precheck_node() {
    local i="$1" out rc=0 err reason
    local errfile="$WORK_DIR/precheck-$i.err"

    if (( N_LOCAL[i] )); then
        precheck_local
    elif [[ "${N_HK[$i]}" == "reject" ]]; then
        set_result "$i" SKIPPED "host key unknown"
        return 0
    else
        out="$(ssh_node "$i" "$SSH_TIMEOUT" "$REMOTE_PRECHECK" 2> "$errfile")" || rc=$?
        parse_precheck "$out"
        if (( ! PC_OK )); then
            err="$(cat "$errfile" 2>/dev/null)" || err=""
            reason="$(ssh_fail_reason "$err" "$rc")"
            set_result "$i" SKIPPED "$reason"
            log_event PRECHECK "host=${N_NAME[$i]}" "ip=${N_IP[$i]}" result=SKIPPED "reason=$reason" \
                "rc=$rc" "error=$(tail -n 2 "$errfile" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
            return 0
        fi
        log_accepted_key "$i"
    fi

    N_RELEASE[i]="$PC_RELEASE"
    N_SOS_RPM[i]="$PC_RPM"
    N_EPOCH[i]="$PC_EPOCH"
    N_FREE_KB[i]="$PC_FREE"

    if [[ -z "$PC_SOS" ]]; then
        set_result "$i" SKIPPED "sosreport not found"
    elif [[ "$PC_SUDO" != "ok" ]]; then
        set_result "$i" SKIPPED "sudo failed"
    elif ! is_uint "$PC_EPOCH"; then
        set_result "$i" SKIPPED "precheck failed (no epoch)"
    elif is_uint "$PC_FREE" && (( PC_FREE < MIN_FREE_HARD_GB * 1048576 )); then
        set_result "$i" SKIPPED "insufficient disk"
    fi

    log_event PRECHECK "host=${N_NAME[$i]}" "ip=${N_IP[$i]}" "rhosp_release=${PC_RELEASE:--}" \
        "sos_rpm=${PC_RPM:--}" "sosreport=${PC_SOS:--}" "sudo=${PC_SUDO:--}" \
        "free_kb=${PC_FREE:--}" "epoch=${PC_EPOCH:--}" "result=${N_RESULT[$i]:-OK}" "reason=${N_MSG[$i]:--}"

    if (( ! N_LOCAL[i] )) && [[ -n "$PC_RELEASE" && "$PC_RELEASE" != "$UC_RELEASE" ]]; then
        warn "${N_NAME[$i]}: rhosp-release berbeda dengan undercloud (${PC_RELEASE} vs ${UC_RELEASE})"
    fi
    return 0
}

precheck_nodes() {
    local i answer status free
    local -a low=()

    echo
    echo "${C_BOLD}🔍 Pre-check node...${C_RESET}"
    for i in "${SEL[@]}"; do
        precheck_node "$i"
        free="${N_FREE_KB[$i]:-}"
        if [[ -n "${N_RESULT[$i]}" ]]; then
            status="${C_YELLOW}SKIPPED (${N_MSG[$i]})${C_RESET}"
        else
            status="${C_GREEN}OK${C_RESET}"
            if is_uint "$free" && (( free < MIN_FREE_GB * 1048576 )); then
                status="${C_YELLOW}OK, disk tipis${C_RESET}"
                low+=("$i")
            fi
        fi
        printf '  %-28s %-10s %-12s %s\n' "${N_NAME[$i]}" "$(release_version "${N_RELEASE[$i]}")" \
            "$(is_uint "$free" && human_kb "$free" || printf -- '-')" "$status"
    done

    for i in "${low[@]}"; do
        if (( DRY_RUN )); then
            info "${N_NAME[$i]}: ruang kosong $(human_kb "${N_FREE_KB[$i]}") (< ${MIN_FREE_GB} GiB) — saat eksekusi akan ditanya."
            continue
        fi
        ask answer "⚠️  ${N_NAME[$i]}: ruang kosong $(human_kb "${N_FREE_KB[$i]}") (< ${MIN_FREE_GB} GiB). Tetap kumpulkan? [y/N]: "
        if is_yes "$answer"; then
            log_event DECISION "host=${N_NAME[$i]}" low_disk=continue
        else
            set_result "$i" SKIPPED "insufficient disk"
            log_event DECISION "host=${N_NAME[$i]}" low_disk=skip
        fi
    done
    return 0
}

check_dest_space() {
    local avail n=0 i need
    for i in "${SEL[@]}"; do
        pending "$i" && n=$(( n + 1 ))
    done
    (( n > 0 )) || return 0

    avail="$(df -Pk "$DEST" 2>/dev/null | awk 'NR==2 {print $4}')" || avail=""
    need=$(( n * DEST_GB_PER_NODE * 1048576 ))
    if is_uint "$avail" && (( avail < need )); then
        warn "Ruang kosong di $DEST tinggal $(human_kb "$avail") (< ${DEST_GB_PER_NODE} GiB x $n node). sosreport --all-logs bisa beberapa GB per node."
    fi
    if [[ "$DEST" == "/tmp" ]]; then
        info "Hasil disimpan di /tmp: isinya bisa dibersihkan otomatis oleh sistem (systemd-tmpfiles) dan hilang saat reboot. Pindahkan hasil setelah selesai."
    fi
    log_event DEST "dest=$DEST" "avail_kb=${avail:--}" "nodes=$n"
}

# ============================================================
# 8. Anggota cluster
# ============================================================

# pcs_on IDX ARGS... — sudo pcs di controller IDX
pcs_on() {
    local i="$1" t="$SSH_TIMEOUT" cmd="sudo pcs" a q
    shift
    if [[ "${1:-}" == "--restore" ]]; then
        t="$RESTORE_TIMEOUT"
        shift
    fi
    for a in "$@"; do
        printf -v q '%q' "$a"
        cmd+=" $q"
    done
    ssh_node "$i" "$t" "$cmd"
}

# Untuk log_run: CMD tercatat dengan nama controller, bukan index
# shellcheck disable=SC2329  # dipanggil lewat log_run
pcs_at() {
    local host="$1"
    shift
    pcs_on "${IDX_BY_NAME[${host,,}]}" "$@"
}

usable_ctrl() {
    [[ "${N_HK[$1]}" != "reject" ]]
}

# Daftar controller dengan PREF di depan
ctrl_order() {
    local pref="${1:--1}" c
    (( pref >= 0 )) && printf '%s\n' "$pref"
    for c in "${CTRL_LIST[@]}"; do
        [[ "$c" == "$pref" ]] || printf '%s\n' "$c"
    done
    return 0
}

# Parse "pcs status nodes": baris "<bagian> <status> <nama>"
parse_status_nodes() {
    awk '
        /^[^ \t].*:[ \t]*$/ {
            sec = ($0 ~ /Remote/) ? "remote" : "node"
            next
        }
        /^[ \t]+[A-Za-z][A-Za-z ()]*:/ {
            line = $0
            st = line
            sub(/:.*/, "", st)
            gsub(/^[ \t]+|[ \t]+$/, "", st)
            sub(/^[^:]*:/, "", line)
            n = split(line, a, /[ \t]+/)
            for (k = 1; k <= n; k++) if (a[k] != "") print sec, st, a[k]
        }
    ' <<< "$1"
}

determine_cluster() {
    local i c out rc any=0 status_out sec nst name key idx
    local members="" ignored="" offline="" failed=""
    local -A keymap=()

    for i in "${SEL[@]}"; do
        pending "$i" && (( ! N_LOCAL[i] )) && any=1
    done
    (( any )) || return 0

    echo
    echo "${C_BOLD}🧩 Status cluster Pacemaker...${C_RESET}"

    for c in "${CTRL_LIST[@]}"; do
        usable_ctrl "$c" || continue
        rc=0
        out="$(pcs_on "$c" status nodes 2> "$WORK_DIR/pcs.err")" || rc=$?
        if (( rc == 0 )) && [[ "$out" == *"Pacemaker Nodes"* ]]; then
            PCS_CTRL="$c"
            log_accepted_key "$c"
            break
        fi
        log_warn -q "pcs status nodes gagal di ${N_NAME[$c]} rc=$rc: $(tail -n 2 "$WORK_DIR/pcs.err" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
        echo "  ${C_YELLOW}⚠️  ${N_NAME[$c]}: pcs tidak bisa dijalankan, coba controller berikutnya${C_RESET}"
    done

    if (( PCS_CTRL < 0 )); then
        warn "Anggota cluster tidak bisa ditentukan (tidak ada controller yang bisa menjalankan pcs)."
        for i in "${SEL[@]}"; do
            pending "$i" || continue
            (( N_LOCAL[i] )) && continue
            if [[ "${N_PCMK[$i]}" == 1 || "${N_PCMKR[$i]}" == 1 ]] || is_controller_role "$i"; then
                set_result "$i" SKIPPED "cluster status unknown"
            fi
        done
        log_event CLUSTER known=0
        return 0
    fi
    CLUSTER_KNOWN=1

    # Kunci pencocokan: hostname, short canonical_hostname, short ansible_host
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        keymap["${N_NAME[$i],,}"]=$i
        [[ -n "${N_CANON[$i]}" ]] && keymap["$(short_name "${N_CANON[$i]}")"]=$i
        is_ip "${N_IP[$i]}" || keymap["$(short_name "${N_IP[$i]}")"]=$i
    done

    while read -r sec nst name; do
        [[ -n "$name" ]] || continue
        [[ "${nst,,}" == offline* ]] && offline+="${offline:+ }$name"
        key="${name,,}"
        idx="${keymap[$key]:-${keymap[$(short_name "$name")]:-}}"
        if [[ -z "$idx" ]]; then
            [[ " $ignored " == *" $name "* ]] || ignored+="${ignored:+ }$name"
            continue
        fi
        if [[ -z "${N_MEMBER[$idx]}" ]]; then
            N_MEMBER[idx]="$sec"
            members+="${members:+ }${N_NAME[$idx]}($sec)"
        fi
    done < <(parse_status_nodes "$out")

    # Nama cluster, failed actions, quorum dari "pcs status"
    status_out="$(pcs_on "$PCS_CTRL" status 2>/dev/null)" || status_out=""
    CLUSTER_NAME="$(awk -F': *' '/^Cluster name:/ {print $2; exit}' <<< "$status_out")"
    CLUSTER_NAME="$(trim "$CLUSTER_NAME")"
    [[ -n "$CLUSTER_NAME" ]] || CLUSTER_NAME="pcs@${N_NAME[$PCS_CTRL]}"
    failed="$(awk '
        /^Failed Resource Actions:/ { f = 1; next }
        f && /^[^ \t]/ { f = 0 }
        f && /^[ \t]*\*/ { sub(/^[ \t]*\*[ \t]*/, ""); print }
    ' <<< "$status_out")"

    echo "  Controller pcs : ${N_NAME[$PCS_CTRL]} (${N_IP[$PCS_CTRL]})"
    echo "  Cluster        : $CLUSTER_NAME"
    echo "  Anggota        : ${members:-(tidak ada yang cocok dengan inventory)}"
    [[ -n "$ignored" ]] && echo "  ${C_DIM}Diabaikan (bukan host inventory, mis. guest bundle): $ignored${C_RESET}"

    for i in "${SEL[@]}"; do
        pending "$i" || continue
        [[ -n "${N_MEMBER[$i]}" ]] && N_CLUSTER[i]=1
        if [[ -z "${N_MEMBER[$i]}" && ( "${N_PCMK[$i]}" == 1 || "${N_PCMKR[$i]}" == 1 ) ]]; then
            warn "${N_NAME[$i]} ada di grup pacemaker/pacemaker_remote inventory tetapi tidak terlihat di pcs status nodes."
        fi
    done

    if [[ -n "$offline" || -n "$failed" || "$status_out" == *"WITHOUT quorum"* ]]; then
        CLUSTER_UNHEALTHY=1
        echo "  ${C_RED}${C_BOLD}Cluster tidak sehat:${C_RESET}"
        [[ -n "$offline" ]] && echo "    - node offline: $offline"
        [[ "$status_out" == *"WITHOUT quorum"* ]] && echo "    - partition WITHOUT quorum"
        if [[ -n "$failed" ]]; then
            echo "    - failed resource actions: $(wc -l <<< "$failed")"
            head -n 5 <<< "$failed" | sed 's/^/        /'
        fi
    else
        echo "  Kesehatan      : ${C_GREEN}OK${C_RESET} (tidak ada node offline / failed actions)"
    fi

    log_event CLUSTER known=1 "controller=${N_NAME[$PCS_CTRL]}" "cluster=$CLUSTER_NAME" \
        "members=${members:--}" "ignored=${ignored:--}" "offline=${offline:--}" \
        "failed_actions=$( [[ -n "$failed" ]] && wc -l <<< "$failed" || echo 0)" "unhealthy=$CLUSTER_UNHEALTHY"
}

confirm_cluster_health() {
    local i answer any=0
    (( CLUSTER_UNHEALTHY )) || return 0
    for i in "${SEL[@]}"; do
        pending "$i" && (( N_CLUSTER[i] )) && any=1
    done
    (( any )) || return 0

    if (( DRY_RUN )); then
        warn "Cluster tidak sehat — saat eksekusi akan diminta konfirmasi."
        return 0
    fi

    warn "Cluster tidak sehat. Men-disable fencing dan menambah beban di node cluster bisa memperburuk kondisi."
    ask answer "Tetap lanjut mengumpulkan dari node cluster? [y/N]: "
    if is_yes "$answer"; then
        log_event DECISION cluster_unhealthy=continue
        return 0
    fi
    log_event DECISION cluster_unhealthy=skip
    for i in "${SEL[@]}"; do
        pending "$i" && (( N_CLUSTER[i] )) && set_result "$i" DECLINED "cluster unhealthy"
    done
    return 0
}

# ============================================================
# 9. stonith-enabled (get / set / unset / verify)
# ============================================================

# parse_stonith TEXT => true|false|unset (return 1 jika nilai tidak dikenal)
parse_stonith() {
    local line v=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*stonith-enabled[[:space:]]*[:=][[:space:]]*([^[:space:]]*) ]]; then
            v="${BASH_REMATCH[1],,}"
            break
        fi
    done <<< "$1"

    case "$v" in
        "")                    printf 'unset' ;;
        true|yes|on|1|y)       printf 'true' ;;
        false|no|off|0|n)      printf 'false' ;;
        *)                     return 1 ;;
    esac
}

# get_stonith IDX [--restore] => STONITH_VAL; return 1 jika tidak bisa dibaca
get_stonith() {
    local i="$1" opt="${2:-}" out rc=0
    local -a o=()
    [[ -n "$opt" ]] && o=("$opt")

    STONITH_VAL=""
    out="$(pcs_on "$i" "${o[@]}" property config stonith-enabled 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
        # Fallback: pcs config (pcs lama tanpa "property config")
        rc=0
        out="$(pcs_on "$i" "${o[@]}" config 2>/dev/null)" || rc=$?
        (( rc == 0 )) || return 1
        out="$(grep -i 'stonith-enabled' <<< "$out")" || out=""
    fi
    STONITH_VAL="$(parse_stonith "$out")" || return 1
    return 0
}

stonith_effective_true() {
    [[ "$1" == "true" || "$1" == "unset" ]]
}

# ============================================================
# State file (pemulihan setelah crash)
# ============================================================

init_state_path() {
    STATE_FILE=""
    [[ -n "$LOG_FILE" ]] && STATE_FILE="$(dirname "$LOG_FILE")/collect-sosreport-fencing.state"
    return 0
}

write_state() {
    local orig="$1" tmp
    [[ -n "$STATE_FILE" ]] || return 1
    tmp="$STATE_FILE.tmp.$$"
    if ! ( umask 077; set -o noclobber
           {
               echo "# collect-sosreport: fencing di-disable sementara. Hapus HANYA setelah"
               echo "# stonith-enabled dipulihkan ke nilai awal (original) di bawah."
               echo "run_id=${LOG_RUN_ID:--}"
               echo "controller=${N_NAME[$PCS_CTRL]}"
               echo "controller_ip=${N_IP[$PCS_CTRL]}"
               echo "cluster=$CLUSTER_NAME"
               echo "original=$orig"
               echo "disabled_at=$(date -Iseconds)"
               echo "operator=${SUDO_USER:-$(id -un)}"
           } > "$tmp" ) 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    if ! mv -fT -- "$tmp" "$STATE_FILE" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    log_event STATE_FILE action=write "file=$STATE_FILE" "original=$orig"
    return 0
}

remove_state() {
    [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]] || return 0
    rm -f -- "$STATE_FILE" 2>/dev/null || true
    log_event STATE_FILE action=remove "file=$STATE_FILE"
}

# ============================================================
# 14. Pulihkan fencing
# ============================================================

manual_restore_cmd() {
    if [[ "$FENCING_ORIG" == "unset" ]]; then
        printf 'sudo pcs property unset stonith-enabled   (atau: sudo pcs property set stonith-enabled=true)'
    else
        printf 'sudo pcs property set stonith-enabled=true'
    fi
}

# Pulihkan ke nilai awal (FENCING_ORIG), coba controller satu per satu.
restore_fencing() {
    local c host ok=0 pref="$PCS_CTRL"

    (( FENCING_RESTORE )) || return 0
    (( FENCING_RESTORED == 0 )) || return 0

    echo
    echo "${C_BOLD}🛡️  Memulihkan fencing (stonith-enabled → ${FENCING_ORIG})...${C_RESET}"

    if [[ -n "$STALE_CTRL" && -n "${IDX_BY_NAME[${STALE_CTRL,,}]+x}" ]] && (( pref < 0 )); then
        pref="${IDX_BY_NAME[${STALE_CTRL,,}]}"
    fi

    while read -r c; do
        [[ -n "$c" ]] || continue
        usable_ctrl "$c" || continue
        host="${N_NAME[$c]}"

        if [[ "$FENCING_ORIG" == "unset" ]]; then
            if ! log_run pcs_at "$host" --restore property unset stonith-enabled; then
                log_warn -q "unset stonith-enabled gagal di $host, fallback set true"
                log_run pcs_at "$host" --restore property set stonith-enabled=true || {
                    log_warn -q "set stonith-enabled=true gagal di $host: $LOG_LAST_ERROR"
                    continue
                }
            fi
        else
            log_run pcs_at "$host" --restore property set stonith-enabled=true || {
                log_warn -q "set stonith-enabled=true gagal di $host: $LOG_LAST_ERROR"
                continue
            }
        fi

        if get_stonith "$c" --restore && stonith_effective_true "$STONITH_VAL"; then
            ok=1
            FENCING_RESTORED=1
            echo "  ${C_GREEN}✅ Fencing dipulihkan di cluster ${CLUSTER_NAME:-?} lewat $host (stonith-enabled: $STONITH_VAL)${C_RESET}"
            log_event FENCING action=verify "controller=$host" "value=$STONITH_VAL" expected=true result=ok
            log_result "resource=${CLUSTER_NAME:-unknown}" action=enable-fencing result=SUCCESS \
                "controller=$host" "original=$FENCING_ORIG" "value=$STONITH_VAL"
            remove_state
            break
        fi
        log_warn -q "verifikasi pemulihan gagal di $host (nilai: ${STONITH_VAL:-tidak terbaca})"
    done < <(ctrl_order "$pref")

    if (( ! ok )); then
        FENCING_RESTORED=2
        big_warning "${C_RED}${C_BOLD}FENCING BELUM DIPULIHKAN!${C_RESET}" \
            "stonith-enabled seharusnya dikembalikan ke: $FENCING_ORIG" \
            "Jalankan manual di salah satu controller:" \
            "  $(manual_restore_cmd)" \
            "lalu cek: sudo pcs property config stonith-enabled" \
            "State file dibiarkan: ${STATE_FILE:-(tidak ada)}"
        log_result "resource=${CLUSTER_NAME:-unknown}" action=enable-fencing result=FAILED \
            "original=$FENCING_ORIG" "msg=${LOG_LAST_ERROR:-restore/verify failed on all controllers}"
    fi
    return 0
}

# ============================================================
# 10. State file sisa eksekusi sebelumnya
# ============================================================

check_stale_state() {
    local line k v answer c cur="" ctrl_ok=0
    local -A sf=()

    init_state_path
    if [[ -z "$STATE_FILE" ]]; then
        warn "Logging nonaktif: state file fencing dari eksekusi sebelumnya tidak bisa diperiksa."
        return 0
    fi
    [[ -f "$STATE_FILE" ]] || return 0

    if (( DRY_RUN )) && command -v flock >/dev/null 2>&1 && \
       [[ -f "$(dirname "$STATE_FILE")/collect-sosreport.lock" ]] && \
       ! flock -n "$(dirname "$STATE_FILE")/collect-sosreport.lock" true 2>/dev/null; then
        info "Eksekusi collect-sosreport lain sedang berjalan; state file fencing milik eksekusi tersebut."
        log_event STATE_FILE action=found-active "file=$STATE_FILE"
        return 0
    fi

    local -a lines=()
    mapfile -t lines < "$STATE_FILE"
    for line in "${lines[@]}"; do
        [[ "$line" == \#* || "$line" != *=* ]] && continue
        k="${line%%=*}" v="${line#*=}"
        case "$k" in
            run_id|controller|controller_ip|cluster|original|disabled_at|operator) sf[$k]="$v" ;;
        esac
    done
    STALE_CTRL="${sf[controller]:-}"
    STALE_ORIG="${sf[original]:-}"
    if [[ "$STALE_ORIG" != "true" && "$STALE_ORIG" != "unset" ]]; then
        log_warn -q "state file: original tidak valid '${STALE_ORIG}', dianggap true"
        STALE_ORIG="true"
    fi
    log_event STATE_FILE action=found "file=$STATE_FILE" "run_id=${sf[run_id]:--}" \
        "controller=${STALE_CTRL:--}" "original=$STALE_ORIG" "disabled_at=${sf[disabled_at]:--}"

    check_host_keys "membaca status fencing" "${CTRL_LIST[@]}"

    if [[ -n "$STALE_CTRL" && -n "${IDX_BY_NAME[${STALE_CTRL,,}]+x}" ]]; then
        c="${IDX_BY_NAME[${STALE_CTRL,,}]}"
    else
        c=-1
    fi
    while read -r c; do
        [[ -n "$c" ]] || continue
        usable_ctrl "$c" || continue
        if get_stonith "$c"; then
            cur="$STONITH_VAL"
            ctrl_ok=1
            break
        fi
    done < <(ctrl_order "$c")

    if (( ctrl_ok )) && stonith_effective_true "$cur"; then
        info "State file fencing dari eksekusi sebelumnya ditemukan, tetapi stonith-enabled sudah aktif ($cur). State file dihapus."
        log_event STATE_FILE action=stale-already-restored "value=$cur"
        (( DRY_RUN )) || remove_state
        STALE_ORIG="" STALE_CTRL=""
        return 0
    fi

    big_warning "${C_RED}${C_BOLD}FENCING MUNGKIN MASIH DI-DISABLE OLEH EKSEKUSI SEBELUMNYA${C_RESET}" \
        "State file : $STATE_FILE" \
        "Run        : ${sf[run_id]:--} (${sf[disabled_at]:--}, oleh ${sf[operator]:--})" \
        "Controller : ${STALE_CTRL:--}   Cluster: ${sf[cluster]:--}" \
        "Nilai awal : $STALE_ORIG   Nilai saat ini: ${cur:-tidak bisa dibaca}" \
        "Eksekusi itu berhenti sebelum memulihkan fencing (kill -9, SSH putus, ...)."

    if (( DRY_RUN )); then
        warn "Dry-run: fencing tidak dipulihkan. Jalankan tanpa --dry-run untuk memulihkan."
        return 0
    fi

    while true; do
        ask answer "r = pulihkan sekarang, s = lanjut tanpa memulihkan, q = keluar [r/s/q]: "
        case "${answer,,}" in
            r|s|q) break ;;
        esac
    done
    log_event DECISION "stale_state=${answer,,}"

    case "${answer,,}" in
        r)
            FENCING_ORIG="$STALE_ORIG"
            CLUSTER_NAME="${sf[cluster]:-}"
            FENCING_RESTORE=1
            restore_fencing
            if (( FENCING_RESTORED != 1 )); then
                die "Pemulihan fencing gagal. Pulihkan manual sebelum menjalankan script ini lagi."
            fi
            # Eksekusi ini mulai dari awal tanpa kewajiban pemulihan
            FENCING_RESTORE=0 FENCING_RESTORED=0 FENCING_ORIG="" CLUSTER_NAME=""
            STALE_ORIG="" STALE_CTRL=""
            ;;
        s)
            warn "Lanjut tanpa memulihkan. State file dipertahankan; jika eksekusi ini men-disable fencing, nilai awal diambil dari state file ($STALE_ORIG)."
            ;;
        q)
            echo "Keluar. State file tetap ada: $STATE_FILE"
            exit 0
            ;;
    esac
}

# ============================================================
# Fencing: baca nilai, putuskan, disable
# ============================================================

impact_text() {
    local i has_remote=0
    for i in "${!N_NAME[@]}"; do
        [[ "${N_PCMKR[$i]}" == 1 ]] && has_remote=1
    done
    echo "  Selama fencing mati, Pacemaker tidak akan mem-fence node yang bermasalah;"
    echo "  resource di node yang hang bisa tidak dipindahkan."
    if (( has_remote )); then
        echo "  ${C_YELLOW}Instance HA: selama fencing mati, VM di compute (pacemaker_remote) yang"
        echo "  gagal TIDAK akan dievakuasi otomatis.${C_RESET}"
    fi
}

decide_fencing() {
    local i c ok=0 has_remote=0

    NEED_FENCING=0
    for i in "${SEL[@]}"; do
        pending "$i" && (( N_CLUSTER[i] )) && NEED_FENCING=1
    done

    if (( ! NEED_FENCING )); then
        if (( CLUSTER_KNOWN )); then
            info "Tidak ada node terpilih yang anggota cluster Pacemaker: fencing tidak disentuh."
            log_event FENCING action=skip reason=no-cluster-members
        fi
        return 0
    fi

    while read -r c; do
        [[ -n "$c" ]] || continue
        usable_ctrl "$c" || continue
        if get_stonith "$c"; then
            PCS_CTRL="$c"
            ok=1
            break
        fi
    done < <(ctrl_order "$PCS_CTRL")

    if (( ! ok )); then
        FENCING_STATE="unknown"
        warn "Nilai stonith-enabled tidak bisa dibaca. Node anggota cluster dilewati."
        for i in "${SEL[@]}"; do
            pending "$i" && (( N_CLUSTER[i] )) && set_result "$i" SKIPPED "fencing status unknown"
        done
        log_event FENCING action=read result=unknown
        return 0
    fi

    log_event FENCING action=read "controller=${N_NAME[$PCS_CTRL]}" "value=$STONITH_VAL" "stale_original=${STALE_ORIG:--}"

    if [[ -n "$STALE_ORIG" && "$STONITH_VAL" == "false" ]]; then
        # Opsi "s": fencing masih mati dari eksekusi sebelumnya; nilai awal dari state file
        FENCING_ORIG="$STALE_ORIG"
        FENCING_STATE="carried"
        echo "  stonith-enabled: ${C_YELLOW}false${C_RESET} (masih mati dari eksekusi sebelumnya; nilai awal tercatat: $STALE_ORIG)"
        return 0
    fi

    FENCING_ORIG="$STONITH_VAL"
    echo "  stonith-enabled: $FENCING_ORIG$( [[ "$FENCING_ORIG" == unset ]] && echo ' (tidak diset, efektif true)')"

    if [[ "$FENCING_ORIG" == "false" ]]; then
        FENCING_STATE="already-false"
        for i in "${!N_NAME[@]}"; do
            [[ "${N_PCMKR[$i]}" == 1 ]] && has_remote=1
        done
        big_warning "${C_YELLOW}${C_BOLD}FENCING SUDAH MATI (stonith-enabled=false) SEBELUM SCRIPT DIJALANKAN${C_RESET}" \
            "Script tidak mengubah fencing dan TIDAK akan mengaktifkannya kembali." \
            "$( (( has_remote )) && echo 'Instance HA: selama fencing mati, VM dari compute yang gagal TIDAK dapat dievakuasi.')" \
            "Jika kondisi ini tidak disengaja, aktifkan manual di controller:" \
            "  sudo pcs property set stonith-enabled=true"
        log_warn -q "stonith-enabled sudah false sebelum script dijalankan; script tidak akan mengaktifkannya kembali (cluster=$CLUSTER_NAME instance_ha=$has_remote)"
    fi
    return 0
}

disable_fencing() {
    local i answer host

    (( NEED_FENCING )) || return 0
    case "$FENCING_STATE" in
        already-false|unknown) return 0 ;;
    esac

    if [[ "$FENCING_STATE" == "carried" ]]; then
        if write_state "$FENCING_ORIG"; then
            FENCING_RESTORE=1
            FENCING_STATE="disabled"
            log_event FENCING action=carry "original=$FENCING_ORIG"
        else
            warn "State file tidak bisa ditulis ulang: ${STATE_FILE:-(logging nonaktif)}"
            for i in "${SEL[@]}"; do
                pending "$i" && (( N_CLUSTER[i] )) && set_result "$i" ABORTED "state file not writable"
            done
            FENCING_STATE="statefile-failed"
        fi
        return 0
    fi

    echo
    echo "${C_RED}${C_BOLD}⚠️  Fencing akan di-disable sementara di cluster $CLUSTER_NAME${C_RESET}"
    impact_text
    echo "  Fencing dipulihkan ke nilai awal ($FENCING_ORIG) segera setelah sosreport"
    echo "  semua node cluster selesai (juga saat error/Ctrl-C)."
    ask answer "Ketik 'yes' untuk men-disable fencing: "
    if [[ "${answer,,}" != "yes" ]]; then
        FENCING_STATE="declined"
        log_result "resource=$CLUSTER_NAME" action=disable-fencing result=DECLINED "original=$FENCING_ORIG"
        for i in "${SEL[@]}"; do
            pending "$i" && (( N_CLUSTER[i] )) && set_result "$i" DECLINED "fencing not disabled"
        done
        echo "Fencing tidak di-disable; node anggota cluster dilewati."
        return 0
    fi

    if ! write_state "$FENCING_ORIG"; then
        FENCING_STATE="statefile-failed"
        warn "State file tidak bisa ditulis: ${STATE_FILE:-(logging nonaktif)}. Fencing tidak di-disable."
        log_result "resource=$CLUSTER_NAME" action=disable-fencing result=ABORTED "msg=state file not writable"
        for i in "${SEL[@]}"; do
            pending "$i" && (( N_CLUSTER[i] )) && set_result "$i" ABORTED "state file not writable"
        done
        return 0
    fi

    host="${N_NAME[$PCS_CTRL]}"
    FENCING_RESTORE=1
    if log_run pcs_at "$host" property set stonith-enabled=false && \
       get_stonith "$PCS_CTRL" && [[ "$STONITH_VAL" == "false" ]]; then
        FENCING_STATE="disabled"
        echo "  ${C_GREEN}✅ Fencing di-disable (stonith-enabled=false, terverifikasi)${C_RESET}"
        log_event FENCING action=verify "controller=$host" value=false expected=false result=ok
        log_result "resource=$CLUSTER_NAME" action=disable-fencing result=SUCCESS "controller=$host" "original=$FENCING_ORIG"
        return 0
    fi

    FENCING_STATE="disable-failed"
    warn "Disable fencing gagal atau tidak terverifikasi (nilai: ${STONITH_VAL:-tidak terbaca}). sosreport TIDAK dijalankan di node anggota cluster."
    log_result "resource=$CLUSTER_NAME" action=disable-fencing result=FAILED "controller=$host" \
        "msg=${LOG_LAST_ERROR:-verify failed (value=${STONITH_VAL:-unreadable})}"
    for i in "${SEL[@]}"; do
        pending "$i" && (( N_CLUSTER[i] )) && set_result "$i" ABORTED "fencing disable failed"
    done
    # Kembalikan ke nilai awal (perintah set mungkin sebagian berlaku)
    restore_fencing
}

# ============================================================
# 11-13. Worker per node: sosreport → lokasi file → chown → scp → verifikasi
# ============================================================

sos_remote_cmd() {
    local cmd="timeout --kill-after=120 $(( TIMEOUT_MIN * 60 )) sudo sosreport --batch --all-logs --threads=1"
    [[ -n "$CASE_ID" ]] && cmd+=" --case-id $CASE_ID"
    printf '%s' "$cmd"
}

# Status worker (append key=value, nilai terakhir berlaku)
st() {
    local v="${2//$'\n'/ }"
    printf '%s=%s\n' "$1" "${v//$'\r'/ }" >> "$WORK_DIR/n$JOB_IDX.st"
}

job_fail() {
    st msg "$2"
    st result "$1"
    exit 0
}

# Path arsip sosreport yang aman dipakai (di direktori hasil, nama wajar)
valid_report_path() {
    local p="$1" dir="$2" base
    [[ "$p" == "$dir"/* ]] || return 1
    base="${p#"$dir"/}"
    [[ "$base" != */* && "$base" =~ ^sosreport-[A-Za-z0-9._+-]+\.tar\.[a-z0-9]+$ ]]
}

# Jalankan perintah di node (atau lokal untuk undercloud)
job_exec() {
    local t="$1" cmd="$2"
    if (( N_LOCAL[JOB_IDX] )); then
        timeout --kill-after=10 "$t" bash -c "$cmd" < /dev/null
    else
        ssh_node "$JOB_IDX" "$t" "$cmd"
    fi
}

job_sos() {
    local i="$JOB_IDX" out="$WORK_DIR/n$JOB_IDX.out" rc=0 path="" hash="" sumfile="" sum_method=""
    local dir="$REMOTE_SOS_DIR" cands n cmd sumout

    (( N_LOCAL[i] )) && dir="$LOCAL_SOS_DIR"

    st state "sosreport berjalan"
    cmd="$(sos_remote_cmd)"
    log_event SOSREPORT_START "host=${N_NAME[$i]}" "cmd=$cmd"
    if (( N_LOCAL[i] )); then
        # shellcheck disable=SC2086  # cmd terdiri dari kata-kata aman (case-id tervalidasi)
        timeout --kill-after=30 $(( TIMEOUT_MIN * 60 + 300 )) $cmd > "$out" 2>&1 < /dev/null || rc=$?
    else
        ssh_node "$i" $(( TIMEOUT_MIN * 60 + 300 )) "$cmd" > "$out" 2>&1 || rc=$?
    fi
    log_event SOSREPORT_END "host=${N_NAME[$i]}" "rc=$rc" "output_lines=$(wc -l < "$out")" \
        "tail=$(grep -v '^[[:space:]]*$' "$out" | tail -n 3 | tr '\n' '|' | cut -c1-400)"

    if (( rc == 124 || rc == 137 )); then
        job_fail FAILED "sosreport timeout (${TIMEOUT_MIN}m)"
    elif (( rc != 0 )); then
        job_fail FAILED "sosreport failed (rc=$rc)"
    fi

    st state "mencari file hasil"
    # Utama: path arsip terakhir + baris sha256 dari output sosreport
    path="$(grep -oE '/[^[:space:]]*sosreport-[^[:space:]]*\.tar\.[a-z0-9]+' "$out" | tail -n 1)" || path=""
    hash="$(awk '$1 == "sha256" && $2 ~ /^[0-9a-f]{64}$/ {print $2}' "$out" | tail -n 1)" || hash=""

    if [[ -n "$path" ]] && valid_report_path "$path" "$dir"; then
        st locate_method parse
    else
        [[ -n "$path" ]] && log_warn -q "${N_NAME[$i]}: path dari output tidak valid/di luar $dir: $path"
        path="" hash=""
        # Fallback: arsip terbaru yang dibuat setelah epoch pre-check node
        cands="$(job_exec "$SSH_TIMEOUT" "sudo find $dir -maxdepth 1 -type f -name 'sosreport-*.tar.xz' -newermt @${N_EPOCH[$i]} -printf '%T@ %p\n'" 2>/dev/null)" || cands=""
        cands="$(sort -n <<< "$cands" | awk 'NF >= 2 {print $2}')"
        n="$(grep -c . <<< "$cands")" || n=0
        if (( n > 1 )); then
            log_warn -q "${N_NAME[$i]}: $n kandidat sosreport setelah epoch ${N_EPOCH[$i]}, dipilih yang terbaru"
        fi
        path="$(tail -n 1 <<< "$cands")"
        if [[ -z "$path" ]] || ! valid_report_path "$path" "$dir"; then
            st locate_method none
            job_fail FAILED "report file not found"
        fi
        st locate_method fallback
    fi
    log_event LOCATE "host=${N_NAME[$i]}" "file=$path" "method=$(awk -F= '$1=="locate_method"{m=$2} END{print m}' "$WORK_DIR/n$i.st")"

    # Checksum: file .sha256 > hash dari output > dihitung di node
    sumout="$(job_exec "$SSH_TIMEOUT" "if sudo test -f $path.sha256; then echo __SUMFILE__; sudo cat $path.sha256; fi" 2>/dev/null)" || sumout=""
    if [[ "$sumout" == __SUMFILE__* ]]; then
        sumfile="$path.sha256"
        hash="$(sed -n '2p' <<< "$sumout" | awk '{print $1}')"
        sum_method="file"
    elif [[ -n "$hash" ]]; then
        sum_method="output"
    else
        hash="$(job_exec "$SSH_TIMEOUT" "sudo sha256sum $path" 2>/dev/null | awk '{print $1}')" || hash=""
        sum_method="computed"
    fi
    if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]]; then
        st remote_file "$path"
        job_fail FAILED "checksum not available"
    fi
    log_event CHECKSUM "host=${N_NAME[$i]}" "method=$sum_method" "sha256=$hash"

    st remote_file "$path"
    st remote_sum "$sumfile"
    st sha "$hash"
    st sum_method "$sum_method"
    st sos_done 1
}

job_copy() {
    local i="$JOB_IDX" path sumfile hash base stem ext local_f actual size who

    path="$(st_get "$i" remote_file)"
    sumfile="$(st_get "$i" remote_sum)"
    hash="$(st_get "$i" sha)"

    st state "menyalin"
    if (( N_LOCAL[i] )); then
        who="$(id -un):$(id -gn)"
    else
        who="${N_USER[$i]}:${N_USER[$i]}"
    fi
    if ! job_exec "$SSH_TIMEOUT" "sudo chown $who -- $path${sumfile:+ $sumfile}" > "$WORK_DIR/n$i.chown" 2>&1; then
        log_warn -q "${N_NAME[$i]}: chown gagal: $(tail -n 2 "$WORK_DIR/n$i.chown" | tr '\n' ' ')"
        job_fail FAILED "chown failed"
    fi
    log_event CHOWN "host=${N_NAME[$i]}" "owner=$who" "file=$path"

    # Nama di --dest: jangan timpa; bentrok => suffix run_id (nama dipesan dengan noclobber)
    base="$(basename "$path")"
    local_f="$DEST/$base"
    if [[ -e "$local_f" || -e "$local_f.sha256" ]] || ! ( umask 077; set -o noclobber; : > "$local_f" ) 2>/dev/null; then
        stem="${base%.tar.*}" ext="${base##*.tar.}"
        local_f="$DEST/$stem-${LOG_RUN_ID:-$$}.tar.$ext"
        if [[ -e "$local_f.sha256" ]] || ! ( umask 077; set -o noclobber; : > "$local_f" ) 2>/dev/null; then
            job_fail FAILED "destination file exists: $local_f"
        fi
        st renamed 1
        log_warn -q "${N_NAME[$i]}: $DEST/$base sudah ada, disimpan sebagai $local_f"
    fi
    st local_file "$local_f"

    if (( N_LOCAL[i] )); then
        ( umask 077; cp -- "$path" "$local_f" ) || job_fail FAILED "copy failed"
        [[ -n "$sumfile" ]] && ( umask 077; cp -- "$sumfile" "$local_f.sha256" ) 2>/dev/null
    else
        if ! ( umask 077; scp_fetch "$i" "$path" "$local_f" ) 2> "$WORK_DIR/n$i.scp"; then
            log_warn -q "${N_NAME[$i]}: scp gagal: $(tail -n 2 "$WORK_DIR/n$i.scp" | tr '\n' ' ')"
            job_fail FAILED "scp failed"
        fi
        if [[ -n "$sumfile" ]]; then
            ( umask 077; scp_fetch "$i" "$sumfile" "$local_f.sha256" ) 2>/dev/null || \
                log_warn -q "${N_NAME[$i]}: file checksum tidak tersalin: $sumfile"
        fi
    fi
    chmod 600 -- "$local_f" 2>/dev/null || true
    [[ -f "$local_f.sha256" ]] && chmod 600 -- "$local_f.sha256" 2>/dev/null

    size="$(stat -c %s -- "$local_f" 2>/dev/null)" || size=""
    st size "$size"
    actual="$(sha256sum -- "$local_f" | awk '{print $1}')" || actual=""
    log_event COPY "host=${N_NAME[$i]}" "remote=$path" "local=$local_f" "size=$size" \
        "sha256_expected=$hash" "sha256_actual=$actual"
    if [[ "$actual" != "$hash" ]]; then
        job_fail FAILED "checksum mismatch"
    fi
    st msg "checksum ok"
    st result SUCCESS
}

# node_job IDX MODE (sos | copy | full) — dijalankan di background
node_job() {
    JOB_IDX="$1"
    set +o errexit
    case "$2" in
        sos)  job_sos ;;
        copy) job_copy ;;
        full) job_sos; job_copy ;;
    esac
    exit 0
}

# st_get IDX KEY — nilai terakhir dari file status worker
st_get() {
    local f="$WORK_DIR/n$1.st"
    [[ -f "$f" ]] || return 0
    awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "$f"
}

# Ambil hasil worker ke array N_*
collect_job() {
    local i="$1" r
    N_REMOTE[i]="$(st_get "$i" remote_file)"
    N_REMOTE_SUM[i]="$(st_get "$i" remote_sum)"
    N_SHA[i]="$(st_get "$i" sha)"
    N_LOCALF[i]="$(st_get "$i" local_file)"
    N_SIZE[i]="$(st_get "$i" size)"
    N_METHOD[i]="$(st_get "$i" locate_method)"
    N_SOSDONE[i]="$(st_get "$i" sos_done)"
    r="$(st_get "$i" result)"
    if [[ -n "$r" ]]; then
        set_result "$i" "$r" "$(st_get "$i" msg)"
    fi
}

# shellcheck disable=SC2329  # dipanggil oleh kill_workers
kill_tree() {
    local pid="$1" child
    if command -v pgrep >/dev/null 2>&1; then
        for child in $(pgrep -P "$pid" 2>/dev/null); do
            kill_tree "$child"
        done
    fi
    kill -TERM "$pid" 2>/dev/null || true
}

# shellcheck disable=SC2329  # dipanggil dari hook trap
kill_workers() {
    local pid
    RUNNING_NAMES=""
    for pid in "${!WORKER_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            RUNNING_NAMES+="${RUNNING_NAMES:+, }${N_NAME[${WORKER_PIDS[$pid]}]}"
            kill_tree "$pid"
        fi
        unset "WORKER_PIDS[$pid]"
    done
    return 0
}

print_progress() {
    local pid i now
    now="$(date +%s)"
    for pid in "${!WORKER_PIDS[@]}"; do
        i="${WORKER_PIDS[$pid]}"
        printf '  ⏳ %-28s %-22s %s\n' "${N_NAME[$i]}" "$(st_get "$i" state)" "$(fmt_dur $(( now - N_PH_T0[i] )))"
    done
    return 0
}

# run_jobs MODE IDX... — maksimal PARALLEL worker bersamaan
run_jobs() {
    local mode="$1" qi=0 pid i now last_progress r
    shift
    local -a queue=("$@")

    (( ${#queue[@]} > 0 )) || return 0
    last_progress="$(date +%s)"

    while (( qi < ${#queue[@]} || ${#WORKER_PIDS[@]} > 0 )); do
        while (( ${#WORKER_PIDS[@]} < PARALLEL && qi < ${#queue[@]} )); do
            i="${queue[$qi]}"
            qi=$(( qi + 1 ))
            N_PH_T0[i]="$(date +%s)"
            node_job "$i" "$mode" > "$WORK_DIR/n$i.job" 2>&1 &
            WORKER_PIDS[$!]="$i"
            echo "  ▶ ${N_NAME[$i]}: mulai ($( [[ "$mode" == copy ]] && echo menyalin || echo sosreport))"
        done

        sleep 1

        now="$(date +%s)"
        for pid in "${!WORKER_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null && continue
            wait "$pid" 2>/dev/null || true
            i="${WORKER_PIDS[$pid]}"
            unset "WORKER_PIDS[$pid]"
            N_DUR[i]=$(( N_DUR[i] + now - N_PH_T0[i] ))
            collect_job "$i"
            r="${N_RESULT[$i]}"
            if [[ "$r" == "SUCCESS" ]]; then
                echo "  ${C_GREEN}✅ ${N_NAME[$i]}: SUCCESS ($(fmt_dur "${N_DUR[$i]}"))${C_RESET}"
            elif [[ -n "$r" ]]; then
                echo "  ${C_RED}❌ ${N_NAME[$i]}: $r (${N_MSG[$i]}) ($(fmt_dur "${N_DUR[$i]}"))${C_RESET}"
            else
                echo "  ✔ ${N_NAME[$i]}: sosreport selesai ($(fmt_dur "${N_DUR[$i]}")), menunggu penyalinan"
            fi
        done

        if (( now - last_progress >= PROGRESS_INTERVAL )) && (( ${#WORKER_PIDS[@]} > 0 )); then
            print_progress
            last_progress="$now"
        fi
    done
    return 0
}

# ============================================================
# Rencana, laporan, ringkasan
# ============================================================

show_plan() {
    local i will=0 cmd
    cmd="$(sos_remote_cmd)"

    echo
    echo "${C_BOLD}📋 Rencana${C_RESET}"
    for i in "${SEL[@]}"; do
        if pending "$i"; then
            will=$(( will + 1 ))
            printf '  %-28s %-20s %s%s\n' "${N_NAME[$i]}" "${N_ROLE[$i]}" "${C_GREEN}AKAN DIKUMPULKAN${C_RESET}" \
                "$( (( N_CLUSTER[i] )) && echo " (anggota cluster: ${N_MEMBER[$i]})")"
        else
            printf '  %-28s %-20s %s\n' "${N_NAME[$i]}" "${N_ROLE[$i]}" "${C_YELLOW}${N_RESULT[$i]} (${N_MSG[$i]})${C_RESET}"
        fi
        if (( DRY_RUN )); then
            log_info "PLAN dry_run=true host=${N_NAME[$i]} role=${N_ROLE[$i]} action=$(pending "$i" && echo collect || echo "${N_RESULT[$i]}") reason=${N_MSG[$i]:--} cluster_member=${N_CLUSTER[$i]}"
        fi
    done

    echo
    echo "  Perintah   : $cmd"
    echo "  Tujuan     : $DEST (permission 600)"
    echo "  Paralel    : $PARALLEL, timeout ${TIMEOUT_MIN} menit per node"
    if (( NEED_FENCING )); then
        case "$FENCING_STATE" in
            already-false) echo "  Fencing    : ${C_YELLOW}sudah false sejak awal — tidak diubah, tidak diaktifkan kembali${C_RESET}" ;;
            carried)       echo "  Fencing    : masih false dari eksekusi sebelumnya — dipulihkan ke $FENCING_ORIG setelah node cluster selesai" ;;
            unknown)       echo "  Fencing    : ${C_RED}tidak bisa dibaca — node cluster dilewati${C_RESET}" ;;
            *)             echo "  Fencing    : ${C_RED}${C_BOLD}AKAN DI-DISABLE${C_RESET} di $CLUSTER_NAME (nilai awal $FENCING_ORIG), dipulihkan setelah sosreport node cluster selesai" ;;
        esac
    else
        echo "  Fencing    : tidak disentuh"
    fi
    if (( DRY_RUN )); then
        log_info "PLAN dry_run=true nodes=$will need_fencing=$NEED_FENCING fencing_original=${FENCING_ORIG:--} fencing_state=$FENCING_STATE cmd=\"$cmd\""
    fi
    PLAN_COUNT=$will
}

init_report() {
    REPORT_FILE="$(dirname "$LOG_FILE")/collect-sosreport-${LOG_RUN_ID:-$$}-results.tsv"
    if ! ( umask 077; set -o noclobber
           printf 'timestamp\thostname\trole\tip\trhosp_release\tresult\tremote_file\tlocal_file\tsize_bytes\tsha256\tduration_s\tmessage\n' > "$REPORT_FILE" ) 2>/dev/null; then
        warn "Gagal membuat file laporan: $REPORT_FILE"
        REPORT_FILE=""
    fi
    REPORT_READY=1
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

# log_result + baris TSV per node (sekali)
finalize_results() {
    local i
    (( REPORT_READY && ! FINALIZED )) || return 0
    FINALIZED=1
    for i in "${SEL[@]}"; do
        (( N_LOGGED[i] )) && continue
        N_LOGGED[i]=1
        if [[ -z "${N_RESULT[$i]}" ]]; then
            if (( INTERRUPTED )); then
                set_result "$i" ABORTED "interrupted (sosreport may still run on node)"
            else
                set_result "$i" ABORTED "not run"
            fi
        fi
        log_result "resource=${N_NAME[$i]}" action=sos-report "result=${N_RESULT[$i]}" \
            "role=${N_ROLE[$i]}" "ip=${N_IP[$i]}" "file=${N_LOCALF[$i]:--}" "size=${N_SIZE[$i]:--}" \
            "duration=${N_DUR[$i]}s" "msg=${N_MSG[$i]:--}"
        tsv_row "${N_NAME[$i]}" "${N_ROLE[$i]}" "${N_IP[$i]}" "${N_RELEASE[$i]}" "${N_RESULT[$i]}" \
            "${N_REMOTE[$i]}" "${N_LOCALF[$i]}" "${N_SIZE[$i]}" "${N_SHA[$i]}" "${N_DUR[$i]}" "${N_MSG[$i]}"
    done
    return 0
}

cleanup_remote() {
    local i answer n=0 rc
    local -a ok=()

    for i in "${SEL[@]}"; do
        [[ "${N_RESULT[$i]}" == "SUCCESS" && -n "${N_REMOTE[$i]}" ]] && ok+=("$i")
    done
    (( ${#ok[@]} > 0 )) || return 0

    if (( KEEP_REMOTE )); then
        log_info "remote cleanup dilewati (--keep-remote): file sosreport tetap di node, dimiliki user SSH"
        return 0
    fi

    echo
    ask answer "🧹 Hapus file sosreport di ${#ok[@]} node (/var/tmp) yang sudah tersalin dan checksum cocok? [y/N]: "
    if ! is_yes "$answer"; then
        log_event DECISION remote_cleanup=declined
        log_info "file sosreport tetap ada di node (dimiliki user SSH): $(for i in "${ok[@]}"; do printf '%s:%s ' "${N_NAME[$i]}" "${N_REMOTE[$i]}"; done)"
        return 0
    fi
    log_event DECISION remote_cleanup=accepted

    for i in "${ok[@]}"; do
        JOB_IDX="$i"
        rc=0
        # Tanpa sudo: file sudah milik user SSH di /var/tmp (sticky)
        job_exec "$SSH_TIMEOUT" "rm -f -- ${N_REMOTE[$i]}${N_REMOTE_SUM[$i]:+ ${N_REMOTE_SUM[$i]}}" > /dev/null 2>&1 || rc=$?
        if (( rc == 0 )); then
            n=$(( n + 1 ))
            log_event REMOTE_CLEANUP "host=${N_NAME[$i]}" "file=${N_REMOTE[$i]}" result=SUCCESS
        else
            warn "${N_NAME[$i]}: gagal menghapus ${N_REMOTE[$i]} (rc=$rc)"
            log_event REMOTE_CLEANUP "host=${N_NAME[$i]}" "file=${N_REMOTE[$i]}" result=FAILED "rc=$rc"
        fi
    done
    echo "  Dihapus di $n node."
}

summary() {
    local i color total_ok=0

    finalize_results

    echo
    echo "${C_BOLD}========================================${C_RESET}"
    echo "${C_BOLD}📊 Ringkasan${C_RESET}"
    echo "${C_BOLD}========================================${C_RESET}"
    printf '%-28s %-18s %-8s %-9s %-8s %-8s %s\n' HOSTNAME ROLE RHOSP RESULT SIZE DURASI "FILE / PESAN"
    for i in "${SEL[@]}"; do
        case "${N_RESULT[$i]}" in
            SUCCESS) color="$C_GREEN"; total_ok=$(( total_ok + 1 )) ;;
            SKIPPED|DECLINED) color="$C_YELLOW" ;;
            *) color="$C_RED" ;;
        esac
        printf '%-28s %-18s %-8s %s%-9s%s %-8s %-8s %s\n' "${N_NAME[$i]}" "${N_ROLE[$i]}" \
            "$(release_version "${N_RELEASE[$i]}")" "$color" "${N_RESULT[$i]}" "$C_RESET" \
            "$(human_bytes "${N_SIZE[$i]}")" "$(fmt_dur "${N_DUR[$i]}")" \
            "$( if [[ "${N_RESULT[$i]}" == SUCCESS ]]; then basename "${N_LOCALF[$i]}"; else
                printf '%s' "${N_MSG[$i]}"; [[ -n "${N_LOCALF[$i]}" ]] && printf ' (%s)' "$(basename "${N_LOCALF[$i]}")"; fi )"
        if [[ "${N_RESULT[$i]}" == FAILED && -n "${N_REMOTE[$i]}" ]] && (( ! N_LOCAL[i] )); then
            echo "    ${C_DIM}file di node tetap ada: ${N_REMOTE[$i]}${C_RESET}"
        fi
    done

    echo
    echo "Fencing:"
    echo "  Nilai awal stonith-enabled : ${FENCING_ORIG:--}"
    case "$FENCING_STATE" in
        none)
            echo "  Tidak disentuh (tidak ada node anggota cluster yang dikumpulkan)" ;;
        already-false)
            echo "  ${C_YELLOW}${C_BOLD}⚠️  Sudah false sebelum script dijalankan — tidak diubah dan TIDAK diaktifkan kembali.${C_RESET}"
            echo "     Aktifkan manual jika tidak disengaja: sudo pcs property set stonith-enabled=true" ;;
        declined)
            echo "  Tidak di-disable (operator menolak); node cluster dilewati" ;;
        unknown)
            echo "  Tidak bisa dibaca; node cluster dilewati" ;;
        statefile-failed)
            echo "  Tidak di-disable (state file tidak bisa ditulis)" ;;
        disable-failed)
            echo "  ${C_RED}Disable gagal/tidak terverifikasi — node cluster tidak dikumpulkan${C_RESET}"
            if (( FENCING_RESTORED == 1 )); then
                echo "  ${C_GREEN}✅ Nilai awal ($FENCING_ORIG) dipulihkan dan terverifikasi${C_RESET}"
            elif (( FENCING_RESTORED == 2 )); then
                echo "  ${C_RED}${C_BOLD}❌ GAGAL dipulihkan — jalankan: $(manual_restore_cmd)${C_RESET}"
            fi ;;
        *)
            echo "  Di-disable oleh script     : ya"
            if (( FENCING_RESTORED == 1 )); then
                echo "  ${C_GREEN}✅ Sudah dipulihkan ke nilai awal ($FENCING_ORIG) dan terverifikasi${C_RESET}"
            elif (( FENCING_RESTORED == 2 )); then
                echo "  ${C_RED}${C_BOLD}❌ GAGAL dipulihkan — jalankan: $(manual_restore_cmd)${C_RESET}"
            fi ;;
    esac

    echo
    echo "Berhasil     : $total_ok / ${#SEL[@]}"
    echo "Hasil        : $DEST"
    [[ -n "$REPORT_FILE" ]] && echo "Laporan      : $REPORT_FILE"
    [[ -n "$LOG_FILE" ]] && echo "Log          : $LOG_FILE"

    log_event SUMMARY "total=${#SEL[@]}" "success=$total_ok" "fencing_original=${FENCING_ORIG:--}" \
        "fencing_state=$FENCING_STATE" "fencing_restored=$FENCING_RESTORED" "dest=$DEST"
}

# ============================================================
# Hook library (trap EXIT/INT/TERM milik lib/logging.sh)
# ============================================================

# shellcheck disable=SC2329  # dipanggil lewat LOG_INTERRUPT_HOOK
on_interrupt() {
    INTERRUPTED=1
    kill_workers
    echo
    warn "Dihentikan (${1:-INT})."
    if [[ -n "$RUNNING_NAMES" ]]; then
        warn "sosreport yang sedang berjalan di node berikut mungkin masih berlanjut: $RUNNING_NAMES"
    fi
}

# shellcheck disable=SC2329  # dipanggil lewat LOG_EXIT_HOOK
on_exit() {
    set +o errexit
    # Keluar tidak normal (SIGHUP, error) dengan node belum selesai
    (( ${1:-0} != 0 )) && INTERRUPTED=1
    if (( FENCING_RESTORE && FENCING_RESTORED == 0 )); then
        # Ctrl-C kedua / SIGTERM / SIGHUP tidak boleh memotong pemulihan
        # (durasi dibatasi timeout per controller)
        trap '' INT TERM HUP
        kill_workers
        [[ -n "$RUNNING_NAMES" ]] && \
            warn "sosreport yang sedang berjalan di node berikut mungkin masih berlanjut: $RUNNING_NAMES"
        restore_fencing
    fi
    kill_workers
    finalize_results
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"
    return 0
}

# ============================================================
# Argumen
# ============================================================

need_arg() {
    [[ -n "${2:-}" ]] || die "$1 membutuhkan nilai."
}

while (( $# > 0 )); do
    case "$1" in
        --inventory)          need_arg "$1" "${2:-}"; INVENTORY="$2"; shift 2 ;;
        --node)               need_arg "$1" "${2:-}"; NODE_ARGS+=("$2"); shift 2 ;;
        --role)               need_arg "$1" "${2:-}"; ROLE_ARGS+=("$2"); shift 2 ;;
        --include-undercloud) INCLUDE_UC=1; shift ;;
        --case-id)            need_arg "$1" "${2:-}"; CASE_ID="$2"; shift 2 ;;
        --dest)               need_arg "$1" "${2:-}"; DEST="$2"; shift 2 ;;
        --parallel)           need_arg "$1" "${2:-}"; PARALLEL="$2"; shift 2 ;;
        --timeout)            need_arg "$1" "${2:-}"; TIMEOUT_MIN="$2"; shift 2 ;;
        --keep-remote)        KEEP_REMOTE=1; shift ;;
        --dry-run)            DRY_RUN=1; shift ;;
        *)
            echo "❌ Parameter tidak dikenal: $1"
            echo
            usage
            exit 1
            ;;
    esac
done

[[ "$CASE_ID" =~ ^[A-Za-z0-9._-]*$ ]] || die "--case-id hanya boleh huruf, angka, titik, minus, underscore."
if ! is_uint "$PARALLEL" || (( PARALLEL < 1 )); then
    die "--parallel harus bilangan bulat >= 1."
fi
if ! is_uint "$TIMEOUT_MIN" || (( TIMEOUT_MIN < 1 )); then
    die "--timeout harus bilangan bulat (menit) >= 1."
fi
for _v in MIN_FREE_GB MIN_FREE_HARD_GB DEST_GB_PER_NODE PROGRESS_INTERVAL; do
    is_uint "${!_v}" || die "Nilai $_v tidak valid: ${!_v}"
done

# ============================================================
# Main
# ============================================================

has_tty || die "Terminal (/dev/tty) tidak tersedia. Jalankan dari terminal interaktif."

WORK_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/collect-sosreport.XXXXXX")" || die "Gagal membuat direktori sementara."
LOG_EXIT_HOOK=on_exit
LOG_INTERRUPT_HOOK=on_interrupt

echo "========================================"
echo "🧰 Collect sosreport$( (( DRY_RUN )) && echo ' (DRY-RUN)')"
echo "========================================"

check_environment
if (( ! DRY_RUN )); then
    acquire_lock
    check_session
fi
find_inventory
load_nodes
check_stale_state
select_nodes

# Host key: node terpilih + controller (untuk pcs)
_hk=()
for _i in "${SEL[@]}"; do
    (( N_LOCAL[_i] )) || _hk+=("$_i")
done
if (( ${#_hk[@]} > 0 )); then
    check_host_keys "node terpilih dan controller untuk pcs" "${_hk[@]}" "${CTRL_LIST[@]}"
fi

precheck_nodes
check_dest_space
determine_cluster
confirm_cluster_health
decide_fencing
PLAN_COUNT=0
show_plan

if (( DRY_RUN )); then
    echo
    echo "${C_CYAN}DRY-RUN: fencing tidak diubah, sosreport tidak dijalankan, tidak ada yang disalin.${C_RESET}"
    log_info "SUMMARY dry_run=true selected=${#SEL[@]} will_collect=$PLAN_COUNT need_fencing=$NEED_FENCING fencing_state=$FENCING_STATE"
    [[ -n "$LOG_FILE" ]] && echo "Log: $LOG_FILE"
    exit 0
fi

init_report

if (( PLAN_COUNT == 0 )); then
    echo
    echo "Tidak ada node yang bisa dikumpulkan."
    summary
    exit 0
fi

echo
echo "Undercloud: $(hostname -f 2>/dev/null || hostname)  •  $UC_RELEASE"
_answer=""
ask _answer "Lanjutkan mengumpulkan sosreport dari $PLAN_COUNT node? [y/N]: "
if ! is_yes "$_answer"; then
    log_event DECISION plan=declined
    for _i in "${SEL[@]}"; do
        pending "$_i" && set_result "$_i" DECLINED "declined at confirmation"
    done
    summary
    exit 0
fi
log_event DECISION plan=accepted

disable_fencing

# Fase A (fencing di-disable oleh script): sosreport node cluster dulu,
# lalu fencing segera dipulihkan sebelum penyalinan dan node lain.
_cluster=() _rest=()
for _i in "${SEL[@]}"; do
    pending "$_i" || continue
    if (( N_CLUSTER[_i] )); then
        _cluster+=("$_i")
    else
        _rest+=("$_i")
    fi
done

if (( FENCING_RESTORE )) && [[ "$FENCING_STATE" == "disabled" ]]; then
    echo
    echo "${C_BOLD}▶ Fase 1: sosreport node anggota cluster (fencing di-disable)${C_RESET}"
    run_jobs sos "${_cluster[@]}"
    restore_fencing

    _copy=()
    for _i in "${_cluster[@]}"; do
        pending "$_i" && (( N_SOSDONE[_i] )) && _copy+=("$_i")
    done
    echo
    echo "${C_BOLD}▶ Fase 2: penyalinan hasil node cluster, lalu node lain${C_RESET}"
    run_jobs copy "${_copy[@]}"
    run_jobs full "${_rest[@]}"
else
    echo
    echo "${C_BOLD}▶ Mengumpulkan sosreport${C_RESET}"
    run_jobs full "${_cluster[@]}" "${_rest[@]}"
fi

cleanup_remote
summary

# Fencing tidak berhasil dipulihkan => exit code non-zero (TUI menandai)
(( FENCING_RESTORED == 2 )) && exit 2
exit 0
