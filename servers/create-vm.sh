#!/bin/bash
# ============================================================
# @name:        Create VM
# @description: Create an instance (boot from image or volume) with distro-aware cloud-init
# @mutates:     yes
# @requires:    jq, openssl
# @tags:        nova, server, create, volume, cloud-init, keypair
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: create-vm.sh [opsi]

Buat VM (boot dari volume atau image) dengan cloud-init sesuai distro:
user distro dengan sudo, password acak (hanya hash SHA-512 yang dikirim)
dan/atau public key. Berjalan di OpenStack upstream dan RHOSP 17.1:
kemampuan CLI dideteksi saat runtime. Tanpa opsi, semua ditanyakan.

Project:
  --project NAMA|ID          Project tujuan (scope diganti hanya di proses ini)
  --project-domain NAMA|ID   Domain project (jika nama project tidak unik)
VM:
  --name NAMA                Nama VM (--count > 1: NAMA-1, NAMA-2, ...)
  --image NAMA|ID            Image (hanya rhel/centos/ubuntu/debian/cirros)
  --distro D                 rhel | centos | ubuntu | debian | cirros (override deteksi)
  --flavor NAMA|ID           Flavor
  --boot volume|image        Sumber boot (default volume)
  --volume-size GB           Ukuran root volume
  --volume-type NAMA         Volume type (default: type default Cinder)
  --delete-volume-on-terminate | --keep-volume
                             Hapus root volume saat VM dihapus (default: hapus)
  --network NAMA|ID          Network (bisa diulang; urutan = urutan NIC)
  --security-group NAMA|ID   Security group (bisa diulang)
  --availability-zone ZONE   Availability zone
  --host COMPUTE             Compute tujuan (admin)
  --floating-ip NETWORK      Alokasikan dan pasang floating IP dari network external
  --count N                  Jumlah VM (default 1)
Akses:
  --key-name NAMA            Keypair yang sudah terdaftar
  --public-key PATH          Public key (keypair dipakai ulang jika fingerprint sama)
  --no-key                   Tanpa key
  --username NAMA            Override username default distro
  --no-password              Tanpa password (login hanya dengan key)
Lainnya:
  --timeout MENIT            Batas tunggu ACTIVE per VM / volume (default 15)
  --dry-run                  Langkah 1-11 saja: tanpa keypair, volume, VM, floating IP
  -h, --help                 Tampilkan help

Username default: debian=debian, ubuntu=ubuntu, rhel=cloud-user,
centos=cloud-user (CentOS 7 lama: centos, pakai --username). CirrOS tanpa
cloud-init (kredensial bawaan image).

Environment (terutama untuk tes):
  OSOPS_OS_CMD                Perintah OpenStack CLI (default: openstack)
  OSOPS_COMPUTE_API_VERSION   Compute microversion (default 2.85; diturunkan ke maks. cloud)
  OSOPS_FZF, OSOPS_CURL       Pengganti fzf / curl
  OSOPS_POLL_INTERVAL         Interval polling detik (default 5)
  OSOPS_CREDS_DIR             Lokasi file kredensial opsional (default /tmp)
  OSOPS_TIMEOUT_SEC           Timeout dalam detik (menimpa --timeout; untuk tes)
EOF
}

for _arg in "$@"; do
    if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

# Logging terpusat (lib/logging.sh) + helper API (lib/api.sh)
# shellcheck source=../lib/logging.sh
if ! source "${OSOPS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/logging.sh" 2>/dev/null; then
    echo "❌ lib/logging.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi
log_init
# shellcheck source=../lib/api.sh
if ! source "$OSOPS_HOME/lib/api.sh" 2>/dev/null; then
    echo "❌ lib/api.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi

# ============================================================
# Konfigurasi
# ============================================================

# Compute microversion (satu tempat, bisa di-override):
#   2.67 volume_type di --block-device, 2.74 --host,
#   2.85 server volume update --delete-on-termination.
COMPUTE_API_VERSION="${OSOPS_COMPUTE_API_VERSION:-2.85}"
MV_BDM_TYPE="2.67"
MV_HOST="2.74"
MV_VOL_UPDATE="2.85"

if [[ -n "${OSOPS_OS_CMD:-}" ]]; then
    read -ra OS_CMD <<< "$OSOPS_OS_CMD"
else
    OS_CMD=(openstack)
fi
read -ra FZF_CMD <<< "${OSOPS_FZF:-fzf}"
POLL_INTERVAL="${OSOPS_POLL_INTERVAL:-5}"
CREDS_DIR="${OSOPS_CREDS_DIR:-/tmp}"
TIMEOUT_SEC=""      # dari --timeout (menit); OSOPS_TIMEOUT_SEC menimpa (tes)

US=$'\x1f'

# Opsi
OPT_PROJECT="" OPT_PROJECT_DOMAIN="" OPT_NAME="" OPT_IMAGE="" OPT_DISTRO="" OPT_FLAVOR=""
OPT_BOOT="" OPT_VOL_SIZE="" OPT_VOL_TYPE="" OPT_DELETE_VOL="" OPT_KEY_NAME="" OPT_PUBKEY=""
OPT_NO_KEY=0 OPT_USERNAME="" OPT_NO_PASSWORD=0 OPT_HOST="" OPT_AZ="" OPT_FIP="" OPT_COUNT=""
OPT_TIMEOUT=15 DRY_RUN=0
OPT_NETWORKS=() OPT_SECGROUPS=()

# Kemampuan CLI/cloud (detect_caps)
CAP_BDM_FULL=0 CAP_DISK_REQUIRED=1 CAP_HOST_OPT=0 CAP_VOL_UPDATE=0 MV_MAX=""
BOOT_PATH=""        # A (--block-device) | B (volume dulu) | image

# Pilihan
WORK_DIR=""
SCOPE_PROJECT_ID="" PICK_PROJECT_ID="" RESOLVED_PROJECT_ID="" PROJECT_ID="" PROJECT_NAME="" PROJECT_DOMAIN=""
IMG_ID="" IMG_NAME="" IMG_DISTRO="" IMG_MIN_DISK=0 IMG_MIN_RAM=0 IMG_SIZE=0 IMG_VSIZE=0
FLV_ID="" FLV_NAME="" FLV_RAM=0 FLV_DISK=0 FLV_VCPU=0
BOOT="volume" VOL_SIZE=0 VOL_TYPE="" DEF_VTYPE="" DELETE_VOL=1
NET_IDS=() NET_NAMES=()
SG_IDS=() SG_NAMES=()
KEY_MODE="none"     # none | existing | create
KEY_NAME="" KEY_FP="" PUBKEY_FILE="" PUBKEY_TEXT=""
USERNAME="" USE_PASSWORD=1
HOST="" HOST_ZONE="" AZ=""
FIP_NET_ID="" FIP_NET_NAME=""
COUNT=1 VM_NAME=""

# Hasil per VM (index 0..COUNT-1)
R_NAME=() R_SERVER=() R_VOLUME=() R_STATUS=() R_RESULT=() R_MSG=() R_FIP=() R_FIP_ID=()
R_HOST=() R_ADDR=() R_DELWARN=()
PASSWORDS=()        # teks asli password, hanya di memori proses ini
KEYPAIR_CREATED=""
PICKED=()

if [[ -t 1 ]]; then
    C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m' C_RESET=$'\e[0m'
else
    C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_RESET=""
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

info() {
    echo "${C_CYAN}ℹ️  $1${C_RESET}"
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

# ask_yn PROMPT DEFAULT(y|n) — return 0 jika ya
ask_yn() {
    local a
    ask a "$1"
    a="${a,,}"
    [[ -z "$a" ]] && a="$2"
    [[ "$a" == y || "$a" == yes ]]
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

# mv_ge A B => true jika microversion A >= B
mv_ge() {
    local a_maj="${1%%.*}" a_min="${1#*.}" b_maj="${2%%.*}" b_min="${2#*.}"
    (( a_maj > b_maj || (a_maj == b_maj && a_min >= b_min) ))
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1073741824) printf "%.1fG", b / 1073741824
        else if (b >= 1048576) printf "%.1fM", b / 1048576
        else if (b >= 1024) printf "%.1fK", b / 1024
        else printf "%dB", b }'
}

# Byte => GiB dibulatkan ke atas
ceil_gb() {
    local b="${1:-0}"
    is_uint "$b" || b=0
    echo $(( (b + 1073741823) / 1073741824 ))
}

fmt_elapsed() {
    printf '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 ))
}

# ============================================================
# OpenStack CLI wrapper
# ============================================================

# Scope project diganti lewat opsi CLI (--os-project-id): OS_CLOUD/clouds.yaml
# bisa mengalahkan variabel environment, opsi CLI tidak.
os_cli() {
    if [[ -n "$SCOPE_PROJECT_ID" ]]; then
        "${OS_CMD[@]}" --os-compute-api-version "$COMPUTE_API_VERSION" --os-project-id "$SCOPE_PROJECT_ID" "$@"
    else
        "${OS_CMD[@]}" --os-compute-api-version "$COMPUTE_API_VERSION" "$@"
    fi
}

# Aksi yang mengubah resource: dicatat (CMD), stderr di LOG_LAST_ERROR
os_run() {
    if [[ -n "$SCOPE_PROJECT_ID" ]]; then
        log_run "${OS_CMD[@]}" --os-compute-api-version "$COMPUTE_API_VERSION" --os-project-id "$SCOPE_PROJECT_ID" "$@"
    else
        log_run "${OS_CMD[@]}" --os-compute-api-version "$COMPUTE_API_VERSION" "$@"
    fi
}

# ============================================================
# Picker (fzf, atau menu bernomor dengan filter teks)
# ============================================================

use_fzf() {
    command -v "${FZF_CMD[0]}" >/dev/null 2>&1
}

# pick FILE MULTI PROMPT HEADER — FILE: "key<TAB>label" per baris.
# Hasil di PICKED (key). Return 1 jika batal.
pick() {
    local file="$1" multi="$2" prompt="$3" header="$4" out rc=0
    local -a extra=()
    PICKED=()
    [[ -s "$file" ]] || return 1
    if use_fzf; then
        (( multi )) && extra=(--multi)
        out="$("${FZF_CMD[@]}" "${extra[@]}" --layout=reverse --border --info=inline \
            --delimiter=$'\t' --with-nth=2.. --prompt="$prompt> " --header="$header" < "$file")" || rc=$?
        (( rc == 0 )) || return 1
        mapfile -t PICKED < <(cut -f1 <<< "$out" | sed '/^$/d')
    else
        pick_menu "$file" "$multi" "$header" || return 1
    fi
    (( ${#PICKED[@]} > 0 ))
}

pick_menu() {
    local file="$1" multi="$2" header="$3" filter="" input tok k ok
    local -a keys=() labels=() shown=() toks=() words=()
    while IFS=$'\t' read -r k input; do
        keys+=("$k")
        labels+=("$input")
    done < "$file"
    while true; do
        shown=()
        echo
        echo "${C_BOLD}${header%%$'\n'*}${filter:+ (filter: \"$filter\")}${C_RESET}"
        read -ra words <<< "${filter,,}"
        for k in "${!keys[@]}"; do
            ok=1
            for tok in "${words[@]}"; do
                [[ "${labels[$k],,}" == *"$tok"* ]] || ok=0
            done
            (( ok )) || continue
            shown+=("$k")
            printf '  %3d) %s\n' "${#shown[@]}" "${labels[$k]}"
        done
        (( ${#shown[@]} == 0 )) && echo "  ${C_DIM}(tidak ada yang cocok)${C_RESET}"
        ask input "Nomor$( (( multi )) && echo ' (mis. 1 3)') / kata kunci filter / kosong = hapus filter / q = batal: "
        input="$(trim "$input")"
        case "$input" in
            q|Q) return 1 ;;
            "")  filter=""; continue ;;
        esac
        read -ra toks <<< "${input//,/ }"
        ok=1
        for tok in "${toks[@]}"; do
            if is_uint "$tok"; then
                (( tok >= 1 && tok <= ${#shown[@]} )) || ok=0
            else
                ok=2
            fi
        done
        if (( ok == 2 )); then filter="$input"; continue; fi
        if (( ok == 0 )) || { (( ! multi )) && (( ${#toks[@]} > 1 )); }; then
            echo "${C_RED}❌ Pilihan tidak valid: $input${C_RESET}"
            continue
        fi
        for tok in "${toks[@]}"; do
            PICKED+=("${keys[${shown[$(( tok - 1 ))]}]}")
        done
        return 0
    done
}

# ============================================================
# Setup: argumen, dependency, kemampuan CLI
# ============================================================

need_value() {
    [[ -n "${2:-}" ]] || die "$1 membutuhkan nilai."
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --project)            need_value "$1" "${2:-}"; OPT_PROJECT="$2"; shift 2 ;;
            --project-domain)     need_value "$1" "${2:-}"; OPT_PROJECT_DOMAIN="$2"; shift 2 ;;
            --name)               need_value "$1" "${2:-}"; OPT_NAME="$2"; shift 2 ;;
            --image)              need_value "$1" "${2:-}"; OPT_IMAGE="$2"; shift 2 ;;
            --distro)             need_value "$1" "${2:-}"; OPT_DISTRO="${2,,}"; shift 2 ;;
            --flavor)             need_value "$1" "${2:-}"; OPT_FLAVOR="$2"; shift 2 ;;
            --boot)               need_value "$1" "${2:-}"; OPT_BOOT="${2,,}"; shift 2 ;;
            --volume-size)        need_value "$1" "${2:-}"; OPT_VOL_SIZE="$2"; shift 2 ;;
            --volume-type)        need_value "$1" "${2:-}"; OPT_VOL_TYPE="$2"; shift 2 ;;
            --delete-volume-on-terminate) OPT_DELETE_VOL=1; shift ;;
            --keep-volume)        OPT_DELETE_VOL=0; shift ;;
            --network)            need_value "$1" "${2:-}"; OPT_NETWORKS+=("$2"); shift 2 ;;
            --security-group)     need_value "$1" "${2:-}"; OPT_SECGROUPS+=("$2"); shift 2 ;;
            --key-name)           need_value "$1" "${2:-}"; OPT_KEY_NAME="$2"; shift 2 ;;
            --public-key)         need_value "$1" "${2:-}"; OPT_PUBKEY="$2"; shift 2 ;;
            --no-key)             OPT_NO_KEY=1; shift ;;
            --username)           need_value "$1" "${2:-}"; OPT_USERNAME="$2"; shift 2 ;;
            --no-password)        OPT_NO_PASSWORD=1; shift ;;
            --host)               need_value "$1" "${2:-}"; OPT_HOST="$2"; shift 2 ;;
            --availability-zone)  need_value "$1" "${2:-}"; OPT_AZ="$2"; shift 2 ;;
            --floating-ip)        need_value "$1" "${2:-}"; OPT_FIP="$2"; shift 2 ;;
            --count)              need_value "$1" "${2:-}"; OPT_COUNT="$2"; shift 2 ;;
            --timeout)            need_value "$1" "${2:-}"; OPT_TIMEOUT="$2"; shift 2 ;;
            --dry-run)            DRY_RUN=1; shift ;;
            *)                    die "Parameter tidak dikenal: $1 (lihat --help)" ;;
        esac
    done

    [[ -z "$OPT_DISTRO" || "$OPT_DISTRO" =~ ^(rhel|centos|ubuntu|debian|cirros)$ ]] || \
        die "--distro harus salah satu: rhel, centos, ubuntu, debian, cirros."
    [[ -z "$OPT_BOOT" || "$OPT_BOOT" =~ ^(volume|image)$ ]] || die "--boot harus volume atau image."
    [[ -z "$OPT_VOL_SIZE" ]] || { is_uint "$OPT_VOL_SIZE" && (( OPT_VOL_SIZE >= 1 )); } || \
        die "--volume-size harus bilangan bulat >= 1 (GB)."
    [[ -z "$OPT_COUNT" ]] || { is_uint "$OPT_COUNT" && (( OPT_COUNT >= 1 && OPT_COUNT <= 50 )); } || \
        die "--count harus bilangan bulat 1-50."
    { is_uint "$OPT_TIMEOUT" && (( OPT_TIMEOUT >= 1 )); } || die "--timeout harus bilangan bulat >= 1 (menit)."
    TIMEOUT_SEC=$(( OPT_TIMEOUT * 60 ))
    if [[ -n "${OSOPS_TIMEOUT_SEC:-}" ]] && is_uint "$OSOPS_TIMEOUT_SEC" && (( OSOPS_TIMEOUT_SEC >= 1 )); then
        TIMEOUT_SEC="$OSOPS_TIMEOUT_SEC"
    fi
    is_uint "$POLL_INTERVAL" && (( POLL_INTERVAL >= 1 )) || POLL_INTERVAL=5
    if (( OPT_NO_KEY )) && [[ -n "$OPT_KEY_NAME$OPT_PUBKEY" ]]; then
        die "--no-key tidak bisa digabung dengan --key-name / --public-key."
    fi
    [[ -n "$OPT_KEY_NAME" && -n "$OPT_PUBKEY" ]] && die "Pilih salah satu: --key-name atau --public-key."
    if [[ -n "$OPT_USERNAME" && ! "$OPT_USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        die "--username tidak valid (huruf kecil, angka, _ atau -, maks. 32 karakter)."
    fi
    if [[ -n "$OPT_NAME" ]] && ! valid_vm_name "$OPT_NAME"; then
        die "--name tidak valid (huruf, angka, titik, _ atau -, maks. 60 karakter)."
    fi
    return 0
}

valid_vm_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,59}$ ]]
}

