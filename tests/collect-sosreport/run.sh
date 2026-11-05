#!/bin/bash
# ============================================================
# Tes rhosp/collect-sosreport.sh dengan stub ssh/scp/ansible-inventory/
# sudo/sosreport/pcs/fzf (tanpa undercloud/overcloud sungguhan).
#
#   bash tests/collect-sosreport/run.sh            # semua tes
#   bash tests/collect-sosreport/run.sh fencing    # hanya tes yang namanya cocok
#   KEEP=1 bash tests/collect-sosreport/run.sh     # simpan direktori kerja
#
# Butuh: bash, jq, tmux, flock, setsid, ssh-keygen. Script dijalankan di tmux
# karena semua prompt membaca dari /dev/tty. Stub ssh menjalankan perintah
# "remote" di direktori palsu per host ($WORK/state/hosts/<ip>).
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/rhosp/collect-sosreport.sh"
STUB="$HERE/stub"
FIX="$HERE/fixtures"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cs-test.XXXXXX")"
TM=(tmux -L "cs-test-$$")
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()

C0=192.168.24.21 C1=192.168.24.22 C2=192.168.24.23
P0=192.168.24.24 P1=192.168.24.25 P2=192.168.24.26
ALL_IPS=("$C0" "$C1" "$C2" "$P0" "$P1" "$P2")
declare -A HOSTNAME_OF=(
    [$C0]=overcloud-controller-0 [$C1]=overcloud-controller-1 [$C2]=overcloud-controller-2
    [$P0]=overcloud-computeiha-0 [$P1]=overcloud-computeiha-1 [$P2]=overcloud-computeiha-2
)

# Nilai palsu field sensitif di fixture inventory (tidak boleh bocor)
SECRET_TOKEN="FAKE-os-auth-token-9d1e7c"
SECRET_PW="FakeOvercloudAdminPw-4c7b2a"

SOS_EXACT="timeout --kill-after=120 3600 sudo sos report --batch --all-logs --threads=1"

for tool in jq tmux flock setsid ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || { echo "❌ $tool dibutuhkan untuk tes"; exit 1; }
done

cleanup() {
    "${TM[@]}" kill-server 2>/dev/null || true
    if [[ -n "${KEEP:-}" ]]; then
        echo "Direktori kerja disimpan: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

# Host key yang dibuat saat tes (format valid untuk ssh-keygen -F)
ssh-keygen -q -t ed25519 -N '' -f "$WORK/hostkey" >/dev/null
HOSTKEY_PUB="$(awk '{print $1 " " $2}' "$WORK/hostkey.pub")"

# ============================================================
# Helpers
# ============================================================

CURRENT=""

ok() {
    PASS=$(( PASS + 1 ))
    echo "  ✅ $1"
}

bad() {
    FAIL=$(( FAIL + 1 ))
    FAILED_TESTS+=("$CURRENT: $1")
    echo "  ❌ $1"
    [[ -n "${2:-}" ]] && printf '     %s\n' "$2"
    return 0
}

expect_eq() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "dapat: '$2'  harap: '$3'"; fi
}

expect_match() {
    if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "dapat: '${2:0:300}'  pola: '$3'"; fi
}

