#!/bin/bash
# ============================================================
# @name:        Search Container Logs
# @description: Search a keyword in OpenStack container logs across RHOSP nodes
# @mutates:     no
# @requires:    rhosp-undercloud, jq, ansible-inventory, fzf
# @platform:    rhosp
# @tags:        rhosp, logs, search, grep, request-id, troubleshooting, controller, compute
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: search-container-logs.sh [--inventory PATH] [--node HOST]... [--role ROLE]...
                                [--keyword TEXT] [--regex] [--ignore-case]
                                [--log PATH]... | [--all-logs] [--include-rotated]
                                [--context N] [--max-per-file N] [--timeout DETIK] [--save]

Cari kata kunci (mis. request ID) di log container OpenStack
(/var/log/containers) pada beberapa node RHOSP 17.1 sekaligus. Satu SSH per
node, paralel; di node pencarian berjalan dengan nice -n 19, ionice -c3 dan
timeout. Read-only: di node hanya dijalankan sudo find / grep / zgrep.

Options:
  --inventory PATH    File inventory (melewati pencarian otomatis)
  --node HOST         Node target (bisa diulang)
  --role ROLE         Semua node dalam role (bisa diulang)
  --keyword TEXT      Kata kunci (tanpa opsi ini ditanyakan; wajib, tanpa newline)
  --regex             Kata kunci sebagai regex ERE (default: teks biasa / fixed string)
  --ignore-case       Abaikan huruf besar/kecil (interaktif: ditanyakan, default tidak)
  --log PATH          File log relatif dari /var/log/containers (bisa diulang)
  --all-logs          Cari di semua file log aktif tanpa picker file
  --include-rotated   Ikut cari di file rotasi (.1, -YYYYMMDD, .gz). Format
                      kompresi lain (.xz, .bz2, .zst) dilewati dengan catatan
  --context N         Baris sebelum dan sesudah kecocokan (default 0)
  --max-per-file N    Batas kecocokan per file per node (default 500)
  --timeout DETIK     Batas waktu pencarian per node (default 300)
  --save              Simpan hasil ke /tmp/container-logs-search-<waktu>.log (600)
  -h, --help          Tampilkan help

Tanpa --node/--role, node dipilih lewat picker (entry "[semua <Role>]").
Tanpa --log/--all-logs, file dipilih lewat picker; entry "[semua file log]"
di atas daftar = --all-logs.
Tanpa terminal: --node/--role, --keyword, dan --log atau --all-logs wajib.

Environment (terutama untuk tes):
  OSOPS_SSH, OSOPS_ANSIBLE_INVENTORY, OSOPS_FZF, OSOPS_RHOSP_RELEASE_FILE,
  OSOPS_STACK_HOME, OSOPS_CL_SAVE_DIR (default /tmp), PAGER (default less -R)
EOF
}

for _arg in "$@"; do
    if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

_LIBDIR="${OSOPS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib"

# Mode internal untuk preview fzf: tanpa log_init (tidak menulis log)
if [[ "${1:-}" == "--_preview" ]]; then
    # shellcheck source=../lib/logging.sh
    source "$_LIBDIR/logging.sh" 2>/dev/null || exit 0
    # shellcheck source=../lib/rhosp.sh
    source "$_LIBDIR/rhosp.sh" 2>/dev/null || exit 0
    # shellcheck source=../lib/containerlogs.sh
    source "$_LIBDIR/containerlogs.sh" 2>/dev/null || exit 0
    cl_preview_main "${2:-}" "${3:-}"
    exit 0
fi

# Logging terpusat (lib/logging.sh)
# shellcheck source=../lib/logging.sh
if ! source "$_LIBDIR/logging.sh" 2>/dev/null; then
    echo "❌ lib/logging.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi
log_init

# Inventory, node, SSH (lib/rhosp.sh) dan discovery/picker log (lib/containerlogs.sh)
# shellcheck source=../lib/rhosp.sh
if ! source "$OSOPS_HOME/lib/rhosp.sh" 2>/dev/null \
   || ! source "$OSOPS_HOME/lib/containerlogs.sh" 2>/dev/null; then
    echo "❌ lib/rhosp.sh atau lib/containerlogs.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi
CL_SELF="$(realpath -- "${BASH_SOURCE[0]}")"

# ============================================================
# Konfigurasi
# ============================================================

KEYWORD=""
KEYWORD_SET=0
REGEX=0
IGNORE_CASE=0
IC_SET=0
ALL_LOGS=0
ROTATED=0
ROT_SET=0
CONTEXT=0
MAX_PER_FILE=500
TIMEOUT_S=300
SAVE=0
LOG_ARGS=()
INTERACTIVE=0
PROGRESS_INTERVAL="${OSOPS_CL_PROGRESS_INTERVAL:-10}"

SCOPE_ALL=0          # 1 = semua file log aktif
OLD_SEL=() OLD_FILES=() OLD_ALL=0 OLD_ROT=0
RESULT_PLAIN=""
declare -A WORKER_PIDS=()
declare -A S_STATUS=() S_MSG=() S_MATCHES=() S_DUR=() S_NFILES=() S_TRUNC=() S_SKIPPED=() S_WARN=()

# ============================================================
# Kata kunci
# ============================================================

