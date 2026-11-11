#!/bin/bash
# shellcheck disable=SC2034  # NS_* dibaca oleh script pemanggil
# ============================================================
# OpenStack Ops Toolkit - shared helper: network state (backup/restore)
# ============================================================
#
# Di-source oleh rhosp/backup-network-state.sh dan
# rhosp/restore-network-state.sh SETELAH lib/logging.sh dan lib/rhosp.sh
# (tidak punya @name, lib/ tidak ikut discovery).
#
# Pengambilan state (read-only) di node:
#   NS_COLLECT_SCRIPT    skrip remote statis (route/rule, iptables, nftables,
#                        netns opsional, verifikasi sintaks); hasil tar.gz di stdout
#   NS_PRECHECK_CMD      pre-check: sudo -n, tool, jumlah netns
#   ns_collect IDX OUT RUN COUNTERS NETNS VERIFY TIMEOUT
#                        jalankan kolektor (lokal untuk N_LOCAL, selain itu
#                        ssh_node_stdin) => OUT.tgz, OUT.err, OUT.rc
#   ns_precheck IDX OUT TIMEOUT          => OUT.out, OUT.err, OUT.rc
#   ns_cleanup_cmd RUN   hapus /tmp/osops-netstate-RUN.* milik user SSH
#
# Penerimaan di undercloud:
#   ns_receive NAME OUT STAGE HOST_DIR LOCAL TIMEOUT
#                        validasi rc/arsip/sha256, ekstrak ke STAGE, pindahkan
#                        file data ke HOST_DIR (baru). NS_RX_MSG kosong = OK.
#   ns_items NAME STAGE HOST_DIR ITEMS_FILE [NSNOTE]
#                        baris MANIFEST per item + NS_N_OK/NS_N_SKIP/NS_N_FAIL,
#                        NS_SKIPNOTE, NS_VERIFY, NS_XTSKIP
#   ns_write_meta OUT STAGE HOST ROLE RUN BACKEND ADDR COUNTERS NETNS VERIFY
#   ns_write_manifest RUN_DIR HEADER   (baris item dari stdin), ns_write_sums RUN_DIR
#   ns_backend VERSION   nf_tables | legacy | - | unknown
#   ns_meta_get FILE KEY
#
# Validasi backup yang sudah ada (restore):
#   ns_verify_run RUN_DIR HOST   SHA256SUMS, sha256 MANIFEST, struktur,
#                                permission/owner. NS_VERIFY_MSG = alasan gagal.
#   ns_manifest_get RUN_DIR HOST ITEM  => "status<TAB>reason" (kosong = tidak ada)

[[ -n "${_OSOPS_NETSTATE_LOADED:-}" ]] && return 0
_OSOPS_NETSTATE_LOADED=1

NS_PREFIX="osops-netstate"
# run_id dipakai di path dan perintah remote: pola ketat (tanpa titik, glob, spasi)
NS_RUN_ID_RE='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
NS_NAME_RE='[A-Za-z0-9][A-Za-z0-9._:@-]{0,254}'
NS_ITEM_RE='routes-v[46]\.(txt|json)|rules-v[46]\.(txt|json)|iptables-v[46]\.rules|nftables\.ruleset'
NS_NS_ITEM_RE='routes-v[46]\.txt|rules-v[46]\.txt|iptables-v[46]\.rules|nftables\.ruleset'
NS_XT_REASON="iptables-nft compat (xt): restore via iptables-restore"

NS_RX_MSG=""
NS_N_OK=0 NS_N_SKIP=0 NS_N_FAIL=0 NS_SKIPNOTE="" NS_VERIFY="" NS_XTSKIP=0
NS_VERIFY_MSG=""

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
NS_COLLECT_SCRIPT='set -u
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
            ns="$(printf "%s\n" "$line" | sed -nE "s/^('"$NS_NAME_RE"')( \(id: [0-9]+\))?\$/\1/p")"
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
NS_PRECHECK_CMD='echo __OSOPS_NETSTATE__
if sudo -n true >/dev/null 2>&1; then echo sudo=ok; else echo sudo=fail; fi
for t in mktemp tar gzip sha256sum timeout; do command -v "$t" >/dev/null 2>&1 || printf "missing=%s\n" "$t"; done
printf "netns=%s\n" "$(timeout 10 ip netns list 2>/dev/null | wc -l)"'

