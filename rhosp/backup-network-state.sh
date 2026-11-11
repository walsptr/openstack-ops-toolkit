#!/bin/bash
# ============================================================
# @name:        Backup Network State
# @description: Backup ip route/rule, iptables, dan nftables dari node overcloud ke undercloud
# @mutates:     no
# @requires:    ssh, jq
# @platform:    rhosp
# @tags:        rhosp, network, firewall, backup
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: backup-network-state.sh [--inventory PATH] [--nodes H1,H2] [--node HOST]...
                               [--role ROLE]... [--all] [--local]
                               [--include-netns] [--counters] [--no-verify]
                               [--parallel N] [--timeout DETIK] [--output-dir DIR]

Backup state jaringan node RHOSP (read-only) ke undercloud:
  routing   ip -4/-6 route show table all, ip -4/-6 rule show (+ versi JSON ip -j)
  iptables  iptables-save, ip6tables-save (backend nf_tables/legacy dicatat)
  nftables  nft list ruleset (semua family)

Di setiap node satu skrip statis dijalankan lewat stdin SSH; hasil dikumpulkan
di direktori mktemp (/tmp/osops-netstate-<run_id>.*), dikirim sebagai tar.gz
lewat stdout SSH, lalu direktori itu dihapus. Script TIDAK pernah mengubah
aturan/route di node (tidak ada restore/flush/route add/del).

Options:
  --inventory PATH    File inventory (melewati pencarian otomatis)
  --nodes H1,H2       Node target, dipisah koma
  --node HOST         Node target (bisa diulang)
  --role ROLE         Semua node dalam role (bisa diulang)
  --all               Semua node overcloud + undercloud (seperti --local);
                      butuh terminal: ketik jumlah node
  --local             Ikut backup host yang menjalankan script (undercloud)
  --include-netns     Ikut backup setiap network namespace (ip netns list):
                      route, rule, iptables, nftables. Lebih dari 50 namespace
                      di satu node => konfirmasi (tanpa terminal: dilewati)
  --counters          Sertakan counter (iptables-save -c, nft list ruleset).
                      Default: tanpa counter (policy chain [0:0], nft -s)
  --no-verify         Lewati verifikasi sintaks di node (iptables-restore --test,
                      ip6tables-restore --test, nft -c -f). sha256 node vs
                      undercloud selalu dicek
  --parallel N        Jumlah node bersamaan (default 4)
  --timeout DETIK     Batas waktu pengambilan per node (default 120)
  --output-dir DIR    Direktori induk backup (default
                      ${OSOPS_BACKUP_DIR:-$HOME/osops-backups}/network-state).
                      Hasil di DIR/<run_id>/ (700, file 600)
  -h, --help          Tampilkan help

Tanpa --nodes/--node/--role/--all/--local, node dipilih lewat picker
(entry "[semua node]" = --all, "[semua <Role>]", "Undercloud (lokal)").

Exit code: 0 semua node SUCCESS/SKIPPED, 1 ada node FAILED.

Environment (terutama untuk tes):
  OSOPS_BACKUP_DIR, OSOPS_SSH, OSOPS_ANSIBLE_INVENTORY, OSOPS_FZF,
  OSOPS_RHOSP_RELEASE_FILE, OSOPS_STACK_HOME
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

# Inventory, pemilihan node, wrapper SSH (lib/rhosp.sh)
# shellcheck source=../lib/rhosp.sh
if ! source "$OSOPS_HOME/lib/rhosp.sh" 2>/dev/null; then
    echo "❌ lib/rhosp.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi
# Kolektor state jaringan, validasi arsip, manifest (lib/netstate.sh)
# shellcheck source=../lib/netstate.sh
if ! source "$OSOPS_HOME/lib/netstate.sh" 2>/dev/null; then
    echo "❌ lib/netstate.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi
RHOSP_WITH_UNDERCLOUD=1
RHOSP_PICK_ALL=1

# ============================================================
# Konfigurasi
# ============================================================

ALL_NODES=0
LOCAL_RUN=0
INCLUDE_NETNS=0
COUNTERS=0
VERIFY=1
PARALLEL=4
TIMEOUT_S=120
OUTPUT_BASE=""

NETNS_CONFIRM=50          # lebih dari ini per node => konfirmasi
PRECHECK_TIMEOUT=30
CLEANUP_TIMEOUT=20

WORK_DIR=""
RUN_DIR=""
STAGE_DIR=""
FINALIZED=0
declare -A WORKER_PIDS=()

