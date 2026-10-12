#!/bin/bash
# ============================================================
# Tes servers/list-instances-by-host.sh dengan stub OpenStack CLI dan stub
# curl (tanpa cloud).
#
#   bash tests/list-instances-by-host/run.sh          # semua tes
#   bash tests/list-instances-by-host/run.sh api      # hanya tes yang namanya cocok
#   KEEP=1 bash tests/list-instances-by-host/run.sh   # simpan direktori kerja
#
# Butuh: bash, jq, tmux, setsid, fzf (untuk tes picker). Picker dijalankan
# di tmux karena prompt membaca dari /dev/tty.
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/servers/list-instances-by-host.sh"
LIVE_MIGRATE="$ROOT/servers/live-migrate.sh"
STUB="$HERE/stub/openstack"
CSTUB="$HERE/stub/curl"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/libh-test.XXXXXX")"
TM=(tmux -L "libh-test-$$")
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()

TOKEN="gAAAAAstubNOVAtokenRAHASIA-987654321"
SECRET_PW="StubPassw0rd-Rahasia"
HEADER="Instance ID,Instance Name,Project ID,Project Name,Domain ID,Domain Name"
HEADER_EXT="$HEADER,Status,Power State,Flavor,vCPU,RAM (MB),IP Addresses,Availability Zone"

# compute-a, urut Project Name lalu Instance Name (case-insensitive)
read -r -d '' EXPECTED_A <<'EOF' || true
"11111111-0000-4000-8000-000000000004","orphan-vm","a0000000000000000000000000000009","(not found)","",""
"11111111-0000-4000-8000-000000000006","Alpha","a0000000000000000000000000000001","Acme, ""Prod""","default","Default"
"11111111-0000-4000-8000-000000000002","db,01","a0000000000000000000000000000001","Acme, ""Prod""","default","Default"
"11111111-0000-4000-8000-000000000001","Web-01","a0000000000000000000000000000001","Acme, ""Prod""","default","Default"
"11111111-0000-4000-8000-000000000003","app ""quoted""","a0000000000000000000000000000002","beta","d0000000000000000000000000000002","Dom Two"
"11111111-0000-4000-8000-000000000005","zz","a0000000000000000000000000000003","gamma","d0000000000000000000000000000009","(not found)"
EOF

read -r -d '' EXPECTED_A_EXT <<'EOF' || true
"11111111-0000-4000-8000-000000000004","orphan-vm","a0000000000000000000000000000009","(not found)","","","ACTIVE","Running","m1.small","2","2048","","nova"
"11111111-0000-4000-8000-000000000006","Alpha","a0000000000000000000000000000001","Acme, ""Prod""","default","Default","ACTIVE","Running","m1.small","2","2048","net-a: 10.0.0.9","nova"
"11111111-0000-4000-8000-000000000002","db,01","a0000000000000000000000000000001","Acme, ""Prod""","default","Default","SHUTOFF","Shutdown","m1.small","2","2048","net-a: 10.0.0.6","nova"
"11111111-0000-4000-8000-000000000001","Web-01","a0000000000000000000000000000001","Acme, ""Prod""","default","Default","ACTIVE","Running","m1.small","2","2048","net-a: 10.0.0.5, 172.24.4.28 (floating); net-b: 192.168.1.9","nova"
"11111111-0000-4000-8000-000000000003","app ""quoted""","a0000000000000000000000000000002","beta","d0000000000000000000000000000002","Dom Two","PAUSED","Paused","m1.small","2","2048","net-a: 10.0.0.7","nova"
"11111111-0000-4000-8000-000000000005","zz","a0000000000000000000000000000003","gamma","d0000000000000000000000000000009","(not found)","SUSPENDED","Suspended","m1.small","2","2048","net-a: 10.0.0.8","nova"
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
    : > "$WORK/state/curl_mv.log"
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
    "${TM[@]}" new-session -d -s t -x 200 -y 60 \
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
    cat "$WORK"/log/servers/list-instances-by-host-*.log 2>/dev/null || true
}

calls() {
    cat "$WORK/state/calls.log"
}

