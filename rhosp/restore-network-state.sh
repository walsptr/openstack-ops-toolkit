#!/bin/bash
# ============================================================
# @name:        Restore Network State
# @description: Restore iptables/nftables (dan route/rule terbatas) satu node dari backup, dengan dry-run dan auto-rollback
# @mutates:     yes
# @requires:    ssh, jq
# @platform:    rhosp
# @tags:        rhosp, network, firewall, restore
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

usage() {
    cat <<'EOF'
Usage: restore-network-state.sh [--backup-dir DIR] [--host HOST] [--items LIST]
                                [--apply] [--rollback-timeout DETIK] [--save-diff FILE]
                                [--inventory PATH] [--timeout DETIK]
       restore-network-state.sh --status --host HOST
       restore-network-state.sh --clear-state --host HOST

Restore state jaringan RUNTIME satu node overcloud dari hasil
rhosp/backup-network-state.sh. Default DRY-RUN: hanya diff backup vs kondisi
saat ini. Perubahan hanya dengan --apply, selalu dengan auto-rollback.

Item (--items, dipisah koma, wajib; tanpa default "semua"):
  iptables-v4, iptables-v6   iptables-restore dari file backup (atomik per tabel)
  nftables                   satu batch atomik "flush ruleset" + isi backup (nft -f)
  routes-v4, routes-v6,      add-missing saja: route/rule yang ada di backup tapi
  rules-v4, rules-v6         tidak ada sekarang ditambahkan. Tidak pernah menghapus;
                             route proto kernel, link-local, dan default route tidak
                             disentuh (hanya ditampilkan sebagai "tindakan manual")
  Di backend nf_tables, nftables tidak bisa digabung dengan iptables-v4/v6:
  ruleset nftables sudah mencakup tabel iptables-nft. Network namespace
  (netns) tidak di-restore.

Yang TIDAK dilakukan: mengubah /etc/sysconfig/iptables*, /etc/nftables/*,
file persistence atau konfigurasi director, start/stop/restart service.
Reboot atau run director berikutnya mengembalikan konfigurasi dari director.

Options:
  --backup-dir DIR        Direktori run backup (<...>/network-state/<run_id>/).
                          Tanpa opsi ini: picker run backup (termasuk *-pre-restore)
  --host HOST             Host di dalam backup (= node tujuan). Tanpa opsi: picker
  --items LIST            Item yang di-restore (lihat di atas). Interaktif: picker
  --apply                 Terapkan (tanpa opsi ini: dry-run)
  --rollback-timeout DETIK  Timer auto-rollback di node (default 180, 120-900)
  --save-diff FILE        Tulis diff lengkap ke FILE (600, tidak ditimpa)
  --status                Cek restore yang belum tuntas untuk --host (read-only)
  --clear-state           Hapus state restore yang SUDAH tuntas (ketik hostname)
  --inventory PATH        File inventory (melewati pencarian otomatis)
  --timeout DETIK         Batas waktu pengambilan state per node (default 120)
  -h, --help              Tampilkan help

Alur --apply: validasi backup (SHA256SUMS, MANIFEST, struktur, permission) =>
hostname dan backend iptables node harus sama dengan backup => diff =>
cluster Pacemaker Online => ketik hostname, lalu RESTORE => snapshot
pra-restore (<backup-base>/<run_id>-pre-restore/) => upload ke
/var/lib/osops-restore/<run_id>/ (root, 700) => verifikasi (--test, nft -c)
=> timer rollback systemd-run => apply => cek (SSH baru, pcs, jumlah aturan)
=> ketik hostname dalam sisa waktu timer. Tanpa konfirmasi (atau cek gagal,
Ctrl-C, koneksi putus) rollback berjalan otomatis.

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

# Inventory, SSH (lib/rhosp.sh) dan kolektor/validasi backup (lib/netstate.sh)
# shellcheck source=../lib/rhosp.sh
if ! source "$OSOPS_HOME/lib/rhosp.sh" 2>/dev/null; then
    echo "❌ lib/rhosp.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi
# shellcheck source=../lib/netstate.sh
if ! source "$OSOPS_HOME/lib/netstate.sh" 2>/dev/null; then
    echo "❌ lib/netstate.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi

# ============================================================
# Konfigurasi
# ============================================================

BACKUP_DIR=""
HOST=""
ITEMS_ARG=""
ITEMS_SET=0
APPLY=0
MODE=restore            # restore | status | clear
RB_TIMEOUT=180
RB_MIN=120
RB_MAX=900
SAVE_DIFF=""
TIMEOUT_S=120

ALL_ITEMS=(iptables-v4 iptables-v6 nftables routes-v4 routes-v6 rules-v4 rules-v6)
NODE_BASE="/var/lib/osops-restore"
CONFIRM_MIN_LEFT=45     # sisa waktu timer minimal untuk meminta konfirmasi
CONFIRM_MARGIN=10       # cadangan untuk menjalankan "confirm" sebelum timer habis
PCS_POLLS=3
PCS_INTERVAL=10
SSH_T=60
AGENT_T=150             # batas waktu satu fase agent (sudo timeout)
AGENT_RUN=""            # run_id agent yang dituju (default: run ini)

WORK_DIR=""
TGT=-1
NAME=""
UNIT=""
NODE_DIR=""
STATE_FILE=""
LOCK_FILE=""
PRE_DIR=""
PHASE="none"            # none | uploaded | scheduled | applied | done
DUE=""
BAK_HOSTNAME="" BAK_BACKEND="" BAK_COUNTERS=0 BAK_EPOCH=""
CUR_HOSTNAME="" CUR_BACKEND=""
ITEMS=()
declare -A ST=() RS=() ADDN=() REMN=() NOTE=()
MANUAL_FILE=""
CLUSTER=0
CTRL=-1
ONLINE_BEFORE=""
LEGACY_EMPTIED=""
CRITICAL=""

# ============================================================
# Program awk bersama (lokal dan di agent node: penghitungan sama persis)
# ============================================================

# iptables-save => "tabel<TAB>jumlah -A"
# shellcheck disable=SC2016
AWK_IPT_COUNT='/^\*/ { t = substr($0, 2); if (!(t in c)) c[t] = 0; next } /^-A / { c[t]++ } END { for (t in c) print t "\t" c[t] }'
# nft list ruleset => "family nama<TAB>jumlah aturan" (baris di dalam chain)
# shellcheck disable=SC2016
AWK_NFT_COUNT='/^table / { t = $2 " " $3; if (!(t in c)) c[t] = 0; next } /^\tchain / { inc = 1; next } /^\t}/ { inc = 0; next } inc && /^\t\t[^\t]/ && !/^\t\t(type|policy|comment|devices) / { c[t]++ } END { for (t in c) print t "\t" c[t] }'

# ============================================================
# Agent di node (statis, root). Ada di /var/lib/osops-restore/<run_id>/agent.sh
# (700/600, milik root), dijalankan:
#   sudo -n timeout N /bin/bash /var/lib/osops-restore/<run_id>/agent.sh FASE [ARG]
# dan oleh unit rollback systemd (fase rollback). Tidak ada input user di
# perintah remote: semua data ada di file dengan nama statis (SUMS menjamin
# integritas). Fase: verify | schedule N | apply | counts | rollback |
# rollback-now | verify-rollback | confirm | cleanup.
#
# Rollback (unit transient milik PID 1, tetap jalan saat SSH putus):
#   systemd-run --unit=osops-restore-rb-<run_id> --on-active=Ns
#     --timer-property=AccuracySec=1s --property=Type=oneshot
#     --property=TimeoutStartSec=120 /bin/bash <dir>/agent.sh rollback
# Rollback hanya memulihkan item di file "applied" (ditulis SEBELUM tiap item
# diterapkan) dari salinan pra-restore pre/, dan menghapus route/rule yang
# tercatat di added-<item> (ditulis SEBELUM tiap ip route/rule add). SUMS
# dicek dulu; gagal => rollback.result=FAILED (integrity), tidak ada perubahan.
# Unit transient tidak bertahan reboot; reboot memuat konfigurasi director.
# ============================================================
# shellcheck disable=SC2016,SC2027  # dievaluasi di node; program awk disisipkan sebagai literal
AGENT_SCRIPT='set -u
set -f
umask 077
export LC_ALL=C
PH="${1:-}" ARG="${2:-}"
D="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || { echo "agent: bad dir"; exit 9; }
RUN="${D##*/}"
case "$RUN" in [A-Za-z0-9]*) ;; *) echo "agent: bad dir"; exit 9 ;; esac
case "$RUN" in *[!A-Za-z0-9_-]*) echo "agent: bad dir"; exit 9 ;; esac
case "$D" in */var/lib/osops-restore/"$RUN") ;; *) echo "agent: bad dir"; exit 9 ;; esac
[ "$(stat -c "%u %a" "$D")" = "$(id -u) 700" ] || { echo "agent: bad owner/mode"; exit 9; }
U="osops-restore-rb-$RUN"
cv() { sed -n "s/^$1=//p" "$D/conf" | head -n 1; }
BK="$(cv backend)" ITEMS="$(cv items)" HN="$(cv host)"
AWK_IPT='"'"$AWK_IPT_COUNT"'"'
AWK_NFT='"'"$AWK_NFT_COUNT"'"'

integrity() { ( cd "$D" && sha256sum --quiet -c SUMS ) >/dev/null 2>&1; }
has() { case ",$ITEMS," in *",$1,"*) return 0 ;; esac; return 1; }
tool() { case "$1" in iptables-v4) echo iptables ;; iptables-v6) echo ip6tables ;; esac; }
fam() { case "$1" in iptables-v4) echo ip ;; iptables-v6) echo ip6 ;; esac; }
ipc() { case "$1" in routes-v4) echo "-4 route" ;; routes-v6) echo "-6 route" ;; rules-v4) echo "-4 rule" ;; rules-v6) echo "-6 rule" ;; esac; }
# Pesan error tanpa isi aturan (nft mengulang baris aturan di pesannya)
san() {
    grep -E "^[^ ]*:[0-9]+:[0-9-]+: Error: |line [0-9]+|^sudo:|unknown option|COMMIT expected|RTNETLINK|Error:|No such|File exists|Cannot" "$D/err" 2>/dev/null \
        | sed -E "s#^[^ ]*:([0-9]+):[0-9-]+: Error: #line \1: Error: #" | grep -v "^[[:space:]]" | head -n 2 | tr "\t\n" "  " | cut -c1-200
}
valid_line() {
    [ -n "$1" ] || return 1
    for w in $1; do
        case "$w" in -*|*[!A-Za-z0-9._:/@-]*) return 1 ;; esac
    done
    return 0
}
# ipt_restore ITEM FILE [OPSI...] — input lewat PIPE, bukan redirect file:
# di unit systemd (SELinux initrc_t) iptables-restore tidak bisa membaca stdin
# yang di-redirect dari file di /var/lib/osops-restore (ditolak diam-diam oleh
# dontaudit) dan keluar 0 tanpa menerapkan apa pun. Diverifikasi di RHEL 9.
ipt_restore() {
    it="$1" f="$2"
    shift 2
    [ -r "$f" ] && [ -s "$f" ] || { echo "Error: cannot read $f" > "$D/err"; return 1; }
    cat "$f" | timeout 60 "$(tool "$it")-restore" "$@" -w 5 > /dev/null 2> "$D/err"
}
nft_norm() { grep -v -e "^#" -e "^flush ruleset\$" | sed -E "s/ packets [0-9]+ bytes [0-9]+//; s/[[:space:]]+\$//" | grep -v "^\$"; }
ipt_norm() { grep -v "^#" | sed -E "s/^(:[^ ]+ [^ ]+) \[[0-9]+:[0-9]+\]\$/\1 [0:0]/; s/^\[[0-9]+:[0-9]+\] //"; }
ipt_tables() { sed -n "s/^\*//p" "$1"; }
# ipt_section TABEL < FILE — baris tabel (ternormalisasi) dari stdin
ipt_section() { awk -v t="$1" "/^\\*/ { on = (substr(\$0, 2) == t) } on" | ipt_norm; }
route_present() {
    # route_present ITEM SPEC: route dengan dst (token 1) + table ada sekarang
    set -- "$1" $2
    it="$1" dst="$2" tb=main
    shift 2
    while [ $# -gt 0 ]; do [ "$1" = table ] && tb="${2:-main}"; shift; done
    [ -n "$(timeout 30 ip "-${it##*-v}" route show table "$tb" exact "$dst" 2>/dev/null)" ]
}
rule_present() {
    set -- "$1" $2
    it="$1"; shift
    p=""
    while [ $# -gt 0 ]; do [ "$1" = priority ] && p="${2:-}"; shift; done
    [ -n "$p" ] && [ -n "$(timeout 30 ip "-${it##*-v}" rule show pref "$p" 2>/dev/null)" ]
}
join_counts() {
    # join_counts ITEM EXPFILE ACTFILE => count<TAB>item<TAB>table<TAB>exp<TAB>act (tabel dari EXP)
    awk -F "\t" -v it="$1" "FNR == NR { a[\$1] = \$2; next } { printf \"count\t%s\t%s\t%s\t%s\n\", it, \$1, \$2, ((\$1 in a) ? a[\$1] : 0) }" "$3" "$2"
}

ph_verify() {
    rc=0
    if ! integrity; then printf "verify\tall\tFAILED\tintegrity check failed (SUMS)\n"; return 20; fi
    if [ "$(hostname -f 2>/dev/null || hostname)" != "$HN" ]; then printf "verify\tall\tFAILED\thostname mismatch\n"; return 21; fi
    case "$(timeout 10 iptables --version 2>/dev/null)" in
        *"($BK)"*) ;;
        *) if [ "$BK" != "-" ]; then printf "verify\tall\tFAILED\tbackend mismatch\n"; return 21; fi ;;
    esac
    for it in iptables-v4 iptables-v6 nftables routes-v4 routes-v6 rules-v4 rules-v6; do
        has "$it" || continue
        ok=1 msg=""
        case "$it" in
            iptables-v*)
                for f in "items/$it.rules" "pre/$it.rules" "pre/$it.empty"; do
                    [ -f "$D/$f" ] || continue
                    if ! ipt_restore "$it" "$D/$f" --test; then
                        ok=0 msg="$f: $(san)"
                    fi
                done ;;
            nftables)
                for f in items/nftables.batch pre/nftables.batch; do
                    if ! timeout 60 nft -c -f "$D/$f" < /dev/null > /dev/null 2> "$D/err"; then
                        ok=0 msg="$f: $(san)"
                    fi
                done ;;
            *)
                while IFS= read -r l; do
                    valid_line "$l" || { ok=0; msg="invalid entry"; break; }
                done < "$D/items/$it.add" ;;
        esac
        if [ "$ok" = 1 ]; then printf "verify\t%s\tOK\t\n" "$it"; else printf "verify\t%s\tFAILED\t%s\n" "$it" "$msg"; rc=22; fi
    done
    return "$rc"
}

ph_schedule() {
    n="$ARG"
    case "$n" in ""|*[!0-9]*) echo "agent: bad timeout"; return 2 ;; esac
    if [ "$n" -lt 60 ] || [ "$n" -gt 900 ]; then echo "agent: bad timeout"; return 2; fi
    integrity || { printf "schedule\tFAILED\tintegrity\n"; return 20; }
    if [ -e "$D/scheduled" ] || [ "$(systemctl is-active "$U.timer" 2>/dev/null)" = active ]; then
        printf "schedule\tFAILED\talready scheduled\n"
        return 23
    fi
    t0="$(date +%s)"
    if ! systemd-run --unit="$U" --description="osops restore rollback $RUN" --on-active="${n}s" \
            --timer-property=AccuracySec=1s --property=Type=oneshot --property=TimeoutStartSec=120 \
            /bin/bash "$D/agent.sh" rollback > /dev/null 2> "$D/err"; then
        printf "schedule\tFAILED\tsystemd-run: %s\n" "$(head -n 1 "$D/err" | cut -c1-200)"
        return 24
    fi
    if [ "$(systemctl is-active "$U.timer" 2>/dev/null)" != active ]; then
        printf "schedule\tFAILED\ttimer not active\n"
        return 24
    fi
    echo "$((t0 + n))" > "$D/scheduled"
    printf "schedule\tOK\t%s\t%s\n" "$((t0 + n))" "$(date +%s)"
}