# State per node (hook lib/rhosp.sh)
N_RESULT=() N_MSG=() N_NSCOUNT=() N_DONETNS=() N_NSNOTE=() N_STARTED=() N_CLEAN=()
N_BYTES=() N_FILES=() N_DUR=() N_T0=() N_BACKEND=() N_XTSKIP=() N_VERIFY=() N_SKIPNOTE=()

# shellcheck disable=SC2329  # dipanggil oleh rhosp_add_node
rhosp_on_node_added() {
    N_RESULT+=("") N_MSG+=("") N_NSCOUNT+=("") N_DONETNS+=(0) N_NSNOTE+=("") N_STARTED+=(0) N_CLEAN+=(0)
    N_BYTES+=(0) N_FILES+=(0) N_DUR+=(0) N_T0+=(0) N_BACKEND+=("") N_XTSKIP+=(0) N_VERIFY+=("") N_SKIPNOTE+=("")
}

# ============================================================
# Helper
# ============================================================

human() {
    local b="${1:-0}"
    is_uint "$b" || { printf -- '-'; return 0; }
    if (( b >= 1073741824 )); then
        awk -v b="$b" 'BEGIN { printf "%.1fG", b / 1073741824 }'
    elif (( b >= 1048576 )); then
        awk -v b="$b" 'BEGIN { printf "%.1fM", b / 1048576 }'
    elif (( b >= 1024 )); then
        awk -v b="$b" 'BEGIN { printf "%.1fK", b / 1024 }'
    else
        printf '%dB' "$b"
    fi
}

set_result() {
    N_RESULT[$1]="$2"
    N_MSG[$1]="$3"
}

