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
  --all               Semua node overcloud (butuh terminal: ketik jumlah node)
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
(entry "[semua <Role>]", "Undercloud (lokal)").

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
RHOSP_WITH_UNDERCLOUD=1

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
REMOTE_PREFIX="osops-netstate"
# run_id dipakai di path dan perintah remote: pola ketat (tanpa titik, glob, spasi)
RUN_ID_RE='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
NS_RE='[A-Za-z0-9][A-Za-z0-9._:@-]{0,254}'
ITEM_RE='routes-v[46]\.(txt|json)|rules-v[46]\.(txt|json)|iptables-v[46]\.rules|nftables\.ruleset'
NS_ITEM_RE='routes-v[46]\.txt|rules-v[46]\.txt|iptables-v[46]\.rules|nftables\.ruleset'
XT_REASON="iptables-nft compat (xt): restore via iptables-restore"

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
# Skrip remote (statis). Dijalankan di node sebagai user SSH:
#   timeout -k 10 T bash -c "$(cat)" osops-netstate RUN_ID COUNTERS NETNS VERIFY T
# Argumen hanya run_id tervalidasi dan angka; tidak ada input user di
# perintah remote. sudo hanya untuk perintah yang butuh root
# (iptables-save, ip6tables-save, nft, ip -n / ip netns exec, verifikasi);
# ip route/rule berjalan tanpa sudo. Output perintah ditulis oleh shell user
# SSH (file milik user, bukan root), sehingga direktori sementara bisa dihapus
# tanpa sudo. Hasil: tar.gz di stdout (stdout tidak dipakai untuk hal lain).
#
# Verifikasi (VERIFY=1) TIDAK menerapkan aturan:
#  - iptables-restore --test / ip6tables-restore --test: mode test memanggil
#    abort, bukan commit (xtables-restore.c). Backend nf_tables (RHEL 9):
#    batch nftables dibuat di userspace dan tidak pernah dikirim untuk
#    commit; backend legacy: iptc_commit tidak dipanggil. Dicek nyata dengan
#    iptables v1.8.11 (nf_tables) di netns terisolasi: ruleset tidak berubah,
#    juga untuk file yang berisi aturan berbeda. Keterbatasan: di nf_tables
#    --test hanya memeriksa sintaks (opsi tidak dikenal, COMMIT hilang);
#    chain/target yang tidak ada TIDAK terdeteksi.
#  - nft -c -f FILE (--check): batch dikirim ke kernel untuk divalidasi lalu
#    dibatalkan (tanpa commit). Dicek nyata dengan nftables v1.1.6, termasuk
#    file berisi "flush ruleset": ruleset tidak berubah.
#  - Ruleset dengan ekspresi xt (iptables-nft compat, "xt match"/"xt target")
#    tidak bisa dimuat nft -f: verifikasi nft di-SKIP dengan alasan; tabel
#    itu di-restore lewat iptables-restore.
#  Pesan error nft memuat isi aturan: yang disimpan hanya "line N: Error: ...".
#
# Snapshot TIDAK atomik: tiap perintah punya timestamp sendiri (_status.tsv).
# ============================================================
# shellcheck disable=SC2016  # dievaluasi di node
REMOTE_SCRIPT='set -u
umask 077
export LC_ALL=C
RUN="${1:-}" CNT="${2:-0}" NSF="${3:-0}" VFY="${4:-0}" CT="${5:-60}"
case "$RUN" in [A-Za-z0-9]*) ;; *) echo "osops: invalid run id" >&2; exit 2 ;; esac
case "$RUN" in *[!A-Za-z0-9_-]*) echo "osops: invalid run id" >&2; exit 2 ;; esac
for v in "$CNT" "$NSF" "$VFY" "$CT"; do
    case "$v" in ""|*[!0-9]*) echo "osops: invalid argument" >&2; exit 2 ;; esac
done
for t in mktemp tar gzip sha256sum timeout; do
    command -v "$t" >/dev/null 2>&1 || { echo "osops: $t not found" >&2; exit 3; }
done
D="$(mktemp -d "/tmp/osops-netstate-$RUN.XXXXXX")" || { echo "osops: mktemp failed" >&2; exit 3; }
trap '"'"'cd /; rm -rf -- "$D"'"'"' EXIT
trap '"'"'exit 129'"'"' HUP
trap '"'"'exit 130'"'"' INT
trap '"'"'exit 143'"'"' TERM
trap '"'"'exit 141'"'"' PIPE
O="$D/b"
E="$D/err"
mkdir "$O" || exit 3
ST="$O/_status.tsv"
: > "$ST"
SC=""
[ "$CNT" = 1 ] && SC="-c"

