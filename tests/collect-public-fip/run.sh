#!/bin/bash
# ============================================================
# Tes network/collect-public-fip.sh dengan stub OpenStack CLI dan stub curl
# (tanpa cloud).
#
#   bash tests/collect-public-fip/run.sh            # semua tes
#   bash tests/collect-public-fip/run.sh api        # hanya tes yang namanya cocok
#   KEEP=1 bash tests/collect-public-fip/run.sh     # simpan direktori kerja
#
# Butuh: bash, jq, tmux, setsid, fzf (untuk tes picker). Picker dijalankan
# di tmux karena prompt membaca dari /dev/tty.
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/network/collect-public-fip.sh"
STUB="$HERE/stub/openstack"
CSTUB="$HERE/stub/curl"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cpf-test.XXXXXX")"
TM=(tmux -L "cpf-test-$$")
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()

N_PUB="b0000000-0000-4000-8000-000000000001"
N_INT="b0000000-0000-4000-8000-000000000004"
TOKEN="gAAAAAstubTOKENrahasia-0123456789"
SECRET_PW="StubPassw0rd-Rahasia"
HEADER="Floating ID,Floating IP Address,Project Name,Status,Instance ID,Instance Name,Created At,Updated At"

# Isi CSV yang diharapkan untuk network "public" (urut IP numerik)
read -r -d '' EXPECTED_PUBLIC <<'EOF' || true
"f0000000-0000-4000-8000-000000000005","9.255.255.255","beta","DOWN","","","2026-01-06T10:00:00Z","2026-01-06T10:00:00Z"
"f0000000-0000-4000-8000-000000000002","10.0.0.9","Acme, ""Prod""","ACTIVE","50000000-0000-4000-8000-000000000002","db,01","2026-01-03T10:00:00Z","2026-01-03T11:00:00Z"
"f0000000-0000-4000-8000-000000000001","10.0.0.10","Acme, ""Prod""","ACTIVE","50000000-0000-4000-8000-000000000001","web-01","2026-01-01T10:00:00Z","2026-01-02T10:00:00Z"
"f0000000-0000-4000-8000-000000000003","10.0.0.100","beta","ACTIVE","","","2026-01-04T10:00:00Z","2026-01-04T10:00:00Z"
"f0000000-0000-4000-8000-000000000004","10.0.1.2","beta","ACTIVE","","","2026-01-05T10:00:00Z","2026-01-05T10:00:00Z"
"f0000000-0000-4000-8000-000000000006","10.0.1.20","Acme, ""Prod""","DOWN","50000000-0000-4000-8000-000000000003","app-03","2026-01-07T10:00:00Z","2026-01-07T12:00:00Z"
"f0000000-0000-4000-8000-000000000007","10.0.1.30","a0000000000000000000000000000009 (not found)","ACTIVE","50000000-0000-4000-8000-000000000009","(not found)","2026-01-08T10:00:00Z","2026-01-08T10:00:00Z"
EOF

for tool in jq tmux setsid fzf; do
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
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "dapat: '$2'  harap: '$3'"; fi
}

expect_match() {
    if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "dapat: '${2:0:600}'  pola: '$3'"; fi
}

expect_no_match() {
    if [[ "$2" =~ $3 ]]; then bad "$1" "pola tidak boleh muncul: '$3'"; else ok "$1"; fi
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
        "OSOPS_FZF=$(printf '%q' "${FZF_CMD:-fzf}")" \
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
    "${TM[@]}" new-session -d -s t -x 200 -y 50 \
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
    wait_for "$1" "$2" && keys "$3" Enter
}

tmux_exit() {
    wait_for '__EXIT=' 1 "${1:-60}" || { echo "?"; return 0; }
    screen_text | grep -o '__EXIT=[0-9]*' | tail -n 1 | cut -d= -f2
}

log_text() {
    cat "$WORK"/log/network/collect-public-fip-*.log 2>/dev/null || true
}

calls() {
    cat "$WORK/state/calls.log"
}

csv_files() {
    find "$WORK/out" -maxdepth 1 -name '*.csv' | sort
}