expect_no_match() {
    if [[ ! "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "pola tidak boleh muncul: '$3'"; fi
}

expect_true() {
    local desc="$1"
    shift
    if "$@"; then ok "$desc"; else bad "$desc"; fi
}

# Lingkungan bersih: 6 host (semua host key dikenal), cluster sehat,
# stonith-enabled=true, inventory di $WORK/stack/inventory.yaml
reset_state() {
    local ip
    "${TM[@]}" kill-server 2>/dev/null || true
    rm -rf "${WORK:?}/state" "${WORK:?}/log" "${WORK:?}/dest" "${WORK:?}/home" "${WORK:?}/stack"
    mkdir -p "$WORK/state/cluster" "$WORK/state/local_var_tmp" "$WORK/log" "$WORK/dest" \
        "$WORK/home/.ssh" "$WORK/stack"
    : > "$WORK/state/calls.log"
    : > "$WORK/home/.ssh/known_hosts"
    : > "$WORK/home/.ssh/id_rsa"
    for ip in "${ALL_IPS[@]}"; do
        mkdir -p "$WORK/state/hosts/$ip/var_tmp"
        echo "Red Hat OpenStack Platform release 17.1.4 (Wallaby)" > "$WORK/state/hosts/$ip/rhosp-release"
        echo "SOS_HOSTNAME=${HOSTNAME_OF[$ip]}" > "$WORK/state/hosts/$ip/env"
        printf '%s %s\n' "$ip" "$HOSTKEY_PUB" >> "$WORK/home/.ssh/known_hosts"
    done
    echo true > "$WORK/state/cluster/stonith"
    echo colon > "$WORK/state/cluster/format"
    cp "$FIX/pcs-status-nodes.txt" "$WORK/state/cluster/status-nodes"
    cp "$FIX/pcs-status.txt" "$WORK/state/cluster/status"
    cp "$FIX/inventory.yaml" "$FIX/inventory.yaml.json" "$WORK/stack/"
    echo "Red Hat OpenStack Platform release 17.1.4 (Wallaby)" > "$WORK/rhosp-release"
}

# host_env IP KEY=VALUE... — perilaku stub untuk host
host_env() {
    local ip="$1"
    shift
    printf '%s\n' "$@" >> "$WORK/state/hosts/$ip/env"
}

forget_hostkey() {
    local tmp="$WORK/home/.ssh/known_hosts.tmp"
    grep -v "^$1 " "$WORK/home/.ssh/known_hosts" > "$tmp" || true
    mv "$tmp" "$WORK/home/.ssh/known_hosts"
}

stonith() {
    cat "$WORK/state/cluster/stonith"
}

# run_tmux "ENV..." ARGS... — jalankan script di tmux (TMUX diset agar tidak
# ada peringatan tmux/screen, kecuali NO_TMUX=1)
run_tmux() {
    local envs="$1" cmd="" session="-u STY TMUX=cs-test"
    shift
    (( $# > 0 )) && printf -v cmd '%q ' "$@"
    [[ -n "${NO_TMUX:-}" ]] && session="-u TMUX -u STY"
    "${TM[@]}" kill-server 2>/dev/null || true
    "${TM[@]}" new-session -d -s t -x 230 -y 60 \
        "env $session HOME=$(printf '%q' "$WORK/home") STUB_STATE=$(printf '%q' "$WORK/state") \
STUB_HOSTKEY_PUB=$(printf '%q' "$HOSTKEY_PUB") STUB_SOS_DIR=$(printf '%q' "$WORK/state/local_var_tmp") \
OSOPS_SSH=$(printf '%q' "$STUB/ssh") OSOPS_SCP=$(printf '%q' "$STUB/scp") \
OSOPS_ANSIBLE_INVENTORY=$(printf '%q' "$STUB/ansible-inventory") OSOPS_FZF=$(printf '%q' "$STUB/fzf") \
OSOPS_RHOSP_RELEASE_FILE=$(printf '%q' "$WORK/rhosp-release") OSOPS_STACK_HOME=$(printf '%q' "$WORK/stack") \
OSOPS_SOS_LOCAL_DIR=$(printf '%q' "$WORK/state/local_var_tmp") OSOPS_LOG_DIR=$(printf '%q' "$WORK/log") \
OSOPS_SOS_PROGRESS_INTERVAL=1 PATH=$(printf '%q' "$STUB/local:$PATH") \
$envs bash $(printf '%q' "$SCRIPT") $cmd; echo __EXIT=\$?; sleep 3600"
}

screen_text() {
    "${TM[@]}" capture-pane -p -J -t t -S -5000 2>/dev/null
}

count_of() {
    screen_text | grep -cE -- "$1" || true
}

# wait_for PATTERN [N] [DETIK]
wait_for() {
    local pat="$1" n="${2:-1}" secs="${3:-30}" i
    for (( i = 0; i < secs * 5; i++ )); do
        (( $(count_of "$pat") >= n )) && return 0
        sleep 0.2
    done
    bad "timeout menunggu '$pat' (x$n)"
    screen_text | tail -n 20 | sed 's/^/     | /'
    return 1
}

keys() {
    "${TM[@]}" send-keys -t t "$@"
}

answer() {
    wait_for "$1" "$2" && keys "$3" Enter
}

tmux_exit() {
    wait_for '__EXIT=' 1 "${1:-60}" || { echo "?"; return 0; }
    screen_text | grep -o '__EXIT=[0-9]*' | tail -n 1 | cut -d= -f2
}

# start "ENV" ARGS... — run_tmux + jawab prompt user bukan 'stack' (jika ada)
# dan prompt Case ID (kosong, atau $CASE_ANSWER) jika --case-id tidak diberikan
start() {
    local a case_given=0
    for a in "$@"; do
        [[ "$a" == "--case-id" ]] && case_given=1
    done
    run_tmux "$@"
    if [[ "$(id -un)" != "stack" ]]; then
        answer 'Tetap lanjut sebagai' 1 y || return 1
    fi
    if (( ! case_given )); then
        answer 'Case ID Red Hat' 1 "${CASE_ANSWER:-}" || return 1
    fi
}

log_dir() {
    printf '%s' "$WORK/log/rhosp"
}

log_text() {
    cat "$WORK"/log/rhosp/collect-sosreport-*.log 2>/dev/null || true
}

report_file() {
    local f=("$WORK"/log/rhosp/collect-sosreport-*-results.tsv)
    [[ -f "${f[0]}" ]] && printf '%s' "${f[0]}"
}

# tsv COL HOST — 3=role 4=ip 5=rhosp_release 6=result 7=remote_file
#                8=local_file 9=size 10=sha256 11=duration 12=message
tsv() {
    local f
    f="$(report_file)" || return 0
    awk -F'\t' -v h="$2" -v col="$1" '$2 == h { print $col }' "$f"
}

calls() {
    cat "$WORK/state/calls.log"
}

# Nomor baris pertama di calls.log yang cocok (ERE), 0 jika tidak ada
call_line() {
    local n
    n="$(grep -nE -- "$1" "$WORK/state/calls.log" | head -n 1 | cut -d: -f1)"
    printf '%s' "${n:-0}"
}

last_call_line() {
    local n
    n="$(grep -nE -- "$1" "$WORK/state/calls.log" | tail -n 1 | cut -d: -f1)"
    printf '%s' "${n:-0}"
}

no_call() {
    ! grep -qE -- "$1" "$WORK/state/calls.log"
}

state_file() {
    printf '%s' "$WORK/log/rhosp/collect-sosreport-fencing.state"
}

want() {
    [[ -z "$FILTER" || "$1" == *"$FILTER"* ]]
}

begin() {
    CURRENT="$1"
    echo
    echo "▶ $1"
    reset_state
}

# ============================================================
# Tes
# ============================================================

# Controller + compute Instance HA, stonith true → disable, fase, restore
test_fencing_basic() {
    local rc ln_restore ln_scp ln_sos_last ln_rest
    begin "fencing_basic"

    start "" --node overcloud-controller-0 --node overcloud-computeiha-0 --dest "$WORK/dest" || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 2 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    answer 'Hapus file sosreport di 2 node' 1 n || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 0" "$rc" "0"
    expect_eq "controller SUCCESS" "$(tsv 6 overcloud-controller-0)" "SUCCESS"
    expect_eq "compute (remote node) SUCCESS" "$(tsv 6 overcloud-computeiha-0)" "SUCCESS"
    expect_eq "stonith kembali true" "$(stonith)" "true"
    expect_true "fencing di-disable (set false)" grep -q $'pcs\t.*\tproperty set stonith-enabled=false' "$WORK/state/calls.log"
    expect_true "state file dihapus setelah pulih" test ! -e "$(state_file)"

    ln_restore="$(call_line $'pcs\t.*property set stonith-enabled=true')"
    ln_scp="$(call_line $'^scp\t')"
    ln_sos_last="$(last_call_line $'^sos\t')"
    expect_true "restore setelah sosreport node cluster terakhir" test "$ln_restore" -gt "$ln_sos_last"
    expect_true "restore sebelum scp pertama" test "$ln_restore" -lt "$ln_scp"

    expect_match "log disable-fencing SUCCESS" "$(log_text)" 'RESULT resource=tripleo_cluster action=disable-fencing result=SUCCESS'
    expect_match "log enable-fencing SUCCESS" "$(log_text)" 'RESULT resource=tripleo_cluster action=enable-fencing result=SUCCESS'
    expect_match "log sos-report per node" "$(log_text)" 'RESULT resource=overcloud-computeiha-0 action=sos-report result=SUCCESS role=ComputeInstanceHA'
    expect_match "ringkasan: dipulihkan" "$(screen_text)" 'Sudah dipulihkan ke nilai awal \(true\)'
    ln_rest="$(call_line "^ssh"$'\t'"$P0"$'\t'"yes"$'\t'"$SOS_EXACT\$")"
    expect_true "perintah sosreport persis (tanpa --case-id)" test "$ln_rest" -gt 0
    expect_true "binary sosreport (stub RHEL 9: deprecated, exit 1) tidak dipakai" no_call $'^sosreport\t'
    expect_eq "permission 600 di --dest" "$(stat -c %a "$(tsv 8 overcloud-computeiha-0)")" "600"
    expect_eq "file .sha256 juga 600" "$(stat -c %a "$(tsv 8 overcloud-computeiha-0).sha256")" "600"
    expect_eq "file laporan 600" "$(stat -c %a "$(report_file)")" "600"
    expect_true "file remote tetap ada (cleanup ditolak)" test -f "$WORK/state/hosts/$P0/var_tmp/$(basename "$(tsv 7 overcloud-computeiha-0)")"
}

# Cluster tanpa Instance HA: compute bukan remote node
no_instance_ha() {
    cat > "$WORK/state/cluster/status-nodes" <<'EOF'
Pacemaker Nodes:
 Online: overcloud-controller-0 overcloud-controller-1 overcloud-controller-2
 Standby:
 Maintenance:
 Offline:
Pacemaker Remote Nodes:
 Online: galera-bundle-0 galera-bundle-1 galera-bundle-2 rabbitmq-bundle-0 redis-bundle-0
 Standby:
 Maintenance:
 Offline:
EOF
}

test_release() {
    local rc
    begin "release_missing"
    rm -f "$WORK/rhosp-release"
    run_tmux "" --dry-run
    rc="$(tmux_exit)"
    expect_eq "exit code 1" "$rc" "1"
    expect_match "pesan hanya untuk undercloud RHOSP" "$(screen_text)" 'hanya untuk undercloud RHOSP'
    expect_true "ansible-inventory tidak dipanggil" no_call '^ansible-inventory'

    begin "release_other_cancel"
    echo "Red Hat OpenStack Platform release 16.2.6 (Train)" > "$WORK/rhosp-release"
    run_tmux "" --dry-run
    answer 'Tetap lanjut di versi ini' 1 n || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "peringatan versi" "$(screen_text)" 'dirancang untuk RHOSP 17.1'
    expect_true "tidak lanjut (tanpa inventory)" no_call '^ansible-inventory'

    begin "release_other_continue"
    echo "Red Hat OpenStack Platform release 16.2.6 (Train)" > "$WORK/rhosp-release"
    run_tmux "" --dry-run --include-undercloud
    answer 'Tetap lanjut di versi ini' 1 y || return 0
    [[ "$(id -un)" != stack ]] && { answer 'Tetap lanjut sebagai' 1 y || return 0; }
    answer 'Case ID Red Hat' 1 "" || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "lanjut setelah konfirmasi" "$(log_text)" 'DECISION release_mismatch=continue'
}

test_inventory_search() {
    local rc ocd="$WORK/stack/overcloud-deploy"

    begin "inventory_option"
    mkdir -p "$WORK/other"
    cp "$FIX/inventory.yaml" "$FIX/inventory.yaml.json" "$WORK/other/"
    start "" --inventory "$WORK/other/inventory.yaml" --dry-run --include-undercloud || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "--inventory dipakai" "$(log_text)" "INPUT inventory=$WORK/other/inventory.yaml source=option"

    begin "inventory_default"
    start "" --dry-run --include-undercloud || return 0
    rc="$(tmux_exit)"
    expect_match "default /home/stack/inventory.yaml" "$(log_text)" "INPUT inventory=$WORK/stack/inventory.yaml source=default"

    begin "inventory_one_stack"
    mkdir -p "$ocd/overcloud"
    mv "$WORK/stack/inventory.yaml" "$ocd/overcloud/tripleo-ansible-inventory.yaml"
    mv "$WORK/stack/inventory.yaml.json" "$ocd/overcloud/tripleo-ansible-inventory.yaml.json"
    start "" --dry-run --include-undercloud || return 0
    rc="$(tmux_exit)"
    expect_match "satu stack dipakai tanpa prompt" "$(log_text)" "inventory=$ocd/overcloud/tripleo-ansible-inventory.yaml source=stack"

    begin "inventory_multi_stack"
    rm -f "$WORK/stack/inventory.yaml" "$WORK/stack/inventory.yaml.json"
    for s in overcloud cell1; do
        mkdir -p "$ocd/$s"
        cp "$FIX/inventory.yaml" "$ocd/$s/tripleo-ansible-inventory.yaml"
        cp "$FIX/inventory.yaml.json" "$ocd/$s/tripleo-ansible-inventory.yaml.json"
    done
    start "" --dry-run --include-undercloud || return 0
    wait_for '2\) overcloud' 1 || return 0
    expect_match "pilihan nama stack" "$(screen_text)" '1\) cell1'
    keys 2 Enter
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "stack terpilih" "$(log_text)" "inventory=$ocd/overcloud/tripleo-ansible-inventory.yaml source=stack"

    begin "inventory_none"
    rm -f "$WORK/stack/inventory.yaml" "$WORK/stack/inventory.yaml.json"
    start "" --dry-run --include-undercloud || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 1" "$rc" "1"
    expect_match "menyebut path default" "$(screen_text)" "$WORK/stack/inventory.yaml"
    expect_match "menyebut pola overcloud-deploy" "$(screen_text)" 'overcloud-deploy/\*/tripleo-ansible-inventory.yaml'
}

test_inventory_parse() {
    local rc all
    begin "inventory_parse"
    start "STUB_FZF_SELECT='^role:Controller;^uc'" --dry-run || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "role Controller terbaca" "$(log_text)" 'NODE host=overcloud-controller-0 role=Controller ip=192.168.24.21 user=tripleo-admin'
    expect_match "role ComputeInstanceHA + pacemaker_remote" "$(log_text)" 'NODE host=overcloud-computeiha-2 role=ComputeInstanceHA ip=192.168.24.26 user=tripleo-admin key=[^ ]*/home/.ssh/id_rsa port=- pacemaker=0 pacemaker_remote=1'
    expect_match "6 node overcloud, undercloud dari nama grup" "$(log_text)" 'INVENTORY .* nodes=6 pacemaker=3 pacemaker_remote=3 invalid=0 undercloud=undercloud'
    expect_no_match "undercloud bukan node SSH" "$(log_text)" 'NODE host=undercloud'
    expect_no_match "key grup Undercloud tidak terwarisi" "$(log_text)" '/var/lib/mistral'
    expect_match "picker: entry semua Controller" "$(cat "$WORK/state/fzf.in")" $'role:Controller\t\\[semua Controller\\] \\(3 node\\)'
    expect_match "picker: entry semua ComputeInstanceHA" "$(cat "$WORK/state/fzf.in")" '\[semua ComputeInstanceHA\] \(3 node\)'
    expect_match "picker: entry Undercloud (lokal)" "$(cat "$WORK/state/fzf.in")" $'uc\tUndercloud \\(lokal\\)'
    expect_match "picker: kolom hostname role ip" "$(cat "$WORK/state/fzf.in")" 'overcloud-computeiha-1 +ComputeInstanceHA +192.168.24.25'
    expect_match "pilihan role + undercloud" "$(log_text)" 'SELECT selected=4 nodes=overcloud-controller-0,overcloud-controller-1,overcloud-controller-2,undercloud'

    all="$(screen_text; cat "$WORK"/log/rhosp/* "$WORK/state/calls.log" "$WORK/state/fzf.in" 2>/dev/null)"
    expect_no_match "os_auth_token palsu tidak bocor" "$all" "$SECRET_TOKEN"
    expect_no_match "overcloud_admin_password palsu tidak bocor" "$all" "$SECRET_PW"
    expect_no_match "hostvars tidak di-log (deploy_server_id)" "$all" '00000000-0000-4000-8000-000000000001'
}

test_picker() {
    local rc
    begin "picker_menu"
    start "OSOPS_FZF=$WORK/no-such-fzf" --dry-run || return 0
    answer 'Nomor \(mis' 1 "x9" || return 0
    answer 'Nomor \(mis' 2 "2 4" || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "input tidak valid ditolak" "$(screen_text)" 'Input tidak valid: x9'
    expect_match "menu bernomor: role + node" "$(log_text)" 'SELECT selected=4 nodes=overcloud-controller-0,overcloud-controller-1,overcloud-controller-2,overcloud-computeiha-0'

    begin "unknown_node_role"
    start "" --dry-run --node bogus-node --role NoSuchRole --node OVERCLOUD-COMPUTEIHA-1 || return 0
    rc="$(tmux_exit)"
    expect_match "node tidak dikenal dilewati" "$(screen_text)" 'Node tidak dikenal di inventory, dilewati: bogus-node'
    expect_match "role tidak dikenal dilewati" "$(screen_text)" 'Role tidak dikenal di inventory, dilewati: NoSuchRole'
    expect_match "node valid (case-insensitive) tetap dipilih" "$(log_text)" 'SELECT selected=1 nodes=overcloud-computeiha-1'
}

test_hostkeys() {
    local rc
    begin "hostkey_accept"
    forget_hostkey "$P0"
    start "" --dry-run --node overcloud-computeiha-0 || return 0
    answer 'Terima host key baru untuk 1 host' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "daftar host belum dikenal" "$(screen_text)" 'overcloud-computeiha-0 +192.168.24.24'
    expect_true "host baru: accept-new" grep -qE "^ssh"$'\t'"$P0"$'\t'"accept-new" "$WORK/state/calls.log"
    expect_true "host dikenal: yes" grep -qE "^ssh"$'\t'"$C0"$'\t'"yes" "$WORK/state/calls.log"
    expect_match "host key diterima dicatat (fingerprint)" "$(log_text)" 'HOSTKEY_ACCEPTED host=overcloud-computeiha-0 ip=192.168.24.24 fingerprint=SHA256:[A-Za-z0-9+/]+/ED25519'

    begin "hostkey_reject_and_changed"
    forget_hostkey "$P0"
    host_env "$P1" HOSTKEY_CHANGED=1
    start "" --dry-run --node overcloud-computeiha-0 --node overcloud-computeiha-1 --node overcloud-computeiha-2 || return 0
    answer 'Terima host key baru untuk 1 host' 1 n || return 0
    rc="$(tmux_exit)"
    expect_match "ditolak -> SKIPPED (host key unknown)" "$(screen_text)" 'overcloud-computeiha-0 .*SKIPPED \(host key unknown\)'
    expect_match "berubah -> SKIPPED (host key mismatch)" "$(screen_text)" 'overcloud-computeiha-1 .*SKIPPED \(host key mismatch\)'
    expect_true "host ditolak tidak dihubungi" no_call "^ssh"$'\t'"$P0"
    expect_true "known_hosts tidak ditimpa untuk host ditolak" sh -c "! grep -q '^$P0 ' '$WORK/home/.ssh/known_hosts'"
}

test_precheck() {
    local rc
    begin "precheck_failures"
    host_env "$P0" UNREACHABLE=1
    host_env "$P1" SUDO_FAIL=1
    host_env "$P2" STUB_FREE_KB=3145728
    host_env "$C1" STUB_FREE_KB=524288
    host_env "$C2" SOS_MISSING=1
    echo "Red Hat OpenStack Platform release 17.1.3 (Wallaby)" > "$WORK/state/hosts/$C0/rhosp-release"
    start "" --role Controller --role ComputeInstanceHA --dest "$WORK/dest" || return 0
    answer 'overcloud-computeiha-2: ruang kosong 3.0 GiB' 1 n || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    answer 'Hapus file sosreport di 1 node' 1 n || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_eq "tidak terjangkau" "$(tsv 6 overcloud-computeiha-0)/$(tsv 12 overcloud-computeiha-0)" "SKIPPED/unreachable"
    expect_eq "sudo gagal" "$(tsv 6 overcloud-computeiha-1)/$(tsv 12 overcloud-computeiha-1)" "SKIPPED/sudo failed"
    expect_eq "disk < 5 GiB, ditolak" "$(tsv 6 overcloud-computeiha-2)/$(tsv 12 overcloud-computeiha-2)" "SKIPPED/insufficient disk"
    expect_eq "disk < 1 GiB, langsung" "$(tsv 6 overcloud-controller-1)/$(tsv 12 overcloud-controller-1)" "SKIPPED/insufficient disk"
    expect_eq "sos tidak ada" "$(tsv 6 overcloud-controller-2)/$(tsv 12 overcloud-controller-2)" "SKIPPED/sos not found"
    expect_eq "node sehat tetap dikumpulkan" "$(tsv 6 overcloud-controller-0)" "SUCCESS"
    expect_match "versi node berbeda -> peringatan" "$(log_text)" 'WARN .*overcloud-controller-0: rhosp-release berbeda dengan undercloud'
    expect_true "< 1 GiB tidak ditanya" sh -c "! tmux -L cs-test-$$ capture-pane -p -J -t t -S -5000 | grep -q 'overcloud-controller-1: ruang kosong'"
    expect_true "sosreport tidak dijalankan di node SKIPPED" no_call $'^sos\t'"$P1"
    expect_match "ringkasan memuat alasan" "$(screen_text)" 'overcloud-computeiha-1 +ComputeInstanceHA .*SKIPPED .*sudo failed'
}

test_case_id() {
    local rc
    begin "case_id"
    no_instance_ha
    start "" --node overcloud-computeiha-0 --case-id 04123456 --dest "$WORK/dest" --keep-remote || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_true "perintah persis + --case-id" grep -qxF "ssh"$'\t'"$P0"$'\t'"yes"$'\t'"$SOS_EXACT --case-id 04123456" "$WORK/state/calls.log"
    expect_match "case-id di nama arsip" "$(tsv 8 overcloud-computeiha-0)" '^/[^ ]*/sosreport-overcloud-computeiha-0-04123456-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{7}\.tar\.xz$'
    expect_true "--keep-remote: tidak ditanya hapus" sh -c "! tmux -L cs-test-$$ capture-pane -p -J -t t -S -5000 | grep -q 'Hapus file sosreport'"

    begin "case_id_prompt"
    run_tmux "" --node overcloud-controller-2 --dest "$WORK/dest" --keep-remote
    [[ "$(id -un)" != stack ]] && { answer 'Tetap lanjut sebagai' 1 y || return 0; }
    answer 'Case ID Red Hat' 1 "04 123" || return 0
    answer 'Case ID Red Hat' 2 " 04123456 " || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "case id tidak valid ditanya ulang" "$(screen_text)" 'Case ID hanya boleh huruf'
    expect_match "case id dari prompt dicatat" "$(log_text)" 'DECISION case_id=04123456 source=prompt'
    expect_match "rencana memuat --case-id" "$(screen_text)" "Perintah +: $SOS_EXACT --case-id 04123456"
    expect_true "perintah persis + --case-id dari prompt" grep -qxF "ssh"$'\t'"$C2"$'\t'"yes"$'\t'"$SOS_EXACT --case-id 04123456" "$WORK/state/calls.log"
    expect_match "format nama arsip di node" "$(tsv 7 overcloud-controller-2)" '^/var/tmp/sosreport-overcloud-controller-2-04123456-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{7}\.tar\.xz$'
    expect_true "chown ke tripleo-admin sebelum scp" test "$(call_line "^ssh"$'\t'"$C2"$'\t.*sudo chown tripleo-admin:tripleo-admin -- /var/tmp/sosreport-overcloud-controller-2-04123456-')" -lt "$(call_line $'^scp\t'"$C2"$'\t/var/tmp/sosreport-overcloud-controller-2-04123456-')"
    expect_eq "nama sama di undercloud" "$(basename "$(tsv 8 overcloud-controller-2)")" "$(basename "$(tsv 7 overcloud-controller-2)")"
    expect_eq "SUCCESS" "$(tsv 6 overcloud-controller-2)" "SUCCESS"

    begin "case_id_invalid"
    run_tmux "" --case-id 'a;rm -rf /' --dry-run
    rc="$(tmux_exit)"
    expect_eq "exit code 1" "$rc" "1"
    expect_match "case-id ditolak" "$(screen_text)" 'case-id hanya boleh'
}

test_locate() {
    local rc
    begin "locate"
    no_instance_ha
    head -c 100 /dev/urandom > "$WORK/state/hosts/$P0/var_tmp/sosreport-old-2026-01-01-aaaaaaa.tar.xz"
    touch -d '-2 hours' "$WORK/state/hosts/$P0/var_tmp/sosreport-old-2026-01-01-aaaaaaa.tar.xz"
    head -c 100 /dev/urandom > "$WORK/state/hosts/$P1/var_tmp/sosreport-old-2026-01-01-bbbbbbb.tar.xz"
    touch -d '-2 hours' "$WORK/state/hosts/$P1/var_tmp/sosreport-old-2026-01-01-bbbbbbb.tar.xz"
    host_env "$P0" SOS_MODE=noparse
    host_env "$P1" SOS_MODE=none
    host_env "$P2" SOS_NO_SHAFILE=1
    start "SOS_NO_SHAFILE=1 SOS_NO_HASHLINE=1" --role ComputeInstanceHA --include-undercloud --dest "$WORK/dest" || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 4 node' 1 y || return 0
    answer 'Hapus file sosreport di 3 node' 1 n || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_eq "fallback find: SUCCESS" "$(tsv 6 overcloud-computeiha-0)" "SUCCESS"
    expect_match "fallback: file lama tidak terpilih" "$(tsv 7 overcloud-computeiha-0)" '^/var/tmp/sosreport-overcloud-computeiha-0-'
    expect_match "metode fallback dicatat" "$(log_text)" 'LOCATE host=overcloud-computeiha-0 file=/var/tmp/sosreport-overcloud-computeiha-0-[^ ]* method=fallback'
    expect_true "fallback memakai -newermt epoch pre-check" grep -qE "^ssh"$'\t'"$P0"$'\t'"yes"$'\t'"sudo find /var/tmp -maxdepth 1 -type f -name 'sosreport-\*\.tar\.xz' -newermt @[0-9]+ " "$WORK/state/calls.log"
    expect_eq "tidak ditemukan (file lama diabaikan)" "$(tsv 6 overcloud-computeiha-1)/$(tsv 12 overcloud-computeiha-1)" "FAILED/report file not found"
    expect_match "metode parse dicatat" "$(log_text)" 'LOCATE host=overcloud-computeiha-2 .* method=parse'
    expect_match "checksum dari output (tanpa .sha256)" "$(log_text)" 'CHECKSUM host=overcloud-computeiha-2 method=output'
    expect_eq "checksum output: SUCCESS" "$(tsv 6 overcloud-computeiha-2)" "SUCCESS"
    expect_match "checksum dihitung di node (lokal: undercloud)" "$(log_text)" 'CHECKSUM host=undercloud method=computed'
    expect_eq "undercloud SUCCESS" "$(tsv 6 undercloud)" "SUCCESS"
}

test_copy() {
    local rc lf
    begin "copy_collision_chown"
    no_instance_ha
    host_env "$P0" SOS_NAME=sosreport-fixed-2026-11-03-abcdefg.tar.xz
    echo OLD > "$WORK/dest/sosreport-fixed-2026-11-03-abcdefg.tar.xz"
    start "" --node overcloud-computeiha-0 --dest "$WORK/dest" || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer 'Hapus file sosreport di 1 node' 1 n || return 0
    rc="$(tmux_exit)"
    lf="$(tsv 8 overcloud-computeiha-0)"
    expect_eq "SUCCESS" "$(tsv 6 overcloud-computeiha-0)" "SUCCESS"
    expect_match "nama bentrok: suffix run_id" "$lf" "/sosreport-fixed-2026-11-03-abcdefg-[0-9]{8}T[0-9]{6}-[0-9]+-[0-9a-f]{4}\.tar\.xz$"
    expect_eq "file lama tidak ditimpa" "$(cat "$WORK/dest/sosreport-fixed-2026-11-03-abcdefg.tar.xz")" "OLD"
    expect_match "peringatan bentrok di log" "$(log_text)" 'WARN .*sudah ada, disimpan sebagai'
    expect_eq "permission 600" "$(stat -c %a "$lf")" "600"
    expect_true "chown di node sebelum scp" test "$(call_line "^ssh"$'\t'"$P0"$'\t.*sudo chown tripleo-admin:tripleo-admin -- ')" -lt "$(call_line $'^scp\t'"$P0")"
    expect_true "chown arsip dan .sha256" grep -qE "^ssh"$'\t'"$P0"$'\t'".*sudo chown tripleo-admin:tripleo-admin -- /var/tmp/sosreport-fixed-2026-11-03-abcdefg.tar.xz /var/tmp/sosreport-fixed-2026-11-03-abcdefg.tar.xz.sha256$" "$WORK/state/calls.log"

    begin "checksum_mismatch_cleanup"
    no_instance_ha
    host_env "$P0" SCP_CORRUPT=1
    start "" --node overcloud-computeiha-0 --node overcloud-computeiha-1 --dest "$WORK/dest" || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 2 node' 1 y || return 0
    answer 'Hapus file sosreport di 1 node' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "checksum tidak cocok -> FAILED" "$(tsv 6 overcloud-computeiha-0)/$(tsv 12 overcloud-computeiha-0)" "FAILED/checksum mismatch"
    expect_eq "checksum cocok -> SUCCESS" "$(tsv 6 overcloud-computeiha-1)/$(tsv 12 overcloud-computeiha-1)" "SUCCESS/checksum ok"
    expect_true "file remote node gagal TIDAK dihapus" test -f "$WORK/state/hosts/$P0/var_tmp/$(basename "$(tsv 7 overcloud-computeiha-0)")"
    expect_true "file remote node sukses dihapus" test ! -e "$WORK/state/hosts/$P1/var_tmp/$(basename "$(tsv 7 overcloud-computeiha-1)")"
    expect_true "hapus remote tanpa sudo" grep -qE "^ssh"$'\t'"$P1"$'\t'"yes"$'\t'"rm -f -- /var/tmp/sosreport-" "$WORK/state/calls.log"
    expect_true "tidak ada sudo rm" no_call $'^sudo\t.*\trm '
    expect_match "ringkasan: file di node tetap ada" "$(screen_text)" 'file di node tetap ada: /var/tmp/sosreport-overcloud-computeiha-0-'
}

test_cluster_membership() {
    local rc
    begin "compute_without_instance_ha"
    no_instance_ha
    start "" --node overcloud-computeiha-0 --dest "$WORK/dest" --keep-remote || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_eq "SUCCESS" "$(tsv 6 overcloud-computeiha-0)" "SUCCESS"
    expect_true "fencing tidak disentuh (tanpa property set/unset)" no_call $'^pcs\t.*\tproperty (set|unset)'
    expect_match "info: tidak ada anggota cluster" "$(screen_text)" 'fencing tidak disentuh'
    expect_eq "stonith tetap true" "$(stonith)" "true"

    begin "undercloud_only"
    start "" --include-undercloud --dest "$WORK/dest" || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer 'Hapus file sosreport di 1 node' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "undercloud lokal SUCCESS" "$(tsv 6 undercloud)" "SUCCESS"
    expect_true "tanpa ssh sama sekali" no_call $'^ssh\t'
    expect_true "sos report lokal persis" grep -qxF "sos"$'\t'"local"$'\t'"report --batch --all-logs --threads=1" "$WORK/state/calls.log"
    expect_true "sudo chown lokal ke user sendiri" grep -qE $'^sudo\tlocal\tchown '"$(id -un):$(id -gn) -- " "$WORK/state/calls.log"
    expect_eq "permission 600" "$(stat -c %a "$(tsv 8 undercloud)")" "600"
    expect_true "file lokal di /var/tmp dihapus setelah disalin" test -z "$(ls "$WORK/state/local_var_tmp")"

    begin "name_matching_and_bundles"
    jq '
        def ren($a; $b): ._meta.hostvars[$b] = ._meta.hostvars[$a] | del(._meta.hostvars[$a])
            | .ComputeInstanceHA.hosts |= map(if . == $a then $b else . end);
        ren("overcloud-computeiha-0"; "c0-alias")
        | ren("overcloud-computeiha-1"; "c1-alias")
        | ._meta.hostvars["c1-alias"].ansible_host = "overcloud-computeiha-1.ctlplane.example.com"
        | del(._meta.hostvars["c1-alias"].canonical_hostname)
    ' "$FIX/inventory.yaml.json" > "$WORK/stack/inv2.yaml.json"
    cp "$FIX/inventory.yaml" "$WORK/stack/inv2.yaml"
    mkdir -p "$WORK/state/hosts/overcloud-computeiha-1.ctlplane.example.com/var_tmp"
    cp "$WORK/state/hosts/$P1/rhosp-release" "$WORK/state/hosts/overcloud-computeiha-1.ctlplane.example.com/"
    printf '%s %s\n' "overcloud-computeiha-1.ctlplane.example.com" "$HOSTKEY_PUB" >> "$WORK/home/.ssh/known_hosts"
    sed -i 's/ overcloud-computeiha-1 / OVERCLOUD-COMPUTEIHA-1.example.com /' "$WORK/state/cluster/status-nodes"
    start "" --inventory "$WORK/stack/inv2.yaml" --dry-run --node c0-alias --node c1-alias || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "cocok via canonical_hostname" "$(log_text)" 'CLUSTER known=1 .*members="[^"]*c0-alias\(remote\)'
    expect_match "cocok via ansible_host (case-insensitive)" "$(log_text)" 'members="[^"]*c1-alias\(remote\)'
    expect_match "guest bundle diabaikan" "$(log_text)" 'ignored="galera-bundle-0 galera-bundle-1 galera-bundle-2 rabbitmq-bundle-0'
    expect_no_match "bundle bukan anggota" "$(log_text | grep 'CLUSTER known')" 'members="[^"]*bundle'
    expect_match "rencana: anggota cluster remote" "$(screen_text)" 'c0-alias .*AKAN DIKUMPULKAN \(anggota cluster: remote\)'
}

test_cluster_unknown() {
    local rc
    begin "cluster_unknown"
    host_env "$C0" PCS_FAIL=1
    host_env "$C1" PCS_FAIL=1
    host_env "$C2" UNREACHABLE=1
    start "" --node overcloud-computeiha-0 --include-undercloud --dest "$WORK/dest" || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer 'Hapus file sosreport di 1 node' 1 n || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_eq "pacemaker_remote -> SKIPPED" "$(tsv 6 overcloud-computeiha-0)/$(tsv 12 overcloud-computeiha-0)" "SKIPPED/cluster status unknown"
    expect_eq "node lain tetap jalan" "$(tsv 6 undercloud)" "SUCCESS"
    expect_true "controller dicoba berurutan" test "$(call_line $'^pcs\t'"$C1"$'\tstatus nodes')" -gt "$(call_line $'^pcs\t'"$C0"$'\tstatus nodes')"
    expect_true "tidak ada property set" no_call $'\tproperty set'
}

test_cluster_unhealthy() {
    local rc
    begin "cluster_unhealthy"
    sed -i '0,/ Offline:/s/ Offline:/ Offline: overcloud-controller-2/' "$WORK/state/cluster/status-nodes"
    printf '\nFailed Resource Actions:\n  * rabbitmq_monitor_10000 on rabbitmq-bundle-1 '\''not running'\'' (7): call=88, status='\''complete'\''\n' >> "$WORK/state/cluster/status"
    start "" --node overcloud-computeiha-0 --include-undercloud --dest "$WORK/dest" --keep-remote || return 0
    answer 'Tetap lanjut mengumpulkan dari node cluster' 1 n || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    rc="$(tmux_exit)"
    expect_match "ringkasan kesehatan: offline" "$(screen_text)" 'node offline: overcloud-controller-2'
    expect_match "ringkasan kesehatan: failed actions" "$(screen_text)" 'failed resource actions: 1'
    expect_eq "node cluster DECLINED" "$(tsv 6 overcloud-computeiha-0)/$(tsv 12 overcloud-computeiha-0)" "DECLINED/cluster unhealthy"
    expect_eq "undercloud tetap" "$(tsv 6 undercloud)" "SUCCESS"
    expect_true "fencing tidak disentuh" no_call $'\tproperty set'
}

test_pcs_parser() {
    local rc
    begin "pcs_equals_false"
    echo equals > "$WORK/state/cluster/format"
    echo false > "$WORK/state/cluster/stonith"
    start "" --dry-run --node overcloud-computeiha-0 || return 0
    rc="$(tmux_exit)"
    expect_match "format '=' terbaca false" "$(log_text)" 'FENCING action=read controller=overcloud-controller-0 value=false'

    begin "pcs_fallback_config"
    host_env "$C0" PCS_NO_PROPCONFIG=1
    start "" --dry-run --node overcloud-computeiha-0 || return 0
    rc="$(tmux_exit)"
    expect_true "fallback pcs config dipanggil" grep -qE $'^pcs\t'"$C0"$'\tconfig$' "$WORK/state/calls.log"
    expect_match "nilai dari pcs config" "$(log_text)" 'FENCING action=read controller=overcloud-controller-0 value=true'

    begin "pcs_unset_restore_unset"
    echo unset > "$WORK/state/cluster/stonith"
    start "" --node overcloud-computeiha-0 --dest "$WORK/dest" --keep-remote || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    rc="$(tmux_exit)"
    expect_match "header saja -> unset (efektif true)" "$(screen_text)" 'stonith-enabled: unset \(tidak diset, efektif true\)'
    expect_true "dipulihkan dengan unset" grep -qE $'^pcs\t.*\tproperty unset stonith-enabled$' "$WORK/state/calls.log"
    expect_true "tanpa set true" no_call $'\tproperty set stonith-enabled=true'
    expect_eq "stonith kembali unset" "$(stonith)" "unset"
    expect_match "state file mencatat original=unset" "$(log_text)" 'STATE_FILE action=write .* original=unset'

    begin "pcs_unset_fallback_set_true"
    echo unset > "$WORK/state/cluster/stonith"
    host_env "$C0" PCS_UNSET_FAIL=1
    start "" --node overcloud-computeiha-0 --dest "$WORK/dest" --keep-remote || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    rc="$(tmux_exit)"
    expect_true "unset dicoba dulu" grep -qE $'^pcs\t'"$C0"$'\tproperty unset' "$WORK/state/calls.log"
    expect_true "fallback set true" grep -qE $'^pcs\t'"$C0"$'\tproperty set stonith-enabled=true' "$WORK/state/calls.log"
    expect_eq "stonith efektif true" "$(stonith)" "true"
    expect_true "state file dihapus" test ! -e "$(state_file)"
}

test_already_false() {
    local rc
    begin "already_false"
    echo false > "$WORK/state/cluster/stonith"
    start "" --node overcloud-computeiha-0 --node overcloud-controller-1 --dest "$WORK/dest" --keep-remote || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 2 node' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "peringatan menonjol" "$(screen_text)" 'FENCING SUDAH MATI \(stonith-enabled=false\) SEBELUM SCRIPT DIJALANKAN'
    expect_match "dampak Instance HA" "$(screen_text)" 'Instance HA: selama fencing mati, VM dari compute yang gagal TIDAK dapat dievakuasi'
    expect_match "perintah manual" "$(screen_text)" 'sudo pcs property set stonith-enabled=true'
    expect_true "tidak ditanya disable" sh -c "! tmux -L cs-test-$$ capture-pane -p -J -t t -S -5000 | grep -q \"Ketik 'yes'\""
    expect_true "fencing tidak pernah disentuh" no_call $'\tproperty (set|unset)'
    expect_eq "stonith tetap false" "$(stonith)" "false"
    expect_match "log_warn" "$(log_text)" 'WARN .*stonith-enabled sudah false sebelum script dijalankan'
    expect_match "ringkasan: tidak diaktifkan kembali" "$(screen_text)" 'TIDAK diaktifkan kembali'
    expect_true "tanpa state file" test ! -e "$(state_file)"
    expect_eq "node tetap dikumpulkan" "$(tsv 6 overcloud-computeiha-0)/$(tsv 6 overcloud-controller-1)" "SUCCESS/SUCCESS"
}

test_phase_order() {
    local rc
    begin "phase_order_and_error_mid_way"
    host_env "$P1" SOS_MODE=fail
    start "" --node overcloud-computeiha-0 --node overcloud-computeiha-1 --include-undercloud --dest "$WORK/dest" --keep-remote || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 3 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_eq "node cluster gagal di tengah -> FAILED" "$(tsv 6 overcloud-computeiha-1)/$(tsv 12 overcloud-computeiha-1)" "FAILED/sosreport failed (rc=1)"
    expect_eq "stonith tetap dipulihkan" "$(stonith)" "true"
    expect_true "undercloud (non-cluster) setelah pemulihan" test "$(call_line $'^sos\tlocal')" -gt "$(call_line $'^pcs\t.*\tproperty set stonith-enabled=true')"
    expect_true "sosreport cluster sebelum pemulihan" test "$(last_call_line $'^sos\t172')" -lt "$(call_line $'^pcs\t.*\tproperty set stonith-enabled=true')"
}

test_disable_verify_fail() {
    local rc
    begin "disable_verify_fail"
    host_env "$C0" PCS_SET_NOOP=1
    start "" --node overcloud-computeiha-0 --include-undercloud --dest "$WORK/dest" --keep-remote || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 2 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_eq "node cluster ABORTED" "$(tsv 6 overcloud-computeiha-0)/$(tsv 12 overcloud-computeiha-0)" "ABORTED/fencing disable failed"
    expect_true "tanpa sosreport di node cluster" no_call $'^sos\t'"$P0"
    expect_match "disable-fencing FAILED" "$(log_text)" 'action=disable-fencing result=FAILED'
    expect_eq "node non-cluster tetap jalan" "$(tsv 6 undercloud)" "SUCCESS"
    expect_eq "stonith true" "$(stonith)" "true"
    expect_true "state file dihapus (dipulihkan)" test ! -e "$(state_file)"
}

test_parallel() {
    local rc txt first_done second_start
    begin "parallel"
    no_instance_ha
    host_env "$P0" SOS_SLEEP=3
    host_env "$P1" SOS_SLEEP=3
    host_env "$P2" SOS_SLEEP=3
    start "" --role ComputeInstanceHA --parallel 2 --dest "$WORK/dest" --keep-remote || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 3 node' 1 y || return 0
    rc="$(tmux_exit 60)"
    txt="$(screen_text)"
    second_start="$(grep -n 'overcloud-computeiha-1: mulai' <<< "$txt" | head -n 1 | cut -d: -f1)"
    first_done="$(grep -n '✅ overcloud-computeiha-' <<< "$txt" | head -n 1 | cut -d: -f1)"
    expect_true "2 node berjalan bersamaan" test "${second_start:-999}" -lt "${first_done:-0}"
    expect_match "progres per node (status, elapsed)" "$txt" '⏳ overcloud-computeiha-[01] +sosreport berjalan +00:0[0-9]'
    expect_eq "semua SUCCESS" "$(tsv 6 overcloud-computeiha-0)/$(tsv 6 overcloud-computeiha-1)/$(tsv 6 overcloud-computeiha-2)" "SUCCESS/SUCCESS/SUCCESS"
}

script_pid() {
    sed -n 's/^pid=\([0-9]*\).*/\1/p' "$WORK/log/rhosp/collect-sosreport.lock" 2>/dev/null
}

test_interrupt() {
    local rc
    begin "sigint"
    host_env "$C0" SOS_SLEEP=37
    start "" --node overcloud-controller-0 --dest "$WORK/dest" || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    wait_for 'sosreport berjalan' 1 || return 0
    keys C-c
    rc="$(tmux_exit)"
    expect_eq "exit code 130" "$rc" "130"
    expect_match "pesan sosreport mungkin berlanjut" "$(screen_text)" 'mungkin masih berlanjut: overcloud-controller-0'
    expect_eq "stonith dipulihkan" "$(stonith)" "true"
    expect_true "state file dihapus" test ! -e "$(state_file)"
    expect_eq "node ABORTED (interrupted)" "$(tsv 6 overcloud-controller-0)" "ABORTED"
    sleep 0.5
    expect_true "worker di-kill (tidak ada sosreport tersisa)" sh -c "! pgrep -f 'sleep 3[7]' >/dev/null"

    begin "sigint_twice_during_restore"
    host_env "$C0" SOS_SLEEP=37 PCS_ENABLE_SLEEP=3
    start "" --node overcloud-controller-0 --dest "$WORK/dest" || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    wait_for 'sosreport berjalan' 1 || return 0
    keys C-c
    wait_for 'Memulihkan fencing' 1 || return 0
    sleep 0.5
    keys C-c
    rc="$(tmux_exit)"
    expect_match "pemulihan selesai walau Ctrl-C kedua" "$(screen_text)" 'Fencing dipulihkan di cluster tripleo_cluster'
    expect_eq "stonith dipulihkan" "$(stonith)" "true"
    expect_true "state file dihapus" test ! -e "$(state_file)"

    begin "sighup"
    host_env "$C0" SOS_SLEEP=38
    start "" --node overcloud-controller-0 --dest "$WORK/dest" || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    wait_for 'sosreport berjalan' 1 || return 0
    kill -HUP "$(script_pid)"
    rc="$(tmux_exit)"
    expect_eq "exit code 129" "$rc" "129"
    expect_eq "stonith dipulihkan saat SIGHUP" "$(stonith)" "true"
    expect_true "state file dihapus" test ! -e "$(state_file)"
    expect_match "enable-fencing SUCCESS" "$(log_text)" 'action=enable-fencing result=SUCCESS'
    sleep 0.5
    expect_true "worker di-kill" sh -c "! pgrep -f 'sleep 3[8]' >/dev/null"

    begin "sigterm"
    host_env "$C0" SOS_SLEEP=39
    start "" --node overcloud-controller-0 --dest "$WORK/dest" || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    wait_for 'sosreport berjalan' 1 || return 0
    kill -TERM "$(script_pid)"
    rc="$(tmux_exit)"
    expect_eq "exit code 143" "$rc" "143"
    expect_eq "stonith dipulihkan saat SIGTERM" "$(stonith)" "true"
}

test_restore_fail() {
    local rc
    begin "restore_fallback_controller"
    host_env "$C0" PCS_ENABLE_FAIL=1
    start "" --node overcloud-computeiha-0 --dest "$WORK/dest" --keep-remote || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_true "controller lain dipakai" grep -qE $'^pcs\t'"$C1"$'\tproperty set stonith-enabled=true' "$WORK/state/calls.log"
    expect_eq "stonith dipulihkan" "$(stonith)" "true"
    expect_match "enable-fencing via controller-1" "$(log_text)" 'action=enable-fencing result=SUCCESS controller=overcloud-controller-1'

    begin "restore_fail_all"
    host_env "$C0" PCS_ENABLE_FAIL=1
    host_env "$C1" PCS_ENABLE_FAIL=1
    host_env "$C2" PCS_ENABLE_FAIL=1
    start "" --node overcloud-computeiha-0 --dest "$WORK/dest" --keep-remote || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 2" "$rc" "2"
    expect_match "peringatan besar + perintah manual" "$(screen_text)" 'FENCING BELUM DIPULIHKAN'
    expect_match "perintah manual" "$(screen_text)" 'sudo pcs property set stonith-enabled=true'
    expect_true "state file tetap ada" test -f "$(state_file)"
    expect_match "enable-fencing FAILED" "$(log_text)" 'ERROR .*action=enable-fencing result=FAILED'
    expect_true "ketiga controller dicoba" grep -qE $'^pcs\t'"$C2"$'\tproperty set stonith-enabled=true' "$WORK/state/calls.log"
}

write_stale() {
    mkdir -p "$WORK/log/rhosp"
    printf '%s\n' "# state" "run_id=20261101T000000-1-dead" "controller=overcloud-controller-0" \
        "controller_ip=$C0" "cluster=tripleo_cluster" "original=$1" "disabled_at=2026-11-01T00:00:00+07:00" \
        > "$(state_file)"
}

test_stale_state() {
    local rc
    begin "stale_already_true"
    write_stale true
    start "" --include-undercloud --dest "$WORK/dest" || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 n || return 0
    rc="$(tmux_exit)"
    expect_match "info state dihapus" "$(screen_text)" 'stonith-enabled sudah aktif \(true\). State file dihapus'
    expect_true "state file dihapus" test ! -e "$(state_file)"

    begin "stale_quit"
    write_stale true
    echo false > "$WORK/state/cluster/stonith"
    start "" --include-undercloud --dest "$WORK/dest" || return 0
    answer 'r = pulihkan sekarang' 1 q || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "peringatan menonjol" "$(screen_text)" 'FENCING MUNGKIN MASIH DI-DISABLE OLEH EKSEKUSI SEBELUMNYA'
    expect_true "state file tetap" test -f "$(state_file)"
    expect_eq "stonith tidak diubah" "$(stonith)" "false"

    begin "stale_restore_r"
    write_stale unset
    echo false > "$WORK/state/cluster/stonith"
    start "" --include-undercloud --dest "$WORK/dest" || return 0
    answer 'r = pulihkan sekarang' 1 r || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 n || return 0
    rc="$(tmux_exit)"
    expect_eq "dipulihkan ke nilai di state file (unset)" "$(stonith)" "unset"
    expect_true "state file dihapus" test ! -e "$(state_file)"

    begin "stale_skip_s"
    write_stale true
    echo false > "$WORK/state/cluster/stonith"
    start "" --node overcloud-computeiha-0 --dest "$WORK/dest" --keep-remote || return 0
    answer 'r = pulihkan sekarang' 1 s || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 1 node' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_true "tidak set false lagi" no_call $'\tproperty set stonith-enabled=false'
    expect_eq "dipulihkan ke nilai awal dari state file (true)" "$(stonith)" "true"
    expect_true "state file dihapus setelah pulih" test ! -e "$(state_file)"
    expect_eq "node SUCCESS" "$(tsv 6 overcloud-computeiha-0)" "SUCCESS"

    begin "state_not_writable"
    mkdir -p "$(state_file)"
    start "" --node overcloud-computeiha-0 --include-undercloud --dest "$WORK/dest" --keep-remote || return 0
    answer 'Lanjutkan mengumpulkan sosreport dari 2 node' 1 y || return 0
    answer "Ketik 'yes'" 1 yes || return 0
    rc="$(tmux_exit)"
    expect_eq "node cluster ABORTED" "$(tsv 6 overcloud-computeiha-0)/$(tsv 12 overcloud-computeiha-0)" "ABORTED/state file not writable"
    expect_true "fencing tidak di-disable" no_call $'\tproperty set stonith-enabled=false'
    expect_eq "stonith tetap true" "$(stonith)" "true"
    expect_eq "node lain tetap jalan" "$(tsv 6 undercloud)" "SUCCESS"
}

test_dry_run() {
    local rc
    begin "dry_run"
    start "" --dry-run --role Controller --role ComputeInstanceHA --include-undercloud --case-id 0411 || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "rencana: fencing akan di-disable" "$(screen_text)" 'Fencing +: .*AKAN DI-DISABLE.* \(nilai awal true\)'
    expect_match "rencana: perintah" "$(screen_text)" "Perintah +: $SOS_EXACT --case-id 0411"
    expect_true "tanpa property set/unset" no_call $'\tproperty (set|unset)'
    expect_true "tanpa sosreport" no_call $'^sos\t'
    expect_true "tanpa chown" no_call 'chown'
    expect_true "tanpa scp" no_call $'^scp\t'
    expect_true "tanpa state file" test ! -e "$(state_file)"
    expect_true "tanpa lock" test ! -e "$WORK/log/rhosp/collect-sosreport.lock"
    expect_true "tanpa laporan TSV" test -z "$(report_file)"
    expect_match "log dry_run=true" "$(log_text)" 'INFO .*PLAN dry_run=true nodes=7 need_fencing=1'
    expect_no_match "tanpa log_result" "$(log_text)" ' RESULT '

    begin "dry_run_already_false"
    echo false > "$WORK/state/cluster/stonith"
    start "" --dry-run --node overcloud-computeiha-0 || return 0
    rc="$(tmux_exit)"
    expect_match "peringatan fencing mati tetap muncul" "$(screen_text)" 'FENCING SUDAH MATI'
}

# Penanda @platform di TUI (main.sh)
test_platform_tui() {
    local rows list1 list2 rc pw="$WORK/pw"
    begin "platform_tui"

    rows="$(OOT_WORKDIR="$ROOT" OSOPS_RHOSP_RELEASE_FILE="$WORK/none" bash "$ROOT/main.sh" --rows)"
    expect_match "tabel: (rhosp only) jika tidak terpenuhi" "$(grep collect-sosreport <<< "$rows")" 'Collect sosreport \(rhosp only\)'
    rows="$(OOT_WORKDIR="$ROOT" OSOPS_RHOSP_RELEASE_FILE="$WORK/rhosp-release" bash "$ROOT/main.sh" --rows)"
    expect_no_match "tabel: tanpa penanda jika terpenuhi" "$(grep collect-sosreport <<< "$rows")" 'rhosp only'
    expect_match "preview: tidak terpenuhi" \
        "$(OOT_WORKDIR="$ROOT" OSOPS_RHOSP_RELEASE_FILE="$WORK/none" bash "$ROOT/main.sh" --preview "$SCRIPT")" \
        'Platform : rhosp — tidak terpenuhi'

    list1="$(OSOPS_RHOSP_RELEASE_FILE="$WORK/none" bash "$ROOT/main.sh" --workdir "$ROOT" --list)"
    list2="$(OSOPS_RHOSP_RELEASE_FILE="$WORK/rhosp-release" bash "$ROOT/main.sh" --workdir "$ROOT" --list)"
    expect_eq "--list sama di semua host" "$list1" "$list2"
    expect_no_match "--list tanpa penanda" "$list1" 'only\)'

    # Nilai @platform tidak dikenal => tidak terpenuhi + peringatan
    mkdir -p "$pw/foo" "$pw/lib"
    cp "$ROOT/lib/logging.sh" "$pw/lib/"
    printf '#!/bin/bash\n# @name: Foo Tool\n# @platform: foo\necho ran-foo\n' > "$pw/foo/foo.sh"
    expect_match "platform tidak dikenal: penanda" "$(OOT_WORKDIR="$pw" bash "$ROOT/main.sh" --rows)" 'Foo Tool \(foo only\)'
    expect_match "platform tidak dikenal: peringatan" "$(OOT_WORKDIR="$pw" bash "$ROOT/main.sh" --preview "$pw/foo/foo.sh")" '@platform tidak dikenal'

    # Enter di menu: pesan, tidak dijalankan, RUN_BLOCKED di toolkit.log
    mkdir -p "$WORK/osbin"
    printf '#!/bin/bash\nexit 0\n' > "$WORK/osbin/openstack"
    chmod +x "$WORK/osbin/openstack"
    printf 'export OS_AUTH_URL=https://keystone.example:5000/v3\nexport OS_USERNAME=tester\n' > "$WORK/test.rc"
    "${TM[@]}" kill-server 2>/dev/null || true
    "${TM[@]}" new-session -d -s t -x 200 -y 50 \
        "env OSOPS_RHOSP_RELEASE_FILE=$(printf '%q' "$WORK/none") OSOPS_LOG_DIR=$(printf '%q' "$WORK/log") PATH=$(printf '%q' "$WORK/osbin:$PATH") \
bash $(printf '%q' "$ROOT/main.sh") --workdir $(printf '%q' "$pw") --rc $(printf '%q' "$WORK/test.rc") --no-fzf; echo __EXIT=\$?; sleep 3600"
    wait_for 'Nomor / kata kunci' 1 || return 0
    expect_match "menu: penanda (foo only)" "$(screen_text)" 'Foo Tool.*\(foo only\)'
    keys 1 Enter
    answer 'Tekan Enter untuk kembali' 1 "" || return 0
    answer 'Enter untuk kembali ke menu' 1 q || return 0
    rc="$(tmux_exit)"
    expect_match "pesan hanya berlaku di environment" "$(screen_text)" 'hanya berlaku di environment foo'
    expect_no_match "script tidak dijalankan" "$(screen_text)" 'ran-foo'
    expect_match "toolkit.log RUN_BLOCKED result=SKIPPED" "$(cat "$WORK/log/toolkit.log")" 'RUN_BLOCKED script=foo/foo.sh name="Foo Tool" platform=foo .*result=SKIPPED'
}

# ============================================================
# Run
# ============================================================

ALL_TESTS=(fencing_basic release inventory_search inventory_parse picker hostkeys precheck case_id
    locate copy cluster_membership cluster_unknown cluster_unhealthy pcs_parser already_false
    phase_order disable_verify_fail parallel interrupt restore_fail stale_state dry_run platform_tui)
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