one() { tr "\t\r\n" "   " | cut -c1-300; }
# rec ITEM STATUS REASON RC START END [ERRFILE]
rec() {
    er=""
    [ -n "${7:-}" ] && [ -s "$7" ] && er="$(head -n 3 "$7" | one)"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$4" "$5" "$6" "$er" >> "$ST"
}
now() { date +%s; }

# item ITEM KIND CMD... — stdout => $O/ITEM. KIND: x | v6 | ipt (main namespace),
# ns | nsv6 | nsipt (di dalam network namespace)
item() {
    it="$1" k="$2"
    shift 2
    s="$(now)" rc=0
    "$@" > "$O/$it" 2> "$E" < /dev/null || rc=$?
    t="$(now)"
    if [ "$rc" -eq 0 ]; then
        if { [ "$k" = ipt ] || [ "$k" = nsipt ]; } && [ "$CNT" != 1 ]; then
            sed -i -E "s/^(:[^ ]+ [^ ]+) \[[0-9]+:[0-9]+\]\$/\1 [0:0]/" "$O/$it"
        fi
        rec "$it" OK "" 0 "$s" "$t" "$E"
        return 0
    fi
    rm -f -- "$O/$it"
    if [ "$rc" -eq 127 ]; then
        rec "$it" SKIPPED "not installed" "$rc" "$s" "$t" "$E"
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        rec "$it" FAILED "timeout" "$rc" "$s" "$t" "$E"
    elif grep -q "^sudo:" "$E"; then
        rec "$it" FAILED "sudo failed" "$rc" "$s" "$t" "$E"
    elif { [ "$k" = ns ] || [ "$k" = nsv6 ] || [ "$k" = nsipt ]; } && grep -qE "Cannot open network namespace|No such file or directory" "$E"; then
        rec "$it" SKIPPED "namespace vanished" "$rc" "$s" "$t" "$E"
    elif { [ "$k" = v6 ] || [ "$k" = nsv6 ]; } && grep -qiE "not supported|Address family" "$E"; then
        rec "$it" SKIPPED "ipv6 not available" "$rc" "$s" "$t" "$E"
    else
        rec "$it" FAILED "command failed (rc=$rc)" "$rc" "$s" "$t" "$E"
    fi
    return 0
}

# vfy FILE KIND [NS] — verifikasi sintaks; tidak menerapkan aturan (lihat atas)
vfy() {
    f="$1" k="$2" n="${3:-}" it="verify:$1" in=/dev/null
    if [ ! -f "$O/$f" ]; then
        rec "$it" SKIPPED "no backup file" 0 0 0
        return 0
    fi
    case "$k" in
        ipt4) set -- iptables-restore --test -w 5; in="$O/$f" ;;
        ipt6) set -- ip6tables-restore --test -w 5; in="$O/$f" ;;
        nft)
            if grep -qE "(^|[[:space:]])xt (match|target)[[:space:]]" "$O/$f"; then
                rec "$it" SKIPPED "iptables-nft compat (xt): restore via iptables-restore" 0 "$(now)" "$(now)"
                return 0
            fi
            set -- nft -c -f "$O/$f" ;;
    esac
    [ -n "$n" ] && set -- ip netns exec "$n" "$@"
    s="$(now)" rc=0
    sudo -n timeout "$CT" "$@" < "$in" > /dev/null 2> "$E.raw" || rc=$?
    t="$(now)"
    # Hanya posisi + pesan error (pesan nft memuat isi aturan)
    grep -E "^[^ ]*:[0-9]+:[0-9-]+: Error: |line [0-9]+|^sudo:|unknown option|COMMIT expected" "$E.raw" \
        | sed -E "s#^[^ ]*:([0-9]+):[0-9-]+: Error: #line \1: Error: #" | head -n 3 > "$E"
    if [ "$rc" -eq 0 ]; then
        rec "$it" OK "" 0 "$s" "$t"
    elif [ "$k" = nft ] && grep -q "unsupported xtables compat" "$E.raw"; then
        rec "$it" SKIPPED "iptables-nft compat (xt): restore via iptables-restore" "$rc" "$s" "$t"
    elif [ "$rc" -eq 127 ]; then
        rec "$it" SKIPPED "not installed" "$rc" "$s" "$t"
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        rec "$it" FAILED "verify timeout" "$rc" "$s" "$t" "$E"
    elif grep -q "^sudo:" "$E.raw"; then
        rec "$it" FAILED "sudo failed" "$rc" "$s" "$t" "$E"
    else
        rec "$it" FAILED "verify failed (rc=$rc)" "$rc" "$s" "$t" "$E"
    fi
    rm -f -- "$E.raw"
    return 0
}

