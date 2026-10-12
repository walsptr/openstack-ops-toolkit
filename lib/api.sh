#!/bin/bash
# shellcheck disable=SC2034  # variabel API_* dibaca oleh script pemanggil
# ============================================================
# OpenStack Ops Toolkit - shared helper for direct API access (curl)
# ============================================================
#
# Di-source oleh operational scripts SETELAH lib/logging.sh (tidak punya
# @name, lib/ tidak ikut discovery). Script pemanggil wajib mendefinisikan
# os_cli (wrapper OpenStack CLI) dan mengisi API_WORK_DIR (direktori
# sementara milik script, mis. mktemp -d; dihapus oleh script lewat
# LOG_EXIT_HOOK).
#
#   api_setup SERVICE [SUFFIX]   endpoint dari "catalog show SERVICE" sesuai
#                                OS_REGION_NAME + OS_INTERFACE (default public),
#                                token dari "token issue", opsi TLS curl.
#                                SUFFIX (mis. /v2.0) ditambahkan jika URL belum
#                                diakhiri versi itu. Return 1 = API tidak bisa
#                                dipakai (alasan di API_REASON). Hasil di-cache.
#   api_get URL OUT              GET satu URL ke file OUT
#   api_collect PATH QUERY KEY OUT
#                                GET API_ENDPOINT/PATH?QUERY, ikuti pagination
#                                (KEY_links rel=next), gabungkan array KEY ke OUT
#
# Variabel: API_ENDPOINT, API_REASON, API_HEADERS (array header tambahan,
# mis. "OpenStack-API-Version: compute 2.47"), API_CURL (default
# $OSOPS_CURL atau curl).
#
# Keamanan: token TIDAK PERNAH muncul di argumen proses (terlihat di ps),
# di file, atau di log — dikirim ke curl sebagai config lewat stdin (-K -).
# Fungsi di sini tidak memanggil exit/die; pemanggil yang memutuskan
# (mis. fallback ke metode cli).

[[ -n "${_OSOPS_API_LOADED:-}" ]] && return 0
_OSOPS_API_LOADED=1

API_CURL="${OSOPS_CURL:-curl}"
API_WORK_DIR="${API_WORK_DIR:-}"
API_HEADERS=()
API_ENDPOINT=""
API_REASON=""
API_PAGES=0

_API_SERVICE=""
_API_STATE=""        # "" = belum dicoba | ok | fail (untuk _API_SERVICE)
_API_TOKEN=""
_API_CURL_OPTS=()

_api_last_line() {
    grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | cut -c1-300
}

api_curl_available() {
    command -v "$API_CURL" >/dev/null 2>&1
}