require_deps() {
    local t
    for t in jq openssl; do
        command -v "$t" >/dev/null 2>&1 || die "$t tidak ditemukan (dibutuhkan untuk JSON / password)."
    done
    command -v "${OS_CMD[0]}" >/dev/null 2>&1 || die "OpenStack CLI tidak ditemukan: ${OS_CMD[0]}"
    openssl passwd -6 -stdin <<< "x" >/dev/null 2>&1 || \
        die "openssl tidak mendukung 'passwd -6' (SHA-512). Perbarui openssl."
}

# Deteksi kemampuan CLI dan microversion cloud
detect_caps() {
    local help vhelp json max
    if json="$(os_cli versions show --service compute -f json 2>/dev/null)"; then
        max="$(jq -r '[ .[] | (."Max Microversion" // .max_microversion // empty) | select(. != null and . != "") ]
                       | sort_by(split(".") | map(tonumber)) | last // empty' <<< "$json" 2>/dev/null)" || max=""
        if [[ "$max" =~ ^[0-9]+\.[0-9]+$ ]]; then
            MV_MAX="$max"
            if ! mv_ge "$max" "$COMPUTE_API_VERSION"; then
                warn "Max compute microversion cloud $max < $COMPUTE_API_VERSION, memakai $max."
                COMPUTE_API_VERSION="$max"
            fi
        fi
    fi
    [[ -n "$MV_MAX" ]] || warn "Max compute microversion cloud tidak bisa dicek, memakai $COMPUTE_API_VERSION."

    help="$(os_cli server create --help 2>/dev/null)" || help=""
    [[ "$help" == *"volume_type="* && "$help" == *"delete_on_termination="* && "$help" == *"--block-device "* ]] \
        && CAP_BDM_FULL=1
    # OSC lama (5.x): salah satu --image/--volume/--snapshot wajib ("(--image ...")
    if [[ "$help" =~ \[--image[[:space:]] ]]; then CAP_DISK_REQUIRED=0; fi
    [[ "$help" == *"--host <host>"* ]] && CAP_HOST_OPT=1
    vhelp="$(os_cli server volume update --help 2>/dev/null)" || vhelp=""
    [[ "$vhelp" == *"--delete-on-termination"* ]] && CAP_VOL_UPDATE=1

    log_event CAPS "compute_api=$COMPUTE_API_VERSION" "mv_max=${MV_MAX:--}" "bdm_full=$CAP_BDM_FULL" \
        "disk_required=$CAP_DISK_REQUIRED" "host_opt=$CAP_HOST_OPT" "vol_update=$CAP_VOL_UPDATE"
    return 0
}

# ============================================================
# 1. Project
# ============================================================

# Isi PROJECT_ID/NAME/DOMAIN dari token aktif
current_project() {
    local json pid pjson did dname
    json="$(os_cli token issue -f json 2>"$WORK_DIR/token.err")" || return 1
    pid="$(jq -r '.project_id // empty' <<< "$json")"
    json=""
    [[ -n "$pid" ]] || return 1
    PROJECT_ID="$pid"
    PROJECT_NAME="" PROJECT_DOMAIN=""
    if pjson="$(os_cli project show "$pid" -f json 2>/dev/null)"; then
        PROJECT_NAME="$(jq -r '.name // empty' <<< "$pjson")"
        did="$(jq -r '.domain_id // empty' <<< "$pjson")"
        dname=""
        [[ -n "$did" ]] && dname="$(os_cli domain show "$did" -c name -f value 2>/dev/null)" || true
        PROJECT_DOMAIN="${dname:-$did}"
    fi
    [[ -n "$PROJECT_NAME" ]] || PROJECT_NAME="${OS_PROJECT_NAME:-$pid}"
    [[ -n "$PROJECT_DOMAIN" ]] || PROJECT_DOMAIN="${OS_PROJECT_DOMAIN_NAME:-${OS_PROJECT_DOMAIN_ID:--}}"
    return 0
}

# Simpan scope awal dari RC (untuk kembali jika project lain gagal diverifikasi)
SAVED_SCOPE=()
save_scope() {
    local v
    SAVED_SCOPE=()
    for v in OS_PROJECT_ID OS_PROJECT_NAME OS_TENANT_ID OS_TENANT_NAME OS_PROJECT_DOMAIN_NAME OS_PROJECT_DOMAIN_ID; do
        [[ -n "${!v+x}" ]] && SAVED_SCOPE+=("$v=${!v}")
    done
    return 0
}

restore_scope() {
    local kv
    unset OS_PROJECT_ID OS_PROJECT_NAME OS_TENANT_ID OS_TENANT_NAME OS_PROJECT_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
    for kv in "${SAVED_SCOPE[@]}"; do
        export "${kv%%=*}=${kv#*=}"
    done
    SCOPE_PROJECT_ID=""
    current_project || true
    log_event SCOPE_RESTORE "project_id=$PROJECT_ID"
}

# Ganti scope ke project ID — hanya di proses ini (environment parent/TUI
# tidak berubah). Variabel yang bisa menimpa scope dibersihkan; os_cli juga
# mengirim --os-project-id (mengalahkan clouds.yaml / OS_CLOUD).
switch_scope() {
    local id="$1"
    export OS_PROJECT_ID="$id"
    unset OS_PROJECT_NAME OS_TENANT_ID OS_TENANT_NAME OS_PROJECT_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
    SCOPE_PROJECT_ID="$id"
    log_event SCOPE_SWITCH "project_id=$id" "os_cloud=${OS_CLOUD:--}"
}

# Verifikasi token: project di token harus sama dengan yang dipilih
verify_scope() {
    local want="$1" err
    if ! current_project; then
        err="$(grep -v '^$' "$WORK_DIR/token.err" 2>/dev/null | tail -n 2 | tr '\n' ' ' | cut -c1-300)"
        warn "Tidak bisa mendapatkan token untuk project $want: ${err:-token issue gagal}"
        echo "   Biasanya user tidak punya role di project tersebut. Tambahkan role dengan"
        echo "   identity/assign-user-to-project.sh (butuh admin), lalu coba lagi."
        log_event SCOPE_VERIFY "project_id=$want" result=FAILED "msg=${err:--}"
        return 1
    fi
    if [[ "$PROJECT_ID" != "$want" ]]; then
        warn "Token tetap ber-scope project $PROJECT_ID, bukan $want."
        log_event SCOPE_VERIFY "project_id=$want" "token_project=$PROJECT_ID" result=FAILED
        return 1
    fi
    log_event SCOPE_VERIFY "project_id=$want" "project=$PROJECT_NAME" "domain=$PROJECT_DOMAIN" result=OK
    return 0
}

# Daftar project: --my-projects; admin juga bisa melihat semua project
# Output: ID<US>Name<US>DomainID per baris
project_rows() {
    local mode="$1" json
    if [[ "$mode" == all ]]; then
        json="$(os_cli project list --long -f json 2>/dev/null)" || return 1
    else
        json="$(os_cli project list --my-projects --long -f json 2>/dev/null)" || \
            json="$(os_cli project list --my-projects -f json 2>/dev/null)" || return 1
    fi
    jq -r '.[] | [.ID, .Name, (."Domain ID" // .domain_id // "-")] | join("\u001f")' <<< "$json" | LC_ALL=C sort -t "$US" -k2,2
}

# Cari project dari --project (nama atau ID, + --project-domain)
resolve_project() {
    local want="$1" dom="$2" mode id name did n=0 found=""
    for mode in my all; do
        while IFS="$US" read -r id name did; do
            [[ "$id" == "$want" || "$name" == "$want" ]] || continue
            [[ -z "$dom" || "$did" == "$dom" ]] || \
                [[ "$(os_cli domain show "$did" -c name -f value 2>/dev/null)" == "$dom" ]] || continue
            [[ " $found " == *" $id "* ]] && continue
            found+="${found:+ }$id"
            n=$(( n + 1 ))
        done < <(project_rows "$mode" 2>/dev/null || true)
        (( n > 0 )) && break
    done
    (( n == 1 )) && { RESOLVED_PROJECT_ID="$found"; return 0; }
    (( n > 1 )) && die "Nama project '$want' ada di beberapa domain. Pakai ID atau --project-domain."
    return 1
}

pick_project() {
    local mode="my" f="$WORK_DIR/projects.lst" id name did
    if project_rows all > /dev/null 2>&1; then
        if ask_yn "Anda admin: tampilkan SEMUA project (bukan hanya project Anda)? [y/N]: " n; then
            mode="all"
            info "Daftar semua project: Anda tetap harus punya role di project tujuan."
        fi
    fi
    : > "$f"
    while IFS="$US" read -r id name did; do
        printf '%s\t%-40s %-34s %s\n' "$id" "$name" "$id" "$did" >> "$f"
    done < <(project_rows "$mode" || true)
    [[ -s "$f" ]] || die "Tidak ada project yang bisa dipilih."
    pick "$f" 0 "📁 project" $'Pilih project tujuan (Esc: batal)\nNAMA                                     ID                                 DOMAIN' || return 1
    PICK_PROJECT_ID="${PICKED[0]}"
}

select_project() {
    local id
    if ! current_project; then
        die "Kredensial tidak valid: token issue gagal ($(tail -n 1 "$WORK_DIR/token.err" 2>/dev/null))."
    fi
    echo "📁 Project aktif    : $PROJECT_NAME ($PROJECT_ID), domain $PROJECT_DOMAIN"

    if [[ -n "$OPT_PROJECT" ]]; then
        resolve_project "$OPT_PROJECT" "$OPT_PROJECT_DOMAIN" || \
            die "Project tidak ditemukan atau tidak bisa diakses: $OPT_PROJECT"
        id="$RESOLVED_PROJECT_ID"
        if [[ "$id" != "$PROJECT_ID" ]]; then
            switch_scope "$id"
            verify_scope "$id" || die "Gagal berpindah ke project $OPT_PROJECT."
        fi
    elif ask_yn "Pakai project lain? [y/N]: " n; then
        save_scope
        while true; do
            if ! pick_project; then
                echo "Tetap di project aktif."
                break
            fi
            id="$PICK_PROJECT_ID"
            [[ "$id" == "$PROJECT_ID" ]] && break
            switch_scope "$id"
            verify_scope "$id" && break
            restore_scope
            echo "Kembali ke project $PROJECT_NAME. Pilih project lain atau Esc untuk tetap."
        done
    fi
    echo "✅ Project tujuan    : $PROJECT_NAME ($PROJECT_ID), domain $PROJECT_DOMAIN"
    log_event INPUT "project=$PROJECT_NAME" "project_id=$PROJECT_ID" "domain=$PROJECT_DOMAIN"
}

# ============================================================
# 2. Image
# ============================================================

# Distro dari os_distro (diutamakan) atau nama; kosong = tidak didukung
detect_distro() {
    local d="${1,,}" n="${2,,}" s
    for s in "$d" "$n"; do
        [[ -n "$s" ]] || continue
        case "$s" in
            *cirros*) echo cirros; return 0 ;;
            *ubuntu*) echo ubuntu; return 0 ;;
            *debian*) echo debian; return 0 ;;
            *centos*) echo centos; return 0 ;;
            *rhel*|*redhat*|*"red hat"*|*red-hat*) echo rhel; return 0 ;;
        esac
    done
    return 0
}

