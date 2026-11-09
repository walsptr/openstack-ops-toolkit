#!/bin/bash
# ============================================================
# Tes network/list-routers.sh dengan stub OpenStack CLI dan stub curl
# (tanpa cloud). Script tidak punya prompt, jadi tidak butuh tmux.
#
#   bash tests/list-routers/run.sh            # semua tes
#   bash tests/list-routers/run.sh api        # hanya tes yang namanya cocok
#   KEEP=1 bash tests/list-routers/run.sh     # simpan direktori kerja
#
# Butuh: bash, jq, setsid. python3 (opsional) untuk validasi CSV.
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC2034  # dipakai di dalam string eval (run)
SCRIPT="$ROOT/network/list-routers.sh"
STUB="$HERE/stub/openstack"
CSTUB="$HERE/stub/curl"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lr-test.XXXXXX")"
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()

TOKEN="gAAAAAstubTOKENrahasia-0123456789"
SECRET_PW="StubPassw0rd-Rahasia"
HEADER="Router ID,Router Name,Public IP,Public Network Name,Project Name,Domain Name"
HEADER_EXT="$HEADER,Project ID,Domain ID,Public Network ID,Status,Admin State,SNAT,HA,Distributed,Created At,Updated At"

# Urut: project name, router name, ID (case-insensitive; "(" < huruf)
read -r -d '' EXPECTED <<'EOF' || true
"c0000000-0000-4000-8000-000000000004","ghost","203.0.113.30","public","(not found: a0000000000000000000000000000009)",""
"c0000000-0000-4000-8000-000000000001","edge,""main""","203.0.113.9;203.0.113.10","public","Acme, ""Prod""","Default"
"c0000000-0000-4000-8000-000000000002","beta-r1","","","beta","Cust, ""Dom"""
"c0000000-0000-4000-8000-000000000003","dual","203.0.113.20;2001:db8::10","public","beta","Cust, ""Dom"""
"c0000000-0000-4000-8000-000000000005","gamma-r","198.51.100.5","ext-gamma","gamma","Default"
"c0000000-0000-4000-8000-000000000007","stale-net","192.0.2.1","(not found: b0000000-0000-4000-8000-000000000009)","gamma","Default"
"c0000000-0000-4000-8000-000000000006","orphan","","","orphan-dom-proj","(not found: d0000000000000000000000000000099)"
EOF

read -r -d '' EXPECTED_EXT <<'EOF' || true
"c0000000-0000-4000-8000-000000000004","ghost","203.0.113.30","public","(not found: a0000000000000000000000000000009)","","a0000000000000000000000000000009","","b0000000-0000-4000-8000-000000000001","ERROR","UP","true","false","true","2026-01-05T10:00:00Z","2026-01-05T10:00:00Z"
"c0000000-0000-4000-8000-000000000001","edge,""main""","203.0.113.9;203.0.113.10","public","Acme, ""Prod""","Default","a0000000000000000000000000000001","default","b0000000-0000-4000-8000-000000000001","ACTIVE","UP","true","false","false","2026-01-01T10:00:00Z","2026-01-02T10:00:00Z"
"c0000000-0000-4000-8000-000000000002","beta-r1","","","beta","Cust, ""Dom""","a0000000000000000000000000000002","d0000000000000000000000000000002","","ACTIVE","DOWN","","true","false","2026-01-03T10:00:00Z","2026-01-03T11:00:00Z"
"c0000000-0000-4000-8000-000000000003","dual","203.0.113.20;2001:db8::10","public","beta","Cust, ""Dom""","a0000000000000000000000000000002","d0000000000000000000000000000002","b0000000-0000-4000-8000-000000000001","ACTIVE","UP","false","true","false","2026-01-04T10:00:00Z","2026-01-04T10:00:00Z"
"c0000000-0000-4000-8000-000000000005","gamma-r","198.51.100.5","ext-gamma","gamma","Default","a0000000000000000000000000000003","default","b0000000-0000-4000-8000-000000000002","ACTIVE","UP","true","false","false","2026-01-06T10:00:00Z","2026-01-06T10:00:00Z"
"c0000000-0000-4000-8000-000000000007","stale-net","192.0.2.1","(not found: b0000000-0000-4000-8000-000000000009)","gamma","Default","a0000000000000000000000000000003","default","b0000000-0000-4000-8000-000000000009","ACTIVE","UP","true","false","false","2026-01-08T10:00:00Z","2026-01-08T10:00:00Z"
"c0000000-0000-4000-8000-000000000006","orphan","","","orphan-dom-proj","(not found: d0000000000000000000000000000099)","a0000000000000000000000000000005","d0000000000000000000000000000099","","ACTIVE","UP","","false","false","2026-01-07T10:00:00Z","2026-01-07T10:00:00Z"
EOF