api_setup() {
    local service="$1" suffix="${2:-}" json errf iface

    if [[ "$service" == "$_API_SERVICE" ]]; then
        case "$_API_STATE" in
            ok)   return 0 ;;
            fail) return 1 ;;
        esac
    fi
    _API_SERVICE="$service"
    _API_STATE="fail"
    API_ENDPOINT=""

    if ! api_curl_available; then
        API_REASON="curl tidak tersedia"
        return 1
    fi
    if [[ -z "$API_WORK_DIR" || ! -d "$API_WORK_DIR" ]]; then
        API_REASON="API_WORK_DIR belum diset"
        return 1
    fi

    iface="${OS_INTERFACE:-${OS_ENDPOINT_TYPE:-public}}"
    iface="${iface%URL}"
    iface="${iface,,}"

    errf="$API_WORK_DIR/api-catalog.err"
    if ! json="$(os_cli catalog show "$service" -f json 2>"$errf")"; then
        API_REASON="catalog show $service gagal: $(_api_last_line "$errf")"
        return 1
    fi
    API_ENDPOINT="$(jq -r --arg r "${OS_REGION_NAME:-}" --arg i "$iface" '
        [ (.endpoints // [])[]
          | select((.interface // "") == $i)
          | select($r == "" or (.region_id // .region // "") == $r) ] as $e
        | if ($e | length) == 1 or (($e | length) > 1 and $r != "") then $e[0].url
          elif ($e | length) > 1 and ([ $e[] | (.region_id // .region) ] | unique | length) == 1 then $e[0].url
          else empty end' <<< "$json" 2>/dev/null)" || API_ENDPOINT=""
    if [[ -z "$API_ENDPOINT" ]]; then
        API_REASON="endpoint $service (interface=$iface, region=${OS_REGION_NAME:--}) tidak ditemukan di catalog"
        return 1
    fi
    API_ENDPOINT="${API_ENDPOINT%/}"
    if [[ -n "$suffix" && "$API_ENDPOINT" != *"$suffix" ]]; then
        API_ENDPOINT="$API_ENDPOINT$suffix"
    fi

    if [[ -z "$_API_TOKEN" ]]; then
        errf="$API_WORK_DIR/api-token.err"
        if ! json="$(os_cli token issue -f json 2>"$errf")"; then
            API_REASON="token issue gagal: $(_api_last_line "$errf")"
            return 1
        fi
        _API_TOKEN="$(jq -r '.id // empty' <<< "$json" 2>/dev/null)" || _API_TOKEN=""
        json=""
        if [[ -z "$_API_TOKEN" ]]; then
            API_REASON="token issue tidak mengembalikan token"
            return 1
        fi
    fi

    _API_CURL_OPTS=(--silent --show-error --fail --connect-timeout 15 --max-time 300)
    [[ -n "${OS_CACERT:-}" ]] && _API_CURL_OPTS+=(--cacert "$OS_CACERT")
    [[ -n "${OS_CERT:-}" ]] && _API_CURL_OPTS+=(--cert "$OS_CERT")
    [[ -n "${OS_KEY:-}" ]] && _API_CURL_OPTS+=(--key "$OS_KEY")
    [[ "${OS_INSECURE:-}" =~ ^([Tt]rue|1|[Yy]es)$ ]] && _API_CURL_OPTS+=(--insecure)

    log_event API_SETUP "service=$service" "endpoint=$API_ENDPOINT" "interface=$iface" \
        "cacert=${OS_CACERT:+yes}" "insecure=${OS_INSECURE:-no}"
    _API_STATE="ok"
    return 0
}

# api_get URL OUT — token + header lewat config curl di stdin
api_get() {
    local url="$1" out="$2" errf="$2.err" h

    if ! {
        printf 'header = "X-Auth-Token: %s"\n' "$_API_TOKEN"
        printf 'header = "Accept: application/json"\n'
        for h in "${API_HEADERS[@]}"; do
            printf 'header = "%s"\n' "$h"
        done
    } | "$API_CURL" "${_API_CURL_OPTS[@]}" -K - -o "$out" "$url" 2>"$errf"; then
        API_REASON="request API gagal: $(_api_last_line "$errf")"
        return 1
    fi
    return 0
}

# Ikuti pagination: query string link "next" dipakai di endpoint dari catalog
# (link dari API di belakang proxy bisa berisi host/scheme yang salah).
api_collect() {
    local path="$1" query="$2" key="$3" out="$4" page=0 url next prev_next="" got
    local dir="$API_WORK_DIR/api-pages"

    rm -rf "$dir"
    mkdir -p "$dir"

    url="$API_ENDPOINT/$path?$query"
    while true; do
        page=$(( page + 1 ))
        (( page <= 100000 )) || { API_REASON="pagination tidak berhenti"; return 1; }
        api_get "$url" "$dir/$page.json" || return 1
        if ! got="$(jq -r --arg k "$key" '(.[$k] | length), ([ (.[$k + "_links"] // [])[] | select(.rel == "next") | .href ][0] // "")' \
                "$dir/$page.json" 2>/dev/null)"; then
            API_REASON="respons API tidak valid (bukan JSON $key)"
            return 1
        fi
        next="$(sed -n 2p <<< "$got")"
        [[ -z "$next" || "$(head -n 1 <<< "$got")" == "0" || "$next" == "$prev_next" ]] && break
        prev_next="$next"
        [[ "$next" == *\?* ]] || break
        url="$API_ENDPOINT/$path?${next#*\?}"
    done

    # Halaman digabung berurutan (1, 2, ..., 10 — bukan urutan glob)
    local -a files=()
    local i
    for (( i = 1; i <= page; i++ )); do files+=("$dir/$i.json"); done
    jq -s --arg k "$key" '[ .[] | .[$k][] ]' "${files[@]}" > "$out" 2>/dev/null || {
        API_REASON="gagal menggabungkan halaman API"
        return 1
    }
    API_PAGES=$page
    log_event API_FETCH "path=$path" "pages=$page" "count=$(jq length "$out")"
    return 0
}

# Hapus token dari memori (panggil dari LOG_EXIT_HOOK script)
api_cleanup() {
    _API_TOKEN=""
    return 0
}
