#!/bin/bash
# ============================================================
# Tes rhosp/restore-network-state.sh dengan node palsu berstate (stub
# ssh/sudo/ip/iptables*/nft/systemd-run/systemctl/pcs/hostname).
#
#   bash tests/restore-network-state/run.sh           # semua tes (~15 menit:
#                                                     # beberapa tes menunggu timer rollback 120 detik)
#   bash tests/restore-network-state/run.sh dryrun    # hanya tes yang namanya cocok
#   KEEP=1 bash tests/restore-network-state/run.sh    # simpan direktori kerja
#
# Setiap tes membuat backup SUNGGUHAN dengan rhosp/backup-network-state.sh
# terhadap node palsu, mengubah state live node (drift), lalu menjalankan
# restore. Butuh: bash, jq, tmux, setsid, ssh-keygen, tar, gzip, sha256sum,
# mkfifo, flock. Opsional: unshare + iptables-nft + nft asli (tes real_apply).
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/rhosp/restore-network-state.sh"
BACKUP_SCRIPT="$ROOT/rhosp/backup-network-state.sh"
STUB="$HERE/stub"
FIX="$HERE/fixtures"
CS="$ROOT/tests/collect-sosreport"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rns-test.XXXXXX")"
TM=(tmux -L "rns-test-$$")
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()

C0=192.168.24.21 C1=192.168.24.22 C2=192.168.24.23
P0=192.168.24.24 P1=192.168.24.25 P2=192.168.24.26
ALL_IPS=("$C0" "$C1" "$C2" "$P0" "$P1" "$P2")
declare -A NAME_OF=(
    [$C0]=overcloud-controller-0 [$C1]=overcloud-controller-1 [$C2]=overcloud-controller-2
    [$P0]=overcloud-computeiha-0 [$P1]=overcloud-computeiha-1 [$P2]=overcloud-computeiha-2
)
BK_RUN="bk-0001"
RS_RUN="rs-0001"
CONTENT_PAT='OSOPS-RULE-MARKER|10\.99\.42|10\.98\.|10\.77\.|10\.66\.|fd00:99:42|172\.17\.0\.19'
SECRET_PAT='FAKE-os-auth-token-9d1e7c|FakeOvercloudAdminPw-4c7b2a'

for tool in jq tmux setsid ssh-keygen tar gzip sha256sum mkfifo flock; do
    command -v "$tool" >/dev/null 2>&1 || { echo "❌ $tool dibutuhkan untuk tes"; exit 1; }
done