ph_apply() {
    trap "" HUP PIPE
    integrity || { printf "apply\tall\tFAILED\tintegrity\n"; return 20; }
    if [ "$(systemctl is-active "$U.timer" 2>/dev/null)" != active ]; then
        printf "apply\tall\tFAILED\tno rollback timer\n"
        return 22
    fi
    if [ -e "$D/applied" ]; then printf "apply\tall\tFAILED\talready applied\n"; return 23; fi
    : > "$D/applied"
    : > "$D/apply.result"
    for it in iptables-v4 iptables-v6 nftables routes-v4 routes-v6 rules-v4 rules-v6; do
        has "$it" || continue
        echo "$it" >> "$D/applied"
        sync "$D/applied" 2>/dev/null || true
        st=APPLIED det=""
        case "$it" in
            iptables-v*)
                ipt_restore "$it" "$D/items/$it.rules" || { st=FAILED; det="$(san)"; } ;;
            nftables)
                timeout 60 nft -f "$D/items/nftables.batch" < /dev/null > /dev/null 2> "$D/err" \
                    || { st=FAILED; det="$(san)"; } ;;
            *)
                : > "$D/added-$it"
                n=0
                while IFS= read -r l; do
                    if ! valid_line "$l"; then st=FAILED; det="invalid entry"; break; fi
                    printf "%s\n" "$l" >> "$D/added-$it"
                    sync "$D/added-$it" 2>/dev/null || true
                    if timeout 30 ip $(ipc "$it") add $l < /dev/null > /dev/null 2> "$D/err"; then
                        n=$((n + 1))
                    else
                        sed -i "\$d" "$D/added-$it"
                        st=FAILED det="add failed after $n: $(san)"
                        break
                    fi
                done < "$D/items/$it.add"
                [ "$st" = APPLIED ] && det="$n added" ;;
        esac
        printf "apply\t%s\t%s\t%s\n" "$it" "$st" "$det" >> "$D/apply.result"
        [ "$st" = APPLIED ] || break
    done
    cat "$D/apply.result"
}

ph_counts() {
    printf "host\t%s\n" "$(hostname -f 2>/dev/null || hostname)"
    printf "now\t%s\n" "$(date +%s)"
    [ -f "$D/scheduled" ] && printf "due\t%s\n" "$(cat "$D/scheduled")"
    printf "timer\t%s\n" "$(systemctl is-active "$U.timer" 2>/dev/null)"
    [ -f "$D/applied" ] || return 0
    while IFS= read -r it; do
        case "$it" in
            iptables-v*)
                awk "$AWK_IPT" "$D/items/$it.rules" > "$D/exp"
                timeout 60 "$(tool "$it")-save" 2>/dev/null | awk "$AWK_IPT" > "$D/act"
                join_counts "$it" "$D/exp" "$D/act" ;;
            nftables)
                awk "$AWK_NFT" "$D/items/nftables.batch" > "$D/exp"
                timeout 60 nft -s list ruleset 2>/dev/null | awk "$AWK_NFT" > "$D/act"
                join_counts "$it" "$D/exp" "$D/act" ;;
            routes-*|rules-*)
                e=0 a=0
                while IFS= read -r l; do
                    e=$((e + 1))
                    case "$it" in
                        routes-*) route_present "$it" "$l" && a=$((a + 1)) ;;
                        rules-*)  rule_present "$it" "$l" && a=$((a + 1)) ;;
                    esac
                done < "$D/added-$it"
                printf "count\t%s\t-\t%s\t%s\n" "$it" "$e" "$a" ;;
        esac
    done < "$D/applied"
}

ph_rollback() {
    trap "" HUP PIPE INT TERM
    [ -e "$D/rollback.result" ] && return 0
    tmp="$D/rollback.result.tmp"
    : > "$tmp"
    if ! integrity; then
        printf "result=FAILED\nreason=integrity check failed (SUMS): nothing restored\n" > "$tmp"
        mv -f "$tmp" "$D/rollback.result"
        return 1
    fi
    res=OK
    if [ -f "$D/applied" ]; then
        for it in $(tac "$D/applied"); do
            st=OK det=""
            case "$it" in
                iptables-v*)
                    ipt_restore "$it" "$D/pre/$it.rules" || { st=FAILED; det="$(san)"; }
                    # Cek sendiri: jumlah aturan per tabel = snapshot pra-restore
                    if [ "$st" = OK ]; then
                        timeout 60 "$(tool "$it")-save" 2>/dev/null | awk "$AWK_IPT" > "$D/rb.act"
                        awk "$AWK_IPT" "$D/pre/$it.rules" > "$D/rb.exp"
                        mism="$(awk -F "\t" "FNR == NR { a[\$1] = \$2; next } (\$1 in a) && a[\$1] != \$2 { printf \"%s: %s now, %s expected; \", \$1, a[\$1], \$2 }" "$D/rb.act" "$D/rb.exp")"
                        [ -z "$mism" ] || { st=FAILED; det="counts differ after restore: $mism"; }
                    fi
                    if [ "$st" = OK ] && [ -s "$D/pre/$it.drop" ]; then
                        if [ "$BK" = nf_tables ]; then
                            for tb in $(cat "$D/pre/$it.drop"); do
                                timeout 30 nft delete table "$(fam "$it")" "$tb" < /dev/null > /dev/null 2> "$D/err" \
                                    || { st=FAILED; det="delete table $tb: $(san)"; }
                            done
                        elif [ -s "$D/pre/$it.empty" ]; then
                            ipt_restore "$it" "$D/pre/$it.empty" || { st=FAILED; det="empty tables: $(san)"; }
                            det="${det:-tables emptied: $(tr "\n" " " < "$D/pre/$it.drop")}"
                        fi
                    fi ;;
                nftables)
                    timeout 60 nft -f "$D/pre/nftables.batch" < /dev/null > /dev/null 2> "$D/err" \
                        || { st=FAILED; det="$(san)"; } ;;
                routes-*|rules-*)
                    n=0 miss=0
                    if [ -f "$D/added-$it" ]; then
                        while IFS= read -r l; do
                            valid_line "$l" || { st=FAILED; det="invalid entry"; continue; }
                            if timeout 30 ip $(ipc "$it") del $l < /dev/null > /dev/null 2> "$D/err"; then
                                n=$((n + 1))
                            elif grep -qE "No such process|No such file|Cannot find" "$D/err"; then
                                miss=$((miss + 1))
                            else
                                st=FAILED det="$(san)"
                            fi
                        done < "$D/added-$it"
                    fi
                    [ "$st" = OK ] && det="$n removed, $miss already absent" ;;
            esac
            [ "$st" = OK ] || res=FAILED
            printf "%s\t%s\t%s\n" "$it" "$st" "$det" >> "$tmp"
        done
    fi
    printf "result=%s\n" "$res" >> "$tmp"
    mv -f "$tmp" "$D/rollback.result"
}

ph_rollback_now() {
    timeout 140 systemctl start "$U.service" > /dev/null 2>&1 || true
    if [ -f "$D/rollback.result" ]; then sed "s/^/rb:/" "$D/rollback.result"; else echo "rb:result=PENDING"; fi
}

ph_verify_rollback() {
    [ -f "$D/applied" ] || { printf "vr\tall\tOK\tnothing applied\n"; return 0; }
    while IFS= read -r it; do
        st=OK det=""
        case "$it" in
            iptables-v*)
                timeout 60 "$(tool "$it")-save" 2>/dev/null > "$D/live"
                for tb in $(ipt_tables "$D/pre/$it.rules"); do
                    if ! cmp -s <(ipt_section "$tb" < "$D/live") <(ipt_section "$tb" < "$D/pre/$it.rules"); then
                        st=MISMATCH det="$det table $tb: $(ipt_section "$tb" < "$D/live" | grep -c "^-A ") rules now, $(ipt_section "$tb" < "$D/pre/$it.rules" | grep -c "^-A ") expected;"
                    fi
                done
                if [ -s "$D/pre/$it.drop" ]; then
                    for tb in $(cat "$D/pre/$it.drop"); do
                        if [ "$BK" = nf_tables ]; then
                            ipt_tables "$D/live" | grep -qx "$tb" && { st=MISMATCH; det="$det table $tb still present;"; }
                        else
                            [ "$(ipt_section "$tb" < "$D/live" | grep -c "^-A ")" = 0 ] || { st=MISMATCH; det="$det table $tb not empty;"; }
                        fi
                    done
                fi ;;
            nftables)
                if ! cmp -s <(timeout 60 nft -s list ruleset 2>/dev/null | nft_norm) <(nft_norm < "$D/pre/nftables.batch"); then
                    st=MISMATCH det="ruleset differs from pre-restore snapshot"
                fi ;;
            routes-*|rules-*)
                left=0
                [ -f "$D/added-$it" ] && while IFS= read -r l; do
                    case "$it" in
                        routes-*) route_present "$it" "$l" && left=$((left + 1)) ;;
                        rules-*)  rule_present "$it" "$l" && left=$((left + 1)) ;;
                    esac
                done < "$D/added-$it"
                [ "$left" = 0 ] || { st=MISMATCH; det="$left added entries still present"; } ;;
        esac
        printf "vr\t%s\t%s\t%s\n" "$it" "$st" "$det"
    done < "$D/applied"
}

ph_confirm() {
    systemctl stop "$U.timer" > /dev/null 2>&1 || true
    i=0
    while :; do
        s="$(systemctl is-active "$U.service" 2>/dev/null)"
        [ "$s" = activating ] || [ "$s" = active ] || [ "$s" = deactivating ] || break
        i=$((i + 1)); [ "$i" -ge 130 ] && break
        sleep 1
    done
    if [ -e "$D/rollback.result" ]; then printf "confirm\tROLLED_BACK\n"; return 30; fi
    if [ "$(systemctl is-active "$U.timer" 2>/dev/null)" = active ]; then printf "confirm\tFAILED\ttimer still active\n"; return 31; fi
    cd / && rm -rf -- "$D"
    printf "confirm\tOK\n"
}

ph_cleanup() {
    if [ "$(systemctl is-active "$U.timer" 2>/dev/null)" = active ]; then echo "cleanup: timer active"; return 32; fi
    s="$(systemctl is-active "$U.service" 2>/dev/null)"
    case "$s" in active|activating|deactivating) echo "cleanup: rollback running"; return 32 ;; esac
    if [ -e "$D/applied" ] && ! grep -qx "result=OK" "$D/rollback.result" 2>/dev/null; then
        echo "cleanup: applied without verified rollback"; return 32
    fi
    cd / && rm -rf -- "$D"
    echo "cleanup OK"
}

case "$PH" in
    verify)          ph_verify ;;
    schedule)        ph_schedule ;;
    apply)           ph_apply ;;
    counts)          ph_counts ;;
    rollback)        ph_rollback ;;
    rollback-now)    ph_rollback_now ;;
    verify-rollback) ph_verify_rollback ;;
    confirm)         ph_confirm ;;
    cleanup)         ph_cleanup ;;
    *) echo "agent: unknown phase"; exit 2 ;;
esac'