# Normalisasi image dari Glance API atau "image show" => images.json
# shellcheck disable=SC2016
JQ_IMG_NORM='[ .[] | {
    id: (.id // .ID), name: (.name // .Name // ""), status: (.status // .Status // ""),
    os_distro: (.os_distro // (if (.properties | type) == "object" then .properties.os_distro
               elif (.properties | type) == "string" then (.properties | capture("os_distro=.(?<d>[^\u0027,]*)").d? )
               else null end) // ""),
    min_disk: ((.min_disk // 0) | tonumber? // 0), min_ram: ((.min_ram // 0) | tonumber? // 0),
    size: ((.size // 0) | tonumber? // 0), virtual_size: ((.virtual_size // 0) | tonumber? // 0),
    visibility: (.visibility // "-"), created_at: (.created_at // "-") } ]'

fetch_images() {
    local out="$WORK_DIR/images.json" ids="$WORK_DIR/image-ids.txt"
    API_WORK_DIR="$WORK_DIR"
    if api_setup image && api_collect "v2/images" "status=active&limit=200" images "$WORK_DIR/images-raw.json"; then
        jq "$JQ_IMG_NORM" "$WORK_DIR/images-raw.json" > "$out"
        log_event IMAGES method=api "count=$(jq length "$out")"
        return 0
    fi
    info "Glance API tidak dipakai (${API_REASON:-?}); memakai CLI (image show per image, paralel)."
    os_cli image list --status active -f json 2>"$WORK_DIR/image-list.err" | jq -r '.[].ID' > "$ids" || \
        die "image list gagal: $(tail -n 1 "$WORK_DIR/image-list.err")"
    mkdir -p "$WORK_DIR/img"
    export -f os_cli
    export SCOPE_PROJECT_ID COMPUTE_API_VERSION OSOPS_OS_CMD="${OS_CMD[*]}"
    # shellcheck disable=SC2016
    xargs -r -P 8 -I{} bash -c 'read -ra OS_CMD <<< "$OSOPS_OS_CMD"; os_cli image show "$1" -f json > "$2/img/$1.json" 2>/dev/null || rm -f "$2/img/$1.json"' _ {} "$WORK_DIR" < "$ids"
    if compgen -G "$WORK_DIR/img/*.json" > /dev/null; then
        jq -s "$JQ_IMG_NORM" "$WORK_DIR"/img/*.json > "$out"
    else
        echo '[]' > "$out"
    fi
    log_event IMAGES method=cli "count=$(jq length "$out")"
}

# Simpan image terpilih ke IMG_*
use_image() {
    local row="$1"
    IMG_ID="$(jq -r '.id' <<< "$row")"
    IMG_NAME="$(jq -r '.name' <<< "$row")"
    IMG_MIN_DISK="$(jq -r '.min_disk' <<< "$row")"
    IMG_MIN_RAM="$(jq -r '.min_ram' <<< "$row")"
    IMG_SIZE="$(jq -r '.size' <<< "$row")"
    IMG_VSIZE="$(jq -r '.virtual_size' <<< "$row")"
    IMG_DISTRO="$(detect_distro "$(jq -r '.os_distro' <<< "$row")" "$IMG_NAME")"
    if [[ -n "$OPT_DISTRO" ]]; then
        [[ "$OPT_DISTRO" != "$IMG_DISTRO" ]] && info "Distro di-override: ${IMG_DISTRO:-?} → $OPT_DISTRO (--distro)"
        IMG_DISTRO="$OPT_DISTRO"
    fi
    [[ -n "$IMG_DISTRO" ]] || die "Distro image $IMG_NAME tidak dikenali. Pakai --distro."
}

select_image() {
    local f="$WORK_DIR/images.lst" json rows n id
    fetch_images
    # Hanya image active yang nama / os_distro-nya cocok dengan distro didukung
    json="$(jq '[ .[] | select(.status == "active")
        | select(((.name + " " + .os_distro) | ascii_downcase) | test("rhel|redhat|red hat|red-hat|centos|ubuntu|debian|cirros")) ]' \
        "$WORK_DIR/images.json")"

    if [[ -n "$OPT_IMAGE" ]]; then
        rows="$(jq -c --arg w "$OPT_IMAGE" '[ .[] | select(.id == $w or .name == $w) ]' "$WORK_DIR/images.json")"
        n="$(jq length <<< "$rows")"
        (( n == 0 )) && die "Image tidak ditemukan (atau tidak active): $OPT_IMAGE"
        (( n > 1 )) && die "Ada $n image bernama '$OPT_IMAGE'. Pakai ID image."
        use_image "$(jq -c '.[0]' <<< "$rows")"
    else
        n="$(jq length <<< "$json")"
        if (( n == 0 )); then
            echo "${C_YELLOW}Tidak ada image active yang cocok dengan rhel/redhat/centos/ubuntu/debian/cirros (nama atau os_distro).${C_RESET}"
            log_event IMAGES matched=0
            exit 0
        fi
        : > "$f"
        while IFS="$US" read -r id rows; do
            printf '%s\t%s\n' "$id" "$rows" >> "$f"
        done < <(jq -r '.[] | [.id, .name, .os_distro, (.size|tostring), (.min_disk|tostring), .visibility, .created_at] | join("\u001f")' <<< "$json" \
            | while IFS="$US" read -r id name od size md vis created; do
                printf '%s%s%-40s %-8s %8s %5sG  %-10s %s\n' "$id" "$US" "$name" "$(detect_distro "$od" "$name")" \
                    "$(human_bytes "$size")" "$md" "$vis" "${created%%T*}"
            done | LC_ALL=C sort -t "$US" -k2,2)
        pick "$f" 0 "💿 image" $'Pilih image (Esc: batal)\nNAMA                                     DISTRO     UKURAN  MIN_DISK VISIBILITY CREATED' || \
            { echo "Tidak ada image yang dipilih."; exit 0; }
        use_image "$(jq -c --arg i "${PICKED[0]}" '.[] | select(.id == $i)' <<< "$json")"
    fi
    echo "💿 Image            : $IMG_NAME ($IMG_ID), distro $IMG_DISTRO, min_disk ${IMG_MIN_DISK}G, min_ram ${IMG_MIN_RAM}M"
    log_event INPUT "image=$IMG_NAME" "image_id=$IMG_ID" "distro=$IMG_DISTRO" "min_disk=$IMG_MIN_DISK" "min_ram=$IMG_MIN_RAM"
}

# ============================================================
# 3. Flavor
# ============================================================

# flavor_ok RAM DISK — alasan tidak cocok di stdout (kosong = cocok)
flavor_reason() {
    local ram="$1" disk="$2"
    (( ram < IMG_MIN_RAM )) && { printf 'RAM %sM < min_ram image %sM' "$ram" "$IMG_MIN_RAM"; return 0; }
    if [[ "$BOOT" == image ]] && (( disk < IMG_MIN_DISK )); then
        printf 'disk %sG < min_disk image %sG' "$disk" "$IMG_MIN_DISK"
    fi
    return 0
}

select_flavor() {
    local json f="$WORK_DIR/flavors.lst" id name ram disk vcpu reason row hidden=0
    json="$(os_cli flavor list -f json 2>"$WORK_DIR/flavor.err")" || die "flavor list gagal: $(tail -n 1 "$WORK_DIR/flavor.err")"
    if [[ -n "$OPT_FLAVOR" ]]; then
        row="$(jq -c --arg w "$OPT_FLAVOR" '[ .[] | select(.ID == $w or .Name == $w) ][0] // empty' <<< "$json")"
        [[ -n "$row" ]] || die "Flavor tidak ditemukan: $OPT_FLAVOR"
    else
        : > "$f"
        while IFS="$US" read -r id name ram disk vcpu; do
            reason="$(flavor_reason "$ram" "$disk")"
            if [[ -n "$reason" ]]; then hidden=$(( hidden + 1 )); continue; fi
            printf '%s\t%-30s %4s vCPU %8s MB RAM %5s GB disk\n' "$id" "$name" "$vcpu" "$ram" "$disk" >> "$f"
        done < <(jq -r 'sort_by(.VCPUs, .RAM, .Disk) | .[] | [.ID, .Name, (.RAM|tostring), (.Disk|tostring), (.VCPUs|tostring)] | join("\u001f")' <<< "$json")
        (( hidden > 0 )) && info "$hidden flavor disembunyikan karena tidak memenuhi min_ram/min_disk image."
        pick "$f" 0 "🧩 flavor" $'Pilih flavor (Esc: batal)\nNAMA                            vCPU      RAM          DISK' || \
            { echo "Tidak ada flavor yang dipilih."; exit 0; }
        row="$(jq -c --arg i "${PICKED[0]}" '.[] | select(.ID == $i)' <<< "$json")"
    fi
    FLV_ID="$(jq -r '.ID' <<< "$row")"
    FLV_NAME="$(jq -r '.Name' <<< "$row")"
    FLV_RAM="$(jq -r '.RAM' <<< "$row")"
    FLV_DISK="$(jq -r '.Disk' <<< "$row")"
    FLV_VCPU="$(jq -r '.VCPUs' <<< "$row")"
    reason="$(flavor_reason "$FLV_RAM" "$FLV_DISK")"
    [[ -z "$reason" ]] || die "Flavor $FLV_NAME tidak cocok dengan image: $reason."
    if [[ "$BOOT" == image ]] && (( FLV_DISK == 0 )); then
        warn "Flavor $FLV_NAME punya disk 0: boot dari image dengan flavor disk 0 biasanya ditolak Nova (kecuali admin). Pertimbangkan boot dari volume."
    fi
    echo "🧩 Flavor           : $FLV_NAME ($FLV_VCPU vCPU, ${FLV_RAM} MB RAM, ${FLV_DISK} GB disk)"
    log_event INPUT "flavor=$FLV_NAME" "flavor_id=$FLV_ID" "vcpu=$FLV_VCPU" "ram=$FLV_RAM" "disk=$FLV_DISK"
}

# ============================================================
# 4. Boot source dan volume
# ============================================================

select_boot() {
    if [[ -n "$OPT_BOOT" ]]; then
        BOOT="$OPT_BOOT"
    elif ask_yn "Boot dari volume (disarankan)? [Y/n]: " y; then
        BOOT="volume"
    else
        BOOT="image"
    fi
    log_event INPUT "boot=$BOOT"
}

# Ukuran default: max(min_disk, ukuran virtual/ukuran image, 10 GB kecuali cirros)
default_volume_size() {
    local s="$IMG_MIN_DISK" v
    v="$(ceil_gb "$IMG_VSIZE")"
    (( v == 0 )) && v="$(ceil_gb "$IMG_SIZE")"
    (( v > s )) && s="$v"
    [[ "$IMG_DISTRO" != cirros ]] && (( s < 10 )) && s=10
    (( s < 1 )) && s=1
    echo "$s"
}

volume_size_reason() {
    local s="$1" v
    v="$(ceil_gb "$IMG_VSIZE")"
    (( v == 0 )) && v="$(ceil_gb "$IMG_SIZE")"
    (( s < IMG_MIN_DISK )) && { printf '%sG < min_disk image %sG' "$s" "$IMG_MIN_DISK"; return 0; }
    (( s < v )) && printf '%sG < ukuran image %sG' "$s" "$v"
    return 0
}

select_volume_plan() {
    local def input reason json f="$WORK_DIR/vtypes.lst" deftype id name
    [[ "$BOOT" == volume ]] || return 0
    def="$(default_volume_size)"
    if [[ -n "$OPT_VOL_SIZE" ]]; then
        VOL_SIZE="$OPT_VOL_SIZE"
    else
        while true; do
            ask input "Ukuran root volume GB [$def]: "
            input="$(trim "$input")"
            [[ -z "$input" ]] && input="$def"
            if is_uint "$input" && (( input >= 1 )); then
                reason="$(volume_size_reason "$input")"
                [[ -z "$reason" ]] && { VOL_SIZE="$input"; break; }
                echo "${C_RED}❌ Ukuran terlalu kecil: $reason${C_RESET}"
            else
                echo "${C_RED}❌ Masukkan bilangan bulat GB.${C_RESET}"
            fi
        done
    fi
    reason="$(volume_size_reason "$VOL_SIZE")"
    [[ -z "$reason" ]] || die "--volume-size terlalu kecil: $reason."

    deftype="$(os_cli volume type list --default -f json 2>/dev/null | jq -r 'if type == "array" then (.[0].Name // .[0].name // empty) else (.Name // .name // empty) end' 2>/dev/null)" || deftype=""
    DEF_VTYPE="$deftype"
    if [[ -n "$OPT_VOL_TYPE" ]]; then
        VOL_TYPE="$OPT_VOL_TYPE"
        if json="$(os_cli volume type list -f json 2>/dev/null)"; then
            jq -e --arg w "$VOL_TYPE" 'any(.[]; .Name == $w or .ID == $w)' <<< "$json" >/dev/null || \
                die "Volume type tidak ditemukan: $VOL_TYPE"
        fi
    elif json="$(os_cli volume type list -f json 2>/dev/null)" && [[ "$(jq length <<< "$json")" -gt 1 ]]; then
        : > "$f"
        [[ -n "$deftype" ]] && printf '%s\t%s (default Cinder)\n' "__default__" "$deftype" >> "$f"
        [[ -z "$deftype" ]] && printf '%s\t%s\n' "__default__" "(default Cinder)" >> "$f"
        while IFS="$US" read -r id name; do
            [[ "$name" == "$deftype" ]] && continue
            printf '%s\t%s\n' "$name" "$name" >> "$f"
        done < <(jq -r '.[] | [.ID, .Name] | join("\u001f")' <<< "$json")
        if pick "$f" 0 "💾 volume type" $'Pilih volume type (Enter pada baris pertama = default Cinder)'; then
            [[ "${PICKED[0]}" != "__default__" ]] && VOL_TYPE="${PICKED[0]}"
        fi
    fi

    if [[ -n "$OPT_DELETE_VOL" ]]; then
        DELETE_VOL="$OPT_DELETE_VOL"
    elif ask_yn "Hapus root volume saat VM dihapus (delete on terminate)? [Y/n]: " y; then
        DELETE_VOL=1
    else
        DELETE_VOL=0
    fi
    echo "💾 Root volume      : ${VOL_SIZE} GB, type ${VOL_TYPE:-${deftype:-default}}, $( (( DELETE_VOL )) && echo 'DIHAPUS saat VM dihapus' || echo 'TETAP ADA saat VM dihapus')"
    log_event INPUT "volume_size=$VOL_SIZE" "volume_type=${VOL_TYPE:-default}" "delete_on_terminate=$DELETE_VOL"
}

# Jalur pembuatan: A (--block-device) atau B (volume dulu)
decide_boot_path() {
    if [[ "$BOOT" == image ]]; then
        BOOT_PATH="image"
    elif (( CAP_BDM_FULL && ! CAP_DISK_REQUIRED )) && mv_ge "$COMPUTE_API_VERSION" "$MV_BDM_TYPE"; then
        BOOT_PATH="A"
    else
        BOOT_PATH="B"
    fi
    log_event DECISION "boot_path=$BOOT_PATH"
}

# ============================================================
# 5. Network
# ============================================================

select_network() {
    local json subnets f="$WORK_DIR/nets.lst" id name shared ext cidrs w row ok order input i
    local -a picked=() newn=() newi=()
    json="$(os_cli network list --long -f json 2>"$WORK_DIR/net.err")" || die "network list gagal: $(tail -n 1 "$WORK_DIR/net.err")"
    subnets="$(os_cli subnet list -f json 2>/dev/null)" || subnets='[]'
    # Network milik project, shared, atau external
    json="$(jq --arg p "$PROJECT_ID" '[ .[] | select((.Project // "") == $p or (.Shared == true) or ((."Router Type" // "") == "External")) ]' <<< "$json")"
    echo "$json" > "$WORK_DIR/networks.json"

    if (( ${#OPT_NETWORKS[@]} > 0 )); then
        for w in "${OPT_NETWORKS[@]}"; do
            row="$(jq -c --arg w "$w" '[ .[] | select(.ID == $w or .Name == $w) ]' <<< "$json")"
            (( $(jq length <<< "$row") == 1 )) || die "Network tidak ditemukan atau tidak unik: $w (pakai ID)"
            picked+=("$(jq -r '.[0].ID' <<< "$row")")
        done
    else
        : > "$f"
        while IFS="$US" read -r id name shared ext; do
            cidrs="$(jq -r --arg n "$id" '[ .[] | select(.Network == $n) | .Subnet ] | join(",")' <<< "$subnets")"
            printf '%s\t%-28s %-36s %-7s %-9s %s\n' "$id" "$name" "$id" "$( [[ "$shared" == true ]] && echo shared || echo -)" \
                "$( [[ "$ext" == External ]] && echo EXTERNAL || echo -)" "${cidrs:--}" >> "$f"
        done < <(jq -r '.[] | [.ID, .Name, (.Shared|tostring), (."Router Type" // "-")] | join("\u001f")' <<< "$json" | LC_ALL=C sort -t "$US" -k2,2)
        pick "$f" 1 "🌐 network" $'Pilih network (Tab: multi, urutan = urutan NIC; Esc: batal)\nNAMA                         ID                                   SHARED  EXTERNAL  SUBNET' || \
            die "Tidak ada network yang dipilih."
        picked=("${PICKED[@]}")
        if (( ${#picked[@]} > 1 )); then
            echo "Urutan NIC:"
            for i in "${!picked[@]}"; do
                printf '  %d) %s\n' $(( i + 1 )) "$(jq -r --arg i "${picked[$i]}" '.[] | select(.ID == $i) | .Name' <<< "$json")"
            done
            while true; do
                ask input "Ubah urutan? Masukkan nomor sesuai urutan baru (mis. 2 1), Enter = tetap: "
                input="$(trim "$input")"
                [[ -z "$input" ]] && break
                read -ra order <<< "$input"
                ok=1
                (( ${#order[@]} == ${#picked[@]} )) || ok=0
                for i in "${order[@]}"; do
                    { is_uint "$i" && (( i >= 1 && i <= ${#picked[@]} )); } || ok=0
                done
                (( $(printf '%s\n' "${order[@]}" | sort -u | wc -l) == ${#picked[@]} )) || ok=0
                if (( ok )); then
                    newi=()
                    for i in "${order[@]}"; do newi+=("${picked[$(( i - 1 ))]}"); done
                    picked=("${newi[@]}")
                    break
                fi
                echo "${C_RED}❌ Urutan tidak valid.${C_RESET}"
            done
        fi
    fi

    NET_IDS=("${picked[@]}")
    NET_NAMES=()
    for id in "${NET_IDS[@]}"; do
        name="$(jq -r --arg i "$id" '.[] | select(.ID == $i) | .Name' <<< "$json")"
        NET_NAMES+=("$name")
        if [[ "$(jq -r --arg i "$id" '.[] | select(.ID == $i) | (."Router Type" // "")' <<< "$json")" == External ]]; then
            warn "Network $name adalah network EXTERNAL. VM biasanya tidak bisa dipasang langsung ke network external, kecuali network itu shared dan memang dirancang untuk itu. Untuk akses dari luar, pakai floating IP."
        fi
    done
    newn=("${NET_NAMES[@]}")
    echo "🌐 Network          : $(IFS=,; echo "${newn[*]}")"
    log_event INPUT "networks=$(IFS=,; echo "${NET_NAMES[*]}")" "network_ids=$(IFS=,; echo "${NET_IDS[*]}")"
}

# ============================================================
# 6. Security group
# ============================================================

# Ringkasan aturan ingress satu security group (dari rules.json)
sg_ingress_summary() {
    jq -r --arg g "$1" '[ .[] | select((."Security Group" // .security_group_id) == $g)
        | select(((.Direction // .direction // "ingress") | ascii_downcase) == "ingress")
        | "\((."IP Protocol" // .protocol // "any") // "any")/\((."Port Range" // "") | if . == "" then "all" else . end) \((."IP Range" // .remote_ip_prefix // "") | if . == "" or . == null then "" else . end)\(if (."Remote Security Group" // "") != "" and (."Remote Security Group" // null) != null then "sg:" + (."Remote Security Group" | tostring | .[0:8]) else "" end)" ] | join(", ")' \
        "$WORK_DIR/rules.json"
}

# SSH (tcp 22) diizinkan oleh salah satu aturan ingress?
sg_allows_ssh() {
    jq -e --argjson g "$1" '[ .[] | select((."Security Group" // .security_group_id) as $s | $g | index($s))
        | select(((.Direction // .direction // "ingress") | ascii_downcase) == "ingress")
        | select(((."IP Protocol" // .protocol // "any") | tostring | ascii_downcase) as $p | $p == "tcp" or $p == "any" or $p == "null" or $p == "6")
        | (."Port Range" // "") as $r
        | select($r == "" or ($r | split(":") | map(tonumber? // 0) | (.[0] <= 22 and (.[1] // .[0]) >= 22))) ] | length > 0' \
        "$WORK_DIR/rules.json" >/dev/null 2>&1
}

select_secgroup() {
    local json f="$WORK_DIR/sgs.lst" id name w row ids_json
    local -a picked=()
    json="$(os_cli security group list -f json 2>"$WORK_DIR/sg.err")" || die "security group list gagal: $(tail -n 1 "$WORK_DIR/sg.err")"
    json="$(jq --arg p "$PROJECT_ID" '[ .[] | select((.Project // $p) == $p) ]' <<< "$json")"
    os_cli security group rule list --long -f json > "$WORK_DIR/rules.json" 2>/dev/null || echo '[]' > "$WORK_DIR/rules.json"

    if (( ${#OPT_SECGROUPS[@]} > 0 )); then
        for w in "${OPT_SECGROUPS[@]}"; do
            row="$(jq -c --arg w "$w" '[ .[] | select(.ID == $w or .Name == $w) ]' <<< "$json")"
            (( $(jq length <<< "$row") == 1 )) || die "Security group tidak ditemukan atau tidak unik: $w (pakai ID)"
            picked+=("$(jq -r '.[0].ID' <<< "$row")")
        done
    else
        : > "$f"
        # "default" di baris pertama: Enter tanpa Tab memilihnya
        while IFS="$US" read -r id name; do
            printf '%s\t%-24s %s\n' "$id" "$name" "$(sg_ingress_summary "$id" | cut -c1-110)" >> "$f"
        done < <(jq -r 'sort_by(if .Name == "default" then "" else .Name end) | .[] | [.ID, .Name] | join("\u001f")' <<< "$json")
        pick "$f" 1 "🛡️  secgroup" $'Pilih security group (Tab: multi; Enter = baris yang disorot)\nNAMA                     INGRESS (protokol/port sumber)' || \
            die "Tidak ada security group yang dipilih."
        picked=("${PICKED[@]}")
    fi
    SG_IDS=("${picked[@]}")
    SG_NAMES=()
    for id in "${SG_IDS[@]}"; do
        name="$(jq -r --arg i "$id" '.[] | select(.ID == $i) | .Name' <<< "$json")"
        SG_NAMES+=("$name")
        echo "🛡️  $name ingress   : $(sg_ingress_summary "$id" | cut -c1-150)"
    done
    ids_json="$(printf '%s\n' "${SG_IDS[@]}" | jq -R . | jq -s .)"
    if ! sg_allows_ssh "$ids_json"; then
        warn "Tidak ada aturan ingress yang membuka TCP 22 (SSH) di security group terpilih: VM tidak bisa diakses lewat SSH dari luar."
    fi
    log_event INPUT "security_groups=$(IFS=,; echo "${SG_NAMES[*]}")"
}

# ============================================================
# 7. Akses: username, password, key, cloud-init
# ============================================================

default_username() {
    case "$1" in
        debian) echo debian ;;
        ubuntu) echo ubuntu ;;
        rhel|centos) echo cloud-user ;;
        cirros) echo cirros ;;
    esac
}

select_access() {
    if [[ "$IMG_DISTRO" == cirros ]]; then
        USERNAME="cirros"
        USE_PASSWORD=0
        [[ -n "$OPT_USERNAME" ]] && warn "CirrOS tidak memakai cloud-init: --username diabaikan."
        (( OPT_NO_PASSWORD )) && info "CirrOS: --no-password tidak berlaku (password bawaan image)."
    else
        USERNAME="${OPT_USERNAME:-$(default_username "$IMG_DISTRO")}"
        [[ "$IMG_DISTRO" == centos && -z "$OPT_USERNAME" ]] && \
            info "CentOS: username cloud-user. Image CentOS 7 lama memakai 'centos' (pakai --username centos)."
        (( OPT_NO_PASSWORD )) && USE_PASSWORD=0
    fi
    log_event INPUT "username=$USERNAME" "password=$( (( USE_PASSWORD )) && echo generated || echo none)" "cloud_init=$( [[ "$IMG_DISTRO" == cirros ]] && echo no || echo yes)"
}

# Fingerprint MD5 (format nova: aa:bb:...) dari file public key
pubkey_md5() {
    local out
    out="$(ssh-keygen -l -E md5 -f "$1" 2>/dev/null)" || return 1
    out="$(awk '{print $2}' <<< "$out")"
    printf '%s' "${out#MD5:}"
}

validate_pubkey() {
    local f="$1" line
    [[ -f "$f" && -r "$f" ]] || { echo "${C_RED}❌ File tidak ada / tidak bisa dibaca: $f${C_RESET}"; return 1; }
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen tidak ditemukan (dibutuhkan untuk memvalidasi public key)."
    if ! ssh-keygen -l -f "$f" >/dev/null 2>&1; then
        echo "${C_RED}❌ Bukan public key SSH yang valid: $f${C_RESET}"
        return 1
    fi
    line="$(grep -m1 -vE '^[[:space:]]*(#|$)' "$f")"
    if [[ "$line" == *PRIVATE* || "$line" == *"'"* || "$line" == *'"'* ]]; then
        echo "${C_RED}❌ Isi file tidak bisa dipakai sebagai public key: $f${C_RESET}"
        return 1
    fi
    return 0
}

# Pakai file public key: cari keypair dengan fingerprint sama, atau rencanakan keypair baru
use_pubkey_file() {
    local f="$1" kjson existing sha def input
    PUBKEY_FILE="$f"
    PUBKEY_TEXT="$(grep -m1 -vE '^[[:space:]]*(#|$)' "$f")"
    KEY_FP="$(pubkey_md5 "$f")" || die "Fingerprint public key tidak bisa dihitung: $f"
    kjson="$(os_cli keypair list -f json 2>/dev/null)" || kjson='[]'
    existing="$(jq -r --arg fp "$KEY_FP" '[ .[] | select((.Fingerprint // .fingerprint) == $fp) | (.Name // .name) ][0] // empty' <<< "$kjson")"
    if [[ -n "$existing" ]]; then
        KEY_MODE="existing"
        KEY_NAME="$existing"
        echo "🔑 Keypair          : $KEY_NAME (sudah terdaftar, fingerprint sama: $KEY_FP)"
        return 0
    fi
    sha="$(ssh-keygen -l -E sha256 -f "$f" 2>/dev/null | awk '{print $2}' | sed 's/^SHA256://; s/[^A-Za-z0-9]//g' | cut -c1-8)"
    def="$(id -un)-$(hostname -s 2>/dev/null || hostname)-$sha"
    def="${def//[^A-Za-z0-9_.@-]/-}"
    KEY_MODE="create"
    KEY_NAME="$def"
    if [[ -z "$OPT_PUBKEY" ]]; then
        ask input "Nama keypair baru [$def]: "
        input="$(trim "$input")"
        [[ -n "$input" ]] && KEY_NAME="$input"
    fi
    [[ "$KEY_NAME" =~ ^[A-Za-z0-9_.@\ -]{1,255}$ ]] || die "Nama keypair tidak valid: $KEY_NAME"
    jq -e --arg n "$KEY_NAME" 'any(.[]; (.Name // .name) == $n)' <<< "$kjson" >/dev/null && \
        die "Keypair '$KEY_NAME' sudah ada dengan fingerprint berbeda. Pilih nama lain."
    echo "🔑 Keypair          : $KEY_NAME (BARU, dibuat dari $f, fingerprint $KEY_FP)"
}

use_existing_keypair() {
    local name="$1" kjson
    kjson="$(os_cli keypair list -f json 2>/dev/null)" || kjson='[]'
    jq -e --arg n "$name" 'any(.[]; (.Name // .name) == $n)' <<< "$kjson" >/dev/null || \
        die "Keypair tidak ditemukan (keypair milik user, bukan project): $name"
    KEY_MODE="existing"
    KEY_NAME="$name"
    KEY_FP="$(jq -r --arg n "$name" '.[] | select((.Name // .name) == $n) | (.Fingerprint // .fingerprint // "-")' <<< "$kjson")"
    PUBKEY_TEXT="$(os_cli keypair show --public-key "$name" 2>/dev/null | grep -m1 -vE '^[[:space:]]*$')" || PUBKEY_TEXT=""
    [[ -z "$PUBKEY_TEXT" ]] && warn "Public key keypair $name tidak bisa dibaca: hanya dipasang lewat metadata keypair (user default image)."
    echo "🔑 Keypair          : $KEY_NAME (terdaftar, fingerprint $KEY_FP)"
}

select_key() {
    local f="$WORK_DIR/keys.lst" p input kjson
    if (( OPT_NO_KEY )); then
        KEY_MODE="none"
    elif [[ -n "$OPT_KEY_NAME" ]]; then
        use_existing_keypair "$OPT_KEY_NAME"
    elif [[ -n "$OPT_PUBKEY" ]]; then
        validate_pubkey "${OPT_PUBKEY/#\~/$HOME}" || die "--public-key tidak valid."
        use_pubkey_file "${OPT_PUBKEY/#\~/$HOME}"
    else
        : > "$f"
        for p in "$HOME"/.ssh/*.pub; do
            [[ -f "$p" ]] || continue
            ssh-keygen -l -f "$p" >/dev/null 2>&1 || continue
            printf 'file:%s\t%-40s %s\n' "$p" "$p" "$(ssh-keygen -l -E sha256 -f "$p" 2>/dev/null | awk '{print $2, $NF}')" >> "$f"
        done
        printf '%s\t%s\n' "manual" "[path public key lain ...]" >> "$f"
        kjson="$(os_cli keypair list -f json 2>/dev/null)" || kjson='[]'
        jq -r '.[] | "existing:\(.Name // .name)\t[keypair terdaftar] \(.Name // .name)  \(.Fingerprint // .fingerprint // "")"' <<< "$kjson" >> "$f"
        printf '%s\t%s\n' "none" "[tanpa key]" >> "$f"
        pick "$f" 0 "🔑 key" $'Pilih public key / keypair (Esc: batal)' || die "Tidak ada key yang dipilih."
        case "${PICKED[0]}" in
            file:*)     use_pubkey_file "${PICKED[0]#file:}" ;;
            existing:*) use_existing_keypair "${PICKED[0]#existing:}" ;;
            none)       KEY_MODE="none" ;;
            manual)
                while true; do
                    ask input "Path public key: "
                    input="$(trim "$input")"
                    input="${input/#\~/$HOME}"
                    validate_pubkey "$input" && break
                done
                use_pubkey_file "$input"
                ;;
        esac
    fi
    if [[ "$KEY_MODE" == none ]]; then
        echo "🔑 Keypair          : (tanpa key)"
        if (( ! USE_PASSWORD )) && [[ "$IMG_DISTRO" != cirros ]]; then
            die "Tanpa key dan tanpa password VM tidak bisa diakses. Pilih key atau hapus --no-password."
        fi
    fi
    log_event INPUT "keypair=${KEY_NAME:--}" "keypair_mode=$KEY_MODE" "fingerprint=${KEY_FP:--}"
}

# Password acak 20 karakter (A-Z a-z 0-9 tanpa 0 O o 1 l I) dari openssl rand
gen_password() {
    local pw="" chunk
    while (( ${#pw} < 20 )); do
        chunk="$(openssl rand -base64 48 | tr -dc 'A-HJ-NP-Za-km-np-z2-9')" || chunk=""
        pw+="$chunk"
    done
    printf '%s' "${pw:0:20}"
}

# Hash SHA-512 (crypt $6$); password lewat stdin, tidak pernah di argumen proses
hash_password() {
    printf '%s\n' "$1" | openssl passwd -6 -stdin
}

yaml_squote() {
    local s="${1//\'/\'\'}"
    printf "'%s'" "$s"
}

# Template cloud-config (mudah diubah). Argumen: HASH (kosong = tanpa password)
render_cloud_init() {
    local hash="$1"
    cat <<EOF
#cloud-config
# Dibuat oleh OpenStack Ops Toolkit (servers/create-vm.sh)
users:
  - default
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
EOF
    if [[ -n "$hash" ]]; then
        echo "    lock_passwd: false"
        echo "    passwd: $(yaml_squote "$hash")"
    else
        echo "    lock_passwd: true"
    fi
    if [[ -n "$PUBKEY_TEXT" ]]; then
        echo "    ssh_authorized_keys:"
        echo "      - $(yaml_squote "$PUBKEY_TEXT")"
    fi
    if [[ -n "$hash" ]]; then
        echo "ssh_pwauth: true"
    else
        echo "ssh_pwauth: false"
    fi
    cat <<'EOF'
chpasswd:
  expire: false
EOF
}

# Siapkan password + file user-data per VM (file 600 di WORK_DIR)
prepare_userdata() {
    local i hash
    PASSWORDS=()
    for (( i = 0; i < COUNT; i++ )); do
        [[ "$IMG_DISTRO" == cirros ]] && continue
        hash=""
        if (( USE_PASSWORD )); then
            PASSWORDS[i]="$(gen_password)"
            hash="$(hash_password "${PASSWORDS[$i]}")"
            [[ "${hash:0:3}" == "\$6\$" ]] || die "Hash password gagal dibuat (openssl passwd -6)."
        fi
        ( umask 077; render_cloud_init "$hash" > "$WORK_DIR/user-data-$i.yaml" )
        hash=""
    done
    return 0
}

# ============================================================
# 8. Host (opsional)
# ============================================================

select_host() {
    local json f="$WORK_DIR/hosts.lst" h z row
    [[ -n "$OPT_HOST" ]] || ask_yn "Pilih compute host tujuan (admin)? [y/N]: " n || {
        AZ="$OPT_AZ"
        [[ -n "$AZ" ]] && log_event INPUT "availability_zone=$AZ"
        return 0
    }
    if ! json="$(os_cli compute service list --service nova-compute -f json 2>"$WORK_DIR/svc.err")"; then
        if [[ -n "$OPT_HOST" ]]; then
            die "Daftar compute tidak bisa dibaca (butuh role admin): $(tail -n 1 "$WORK_DIR/svc.err")"
        fi
        warn "Daftar compute tidak bisa dibaca (butuh role admin). Host tidak dipilih."
        AZ="$OPT_AZ"
        return 0
    fi
    json="$(jq '[ .[] | select((.Status // .status) == "enabled" and (.State // .state) == "up") ]' <<< "$json")"
    if [[ -n "$OPT_HOST" ]]; then
        row="$(jq -c --arg h "$OPT_HOST" '[ .[] | select(.Host == $h or (.Host | split(".")[0]) == ($h | split(".")[0])) ][0] // empty' <<< "$json")"
        [[ -n "$row" ]] || die "Compute $OPT_HOST tidak ditemukan atau tidak enabled/up."
    else
        : > "$f"
        while IFS="$US" read -r h z; do
            printf '%s\t%-50s %s\n' "$h" "$h" "$z" >> "$f"
        done < <(jq -r 'sort_by(.Host) | .[] | [.Host, .Zone] | join("\u001f")' <<< "$json")
        pick "$f" 0 "🖥️  host" $'Pilih compute (enabled + up)\nHOST                                               ZONE' || {
            AZ="$OPT_AZ"
            return 0
        }
        row="$(jq -c --arg h "${PICKED[0]}" '.[] | select(.Host == $h)' <<< "$json")"
    fi
    HOST="$(jq -r '.Host' <<< "$row")"
    HOST_ZONE="$(jq -r '.Zone' <<< "$row")"
    AZ="${OPT_AZ:-$HOST_ZONE}"
    if [[ -n "$OPT_AZ" && "$OPT_AZ" != "$HOST_ZONE" ]]; then
        die "Host $HOST ada di zone $HOST_ZONE, bukan --availability-zone $OPT_AZ."
    fi
    echo "🖥️  Host            : $HOST (zone $HOST_ZONE, via $( host_via ))"
    log_event INPUT "host=$HOST" "zone=$HOST_ZONE" "host_via=$(host_via)"
}

host_via() {
    if (( CAP_HOST_OPT )) && mv_ge "$COMPUTE_API_VERSION" "$MV_HOST"; then
        echo "--host"
    else
        echo "--availability-zone zone:host"
    fi
}

# ============================================================
# 9. Floating IP (opsional)
# ============================================================

select_fip() {
    local json f="$WORK_DIR/ext.lst" w row id name
    json="$(jq '[ .[] | select((."Router Type" // "") == "External") ]' "$WORK_DIR/networks.json")"
    if [[ -n "$OPT_FIP" ]]; then
        row="$(jq -c --arg w "$OPT_FIP" '[ .[] | select(.ID == $w or .Name == $w) ]' <<< "$json")"
        (( $(jq length <<< "$row") == 1 )) || die "Network external tidak ditemukan / tidak unik: $OPT_FIP"
    else
        (( $(jq length <<< "$json") > 0 )) || return 0
        ask_yn "Alokasikan dan pasang floating IP? [y/N]: " n || return 0
        : > "$f"
        while IFS="$US" read -r id name; do
            printf '%s\t%-30s %s\n' "$id" "$name" "$id" >> "$f"
        done < <(jq -r '.[] | [.ID, .Name] | join("\u001f")' <<< "$json")
        pick "$f" 0 "🌍 network external" $'Pilih network external untuk floating IP' || return 0
        row="$(jq -c --arg i "${PICKED[0]}" '[ .[] | select(.ID == $i) ]' <<< "$json")"
    fi
    FIP_NET_ID="$(jq -r '.[0].ID' <<< "$row")"
    FIP_NET_NAME="$(jq -r '.[0].Name' <<< "$row")"
    echo "🌍 Floating IP      : dari $FIP_NET_NAME"
    log_event INPUT "floating_ip_network=$FIP_NET_NAME"
}

# ============================================================
# 10. Quota
# ============================================================

check_quota() {
    local limits qjson fipq fipu
    local -a lines=()
    local need_inst="$COUNT" need_core=$(( FLV_VCPU * COUNT )) need_ram=$(( FLV_RAM * COUNT ))
    local need_vol=0 need_gb=0 need_fip=0 bad=0
    [[ "$BOOT" == volume ]] && need_vol="$COUNT" need_gb=$(( VOL_SIZE * COUNT ))
    [[ -n "$FIP_NET_ID" ]] && need_fip="$COUNT"

    if ! limits="$(os_cli limits show --absolute -f json 2>"$WORK_DIR/limits.err")"; then
        warn "Quota tidak bisa dicek (limits show gagal: $(tail -n 1 "$WORK_DIR/limits.err")). Lanjut tanpa pre-check quota."
        return 0
    fi
    lim() { jq -r --arg n "$1" '[ .[] | select(.Name == $n) | .Value ][0] // empty' <<< "$limits"; }
    _q() {
        local label="$1" max="$2" used="$3" need="$4" free
        [[ -n "$max" && -n "$used" ]] || return 0
        if (( max < 0 )); then
            lines+=("$(printf '  %-16s butuh %6s, terpakai %6s, limit tak terbatas' "$label" "$need" "$used")")
            return 0
        fi
        free=$(( max - used ))
        lines+=("$(printf '  %-16s butuh %6s, terpakai %6s / %6s, sisa %6s%s' "$label" "$need" "$used" "$max" "$free" \
            "$( (( need > free )) && echo '  ❌ TIDAK CUKUP')")")
        (( need > free )) && bad=1
        return 0
    }
    _q "instance" "$(lim maxTotalInstances)" "$(lim totalInstancesUsed)" "$need_inst"
    _q "vCPU" "$(lim maxTotalCores)" "$(lim totalCoresUsed)" "$need_core"
    _q "RAM (MB)" "$(lim maxTotalRAMSize)" "$(lim totalRAMUsed)" "$need_ram"
    if (( need_vol > 0 )); then
        _q "volume" "$(lim maxTotalVolumes)" "$(lim totalVolumesUsed)" "$need_vol"
        _q "volume GB" "$(lim maxTotalVolumeGigabytes)" "$(lim totalGigabytesUsed)" "$need_gb"
    fi
    if (( need_fip > 0 )); then
        qjson="$(os_cli quota show "$PROJECT_ID" -f json 2>/dev/null)" || qjson='{}'
        fipq="$(jq -r 'if type == "array" then ([ .[] | select((.Resource // .resource) == "floating-ips" or (.Resource // .resource) == "floating_ips" or (.Resource // .resource) == "floatingip") | (.Limit // .limit) ][0] // empty)
                       else (."floating-ips" // .floating_ips // .floatingip // empty) end' <<< "$qjson" 2>/dev/null)" || fipq=""
        fipu="$(os_cli floating ip list --project "$PROJECT_ID" -f json 2>/dev/null | jq length 2>/dev/null)" || fipu=""
        [[ "$fipq" =~ ^-?[0-9]+$ && "$fipu" =~ ^[0-9]+$ ]] && _q "floating IP" "$fipq" "$fipu" "$need_fip"
    fi
    echo
    echo "${C_BOLD}📊 Quota project $PROJECT_NAME:${C_RESET}"
    printf '%s\n' "${lines[@]}"
    log_event QUOTA "instances=$need_inst" "cores=$need_core" "ram=$need_ram" "volumes=$need_vol" \
        "gigabytes=$need_gb" "floating_ips=$need_fip" "ok=$(( ! bad ))"
    if (( bad )); then
        die "Quota tidak cukup untuk $COUNT VM (lihat rincian di atas). Dibatalkan."
    fi
    info "Quota per volume type (gigabytes_<type>) tidak dicek."
}

# ============================================================
# 11. Ringkasan dan konfirmasi
# ============================================================

ask_name_count() {
    local input
    if [[ -n "$OPT_NAME" ]]; then
        VM_NAME="$OPT_NAME"
    else
        while true; do
            ask input "Nama VM: "
            input="$(trim "$input")"
            valid_vm_name "$input" && { VM_NAME="$input"; break; }
            echo "${C_RED}❌ Nama tidak valid (huruf, angka, titik, _ atau -, maks. 60 karakter).${C_RESET}"
        done
    fi
    COUNT="${OPT_COUNT:-1}"
    local i
    R_NAME=()
    for (( i = 0; i < COUNT; i++ )); do
        if (( COUNT == 1 )); then R_NAME+=("$VM_NAME"); else R_NAME+=("$VM_NAME-$(( i + 1 ))"); fi
    done
    log_event INPUT "name=$VM_NAME" "count=$COUNT"
}

show_summary() {
    local auth="${OS_AUTH_URL:-}"
    auth="${auth#*://}"
    auth="${auth%%/*}"
    echo
    echo "${C_BOLD}═══════════════ Ringkasan ═══════════════${C_RESET}"
    printf '  %-18s %s\n' "Region" "${OS_REGION_NAME:--} (auth ${auth:-${OS_CLOUD:+clouds.yaml: $OS_CLOUD}})"
    printf '  %-18s %s\n' "Project" "$PROJECT_NAME ($PROJECT_ID), domain $PROJECT_DOMAIN"
    printf '  %-18s %s\n' "Nama VM" "$(IFS=,; echo "${R_NAME[*]}")"
    printf '  %-18s %s\n' "Jumlah" "$COUNT"
    printf '  %-18s %s\n' "Image" "$IMG_NAME ($IMG_ID), distro $IMG_DISTRO"
    printf '  %-18s %s\n' "Flavor" "$FLV_NAME ($FLV_VCPU vCPU, $FLV_RAM MB, $FLV_DISK GB)"
    if [[ "$BOOT" == volume ]]; then
        printf '  %-18s %s\n' "Boot" "VOLUME ${VOL_SIZE} GB, type ${VOL_TYPE:-default${DEF_VTYPE:+ ($DEF_VTYPE)}}, nama <vm>-root (jalur $BOOT_PATH)"
        printf '  %-18s %s\n' "Delete on terminate" "$( (( DELETE_VOL )) && echo 'YA — volume DIHAPUS saat VM dihapus' || echo 'TIDAK — volume TETAP ADA saat VM dihapus')"
        if [[ "$BOOT_PATH" == B ]] && (( DELETE_VOL )) && { (( ! CAP_VOL_UPDATE )) || ! mv_ge "$COMPUTE_API_VERSION" "$MV_VOL_UPDATE"; }; then
            printf '  %-18s %s\n' "" "${C_YELLOW}⚠️  CLI/cloud tidak mendukung pengaturan delete on terminate: volume TIDAK akan terhapus otomatis${C_RESET}"
        fi
    else
        printf '  %-18s %s\n' "Boot" "IMAGE (disk lokal flavor)"
    fi
    printf '  %-18s %s\n' "Network" "$(IFS=,; echo "${NET_NAMES[*]}")"
    printf '  %-18s %s\n' "Security group" "$(IFS=,; echo "${SG_NAMES[*]}")"
    printf '  %-18s %s\n' "Keypair" "$( case "$KEY_MODE" in none) echo '(tanpa)';; create) echo "$KEY_NAME (BARU, $KEY_FP)";; *) echo "$KEY_NAME ($KEY_FP)";; esac)"
    if [[ "$IMG_DISTRO" == cirros ]]; then
        printf '  %-18s %s\n' "Login" "cirros, kredensial bawaan image (tanpa cloud-init)"
    else
        printf '  %-18s %s\n' "Username" "$USERNAME"
        printf '  %-18s %s\n' "Login" "$( (( USE_PASSWORD )) && echo 'password acak per VM' )$( (( USE_PASSWORD )) && [[ "$KEY_MODE" != none ]] && echo ' + ' )$( [[ "$KEY_MODE" != none ]] && echo 'key')"
    fi
    printf '  %-18s %s\n' "Host" "${HOST:--}${HOST:+ (via $(host_via))}"
    printf '  %-18s %s\n' "Availability zone" "${AZ:--}"
    printf '  %-18s %s\n' "Floating IP" "${FIP_NET_NAME:--}"
    printf '  %-18s %s\n' "Compute API" "$COMPUTE_API_VERSION (maks. cloud ${MV_MAX:-?})"
}

# ============================================================
# 12. Create dan tunggu
# ============================================================

# Argumen server create bersama
server_args() {
    local i="$1" n s
    SARGS=(server create --flavor "$FLV_ID")
    for n in "${NET_IDS[@]}"; do SARGS+=(--network "$n"); done
    for s in "${SG_IDS[@]}"; do SARGS+=(--security-group "$s"); done
    [[ "$KEY_MODE" != none ]] && SARGS+=(--key-name "$KEY_NAME")
    [[ "$IMG_DISTRO" != cirros ]] && SARGS+=(--user-data "$WORK_DIR/user-data-$i.yaml")
    if [[ -n "$HOST" ]]; then
        if [[ "$(host_via)" == "--host" ]]; then
            SARGS+=(--host "$HOST")
            [[ -n "$AZ" ]] && SARGS+=(--availability-zone "$AZ")
        else
            SARGS+=(--availability-zone "$AZ:$HOST")
        fi
    elif [[ -n "$AZ" ]]; then
        SARGS+=(--availability-zone "$AZ")
    fi
    case "$BOOT_PATH" in
        image) SARGS+=(--image "$IMG_ID") ;;
        A)
            local bdm="uuid=$IMG_ID,source_type=image,destination_type=volume,boot_index=0,volume_size=$VOL_SIZE"
            bdm+=",delete_on_termination=$( (( DELETE_VOL )) && echo true || echo false)"
            [[ -n "$VOL_TYPE" ]] && bdm+=",volume_type=$VOL_TYPE"
            SARGS+=(--block-device "$bdm")
            ;;
        B) SARGS+=(--volume "${R_VOLUME[$i]:-<volume-id>}") ;;
    esac
    SARGS+=(-f json "${R_NAME[$i]}")
}

# Tunggu volume available. Return 0 ok, 1 error, 2 timeout
wait_volume() {
    local vid="$1" t0 now st json
    t0="$(date +%s)"
    while true; do
        json="$(os_cli volume show "$vid" -f json 2>/dev/null)" || json='{}'
        st="$(jq -r '.status // "?"' <<< "$json")"
        now="$(date +%s)"
        printf '\r  ⏳ volume %s: %-12s %s ' "${vid:0:8}" "$st" "$(fmt_elapsed $(( now - t0 )))"
        case "$st" in
            available) echo; return 0 ;;
            error*) echo; return 1 ;;
        esac
        if (( now - t0 >= TIMEOUT_SEC )); then echo; return 2; fi
        sleep "$POLL_INTERVAL"
    done
}

create_keypair() {
    [[ "$KEY_MODE" == create ]] || return 0
    if os_run keypair create --public-key "$PUBKEY_FILE" "$KEY_NAME" > /dev/null; then
        KEYPAIR_CREATED="$KEY_NAME"
        log_event CREATED kind=keypair "id=$KEY_NAME" "fingerprint=$KEY_FP"
        log_result "resource=$KEY_NAME" action=create-keypair result=SUCCESS "fingerprint=$KEY_FP"
        echo "${C_GREEN}✅ Keypair $KEY_NAME dibuat.${C_RESET}"
    else
        log_result "resource=$KEY_NAME" action=create-keypair result=FAILED "msg=$LOG_LAST_ERROR"
        die "Keypair gagal dibuat: $LOG_LAST_ERROR"
    fi
}

create_volume() {
    local i="$1" name="${R_NAME[$1]}-root" vid rc
    local -a args=(volume create --image "$IMG_ID" --size "$VOL_SIZE" --bootable)
    [[ -n "$VOL_TYPE" ]] && args+=(--type "$VOL_TYPE")
    args+=(-f json "$name")
    if ! os_run "${args[@]}" > "$WORK_DIR/out.json"; then
        log_result "resource=$name" action=create-volume result=FAILED "msg=$LOG_LAST_ERROR"
        R_RESULT[i]="FAILED" R_MSG[i]="volume create gagal: $LOG_LAST_ERROR"
        return 1
    fi
    vid="$(jq -r '.id // empty' "$WORK_DIR/out.json")"
    R_VOLUME[i]="$vid"
    log_event CREATED kind=volume "id=$vid" "name=$name" "project=$PROJECT_ID"
    echo "  💾 volume $name ($vid) dibuat, menunggu available..."
    rc=0
    wait_volume "$vid" || rc=$?
    if (( rc == 0 )); then
        log_result "resource=$vid" action=create-volume result=SUCCESS "name=$name" "size=$VOL_SIZE" \
            "type=${VOL_TYPE:-default}" "image=$IMG_ID"
        return 0
    fi
    local why="status error"
    (( rc == 2 )) && why="timeout ${TIMEOUT_SEC}s"
    log_result "resource=$vid" action=create-volume result=FAILED "name=$name" "msg=$why"
    R_RESULT[i]="FAILED" R_MSG[i]="volume $vid tidak available ($why)"
    return 1
}

# Tunggu VM ACTIVE. Return 0 ACTIVE, 1 ERROR, 2 timeout
wait_server() {
    local i="$1" sid="${R_SERVER[$1]}" t0 now st task json
    t0="$(date +%s)"
    while true; do
        json="$(os_cli server show "$sid" -f json 2>/dev/null)" || json='{}'
        st="$(jq -r '.status // "?"' <<< "$json")"
        task="$(jq -r '."OS-EXT-STS:task_state" // "-" | if . == null or . == "" then "-" else . end' <<< "$json")"
        now="$(date +%s)"
        printf '\r  ⏳ %s: %-8s task=%-22s %s ' "${R_NAME[$i]}" "$st" "$task" "$(fmt_elapsed $(( now - t0 )))"
        R_STATUS[i]="$st"
        case "$st" in
            ACTIVE) echo; echo "$json" > "$WORK_DIR/server-$i.json"; return 0 ;;
            ERROR)
                echo
                echo "$json" > "$WORK_DIR/server-$i.json"
                R_MSG[i]="$(jq -r 'if (.fault | type) == "object" then (.fault.message // "-") else (.fault // "-") end' <<< "$json" | tr '\n' ' ' | cut -c1-300)"
                return 1
                ;;
        esac
        if (( now - t0 >= TIMEOUT_SEC )); then echo; return 2; fi
        sleep "$POLL_INTERVAL"
    done
}

# ID volume root dari server show (format dict atau string lama)
server_volume_ids() {
    jq -r '(.volumes_attached // []) | if type == "array" then .[] | (.id // empty)
           else (tostring | [ scan("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") ] | .[]) end' "$1" 2>/dev/null
}

# Pasca ACTIVE: nama volume (jalur A), delete on terminate (jalur B)
post_active_volume() {
    local i="$1" vid
    if [[ "$BOOT_PATH" == A ]]; then
        vid="$(server_volume_ids "$WORK_DIR/server-$i.json" | head -n 1)"
        if [[ -n "$vid" ]]; then
            R_VOLUME[i]="$vid"
            log_event CREATED kind=volume "id=$vid" "name=${R_NAME[$i]}-root" "project=$PROJECT_ID" via=block-device
            if os_run volume set --name "${R_NAME[$i]}-root" "$vid" > /dev/null; then
                log_result "resource=$vid" action=create-volume result=SUCCESS "name=${R_NAME[$i]}-root" "size=$VOL_SIZE" \
                    "type=${VOL_TYPE:-default}" "via=block-device" "delete_on_terminate=$DELETE_VOL"
            else
                log_result "resource=$vid" action=create-volume result=SUCCESS "via=block-device" "msg=rename failed: $LOG_LAST_ERROR"
            fi
        fi
    elif [[ "$BOOT_PATH" == B ]] && (( DELETE_VOL )); then
        if (( CAP_VOL_UPDATE )) && mv_ge "$COMPUTE_API_VERSION" "$MV_VOL_UPDATE" \
           && os_run server volume update --delete-on-termination "${R_SERVER[$i]}" "${R_VOLUME[$i]}" > /dev/null; then
            log_event VOLUME_DOT "server=${R_SERVER[$i]}" "volume=${R_VOLUME[$i]}" delete_on_termination=true result=SUCCESS
        else
            R_DELWARN[i]=1
            warn "Delete on terminate TIDAK bisa diatur untuk ${R_NAME[$i]}: volume ${R_VOLUME[$i]} TIDAK akan terhapus otomatis saat VM dihapus (${LOG_LAST_ERROR:-CLI/microversion tidak mendukung})."
            log_event VOLUME_DOT "server=${R_SERVER[$i]}" "volume=${R_VOLUME[$i]}" delete_on_termination=false \
                result=FAILED "msg=volume will NOT be deleted with the server: ${LOG_LAST_ERROR:-unsupported}"
        fi
    fi
    return 0
}

attach_fip() {
    local i="$1" ip fid
    [[ -n "$FIP_NET_ID" ]] || return 0
    if ! os_run floating ip create -f json "$FIP_NET_ID" > "$WORK_DIR/out.json"; then
        log_result "resource=${R_SERVER[$i]}" action=add-floating-ip result=FAILED "msg=create: $LOG_LAST_ERROR"
        warn "Floating IP gagal dialokasikan: $LOG_LAST_ERROR"
        return 0
    fi
    ip="$(jq -r '.floating_ip_address // empty' "$WORK_DIR/out.json")"
    fid="$(jq -r '.id // empty' "$WORK_DIR/out.json")"
    R_FIP_ID[i]="$fid"
    log_event CREATED kind=floating-ip "id=$fid" "ip=$ip" "project=$PROJECT_ID"
    if os_run server add floating ip "${R_SERVER[$i]}" "$ip" > /dev/null; then
        R_FIP[i]="$ip"
        log_result "resource=${R_SERVER[$i]}" action=add-floating-ip result=SUCCESS "ip=$ip" "floating_ip_id=$fid"
    else
        log_result "resource=${R_SERVER[$i]}" action=add-floating-ip result=FAILED "ip=$ip" "msg=$LOG_LAST_ERROR"
        warn "Floating IP $ip gagal dipasang: $LOG_LAST_ERROR (floating IP tetap teralokasi: $fid)"
    fi
}

# Hapus resource satu jenis dan tunggu hilang (hanya "not found" = SUCCESS)
cleanup_one() {
    local kind="$1" id="$2" t0 out
    [[ -n "$id" ]] || return 0
    case "$kind" in
        server) os_run server delete "$id" > /dev/null || { log_result "resource=$id" action=cleanup kind=server result=FAILED "msg=$LOG_LAST_ERROR"; return 1; } ;;
        volume) os_run volume delete "$id" > /dev/null || { log_result "resource=$id" action=cleanup kind=volume result=FAILED "msg=$LOG_LAST_ERROR"; return 1; } ;;
        fip)    os_run floating ip delete "$id" > /dev/null || { log_result "resource=$id" action=cleanup kind=floating-ip result=FAILED "msg=$LOG_LAST_ERROR"; return 1; }
                log_result "resource=$id" action=cleanup kind=floating-ip result=SUCCESS; return 0 ;;
    esac
    t0="$(date +%s)"
    while true; do
        if ! out="$(os_cli "$kind" show "$id" -f json 2>&1)"; then
            if [[ "$out" == *"with a name or ID of"*"exists"* || "$out" == *"could not be found"* \
                  || "$out" == *"No "*" found"* || "$out" == *"(HTTP 404)"* ]]; then
                log_result "resource=$id" action=cleanup "kind=$kind" result=SUCCESS
                return 0
            fi
        elif [[ "$(jq -r '.status // ""' <<< "$out" 2>/dev/null)" == error_deleting ]]; then
            log_result "resource=$id" action=cleanup "kind=$kind" result=FAILED msg=error_deleting
            return 1
        fi
        if (( $(date +%s) - t0 >= TIMEOUT_SEC )); then
            log_result "resource=$id" action=cleanup "kind=$kind" result=FAILED msg=timeout
            return 1
        fi
        sleep "$POLL_INTERVAL"
    done
}

# Tawarkan hapus resource yang dibuat script untuk VM i
offer_cleanup() {
    local i="$1" what=""
    [[ -n "${R_SERVER[$i]:-}" ]] && what+=" VM ${R_SERVER[$i]}"
    # Volume yang tidak ikut terhapus bersama VM
    if [[ -n "${R_VOLUME[$i]:-}" ]] && { [[ "$BOOT_PATH" == B ]] || (( ! DELETE_VOL )); }; then
        what+=" volume ${R_VOLUME[$i]}"
    fi
    [[ -n "${R_FIP_ID[$i]:-}" ]] && what+=" floating-ip ${R_FIP_ID[$i]}"
    [[ -n "$what" ]] || return 0
    if ! ask_yn "Hapus resource yang dibuat script untuk ${R_NAME[$i]}:$what ? [y/N]: " n; then
        log_event DECISION "vm=${R_NAME[$i]}" cleanup=declined
        log_result "resource=${R_NAME[$i]}" action=cleanup result=DECLINED "resources=${what# }"
        return 0
    fi
    log_event DECISION "vm=${R_NAME[$i]}" cleanup=accepted
    [[ -n "${R_FIP_ID[$i]:-}" ]] && cleanup_one fip "${R_FIP_ID[$i]}" || true
    if [[ -n "${R_SERVER[$i]:-}" ]]; then
        if cleanup_one server "${R_SERVER[$i]}"; then echo "  🗑️  VM ${R_SERVER[$i]} dihapus."; else warn "VM ${R_SERVER[$i]} gagal dihapus."; fi
    fi
    if [[ "$what" == *"volume ${R_VOLUME[$i]:-x}"* ]]; then
        if cleanup_one volume "${R_VOLUME[$i]}"; then echo "  🗑️  Volume ${R_VOLUME[$i]} dihapus."; else warn "Volume ${R_VOLUME[$i]} gagal dihapus."; fi
    fi
    return 0
}

create_server() {
    local i="$1" rc
    R_RESULT[i]="" R_MSG[i]="" R_SERVER[i]="" R_STATUS[i]="-" R_DELWARN[i]=0
    echo
    echo "${C_BOLD}▶ ${R_NAME[$i]} ($(( i + 1 ))/$COUNT)${C_RESET}"
    if [[ "$BOOT_PATH" == B ]]; then
        if ! create_volume "$i"; then
            warn "${R_MSG[$i]}"
            [[ -n "${R_VOLUME[$i]:-}" ]] && offer_cleanup "$i"
            return 0
        fi
    fi
    server_args "$i"
    if ! os_run "${SARGS[@]}" > "$WORK_DIR/out.json"; then
        R_RESULT[i]="FAILED" R_MSG[i]="server create gagal: $LOG_LAST_ERROR"
        log_result "resource=${R_NAME[$i]}" action=create-server result=FAILED "msg=$LOG_LAST_ERROR"
        if [[ "$LOG_LAST_ERROR" == *"Forbidden"* || "$LOG_LAST_ERROR" == *"403"* || "$LOG_LAST_ERROR" == *"policy"* ]] && [[ -n "$HOST" ]]; then
            warn "Penempatan ke host tertentu butuh role admin."
        fi
        warn "${R_MSG[$i]}"
        offer_cleanup "$i"
        return 0
    fi
    # Output server create bisa berisi adminPass: hanya ID yang diambil, file dikosongkan
    R_SERVER[i]="$(jq -r '.id // empty' "$WORK_DIR/out.json")"
    : > "$WORK_DIR/out.json"
    log_event CREATED kind=server "id=${R_SERVER[$i]}" "name=${R_NAME[$i]}" "project=$PROJECT_ID"
    echo "  🖥️  server ${R_SERVER[$i]} dibuat, menunggu ACTIVE..."
    rc=0
    wait_server "$i" || rc=$?
    case "$rc" in
        0)
            R_RESULT[i]="SUCCESS"
            post_active_volume "$i"
            attach_fip "$i"
            os_cli server show "${R_SERVER[$i]}" -f json > "$WORK_DIR/server-$i.json" 2>/dev/null || true
            log_result "resource=${R_SERVER[$i]}" action=create-server result=SUCCESS "name=${R_NAME[$i]}" \
                "image=$IMG_ID" "flavor=$FLV_NAME" "boot=$BOOT" "boot_path=$BOOT_PATH" "volume=${R_VOLUME[$i]:--}" \
                "host=${HOST:--}" "keypair=${KEY_NAME:--}"
            ;;
        1)
            R_RESULT[i]="FAILED"
            # Jalur A: root volume dibuat Nova (jika sempat) — ID dari server show
            if [[ "$BOOT_PATH" == A && -z "${R_VOLUME[$i]:-}" ]]; then
                R_VOLUME[i]="$(server_volume_ids "$WORK_DIR/server-$i.json" | head -n 1)"
            fi
            echo "${C_RED}❌ ${R_NAME[$i]} ERROR: ${R_MSG[$i]}${C_RESET}"
            log_result "resource=${R_SERVER[$i]}" action=create-server result=FAILED "name=${R_NAME[$i]}" "msg=fault: ${R_MSG[$i]}"
            offer_cleanup "$i"
            ;;
        2)
            R_RESULT[i]="FAILED"
            R_MSG[i]="timeout ${TIMEOUT_SEC}s (status terakhir ${R_STATUS[$i]}); resource TIDAK dihapus"
            warn "${R_NAME[$i]}: ${R_MSG[$i]}. Server ${R_SERVER[$i]}${R_VOLUME[$i]:+, volume ${R_VOLUME[$i]}}."
            log_result "resource=${R_SERVER[$i]}" action=create-server result=FAILED "name=${R_NAME[$i]}" "msg=${R_MSG[$i]}" \
                "volume=${R_VOLUME[$i]:--}"
            ;;
    esac
    return 0
}

# ============================================================
# 13. Ringkasan akhir
# ============================================================

server_addresses() {
    jq -r '(.addresses // {}) | if type == "object" then (to_entries | map("\(.key)=\([ .value[] | (if type == "object" then .addr else . end) ] | join(","))") | join("; "))
           else tostring end' "$1" 2>/dev/null
}

final_summary() {
    local i ip creds="" save
    echo
    echo "${C_BOLD}═══════════════ Hasil ═══════════════${C_RESET}"
    for (( i = 0; i < COUNT; i++ )); do
        echo "${C_BOLD}${R_NAME[$i]}${C_RESET}  $( [[ "${R_RESULT[$i]:-}" == SUCCESS ]] && echo "${C_GREEN}SUCCESS${C_RESET}" || echo "${C_RED}${R_RESULT[$i]:-SKIPPED}${C_RESET}")"
        printf '  %-14s %s\n' "ID" "${R_SERVER[$i]:--}" "Status" "${R_STATUS[$i]:--}"
        [[ -n "${R_MSG[$i]:-}" ]] && printf '  %-14s %s\n' "Pesan" "${R_MSG[$i]}"
        [[ "${R_RESULT[$i]:-}" == SUCCESS ]] || continue
        [[ -f "$WORK_DIR/server-$i.json" ]] && {
            R_HOST[i]="$(jq -r '."OS-EXT-SRV-ATTR:host" // empty' "$WORK_DIR/server-$i.json" 2>/dev/null)"
            R_ADDR[i]="$(server_addresses "$WORK_DIR/server-$i.json")"
        }
        [[ -n "${R_HOST[$i]:-}" ]] && printf '  %-14s %s\n' "Host" "${R_HOST[$i]}"
        printf '  %-14s %s\n' "IP" "${R_ADDR[$i]:--}"
        [[ -n "${R_FIP[$i]:-}" ]] && printf '  %-14s %s\n' "Floating IP" "${R_FIP[$i]}"
        [[ -n "${R_VOLUME[$i]:-}" ]] && printf '  %-14s %s\n' "Root volume" "${R_VOLUME[$i]} ($( (( DELETE_VOL && ! ${R_DELWARN[$i]:-0} )) && echo 'dihapus bersama VM' || echo 'TIDAK dihapus otomatis saat VM dihapus'))"
        printf '  %-14s %s\n' "Keypair" "${KEY_NAME:--}"
        ip="${R_FIP[$i]:-$(grep -oE '[0-9]+(\.[0-9]+){3}' <<< "${R_ADDR[$i]:-}" | head -n 1)}"
        if [[ "$IMG_DISTRO" == cirros ]]; then
            printf '  %-14s %s\n' "Username" "cirros"
            printf '  %-14s %s\n' "Password" "gocubsgo (bawaan image CirrOS >= 0.4; versi lama: cubswin:))"
        else
            printf '  %-14s %s\n' "Username" "$USERNAME"
            if (( USE_PASSWORD )) && [[ -n "${PASSWORDS[$i]:-}" ]]; then
                printf '  %-14s %s\n' "Password" "${C_BOLD}${PASSWORDS[$i]}${C_RESET}"
                creds+="${R_NAME[$i]} ${R_SERVER[$i]} user=$USERNAME password=${PASSWORDS[$i]} ip=${ip:--}"$'\n'
            fi
        fi
        printf '  %-14s %s\n' "SSH" "ssh $( [[ -n "$PUBKEY_FILE" ]] && echo "-i ${PUBKEY_FILE%.pub} ")${USERNAME}@${ip:-<ip>}"
    done
    if [[ -n "$creds" ]]; then
        echo
        echo "${C_YELLOW}${C_BOLD}⚠️  Simpan password sekarang: password tidak disimpan di mana pun dan TIDAK bisa ditampilkan ulang.${C_RESET}"
        if ask_yn "Simpan kredensial ke file $CREDS_DIR/vm-credentials-<waktu>.txt (permission 600, BERISI PASSWORD)? [y/N]: " n; then
            save="$CREDS_DIR/vm-credentials-$(date +%Y%m%d-%H%M%S).txt"
            if ( umask 077; set -o noclobber; printf '%s' "$creds" > "$save" ) 2>/dev/null; then
                echo "${C_GREEN}💾 Kredensial disimpan: $save (600). Hapus setelah dipindahkan ke tempat aman.${C_RESET}"
                log_event CREDENTIALS_SAVED "file=$save" "vms=$COUNT"
            else
                warn "Gagal menyimpan kredensial ke $save (file sudah ada atau tidak bisa ditulis)."
            fi
        else
            log_event DECISION credentials_file=no
        fi
    fi
    creds=""
}

# ============================================================
# Dry-run
# ============================================================

show_dry_run() {
    local i a q line
    echo
    echo "${C_CYAN}${C_BOLD}DRY-RUN: tidak ada keypair, volume, VM, atau floating IP yang dibuat.${C_RESET}"
    echo "Perintah yang akan dijalankan:"
    if [[ "$KEY_MODE" == create ]]; then
        echo "  openstack keypair create --public-key $PUBKEY_FILE $KEY_NAME"
        log_info "dry_run=true action=create-keypair resource=$KEY_NAME"
    fi
    for (( i = 0; i < COUNT; i++ )); do
        if [[ "$BOOT_PATH" == B ]]; then
            echo "  openstack volume create --image $IMG_ID --size $VOL_SIZE --bootable${VOL_TYPE:+ --type $VOL_TYPE} ${R_NAME[$i]}-root"
            log_info "dry_run=true action=create-volume resource=${R_NAME[$i]}-root size=$VOL_SIZE"
        fi
        server_args "$i"
        line="  openstack --os-compute-api-version $COMPUTE_API_VERSION${SCOPE_PROJECT_ID:+ --os-project-id $SCOPE_PROJECT_ID}"
        for a in "${SARGS[@]}"; do
            if [[ "$a" =~ ^[A-Za-z0-9_./:=,@+-]+$ ]]; then q="$a"; else printf -v q '%q' "$a"; fi
            line+=" $q"
        done
        echo "$line"
        log_info "dry_run=true action=create-server resource=${R_NAME[$i]} boot_path=$BOOT_PATH"
        if [[ "$BOOT_PATH" == B ]] && (( DELETE_VOL )); then
            echo "  openstack server volume update --delete-on-termination <server-id> <volume-id>   (setelah ACTIVE)"
        fi
        [[ -n "$FIP_NET_ID" ]] && echo "  openstack floating ip create $FIP_NET_ID ; openstack server add floating ip <server-id> <ip>"
    done
    if [[ "$IMG_DISTRO" != cirros ]]; then
        echo
        echo "cloud-init (user-data VM pertama; hash password disamarkan):"
        sed -E "s/^(    passwd: ').*(')\$/\1\$6\$********\2/" "$WORK_DIR/user-data-0.yaml" | sed 's/^/  │ /'
    fi
    log_info "SUMMARY dry_run=true vms=$COUNT boot_path=$BOOT_PATH project=$PROJECT_ID"
}

# ============================================================
# Hook library
# ============================================================

# shellcheck disable=SC2329  # dipanggil lewat LOG_INTERRUPT_HOOK
on_interrupt() {
    local i ids=""
    echo
    for (( i = 0; i < ${#R_NAME[@]}; i++ )); do
        [[ -n "${R_SERVER[$i]:-}" ]] && ids+=" server ${R_SERVER[$i]}"
        [[ -n "${R_VOLUME[$i]:-}" ]] && ids+=" volume ${R_VOLUME[$i]}"
        [[ -n "${R_FIP_ID[$i]:-}" ]] && ids+=" floating-ip ${R_FIP_ID[$i]}"
    done
    [[ -n "$KEYPAIR_CREATED" ]] && ids+=" keypair $KEYPAIR_CREATED"
    warn "Dihentikan (${1:-INT}). Resource yang sudah dibuat TIDAK dihapus otomatis:${ids:- (tidak ada)}"
    log_result "resource=${VM_NAME:--}" action=create-server result=ABORTED "msg=interrupted; created:${ids:- none}"
}

# shellcheck disable=SC2329  # dipanggil lewat LOG_EXIT_HOOK
on_exit() {
    set +o errexit
    PASSWORDS=()
    api_cleanup
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"
    return 0
}

# ============================================================
# Main
# ============================================================

parse_args "$@"
has_tty || die "Terminal (/dev/tty) tidak tersedia. Jalankan dari terminal interaktif."
require_deps
WORK_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/create-vm.XXXXXX")" || die "Gagal membuat direktori sementara."
LOG_EXIT_HOOK=on_exit
LOG_INTERRUPT_HOOK=on_interrupt

echo "========================================"
echo "🖥️  Create VM$( (( DRY_RUN )) && echo ' (DRY-RUN)')"
echo "========================================"
log_event INPUT "dry_run=$DRY_RUN" "timeout_min=$OPT_TIMEOUT"

detect_caps
select_project
select_image
select_boot
select_flavor
select_volume_plan
decide_boot_path
select_network
select_secgroup
select_access
select_key
select_host
select_fip
ask_name_count
check_quota
prepare_userdata
show_summary

if (( DRY_RUN )); then
    show_dry_run
    [[ -n "$LOG_FILE" ]] && echo "Log: $LOG_FILE"
    exit 0
fi

echo
_answer=""
ask _answer "Buat $COUNT VM di project $PROJECT_NAME (region ${OS_REGION_NAME:--})? [y/N]: "
if ! is_yes "$_answer"; then
    log_event DECISION plan=declined
    for _n in "${R_NAME[@]}"; do
        log_result "resource=$_n" action=create-server result=DECLINED
    done
    echo "❌ Dibatalkan."
    exit 0
fi
log_event DECISION plan=accepted

create_keypair
for (( _i = 0; _i < COUNT; _i++ )); do
    create_server "$_i"
done
final_summary

_ok=0
for (( _i = 0; _i < COUNT; _i++ )); do
    [[ "${R_RESULT[$_i]:-}" == SUCCESS ]] && _ok=$(( _ok + 1 ))
done
log_info "SUMMARY vms=$COUNT success=$_ok failed=$(( COUNT - _ok )) project=$PROJECT_ID boot_path=$BOOT_PATH"
[[ -n "$LOG_FILE" ]] && echo "Log: $LOG_FILE"
(( _ok == COUNT )) || exit 1
exit 0
