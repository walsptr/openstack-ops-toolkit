#!/bin/bash
# ============================================================
# Tes network/get-ip-info.sh (+ lib/netinfo.sh, rename di install.sh) dengan
# stub OpenStack CLI dan stub curl (tanpa cloud).
#
#   bash tests/get-ip-info/run.sh            # semua tes
#   bash tests/get-ip-info/run.sh deep       # hanya tes yang namanya cocok
#   KEEP=1 bash tests/get-ip-info/run.sh     # simpan direktori kerja
#
# Butuh: bash, jq, tmux, setsid. Tes install butuh unshare (user namespace,
# root palsu); tanpa itu tes install dilewati. Prompt dijalankan di tmux
# karena membaca dari /dev/tty.
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/network/get-ip-info.sh"
STUB="$HERE/stub/openstack"
CSTUB="$HERE/stub/curl"
FIX="$HERE/fixtures"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gii-test.XXXXXX")"
TM=(tmux -L "gii-test-$$")
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()

TOKEN="gAAAAAstubTOKENrahasia-0123456789"
SECRET_PW="StubPassw0rd-Rahasia"
HEADER="Query IP,Match Type,Device Type,Device ID,Device Name,Compute Host,Port ID,MAC Address,Port Status,Network Name,Subnet CIDR,Fixed IP,Floating IP ID,Floating IP,Floating IP Status,Project ID,Project Name,Domain Name,Created At,Updated At"
P_WEB="e0000000-0000-4000-8000-000000000001"
P_VRRP="e0000000-0000-4000-8000-000000000014"
N_B="b0000000-0000-4000-8000-000000000003"
PRJ_ACME="a0000000000000000000000000000001"

for tool in jq tmux setsid; do
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
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "dapat: '${2:0:800}'  harap: '${3:0:800}'"; fi
}

expect_match() {
    if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "dapat: '${2:0:800}'  pola: '$3'"; fi
}

expect_no_match() {
    if [[ "$2" =~ $3 ]]; then bad "$1" "pola tidak boleh muncul: '$3'"; else ok "$1"; fi
}

expect_true() {
    local desc="$1"
    shift
    if "$@"; then ok "$desc"; else bad "$desc"; fi
}

reset_state() {
    "${TM[@]}" kill-server 2>/dev/null || true
    # Arsipkan calls.log semua tes untuk cek read-only di akhir
    [[ -f "$WORK/state/calls.log" ]] && cat "$WORK/state/calls.log" >> "$WORK/all-calls.log"
    rm -rf "$WORK/state" "$WORK/log" "$WORK/tmp" "$WORK/out"
    mkdir -p "$WORK/state/scen" "$WORK/log" "$WORK/tmp" "$WORK/out"
    : > "$WORK/state/calls.log"
    : > "$WORK/state/curl.log"
    : > "$WORK/state/curl_auth.log"
}

scenario() {
    echo "$2" > "$WORK/state/scen/$1"
}

base_env() {
    printf '%s ' \
        "STUB_STATE=$(printf '%q' "$WORK/state")" \
        "OSOPS_OS_CMD=$(printf '%q' "$STUB")" \
        "OSOPS_CURL=$(printf '%q' "${CURL_CMD:-$CSTUB}")" \
        "OSOPS_LOG_DIR=$(printf '%q' "$WORK/log")" \
        "TMPDIR=$(printf '%q' "$WORK/tmp")" \
        OS_REGION_NAME=RegionTest OS_INTERFACE=public \
        OS_AUTH_URL=https://keystone.test:5000/v3 OS_PROJECT_NAME=admin \
        OS_PROJECT_DOMAIN_NAME=Default OS_USERNAME=admin "OS_PASSWORD=$SECRET_PW"
}