# Nama statis yang boleh ada di bundle upload
BUNDLE_NAMES='./|./agent.sh|./conf|./SUMS|./items/|./pre/|./items/iptables-v4.rules|./items/iptables-v6.rules|./items/nftables.batch|./items/routes-v4.add|./items/routes-v6.add|./items/rules-v4.add|./items/rules-v6.add|./pre/iptables-v4.rules|./pre/iptables-v6.rules|./pre/nftables.batch|./pre/iptables-v4.drop|./pre/iptables-v6.drop|./pre/iptables-v4.empty|./pre/iptables-v6.empty'

# ============================================================
# Perintah remote statis (hanya run_id tervalidasi yang berubah)
# ============================================================

# Upload: tar dari stdin => cek daftar isi (nama statis, hanya file/direktori)
# => direktori node harus BELUM ada => ekstrak (root, 700/600)
upload_cmd() {
    local r="$1"
    [[ "$r" =~ $NS_RUN_ID_RE ]] || return 1
    # shellcheck disable=SC2016
    printf '%s' 'set -u; umask 077; R='"$r"'; B='"$NODE_BASE"'; D="$B/$R"
t="$(mktemp /tmp/osops-restore-$R.XXXXXX)" || exit 3
trap '"'"'rm -f -- "$t"'"'"' EXIT
cat > "$t"
tar -tzf "$t" > "$t.l" 2>/dev/null || { rm -f -- "$t.l"; echo "osops: bad tar"; exit 4; }
while IFS= read -r n; do case "$n" in '"$BUNDLE_NAMES"') ;; *) rm -f -- "$t.l"; echo "osops: unexpected name in archive"; exit 5 ;; esac; done < "$t.l"
rm -f -- "$t.l"
ty="$(tar -tvzf "$t" | cut -c1 | sort -u | tr -d "\n")"
case "$ty" in ""|*[!d-]*) echo "osops: unexpected entry type in archive"; exit 5 ;; esac
if sudo -n test -e "$D"; then echo "osops: node directory exists"; exit 6; fi
sudo -n install -d -m 700 "$B" || exit 7
sudo -n mkdir -m 700 "$D" || { echo "osops: node directory exists or cannot be created"; exit 6; }
sudo -n tar -xzf "$t" -C "$D" --no-same-owner --no-same-permissions --no-overwrite-dir || exit 8
sudo -n find "$D" -mindepth 1 -type d -exec chmod 700 {} + || exit 8
sudo -n find "$D" -type f -exec chmod 600 {} + || exit 8
echo __OSOPS_UPLOADED__'
}

agent_cmd() {
    local run="${AGENT_RUN:-$LOG_RUN_ID}"
    [[ "$run" =~ $NS_RUN_ID_RE ]] || return 1
    printf 'sudo -n timeout %d /bin/bash %s/%s/agent.sh %s' "$AGENT_T" "$NODE_BASE" "$run" "$1"
    [[ -n "${2:-}" ]] && printf ' %d' "$2"
    return 0
}

# Status tanpa agent (direktori bisa sudah tidak ada)
status_cmd() {
    local r="$1"
    [[ "$r" =~ $NS_RUN_ID_RE ]] || return 1
    # shellcheck disable=SC2016
    printf '%s' 'R='"$r"'; D='"$NODE_BASE"'/$R; U=osops-restore-rb-$R
echo __OSOPS_RESTORE_STATUS__
printf "timer=%s\n" "$(systemctl is-active "$U.timer" 2>/dev/null)"
printf "service=%s\n" "$(systemctl is-active "$U.service" 2>/dev/null)"
if sudo -n test -d "$D"; then echo dir=1; else echo dir=0; fi
if sudo -n test -f "$D/applied"; then printf "applied=%s\n" "$(sudo -n cat "$D/applied" | tr "\n" "," )"; fi
if sudo -n test -f "$D/scheduled"; then printf "due=%s\n" "$(sudo -n cat "$D/scheduled")"; fi
printf "now=%s\n" "$(date +%s)"
if sudo -n test -f "$D/rollback.result"; then sudo -n cat "$D/rollback.result" | sed "s/^/rb:/"; fi'
}

# Hapus direktori node (hanya --clear-state, setelah status jelas)
clear_cmd() {
    local r="$1"
    [[ "$r" =~ $NS_RUN_ID_RE ]] || return 1
    # shellcheck disable=SC2016
    printf '%s' 'R='"$r"'; D='"$NODE_BASE"'/$R; U=osops-restore-rb-$R
if [ "$(systemctl is-active "$U.timer" 2>/dev/null)" = active ]; then echo "osops: timer active"; exit 3; fi
case "$(systemctl is-active "$U.service" 2>/dev/null)" in active|activating|deactivating) echo "osops: rollback running"; exit 3 ;; esac
sudo -n rm -rf -- "$D" && echo __OSOPS_CLEARED__'
}

# Pre-check restore (statis)
# shellcheck disable=SC2016
RESTORE_PRECHECK='echo __OSOPS_RESTORE__
if sudo -n true >/dev/null 2>&1; then echo sudo=ok; else echo sudo=fail; fi
for t in systemd-run systemctl tar sha256sum mktemp timeout; do command -v "$t" >/dev/null 2>&1 || printf "missing=%s\n" "$t"; done
for t in iptables-restore ip6tables-restore nft ip; do
    v=--version; [ "$t" = ip ] && v=-V
    sudo -n timeout 10 "$t" "$v" >/dev/null 2>&1; [ $? -eq 127 ] && printf "missing_root=%s\n" "$t"
done
printf "hostname=%s\n" "$(hostname -f 2>/dev/null || hostname)"'

# ============================================================
# Helper
# ============================================================

human_age() {
    local s="$1"
    if (( s < 3600 )); then printf '%d menit' $(( s / 60 ))
    elif (( s < 172800 )); then printf '%d jam' $(( s / 3600 ))
    else printf '%d hari' $(( s / 86400 )); fi
}

stack_name() {
    if [[ "$INVENTORY" =~ /overcloud-deploy/([^/]+)/tripleo-ansible-inventory\.yaml$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf -- '-'
    fi
}

item_file() {
    case "$1" in
        iptables-v4|iptables-v6) printf '%s.rules' "$1" ;;
        nftables)                printf 'nftables.ruleset' ;;
        routes-v4|routes-v6|rules-v4|rules-v6) printf '%s.json' "$1" ;;
    esac
}

# Sisa output "key=value" (baris pertama yang cocok)
kv() {
    sed -n "s/^$2=//p" <<< "$1" | head -n 1
}

# ssh dengan koneksi BARU (tanpa ControlMaster / koneksi yang dipakai ulang)
fresh_ssh() {
    local RHOSP_SSH_EXTRA=(-o ControlMaster=no -o ControlPath=none -o ControlPersist=no)
    ssh_node "$@"
}

# ask_timeout VAR PROMPT DETIK — return 1 jika waktu habis
ask_timeout() {
    local __r="" __t="$3"
    (( __t > 0 )) || return 1
    printf '%s' "$2" > /dev/tty
    if IFS= read -r -t "$__t" __r < /dev/tty; then
        printf -v "$1" '%s' "$__r"
        return 0
    fi
    echo > /dev/tty
    return 1
}

set_item() {
    ST[$1]="$2"
    RS[$1]="$3"
}

# ============================================================
# State file per node
# ============================================================

state_init() {
    [[ -n "$LOG_FILE" ]] || return 1
    STATE_FILE="$(dirname "$LOG_FILE")/restore-network-state-$NAME.state"
    LOCK_FILE="$(dirname "$LOG_FILE")/restore-network-state-$NAME.lock"
}

# state_write PHASE — ditulis atomik (600) sebelum setiap langkah yang mengubah node
state_write() {
    local tmp="$STATE_FILE.tmp.$$"
    if ! ( umask 077; set -o noclobber
           {
               echo "# restore-network-state: restore belum tuntas. Cek: restore-network-state.sh --status --host $NAME"
               echo "run_id=$LOG_RUN_ID"
               echo "host=$NAME"
               echo "items=$(IFS=,; printf '%s' "${ITEMS[*]}")"
               echo "phase=$1"
               echo "unit=$UNIT"
               echo "node_dir=$NODE_DIR"
               echo "due_epoch_node=${DUE:--}"
               echo "backup_dir=$BACKUP_DIR"
               echo "pre_restore_dir=${PRE_DIR:--}"
               echo "updated=$(date -Iseconds)"
               echo "operator=${SUDO_USER:-$(id -un)}"
           } > "$tmp" ) 2>/dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -fT -- "$tmp" "$STATE_FILE" || { rm -f -- "$tmp"; return 1; }
    log_event STATE_FILE action=write "phase=$1" "file=$STATE_FILE"
}

state_remove() {
    [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]] || return 0
    rm -f -- "$STATE_FILE"
    log_event STATE_FILE action=remove "file=$STATE_FILE"
}

state_get() {
    sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1
}

# ============================================================
# Pemilihan backup, host, item
# ============================================================

backup_base() {
    printf '%s' "${OSOPS_BACKUP_DIR:-$HOME/osops-backups}/network-state"
}