stack_name() {
    if [[ "$INVENTORY" =~ /overcloud-deploy/([^/]+)/tripleo-ansible-inventory\.yaml$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf -- '-'
    fi
}

# ============================================================
# Worker paralel (pola collect-sosreport: maksimal PARALLEL bersamaan)
# ============================================================

# shellcheck disable=SC2329  # dipanggil tidak langsung (run_jobs)
job_precheck() {
    ns_precheck "$1" "$WORK_DIR/p$1" "$PRECHECK_TIMEOUT"
}

# shellcheck disable=SC2329  # dipanggil tidak langsung (run_jobs)
job_collect() {
    ns_collect "$1" "$WORK_DIR/c$1" "$LOG_RUN_ID" "$COUNTERS" "${N_DONETNS[$1]}" "$VERIFY" "$TIMEOUT_S"
}

# run_jobs MODE IDX... — MODE precheck | collect; on_done_MODE IDX setelah selesai
run_jobs() {
    local mode="$1" qi=0 pid i now
    shift
    local -a queue=("$@")
    (( ${#queue[@]} > 0 )) || return 0

    while (( qi < ${#queue[@]} || ${#WORKER_PIDS[@]} > 0 )); do
        while (( ${#WORKER_PIDS[@]} < PARALLEL && qi < ${#queue[@]} )); do
            i="${queue[$qi]}"
            qi=$(( qi + 1 ))
            N_T0[i]="$(date +%s)"
            if [[ "$mode" == collect ]]; then N_STARTED[i]=1; fi
            ( set +o errexit; "job_$mode" "$i" ) &
            WORKER_PIDS[$!]="$i"
            if [[ "$mode" == collect ]]; then echo "  ▶ ${N_NAME[$i]}: mulai"; fi
        done
        sleep 0.5
        now="$(date +%s)"
        for pid in "${!WORKER_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null && continue
            wait "$pid" 2>/dev/null || true
            i="${WORKER_PIDS[$pid]}"
            unset "WORKER_PIDS[$pid]"
            N_DUR[i]=$(( now - N_T0[i] ))
            "on_done_$mode" "$i"
        done
    done
    return 0
}

# shellcheck disable=SC2329  # dipanggil dari hook
kill_workers() {
    local pid
    for pid in "${!WORKER_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && kill_tree "$pid"
        unset "WORKER_PIDS[$pid]"
    done
    return 0
}

# ============================================================
# Pre-check
# ============================================================

# shellcheck disable=SC2329  # dipanggil oleh run_jobs
on_done_precheck() {
    local i="$1" rc out err line sudo_ok="" missing="" ns="" reason
    rc="$(cat "$WORK_DIR/p$i.rc" 2>/dev/null)" || rc=255
    out="$(cat "$WORK_DIR/p$i.out" 2>/dev/null)" || out=""
    err="$(cat "$WORK_DIR/p$i.err" 2>/dev/null)" || err=""

    if [[ "$out" != *__OSOPS_NETSTATE__* ]]; then
        reason="$(ssh_fail_reason "$err" "$rc")"
        if [[ "$reason" == "host key mismatch" ]]; then
            set_result "$i" SKIPPED "$reason"
        else
            set_result "$i" FAILED "$reason"
        fi
        log_event PRECHECK "host=${N_NAME[$i]}" "result=${N_RESULT[$i]}" "reason=$reason" "rc=$rc"
        return 0
    fi
    (( N_LOCAL[i] )) || log_accepted_key "$i"
    while IFS= read -r line; do
        case "$line" in
            sudo=*)    sudo_ok="${line#sudo=}" ;;
            missing=*) missing+="${missing:+,}${line#missing=}" ;;
            netns=*)   ns="${line#netns=}" ;;
        esac
    done <<< "$out"
    is_uint "$ns" || ns=0
    N_NSCOUNT[i]="$ns"
    if [[ "$sudo_ok" != ok ]]; then
        set_result "$i" FAILED "sudo failed (sudo -n)"
    elif [[ -n "$missing" ]]; then
        set_result "$i" FAILED "missing tools on node: $missing"
    fi
    log_event PRECHECK "host=${N_NAME[$i]}" "result=${N_RESULT[$i]:-OK}" "reason=${N_MSG[$i]:--}" \
        "sudo=${sudo_ok:--}" "netns=$ns" "addr=$(rhosp_node_addr "$i")"
}

precheck_nodes() {
    local i st
    local -a todo=()
    echo
    echo "${C_BOLD}🔍 Pre-check node...${C_RESET}"
    for i in "${SEL[@]}"; do
        if [[ "${N_HK[$i]}" == "reject" ]]; then
            set_result "$i" SKIPPED "host key unknown (not accepted)"
            log_event PRECHECK "host=${N_NAME[$i]}" result=SKIPPED "reason=${N_MSG[$i]}"
        else
            todo+=("$i")
        fi
    done
    run_jobs precheck "${todo[@]}"
    rhosp_report_fallbacks "${SEL[@]}"
    for i in "${SEL[@]}"; do
        case "${N_RESULT[$i]}" in
            "")      st="${C_GREEN}OK${C_RESET}$( (( INCLUDE_NETNS )) && printf ' (%s netns)' "${N_NSCOUNT[$i]}"; true)" ;;
            SKIPPED) st="${C_YELLOW}SKIPPED (${N_MSG[$i]})${C_RESET}" ;;
            *)       st="${C_RED}${N_RESULT[$i]} (${N_MSG[$i]})${C_RESET}" ;;
        esac
        printf '  %-28s %-20s %s\n' "${N_NAME[$i]}" "${N_ROLE[$i]}" "$st"
    done
    return 0
}

# Namespace: lebih dari NETNS_CONFIRM per node => konfirmasi per node
decide_netns() {
    local i answer
    (( INCLUDE_NETNS )) || return 0
    for i in "${SEL[@]}"; do
        [[ -z "${N_RESULT[$i]}" ]] || continue
        N_DONETNS[i]=1
        (( N_NSCOUNT[i] > NETNS_CONFIRM )) || continue
        if ! has_tty; then
            N_DONETNS[i]=0
            N_NSNOTE[i]="${N_NSCOUNT[$i]} namespaces > $NETNS_CONFIRM, no terminal for confirmation"
            warn "${N_NAME[$i]}: ${N_NSCOUNT[$i]} namespace (> $NETNS_CONFIRM), tanpa terminal: namespace dilewati."
            log_event DECISION "host=${N_NAME[$i]}" netns=skip "count=${N_NSCOUNT[$i]}" reason=no-tty
            continue
        fi
        ask answer "⚠️  ${N_NAME[$i]}: ${N_NSCOUNT[$i]} network namespace (> $NETNS_CONFIRM). Ikut backup semua namespace di node ini? [y/N]: "
        if is_yes "$answer"; then
            log_event DECISION "host=${N_NAME[$i]}" netns=include "count=${N_NSCOUNT[$i]}"
        else
            N_DONETNS[i]=0
            N_NSNOTE[i]="${N_NSCOUNT[$i]} namespaces > $NETNS_CONFIRM, declined"
            log_event DECISION "host=${N_NAME[$i]}" netns=skip "count=${N_NSCOUNT[$i]}" reason=declined
        fi
    done
    return 0
}

# ============================================================
# Penerimaan hasil di undercloud
# ============================================================

# Proses hasil satu node => <run>/<host>/, items-IDX.tsv (lib/netstate.sh)
# shellcheck disable=SC2329  # dipanggil oleh run_jobs
on_done_collect() {
    local i="$1" stage host_dir backend
    local items="$WORK_DIR/items-$i.tsv"

    host_dir="$RUN_DIR/${N_NAME[$i]}"
    stage="$STAGE_DIR/$i"
    : > "$items"

    ns_receive "${N_NAME[$i]}" "$WORK_DIR/c$i" "$stage" "$host_dir" "${N_LOCAL[$i]}" "$TIMEOUT_S"
    if [[ -n "$NS_RX_MSG" ]]; then
        set_result "$i" FAILED "$NS_RX_MSG"
        if [[ "$NS_RX_MSG" == "host directory exists: "* ]]; then
            N_CLEAN[i]=1
            printf '%s\t-\tFAILED\t%s\t-\t-\n' "${N_NAME[$i]}" "${N_MSG[$i]}" >> "$items"
            log_result "resource=${N_NAME[$i]}" action=lookup result=FAILED "reason=host directory exists"
            return 0
        fi
        N_CLEAN[i]=0
        printf '%s\t-\tFAILED\t%s\t-\t-\n' "${N_NAME[$i]}" "${N_MSG[$i]}" >> "$items"
        log_result "resource=${N_NAME[$i]}" action=lookup result=FAILED "reason=${N_MSG[$i]}" \
            "rc=$(cat "$WORK_DIR/c$i.rc" 2>/dev/null || echo 255)" "duration=${N_DUR[$i]}s"
        echo "  ${C_RED}❌ ${N_NAME[$i]}: FAILED (${N_MSG[$i]})${C_RESET}"
        return 0
    fi
    N_CLEAN[i]=1

    ns_items "${N_NAME[$i]}" "$stage" "$host_dir" "$items" "${N_NSNOTE[$i]}"
    N_SKIPNOTE[i]="$NS_SKIPNOTE"
    N_VERIFY[i]="$NS_VERIFY"
    N_XTSKIP[i]="$NS_XTSKIP"

    backend="$(ns_backend "$(ns_meta_get "$stage/_meta.env" iptables_version)")"
    N_BACKEND[i]="$backend"

    ns_write_meta "$host_dir/meta.json" "$stage" "${N_NAME[$i]}" "${N_ROLE[$i]}" "$LOG_RUN_ID" "$backend" \
        "$(rhosp_node_addr "$i")" "$COUNTERS" "${N_DONETNS[$i]}" "$VERIFY" \
        || log_warn -q "${N_NAME[$i]}: meta.json gagal ditulis"
    N_FILES[i]="$(find "$host_dir" -type f | wc -l)"
    N_BYTES[i]="$(du -sb -- "$host_dir" 2>/dev/null | awk '{print $1}')"
    rm -rf -- "$stage"

    if (( NS_N_FAIL > 0 )); then
        set_result "$i" FAILED "$NS_N_FAIL item(s) failed"
    else
        set_result "$i" SUCCESS ""
    fi
    log_result "resource=${N_NAME[$i]}" action=lookup "result=${N_RESULT[$i]}" "items_ok=$NS_N_OK" \
        "items_skipped=$NS_N_SKIP" "items_failed=$NS_N_FAIL" "files=${N_FILES[$i]}" "bytes=${N_BYTES[$i]}" \
        "backend=$backend" "verify=${NS_VERIFY:--}" "path=$host_dir" "duration=${N_DUR[$i]}s"
    if [[ "${N_RESULT[$i]}" == SUCCESS ]]; then
        echo "  ${C_GREEN}✅ ${N_NAME[$i]}: SUCCESS (${N_FILES[$i]} file, $(human "${N_BYTES[$i]}"), ${N_DUR[$i]}s)${C_RESET}"
    else
        echo "  ${C_RED}❌ ${N_NAME[$i]}: FAILED (${N_MSG[$i]})${C_RESET}"
    fi
    return 0
}

# ============================================================
# Manifest, ringkasan
# ============================================================

finalize_run() {
    local i f
    (( FINALIZED )) && return 0
    FINALIZED=1
    [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]] || return 0
    if [[ -n "$STAGE_DIR" ]]; then rm -rf -- "$STAGE_DIR"; fi

    for i in "${SEL[@]}"; do
        f="$WORK_DIR/items-$i.tsv"
        if [[ -s "$f" ]]; then
            cat "$f"
        elif [[ -n "${N_RESULT[$i]}" ]]; then
            printf '%s\t-\t%s\t%s\t-\t-\n' "${N_NAME[$i]}" "${N_RESULT[$i]}" "${N_MSG[$i]}"
        fi
    done | ns_write_manifest "$RUN_DIR" \
        "# Backup Network State run=$LOG_RUN_ID created=$(date -Iseconds) counters=$COUNTERS netns=$INCLUDE_NETNS verify=$VERIFY" \
        || log_warn -q "MANIFEST.tsv gagal ditulis"
    ns_write_sums "$RUN_DIR" || log_warn -q "SHA256SUMS gagal ditulis"
    return 0
}

summary() {
    local i color n_ok=0 n_fail=0 n_skip=0 total xt=""
    echo
    echo "${C_BOLD}========================================${C_RESET}"
    echo "${C_BOLD}📊 Ringkasan${C_RESET}"
    echo "${C_BOLD}========================================${C_RESET}"
    printf '%-28s %-20s %-8s %-10s %6s %8s %6s  %s\n' HOSTNAME ROLE RESULT BACKEND FILE SIZE DURASI "VERIFIKASI / PESAN"
    for i in "${SEL[@]}"; do
        case "${N_RESULT[$i]}" in
            SUCCESS) color="$C_GREEN"; n_ok=$(( n_ok + 1 )) ;;
            SKIPPED) color="$C_YELLOW"; n_skip=$(( n_skip + 1 )) ;;
            *)       color="$C_RED"; n_fail=$(( n_fail + 1 )) ;;
        esac
        printf '%-28s %-20s %s%-8s%s %-10s %6s %8s %6s  %s\n' "${N_NAME[$i]}" "${N_ROLE[$i]}" \
            "$color" "${N_RESULT[$i]:-ABORTED}" "$C_RESET" "${N_BACKEND[$i]:--}" "${N_FILES[$i]}" \
            "$(human "${N_BYTES[$i]}")" "${N_DUR[$i]}s" \
            "$(if [[ -n "${N_MSG[$i]}" ]]; then printf '%s' "${N_MSG[$i]}"; elif (( VERIFY )); then printf 'verify: %s' "${N_VERIFY[$i]:--}"; else printf 'verify: off'; fi)"
        if [[ -n "${N_SKIPNOTE[$i]}" ]]; then printf '    %sdilewati: %s%s\n' "$C_DIM" "${N_SKIPNOTE[$i]}" "$C_RESET"; fi
        (( N_XTSKIP[i] )) && xt+="${xt:+, }${N_NAME[$i]}"
        if [[ "${N_RESULT[$i]}" == FAILED && -s "$WORK_DIR/items-$i.tsv" ]]; then
            awk -F'\t' '$3 == "FAILED" && $2 != "-" { printf "    gagal: %s (%s)\n", $2, $4 }' "$WORK_DIR/items-$i.tsv" | head -n 10
        fi
    done
    echo
    if [[ -n "$xt" ]]; then
        echo "${C_YELLOW}Verifikasi nft di-SKIP (ruleset berisi ekspresi xt dari iptables-nft; restore tabel itu lewat iptables-restore, bukan nft -f): $xt${C_RESET}"
    fi
    echo "Snapshot tidak atomik: setiap perintah punya timestamp sendiri (meta.json)."
    total="$( [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]] && du -sb -- "$RUN_DIR" 2>/dev/null | awk '{print $1}')" || total=0
    echo "Berhasil     : $n_ok / ${#SEL[@]} (gagal: $n_fail, dilewati: $n_skip)"
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
        echo "Backup       : $RUN_DIR"
        echo "Ukuran total : $(human "${total:-0}")"
        echo "Manifest     : $RUN_DIR/MANIFEST.tsv, $RUN_DIR/SHA256SUMS"
    fi
    if [[ -n "$LOG_FILE" ]]; then echo "Log          : $LOG_FILE"; fi
    log_info "SUMMARY nodes=${#SEL[@]} success=$n_ok failed=$n_fail skipped=$n_skip bytes=${total:-0} nft_verify_xt_skipped=${xt:--} path=${RUN_DIR:--}"
    SUMMARY_FAILED=$n_fail
}

# ============================================================
# Pembersihan direktori sementara di node (hook)
# ============================================================

# Node yang pengambilannya dimulai tetapi tidak selesai bersih: hapus
# /tmp/osops-netstate-<run_id>.* milik user SSH (paralel, dibatasi waktu).
cleanup_remote() {
    local i cmd out left
    local -a idx=() pids=()
    cmd="$(ns_cleanup_cmd "$LOG_RUN_ID")" || return 0
    for i in "${SEL[@]}"; do
        if (( N_STARTED[i] && ! N_CLEAN[i] )); then idx+=("$i"); fi
    done
    (( ${#idx[@]} > 0 )) || return 0
    echo "🧹 Membersihkan direktori sementara di ${#idx[@]} node..."
    for i in "${idx[@]}"; do
        (
            set +o errexit
            if (( N_LOCAL[i] )); then
                timeout --kill-after=5 "$CLEANUP_TIMEOUT" bash -c "$cmd" < /dev/null > "$WORK_DIR/x$i.out" 2>/dev/null
            else
                ssh_node "$i" "$CLEANUP_TIMEOUT" "$cmd" > "$WORK_DIR/x$i.out" 2>/dev/null
            fi
        ) &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
    for i in "${idx[@]}"; do
        out="$(cat "$WORK_DIR/x$i.out" 2>/dev/null)" || out=""
        left="$(sed -n 's/^left=\([0-9]*\)$/\1/p' <<< "$out" | tail -n 1)"
        if [[ "$left" == 0 ]]; then
            log_event CLEANUP "host=${N_NAME[$i]}" result=SUCCESS left=0
        else
            warn "${N_NAME[$i]}: pembersihan /tmp/$NS_PREFIX-$LOG_RUN_ID.* tidak terverifikasi (sisa: ${left:-?})."
            log_event CLEANUP "host=${N_NAME[$i]}" result=FAILED "left=${left:--}"
        fi
    done
    return 0
}

# shellcheck disable=SC2329  # dipanggil lewat LOG_INTERRUPT_HOOK
on_interrupt() {
    local pid i
    for pid in "${!WORKER_PIDS[@]}"; do
        i="${WORKER_PIDS[$pid]}"
        set_result "$i" FAILED "interrupted (${1:-INT})"
        log_result "resource=${N_NAME[$i]}" action=lookup result=ABORTED "msg=stopped by operator (${1:-INT})"
    done
    kill_workers
    echo
    warn "Dihentikan (${1:-INT})."
}

# shellcheck disable=SC2329  # dipanggil lewat LOG_EXIT_HOOK
on_exit() {
    set +o errexit
    kill_workers
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        cleanup_remote
        if (( ! FINALIZED )) && [[ -n "$RUN_DIR" ]]; then
            finalize_run
            if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then echo "Backup sebagian: $RUN_DIR"; fi
        fi
        rm -rf -- "$WORK_DIR"
    fi
    return 0
}

# ============================================================
# Semua node (--all atau entry "[semua node]" di picker)
# ============================================================

# confirm_all_nodes LABEL — pilih semua node overcloud + undercloud, tampilkan
# daftar (undercloud di baris terpisah), konfirmasi dengan mengetik jumlah node
confirm_all_nodes() {
    local label="$1" i n_oc answer=""
    LOCAL_RUN=1
    rhosp_reset_selection
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) || select_idx "$i"
    done
    n_oc=${#SEL[@]}
    select_idx "$UC_IDX"
    echo
    warn "$label: ${#SEL[@]} node akan dibackup ($n_oc node overcloud + undercloud):"
    for i in "${SEL[@]}"; do
        (( N_LOCAL[i] )) && continue
        printf '     %-28s %-20s %s\n' "${N_NAME[$i]}" "${N_ROLE[$i]}" "${N_IP[$i]}"
    done
    echo "     ----"
    printf '     %-28s %-20s %s\n' "${N_NAME[$UC_IDX]}" "Undercloud" "lokal (host ini)"
    ask answer "Ketik jumlah node (${#SEL[@]}) untuk melanjutkan: "
    if [[ "$(trim "$answer")" != "${#SEL[@]}" ]]; then
        log_event DECISION all=cancel "via=$label" "count=${#SEL[@]}"
        echo "❌ Dibatalkan."
        exit 0
    fi
    log_event DECISION all=confirm "via=$label" "count=${#SEL[@]}"
    log_event SELECT "selected=${#SEL[@]}" "nodes=$(rhosp_selected_names)"
}

# ============================================================
# Argumen
# ============================================================

need_arg() {
    [[ -n "${2:-}" ]] || die "$1 membutuhkan nilai."
}

while (( $# > 0 )); do
    case "$1" in
        --inventory)     need_arg "$1" "${2:-}"; INVENTORY="$2"; shift 2 ;;
        --nodes)
            need_arg "$1" "${2:-}"
            IFS=',' read -ra _nodes <<< "$2"
            for _n in "${_nodes[@]}"; do
                _n="$(trim "$_n")"
                if [[ -n "$_n" ]]; then NODE_ARGS+=("$_n"); fi
            done
            shift 2 ;;
        --node)          need_arg "$1" "${2:-}"; NODE_ARGS+=("$2"); shift 2 ;;
        --role)          need_arg "$1" "${2:-}"; ROLE_ARGS+=("$2"); shift 2 ;;
        --all)           ALL_NODES=1; shift ;;
        --local)         LOCAL_RUN=1; shift ;;
        --include-netns) INCLUDE_NETNS=1; shift ;;
        --counters)      COUNTERS=1; shift ;;
        --no-verify)     VERIFY=0; shift ;;
        --parallel)      need_arg "$1" "${2:-}"; PARALLEL="$2"; shift 2 ;;
        --timeout)       need_arg "$1" "${2:-}"; TIMEOUT_S="$2"; shift 2 ;;
        --output-dir)    need_arg "$1" "${2:-}"; OUTPUT_BASE="$2"; shift 2 ;;
        *)
            echo "❌ Parameter tidak dikenal: $1"
            echo
            usage
            exit 1
            ;;
    esac