# run_tmux "ENV..." ARGS... — jalankan script di tmux (prompt dari /dev/tty)
run_tmux() {
    local envs="$1" cmd=""
    shift
    (( $# > 0 )) && printf -v cmd '%q ' "$@"
    "${TM[@]}" kill-server 2>/dev/null || true
    "${TM[@]}" new-session -d -s t -x 220 -y 50 \
        "env $(base_env) $envs bash $(printf '%q' "$SCRIPT") $cmd; echo __EXIT=\$?; sleep 3600"
}

# run_direct [ENV=...]... -- ARGS... — tanpa tty (seperti cron); output di $OUT, exit code di $RC
run_direct() {
    local -a envs=()
    while (( $# > 0 )) && [[ "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    [[ "${1:-}" == "--" ]] && shift
    RC=0
    OUT="$(eval "env $(base_env)" '"${envs[@]}"' setsid -w bash '"$SCRIPT"' '"$@"' < /dev/null 2>&1)" || RC=$?
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
    screen_text | tail -n 15 | sed 's/^/     | /'
    return 1
}

keys() {
    "${TM[@]}" send-keys -t t "$@"
}

answer() {
    wait_for "$1" "$2" || return 1
    if [[ -n "$3" ]]; then keys "$3" Enter; else keys Enter; fi
}

tmux_exit() {
    wait_for '__EXIT=' 1 "${1:-60}" || { echo "?"; return 0; }
    screen_text | grep -o '__EXIT=[0-9]*' | tail -n 1 | cut -d= -f2
}

log_text() {
    cat "$WORK"/log/network/get-ip-info-*.log 2>/dev/null || true
}

calls() {
    cat "$WORK/state/calls.log"
}

csv_files() {
    find "$WORK/out" -maxdepth 1 -name '*.csv' | sort
}

csv_file() {
    csv_files | head -n 1
}

csv_body() {
    local f
    f="$(csv_file)"
    [[ -n "$f" ]] && tail -n +2 "$f"
}

# Baris CSV untuk satu query IP
csv_rows() {
    csv_body | grep -F "\"$1\"," | grep "^\"$1\"," || true
}

# Blok hasil di terminal (tanpa baris metode/progres/ringkasan)
result_blocks() {
    sed -n '/^━━ /,/^========================================$/p' <<< "$OUT" | sed '$d'
}

tmp_empty() {
    [[ -z "$(find "$WORK/tmp" -mindepth 1 2>/dev/null)" ]]
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

test_lib() {
    begin "lib"
    local out
    # shellcheck source=../../lib/netinfo.sh
    out="$(source "$ROOT/lib/netinfo.sh"
        for x in 10.0.0.5 010.0.0.1 256.1.1.1 1.2.3 2001:DB8:0:0:0:0:0:1 2001:0db8::0001 fe80:0:0:1:0:0:0:2 \
                 1:2:3:4:5:6:7:8 ::ffff:1.2.3.4 1:: :1 1::2::3 fe80::1%eth0 abc; do
            printf '%s=%s ' "$x" "$(ip_normalize "$x" || echo INVALID)"
        done
        ip4_in_cidr 10.0.0.130 10.0.0.128/28 && printf 'cidr-in '
        ip4_in_cidr 10.0.0.150 10.0.0.128/28 || printf 'cidr-out '
        ip4_in_cidr 10.0.0.5 10.0.0.5 && printf 'host-in '
        device_label compute:az-2; device_label compute:nova amphora-9; device_label Octavia; device_label network:foo)"
    expect_match "IPv4 valid" "$out" '10\.0\.0\.5=10\.0\.0\.5 '
    expect_match "leading zero ditolak" "$out" '010\.0\.0\.1=INVALID'
    expect_match "oktet > 255 ditolak" "$out" '256\.1\.1\.1=INVALID'
    expect_match "IPv6 dikanonisasi (huruf kecil + ::)" "$out" '2001:DB8:0:0:0:0:0:1=2001:db8::1 '
    expect_match "IPv6 leading zero" "$out" '2001:0db8::0001=2001:db8::1 '
    expect_match "IPv6 run nol terpanjang" "$out" 'fe80:0:0:1:0:0:0:2=fe80:0:0:1::2 '
    expect_match "IPv6 8 grup" "$out" '1:2:3:4:5:6:7:8=1:2:3:4:5:6:7:8 '
    expect_match "IPv6 embedded IPv4" "$out" '::ffff:1\.2\.3\.4=::ffff:102:304 '
    expect_match "IPv6 :1 ditolak" "$out" ' :1=INVALID'
    expect_match "IPv6 :: ganda ditolak" "$out" '1::2::3=INVALID'
    expect_match "IPv6 zone ditolak" "$out" 'fe80::1%eth0=INVALID'
    expect_match "CIDR /28 mencakup" "$out" 'cidr-in cidr-out host-in'
    expect_match "label device" "$out" 'Instance.Load balancer amphora.Load balancer VIP.network:foo'
}

test_cli() {
    begin "cli"
    run_direct -- --help
    expect_eq "--help exit 0" "$RC" 0
    expect_match "--help usage" "$OUT" 'Usage: get-ip-info.sh'

    run_direct -- --ip 10.0.0.5 --method foo
    expect_eq "--method tidak valid exit 1" "$RC" 1
    expect_match "pesan --method" "$OUT" '--method harus auto, api, atau cli'

    run_direct -- --ip 10.0.0.5 --parallel 0
    expect_match "--parallel 0 ditolak" "$OUT" '--parallel harus angka 1-64'

    run_direct -- --ip 10.0.0.5 --csv --output-dir "$WORK/tidak-ada"
    expect_match "--output-dir tidak ada" "$OUT" 'Direktori output tidak ada'

    run_direct -- --bogus
    expect_match "opsi tidak dikenal" "$OUT" 'Opsi tidak dikenal: --bogus'

    run_direct --
    expect_eq "tanpa tty dan tanpa --ip/--file exit 1" "$RC" 1
    expect_match "pesan butuh --ip/--file" "$OUT" 'gunakan --ip atau --file'

    run_direct -- --file "$WORK/tidak-ada.txt"
    expect_match "file tidak ada" "$OUT" "File '.*tidak-ada.txt' tidak ditemukan"

    printf '# kosong\n\n   \n' > "$WORK/empty.txt"
    run_direct -- --file "$WORK/empty.txt"
    expect_eq "file tanpa IP exit 1" "$RC" 1
    expect_match "pesan file kosong" "$OUT" 'Tidak ada IP di input'
    expect_eq "tidak ada CSV" "$(csv_files)" ""
    expect_eq "tidak ada panggilan cloud" "$(calls)" ""
}

test_golden() {
    begin "golden"
    run_direct -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out"
    expect_eq "exit 0" "$RC" 0
    expect_match "strategi bulk (>20 IP)" "$OUT" 'Strategi / metode +: bulk / api'
    expect_eq "header persis" "$(head -n 1 "$(csv_file)")" "$HEADER"
    expect_eq "isi CSV = fixtures/expected.csv" "$(csv_body)" "$(cat "$FIX/expected.csv")"
    expect_eq "permission 600" "$(stat -c %a "$(csv_file)")" 600
    expect_match "nama file" "$(csv_file)" '/out/ip-info-[0-9]{8}-[0-9]{6}\.csv$'
    expect_match "escape CSV (koma + kutip)" "$(csv_rows 10.0.0.3)" '"Cust, ""X"""'
    expect_eq "satu baris per kecocokan (10.0.0.5 = 2)" "$(csv_rows 10.0.0.5 | wc -l)" 2
    expect_eq "urutan mengikuti input" "$(csv_body | cut -d, -f1 | uniq | head -n 4 | tr '\n' ' ')" \
        '"203.0.113.10" "203.0.113.11" "203.0.113.12" "10.0.0.5" '
    expect_match "ringkasan per tipe" "$OUT" 'FIXED_IP +: 14 IP'
    expect_match "ringkasan input" "$OUT" 'IP dicari +: 26 \(valid 24, invalid 2, duplikat 1\)'
    expect_no_match "tanpa --deep: baris AAP tidak ada di ringkasan" "$OUT" 'ALLOWED_ADDRESS_PAIR +:'
    expect_true "direktori sementara dihapus" tmp_empty

    # CSV tidak menimpa file yang sudah ada
    run_direct -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out"
    run_direct -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out"
    expect_eq "tiga run = tiga CSV" "$(csv_files | wc -l)" 3
}

test_classify() {
    begin "classify"
    run_direct -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out"
    local r
    expect_match "FIP terasosiasi ke instance" "$(csv_rows 203.0.113.10)" '^"203\.0\.113\.10","FLOATING_IP","Instance",[^,]*,"web-01","cmp-01","'"$P_WEB"'".*"net-a","10\.0\.0\.0/24","10\.0\.0\.5"'
    expect_eq "port internal FIP (network:floatingip) tidak jadi hasil terpisah" "$(csv_rows 203.0.113.10 | wc -l)" 1
    expect_match "FIP tidak terasosiasi: Network Name = network floating" "$(csv_rows 203.0.113.11)" '"FLOATING_IP","Not associated","","","","","","","public",'
    r="$(csv_rows 10.0.0.5)"
    expect_match "fixed IP instance + floating IP-nya" "$r" '"FIXED_IP","Instance",.*"web-01".*"10\.0\.0\.5","f0000000-0000-4000-8000-000000000001","203\.0\.113\.10","ACTIVE","'"$PRJ_ACME"'","acme"'
    expect_match "IP private sama di project lain" "$r" '"app-02","cmp-02".*"net-b".*"beta","Cust, ""X"""'
    expect_match "Router gateway" "$(csv_rows 203.0.113.2)" '"Router gateway",[^,]*,"router-a"'
    expect_match "Router interface" "$(csv_rows 10.0.0.1)" '"Router interface",[^,]*,"router-a"'
    expect_match "Router interface (distributed)" "$(csv_rows 10.1.0.1)" '"Router interface",[^,]*,"router-a"'
    expect_match "Router interface (HA)" "$(csv_rows 10.0.0.3)" '"Router interface",[^,]*,"router-b"'
    expect_match "DHCP" "$(csv_rows 10.0.0.4)" '"FIXED_IP","DHCP"'
    expect_match "DVR FIP gateway" "$(csv_rows 203.0.113.3)" '"FIXED_IP","DVR FIP gateway"'
    expect_match "Octavia tanpa plugin: nama port" "$(csv_rows 10.1.0.20)" '"Load balancer VIP","lb-70000000-[^"]*","octavia-lb-70000000-0000-4000-8000-000000000001"'
    expect_match "catatan plugin Octavia" "$OUT" 'plugin Octavia \(loadbalancer\) tidak tersedia'
    expect_match "amphora" "$(csv_rows 10.1.0.21)" '"Load balancer amphora",[^,]*,"amphora-1234","cmp-03"'
    expect_match "Distributed (metadata)" "$(csv_rows 10.0.0.6)" '"Distributed \(metadata\)"'
    expect_match "Unattached port" "$(csv_rows 10.0.0.7)" '"Unattached port","","",'
    expect_match "device_owner lain apa adanya" "$(csv_rows 10.0.0.8)" '"baremetal:none","node-1"'
    expect_match "instance tidak ditemukan" "$(csv_rows 10.0.0.30)" '"Instance","50000000-0000-4000-8000-000000000009","\(not found\)"'
    expect_match "blok terminal: compute host" "$OUT" 'Host +: cmp-01  \(status ACTIVE\)'
    expect_match "blok terminal: jumlah kecocokan" "$OUT" '━━ 10\.0\.0\.5 — 2 kecocokan'

    reset_state
    scenario lb yes
    run_direct -- --ip 10.1.0.20 --csv --output-dir "$WORK/out"
    expect_match "Octavia dengan plugin: nama load balancer" "$(csv_rows 10.1.0.20)" '"Load balancer VIP","lb-70000000-[^"]*","web-lb"'
    expect_match "loadbalancer show dipanggil" "$(calls)" 'loadbalancer show 70000000-0000-4000-8000-000000000001 -f json'
}

test_notfound() {
    begin "notfound"
    run_direct -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out"
    expect_match "di dalam allocation pool" "$(csv_rows 10.0.0.100)" '"SUBNET_ONLY","No port \(in allocation pool\)"'
    expect_eq "CIDR sama di dua project → 2 subnet" "$(csv_rows 10.0.0.100 | wc -l)" 2
    expect_match "di luar allocation pool" "$(csv_rows 10.0.0.250)" '"No port \(outside allocation pool\)"'
    local r
    r="$(csv_rows 172.16.5.50)"
    expect_match "subnet tumpang-tindih: /16 (di luar pool)" "$r" '"No port \(outside allocation pool\)",.*"172\.16\.0\.0/16"'
    expect_match "subnet tumpang-tindih: /24 (di dalam pool)" "$r" '"No port \(in allocation pool\)",.*"172\.16\.5\.0/24"'
    expect_match "gateway subnet tanpa port" "$(csv_rows 172.16.0.1)" '"No port \(subnet gateway IP\)"'
    expect_match "tidak ada subnet → NOT_FOUND" "$(csv_rows 192.168.99.1)" '^"192\.168\.99\.1","NOT_FOUND"(,""){18}$'
    expect_match "IPv6 tanpa port → NOT_FOUND" "$(csv_rows 2001:db8::99)" '"NOT_FOUND"'
    expect_match "terminal: subnet" "$OUT" '━━ 10\.0\.0\.100 — tidak ada port; IP berada di 2 subnet'
    expect_match "terminal: NOT_FOUND" "$OUT" '━━ 192\.168\.99\.1 — tidak ditemukan \(NOT_FOUND\)'

    # pools sebagai string (format human OSC) → hasil sama
    reset_state
    scenario pools_string 1
    run_direct -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out"
    expect_eq "allocation pools string: CSV sama" "$(csv_body)" "$(cat "$FIX/expected.csv")"
}

test_deep() {
    begin "deep"
    run_direct -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out" --deep
    expect_eq "exit 0" "$RC" 0
    expect_eq "isi CSV = fixtures/expected-deep.csv" "$(csv_body)" "$(cat "$FIX/expected-deep.csv")"
    expect_match "AAP alamat persis + floating IP-nya" "$(csv_rows 10.0.0.100)" \
        '^"10\.0\.0\.100","ALLOWED_ADDRESS_PAIR","Instance",[^,]*,"vrrp-1",.*"'"$P_VRRP"'".*"10\.0\.0\.100","f0000000-0000-4000-8000-000000000003","203\.0\.113\.12"'
    expect_match "AAP CIDR mencakup IP" "$(csv_rows 10.0.0.130)" '"ALLOWED_ADDRESS_PAIR",.*"10\.0\.0\.128/28"'
    expect_eq "AAP menggantikan SUBNET_ONLY" "$(csv_rows 10.0.0.130 | wc -l)" 1
    expect_match "ringkasan AAP" "$OUT" 'ALLOWED_ADDRESS_PAIR +: 2 IP'
    expect_match "terminal: label Addr. pair" "$OUT" 'Addr\. pair +: 10\.0\.0\.128/28'

    reset_state
    run_direct -- --ip 10.0.0.130 --csv --output-dir "$WORK/out"
    expect_no_match "tanpa --deep: tidak dicari di AAP" "$(csv_body)" 'ALLOWED_ADDRESS_PAIR'
    expect_match "tanpa --deep: SUBNET_ONLY" "$(csv_body)" 'SUBNET_ONLY'
}

# Strategi per IP / massal dan metode api / cli → output identik
test_equivalence() {
    local deep st m ref="" refb="" body blocks
    begin "equivalence"
    for deep in "" --deep; do
        ref=""
        for st in per-ip bulk; do
            for m in api cli; do
                reset_state
                run_direct "OSOPS_IPINFO_STRATEGY=$st" -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out" \
                    --method "$m" ${deep:+"$deep"}
                body="$(csv_body)"
                blocks="$(result_blocks)"
                expect_match "$st/$m$deep: strategi/metode" "$OUT" "Strategi / metode +: $st / $m"
                if [[ -z "$ref" ]]; then
                    ref="$body"
                    refb="$blocks"
                    expect_match "$st/$m$deep: ada hasil" "$blocks" 'kecocokan'
                else
                    expect_eq "$st/$m$deep: CSV identik" "$body" "$ref"
                    expect_eq "$st/$m$deep: output terminal identik" "$blocks" "$refb"
                fi
            done
        done
    done

    # Format string lama OSC (fixed_ips "ip_address='..', ...")
    reset_state
    scenario fixed_string 1
    run_direct -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out" --method cli --deep
    expect_eq "fixed_ips/AAP sebagai string: CSV sama" "$(csv_body)" "$(cat "$FIX/expected-deep.csv")"

    # Pemanggilan per IP memakai filter server-side, massal tidak
    reset_state
    run_direct OSOPS_IPINFO_STRATEGY=per-ip -- --ip 10.0.0.5 --method cli
    expect_match "per-ip cli: port list --fixed-ip" "$(calls)" 'port list --fixed-ip ip-address=10\.0\.0\.5 --long -f json'
    expect_match "per-ip cli: floating ip list --fixed-ip-address" "$(calls)" 'floating ip list --fixed-ip-address 10\.0\.0\.5 --long -f json'
    expect_eq "per-ip cli: port show hanya untuk port yang cocok" "$(calls | grep -c '^port show' || true)" 2
}

test_input() {
    begin "input"
    printf '# daftar\r\n10.0.0.5\r\n  10.0.0.5  \r\n\r\n2001:DB8::10\r\n2001:db8:0:0:0:0:0:10\r\n999.1.1.1\r\nhost.example\r\n' > "$WORK/crlf.txt"
    run_direct -- --file "$WORK/crlf.txt" --csv --output-dir "$WORK/out"
    expect_eq "exit 0 (daftar)" "$RC" 0
    expect_match "statistik input" "$OUT" 'IP: 2 valid, 2 tidak valid, 2 duplikat dilewati'
    expect_eq "urutan + kanonisasi + CRLF" "$(csv_body | cut -d, -f1,2 | uniq | tr '\n' ' ')" \
        '"10.0.0.5","FIXED_IP" "2001:db8::10","FIXED_IP" "999.1.1.1","INVALID" "host.example","INVALID" '
    expect_match "strategi per-ip (<= 20 IP)" "$OUT" 'Strategi / metode +: per-ip / api'
    expect_match "log statistik input" "$(log_text)" 'INPUT_STATS lines=6 valid=2 invalid=2 duplicate=2'
    expect_match "log INVALID = SKIPPED" "$(log_text)" 'RESULT resource=999\.1\.1\.1 action=lookup result=SKIPPED'

    # Hanya IP tidak valid: tanpa panggilan cloud
    reset_state
    run_direct -- --ip abc
    expect_eq "satu IP tidak valid exit 1" "$RC" 1
    expect_match "pesan INVALID" "$OUT" '━━ abc — format IP tidak valid \(INVALID\)'
    expect_eq "tanpa panggilan cloud" "$(calls)" ""

    # --ip bisa diulang dan digabung dengan --file
    reset_state
    printf '10.0.0.4\n' > "$WORK/one.txt"
    run_direct -- --ip 10.0.0.1 --ip 10.0.0.3 --file "$WORK/one.txt" --csv --output-dir "$WORK/out"
    expect_eq "--ip berulang + --file" "$(csv_body | cut -d, -f1 | tr '\n' ' ')" '"10.0.0.1" "10.0.0.3" "10.0.0.4" '
}

test_exitcodes() {
    begin "exitcodes"
    run_direct -- --ip 10.0.0.5
    expect_eq "satu IP ditemukan exit 0" "$RC" 0
    expect_no_match "satu IP: tanpa ringkasan daftar" "$OUT" 'Ringkasan'
    expect_eq "tanpa --csv: tidak ada CSV" "$(csv_files)" ""
    run_direct -- --ip 192.168.99.1
    expect_eq "satu IP NOT_FOUND exit 1 (seperti mode lama)" "$RC" 1
    run_direct -- --ip 10.0.0.100
    expect_eq "satu IP SUBNET_ONLY exit 0" "$RC" 0
    run_direct -- --ip 192.168.99.1 --ip 10.0.0.5
    expect_eq "daftar dengan NOT_FOUND exit 0" "$RC" 0
}

test_filters() {
    begin "filters"
    run_direct -- --ip 10.0.0.5 --network net-b --csv --output-dir "$WORK/out"
    expect_eq "--network net-b: hanya app-02" "$(csv_body | cut -d, -f5)" '"app-02"'
    expect_match "log filter" "$(log_text)" "FILTER network=net-b network_id=$N_B"

    reset_state
    run_direct -- --ip 10.0.0.5 --project acme --csv --output-dir "$WORK/out"
    expect_eq "--project acme: hanya web-01" "$(csv_body | cut -d, -f5)" '"web-01"'

    reset_state
    run_direct -- --ip 10.0.0.5 --project "$PRJ_ACME" --csv --output-dir "$WORK/out"
    expect_eq "--project dengan ID" "$(csv_body | cut -d, -f5)" '"web-01"'

    reset_state
    run_direct -- --ip 203.0.113.10 --network public --csv --output-dir "$WORK/out"
    expect_match "--network = network floating IP" "$(csv_body)" '"FLOATING_IP"'
    reset_state
    run_direct -- --ip 203.0.113.10 --network net-a --csv --output-dir "$WORK/out"
    expect_match "--network = network port terasosiasi" "$(csv_body)" '"FLOATING_IP"'
    reset_state
    run_direct -- --ip 203.0.113.10 --project beta --csv --output-dir "$WORK/out"
    expect_match "--project lain: NOT_FOUND" "$(csv_body)" '"NOT_FOUND"'
    expect_eq "--project lain: satu IP exit 1" "$RC" 1

    reset_state
    run_direct -- --ip 10.0.0.100 --network net-b --csv --output-dir "$WORK/out"
    expect_eq "filter juga untuk subnet fallback" "$(csv_body | cut -d, -f10 | tr '\n' ' ')" '"net-b" '

    # Filter sama untuk strategi per IP dan massal
    local a b
    reset_state
    run_direct OSOPS_IPINFO_STRATEGY=per-ip -- --file "$FIX/ips.txt" --project acme --csv --output-dir "$WORK/out"
    a="$(csv_body)"
    reset_state
    run_direct OSOPS_IPINFO_STRATEGY=bulk -- --file "$FIX/ips.txt" --project acme --csv --output-dir "$WORK/out"
    b="$(csv_body)"
    expect_eq "--project: per-ip == bulk" "$a" "$b"
    expect_no_match "--project acme: tidak ada beta" "$a" '"beta"'

    reset_state
    run_direct -- --ip 10.0.0.5 --network dup
    expect_eq "nama network ambigu exit 1" "$RC" 1
    expect_match "pesan ambigu" "$OUT" "Nama network 'dup' ambigu \(2:"
    run_direct -- --ip 10.0.0.5 --project nope
    expect_match "project tidak ada" "$OUT" "Project 'nope' tidak ditemukan"
}

test_interactive() {
    begin "interactive"
    # Mode 1 (satu IP), CSV default N
    run_tmux "" --output-dir "$WORK/out"
    answer 'Pilih \[1-2\]' 1 '1' || return 0
    answer 'Masukkan IP:' 1 '10.0.0.5' || return 0
    answer 'Simpan hasil ke CSV.*\[y/N\]' 1 '' || return 0
    expect_eq "mode 1: exit 0" "$(tmux_exit)" 0
    expect_match "mode 1: hasil tampil" "$(screen_text)" '━━ 10\.0\.0\.5 — 2 kecocokan'
    expect_eq "mode 1: tanpa CSV (default N)" "$(csv_files)" ""
    expect_match "log sumber interaktif" "$(log_text)" 'INPUT source=interactive'

    # Mode 2 (file), CSV default Y — menggantikan "list → CSV" lama
    reset_state
    run_tmux "" --output-dir "$WORK/out"
    answer 'Pilih \[1-2\]' 1 '2' || return 0
    answer 'Path file daftar IP:' 1 "$FIX/ips.txt" || return 0
    answer 'Simpan hasil ke CSV.*\[Y/n\]' 1 '' || return 0
    expect_eq "mode 2: exit 0" "$(tmux_exit)" 0
    expect_eq "mode 2: CSV (default Y) = expected" "$(csv_body)" "$(cat "$FIX/expected.csv")"

    # --csv sudah diberikan: tidak ditanya
    reset_state
    run_tmux "" --csv --output-dir "$WORK/out"
    answer 'Pilih \[1-2\]' 1 '1' || return 0
    answer 'Masukkan IP:' 1 '10.0.0.4' || return 0
    expect_eq "--csv: exit 0" "$(tmux_exit)" 0
    expect_eq "--csv: tidak ada prompt CSV" "$(count_of 'Simpan hasil ke CSV')" 0
    expect_eq "--csv: CSV dibuat" "$(csv_files | wc -l)" 1

    reset_state
    run_tmux "" --output-dir "$WORK/out"
    answer 'Pilih \[1-2\]' 1 '9' || return 0
    expect_eq "pilihan tidak valid exit 1" "$(tmux_exit)" 1
}

test_partial() {
    begin "partial"
    scenario port_show_fail "$P_WEB"
    run_direct -- --ip 10.0.0.5 --method cli --csv --output-dir "$WORK/out"
    expect_eq "port show gagal: exit 1" "$RC" 1
    expect_match "port show gagal: (lookup failed)" "$(csv_rows 10.0.0.5)" '"Instance","","\(lookup failed\)"'
    expect_match "port lain tetap lengkap" "$(csv_rows 10.0.0.5)" '"app-02"'
    expect_match "peringatan terminal" "$OUT" 'data tidak lengkap'
    expect_match "log FAILED per IP" "$(log_text)" 'RESULT resource=10\.0\.0\.5 action=lookup result=FAILED'

    reset_state
    scenario port_show_gone "$P_WEB"
    run_direct -- --ip 10.0.0.5 --method cli --csv --output-dir "$WORK/out"
    expect_eq "port terhapus saat show: exit 0" "$RC" 0
    expect_eq "port terhapus: dilewati" "$(csv_rows 10.0.0.5 | wc -l)" 1

    reset_state
    scenario subnets fail
    run_direct -- --ip 192.168.99.1 --ip 10.0.0.5 --csv --output-dir "$WORK/out"
    expect_eq "subnet list gagal: exit 1" "$RC" 1
    expect_match "NOT_FOUND ditandai" "$OUT" 'daftar subnet gagal diambil'

    reset_state
    scenario projects fail
    run_direct -- --ip 10.0.0.5 --csv --output-dir "$WORK/out"
    expect_eq "project list gagal: exit 1" "$RC" 1
    expect_match "project (lookup failed)" "$(csv_rows 10.0.0.5)" '"\(lookup failed\)","\(lookup failed\)"'

    reset_state
    scenario servers fail
    run_direct -- --ip 10.0.0.5 --csv --output-dir "$WORK/out"
    expect_eq "server show gagal: exit 1" "$RC" 1
    expect_match "instance (lookup failed)" "$(csv_rows 10.0.0.5)" '"Instance","50000000-[^"]*","\(lookup failed\)"'

    reset_state
    scenario port_list fail
    run_direct -- --ip 10.0.0.5 --method cli
    expect_eq "port list gagal: exit 1" "$RC" 1
    expect_match "pesan port list gagal" "$OUT" 'port list --fixed-ip gagal'
}

test_deep_cli() {
    begin "deep_cli"
    run_direct -- --ip 10.0.0.100 --deep --method cli --csv --output-dir "$WORK/out"
    expect_eq "tanpa tty: hanya peringatan, exit 0" "$RC" 0
    expect_match "peringatan jumlah port" "$OUT" "--deep dengan metode cli: 18 port akan di-'port show'"
    expect_eq "port show untuk semua port" "$(calls | grep -c '^port show' || true)" 18
    expect_match "hasil AAP" "$(csv_body)" 'ALLOWED_ADDRESS_PAIR'

    reset_state
    run_tmux "" --ip 10.0.0.100 --deep --method cli --csv --output-dir "$WORK/out"
    answer 'Lanjutkan\? \[y/N\]' 1 'n' || return 0
    expect_eq "tty, jawab n: exit 0" "$(tmux_exit)" 0
    expect_match "pesan batal" "$(screen_text)" 'Dibatalkan'
    expect_eq "tidak ada port show" "$(calls | grep -c '^port show' || true)" 0
    expect_eq "tidak ada CSV" "$(csv_files)" ""
    expect_match "log keputusan" "$(log_text)" 'DECISION deep_cli=declined ports=18'

    reset_state
    run_tmux "" --ip 10.0.0.100 --deep --method cli --csv --output-dir "$WORK/out"
    wait_for 'perkiraan ~0 menit [0-9]+ detik' || return 0
    answer 'Lanjutkan\? \[y/N\]' 1 'y' || return 0
    expect_eq "tty, jawab y: exit 0" "$(tmux_exit)" 0
    expect_match "tty, y: hasil AAP" "$(csv_body)" 'ALLOWED_ADDRESS_PAIR'

    # Metode api: --deep tanpa konfirmasi (satu request massal)
    reset_state
    run_direct -- --ip 10.0.0.100 --deep --method api
    expect_no_match "api: tanpa peringatan port show" "$OUT" 'port akan di-'
}

test_api() {
    begin "api"
    scenario api_page 2
    run_direct -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out"
    expect_eq "pagination: CSV sama" "$(csv_body)" "$(cat "$FIX/expected.csv")"
    expect_match "pagination: link next diikuti" "$(cat "$WORK/state/curl.log")" 'https://neutron\.test:9696/v2\.0/ports\?marker='
    expect_no_match "pagination: host dari link tidak dipakai" "$(cat "$WORK/state/curl.log")" 'proxy-internal'
    expect_no_match "token tidak di argumen curl" "$(cat "$WORK/state/curl.log")" "$TOKEN"
    expect_no_match "token selalu lewat stdin" "$(cat "$WORK/state/curl_auth.log")" 'missing'
    expect_match "log METHOD" "$(log_text)" 'METHOD method=api strategy=bulk'

    reset_state
    run_direct OSOPS_IPINFO_STRATEGY=per-ip -- --ip 2001:DB8::10 --csv --output-dir "$WORK/out"
    expect_match "per-ip api: filter fixed_ips ter-encode" "$(cat "$WORK/state/curl.log")" 'ports\?fixed_ips=ip_address%3D2001%3Adb8%3A%3A10'
    expect_match "per-ip api: IPv6 ditemukan" "$(csv_body)" '"2001:db8::10","FIXED_IP"'

    reset_state
    scenario api fail
    run_direct -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out"
    expect_eq "api gagal → fallback cli, exit 0" "$RC" 0
    expect_match "pesan fallback" "$OUT" 'fallback ke cli'
    expect_eq "fallback: CSV sama" "$(csv_body)" "$(cat "$FIX/expected.csv")"

    reset_state
    CURL_CMD="/tidak/ada/curl" run_direct -- --ip 10.0.0.5
    expect_match "curl tidak ada → cli" "$OUT" 'curl tidak tersedia\); fallback ke cli'
    expect_no_match "curl tidak ada: tanpa token issue" "$(calls)" 'token issue'

    reset_state
    scenario api fail
    run_direct -- --ip 10.0.0.5 --method api
    expect_eq "--method api gagal: exit 1" "$RC" 1
    expect_match "pesan api gagal" "$OUT" 'Metode api gagal'
}

test_logging() {
    begin "logging"
    run_direct -- --file "$FIX/ips.txt" --csv --output-dir "$WORK/out" --deep
    local log run_id
    log="$(log_text)"
    expect_match "START" "$log" 'START '
    expect_match "INPUT" "$log" "INPUT source=args ip_args=0 input_file=.*ips\.txt network=- project=- deep=1 csv=1"
    expect_match "INPUT_STATS" "$log" 'INPUT_STATS lines=27 valid=24 invalid=2 duplicate=1'
    expect_match "STRATEGY" "$log" 'STRATEGY strategy=bulk'
    expect_match "RESULT per IP" "$log" 'RESULT resource=10\.0\.0\.5 action=lookup result=SUCCESS matches=2 types=FIXED_IP'
    expect_match "RESULT SUBNET_ONLY" "$log" 'RESULT resource=10\.0\.0\.250 action=lookup result=SUCCESS matches=0 types=SUBNET_ONLY'
    expect_match "SUMMARY" "$log" 'SUMMARY ips=26 valid=24 invalid=2 duplicate=1 floating_ip=3 fixed_ip=14 allowed_address_pair=2 subnet_only=3 not_found=2 invalid=2 matches=20 .*duration=[0-9]+s csv=.*ip-info-'
    expect_eq "log_result per IP (26)" "$(grep -cE 'RESULT resource=[^ ]+ action=lookup result=[A-Z]+ (matches=|reason=)' <<< "$log")" 26
    run_id="$(grep -o 'run=[^ ]*' <<< "$log" | head -n 1)"
    expect_eq "satu run_id" "$(grep -o 'run=[^ ]*' <<< "$log" | sort -u | wc -l)" 1
    expect_match "run_id terisi" "$run_id" 'run=.+'
    expect_eq "OS_PASSWORD tidak di log" "$(grep -rc "$SECRET_PW" "$WORK/log" | grep -vc ':0$' || true)" 0
    expect_eq "token tidak di log" "$(grep -rc "$TOKEN" "$WORK/log" | grep -vc ':0$' || true)" 0
}

test_discovery() {
    begin "discovery"
    local list clean="$WORK/clean"
    # Salinan bersih tanpa scripts.env lokal, log, dan file credential
    mkdir -p "$clean"
    tar -C "$ROOT" --exclude=./.git --exclude=./scripts.env --exclude=./log --exclude=./adminrc -cf - . | tar -C "$clean" -xf -
    list="$(bash "$clean/main.sh" --workdir "$clean" --list 2>&1)"
    # shellcheck disable=SC2016  # backtick literal di tabel Markdown
    expect_match "--list: script baru" "$list" '\| IP Information \| network \| `network/get-ip-info\.sh` \| no \|'
    expect_no_match "--list: path lama tidak ada" "$list" 'get-float-ip-info'
    expect_no_match "--list: Floating IP Information tidak ada" "$list" 'Floating IP Information'
    expect_no_match "--discover: tests/ dan lib/ tidak ikut" "$(bash "$ROOT/main.sh" --discover "$ROOT")" '(tests|lib)/'
}

# install.sh di user namespace (root palsu), INSTALL_DIR sementara
test_install() {
    begin "install"
    if ! unshare -r true 2>/dev/null; then
        echo "  ⚠️  unshare -r tidak tersedia: tes install DILEWATI"
        return 0
    fi
    local inst="$WORK/inst" out rc=0 sum_custom sum_env sum_unlisted
    mkdir -p "$inst/network" "$inst/custom-cat"
    # Salinan lama yang terdaftar di RENAMED_SCRIPTS
    printf '#!/bin/bash\n# @name: Floating IP Information\necho lama\n' > "$inst/network/get-float-ip-info.sh"
    # Script custom operator (tidak terdaftar) — tidak boleh disentuh
    printf '#!/bin/bash\n# @name: Custom Net Tool\necho custom\n' > "$inst/network/my-custom.sh"
    printf '#!/bin/bash\n# @name: Old Unlisted\necho unlisted\n' > "$inst/network/old-unlisted.sh"
    printf '#!/bin/bash\n# @name: Site Tool\necho site\n' > "$inst/custom-cat/site.sh"
    cat > "$inst/scripts.env" <<EOF
# lokal
Floating IP Lookup,network/get-float-ip-info.sh   # rename lama
!network/get-float-ip-info.sh
Abs Lookup,$inst/network/get-float-ip-info.sh
Custom Tool,network/my-custom.sh
EOF
    sum_custom="$(cat "$inst/network/my-custom.sh" "$inst/custom-cat/site.sh" | md5sum)"
    sum_unlisted="$(md5sum < "$inst/network/old-unlisted.sh")"
    sum_env="$(md5sum < "$inst/scripts.env")"

    out="$(OSOPS_INSTALL_DIR="$inst" OSOPS_BIN_PATH="$WORK/bin-osops" \
        unshare -r bash "$ROOT/install.sh" --skip-checks --log-group root 2>&1)" || rc=$?
    expect_eq "install exit 0" "$rc" 0
    expect_true "file lama yang terdaftar dihapus" test ! -e "$inst/network/get-float-ip-info.sh"
    expect_match "pesan hapus" "$out" "Script lama dihapus: $inst/network/get-float-ip-info\.sh \(di-rename menjadi network/get-ip-info\.sh\)"
    expect_true "script baru terpasang" test -f "$inst/network/get-ip-info.sh"
    expect_true "lib/netinfo.sh terpasang" test -f "$inst/lib/netinfo.sh"
    expect_true "tests/ tidak di-install" test ! -e "$inst/tests"
    expect_eq "script custom operator utuh" "$(cat "$inst/network/my-custom.sh" "$inst/custom-cat/site.sh" | md5sum)" "$sum_custom"
    expect_eq "script yatim yang tidak terdaftar tidak dihapus" "$(md5sum < "$inst/network/old-unlisted.sh")" "$sum_unlisted"
    expect_eq "scripts.env tidak diubah" "$(md5sum < "$inst/scripts.env")" "$sum_env"
    expect_match "peringatan entry rename" "$out" 'Floating IP Lookup,network/get-float-ip-info\.sh +→ ganti menjadi: Floating IP Lookup,network/get-ip-info\.sh'
    expect_match "peringatan entry hide" "$out" '!network/get-float-ip-info\.sh +→ ganti menjadi: !network/get-ip-info\.sh'
    expect_match "peringatan entry path absolut" "$out" "Abs Lookup,$inst/network/get-float-ip-info\.sh +→ ganti menjadi: Abs Lookup,network/get-ip-info\.sh"
    expect_no_match "entry lain tidak dilaporkan" "$out" 'Custom Tool,network/my-custom\.sh +→'

    local list
    list="$(bash "$ROOT/main.sh" --workdir "$inst" --list 2>&1)"
    expect_match "TUI instalasi: IP Information" "$list" 'network/get-ip-info\.sh'
    expect_no_match "TUI instalasi: tanpa path lama" "$list" 'get-float-ip-info\.sh`'
    expect_match "TUI instalasi: script custom tetap muncul" "$list" 'Custom Tool'

    # Jalankan ulang: tidak ada yang dihapus lagi
    out="$(OSOPS_INSTALL_DIR="$inst" OSOPS_BIN_PATH="$WORK/bin-osops" \
        unshare -r bash "$ROOT/install.sh" --skip-checks --log-group root 2>&1)" || true
    expect_no_match "install kedua: tidak ada penghapusan" "$out" 'Script lama dihapus'
    expect_eq "install kedua: script custom utuh" "$(cat "$inst/network/my-custom.sh" "$inst/custom-cat/site.sh" | md5sum)" "$sum_custom"
}

test_readonly() {
    begin "readonly"
    local all
    all="$(cat "$WORK/all-calls.log" 2>/dev/null || true)"
    expect_match "ada panggilan yang diarsipkan" "$all" 'port list'
    expect_no_match "tidak ada create/set/delete/unset/add/remove" "$all" \
        '(^| )(create|set|unset|delete|add|remove|associate|disassociate)( |$)'
    expect_eq "semua panggilan read-only" "$(grep -vE '^(--os-compute-api-version [0-9.]+ )?(network list|subnet list|project list|domain list|router list|floating ip list|floating ip show|port list|port show|server list|server show|loadbalancer show|token issue|catalog show) ' <<< "$all" || true)" ""
    expect_no_match "curl hanya GET (tanpa -X/--data)" "$(cat "$WORK"/all-curl.log 2>/dev/null || true)" '(^| )(-X|--request|-d|--data)'
}

# ============================================================
# Run
# ============================================================

for t in lib cli golden classify notfound deep equivalence input exitcodes filters interactive \
         partial deep_cli api logging discovery install readonly; do
    if want "$t"; then
        "test_$t"
        [[ -f "$WORK/state/curl.log" ]] && cat "$WORK/state/curl.log" >> "$WORK/all-curl.log"
    fi
done

echo
echo "========================================"
echo "Lulus: $PASS   Gagal: $FAIL"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