valid_keyword() {
    local kw="$1" rc=0
    if [[ -z "$kw" ]]; then
        echo "${C_RED}❌ Kata kunci tidak boleh kosong.${C_RESET}"
        return 1
    fi
    if [[ "$kw" == *$'\n'* || "$kw" == *$'\r'* ]]; then
        echo "${C_RED}❌ Kata kunci tidak boleh berisi newline.${C_RESET}"
        return 1
    fi
    if (( REGEX )); then
        grep -E -e "$kw" < /dev/null >/dev/null 2>&1 || rc=$?
        if (( rc == 2 )); then
            echo "${C_RED}❌ Regex (ERE) tidak valid: $kw${C_RESET}"
            return 1
        fi
    fi
    return 0
}

ask_keyword() {
    local input
    if (( ! KEYWORD_SET )); then
        while true; do
            ask input "🔎 Kata kunci$( (( REGEX )) && echo ' (regex ERE)'): "
            if valid_keyword "$input"; then
                KEYWORD="$input"
                break
            fi
        done
    fi
    KEYWORD_SET=0
    if (( ! IC_SET )) && (( INTERACTIVE )); then
        ask input "Abaikan huruf besar/kecil (ignore-case)? [y/N]: "
        IGNORE_CASE=0
        is_yes "$input" && IGNORE_CASE=1
    fi
    log_event KEYWORD "keyword=$KEYWORD" "regex=$REGEX" "ignore_case=$IGNORE_CASE"
}

# ============================================================
# Cakupan
# ============================================================

# Isi SC_PLAIN / SC_GZ / SC_SKIP untuk node IDX sesuai cakupan
SC_PLAIN=() SC_GZ=() SC_SKIP=()
node_scope() {
    local i="$1" f r kind p size mt parent comp
    SC_PLAIN=() SC_GZ=() SC_SKIP=()

    if (( SCOPE_ALL )); then
        mapfile -t SC_PLAIN < <(cl_node_all_files "$i")
        if (( ROTATED )); then
            while IFS=$'\t' read -r kind p size mt parent comp; do
                [[ "$kind" == "R" ]] || continue
                case "$comp" in
                    "") SC_PLAIN+=("$p") ;;
                    gz) SC_GZ+=("$p") ;;
                    *)  SC_SKIP+=("$p") ;;
                esac
            done < "$CL_WORK/disc/$i.tsv"
        fi
        return 0
    fi

    mapfile -t SC_PLAIN < <(cl_node_files "$i")
    (( ROTATED )) || return 0
    for f in "${CL_FILES[@]}"; do
        while IFS= read -r r; do
            [[ -n "$r" ]] || continue
            case "${CL_RCOMP["$i|$r"]}" in
                "") SC_PLAIN+=("$r") ;;
                gz) SC_GZ+=("$r") ;;
                *)  SC_SKIP+=("$r") ;;
            esac
        done < <(cl_rotated_of "$i" "$f")
    done
    return 0
}

# Ukuran total (byte) dari file aktif/rotasi node
size_of() {
    local i="$1" p total=0
    shift
    for p in "$@"; do
        total=$(( total + ${CL_HAS["$i|$p"]:-${CL_RSIZE["$i|$p"]:-0}} ))
    done
    printf '%d' "$total"
}

scope_text() {
    if (( SCOPE_ALL )); then
        printf 'semua file log aktif di %s' "$CL_ROOT"
    else
        printf '%d file (%s)' "${#CL_FILES[@]}" "$(IFS=,; printf '%s' "${CL_FILES[*]}")"
    fi
    (( ROTATED )) && printf ' + file rotasi'
    return 0
}