{
    printf "hostname=%s\n" "$(hostname -f 2>/dev/null || hostname)"
    printf "epoch=%s\n" "$(date +%s)"
    printf "iso=%s\n" "$(date -Iseconds)"
    printf "kernel=%s\n" "$(uname -r)"
    printf "user=%s\n" "$(id -un)"
    printf "ip_version=%s\n" "$(timeout 10 ip -V 2>/dev/null | head -n 1)"
    printf "iptables_version=%s\n" "$(timeout 10 iptables --version 2>/dev/null | head -n 1)"
    printf "nft_version=%s\n" "$(timeout 10 nft --version 2>/dev/null | head -n 1)"
} 2>/dev/null | tr -d "\r" > "$O/_meta.env"

# Routing (tanpa sudo)
item routes-v4.txt x timeout "$CT" ip -4 route show table all
item routes-v6.txt v6 timeout "$CT" ip -6 route show table all
item rules-v4.txt x timeout "$CT" ip -4 rule show
item rules-v6.txt v6 timeout "$CT" ip -6 rule show
if timeout 10 ip -j link show lo >/dev/null 2>&1; then
    echo "ip_json=1" >> "$O/_meta.env"
    item routes-v4.json x timeout "$CT" ip -j -4 route show table all
    item routes-v6.json v6 timeout "$CT" ip -j -6 route show table all
    item rules-v4.json x timeout "$CT" ip -j -4 rule show
    item rules-v6.json v6 timeout "$CT" ip -j -6 rule show
else
    echo "ip_json=0" >> "$O/_meta.env"
    for j in routes-v4.json routes-v6.json rules-v4.json rules-v6.json; do
        rec "$j" SKIPPED "ip -j not supported" 0 "$(now)" "$(now)"
    done
fi

# Firewall (butuh root)
item iptables-v4.rules ipt sudo -n timeout "$CT" iptables-save $SC
item iptables-v6.rules ipt sudo -n timeout "$CT" ip6tables-save $SC
if [ "$CNT" = 1 ]; then
    item nftables.ruleset x sudo -n timeout "$CT" nft list ruleset
else
    item nftables.ruleset x sudo -n timeout "$CT" nft -s list ruleset
fi

if [ "$VFY" = 1 ]; then
    vfy iptables-v4.rules ipt4
    vfy iptables-v6.rules ipt6
    vfy nftables.ruleset nft
fi