pick_list() {
    # pick_list PROMPT MULTI LABEL... => index (baris) terpilih di PICKED
    local prompt="$1" multi="$2" out rc=0 i input tok
    shift 2
    local -a labels=("$@") sel=()
    PICKED=()
    if command -v "${FZF_CMD[0]}" >/dev/null 2>&1; then
        local -a fopt=(--layout=reverse --border --info=inline --delimiter=$'\t' --with-nth=2.. "--prompt=$prompt> ")
        (( multi )) && fopt+=(--multi --header='Tab: pilih/batal pilih, Enter: selesai, Esc: batal')
        out="$(for i in "${!labels[@]}"; do printf '%d\t%s\n' "$i" "${labels[$i]}"; done | "${FZF_CMD[@]}" "${fopt[@]}")" || rc=$?
        (( rc == 0 )) || return 1
        mapfile -t sel <<< "$out"
        for i in "${sel[@]}"; do [[ -n "$i" ]] && PICKED+=("${i%%$'\t'*}"); done
    else
        echo
        for i in "${!labels[@]}"; do printf '  %2d) %s\n' $(( i + 1 )) "${labels[$i]}"; done
        ask input "$prompt — nomor$( (( multi )) && echo ' (mis. 1 3)') (kosong = batal): "
        read -ra sel <<< "${input//,/ }"
        for tok in "${sel[@]}"; do
            if is_uint "$tok" && (( tok >= 1 && tok <= ${#labels[@]} )); then PICKED+=($(( tok - 1 ))); fi
        done
        if (( ! multi && ${#PICKED[@]} > 1 )); then PICKED=("${PICKED[0]}"); fi
    fi
    (( ${#PICKED[@]} > 0 ))
}

choose_backup() {
    local base d m age label now
    local -a dirs=() labels=()
    if [[ -n "$BACKUP_DIR" ]]; then
        BACKUP_DIR="$(cd "$BACKUP_DIR" 2>/dev/null && pwd -P)" || die "--backup-dir tidak ditemukan."
        return 0
    fi
    has_tty || die "Tanpa terminal: --backup-dir wajib."
    base="$(backup_base)"
    now="$(date +%s)"
    while IFS= read -r m; do
        d="$(dirname "$m")"
        age="$(human_age $(( now - $(stat -c %Y "$m") )))"
        label="$(printf '%-40s %-14s %s host' "$(basename "$d")" "$age lalu" "$(find "$d" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)")"
        [[ "$d" == *-pre-restore ]] && label+="  (snapshot pra-restore)"
        dirs+=("$d") labels+=("$label")
    done < <(find "$base" -mindepth 2 -maxdepth 2 -name MANIFEST.tsv -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    (( ${#dirs[@]} > 0 )) || die "Tidak ada backup di $base. Gunakan --backup-dir."
    pick_list "📦 backup" 0 "${labels[@]}" || { echo "Tidak ada backup yang dipilih."; exit 0; }
    BACKUP_DIR="${dirs[${PICKED[0]}]}"
}

choose_host() {
    local h
    local -a hosts=()
    if [[ -n "$HOST" ]]; then return 0; fi
    has_tty || die "Tanpa terminal: --host wajib."
    mapfile -t hosts < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | LC_ALL=C sort)
    (( ${#hosts[@]} > 0 )) || die "Backup tidak berisi host: $BACKUP_DIR"
    pick_list "🖥️  host" 0 "${hosts[@]}" || { echo "Tidak ada host yang dipilih."; exit 0; }
    h="${hosts[${PICKED[0]}]}"
    HOST="$h"
}

# Item yang boleh dipilih: data OK di MANIFEST, verifikasi tidak FAILED
item_eligible() {
    local it="$1" f row st v
    f="$(item_file "$it")"
    row="$(ns_manifest_get "$BACKUP_DIR" "$HOST" "$f")"
    st="${row%%$'\t'*}"
    if [[ -z "$row" ]]; then ELIG_MSG="not in backup"; return 1; fi
    if [[ "$st" != OK ]]; then ELIG_MSG="manifest status $st ($(cut -f2 <<< "$row"))"; return 1; fi
    case "$it" in
        iptables-v*|nftables)
            v="$(ns_manifest_get "$BACKUP_DIR" "$HOST" "verify:$f" | cut -f1)"
            if [[ "$v" == FAILED ]]; then ELIG_MSG="VERIFY_FAILED in backup"; return 1; fi
            if [[ "$it" == nftables && "$v" == SKIPPED ]]; then ELIG_MSG="verification skipped in backup (xt): use iptables-v4/v6"; return 1; fi ;;
    esac
    return 0
}

choose_items() {
    local it
    local -a cand=() labels=()
    if (( ITEMS_SET )); then
        IFS=',' read -ra ITEMS <<< "$ITEMS_ARG"
    else
        has_tty || die "Tanpa terminal: --items wajib."
        for it in "${ALL_ITEMS[@]}"; do
            if item_eligible "$it"; then cand+=("$it") labels+=("$it"); fi
        done
        (( ${#cand[@]} > 0 )) || die "Tidak ada item yang bisa di-restore untuk $HOST di backup ini."
        pick_list "🧩 item" 1 "${labels[@]}" || { echo "Tidak ada item yang dipilih."; exit 0; }
        ITEMS=()
        for it in "${PICKED[@]}"; do ITEMS+=("${cand[$it]}"); done
    fi
    local -a clean=()
    local -A seen=()
    for it in "${ITEMS[@]}"; do
        it="$(trim "$it")"
        [[ -n "$it" ]] || continue
        if [[ "$it" == netns* ]]; then
            die "Network namespace (netns) tidak di-restore: isinya dikelola agen OVN/neutron."
        fi
        [[ " ${ALL_ITEMS[*]} " == *" $it "* ]] || die "Item tidak dikenal: $it (pilihan: $(IFS=,; printf '%s' "${ALL_ITEMS[*]}"))"
        [[ -n "${seen[$it]+x}" ]] && continue
        seen[$it]=1
        clean+=("$it")
    done
    (( ${#clean[@]} > 0 )) || die "--items kosong."
    # Urutan tetap: iptables lalu nftables lalu route/rule
    ITEMS=()
    for it in "${ALL_ITEMS[@]}"; do
        [[ -n "${seen[$it]+x}" ]] && ITEMS+=("$it")
    done
    return 0
}

has_item() {
    [[ " ${ITEMS[*]} " == *" $1 "* ]]
}

# ============================================================
# Validasi backup dan item
# ============================================================

validate_backup() {
    local now
    if ! ns_verify_run "$BACKUP_DIR" "$HOST"; then
        log_error -q "backup validation failed: $NS_VERIFY_MSG"
        die "Backup tidak valid: $NS_VERIFY_MSG"
    fi
    BAK_HOSTNAME="$(jq -r '.hostname // ""' "$BACKUP_DIR/$HOST/meta.json")"
    BAK_BACKEND="$(jq -r '.tools.iptables_backend // "-"' "$BACKUP_DIR/$HOST/meta.json")"
    BAK_COUNTERS="$(jq -r 'if .options.counters then 1 else 0 end' "$BACKUP_DIR/$HOST/meta.json")"
    BAK_EPOCH="$(jq -r '.node_time.epoch // empty | tostring' "$BACKUP_DIR/$HOST/meta.json")"
    is_uint "${BAK_EPOCH:-x}" || BAK_EPOCH="$(stat -c %Y "$BACKUP_DIR/MANIFEST.tsv")"
    now="$(date +%s)"
    echo "📦 Backup           : $BACKUP_DIR$( [[ "$BACKUP_DIR" == *-pre-restore ]] && echo ' (snapshot pra-restore)')"
    echo "   Umur             : $(human_age $(( now - BAK_EPOCH ))) ($(date -d "@$BAK_EPOCH" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$BAK_EPOCH"))"
    echo "   Hostname / backend: $BAK_HOSTNAME / $BAK_BACKEND"
    log_event BACKUP "dir=$BACKUP_DIR" "host=$HOST" "age_s=$(( now - BAK_EPOCH ))" "backend=$BAK_BACKEND" result=OK
}

validate_items() {
    local it
    for it in "${ITEMS[@]}"; do
        if ! item_eligible "$it"; then
            log_error -q "item rejected: item=$it reason=$ELIG_MSG"
            die "Item $it tidak bisa di-restore: $ELIG_MSG."
        fi
    done
    if [[ "$BAK_BACKEND" == nf_tables ]] && has_item nftables && { has_item iptables-v4 || has_item iptables-v6; }; then
        die "Backend nf_tables: nftables tidak bisa digabung dengan iptables-v4/v6 (tabel tumpang-tindih). Item nftables saja sudah mencakup tabel iptables-nft."
    fi
    if has_item nftables && grep -qE '(^|[[:space:]])xt (match|target)[[:space:]]' "$BACKUP_DIR/$HOST/nftables.ruleset"; then
        die "nftables.ruleset di backup berisi ekspresi xt (iptables-nft compat): tidak bisa dimuat nft -f. Gunakan iptables-v4/iptables-v6."
    fi
    log_event INPUT "items=$(IFS=,; printf '%s' "${ITEMS[*]}")"
}

# ============================================================
# Node, pre-check, kondisi saat ini
# ============================================================

resolve_node() {
    local i="${IDX_BY_NAME[${HOST,,}]:-}"
    if [[ -z "$i" ]] || (( N_LOCAL[i] )); then
        if [[ "${HOST,,}" == "${UC_NAME,,}" || "${HOST,,}" == undercloud ]]; then
            die "Undercloud tidak didukung sebagai target restore."
        fi
        die "Host $HOST tidak ada di inventory overcloud."
    fi
    TGT="$i"
    NAME="${N_NAME[$i]}"
    UNIT="osops-restore-rb-$LOG_RUN_ID"
    NODE_DIR="$NODE_BASE/$LOG_RUN_ID"
    [[ "${N_PCMK[$i]}" == 1 || "${N_PCMKR[$i]}" == 1 ]] && CLUSTER=1
    return 0
}

PRE_SUDO="" PRE_MISSING=""
precheck_node() {
    local out rc=0 line
    check_host_keys "node tujuan" "$TGT"
    [[ "${N_HK[$TGT]}" != reject ]] || die "Host key $NAME belum dikenal dan tidak diterima."
    out="$(ssh_node "$TGT" "$SSH_T" "$RESTORE_PRECHECK" 2> "$WORK_DIR/pre.err")" || rc=$?
    if [[ "$out" != *__OSOPS_RESTORE__* ]]; then
        die "Pre-check $NAME gagal: $(ssh_fail_reason "$(cat "$WORK_DIR/pre.err")" "$rc")"
    fi
    log_accepted_key "$TGT"
    rhosp_report_fallbacks "$TGT"
    PRE_SUDO="$(kv "$out" sudo)"
    PRE_MISSING=""
    while IFS= read -r line; do
        case "$line" in
            missing=*|missing_root=*) PRE_MISSING+="${PRE_MISSING:+,}${line#*=}" ;;
        esac
    done <<< "$out"
    log_event PRECHECK "host=$NAME" "sudo=${PRE_SUDO:--}" "missing=${PRE_MISSING:--}"
}

# Kondisi saat ini (kolektor read-only dari lib/netstate.sh) => DIR/<host>/
collect_state() {
    local out="$1" dest="$2" stage="$WORK_DIR/stage-$RANDOM"
    ( umask 077; mkdir -p -- "$(dirname "$dest")" ) || { COLLECT_MSG="cannot create $(dirname "$dest")"; return 1; }
    ns_collect "$TGT" "$out" "$LOG_RUN_ID" "$BAK_COUNTERS" 0 0 "$TIMEOUT_S"
    ns_receive "$NAME" "$out" "$stage" "$dest" 0 "$TIMEOUT_S"
    if [[ -n "$NS_RX_MSG" ]]; then
        COLLECT_MSG="$NS_RX_MSG"
        return 1
    fi
    COLLECT_STAGE="$stage"
    return 0
}

read_current() {
    local stage="$1"
    CUR_HOSTNAME="$(ns_meta_get "$stage/_meta.env" hostname)"
    CUR_BACKEND="$(ns_backend "$(ns_meta_get "$stage/_meta.env" iptables_version)")"
}

check_identity() {
    if [[ "$CUR_HOSTNAME" != "$BAK_HOSTNAME" ]]; then
        log_error -q "hostname mismatch backup=$BAK_HOSTNAME node=$CUR_HOSTNAME"
        die "Hostname node ($CUR_HOSTNAME) tidak sama dengan hostname di backup ($BAK_HOSTNAME). Restore ditolak."
    fi
    if [[ "$CUR_BACKEND" != "$BAK_BACKEND" || "$CUR_BACKEND" == "-" || "$CUR_BACKEND" == unknown ]]; then
        log_error -q "backend mismatch backup=$BAK_BACKEND node=$CUR_BACKEND"
        die "Backend iptables node ($CUR_BACKEND) tidak sama dengan backup ($BAK_BACKEND). Restore ditolak."
    fi
    echo "✅ Hostname dan backend cocok: $CUR_HOSTNAME / $CUR_BACKEND"
}

# ============================================================
# Diff
# ============================================================

ipt_tables() {
    sed -n 's/^\*//p' "$1" 2>/dev/null
}
ipt_section() {
    awk -v t="$2" '/^\*/ { on = (substr($0, 2) == t) } on' "$1" | grep -v '^#' \
        | sed -E 's/^(:[^ ]+ [^ ]+) \[[0-9]+:[0-9]+\]$/\1 [0:0]/; s/^\[[0-9]+:[0-9]+\] //'
}
nft_norm() {
    grep -v -e '^#' -e '^flush ruleset$' "$1" | sed -E 's/ packets [0-9]+ bytes [0-9]+//; s/[[:space:]]+$//' | grep -v '^$' || true
}
has_xt() {
    grep -qE '(^|[[:space:]])xt (match|target)[[:space:]]' "$1" 2>/dev/null
}

# diff_ipt ITEM CURDIR — tabel di backup diganti, tabel lain tidak disentuh
diff_ipt() {
    local it="$1" cur="$2/$1.rules" bak="$BACKUP_DIR/$HOST/$1.rules" t a r add=0 rem=0 d
    local -A inbak=()
    if [[ ! -f "$cur" ]]; then NOTE[$it]="cannot read current $it (tool missing?)"; return 1; fi
    {
        echo "=== $it ($( [[ $it == *v4 ]] && echo iptables || echo ip6tables)-restore: tabel di backup diganti atomik per tabel) ==="
        for t in $(ipt_tables "$bak"); do
            inbak[$t]=1
            d="$(diff <(ipt_section "$cur" "$t") <(ipt_section "$bak" "$t"))" || true
            a="$(grep -c '^> -A ' <<< "$d")" || a=0
            r="$(grep -c '^< -A ' <<< "$d")" || r=0
            add=$(( add + a )) rem=$(( rem + r ))
            if ! ipt_tables "$cur" | grep -qx "$t"; then
                echo "  tabel $t: dibuat (+$a aturan)$( [[ "$CUR_BACKEND" == legacy ]] && echo ' — saat rollback hanya bisa DIKOSONGKAN (legacy)')"
            else
                echo "  tabel $t: +$a / -$r aturan"
            fi
        done
        for t in $(ipt_tables "$cur"); do
            [[ -n "${inbak[$t]+x}" ]] || echo "  tabel $t: tidak ada di backup — DIBIARKAN (tidak diubah)"
        done
        diff -u --label "sekarang ($NAME)" --label "backup" \
            <(for t in "${!inbak[@]}"; do ipt_section "$cur" "$t"; done | sort) \
            <(for t in "${!inbak[@]}"; do ipt_section "$bak" "$t"; done | sort) | tail -n +3 || true
        echo
    } >> "$DIFF_FILE"
    ADDN[$it]=$add REMN[$it]=$rem
    return 0
}

diff_nft() {
    local cur="$2/nftables.ruleset" bak="$BACKUP_DIR/$HOST/nftables.ruleset" t ipt_tabs="" only_cur="" only_bak=""
    local -A cc=() bc=()
    if [[ ! -f "$cur" ]]; then NOTE[nftables]="cannot read current nftables (nft missing?)"; return 1; fi
    if has_xt "$cur"; then
        NOTE[nftables]="current ruleset contains xt expressions: rollback via nft -f would fail"
        return 2
    fi
    while IFS=$'\t' read -r t a; do cc[$t]="$a"; done < <(awk "$AWK_NFT_COUNT" "$cur")
    while IFS=$'\t' read -r t a; do bc[$t]="$a"; done < <(awk "$AWK_NFT_COUNT" "$bak")
    ipt_tabs="$(sed -n 's/^# Warning: table \(.*\) is managed by iptables-nft.*/\1/p' "$cur" "$bak" | sort -u | paste -sd, -)"
    {
        echo "=== nftables (satu batch atomik: flush ruleset + isi backup) ==="
        for t in "${!bc[@]}"; do
            if [[ -n "${cc[$t]+x}" ]]; then
                echo "  table $t: ${cc[$t]} => ${bc[$t]} aturan"
            else
                echo "  table $t: dibuat (${bc[$t]} aturan)"; only_bak+="${only_bak:+, }$t"
            fi
        done
        for t in "${!cc[@]}"; do
            if [[ -z "${bc[$t]+x}" ]]; then
                echo "  table $t: tidak ada di backup — DIHAPUS oleh flush ruleset (${cc[$t]} aturan)"; only_cur+="${only_cur:+, }$t"
            fi
        done
        if [[ -n "$ipt_tabs" ]]; then
            echo "  ⚠️  Item nftables juga MENGUBAH tabel iptables-nft: $ipt_tabs"
        fi
        diff -u --label "sekarang ($NAME)" --label "backup" <(nft_norm "$cur") <(nft_norm "$bak") | tail -n +3 || true
        echo
    } >> "$DIFF_FILE"
    ADDN[nftables]="$(diff <(nft_norm "$cur") <(nft_norm "$bak") | grep -c '^>')" || ADDN[nftables]=0
    REMN[nftables]="$(diff <(nft_norm "$cur") <(nft_norm "$bak") | grep -c '^<')" || REMN[nftables]=0
    if [[ -n "$ipt_tabs" ]]; then NOTE[nftables]="also changes iptables-nft tables: $ipt_tabs"; fi
    return 0
}

# Klasifikasi route/rule dari JSON (ip -j): kind<TAB>key<TAB>spec
# kind: ok | default | manual | skip
# shellcheck disable=SC2016
JQ_ROUTES='
def ll: (.dst // "") as $d | ($d | test("^169\\.254\\.")) or ($d | test("^fe[89ab][0-9a-f]:"; "i"));
def spec($t): ([.dst]
    + (if .gateway then ["via", .gateway] else [] end)
    + (if .dev then ["dev", .dev] else [] end)
    + (if .protocol then ["proto", (.protocol | tostring)] else [] end)
    + (if .scope and .scope != "global" then ["scope", (.scope | tostring)] else [] end)
    + (if .metric != null then ["metric", (.metric | tostring)] else [] end)
    + (if .prefsrc then ["src", .prefsrc] else [] end)
    + (if ((.flags // []) | index(["onlink"])) then ["onlink"] else [] end)
    + (if .pref and .pref != "medium" then ["pref", .pref] else [] end)
    + (if $t != "main" then ["table", $t] else [] end)) | join(" ");
.[] | ((.table // "main") | tostring) as $t
| ((.metric // "-") | tostring) as $m
| if (.type // "unicast") != "unicast" then ["skip", "", ""]
  elif $t == "local" then ["skip", "", ""]
  elif (.protocol // "") == "kernel" then ["skip", "", ""]
  elif (.dst // "") == "default" then ["default", $t + "|default|" + $m, spec($t)]
  elif ll then ["skip", "", ""]
  elif has("expires") or (.protocol // "") == "ra" then ["skip", "", ""]
  elif ((keys - ["dst","gateway","dev","protocol","scope","prefsrc","metric","flags","table","type","pref"]) | length) > 0
       then ["manual", $t + "|" + .dst + "|" + $m, spec($t)]
  elif ((.flags // []) - ["onlink","linkdown","offload","rt_offload","trap","rt_trap"] | length) > 0
       then ["manual", $t + "|" + .dst + "|" + $m, spec($t)]
  else ["ok", $t + "|" + .dst + "|" + $m, spec($t)] end
| @tsv'

# shellcheck disable=SC2016
JQ_RULES='
.[] | (.priority // -1) as $p
| def spec: (["priority", ($p | tostring)]
    + (if has("not") then ["not"] else [] end)
    + (if .src and .src != "all" then ["from", (.src + (if .srclen then "/" + (.srclen | tostring) else "" end))] else [] end)
    + (if .dst and .dst != "all" then ["to", (.dst + (if .dstlen then "/" + (.dstlen | tostring) else "" end))] else [] end)
    + (if .fwmark then ["fwmark", (.fwmark + (if .fwmask then "/" + .fwmask else "" end))] else [] end)
    + (if .iif then ["iif", .iif] else [] end)
    + (if .oif then ["oif", .oif] else [] end)
    + ["lookup", ((.table // "") | tostring)]) | join(" ");
  if ($p == 0 or $p == 32766 or $p == 32767) then ["skip", "", ""]
  elif ((keys - ["priority","src","srclen","dst","dstlen","table","fwmark","fwmask","iif","oif","not"]) | length) > 0
       or (.table == null) then ["manual", "", (["priority", ($p | tostring)] | join(" ")) + " (unsupported attributes)"]
  else spec as $s | ["ok", $s, $s] end
| @tsv'

# Token yang boleh menjadi argumen ip route/rule add (divalidasi lagi di node)
valid_spec() {
    local w
    [[ -n "$1" ]] || return 1
    for w in $1; do
        [[ "$w" =~ ^[A-Za-z0-9._:/@][A-Za-z0-9._:/@-]*$ ]] || return 1
    done
    return 0
}

# diff_routes ITEM CURDIR — add-missing; selain itu hanya "tindakan manual"
diff_routes() {
    local it="$1" cur="$2/$1.json" bak="$BACKUP_DIR/$HOST/$1.json" prog kind key spec add=0 man=0
    local -A ck=() bk=() cdef=() bdef=()
    local addf="$WORK_DIR/add-$it" curl bakl
    [[ "$it" == routes-* ]] && prog="$JQ_ROUTES" || prog="$JQ_RULES"
    if [[ ! -f "$cur" ]]; then NOTE[$it]="current $it JSON not available (ip -j)"; return 1; fi
    curl="$(jq -r "$prog" "$cur" 2>/dev/null)" || { NOTE[$it]="current JSON cannot be parsed"; return 1; }
    bakl="$(jq -r "$prog" "$bak" 2>/dev/null)" || { NOTE[$it]="backup JSON cannot be parsed"; return 1; }
    : > "$addf"
    while IFS=$'\t' read -r kind key spec; do
        case "$kind" in
            ok)      ck[$key]="$spec" ;;
            default) cdef[$key]="$spec" ;;
        esac
    done <<< "$curl"
    {
        echo "=== $it (add-missing: hanya menambah; tidak pernah menghapus) ==="
        while IFS=$'\t' read -r kind key spec; do
            case "$kind" in
                ok)
                    bk[$key]=1
                    if [[ -z "${ck[$key]+x}" ]]; then
                        if valid_spec "$spec"; then
                            echo "  + $spec"
                            printf '%s\n' "$spec" >> "$addf"
                            add=$(( add + 1 ))
                        else
                            echo "  ! manual (tidak bisa divalidasi): $spec"
                            printf '%s\tinvalid\t%s\n' "$it" "$spec" >> "$MANUAL_FILE"
                            man=$(( man + 1 ))
                        fi
                    elif [[ "${ck[$key]}" != "$spec" ]]; then
                        echo "  ! manual (atribut berbeda): sekarang: ${ck[$key]} | backup: $spec"
                        printf '%s\tchanged\t%s => %s\n' "$it" "${ck[$key]}" "$spec" >> "$MANUAL_FILE"
                        man=$(( man + 1 ))
                    fi ;;
                default) bdef[$key]="$spec" ;;
                manual)
                    echo "  ! manual (atribut tidak didukung): $spec"
                    printf '%s\tunsupported\t%s\n' "$it" "$spec" >> "$MANUAL_FILE"
                    man=$(( man + 1 )) ;;
            esac
        done <<< "$bakl"
        for key in "${!ck[@]}"; do
            if [[ -z "${bk[$key]+x}" ]]; then
                echo "  ! manual (ada sekarang, tidak di backup; TIDAK dihapus): ${ck[$key]}"
                printf '%s\textra\t%s\n' "$it" "${ck[$key]}" >> "$MANUAL_FILE"
                man=$(( man + 1 ))
            fi
        done
        if [[ "$it" == routes-* ]] && [[ "$(printf '%s\n' "${cdef[@]}" | sort)" != "$(printf '%s\n' "${bdef[@]}" | sort)" ]]; then
            echo "  ! manual (default route berbeda; TIDAK disentuh): sekarang: $(printf '%s; ' "${cdef[@]}") | backup: $(printf '%s; ' "${bdef[@]}")"
            printf '%s\tdefault\tnow: %s | backup: %s\n' "$it" "$(printf '%s; ' "${cdef[@]}")" "$(printf '%s; ' "${bdef[@]}")" >> "$MANUAL_FILE"
            man=$(( man + 1 ))
        fi
        echo
    } >> "$DIFF_FILE"
    ADDN[$it]=$add REMN[$it]=0
    NOTE[$it]="$man manual"
    return 0
}

# compute_diff CURDIR — isi DIFF_FILE, ADDN/REMN per item; item yang tidak
# bisa dibandingkan => NOT_APPLIED
compute_diff() {
    local cur="$1" it rc
    : > "$DIFF_FILE"
    : > "$MANUAL_FILE"
    for it in "${ITEMS[@]}"; do
        rc=0
        case "$it" in
            iptables-v*) diff_ipt "$it" "$cur" || rc=$? ;;
            nftables)    diff_nft "$it" "$cur" || rc=$? ;;
            *)           diff_routes "$it" "$cur" || rc=$? ;;
        esac
        if (( rc != 0 )); then
            set_item "$it" NOT_APPLIED "${NOTE[$it]}"
        fi
    done
}

show_diff() {
    local it
    echo
    echo "${C_BOLD}🔍 Diff (backup vs sekarang) — '+' = dari backup (akan diterapkan), '-' = sekarang (akan hilang)${C_RESET}"
    cat "$DIFF_FILE"
    echo "${C_BOLD}Ringkasan diff:${C_RESET}"
    for it in "${ITEMS[@]}"; do
        if [[ "${ST[$it]:-}" == NOT_APPLIED ]]; then
            printf '  %-12s %s\n' "$it" "${C_YELLOW}tidak bisa: ${RS[$it]}${C_RESET}"
        else
            printf '  %-12s +%s / -%s%s\n' "$it" "${ADDN[$it]:-0}" "${REMN[$it]:-0}" "${NOTE[$it]:+  (${NOTE[$it]})}"
        fi
        log_event DIFF "item=$it" "add=${ADDN[$it]:-0}" "remove=${REMN[$it]:-0}" "note=${NOTE[$it]:--}" "status=${ST[$it]:-OK}"
    done
    if [[ -n "$SAVE_DIFF" ]]; then
        if ( umask 077; set -o noclobber; cat "$DIFF_FILE" > "$SAVE_DIFF" ) 2>/dev/null; then
            chmod 600 "$SAVE_DIFF" 2>/dev/null || true
            echo "💾 Diff disimpan: $SAVE_DIFF (600)"
            log_event SAVE_DIFF "file=$SAVE_DIFF"
        else
            warn "Diff tidak disimpan: $SAVE_DIFF sudah ada atau tidak bisa ditulis."
        fi
    fi
}

# ============================================================
# Cluster Pacemaker
# ============================================================

parse_status_nodes() {
    awk '
        /^[^ \t].*:[ \t]*$/ { next }
        /^[ \t]+[A-Za-z][A-Za-z ()]*:/ {
            line = $0; st = line
            sub(/:.*/, "", st); gsub(/^[ \t]+|[ \t]+$/, "", st)
            sub(/^[^:]*:/, "", line)
            n = split(line, a, /[ \t]+/)
            for (k = 1; k <= n; k++) if (a[k] != "") print st, a[k]
        }
    ' <<< "$1"
}

pick_ctrl() {
    local i
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        [[ "$i" == "$TGT" ]] && continue
        [[ "${N_PCMK[$i]}" == 1 ]] || continue
        check_host_keys "controller untuk pcs" "$i"
        [[ "${N_HK[$i]}" == reject ]] && continue
        CTRL="$i"
        return 0
    done
    return 1
}

# pcs_nodes => PCS_ONLINE (nama, dipisah spasi), PCS_BAD ("status nama, ...")
pcs_nodes() {
    local out rc=0 st n
    PCS_ONLINE="" PCS_BAD=""
    out="$(ssh_node "$CTRL" "$SSH_T" "sudo -n pcs status nodes" 2>/dev/null)" || rc=$?
    (( rc == 0 )) || return 1
    while read -r st n; do
        [[ -n "$n" ]] || continue
        if [[ "$st" == Online ]]; then
            PCS_ONLINE+="$n "
        else
            PCS_BAD+="${PCS_BAD:+, }$st $n"
        fi
    done < <(parse_status_nodes "$out")
    PCS_ONLINE="$(tr ' ' '\n' <<< "$PCS_ONLINE" | grep -v '^$' | sort | paste -sd' ' -)"
    [[ -n "$PCS_ONLINE" ]]
}

node_pcs_name() {
    # Nama node di pcs: hostname inventory atau short name canonical
    local n
    for n in "$NAME" "$(short_name "${N_CANON[$TGT]:-}")"; do
        [[ -n "$n" ]] && [[ " $PCS_ONLINE " == *" $n "* ]] && { printf '%s' "$n"; return 0; }
    done
    return 1
}

cluster_precheck() {
    local stonith
    (( CLUSTER )) || { echo "🔗 Cluster         : bukan anggota Pacemaker"; return 0; }
    pick_ctrl || die "Node anggota cluster, tetapi tidak ada Controller lain yang bisa dipakai untuk pcs."
    pcs_nodes || die "pcs status nodes dari ${N_NAME[$CTRL]} gagal."
    if [[ -n "$PCS_BAD" ]]; then
        log_error -q "cluster not all online: $PCS_BAD"
        die "Tidak semua node cluster Online ($PCS_BAD). Restore ditolak."
    fi
    node_pcs_name > /dev/null || die "$NAME tidak terlihat Online di pcs status nodes. Restore ditolak."
    ONLINE_BEFORE="$PCS_ONLINE"
    stonith="$(ssh_node "$CTRL" "$SSH_T" "sudo -n pcs property config stonith-enabled" 2>/dev/null \
        | sed -nE 's/^[[:space:]]*stonith-enabled[[:space:]]*[:=][[:space:]]*([^[:space:]]*).*/\1/p' | head -n 1)" || stonith=""
    echo "🔗 Cluster         : semua node Online ($(wc -w <<< "$ONLINE_BEFORE")), dicek dari ${N_NAME[$CTRL]}"
    echo "   stonith-enabled : ${stonith:-tidak diset (default true)}"
    if [[ "${stonith,,}" == false ]]; then
        warn "stonith-enabled=false: tanpa fencing, node yang bermasalah setelah restore TIDAK akan di-fence."
    fi
    log_event CLUSTER "controller=${N_NAME[$CTRL]}" "online=$(wc -w <<< "$ONLINE_BEFORE")" "stonith=${stonith:-unset}"
}

# ============================================================
# Bundle upload
# ============================================================

build_bundle() {
    local b="$WORK_DIR/bundle" it t pre="$PRE_DIR/$NAME"
    rm -rf -- "$b"
    ( umask 077; mkdir -p "$b/items" "$b/pre" )
    printf '%s\n' "$AGENT_SCRIPT" > "$b/agent.sh"
    {
        echo "run=$LOG_RUN_ID"
        echo "host=$CUR_HOSTNAME"
        echo "backend=$CUR_BACKEND"
        echo "items=$(IFS=,; printf '%s' "${APPLY_ITEMS[*]}")"
    } > "$b/conf"
    for it in "${APPLY_ITEMS[@]}"; do
        case "$it" in
            iptables-v*) [[ -s "$pre/$it.rules" ]] || die "Snapshot pra-restore tidak berisi $it.rules: rollback tidak mungkin, restore dibatalkan." ;;
            nftables)    [[ -f "$pre/nftables.ruleset" ]] || die "Snapshot pra-restore tidak berisi nftables.ruleset: restore dibatalkan." ;;
        esac
        case "$it" in
            iptables-v*)
                cp -- "$BACKUP_DIR/$HOST/$it.rules" "$b/items/$it.rules"
                cp -- "$pre/$it.rules" "$b/pre/$it.rules"
                # Tabel yang dibuat oleh restore (tidak ada sebelum restore)
                : > "$b/pre/$it.drop"
                for t in $(ipt_tables "$b/items/$it.rules"); do
                    ipt_tables "$b/pre/$it.rules" | grep -qx "$t" || echo "$t" >> "$b/pre/$it.drop"
                done
                if [[ "$CUR_BACKEND" == legacy && -s "$b/pre/$it.drop" ]]; then
                    while IFS= read -r t; do printf '*%s\nCOMMIT\n' "$t"; done < "$b/pre/$it.drop" > "$b/pre/$it.empty"
                    LEGACY_EMPTIED+="${LEGACY_EMPTIED:+, }$it: $(paste -sd' ' "$b/pre/$it.drop")"
                fi ;;
            nftables)
                { echo "flush ruleset"; cat "$BACKUP_DIR/$HOST/nftables.ruleset"; } > "$b/items/nftables.batch"
                { echo "flush ruleset"; cat "$pre/nftables.ruleset"; } > "$b/pre/nftables.batch" ;;
            *)
                cp -- "$WORK_DIR/add-$it" "$b/items/$it.add" ;;
        esac
    done
    # shellcheck disable=SC2094  # SUMS tidak ikut dibaca (! -name SUMS)
    ( cd "$b" && find . -type f ! -name SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SUMS )
    ( umask 077; tar -czf "$WORK_DIR/bundle.tgz" -C "$b" . )
}

upload_bundle() {
    local out rc=0 cmd
    cmd="$(upload_cmd "$LOG_RUN_ID")" || return 1
    out="$(ssh_node_stdin "$TGT" "$SSH_T" "$cmd" < "$WORK_DIR/bundle.tgz" 2> "$WORK_DIR/upload.err")" || rc=$?
    if [[ "$out" != *__OSOPS_UPLOADED__* ]]; then
        UPLOAD_MSG="$(grep -m1 '^osops:' <<< "$out" || true)"
        UPLOAD_MSG="${UPLOAD_MSG#osops: }"
        [[ -n "$UPLOAD_MSG" ]] || UPLOAD_MSG="upload failed (rc=$rc)"
        return 1
    fi
    return 0
}

# agent FASE [ARG] — output agent di AGENT_OUT; koneksi baru jika FRESH=1
agent() {
    local rc=0 cmd
    cmd="$(agent_cmd "$@")"
    if (( ${FRESH:-0} )); then
        AGENT_OUT="$(fresh_ssh "$TGT" $(( AGENT_T + 20 )) "$cmd" 2> "$WORK_DIR/agent.err")" || rc=$?
    else
        AGENT_OUT="$(ssh_node "$TGT" $(( AGENT_T + 20 )) "$cmd" 2> "$WORK_DIR/agent.err")" || rc=$?
    fi
    return "$rc"
}

# ============================================================
# Status node (restore sebelumnya)
# ============================================================

# node_status RUN => NS_STATE (PENDING_ROLLBACK | ROLLBACK_RUNNING | CONFIRMED |
# ROLLED_BACK | ROLLBACK_FAILED | NOT_APPLIED | APPLIED_NO_TIMER | UNREACHABLE)
node_status() {
    local run="$1" out rc=0 cmd
    cmd="$(status_cmd "$run")" || { NS_STATE=INVALID; return 0; }
    out="$(fresh_ssh "$TGT" "$SSH_T" "$cmd" 2>/dev/null)" || rc=$?
    STATUS_OUT="$out"
    if [[ "$out" != *__OSOPS_RESTORE_STATUS__* ]]; then NS_STATE=UNREACHABLE; return 0; fi
    S_TIMER="$(kv "$out" timer)" S_SERVICE="$(kv "$out" service)" S_DIR="$(kv "$out" dir)"
    S_APPLIED="$(kv "$out" applied)" S_DUE="$(kv "$out" due)" S_NOW="$(kv "$out" now)"
    S_RB="$(sed -n 's/^rb:result=//p' <<< "$out" | head -n 1)"
    if [[ "$S_TIMER" == active ]]; then NS_STATE=PENDING_ROLLBACK
    elif [[ "$S_SERVICE" =~ ^(active|activating|deactivating)$ ]]; then NS_STATE=ROLLBACK_RUNNING
    elif [[ "$S_DIR" == 0 ]]; then NS_STATE=CONFIRMED
    elif [[ "$S_RB" == OK ]]; then NS_STATE=ROLLED_BACK
    elif [[ "$S_RB" == FAILED ]]; then NS_STATE=ROLLBACK_FAILED
    elif [[ -z "$S_APPLIED" ]]; then NS_STATE=NOT_APPLIED
    else NS_STATE=APPLIED_NO_TIMER
    fi
}

print_critical() {
    echo "${C_RED}${C_BOLD}❗ KRITIS: rollback di $NAME GAGAL atau tidak terverifikasi.${C_RESET}"
    echo "${C_RED}   $(sed -n 's/^rb:reason=//p' <<< "${STATUS_OUT:-}" | head -n 1)${C_RESET}"
    echo "   Pulihkan manual dari snapshot pra-restore di undercloud: ${1:-<backup-base>/<run_id>-pre-restore}/$NAME/"
    echo "   (contoh: sudo iptables-restore < iptables-v4.rules; nft -f dengan 'flush ruleset' + nftables.ruleset),"
    echo "   lalu periksa dengan rhosp/backup-network-state.sh dan --status."
}

show_status() {
    local run="$1" pre="$2"
    node_status "$run"
    echo "  Run restore      : $run"
    echo "  Status node      : $NS_STATE"
    [[ "$NS_STATE" == UNREACHABLE || "$NS_STATE" == INVALID ]] || {
        echo "  Timer rollback   : ${S_TIMER:--}$( [[ -n "${S_DUE:-}" && "$S_TIMER" == active ]] && printf ' (sisa %ss)' $(( S_DUE - S_NOW )))"
        echo "  Service rollback : ${S_SERVICE:--}"
        echo "  Item diterapkan  : ${S_APPLIED:--}"
        echo "  rollback.result  : ${S_RB:--}"
    }
    case "$NS_STATE" in
        PENDING_ROLLBACK) echo "  ⏳ Rollback terjadwal dan akan berjalan otomatis. Jangan restore lagi sebelum selesai." ;;
        ROLLBACK_RUNNING) echo "  ⏳ Rollback sedang berjalan." ;;
        CONFIRMED)        echo "  ✅ Tidak ada direktori restore di node (sudah dikonfirmasi atau dibersihkan)." ;;
        ROLLED_BACK)
            FRESH=1 agent verify-rollback || true
            VR_OUT="$AGENT_OUT"
            if grep -qP '^vr\t[^\t]+\tMISMATCH' <<< "$VR_OUT"; then
                echo "  ${C_YELLOW}⚠️  Rollback selesai, tetapi kondisi sekarang berbeda dari snapshot pra-restore:${C_RESET}"
                awk -F'\t' '$1 == "vr" { printf "     %s: %s %s\n", $2, $3, $4 }' <<< "$VR_OUT"
            else
                echo "  ✅ Rollback selesai dan terverifikasi (kondisi = snapshot pra-restore)."
            fi ;;
        ROLLBACK_FAILED)  print_critical "$pre" ;;
        NOT_APPLIED)      echo "  ℹ️  Belum ada perubahan yang diterapkan di node (direktori restore masih ada)." ;;
        APPLIED_NO_TIMER) echo "  ${C_YELLOW}⚠️  Item diterapkan, tidak ada timer dan tidak ada hasil rollback (mis. node reboot: konfigurasi director dimuat ulang). Periksa node secara manual.${C_RESET}" ;;
        UNREACHABLE)      echo "  ${C_RED}❌ Node tidak bisa dihubungi; status tidak diketahui.${C_RESET}" ;;
    esac
    log_event STATUS "host=$NAME" "run=$run" "state=$NS_STATE" "timer=${S_TIMER:--}" "rollback=${S_RB:--}"
}

# ============================================================
# Apply
# ============================================================

confirm_typed() {
    local a
    echo
    echo "${C_RED}${C_BOLD}⚠️  RESTORE akan mengubah firewall/route RUNTIME di $NAME.${C_RESET}"
    echo "   Reboot atau run director berikutnya mengembalikan konfigurasi dari director."
    echo "   Auto-rollback dalam ${RB_TIMEOUT}s kecuali dikonfirmasi setelah pengecekan."
    ask a "Ketik hostname node ($NAME) untuk melanjutkan: "
    if [[ "$(trim "$a")" != "$NAME" ]]; then
        log_event DECISION confirm=hostname result=declined
        return 1
    fi
    ask a "Ketik RESTORE untuk menerapkan: "
    if [[ "$(trim "$a")" != RESTORE ]]; then
        log_event DECISION confirm=restore result=declined
        return 1
    fi
    log_event DECISION confirm=restore result=accepted
    return 0
}

take_pre_snapshot() {
    local base stage items="$WORK_DIR/pre-items.tsv"
    base="$(backup_base)"
    PRE_DIR="$base/$LOG_RUN_ID-pre-restore"
    ( umask 077; mkdir -p -- "$base" ) 2>/dev/null || return 1
    mkdir -m 700 -- "$PRE_DIR" 2>/dev/null || { PRE_MSG="exists: $PRE_DIR"; return 1; }
    if ! collect_state "$WORK_DIR/prec" "$PRE_DIR/$NAME"; then PRE_MSG="$COLLECT_MSG"; return 1; fi
    stage="$COLLECT_STAGE"
    : > "$items"
    ns_items "$NAME" "$stage" "$PRE_DIR/$NAME" "$items"
    read_current "$stage"
    ns_write_meta "$PRE_DIR/$NAME/meta.json" "$stage" "$NAME" "${N_ROLE[$TGT]}" "$LOG_RUN_ID" "$CUR_BACKEND" \
        "$(rhosp_node_addr "$TGT")" "$BAK_COUNTERS" 0 0 || { PRE_MSG="meta.json"; return 1; }
    rm -rf -- "$stage"
    ns_write_manifest "$PRE_DIR" "# Pre-restore snapshot run=$LOG_RUN_ID host=$NAME created=$(date -Iseconds) (restore-network-state)" < "$items" || { PRE_MSG="manifest"; return 1; }
    ns_write_sums "$PRE_DIR" || { PRE_MSG="SHA256SUMS"; return 1; }
    ns_verify_run "$PRE_DIR" "$NAME" || { PRE_MSG="$NS_VERIFY_MSG"; return 1; }
    log_event PRE_SNAPSHOT "dir=$PRE_DIR" "items_ok=$NS_N_OK" "items_failed=$NS_N_FAIL" result=OK
    return 0
}

# Pengecekan setelah apply => CHECK_FAIL (kosong = lulus), REMAIN (detik)
post_checks() {
    local out rc=0 p line mism=""
    CHECK_FAIL="" REMAIN=0
    # 1. Koneksi SSH baru + 3. jumlah aturan/route
    FRESH=1 agent counts || rc=$?
    out="$AGENT_OUT"
    if [[ "$(awk -F'\t' '$1 == "host" { print $2 }' <<< "$out")" != "$CUR_HOSTNAME" ]]; then
        CHECK_FAIL="new SSH connection failed (rc=$rc)"
        log_event CHECK check=ssh result=FAILED "rc=$rc"
        return 0
    fi
    echo "  ✅ Koneksi SSH baru ke $NAME berhasil"
    log_event CHECK check=ssh result=OK
    while IFS=$'\t' read -r _ it tb e a; do
        if [[ "$e" != "$a" ]]; then
            mism+="${mism:+; }$it ${tb}: expected $e, now $a"
        fi
    done < <(awk -F'\t' '$1 == "count"' <<< "$out")
    COUNT_MISMATCH="$mism"
    # 2. Pacemaker
    if (( CLUSTER )); then
        for (( p = 1; p <= PCS_POLLS; p++ )); do
            if ! pcs_nodes; then
                CHECK_FAIL="pcs status nodes failed"; break
            fi
            if [[ "$PCS_ONLINE" != "$ONLINE_BEFORE" || -n "$PCS_BAD" ]] || ! node_pcs_name > /dev/null; then
                CHECK_FAIL="cluster changed: ${PCS_BAD:-online set differs}"; break
            fi
            if (( p < PCS_POLLS )); then sleep "$PCS_INTERVAL"; fi
        done
        if [[ -z "$CHECK_FAIL" ]]; then
            echo "  ✅ Pacemaker: $NAME tetap Online, node Online sama seperti sebelum apply ($PCS_POLLS x cek)"
            log_event CHECK check=pacemaker result=OK "polls=$PCS_POLLS"
        else
            log_event CHECK check=pacemaker result=FAILED "reason=$CHECK_FAIL"
            return 0
        fi
    fi
    if [[ -n "$mism" ]]; then
        CHECK_FAIL="rule/route count mismatch"
        log_event CHECK check=counts result=FAILED "detail=$mism"
        return 0
    fi
    echo "  ✅ Jumlah aturan/route sesuai yang diharapkan"
    log_event CHECK check=counts result=OK
    # Sisa waktu timer (jam node)
    FRESH=1 agent counts || true
    local due now
    due="$(awk -F'\t' '$1 == "due" { print $2 }' <<< "$AGENT_OUT")"
    now="$(awk -F'\t' '$1 == "now" { print $2 }' <<< "$AGENT_OUT")"
    if is_uint "${due:-x}" && is_uint "${now:-x}"; then REMAIN=$(( due - now )); fi
    return 0
}

# Tampilkan dan catat rollback.result per item (status + alasan, tanpa isi aturan)
report_rb_items() {
    local it st det
    while IFS=$'\t' read -r it st det; do
        [[ -n "$it" && "$it" != result=* && "$it" != reason=* ]] || continue
        printf '     rollback %s: %s %s\n' "$it" "$st" "$det"
        log_event ROLLBACK_ITEM "item=$it" "status=$st" "detail=${det:--}"
    done < <(sed -n 's/^rb://p' <<< "${STATUS_OUT:-}")
}

# Tunggu rollback (timer atau rollback-now) lalu verifikasi lewat koneksi baru
wait_rollback() {
    local deadline now
    deadline=$(( $(date +%s) + RB_TIMEOUT + 180 ))
    echo "⏳ Menunggu rollback di $NAME..."
    while :; do
        node_status "$LOG_RUN_ID"
        case "$NS_STATE" in
            ROLLED_BACK|ROLLBACK_FAILED|CONFIRMED|APPLIED_NO_TIMER|NOT_APPLIED) break ;;
        esac
        now="$(date +%s)"
        (( now >= deadline )) && break
        sleep 5
    done
    case "$NS_STATE" in
        ROLLED_BACK|ROLLBACK_FAILED) report_rb_items ;;
    esac
    case "$NS_STATE" in
        ROLLED_BACK)
            FRESH=1 agent verify-rollback || true
            VR_OUT="$AGENT_OUT"
            awk -F'\t' '$1 == "vr" { printf "     verifikasi %s: %s %s\n", $2, $3, $4 }' <<< "$VR_OUT"
            if grep -qP '^vr\t[^\t]+\tOK' <<< "$VR_OUT" && ! grep -qP '^vr\t[^\t]+\tMISMATCH' <<< "$VR_OUT"; then
                echo "  ✅ Rollback selesai dan terverifikasi lewat koneksi baru"
                log_event ROLLBACK result=OK verified=yes
                FRESH=1 agent cleanup || true
                state_remove
                return 0
            fi
            CRITICAL="rollback verification mismatch"
            echo "  ${C_RED}❌ Rollback selesai tetapi verifikasi berbeda:${C_RESET}"
            awk -F'\t' '$1 == "vr" { printf "     %s: %s %s\n", $2, $3, $4 }' <<< "$VR_OUT"
            log_event ROLLBACK result=FAILED verified=mismatch ;;
        ROLLBACK_FAILED)
            CRITICAL="rollback failed: $(sed -n 's/^rb:reason=//p' <<< "$STATUS_OUT" | head -n 1)"
            print_critical "$PRE_DIR"
            log_event ROLLBACK result=FAILED "reason=$CRITICAL" ;;
        *)
            CRITICAL="rollback status unknown ($NS_STATE)"
            echo "  ${C_RED}❌ Status rollback tidak bisa dipastikan ($NS_STATE). Cek: $0 --status --host $NAME${C_RESET}"
            log_event ROLLBACK result=UNKNOWN "state=$NS_STATE" ;;
    esac
    return 1
}

finish_rolled_back() {
    local reason="$1" it
    for it in "${APPLY_ITEMS[@]}"; do
        if [[ -z "$CRITICAL" ]]; then
            set_item "$it" ROLLED_BACK "$reason"
        else
            set_item "$it" ROLLBACK_FAILED "$reason; $CRITICAL"
        fi
        log_result "resource=$NAME" "item=$it" action=restore result=FAILED "reason=$reason" "rollback=${CRITICAL:-OK}"
    done
}

do_apply() {
    local it a left t
    APPLY_ITEMS=()
    for it in "${ITEMS[@]}"; do
        [[ -z "${ST[$it]:-}" ]] || continue
        if (( ${ADDN[$it]:-0} + ${REMN[$it]:-0} == 0 )); then
            set_item "$it" NOT_APPLIED "no difference"
            continue
        fi
        APPLY_ITEMS+=("$it")
    done
    if (( ${#APPLY_ITEMS[@]} == 0 )); then
        echo "Tidak ada perubahan untuk diterapkan."
        return 0
    fi

    if [[ "$PRE_SUDO" != ok ]]; then die "sudo -n gagal di $NAME: --apply ditolak."; fi
    if [[ -n "$PRE_MISSING" ]]; then
        log_error -q "apply rejected: missing=$PRE_MISSING"
        die "Tool tidak ada di $NAME ($PRE_MISSING): --apply ditolak (tanpa systemd-run tidak ada auto-rollback)."
    fi
    cluster_precheck
    acquire_lock
    if [[ -z "${TMUX:-}" && -z "${STY:-}" ]]; then
        warn "Tidak berjalan di dalam tmux/screen. Jika koneksi ke undercloud putus setelah apply, rollback tetap berjalan otomatis di node."
    fi

    echo
    echo "${C_BOLD}📋 Rencana --apply${C_RESET}"
    echo "  Region     : ${OS_REGION_NAME:--}    Stack: $(stack_name)"
    echo "  Node       : $NAME (${N_ROLE[$TGT]}, $(rhosp_node_addr "$TGT"))"
    echo "  Item       : $(IFS=,; printf '%s' "${APPLY_ITEMS[*]}")"
    for it in "${APPLY_ITEMS[@]}"; do printf '    %-12s +%s / -%s\n' "$it" "${ADDN[$it]:-0}" "${REMN[$it]:-0}"; done
    echo "  Backup     : $BACKUP_DIR (umur $(human_age $(( $(date +%s) - BAK_EPOCH ))))"
    echo "  Rollback   : otomatis setelah ${RB_TIMEOUT}s (systemd-run di node) kecuali dikonfirmasi"

    if ! confirm_typed; then
        echo "❌ Dibatalkan."
        for it in "${APPLY_ITEMS[@]}"; do
            set_item "$it" NOT_APPLIED "declined at confirmation"
            log_result "resource=$NAME" "item=$it" action=restore result=DECLINED
        done
        return 0
    fi

    # Snapshot pra-restore (undercloud + salinan di node)
    echo "📸 Snapshot pra-restore..."
    if ! take_pre_snapshot; then
        log_error -q "pre-restore snapshot failed: ${PRE_MSG:-}"
        die "Snapshot pra-restore gagal (${PRE_MSG:-}); restore dibatalkan."
    fi
    echo "   $PRE_DIR (600/700)"
    # Kondisi bisa berubah sejak diff: hitung ulang terhadap snapshot terbaru
    local -A oadd=() orem=()
    for it in "${APPLY_ITEMS[@]}"; do oadd[$it]="${ADDN[$it]:-0}" orem[$it]="${REMN[$it]:-0}"; done
    check_identity
    compute_diff "$PRE_DIR/$NAME"
    for it in "${APPLY_ITEMS[@]}"; do
        if [[ -n "${ST[$it]:-}" || "${oadd[$it]}" != "${ADDN[$it]:-0}" || "${orem[$it]}" != "${REMN[$it]:-0}" ]]; then
            log_error -q "state changed since diff: item=$it"
            die "Kondisi $it di node berubah sejak diff ditampilkan. Jalankan ulang (dry-run) untuk melihat diff terbaru."
        fi
    done

    build_bundle
    state_write uploading || die "State file tidak bisa ditulis ($STATE_FILE); restore dibatalkan."
    echo "📤 Upload ke $NAME:$NODE_DIR ..."
    if ! upload_bundle; then
        log_error -q "upload failed: $UPLOAD_MSG"
        state_write upload-failed || true
        die "Upload gagal: $UPLOAD_MSG. Cek: --status --host $NAME"
    fi
    PHASE=uploaded
    log_event UPLOAD "node_dir=$NODE_DIR" result=OK

    echo "🔎 Verifikasi di node (iptables-restore --test / nft -c, termasuk salinan pra-restore)..."
    if ! agent verify; then
        echo "${C_RED}❌ Verifikasi gagal:${C_RESET}"
        awk -F'\t' '$1 == "verify" && $3 != "OK" { printf "   %s: %s\n", $2, $4 }' <<< "$AGENT_OUT"
        log_error -q "verify failed: $(awk -F'\t' '$1 == "verify" && $3 != "OK" { printf "%s=%s; ", $2, $4 }' <<< "$AGENT_OUT")"
        agent cleanup > /dev/null 2>&1 || true
        state_remove
        PHASE=none
        for it in "${APPLY_ITEMS[@]}"; do
            set_item "$it" NOT_APPLIED "verification on node failed"
            log_result "resource=$NAME" "item=$it" action=restore result=FAILED reason=verify-failed
        done
        return 0
    fi
    log_event VERIFY result=OK

    if ! agent schedule "$RB_TIMEOUT"; then
        log_error -q "schedule failed: $(tr '\n' ' ' <<< "$AGENT_OUT" | cut -c1-200)"
        agent cleanup > /dev/null 2>&1 || true
        state_remove
        PHASE=none
        die "Timer rollback tidak bisa dijadwalkan: --apply dibatalkan tanpa perubahan."
    fi
    DUE="$(awk -F'\t' '$1 == "schedule" && $2 == "OK" { print $3 }' <<< "$AGENT_OUT")"
    PHASE=scheduled
    state_write scheduled || warn "State file tidak bisa diperbarui."
    log_event SCHEDULE "unit=$UNIT" "timeout=$RB_TIMEOUT" "due_node=$DUE" result=OK
    echo "⏲️  Rollback dijadwalkan: $UNIT (${RB_TIMEOUT}s)"

    echo "🚀 Apply..."
    PHASE=applied
    state_write applied || true
    a=0
    agent apply || a=$?
    log_event APPLY "rc=$a" "result=$(awk -F'\t' '$1 == "apply" { printf "%s=%s ", $2, $3 }' <<< "$AGENT_OUT")"
    awk -F'\t' '$1 == "apply" { printf "   %s: %s %s\n", $2, $3, $4 }' <<< "$AGENT_OUT"
    if (( a != 0 )) || ! grep -qP '^apply\t' <<< "$AGENT_OUT" || grep -qP '^apply\t[^\t]+\tFAILED' <<< "$AGENT_OUT"; then
        CHECK_FAIL="apply failed or connection lost during apply"
    else
        echo "🔍 Pengecekan setelah apply..."
        post_checks
    fi

    if [[ -n "${CHECK_FAIL:-}" ]]; then
        echo "${C_RED}❌ Pengecekan gagal: $CHECK_FAIL${C_RESET}"
        if [[ -n "${COUNT_MISMATCH:-}" ]]; then
            echo "   Selisih jumlah (jumlah saja): $COUNT_MISMATCH"
            echo "   Jika aturan berubah karena agen neutron/OVN di tengah jalan, rollback dipicu oleh agen, bukan oleh restore yang rusak."
        fi
        log_event DECISION rollback=early "reason=$CHECK_FAIL"
        echo "↩️  Memicu rollback lebih awal..."
        FRESH=1 agent rollback-now || true
        wait_rollback || true
        finish_rolled_back "$CHECK_FAIL"
        PHASE="done"
        return 0
    fi

    if (( REMAIN < CONFIRM_MIN_LEFT )); then
        echo "${C_YELLOW}⏳ Waktu konfirmasi tidak cukup (sisa ${REMAIN}s < ${CONFIRM_MIN_LEFT}s): rollback dibiarkan berjalan.${C_RESET}"
        log_event DECISION confirm=skipped "remaining=$REMAIN"
        wait_rollback || true
        finish_rolled_back "confirmation time insufficient (${REMAIN}s)"
        PHASE="done"
        return 0
    fi

    left=$(( REMAIN - CONFIRM_MARGIN ))
    t="$(date +%s)"
    local answer="" confirmed=0
    echo
    echo "${C_BOLD}Semua pengecekan lulus. Rollback otomatis dalam ${REMAIN}s.${C_RESET}"
    while :; do
        local rem=$(( left - ( $(date +%s) - t ) ))
        if ! ask_timeout answer "Ketik hostname ($NAME) dalam ${rem}s untuk MEMPERTAHANKAN perubahan: " "$rem"; then
            break
        fi
        if [[ "$(trim "$answer")" == "$NAME" ]]; then confirmed=1; break; fi
        echo "${C_RED}❌ Tidak cocok.${C_RESET}"
    done
    if (( ! confirmed )); then
        echo "${C_YELLOW}⏳ Tidak ada konfirmasi: rollback dibiarkan berjalan.${C_RESET}"
        log_event DECISION confirm=timeout
        wait_rollback || true
        finish_rolled_back "not confirmed in time"
        PHASE="done"
        return 0
    fi

    log_event DECISION confirm=keep
    agent confirm || true
    if grep -qP '^confirm\tOK' <<< "$AGENT_OUT"; then
        echo "${C_GREEN}✅ Dikonfirmasi: timer rollback dibatalkan, salinan di node dihapus.${C_RESET}"
        state_remove
        for it in "${APPLY_ITEMS[@]}"; do
            set_item "$it" APPLIED "confirmed"
            log_result "resource=$NAME" "item=$it" action=restore result=SUCCESS "add=${ADDN[$it]:-0}" "remove=${REMN[$it]:-0}"
        done
    elif grep -qP '^confirm\tROLLED_BACK' <<< "$AGENT_OUT"; then
        echo "${C_YELLOW}⚠️  Rollback sudah berjalan sebelum konfirmasi diterima.${C_RESET}"
        wait_rollback || true
        finish_rolled_back "rollback started before confirmation"
    else
        echo "${C_RED}❌ Konfirmasi gagal; rollback akan berjalan.${C_RESET}"
        wait_rollback || true
        finish_rolled_back "confirm failed"
    fi
    PHASE="done"
    return 0
}

acquire_lock() {
    [[ -n "$LOCK_FILE" ]] || die "Logging nonaktif: lock dan state file tidak bisa dibuat."
    command -v flock >/dev/null 2>&1 || die "flock (util-linux) tidak ditemukan."
    exec 8>>"$LOCK_FILE" || die "Tidak bisa membuka lock file: $LOCK_FILE"
    flock -n 8 || die "Restore lain untuk $NAME sedang berjalan (lock: $LOCK_FILE)."
    log_event LOCK "file=$LOCK_FILE"
}

# ============================================================
# Ringkasan
# ============================================================

summary() {
    local it st color
    echo
    echo "${C_BOLD}========================================${C_RESET}"
    echo "${C_BOLD}📊 Ringkasan ($NAME$( (( APPLY )) || echo ', DRY-RUN'))${C_RESET}"
    echo "${C_BOLD}========================================${C_RESET}"
    for it in "${ITEMS[@]}"; do
        st="${ST[$it]:-NOT_APPLIED}"
        case "$st" in
            APPLIED) color="$C_GREEN" ;;
            ROLLED_BACK|NOT_APPLIED) color="$C_YELLOW" ;;
            *) color="$C_RED" ;;
        esac
        printf '  %-12s %s%-15s%s %s\n' "$it" "$color" "$st" "$C_RESET" "${RS[$it]:-$( (( APPLY )) || echo dry-run)}"
    done
    if [[ -n "$LEGACY_EMPTIED" ]]; then
        echo "  Backend legacy: tabel yang dibuat oleh restore hanya DIKOSONGKAN saat rollback (tidak bisa dihapus): $LEGACY_EMPTIED"
    fi
    if [[ -s "$MANUAL_FILE" ]]; then
        echo
        echo "${C_YELLOW}Perlu tindakan manual (tidak diubah oleh script):${C_RESET}"
        awk -F'\t' '{ printf "  %s [%s] %s\n", $1, $2, $3 }' "$MANUAL_FILE"
    fi
    if [[ -n "$CRITICAL" ]]; then
        echo
        echo "${C_RED}${C_BOLD}❗ KRITIS: $CRITICAL${C_RESET}"
        echo "   Snapshot pra-restore: ${PRE_DIR:--}/$NAME/   Cek: $0 --status --host $NAME"
    fi
    echo
    echo "Catatan: hanya runtime yang diubah; reboot atau run director berikutnya mengembalikan konfigurasi director."
    [[ -n "$PRE_DIR" ]] && echo "Snapshot pra-restore: $PRE_DIR"
    [[ -n "$LOG_FILE" ]] && echo "Log: $LOG_FILE"
    log_info "SUMMARY host=$NAME apply=$APPLY items=$(for it in "${ITEMS[@]}"; do printf '%s=%s,' "$it" "${ST[$it]:-NOT_APPLIED}"; done) manual=$(wc -l < "$MANUAL_FILE" 2>/dev/null || echo 0) critical=${CRITICAL:--}"
}

# ============================================================
# Hook library — TIDAK pernah membatalkan timer rollback
# ============================================================

# shellcheck disable=SC2329  # dipanggil lewat LOG_INTERRUPT_HOOK
on_interrupt() {
    local it
    echo
    if [[ "$PHASE" == scheduled || "$PHASE" == applied ]]; then
        warn "Dihentikan (${1:-INT}) setelah timer rollback dijadwalkan. Timer TIDAK dibatalkan: rollback berjalan otomatis di $NAME."
        echo "   Cek status: $0 --status --host $NAME"
        for it in "${APPLY_ITEMS[@]}"; do
            log_result "resource=$NAME" "item=$it" action=restore result=ABORTED "msg=interrupted (${1:-INT}); rollback timer left running"
        done
    else
        warn "Dihentikan (${1:-INT})."
    fi
}

# shellcheck disable=SC2329  # dipanggil lewat LOG_EXIT_HOOK
on_exit() {
    set +o errexit
    if [[ "$PHASE" == scheduled || "$PHASE" == applied ]]; then
        echo "⏲️  Timer rollback $UNIT tetap aktif di $NAME (tidak dibatalkan)."
    fi
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
        --backup-dir)       need_arg "$1" "${2:-}"; BACKUP_DIR="$2"; shift 2 ;;
        --host)             need_arg "$1" "${2:-}"; HOST="$2"; shift 2 ;;
        --items)            need_arg "$1" "${2:-}"; ITEMS_ARG="$2"; ITEMS_SET=1; shift 2 ;;
        --apply)            APPLY=1; shift ;;
        --status)           MODE=status; shift ;;
        --clear-state)      MODE=clear; shift ;;
        --rollback-timeout) need_arg "$1" "${2:-}"; RB_TIMEOUT="$2"; shift 2 ;;
        --save-diff)        need_arg "$1" "${2:-}"; SAVE_DIFF="$2"; shift 2 ;;
        --inventory)        need_arg "$1" "${2:-}"; INVENTORY="$2"; shift 2 ;;
        --timeout)          need_arg "$1" "${2:-}"; TIMEOUT_S="$2"; shift 2 ;;
        --all|--nodes|--node|--role|--local)
            die "Restore hanya untuk satu node per run (--host). $1 tidak didukung." ;;
        *)
            echo "❌ Parameter tidak dikenal: $1"
            echo
            usage
            exit 1
            ;;
    esac
