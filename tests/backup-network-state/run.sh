#!/bin/bash
# ============================================================
# Tes rhosp/backup-network-state.sh dengan stub ssh/sudo/ip/iptables*/nft
# (tanpa undercloud/overcloud sungguhan).
#
#   bash tests/backup-network-state/run.sh           # semua tes
#   bash tests/backup-network-state/run.sh netns     # hanya tes yang namanya cocok
#   KEEP=1 bash tests/backup-network-state/run.sh    # simpan direktori kerja
#
# Butuh: bash, jq, tmux, setsid, ssh-keygen, tar, gzip, sha256sum, mkfifo.
# Opsional: unshare + iptables-nft + nft asli (tes real_verify: membuktikan
# iptables-restore --test dan nft -c -f tidak menerapkan aturan).
# Stub ssh menjalankan skrip remote yang SEBENARNYA terhadap direktori palsu
# per host ($WORK/state/hosts/<ip>, /tmp node = hosts/<ip>/tmp).
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/rhosp/backup-network-state.sh"
STUB="$HERE/stub"
INV_FIX="$ROOT/tests/collect-sosreport/fixtures"
CS_STUB="$ROOT/tests/collect-sosreport/stub"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bns-test.XXXXXX")"
TM=(tmux -L "bns-test-$$")
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()

C0=192.168.24.21 C1=192.168.24.22 C2=192.168.24.23
P0=192.168.24.24 P1=192.168.24.25 P2=192.168.24.26
ALL_IPS=("$C0" "$C1" "$C2" "$P0" "$P1" "$P2")
RUN_ID="test-run-0001"

SECRET_TOKEN="FAKE-os-auth-token-9d1e7c"
SECRET_PW="FakeOvercloudAdminPw-4c7b2a"
# Isi aturan/route dari fixture: tidak boleh ada di log
CONTENT_PAT='OSOPS-RULE-MARKER|10\.99\.42|fd00:99:42|4242'

for tool in jq tmux setsid ssh-keygen tar gzip sha256sum mkfifo; do
    command -v "$tool" >/dev/null 2>&1 || { echo "❌ $tool dibutuhkan untuk tes"; exit 1; }
done

cleanup() {
    "${TM[@]}" kill-server 2>/dev/null || true
    pkill -f "$WORK/state/hosts" 2>/dev/null || true
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

ok() {
    PASS=$(( PASS + 1 ))
    echo "  ✅ $1"
}

bad() {
    FAIL=$(( FAIL + 1 ))
    FAILED_TESTS+=("$CURRENT: $1")
    echo "  ❌ $1"
    [[ -n "${2:-}" ]] && printf '     %s\n' "${2:0:600}"
    return 0
}

expect_eq() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "dapat: '$2'  harap: '$3'"; fi
}

expect_match() {
    if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "dapat: '${2:0:400}'  pola: '$3'"; fi
}