# Perintah pembersihan direktori sementara milik run ini di node: hanya
# direktori milik user SSH sendiri, langsung di /tmp, nama persis.
ns_cleanup_cmd() {
    local run="$1"
    [[ "$run" =~ $NS_RUN_ID_RE ]] || return 1
    # shellcheck disable=SC2016  # dievaluasi di node
    printf '%s' 'u="$(id -un)"; find /tmp -mindepth 1 -maxdepth 1 -type d -user "$u" -name '"'$NS_PREFIX-$run.*'"' -exec rm -rf -- {} + ; printf "left=%s\n" "$(find /tmp -mindepth 1 -maxdepth 1 -type d -user "$u" -name '"'$NS_PREFIX-$run.*'"' | wc -l)"'
}

# ns_precheck IDX OUT TIMEOUT
ns_precheck() {
    local i="$1" out="$2" t="$3" rc=0
    if (( N_LOCAL[i] )); then
        timeout --kill-after=5 "$t" bash -c "$NS_PRECHECK_CMD" \
            > "$out.out" 2> "$out.err" < /dev/null || rc=$?
    else
        ssh_node "$i" "$t" "$NS_PRECHECK_CMD" > "$out.out" 2> "$out.err" || rc=$?
    fi
    echo "$rc" > "$out.rc"
}

# ns_collect IDX OUT RUN COUNTERS NETNS VERIFY TIMEOUT — argumen remote hanya
# run_id tervalidasi dan angka
ns_collect() {
    local i="$1" out="$2" run="$3" cnt="$4" nsf="$5" vfy="$6" t="$7" rc=0 sf
    [[ "$run" =~ $NS_RUN_ID_RE ]] || { echo 2 > "$out.rc"; return 0; }
    local rargs="$run $cnt $nsf $vfy $t"
    if (( N_LOCAL[i] )); then
        # shellcheck disable=SC2086  # rargs: run_id tervalidasi dan angka
        ( cd / && timeout --kill-after=10 "$t" bash -c "$NS_COLLECT_SCRIPT" "$NS_PREFIX" $rargs ) \
            < /dev/null > "$out.tgz" 2> "$out.err" || rc=$?
    else
        sf="$RHOSP_WORK_DIR/netstate-collect.sh"
        [[ -f "$sf" ]] || printf '%s\n' "$NS_COLLECT_SCRIPT" > "$sf"
        ssh_node_stdin "$i" $(( t + 20 )) \
            "timeout -k 10 $t bash -c \"\$(cat)\" $NS_PREFIX $rargs" \
            < "$sf" > "$out.tgz" 2> "$out.err" || rc=$?
    fi
    echo "$rc" > "$out.rc"
}

# Isi tar harus persis struktur yang diharapkan: hanya file biasa dan
# direktori, nama dikenal, tanpa path absolut, "..", atau symlink.
ns_valid_archive() {
    local f="$1" name types
    local re="^\./(_status\.tsv|_meta\.env|_sums|($NS_ITEM_RE)|netns/|netns/$NS_NAME_RE/|netns/$NS_NAME_RE/($NS_NS_ITEM_RE))?\$"
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
ns_compare_sums() {
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
ns_meta_get() {
    awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "$1"
}

ns_backend() {
    case "$1" in
        *nf_tables*) printf 'nf_tables' ;;
        *legacy*)    printf 'legacy' ;;
        "")          printf -- '-' ;;
        *)           printf 'unknown' ;;
    esac
}