done

if ! is_uint "$RB_TIMEOUT" || (( RB_TIMEOUT < RB_MIN || RB_TIMEOUT > RB_MAX )); then
    die "--rollback-timeout harus bilangan bulat $RB_MIN-$RB_MAX detik."
fi
if ! is_uint "$TIMEOUT_S" || (( TIMEOUT_S < 10 || TIMEOUT_S > 3600 )); then
    die "--timeout harus bilangan bulat (detik) 10-3600."
fi
if [[ ! "${LOG_RUN_ID:-}" =~ $NS_RUN_ID_RE ]]; then
    die "run_id tidak valid untuk path/perintah remote: '${LOG_RUN_ID:-}'."
fi
if [[ "$MODE" != restore ]]; then
    [[ -n "$HOST" ]] || die "--status/--clear-state membutuhkan --host."
    (( APPLY )) && die "--apply tidak bisa digabung dengan --status/--clear-state."
fi
if (( APPLY )) && ! has_tty; then
    die "--apply membutuhkan terminal (konfirmasi berlapis)."
fi
if [[ -n "$SAVE_DIFF" && -e "$SAVE_DIFF" ]]; then
    die "--save-diff: file sudah ada (tidak ditimpa): $SAVE_DIFF"
fi

# ============================================================
# Main
# ============================================================

