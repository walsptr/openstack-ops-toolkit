#!/bin/bash
# ============================================================
# @name:        Upload Image
# @description: Upload an image to Glance with progress, sharing, and checksum verification
# @mutates:     yes
# @requires:    admin, jq
# @tags:        glance, image, upload, import
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: upload-img.sh [--file PATH | --url URL] [--name NAMA] [--disk-format FORMAT]
                     [--visibility public|private|shared|community] [--project P]...
                     [--min-disk GB] [--min-ram MB] [--preset none|linux|windows|windows-uefi]
                     [--property KEY=VALUE]... [--tag TAG]... [--convert-raw] [--tmp-dir PATH]
                     [--checksum ALGO:HASH] [--interval DETIK] [--timeout MENIT] [--dry-run]

Upload SATU image ke Glance di region aktif (credentials dari launcher),
tunggu sampai status active, lalu verifikasi size dan hash.

Sumber (pilih satu):
  --file PATH          File lokal (upload langsung, dengan bar progres)
  --url URL            URL http/https (import web-download; hanya jika
                       method web-download tersedia di region ini)

Image:
  --name NAMA          Nama image
  --disk-format FMT    Disk format (wajib; tidak pernah ditebak dari file).
                       Nilai apa pun diteruskan apa adanya ke Glance.
                       Container format selalu "bare".
  --visibility V       public | private | shared | community
  --project P          private: project owner (nama atau ID).
                       shared : project penerima (ulangi untuk beberapa project)
  --min-disk GB        Default: virtual size dari qemu-img (dibulatkan ke atas)
  --min-ram MB
  --preset P           none | linux | windows | windows-uefi
  --property K=V       Property tambahan (bisa diulang; menimpa nilai preset)
  --tag TAG            Tag (bisa diulang)

Lainnya:
  --convert-raw        Konversi ke raw sebelum upload (butuh qemu-img)
  --tmp-dir PATH       Lokasi file hasil konversi (default ${TMPDIR:-/tmp})
  --checksum A:HASH    Hash yang diharapkan (md5, sha256, sha512, ...).
                       URL: dibandingkan dengan hash Glance setelah import.
                       File: dicek terhadap file lokal sebelum upload.
  --interval DETIK     Interval polling status image (default 5)
  --timeout MENIT      Batas waktu menunggu status active (default 60;
                       akhiran s untuk detik, mis. 90s)
  --dry-run            Deteksi, validasi, cek duplikat, dan ringkasan saja;
                       tanpa konversi, upload, sharing, atau rotasi
  -h, --help           Tampilkan help

Tanpa argumen, semua pilihan ditanyakan secara interaktif. Dengan argumen,
hanya yang wajib dan belum diberikan yang ditanyakan (sumber, nama, disk
format, visibility, project, aksi duplikat).

Environment:
  OSOPS_OS_CMD    Perintah OpenStack CLI (default: openstack)
  OSOPS_QEMU_IMG  Perintah qemu-img (default: qemu-img; opsional)
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

INTERACTIVE=0
(( $# == 0 )) && INTERACTIVE=1

SRC_KIND=""          # file | url
SRC_FILE=""
SRC_URL=""
SRC_URL_SHOWN=""     # URL dengan kredensial disamarkan (untuk layar dan log)
SRC_SIZE=""
NAME=""
DISK_FORMAT=""
CONTAINER_FORMAT="bare"
VISIBILITY=""
PROJECT_ARGS=()
MIN_DISK=""
MIN_DISK_SET=0
MIN_RAM=""
MIN_RAM_SET=0
PRESET=""
PROP_ARGS=()
TAGS=()
CONVERT=0
CONVERT_FLAG=0
TMP_DIR="${TMPDIR:-/tmp}"
CHECKSUM=""
DRY_RUN=0
INTERVAL=5
TIMEOUT_SPEC=60
TIMEOUT_SEC=3600

GIB=1073741824
LARGE_FILE=$(( 5 * GIB ))
FORMATS=(raw qcow2 vmdk vhd vhdx vdi iso ploop)

# Wrapper OpenStack CLI. Array tidak bisa di-export, jadi override
# lewat string, mis. RHOSO: OSOPS_OS_CMD="oc exec -n openstack openstackclient -- openstack"
if [[ -n "${OSOPS_OS_CMD:-}" ]]; then
    read -ra OS_CMD <<< "$OSOPS_OS_CMD"
else
    OS_CMD=(openstack)
fi

QEMU_IMG="${OSOPS_QEMU_IMG:-qemu-img}"
QEMU_OK=0

US=$'\x1f'

# Kemampuan region aktif
REGION="-"
AUTH_HOST="-"
GLANCE_MAX=""
HIDDEN_OK=0
IMPORT_METHODS=""
WEB_DOWNLOAD=0

# Project (dimuat sekali)
PROJECTS_LOADED=0
PROJ_IDS=()
PROJ_NAMES=()
PROJ_DOMAINS=()
CUR_PROJECT_ID="-"
CUR_PROJECT_NAME="-"
OWNER_ID="-"
OWNER_NAME="-"
RECIPIENT_IDS=()
RECIPIENT_NAMES=()

# Properties (urutan dipertahankan)
declare -A PROPS=()
PROP_KEYS=()

# qemu-img / konversi
VIRTUAL_SIZE=""
MIN_DISK_DEFAULT=""
QEMU_WARN=""
TMP_FILE=""
UPLOAD_FILE=""
UPLOAD_FORMAT=""

# Duplikat
DUPS=()              # id US owner US visibility US status US created_at US hidden
DUP_ACTION="none"    # none | continue | rotate
ROT_IDS=()
ROTATED=()           # id US nama_baru US result

# Upload
IMAGE_ID=""
CREATE_ARGS=()
PHASE="setup"
UP_START=0
UP_DURATION=0
RESULT_MSG=""
VERIFY_NOTE=""
MEMBER_INFO=()

# Image terakhir yang dibaca (get_image)
IMG_STATUS="-" IMG_NAME="-" IMG_DISK_FORMAT="-" IMG_SIZE="-" IMG_OWNER="-" IMG_VISIBILITY="-"
IMG_HASH_ALGO="-" IMG_HASH_VALUE="-" IMG_CHECKSUM="-" IMG_FAILED_IMPORT="-"
IMG_ERR=""

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

# ask_timeout VAR DETIK PROMPT — untuk hook interrupt (tidak boleh menunggu selamanya)
ask_timeout() {
    local __askt_reply=""
    if has_tty; then
        printf '%s' "$3" > /dev/tty
        IFS= read -r -t "$2" __askt_reply < /dev/tty || __askt_reply=""
    fi
    printf -v "$1" '%s' "$__askt_reply"
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

# Ukuran bytes => "1.5 GiB"
fmt_size() {
    local b="$1"
    [[ "$b" =~ ^[0-9]+$ ]] || { printf '%s' "$b"; return 0; }
    if (( b >= GIB )); then
        printf '%d.%d GiB' $(( b / GIB )) $(( b % GIB * 10 / GIB ))
    elif (( b >= 1048576 )); then
        printf '%d.%d MiB' $(( b / 1048576 )) $(( b % 1048576 * 10 / 1048576 ))
    else
        printf '%d bytes' "$b"
    fi
}

# "1.5 GiB (1610612736 bytes)", atau "300000 bytes" untuk ukuran kecil
size_text() {
    local t
    t="$(fmt_size "$1")"
    if [[ "$1" =~ ^[0-9]+$ && "$t" != *bytes ]]; then
        printf '%s (%s bytes)' "$t" "$1"
    else
        printf '%s' "$t"
    fi
}

ceil_gib() {
    printf '%d' $(( ($1 + GIB - 1) / GIB ))
}

term_cols() {
    local size
    size="$(stty size < /dev/tty 2>/dev/null)" || size=""
    size="${size#* }"
    [[ "$size" =~ ^[0-9]+$ ]] && (( size > 20 )) || size=120
    printf '%s' "$size"
}

# ver_ge A B => true jika versi A >= B (format MAJOR.MINOR)
ver_ge() {
    local a_maj="${1%%.*}" a_min="${1#*.}" b_maj="${2%%.*}" b_min="${2#*.}"
    (( a_maj > b_maj || (a_maj == b_maj && a_min >= b_min) ))
}

last_error_line() {
    grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | cut -c1-300
}

file_size() {
    stat -c %s -- "$1" 2>/dev/null
}

# Samarkan kredensial di URL: userinfo (user:pass@) dan nilai parameter
# query yang namanya mirip kredensial (token, signature, key, secret, ...).
mask_url() {
    local u="$1" base query frag="" out="" p k
    local -a parts=()

    if [[ "$u" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)([^/?#]*@)(.*)$ ]]; then
        u="${BASH_REMATCH[1]}***@${BASH_REMATCH[3]}"
    fi

    if [[ "$u" == *\?* ]]; then
        base="${u%%\?*}"
        query="${u#*\?}"
        if [[ "$query" == *#* ]]; then
            frag="#${query#*#}"
            query="${query%%#*}"
        fi
        IFS='&' read -ra parts <<< "$query"
        for p in "${parts[@]}"; do
            k="${p%%=*}"
            if [[ "$p" == *=* && "${k,,}" =~ token|sig|key|secret|pass|auth|cred|session ]]; then
                p="$k=***"
            fi
            out+="${out:+&}$p"
        done
        u="$base?$out$frag"
    fi

    printf '%s' "$u"
}

# Ganti URL asli dengan versi tersamar (replacement di-quote: '&' literal)
mask_text() {
    local s="$1"
    if [[ -n "$SRC_URL" && "$SRC_URL" != "$SRC_URL_SHOWN" ]]; then
        s="${s//"$SRC_URL"/"$SRC_URL_SHOWN"}"
    fi
    printf '%s' "$s"
}

new_uuid() {
    local u=""
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        u="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || u=""
    fi
    if [[ -z "$u" ]] && command -v uuidgen >/dev/null 2>&1; then
        u="$(uuidgen 2>/dev/null)" || u=""
    fi
    [[ "$u" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || \
        die "Tidak bisa membuat UUID untuk image ID (/proc/sys/kernel/random/uuid atau uuidgen)."
    IMAGE_ID="${u,,}"
}

# menu_choice TITLE DEFAULT ITEM... — menu bernomor yang tetap terlihat di layar
# (sengaja bukan fzf: kursor fzf selalu di item pertama, satu Enter langsung
# memilihnya, dan picker hilang dari layar). DEFAULT kosong = wajib dipilih.
# Jawaban: nomor atau kata pertama item. Hasil: index (0-based) di MENU_IDX.
menu_choice() {
    local title="$1" def="$2" answer i n key tries=0 hint
    shift 2
    local -a items=("$@")

    n=${#items[@]}
    MENU_IDX=-1
    if [[ -n "$def" ]]; then hint="(default $def)"; else hint="(wajib, tanpa default)"; fi

    echo
    echo "${C_BOLD}$title${C_RESET}"
    for i in "${!items[@]}"; do
        printf '  %d. %s\n' $(( i + 1 )) "${items[$i]}"
    done

    while true; do
        tries=$(( tries + 1 ))
        (( tries <= 5 )) || die "$title wajib dipilih."
        ask answer "Pilih [1-$n atau nama] $hint: "
        answer="$(trim "$answer")"
        [[ -z "$answer" ]] && answer="$def"
        if [[ -z "$answer" ]]; then
            echo "${C_YELLOW}⚠️  $title wajib dipilih (tidak ada default).${C_RESET}"
            continue
        fi
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= n )); then
            MENU_IDX=$(( answer - 1 ))
            return 0
        fi
        for i in "${!items[@]}"; do
            key="${items[$i]%% *}"
            if [[ "${answer,,}" == "${key,,}" ]]; then
                MENU_IDX=$i
                return 0
            fi
        done
        echo "${C_YELLOW}⚠️  Pilihan tidak valid: $answer${C_RESET}"
    done
}

# ============================================================
# OpenStack CLI wrapper
# ============================================================

# Query (output ke stdout, tidak dicatat sebagai CMD)
os_cli() {
    "${OS_CMD[@]}" "$@"
}

# Aksi yang mengubah resource: dicatat (CMD) dan stderr disimpan di LOG_LAST_ERROR.
# stdout TIDAK ditangkap (bar progres --progress harus terlihat di terminal).
os_run() {
    log_run "${OS_CMD[@]}" "$@"
}

# Seperti os_run, tetapi URL sumber disamarkan di CMD, stderr, dan LOG_LAST_ERROR
os_run_masked() {
    local errfile rc=0 a err
    local -a logged=()

    for a in "${OS_CMD[@]}" "$@"; do
        logged+=("$(mask_text "$a")")
    done
    log_cmd "${logged[@]}"
    LOG_LAST_ERROR=""

    errfile="$(mktemp)"
    "${OS_CMD[@]}" "$@" 2>"$errfile" || rc=$?

    err="$(cat "$errfile" 2>/dev/null)" || err=""
    [[ -n "$err" ]] && printf '%s\n' "$(mask_text "$err")" >&2
    LOG_LAST_ERROR="$(mask_text "$(tail -n 5 "$errfile" 2>/dev/null | cut -c1-500)")"
    rm -f "$errfile"

    return "$rc"
}

# Pesan error pertama yang bermakna dari LOG_LAST_ERROR
api_error() {
    local e
    e="$(grep -v '^[[:space:]]*$' <<< "$LOG_LAST_ERROR" | tail -n 1)" || e=""
    printf '%s' "${e:-tidak ada pesan dari API}"
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
            --file)        need_value "$1" "${2:-}"; SRC_FILE="$2"; shift 2 ;;
            --url)         need_value "$1" "${2:-}"; SRC_URL="$2"; shift 2 ;;
            --name)        need_value "$1" "${2:-}"; NAME="$2"; shift 2 ;;
            --disk-format) need_value "$1" "${2:-}"; DISK_FORMAT="$2"; shift 2 ;;
            --visibility)  need_value "$1" "${2:-}"; VISIBILITY="${2,,}"; shift 2 ;;
            --project)     need_value "$1" "${2:-}"; PROJECT_ARGS+=("$2"); shift 2 ;;
            --min-disk)    need_value "$1" "${2:-}"; MIN_DISK="$2"; MIN_DISK_SET=1; shift 2 ;;
            --min-ram)     need_value "$1" "${2:-}"; MIN_RAM="$2"; MIN_RAM_SET=1; shift 2 ;;
            --preset)      need_value "$1" "${2:-}"; PRESET="${2,,}"; shift 2 ;;
            --property)    need_value "$1" "${2:-}"; PROP_ARGS+=("$2"); shift 2 ;;
            --tag)         need_value "$1" "${2:-}"; TAGS+=("$2"); shift 2 ;;
            --convert-raw) CONVERT_FLAG=1; shift ;;
            --tmp-dir)     need_value "$1" "${2:-}"; TMP_DIR="$2"; shift 2 ;;
            --checksum)    need_value "$1" "${2:-}"; CHECKSUM="$2"; shift 2 ;;
            --interval)    need_value "$1" "${2:-}"; INTERVAL="$2"; shift 2 ;;
            --timeout)     need_value "$1" "${2:-}"; TIMEOUT_SPEC="$2"; shift 2 ;;
            --dry-run)     DRY_RUN=1; shift ;;
            *)             die "Parameter tidak dikenal: $1 (lihat --help)" ;;
        esac
    done

    [[ -n "$SRC_FILE" && -n "$SRC_URL" ]] && die "--file dan --url tidak bisa dipakai bersamaan."

    if [[ -n "$VISIBILITY" && ! "$VISIBILITY" =~ ^(public|private|shared|community)$ ]]; then
        die "--visibility harus public, private, shared, atau community."
    fi
    if [[ -n "$PRESET" && ! "$PRESET" =~ ^(none|linux|windows|windows-uefi)$ ]]; then
        die "--preset harus none, linux, windows, atau windows-uefi."
    fi
    if (( MIN_DISK_SET )) && [[ ! "$MIN_DISK" =~ ^[0-9]+$ ]]; then
        die "--min-disk harus bilangan bulat >= 0 (GB)."
    fi
    if (( MIN_RAM_SET )) && [[ ! "$MIN_RAM" =~ ^[0-9]+$ ]]; then
        die "--min-ram harus bilangan bulat >= 0 (MB)."
    fi

    local p t
    for p in "${PROP_ARGS[@]}"; do
        [[ "$p" =~ ^[^=[:space:]]+=.*$ ]] || die "--property harus berformat key=value: $p"
    done
    for t in "${TAGS[@]}"; do
        [[ -n "$(trim "$t")" ]] || die "--tag tidak boleh kosong."
    done

    if [[ -n "$CHECKSUM" ]]; then
        [[ "${CHECKSUM,,}" =~ ^(md5|sha1|sha224|sha256|sha384|sha512):[0-9a-f]+$ ]] || \
            die "--checksum harus berformat algo:hash heksadesimal (md5, sha1, sha224, sha256, sha384, sha512)."
        CHECKSUM="${CHECKSUM,,}"
    fi

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
    if command -v "$QEMU_IMG" >/dev/null 2>&1; then
        QEMU_OK=1
    fi
    return 0
}