# ns_receive NAME OUT STAGE HOST_DIR LOCAL TIMEOUT — NS_RX_MSG kosong = OK;
# jika OK, file data ada di HOST_DIR (700/600) dan _status.tsv/_meta.env di STAGE
ns_receive() {
    local name="$1" out="$2" stage="$3" host_dir="$4" is_local="$5" t="$6" rc err
    NS_RX_MSG=""
    rc="$(cat "$out.rc" 2>/dev/null)" || rc=255
    err="$(grep -vE '^Warning: Permanently added|^[[:space:]]*\*' "$out.err" 2>/dev/null | tail -n 3 | tr '\n' ' ' | cut -c1-300)" || err=""

    if (( rc == 124 || rc == 137 )); then
        NS_RX_MSG="timeout (${t}s)"
    elif (( rc == 255 )) && (( ! is_local )); then
        NS_RX_MSG="$(ssh_fail_reason "$err" "$rc")"
    elif (( rc != 0 )); then
        NS_RX_MSG="collection failed (rc=$rc)"
        log_warn -q "$name: pengambilan gagal rc=$rc: $(grep -m1 '^osops:' "$out.err" 2>/dev/null | cut -c1-200)"
    elif ! ns_valid_archive "$out.tgz"; then
        NS_RX_MSG="invalid archive"
    elif ! ( umask 077; mkdir -p "$stage" && tar -xzf "$out.tgz" -C "$stage" --no-same-owner --no-same-permissions ) 2>/dev/null; then
        NS_RX_MSG="extract failed"
    elif [[ ! -f "$stage/_sums" || ! -f "$stage/_status.tsv" || ! -f "$stage/_meta.env" ]]; then
        NS_RX_MSG="incomplete archive"
    elif ! ns_compare_sums "$stage"; then
        NS_RX_MSG="sha256 mismatch (node vs undercloud)"
    fi
    if [[ -n "$NS_RX_MSG" ]]; then
        rm -rf -- "$stage"
        return 0
    fi

    # Pindahkan ke HOST_DIR (direktori baru, tidak menimpa apa pun)
    if ! mkdir -m 700 -- "$host_dir" 2>/dev/null; then
        NS_RX_MSG="host directory exists: $host_dir"
        rm -rf -- "$stage"
        return 0
    fi
    ( cd "$stage" && find . -mindepth 1 -maxdepth 1 ! -name '_*' -exec mv -n -t "$host_dir" -- {} + )
    find "$host_dir" -type d -exec chmod 700 {} + 2>/dev/null || true
    find "$host_dir" -type f -exec chmod 600 {} + 2>/dev/null || true
    return 0
}