WORK_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/restore-network-state.XXXXXX")" || die "Gagal membuat direktori sementara."
RHOSP_WORK_DIR="$WORK_DIR"
DIFF_FILE="$WORK_DIR/diff.txt"
MANUAL_FILE="$WORK_DIR/manual.tsv"
: > "$MANUAL_FILE"
LOG_EXIT_HOOK=on_exit
LOG_INTERRUPT_HOOK=on_interrupt

echo "========================================"
case "$MODE" in
    status) _title=" — status" ;;
    clear)  _title=" — clear-state" ;;
    *)      _title="$( (( APPLY )) && echo ' (--apply)' || echo ' (DRY-RUN)')" ;;
esac
echo "♻️  Restore Network State$_title"
echo "========================================"

if (( APPLY )) || [[ "$MODE" == clear ]]; then
    rhosp_check_env confirm
else
    rhosp_check_env warn
fi
for _tool in "${SSH_CMD[0]}" timeout tar gzip sha256sum diff jq; do
    command -v "$_tool" >/dev/null 2>&1 || die "$_tool tidak ditemukan."
done
log_event INPUT "mode=$MODE" "apply=$APPLY" "backup_dir=${BACKUP_DIR:--}" "host=${HOST:--}" \
    "items=${ITEMS_ARG:--}" "rollback_timeout=$RB_TIMEOUT" "save_diff=${SAVE_DIFF:--}"

