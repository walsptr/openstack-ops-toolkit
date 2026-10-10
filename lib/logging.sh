#!/bin/bash
# ============================================================
# OpenStack Ops Toolkit - shared logging library
# ============================================================
#
# Di-source oleh operational scripts dan main.sh (tidak dijalankan
# langsung, tidak punya @name, dan lib/ tidak ikut discovery).
#
#   log_init                       mulai logging script (START + trap END)
#   log_info  [-q] MSG             INFO ke file
#   log_warn  [-q] MSG             WARN ke file + stderr (-q: file saja)
#   log_error [-q] MSG             ERROR ke file + stderr (-q: file saja)
#   log_event EVENT key=value...   event terstruktur (nilai di-quote otomatis)
#   log_result key=value...        hasil aksi per resource (wajib result=)
#   log_cmd CMD ARGS...            catat perintah yang akan dijalankan
#   log_run CMD ARGS...            log_cmd + jalankan; stderr ditampilkan
#                                  dan disimpan di LOG_LAST_ERROR
#
# Format baris:
#   <ISO8601+TZ> <LEVEL> run=<run_id> user=<operator> <pesan>
#
# Lokasi: $OSOPS_LOG_DIR > $LOG_DIR > <toolkit root>/log, fallback ke
# ${XDG_STATE_HOME:-$HOME/.local/state}/openstack-ops-toolkit/log.
# Kegagalan logging tidak pernah menggagalkan script.
#
# Nilai variabel env yang namanya mengandung PASSWORD/SECRET/TOKEN
# disensor (***) dari setiap baris log.

[[ -n "${_OSOPS_LOGGING_LOADED:-}" ]] && return 0
_OSOPS_LOGGING_LOADED=1

LOG_RESULT_VALUES="SUCCESS FAILED SKIPPED DECLINED ABORTED"

_LOG_FILE=""
_LOG_TOOLKIT_FILE=""
_LOG_RUN_ID=""
_LOG_OPERATOR=""
_LOG_START=0
_LOG_SIGNAL=""
_LOG_FALLBACK_WARNED=0
LOG_LAST_ERROR=""

# Root toolkit: OSOPS_HOME (diset main.sh) atau parent dari lib/
if [[ -z "${OSOPS_HOME:-}" ]]; then
    OSOPS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
fi

# ============================================================
# Internal helpers
# ============================================================