# Peringatan cakupan semua file: total ukuran per node. $1=1 => minta konfirmasi
confirm_all_logs() {
    local need_confirm="$1" i n sz total=0 answer
    local -a f=()
    echo
    warn "Cakupan: SEMUA file log aktif di $CL_ROOT. Pencarian membaca seluruh isi file di setiap node."
    for i in $(cl_ok_nodes); do
        mapfile -t f < <(cl_node_all_files "$i")
        n=${#f[@]}
        sz="$(size_of "$i" "${f[@]}")"
        total=$(( total + sz ))
        printf '     %-28s %5d file  %8s\n' "${N_NAME[$i]}" "$n" "$(cl_human "$sz")"
    done
    echo "     Total: $(cl_human "$total") (pencarian berjalan dengan nice/ionice, timeout ${TIMEOUT_S}s per node)"
    log_event SCOPE_SIZE scope=all "bytes=$total"
    (( need_confirm )) || return 0
    ask answer "Lanjut mencari di semua file log? [y/N]: "
    if is_yes "$answer"; then
        log_event DECISION all_logs=confirm
        return 0
    fi
    log_event DECISION all_logs=cancel
    return 1
}

# Tanya file rotasi (jika belum ditentukan lewat opsi)
ask_rotated() {
    local i n=0 sz=0 nskip=0 answer save_rot="$ROTATED"
    (( ROT_SET )) && return 0
    if (( ! INTERACTIVE )); then
        ROTATED=0
        return 0
    fi
    ROTATED=1
    for i in $(cl_ok_nodes); do
        node_scope "$i"
        n=$(( n + ${#SC_GZ[@]} ))
        nskip=$(( nskip + ${#SC_SKIP[@]} ))
        sz=$(( sz + $(size_of "$i" "${SC_GZ[@]}") ))
        local rp=()
        local p
        for p in "${SC_PLAIN[@]}"; do
            [[ -n "${CL_RSIZE["$i|$p"]+x}" ]] && rp+=("$p")
        done
        n=$(( n + ${#rp[@]} ))
        sz=$(( sz + $(size_of "$i" "${rp[@]}") ))
    done
    ROTATED="$save_rot"
    if (( n == 0 )); then
        ROTATED=0
        info "Tidak ada file rotasi (.gz / tanpa kompresi) untuk cakupan ini$( (( nskip )) && echo "; $nskip file kompresi lain (.xz/.bz2/.zst) tidak bisa dicari")."
        return 0
    fi
    ask answer "Ikut cari di $n file rotasi (total $(cl_human "$sz"))$( (( nskip )) && echo "; $nskip file .xz/.bz2/.zst dilewati")? [y/N]: "
    ROTATED=0
    is_yes "$answer" && ROTATED=1
    log_event DECISION "include_rotated=$ROTATED" "rotated_files=$n" "rotated_bytes=$sz"
    return 0
}

# Pilih cakupan: --all-logs, --log, atau picker dengan entry "[semua file log]"
choose_scope() {
    local i nf=0 sz=0
    local -a f=()
    SCOPE_ALL=0
    if (( ALL_LOGS )); then
        SCOPE_ALL=1
        CL_FILES=()
        confirm_all_logs 0
    elif (( ${#LOG_ARGS[@]} > 0 )); then
        cl_use_log_args "${LOG_ARGS[@]}" || die "Tidak ada file log dari --log yang ditemukan di node terpilih."
    else
        for i in $(cl_ok_nodes); do
            mapfile -t f < <(cl_node_all_files "$i")
            nf=$(( nf + ${#f[@]} ))
            sz=$(( sz + $(size_of "$i" "${f[@]}") ))
        done
        if ! cl_pick_files "[semua file log] ($nf file aktif, total $(cl_human "$sz") di $(cl_ok_nodes | wc -l) node)"; then
            echo "Tidak ada file log yang dipilih."
            log_event SCOPE files=0
            return 1
        fi
        if (( CL_PICK_ALL )); then
            SCOPE_ALL=1
            CL_FILES=()
            confirm_all_logs 1 || return 1
        fi
    fi
    if (( ! SCOPE_ALL )); then
        echo "📄 File terpilih     : ${#CL_FILES[@]} ($(IFS=,; printf '%s' "${CL_FILES[*]}"))"
        cl_report_missing
    fi
    ask_rotated
    log_event SCOPE "scope=$( (( SCOPE_ALL )) && echo all || echo files)" \
        "files=$(IFS=,; printf '%s' "${CL_FILES[*]}")" "include_rotated=$ROTATED"
    return 0
}

prepare_nodes() {
    check_host_keys "node terpilih" "${SEL[@]}"
    cl_discover "${SEL[@]}"
    [[ -n "$(cl_ok_nodes)" ]]
}

# ============================================================
# Pencarian
# ============================================================

# Perintah remote. Kata kunci dan daftar file TIDAK masuk string perintah:
# stdin baris 1 = kata kunci, baris 2 = file biasa, baris 3 = file .gz
# (path relatif tervalidasi, dipisah spasi; dijadikan absolut di node karena
# user SSH tidak bisa masuk /var/log/containers tanpa sudo). xargs -0 membagi
# daftar file panjang sesuai batas argumen. Semua nilai di string ini
# konstanta/angka tervalidasi.
# Dua lapis timeout: yang luar (user SSH) menghentikan sh/xargs, yang dalam
# berjalan lewat sudo karena grep/zgrep milik root tidak bisa disinyal oleh
# user biasa (dan sudo tidak meneruskan sinyal dari process group yang sama).
# Batas waktu terburuk per node: sekitar 2 x --timeout.
build_remote_cmd() {
    local opts="-H -n" inner
    if (( REGEX )); then opts+=" -E"; else opts+=" -F"; fi
    (( IGNORE_CASE )) && opts+=" -i"
    opts+=" --max-count=$MAX_PER_FILE"
    (( CONTEXT > 0 )) && opts+=" --context=$CONTEXT"
    # shellcheck disable=SC2016  # dievaluasi di node
    inner='IFS= read -r pl || pl=""; IFS= read -r gz || gz=""; st=0; s0=$(date +%s); '
    # shellcheck disable=SC2016
    inner+='if [ -n "$pl" ]; then printf "'"$CL_ROOT"'/%s\0" $pl | xargs -0 -r sudo -n timeout -k 5 '"$TIMEOUT_S"' grep '"$opts"' -e "$1" --; r=$?; [ "$r" -gt "$st" ] && st=$r; fi; '
    # shellcheck disable=SC2016
    inner+='if [ -n "$gz" ]; then printf "'"$CL_ROOT"'/%s\0" $gz | xargs -0 -r sudo -n timeout -k 5 '"$TIMEOUT_S"' zgrep '"$opts"' -e "$1" --; r=$?; [ "$r" -gt "$st" ] && st=$r; fi; '
    # Timeout lapis dalam terjadi => xargs mengembalikan 123: kenali dari waktu
    # shellcheck disable=SC2016
    inner+='[ $(( $(date +%s) - s0 )) -ge '"$TIMEOUT_S"' ] && exit 124; '
    # shellcheck disable=SC2016
    inner+='exit "$st"'
    # shellcheck disable=SC2016
    printf '%s' 'IFS= read -r p || exit 2; exec nice -n 19 ionice -c3 timeout -k 10 '"$TIMEOUT_S"" sh -c '$inner' sh \"\$p\""
}

start_worker() {
    local i="$1" cmd="$2"
    printf '%s\n%s\n%s\n' "$KEYWORD" "${SC_PLAIN[*]}" "${SC_GZ[*]}" > "$CL_WORK/s$i.in"
    printf '%s\n' "${SC_PLAIN[@]}" "${SC_GZ[@]}" > "$CL_WORK/s$i.files"
    (
        rc=0
        ssh_node_stdin "$i" $(( TIMEOUT_S + 30 )) "$cmd" < "$CL_WORK/s$i.in" \
            > "$CL_WORK/s$i.out" 2> "$CL_WORK/s$i.err" || rc=$?
        echo "$rc" > "$CL_WORK/s$i.rc"
    ) &
    WORKER_PIDS[$!]="$i"
}

# Klasifikasi hasil node => S_STATUS (SELESAI|TIMEOUT|GAGAL), S_MSG, S_WARN
classify() {
    local i="$1" rc err gerr
    rc="$(cat "$CL_WORK/s$i.rc" 2>/dev/null)" || rc=255
    err="$(grep -vE '^Warning: Permanently added|^[[:space:]]*\*.*\*[[:space:]]*$|^[[:space:]]*\*+[[:space:]]*$' "$CL_WORK/s$i.err" 2>/dev/null)" || err=""
    gerr="$(grep -E '^(grep|zgrep|gzip|xargs): ' <<< "$err" | head -n 3 | tr '\n' ' ' | cut -c1-300)" || gerr=""
    S_WARN[$i]="$gerr"
    case "$rc" in
        124|137)
            S_STATUS[$i]="TIMEOUT"
            S_MSG[$i]="timeout setelah ${TIMEOUT_S}s (hasil sebagian)"
            ;;
        0|1|123)
            if [[ "$err" == *"sudo:"* ]]; then
                S_STATUS[$i]="GAGAL"
                S_MSG[$i]="sudo failed: $(grep -m1 'sudo:' <<< "$err" | cut -c1-200)"
            else
                S_STATUS[$i]="SELESAI"
                S_MSG[$i]=""
            fi
            ;;
        255)
            S_STATUS[$i]="GAGAL"
            S_MSG[$i]="$(ssh_fail_reason "$err" "$rc")"
            ;;
        *)
            S_STATUS[$i]="GAGAL"
            S_MSG[$i]="rc=$rc $(tail -n 2 <<< "$err" | tr '\n' ' ' | cut -c1-200)"
            ;;
    esac
}

# Format hasil satu node (output grep -H -n) => blok teks + statistik per file
# Baris: [host file:N] teks (cocok), [host file-N] teks (konteks), "  --" antar blok
format_node() {
    local i="$1"
    awk -v host="${N_NAME[$i]}" -v max="$MAX_PER_FILE" -v statf="$CL_WORK/s$i.stat" -v root="$CL_ROOT/" '
        FNR == NR { if ($0 != "") known[$0] = 1; next }
        $0 == "--" { next }
        {
            line = $0; f = ""; kind = ""
            if (index(line, root) == 1) line = substr(line, length(root) + 1)
            c = index(line, ":")
            if (c > 1 && (substr(line, 1, c - 1) in known) && substr(line, c + 1) ~ /^[0-9]+:/) {
                f = substr(line, 1, c - 1); rest = substr(line, c + 1); kind = ":"
            } else {
                for (k = 1; k <= length(line); k++) {
                    if (substr(line, k, 1) != "-") continue
                    if ((substr(line, 1, k - 1) in known) && substr(line, k + 1) ~ /^[0-9]+-/) {
                        f = substr(line, 1, k - 1); rest = substr(line, k + 1); kind = "-"; break
                    }
                }
            }
            if (f == "") next
            sep = index(rest, kind)
            n = substr(rest, 1, sep - 1) + 0
            text = substr(rest, sep + 1)
            if (f != cur) {
                printf "\n── %s │ %s ──\n", host, f
                cur = f; last = -1
                order[++nf] = f
            } else if (last >= 0 && n != last + 1) {
                print "  --"
            }
            last = n
            if (kind == ":") { cnt[f]++; printf "[%s %s:%d] %s\n", host, f, n, text }
            else printf "[%s %s-%d] %s\n", host, f, n, text
        }
        END {
            for (k = 1; k <= nf; k++) {
                f = order[k]
                printf "%s\t%d\t%d\n", f, cnt[f], (cnt[f] >= max ? 1 : 0) > statf
            }
            if (nf == 0) printf "" > statf
        }
    ' "$CL_WORK/s$i.files" "$CL_WORK/s$i.out"
}

progress_line() {
    local i="$1"
    case "${S_STATUS[$i]}" in
        SELESAI) echo "  ${C_GREEN}✅ ${N_NAME[$i]}: selesai (${S_MATCHES[$i]} kecocokan, $(fmt_s "${S_DUR[$i]}"))${C_RESET}" ;;
        TIMEOUT) echo "  ${C_YELLOW}⏱  ${N_NAME[$i]}: timeout setelah ${TIMEOUT_S}s (${S_MATCHES[$i]} kecocokan sebagian)${C_RESET}" ;;
        *)       echo "  ${C_RED}❌ ${N_NAME[$i]}: gagal (${S_MSG[$i]})${C_RESET}" ;;
    esac
}

fmt_s() {
    printf '%ss' "${1:-0}"
}

run_search() {
    local i cmd t0 now last pid st nodes="" total=0 n_ok=0 n_files
    local -a idxs=()
    local -A t_start=()

    RESULT_PLAIN="$CL_WORK/result-search.txt"
    cmd="$(build_remote_cmd)"
    S_STATUS=() S_MSG=() S_MATCHES=() S_DUR=() S_NFILES=() S_TRUNC=() S_SKIPPED=() S_WARN=()

    echo
    echo "${C_BOLD}🔎 Mencari \"$KEYWORD\" ($( (( REGEX )) && echo regex || echo teks)$( (( IGNORE_CASE )) && echo ', ignore-case')) di $(scope_text)${C_RESET}"
    t0="$(date +%s)"
    for i in $(cl_ok_nodes); do
        node_scope "$i"
        n_files=$(( ${#SC_PLAIN[@]} + ${#SC_GZ[@]} ))
        S_SKIPPED[$i]="${SC_SKIP[*]}"
        S_NFILES[$i]="$n_files"
        S_MATCHES[$i]=0
        if (( n_files == 0 )); then
            S_STATUS[$i]="KOSONG"
            S_MSG[$i]="tidak ada file dalam cakupan"
            echo "  ${C_DIM}–  ${N_NAME[$i]}: tidak ada file dalam cakupan${C_RESET}"
            continue
        fi
        idxs+=("$i")
        t_start[$i]="$(date +%s)"
        start_worker "$i" "$cmd"
        echo "  🔎 ${N_NAME[$i]}: mencari ($n_files file, $(cl_human "$(size_of "$i" "${SC_PLAIN[@]}" "${SC_GZ[@]}")"))"
    done

    last="$t0"
    while (( ${#WORKER_PIDS[@]} > 0 )); do
        sleep 1
        now="$(date +%s)"
        for pid in "${!WORKER_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null && continue
            wait "$pid" 2>/dev/null || true
            i="${WORKER_PIDS[$pid]}"
            unset "WORKER_PIDS[$pid]"
            S_DUR[$i]=$(( now - t_start[$i] ))
            classify "$i"
            format_node "$i" > "$CL_WORK/s$i.fmt"
            S_MATCHES[$i]="$(awk -F '\t' '{ s += $2 } END { print s + 0 }' "$CL_WORK/s$i.stat")"
            S_TRUNC[$i]="$(awk -F '\t' '$3 == 1 { n++ } END { print n + 0 }' "$CL_WORK/s$i.stat")"
            progress_line "$i"
            st="${S_STATUS[$i]}"
            log_result "resource=${N_NAME[$i]}" action=lookup mode=search \
                "result=$([[ "$st" == SELESAI ]] && echo SUCCESS || echo FAILED)" \
                "status=$st" "files=${S_NFILES[$i]}" "matches=${S_MATCHES[$i]}" "truncated=${S_TRUNC[$i]}" \
                "skipped_compressed=$(wc -w <<< "${S_SKIPPED[$i]}")" "duration=${S_DUR[$i]}s" \
                "msg=${S_MSG[$i]:--}" "warning=${S_WARN[$i]:--}"
        done
        if (( ${#WORKER_PIDS[@]} > 0 && now - last >= PROGRESS_INTERVAL )); then
            nodes=""
            for pid in "${!WORKER_PIDS[@]}"; do
                nodes+="${nodes:+, }${N_NAME[${WORKER_PIDS[$pid]}]}"
            done
            echo "  ⏳ masih mencari ($(( now - t0 ))s): $nodes"
            last="$now"
        fi
    done

    for i in "${idxs[@]}"; do
        total=$(( total + S_MATCHES[$i] ))
        [[ "${S_STATUS[$i]}" == "SELESAI" ]] && n_ok=$(( n_ok + 1 ))
    done

    build_result "$total" "$t0"
    show_result
    log_info "SUMMARY mode=search nodes=${#idxs[@]} nodes_ok=$n_ok matches=$total scope=$( (( SCOPE_ALL )) && echo all || echo files) files=${#CL_FILES[@]} include_rotated=$ROTATED duration=$(( $(date +%s) - t0 ))s"
    return 0
}

summary_text() {
    local total="$1" i f n tr any_skip=0
    echo "Ringkasan:"
    for i in $(cl_ok_nodes); do
        case "${S_STATUS[$i]:-}" in
            SELESAI) printf '  %-28s %6d kecocokan  (%d file, %ss)\n' "${N_NAME[$i]}" "${S_MATCHES[$i]}" "${S_NFILES[$i]}" "${S_DUR[$i]}" ;;
            TIMEOUT) printf '  %-28s TIMEOUT    %s, %d kecocokan sebagian\n' "${N_NAME[$i]}" "${S_MSG[$i]}" "${S_MATCHES[$i]}" ;;
            GAGAL)   printf '  %-28s GAGAL      %s\n' "${N_NAME[$i]}" "${S_MSG[$i]}" ;;
            KOSONG)  printf '  %-28s -          %s\n' "${N_NAME[$i]}" "${S_MSG[$i]}" ;;
        esac
        if [[ -s "$CL_WORK/s$i.stat" ]]; then
            while IFS=$'\t' read -r f n tr; do
                printf '      %-56s %6d%s\n' "$f" "$n" "$( (( tr )) && echo "  TERPOTONG (batas --max-per-file $MAX_PER_FILE)")"
            done < "$CL_WORK/s$i.stat"
        fi
        [[ -n "${S_WARN[$i]:-}" ]] && printf '      peringatan: %s\n' "${S_WARN[$i]}"
    done
    for i in "${!SEL[@]}"; do
        i="${SEL[$i]}"
        [[ "${CL_STATE[$i]:-}" == "ok" ]] || printf '  %-28s DILEWATI   %s\n' "${N_NAME[$i]}" "${CL_REASON[$i]:-}"
    done
    for i in $(cl_ok_nodes); do
        [[ -n "${S_SKIPPED[$i]:-}" ]] || continue
        (( any_skip )) || echo "File terkompresi dilewati (bukan .gz, tidak bisa dicari dengan zgrep):"
        any_skip=1
        printf '  %s: %d file (%s)\n' "${N_NAME[$i]}" "$(wc -w <<< "${S_SKIPPED[$i]}")" "$(tr ' ' ',' <<< "${S_SKIPPED[$i]}" | cut -c1-300)"
    done
    local done_nodes="" not_done=""
    for i in $(cl_ok_nodes); do
        case "${S_STATUS[$i]:-}" in
            SELESAI) done_nodes+="${done_nodes:+,}${N_NAME[$i]}" ;;
            TIMEOUT|GAGAL) not_done+="${not_done:+,}${N_NAME[$i]}" ;;
        esac
    done
    if (( total == 0 )) && [[ -z "$done_nodes" ]]; then
        echo
        echo "PENCARIAN TIDAK SELESAI di node mana pun (${not_done:-tidak ada node dengan file dalam cakupan}): tidak bisa disimpulkan \"$KEYWORD\" tidak ada."
    elif (( total == 0 )); then
        echo
        echo "TIDAK ADA KECOCOKAN untuk \"$KEYWORD\" di $(scope_text) pada $(wc -w <<< "${done_nodes//,/ }") node ($done_nodes)."
        [[ -n "$not_done" ]] && echo "Catatan: pencarian di $not_done tidak selesai (lihat TIMEOUT/GAGAL di atas)."
    elif [[ -n "$not_done" ]]; then
        echo "Total: $total kecocokan (SEBAGIAN: pencarian di $not_done tidak selesai)."
    else
        echo "Total: $total kecocokan."
    fi
    return 0
}

build_result() {
    local total="$1" t0="$2" i
    {
        echo "Pencarian: \"$KEYWORD\" ($( (( REGEX )) && echo 'regex ERE' || echo 'teks biasa')$( (( IGNORE_CASE )) && echo ', ignore-case')) — $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Cakupan  : $(scope_text)"
        echo "Node     : $(rhosp_selected_names)"
        echo "Opsi     : context=$CONTEXT max-per-file=$MAX_PER_FILE timeout=${TIMEOUT_S}s durasi=$(( $(date +%s) - t0 ))s"
        echo
        summary_text "$total"
        for i in $(cl_ok_nodes); do
            [[ -s "$CL_WORK/s$i.fmt" ]] || continue
            echo
            echo "══════ ${N_NAME[$i]} ══════"
            cat "$CL_WORK/s$i.fmt"
        done
    } > "$RESULT_PLAIN"
    SUMMARY_TOTAL="$total"
}

# Versi berwarna: header tebal, prefix berwarna, kata kunci disorot
colorize() {
    KW="$KEYWORD" awk -v ic="$IGNORE_CASE" -v rx="$REGEX" -v b="$C_BOLD$C_CYAN" -v pf="$C_CYAN" \
        -v ctx="$C_DIM" -v hl=$'\e[1;31m' -v r="$C_RESET" '
        BEGIN { kw = ENVIRON["KW"]; lkw = tolower(kw); if (rx && ic) IGNORECASE = 1 }
        function mark(s,    out, pos, hay, m) {
            out = ""
            if (rx) {
                while (length(s) > 0 && match(s, kw) && RLENGTH > 0) {
                    out = out substr(s, 1, RSTART - 1) hl substr(s, RSTART, RLENGTH) r
                    s = substr(s, RSTART + RLENGTH)
                }
                return out s
            }
            while (1) {
                hay = ic ? tolower(s) : s
                pos = index(hay, ic ? lkw : kw)
                if (pos == 0) break
                out = out substr(s, 1, pos - 1) hl substr(s, pos, length(kw)) r
                s = substr(s, pos + length(kw))
            }
            return out s
        }
        /^(══════ |── )/ { print b $0 r; next }
        /^\[[^]]* [^]]*:[0-9]+\] / { p = index($0, "] "); print pf substr($0, 1, p) r mark(substr($0, p + 1)); next }
        /^\[[^]]* [^]]*-[0-9]+\] / { print ctx $0 r; next }
        /TERPOTONG|TIMEOUT|GAGAL|TIDAK ADA KECOCOKAN|TIDAK SELESAI/ { print "\033[33m" $0 r; next }
        { print }
    ' "$RESULT_PLAIN"
}

show_result() {
    if [[ -t 1 ]]; then
        if ! colorize > "$RESULT_PLAIN.color" 2>/dev/null; then
            cp "$RESULT_PLAIN" "$RESULT_PLAIN.color"
        fi
        cl_show "$RESULT_PLAIN" "$RESULT_PLAIN.color"
        echo
        echo "${C_BOLD}Ringkasan pencarian:${C_RESET}"
        summary_text "$SUMMARY_TOTAL"
    else
        cl_show "$RESULT_PLAIN"
    fi
}

save_result() {
    local dest
    if [[ -z "$RESULT_PLAIN" || ! -f "$RESULT_PLAIN" ]]; then
        warn "Belum ada hasil pencarian untuk disimpan."
        return 0
    fi
    if dest="$(cl_save "$RESULT_PLAIN" search)"; then
        echo "${C_GREEN}💾 Hasil disimpan: $dest (permission 600)${C_RESET}"
        [[ "$CL_SAVE_DIR" == "/tmp" ]] && \
            info "/tmp bisa dibersihkan otomatis (systemd-tmpfiles) dan hilang saat reboot. Isi log bisa sensitif: hapus file setelah selesai."
    else
        warn "Gagal menyimpan hasil ke $CL_SAVE_DIR."
    fi
    return 0
}

# ============================================================
# Menu setelah pencarian
# ============================================================

# Kembalikan node dan cakupan sebelum [n]ode (batal / tidak ada yang bisa dipakai)
restore_selection() {
    local i
    rhosp_reset_selection
    for i in "${OLD_SEL[@]}"; do select_idx "$i"; done
    CL_FILES=("${OLD_FILES[@]}") SCOPE_ALL="$OLD_ALL" ROTATED="$OLD_ROT"
    cl_build_index
    echo "Pilihan node dan cakupan tidak diubah ($(rhosp_selected_names))."
    log_event DECISION menu=node result=unchanged
}

change_nodes() {
    local -a keep=()
    local i f
    OLD_SEL=("${SEL[@]}") OLD_FILES=("${CL_FILES[@]}") OLD_ALL="$SCOPE_ALL" OLD_ROT="$ROTATED"
    rhosp_reset_selection
    if ! rhosp_pick_nodes; then
        restore_selection
        return 1
    fi
    echo "✅ Node terpilih     : ${#SEL[@]} ($(rhosp_selected_names))"
    log_event SELECT "selected=${#SEL[@]}" "nodes=$(rhosp_selected_names)"
    if ! prepare_nodes; then
        warn "Tidak ada node terpilih yang bisa dijangkau; kembali ke pilihan sebelumnya."
        restore_selection
        return 1
    fi
    cl_build_index
    (( SCOPE_ALL )) && return 0
    for f in "${CL_FILES[@]}"; do
        for i in $(cl_ok_nodes); do
            if [[ -n "${CL_HAS["$i|$f"]+x}" ]]; then keep+=("$f"); break; fi
        done
    done
    CL_FILES=("${keep[@]}")
    if (( ${#CL_FILES[@]} == 0 )); then
        info "File sebelumnya tidak ada di node baru; pilih cakupan lagi."
        if ! choose_scope; then
            restore_selection
            return 1
        fi
    else
        cl_report_missing
    fi
    return 0
}

post_menu() {
    local input
    local -a old_files=()
    local old_all old_rot
    while true; do
        echo
        ask input "[k]ata kunci baru  [c]akupan  [n]ode  [s]impan  [q] kembali: "
        case "${input,,}" in
            k)
                ask_keyword
                return 0
                ;;
            c)
                old_files=("${CL_FILES[@]}") old_all="$SCOPE_ALL" old_rot="$ROTATED"
                ALL_LOGS=0 LOG_ARGS=() ROT_SET=0
                if choose_scope; then
                    return 0
                fi
                CL_FILES=("${old_files[@]}") SCOPE_ALL="$old_all" ROTATED="$old_rot"
                echo "Cakupan tidak diubah."
                ;;
            n)
                change_nodes && return 0
                ;;
            s)
                save_result
                ;;
            q|"")
                log_event DECISION menu=quit
                return 1
                ;;
            *)
                echo "${C_RED}❌ Pilihan tidak valid.${C_RESET}"
                ;;
        esac
    done
}

# ============================================================
# Hook library
# ============================================================

# shellcheck disable=SC2329  # dipanggil dari hook
kill_workers() {
    local pid
    for pid in "${!WORKER_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && kill_tree "$pid"
        unset "WORKER_PIDS[$pid]"
    done
    return 0
}

# shellcheck disable=SC2329  # dipanggil lewat LOG_INTERRUPT_HOOK
on_interrupt() {
    local pid
    for pid in "${!WORKER_PIDS[@]}"; do
        log_result "resource=${N_NAME[${WORKER_PIDS[$pid]}]}" action=lookup mode=search result=ABORTED \
            status=interrupted "msg=stopped by operator (${1:-INT})"
    done
    kill_workers
    cl_kill_bg
    echo
    warn "Dihentikan (${1:-INT}). Koneksi SSH ditutup; pencarian di node berhenti oleh timeout ${TIMEOUT_S}s jika masih berjalan."
}

# shellcheck disable=SC2329  # dipanggil lewat LOG_EXIT_HOOK
on_exit() {
    set +o errexit
    kill_workers
    cl_cleanup
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
        --inventory)       need_arg "$1" "${2:-}"; INVENTORY="$2"; shift 2 ;;
        --node)            need_arg "$1" "${2:-}"; NODE_ARGS+=("$2"); shift 2 ;;
        --role)            need_arg "$1" "${2:-}"; ROLE_ARGS+=("$2"); shift 2 ;;
        --log)             need_arg "$1" "${2:-}"; LOG_ARGS+=("$2"); shift 2 ;;
        --keyword)         (( $# >= 2 )) || die "--keyword membutuhkan nilai."; KEYWORD="$2"; KEYWORD_SET=1; shift 2 ;;
        --regex)           REGEX=1; shift ;;
        --ignore-case)     IGNORE_CASE=1; IC_SET=1; shift ;;
        --all-logs)        ALL_LOGS=1; shift ;;
        --include-rotated) ROTATED=1; ROT_SET=1; shift ;;
        --context)         need_arg "$1" "${2:-}"; CONTEXT="$2"; shift 2 ;;
        --max-per-file)    need_arg "$1" "${2:-}"; MAX_PER_FILE="$2"; shift 2 ;;
        --timeout)         need_arg "$1" "${2:-}"; TIMEOUT_S="$2"; shift 2 ;;
        --save)            SAVE=1; shift ;;
        *)
            echo "❌ Parameter tidak dikenal: $1"
            echo
            usage
            exit 1
            ;;
    esac
