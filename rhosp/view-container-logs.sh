#!/bin/bash
# ============================================================
# @name:        View Container Logs
# @description: Search and read OpenStack container logs on RHOSP nodes (tail, follow)
# @mutates:     no
# @requires:    rhosp-undercloud, jq, ansible-inventory, fzf
# @platform:    rhosp
# @tags:        rhosp, logs, troubleshooting, controller, compute, tail, follow
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: view-container-logs.sh [--inventory PATH] [--node HOST]... [--role ROLE]...
                              [--log PATH]... [--mode tail|follow] [--lines N] [--save]

Baca log container OpenStack di node RHOSP 17.1 (/var/log/containers):
N baris terakhir (tail) atau mengikuti secara live (follow) dari beberapa
node sekaligus. Dijalankan di undercloud sebagai user stack; node diakses
lewat SSH (user dari inventory, default tripleo-admin). Read-only: di node
hanya dijalankan sudo find / sudo tail.

Untuk mencari kata kunci (mis. request ID) gunakan search-container-logs.sh.

Options:
  --inventory PATH   File inventory (melewati pencarian otomatis)
  --node HOST        Node target (bisa diulang)
  --role ROLE        Semua node dalam role (bisa diulang)
  --log PATH         File log relatif dari /var/log/containers, mis.
                     nova/nova-api.log (bisa diulang; tanpa opsi ini file
                     dipilih lewat picker)
  --mode MODE        tail | follow (default ditanyakan; tanpa terminal: tail)
  --lines N          Jumlah baris untuk tail (default 200); untuk follow:
                     baris awal per file sebelum live (default 10)
  --save             Simpan hasil tail ke /tmp/container-logs-view-<waktu>.log
                     (permission 600). Mode follow tidak disimpan.
  -h, --help         Tampilkan help

Tanpa --node/--role, node dipilih lewat picker (fzf: entry "[semua <Role>]"
untuk semua node satu role; tanpa fzf: menu bernomor).
Follow: Ctrl-C menghentikan semua koneksi; tail di node ikut berhenti.
Tanpa terminal: --node/--role dan --log wajib, hasil dicetak tanpa pager.

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

MODE=""
TAIL_LINES=200
LINES_SET=0
SAVE=0
LOG_ARGS=()
INTERACTIVE=0
SSH_TIMEOUT=120
RESULT_PLAIN=""
FOLLOW_ACTIVE=0
FOLLOW_T0=0
FOLLOW_NODES=""
FOLLOW_PIDS=()
OLD_SEL=()
OLD_FILES=()

# Warna prefix per node (kosong jika stdout bukan terminal)
NODE_COLORS=()
if [[ -t 1 ]]; then
    NODE_COLORS=($'\e[36m' $'\e[33m' $'\e[35m' $'\e[32m' $'\e[34m' $'\e[31m'
                 $'\e[1;36m' $'\e[1;33m' $'\e[1;35m' $'\e[1;32m' $'\e[1;34m' $'\e[1;31m')
fi

node_color() {
    (( ${#NODE_COLORS[@]} > 0 )) || return 0
    printf '%s' "${NODE_COLORS[$(( $1 % ${#NODE_COLORS[@]} ))]}"
}

# ============================================================
# Pilihan
# ============================================================

ask_mode() {
    local input
    while true; do
        ask input "Mode: [t]ail ${TAIL_LINES} baris / [f]ollow live (default t): "
        case "${input,,}" in
            ""|t|tail)   MODE="tail"; break ;;
            f|follow)    MODE="follow"; break ;;
            *) echo "${C_RED}❌ Pilihan tidak valid.${C_RESET}" ;;
        esac
    done
    if [[ "$MODE" == "tail" ]]; then
        ask input "Jumlah baris [${TAIL_LINES}]: "
        input="$(trim "$input")"
        if [[ -n "$input" ]]; then
            if is_uint "$input" && (( input >= 1 && input <= 100000 )); then
                TAIL_LINES="$input"
                LINES_SET=1
            else
                echo "${C_YELLOW}⚠️  Jumlah baris tidak valid, tetap ${TAIL_LINES}.${C_RESET}"
            fi
        fi
    fi
    log_event DECISION "mode=$MODE" "lines=$TAIL_LINES"
}