cleanup() {
    "${TM[@]}" kill-server 2>/dev/null || true
    pkill -f "$WORK/state" 2>/dev/null || true
    if [[ -n "${KEEP:-}" ]]; then
        echo "Direktori kerja disimpan: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$WORK/hostkey" >/dev/null
HOSTKEY_PUB="$(awk '{print $1 " " $2}' "$WORK/hostkey.pub")"

# ============================================================
# Helpers
# ============================================================

CURRENT=""
ok() { PASS=$(( PASS + 1 )); echo "  ✅ $1"; }
bad() {
    FAIL=$(( FAIL + 1 ))
    FAILED_TESTS+=("$CURRENT: $1")
    echo "  ❌ $1"
    [[ -n "${2:-}" ]] && printf '     %s\n' "${2:0:700}"
    return 0
}
expect_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "dapat: '$2'  harap: '$3'"; fi; }
expect_match() { if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "dapat: '${2: -600}'  pola: '$3'"; fi; }
expect_no_match() {
    if [[ ! "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "pola tidak boleh muncul: '$3' => '$(grep -oE -- "$3" <<< "$2" | head -n 3 | tr '\n' ' ')'"; fi
}
expect_true() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

hd() { printf '%s' "$WORK/state/hosts/$1"; }
host_env() { local ip="$1"; shift; printf '%s\n' "$@" >> "$(hd "$ip")/env"; }

reset_state() {
    local ip
    "${TM[@]}" kill-server 2>/dev/null || true
    pkill -f "$WORK/state" 2>/dev/null || true
    rm -rf "${WORK:?}/state" "${WORK:?}/log" "${WORK:?}/backup" "${WORK:?}/home" "${WORK:?}/stack" "${WORK:?}/out" "${WORK:?}/tmp"
    mkdir -p "$WORK/state/cluster" "$WORK/log" "$WORK/home/.ssh" "$WORK/stack" "$WORK/out" "$WORK/tmp"
    : > "$WORK/state/calls.log"
    : > "$WORK/home/.ssh/known_hosts"
    : > "$WORK/home/.ssh/id_rsa"
    for ip in "${ALL_IPS[@]}"; do
        mkdir -p "$(hd "$ip")/live" "$(hd "$ip")/tmp" "$(hd "$ip")/var/lib"
        cp "$FIX"/live/* "$(hd "$ip")/live/"
        printf 'FQDN=%s.localdomain\nPCS_NAME=%s\n' "${NAME_OF[$ip]}" "${NAME_OF[$ip]}" > "$(hd "$ip")/env"
        printf '%s %s\n' "$ip" "$HOSTKEY_PUB" >> "$WORK/home/.ssh/known_hosts"
    done
    cp "$CS/fixtures/pcs-status-nodes.txt" "$WORK/state/cluster/status-nodes"
    echo true > "$WORK/state/cluster/stonith"
    cp "$CS/fixtures/inventory.yaml" "$CS/fixtures/inventory.yaml.json" "$WORK/stack/"
    echo "Red Hat OpenStack Platform release 17.1.4 (Wallaby)" > "$WORK/rhosp-release"
}

_envs() {
    printf '%s ' -u OS_REGION_NAME -u STY "TMUX=rns-test" "HOME=$(printf '%q' "$WORK/home")" \
        "STUB_STATE=$(printf '%q' "$WORK/state")" "STUB_HOSTKEY_PUB=$(printf '%q' "$HOSTKEY_PUB")" \
        "OSOPS_SSH=$(printf '%q' "$STUB/ssh")" \
        "OSOPS_ANSIBLE_INVENTORY=$(printf '%q' "$CS/stub/ansible-inventory")" "OSOPS_FZF=$(printf '%q' "$CS/stub/fzf")" \
        "OSOPS_RHOSP_RELEASE_FILE=$(printf '%q' "$WORK/rhosp-release")" "OSOPS_STACK_HOME=$(printf '%q' "$WORK/stack")" \
        "OSOPS_LOG_DIR=$(printf '%q' "$WORK/log")" "OSOPS_BACKUP_DIR=$(printf '%q' "$WORK/backup")" \
        "TMPDIR=$(printf '%q' "$WORK/tmp")"
}

# make_backup HOST... — backup sungguhan (backup-network-state.sh) => $BK_DIR
make_backup() {
    local rc=0 nodes
    nodes="$(IFS=,; printf '%s' "$*")"
    eval "env $(_envs) OSOPS_RUN_ID=$BK_RUN setsid bash $(printf '%q' "$BACKUP_SCRIPT") --nodes $(printf '%q' "$nodes")" \
        < /dev/null > "$WORK/out/backup.txt" 2>&1 || rc=$?
    BK_DIR="$WORK/backup/network-state/$BK_RUN"
    if (( rc != 0 && ! ${ALLOW_FAIL:-0} )); then bad "backup gagal (rc=$rc)" "$(tail -n 15 "$WORK/out/backup.txt")"; return 1; fi
    : > "$WORK/state/calls.log"
}

run_plain() {
    local envs="$1" args=""
    shift
    PLAIN_RC=0
    (( $# > 0 )) && printf -v args '%q ' "$@"
    eval "env $(_envs) OSOPS_RUN_ID=$RS_RUN $envs setsid bash $(printf '%q' "$SCRIPT") $args" \
        < /dev/null > "$WORK/out/plain.txt" 2>&1 || PLAIN_RC=$?
    PLAIN_OUT="$(cat "$WORK/out/plain.txt")"
}

run_tmux() {
    local envs="$1" cmd=""
    shift
    (( $# > 0 )) && printf -v cmd '%q ' "$@"
    "${TM[@]}" kill-server 2>/dev/null || true
    "${TM[@]}" new-session -d -s t -x 250 -y 80 \
        "env $(_envs) OSOPS_RUN_ID=$RS_RUN $envs bash $(printf '%q' "$SCRIPT") $cmd; echo __EXIT=\$?; sleep 3600"
}

screen_text() { "${TM[@]}" capture-pane -p -J -t t -S -10000 2>/dev/null; }
count_of() { screen_text | grep -cE -- "$1" || true; }
wait_for() {
    local pat="$1" n="${2:-1}" secs="${3:-60}" i
    for (( i = 0; i < secs * 5; i++ )); do
        (( $(count_of "$pat") >= n )) && return 0
        sleep 0.2
    done
    bad "timeout menunggu '$pat' (x$n)"
    screen_text | tail -n 30 | sed 's/^/     | /'
    return 1
}
keys() { "${TM[@]}" send-keys -t t "$@"; }
answer() { wait_for "$1" "${2:-1}" "${4:-60}" && keys "$3" Enter; }
tmux_exit() {
    wait_for '__EXIT=' 1 "${1:-90}" || { echo "?"; return 0; }
    screen_text | grep -o '__EXIT=[0-9]*' | tail -n 1 | cut -d= -f2
}

# start_apply ARGS... — tmux, jawab prompt user bukan stack, hostname, RESTORE
start_apply() {
    local name="$1"
    shift
    run_tmux "" "$@"
    if [[ "$(id -un)" != stack ]]; then answer 'Tetap lanjut sebagai' 1 y || return 1; fi
    answer "Ketik hostname node \\($name\\) untuk melanjutkan" 1 "$name" 90 || return 1
    answer 'Ketik RESTORE' 1 RESTORE || return 1
}

calls() { cat "$WORK/state/calls.log"; }
log_text() { cat "$WORK"/log/rhosp/restore-network-state-*.log 2>/dev/null || true; }
state_file() { printf '%s' "$WORK/log/rhosp/restore-network-state-$1.state"; }
unit_dir() { printf '%s' "$(hd "$1")/systemd/osops-restore-rb-$RS_RUN"; }
node_dir() { printf '%s' "$(hd "$1")/var/lib/osops-restore/$RS_RUN"; }
want() { [[ -z "$FILTER" || "$1" == *"$FILTER"* ]]; }
begin() { CURRENT="$1"; echo; echo "▶ $1"; reset_state; }

# Perintah yang mengubah node (tidak boleh ada di dry-run)
mutating_calls() {
    awk -F'\t' '
        ($1 == "iptables-restore" || $1 == "ip6tables-restore") && $3 !~ /(^| )(--test|--version|-V)( |$)/ { print; next }
        $1 == "nft" && ($3 ~ /^-f / || $3 ~ /^delete /) { print; next }
        $1 == "ip" && $3 ~ /(route|rule) (add|del)/ { print; next }
        $1 == "systemd-run" { print; next }
        $1 == "systemctl" && $3 ~ /^(start|stop) / { print; next }
        $1 == "SUDO" && $3 ~ /^(mkdir|install|tar -x|rm )/ { print; next }
    ' "$WORK/state/calls.log"
}

check_log_clean() {
    local all
    all="$(cat "$WORK"/log/*.log "$WORK"/log/*/*.log 2>/dev/null || true)"
    expect_no_match "isi aturan/route tidak ada di log" "$all" "$CONTENT_PAT"
    expect_no_match "secret inventory tidak ada di log" "$all" "$SECRET_PAT"
}

# Drift standar pada node IP: iptables (hapus aturan + aturan ekstra), route
# (hilang, ekstra, beda atribut, default route berubah), rule hilang
drift() {
    local L
    L="$(hd "$1")/live"
    sed -i '/MARKER-ipt4/d; s#^-A INPUT -p tcp -m tcp --dport 2222 -j ACCEPT#-A INPUT -p tcp -m tcp --dport 2222 -j ACCEPT\n-A INPUT -s 10.77.7.7/32 -j ACCEPT#' "$L/ipt4"
    jq 'map(select(.dst != "10.98.0.0/16"))
        | map(if .dst == "default" then .gateway = "192.168.24.254" else . end)
        | map(if .dst == "10.99.42.0/24" then .gateway = "172.17.0.197" else . end)
        + [{"dst":"10.66.0.0/16","gateway":"172.17.0.1","dev":"vlan20","protocol":"static","flags":[]}]' \
        "$L/routes4.json" > "$L/r.tmp" && mv "$L/r.tmp" "$L/routes4.json"
    jq 'map(select(.priority != 4242))' "$L/rules4.json" > "$L/r.tmp" && mv "$L/r.tmp" "$L/rules4.json"
}

# ============================================================
# Tes
# ============================================================

test_dryrun() {
    local f
    begin "dryrun"
    make_backup overcloud-controller-0 || return 0
    drift "$C0"
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4,routes-v4,rules-v4 --save-diff "$WORK/out/diff.txt"
    expect_eq "dry-run: exit 0" "$PLAIN_RC" "0"
    [[ "$PLAIN_RC" == 0 ]] || { tail -n 30 <<< "$PLAIN_OUT" | sed 's/^/     | /'; return 0; }
    expect_eq "dry-run: TIDAK ada perintah yang mengubah node" "$(mutating_calls)" ""
    expect_match "diff iptables: aturan dari backup ditambah" "$PLAIN_OUT" '\+-A INPUT -s 10\.99\.42\.7/32'
    expect_match "diff iptables: aturan ekstra akan hilang" "$PLAIN_OUT" '--A INPUT -s 10\.77\.7\.7/32'
    expect_match "diff iptables: hitungan per tabel" "$PLAIN_OUT" 'tabel filter: \+1 / -1 aturan'
    expect_match "route hilang akan ditambahkan" "$PLAIN_OUT" '\+ 10\.98\.0\.0/16 via 172\.17\.0\.198 dev vlan20 proto static metric 100'
    expect_match "route ekstra: manual, tidak dihapus" "$PLAIN_OUT" 'manual \(ada sekarang, tidak di backup; TIDAK dihapus\): 10\.66\.0\.0/16'
    expect_match "default route berbeda: manual" "$PLAIN_OUT" 'default route berbeda; TIDAK disentuh'
    expect_match "atribut berbeda: manual" "$PLAIN_OUT" 'manual \(atribut berbeda\): sekarang: 10\.99\.42\.0/24 via 172\.17\.0\.197'
    expect_no_match "route kernel/link-local/local tidak masuk daftar tambah" "$PLAIN_OUT" '\+ (192\.168\.24\.0/24|169\.254|192\.168\.24\.21)'
    expect_match "rule hilang akan ditambahkan" "$PLAIN_OUT" '\+ priority 4242 from 10\.99\.42\.0/24 lookup 4242'
    local dry1="$PLAIN_OUT"
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items nftables
    expect_match "nftables: menyebut tabel iptables-nft" "$PLAIN_OUT" 'Item nftables juga MENGUBAH tabel iptables-nft: ip filter'
    expect_eq "nftables tanpa perbedaan: NOT_APPLIED" "$(grep -cE 'nftables +NOT_APPLIED' <<< "$PLAIN_OUT" || true)/$(grep -cE 'nftables +NOT_APPLIED +dry-run \(\+0 / -0\)' <<< "$PLAIN_OUT" || true)" "1/1"
    PLAIN_OUT="$dry1"
    expect_match "ringkasan: NOT_APPLIED dry-run" "$PLAIN_OUT" 'iptables-v4 +NOT_APPLIED +dry-run \(\+1 / -1\)'
    expect_match "ringkasan: daftar tindakan manual" "$PLAIN_OUT" 'Perlu tindakan manual'
    expect_match "peringatan runtime/director" "$PLAIN_OUT" 'reboot atau run director berikutnya'
    f="$WORK/out/diff.txt"
    expect_eq "--save-diff: permission 600" "$(stat -c %a "$f" 2>/dev/null)" "600"
    expect_match "--save-diff: berisi diff" "$(cat "$f" 2>/dev/null)" '10\.98\.0\.0/16'
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --save-diff "$WORK/out/diff.txt"
    expect_match "--save-diff tidak menimpa" "$PLAIN_OUT" 'file sudah ada'
    expect_match "log: jumlah perubahan per item" "$(log_text)" 'DIFF item=iptables-v4 add=1 remove=1'
    expect_match "log: PLAN dry_run=true" "$(log_text)" 'PLAN dry_run=true host=overcloud-controller-0 item=routes-v4 add=1'
    check_log_clean
}

test_validation() {
    local f
    begin "validation"
    make_backup overcloud-controller-0 || return 0
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4
    expect_eq "backup utuh: dry-run exit 0" "$PLAIN_RC" "0"
    # hostname tidak cocok
    host_env "$C0" FQDN=other-node.localdomain
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4
    expect_match "hostname tidak cocok: ditolak" "$PLAIN_OUT" 'Hostname node \(other-node\.localdomain\) tidak sama'
    expect_eq "hostname tidak cocok: exit 1" "$PLAIN_RC" "1"
    sed -i '/^FQDN=other/d' "$(hd "$C0")/env"
    # backend berbeda
    host_env "$C0" IPT_BACKEND=legacy
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4
    expect_match "backend berbeda: ditolak" "$PLAIN_OUT" 'Backend iptables node \(legacy\) tidak sama dengan backup \(nf_tables\)'
    sed -i '/^IPT_BACKEND/d' "$(hd "$C0")/env"
    # sha256 rusak
    f="$BK_DIR/overcloud-controller-0/iptables-v4.rules"
    cp -p "$f" "$WORK/keep"
    echo "-A INPUT -j ACCEPT" >> "$f"
    : > "$WORK/state/calls.log"
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4
    expect_match "sha256 rusak: ditolak sebelum SSH" "$PLAIN_OUT" 'Backup tidak valid: sha256 mismatch'
    expect_eq "sha256 rusak: tidak ada koneksi ke node" "$(grep -c '^ssh' "$WORK/state/calls.log" || true)" "0"
    cp -p "$WORK/keep" "$f"
    chmod 644 "$f"
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4
    expect_match "permission 644: ditolak" "$PLAIN_OUT" 'bad permission/owner/type: overcloud-controller-0/iptables-v4\.rules'
    chmod 600 "$f"
    : > "$BK_DIR/overcloud-controller-0/extra.txt"; chmod 600 "$BK_DIR/overcloud-controller-0/extra.txt"
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4
    expect_match "file asing di backup: ditolak" "$PLAIN_OUT" 'unexpected file in backup'
    rm -f "$BK_DIR/overcloud-controller-0/extra.txt"
    # netns, item tidak dikenal, undercloud, mode multi-node
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items netns
    expect_match "netns ditolak" "$PLAIN_OUT" 'Network namespace \(netns\) tidak di-restore'
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items all
    expect_match "item tidak dikenal ditolak" "$PLAIN_OUT" 'Item tidak dikenal: all'
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0
    expect_match "tanpa terminal: --items wajib" "$PLAIN_OUT" 'Tanpa terminal: --items wajib'
    run_plain "" --all
    expect_match "--all ditolak" "$PLAIN_OUT" 'satu node per run'
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --rollback-timeout 119
    expect_match "--rollback-timeout < 120 ditolak" "$PLAIN_OUT" 'rollback-timeout harus bilangan bulat 120-900'
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply
    expect_match "--apply tanpa terminal ditolak" "$PLAIN_OUT" '--apply membutuhkan terminal'
    mkdir -m 700 "$BK_DIR/undercloud"
    run_plain "" --backup-dir "$BK_DIR" --host undercloud --items iptables-v4
    expect_match "undercloud bukan target" "$PLAIN_OUT" 'Undercloud tidak didukung|host not in backup|tidak ada di inventory|Backup tidak valid'
}

test_items() {
    begin "items"
    host_env "$C0" VERIFY_FAIL=nft
    ALLOW_FAIL=1 make_backup overcloud-controller-0 overcloud-controller-1 || return 0
    sed -i '/^VERIFY_FAIL/d' "$(hd "$C0")/env"
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items nftables
    expect_match "item VERIFY_FAILED ditolak" "$PLAIN_OUT" 'Item nftables tidak bisa di-restore: VERIFY_FAILED in backup'
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-1 --items nftables,iptables-v4
    expect_match "nftables + iptables (nf_tables) ditolak" "$PLAIN_OUT" 'nftables tidak bisa digabung dengan iptables-v4/v6'
    # xt di backup
    reset_state
    sed -i 's/tcp dport 22 counter/xt match "string" counter/' "$(hd "$C1")/live/nft"
    make_backup overcloud-controller-1 || return 0
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-1 --items nftables
    expect_match "ruleset xt di backup ditolak" "$PLAIN_OUT" 'nftables tidak bisa di-restore: verification skipped in backup \(xt\)|berisi ekspresi xt'
    # xt di kondisi sekarang (rollback tidak mungkin)
    reset_state
    make_backup overcloud-controller-1 || return 0
    sed -i 's/tcp dport 22 counter/xt match "string" counter/' "$(hd "$C1")/live/nft"
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-1 --items nftables
    expect_match "xt di kondisi sekarang: NOT_APPLIED" "$PLAIN_OUT" 'nftables +NOT_APPLIED +current ruleset contains xt'
    # legacy: kombinasi boleh
    reset_state
    host_env "$C1" IPT_BACKEND=legacy
    make_backup overcloud-controller-1 || return 0
    run_plain "" --backup-dir "$BK_DIR" --host overcloud-controller-1 --items nftables,iptables-v4
    expect_eq "legacy: nftables + iptables-v4 diterima (dry-run exit 0)" "$PLAIN_RC" "0"
}

test_apply_reject() {
    local rc
    begin "apply_reject"
    make_backup overcloud-controller-0 overcloud-computeiha-0 || return 0
    drift "$C0"
    host_env "$C0" NO_SYSTEMD_RUN=1
    run_tmux "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply
    if [[ "$(id -un)" != stack ]]; then answer 'Tetap lanjut sebagai' 1 y || return 0; fi
    rc="$(tmux_exit)"
    expect_match "tanpa systemd-run: --apply ditolak" "$(screen_text)" 'Tool tidak ada di overcloud-controller-0 \(systemd-run\): --apply ditolak'
    expect_eq "tanpa systemd-run: exit 1" "$rc" "1"
    expect_eq "tanpa systemd-run: tidak ada perubahan" "$(mutating_calls)" ""
    # Node cluster Offline sebelum apply
    reset_state
    make_backup overcloud-computeiha-0 || return 0
    drift "$P0"
    sed -i '0,/^ Offline:$/ s/^ Offline:$/ Offline: overcloud-controller-2/; s/^ Online: overcloud-controller-0 overcloud-controller-1 overcloud-controller-2$/ Online: overcloud-controller-0 overcloud-controller-1/' "$WORK/state/cluster/status-nodes"
    run_tmux "" --backup-dir "$BK_DIR" --host overcloud-computeiha-0 --items iptables-v4 --apply
    if [[ "$(id -un)" != stack ]]; then answer 'Tetap lanjut sebagai' 1 y || return 0; fi
    rc="$(tmux_exit)"
    expect_match "node cluster Offline: ditolak" "$(screen_text)" 'Tidak semua node cluster Online \(Offline overcloud-controller-2\)'
    expect_eq "cluster Offline: tidak ada perubahan" "$(mutating_calls)" ""
    # Ditolak di konfirmasi berlapis
    reset_state
    make_backup overcloud-controller-0 || return 0
    drift "$C0"
    echo false > "$WORK/state/cluster/stonith"
    run_tmux "" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply
    if [[ "$(id -un)" != stack ]]; then answer 'Tetap lanjut sebagai' 1 y || return 0; fi
    answer 'Ketik hostname node \(overcloud-controller-0\)' 1 overcloud-controller-1 90 || return 0
    expect_eq "hostname salah di konfirmasi: exit 0" "$(tmux_exit)" "0"
    expect_match "stonith false: peringatan" "$(screen_text)" 'stonith-enabled=false: tanpa fencing'
    expect_match "DECLINED dicatat" "$(log_text)" 'item=iptables-v4 action=restore result=DECLINED'
    expect_eq "ditolak: tidak ada perubahan" "$(mutating_calls)" ""
}

test_apply_confirm() {
    local L rd before
    begin "apply_confirm"
    make_backup overcloud-controller-0 || return 0
    drift "$C0"
    L="$(hd "$C0")/live"
    before="$(cat "$L/routes4.json")"
    start_apply overcloud-controller-0 --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4,routes-v4,rules-v4 --apply || return 0
    answer 'untuk MEMPERTAHANKAN perubahan' 1 overcloud-controller-0 120 || return 0
    expect_eq "exit 0" "$(tmux_exit 60)" "0"
    expect_match "ringkasan: APPLIED" "$(screen_text)" 'iptables-v4 +APPLIED +confirmed'
    expect_eq "iptables live = backup (filter)" "$(grep -c '10.99.42.7' "$L/ipt4")/$(grep -c '10.77.7.7' "$L/ipt4")" "1/0"
    expect_match "tabel nat tetap ada" "$(cat "$L/ipt4")" '\*nat'
    expect_eq "route hilang ditambahkan" "$(jq '[.[] | select(.dst == "10.98.0.0/16")] | length' "$L/routes4.json")" "1"
    expect_eq "route ekstra TIDAK dihapus" "$(jq '[.[] | select(.dst == "10.66.0.0/16")] | length' "$L/routes4.json")" "1"
    expect_eq "default route TIDAK disentuh" "$(jq -r '.[] | select(.dst == "default") | .gateway' "$L/routes4.json")" "192.168.24.254"
    expect_eq "route beda atribut TIDAK disentuh" "$(jq -r '.[] | select(.dst == "10.99.42.0/24") | .gateway' "$L/routes4.json")" "172.17.0.197"
    expect_eq "tidak pernah ip route del" "$(grep -cE $'^ip\t[^\t]+\t-4 route del' "$WORK/state/calls.log" || true)" "0"
    expect_eq "tidak pernah menyentuh default route" "$(grep -cE $'^ip\t[^\t]+\t-4 route (add|del) default' "$WORK/state/calls.log" || true)" "0"
    expect_eq "rule hilang ditambahkan" "$(jq '[.[] | select(.priority == 4242)] | length' "$L/rules4.json")" "1"
    expect_true "timer rollback dibatalkan" test ! -e "$(unit_dir "$C0")/timer.active"
    expect_true "rollback tidak berjalan" test ! -e "$(unit_dir "$C0")/service.done"
    expect_true "salinan di node dihapus" test ! -e "$(node_dir "$C0")"
    expect_true "state file dihapus" test ! -e "$(state_file overcloud-controller-0)"
    rd="$WORK/backup/network-state/$RS_RUN-pre-restore"
    expect_true "snapshot pra-restore ada" test -f "$rd/overcloud-controller-0/iptables-v4.rules"
    expect_true "snapshot pra-restore valid (SHA256SUMS)" bash -c "cd $(printf '%q' "$rd") && sha256sum -c --quiet SHA256SUMS"
    expect_eq "snapshot pra-restore 700" "$(stat -c %a "$rd")" "700"
    expect_match "snapshot pra-restore berisi kondisi sebelum apply" "$(cat "$rd/overcloud-controller-0/iptables-v4.rules")" '10\.77\.7\.7'
    expect_match "SSH baru tanpa ControlMaster" "$(calls)" $'ssh\t192\\.168\\.24\\.21\tcm=no,cp=none\t[^\n]*agent\\.sh counts'
    expect_match "verifikasi --test sebelum apply" "$(calls)" $'iptables-restore\t[^\t]+\t--test -w 5'
    expect_match "timer dijadwalkan sebelum apply" "$(awk -F'\t' '$1 == "systemd-run" { print "S" } $1 == "iptables-restore" && $3 == "-w 5" { print "A" }' "$WORK/state/calls.log" | tr -d '\n')" '^SA'
    expect_match "systemd-run: on-active + oneshot" "$(calls)" $'systemd-run\t[^\t]+\t--unit=osops-restore-rb-rs-0001 [^\n]*--on-active=180s'
    expect_match "pcs dicek dari controller lain" "$(calls)" $'pcs\t192\\.168\\.24\\.22\tstatus nodes'
    expect_match "log: SUCCESS per item" "$(log_text)" 'item=routes-v4 action=restore result=SUCCESS'
    expect_match "log: CHECK ssh/pacemaker/counts OK" "$(log_text)" 'CHECK check=counts result=OK'
    check_log_clean
    if [[ "$before" != "$(cat "$L/routes4.json")" ]]; then ok "route state berubah (sanity)"; fi
}

test_ssh_block() {
    local L
    begin "ssh_block"
    L="$(hd "$C0")/live"
    sed -i 's#^-A INPUT -p tcp -m tcp --dport 2222 -j ACCEPT#-A INPUT -p tcp -m tcp --dport 22 -m comment --comment BLOCKSSH -j DROP#' "$L/ipt4"
    touch "$(hd "$C0")/allow-ssh"
    make_backup overcloud-controller-0 || return 0
    rm -f "$(hd "$C0")/allow-ssh"
    # Aturan blok hanya ada di backup; kondisi sekarang tanpa blok
    sed -i '/BLOCKSSH/d' "$L/ipt4"
    start_apply overcloud-controller-0 --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply --rollback-timeout 120 || return 0
    wait_for 'Pengecekan gagal: new SSH connection failed' 1 90 || return 0
    expect_eq "exit 1 (rolled back)" "$(tmux_exit 330)" "1"
    expect_match "rollback oleh timer meski SSH putus, terverifikasi" "$(screen_text)" 'Rollback selesai dan terverifikasi lewat koneksi baru'
    expect_match "ringkasan: ROLLED_BACK" "$(screen_text)" 'iptables-v4 +ROLLED_BACK +new SSH connection failed'
    expect_eq "aturan blok sudah hilang (rollback)" "$(grep -c BLOCKSSH "$L/ipt4" || true)" "0"
    expect_true "rollback dijalankan oleh unit" test -e "$(unit_dir "$C0")/service.done"
    expect_true "state file dihapus setelah rollback terverifikasi" test ! -e "$(state_file overcloud-controller-0)"
    expect_true "direktori node dibersihkan" test ! -e "$(node_dir "$C0")"
    expect_match "log: rollback event" "$(log_text)" 'ROLLBACK result=OK verified=yes'
    expect_match "log: FAILED per item" "$(log_text)" 'item=iptables-v4 action=restore result=FAILED'
}

test_confirm_timeout() {
    local L
    begin "confirm_timeout"
    make_backup overcloud-controller-0 || return 0
    drift "$C0"
    L="$(hd "$C0")/live"
    cp "$L/ipt4" "$WORK/ipt4.before"
    start_apply overcloud-controller-0 --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply --rollback-timeout 120 || return 0
    wait_for 'untuk MEMPERTAHANKAN perubahan' 1 120 || return 0
    expect_eq "exit 1 (tidak dikonfirmasi)" "$(tmux_exit 330)" "1"
    expect_match "tidak ada konfirmasi: rollback" "$(screen_text)" 'Tidak ada konfirmasi: rollback dibiarkan berjalan'
    expect_eq "iptables kembali ke kondisi sebelum apply" "$(cat "$L/ipt4")" "$(cat "$WORK/ipt4.before")"
    expect_match "ringkasan ROLLED_BACK" "$(screen_text)" 'iptables-v4 +ROLLED_BACK +not confirmed in time'
    expect_match "verifikasi rollback benar-benar membandingkan (OK)" "$(screen_text)" 'verifikasi iptables-v4: OK'
}

test_remain_short() {
    begin "remain_short"
    make_backup overcloud-controller-0 || return 0
    drift "$C0"
    start_apply overcloud-controller-0 --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply --rollback-timeout 120 || return 0
    host_env "$C1" PCS_SLOW=28
    expect_eq "exit 1" "$(tmux_exit 360)" "1"
    expect_match "waktu konfirmasi tidak cukup" "$(screen_text)" 'Waktu konfirmasi tidak cukup \(sisa [0-9]+s < 45s\)'
    expect_eq "tidak ada prompt konfirmasi" "$(count_of 'untuk MEMPERTAHANKAN')" "0"
    expect_match "rollback berjalan" "$(screen_text)" 'Rollback selesai dan terverifikasi'
}

test_interrupt() {
    local rc
    begin "interrupt"
    make_backup overcloud-controller-0 || return 0
    drift "$C0"
    start_apply overcloud-controller-0 --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply --rollback-timeout 120 || return 0
    wait_for 'untuk MEMPERTAHANKAN perubahan' 1 120 || return 0
    keys C-c
    rc="$(tmux_exit 30)"
    expect_eq "Ctrl-C: exit 130" "$rc" "130"
    expect_match "Ctrl-C: timer tidak dibatalkan" "$(screen_text)" 'Timer TIDAK dibatalkan'
    expect_true "timer masih aktif di node" test -e "$(unit_dir "$C0")/timer.active"
    expect_true "state file tetap ada" test -e "$(state_file overcloud-controller-0)"
    expect_match "log: ABORTED" "$(log_text)" 'item=iptables-v4 action=restore result=ABORTED'
    # --status read-only
    : > "$WORK/state/calls.log"
    run_plain "OSOPS_RUN_ID=st-0001" --status --host overcloud-controller-0
    expect_match "--status: PENDING_ROLLBACK" "$PLAIN_OUT" 'Status node +: PENDING_ROLLBACK'
    expect_eq "--status: read-only" "$(mutating_calls)" ""
    # restore baru ditolak
    run_tmux "OSOPS_RUN_ID=rs-0002" --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply
    if [[ "$(id -un)" != stack ]]; then answer 'Tetap lanjut sebagai' 1 y || return 0; fi
    expect_eq "restore baru selama belum tuntas: exit 1" "$(tmux_exit)" "1"
    expect_match "restore baru ditolak" "$(screen_text)" 'Restore baru ditolak sampai statusnya jelas'
    # --clear-state saat timer aktif
    run_tmux "OSOPS_RUN_ID=st-0002" --clear-state --host overcloud-controller-0
    if [[ "$(id -un)" != stack ]]; then answer 'Tetap lanjut sebagai' 1 y || return 0; fi
    expect_eq "--clear-state saat timer aktif: exit 1" "$(tmux_exit)" "1"
    expect_match "--clear-state ditolak" "$(screen_text)" '--clear-state ditolak: status PENDING_ROLLBACK'
    expect_true "timer tetap aktif" test -e "$(unit_dir "$C0")/timer.active"
    # Tunggu rollback oleh timer, lalu --status dan --clear-state
    local i
    for (( i = 0; i < 150; i++ )); do [[ -e "$(unit_dir "$C0")/service.done" ]] && break; sleep 1; done
    expect_true "rollback berjalan oleh timer" test -e "$(unit_dir "$C0")/service.done"
    run_plain "OSOPS_RUN_ID=st-0003" --status --host overcloud-controller-0
    expect_match "--status: ROLLED_BACK terverifikasi" "$PLAIN_OUT" 'Rollback selesai dan terverifikasi'
    run_tmux "OSOPS_RUN_ID=st-0004" --clear-state --host overcloud-controller-0
    if [[ "$(id -un)" != stack ]]; then answer 'Tetap lanjut sebagai' 1 y || return 0; fi
    answer 'untuk menghapus state' 1 overcloud-controller-0 || return 0
    expect_eq "--clear-state: exit 0" "$(tmux_exit)" "0"
    expect_true "--clear-state: state file dihapus" test ! -e "$(state_file overcloud-controller-0)"
    expect_true "--clear-state: direktori node dihapus" test ! -e "$(node_dir "$C0")"
}

test_rollback_integrity() {
    local L
    begin "rollback_integrity"
    make_backup overcloud-controller-0 || return 0
    drift "$C0"
    L="$(hd "$C0")/live"
    host_env "$C0" CORRUPT_PRE=1 OFFLINE_AFTER_APPLY=1
    start_apply overcloud-controller-0 --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply --rollback-timeout 120 || return 0
    expect_eq "rollback gagal integritas: exit 2" "$(tmux_exit 240)" "2"
    expect_match "KRITIS ditampilkan" "$(screen_text)" 'KRITIS: rollback di overcloud-controller-0 GAGAL'
    expect_match "alasan integrity" "$(screen_text)" 'integrity check failed \(SUMS\): nothing restored'
    expect_match "instruksi manual dengan path snapshot" "$(screen_text)" "Pulihkan manual dari snapshot pra-restore di undercloud: .*$RS_RUN-pre-restore/overcloud-controller-0/"
    expect_eq "tidak ada perubahan oleh rollback (aturan backup tetap)" "$(grep -c '10.99.42.7' "$L/ipt4")" "1"
    expect_true "state file tetap ada" test -e "$(state_file overcloud-controller-0)"
    run_plain "OSOPS_RUN_ID=st-0001" --status --host overcloud-controller-0
    expect_match "--status: KRITIS" "$PLAIN_OUT" 'ROLLBACK_FAILED[^❗]*❗ KRITIS'
}

# Rollback yang "berhasil" tetapi tidak memulihkan apa pun harus terdeteksi
test_rollback_mismatch() {
    local L
    begin "rollback_mismatch"
    make_backup overcloud-controller-0 || return 0
    drift "$C0"
    L="$(hd "$C0")/live"
    host_env "$C0" RB_NOOP=1 DRIFT_AFTER_APPLY=1
    start_apply overcloud-controller-0 --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply --rollback-timeout 120 || return 0
    expect_eq "rollback tidak memulihkan: exit 2 (kritis)" "$(tmux_exit 240)" "2"
    expect_match "rollback mendeteksi sendiri (jumlah per tabel)" "$(screen_text)" 'rollback iptables-v4: FAILED counts differ after restore: filter: [0-9]+ now, [0-9]+ expected'
    expect_match "KRITIS ditampilkan" "$(screen_text)" 'KRITIS: rollback di overcloud-controller-0 GAGAL'
    expect_true "direktori node TIDAK dihapus (bukti)" test -e "$(node_dir "$C0")/rollback.result"
    expect_true "state file tetap ada" test -e "$(state_file overcloud-controller-0)"
    expect_match "log: ROLLBACK_ITEM FAILED" "$(log_text)" 'ROLLBACK_ITEM item=iptables-v4 status=FAILED'
    expect_match "log: ROLLBACK FAILED" "$(log_text)" 'ROLLBACK result=FAILED'
    check_log_clean
}

# RHEL 9 + SELinux: di unit systemd iptables-restore tidak membaca stdin dari
# file (ditemukan di dev). Rollback lewat unit harus tetap memulihkan.
test_selinux_rollback() {
    local L
    begin "selinux_rollback"
    make_backup overcloud-controller-0 || return 0
    drift "$C0"
    L="$(hd "$C0")/live"
    cp "$L/ipt4" "$WORK/ipt4.before"
    host_env "$C0" SELINUX_SIM=1 OFFLINE_AFTER_APPLY=1
    start_apply overcloud-controller-0 --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply --rollback-timeout 120 || return 0
    expect_eq "exit 1 (rolled back)" "$(tmux_exit 240)" "1"
    expect_match "rollback lewat unit, terverifikasi" "$(screen_text)" 'verifikasi iptables-v4: OK'
    expect_match "ringkasan ROLLED_BACK" "$(screen_text)" 'iptables-v4 +ROLLED_BACK'
    expect_eq "iptables kembali persis ke kondisi sebelum apply" "$(cat "$L/ipt4")" "$(cat "$WORK/ipt4.before")"
    expect_eq "tidak ada restore yang terblokir (input lewat pipe)" "$(grep -c '^SELINUX_BLOCK' "$WORK/state/calls.log" || true)" "0"
    expect_true "rollback memang lewat unit" test -e "$(unit_dir "$C0")/service.done"
}

test_count_mismatch() {
    begin "count_mismatch"
    make_backup overcloud-controller-0 || return 0
    drift "$C0"
    host_env "$C0" DRIFT_AFTER_APPLY=1
    start_apply overcloud-controller-0 --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply --rollback-timeout 120 || return 0
    expect_eq "exit 1" "$(tmux_exit 240)" "1"
    expect_match "selisih per item/tabel (jumlah saja)" "$(screen_text)" 'Selisih jumlah \(jumlah saja\): iptables-v4 filter: expected 2, now 3'
    expect_match "menyebut kemungkinan agen" "$(screen_text)" 'rollback dipicu oleh agen, bukan oleh restore yang rusak'
    expect_match "rollback lebih awal" "$(screen_text)" 'Memicu rollback lebih awal'
}

test_upload_guard() {
    local cmd out
    begin "upload_guard"
    make_backup overcloud-controller-0 || return 0
    drift "$C0"
    mkdir -p "$(node_dir "$C0")"
    start_apply overcloud-controller-0 --backup-dir "$BK_DIR" --host overcloud-controller-0 --items iptables-v4 --apply || return 0
    expect_eq "direktori node sudah ada: exit 1" "$(tmux_exit 120)" "1"
    expect_match "direktori node sudah ada: ditolak" "$(screen_text)" 'Upload gagal: node directory exists'
    expect_eq "tidak ada timer/apply" "$(mutating_calls | grep -cvE $'^SUDO\t[^\t]+\tinstall ' || true)" "0"
    # Isi tar asing / symlink ditolak oleh perintah upload di node
    cmd="$(bash -c 'NS_RUN_ID_RE='"'"'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'"'"'; eval "$(sed -n "/^NODE_BASE=/p;/^BUNDLE_NAMES=/p" "$1")"; eval "$(sed -n "/^upload_cmd() {/,/^}/p" "$1")"; upload_cmd rs-0009' _ "$SCRIPT")"
    mkdir -p "$WORK/evil/items"
    echo x > "$WORK/evil/agent.sh"
    ln -s /etc/passwd "$WORK/evil/items/iptables-v4.rules"
    out="$(tar -czf - -C "$WORK/evil" . | env STUB_STATE="$WORK/state" HOME="$WORK/home" STUB_HOSTKEY_PUB="$HOSTKEY_PUB" "$STUB/ssh" -o StrictHostKeyChecking=yes -- "tripleo-admin@$C1" "$cmd" 2>&1)" || true
    expect_match "symlink di tar ditolak" "$out" 'unexpected entry type'
    rm -rf "$WORK/evil"; mkdir -p "$WORK/evil"
    echo x > "$WORK/evil/evil.sh"
    out="$(tar -czf - -C "$WORK/evil" . | env STUB_STATE="$WORK/state" HOME="$WORK/home" STUB_HOSTKEY_PUB="$HOSTKEY_PUB" "$STUB/ssh" -o StrictHostKeyChecking=yes -- "tripleo-admin@$C1" "$cmd" 2>&1)" || true
    expect_match "nama asing di tar ditolak" "$out" 'unexpected name in archive'
    expect_true "tidak ada direktori dibuat" test ! -e "$(hd "$C1")/var/lib/osops-restore/rs-0009"
    expect_eq "file sementara upload dihapus" "$(find "$(hd "$C1")/tmp" -name 'osops-restore-*' | wc -l)" "0"
}

test_legacy_rollback() {
    local L
    begin "legacy_rollback"
    host_env "$C1" IPT_BACKEND=legacy
    L="$(hd "$C1")/live"
    printf '*raw\n:PREROUTING ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n-A PREROUTING -s 10.77.1.1/32 -j CT --notrack\nCOMMIT\n' >> "$L/ipt4"
    make_backup overcloud-controller-1 || return 0
    awk '/^\*raw$/ { skip = 1 } !skip { print } /^COMMIT$/ { skip = 0 }' "$L/ipt4" > "$L/x" && mv "$L/x" "$L/ipt4"
    host_env "$C1" OFFLINE_AFTER_APPLY=1
    start_apply overcloud-controller-1 --backup-dir "$BK_DIR" --host overcloud-controller-1 --items iptables-v4,nftables --apply --rollback-timeout 120 || return 0
    expect_eq "exit 1 (rollback karena node Offline)" "$(tmux_exit 240)" "1"
    expect_match "pacemaker berubah => rollback" "$(screen_text)" 'Pengecekan gagal: cluster changed'
    expect_match "ringkasan: tabel legacy hanya dikosongkan" "$(screen_text)" 'Backend legacy: tabel yang dibuat oleh restore hanya DIKOSONGKAN saat rollback .*iptables-v4: raw'
    expect_eq "raw kosong setelah rollback (legacy)" "$(awk '/^\*raw$/ { on = 1 } on && /^-A / { n++ } /^COMMIT$/ { on = 0 } END { print n + 0 }' "$L/ipt4")" "0"
}

# Tool asli di user+net namespace: apply atomik + rollback dari snapshot =
# ruleset identik (agent sungguhan, systemd-run/systemctl palsu)
test_real_apply() {
    local out ag
    begin "real_apply"
    if ! command -v unshare >/dev/null 2>&1 || ! command -v nft >/dev/null 2>&1 \
       || ! command -v iptables-restore >/dev/null 2>&1 || ! unshare -rn true 2>/dev/null; then
        echo "  ⚠️  dilewati: unshare -rn / iptables / nft asli tidak tersedia (TIDAK diverifikasi)"
        return 0
    fi
    ag="$WORK/agent.sh"
    bash -c 'eval "$(sed -n "/^AWK_IPT_COUNT=/p;/^AWK_NFT_COUNT=/p" "$1")"; eval "$(sed -n "/^AGENT_SCRIPT=/,/^esac.$/p" "$1")"; printf "%s\n" "$AGENT_SCRIPT"' _ "$SCRIPT" > "$ag"
    mkdir -p "$WORK/fakebin"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\nd=%q\ncase "$1" in is-active) [ -f "$d/t" ] && { echo active; exit 0; }; echo inactive; exit 3 ;; stop) rm -f "$d/t" ;; esac\n' "$WORK" > "$WORK/fakebin/systemctl"
    printf '#!/bin/bash\ntouch %q/t\n' "$WORK" > "$WORK/fakebin/systemd-run"
    chmod +x "$WORK/fakebin/"*
    # shellcheck disable=SC2016
    out="$(PATH="$WORK/fakebin:$PATH" unshare -rn bash -c '
        set -u
        W="$1" AG="$2"
        D="$W/node/var/lib/osops-restore/rs-real"
        mkdir -p "$D/items" "$D/pre"; chmod 700 "$D"
        iptables -A INPUT -s 10.1.1.1 -j DROP
        nft add table inet t0; nft add chain inet t0 c0 "{ type filter hook input priority 0; }"; nft add rule inet t0 c0 tcp dport 22 accept
        cp "$AG" "$D/agent.sh"
        iptables-save > "$D/pre/iptables-v4.rules"
        { echo "flush ruleset"; nft -s list ruleset; } > "$D/pre/nftables.batch"
        printf "*filter\n:INPUT DROP [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n-A INPUT -s 10.9.9.9/32 -j ACCEPT\nCOMMIT\n" > "$D/items/iptables-v4.rules"
        printf "flush ruleset\ntable inet x {\n\tchain y {\n\t\ttype filter hook input priority 0; policy accept;\n\t\ttcp dport 2222 accept\n\t}\n}\n" > "$D/items/nftables.batch"
        : > "$D/pre/iptables-v4.drop"
        printf "run=rs-real\nhost=%s\nbackend=nf_tables\nitems=nftables\n" "$(hostname -f 2>/dev/null || hostname)" > "$D/conf"
        (cd "$D" && find . -type f ! -name SUMS -print0 | sort -z | xargs -0 sha256sum > SUMS)
        before="$(nft -s list ruleset)"
        bash "$D/agent.sh" verify; echo "verify_rc=$?"
        [ "$before" = "$(nft -s list ruleset)" ] && echo VERIFY_UNCHANGED
        bash "$D/agent.sh" schedule 120 >/dev/null
        bash "$D/agent.sh" apply
        nft -s list ruleset | grep -q "dport 2222" && echo APPLIED_NEW
        bash "$D/agent.sh" rollback; cat "$D/rollback.result"
        [ "$before" = "$(nft -s list ruleset)" ] && echo ROLLBACK_IDENTICAL || { echo ROLLBACK_DIFF; diff <(echo "$before") <(nft -s list ruleset); }
        # iptables-v4: tabel raw dibuat oleh restore => rollback menghapusnya (nf_tables)
        D="$W/node/var/lib/osops-restore/rs-real2"
        mkdir -p "$D/items" "$D/pre"; chmod 700 "$D"
        cp "$AG" "$D/agent.sh"
        iptables-save > "$D/pre/iptables-v4.rules"
        printf "*filter\n:INPUT ACCEPT [0:0]\n:FORWARD DROP [0:0]\n:OUTPUT ACCEPT [0:0]\n-A INPUT -s 10.8.8.8/32 -j DROP\nCOMMIT\n*raw\n:PREROUTING ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n-A PREROUTING -s 10.8.8.9/32 -j DROP\nCOMMIT\n" > "$D/items/iptables-v4.rules"
        echo raw > "$D/pre/iptables-v4.drop"
        printf "run=rs-real2\nhost=%s\nbackend=nf_tables\nitems=iptables-v4\n" "$(hostname -f 2>/dev/null || hostname)" > "$D/conf"
        (cd "$D" && find . -type f ! -name SUMS -print0 | sort -z | xargs -0 sha256sum > SUMS)
        rm -f "$W/t"
        ib="$(iptables-save | grep -v "^#")"; nb="$(nft -s list ruleset)"
        bash "$D/agent.sh" verify | grep -q "verify.iptables-v4.OK" && echo IPT_VERIFY_OK
        bash "$D/agent.sh" schedule 120 >/dev/null
        bash "$D/agent.sh" apply >/dev/null
        iptables-save -t raw | grep -q 10.8.8.9 && echo IPT_APPLIED
        bash "$D/agent.sh" rollback
        grep -q "^result=OK" "$D/rollback.result" && echo IPT_RB_OK
        # Level iptables (yang diverifikasi agent): identik. Level nft: iptables-restore
        # membuat ulang tabel ip filter (urutan listing) dan base chain kosong
        # (policy accept) yang sebelumnya dibuat lazily — fungsional sama.
        [ "$ib" = "$(iptables-save | grep -v "^#")" ] && echo IPT_ROLLBACK_IDENTICAL || { echo IPT_ROLLBACK_DIFF; diff <(echo "$ib") <(iptables-save | grep -v "^#"); }
        nft list tables | grep -q "table ip raw" || echo RAW_TABLE_GONE
        [ "$nb" = "$(nft -s list ruleset)" ] && echo NFT_TEXT_IDENTICAL || echo NFT_TEXT_DIFFERS
    ' _ "$WORK" "$ag" 2>&1)" || true
    expect_match "verify (nft -c) rc=0" "$out" 'verify_rc=0'
    expect_match "verify tidak mengubah ruleset" "$out" 'VERIFY_UNCHANGED'
    expect_match "apply atomik nft -f diterapkan" "$out" 'APPLIED_NEW'
    expect_match "rollback result=OK" "$out" 'result=OK'
    expect_match "rollback = ruleset identik dengan snapshot" "$out" $'(^|\n)ROLLBACK_IDENTICAL'
    expect_match "iptables: verify --test OK" "$out" 'IPT_VERIFY_OK'
    expect_match "iptables: apply atomik (tabel raw dibuat)" "$out" 'IPT_APPLIED'
    expect_match "iptables: rollback OK" "$out" 'IPT_RB_OK'
    expect_match "iptables: rollback = iptables-save identik" "$out" 'IPT_ROLLBACK_IDENTICAL'
    expect_match "iptables: tabel raw yang dibuat restore dihapus (nft delete table)" "$out" 'RAW_TABLE_GONE'
    if [[ "$out" == *NFT_TEXT_DIFFERS* ]]; then
        echo "     (catatan: teks nft list ruleset berbeda setelah rollback iptables: urutan tabel + base chain kosong; diketahui, fungsional sama)"
    fi
    if [[ "$out" == *ROLLBACK_DIFF* ]]; then
        printf '%s\n' "$out" | sed -n '/ROLLBACK_DIFF/,$p' | head -n 20 | sed 's/^/     | /'
    fi
    return 0
}

# ============================================================
# Run
# ============================================================

ALL_TESTS=(dryrun validation items apply_reject apply_confirm upload_guard count_mismatch
    rollback_integrity rollback_mismatch selinux_rollback legacy_rollback ssh_block confirm_timeout remain_short interrupt real_apply)
for t in "${ALL_TESTS[@]}"; do
    want "$t" && "test_$t"
done

echo
echo "========================================"
echo "Lulus: $PASS   Gagal: $FAIL"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