done

if ! is_uint "$PARALLEL" || (( PARALLEL < 1 || PARALLEL > 64 )); then
    die "--parallel harus bilangan bulat 1-64."
fi
if ! is_uint "$TIMEOUT_S" || (( TIMEOUT_S < 10 || TIMEOUT_S > 3600 )); then
    die "--timeout harus bilangan bulat (detik) 10-3600."
fi
if (( ALL_NODES )) && (( ${#NODE_ARGS[@]} > 0 || ${#ROLE_ARGS[@]} > 0 )); then
    die "--all tidak bisa digabung dengan --nodes/--node/--role."
fi
if ! has_tty; then
    (( ALL_NODES )) && die "--all butuh terminal untuk konfirmasi jumlah node. Tanpa terminal gunakan --nodes/--role."
    (( ${#NODE_ARGS[@]} > 0 || ${#ROLE_ARGS[@]} > 0 || LOCAL_RUN )) || \
        die "Tanpa terminal: --nodes/--node/--role atau --local wajib."
fi
if [[ ! "${LOG_RUN_ID:-}" =~ $NS_RUN_ID_RE ]]; then
    die "run_id tidak valid untuk path/perintah remote: '${LOG_RUN_ID:-}' (pola ${NS_RUN_ID_RE})."
fi
if [[ -z "$OUTPUT_BASE" ]]; then OUTPUT_BASE="${OSOPS_BACKUP_DIR:-$HOME/osops-backups}/network-state"; fi

# ============================================================
# Main
# ============================================================

WORK_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/backup-network-state.XXXXXX")" || die "Gagal membuat direktori sementara."
RHOSP_WORK_DIR="$WORK_DIR"
LOG_EXIT_HOOK=on_exit
LOG_INTERRUPT_HOOK=on_interrupt
SUMMARY_FAILED=0

echo "========================================"
echo "🌐 Backup Network State"
echo "========================================"

rhosp_check_env warn
for _tool in "${SSH_CMD[0]}" timeout tar gzip sha256sum du stat find; do
    command -v "$_tool" >/dev/null 2>&1 || die "$_tool tidak ditemukan."
done

# Direktori induk backup: dibuat 700 jika belum ada; isi lama tidak disentuh
if [[ -e "$OUTPUT_BASE" && ! -d "$OUTPUT_BASE" ]]; then
    die "--output-dir bukan direktori: $OUTPUT_BASE"
fi
( umask 077; mkdir -p -- "$OUTPUT_BASE" ) 2>/dev/null || die "Tidak bisa membuat direktori backup: $OUTPUT_BASE"
[[ -w "$OUTPUT_BASE" && -x "$OUTPUT_BASE" ]] || die "Direktori backup tidak bisa ditulis: $OUTPUT_BASE"
OUTPUT_BASE="$(cd "$OUTPUT_BASE" && pwd -P)"
if [[ -e "$OUTPUT_BASE/$LOG_RUN_ID" ]]; then
    die "Direktori backup untuk run ini sudah ada: $OUTPUT_BASE/$LOG_RUN_ID (tidak ditimpa)."
fi

log_event INPUT "output_dir=$OUTPUT_BASE" "all=$ALL_NODES" "local=$LOCAL_RUN" "include_netns=$INCLUDE_NETNS" \
    "counters=$COUNTERS" "verify=$VERIFY" "parallel=$PARALLEL" "timeout=$TIMEOUT_S" \
    "nodes=$(IFS=,; printf '%s' "${NODE_ARGS[*]}")" "roles=$(IFS=,; printf '%s' "${ROLE_ARGS[*]}")"

rhosp_find_inventory
rhosp_load_nodes

# Pemilihan node
if (( ALL_NODES )); then
    confirm_all_nodes "--all"
elif (( LOCAL_RUN )) && (( ${#NODE_ARGS[@]} == 0 && ${#ROLE_ARGS[@]} == 0 )); then
    select_idx "$UC_IDX"
    echo "✅ Node terpilih     : 1 (${N_NAME[$UC_IDX]}, lokal)"
    log_event SELECT selected=1 "nodes=${N_NAME[$UC_IDX]}"
else
    INCLUDE_UC="$LOCAL_RUN"
    rhosp_select_nodes
    # Entry "[semua node]" di picker = --all (konfirmasi yang sama)
    if (( RHOSP_PICKED_ALL )); then confirm_all_nodes "[semua node]"; fi
fi
# Nama host dipakai sebagai nama direktori
for _i in "${SEL[@]}"; do
    [[ "${N_NAME[$_i]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Nama host tidak valid untuk direktori: ${N_NAME[$_i]//[^A-Za-z0-9._-]/?}"
done

_hk=()
for _i in "${SEL[@]}"; do
    (( N_LOCAL[_i] )) || _hk+=("$_i")
done
(( ${#_hk[@]} > 0 )) && check_host_keys "node terpilih" "${_hk[@]}"

echo
echo "${C_BOLD}📋 Rencana${C_RESET}"
echo "  Region     : ${OS_REGION_NAME:--}"
echo "  Stack      : $(stack_name)"
echo "  Inventory  : $INVENTORY"
echo "  Node       : ${#SEL[@]}"
for _i in "${SEL[@]}"; do
    printf '    %-28s %-20s %s\n' "${N_NAME[$_i]}" "${N_ROLE[$_i]}" "$( (( N_LOCAL[_i] )) && echo lokal || echo "${N_IP[$_i]}")"
done
echo "  Data       : route/rule (v4+v6, JSON), iptables/ip6tables, nftables$( (( INCLUDE_NETNS )) && echo ', + network namespace')"
echo "  Counter    : $( (( COUNTERS )) && echo ya || echo 'tidak (policy [0:0], nft -s)')"
echo "  Verifikasi : $( (( VERIFY )) && echo 'iptables-restore --test, ip6tables-restore --test, nft -c -f (tidak menerapkan aturan)' || echo off) + sha256 node vs undercloud"
echo "  Paralel    : $PARALLEL, timeout ${TIMEOUT_S}s per node"
echo "  Tujuan     : $OUTPUT_BASE/$LOG_RUN_ID/"
log_event PLAN "region=${OS_REGION_NAME:--}" "stack=$(stack_name)" "nodes=$(rhosp_selected_names)"

precheck_nodes
decide_netns

_todo=()
for _i in "${SEL[@]}"; do
    if [[ -z "${N_RESULT[$_i]}" ]]; then _todo+=("$_i"); fi
done

if (( ${#_todo[@]} > 0 )); then
    RUN_DIR="$OUTPUT_BASE/$LOG_RUN_ID"
    mkdir -m 700 -- "$RUN_DIR" 2>/dev/null || die "Tidak bisa membuat $RUN_DIR (sudah ada atau tidak bisa ditulis)."
    STAGE_DIR="$RUN_DIR/.staging"
    mkdir -m 700 -- "$STAGE_DIR" || die "Tidak bisa membuat $STAGE_DIR."
    log_event OUTPUT "dir=$RUN_DIR"
    echo
    echo "${C_BOLD}▶ Mengambil state jaringan (${#_todo[@]} node)${C_RESET}"
    run_jobs collect "${_todo[@]}"
else
    echo
    echo "Tidak ada node yang bisa dibackup."
fi

# Node gagal/timeout: pastikan direktori sementara di node terhapus
cleanup_remote
for _i in "${SEL[@]}"; do
    N_STARTED[_i]=0
done
finalize_run
summary
(( SUMMARY_FAILED > 0 )) && exit 1
exit 0