done

if ! is_uint "$CONTEXT" || (( CONTEXT > 100 )); then
    die "--context harus bilangan bulat 0-100."
fi
if ! is_uint "$MAX_PER_FILE" || (( MAX_PER_FILE < 1 || MAX_PER_FILE > 100000 )); then
    die "--max-per-file harus bilangan bulat 1-100000."
fi
if ! is_uint "$TIMEOUT_S" || (( TIMEOUT_S < 1 || TIMEOUT_S > 86400 )); then
    die "--timeout harus bilangan bulat (detik) 1-86400."
fi
is_uint "$PROGRESS_INTERVAL" || PROGRESS_INTERVAL=10
if (( ALL_LOGS )) && (( ${#LOG_ARGS[@]} > 0 )); then
    die "--all-logs dan --log tidak bisa dipakai bersamaan."
fi
if (( KEYWORD_SET )); then
    valid_keyword "$KEYWORD" > /dev/null || { valid_keyword "$KEYWORD" || true; log_error -q "kata kunci tidak valid"; exit 1; }
fi

has_tty && INTERACTIVE=1
if (( ! INTERACTIVE )); then
    (( ${#NODE_ARGS[@]} > 0 || ${#ROLE_ARGS[@]} > 0 )) || die "Tanpa terminal: --node/--role wajib."
    (( KEYWORD_SET )) || die "Tanpa terminal: --keyword wajib."
    (( ALL_LOGS || ${#LOG_ARGS[@]} > 0 )) || die "Tanpa terminal: --log atau --all-logs wajib."
fi

# ============================================================
# Main
# ============================================================

cl_setup_workdir search-container-logs
LOG_EXIT_HOOK=on_exit
LOG_INTERRUPT_HOOK=on_interrupt
SUMMARY_TOTAL=0

echo "========================================"
echo "🔎 Search Container Logs"
echo "========================================"

rhosp_check_env warn
for _tool in "${SSH_CMD[0]}" timeout awk grep; do
    command -v "$_tool" >/dev/null 2>&1 || die "$_tool tidak ditemukan."
done
log_event INPUT "keyword_given=$KEYWORD_SET" "regex=$REGEX" "ignore_case=$IGNORE_CASE" "all_logs=$ALL_LOGS" \
    "include_rotated=$ROTATED" "context=$CONTEXT" "max_per_file=$MAX_PER_FILE" "timeout=$TIMEOUT_S" \
    "save=$SAVE" "interactive=$INTERACTIVE" \
    "nodes=$(IFS=,; printf '%s' "${NODE_ARGS[*]}")" "roles=$(IFS=,; printf '%s' "${ROLE_ARGS[*]}")" \
    "logs=$(IFS=,; printf '%s' "${LOG_ARGS[*]}")"

rhosp_find_inventory
rhosp_load_nodes
rhosp_select_nodes
prepare_nodes || die "Tidak ada node terpilih yang bisa dijangkau."
ask_keyword
choose_scope || exit 0
LOG_ARGS=()

while true; do
    run_search
    if (( SAVE )); then
        save_result
        SAVE=0
    fi
    (( INTERACTIVE )) && [[ -t 1 ]] || break
    post_menu || break
done
[[ -n "$LOG_FILE" ]] && [[ -t 1 ]] && echo "Log: $LOG_FILE"
exit 0