out_files() {
    find "$WORK/out" -maxdepth 1 -type f | sort
}

# file_of NAMA-AMAN EXT — satu-satunya file output untuk host itu
file_of() {
    find "$WORK/out" -maxdepth 1 -name "instances-$1-*.$2" | head -n 1
}

rows_of() {
    tail -n +2 "$(file_of "$1" csv)"
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

# parse_with_live_migrate FILE — jalankan parser input --file milik
# servers/live-migrate.sh (fungsi trim, valid_uuid, load_ids diambil apa adanya)
# terhadap FILE. Output: "<jumlah> <invalid> <duplikat>" lalu satu ID per baris.
parse_with_live_migrate() {
    # shellcheck disable=SC2016  # dievaluasi di subshell bash
    bash -c '
        set -o errexit -o nounset -o pipefail
        eval "$(sed -n -e "/^trim() {/,/^}/p" -e "/^valid_uuid() {/,/^}/p" -e "/^load_ids() {/,/^}/p" "$1")"
        INPUT_FILE="$2"
        ENTRIES=()
        N_LINES=0 N_DUP=0 N_INVALID=0
        load_ids
        echo "${#ENTRIES[@]} $N_INVALID $N_DUP"
        printf "%s\n" "${ENTRIES[@]}"
    ' _ "$LIVE_MIGRATE" "$1"
}

# ============================================================
# Tes
# ============================================================

test_cli() {
    begin "cli"

    run_direct -- --help
    expect_eq "--help exit 0" "$RC" 0
    expect_match "--help menampilkan usage" "$OUT" 'Usage: list-instances-by-host.sh'

    run_direct -- --method foo --host compute-a
    expect_match "--method tidak valid" "$OUT" '--method harus auto, api, atau cli'
    run_direct -- --parallel 99 --host compute-a
    expect_match "--parallel 99 ditolak" "$OUT" '--parallel harus angka 1-64'
    run_direct -- --output-dir "$WORK/tidak-ada" --host compute-a
    expect_match "--output-dir tidak ada" "$OUT" 'Direktori output tidak ada'
    run_direct -- --migrate
    expect_match "tidak ada opsi migrasi" "$OUT" 'Opsi tidak dikenal: --migrate'

    run_direct -- --output-dir "$WORK/out"
    expect_eq "tanpa tty dan tanpa --host exit 1" "$RC" 1
    expect_match "pesan butuh --host" "$OUT" 'gunakan --host'
    expect_eq "tidak ada file output" "$(out_files)" ""
}

test_picker() {
    local s
    begin "picker"
    run_tmux "" --output-dir "$WORK/out"
    wait_for 'host >' || return 0
    wait_for 'compute-empty' || return 0
    s="$(screen_text)"
    expect_match "host enabled/up tampil" "$s" 'compute-a +nova +enabled +up'
    expect_match "host disabled tampil + reason" "$s" 'compute-b\.example\.com +az-2 +disabled +up +\(maintenance 2026-10\)'
    expect_match "host down tampil" "$s" 'compute-c +nova +enabled +down'
    # Urutan: compute-a, compute-b.example.com, compute-c, compute-empty
    keys Tab Tab Enter
    answer 'kolom tambahan' 1 n || return 0
    expect_eq "exit 0" "$(tmux_exit)" 0
    expect_eq "4 file (CSV + .ids per host)" "$(out_files | wc -l)" 4
    expect_eq "CSV compute-a" "$(rows_of compute-a)" "$EXPECTED_A"
    expect_eq "CSV compute-b" "$(rows_of compute-b.example.com)" \
        '"11111111-0000-4000-8000-000000000007","maint-vm","a0000000000000000000000000000002","beta","d0000000000000000000000000000002","Dom Two"'
    expect_eq "header default persis" "$(head -n 1 "$(file_of compute-a csv)")" "$HEADER"
    s="$(screen_text)"
    expect_match "ringkasan service disabled + reason" "$s" 'Service +: disabled / up \(maintenance 2026-10\)'
    expect_match "total keseluruhan" "$s" 'Total +7 instance, 4 project unik, 1 orphan'
    expect_match "catatan snapshot" "$s" 'snapshot saat eksekusi'
    expect_eq "log_result per host" "$(log_text | grep -c 'action=list-instances-by-host result=SUCCESS')" 2
    expect_match "log extended=0" "$(log_text)" 'DECISION extended=0'
    expect_true "direktori sementara dihapus" tmp_empty
}

test_menu() {
    begin "menu"
    FZF_CMD="/tidak/ada/fzf" run_tmux "" --output-dir "$WORK/out"
    wait_for 'Pilih host' || return 0
    expect_match "menu: host down tampil" "$(screen_text)" '3\. compute-c +nova +enabled +down'
    keys '4' Enter
    answer 'kolom tambahan' 1 y || return 0
    expect_eq "exit 0" "$(tmux_exit)" 0
    expect_eq "host kosong: CSV hanya header (extended)" "$(cat "$(file_of compute-empty csv)")" "$HEADER_EXT"
    expect_match "host kosong: .ids hanya komentar" "$(cat "$(file_of compute-empty ids)")" \
        '^# host=compute-empty generated=[0-9T:+-]+ count=0 source=list-instances-by-host$'
    expect_match "host kosong: diberi tahu" "$(screen_text)" 'Tidak ada instance di host ini'
    expect_match "host kosong: log msg" "$(log_text)" 'resource=compute-empty .*count=0 .*msg="tidak ada instance"'
}

test_host_arg() {
    begin "host_arg"
    run_direct -- --host nope --host compute-a --host compute-a --output-dir "$WORK/out"
    expect_eq "host tidak valid dilewati, exit 0" "$RC" 0
    expect_match "pesan host tidak valid" "$OUT" "Host 'nope' tidak ada di daftar nova-compute; dilewati"
    expect_match "log SKIPPED" "$(log_text)" 'RESULT resource=nope action=list-instances-by-host result=SKIPPED'
    expect_eq "duplikat --host: satu CSV + satu .ids" "$(out_files | wc -l)" 2
    expect_match "ringkasan memuat SKIPPED" "$OUT" 'SKIPPED +nope'

    reset_state
    run_direct -- --host compute-b --output-dir "$WORK/out"
    expect_eq "nama pendek diterima" "$RC" 0
    expect_true "nama pendek → compute-b.example.com" test -n "$(file_of compute-b.example.com csv)"

    reset_state
    run_direct -- --host nope --output-dir "$WORK/out"
    expect_eq "hanya host tidak valid: exit 1" "$RC" 1
    expect_match "daftar host ditampilkan" "$OUT" 'compute-c +zone=nova +enabled/down'
}

test_auto() {
    begin "auto"
    run_direct -- --host compute-a --host compute-c --output-dir "$WORK/out"
    expect_eq "exit 0" "$RC" 0
    expect_match "mode default: metode list" "$OUT" 'Metode +: list'
    expect_eq "server list sekali untuk 2 host" "$(calls | grep -c 'server list' || true)" 1
    expect_no_match "--host OSC tidak dipakai (bug OSC 7.1.2)" "$(calls)" 'server list.* --host '
    expect_no_match "tanpa --limit" "$(calls)" 'server list.*--limit'
    expect_eq "tanpa curl" "$(wc -l < "$WORK/state/curl.log")" 0
    expect_eq "CSV list" "$(rows_of compute-a)" "$EXPECTED_A"
    expect_match "log alasan metode" "$(log_text)" 'METHOD host=compute-a method=list'

    reset_state
    run_direct -- --host compute-a --extended --output-dir "$WORK/out"
    expect_match "extended: metode api" "$OUT" 'Metode +: api'
    expect_eq "extended: microversion 2.47 di header" "$(sort -u "$WORK/state/curl_mv.log")" 2.47
    expect_match "extended: host disaring di server" "$(cat "$WORK/state/curl.log")" \
        'https://nova.test:8774/v2.1/servers/detail\?all_tenants=1&host=compute-a'
    expect_eq "extended: header persis" "$(head -n 1 "$(file_of compute-a csv)")" "$HEADER_EXT"
    expect_eq "extended: CSV" "$(rows_of compute-a)" "$EXPECTED_A_EXT"
    expect_match "extended: per power state" "$OUT" 'Per power state +: Paused=1  Running=3  Shutdown=1  Suspended=1'

    reset_state
    scenario list_noproj 1
    run_direct -- --host compute-a --output-dir "$WORK/out"
    expect_match "list tanpa Project ID → api" "$OUT" 'Metode +: api'
    expect_eq "list tanpa Project ID: CSV sama" "$(rows_of compute-a)" "$EXPECTED_A"
}

test_fallback() {
    begin "fallback"
    scenario api fail
    run_direct -- --host compute-a --extended --output-dir "$WORK/out"
    expect_eq "api gagal → exit 0" "$RC" 0
    expect_match "fallback ke cli" "$OUT" 'fallback ke cli'
    expect_match "metode akhir cli" "$OUT" 'Metode +: cli'
    expect_match "log alasan fallback" "$(log_text)" 'method=cli reason="fallback api: request API gagal'
    expect_eq "cli: CSV extended sama dengan api (floating dari floating ip list)" "$(rows_of compute-a)" "$EXPECTED_A_EXT"
    expect_eq "cli: 6 server show" "$(calls | grep -c 'server show' || true)" 6
    expect_match "cli: progres" "$OUT" 'server show: 6/6 selesai'
    expect_match "cli: microversion di-pin" "$(cat "$WORK/state/compute_version")" '^2\.47$'

    reset_state
    CURL_CMD="/tidak/ada/curl" run_direct -- --host compute-a --extended --output-dir "$WORK/out"
    expect_match "curl tidak ada → cli" "$OUT" 'curl tidak tersedia\); fallback ke cli'
    expect_no_match "curl tidak ada: tanpa token issue" "$(calls)" 'token issue'

    reset_state
    scenario catalog fail
    run_direct -- --host compute-a --extended --output-dir "$WORK/out"
    expect_match "catalog gagal → cli" "$OUT" 'catalog show compute gagal.*fallback ke cli'

    reset_state
    scenario api fail
    run_direct -- --host compute-a --method api --output-dir "$WORK/out"
    expect_eq "--method api gagal: exit 1" "$RC" 1
    expect_match "--method api gagal: pesan" "$OUT" 'metode api: request API gagal'
    expect_eq "--method api gagal: tanpa file" "$(out_files)" ""
    expect_match "log_result FAILED" "$(log_text)" 'resource=compute-a action=list-instances-by-host result=FAILED .*count=0'
}

test_pagination() {
    begin "pagination"
    run_direct OSOPS_SERVER_PAGE_LIMIT=2 -- --host compute-a --method api --output-dir "$WORK/out"
    expect_eq "exit 0" "$RC" 0
    expect_eq "4 request (2+2+2+0)" "$(wc -l < "$WORK/state/curl.log")" 4
    expect_eq "semua instance" "$(rows_of compute-a)" "$EXPECTED_A"
    expect_no_match "link next host proxy tidak dipakai" "$(cat "$WORK/state/curl.log")" 'proxy-internal'
    expect_match "marker dipakai" "$(cat "$WORK/state/curl.log")" 'nova.test:8774/v2.1/servers/detail\?all_tenants=1&host=compute-a&limit=2&marker='

    reset_state
    scenario api_page 4
    run_direct -- --host compute-a --method api --output-dir "$WORK/out"
    expect_eq "paging dari server: 2 request" "$(wc -l < "$WORK/state/curl.log")" 2
    expect_eq "paging dari server: 6 baris" "$(rows_of compute-a | wc -l)" 6

    # API mengabaikan filter host: script tetap hanya menulis instance host ini
    reset_state
    scenario api_nofilter 1
    run_direct -- --host compute-a --method api --output-dir "$WORK/out"
    expect_eq "saring ulang host: CSV tetap benar" "$(rows_of compute-a)" "$EXPECTED_A"
}

test_token() {
    begin "token"
    run_direct OS_CACERT=/etc/pki/ca.pem -- --host compute-a --method api --output-dir "$WORK/out"
    expect_eq "exit 0" "$RC" 0
    expect_no_match "token tidak di argumen curl" "$(cat "$WORK/state/curl.log")" "$TOKEN"
    expect_match "config curl dari stdin" "$(cat "$WORK/state/curl.log")" '-K -'
    expect_eq "header token diterima stub" "$(sort -u "$WORK/state/curl_auth.log")" ok
    expect_match "OS_CACERT dipakai" "$(cat "$WORK/state/curl.log")" '--cacert /etc/pki/ca.pem'
    expect_eq "token tidak di log" "$(grep -rlF "$TOKEN" "$WORK/log" || true)" ""
    expect_eq "token tidak di file output" "$(grep -rlF "$TOKEN" "$WORK/out" || true)" ""
    expect_eq "password tidak di log" "$(grep -rlF "$SECRET_PW" "$WORK/log" || true)" ""
    expect_no_match "token tidak di output" "$OUT" "$TOKEN"
    expect_no_match "isi CSV tidak di log (nama instance)" "$(log_text)" 'Web-01|orphan-vm|Acme'
}

test_microversion() {
    begin "microversion"
    scenario compute_max 2.30
    run_direct -- --host compute-a --extended --method api --output-dir "$WORK/out"
    expect_eq "exit 0" "$RC" 0
    expect_match "peringatan microversion" "$OUT" 'Compute API maksimum 2.30 < 2.47: memakai 2.1'
    expect_eq "header API 2.1" "$(sort -u "$WORK/state/curl_mv.log")" 2.1
    expect_match "flavor ID, vCPU/RAM kosong" "$(grep '"Web-01"' "$(file_of compute-a csv)")" '"Running","flavor-id-small","",""'
}

test_owners() {
    local s
    begin "owners"
    run_direct -- --host compute-a --output-dir "$WORK/out"
    s="$OUT"
    expect_match "tabel per project: Acme" "$s" 'Acme, "Prod" +Default +3'
    expect_match "tabel per project: orphan dengan ID" "$s" '\(not found\) \[a0000000\] +- +1'
    expect_match "tabel per project: domain not found" "$s" 'gamma +\(not found\) +1'
    expect_match "jumlah project" "$s" 'Instance per project \(4 project\)'
    expect_match "orphan menonjol" "$s" '1 instance dengan project \(not found\)'
    expect_match "per status" "$s" 'Per status +: ACTIVE=3  PAUSED=1  SHUTOFF=1  SUSPENDED=1'
    expect_match "petunjuk live-migrate" "$s" 'servers/live-migrate.sh --file .*/out/instances-compute-a-[0-9-]+\.ids'
    expect_match "log_result lengkap" "$(log_text)" \
        "RESULT resource=compute-a action=list-instances-by-host result=SUCCESS method=list extended=0 count=6 orphans=1 file=$WORK/out/instances-compute-a-[0-9-]+\.csv ids_file=.*\.ids duration=[0-9]+s msg=ok"
    expect_eq "satu project list + satu domain list" "$(calls | grep -cE '^(project|domain) list' || true)" 2

    reset_state
    scenario projects fail
    run_direct -- --host compute-a --output-dir "$WORK/out"
    expect_eq "project list gagal: exit 1" "$RC" 1
    expect_match "project list gagal: (lookup failed)" "$(grep '"Web-01"' "$(file_of compute-a csv)")" '"\(lookup failed\)"'

    reset_state
    scenario domains fail
    run_direct -- --host compute-a --output-dir "$WORK/out"
    expect_eq "domain list gagal: exit 1" "$RC" 1
    expect_match "domain list gagal: domain (lookup failed)" "$(grep '"Web-01"' "$(file_of compute-a csv)")" '"Acme, ""Prod""","default","\(lookup failed\)"'
}

test_files() {
    local csv ids parsed
    begin "files"
    run_direct -- --host compute-a --output-dir "$WORK/out"
    csv="$(file_of compute-a csv)"
    ids="$(file_of compute-a ids)"
    expect_match "nama file CSV" "$csv" '/out/instances-compute-a-[0-9]{8}-[0-9]{6}\.csv$'
    expect_eq "nama dasar .ids sama" "${ids%.ids}" "${csv%.csv}"
    expect_eq "permission CSV 600" "$(stat -c %a "$csv")" 600
    expect_eq "permission .ids 600" "$(stat -c %a "$ids")" 600
    expect_match "komentar .ids" "$(head -n 1 "$ids")" \
        '^# host=compute-a generated=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+ count=6 source=list-instances-by-host$'
    expect_eq "urutan .ids = urutan CSV" "$(tail -n +2 "$ids")" "$(tail -n +2 "$csv" | cut -d, -f1 | tr -d '"')"

    parsed="$(parse_with_live_migrate "$ids")"
    expect_eq "parser live-migrate: 6 ID, 0 invalid, 0 duplikat" "$(head -n 1 <<< "$parsed")" "6 0 0"
    expect_eq "parser live-migrate: ID sama dan berurutan" "$(tail -n +2 <<< "$parsed")" "$(tail -n +2 "$ids")"

    # Host kosong: parser membaca 0 ID (live-migrate menolak: "Tidak ada instance ID")
    run_direct -- --host compute-empty --output-dir "$WORK/out"
    parsed="$(parse_with_live_migrate "$(file_of compute-empty ids)")"
    expect_eq "parser live-migrate: host kosong 0 ID" "$(head -n 1 <<< "$parsed")" "0 0 0"
}

test_cli_method() {
    begin "cli_method"
    scenario show_gone 11111111-0000-4000-8000-000000000002
    scenario show_moved 11111111-0000-4000-8000-000000000003
    run_direct -- --host compute-a --method cli --parallel 3 --output-dir "$WORK/out"
    expect_eq "gone/moved: exit 0" "$RC" 0
    expect_eq "gone/moved: 4 baris" "$(rows_of compute-a | wc -l)" 4
    expect_match "catatan terhapus" "$OUT" '1 instance terhapus selama proses'
    expect_match "catatan pindah host" "$OUT" '1 instance pindah host selama proses'

    reset_state
    scenario show_fail 11111111-0000-4000-8000-000000000001
    run_direct -- --host compute-a --method cli --output-dir "$WORK/out"
    expect_eq "show gagal: exit 1" "$RC" 1
    expect_match "show gagal: pesan" "$OUT" '1 server show gagal'
    expect_eq "show gagal: CSV tetap ditulis (5 baris)" "$(rows_of compute-a | wc -l)" 5

    reset_state
    scenario list fail
    run_direct -- --host compute-a --method cli --output-dir "$WORK/out"
    expect_eq "server list gagal (cli): exit 1" "$RC" 1
    expect_match "server list gagal: pesan" "$OUT" 'metode cli: server list gagal'
}

test_interrupt() {
    begin "interrupt"
    scenario show_slow 3
    run_tmux "" --host compute-a --method cli --parallel 2 --output-dir "$WORK/out"
    wait_for 'server show: [0-9]/6' || return 0
    keys C-c
    expect_eq "Ctrl-C exit 130" "$(tmux_exit 30)" 130
    sleep 4
    expect_true "direktori sementara dihapus" tmp_empty
    expect_eq "tanpa file output" "$(out_files)" ""
}

test_readonly() {
    local all
    begin "readonly"
    all="$(cat "$WORK/all-calls.log" 2>/dev/null || true)"
    expect_match "ada panggilan yang diarsipkan" "$all" 'server list'
    expect_no_match "tidak ada perintah yang mengubah resource" "$all" \
        '(^| )(create|set|unset|delete|add|remove|migrate|evacuate|stop|start|reboot|lock|shelve)( |$)'
    expect_eq "semua panggilan read-only (allowlist)" "$(grep -vE '^(--os-compute-api-version [0-9.]+ )?(compute service list|versions show|server list|server show|floating ip list|token issue|catalog show|project list|domain list) ' <<< "$all" || true)" ""
}

# ============================================================
# Run
# ============================================================

for t in cli picker menu host_arg auto fallback pagination token microversion owners files \
         cli_method interrupt readonly; do
    want "$t" && "test_$t"
done

echo
echo "========================================"
echo "Lulus: $PASS   Gagal: $FAIL"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