rhosp_find_inventory
rhosp_load_nodes

# --status / --clear-state
if [[ "$MODE" != restore ]]; then
    resolve_node
    state_init || die "Logging nonaktif: state file tidak bisa dibaca."
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "Tidak ada restore yang belum tuntas untuk $NAME (state file: $STATE_FILE)."
        log_event STATUS "host=$NAME" state=none
        exit 0
    fi
    _run="$(state_get run_id)"
    [[ "$_run" =~ $NS_RUN_ID_RE ]] || die "State file tidak valid (run_id): $STATE_FILE"
    check_host_keys "node tujuan" "$TGT"
    echo
    echo "State file: $STATE_FILE"
    sed -n '/^[a-z_]*=/p' "$STATE_FILE" | sed 's/^/  /'
    echo
    AGENT_RUN="$_run"            # agent/verify-rollback memakai run_id restore yang dicek
    show_status "$_run" "$(state_get pre_restore_dir)"
    if [[ "$MODE" == status ]]; then
        exit 0
    fi
    # --clear-state
    case "$NS_STATE" in
        PENDING_ROLLBACK|ROLLBACK_RUNNING|UNREACHABLE|INVALID)
            die "--clear-state ditolak: status $NS_STATE." ;;
        ROLLBACK_FAILED)
            die "--clear-state ditolak: rollback GAGAL (KRITIS). Pulihkan manual dulu." ;;
        ROLLED_BACK)
            if grep -qP '^vr\t[^\t]+\tMISMATCH' <<< "${VR_OUT:-}" || ! grep -qP '^vr\t' <<< "${VR_OUT:-}"; then
                die "--clear-state ditolak: rollback.result belum terverifikasi."
            fi ;;
    esac
    [[ "$NS_STATE" == APPLIED_NO_TIMER ]] && warn "Item pernah diterapkan tanpa hasil rollback; periksa node secara manual sebelum membersihkan."
    acquire_lock
    has_tty || die "--clear-state membutuhkan terminal."
    _a=""
    ask _a "Ketik hostname node ($NAME) untuk menghapus state dan direktori restore di node: "
    if [[ "$(trim "$_a")" != "$NAME" ]]; then
        log_event DECISION clear=declined
        echo "❌ Dibatalkan."
        exit 0
    fi
    if [[ "$NS_STATE" != CONFIRMED ]]; then
        _out="$(fresh_ssh "$TGT" "$SSH_T" "$(clear_cmd "$_run")" 2>/dev/null)" || true
        [[ "$_out" == *__OSOPS_CLEARED__* ]] || die "Direktori restore di node tidak bisa dihapus: $(head -n 1 <<< "$_out")"
    fi
    state_remove
    log_result "resource=$NAME" action=clear-state result=SUCCESS "run=$_run" "state=$NS_STATE"
    echo "✅ State restore $NAME dibersihkan."
    exit 0