# ns_items NAME STAGE HOST_DIR ITEMS_FILE [NSNOTE] — baris "host item status
# reason size sha256" per item (append), log hanya item yang tidak OK
ns_items() {
    local name="$1" stage="$2" host_dir="$3" items="$4" nsnote="${5:-}"
    local it status reason size sha line rest key cnt
    local -A skip_reasons=()
    NS_N_OK=0 NS_N_SKIP=0 NS_N_FAIL=0 NS_SKIPNOTE="" NS_VERIFY="" NS_XTSKIP=0

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
            OK)      NS_N_OK=$(( NS_N_OK + 1 )) ;;
            SKIPPED)
                NS_N_SKIP=$(( NS_N_SKIP + 1 ))
                key="${it##*/}"
                if [[ "$it" == netns:invalid-* ]]; then key="netns"; fi
                if [[ "$it" == verify:netns/* ]]; then key="verify:netns/*/${it##*/}"; fi
                if [[ "$it" == netns/* ]]; then key="netns/*/${it##*/}"; fi
                key+=": $reason"
                skip_reasons["$key"]=$(( ${skip_reasons["$key"]:-0} + 1 )) ;;
            *)  NS_N_FAIL=$(( NS_N_FAIL + 1 )) ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$it" "$status" "$reason" "$size" "$sha" >> "$items"
        # Log: hanya item yang tidak OK (nama item, status, alasan; tanpa isi)
        [[ "$status" == OK ]] || log_event ITEM "host=$name" "item=$it" "status=$status" "reason=${reason:--}"
        if [[ "$it" == verify:* ]]; then
            if [[ "$reason" == "$NS_XT_REASON" ]]; then NS_XTSKIP=1; fi
            if [[ "$it" != verify:netns/* ]]; then
                NS_VERIFY+="${NS_VERIFY:+, }${it#verify:}=$status"
            fi
        fi
    done < "$stage/_status.tsv"
    if [[ -n "$nsnote" ]]; then
        printf '%s\tnetns\tSKIPPED\t%s\t-\t-\n' "$name" "$nsnote" >> "$items"
        NS_N_SKIP=$(( NS_N_SKIP + 1 ))
        skip_reasons["netns: $nsnote"]=1
        log_event ITEM "host=$name" item=netns status=SKIPPED "reason=$nsnote"
    fi
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        cnt="${skip_reasons[$key]}"
        NS_SKIPNOTE+="${NS_SKIPNOTE:+; }$key"
        if [[ "$cnt" != 1 ]]; then NS_SKIPNOTE+=" (x$cnt)"; fi
    done < <(printf '%s\n' "${!skip_reasons[@]}" | LC_ALL=C sort)
    return 0
}

# meta.json dari _meta.env + _status.tsv (jq; hanya metadata, bukan isi aturan)
ns_write_meta() {
    local out="$1" stage="$2" host="$3" role="$4" run="$5" backend="$6" addr="$7"
    local cnt="$8" nsf="$9" vfy="${10}"
    ( umask 077; set -o noclobber
      jq -n --arg host "$host" --arg role "$role" --arg run "$run" \
          --arg backend "$backend" --arg addr "$addr" \
          --argjson counters "$cnt" --argjson netns "$nsf" --argjson verify "$vfy" \
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

# ns_write_manifest RUN_DIR HEADER — baris item dari stdin
ns_write_manifest() {
    local dir="$1" header="$2"
    {
        echo "$header"
        echo "# NOT ATOMIC: every command ran at its own time (see <host>/meta.json commands[].start_epoch); neutron/OVN agents may change rules/routes in between."
        echo "# Restore: rhosp/restore-network-state.sh (dry-run by default). See README (Restore Network State)."
        printf 'host\titem\tstatus\treason\tsize_bytes\tsha256\n'
        cat
    } | ( umask 077; set -o noclobber; cat > "$dir/MANIFEST.tsv" ) 2>/dev/null
}

ns_write_sums() {
    local dir="$1"
    ( cd "$dir" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum | ( umask 077; set -o noclobber; cat > SHA256SUMS ) ) 2>/dev/null || return 1
    chmod 600 "$dir/MANIFEST.tsv" "$dir/SHA256SUMS" 2>/dev/null || true
    return 0
}

# ============================================================
# Validasi backup yang sudah ada (dipakai restore)
# ============================================================

# ns_manifest_get RUN_DIR HOST ITEM => "status<TAB>reason<TAB>size<TAB>sha256"
ns_manifest_get() {
    awk -F'\t' -v h="$2" -v it="$3" '!/^#/ && $1 == h && $2 == it { print $3 "\t" $4 "\t" $5 "\t" $6; exit }' "$1/MANIFEST.tsv"
}

# ns_verify_run RUN_DIR HOST — return 1 dengan NS_VERIFY_MSG jika ada yang
# tidak cocok: permission/owner, struktur, SHA256SUMS, sha256 di MANIFEST
ns_verify_run() {
    local dir="$1" host="$2" me f rel line sum st it size sha re
    local -A listed=()
    NS_VERIFY_MSG=""
    me="$(id -u)"

    if [[ ! -d "$dir" || -L "$dir" ]]; then NS_VERIFY_MSG="not a directory: $dir"; return 1; fi
    if [[ ! -d "$dir/$host" || -L "$dir/$host" ]]; then NS_VERIFY_MSG="host not in backup: $host"; return 1; fi
    for f in MANIFEST.tsv SHA256SUMS; do
        if [[ ! -f "$dir/$f" || -L "$dir/$f" ]]; then NS_VERIFY_MSG="missing $f"; return 1; fi
    done
    # Permission/owner: direktori 700, file 600, milik user ini, tanpa symlink
    while IFS= read -r -d '' f; do
        line="$(stat -c '%u %a %F' -- "$f")"
        case "$line" in
            "$me 700 directory"|"$me 600 regular file"|"$me 600 regular empty file") ;;
            *) NS_VERIFY_MSG="bad permission/owner/type: ${f#"$dir"/} ($line)"; return 1 ;;
        esac
    done < <(find "$dir" -maxdepth 1 \( -name MANIFEST.tsv -o -name SHA256SUMS -o -path "$dir" \) -print0; \
             find "$dir/$host" -print0)
    # Struktur host
    re="^($NS_ITEM_RE|meta\.json|netns|netns/$NS_NAME_RE|netns/$NS_NAME_RE/($NS_NS_ITEM_RE))\$"
    while IFS= read -r -d '' f; do
        rel="${f#"$dir/$host"/}"
        if [[ ! "$rel" =~ $re ]]; then NS_VERIFY_MSG="unexpected file in backup: $host/$rel"; return 1; fi
    done < <(find "$dir/$host" -mindepth 1 -print0)
    # SHA256SUMS: format ketat, semua file host tercantum, semua cocok
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^([0-9a-f]{64})\ \ \./(.+)$ ]] || [[ "${BASH_REMATCH[2]}" == *..* ]]; then
            NS_VERIFY_MSG="malformed SHA256SUMS line"
            return 1
        fi
        sum="${BASH_REMATCH[1]}" rel="${BASH_REMATCH[2]}"
        listed["$rel"]="$sum"
    done < "$dir/SHA256SUMS"
    while IFS= read -r -d '' f; do
        rel="${f#"$dir"/}"
        if [[ -z "${listed[$rel]:-}" ]]; then NS_VERIFY_MSG="file not in SHA256SUMS: $rel"; return 1; fi
    done < <(find "$dir/$host" "$dir/MANIFEST.tsv" -type f -print0)
    for rel in "${!listed[@]}"; do
        [[ "$rel" == "$host/"* || "$rel" == MANIFEST.tsv ]] || continue
        if [[ ! -f "$dir/$rel" ]]; then NS_VERIFY_MSG="listed file missing: $rel"; return 1; fi
        sum="$(sha256sum -- "$dir/$rel" | awk '{print $1}')"
        if [[ "$sum" != "${listed[$rel]}" ]]; then NS_VERIFY_MSG="sha256 mismatch (SHA256SUMS): $rel"; return 1; fi
    done
    # MANIFEST: item OK harus punya file dengan size/sha256 yang sama
    while IFS=$'\n' read -r line; do
        it="$(cut -f2 <<< "$line")" st="$(cut -f3 <<< "$line")" size="$(cut -f5 <<< "$line")" sha="$(cut -f6 <<< "$line")"
        [[ "$st" == OK && "$sha" =~ ^[0-9a-f]{64}$ ]] || continue
        f="$dir/$host/$it"
        if [[ ! -f "$f" ]]; then NS_VERIFY_MSG="manifest item missing: $it"; return 1; fi
        if [[ "$(stat -c %s -- "$f")" != "$size" || "$(sha256sum -- "$f" | awk '{print $1}')" != "$sha" ]]; then
            NS_VERIFY_MSG="sha256 mismatch (MANIFEST): $it"
            return 1
        fi
    done < <(awk -F'\t' -v h="$host" '!/^#/ && $1 == h' "$dir/MANIFEST.tsv")
    if [[ ! -f "$dir/$host/meta.json" ]] || ! jq -e '.hostname | strings' "$dir/$host/meta.json" >/dev/null 2>&1; then
        NS_VERIFY_MSG="meta.json missing or without hostname"
        return 1
    fi
    return 0
}