# csv_of NAMA-AMAN — satu-satunya CSV untuk network itu
csv_of() {
    find "$WORK/out" -maxdepth 1 -name "fip-$1-*.csv" | head -n 1
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

test_cli() {
    begin "cli"

    run_direct -- --help
    expect_eq "--help exit 0" "$RC" 0
    expect_match "--help menampilkan usage" "$OUT" 'Usage: collect-public-fip.sh'

    run_direct -- --method foo --network public
    expect_eq "--method tidak valid exit 1" "$RC" 1
    expect_match "pesan --method" "$OUT" '--method harus auto, api, atau cli'

    run_direct -- --parallel 0 --network public
    expect_match "--parallel 0 ditolak" "$OUT" '--parallel harus angka 1-64'
    run_direct -- --parallel abc --network public
    expect_match "--parallel abc ditolak" "$OUT" '--parallel harus angka 1-64'

    run_direct -- --output-dir "$WORK/tidak-ada" --network public
    expect_match "--output-dir tidak ada" "$OUT" 'Direktori output tidak ada'

    run_direct -- --pattern '(' --output-dir "$WORK/out"
    expect_match "--pattern regex tidak valid" "$OUT" 'bukan regex yang valid'

    run_direct -- --output-dir "$WORK/out"
    expect_eq "tanpa tty dan tanpa --network exit 1" "$RC" 1
    expect_match "pesan butuh --network" "$OUT" 'gunakan --network'

    run_direct -- --bogus
    expect_match "opsi tidak dikenal" "$OUT" 'Opsi tidak dikenal: --bogus'
    expect_eq "tidak ada CSV" "$(csv_files)" ""
}

test_pattern() {
    begin "pattern"

    # Menu bernomor (fzf tidak ada) — daftar tampil, lalu batal
    FZF_CMD="/tidak/ada/fzf" run_tmux "" --output-dir "$WORK/out"
    wait_for 'Pilih network' || return 0
    local s
    s="$(screen_text)"
    expect_match "public cocok" "$s" ' public +b0000000-0000-4000-8000-000000000001'
    expect_match "PUB-01 cocok (huruf besar)" "$s" 'PUB-01 +b0000000-0000-4000-8000-000000000002 +shared=yes +subnets=1'
    expect_match "Public-Lab cocok" "$s" 'Public-Lab'
    expect_match "subnet dihitung" "$s" 'public +b0000000-0000-4000-8000-000000000001 +shared=no +subnets=2'
    expect_no_match "pub-internal (bukan external) tidak muncul" "$s" 'pub-internal'
    expect_no_match "provider-ext tidak cocok pola" "$s" 'provider-ext'
    keys Enter
    expect_eq "kosong = batal, exit 0" "$(tmux_exit)" 0
    expect_match "pesan batal" "$(screen_text)" 'Tidak ada network dipilih'

    # Pola lain
    FZF_CMD="/tidak/ada/fzf" run_tmux "" --pattern LAB --output-dir "$WORK/out"
    wait_for 'Pilih network' || return 0
    s="$(screen_text)"
    expect_match "pola LAB: Public-Lab" "$s" '1\. Public-Lab'
    expect_no_match "pola LAB: public tidak muncul" "$s" ' 2\. '
    keys Enter
    tmux_exit >/dev/null

    # Tidak ada yang cocok: daftar semua external network, exit 1 (tanpa tty pun)
    run_direct -- --pattern zzz --output-dir "$WORK/out"
    expect_eq "tidak cocok exit 1" "$RC" 1
    expect_match "pesan tidak cocok" "$OUT" "Tidak ada external network yang namanya cocok dengan pola 'zzz'"
    expect_match "daftar external ditampilkan" "$OUT" 'provider-ext +b0000000-0000-4000-8000-000000000005'
    expect_no_match "daftar tanpa network internal" "$OUT" 'pub-internal'
    expect_match "log pola" "$(log_text)" 'INPUT pattern=zzz'
}

test_fzf_multi() {
    begin "fzf_multi"
    run_tmux "" --output-dir "$WORK/out"
    wait_for 'network >' || return 0
    wait_for 'Public-Lab' || return 0
    expect_no_match "fzf: pub-internal tidak muncul" "$(screen_text)" 'pub-internal'
    # Urutan (case-insensitive): pub ext/02, PUB-01, public, Public-Lab
    keys Down Tab Tab Enter
    expect_eq "exit 0" "$(tmux_exit)" 0
    expect_eq "dua CSV" "$(csv_files | wc -l)" 2
    expect_true_file "CSV PUB-01" "$(csv_of PUB-01)"
    expect_true_file "CSV public" "$(csv_of public)"
    expect_match "ringkasan gabungan" "$(screen_text)" 'SUCCESS +PUB-01 +1 FIP'
    expect_eq "CSV PUB-01 berisi 1 baris" "$(tail -n +2 "$(csv_of PUB-01)")" \
        '"f0000000-0000-4000-8000-000000000011","172.16.0.5","Acme, ""Prod""","DOWN","","","2026-02-01T10:00:00Z","2026-02-01T10:00:00Z"'
    expect_eq "log_result per network" "$(log_text | grep -c 'RESULT resource=b0000000.* action=collect-public-fip result=SUCCESS')" 2
    expect_true "direktori sementara dihapus" tmp_empty
}

expect_true_file() {
    if [[ -n "$2" && -f "$2" ]]; then ok "$1"; else bad "$1" "file tidak ada"; fi
}

expect_true() {
    local desc="$1"
    shift
    if "$@"; then ok "$desc"; else bad "$desc"; fi
}

test_menu() {
    begin "menu"
    FZF_CMD="/tidak/ada/fzf" run_tmux "" --output-dir "$WORK/out"
    answer 'Pilih network' 1 '9' || return 0
    wait_for 'Pilihan tidak valid: 9' || return 0
    answer 'Pilih network' 2 '3, 4,3' || return 0
    expect_eq "exit 0" "$(tmux_exit)" 0
    expect_eq "dua CSV (duplikat diabaikan)" "$(csv_files | wc -l)" 2
    expect_true_file "CSV public" "$(csv_of public)"
    expect_true_file "CSV Public-Lab (kosong)" "$(csv_of Public-Lab)"
    expect_eq "CSV kosong hanya header" "$(cat "$(csv_of Public-Lab)")" "$HEADER"

    FZF_CMD="/tidak/ada/fzf" run_tmux "" --output-dir "$WORK/out"
    answer 'Pilih network' 1 'all' || return 0
    expect_eq "all: exit 0" "$(tmux_exit)" 0
    expect_match "all: nama network disanitasi" "$(csv_files)" 'fip-pub_ext_02-[0-9]{8}-[0-9]{6}\.csv'
}

test_network_arg() {
    begin "network_arg"
    run_direct -- --network public --network "$N_PUB" --output-dir "$WORK/out"
    expect_eq "nama + ID sama → satu network, exit 0" "$RC" 0
    expect_eq "satu CSV" "$(csv_files | wc -l)" 1

    run_direct -- --network pub-internal --output-dir "$WORK/out"
    expect_eq "network internal ditolak" "$RC" 1
    expect_match "pesan bukan external" "$OUT" "Network 'pub-internal' tidak ditemukan atau bukan external network"

    run_direct -- --network "$N_INT" --output-dir "$WORK/out"
    expect_match "ID network internal ditolak" "$OUT" 'bukan external network'

    run_direct -- --network dup-ext --output-dir "$WORK/out"
    expect_eq "nama ambigu exit 1" "$RC" 1
    expect_match "pesan ambigu + ID" "$OUT" "ambigu \(2 network\)"
    expect_match "ID ditampilkan" "$OUT" 'b0000000-0000-4000-8000-000000000007'

    run_direct -- --network provider-ext --pattern zzz --output-dir "$WORK/out"
    expect_eq "--network melewati pola" "$RC" 0
}

test_auto() {
    begin "auto"
    run_direct -- --network public --output-dir "$WORK/out"
    expect_eq "exit 0" "$RC" 0
    expect_match "metode api dipakai" "$OUT" 'Metode +: api'
    expect_match "list --long dicek dulu" "$(calls)" "floating ip list --network $N_PUB --long -f json"
    expect_match "log alasan metode" "$(log_text)" 'METHOD network_id=.* method=api reason="floating ip list tidak memuat'
    expect_eq "tidak ada floating ip show" "$(calls | grep -c 'floating ip show' || true)" 0
    expect_eq "CSV api" "$(tail -n +2 "$(csv_of public)")" "$EXPECTED_PUBLIC"
    expect_eq "header persis" "$(head -n 1 "$(csv_of public)")" "$HEADER"
    expect_eq "permission 600" "$(stat -c %a "$(csv_of public)")" 600
    expect_match "nama file" "$(csv_of public)" "/out/fip-public-[0-9]{8}-[0-9]{6}\.csv$"
    expect_match "endpoint public + /v2.0" "$(cat "$WORK/state/curl.log")" 'https://neutron.test:9696/v2.0/floatingips\?floating_network_id='
    expect_match "compute microversion di-pin" "$(cat "$WORK/state/compute_version" 2>/dev/null)" '^2\.1$'

    # list sudah lengkap → metode list, tanpa token dan curl
    reset_state
    scenario list_full 1
    run_direct -- --network public --output-dir "$WORK/out"
    expect_match "list lengkap: metode list" "$OUT" 'Metode +: list'
    expect_eq "list lengkap: tanpa curl" "$(wc -l < "$WORK/state/curl.log")" 0
    expect_no_match "list lengkap: tanpa token issue" "$(calls)" 'token issue'
    expect_eq "CSV list sama" "$(tail -n +2 "$(csv_of public)")" "$EXPECTED_PUBLIC"
}

test_fallback() {
    local s
    begin "fallback"
    scenario api fail
    run_direct -- --network public --output-dir "$WORK/out"
    expect_eq "api gagal → exit 0 (fallback)" "$RC" 0
    expect_match "fallback ke cli" "$OUT" 'fallback ke cli'
    expect_match "metode akhir cli" "$OUT" 'Metode +: cli'
    expect_match "log alasan fallback" "$(log_text)" 'method=cli reason="fallback api: request API gagal'
    expect_eq "CSV cli sama" "$(tail -n +2 "$(csv_of public)")" "$EXPECTED_PUBLIC"

    reset_state
    CURL_CMD="/tidak/ada/curl" run_direct -- --network public --output-dir "$WORK/out"
    expect_match "curl tidak ada → cli" "$OUT" 'curl tidak tersedia\); fallback ke cli'
    expect_no_match "curl tidak ada: tanpa token issue" "$(calls)" 'token issue'

    reset_state
    scenario catalog noregion
    run_direct -- --network public --output-dir "$WORK/out"
    expect_match "endpoint region tidak ada → cli" "$OUT" 'endpoint network \(interface=public, region=RegionTest\) tidak ditemukan'

    reset_state
    scenario token fail
    run_direct -- --network public --output-dir "$WORK/out"
    expect_match "token gagal → cli" "$OUT" 'token issue gagal.*fallback ke cli'

    # --method api: tanpa fallback
    reset_state
    scenario api fail
    run_direct -- --network public --method api --output-dir "$WORK/out"
    expect_eq "--method api gagal exit 1" "$RC" 1
    expect_match "pesan api gagal" "$OUT" 'metode api: request API gagal'
    expect_eq "tanpa CSV" "$(csv_files)" ""
    expect_eq "tanpa floating ip show" "$(calls | grep -c 'floating ip show' || true)" 0
    s="$(log_text | grep 'action=collect-public-fip')"
    expect_match "log_result FAILED" "$s" 'result=FAILED name=public method=- count=0 file=- duration=[0-9]+s msg="metode api'

    reset_state
    CURL_CMD="/tidak/ada/curl" run_direct -- --network public --method api --output-dir "$WORK/out"
    expect_match "--method api tanpa curl ditolak" "$OUT" 'curl tidak ditemukan'
}

test_pagination() {
    begin "pagination"
    run_direct OSOPS_FIP_PAGE_LIMIT=2 -- --network public --method api --output-dir "$WORK/out"
    expect_eq "exit 0" "$RC" 0
    expect_eq "4 request (2+2+2+1)" "$(wc -l < "$WORK/state/curl.log")" 4
    expect_eq "semua 7 floating IP" "$(tail -n +2 "$(csv_of public)")" "$EXPECTED_PUBLIC"
    expect_no_match "link next host proxy tidak dipakai" "$(cat "$WORK/state/curl.log")" 'proxy-internal'
    expect_match "marker dari link next dipakai" "$(cat "$WORK/state/curl.log")" 'neutron.test:9696/v2.0/floatingips\?floating_network_id=.*&limit=2&marker='
    expect_match "log jumlah halaman" "$(log_text)" 'API_FETCH path=floatingips pages=4 count=7'

    # Halaman dipaksa server (tanpa limit dari script)
    reset_state
    scenario api_page 3
    run_direct -- --network public --method api --output-dir "$WORK/out"
    expect_eq "server-side paging: 3 request" "$(wc -l < "$WORK/state/curl.log")" 3
    expect_eq "server-side paging: 7 baris" "$(tail -n +2 "$(csv_of public)" | wc -l)" 7
}

test_token() {
    begin "token"
    run_direct OS_CACERT=/etc/pki/ca.pem OS_INSECURE=true -- --network public --method api --output-dir "$WORK/out"
    expect_eq "exit 0" "$RC" 0
    expect_no_match "token tidak di argumen curl" "$(cat "$WORK/state/curl.log")" "$TOKEN"
    expect_match "config curl dari stdin" "$(cat "$WORK/state/curl.log")" '-K -'
    expect_eq "header token diterima stub" "$(sort -u "$WORK/state/curl_auth.log")" ok
    expect_match "OS_CACERT dipakai" "$(cat "$WORK/state/curl.log")" '--cacert /etc/pki/ca.pem'
    expect_match "OS_INSECURE dipakai" "$(cat "$WORK/state/curl.log")" '--insecure'
    expect_eq "token tidak di log" "$(grep -rlF "$TOKEN" "$WORK/log" || true)" ""
    expect_eq "token tidak di CSV" "$(grep -rlF "$TOKEN" "$WORK/out" || true)" ""
    expect_eq "token tidak di file sementara" "$(grep -rlF "$TOKEN" "$WORK/tmp" || true)" ""
    expect_eq "password tidak di log" "$(grep -rlF "$SECRET_PW" "$WORK/log" || true)" ""
    expect_no_match "token tidak di output" "$OUT" "$TOKEN"
}

test_instance_rules() {
    local f
    begin "instance_rules"
    run_direct -- --network public --method api --output-dir "$WORK/out"
    f="$(csv_of public)"
    expect_match "compute:nova → instance" "$(grep '"10.0.0.10"' "$f")" '"50000000-0000-4000-8000-000000000001","web-01"'
    expect_match "compute:az1 → instance (nama berkoma ter-escape)" "$(grep '"10.0.0.9"' "$f")" '"50000000-0000-4000-8000-000000000002","db,01"'
    expect_match "router_gateway → kosong" "$(grep '"10.0.0.100"' "$f")" '"ACTIVE","",""'
    expect_match "router_interface → kosong" "$(grep '"10.0.1.2"' "$f")" '"ACTIVE","",""'
    expect_match "tanpa port → kosong" "$(grep '"9.255.255.255"' "$f")" '"DOWN","",""'
    expect_match "DOWN tapi terasosiasi → instance tetap diisi" "$(grep '"10.0.1.20"' "$f")" '"DOWN","50000000-0000-4000-8000-000000000003","app-03"'
    expect_match "instance terhapus → (not found)" "$(grep '"10.0.1.30"' "$f")" '"50000000-0000-4000-8000-000000000009","\(not found\)"'
    expect_match "project tidak ada → ID (not found)" "$(grep '"10.0.1.30"' "$f")" '"a0000000000000000000000000000009 \(not found\)"'
    expect_match "project berkoma/kutip ter-escape" "$(grep '"10.0.0.10"' "$f")" '"Acme, ""Prod"""'
    expect_eq "server show per ID (≤ 20)" "$(calls | grep -c 'server show' || true)" 4
    expect_eq "satu project list" "$(calls | grep -c 'project list' || true)" 1

    expect_match "ringkasan status" "$OUT" 'Per status +: ACTIVE=5  DOWN=2'
    expect_match "ringkasan instance" "$OUT" 'Terasosiasi ke instance +: 4'
    expect_match "ringkasan non-instance" "$OUT" 'Terasosiasi ke non-instance : 2'
    expect_match "ringkasan tidak terasosiasi" "$OUT" 'Tidak terasosiasi +: 1'
    expect_match "ringkasan not found" "$OUT" 'Instance \(not found\) +: 1'
    expect_match "ringkasan region" "$OUT" 'Region +: RegionTest'

    local l
    l="$(log_text)"
    expect_match "log_result lengkap" "$l" "RESULT resource=$N_PUB action=collect-public-fip result=SUCCESS name=public method=api count=7 file=$WORK/out/fip-public-[0-9-]+\.csv duration=[0-9]+s msg=ok"
    expect_no_match "isi CSV tidak di log (nama server)" "$l" 'web-01|db,01'
    expect_no_match "isi CSV tidak di log (IP)" "$l" '10\.0\.0\.10'
}

test_cli_method() {
    begin "cli_method"
    run_direct -- --network public --method cli --parallel 3 --output-dir "$WORK/out"
    expect_eq "exit 0" "$RC" 0
    expect_eq "7 floating ip show" "$(calls | grep -c '^floating ip show' || true)" 7
    expect_match "progres" "$OUT" 'floating ip show: 7/7 selesai'
    expect_eq "CSV cli (port_details string) sama" "$(tail -n +2 "$(csv_of public)")" "$EXPECTED_PUBLIC"
    expect_eq "tanpa curl" "$(wc -l < "$WORK/state/curl.log")" 0

    reset_state
    scenario show_gone f0000000-0000-4000-8000-000000000003
    run_direct -- --network public --method cli --output-dir "$WORK/out"
    expect_eq "FIP terhapus saat show: exit 0" "$RC" 0
    expect_eq "FIP terhapus: 6 baris" "$(tail -n +2 "$(csv_of public)" | wc -l)" 6
    expect_match "FIP terhapus: catatan" "$OUT" '1 floating IP terhapus selama proses'
    expect_match "FIP terhapus: log SKIPPED" "$(log_text)" 'SKIPPED resource=f0000000-0000-4000-8000-000000000003'

    reset_state
    scenario show_fail f0000000-0000-4000-8000-000000000003
    run_direct -- --network public --method cli --output-dir "$WORK/out"
    expect_eq "show gagal: exit 1" "$RC" 1
    expect_eq "show gagal: CSV tetap ditulis (6 baris)" "$(tail -n +2 "$(csv_of public)" | wc -l)" 6
    expect_match "show gagal: pesan" "$OUT" '1 floating ip show gagal'
    expect_match "show gagal: log FAILED" "$(log_text)" 'action=collect-public-fip result=FAILED .*msg="1 floating ip show gagal'
}

test_nodetails() {
    begin "nodetails"
    scenario nodetails 1
    run_direct -- --network public --method api --output-dir "$WORK/out"
    expect_eq "api tanpa port_details: exit 0" "$RC" 0
    expect_match "port diambil lewat API" "$(cat "$WORK/state/curl.log")" 'v2.0/ports\?fields=id&fields=device_owner&fields=device_id&id='
    expect_eq "api tanpa port_details: CSV sama" "$(tail -n +2 "$(csv_of public)")" "$EXPECTED_PUBLIC"
    expect_match "catatan extension" "$OUT" 'port_details tidak tersedia'

    reset_state
    scenario nodetails 1
    run_direct -- --network public --method cli --output-dir "$WORK/out"
    expect_eq "cli tanpa port_details: 6 port show" "$(calls | grep -c '^port show' || true)" 6
    expect_eq "cli tanpa port_details: CSV sama" "$(tail -n +2 "$(csv_of public)")" "$EXPECTED_PUBLIC"
}

test_server_list() {
    begin "server_list"
    # 25 FIP dengan instance berbeda (> 20 → satu server list)
    jq -n '[ range(1; 26) as $i
             | { id: "f1000000-0000-4000-8000-\($i | tostring | ("000000000000" + .) | .[-12:])",
                 floating_ip_address: "10.9.0.\($i)", floating_network_id: "b0000000-0000-4000-8000-000000000001",
                 project_id: "a0000000000000000000000000000002", status: "ACTIVE",
                 port_id: "e1000000-0000-4000-8000-\($i | tostring | ("000000000000" + .) | .[-12:])",
                 port_details: { device_owner: "compute:nova",
                                 device_id: "51000000-0000-4000-8000-\($i | tostring | ("000000000000" + .) | .[-12:])" },
                 created_at: "2026-03-01T00:00:00Z", updated_at: "2026-03-01T00:00:00Z" } ]' > "$WORK/state/fips.json"
    jq -n '[ range(1; 25) as $i | { ID: "51000000-0000-4000-8000-\($i | tostring | ("000000000000" + .) | .[-12:])", Name: "vm-\($i)" } ]' \
        > "$WORK/state/servers.json"
    run_direct -- --network public --output-dir "$WORK/out"
    expect_eq "exit 0" "$RC" 0
    expect_eq "satu server list --all-projects" "$(calls | grep -c 'server list --all-projects -n -f json' || true)" 1
    expect_eq "tanpa server show" "$(calls | grep -c 'server show' || true)" 0
    expect_no_match "tanpa --limit (semua halaman)" "$(calls | grep 'server list')" '--limit'
    expect_match "instance ke-25 (not found)" "$(grep '"10.9.0.25"' "$(csv_of public)")" '"\(not found\)"'
    expect_match "nama dari server list" "$(grep '"10.9.0.3"' "$(csv_of public)")" '"vm-3"'
    expect_match "urut numerik 10.9.0.2 sebelum 10.9.0.10" "$(tail -n +2 "$(csv_of public)" | cut -d, -f2 | head -n 3 | tr '\n' ' ')" '"10.9.0.1" "10.9.0.2" "10.9.0.3"'

    reset_state
    jq -n '[ range(1; 26) as $i
             | { id: "f1000000-0000-4000-8000-\($i | tostring | ("000000000000" + .) | .[-12:])",
                 floating_ip_address: "10.9.0.\($i)", floating_network_id: "b0000000-0000-4000-8000-000000000001",
                 project_id: "a0000000000000000000000000000002", status: "ACTIVE", port_id: "e",
                 port_details: { device_owner: "compute:nova", device_id: "51000000-0000-4000-8000-\($i)" },
                 created_at: "", updated_at: "" } ]' > "$WORK/state/fips.json"
    scenario servers fail
    run_direct -- --network public --output-dir "$WORK/out"
    expect_eq "server list gagal: exit 1" "$RC" 1
    expect_match "server list gagal: (lookup failed)" "$(sed -n 2p "$(csv_of public)")" '"\(lookup failed\)"'
    expect_match "server list gagal: log FAILED" "$(log_text)" 'RESULT resource=servers action=lookup result=FAILED'
}