# Network namespace: nama dari ip netns list, hanya nama aman yang dipakai
if [ "$NSF" = 1 ]; then
    s0="$(now)" rc=0
    timeout "$CT" ip netns list > "$D/nslist" 2> "$E" < /dev/null || rc=$?
    if [ "$rc" -eq 127 ]; then
        rec netns SKIPPED "not installed" "$rc" "$s0" "$(now)" "$E"
    elif [ "$rc" -ne 0 ]; then
        rec netns FAILED "ip netns list failed (rc=$rc)" "$rc" "$s0" "$(now)" "$E"
    else
        mkdir "$O/netns"
        nsn=0 bad=0 seen=" "
        while IFS= read -r line; do
            ns="$(printf "%s\n" "$line" | sed -nE "s/^('"$NS_RE"')( \(id: [0-9]+\))?\$/\1/p")"
            if [ -z "$ns" ]; then
                bad=$((bad + 1))
                rec "netns:invalid-$bad" SKIPPED "invalid namespace name" 0 "$(now)" "$(now)"
                continue
            fi
            case "$seen" in *" $ns "*) continue ;; esac
            seen="$seen$ns "
            nsn=$((nsn + 1))
            mkdir "$O/netns/$ns" || continue
            p="netns/$ns"
            item "$p/routes-v4.txt" ns sudo -n timeout "$CT" ip -n "$ns" -4 route show table all
            item "$p/routes-v6.txt" nsv6 sudo -n timeout "$CT" ip -n "$ns" -6 route show table all
            item "$p/rules-v4.txt" ns sudo -n timeout "$CT" ip -n "$ns" -4 rule show
            item "$p/rules-v6.txt" nsv6 sudo -n timeout "$CT" ip -n "$ns" -6 rule show
            item "$p/iptables-v4.rules" nsipt sudo -n timeout "$CT" ip netns exec "$ns" iptables-save $SC
            item "$p/iptables-v6.rules" nsipt sudo -n timeout "$CT" ip netns exec "$ns" ip6tables-save $SC
            if [ "$CNT" = 1 ]; then
                item "$p/nftables.ruleset" ns sudo -n timeout "$CT" ip netns exec "$ns" nft list ruleset
            else
                item "$p/nftables.ruleset" ns sudo -n timeout "$CT" ip netns exec "$ns" nft -s list ruleset
            fi
            if [ "$VFY" = 1 ]; then
                vfy "$p/iptables-v4.rules" ipt4 "$ns"
                vfy "$p/iptables-v6.rules" ipt6 "$ns"
                vfy "$p/nftables.ruleset" nft "$ns"
            fi
            # Namespace hilang di tengah jalan: buang direktori kosong
            rmdir "$O/netns/$ns" 2>/dev/null || true
        done < "$D/nslist"
        rec netns OK "$nsn namespaces, $bad invalid names" 0 "$s0" "$(now)"
    fi
fi

cd "$O" || exit 3
find . -type f ! -name _sums -print0 | sort -z | xargs -0 -r sha256sum > _sums || exit 3
tar -czf - .
exit $?'

# Pre-check: koneksi, sudo, tool, jumlah namespace (statis)
# shellcheck disable=SC2016  # dievaluasi di node
PRECHECK_CMD='echo __OSOPS_NETSTATE__
if sudo -n true >/dev/null 2>&1; then echo sudo=ok; else echo sudo=fail; fi
for t in mktemp tar gzip sha256sum timeout; do command -v "$t" >/dev/null 2>&1 || printf "missing=%s\n" "$t"; done
printf "netns=%s\n" "$(timeout 10 ip netns list 2>/dev/null | wc -l)"'

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

# Perintah pembersihan direktori sementara milik run ini di node: hanya
# direktori milik user SSH sendiri, langsung di /tmp, nama persis.
cleanup_cmd() {
    local run="$1"
    [[ "$run" =~ $RUN_ID_RE ]] || return 1
    # shellcheck disable=SC2016  # dievaluasi di node
    printf '%s' 'u="$(id -un)"; find /tmp -mindepth 1 -maxdepth 1 -type d -user "$u" -name '"'$REMOTE_PREFIX-$run.*'"' -exec rm -rf -- {} + ; printf "left=%s\n" "$(find /tmp -mindepth 1 -maxdepth 1 -type d -user "$u" -name '"'$REMOTE_PREFIX-$run.*'"' | wc -l)"'
}

# ============================================================
# Worker paralel (pola collect-sosreport: maksimal PARALLEL bersamaan)
# ============================================================

# shellcheck disable=SC2329  # dipanggil tidak langsung (run_jobs / on_done_collect)
job_precheck() {
    local i="$1" rc=0
    if (( N_LOCAL[i] )); then
        timeout --kill-after=5 "$PRECHECK_TIMEOUT" bash -c "$PRECHECK_CMD" \
            > "$WORK_DIR/p$i.out" 2> "$WORK_DIR/p$i.err" < /dev/null || rc=$?
    else
        ssh_node "$i" "$PRECHECK_TIMEOUT" "$PRECHECK_CMD" > "$WORK_DIR/p$i.out" 2> "$WORK_DIR/p$i.err" || rc=$?
    fi
    echo "$rc" > "$WORK_DIR/p$i.rc"
}