expect_no_match() {
    if [[ ! "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "pola tidak boleh muncul: '$3' => '$(grep -oE -- "$3" <<< "$2" | head -n 3 | tr '\n' ' ')'"; fi
}

expect_true() {
    local desc="$1"
    shift
    if "$@"; then ok "$desc"; else bad "$desc"; fi
}

reset_state() {
    local ip
    "${TM[@]}" kill-server 2>/dev/null || true
    pkill -f "$WORK/state/hosts" 2>/dev/null || true
    rm -rf "${WORK:?}/state" "${WORK:?}/log" "${WORK:?}/backup" "${WORK:?}/home" "${WORK:?}/stack" "${WORK:?}/out"
    mkdir -p "$WORK/state/local/tmp" "$WORK/log" "$WORK/home/.ssh" "$WORK/stack" "$WORK/out" "$WORK/tmp"
    : > "$WORK/state/calls.log"
    : > "$WORK/home/.ssh/known_hosts"
    : > "$WORK/home/.ssh/id_rsa"
    for ip in "${ALL_IPS[@]}"; do
        mkdir -p "$WORK/state/hosts/$ip/tmp"
        : > "$WORK/state/hosts/$ip/env"
        printf '%s %s\n' "$ip" "$HOSTKEY_PUB" >> "$WORK/home/.ssh/known_hosts"
    done
    cp "$INV_FIX/inventory.yaml" "$INV_FIX/inventory.yaml.json" "$WORK/stack/"
    echo "Red Hat OpenStack Platform release 17.1.4 (Wallaby)" > "$WORK/rhosp-release"
    "$STUB/mkbin" "$WORK/state/localbin"
}

hd() {
    printf '%s' "$WORK/state/hosts/$1"
}

host_env() {
    local ip="$1"
    shift
    printf '%s\n' "$@" >> "$(hd "$ip")/env"
}

_envs() {
    printf '%s ' -u OS_REGION_NAME "HOME=$(printf '%q' "$WORK/home")" "STUB_STATE=$(printf '%q' "$WORK/state")" \
        "STUB_HOSTKEY_PUB=$(printf '%q' "$HOSTKEY_PUB")" "OSOPS_SSH=$(printf '%q' "$STUB/ssh")" \
        "OSOPS_ANSIBLE_INVENTORY=$(printf '%q' "$CS_STUB/ansible-inventory")" "OSOPS_FZF=$(printf '%q' "$CS_STUB/fzf")" \
        "OSOPS_RHOSP_RELEASE_FILE=$(printf '%q' "$WORK/rhosp-release")" "OSOPS_STACK_HOME=$(printf '%q' "$WORK/stack")" \
        "OSOPS_LOG_DIR=$(printf '%q' "$WORK/log")" "OSOPS_BACKUP_DIR=$(printf '%q' "$WORK/backup")" \
        "OSOPS_RUN_ID=$RUN_ID" "TMPDIR=$(printf '%q' "$WORK/tmp")" \
        "PATH=$(printf '%q' "$WORK/state/localbin:$PATH")"
}

# run_plain "ENV..." ARGS... — tanpa terminal (setsid: tidak ada /dev/tty)
run_plain() {
    local envs="$1" args=""
    shift
    PLAIN_RC=0
    (( $# > 0 )) && printf -v args '%q ' "$@"
    eval "env $(_envs) $envs setsid bash $(printf '%q' "$SCRIPT") $args" \
        < /dev/null > "$WORK/out/plain.txt" 2>&1 || PLAIN_RC=$?
    PLAIN_OUT="$(cat "$WORK/out/plain.txt")"
}

run_tmux() {
    local envs="$1" cmd=""
    shift
    (( $# > 0 )) && printf -v cmd '%q ' "$@"
    "${TM[@]}" kill-server 2>/dev/null || true
    "${TM[@]}" new-session -d -s t -x 230 -y 60 \
        "env $(_envs) $envs bash $(printf '%q' "$SCRIPT") $cmd; echo __EXIT=\$?; sleep 3600"
}

screen_text() {
    "${TM[@]}" capture-pane -p -J -t t -S -5000 2>/dev/null
}

count_of() {
    screen_text | grep -cE -- "$1" || true
}

wait_for() {
    local pat="$1" n="${2:-1}" secs="${3:-30}" i
    for (( i = 0; i < secs * 5; i++ )); do
        (( $(count_of "$pat") >= n )) && return 0
        sleep 0.2
    done
    bad "timeout menunggu '$pat' (x$n)"
    screen_text | tail -n 25 | sed 's/^/     | /'
    return 1
}

keys() {
    "${TM[@]}" send-keys -t t "$@"
}

answer() {
    wait_for "$1" "${2:-1}" && keys "$3" Enter
}

# Prompt user bukan 'stack' (lib/rhosp.sh, mode warn => tanpa prompt)
tmux_exit() {
    wait_for '__EXIT=' 1 "${1:-60}" || { echo "?"; return 0; }
    screen_text | grep -o '__EXIT=[0-9]*' | tail -n 1 | cut -d= -f2
}

run_dir() {
    printf '%s' "$WORK/backup/network-state/$RUN_ID"
}

log_text() {
    cat "$WORK"/log/rhosp/backup-network-state-*.log 2>/dev/null || true
}

calls() {
    cat "$WORK/state/calls.log"
}

manifest() {
    cat "$(run_dir)/MANIFEST.tsv" 2>/dev/null || true
}

# mf HOST ITEM — "status<TAB>reason" dari MANIFEST
mf() {
    manifest | awk -F'\t' -v h="$1" -v it="$2" '$1 == h && $2 == it { print $3 "\t" $4 }'
}

leftover() {
    find "$(hd "$1")/tmp" -mindepth 1 -maxdepth 1 -name "osops-netstate-$RUN_ID.*" -type d | wc -l
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

# Semua sudo yang dipanggil di node harus ada di allowlist (read-only)
check_allowlist() {
    local bad_lines
    bad_lines="$(awk -F'\t' '$1 == "SUDO" { print $3 }' "$WORK/state/calls.log" | grep -vE \
        '^(true|timeout [0-9]+ ((iptables-save|ip6tables-save)( -c)?|nft (-s )?list ruleset|(iptables-restore|ip6tables-restore) --test -w 5|nft -c -f /[^ ]+|ip -n [A-Za-z0-9._:@-]+ -[46] (route show table all|rule show)|ip netns exec [A-Za-z0-9._:@-]+ ((iptables-save|ip6tables-save)( -c)?|nft (-s )?list ruleset|(iptables-restore|ip6tables-restore) --test -w 5|nft -c -f /[^ ]+)))$')" || true
    expect_eq "sudo hanya perintah allowlist read-only" "$bad_lines" ""
    expect_eq "tidak ada perintah yang mengubah state (VIOLATION)" \
        "$(cat "$WORK"/state/hosts/*/VIOLATION "$WORK/state/local/VIOLATION" 2>/dev/null)" ""
    # Semua panggilan tool (juga tanpa sudo): restore hanya --test, nft -f hanya -c,
    # ip hanya show/list/exec
    expect_eq "tidak ada restore/flush/route add/del" "$(awk -F'\t' '
        ($1 == "iptables-restore" || $1 == "ip6tables-restore") && $3 !~ /^--test( |$)/ { print }
        $1 == "nft" && $3 ~ /(^| )-f/ && $3 !~ /^-c -f / { print }
        $3 ~ /flush|(route|rule) (add|del|replace|change)/ { print }' "$WORK/state/calls.log")" ""
}

check_log_clean() {
    local all
    all="$(cat "$WORK"/log/*.log "$WORK"/log/*/*.log 2>/dev/null || true)"
    expect_no_match "isi aturan/route tidak ada di log" "$all" "$CONTENT_PAT"
    expect_no_match "secret inventory tidak ada di log" "$all" "$SECRET_TOKEN|$SECRET_PW"
}

# ============================================================
# Tes
# ============================================================

test_basic() {
    local rd h f bad_perm missing=0
    begin "basic"
    run_plain "" --nodes overcloud-controller-0,overcloud-computeiha-0
    expect_eq "exit 0" "$PLAIN_RC" "0"
    rd="$(run_dir)"
    expect_true "direktori run dibuat" test -d "$rd"
    for h in overcloud-controller-0 overcloud-computeiha-0; do
        for f in routes-v4.txt routes-v6.txt rules-v4.txt rules-v6.txt routes-v4.json routes-v6.json \
                 iptables-v4.rules iptables-v6.rules nftables.ruleset meta.json; do
            [[ -f "$rd/$h/$f" ]] || { bad "$h/$f ada"; missing=1; }
        done
    done
    (( missing )) || ok "struktur file per host lengkap"
    expect_true "rules-v4.json juga disimpan" test -f "$rd/overcloud-controller-0/rules-v4.json"
    expect_eq "tidak ada file internal (_*) di backup" "$(find "$rd" -name '_*' | wc -l)" "0"
    expect_eq "staging dihapus" "$(find "$rd" -name '.staging' | wc -l)" "0"
    expect_eq "direktori run 700" "$(stat -c %a "$rd")" "700"
    bad_perm="$(find "$rd" \( -type d ! -perm 700 \) -o \( -type f ! -perm 600 \) | head -n 3)"
    expect_eq "semua direktori 700, file 600" "$bad_perm" ""
    expect_eq "induk network-state dibuat 700" "$(stat -c %a "$WORK/backup/network-state")" "700"
    expect_true "SHA256SUMS valid" bash -c "cd $(printf '%q' "$rd") && sha256sum -c --quiet SHA256SUMS"
    expect_match "SHA256SUMS mencakup MANIFEST" "$(cat "$rd/SHA256SUMS")" '\./MANIFEST\.tsv'
    expect_match "MANIFEST: catatan tidak atomik" "$(manifest)" 'NOT ATOMIC'
    expect_eq "MANIFEST routes-v4 OK, alasan kosong" "$(mf overcloud-controller-0 routes-v4.txt)" $'OK\t'
    expect_eq "MANIFEST: 6 kolom di setiap baris data" "$(manifest | grep -v '^#' | awk -F'\t' 'NF != 6' | wc -l)" "0"
    expect_match "MANIFEST: size + sha256" "$(manifest | awk -F'\t' '$1=="overcloud-controller-0" && $2=="nftables.ruleset"')" $'\t[0-9]+\t[0-9a-f]{64}$'
    expect_eq "MANIFEST verify iptables OK" "$(mf overcloud-controller-0 verify:iptables-v4.rules | cut -f1)" "OK"
    expect_eq "MANIFEST verify nft OK" "$(mf overcloud-controller-0 verify:nftables.ruleset | cut -f1)" "OK"
    expect_eq "sha di MANIFEST = file" "$(manifest | awk -F'\t' '$1=="overcloud-controller-0" && $2=="routes-v4.txt" {print $6}')" \
        "$(sha256sum "$rd/overcloud-controller-0/routes-v4.txt" | awk '{print $1}')"
    # Default tanpa counter
    expect_no_match "iptables tanpa counter aturan" "$(cat "$rd/overcloud-controller-0/iptables-v4.rules")" '^\[[0-9]+:[0-9]+\]|'$'\n''\[[0-9]+:'
    expect_match "policy chain [0:0]" "$(cat "$rd/overcloud-controller-0/iptables-v4.rules")" ':INPUT ACCEPT \[0:0\]'
    expect_no_match "nft tanpa nilai counter (-s)" "$(cat "$rd/overcloud-controller-0/nftables.ruleset")" 'packets [0-9]+'
    expect_match "isi route tersimpan" "$(cat "$rd/overcloud-controller-0/routes-v4.txt")" '10\.99\.42\.0/24'
    # meta.json
    f="$rd/overcloud-controller-0/meta.json"
    expect_eq "meta.json: backend nf_tables" "$(jq -r .tools.iptables_backend "$f")" "nf_tables"
    expect_eq "meta.json: atomic false" "$(jq -r .atomic "$f")" "false"
    expect_match "meta.json: kernel + waktu node" "$(jq -r '.kernel + " " + (.node_time.epoch|tostring) + " " + .node_time.iso' "$f")" '^[^ ]+ [0-9]+ [0-9]{4}-'
    expect_match "meta.json: timestamp per perintah" "$(jq -r '.commands[] | select(.item=="iptables-v4.rules") | "\(.start_epoch) \(.end_epoch) \(.rc)"' "$f")" '^[0-9]+ [0-9]+ 0$'
    expect_eq "meta.json: nft version" "$(jq -r .tools.nft "$f")" "nftables v1.0.9 (Old Doc Yak #3)"
    # Node bersih, perintah remote statis
    expect_eq "tidak ada direktori sementara tersisa (controller-0)" "$(leftover "$C0")" "0"
    expect_eq "tidak ada direktori sementara tersisa (computeiha-0)" "$(leftover "$P0")" "0"
    expect_match "perintah remote statis lewat stdin" "$(calls)" "timeout -k 10 120 bash -c \"\\\$\\(cat\\)\" osops-netstate $RUN_ID 0 0 1 120"
    expect_match "ringkasan: tabel per node" "$PLAIN_OUT" 'overcloud-controller-0 +Controller +SUCCESS +nf_tables'
    expect_match "ringkasan: path + ukuran" "$PLAIN_OUT" "Backup       : $rd"
    expect_match "ringkasan: ukuran total" "$PLAIN_OUT" 'Ukuran total : [0-9.]+[KMG]?B?'
    expect_match "region/stack ditampilkan" "$PLAIN_OUT" 'Region     : -'
    expect_true "log file log/rhosp/backup-network-state-YYYYMMDD.log" test -f "$WORK/log/rhosp/backup-network-state-$(date +%Y%m%d).log"
    expect_match "log: RESULT per node" "$(log_text)" 'RESULT resource=overcloud-controller-0 action=lookup result=SUCCESS items_ok=[0-9]+'
    check_allowlist
    check_log_clean
    expect_no_match "output: tidak ada secret inventory" "$PLAIN_OUT" "$SECRET_TOKEN|$SECRET_PW"
    expect_eq "ip route/rule tanpa sudo" "$(awk -F'\t' '$1=="SUDO" && $3 ~ /timeout [0-9]+ ip -[46]/' "$WORK/state/calls.log" | wc -l)" "0"
}

test_counters() {
    local rd
    begin "counters"
    run_plain "" --nodes overcloud-controller-0 --counters --no-verify
    expect_eq "exit 0" "$PLAIN_RC" "0"
    rd="$(run_dir)/overcloud-controller-0"
    expect_match "--counters: counter aturan iptables" "$(cat "$rd/iptables-v4.rules")" '\[12:3456\] -A INPUT'
    expect_match "--counters: policy counter asli" "$(cat "$rd/iptables-v4.rules")" ':INPUT ACCEPT \[1234:567890\]'
    expect_match "--counters: nft packets" "$(cat "$rd/nftables.ruleset")" 'packets 77 bytes 6600'
    expect_eq "--no-verify: tidak ada restore --test / nft -c" "$(grep -cE 'restore|nft -c' "$WORK/state/calls.log" || true)" "0"
    expect_match "--no-verify: ringkasan" "$PLAIN_OUT" 'verify: off'
    check_allowlist
}

test_missing_tools() {
    local rd
    begin "missing_tools"
    host_env "$C0" NO_NFT=1
    host_env "$P0" NO_IP6TABLES_SAVE=1 NO_IPJ=1
    run_plain "" --nodes overcloud-controller-0,overcloud-computeiha-0
    expect_eq "exit 0 (tool tidak ada bukan error node)" "$PLAIN_RC" "0"
    expect_eq "tanpa nft: nftables.ruleset SKIPPED" "$(mf overcloud-controller-0 nftables.ruleset)" $'SKIPPED\tnot installed'
    expect_eq "tanpa nft: verify nft SKIPPED" "$(mf overcloud-controller-0 verify:nftables.ruleset)" $'SKIPPED\tno backup file'
    expect_eq "tanpa ip6tables-save: SKIPPED" "$(mf overcloud-computeiha-0 iptables-v6.rules)" $'SKIPPED\tnot installed'
    expect_eq "tanpa ip -j: json SKIPPED" "$(mf overcloud-computeiha-0 routes-v4.json)" $'SKIPPED\tip -j not supported'
    rd="$(run_dir)"
    expect_true "file nft tidak dibuat" test ! -e "$rd/overcloud-controller-0/nftables.ruleset"
    expect_match "ringkasan: controller-0 SUCCESS + item dilewati" "$PLAIN_OUT" 'overcloud-controller-0 .*SUCCESS'
    expect_match "ringkasan: alasan item dilewati" "$PLAIN_OUT" 'dilewati: .*nftables\.ruleset: not installed'
    expect_match "ringkasan: ip6tables dilewati" "$PLAIN_OUT" 'iptables-v6\.rules: not installed'
    expect_match "log: item SKIPPED dicatat" "$(log_text)" 'ITEM host=overcloud-controller-0 item=nftables.ruleset status=SKIPPED reason="not installed"'
    expect_eq "tidak ada sisa di node" "$(( $(leftover "$C0") + $(leftover "$P0") ))" "0"
}

test_backend() {
    begin "backend"
    host_env "$C1" IPT_BACKEND=legacy
    run_plain "" --nodes overcloud-controller-0,overcloud-controller-1
    expect_eq "exit 0" "$PLAIN_RC" "0"
    expect_eq "nf_tables dicatat" "$(jq -r .tools.iptables_backend "$(run_dir)/overcloud-controller-0/meta.json")" "nf_tables"
    expect_eq "legacy dicatat" "$(jq -r .tools.iptables_backend "$(run_dir)/overcloud-controller-1/meta.json")" "legacy"
    expect_match "meta.json: versi iptables" "$(jq -r .tools.iptables "$(run_dir)/overcloud-controller-1/meta.json")" 'v1\.8\.10 \(legacy\)'
    expect_match "ringkasan: kolom backend legacy" "$PLAIN_OUT" 'overcloud-controller-1 .*SUCCESS +legacy'
    expect_match "log: backend" "$(log_text)" 'resource=overcloud-controller-1 .*backend=legacy'
}

test_timeout() {
    local t0 dur
    begin "timeout"
    host_env "$C0" SLOW_SAVE=40
    t0="$(date +%s)"
    run_plain "" --nodes overcloud-controller-0,overcloud-computeiha-0 --timeout 10
    dur=$(( $(date +%s) - t0 ))
    expect_eq "exit 1 (ada node FAILED)" "$PLAIN_RC" "1"
    expect_match "controller-0 FAILED timeout" "$PLAIN_OUT" 'overcloud-controller-0 .*FAILED .*timeout \(10s\)'
    expect_match "computeiha-0 tetap SUCCESS" "$PLAIN_OUT" 'overcloud-computeiha-0 .*SUCCESS'
    expect_true "durasi dibatasi timeout (< 45s)" test "$dur" -lt 45
    expect_eq "MANIFEST: node FAILED" "$(mf overcloud-controller-0 -)" $'FAILED\ttimeout (10s)'
    expect_true "tidak ada direktori host untuk node gagal" test ! -e "$(run_dir)/overcloud-controller-0"
    expect_match "pembersihan remote dipanggil" "$(calls)" "find /tmp -mindepth 1 -maxdepth 1 -type d -user \"\\\$u\" -name 'osops-netstate-$RUN_ID\\.\\*'"
    sleep 2
    expect_eq "tidak ada sisa di node timeout" "$(leftover "$C0")" "0"
    expect_match "log: CLEANUP left=0" "$(log_text)" 'CLEANUP host=overcloud-controller-0 result=SUCCESS left=0'
}

test_verify_fail() {
    local rd
    begin "verify_fail"
    host_env "$C0" VERIFY_FAIL=nft
    host_env "$P0" VERIFY_FAIL=ipt
    run_plain "" --nodes overcloud-controller-0,overcloud-computeiha-0
    expect_eq "exit 1" "$PLAIN_RC" "1"
    expect_eq "nft verify FAILED" "$(mf overcloud-controller-0 verify:nftables.ruleset)" $'FAILED\tverify failed (rc=1)'
    expect_eq "iptables verify FAILED" "$(mf overcloud-computeiha-0 verify:iptables-v4.rules)" $'FAILED\tverify failed (rc=1)'
    rd="$(run_dir)"
    expect_true "file tetap disimpan meski verifikasi gagal" test -s "$rd/overcloud-controller-0/nftables.ruleset"
    expect_match "ringkasan: node FAILED + item gagal" "$PLAIN_OUT" 'gagal: verify:nftables\.ruleset'
    expect_match "meta.json: hanya posisi error nft" "$(jq -r '.commands[] | select(.item=="verify:nftables.ruleset") | .stderr' "$rd/overcloud-controller-0/meta.json")" '^line 4: Error: Could not process rule'
    expect_no_match "meta.json: tanpa isi aturan dari pesan nft" "$(cat "$rd/overcloud-controller-0/meta.json")" 'MARKER-nfterr'
    expect_no_match "output: tanpa isi aturan" "$PLAIN_OUT" "$CONTENT_PAT"
    check_log_clean
    check_allowlist
}

test_xt() {
    begin "xt"
    host_env "$C0" NFT_XT=1
    run_plain "" --nodes overcloud-controller-0,overcloud-controller-1
    expect_eq "exit 0" "$PLAIN_RC" "0"
    expect_eq "verify nft SKIPPED (xt)" "$(mf overcloud-controller-0 verify:nftables.ruleset)" \
        $'SKIPPED\tiptables-nft compat (xt): restore via iptables-restore'
    expect_eq "nft -c tidak dijalankan untuk ruleset xt" "$(grep -c "^nft	$C0	-c" "$WORK/state/calls.log" || true)" "0"
    expect_match "ringkasan menyebut node xt" "$PLAIN_OUT" 'Verifikasi nft di-SKIP .*: overcloud-controller-0'
    expect_match "log SUMMARY xt" "$(log_text)" 'nft_verify_xt_skipped=overcloud-controller-0'
}

test_netns() {
    local rd i nsdirs missing=0
    begin "netns"
    {
        echo "qrouter-11111111-2222-3333-4444-555555555555 (id: 0)"
        echo "ovnmeta-aaaa-bbbb (id: 1)"
        echo "ovnmeta-aaaa-bbbb"
        echo "bad name (id: 2)"
        echo "-evil"
        echo "../escape"
        # shellcheck disable=SC2016  # sengaja literal: nama berisi substitusi perintah
        echo 'ns$(touch PWNED)'
        echo "qdhcp-gone (id: 4)"
    } > "$(hd "$C0")/netns.list"
    echo "qdhcp-gone" > "$(hd "$C0")/netns.vanish"
    run_plain "" --nodes overcloud-controller-0 --include-netns
    expect_eq "exit 0" "$PLAIN_RC" "0"
    [[ "$PLAIN_RC" == 0 ]] || sed -n '/Mengambil/,$p' <<< "$PLAIN_OUT" | sed 's/^/     | /'
    rd="$(run_dir)/overcloud-controller-0/netns"
    nsdirs="$(find "$rd" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')"
    expect_eq "hanya namespace valid jadi direktori" "$nsdirs" "ovnmeta-aaaa-bbbb qrouter-11111111-2222-3333-4444-555555555555 "
    for i in routes-v4.txt routes-v6.txt rules-v4.txt rules-v6.txt iptables-v4.rules iptables-v6.rules nftables.ruleset; do
        [[ -f "$rd/qrouter-11111111-2222-3333-4444-555555555555/$i" ]] || { bad "netns file $i"; missing=1; }
    done
    (( missing )) || ok "file per namespace lengkap"
    expect_eq "nama tidak valid SKIPPED (4)" "$(manifest | awk -F'\t' '$2 ~ /^netns:invalid-/ && $3 == "SKIPPED"' | wc -l)" "4"
    expect_eq "namespace hilang SKIPPED" "$(mf overcloud-controller-0 netns/qdhcp-gone/routes-v4.txt)" $'SKIPPED\tnamespace vanished'
    expect_eq "ringkasan namespace" "$(mf overcloud-controller-0 netns)" $'OK\t3 namespaces, 4 invalid names'
    expect_eq "tidak ada eksekusi dari nama namespace" "$(find "$WORK/state" -name PWNED | wc -l)" "0"
    expect_true "tidak ada path keluar dari netns/" test ! -e "$(run_dir)/overcloud-controller-0/escape"
    expect_eq "verify netns dijalankan di namespace" "$(grep -c $'^SUDO\t'"$C0"$'\ttimeout [0-9]* ip netns exec qrouter-11111111-2222-3333-4444-555555555555 iptables-restore --test' "$WORK/state/calls.log" || true)" "1"
    expect_match "meta.json: netns on" "$(jq -r .options.netns "$(run_dir)/overcloud-controller-0/meta.json")" true
    expect_eq "tidak ada sisa di node" "$(leftover "$C0")" "0"
    check_allowlist
    check_log_clean
}

test_netns_many() {
    local i
    begin "netns_many"
    for (( i = 0; i < 51; i++ )); do
        printf 'qrouter-%04d (id: %d)\n' "$i" "$i"
    done > "$(hd "$C0")/netns.list"
    run_plain "" --nodes overcloud-controller-0 --include-netns
    expect_eq "tanpa terminal: exit 0" "$PLAIN_RC" "0"
    expect_match "tanpa terminal: namespace dilewati" "$PLAIN_OUT" '51 namespace \(> 50\), tanpa terminal: namespace dilewati'
    expect_eq "MANIFEST: netns SKIPPED" "$(mf overcloud-controller-0 netns)" $'SKIPPED\t51 namespaces > 50, no terminal for confirmation'
    expect_true "tidak ada direktori netns" test ! -e "$(run_dir)/overcloud-controller-0/netns"

    reset_state
    for (( i = 0; i < 51; i++ )); do
        printf 'qrouter-%04d (id: %d)\n' "$i" "$i"
    done > "$(hd "$C0")/netns.list"
    run_tmux "" --nodes overcloud-controller-0 --include-netns
    answer 'Ikut backup semua namespace di node ini' 1 y || return 0
    expect_eq "konfirmasi y: exit 0" "$(tmux_exit)" "0"
    expect_eq "konfirmasi y: 51 namespace dibackup" "$(find "$(run_dir)/overcloud-controller-0/netns" -mindepth 1 -maxdepth 1 -type d | wc -l)" "51"
    expect_match "jumlah namespace ditampilkan" "$(screen_text)" 'overcloud-controller-0 +Controller +OK \(51 netns\)'
}

test_interrupt() {
    local h
    begin "interrupt"
    host_env "$C0" SLOW_SAVE=6
    h="$(hd "$C0")/tmp"
    mkdir -p "$h/osops-netstate-other-run.abc123" "$h/osops-netstate-$RUN_ID""9.x" "$h/keep-me" "$h/sub/osops-netstate-$RUN_ID.deep"
    : > "$h/osops-netstate-$RUN_ID.file"
    run_tmux "" --nodes overcloud-controller-0
    wait_for 'overcloud-controller-0: mulai' 1 || return 0
    # Tunggu sampai direktori sementara dibuat di node, lalu Ctrl-C
    for (( i = 0; i < 50; i++ )); do
        (( $(leftover "$C0") > 0 )) && break
        sleep 0.2
    done
    expect_eq "direktori sementara ada saat berjalan" "$(leftover "$C0")" "1"
    keys C-c
    expect_eq "exit 130" "$(tmux_exit 40)" "130"
    expect_match "pembersihan dijalankan" "$(screen_text)" 'Membersihkan direktori sementara di 1 node'
    expect_eq "direktori sementara node terhapus" "$(leftover "$C0")" "0"
    sleep 7
    expect_eq "tetap terhapus setelah remote selesai" "$(leftover "$C0")" "0"
    expect_true "direktori run lain tidak terhapus" test -d "$h/osops-netstate-other-run.abc123"
    expect_true "prefix run_id lebih panjang tidak terhapus" test -d "$h/osops-netstate-$RUN_ID""9.x"
    expect_true "direktori lain di /tmp tidak terhapus" test -d "$h/keep-me"
    expect_true "subdirektori (bukan langsung di /tmp) tidak terhapus" test -d "$h/sub/osops-netstate-$RUN_ID.deep"
    expect_true "file (bukan direktori) dengan nama cocok tidak terhapus" test -f "$h/osops-netstate-$RUN_ID.file"
    expect_match "log: ABORTED" "$(log_text)" 'RESULT resource=overcloud-controller-0 action=lookup result=ABORTED'
    expect_match "log: CLEANUP left=0" "$(log_text)" 'CLEANUP host=overcloud-controller-0 result=SUCCESS left=0'
    expect_match "MANIFEST ditulis untuk backup sebagian" "$(manifest)" $'overcloud-controller-0\t-\tFAILED\tinterrupted'
    expect_eq "tidak ada proses remote tersisa" "$(pgrep -fc "$WORK/state/hosts/$C0" || true)" "0"
}

test_run_id() {
    begin "run_id"
    run_plain "OSOPS_RUN_ID='bad;id'" --nodes overcloud-controller-0
    expect_eq "run_id tidak valid: exit 1" "$PLAIN_RC" "1"
    expect_match "run_id tidak valid: pesan" "$PLAIN_OUT" 'run_id tidak valid'
    expect_eq "run_id tidak valid: tidak ada ssh" "$(grep -c '^ssh' "$WORK/state/calls.log" || true)" "0"
    run_plain "OSOPS_RUN_ID='x.*'" --nodes overcloud-controller-0
    expect_eq "run_id dengan glob/titik ditolak" "$PLAIN_RC" "1"
    run_plain "OSOPS_RUN_ID='../x'" --nodes overcloud-controller-0
    expect_eq "run_id dengan path ditolak" "$PLAIN_RC" "1"
    expect_eq "tidak ada direktori backup dibuat" "$(find "$WORK/backup" -mindepth 2 2>/dev/null | wc -l)" "0"
    # Skrip remote juga menolak run_id tidak valid (lapis kedua)
    local rs
    rs="$(bash -c 'eval "$(sed -n "/^NS_RE=/p" "$1")"; eval "$(sed -n "/^REMOTE_SCRIPT=/,/^exit \$?.$/p" "$1")"; printf "%s" "$REMOTE_SCRIPT"' _ "$SCRIPT")"
    expect_match "remote: run_id tidak valid ditolak" "$(bash -c "$rs" osops-netstate 'a/../b' 0 0 0 10 2>&1; echo "rc=$?")" 'invalid run id.*rc=2'
    expect_match "remote: argumen bukan angka ditolak" "$(bash -c "$rs" osops-netstate 'abc' '0;x' 0 0 10 2>&1; echo "rc=$?")" 'invalid argument.*rc=2'
}

test_output_dir() {
    local od before after
    begin "output_dir"
    od="$WORK/custom-out"
    mkdir -p "$od/older-run" "$od/$RUN_ID"
    echo keep > "$od/older-run/MANIFEST.tsv"
    echo existing > "$od/notes.txt"
    chmod 755 "$od"
    before="$(cd "$od" && find . -type f -exec sha256sum {} + | sort)"
    run_plain "" --nodes overcloud-controller-0 --output-dir "$od"
    expect_eq "run dir sudah ada: exit 1" "$PLAIN_RC" "1"
    expect_match "run dir sudah ada: tidak ditimpa" "$PLAIN_OUT" 'sudah ada: .* \(tidak ditimpa\)'
    expect_eq "tidak ada ssh sebelum cek output" "$(grep -c '^ssh' "$WORK/state/calls.log" || true)" "0"
    rmdir "$od/$RUN_ID"
    run_plain "" --nodes overcloud-controller-0 --output-dir "$od"
    expect_eq "exit 0" "$PLAIN_RC" "0"
    expect_true "backup di --output-dir/<run_id>" test -f "$od/$RUN_ID/overcloud-controller-0/routes-v4.txt"
    after="$(cd "$od" && find . -path "./$RUN_ID" -prune -o -type f -exec sha256sum {} + | sort)"
    expect_eq "isi lama --output-dir tidak berubah" "$after" "$before"
    expect_eq "permission --output-dir lama tidak diubah" "$(stat -c %a "$od")" "755"
    expect_eq "run dir 700" "$(stat -c %a "$od/$RUN_ID")" "700"
    expect_true "default OSOPS_BACKUP_DIR tidak dipakai" test ! -e "$WORK/backup/network-state/$RUN_ID"
    : > "$WORK/notadir"
    run_plain "OSOPS_RUN_ID=test-run-0002" --nodes overcloud-controller-0 --output-dir "$WORK/notadir"
    expect_match "--output-dir file biasa ditolak" "$PLAIN_OUT" 'bukan direktori'
}

test_selection() {
    begin "selection"
    run_plain "" --all
    expect_eq "--all tanpa terminal ditolak" "$PLAIN_RC" "1"
    expect_match "--all tanpa terminal: pesan" "$PLAIN_OUT" '--all butuh terminal'
    run_plain ""
    expect_match "tanpa terminal: pilihan node wajib" "$PLAIN_OUT" 'Tanpa terminal: --nodes/--node/--role atau --local wajib'
    run_plain "" --all --role Controller
    expect_match "--all + --role ditolak" "$PLAIN_OUT" 'tidak bisa digabung'

    run_tmux "" --all
    answer 'Ketik jumlah node \(6\)' 1 5 || return 0
    expect_eq "--all: jumlah salah => batal, exit 0" "$(tmux_exit)" "0"
    expect_eq "--all batal: tidak ada ssh" "$(grep -c '^ssh' "$WORK/state/calls.log" || true)" "0"

    run_tmux "" --all --parallel 3
    answer 'Ketik jumlah node \(6\)' 1 6 || return 0
    expect_eq "--all: 6 node, exit 0" "$(tmux_exit 60)" "0"
    expect_eq "--all: 6 direktori host" "$(find "$(run_dir)" -mindepth 1 -maxdepth 1 -type d | wc -l)" "6"
    expect_match "--all: daftar node sebelum mulai" "$(screen_text)" 'Node       : 6'

    reset_state
    run_plain "" --role ComputeInstanceHA --nodes overcloud-controller-2
    expect_eq "--role + --nodes: exit 0" "$PLAIN_RC" "0"
    expect_eq "--role + --nodes: 4 host" "$(find "$(run_dir)" -mindepth 1 -maxdepth 1 -type d | wc -l)" "4"

    reset_state
    run_tmux "STUB_FZF_SELECT='overcloud-controller-1'"
    expect_eq "picker: exit 0" "$(tmux_exit)" "0"
    expect_eq "picker: node terpilih dibackup" "$(find "$(run_dir)" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')" "overcloud-controller-1"
}

test_local() {
    local rd
    begin "local"
    run_plain "" --local
    expect_eq "--local: exit 0" "$PLAIN_RC" "0"
    rd="$(run_dir)/undercloud"
    expect_true "--local: undercloud dibackup" test -s "$rd/iptables-v4.rules"
    expect_eq "--local: tanpa ssh" "$(grep -c '^ssh' "$WORK/state/calls.log" || true)" "0"
    expect_eq "--local: direktori /tmp lokal terhapus" "$(find /tmp -maxdepth 1 -name "osops-netstate-$RUN_ID.*" 2>/dev/null | wc -l)" "0"
    reset_state
    run_plain "" --local --nodes overcloud-controller-0
    expect_eq "--local + --nodes: 2 host" "$(find "$(run_dir)" -mindepth 1 -maxdepth 1 -type d | wc -l)" "2"
    check_allowlist
}

test_failures() {
    begin "failures"
    host_env "$C1" UNREACHABLE=1
    host_env "$C2" SUDO_FAIL=1
    host_env "$P1" HOSTKEY_CHANGED=1
    host_env "$P2" CORRUPT_SUM=1
    grep -v "^$P0 " "$WORK/home/.ssh/known_hosts" > "$WORK/kh" && mv "$WORK/kh" "$WORK/home/.ssh/known_hosts"
    run_plain "" --nodes overcloud-controller-0,overcloud-controller-1,overcloud-controller-2,overcloud-computeiha-0,overcloud-computeiha-1,overcloud-computeiha-2
    expect_eq "exit 1" "$PLAIN_RC" "1"
    expect_match "unreachable => FAILED" "$PLAIN_OUT" 'overcloud-controller-1 .*FAILED .*unreachable'
    expect_match "sudo gagal => FAILED" "$PLAIN_OUT" 'overcloud-controller-2 .*FAILED .*sudo failed'
    expect_match "host key berubah => SKIPPED" "$PLAIN_OUT" 'overcloud-computeiha-1 .*SKIPPED .*host key mismatch'
    expect_match "host key tidak dikenal tanpa terminal => SKIPPED" "$PLAIN_OUT" 'overcloud-computeiha-0 .*SKIPPED .*host key unknown'
    expect_match "sha256 berbeda => FAILED" "$PLAIN_OUT" 'overcloud-computeiha-2 .*FAILED .*sha256 mismatch'
    expect_match "node sehat tetap SUCCESS" "$PLAIN_OUT" 'overcloud-controller-0 .*SUCCESS'
    expect_eq "tidak ada koneksi ke host key tidak dikenal" "$(grep -c $'^ssh\t'"$P0" "$WORK/state/calls.log" || true)" "0"
    expect_true "sha mismatch: tidak ada direktori host" test ! -e "$(run_dir)/overcloud-computeiha-2"
    expect_eq "sha mismatch: sisa di node dibersihkan" "$(leftover "$P2")" "0"
    expect_match "MANIFEST mencatat node SKIPPED" "$(manifest)" $'overcloud-computeiha-1\t-\tSKIPPED\thost key mismatch'

    reset_state
    host_env "$C0" EVIL_TAR=1
    run_plain "" --nodes overcloud-controller-0
    expect_eq "arsip berisi symlink: exit 1" "$PLAIN_RC" "1"
    expect_match "arsip berisi symlink: invalid archive" "$PLAIN_OUT" 'FAILED .*invalid archive'
    expect_eq "symlink tidak diekstrak" "$(find "$WORK/backup" -type l | wc -l)" "0"
}

# Bukti dengan tool asli (jika tersedia): verifikasi tidak menerapkan aturan
test_real_verify() {
    local out
    begin "real_verify"
    if ! command -v unshare >/dev/null 2>&1 || ! command -v nft >/dev/null 2>&1 \
       || ! command -v iptables-restore >/dev/null 2>&1 || ! unshare -rn true 2>/dev/null; then
        echo "  ⚠️  dilewati: unshare -rn / iptables / nft asli tidak tersedia (TIDAK diverifikasi)"
        return 0
    fi
    # shellcheck disable=SC2016
    out="$(unshare -rn bash -c '
        set -u
        nft add table inet t0 && nft add chain inet t0 c0 "{ type filter hook input priority 0; }" && nft add rule inet t0 c0 tcp dport 22 accept
        iptables -A INPUT -s 10.1.1.1 -j DROP; ip6tables -A INPUT -s 2001:db8::1 -j DROP
        before="$(nft list ruleset)"
        printf "*filter\n:INPUT DROP [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n-A INPUT -s 10.9.9.9 -j ACCEPT\nCOMMIT\n" | iptables-restore --test -w 5; echo "ipt=$?"
        printf "*filter\n:INPUT DROP [0:0]\n-A INPUT -s 2001:db8::9 -j ACCEPT\nCOMMIT\n" | ip6tables-restore --test -w 5; echo "ip6t=$?"
        printf "flush ruleset\ntable inet x {\n chain y {\n  type filter hook input priority 0; policy drop;\n }\n}\n" > "$1/n.rules"
        nft -c -f "$1/n.rules"; echo "nft=$?"
        [ "$before" = "$(nft list ruleset)" ] && echo UNCHANGED || echo CHANGED
        iptables --version
    ' _ "$WORK/tmp" 2>&1)" || true
    expect_match "iptables-restore --test rc=0" "$out" 'ipt=0'
    expect_match "ip6tables-restore --test rc=0" "$out" 'ip6t=0'
    expect_match "nft -c -f (flush ruleset) rc=0" "$out" 'nft=0'
    expect_match "ruleset tidak berubah setelah verifikasi" "$out" 'UNCHANGED'
    echo "     ($(grep -m1 '^iptables v' <<< "$out"), $(nft --version 2>/dev/null))"
}

# ============================================================
# Run
# ============================================================

ALL_TESTS=(basic counters missing_tools backend timeout verify_fail xt netns netns_many interrupt
    run_id output_dir selection local failures real_verify)
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