test_lookup_fail() {
    begin "lookup_fail"
    scenario servers fail
    run_direct -- --network public --output-dir "$WORK/out"
    expect_eq "server show 503: exit 1" "$RC" 1
    expect_match "server show 503: (lookup failed)" "$(grep '"10.0.0.10"' "$(csv_of public)")" '"\(lookup failed\)"'
    expect_match "server show 503: pesan" "$OUT" 'lookup instance gagal untuk 4 ID'

    reset_state
    scenario projects fail
    run_direct -- --network public --output-dir "$WORK/out"
    expect_eq "project list gagal: exit 0 (peringatan)" "$RC" 0
    expect_match "project list gagal: peringatan" "$OUT" 'Gagal mengambil daftar project'
    expect_match "project list gagal: ID (lookup failed)" "$(grep '"10.0.0.10"' "$(csv_of public)")" '"a0000000000000000000000000000001 \(lookup failed\)"'

    reset_state
    scenario netlist fail
    run_direct -- --network public --output-dir "$WORK/out"
    expect_eq "network list gagal: exit 1" "$RC" 1
    expect_match "network list gagal: pesan" "$OUT" 'Gagal mengambil daftar external network'
}

test_interrupt() {
    begin "interrupt"
    scenario show_slow 3
    run_tmux "" --network public --method cli --parallel 2 --output-dir "$WORK/out"
    wait_for 'floating ip show: [0-9]/7' || return 0
    keys C-c
    local rc
    rc="$(tmux_exit 30)"
    expect_eq "Ctrl-C exit 130" "$rc" 130
    sleep 4
    expect_true "direktori sementara dihapus" tmp_empty
    expect_eq "tanpa CSV" "$(csv_files)" ""
}

test_readonly() {
    begin "readonly"
    # calls.log semua tes sebelumnya (diarsipkan oleh reset_state)
    local all
    all="$(cat "$WORK/all-calls.log" 2>/dev/null || true)"
    expect_match "ada panggilan yang diarsipkan" "$all" 'floating ip'
    expect_no_match "tidak ada create/set/delete/unset/add/remove" "$all" \
        '(^| )(create|set|unset|delete|add|remove|associate|disassociate)( |$)'
    # Allowlist: hanya perintah read-only yang dikenal
    expect_eq "semua panggilan read-only" "$(grep -vE '^(--os-compute-api-version [0-9.]+ )?(network list|floating ip list|floating ip show|port show|token issue|catalog show|project list|server list|server show) ' <<< "$all" || true)" ""
}

# ============================================================
# Run
# ============================================================

for t in cli pattern fzf_multi menu network_arg auto fallback pagination token instance_rules \
         cli_method nodetails server_list lookup_fail interrupt readonly; do
    want "$t" && "test_$t"
done

echo
echo "========================================"
echo "Lulus: $PASS   Gagal: $FAIL"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
