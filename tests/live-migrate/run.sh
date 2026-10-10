#!/bin/bash
# ============================================================
# Tes servers/live-migrate.sh dengan stub OpenStack CLI (tanpa cloud).
#
#   bash tests/live-migrate/run.sh          # semua tes
#   bash tests/live-migrate/run.sh abort    # hanya tes yang namanya cocok
#   KEEP=1 bash tests/live-migrate/run.sh   # simpan direktori kerja
#
# Butuh: bash, jq, tmux, flock, fzf (tes picker). Script dijalankan di
# tmux karena semua prompt membaca dari /dev/tty.
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/servers/live-migrate.sh"
STUB="$HERE/stub/openstack"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lm-test.XXXXXX")"
TM=(tmux -L "lm-test-$$")
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()

for tool in jq tmux flock setsid; do
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
    if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "dapat: '$2'  pola: '$3'"; fi
}

expect_true() {
    local desc="$1"
    shift
    if "$@"; then ok "$desc"; else bad "$desc"; fi
}

uid() {
    printf '11111111-0000-4000-8000-0000000000%s' "$1"
}

reset_state() {
    "${TM[@]}" kill-server 2>/dev/null || true
    rm -rf "$WORK/state" "$WORK/log"
    mkdir -p "$WORK/state/servers" "$WORK/state/scen" "$WORK/state/mig" "$WORK/log"
    : > "$WORK/state/calls.log"
}

# mk_server SUFFIX NAME [JQ-FILTER] — server ACTIVE di compute-a + migrasi lama (Id 5)
mk_server() {
    local id
    id="$(uid "$1")"
    jq --arg id "$id" --arg n "$2" ".id = \$id | .name = \$n | ${3:-.}" \
        "$HERE/fixtures/server.json" > "$WORK/state/servers/$id.json"
    printf '[{"Id": 5, "Status": "completed", "Server UUID": "%s", "Type": "live-migration", "Source Compute": "compute-c", "Dest Compute": "compute-a", "tick": 0, "aborted": false}]\n' \
        "$id" > "$WORK/state/mig/$id.json"
}

scenario() {
    echo "$2 ${3:-3}" > "$WORK/state/scen/$(uid "$1")"
}

# run_tmux "ENV..." ARGS... — jalankan script di tmux. TMUX diset agar tidak
# ada peringatan tmux/screen, kecuali NO_TMUX=1 (TMUX dan STY dihapus).
run_tmux() {
    local envs="$1" cmd session="-u STY TMUX=lm-test"
    shift
    printf -v cmd '%q ' "$@"
    [[ -n "${NO_TMUX:-}" ]] && session="-u TMUX -u STY"
    "${TM[@]}" kill-server 2>/dev/null || true
    "${TM[@]}" new-session -d -s t -x 220 -y 50 \
        "env $session STUB_STATE=$(printf '%q' "$WORK/state") OSOPS_OS_CMD=$(printf '%q' "$STUB") OSOPS_LOG_DIR=$(printf '%q' "$WORK/log") $envs bash $(printf '%q' "$SCRIPT") $cmd; echo __EXIT=\$?; sleep 3600"
}

# run_direct ARGS... — tanpa tty; output di $OUT, exit code di $RC
run_direct() {
    local -a extra=()
    [[ -n "${DIRECT_ENV:-}" ]] && read -ra extra <<< "$DIRECT_ENV"
    RC=0
    # setsid: tanpa controlling terminal (/dev/tty tidak tersedia)
    OUT="$(env STUB_STATE="$WORK/state" OSOPS_OS_CMD="$STUB" OSOPS_LOG_DIR="$WORK/log" \
        "${extra[@]}" setsid -w bash "$SCRIPT" "$@" < /dev/null 2>&1)" || RC=$?
}

screen_text() {
    "${TM[@]}" capture-pane -p -J -t t -S -5000 2>/dev/null
}

count_of() {
    screen_text | grep -cE -- "$1" || true
}

# wait_for PATTERN [N] [DETIK] — tunggu sampai PATTERN muncul >= N kali
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

# answer PATTERN N JAWABAN — tunggu prompt ke-N lalu jawab + Enter
answer() {
    wait_for "$1" "$2" && keys "$3" Enter
}