fi

choose_backup
choose_host
validate_backup
choose_items
validate_items
resolve_node
state_init || true
if [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]]; then
    echo
    warn "Restore sebelumnya untuk $NAME belum tuntas (state file: $STATE_FILE)."
    _run="$(state_get run_id)"
    if [[ "$_run" =~ $NS_RUN_ID_RE ]]; then
        check_host_keys "node tujuan" "$TGT"
        AGENT_RUN="$_run"
        show_status "$_run" "$(state_get pre_restore_dir)"
        AGENT_RUN=""
    fi
    if (( APPLY )); then
        die "Restore baru ditolak sampai statusnya jelas. Gunakan --status / --clear-state --host $NAME."
    fi
    warn "Dry-run tetap dijalankan (tidak ada perubahan)."
fi

echo "🎯 Node tujuan     : $NAME (${N_ROLE[$TGT]})    Region: ${OS_REGION_NAME:--}    Stack: $(stack_name)"
precheck_node
echo "📥 Mengambil kondisi saat ini dari $NAME (read-only)..."
collect_state "$WORK_DIR/cur" "$WORK_DIR/current/$NAME" || die "Kondisi saat ini tidak bisa diambil: $COLLECT_MSG"
read_current "$COLLECT_STAGE"
rm -rf -- "$COLLECT_STAGE"
check_identity
compute_diff "$WORK_DIR/current/$NAME"
show_diff

if (( ! APPLY )); then
    for _it in "${ITEMS[@]}"; do
        if [[ -z "${ST[$_it]:-}" ]]; then
            set_item "$_it" NOT_APPLIED "dry-run (+${ADDN[$_it]:-0} / -${REMN[$_it]:-0})"
            log_info "PLAN dry_run=true host=$NAME item=$_it add=${ADDN[$_it]:-0} remove=${REMN[$_it]:-0}"
        fi
    done
    if [[ "$PRE_SUDO" != ok || -n "$PRE_MISSING" ]]; then
        warn "--apply akan ditolak di node ini: sudo=${PRE_SUDO:--} missing=${PRE_MISSING:--}"
    fi
    echo
    echo "${C_CYAN}DRY-RUN: tidak ada perubahan. Tambahkan --apply untuk menerapkan (dengan auto-rollback).${C_RESET}"
    summary
    exit 0
fi

do_apply
summary
if [[ -n "$CRITICAL" ]]; then exit 2; fi
for _it in "${ITEMS[@]}"; do
    case "${ST[$_it]:-}" in ROLLED_BACK|ROLLBACK_FAILED) exit 1 ;; esac
done
exit 0