for tool in jq setsid; do
    command -v "$tool" >/dev/null 2>&1 || { echo "❌ $tool dibutuhkan untuk tes"; exit 1; }
done

# shellcheck disable=SC2329  # dipanggil lewat trap EXIT
cleanup() {
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
    if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "dapat: '${2:0:800}'  pola: '$3'"; fi
}

expect_no_match() {
    if [[ "$2" =~ $3 ]]; then bad "$1" "pola tidak boleh muncul: '$3'"; else ok "$1"; fi
}

reset_state() {
    [[ -f "$WORK/state/calls.log" ]] && cat "$WORK/state/calls.log" >> "$WORK/all-calls.log"
    [[ -d "$WORK/log" ]] && cat "$WORK"/log/network/*.log >> "$WORK/all-logs.txt" 2>/dev/null || true
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
        "OSOPS_CURL=$(printf '%q' "$CSTUB")" \
        "OSOPS_LOG_DIR=$(printf '%q' "$WORK/log")" \
        "OSOPS_ROUTERS_OUTPUT_DIR=$(printf '%q' "$WORK/out")" \
        "TMPDIR=$(printf '%q' "$WORK/tmp")" \
        OS_REGION_NAME=RegionTest OS_INTERFACE=public \
        OS_AUTH_URL=https://keystone.test:5000/v3 OS_PROJECT_NAME=admin \
        OS_PROJECT_DOMAIN_NAME=Default OS_USERNAME=admin "OS_PASSWORD=$SECRET_PW"
}

# run [ENV=...]... -- ARGS... — tanpa tty (seperti cron); output di $OUT, exit code di $RC
run() {
    local -a envs=()
    while (( $# > 0 )) && [[ "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    [[ "${1:-}" == "--" ]] && shift
    RC=0
    OUT="$(eval "env $(base_env)" '"${envs[@]}"' setsid -w bash '"$SCRIPT"' '"$@"' < /dev/null 2>&1)" || RC=$?
}

log_text() {
    cat "$WORK"/log/network/list-routers-*.log 2>/dev/null || true
}

calls() {
    cat "$WORK/state/calls.log"
}

csv_files() {
    find "$WORK/out" -maxdepth 1 -name '*.csv' | sort
}

the_csv() {
    csv_files | head -n 1
}

csv_body() {
    tail -n +2 "$(the_csv)"
}

summary_val() {
    grep -E "^  $1 +:" <<< "$OUT" | sed 's/^[^:]*: //' | head -n 1
}

tmp_empty() {
    [[ -z "$(find "$WORK/tmp" -mindepth 1 2>/dev/null)" ]]
}

want() {
    [[ -z "$FILTER" || "$1" == *"$FILTER"* ]]
}

begin() {
    CURRENT="$1"
    reset_state
    echo
    echo "▶ $1"
}

# Validasi CSV dengan parser CSV sungguhan: semua baris punya N kolom
check_csv_parse() {
    local file="$1" cols="$2" rows="$3" got
    if ! command -v python3 >/dev/null 2>&1; then
        echo "  ⚠️  python3 tidak ada: validasi parser CSV dilewati"
        return 0
    fi
    got="$(python3 -I -c '
import csv, sys
r = list(csv.reader(open(sys.argv[1], newline="")))
print(len(r) - 1, ",".join(sorted({str(len(x)) for x in r})))' "$file")"
    expect_eq "CSV valid (parser): $rows baris, $cols kolom" "$got" "$rows $cols"
}

# ============================================================
# Tes
# ============================================================

if want help; then
    begin help
    run -- --help
    expect_eq "exit 0" "$RC" 0
    expect_match "kolom di help" "$OUT" "Router ID,Router Name,Public IP,Public Network Name,Project Name,Domain Name"
    expect_match "opsi di help" "$OUT" "--with-gateway-only"
    expect_eq "tidak ada panggilan CLI" "$(calls)" ""
    run -- --bogus
    expect_eq "opsi tidak dikenal → exit 1" "$RC" 1
    run -- --method foo
    expect_match "--method tidak valid" "$OUT" "--method harus auto, api, atau cli"
fi

if want cli-default; then
    begin cli-default
    run --
    expect_eq "exit 0" "$RC" 0
    expect_eq "satu file CSV" "$(csv_files | wc -l)" 1
    expect_match "nama file default" "$(basename "$(the_csv)")" '^list-routers-RegionTest-[0-9]{8}-[0-9]{6}\.csv$'
    expect_eq "permission 600" "$(stat -c %a "$(the_csv)")" 600
    expect_eq "header" "$(head -n 1 "$(the_csv)")" "$HEADER"
    expect_eq "isi CSV (gateway kosong, dual-stack, koma/kutip, project terhapus, network project lain)" \
        "$(csv_body)" "$EXPECTED"
    check_csv_parse "$(the_csv)" 6 7
    expect_match "region + metode di awal" "$OUT" "Region  : RegionTest.*Metode  : auto"
    expect_eq "metode dipakai" "$(summary_val Metode)" cli
    expect_eq "total" "$(summary_val 'Total router')" 7
    expect_eq "dengan gateway" "$(summary_val 'Dengan gateway')" 5
    expect_eq "tanpa gateway" "$(summary_val 'Tanpa gateway')" 2
    expect_eq "project tidak ditemukan" "$(summary_val 'Project tidak ditemukan')" 1
    expect_eq "domain tidak ditemukan" "$(summary_val 'Domain tidak ditemukan')" 1
    expect_eq "file di ringkasan" "$(summary_val 'File CSV')" "$(the_csv)"
    expect_eq "tanpa curl" "$(cat "$WORK/state/curl.log")" ""
    expect_eq "tanpa router show per router" "$(calls | grep -c 'router show' || true)" 0
    expect_eq "lookup massal: tepat 4 panggilan" "$(calls | sort | tr '\n' '|')" \
        "domain list -f json|network list -f json|project list --long -f json|router list --long -f json|"
    expect_match "log lookup routers" "$(log_text)" "RESULT resource=routers action=lookup result=SUCCESS method=cli count=7"
    expect_match "log SUMMARY" "$(log_text)" "SUMMARY region=RegionTest method=cli total=7 with_gateway=5 without_gateway=2 project_not_found=1"
    expect_match "log END rc=0" "$(log_text)" "END rc=0"
    if tmp_empty; then ok "direktori sementara dihapus"; else bad "direktori sementara tersisa"; fi
    cp "$(the_csv)" "$WORK/cli.csv"
fi

if want api-pagination; then
    begin api-pagination
    run OSOPS_ROUTER_PAGE_LIMIT=2 -- --method api
    expect_eq "exit 0" "$RC" 0
    expect_eq "metode api" "$(summary_val Metode)" api
    expect_eq "4 halaman (7 router / 2)" "$(wc -l < "$WORK/state/curl.log")" 4
    expect_match "log API_FETCH" "$(log_text)" "API_FETCH path=routers pages=4 count=7"
    expect_eq "isi CSV sama dengan cli" "$(csv_body)" "$EXPECTED"
    expect_eq "jumlah router api = cli" "$(summary_val 'Total router')" 7
    expect_no_match "link next memakai endpoint catalog, bukan host proxy" "$(cat "$WORK/state/curl.log")" "proxy-internal"
    expect_match "marker diikuti" "$(cat "$WORK/state/curl.log")" "routers\?limit=2&marker=c0000000-0000-4000-8000-000000000006"
    expect_no_match "token tidak di argumen curl" "$(cat "$WORK/state/curl.log")" "$TOKEN"
    expect_eq "token selalu lewat stdin" "$(sort -u "$WORK/state/curl_auth.log")" ok
    expect_eq "tanpa router list CLI" "$(calls | grep -c 'router list' || true)" 0
    run OSOPS_ROUTER_PAGE_LIMIT=0 -- --method api
    expect_match "page limit tidak valid" "$OUT" "OSOPS_ROUTER_PAGE_LIMIT harus angka"
fi

if want cli-string; then
    begin cli-string
    scenario cli_gw string
    run -- --method cli
    expect_eq "exit 0 (gateway sebagai string JSON)" "$RC" 0
    expect_eq "isi CSV sama" "$(csv_body)" "$EXPECTED"
fi

for kind in old nofips nokey; do
    if want "cli-incomplete-$kind"; then
        begin "cli-incomplete-$kind"
        scenario cli_gw "$kind"
        run -- --method cli
        expect_eq "--method cli: exit 1" "$RC" 1
        expect_match "--method cli: pesan jelas" "$OUT" "Metode cli: (external_gateway_info tidak lengkap|key external_gateway_info tidak ada).*--method api"
        expect_eq "--method cli: tidak ada CSV (bukan kolom kosong diam-diam)" "$(csv_files | wc -l)" 0
        run --
        expect_eq "auto: exit 0" "$RC" 0
        expect_match "auto: peringatan fallback" "$OUT" "Output CLI tidak bisa dipakai.*mencoba metode api"
        expect_eq "auto: metode api" "$(summary_val Metode)" api
        expect_eq "auto: isi CSV lengkap" "$(csv_body)" "$EXPECTED"
        expect_match "auto: alasan di log" "$(log_text)" "METHOD method=api reason=\"fallback cli"
    fi
done

if want auto-both-fail; then
    begin auto-both-fail
    scenario cli_gw old
    scenario api fail
    run --
    expect_eq "exit 1" "$RC" 1
    expect_match "pesan menyebut cli dan api" "$OUT" "Metode cli: .*; metode api: request API gagal"
    expect_eq "tidak ada CSV" "$(csv_files | wc -l)" 0
    if tmp_empty; then ok "direktori sementara dihapus"; else bad "direktori sementara tersisa"; fi
fi

if want routers-fail; then
    begin routers-fail
    scenario routers fail
    run -- --method cli
    expect_eq "exit 1" "$RC" 1
    expect_match "pesan" "$OUT" "router list gagal: Service Unavailable"
    expect_eq "tidak ada CSV" "$(csv_files | wc -l)" 0
fi

if want extended; then
    begin extended
    run -- --extended
    expect_eq "exit 0" "$RC" 0
    expect_eq "auto + --extended → api" "$(summary_val Metode)" api
    expect_eq "header extended" "$(head -n 1 "$(the_csv)")" "$HEADER_EXT"
    expect_eq "isi CSV extended" "$(csv_body)" "$EXPECTED_EXT"
    check_csv_parse "$(the_csv)" 16 7
    expect_eq "tanpa router list CLI" "$(calls | grep -c 'router list' || true)" 0

    begin extended-cli
    run -- --extended --method cli
    expect_eq "--method cli --extended: exit 1" "$RC" 1
    expect_match "pesan jelas" "$OUT" "--extended butuh Created At/Updated At"
    expect_eq "tidak ada panggilan CLI" "$(calls)" ""
fi

if want noext; then
    begin noext
    scenario noext 1
    run -- --extended
    expect_eq "exit 0 (tanpa l3-ha/dvr bukan error)" "$RC" 0
    expect_no_match "tanpa peringatan" "$OUT" "⚠️"
    expect_eq "kolom HA/Distributed kosong" \
        "$(tail -n +2 "$(the_csv)" | python3 -I -c 'import csv,sys; print(sorted({(r[12], r[13]) for r in csv.reader(sys.stdin)}))' 2>/dev/null || echo skip)" \
        "[('', '')]"
    begin noext-cli
    scenario noext 1
    run -- --method cli
    expect_eq "cli tanpa kolom HA/Distributed: exit 0" "$RC" 0
    expect_eq "isi CSV sama" "$(csv_body)" "$EXPECTED"
fi

if want gateway-only; then
    begin gateway-only
    run -- --with-gateway-only
    expect_eq "exit 0" "$RC" 0
    expect_eq "hanya router dengan gateway" "$(csv_body)" "$(grep -v -e '"beta-r1"' -e '"orphan"' <<< "$EXPECTED")"
    expect_eq "total tetap semua router" "$(summary_val 'Total router')" 7
    expect_match "ditulis ke CSV" "$(summary_val 'Ditulis ke CSV')" "^5 router \(--with-gateway-only\)"
    expect_match "log" "$(log_text)" "written=5 extended=0 gateway_only=1"
fi

if want output; then
    begin output
    run -- --output "$WORK/out/custom.csv"
    expect_eq "exit 0" "$RC" 0
    expect_eq "file custom dibuat" "$(csv_files)" "$WORK/out/custom.csv"
    expect_eq "permission 600" "$(stat -c %a "$WORK/out/custom.csv")" 600
    echo "lama" > "$WORK/out/exists.csv"
    run -- --output "$WORK/out/exists.csv"
    expect_eq "file sudah ada: exit 1" "$RC" 1
    expect_match "pesan" "$OUT" "File output sudah ada \(tidak ditimpa\)"
    expect_eq "file lama tidak berubah" "$(cat "$WORK/out/exists.csv")" lama
    expect_eq "tidak ada panggilan CLI" "$(calls | grep -c . || true)" 4
    ln -s "$WORK/out/target-none" "$WORK/out/link.csv"
    run -- --output "$WORK/out/link.csv"
    expect_eq "symlink (dangling) ditolak" "$RC" 1
    if [[ -e "$WORK/out/target-none" ]]; then bad "target symlink dibuat"; else ok "target symlink tidak dibuat"; fi
    run -- --output "$WORK/nodir/x.csv"
    expect_match "direktori tidak ada" "$OUT" "Direktori output tidak ada"
fi

if want lookup-fail-projects; then
    begin lookup-fail-projects
    scenario projects fail
    run --
    expect_eq "exit 1 (sebagian lookup gagal)" "$RC" 1
    expect_eq "CSV tetap ditulis" "$(csv_files | wc -l)" 1
    expect_match "peringatan" "$OUT" "Gagal mengambil projects"
    expect_match "lookup failed, bukan not found" "$(csv_body)" '"edge,""main""","203.0.113.9;203.0.113.10","public","\(lookup failed: a0000000000000000000000000000001\)",""'
    expect_no_match "tidak ada (not found: <project>)" "$(csv_body)" "not found: a0"
    expect_eq "project tidak ditemukan = 0" "$(summary_val 'Project tidak ditemukan')" 0
    expect_eq "router dengan lookup gagal" "$(summary_val 'Router dengan lookup gagal')" 7
    expect_match "log FAILED" "$(log_text)" "RESULT resource=projects action=lookup result=FAILED"
    expect_match "log END rc=1" "$(log_text)" "END rc=1"
fi

if want lookup-fail-domains; then
    begin lookup-fail-domains
    scenario domains fail
    run --
    expect_eq "exit 1" "$RC" 1
    expect_match "domain lookup failed" "$(csv_body)" '"gamma-r","198.51.100.5","ext-gamma","gamma","\(lookup failed: default\)"'
    expect_eq "domain tidak ditemukan = 0" "$(summary_val 'Domain tidak ditemukan')" 0
fi

if want lookup-fail-networks; then
    begin lookup-fail-networks
    scenario networks fail
    run --
    expect_eq "exit 1" "$RC" 1
    expect_match "network lookup failed" "$(csv_body)" '"gamma-r","198.51.100.5","\(lookup failed: b0000000-0000-4000-8000-000000000002\)"'
    expect_match "router tanpa gateway tetap kosong" "$(csv_body)" '"beta-r1","","","beta"'
    expect_eq "router dengan lookup gagal (5 dengan gateway)" "$(summary_val 'Router dengan lookup gagal')" 5
fi

if want region; then
    begin region-catalog
    run OS_REGION_NAME= OS_CLOUD=overcloud OS_AUTH_URL= --
    expect_eq "exit 0" "$RC" 0
    expect_match "region dari catalog" "$(basename "$(the_csv)")" '^list-routers-RegionTest-'
    expect_match "auth dari clouds.yaml" "$OUT" "auth: clouds.yaml: overcloud"
    begin region-multi
    scenario catalog multi
    run OS_REGION_NAME= --
    expect_match "lebih dari satu region → unknown" "$(basename "$(the_csv)")" '^list-routers-unknown-'
    begin region-unsafe
    run "OS_REGION_NAME=Reg/../x y" --
    expect_eq "exit 0" "$RC" 0
    expect_match "region disanitasi di nama file" "$(basename "$(the_csv)")" '^list-routers-Reg_.._x_y-[0-9]{8}-[0-9]{6}\.csv$'
fi

if want collision; then
    begin collision
    # Tabrakan nama: buat file untuk detik ini dan beberapa detik ke depan
    for (( s = 0; s < 3; s++ )); do
        : > "$WORK/out/list-routers-RegionTest-$(date -d "+$s sec" +%Y%m%d-%H%M%S).csv"
    done
    run --
    expect_eq "exit 0" "$RC" 0
    expect_eq "file baru dengan sufiks, file lama tidak ditimpa" \
        "$(find "$WORK/out" -name '*-2.csv' -size +0 | wc -l)" 1
fi

if want secrets; then
    begin secrets
    run OSOPS_ROUTER_PAGE_LIMIT=3 -- --extended
    reset_state
    if grep -rqF -e "$SECRET_PW" -e "$TOKEN" "$WORK/all-logs.txt" 2>/dev/null; then
        bad "OS_PASSWORD/token muncul di log"
    else
        ok "OS_PASSWORD/token tidak ada di log semua tes"
    fi
fi

# Read-only: hanya perintah list/show/issue
CURRENT="read-only"
reset_state
echo
echo "▶ read-only"
if [[ -s "$WORK/all-calls.log" ]]; then
    bad_calls="$(grep -vE '^(router list --long|network list|project list --long|domain list|token issue|catalog show network) -f json$' \
        "$WORK/all-calls.log" | sort -u || true)"
    expect_eq "semua panggilan CLI read-only" "$bad_calls" ""
fi

echo
echo "========================================"
echo "Lulus: $PASS  Gagal: $FAIL"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
exit 0