tmux_exit() {
    wait_for '__EXIT=' 1 "${1:-60}" || { echo "?"; return 0; }
    screen_text | grep -o '__EXIT=[0-9]*' | tail -n 1 | cut -d= -f2
}

report_file() {
    local f=("$WORK"/log/servers/live-migrate-*-results.tsv)
    [[ -f "${f[0]}" ]] && printf '%s' "${f[0]}"
}

# tsv FIELD ID — 6=result 5=dst 8=message
tsv() {
    local f
    f="$(report_file)" || return 0
    awk -F'\t' -v id="$2" -v col="$1" '$2 == id { print $col }' "$f"
}

log_text() {
    cat "$WORK"/log/servers/live-migrate-*.log 2>/dev/null || true
}

calls() {
    cat "$WORK/state/calls.log"
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

input_file_mixed() {
    local f="$WORK/ids-mixed.txt"
    {
        echo "# daftar VM untuk rebalance"
        printf '%s\r\n' "$(uid a1 | tr 'a-f' 'A-F')"
        echo "   $(uid a1)   "
        echo ""
        echo "not-a-uuid"
        uid f0; echo
        uid 51; echo
        uid 52; echo
        uid 53; echo
        uid 54; echo
        uid 55; echo
        echo "$(uid a1)   # duplikat dengan komentar"
    } > "$f"
    printf '%s' "$f"
}

mixed_servers() {
    mk_server a1 vm-ok
    mk_server 51 vm-shutoff '.status = "SHUTOFF" | ."OS-EXT-STS:power_state" = 4'
    mk_server 52 vm-error '.status = "ERROR"'
    mk_server 53 vm-busy '."OS-EXT-STS:task_state" = "rebooting"'
    mk_server 54 vm-locked '.locked = true'
    mk_server 55 vm-ontarget '."OS-EXT-SRV-ATTR:host" = "compute-b"'
}

test_input_and_precheck() {
    local f rc
    begin "input_and_precheck"
    mixed_servers
    scenario a1 success 3
    f="$(input_file_mixed)"

    run_tmux "" --file "$f" --target compute-b --interval 1
    answer 'Migrate VM ini\?' 1 y || return 0
    wait_for 'progress=[0-9]+%' 1 || true
    rc="$(tmux_exit)"

    expect_eq "exit code 0" "$rc" "0"
    expect_eq "A1 (CRLF, huruf besar) SUCCESS" "$(tsv 6 "$(uid a1)")" "SUCCESS"
    expect_eq "ID tidak valid -> SKIPPED" "$(tsv 6 not-a-uuid)/$(tsv 8 not-a-uuid)" "SKIPPED/invalid id"
    expect_eq "tidak ditemukan" "$(tsv 8 "$(uid f0)")" "not found"
    expect_eq "status SHUTOFF" "$(tsv 8 "$(uid 51)")" "status=SHUTOFF"
    expect_eq "status ERROR" "$(tsv 8 "$(uid 52)")" "status=ERROR"
    expect_eq "task_state" "$(tsv 8 "$(uid 53)")" "busy: rebooting"
    expect_eq "locked" "$(tsv 8 "$(uid 54)")" "locked"
    expect_eq "sudah di tujuan" "$(tsv 8 "$(uid 55)")" "already on target"
    expect_eq "baris TSV (header + 8)" "$(wc -l < "$(report_file)")" "9"
    expect_match "hitungan input di log" "$(log_text | grep ' INPUT ')" \
        'lines=10 unique=8 valid=7 invalid=1 duplicates=2'
    expect_match "MIGRATION_STATUS dicatat" "$(log_text | grep -c MIGRATION_STATUS)" '^[2-9]'
    expect_match "RESULT dengan field lengkap" "$(log_text | grep 'result=SUCCESS')" \
        'resource=11111111-0000-4000-8000-0000000000a1 name=vm-ok src=compute-a dst=compute-b result=SUCCESS duration=[0-9]+ msg=""'
    expect_match "CMD migrate tanpa flag block/shared" "$(log_text | grep ' CMD ')" \
        '--os-compute-api-version 2.65 server migrate --live-migration --host compute-b 1111'
}

test_dry_run() {
    local f
    begin "dry_run"
    mixed_servers
    f="$(input_file_mixed)"

    run_direct --file "$f" --target compute-b --dry-run

    expect_eq "exit code 0" "$RC" "0"
    expect_match "A1 WILL MIGRATE" "$OUT" "$(uid a1) +vm-ok +compute-a +compute-b +WILL MIGRATE"
    expect_match "SKIP (busy)" "$OUT" 'SKIP \(busy: rebooting\)'
    expect_match "SKIP (invalid id)" "$OUT" 'not-a-uuid .*SKIP \(invalid id\)'
    expect_match "SKIP (not found)" "$OUT" 'SKIP \(not found\)'
    expect_true "tidak pernah memanggil server migrate" bash -c "! grep -q 'server migrate ' '$WORK/state/calls.log'"
    expect_true "tidak ada laporan TSV" bash -c "! ls '$WORK'/log/servers/*-results.tsv >/dev/null 2>&1"
    expect_match "log PLAN dry_run=true" "$(log_text | grep -c 'PLAN dry_run=true')" '^8$'
    expect_true "tidak ada log_result" bash -c "! grep -q ' RESULT ' '$WORK'/log/servers/live-migrate-*.log"
}

test_outcomes() {
    local rc
    begin "outcomes"
    mk_server 01 vm-success
    mk_server e1 vm-error
    mk_server e2 vm-rollback
    mk_server 04 vm-declined
    mk_server 05 vm-change
    mk_server 06 vm-badport
    mk_server 07 vm-reject
    mk_server 08 vm-bfv '.image = "N/A (booted from volume)"'
    scenario 01 success 2
    scenario e1 error 2
    scenario e2 rollback 2
    scenario 05 success 2
    scenario 06 badport 2
    scenario 07 reject
    scenario 08 success 2
    printf '%s\n' "$(uid 01)" "$(uid e1)" "$(uid e2)" "$(uid 04)" "$(uid 05)" "$(uid 06)" "$(uid 07)" "$(uid 08)" > "$WORK/ids.txt"

    run_tmux "" --file "$WORK/ids.txt" --target compute-b --interval 1 --delay 1
    answer 'Migrate VM ini\?' 1 y || return 0
    answer 'Migrate VM ini\?' 2 y || return 0
    answer 'Migrate VM ini\?' 3 y || return 0
    answer 'Migrate VM ini\?' 4 n || return 0
    answer 'Migrate VM ini\?' 5 c || return 0
    wait_for 'host >' 1 || return 0
    keys compute-c
    sleep 0.5
    keys Enter
    wait_for 'Host tujuan : compute-c' 1 || return 0
    answer 'Migrate VM ini\?' 6 y || return 0
    answer 'Migrate VM ini\?' 7 y || return 0
    answer 'Migrate VM ini\?' 8 y || return 0
    wait_for 'Disk +: boot from volume' 1 || return 0
    answer 'Migrate VM ini\?' 9 y || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 1 (ada FAILED)" "$rc" "1"
    expect_eq "sukses" "$(tsv 6 "$(uid 01)")" "SUCCESS"
    expect_eq "status ERROR -> FAILED" "$(tsv 6 "$(uid e1)")" "FAILED"
    expect_match "pesan dari server event" "$(tsv 8 "$(uid e1)")" 'status=ERROR; Error; compute_live_migration: Error - libvirt.libvirtError: internal error'
    expect_eq "rollback (ACTIVE, host asal) -> FAILED" "$(tsv 6 "$(uid e2)")" "FAILED"
    expect_match "pesan rollback" "$(tsv 8 "$(uid e2)")" "rollback.*CPU doesn't have compatibility"
    expect_eq "declined" "$(tsv 6 "$(uid 04)")" "DECLINED"
    expect_eq "ganti tujuan -> compute-c" "$(tsv 5 "$(uid 05)")/$(tsv 6 "$(uid 05)")" "compute-c/SUCCESS"
    expect_eq "host tujuan batch tidak berubah" "$(tsv 5 "$(uid 06)")" "compute-b"
    expect_match "post-check port binding (warning saja)" "$(tsv 6 "$(uid 06)") $(tsv 8 "$(uid 06)")" \
        "^SUCCESS postcheck: port port-$(uid 06) binding_host_id=compute-a\$"
    expect_match "migrate ditolak API" "$(tsv 6 "$(uid 07)") $(tsv 8 "$(uid 07)")" '^FAILED migrate ditolak: Compute service'
    expect_eq "boot from volume sukses" "$(tsv 6 "$(uid 08)")" "SUCCESS"
    expect_match "jeda antar migrasi" "$(screen_text)" 'Jeda 1 detik'
    expect_match "keputusan user dicatat" "$(log_text | grep -c 'DECISION')" '^[7-9]$'
    expect_match "ringkasan per hasil" "$(screen_text)" 'SUCCESS +: 4'
}

test_abort() {
    local rc
    begin "abort"
    mk_server a1 vm-abort-ok
    mk_server a2 vm-abort-late
    mk_server a3 vm-abort-reject
    scenario a1 abort_ok
    scenario a2 abort_late 5
    scenario a3 abort_reject 6
    printf '%s\n' "$(uid a1)" "$(uid a2)" "$(uid a3)" > "$WORK/ids.txt"

    run_tmux "" --file "$WORK/ids.txt" --target compute-b --interval 1

    # 1) abort berhasil
    answer 'Migrate VM ini\?' 1 y || return 0
    wait_for 'migration=running' 1 || return 0
    keys a
    answer 'Yakin abort' 1 y || return 0

    # 2) abort terlambat: abort diterima, migrasi tetap selesai di tujuan
    answer 'Migrate VM ini\?' 2 y || return 0
    wait_for '\[vm-abort-late\] .*migration=running' 1 || return 0
    keys a
    answer 'Yakin abort' 2 y || return 0

    # 3) abort dibatalkan (n), lalu abort ditolak API
    answer 'Migrate VM ini\?' 3 y || return 0
    wait_for '\[vm-abort-reject\] .*migration=running' 1 || return 0
    keys a
    answer 'Yakin abort' 3 n || return 0
    wait_for 'Abort dibatalkan' 1 || return 0
    keys a
    answer 'Yakin abort' 4 y || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 0" "$rc" "0"
    expect_eq "abort berhasil -> ABORTED" "$(tsv 6 "$(uid a1)")" "ABORTED"
    expect_eq "abort terlambat -> SUCCESS" "$(tsv 6 "$(uid a2)")/$(tsv 8 "$(uid a2)")" \
        "SUCCESS/abort terlambat, migrasi sudah selesai"
    expect_eq "abort ditolak -> tetap dipantau -> SUCCESS" "$(tsv 6 "$(uid a3)")" "SUCCESS"
    expect_match "pesan penolakan dari API ditampilkan" "$(screen_text)" 'Abort ditolak: .*post-migrating'
    expect_match "penolakan abort dicatat WARN" "$(log_text | grep ' WARN ' | grep -c 'Abort ditolak')" '^1$'
    expect_match "CMD abort dicatat" "$(log_text | grep -c 'CMD .*server migration abort')" '^3$'
    expect_match "abort declined dicatat" "$(log_text | grep -c 'abort=declined')" '^1$'
}

test_timeout() {
    local rc
    begin "timeout"
    mk_server 71 vm-slow
    scenario 71 slow
    uid 71 > "$WORK/ids.txt"
    echo >> "$WORK/ids.txt"

    run_tmux "" --file "$WORK/ids.txt" --target compute-b --interval 1 --timeout 3s
    answer 'Migrate VM ini\?' 1 y || return 0
    answer '\[W\]ait 3 detik lagi' 1 "" || return 0
    answer '\[W\]ait 3 detik lagi' 2 a || return 0
    answer 'Yakin abort' 1 y || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 0" "$rc" "0"
    expect_eq "timeout -> abort -> ABORTED" "$(tsv 6 "$(uid 71)")" "ABORTED"
    expect_match "tidak abort otomatis: 2x TIMEOUT di log" "$(log_text | grep -c ' TIMEOUT ')" '^2$'
    expect_match "keputusan wait dicatat" "$(log_text | grep -c 'timeout=wait')" '^1$'
    expect_match "progres terakhir ditampilkan" "$(screen_text)" 'melewati batas waktu 3 detik .*progress=[0-9]+%'
}

test_quit() {
    local rc
    begin "quit"
    mk_server 81 vm-q1
    mk_server 82 vm-q2
    mk_server 83 vm-q3
    printf '%s\n' "$(uid 81)" "$(uid 82)" "$(uid 83)" > "$WORK/ids.txt"

    run_tmux "" --file "$WORK/ids.txt" --target compute-b --interval 1
    answer 'Migrate VM ini\?' 1 n || return 0
    answer 'Migrate VM ini\?' 2 q || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 0" "$rc" "0"
    expect_eq "VM 1 DECLINED" "$(tsv 6 "$(uid 81)")" "DECLINED"
    expect_eq "VM 2 & 3 belum diproses" "$(tsv 6 "$(uid 82)")/$(tsv 6 "$(uid 83)")" "NOT_PROCESSED/NOT_PROCESSED"
    expect_match "ringkasan NOT_PROCESSED" "$(screen_text)" 'NOT_PROCESSED +: 2'
    expect_true "tidak ada migrate" bash -c "! grep -q 'server migrate ' '$WORK/state/calls.log'"
}

test_interrupt() {
    local rc
    begin "interrupt"
    mk_server 91 vm-ctrlc
    mk_server 92 vm-after
    scenario 91 slow
    printf '%s\n' "$(uid 91)" "$(uid 92)" > "$WORK/ids.txt"

    run_tmux "" --file "$WORK/ids.txt" --target compute-b --interval 1
    answer 'Migrate VM ini\?' 1 y || return 0
    wait_for 'migration=running' 1 || return 0
    keys C-c
    wait_for 'TETAP BERJALAN di Nova' 1 || return 0
    answer 'Abort migrasi ini sebelum keluar' 1 y || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 130" "$rc" "130"
    expect_match "VM berjalan -> ABORTED + catatan" "$(tsv 6 "$(uid 91)") $(tsv 8 "$(uid 91)")" '^ABORTED .*abort diminta'
    expect_eq "VM berikutnya belum diproses" "$(tsv 6 "$(uid 92)")" "NOT_PROCESSED"
    expect_true "abort dikirim" grep -q 'server migration abort' "$WORK/state/calls.log"
    expect_match "ringkasan parsial" "$(screen_text)" 'Ringkasan Live Migration'
    expect_match "END signal=INT di log" "$(log_text | grep ' END ')" 'rc=130 .*signal=INT'
}

test_lock() {
    local rc holder
    begin "lock"
    mk_server 01 vm-1
    uid 01 > "$WORK/ids.txt"
    echo >> "$WORK/ids.txt"
    mkdir -p "$WORK/log/servers"
    flock "$WORK/log/servers/live-migrate.lock" sleep 30 &
    holder=$!
    sleep 0.5

    run_tmux "" --file "$WORK/ids.txt" --target compute-b --interval 1
    rc="$(tmux_exit)"
    kill "$holder" 2>/dev/null || true

    expect_eq "exit code 1" "$rc" "1"
    expect_match "pesan lock" "$(screen_text)" 'Live migration lain sedang berjalan'
    expect_true "tidak ada migrate" bash -c "! grep -q 'server migrate ' '$WORK/state/calls.log'"
}

test_no_tmux() {
    local rc
    begin "no_tmux"
    mk_server 01 vm-1
    uid 01 > "$WORK/ids.txt"
    echo >> "$WORK/ids.txt"

    NO_TMUX=1 run_tmux "" --file "$WORK/ids.txt" --target compute-b
    answer 'Tetap lanjut\?' 1 n || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 0" "$rc" "0"
    expect_match "peringatan SSH" "$(screen_text)" 'Tidak berjalan di dalam tmux/screen'
    expect_true "tidak ada laporan / migrate" bash -c "! ls '$WORK'/log/servers/*-results.tsv >/dev/null 2>&1 && ! grep -q 'server migrate ' '$WORK/state/calls.log'"
}

test_interactive_picker() {
    local rc
    begin "interactive_picker"
    if ! command -v fzf >/dev/null 2>&1; then
        bad "fzf tidak tersedia, tes picker dilewati"
        return 0
    fi
    mk_server 01 vm-1
    uid 01 > "$WORK/ids.txt"
    echo >> "$WORK/ids.txt"

    run_tmux "" --interval 1
    answer 'Path file daftar instance ID' 1 "$WORK/ids.txt" || return 0
    wait_for 'host >' 1 || return 0
    expect_match "utilisasi host (nama FQDN hypervisor cocok)" "$(screen_text)" 'compute-b +vCPU 8/64  RAM 32/256 GiB'
    expect_true "host disabled/down tidak ditawarkan" bash -c "! tmux -L lm-test-$$ capture-pane -p -t t | grep -qE 'compute-[de]'"
    keys compute-b
    sleep 0.5
    keys Enter
    answer 'Migrate VM ini\?' 1 n || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "target dari picker" "$(log_text | grep ' TARGET ')" 'dst=compute-b source=picker'

    begin "interactive_picker_no_stats"
    mk_server 01 vm-1
    run_tmux "STUB_NO_HYP_STATS=1" --file "$WORK/ids.txt" --interval 1
    wait_for 'host >' 1 || return 0
    expect_true "tanpa field utilisasi: nama host saja" bash -c "! tmux -L lm-test-$$ capture-pane -p -t t | grep -q 'vCPU'"
    keys compute-c
    sleep 0.5
    keys Enter
    answer 'Migrate VM ini\?' 1 q || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
}

test_microversion() {
    local f="$WORK/ids-mv.txt"
    begin "microversion"
    mk_server 01 vm-1
    uid 01 > "$f"
    echo >> "$f"

    DIRECT_ENV="STUB_MAX_MV=2.29" run_direct --file "$f" --target compute-b --dry-run
    expect_eq "max < 2.30 -> exit 1" "$RC" "1"
    expect_match "pesan microversion" "$OUT" '2\.29 \(< 2\.30\)'

    DIRECT_ENV="STUB_MAX_MV=2.60" run_direct --file "$f" --target compute-b --dry-run
    expect_eq "max 2.60 -> lanjut" "$RC" "0"
    expect_match "peringatan fitur abort" "$OUT" 'abort hanya bisa untuk migrasi berstatus running'
    expect_eq "microversion efektif" "$(cat "$WORK/state/last_mv")" "2.60"

    DIRECT_ENV="OSOPS_COMPUTE_API_VERSION=2.20" run_direct --file "$f" --target compute-b --dry-run
    expect_eq "override < 2.30 ditolak" "$RC" "1"
}

test_cli() {
    begin "cli"
    run_direct --help
    expect_eq "--help exit 0" "$RC" "0"
    expect_match "--help isi" "$OUT" 'Usage: live-migrate.sh .*--dry-run'
    expect_true "--help tidak membuat log" bash -c "! ls '$WORK'/log/servers/*.log >/dev/null 2>&1"

    run_direct --bogus
    expect_match "parameter tidak dikenal" "$RC $OUT" '^1 .*Parameter tidak dikenal: --bogus'

    run_direct --interval 0 --dry-run
    expect_match "--interval divalidasi" "$RC $OUT" '^1 .*--interval'

    run_direct --timeout 5m --dry-run
    expect_match "--timeout divalidasi" "$RC $OUT" '^1 .*--timeout'

    mk_server 01 vm-1
    uid 01 > "$WORK/ids.txt"
    run_direct --file "$WORK/ids.txt" --target compute-d --dry-run
    expect_match "target disabled ditolak" "$RC $OUT" "^1 .*'compute-d' tidak ditemukan atau tidak enabled/up"

    run_direct --file "$WORK/ids.txt" --target compute-b
    expect_match "migrasi tanpa tty ditolak" "$RC $OUT" '^1 .*butuh terminal interaktif'

    # shellcheck disable=SC2016  # backtick literal di pola
    expect_match "muncul di --list dengan metadata" "$(bash "$ROOT/main.sh" --workdir "$ROOT" --list)" \
        '\| Live Migrate Instances \| servers \| `servers/live-migrate.sh` \| yes \|'
    expect_true "tests/ tidak ikut discovery" bash -c "! bash '$ROOT/main.sh' --discover '$ROOT' | grep -q tests/"
}

# ============================================================
# Run
# ============================================================

for t in cli input_and_precheck dry_run outcomes abort timeout quit interrupt lock no_tmux interactive_picker microversion; do
    want "$t" && "test_$t"
done

echo
echo "========================================"
echo "Lulus: $PASS   Gagal: $FAIL"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