# shellcheck disable=SC2329  # dipanggil tidak langsung (run_jobs / on_done_collect)
job_collect() {
    local i="$1" rc=0
    local rargs="$LOG_RUN_ID $COUNTERS ${N_DONETNS[$i]} $VERIFY $TIMEOUT_S"
    if (( N_LOCAL[i] )); then
        # shellcheck disable=SC2086  # rargs: run_id tervalidasi dan angka
        ( cd / && timeout --kill-after=10 "$TIMEOUT_S" bash -c "$REMOTE_SCRIPT" "$REMOTE_PREFIX" $rargs ) \
            < /dev/null > "$WORK_DIR/c$i.tgz" 2> "$WORK_DIR/c$i.err" || rc=$?
    else
        ssh_node_stdin "$i" $(( TIMEOUT_S + 20 )) \
            "timeout -k 10 $TIMEOUT_S bash -c \"\$(cat)\" $REMOTE_PREFIX $rargs" \
            < "$WORK_DIR/remote.sh" > "$WORK_DIR/c$i.tgz" 2> "$WORK_DIR/c$i.err" || rc=$?
    fi
    echo "$rc" > "$WORK_DIR/c$i.rc"
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

# Isi tar harus persis struktur yang diharapkan: hanya file biasa dan
# direktori, nama dikenal, tanpa path absolut, "..", atau symlink.
# shellcheck disable=SC2329  # dipanggil tidak langsung (run_jobs / on_done_collect)
valid_archive() {
    local f="$1" name types
    local re="^\./(_status\.tsv|_meta\.env|_sums|($ITEM_RE)|netns/|netns/$NS_RE/|netns/$NS_RE/($NS_ITEM_RE))?\$"
    tar -tzf "$f" > "$f.list" 2>/dev/null || return 1
    [[ -s "$f.list" ]] || return 1
    while IFS= read -r name; do
        [[ "$name" =~ $re && "$name" != *"/../"* && "$name" != */.. ]] || return 1
    done < "$f.list"
    # Jenis entry: hanya '-' (file) dan 'd' (direktori). Tanpa grep -q di
    # pipeline (SIGPIPE + pipefail membalik hasil).
    types="$(tar -tvzf "$f" 2>/dev/null | cut -c1 | LC_ALL=C sort -u | tr -d '\n')" || return 1
    [[ "$types" =~ ^[-d]+$ ]]
}

# Bandingkan sha256 node (_sums) dengan file yang diterima. Return 1 jika beda.
# shellcheck disable=SC2329  # dipanggil tidak langsung (run_jobs / on_done_collect)
compare_sums() {
    local dir="$1" line sum path actual
    local -A want=()
    while IFS= read -r line; do
        [[ "$line" =~ ^([0-9a-f]{64})\ [\ *]\./(.+)$ ]] || return 1
        want["${BASH_REMATCH[2]}"]="${BASH_REMATCH[1]}"
    done < "$dir/_sums"
    while IFS= read -r -d '' path; do
        path="${path#./}"
        if [[ "$path" == _sums ]]; then continue; fi
        sum="${want[$path]:-}"
        [[ -n "$sum" ]] || return 1
        actual="$(sha256sum -- "$dir/$path" | awk '{print $1}')"
        [[ "$actual" == "$sum" ]] || return 1
        unset "want[$path]"
    done < <(cd "$dir" && find . -type f -print0)
    (( ${#want[@]} == 0 ))
}

# Nilai dari _meta.env (key=value, dibaca tanpa source)
# shellcheck disable=SC2329  # dipanggil tidak langsung (run_jobs / on_done_collect)
meta_get() {
    awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "$1"
}

# Proses hasil satu node => <run>/<host>/, items-IDX.tsv
# shellcheck disable=SC2329  # dipanggil oleh run_jobs
on_done_collect() {
    local i="$1" rc err stage host_dir it status reason size sha line rest n_ok=0 n_skip=0 n_fail=0
    local items="$WORK_DIR/items-$i.tsv" ipt_ver backend vf="" skipnote="" key cnt
    local -A skip_reasons=()

    host_dir="$RUN_DIR/${N_NAME[$i]}"
    stage="$STAGE_DIR/$i"
    rc="$(cat "$WORK_DIR/c$i.rc" 2>/dev/null)" || rc=255
    err="$(grep -vE '^Warning: Permanently added|^[[:space:]]*\*' "$WORK_DIR/c$i.err" 2>/dev/null | tail -n 3 | tr '\n' ' ' | cut -c1-300)" || err=""
    : > "$items"

    if (( rc == 124 || rc == 137 )); then
        set_result "$i" FAILED "timeout (${TIMEOUT_S}s)"
    elif (( rc == 255 )) && (( ! N_LOCAL[i] )); then
        set_result "$i" FAILED "$(ssh_fail_reason "$err" "$rc")"
    elif (( rc != 0 )); then
        set_result "$i" FAILED "collection failed (rc=$rc)"
        log_warn -q "${N_NAME[$i]}: pengambilan gagal rc=$rc: $(grep -m1 '^osops:' "$WORK_DIR/c$i.err" 2>/dev/null | cut -c1-200)"
    elif ! valid_archive "$WORK_DIR/c$i.tgz"; then
        set_result "$i" FAILED "invalid archive"
    elif ! ( umask 077; mkdir -p "$stage" && tar -xzf "$WORK_DIR/c$i.tgz" -C "$stage" --no-same-owner --no-same-permissions ) 2>/dev/null; then
        set_result "$i" FAILED "extract failed"
    elif [[ ! -f "$stage/_sums" || ! -f "$stage/_status.tsv" || ! -f "$stage/_meta.env" ]]; then
        set_result "$i" FAILED "incomplete archive"
    elif ! compare_sums "$stage"; then
        set_result "$i" FAILED "sha256 mismatch (node vs undercloud)"
    fi

    if [[ -n "${N_RESULT[$i]}" ]]; then
        N_CLEAN[i]=0
        printf '%s\t-\tFAILED\t%s\t-\t-\n' "${N_NAME[$i]}" "${N_MSG[$i]}" >> "$items"
        log_result "resource=${N_NAME[$i]}" action=lookup result=FAILED "reason=${N_MSG[$i]}" "rc=$rc" \
            "duration=${N_DUR[$i]}s"
        echo "  ${C_RED}❌ ${N_NAME[$i]}: FAILED (${N_MSG[$i]})${C_RESET}"
        rm -rf -- "$stage"
        return 0
    fi
    N_CLEAN[i]=1

    # Pindahkan ke <run>/<host>/ (direktori baru, tidak menimpa apa pun)
    if ! mkdir -m 700 -- "$host_dir" 2>/dev/null; then
        set_result "$i" FAILED "host directory exists: $host_dir"
        printf '%s\t-\tFAILED\t%s\t-\t-\n' "${N_NAME[$i]}" "${N_MSG[$i]}" >> "$items"
        log_result "resource=${N_NAME[$i]}" action=lookup result=FAILED "reason=host directory exists"
        rm -rf -- "$stage"
        return 0
    fi
    ( cd "$stage" && find . -mindepth 1 -maxdepth 1 ! -name '_*' -exec mv -n -t "$host_dir" -- {} + )
    find "$host_dir" -type d -exec chmod 700 {} + 2>/dev/null || true
    find "$host_dir" -type f -exec chmod 600 {} + 2>/dev/null || true

    # Item: host item status reason size sha256
    # Split eksplisit: read dengan IFS=tab menggabungkan tab berurutan (kolom kosong hilang)
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        it="${line%%$'\t'*}" rest="${line#*$'\t'}"
        status="${rest%%$'\t'*}" rest="${rest#*$'\t'}"
        reason="${rest%%$'\t'*}"
        size="-" sha="-"
        if [[ "$it" != verify:* && "$it" != netns && "$it" != netns:* && "$status" == OK ]]; then
            if [[ -f "$host_dir/$it" ]]; then
                size="$(stat -c %s -- "$host_dir/$it")"
                sha="$(sha256sum -- "$host_dir/$it" | awk '{print $1}')"
            else
                status=FAILED reason="file missing after transfer"
            fi
        fi
        case "$status" in
            OK)      n_ok=$(( n_ok + 1 )) ;;
            SKIPPED)
                n_skip=$(( n_skip + 1 ))
                key="${it##*/}"
                if [[ "$it" == netns:invalid-* ]]; then key="netns"; fi
                if [[ "$it" == verify:netns/* ]]; then key="verify:netns/*/${it##*/}"; fi
                if [[ "$it" == netns/* ]]; then key="netns/*/${it##*/}"; fi
                key+=": $reason"
                skip_reasons["$key"]=$(( ${skip_reasons["$key"]:-0} + 1 )) ;;
            *)  n_fail=$(( n_fail + 1 )) ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${N_NAME[$i]}" "$it" "$status" "$reason" "$size" "$sha" >> "$items"
        # Log: hanya item yang tidak OK (nama item, status, alasan; tanpa isi)
        [[ "$status" == OK ]] || log_event ITEM "host=${N_NAME[$i]}" "item=$it" "status=$status" "reason=${reason:--}"
        if [[ "$it" == verify:* ]]; then
            if [[ "$reason" == "$XT_REASON" ]]; then N_XTSKIP[i]=1; fi
            if [[ "$it" != verify:netns/* ]]; then
                vf+="${vf:+, }${it#verify:}=$status"
            fi
        fi
    done < "$stage/_status.tsv"
    if [[ -n "${N_NSNOTE[$i]}" ]]; then
        printf '%s\tnetns\tSKIPPED\t%s\t-\t-\n' "${N_NAME[$i]}" "${N_NSNOTE[$i]}" >> "$items"
        n_skip=$(( n_skip + 1 ))
        skip_reasons["netns: ${N_NSNOTE[$i]}"]=1
        log_event ITEM "host=${N_NAME[$i]}" item=netns status=SKIPPED "reason=${N_NSNOTE[$i]}"
    fi
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        cnt="${skip_reasons[$key]}"
        skipnote+="${skipnote:+; }$key"
        if [[ "$cnt" != 1 ]]; then skipnote+=" (x$cnt)"; fi
    done < <(printf '%s\n' "${!skip_reasons[@]}" | LC_ALL=C sort)
    N_SKIPNOTE[i]="$skipnote"
    N_VERIFY[i]="$vf"

    ipt_ver="$(meta_get "$stage/_meta.env" iptables_version)"
    case "$ipt_ver" in
        *nf_tables*) backend=nf_tables ;;
        *legacy*)    backend=legacy ;;
        "")          backend="-" ;;
        *)           backend=unknown ;;
    esac
    N_BACKEND[i]="$backend"

    write_meta "$i" "$stage" "$host_dir/meta.json" "$backend" || log_warn -q "${N_NAME[$i]}: meta.json gagal ditulis"
    N_FILES[i]="$(find "$host_dir" -type f | wc -l)"
    N_BYTES[i]="$(du -sb -- "$host_dir" 2>/dev/null | awk '{print $1}')"
    rm -rf -- "$stage"

    if (( n_fail > 0 )); then
        set_result "$i" FAILED "$n_fail item(s) failed"
    else
        set_result "$i" SUCCESS ""
    fi
    log_result "resource=${N_NAME[$i]}" action=lookup "result=${N_RESULT[$i]}" "items_ok=$n_ok" \
        "items_skipped=$n_skip" "items_failed=$n_fail" "files=${N_FILES[$i]}" "bytes=${N_BYTES[$i]}" \
        "backend=$backend" "verify=${vf:--}" "path=$host_dir" "duration=${N_DUR[$i]}s"
    if [[ "${N_RESULT[$i]}" == SUCCESS ]]; then
        echo "  ${C_GREEN}✅ ${N_NAME[$i]}: SUCCESS (${N_FILES[$i]} file, $(human "${N_BYTES[$i]}"), ${N_DUR[$i]}s)${C_RESET}"
    else
        echo "  ${C_RED}❌ ${N_NAME[$i]}: FAILED (${N_MSG[$i]})${C_RESET}"
    fi
    return 0
}

# meta.json dari _meta.env + _status.tsv (jq; hanya metadata, bukan isi aturan)
# shellcheck disable=SC2329  # dipanggil tidak langsung (run_jobs / on_done_collect)
write_meta() {
    local i="$1" stage="$2" out="$3" backend="$4"
    ( umask 077; set -o noclobber
      jq -n --arg host "${N_NAME[$i]}" --arg role "${N_ROLE[$i]}" --arg run "$LOG_RUN_ID" \
          --arg backend "$backend" --arg addr "$(rhosp_node_addr "$i")" \
          --argjson counters "$COUNTERS" --argjson netns "${N_DONETNS[$i]}" --argjson verify "$VERIFY" \
          --arg collected "$(date -Iseconds)" \
          --rawfile meta "$stage/_meta.env" --rawfile status "$stage/_status.tsv" '
        def kv: split("\n") | map(select(length > 0) | capture("^(?<key>[a-z_0-9]+)=(?<value>.*)$")) | from_entries;
        def num: (tonumber? // .);
        ($meta | kv) as $m
        | {
            host: $host, role: $role, run_id: $run, address: $addr,
            hostname: ($m.hostname // null),
            node_time: { epoch: (($m.epoch // "") | num), iso: ($m.iso // null) },
            undercloud_received: $collected,
            kernel: ($m.kernel // null),
            tools: { ip: ($m.ip_version // null), ip_json: (($m.ip_json // "") == "1"),
                     iptables: ($m.iptables_version // null), iptables_backend: $backend,
                     nft: ($m.nft_version // null) },
            options: { counters: ($counters == 1), netns: ($netns == 1), verify: ($verify == 1) },
            atomic: false,
            note: "Snapshot is not atomic: each command ran at its own time (start/end epoch per command); neutron/OVN agents may change rules or routes in between.",
            commands: ($status | split("\n") | map(select(length > 0) | split("\t")
                | { item: .[0], status: .[1], reason: .[2], rc: ((.[3] // "") | num),
                    start_epoch: ((.[4] // "") | num), end_epoch: ((.[5] // "") | num),
                    stderr: (.[6] // "") }))
          }' > "$out" ) 2>/dev/null
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

    {
        echo "# Backup Network State run=$LOG_RUN_ID created=$(date -Iseconds) counters=$COUNTERS netns=$INCLUDE_NETNS verify=$VERIFY"
        echo "# NOT ATOMIC: every command ran at its own time (see <host>/meta.json commands[].start_epoch); neutron/OVN agents may change rules/routes in between."
        echo "# This script never restores anything. See README (Backup Network State) for manual restore."
        printf 'host\titem\tstatus\treason\tsize_bytes\tsha256\n'
        for i in "${SEL[@]}"; do
            f="$WORK_DIR/items-$i.tsv"
            if [[ -s "$f" ]]; then
                cat "$f"
            elif [[ -n "${N_RESULT[$i]}" ]]; then
                printf '%s\t-\t%s\t%s\t-\t-\n' "${N_NAME[$i]}" "${N_RESULT[$i]}" "${N_MSG[$i]}"
            fi
        done
    } | ( umask 077; set -o noclobber; cat > "$RUN_DIR/MANIFEST.tsv" ) 2>/dev/null \
        || log_warn -q "MANIFEST.tsv gagal ditulis"

    ( cd "$RUN_DIR" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum | ( umask 077; set -o noclobber; cat > SHA256SUMS ) ) 2>/dev/null \
        || log_warn -q "SHA256SUMS gagal ditulis"
    chmod 600 "$RUN_DIR/MANIFEST.tsv" "$RUN_DIR/SHA256SUMS" 2>/dev/null || true
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
    cmd="$(cleanup_cmd "$LOG_RUN_ID")" || return 0
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
            warn "${N_NAME[$i]}: pembersihan /tmp/$REMOTE_PREFIX-$LOG_RUN_ID.* tidak terverifikasi (sisa: ${left:-?})."
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
if [[ ! "${LOG_RUN_ID:-}" =~ $RUN_ID_RE ]]; then
    die "run_id tidak valid untuk path/perintah remote: '${LOG_RUN_ID:-}' (pola ${RUN_ID_RE})."
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
printf '%s\n' "$REMOTE_SCRIPT" > "$WORK_DIR/remote.sh"

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
    for _i in "${!N_NAME[@]}"; do
        (( N_LOCAL[_i] )) || select_idx "$_i"
    done
    (( LOCAL_RUN )) && select_idx "$UC_IDX"
    _answer=""
    echo
    warn "--all: ${#SEL[@]} node akan dibackup ($(rhosp_selected_names | cut -c1-300))."
    ask _answer "Ketik jumlah node (${#SEL[@]}) untuk melanjutkan: "
    if [[ "$(trim "$_answer")" != "${#SEL[@]}" ]]; then
        log_event DECISION all=cancel "count=${#SEL[@]}"
        echo "❌ Dibatalkan."
        exit 0
    fi
    log_event DECISION all=confirm "count=${#SEL[@]}"
    log_event SELECT "selected=${#SEL[@]}" "nodes=$(rhosp_selected_names)"
elif (( LOCAL_RUN )) && (( ${#NODE_ARGS[@]} == 0 && ${#ROLE_ARGS[@]} == 0 )); then
    select_idx "$UC_IDX"
    echo "✅ Node terpilih     : 1 (${N_NAME[$UC_IDX]}, lokal)"
    log_event SELECT selected=1 "nodes=${N_NAME[$UC_IDX]}"
else
    INCLUDE_UC="$LOCAL_RUN"
    rhosp_select_nodes
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