# ============================================================
# 1. Deteksi kemampuan region aktif
# ============================================================

detect_capabilities() {
    local json host
    local -a region_arg=()

    REGION="${OS_REGION_NAME:--}"
    host="${OS_AUTH_URL:--}"
    host="${host#*://}"
    host="${host%%/*}"
    AUTH_HOST="${host:--}"

    [[ "$REGION" != "-" ]] && region_arg=(--region-name "$REGION")

    GLANCE_MAX=""
    if json="$(os_cli versions show --service image "${region_arg[@]}" -f json 2>/dev/null)"; then
        GLANCE_MAX="$(jq -r '
            [ .[] | select(((."Status" // "") | ascii_upcase) as $s | $s == "CURRENT" or $s == "SUPPORTED")
                  | (."Version" // "" | tostring | ltrimstr("v"))
                  | select(test("^[0-9]+\\.[0-9]+$")) ]
            | sort_by(split(".") | map(tonumber)) | last // empty' <<< "$json" 2>/dev/null)" || GLANCE_MAX=""
    fi

    HIDDEN_OK=0
    if [[ -n "$GLANCE_MAX" ]] && ver_ge "$GLANCE_MAX" 2.7; then
        HIDDEN_OK=1
    fi

    IMPORT_METHODS=""
    if json="$(os_cli image import info -f json 2>/dev/null)"; then
        IMPORT_METHODS="$(jq -r '
            (."import-methods" // .import_methods // [])
            | if type == "array" then join(",")
              elif type == "string" then (split(",") | map(gsub("^\\s+|\\s+$"; "")) | join(","))
              else empty end' <<< "$json" 2>/dev/null)" || IMPORT_METHODS=""
    fi

    WEB_DOWNLOAD=0
    [[ ",$IMPORT_METHODS," == *",web-download,"* ]] && WEB_DOWNLOAD=1

    echo "🌐 Region  : $REGION (auth: $AUTH_HOST)"
    if [[ -n "$GLANCE_MAX" ]]; then
        echo "🖼️  Glance  : API v$GLANCE_MAX (os_hidden: $( (( HIDDEN_OK )) && echo didukung || echo 'tidak didukung, butuh v2.7+'))"
    else
        echo "🖼️  Glance  : versi API tidak diketahui (os_hidden tidak dipakai)"
    fi
    echo "📥 Import  : ${IMPORT_METHODS:-tidak diketahui} (web-download: $( (( WEB_DOWNLOAD )) && echo ya || echo tidak))"
    if (( QEMU_OK )); then
        echo "🔧 qemu-img: tersedia"
    else
        echo "🔧 qemu-img: tidak tersedia (virtual size / default min-disk dan konversi raw dilewati)"
    fi

    log_event CAPABILITIES "region=$REGION" "auth_host=$AUTH_HOST" "glance_max=${GLANCE_MAX:--}" \
        "os_hidden=$HIDDEN_OK" "import_methods=${IMPORT_METHODS:--}" "web_download=$WEB_DOWNLOAD" \
        "qemu_img=$QEMU_OK"
    return 0
}

# ============================================================
# 2. Sumber dan validasi
# ============================================================

select_source() {
    local answer

    if [[ -n "$SRC_FILE" ]]; then
        SRC_KIND="file"
    elif [[ -n "$SRC_URL" ]]; then
        SRC_KIND="url"
    elif (( WEB_DOWNLOAD )); then
        echo
        echo "Sumber image:"
        echo "  1. File lokal"
        echo "  2. URL (web-download)"
        ask answer "Pilih [1-2] (default 1): "
        case "$(trim "$answer")" in
            ""|1) SRC_KIND="file" ;;
            2)    SRC_KIND="url" ;;
            *)    die "Pilihan sumber tidak valid: $answer" ;;
        esac
    else
        note "Sumber URL tidak tersedia: method web-download tidak aktif di region ini."
        SRC_KIND="file"
    fi

    if [[ "$SRC_KIND" == "file" && -z "$SRC_FILE" ]]; then
        ask SRC_FILE "Path file image: "
        SRC_FILE="$(trim "$SRC_FILE")"
    elif [[ "$SRC_KIND" == "url" && -z "$SRC_URL" ]]; then
        ask SRC_URL "URL image (http/https): "
        SRC_URL="$(trim "$SRC_URL")"
    fi

    validate_source
}

validate_source() {
    if [[ "$SRC_KIND" == "file" ]]; then
        SRC_FILE="${SRC_FILE/#\~/$HOME}"
        [[ -n "$SRC_FILE" ]] || die "Path file tidak boleh kosong."
        [[ -e "$SRC_FILE" ]] || die "File tidak ditemukan: $SRC_FILE"
        [[ -f "$SRC_FILE" ]] || die "Bukan file biasa: $SRC_FILE"
        [[ -r "$SRC_FILE" ]] || die "File tidak bisa dibaca: $SRC_FILE"
        SRC_FILE="$(realpath -- "$SRC_FILE")"
        SRC_SIZE="$(file_size "$SRC_FILE")" || SRC_SIZE=""
        [[ "$SRC_SIZE" =~ ^[0-9]+$ ]] || die "Ukuran file tidak bisa dibaca: $SRC_FILE"
        (( SRC_SIZE > 0 )) || die "File kosong (0 bytes): $SRC_FILE"
        echo "📄 Sumber  : $SRC_FILE ($(fmt_size "$SRC_SIZE"))"
        log_event INPUT source=file "file=$SRC_FILE" "size=$SRC_SIZE"
    else
        (( WEB_DOWNLOAD )) || \
            die "Sumber URL butuh import method web-download, tidak tersedia di region $REGION (method: ${IMPORT_METHODS:-tidak diketahui})."
        [[ -n "$SRC_URL" ]] || die "URL tidak boleh kosong."
        SRC_URL_SHOWN="$(mask_url "$SRC_URL")"
        [[ "$SRC_URL" =~ ^[Hh][Tt][Tt][Pp][Ss]?://[^/?#[:space:]]+ && "$SRC_URL" != *[[:space:]]* ]] || \
            die "URL harus diawali http:// atau https:// dan tanpa spasi: $SRC_URL_SHOWN"
        echo "🔗 Sumber  : $SRC_URL_SHOWN"
        log_event INPUT source=url "url=$SRC_URL_SHOWN"
    fi
    return 0
}

# --checksum untuk file lokal: dicek sebelum upload (gagal lebih awal)
check_local_checksum() {
    local algo="${CHECKSUM%%:*}" want="${CHECKSUM#*:}" got

    [[ -n "$CHECKSUM" && "$SRC_KIND" == "file" ]] || return 0
    command -v "${algo}sum" >/dev/null 2>&1 || die "${algo}sum tidak ditemukan untuk --checksum."

    echo "🔎 Menghitung $algo file lokal..."
    got="$("${algo}sum" -- "$SRC_FILE" | cut -d' ' -f1)" || die "Gagal menghitung $algo: $SRC_FILE"
    if [[ "$got" != "$want" ]]; then
        log_event CHECKSUM_INPUT "algo=$algo" "expected=$want" "actual=$got" result=mismatch
        die "Checksum file lokal tidak cocok dengan --checksum ($algo): harap $want, dapat $got"
    fi
    echo "${C_GREEN}✅ Checksum file lokal cocok ($algo).${C_RESET}"
    log_event CHECKSUM_INPUT "algo=$algo" "expected=$want" result=match
    return 0
}

# ============================================================
# 3. Nama, disk format, container format
# ============================================================

select_name() {
    local def answer

    if [[ -z "$NAME" ]]; then
        if [[ "$SRC_KIND" == "file" ]]; then
            def="$(basename -- "$SRC_FILE")"
        else
            def="${SRC_URL%%[?#]*}"
            def="${def%/}"
            def="${def##*/}"
        fi
        def="${def%.*}"
        ask answer "Nama image${def:+ [default $def]}: "
        answer="$(trim "$answer")"
        NAME="${answer:-$def}"
    fi

    NAME="$(trim "$NAME")"
    [[ -n "$NAME" ]] || die "Nama image tidak boleh kosong."
    (( ${#NAME} <= 255 )) || die "Nama image maksimal 255 karakter."
    log_event INPUT "name=$NAME"
}

# Disk format sepenuhnya pilihan user: tidak ada deteksi dan tidak ada default.
# Sengaja menu bernomor (bukan fzf): kursor fzf selalu di item pertama sehingga
# satu Enter langsung memilih "raw", dan picker hilang dari layar setelahnya.
select_format() {
    local -a desc=(
        "disk mentah tanpa format"
        "QEMU copy-on-write"
        "VMware"
        "Hyper-V / Xen (VHD)"
        "Hyper-V (VHDX)"
        "VirtualBox"
        "image CD/DVD"
        "Virtuozzo"
    )
    local answer i n=${#FORMATS[@]} tries=0

    if [[ -n "$DISK_FORMAT" ]]; then
        log_event INPUT "disk_format=$DISK_FORMAT" via=option
    else
        has_tty || die "Butuh terminal interaktif (/dev/tty) untuk input: Disk format (atau gunakan --disk-format)"
        echo
        echo "${C_BOLD}Disk format${C_RESET} — pilih sesuai ISI file (tidak dideteksi otomatis, tidak ada default)."
        echo "  Ekstensi file tidak menentukan format: file .img bisa berisi qcow2 maupun raw."
        if [[ "$SRC_KIND" == "file" ]]; then
            echo "  Jika ragu, cek manual di terminal lain: qemu-img info $SRC_FILE"
        fi
        for i in "${!FORMATS[@]}"; do
            printf '  %d. %-6s %s\n' $(( i + 1 )) "${FORMATS[$i]}" "${desc[$i]}"
        done

        while [[ -z "$DISK_FORMAT" ]]; do
            tries=$(( tries + 1 ))
            (( tries <= 5 )) || die "Disk format wajib dipilih."
            ask answer "Disk format [1-$n atau nama format] (wajib): "
            answer="$(trim "$answer")"
            if [[ -z "$answer" ]]; then
                echo "${C_YELLOW}⚠️  Disk format wajib dipilih (tidak ada default).${C_RESET}"
            elif [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= n )); then
                DISK_FORMAT="${FORMATS[$(( answer - 1 ))]}"
            elif [[ " ${FORMATS[*]} " == *" ${answer,,} "* ]]; then
                DISK_FORMAT="${answer,,}"
            else
                echo "${C_YELLOW}⚠️  Pilihan tidak valid: $answer${C_RESET}"
            fi
        done
        log_event INPUT "disk_format=$DISK_FORMAT" via=menu
    fi

    UPLOAD_FORMAT="$DISK_FORMAT"
    echo "💽 Format  : $DISK_FORMAT (container: $CONTAINER_FORMAT)"
}

# Nama driver qemu-img untuk disk format Glance (vhd = vpc, ploop = parallels)
qemu_format() {
    case "$1" in
        vhd)   printf 'vpc' ;;
        ploop) printf 'parallels' ;;
        *)     printf '%s' "$1" ;;
    esac
}

# ============================================================
# 4. Virtual size dan min-disk
# ============================================================

read_virtual_size() {
    local out errf qf err vs

    [[ "$SRC_KIND" == "file" ]] || return 0

    if (( ! QEMU_OK )); then
        log_info "qemu-img tidak tersedia: virtual size dan konversi dilewati"
        return 0
    fi
    if [[ "$DISK_FORMAT" == "iso" ]]; then
        log_info "disk_format=iso: qemu-img info dilewati"
        return 0
    fi

    qf="$(qemu_format "$DISK_FORMAT")"
    errf="$(mktemp)"
    if out="$("$QEMU_IMG" info -f "$qf" --output=json "$SRC_FILE" 2>"$errf")" &&
       vs="$(jq -r '."virtual-size" // empty' <<< "$out" 2>/dev/null)" && [[ "$vs" =~ ^[0-9]+$ ]]; then
        VIRTUAL_SIZE="$vs"
        MIN_DISK_DEFAULT="$(ceil_gib "$vs")"
        echo "📐 Virtual : $(fmt_size "$vs") (qemu-img -f $qf) → default min-disk $MIN_DISK_DEFAULT GB"
        log_event QEMU_INFO "format=$qf" "virtual_size=$vs" "min_disk_default=$MIN_DISK_DEFAULT"
    else
        err="$(last_error_line "$errf")"
        QEMU_WARN="${err:-output qemu-img info tidak valid}"
        warn "qemu-img tidak bisa membaca file sebagai '$DISK_FORMAT' — file mungkin tidak sesuai dengan format yang dipilih: $QEMU_WARN"
        log_event QEMU_INFO "format=$qf" result=failed "msg=$QEMU_WARN"
    fi
    rm -f "$errf"
    return 0
}

select_min_values() {
    local answer

    if (( ! MIN_DISK_SET )); then
        if (( INTERACTIVE )); then
            ask answer "Min disk (GB)${MIN_DISK_DEFAULT:+ [default $MIN_DISK_DEFAULT]} (kosong = ${MIN_DISK_DEFAULT:-tidak diisi}): "
            answer="$(trim "$answer")"
            MIN_DISK="${answer:-$MIN_DISK_DEFAULT}"
        else
            MIN_DISK="$MIN_DISK_DEFAULT"
        fi
    fi
    if [[ -n "$MIN_DISK" && ! "$MIN_DISK" =~ ^[0-9]+$ ]]; then
        die "Min disk harus bilangan bulat >= 0 (GB): $MIN_DISK"
    fi
    if [[ -n "$MIN_DISK" && -n "$MIN_DISK_DEFAULT" ]] && (( MIN_DISK < MIN_DISK_DEFAULT )); then
        warn "min-disk $MIN_DISK GB lebih kecil dari virtual size ($MIN_DISK_DEFAULT GB)."
    fi

    if (( ! MIN_RAM_SET && INTERACTIVE )); then
        ask answer "Min RAM (MB) (kosong = tidak diisi): "
        MIN_RAM="$(trim "$answer")"
    fi
    if [[ -n "$MIN_RAM" && ! "$MIN_RAM" =~ ^[0-9]+$ ]]; then
        die "Min RAM harus bilangan bulat >= 0 (MB): $MIN_RAM"
    fi

    log_event INPUT "min_disk=${MIN_DISK:--}" "min_ram=${MIN_RAM:--}"
}

# ============================================================
# 5. Konversi ke raw (opsional)
# ============================================================

# Ruang kosong di TMP_DIR >= virtual size + margin (5%, minimal 1 GiB)
check_tmp_space() {
    local need margin avail

    [[ -d "$TMP_DIR" && -w "$TMP_DIR" ]] || die "--tmp-dir tidak ada atau tidak bisa ditulis: $TMP_DIR"

    margin=$(( VIRTUAL_SIZE / 20 ))
    (( margin < GIB )) && margin=$GIB
    need=$(( VIRTUAL_SIZE + margin ))

    avail="$(df -P -B1 -- "$TMP_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')" || avail=""
    [[ "$avail" =~ ^[0-9]+$ ]] || die "Ruang kosong di $TMP_DIR tidak bisa dicek (df)."

    log_event TMP_SPACE "dir=$TMP_DIR" "available=$avail" "needed=$need"
    if (( avail < need )); then
        die "Ruang kosong di $TMP_DIR tidak cukup untuk konversi: tersedia $(fmt_size "$avail"), butuh $(fmt_size "$need") (virtual size + margin). Gunakan --tmp-dir lain."
    fi
    return 0
}

offer_convert() {
    local answer reason=""

    if [[ "$SRC_KIND" != "file" ]]; then
        reason="sumber URL"
    elif (( ! QEMU_OK )); then
        reason="qemu-img tidak tersedia"
    elif [[ "$DISK_FORMAT" == "raw" || "$DISK_FORMAT" == "iso" ]]; then
        reason="format $DISK_FORMAT"
    elif [[ -z "$VIRTUAL_SIZE" ]]; then
        reason="virtual size tidak terbaca oleh qemu-img"
    fi

    if [[ -n "$reason" ]]; then
        (( CONVERT_FLAG )) && die "--convert-raw tidak bisa dipakai: $reason."
        return 0
    fi

    if (( CONVERT_FLAG )); then
        CONVERT=1
    elif (( INTERACTIVE )); then
        echo
        echo "${C_BOLD}Konversi ke raw?${C_RESET}"
        echo "  Raw direkomendasikan untuk backend Ceph RBD (clone copy-on-write untuk instance/volume)."
        echo "  Untuk backend lain (file, swift, cinder) format asli umumnya lebih hemat ruang dan waktu upload."
        echo "  Script tidak mendeteksi backend Glance; sesuaikan dengan konfigurasi region $REGION."
        echo "  Butuh ruang kosong ±$(fmt_size "$VIRTUAL_SIZE") di $TMP_DIR."
        ask answer "Konversi $DISK_FORMAT → raw sebelum upload? [y/N]: "
        is_yes "$answer" && CONVERT=1
    else
        note "Konversi ke raw tersedia (--convert-raw), disarankan untuk backend Ceph RBD."
    fi

    log_event DECISION "convert_raw=$CONVERT"
    if (( CONVERT )); then
        check_tmp_space
        UPLOAD_FORMAT="raw"
    fi
    return 0
}

convert_raw() {
    local qf start dur after

    qf="$(qemu_format "$DISK_FORMAT")"
    check_tmp_space
    TMP_FILE="$(mktemp "$TMP_DIR/upload-img-XXXXXXXX.raw")" || die "Tidak bisa membuat file sementara di $TMP_DIR"

    echo
    echo "🔄 Konversi $DISK_FORMAT → raw: $TMP_FILE"
    PHASE="convert"
    start=$SECONDS
    log_cmd "$QEMU_IMG" convert -p -f "$qf" -O raw "$SRC_FILE" "$TMP_FILE"

    # Output progres qemu-img langsung ke terminal (tidak ditangkap)
    if ! "$QEMU_IMG" convert -p -f "$qf" -O raw "$SRC_FILE" "$TMP_FILE"; then
        dur=$(( SECONDS - start ))
        rm -f "$TMP_FILE"
        TMP_FILE=""
        RESULT_MSG="konversi qemu-img gagal"
        echo "${C_RED}❌ Konversi gagal setelah ${dur}s; file sementara dihapus.${C_RESET}"
        log_event CONVERT result=failed "duration=$dur"
        log_result resource=- action=upload-image result=FAILED "name=$NAME" "region=$REGION" \
            "disk_format=$DISK_FORMAT" "visibility=$VISIBILITY" "owner=$OWNER_ID" "size=$SRC_SIZE" \
            hash=- "duration=$dur" "msg=$RESULT_MSG"
        return 1
    fi

    dur=$(( SECONDS - start ))
    after="$(file_size "$TMP_FILE")" || after="-"
    UPLOAD_FILE="$TMP_FILE"
    UPLOAD_FORMAT="raw"
    echo "${C_GREEN}✅ Konversi selesai (${dur}s): $(fmt_size "$SRC_SIZE") → $(fmt_size "$after")${C_RESET}"
    log_event CONVERT result=ok "duration=$dur" "size_before=$SRC_SIZE" "size_after=$after" "file=$TMP_FILE"
    return 0
}

# Dipanggil lib/logging.sh saat script keluar (normal, error, sinyal)
on_exit() {
    if [[ -n "$TMP_FILE" && -e "$TMP_FILE" ]]; then
        rm -f "$TMP_FILE" && log_info "file sementara dihapus: $TMP_FILE"
    fi
    return 0
}

# ============================================================
# 6. Visibility dan project
# ============================================================

load_projects() {
    local json djson errf err
    local -A dom=()
    local -a rows=()
    local r id name did

    (( PROJECTS_LOADED )) && return 0

    errf="$(mktemp)"
    if ! json="$(os_cli project list --long -f json 2>"$errf")"; then
        err="$(last_error_line "$errf")"
        rm -f "$errf"
        die "project list gagal (butuh role admin?): ${err:-tanpa pesan}"
    fi
    rm -f "$errf"

    if djson="$(os_cli domain list -f json 2>/dev/null)"; then
        while IFS="$US" read -r id name; do
            [[ -n "$id" ]] && dom[$id]="$name"
        done < <(jq -r '.[] | [.ID, .Name] | map(tostring) | join("\u001f")' <<< "$djson" 2>/dev/null)
    fi

    mapfile -t rows < <(
        jq -r 'def v: if . == null or . == "" then "-" else tostring end;
               sort_by(.Name | ascii_downcase) | .[]
               | [ .ID, .Name, (."Domain ID" // .domain_id) ] | map(v) | join("\u001f")' <<< "$json" 2>/dev/null
    )
    (( ${#rows[@]} > 0 )) || die "project list kosong atau bukan JSON yang valid."

    for r in "${rows[@]}"; do
        IFS="$US" read -r id name did <<< "$r"
        PROJ_IDS+=("$id")
        PROJ_NAMES+=("$name")
        PROJ_DOMAINS+=("${dom[$did]:-$did}")
    done

    PROJECTS_LOADED=1
    return 0
}

# Index project dari nama atau ID => PIDX. Nama ganda di domain berbeda harus pakai ID.
# Return 0 = ditemukan, 1 = tidak ditemukan, 2 = nama ambigu. Pesan di PERR.
find_project() {
    local want="$1" i n=0

    PIDX=-1
    PERR=""
    for i in "${!PROJ_IDS[@]}"; do
        if [[ "${PROJ_IDS[$i]}" == "$want" ]]; then
            PIDX=$i
            return 0
        fi
    done
    for i in "${!PROJ_NAMES[@]}"; do
        if [[ "${PROJ_NAMES[$i]}" == "$want" ]]; then
            PIDX=$i
            n=$(( n + 1 ))
        fi
    done
    (( n == 1 )) && return 0
    if (( n > 1 )); then
        PERR="Nama project '$want' ada di lebih dari satu domain; gunakan project ID."
        return 2
    fi
    PERR="Project tidak ditemukan: $want"
    return 1
}

resolve_project() {
    find_project "$1" || die "$PERR"
}

print_projects() {
    local i
    printf '  %s%-30s %-20s %s%s\n' "$C_BOLD" NAMA DOMAIN ID "$C_RESET"
    for i in "${!PROJ_IDS[@]}"; do
        printf '  %s\n' "$(project_label "$i")"
    done
}

# ask_projects MULTI PROMPT — input nama/ID project (MULTI: dipisah koma),
# divalidasi dan ditanya ulang jika salah; "?" menampilkan daftar project.
# Hasil: index di PROJ_SEL.
ask_projects() {
    local multi="$1" prompt="$2" answer tok ok tries=0
    local -a toks=()

    PROJ_SEL=()
    while true; do
        tries=$(( tries + 1 ))
        (( tries <= 5 )) || die "Project wajib diisi dengan nama atau ID yang valid."
        ask answer "$prompt"
        answer="$(trim "$answer")"
        if [[ "$answer" == "?" ]]; then
            print_projects
            tries=$(( tries - 1 ))
            continue
        fi
        if [[ -z "$answer" ]]; then
            echo "${C_YELLOW}⚠️  Project wajib diisi (ketik ? untuk melihat daftar).${C_RESET}"
            continue
        fi

        if (( multi )); then
            IFS=',' read -ra toks <<< "$answer"
        else
            toks=("$answer")
        fi

        PROJ_SEL=()
        ok=1
        for tok in "${toks[@]}"; do
            tok="$(trim "$tok")"
            [[ -n "$tok" ]] || continue
            if find_project "$tok"; then
                [[ " ${PROJ_SEL[*]} " == *" $PIDX "* ]] || PROJ_SEL+=("$PIDX")
            else
                echo "${C_YELLOW}⚠️  $PERR${C_RESET}"
                ok=0
            fi
        done
        if (( ok && ${#PROJ_SEL[@]} > 0 )); then
            for tok in "${PROJ_SEL[@]}"; do
                echo "   → ${PROJ_NAMES[$tok]} [${PROJ_DOMAINS[$tok]}] ${PROJ_IDS[$tok]}"
            done
            return 0
        fi
    done
}

project_label() {
    printf '%-30s %-20s %s' "${PROJ_NAMES[$1]}" "[${PROJ_DOMAINS[$1]}]" "${PROJ_IDS[$1]}"
}

project_name_of() {
    local i
    for i in "${!PROJ_IDS[@]}"; do
        if [[ "${PROJ_IDS[$i]}" == "$1" ]]; then
            printf '%s' "${PROJ_NAMES[$i]}"
            return 0
        fi
    done
    printf '%s' "$1"
}

# Project credentials aktif (owner image untuk public/shared/community)
current_project() {
    local i pdom="${OS_PROJECT_DOMAIN_NAME:-${OS_PROJECT_DOMAIN_ID:-${OS_USER_DOMAIN_NAME:-}}}"
    local -a hits=()

    if [[ -n "${OS_PROJECT_ID:-}" ]]; then
        CUR_PROJECT_ID="$OS_PROJECT_ID"
    elif [[ -n "${OS_PROJECT_NAME:-}" ]]; then
        for i in "${!PROJ_NAMES[@]}"; do
            [[ "${PROJ_NAMES[$i]}" == "$OS_PROJECT_NAME" ]] && hits+=("$i")
        done
        if (( ${#hits[@]} == 1 )); then
            CUR_PROJECT_ID="${PROJ_IDS[${hits[0]}]}"
        elif (( ${#hits[@]} > 1 )) && [[ -n "$pdom" ]]; then
            for i in "${hits[@]}"; do
                if [[ "${PROJ_DOMAINS[$i],,}" == "${pdom,,}" ]]; then
                    CUR_PROJECT_ID="${PROJ_IDS[$i]}"
                fi
            done
        fi
    fi
    CUR_PROJECT_NAME="$(project_name_of "$CUR_PROJECT_ID")"
    [[ "$CUR_PROJECT_ID" == "-" ]] && CUR_PROJECT_NAME="${OS_PROJECT_NAME:--}"
    return 0
}

select_visibility() {
    local -a vis=(public private shared community)
    local -a labels=(
        "public     terlihat dan bisa dipakai semua project"
        "private    hanya project owner (input nama/ID project)"
        "shared     project owner + project penerima (input nama/ID project)"
        "community  bisa dipakai semua project, tidak muncul di daftar default"
    )
    local i p

    if [[ -z "$VISIBILITY" ]]; then
        menu_choice "Visibility image" "" "${labels[@]}"
        VISIBILITY="${vis[$MENU_IDX]}"
        log_event INPUT "visibility=$VISIBILITY" via=menu
    fi
    echo "👁️  Visibility: $VISIBILITY"

    load_projects
    current_project

    if [[ "$VISIBILITY" =~ ^(public|community)$ ]] && (( ${#PROJECT_ARGS[@]} > 0 )); then
        die "--project hanya untuk visibility private (owner) atau shared (penerima)."
    fi
    if [[ "$VISIBILITY" == "private" ]] && (( ${#PROJECT_ARGS[@]} > 1 )); then
        die "Visibility private hanya menerima satu --project (owner)."
    fi

    OWNER_ID="$CUR_PROJECT_ID"
    OWNER_NAME="$CUR_PROJECT_NAME"

    case "$VISIBILITY" in
        private)
            if (( ${#PROJECT_ARGS[@]} == 1 )); then
                resolve_project "${PROJECT_ARGS[0]}"
            else
                ask_projects 0 "Project owner (nama atau ID; ? = daftar project): "
                PIDX="${PROJ_SEL[0]}"
            fi
            OWNER_ID="${PROJ_IDS[$PIDX]}"
            OWNER_NAME="${PROJ_NAMES[$PIDX]}"
            ;;
        shared)
            [[ "$CUR_PROJECT_ID" != "-" ]] || \
                die "Project credentials aktif tidak bisa ditentukan (OS_PROJECT_ID/OS_PROJECT_NAME); dibutuhkan untuk image shared."
            if (( ${#PROJECT_ARGS[@]} > 0 )); then
                PROJ_SEL=()
                for p in "${PROJECT_ARGS[@]}"; do
                    resolve_project "$p"
                    PROJ_SEL+=("$PIDX")
                done
            else
                echo "   Owner image shared: $OWNER_NAME (project credentials aktif)"
                ask_projects 1 "Project penerima (nama atau ID, pisahkan dengan koma; ? = daftar project): "
            fi
            for i in "${PROJ_SEL[@]}"; do
                [[ "${PROJ_IDS[$i]}" == "$OWNER_ID" ]] && continue
                [[ " ${RECIPIENT_IDS[*]} " == *" ${PROJ_IDS[$i]} "* ]] && continue
                RECIPIENT_IDS+=("${PROJ_IDS[$i]}")
                RECIPIENT_NAMES+=("${PROJ_NAMES[$i]}")
            done
            (( ${#RECIPIENT_IDS[@]} > 0 )) || die "Tidak ada project penerima selain owner ($OWNER_NAME)."
            ;;
        community)
            echo
            note "Community: image bisa dipakai oleh SEMUA project (siapa pun yang tahu ID/namanya),"
            note "tetapi tidak muncul di daftar image default project lain. Owner: $OWNER_NAME."
            ;;
    esac

    log_event INPUT "visibility=$VISIBILITY" "owner=$OWNER_ID" "owner_name=$OWNER_NAME" \
        "recipients=$(IFS=,; printf '%s' "${RECIPIENT_IDS[*]:-}")"
    return 0
}

# ============================================================
# 7. Cek nama duplikat
# ============================================================

# list_by_name NAMA => baris id US project US visibility US status US hidden (stdout)
list_by_name() {
    local name="$1" json
    local -a calls=("")

    (( HIDDEN_OK )) && calls+=(--hidden)

    local c
    for c in "${calls[@]}"; do
        if [[ -z "$c" ]]; then
            json="$(os_cli image list --name "$name" --long -f json 2>/dev/null)" || return 1
        else
            json="$(os_cli image list --name "$name" --long --hidden -f json 2>/dev/null)" || return 1
        fi
        jq -r --arg h "$( [[ -n "$c" ]] && echo yes || echo no )" '
            def v: if . == null or . == "" then "-" else tostring end;
            .[] | [ .ID, (."Project" // .owner), .Visibility, .Status, $h ] | map(v) | join("\u001f")' \
            <<< "$json" 2>/dev/null || return 1
    done
}

check_duplicates() {
    local rows r id owner vis status hidden created json answer own_count=0 n
    local -A seen=()
    local -a lines=()

    if ! rows="$(list_by_name "$NAME")"; then
        warn "Cek nama duplikat gagal (image list); dilanjutkan tanpa cek duplikat."
        return 0
    fi

    mapfile -t lines <<< "$rows"
    for r in "${lines[@]}"; do
        [[ -n "$r" ]] || continue
        IFS="$US" read -r id owner vis status hidden <<< "$r"
        [[ -z "${seen[$id]+x}" ]] || continue
        seen[$id]=1
        created="-"
        if json="$(os_cli image show "$id" -f json 2>/dev/null)"; then
            created="$(jq -r '.created_at // "-"' <<< "$json" 2>/dev/null)" || created="-"
        fi
        DUPS+=("$id$US$owner$US$vis$US$status$US$created$US$hidden")
        [[ "$owner" == "$OWNER_ID" ]] && own_count=$(( own_count + 1 ))
        log_event DUPLICATE "resource=$id" "name=$NAME" "owner=$owner" "visibility=$vis" \
            "status=$status" "created_at=$created" "hidden=$hidden"
    done

    n=${#DUPS[@]}
    (( n > 0 )) || return 0

    echo
    echo "${C_YELLOW}${C_BOLD}⚠️  Sudah ada $n image dengan nama '$NAME':${C_RESET}"
    print_dups

    if (( n > 1 )); then
        note "Catatan: OSC mencari image berdasarkan nama sebelum upload; jika lebih dari satu image"
        note "bernama sama terlihat, upload bisa ditolak (\"More than one Image exists\")."
    fi

    echo
    echo "  a = batal"
    echo "  c = tetap lanjut (nama ganda)"
    if (( own_count > 0 )); then
        echo "  r = rotasi: setelah image baru active, $own_count image lama milik owner yang sama"
        echo "      diganti nama menjadi '$NAME-<YYYYMMDD created_at>'$( (( HIDDEN_OK )) && echo ' dan os_hidden=true')"
        ask answer "Pilih [a/c/r] (default a): "
    else
        note "Rotasi tidak tersedia: tidak ada image lama milik owner $OWNER_NAME."
        ask answer "Pilih [a/c] (default a): "
    fi

    case "${answer,,}" in
        c)
            DUP_ACTION="continue"
            ;;
        r)
            (( own_count > 0 )) || die "Pilihan tidak valid: $answer"
            DUP_ACTION="rotate"
            for r in "${DUPS[@]}"; do
                IFS="$US" read -r id owner _ <<< "$r"
                [[ "$owner" == "$OWNER_ID" ]] && ROT_IDS+=("$id")
            done
            ;;
        *)
            log_event DECISION duplicate=abort
            log_result resource=- action=upload-image result=DECLINED "name=$NAME" "region=$REGION" \
                "msg=dibatalkan: nama duplikat ($n image)"
            echo "❌ Dibatalkan: nama duplikat."
            exit 0
            ;;
    esac

    log_event DECISION "duplicate=$DUP_ACTION" "rotate_ids=$(IFS=,; printf '%s' "${ROT_IDS[*]:-}")"
    return 0
}

print_dups() {
    local r id owner vis status created hidden
    printf '  %s%-36s  %-24s  %-10s  %-8s  %-27s %s%s\n' "$C_BOLD" ID OWNER VISIBILITY STATUS CREATED_AT HIDDEN "$C_RESET"
    for r in "${DUPS[@]}"; do
        IFS="$US" read -r id owner vis status created hidden <<< "$r"
        printf '  %-36s  %-24s  %-10s  %-8s  %-27s %s\n' "$id" "$(project_name_of "$owner" | cut -c1-24)" \
            "$vis" "$status" "$created" "$hidden"
    done
}

# ============================================================
# 8. Properties
# ============================================================

set_prop() {
    [[ -n "${PROPS[$1]+x}" ]] || PROP_KEYS+=("$1")
    PROPS[$1]="$2"
}

has_prop_arg() {
    local p
    for p in "${PROP_ARGS[@]}"; do
        [[ "${p%%=*}" == "$1" ]] && return 0
    done
    return 1
}

build_properties() {
    local -a labels=(
        "none          tanpa preset"
        "linux         hw_qemu_guest_agent=yes, hw_disk_bus=virtio (+ os_distro/os_version)"
        "windows       os_type=windows, hw_qemu_guest_agent=yes"
        "windows-uefi  windows + hw_firmware_type=uefi, hw_machine_type=q35"
    )
    local -a presets=(none linux windows windows-uefi)
    local p answer

    if [[ -z "$PRESET" ]]; then
        if (( INTERACTIVE )); then
            menu_choice "Preset properties" none "${labels[@]}"
            PRESET="${presets[$MENU_IDX]}"
        else
            PRESET="none"
        fi
    fi

    case "$PRESET" in
        linux)
            set_prop hw_qemu_guest_agent yes
            set_prop hw_disk_bus virtio
            if (( INTERACTIVE )); then
                if ! has_prop_arg os_distro; then
                    ask answer "os_distro (opsional, mis. ubuntu, rhel, rocky): "
                    answer="$(trim "$answer")"
                    [[ -n "$answer" ]] && set_prop os_distro "$answer"
                fi
                if ! has_prop_arg os_version; then
                    ask answer "os_version (opsional, mis. 24.04, 9.4): "
                    answer="$(trim "$answer")"
                    [[ -n "$answer" ]] && set_prop os_version "$answer"
                fi
            fi
            ;;
        windows|windows-uefi)
            set_prop os_type windows
            set_prop hw_qemu_guest_agent yes
            if [[ "$PRESET" == "windows-uefi" ]]; then
                set_prop hw_firmware_type uefi
                set_prop hw_machine_type q35
            fi
            ;;
    esac

    # --property menimpa nilai preset
    for p in "${PROP_ARGS[@]}"; do
        set_prop "${p%%=*}" "${p#*=}"
    done

    log_event INPUT "preset=$PRESET" "properties=$(props_text)" "tags=$(IFS=,; printf '%s' "${TAGS[*]:-}")"
    return 0
}

props_text() {
    local k out=""
    for k in "${PROP_KEYS[@]}"; do
        out+="${out:+, }$k=${PROPS[$k]}"
    done
    printf '%s' "${out:--}"
}

# ============================================================
# 9. Ringkasan dan konfirmasi
# ============================================================

build_create_args() {
    local k t

    CREATE_ARGS=(image create --id "$IMAGE_ID" --disk-format "$UPLOAD_FORMAT"
                 --container-format "$CONTAINER_FORMAT" "--$VISIBILITY")
    [[ "$VISIBILITY" == "private" ]] && CREATE_ARGS+=(--project "$OWNER_ID")
    [[ -n "$MIN_DISK" ]] && CREATE_ARGS+=(--min-disk "$MIN_DISK")
    [[ -n "$MIN_RAM" ]] && CREATE_ARGS+=(--min-ram "$MIN_RAM")
    for k in "${PROP_KEYS[@]}"; do
        CREATE_ARGS+=(--property "$k=${PROPS[$k]}")
    done
    for t in "${TAGS[@]}"; do
        CREATE_ARGS+=(--tag "$t")
    done
    if [[ "$SRC_KIND" == "file" ]]; then
        CREATE_ARGS+=(--file "$UPLOAD_FILE" --progress)
    fi
    CREATE_ARGS+=(-f value -c id "$NAME")
    return 0
}

# Perintah sebagai teks shell; URL sumber disamarkan per argumen (sebelum quoting)
cmd_text() {
    local a out=""
    for a in "$@"; do
        out+=" $(printf '%q' "$(mask_text "$a")")"
    done
    out="${out//'\*\*\*'/***}"
    printf '%s' "${out# }"
}

print_cmd() {
    printf '  %s\n' "$(cmd_text "$@")"
}

show_summary() {
    local recip="-" i

    if (( ${#RECIPIENT_IDS[@]} > 0 )); then
        recip=""
        for i in "${!RECIPIENT_IDS[@]}"; do
            recip+="${recip:+, }${RECIPIENT_NAMES[$i]} (${RECIPIENT_IDS[$i]})"
        done
    fi

    echo
    echo "=============================================================="
    echo "                  Ringkasan Upload Image"
    echo "=============================================================="
    printf '%-17s: %s\n' "Region" "$REGION (auth: $AUTH_HOST)"
    if [[ "$SRC_KIND" == "file" ]]; then
        printf '%-17s: %s\n' "Sumber" "$SRC_FILE"
        printf '%-17s: %s\n' "Ukuran file" "$(size_text "$SRC_SIZE")"
    else
        printf '%-17s: %s\n' "Sumber (URL)" "$SRC_URL_SHOWN"
        printf '%-17s: %s\n' "Ukuran file" "tidak diketahui (diunduh oleh Glance)"
    fi
    if (( CONVERT )); then
        printf '%-17s: %s\n' "Disk format" "$DISK_FORMAT → raw (konversi qemu-img di $TMP_DIR)"
    else
        printf '%-17s: %s\n' "Disk format" "$DISK_FORMAT"
    fi
    printf '%-17s: %s\n' "Container format" "$CONTAINER_FORMAT"
    printf '%-17s: %s\n' "Virtual size" "$( [[ -n "$VIRTUAL_SIZE" ]] && fmt_size "$VIRTUAL_SIZE" || echo '-')"
    printf '%-17s: %s\n' "Nama" "$NAME"
    printf '%-17s: %s\n' "Visibility" "$VISIBILITY"
    printf '%-17s: %s\n' "Owner" "$OWNER_NAME ($OWNER_ID)"
    printf '%-17s: %s\n' "Project penerima" "$recip"
    printf '%-17s: %s\n' "Min disk" "${MIN_DISK:--}${MIN_DISK:+ GB}"
    printf '%-17s: %s\n' "Min RAM" "${MIN_RAM:--}${MIN_RAM:+ MB}"
    printf '%-17s: %s\n' "Preset" "$PRESET"
    printf '%-17s: %s\n' "Properties" "$(props_text)"
    printf '%-17s: %s\n' "Tags" "$(IFS=,; printf '%s' "${TAGS[*]:--}")"
    case "$DUP_ACTION" in
        none)     printf '%-17s: %s\n' "Nama duplikat" "tidak ada" ;;
        continue) printf '%-17s: %s\n' "Nama duplikat" "${#DUPS[@]} image, tetap lanjut (nama ganda)" ;;
        rotate)   printf '%-17s: %s\n' "Nama duplikat" "${#DUPS[@]} image, rotasi ${#ROT_IDS[@]} image lama setelah upload berhasil" ;;
    esac
    [[ -n "$CHECKSUM" ]] && printf '%-17s: %s\n' "Checksum" "$CHECKSUM"
    echo "=============================================================="
}

show_planned_commands() {
    local id_shown="$IMAGE_ID"

    echo
    echo "${C_BOLD}Perintah yang akan dijalankan:${C_RESET}"
    if (( CONVERT )); then
        print_cmd "$QEMU_IMG" convert -p -f "$(qemu_format "$DISK_FORMAT")" -O raw "$SRC_FILE" "$TMP_DIR/upload-img-XXXXXXXX.raw"
    fi
    print_cmd "${OS_CMD[@]}" "${CREATE_ARGS[@]}"
    if [[ "$SRC_KIND" == "url" ]]; then
        print_cmd "${OS_CMD[@]}" image import "$id_shown" --method web-download --uri "$SRC_URL"
    fi
    echo "  (polling: ${OS_CMD[*]} image show $id_shown -f json, sampai status active)"
    local i
    for i in "${!RECIPIENT_IDS[@]}"; do
        print_cmd "${OS_CMD[@]}" image add project "$id_shown" "${RECIPIENT_IDS[$i]}"
    done
    for i in "${ROT_IDS[@]}"; do
        if (( HIDDEN_OK )); then
            print_cmd "${OS_CMD[@]}" image set --name "$NAME-<YYYYMMDD>" --hidden "$i"
        else
            print_cmd "${OS_CMD[@]}" image set --name "$NAME-<YYYYMMDD>" "$i"
        fi
    done
}

confirm_upload() {
    local answer

    if [[ "$SRC_KIND" == "file" && -z "${TMUX:-}" && -z "${STY:-}" ]] && (( SRC_SIZE > LARGE_FILE )); then
        echo
        warn "Tidak berjalan di dalam tmux/screen dan file besar ($(fmt_size "$SRC_SIZE")): jika koneksi SSH putus, upload ikut berhenti."
    fi

    echo
    ask answer "Upload image ini ke region $REGION? [y/N]: "
    if ! is_yes "$answer"; then
        log_event DECISION decision=declined
        log_result resource=- action=upload-image result=DECLINED "name=$NAME" "region=$REGION" \
            "disk_format=$UPLOAD_FORMAT" "visibility=$VISIBILITY" "owner=$OWNER_ID" "msg=dibatalkan operator"
        echo "❌ Dibatalkan."
        exit 0
    fi
    log_event DECISION decision=upload "image_id=$IMAGE_ID"
}

# ============================================================
# 10. Upload dan pemantauan
# ============================================================

# Satu "image show -f json" => IMG_*. Return 0 = ada, 1 = tidak ditemukan, 2 = gagal dibaca
get_image() {
    local id="$1" json errf

    IMG_STATUS="-" IMG_NAME="-" IMG_DISK_FORMAT="-" IMG_SIZE="-" IMG_OWNER="-" IMG_VISIBILITY="-"
    IMG_HASH_ALGO="-" IMG_HASH_VALUE="-" IMG_CHECKSUM="-" IMG_FAILED_IMPORT="-"
    IMG_ERR=""

    errf="$(mktemp)"
    if ! json="$(os_cli image show "$id" -f json 2>"$errf")"; then
        IMG_ERR="$(last_error_line "$errf")"
        rm -f "$errf"
        if [[ "${IMG_ERR,,}" == *"${id,,}"* && "${IMG_ERR,,}" =~ no\ image|could\ not\ be\ found|not\ found|http\ 404 ]]; then
            return 1
        fi
        IMG_ERR="${IMG_ERR:-image show gagal tanpa pesan}"
        return 2
    fi
    rm -f "$errf"

    # os_hash_*, os_hidden, os_glance_* ada di .properties (OSC 7) atau top-level
    if ! IFS="$US" read -r IMG_STATUS IMG_NAME IMG_DISK_FORMAT IMG_SIZE IMG_OWNER IMG_VISIBILITY \
            IMG_HASH_ALGO IMG_HASH_VALUE IMG_CHECKSUM IMG_FAILED_IMPORT < <(
        jq -r '
            def v: if . == null or . == "" then "-" else tostring end;
            def p(k): (.properties[k]? // .[k]);
            [ .status, .name, .disk_format, .size, .owner, .visibility,
              p("os_hash_algo"), p("os_hash_value"), .checksum,
              p("os_glance_failed_import") ]
            | map(v) | join("\u001f")' <<< "$json" 2>/dev/null
    ); then
        IMG_ERR="output image show bukan JSON yang valid"
        return 2
    fi
    return 0
}

upload_file() {
    echo
    echo "⬆️  Upload ke Glance ($REGION), image ID $IMAGE_ID ..."
    PHASE="upload"
    UP_START=$SECONDS
    log_event UPLOAD_START "resource=$IMAGE_ID" "file=$UPLOAD_FILE" "disk_format=$UPLOAD_FORMAT"

    # stdout tidak ditangkap: bar progres --progress tampil langsung di terminal
    if ! os_run "${CREATE_ARGS[@]}"; then
        UP_DURATION=$(( SECONDS - UP_START ))
        upload_failed "upload gagal"
        return 1
    fi

    UP_DURATION=$(( SECONDS - UP_START ))
    log_event UPLOAD_END "resource=$IMAGE_ID" "duration=$UP_DURATION"
    return 0
}

import_url() {
    echo
    echo "⬆️  Membuat image $IMAGE_ID lalu import web-download dari $SRC_URL_SHOWN ..."
    PHASE="upload"
    UP_START=$SECONDS
    log_event UPLOAD_START "resource=$IMAGE_ID" "url=$SRC_URL_SHOWN" "disk_format=$UPLOAD_FORMAT"

    # stdin ditutup: tanpa --file, OSC membaca data image dari stdin jika bukan TTY
    if ! os_run "${CREATE_ARGS[@]}" <&-; then
        UP_DURATION=$(( SECONDS - UP_START ))
        upload_failed "image create gagal"
        return 1
    fi

    if ! os_run_masked image import "$IMAGE_ID" --method web-download --uri "$SRC_URL" > /dev/null; then
        UP_DURATION=$(( SECONDS - UP_START ))
        upload_failed "image import gagal"
        return 1
    fi

    log_event IMPORT_REQUESTED "resource=$IMAGE_ID" method=web-download
    return 0
}

upload_failed() {
    local what="$1" err
    local r id owner vis

    err="$(api_error)"
    RESULT_MSG="$what: $err"
    echo
    echo "${C_RED}❌ ${what^} di region $REGION: $err${C_RESET}"

    if [[ "${LOG_LAST_ERROR,,}" == *"more than one image exists"* ]]; then
        echo
        echo "${C_YELLOW}Upload ditolak karena ada lebih dari satu image bernama '$NAME' yang terlihat oleh credentials ini.${C_RESET}"
        echo "  Image ID yang disiapkan untuk upload ini : $IMAGE_ID (tidak dibuat)"
        echo "  Image lain dengan nama yang sama         :"
        for r in "${DUPS[@]}"; do
            IFS="$US" read -r id owner vis _ <<< "$r"
            echo "    - $id (owner $(project_name_of "$owner"), $vis)"
        done
        echo "  Gunakan nama lain, atau ganti nama/sembunyikan image lama lalu jalankan ulang."
        log_event DUPLICATE_REJECTED "resource=$IMAGE_ID" "name=$NAME" "duplicates=$(dup_ids)"
    fi

    offer_cleanup "$IMAGE_ID" 0
    log_upload_result FAILED
    return 0
}

dup_ids() {
    local r out=""
    for r in "${DUPS[@]}"; do
        out+="${out:+,}${r%%"$US"*}"
    done
    printf '%s' "$out"
}

log_upload_result() {
    local result="$1" hash="-"
    [[ "$IMG_HASH_VALUE" != "-" ]] && hash="$IMG_HASH_ALGO:$IMG_HASH_VALUE"
    log_result "resource=$IMAGE_ID" action=upload-image "result=$result" "name=$NAME" "region=$REGION" \
        "disk_format=$UPLOAD_FORMAT" "visibility=$VISIBILITY" "owner=$OWNER_ID" "size=${IMG_SIZE}" \
        "hash=$hash" "duration=$UP_DURATION" "msg=$RESULT_MSG"
}

# Polling sampai active (berhasil), killed/deleted/import gagal/timeout (gagal).
# Satu baris status diperbarui di tempat.
wait_active() {
    local deadline rc line cols last="" shown

    PHASE="wait"
    deadline=$(( SECONDS + TIMEOUT_SEC ))
    cols="$(term_cols)"

    while true; do
        rc=0
        get_image "$IMAGE_ID" || rc=$?

        if (( rc == 0 )); then
            shown="$IMG_STATUS"
            if [[ "$IMG_STATUS" != "$last" ]]; then
                log_event IMAGE_STATUS "resource=$IMAGE_ID" "status=$IMG_STATUS" "elapsed=$(( SECONDS - UP_START ))"
                last="$IMG_STATUS"
            fi
            case "$IMG_STATUS" in
                active)
                    printf '\r\e[K'
                    return 0
                    ;;
                killed|deleted|pending_delete)
                    printf '\r\e[K'
                    RESULT_MSG="status=$IMG_STATUS"
                    return 1
                    ;;
                queued)
                    if [[ "$SRC_KIND" == "url" && "$IMG_FAILED_IMPORT" != "-" ]]; then
                        printf '\r\e[K'
                        RESULT_MSG="import gagal (os_glance_failed_import=$IMG_FAILED_IMPORT)"
                        return 1
                    fi
                    ;;
            esac
        elif (( rc == 1 )); then
            printf '\r\e[K'
            RESULT_MSG="image tidak ditemukan lagi (dihapus?)"
            return 1
        else
            shown="? (gagal dibaca)"
            log_warn -q "image show $IMAGE_ID gagal saat polling: $IMG_ERR"
        fi

        line="[$NAME] status=$shown elapsed=$(fmt_elapsed $(( SECONDS - UP_START ))) (timeout $(fmt_timeout))"
        printf '\r\e[K%s' "${line:0:cols-1}"

        if (( SECONDS >= deadline )); then
            printf '\r\e[K'
            RESULT_MSG="timeout, last status=${last:-?}"
            return 1
        fi
        sleep "$INTERVAL"
    done
}

# ============================================================
# 11. Verifikasi
# ============================================================

# Return 0 = cocok/warning, 1 = gagal (mismatch dengan format yang sama)
verify_image() {
    local algo want got local_size format_changed=0 problems="" note_txt=""

    get_image "$IMAGE_ID" || true
    [[ "$IMG_DISK_FORMAT" != "$UPLOAD_FORMAT" ]] && format_changed=1

    echo
    echo "🔎 Verifikasi:"

    if [[ "$SRC_KIND" == "file" ]]; then
        local_size="$(file_size "$UPLOAD_FILE")" || local_size="-"
        if [[ "$IMG_SIZE" == "$local_size" ]]; then
            echo "   size : cocok ($IMG_SIZE bytes)"
        else
            echo "   size : BERBEDA (Glance $IMG_SIZE, lokal $local_size)"
            problems+="size mismatch; "
        fi

        algo="$IMG_HASH_ALGO"
        want="$IMG_HASH_VALUE"
        if [[ "$algo" == "-" || "$want" == "-" ]]; then
            if [[ "$IMG_CHECKSUM" != "-" ]]; then
                algo="md5"
                want="$IMG_CHECKSUM"
            fi
        fi

        if [[ "$algo" =~ ^(md5|sha1|sha224|sha256|sha384|sha512)$ ]] && command -v "${algo}sum" >/dev/null 2>&1; then
            echo "   Menghitung $algo file lokal ($(fmt_size "$local_size"))..."
            got="$("${algo}sum" -- "$UPLOAD_FILE" | cut -d' ' -f1)" || got="-"
            if [[ "$got" == "$want" ]]; then
                echo "   hash : cocok ($algo)"
            else
                echo "   hash : BERBEDA ($algo; Glance $want, lokal $got)"
                problems+="checksum mismatch; "
            fi
            log_event VERIFY "resource=$IMAGE_ID" "algo=$algo" "glance=$want" "local=$got" \
                "glance_size=$IMG_SIZE" "local_size=$local_size"
        else
            note_txt="hash tidak diverifikasi (algoritma Glance: $algo)"
            echo "   hash : $note_txt"
        fi
    else
        echo "   size : $IMG_SIZE bytes (tidak ada pembanding lokal untuk URL)"
        if [[ -n "$CHECKSUM" ]]; then
            algo="${CHECKSUM%%:*}"
            want="${CHECKSUM#*:}"
            got="-"
            if [[ "$algo" == "md5" ]]; then
                got="$IMG_CHECKSUM"
            elif [[ "$algo" == "$IMG_HASH_ALGO" ]]; then
                got="$IMG_HASH_VALUE"
            fi
            if [[ "$got" == "-" ]]; then
                note_txt="--checksum $algo tidak bisa dibandingkan (Glance memakai ${IMG_HASH_ALGO})"
                echo "   hash : $note_txt"
            elif [[ "$got" == "$want" ]]; then
                echo "   hash : cocok dengan --checksum ($algo)"
            else
                echo "   hash : BERBEDA dari --checksum ($algo; Glance $got, harap $want)"
                problems+="checksum mismatch; "
            fi
            log_event VERIFY "resource=$IMAGE_ID" "algo=$algo" "glance=$got" "expected=$want"
        else
            note_txt="hash tidak diverifikasi (tanpa --checksum)"
            echo "   hash : $note_txt (Glance $IMG_HASH_ALGO:$IMG_HASH_VALUE)"
        fi
    fi

    problems="${problems%; }"
    if [[ -z "$problems" ]]; then
        VERIFY_NOTE="${note_txt:-ok}"
        RESULT_MSG="$note_txt"
        return 0
    fi

    if (( format_changed )); then
        VERIFY_NOTE="$problems; disk_format diubah Glance $UPLOAD_FORMAT → $IMG_DISK_FORMAT (konversi saat import)"
        RESULT_MSG="$VERIFY_NOTE"
        warn "Hash/size berbeda, tetapi Glance mengubah disk_format $UPLOAD_FORMAT → $IMG_DISK_FORMAT (kemungkinan konversi saat import di region $REGION). Dicatat sebagai warning."
        return 0
    fi

    VERIFY_NOTE="$problems"
    RESULT_MSG="$problems"
    return 1
}

# ============================================================
# 12. Sharing dan rotasi
# ============================================================

share_image() {
    local i pid pname json st
    local -A status=()

    (( ${#RECIPIENT_IDS[@]} > 0 )) || return 0
    PHASE="share"

    echo
    echo "🤝 Sharing ke ${#RECIPIENT_IDS[@]} project:"
    for i in "${!RECIPIENT_IDS[@]}"; do
        pid="${RECIPIENT_IDS[$i]}"
        pname="${RECIPIENT_NAMES[$i]}"
        if os_run image add project "$IMAGE_ID" "$pid" -f json > /dev/null; then
            echo "   ✅ $pname ($pid)"
            log_result "resource=$IMAGE_ID" action=share-image result=SUCCESS "project=$pid" \
                "project_name=$pname" "msg=member pending"
        else
            echo "   ${C_RED}❌ $pname ($pid): $(api_error)${C_RESET}"
            log_result "resource=$IMAGE_ID" action=share-image result=FAILED "project=$pid" \
                "project_name=$pname" "msg=$(api_error)"
        fi
    done

    # Status member: pending sampai project penerima menerima. OSC tidak punya
    # perintah untuk mengubah status member project lain tanpa mengubah owner
    # image ("image set --accept --project" juga mengganti owner), jadi
    # penerimaan dilakukan oleh project penerima sendiri.
    if json="$(os_cli image member list "$IMAGE_ID" -f json 2>/dev/null)"; then
        while IFS="$US" read -r pid st; do
            [[ -n "$pid" ]] && status[$pid]="$st"
        done < <(jq -r '.[] | [."Member ID", .Status] | map(tostring) | join("\u001f")' <<< "$json" 2>/dev/null)
    fi

    for i in "${!RECIPIENT_IDS[@]}"; do
        pid="${RECIPIENT_IDS[$i]}"
        MEMBER_INFO+=("${RECIPIENT_NAMES[$i]} ($pid): ${status[$pid]:-tidak diketahui}")
    done

    echo
    note "Member image berstatus 'pending' sampai project penerima menerimanya. Jalankan dengan"
    note "credentials project penerima: openstack image set --accept $IMAGE_ID"
    log_event MEMBER_PENDING "resource=$IMAGE_ID" "instruction=openstack image set --accept $IMAGE_ID" \
        "members=$(IFS=,; printf '%s' "${RECIPIENT_IDS[*]}")"
    return 0
}

# Nama rotasi unik: NAMA-YYYYMMDD, lalu -2, -3, ... => ROT_NAME
rotation_name() {
    local created="$1" base cand n=1 rows
    local d="${created:0:10}"
    d="${d//-/}"
    [[ "$d" =~ ^[0-9]{8}$ ]] || d="$(date +%Y%m%d)"
    base="$NAME-$d"
    cand="$base"
    while (( n < 50 )); do
        rows="$(list_by_name "$cand")" || rows=""
        [[ -z "$rows" && " ${ROT_USED[*]:-} " != *" $cand "* ]] && break
        n=$(( n + 1 ))
        cand="$base-$n"
    done
    ROT_USED+=("$cand")
    ROT_NAME="$cand"
}

rotate_images() {
    local r id created newname
    local -a args=()
    ROT_USED=()

    (( ${#ROT_IDS[@]} > 0 )) || return 0
    PHASE="rotate"

    echo
    echo "🔁 Rotasi image lama:"
    for r in "${DUPS[@]}"; do
        IFS="$US" read -r id _ _ _ created _ <<< "$r"
        [[ " ${ROT_IDS[*]} " == *" $id "* ]] || continue
        rotation_name "$created"
        newname="$ROT_NAME"
        args=(image set --name "$newname")
        (( HIDDEN_OK )) && args+=(--hidden)
        args+=("$id")
        if os_run "${args[@]}"; then
            echo "   ✅ $id → $newname$( (( HIDDEN_OK )) && echo ' (hidden)')"
            log_result "resource=$id" action=rotate-image result=SUCCESS "new_name=$newname" \
                "hidden=$HIDDEN_OK" "new_image=$IMAGE_ID"
            ROTATED+=("$id$US$newname${US}SUCCESS")
        else
            echo "   ${C_RED}❌ $id: $(api_error)${C_RESET}"
            log_result "resource=$id" action=rotate-image result=FAILED "new_name=$newname" "msg=$(api_error)"
            ROTATED+=("$id$US$newname${US}FAILED")
        fi
    done
    return 0
}

# ============================================================
# 13. Cleanup
# ============================================================

# offer_cleanup ID TIMEOUT [any] — tawarkan hapus image yang tertinggal.
# TIMEOUT > 0 dipakai dari hook interrupt (tidak boleh menunggu selamanya).
# "any": juga untuk image active (checksum mismatch).
offer_cleanup() {
    local id="$1" timeout="$2" mode="${3:-}" rc=0 answer prompt

    get_image "$id" || rc=$?
    if (( rc == 1 )); then
        echo "ℹ️  Tidak ada image yang tertinggal ($id)."
        log_info "cleanup: image $id tidak ada"
        return 0
    elif (( rc != 0 )); then
        warn "Status image $id tidak bisa dibaca ($IMG_ERR). Periksa manual: openstack image show $id"
        log_result "resource=$id" action=cleanup-image result=SKIPPED "msg=status tidak terbaca: $IMG_ERR"
        return 0
    fi

    if [[ "$mode" != "any" && ! "$IMG_STATUS" =~ ^(queued|saving|importing|uploading|killed)$ ]]; then
        log_info "cleanup: image $id status=$IMG_STATUS, tidak ditawarkan"
        return 0
    fi

    prompt="Hapus image $id (status $IMG_STATUS)? [y/N]: "
    echo
    if (( timeout > 0 )); then
        ask_timeout answer "$timeout" "$prompt"
        echo
    else
        ask answer "$prompt"
    fi

    if ! is_yes "$answer"; then
        log_event DECISION "resource=$id" cleanup=no
        log_result "resource=$id" action=cleanup-image result=DECLINED "status=$IMG_STATUS" "msg=dibiarkan operator"
        echo "ℹ️  Image dibiarkan. Hapus manual: openstack image delete $id"
        return 0
    fi

    log_event DECISION "resource=$id" cleanup=yes
    if os_run image delete "$id"; then
        echo "🗑️  Image $id dihapus."
        log_result "resource=$id" action=cleanup-image result=SUCCESS "status=$IMG_STATUS"
    else
        echo "${C_RED}❌ Gagal menghapus $id: $(api_error)${C_RESET}"
        log_result "resource=$id" action=cleanup-image result=FAILED "status=$IMG_STATUS" "msg=$(api_error)"
    fi
    return 0
}

# Dipanggil lib/logging.sh saat SIGINT/SIGTERM (sebelum exit 130/143)
on_interrupt() {
    local sig="$1"

    printf '\r\e[K\n'
    case "$PHASE" in
        convert)
            echo "${C_YELLOW}⚠️  Konversi dihentikan ($sig); file sementara dihapus.${C_RESET}"
            log_result resource=- action=upload-image result=ABORTED "name=$NAME" "region=$REGION" \
                "msg=konversi dihentikan ($sig)"
            ;;
        upload|wait)
            UP_DURATION=$(( SECONDS - UP_START ))
            RESULT_MSG="dihentikan ($sig) saat $PHASE"
            echo "${C_YELLOW}⚠️  Upload dihentikan ($sig). Image ID: $IMAGE_ID${C_RESET}"
            [[ "$SRC_KIND" == "url" && "$PHASE" == "wait" ]] && \
                echo "   Import web-download mungkin tetap berjalan di Glance."
            log_upload_result ABORTED
            offer_cleanup "$IMAGE_ID" 60
            ;;
        *)
            log_event INTERRUPT "signal=$sig" "phase=$PHASE"
            ;;
    esac
    return 0
}

# ============================================================
# Ringkasan akhir
# ============================================================

print_final() {
    local m r id newname result

    echo
    echo "=============================================================="
    echo "                  Hasil Upload Image"
    echo "=============================================================="
    printf '%-17s: %s\n' "Image ID" "$IMAGE_ID"
    printf '%-17s: %s\n' "Nama" "$IMG_NAME"
    printf '%-17s: %s\n' "Status" "$IMG_STATUS"
    printf '%-17s: %s\n' "Disk format" "$IMG_DISK_FORMAT"
    printf '%-17s: %s\n' "Visibility" "$IMG_VISIBILITY"
    printf '%-17s: %s\n' "Owner" "$(project_name_of "$IMG_OWNER") ($IMG_OWNER)"
    if (( ${#MEMBER_INFO[@]} > 0 )); then
        printf '%-17s:\n' "Project penerima"
        for m in "${MEMBER_INFO[@]}"; do
            echo "   - $m"
        done
    fi
    printf '%-17s: %s\n' "Hash" "$IMG_HASH_ALGO:$IMG_HASH_VALUE"
    printf '%-17s: %s\n' "Size" "$(size_text "$IMG_SIZE")"
    printf '%-17s: %s\n' "Verifikasi" "$VERIFY_NOTE"
    printf '%-17s: %s\n' "Durasi upload" "${UP_DURATION}s"
    for r in "${ROTATED[@]}"; do
        IFS="$US" read -r id newname result <<< "$r"
        printf '%-17s: %s\n' "Rotasi" "$id → $newname ($result)"
    done
    printf '%-17s: %s\n' "Log" "${LOG_FILE:-(logging nonaktif)}"
    echo "=============================================================="

    # Nama ganda dibiarkan: tampilkan ID upload ini dan ID image lain bernama sama
    if [[ "$DUP_ACTION" != "none" ]]; then
        local -a others=()
        local owner vis
        for r in "${DUPS[@]}"; do
            IFS="$US" read -r id owner vis _ <<< "$r"
            [[ "$DUP_ACTION" == "rotate" && " ${ROT_IDS[*]} " == *" $id "* ]] && continue
            others+=("$id (owner $(project_name_of "$owner"), $vis)")
        done
        if (( ${#others[@]} > 0 )); then
            echo
            echo "${C_YELLOW}ℹ️  Ada image lain dengan nama '$NAME':${C_RESET}"
            echo "   Image yang Anda upload : $IMAGE_ID"
            for m in "${others[@]}"; do
                echo "   Nama sama              : $m"
            done
            echo "   Gunakan image ID (bukan nama) saat membuat instance/volume."
        fi
    fi
}

# ============================================================
# Main
# ============================================================

main() {
    parse_args "$@"
    require_deps

    echo "========================================"
    echo "            Upload Image"
    echo "========================================"

    log_event OPTIONS "dry_run=$DRY_RUN" "interactive=$INTERACTIVE" "interval=$INTERVAL" \
        "timeout_s=$TIMEOUT_SEC" "tmp_dir=$TMP_DIR" "os_cmd=${OS_CMD[*]}" "qemu_img=$QEMU_IMG"

    LOG_EXIT_HOOK=on_exit

    detect_capabilities
    select_source
    select_name
    select_format
    check_local_checksum
    read_virtual_size
    offer_convert
    select_min_values
    select_visibility
    check_duplicates
    build_properties

    UPLOAD_FILE="$SRC_FILE"
    if (( DRY_RUN )); then
        IMAGE_ID="<uuid-baru>"
        (( CONVERT )) && UPLOAD_FILE="$TMP_DIR/upload-img-XXXXXXXX.raw"
    else
        new_uuid
    fi
    build_create_args
    show_summary

    if (( DRY_RUN )); then
        show_planned_commands
        log_info "PLAN dry_run=true name=\"$NAME\" region=$REGION source=$SRC_KIND disk_format=$UPLOAD_FORMAT visibility=$VISIBILITY owner=$OWNER_ID convert=$CONVERT duplicate=$DUP_ACTION"
        log_info "PLAN dry_run=true CMD $(cmd_text "${OS_CMD[@]}" "${CREATE_ARGS[@]}")"
        if [[ "$SRC_KIND" == "url" ]]; then
            log_info "PLAN dry_run=true CMD $(cmd_text "${OS_CMD[@]}" image import "$IMAGE_ID" --method web-download --uri "$SRC_URL")"
        fi
        echo
        echo "Dry-run: tidak ada konversi, upload, sharing, atau rotasi."
        echo "Log : ${LOG_FILE:-(logging nonaktif)}"
        return 0
    fi

    confirm_upload
    LOG_INTERRUPT_HOOK=on_interrupt

    if (( CONVERT )); then
        convert_raw || exit 1
        build_create_args
    fi

    if [[ "$SRC_KIND" == "file" ]]; then
        upload_file || exit 1
    else
        import_url || exit 1
    fi

    if ! wait_active; then
        UP_DURATION=$(( SECONDS - UP_START ))
        echo "${C_RED}❌ Upload gagal di region $REGION: $RESULT_MSG${C_RESET}"
        offer_cleanup "$IMAGE_ID" 0
        log_upload_result FAILED
        exit 1
    fi
    UP_DURATION=$(( SECONDS - UP_START ))
    echo "${C_GREEN}✅ Image active (${UP_DURATION}s).${C_RESET}"

    PHASE="verify"
    if ! verify_image; then
        echo "${C_RED}❌ FAILED ($RESULT_MSG)${C_RESET}"
        log_upload_result FAILED
        offer_cleanup "$IMAGE_ID" 0 any
        LOG_INTERRUPT_HOOK=""
        exit 1
    fi
    log_upload_result SUCCESS

    share_image
    rotate_images
    LOG_INTERRUPT_HOOK=""

    get_image "$IMAGE_ID" || true
    print_final

    log_event SUMMARY "resource=$IMAGE_ID" "name=$NAME" "status=$IMG_STATUS" \
        "shared=${#RECIPIENT_IDS[@]}" "rotated=${#ROTATED[@]}" "verify=$VERIFY_NOTE"
    return 0
}

main "$@"