log_files() {
    log_event FILES "count=${#CL_FILES[@]}" "files=$(IFS=,; printf '%s' "${CL_FILES[*]}")"
}

choose_files() {
    if (( ${#LOG_ARGS[@]} > 0 )); then
        cl_use_log_args "${LOG_ARGS[@]}" || die "Tidak ada file log dari --log yang ditemukan di node terpilih."
        LOG_ARGS=()
    else
        if ! cl_pick_files; then
            echo "Tidak ada file log yang dipilih."
            log_event FILES count=0
            return 1
        fi
    fi
    echo "📄 File terpilih     : ${#CL_FILES[@]} ($(IFS=,; printf '%s' "${CL_FILES[*]}"))"
    cl_report_missing
    log_files
    return 0
}

# Node terpilih + discovery; return 1 jika tidak ada node yang bisa dipakai
prepare_nodes() {
    check_host_keys "node terpilih" "${SEL[@]}"
    cl_discover "${SEL[@]}"
    [[ -n "$(cl_ok_nodes)" ]]
}

# ============================================================
# tail
# ============================================================

run_tail() {
    local i rc t0 n_files out err nodes_ok=0 summary="" status
    local -a files=() idxs=()

    RESULT_PLAIN="$CL_WORK/result-tail.txt"
    if (( ${#CL_FILES[@]} == 0 )); then
        warn "Tidak ada file log yang dipilih."
        return 0
    fi
    echo
    echo "${C_BOLD}📜 Mengambil ${TAIL_LINES} baris terakhir...${C_RESET}"

    t0="$(date +%s)"
    for i in $(cl_ok_nodes); do
        mapfile -t files < <(cl_node_files "$i")
        (( ${#files[@]} > 0 )) || continue
        idxs+=("$i")
        (
            rc=0
            ssh_node "$i" "$SSH_TIMEOUT" "sudo -n tail -v -n $TAIL_LINES -- $(cl_quote_paths "${files[@]}")" \
                > "$CL_WORK/t$i.out" 2> "$CL_WORK/t$i.err" || rc=$?
            echo "$rc" > "$CL_WORK/t$i.rc"
        ) &
        CL_BG_PIDS+=("$!")
    done
    wait "${CL_BG_PIDS[@]}" 2>/dev/null || true
    CL_BG_PIDS=()

    {
        echo "Tail ${TAIL_LINES} baris terakhir — $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Node: $(rhosp_selected_names)"
        echo "File: $(IFS=,; printf '%s' "${CL_FILES[*]}")"
    } > "$RESULT_PLAIN.head"
    : > "$RESULT_PLAIN.body"

    for i in "${idxs[@]}"; do
        rc="$(cat "$CL_WORK/t$i.rc" 2>/dev/null)" || rc=255
        out="$CL_WORK/t$i.out"
        err="$(cl_err_tail "$CL_WORK/t$i.err")"
        mapfile -t files < <(cl_node_files "$i")
        n_files=${#files[@]}

        if [[ ! -s "$out" ]] && (( rc != 0 )); then
            status="FAILED"
            summary+="  ${N_NAME[$i]}: GAGAL ($(ssh_fail_reason "$err" "$rc"); ${err:-rc=$rc})"$'\n'
            log_result "resource=${N_NAME[$i]}" action=lookup mode=tail result=FAILED "files=$n_files" \
                "rc=$rc" "msg=${err:--}" "duration=$(( $(date +%s) - t0 ))s"
            continue
        fi
        nodes_ok=$(( nodes_ok + 1 ))
        status="OK"
        (( rc != 0 )) && status="sebagian (${err:-rc=$rc})"
        summary+="  ${N_NAME[$i]}: $n_files file, $status"$'\n'
        log_result "resource=${N_NAME[$i]}" action=lookup mode=tail result=SUCCESS "files=$n_files" \
            "lines=$TAIL_LINES" "rc=$rc" "duration=$(( $(date +%s) - t0 ))s"

        awk -v host="${N_NAME[$i]}" -v root="$CL_ROOT/" '
            function hdr(f) { printf "\n══════ %s │ %s ══════\n", host, f }
            /^==> .* <==$/ {
                f = substr($0, 5, length($0) - 8)
                if (index(f, root) == 1) { held = 0; hdr(substr(f, length(root) + 1)); next }
            }
            {
                if (held) { print ""; held = 0 }
                if ($0 == "") { held = 1; next }
                print
            }
        ' "$out" >> "$RESULT_PLAIN.body"
    done

    {
        cat "$RESULT_PLAIN.head"
        echo
        echo "Ringkasan:"
        printf '%s' "$summary"
        cat "$RESULT_PLAIN.body"
    } > "$RESULT_PLAIN"
    rm -f "$RESULT_PLAIN.head" "$RESULT_PLAIN.body"

    # Versi berwarna untuk pager (file simpanan tetap polos)
    if [[ -t 1 ]]; then
        awk -v b="$C_BOLD$C_CYAN" -v r="$C_RESET" '/^══════ / { print b $0 r; next } { print }' \
            "$RESULT_PLAIN" > "$RESULT_PLAIN.color"
        cl_show "$RESULT_PLAIN" "$RESULT_PLAIN.color"
    else
        cl_show "$RESULT_PLAIN"
    fi

    if [[ -t 1 ]]; then
        echo
        echo "${C_BOLD}Ringkasan tail:${C_RESET}"
        printf '%s' "$summary"
    fi
    log_info "SUMMARY mode=tail nodes=${#idxs[@]} nodes_ok=$nodes_ok files=${#CL_FILES[@]} lines=$TAIL_LINES duration=$(( $(date +%s) - t0 ))s"
    return 0
}

save_result() {
    local dest
    if [[ -z "$RESULT_PLAIN" || ! -f "$RESULT_PLAIN" ]]; then
        warn "Belum ada hasil tail untuk disimpan."
        return 0
    fi
    if dest="$(cl_save "$RESULT_PLAIN" view)"; then
        echo "${C_GREEN}💾 Hasil disimpan: $dest (permission 600)${C_RESET}"
        [[ "$CL_SAVE_DIR" == "/tmp" ]] && \
            info "/tmp bisa dibersihkan otomatis (systemd-tmpfiles) dan hilang saat reboot. Isi log bisa sensitif: hapus file setelah selesai."
    else
        warn "Gagal menyimpan hasil ke $CL_SAVE_DIR."
    fi
    return 0
}

# ============================================================
# follow
# ============================================================

# shellcheck disable=SC2329  # dipanggil dari hook / akhir follow
finish_follow() {
    local why="$1" i
    (( FOLLOW_ACTIVE )) || return 0
    FOLLOW_ACTIVE=0
    for i in "${FOLLOW_PIDS[@]}"; do
        kill -0 "$i" 2>/dev/null && kill_tree "$i"
    done
    FOLLOW_PIDS=()
    for i in $FOLLOW_NODES; do
        log_result "resource=${N_NAME[$i]}" action=lookup mode=follow result=SUCCESS \
            "files=$(cl_node_files "$i" | wc -l)" "msg=$why" "duration=$(( $(date +%s) - FOLLOW_T0 ))s"
    done
    log_info "SUMMARY mode=follow nodes=$(wc -w <<< "$FOLLOW_NODES") files=${#CL_FILES[@]} stopped=$why duration=$(( $(date +%s) - FOLLOW_T0 ))s"
    return 0
}

run_follow() {
    local i n_init cmd color fifo set hold_fd
    local -a files=()

    n_init=10
    (( LINES_SET )) && n_init="$TAIL_LINES"
    fifo="$CL_WORK/follow.hold"
    mkfifo -m 600 "$fifo"
    # FIFO ditahan terbuka (baca-tulis) tanpa pernah ditulisi: stdin ssh tidak
    # pernah EOF selama script hidup. Saat ssh berhenti, sshd menutup stdin
    # perintah remote => "cat" selesai => shell remote keluar => tail --pid
    # ikut berhenti (dalam ~1 detik).
    exec {hold_fd}<>"$fifo"

    echo
    echo "${C_BOLD}▶ Follow live (${n_init} baris awal per file).${C_RESET} ${C_CYAN}Tekan Ctrl-C untuk berhenti.${C_RESET}"
    echo

    FOLLOW_NODES=""
    FOLLOW_T0="$(date +%s)"
    FOLLOW_ACTIVE=1
    for i in $(cl_ok_nodes); do
        mapfile -t files < <(cl_node_files "$i")
        (( ${#files[@]} > 0 )) || continue
        FOLLOW_NODES+="${FOLLOW_NODES:+ }$i"
        # shellcheck disable=SC2016  # $$ dievaluasi di node (pid shell remote)
        cmd="sudo -n tail -F -v -n $n_init --pid=\$\$ -- $(cl_quote_paths "${files[@]}") & cat >/dev/null"
        color="$(node_color "$i")"
        set="|$(IFS='|'; printf '%s' "${files[*]}")|"
        (
            ssh_node_stdin "$i" 0 "$cmd" < "$fifo" \
                2> >(awk -v p="${color}[${N_NAME[$i]}]${C_RESET} " '!/^Warning: Permanently added/ { print p $0; fflush() }' >&2) \
            | awk -v host="${N_NAME[$i]}" -v c="$color" -v r="$C_RESET" -v root="$CL_ROOT/" -v set="$set" '
                /^==> .* <==$/ {
                    f = substr($0, 5, length($0) - 8)
                    if (index(f, root) == 1 && index(set, "|" substr(f, length(root) + 1) "|") > 0) {
                        cur = substr(f, length(root) + 1); held = 0; next
                    }
                }
                {
                    if (held) { print c "[" host " " cur "]" r " "; held = 0 }
                    if ($0 == "") { held = 1; next }
                    print c "[" host " " cur "]" r " " $0
                    fflush()
                }'
        ) &
        FOLLOW_PIDS+=("$!")
    done
    log_event FOLLOW_START "nodes=$(rhosp_selected_names)" "files=${#CL_FILES[@]}" "initial_lines=$n_init"

    wait "${FOLLOW_PIDS[@]}" 2>/dev/null || true
    echo
    warn "Semua stream follow berakhir (koneksi ke node terputus)."
    finish_follow "stream ended"
    exec {hold_fd}>&-
    return 0
}

# ============================================================
# Menu setelah tail
# ============================================================

# Kembalikan node dan file sebelum [n]ode (batal / tidak ada yang bisa dipakai)
restore_selection() {
    local i
    rhosp_reset_selection
    for i in "${OLD_SEL[@]}"; do select_idx "$i"; done
    CL_FILES=("${OLD_FILES[@]}")
    cl_build_index
    echo "Pilihan node dan file tidak diubah ($(rhosp_selected_names))."
    log_event DECISION menu=node result=unchanged
}

change_nodes() {
    local i
    OLD_SEL=("${SEL[@]}")
    OLD_FILES=("${CL_FILES[@]}")
    rhosp_reset_selection
    if ! rhosp_pick_nodes; then
        restore_selection
        return 0
    fi
    echo "✅ Node terpilih     : ${#SEL[@]} ($(rhosp_selected_names))"
    log_event SELECT "selected=${#SEL[@]}" "nodes=$(rhosp_selected_names)"
    if ! prepare_nodes; then
        warn "Tidak ada node terpilih yang bisa dijangkau; kembali ke pilihan sebelumnya."
        restore_selection
        return 0
    fi
    cl_build_index
    local -a keep=()
    local f
    for f in "${CL_FILES[@]}"; do
        for i in $(cl_ok_nodes); do
            if [[ -n "${CL_HAS["$i|$f"]+x}" ]]; then keep+=("$f"); break; fi
        done
    done
    CL_FILES=("${keep[@]}")
    if (( ${#CL_FILES[@]} == 0 )); then
        info "File sebelumnya tidak ada di node baru; pilih file lagi."
        choose_files || restore_selection
    else
        cl_report_missing
        log_files
    fi
    return 0
}

post_menu() {
    local input
    while true; do
        echo
        ask input "[m]ode  [f]ile  [n]ode  [s]impan  [q] kembali: "
        case "${input,,}" in
            m)
                ask_mode
                return 0
                ;;
            f)
                local -a old=("${CL_FILES[@]}")
                if ! choose_files; then
                    CL_FILES=("${old[@]}")
                    echo "Pilihan file tidak diubah."
                    continue
                fi
                return 0
                ;;
            n)
                change_nodes
                return 0
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

# shellcheck disable=SC2329  # dipanggil lewat LOG_INTERRUPT_HOOK
on_interrupt() {
    echo
    if (( FOLLOW_ACTIVE )); then
        finish_follow "stopped by operator (${1:-INT})"
        echo "${C_CYAN}⏹  Follow dihentikan; semua koneksi SSH ditutup.${C_RESET}"
    else
        cl_kill_bg
        warn "Dihentikan (${1:-INT})."
    fi
}

# shellcheck disable=SC2329  # dipanggil lewat LOG_EXIT_HOOK
on_exit() {
    set +o errexit
    finish_follow "exit"
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
        --inventory) need_arg "$1" "${2:-}"; INVENTORY="$2"; shift 2 ;;
        --node)      need_arg "$1" "${2:-}"; NODE_ARGS+=("$2"); shift 2 ;;
        --role)      need_arg "$1" "${2:-}"; ROLE_ARGS+=("$2"); shift 2 ;;
        --log)       need_arg "$1" "${2:-}"; LOG_ARGS+=("$2"); shift 2 ;;
        --mode)      need_arg "$1" "${2:-}"; MODE="${2,,}"; shift 2 ;;
        --lines)     need_arg "$1" "${2:-}"; TAIL_LINES="$2"; LINES_SET=1; shift 2 ;;
        --save)      SAVE=1; shift ;;
        --keyword|--pattern|--regex|--ignore-case|--include-rotated|--all-logs|--context|--max-per-file)
            echo "❌ $1 tidak tersedia di script ini. Untuk mencari kata kunci gunakan rhosp/search-container-logs.sh."
            log_error -q "opsi pencarian ditolak: $1"
            exit 1
            ;;
        *)
            echo "❌ Parameter tidak dikenal: $1"
            echo
            usage
            exit 1
            ;;
    esac
done

case "$MODE" in
    ""|tail|follow) ;;
    *) die "--mode harus tail atau follow." ;;
esac
if ! is_uint "$TAIL_LINES" || (( TAIL_LINES < 1 || TAIL_LINES > 100000 )); then
    die "--lines harus bilangan bulat 1-100000."
fi
if (( SAVE )) && [[ "$MODE" == "follow" ]]; then
    die "--save tidak berlaku untuk mode follow (hasil follow tidak disimpan)."
fi

has_tty && INTERACTIVE=1
if (( ! INTERACTIVE )); then
    (( ${#NODE_ARGS[@]} > 0 || ${#ROLE_ARGS[@]} > 0 )) || die "Tanpa terminal: --node/--role wajib."
    (( ${#LOG_ARGS[@]} > 0 )) || die "Tanpa terminal: --log wajib."
    [[ -n "$MODE" ]] || MODE="tail"
fi

# ============================================================
# Main
# ============================================================

cl_setup_workdir view-container-logs
LOG_EXIT_HOOK=on_exit
LOG_INTERRUPT_HOOK=on_interrupt

echo "========================================"
echo "📜 View Container Logs"
echo "========================================"

rhosp_check_env warn
for _tool in "${SSH_CMD[0]}" timeout awk mkfifo; do
    command -v "$_tool" >/dev/null 2>&1 || die "$_tool tidak ditemukan."
done
log_event INPUT "mode=${MODE:-ask}" "lines=$TAIL_LINES" "save=$SAVE" "interactive=$INTERACTIVE" \
    "nodes=$(IFS=,; printf '%s' "${NODE_ARGS[*]}")" "roles=$(IFS=,; printf '%s' "${ROLE_ARGS[*]}")" \
    "logs=$(IFS=,; printf '%s' "${LOG_ARGS[*]}")"

rhosp_find_inventory
rhosp_load_nodes
rhosp_select_nodes
prepare_nodes || die "Tidak ada node terpilih yang bisa dijangkau."
choose_files || exit 0

if [[ -z "$MODE" ]]; then
    ask_mode
else
    log_event DECISION "mode=$MODE" "lines=$TAIL_LINES" source=option
fi

while true; do
    if [[ "$MODE" == "follow" ]]; then
        (( SAVE )) && warn "Hasil follow tidak disimpan (--save hanya untuk tail)."
        run_follow
        exit 0
    fi

    run_tail
    if (( SAVE )); then
        save_result
        SAVE=0
    fi
    (( INTERACTIVE )) && [[ -t 1 ]] || break
    post_menu || break
done
[[ -n "$LOG_FILE" ]] && [[ -t 1 ]] && echo "Log: $LOG_FILE"
exit 0