_log_ts() {
    date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

log_new_run_id() {
    printf '%(%Y%m%dT%H%M%S)T-%d-%04x\n' -1 "$$" "$RANDOM"
}

_log_operator() {
    printf '%s' "${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"
}

# Sensor nilai variabel env rahasia, lalu escape agar satu event tetap
# satu baris (\ -> \\, newline -> \n, CR -> \r). Hasil di _LOG_S.
_log_clean() {
    local name val

    _LOG_S="$1"

    for name in $(compgen -e); do
        [[ "${name^^}" =~ PASSWORD|SECRET|TOKEN ]] || continue
        val="${!name-}"
        (( ${#val} >= 3 )) || continue
        _LOG_S="${_LOG_S//"$val"/***}"
    done

    _LOG_S="${_LOG_S//\\/\\\\}"
    _LOG_S="${_LOG_S//$'\n'/\\n}"
    _LOG_S="${_LOG_S//$'\r'/\\r}"
}

# Nilai key=value: di-quote jika kosong atau berisi spasi/kutip/=. Hasil di _LOG_S.
_log_kv_value() {
    _log_clean "$1"

    if [[ -z "$_LOG_S" || "$_LOG_S" == *[[:space:]\"=]* ]]; then
        _LOG_S="\"${_LOG_S//\"/\\\"}\""
    fi
}

# _log_write FILE LEVEL MSG [raw]  ("raw": MSG sudah dibersihkan via _log_kv_value)
_log_write() {
    local file="$1" level="$2"

    [[ -n "$file" ]] || return 0

    if [[ "${4:-}" == "raw" ]]; then
        _LOG_S="$3"
    else
        _log_clean "$3"
    fi

    {
        printf '%s %s run=%s user=%s %s\n' \
            "$(_log_ts)" "$level" "${_LOG_RUN_ID:--}" "${_LOG_OPERATOR:--}" "$_LOG_S" >> "$file"
    } 2>/dev/null || true

    return 0
}

# Siapkan file log (buat direktori & file dengan umask 002 agar
# anggota group tetap bisa menulis). Return 0 jika bisa ditulis.
_log_prepare_file() {
    local file="$1"

    (
        umask 002
        mkdir -p "$(dirname "$file")" && : >> "$file"
    ) 2>/dev/null || return 1

    [[ -w "$file" ]]
}

_log_fallback_dir() {
    printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/openstack-ops-toolkit/log"
}

# Tentukan LOG_DIR dan siapkan file "$LOG_DIR/<subpath>".
# Output path file di _LOG_S; return 1 jika logging tidak mungkin.
_log_setup() {
    local sub="$1"
    local primary fallback

    primary="${OSOPS_LOG_DIR:-${LOG_DIR:-$OSOPS_HOME/log}}"

    if _log_prepare_file "$primary/$sub"; then
        LOG_DIR="$primary"
        _LOG_S="$primary/$sub"
        return 0
    fi

    fallback="$(_log_fallback_dir)"

    if [[ "$fallback" != "$primary" ]] && _log_prepare_file "$fallback/$sub"; then
        if (( ! _LOG_FALLBACK_WARNED )); then
            echo "⚠️  Direktori log tidak bisa ditulis: $primary — log dialihkan ke $fallback" >&2
            _LOG_FALLBACK_WARNED=1
        fi
        LOG_DIR="$fallback"
        _LOG_S="$fallback/$sub"
        return 0
    fi

    if (( ! _LOG_FALLBACK_WARNED )); then
        echo "⚠️  Direktori log tidak bisa ditulis ($primary, $fallback) — logging nonaktif." >&2
        _LOG_FALLBACK_WARNED=1
    fi
    return 1
}

# ============================================================
# Public API
# ============================================================

# Konteks OpenStack aktif (tanpa secret) sebagai argumen key=value
# di array LOG_CTX, untuk log_event / log_toolkit.
log_os_context_args() {
    local host="${OS_AUTH_URL:--}"
    host="${host#*://}"
    host="${host%%/*}"

    LOG_CTX=(
        "os_user=${OS_USERNAME:-${OS_USER_ID:--}}"
        "os_project=${OS_PROJECT_NAME:-${OS_PROJECT_ID:--}}"
        "os_region=${OS_REGION_NAME:--}"
        "os_auth_host=${host:--}"
    )
}

log_init() {
    local script="${1:-${BASH_SOURCE[1]:-$0}}"
    local home rel category name

    _LOG_OPERATOR="$(_log_operator)"
    _LOG_RUN_ID="${OSOPS_RUN_ID:-$(log_new_run_id)}"
    _LOG_START="$(date +%s)"

    script="$(realpath -- "$script" 2>/dev/null || printf '%s' "$script")"
    home="$(realpath -- "$OSOPS_HOME" 2>/dev/null || printf '%s' "$OSOPS_HOME")"

    # Kategori = direktori pertama relatif terhadap root toolkit
    if [[ "$script" == "$home"/*/* ]]; then
        rel="${script#"$home"/}"
        category="${rel%%/*}"
    else
        rel="$script"
        category="custom"
    fi

    name="$(basename "$script" .sh)"

    if _log_setup "$category/$name-$(date +%Y%m%d).log"; then
        _LOG_FILE="$_LOG_S"
    else
        _LOG_FILE=""
    fi

    log_os_context_args
    log_event START "script=$rel" "pid=$$" "${LOG_CTX[@]}"

    trap '_log_on_exit' EXIT
    trap '_log_on_signal INT' INT
    trap '_log_on_signal TERM' TERM

    return 0
}

_log_on_signal() {
    _LOG_SIGNAL="$1"

    if [[ "$1" == "INT" ]]; then
        echo >&2
        exit 130
    fi
    exit 143
}

_log_on_exit() {
    local rc=$?
    local end duration

    end="$(date +%s)"
    duration=$(( end - ${_LOG_START:-end} ))

    if [[ -n "$_LOG_SIGNAL" ]]; then
        _log_write "$_LOG_FILE" WARN "END rc=$rc duration=${duration}s signal=$_LOG_SIGNAL"
    elif (( rc == 0 )); then
        _log_write "$_LOG_FILE" INFO "END rc=$rc duration=${duration}s"
    else
        _log_write "$_LOG_FILE" ERROR "END rc=$rc duration=${duration}s"
    fi
}

log_info() {
    [[ "${1:-}" == "-q" ]] && shift
    _log_write "$_LOG_FILE" INFO "$*"
}

log_warn() {
    local quiet=0
    [[ "${1:-}" == "-q" ]] && { quiet=1; shift; }
    (( quiet )) || echo "⚠️  $*" >&2
    _log_write "$_LOG_FILE" WARN "$*"
}

log_error() {
    local quiet=0
    [[ "${1:-}" == "-q" ]] && { quiet=1; shift; }
    (( quiet )) || echo "❌ $*" >&2
    _log_write "$_LOG_FILE" ERROR "$*"
}

# log_event EVENT key=value... (argumen tanpa '=' dicatat sebagai msg=)
_log_kv_line() {
    local out="$1" arg key
    shift

    for arg in "$@"; do
        if [[ "$arg" == *=* ]]; then
            key="${arg%%=*}"
            _log_kv_value "${arg#*=}"
        else
            key="msg"
            _log_kv_value "$arg"
        fi
        out+=" $key=$_LOG_S"
    done

    _LOG_LINE="$out"
}

log_event() {
    _log_kv_line "$@"
    _log_write "$_LOG_FILE" INFO "$_LOG_LINE" raw
}

# log_result resource=<id> action=<aksi> result=<RESULT> [key=value...]
log_result() {
    local -a args=()
    local arg result="" level="INFO"

    for arg in "$@"; do
        if [[ "$arg" == result=* ]]; then
            result="${arg#result=}"
            result="${result^^}"

            if [[ " $LOG_RESULT_VALUES " != *" $result "* ]]; then
                _log_write "$_LOG_FILE" WARN "log_result: result tidak valid '${result}', dicatat sebagai FAILED"
                result="FAILED"
            fi
            arg="result=$result"
        fi
        args+=("$arg")
    done

    if [[ -z "$result" ]]; then
        _log_write "$_LOG_FILE" WARN "log_result: result tidak diisi, dicatat sebagai FAILED"
        result="FAILED"
        args+=("result=FAILED")
    fi

    [[ "$result" == "FAILED" || "$result" == "ABORTED" ]] && level="ERROR"

    _log_kv_line RESULT "${args[@]}"
    _log_write "$_LOG_FILE" "$level" "$_LOG_LINE" raw
}

log_cmd() {
    local out="CMD" arg

    for arg in "$@"; do
        _log_kv_value "$arg"
        out+=" $_LOG_S"
    done

    _log_write "$_LOG_FILE" INFO "$out" raw
}

# Jalankan perintah non-interaktif. stdout tetap ke terminal; stderr
# ditampilkan setelah perintah selesai dan disimpan (ringkas) di
# LOG_LAST_ERROR untuk log_result msg=. Return code = rc perintah.
log_run() {
    local errfile rc

    log_cmd "$@"
    LOG_LAST_ERROR=""

    if ! errfile="$(mktemp 2>/dev/null)"; then
        "$@"
        return
    fi

    rc=0
    "$@" 2>"$errfile" || rc=$?

    cat "$errfile" >&2 2>/dev/null || true
    LOG_LAST_ERROR="$(tail -n 5 "$errfile" 2>/dev/null | cut -c1-500)"
    rm -f "$errfile"

    return "$rc"
}

# ============================================================
# Launcher (main.sh) → $LOG_DIR/toolkit.log
# ============================================================

log_toolkit_init() {
    _LOG_OPERATOR="$(_log_operator)"
    _LOG_RUN_ID="${_LOG_RUN_ID:-$(log_new_run_id)}"

    if _log_setup "toolkit.log"; then
        _LOG_TOOLKIT_FILE="$_LOG_S"
        return 0
    fi

    _LOG_TOOLKIT_FILE=""
    return 1
}

# log_toolkit LEVEL EVENT key=value...
log_toolkit() {
    local level="$1"
    shift
    _log_kv_line "$@"
    _log_write "$_LOG_TOOLKIT_FILE" "$level" "$_LOG_LINE" raw
}
