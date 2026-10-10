#!/bin/bash
# ============================================================
# Tes volumes/delete-volume.sh dengan stub OpenStack CLI (tanpa cloud).
#
#   bash tests/delete-volume/run.sh            # semua tes
#   bash tests/delete-volume/run.sh confirm    # hanya tes yang namanya cocok
#   KEEP=1 bash tests/delete-volume/run.sh     # simpan direktori kerja
#
# Butuh: bash, jq, tmux, flock, setsid. Script dijalankan di tmux karena
# semua prompt membaca dari /dev/tty.
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/volumes/delete-volume.sh"
STUB="$HERE/stub/openstack"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dv-test.XXXXXX")"
TM=(tmux -L "dv-test-$$")
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()

P_ALPHA="a0000000000000000000000000000001"
P_LOSTDOM="a0000000000000000000000000000002"
P_ORPHAN="a00000000000000000000000000000ff"

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
    printf '22222222-0000-4000-8000-0000000000%s' "$1"
}

sid() {
    printf '33333333-0000-4000-8000-0000000000%s' "$1"
}

reset_state() {
    "${TM[@]}" kill-server 2>/dev/null || true
    rm -rf "$WORK/state" "$WORK/log"
    mkdir -p "$WORK/state/volumes" "$WORK/state/snaps" "$WORK/state/scen" "$WORK/log"
    : > "$WORK/state/calls.log"
}

# mk_vol SUFFIX NAME [JQ-FILTER] — volume available di proj-alpha
mk_vol() {
    local id
    id="$(uid "$1")"
    jq --arg id "$id" --arg n "$2" ".id = \$id | .name = \$n | ${3:-.}" \
        "$HERE/fixtures/volume.json" > "$WORK/state/volumes/$id.json"
}

# mk_snaps VOL-SUFFIX "SNAP-SUFFIX:STATUS" ... — daftar snapshot volume
mk_snaps() {
    local vid s
    vid="$(uid "$1")"
    shift
    echo '[]' > "$WORK/state/snaps/$vid.json"
    for s in "$@"; do
        jq --slurpfile t "$HERE/fixtures/snapshot.json" --arg id "$(sid "${s%%:*}")" --arg st "${s#*:}" \
            '. + [$t[0] | .ID = $id | .Name = "snap-\($id[-2:])" | .Status = $st | .Size = 5]' \
            "$WORK/state/snaps/$vid.json" > "$WORK/state/snaps/$vid.tmp"
        mv "$WORK/state/snaps/$vid.tmp" "$WORK/state/snaps/$vid.json"
    done
}

scenario() {
    echo "$2 ${3:-2}" > "$WORK/state/scen/$(uid "$1")"
}

# run_tmux "ENV..." ARGS... — jalankan script di tmux. TMUX diset agar tidak
# ada peringatan tmux/screen, kecuali NO_TMUX=1 (TMUX dan STY dihapus).
run_tmux() {
    local envs="$1" cmd="" session="-u STY TMUX=dv-test"
    shift
    (( $# > 0 )) && printf -v cmd '%q ' "$@"
    [[ -n "${NO_TMUX:-}" ]] && session="-u TMUX -u STY"
    "${TM[@]}" kill-server 2>/dev/null || true
    "${TM[@]}" new-session -d -s t -x 230 -y 60 \
        "env $session STUB_STATE=$(printf '%q' "$WORK/state") OSOPS_OS_CMD=$(printf '%q' "$STUB") OSOPS_LOG_DIR=$(printf '%q' "$WORK/log") $envs bash $(printf '%q' "$SCRIPT") $cmd; echo __EXIT=\$?; sleep 3600"
}

# run_direct ARGS... — tanpa tty; output di $OUT, exit code di $RC
run_direct() {
    RC=0
    # setsid: tanpa controlling terminal (/dev/tty tidak tersedia)
    OUT="$(env STUB_STATE="$WORK/state" OSOPS_OS_CMD="$STUB" OSOPS_LOG_DIR="$WORK/log" \
        setsid -w bash "$SCRIPT" "$@" < /dev/null 2>&1)" || RC=$?
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
    local f=("$WORK"/log/volumes/delete-volume-*-results.tsv)
    [[ -f "${f[0]}" ]] && printf '%s' "${f[0]}"
}

# tsv FIELD ID — 3=name 4=project 5=domain 7=status 9=snapshot_count
#                10=snapshot_ids 11=result 13=message
tsv() {
    local f
    f="$(report_file)" || return 0
    awk -F'\t' -v id="$2" -v col="$1" '$2 == id { print $col }' "$f"
}

log_text() {
    cat "$WORK"/log/volumes/delete-volume-*.log 2>/dev/null || true
}

calls() {
    cat "$WORK/state/calls.log"
}

no_delete_called() {
    ! grep -q '^volume delete' "$WORK/state/calls.log"
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
        echo "# volume untuk cleanup"
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
        uid 56; echo
        uid 57; echo
        echo "$(uid a1)   # duplikat dengan komentar"
    } > "$f"
    printf '%s' "$f"
}

mixed_volumes() {
    mk_vol a1 vol-nosnap
    mk_vol 51 vol-inuse '.status = "in-use"'
    mk_vol 52 vol-error '.status = "error"'
    mk_vol 53 vol-creating '.status = "creating"'
    mk_vol 54 vol-snaps '.size = 20'
    mk_snaps 54 "01:available" "02:error"
    mk_vol 55 vol-badsnap
    mk_snaps 55 "03:available" "04:backing-up"
    mk_vol 56 vol-orphan ".\"os-vol-tenant-attr:tenant_id\" = \"$P_ORPHAN\""
    mk_vol 57 vol-lostdom ".\"os-vol-tenant-attr:tenant_id\" = \"$P_LOSTDOM\""
}

test_cli() {
    begin "cli"
    run_direct --help
    expect_eq "--help exit 0" "$RC" "0"
    expect_match "--help isi" "$OUT" 'Usage: delete-volume.sh .*--no-confirm.*--dry-run'
    expect_true "--help tidak membuat log" bash -c "! ls '$WORK'/log/volumes/*.log >/dev/null 2>&1"

    run_direct --bogus
    expect_match "parameter tidak dikenal" "$RC $OUT" '^1 .*Parameter tidak dikenal: --bogus'

    run_direct --id "$(uid 01)" --file /etc/hostname --dry-run
    expect_match "--id dan --file eksklusif" "$RC $OUT" '^1 .*tidak bisa dipakai bersamaan'

    run_direct --id "$(uid 01)" --interval 0 --dry-run
    expect_match "--interval divalidasi" "$RC $OUT" '^1 .*--interval'

    run_direct --id "$(uid 01)" --timeout 5m --dry-run
    expect_match "--timeout divalidasi" "$RC $OUT" '^1 .*--timeout'

    run_direct --file "$WORK/nope.txt" --dry-run
    expect_match "file tidak ada" "$RC $OUT" "^1 .*tidak ditemukan atau tidak bisa dibaca"

    run_direct --dry-run
    expect_match "tanpa tty dan tanpa input ditolak" "$RC $OUT" '^1 .*gunakan --id atau --file'

    mk_vol 01 vol-1
    run_direct --id "$(uid 01)" --no-confirm
    expect_match "penghapusan tanpa tty ditolak" "$RC $OUT" '^1 .*butuh terminal interaktif'
    expect_true "tidak ada delete" no_delete_called

    # shellcheck disable=SC2016  # backtick literal di pola
    expect_match "muncul di --list dengan metadata" "$(bash "$ROOT/main.sh" --workdir "$ROOT" --list)" \
        '\| Delete Volume \| volumes \| `volumes/delete-volume.sh` \| yes \|'
    expect_true "tests/ tidak ikut discovery" bash -c "! bash '$ROOT/main.sh' --discover '$ROOT' | grep -q tests/"
}

test_per_volume() {
    local f rc
    begin "per_volume"
    mixed_volumes
    f="$(input_file_mixed)"

    run_tmux "" --file "$f" --interval 1
    answer 'Pilih \[1-2\]' 1 1 || return 0
    answer 'Hapus volume ini PERMANEN' 1 y || return 0          # a1 (tanpa snapshot)
    wait_for 'IKUT DIHAPUS PERMANEN oleh --purge' 1 || return 0
    answer 'Hapus volume ini PERMANEN' 2 y || return 0          # 54 (2 snapshot)
    answer 'Hapus volume ini PERMANEN' 3 n || return 0          # 56 orphan project
    answer 'Hapus volume ini PERMANEN' 4 y || return 0          # 57 domain hilang
    rc="$(tmux_exit)"

    expect_eq "exit code 0" "$rc" "0"
    expect_eq "A1 (CRLF, huruf besar) tanpa snapshot SUCCESS" "$(tsv 11 "$(uid a1)")/$(tsv 9 "$(uid a1)")" "SUCCESS/0"
    expect_eq "ID tidak valid" "$(tsv 11 not-a-uuid)/$(tsv 13 not-a-uuid)" "SKIPPED/invalid id"
    expect_eq "tidak ditemukan" "$(tsv 11 "$(uid f0)")/$(tsv 13 "$(uid f0)")" "SKIPPED/not found"
    expect_eq "in-use dilewati" "$(tsv 13 "$(uid 51)")" "not available, status=in-use"
    expect_eq "error dilewati" "$(tsv 13 "$(uid 52)")" "not available, status=error"
    expect_eq "creating dilewati" "$(tsv 13 "$(uid 53)")" "not available, status=creating"
    expect_eq "2 snapshot ikut terhapus" "$(tsv 11 "$(uid 54)")/$(tsv 9 "$(uid 54)")/$(tsv 10 "$(uid 54)")" \
        "SUCCESS/2/$(sid 01),$(sid 02)"
    expect_eq "snapshot backing-up -> volume dilewati" "$(tsv 13 "$(uid 55)")" "snapshot $(sid 04) status=backing-up"
    expect_eq "project orphan" "$(tsv 4 "$(uid 56)")/$(tsv 5 "$(uid 56)")/$(tsv 11 "$(uid 56)")" \
        "$P_ORPHAN (project not found)/-/DECLINED"
    expect_eq "domain orphan" "$(tsv 4 "$(uid 57)")/$(tsv 5 "$(uid 57)")" \
        "proj-lost-domain/d00000000000000000000000000000ff (domain not found)"
    expect_eq "baris TSV (header + 10)" "$(wc -l < "$(report_file)")" "11"
    expect_eq "info lengkap di TSV" "$(awk -F'\t' -v id="$(uid 54)" '$2 == id { print $3"|"$4"|"$5"|"$6"|"$7"|"$8 }' "$(report_file)")" \
        "vol-snaps|proj-alpha|dom-one|2026-09-01T10:00:00.000000|available|20"

    expect_match "--purge dipanggil, tanpa --force" "$(calls | grep '^volume delete' | sort | tr '\n' ' ')" \
        "^volume delete --purge $(uid 54) volume delete --purge $(uid 57) volume delete --purge $(uid a1) \$"
    expect_true "tidak pernah --force / reset-state / set" bash -c "! grep -qE -- '--force|reset-state|volume set' '$WORK/state/calls.log'"
    expect_true "snapshot list memakai --all-projects" bash -c \
        "grep '^volume snapshot list' '$WORK/state/calls.log' | grep -qv -- '--all-projects' && exit 1 || exit 0"
    expect_eq "cache: proj-alpha hanya di-query sekali" "$(calls | grep -c "^project show $P_ALPHA")" "1"
    expect_eq "cache: domain hanya di-query sekali" "$(calls | grep -c '^domain show d0000000000000000000000000000001')" "1"
    expect_eq "cache: project orphan hanya sekali" "$(calls | grep -c "^project show $P_ORPHAN")" "1"
    expect_match "hitungan input di log" "$(log_text | grep ' INPUT ')" \
        'input_mode=file .*lines=12 unique=10 valid=9 invalid=1 duplicates=2'
    expect_match "mode konfirmasi di log" "$(log_text | grep ' OPTIONS ')" 'confirm_mode=per-volume'
    expect_match "VOLUME_INFO + SNAPSHOT dicatat sebelum CMD delete" \
        "$(log_text | grep -E "VOLUME_INFO resource=$(uid 54)|SNAPSHOT volume=$(uid 54)|CMD .*$(uid 54)" | awk '{print $5}' | tr '\n' ' ')" \
        '^(VOLUME_INFO SNAPSHOT SNAPSHOT )+CMD $'
    expect_match "VOLUME_INFO lengkap" "$(log_text | grep "VOLUME_INFO resource=$(uid 54)" | head -n 1)" \
        "name=vol-snaps project_id=$P_ALPHA project=proj-alpha domain=dom-one created_at=2026-09-01T10:00:00.000000 status=available size_gb=20 type=ceph-ssd snapshots=2"
    expect_match "RESULT dengan field lengkap" "$(log_text | grep "RESULT resource=$(uid 54)")" \
        'action=delete-volume-purge result=SUCCESS name=vol-snaps project=proj-alpha snapshots=2 duration=[0-9]+ msg=""'
    expect_match "SKIPPED msg alasan" "$(log_text | grep "RESULT resource=$(uid 51)")" \
        'result=SKIPPED .*msg="not available, status=in-use"'
    expect_match "DECLINED dicatat" "$(log_text | grep -c 'decision=declined')" '^1$'

    local s
    s="$(screen_text)"
    expect_match "tabel TIDAK dihapus" "$s" 'Volume yang TIDAK dihapus \(7\)'
    expect_match "grup not available dengan status" "$s" "▸ Not available \(3\)"
    expect_match "status aktual di tabel" "$s" "$(uid 51) +vol-inuse .*SKIPPED +not available, status=in-use"
    expect_match "grup snapshot status" "$s" '▸ Snapshot status \(1\)'
    expect_match "grup declined" "$s" '▸ Declined'
    expect_match "total snapshot terhapus" "$s" 'Snapshot terhapus +: 2'
    expect_match "total GB" "$s" 'Kapasitas bebas +: 40 GB volume \(\+ 10 GB snapshot'
}

test_outcomes() {
    local rc
    begin "outcomes"
    mk_vol 01 vol-reject
    mk_vol 02 vol-errdel
    mk_vol 03 vol-stuck
    mk_vol 04 vol-flaky
    scenario 01 reject
    scenario 02 error_deleting 2
    scenario 03 stuck
    scenario 04 flaky 3
    printf '%s\n' "$(uid 01)" "$(uid 02)" "$(uid 03)" "$(uid 04)" > "$WORK/ids.txt"

    run_tmux "" --file "$WORK/ids.txt" --interval 1 --timeout 3s
    answer 'Pilih \[1-2\]' 1 "" || return 0
    answer 'Hapus volume ini PERMANEN' 1 y || return 0
    answer 'Hapus volume ini PERMANEN' 2 y || return 0
    answer 'Hapus volume ini PERMANEN' 3 y || return 0
    wait_for 'status=deleting elapsed' 1 || return 0
    answer 'Hapus volume ini PERMANEN' 4 y || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 1 (ada FAILED)" "$rc" "1"
    expect_match "delete ditolak API -> pesan API" "$(tsv 11 "$(uid 01)") $(tsv 13 "$(uid 01)")" \
        '^FAILED Invalid volume: Volume status must be available.*\(HTTP 400\)'
    expect_eq "error_deleting" "$(tsv 11 "$(uid 02)")/$(tsv 13 "$(uid 02)")" "FAILED/status=error_deleting"
    expect_eq "timeout" "$(tsv 11 "$(uid 03)")/$(tsv 13 "$(uid 03)")" "FAILED/timeout, last status=deleting"
    expect_eq "HTTP 503 saat polling bukan sukses palsu" "$(tsv 11 "$(uid 04)")" "SUCCESS"
    expect_true "polling lanjut setelah 503" grep -qx 3 "$WORK/state/polls/$(uid 04)"
    expect_match "503 dicatat WARN" "$(log_text | grep ' WARN ')" 'gagal saat polling: Service Unavailable'
    expect_match "stderr API dicatat" "$(log_text | grep "RESULT resource=$(uid 01)")" 'result=FAILED .*msg="Invalid volume'
    expect_match "status polling dicatat" "$(log_text | grep -c 'DELETE_STATUS')" '^[1-9]'
    expect_match "grup failed" "$(screen_text)" '▸ Failed \(3\)'
}

test_no_confirm_ok() {
    local rc
    begin "no_confirm_ok"
    mk_vol 01 vol-a
    mk_vol 02 vol-b
    mk_snaps 02 "11:available"
    mk_vol 03 vol-inuse '.status = "in-use"'
    mk_vol 04 vol-newsnap
    scenario 04 newsnap
    printf '%s\n' "$(uid 01)" "$(uid 02)" "$(uid 03)" "$(uid 04)" > "$WORK/ids.txt"

    run_tmux "" --file "$WORK/ids.txt" --no-confirm --interval 1
    answer 'Ketik jumlah volume' 1 3 || return 0
    rc="$(tmux_exit)"

    local s
    s="$(screen_text)"
    expect_eq "exit code 0" "$rc" "0"
    expect_true "tidak ada prompt mode / per volume" bash -c "! grep -qE 'Pilih \\[1-2\\]|Hapus volume ini' <<< '$s'"
    expect_match "rencana: snapshot ditampilkan" "$s" "  - $(sid 11)  snap-11  available  5 GB"
    expect_match "rencana: skip dengan alasan" "$s" "$(uid 03) .*SKIP \(not available, status=in-use\)"
    expect_match "total rencana" "$s" 'Akan dihapus : 3 volume, 1 snapshot ikut terhapus \(--purge\), 30 GB'
    expect_eq "A sukses" "$(tsv 11 "$(uid 01)")" "SUCCESS"
    expect_eq "B sukses + snapshot" "$(tsv 11 "$(uid 02)")/$(tsv 9 "$(uid 02)")" "SUCCESS/1"
    expect_eq "skip dari rencana dicatat" "$(tsv 11 "$(uid 03)")/$(tsv 13 "$(uid 03)")" "SKIPPED/not available, status=in-use"
    expect_eq "snapshot baru setelah rencana -> dilewati" "$(tsv 11 "$(uid 04)")/$(tsv 13 "$(uid 04)")" \
        "SKIPPED/snapshots changed since plan"
    expect_true "volume newsnap tidak dihapus" bash -c "! grep -q 'volume delete --purge $(uid 04)' '$WORK/state/calls.log'"
    expect_eq "validasi ulang sebelum hapus (volume show A >= 2 sebelum delete)" \
        "$(calls | sed -n "1,/^volume delete --purge $(uid 01)/p" | grep -c "^volume show $(uid 01)")" "2"
    expect_match "konfirmasi batch dicatat" "$(log_text | grep 'decision=batch-confirm')" 'count=3'
    expect_match "mode konfirmasi batch di log" "$(log_text | grep ' OPTIONS ')" 'confirm_mode=batch'
}

test_no_confirm_mismatch() {
    local rc
    begin "no_confirm_mismatch"
    mk_vol 01 vol-a
    mk_vol 02 vol-b
    mk_vol 03 vol-inuse '.status = "in-use"'
    printf '%s\n' "$(uid 01)" "$(uid 02)" "$(uid 03)" > "$WORK/ids.txt"

    run_tmux "" --file "$WORK/ids.txt" --no-confirm
    answer 'Ketik jumlah volume' 1 y || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 0" "$rc" "0"
    expect_match "pesan batal" "$(screen_text)" 'Konfirmasi tidak cocok \(y ≠ 2\)'
    expect_true "tidak ada delete" no_delete_called
    expect_eq "DECLINED + alasan" "$(tsv 11 "$(uid 01)")/$(tsv 13 "$(uid 01)")" "DECLINED/batch confirmation mismatch"
    expect_eq "skip tetap dicatat" "$(tsv 11 "$(uid 03)")" "SKIPPED"
    expect_match "keputusan dicatat" "$(log_text | grep 'batch-cancel')" 'expected=2 typed=y'
}

test_dry_run() {
    local f
    begin "dry_run"
    mixed_volumes
    f="$(input_file_mixed)"

    run_direct --file "$f" --dry-run

    expect_eq "exit code 0 (tanpa tty)" "$RC" "0"
    expect_match "A1 WILL DELETE" "$OUT" "$(uid a1) +vol-nosnap +proj-alpha +0 +10 GB  WILL DELETE"
    expect_match "snapshot dalam rencana" "$OUT" "  - $(sid 01)  snap-01  available  5 GB"
    expect_match "SKIP in-use" "$OUT" 'SKIP \(not available, status=in-use\)'
    expect_match "SKIP invalid id" "$OUT" 'not-a-uuid .*SKIP \(invalid id\)'
    expect_match "SKIP snapshot status" "$OUT" "SKIP \(snapshot $(sid 04) status=backing-up\)"
    expect_match "total" "$OUT" 'Akan dihapus : 4 volume, 2 snapshot'
    expect_true "tidak pernah memanggil volume delete" no_delete_called
    expect_true "tidak ada laporan TSV / lock" bash -c "! ls '$WORK'/log/volumes/*-results.tsv '$WORK'/log/volumes/*.lock >/dev/null 2>&1"
    expect_match "log PLAN dry_run=true" "$(log_text | grep -c 'PLAN dry_run=true')" '^10$'
    expect_true "tidak ada log_result" bash -c "! grep -q ' RESULT ' '$WORK'/log/volumes/delete-volume-*.log"
}

test_quit() {
    local rc
    begin "quit"
    mk_vol 81 vol-q1
    mk_vol 82 vol-q2
    mk_vol 83 vol-q3
    printf '%s\n' "$(uid 81)" "$(uid 82)" "$(uid 83)" > "$WORK/ids.txt"

    run_tmux "" --file "$WORK/ids.txt"
    answer 'Pilih \[1-2\]' 1 1 || return 0
    answer 'Hapus volume ini PERMANEN' 1 n || return 0
    answer 'Hapus volume ini PERMANEN' 2 q || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 0" "$rc" "0"
    expect_eq "vol 1 DECLINED" "$(tsv 11 "$(uid 81)")" "DECLINED"
    expect_eq "vol 2 & 3 belum diproses" "$(tsv 11 "$(uid 82)")/$(tsv 11 "$(uid 83)")" "NOT_PROCESSED/NOT_PROCESSED"
    expect_match "ringkasan NOT_PROCESSED" "$(screen_text)" '▸ Not processed \(2\)'
    expect_true "tidak ada delete" no_delete_called
}

test_changed_after_confirm() {
    local rc
    begin "changed_after_confirm"
    mk_vol 04 vol-newsnap
    scenario 04 newsnap

    run_tmux "" --id "$(uid 04)"
    answer 'Pilih \[1-2\]' 1 1 || return 0
    answer 'Hapus volume ini PERMANEN' 1 y || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 0" "$rc" "0"
    expect_eq "snapshot baru setelah konfirmasi -> dilewati" "$(tsv 13 "$(uid 04)")" "snapshots changed since confirmation"
    expect_true "tidak ada delete" no_delete_called
    expect_match "mode input id di log" "$(log_text | grep ' INPUT ')" "input_mode=id volume_id=$(uid 04)"
}

test_interrupt() {
    local rc
    begin "interrupt"
    mk_vol 91 vol-ctrlc
    mk_vol 92 vol-after
    scenario 91 stuck
    printf '%s\n' "$(uid 91)" "$(uid 92)" > "$WORK/ids.txt"

    run_tmux "" --file "$WORK/ids.txt" --interval 1
    answer 'Pilih \[1-2\]' 1 1 || return 0
    answer 'Hapus volume ini PERMANEN' 1 y || return 0
    wait_for 'status=deleting elapsed' 1 || return 0
    keys C-c
    rc="$(tmux_exit)"

    expect_eq "exit code 130" "$rc" "130"
    expect_match "pemberitahuan tetap berjalan" "$(screen_text)" 'TETAP BERJALAN di Cinder'
    expect_match "volume berjalan -> ABORTED + catatan" "$(tsv 11 "$(uid 91)") $(tsv 3 "$(uid 91)") $(tsv 13 "$(uid 91)")" \
        '^ABORTED vol-ctrlc polling dihentikan \(INT\); penghapusan tetap berjalan'
    expect_eq "volume berikutnya belum diproses" "$(tsv 11 "$(uid 92)")" "NOT_PROCESSED"
    expect_match "ringkasan parsial" "$(screen_text)" 'Ringkasan Delete Volume'
    expect_match "END signal=INT di log" "$(log_text | grep ' END ')" 'rc=130 .*signal=INT'
}

test_lock() {
    local rc holder
    begin "lock"
    mk_vol 01 vol-1
    uid 01 > "$WORK/ids.txt"
    mkdir -p "$WORK/log/volumes"
    flock "$WORK/log/volumes/delete-volume.lock" sleep 30 &
    holder=$!
    sleep 0.5

    run_tmux "" --file "$WORK/ids.txt" --no-confirm
    rc="$(tmux_exit)"
    kill "$holder" 2>/dev/null || true

    expect_eq "exit code 1" "$rc" "1"
    expect_match "pesan lock" "$(screen_text)" 'Delete volume lain sedang berjalan'
    expect_true "tidak ada delete" no_delete_called
}

test_no_tmux() {
    local rc
    begin "no_tmux"
    mk_vol 01 vol-1
    uid 01 > "$WORK/ids.txt"

    NO_TMUX=1 run_tmux "" --file "$WORK/ids.txt" --no-confirm
    answer 'Tetap lanjut\?' 1 n || return 0
    rc="$(tmux_exit)"

    expect_eq "exit code 0" "$rc" "0"
    expect_true "tidak ada delete" no_delete_called
}

test_interactive() {
    local rc
    begin "interactive"
    mk_vol 01 vol-1
    mk_vol 02 vol-2

    run_tmux ""
    answer 'Pilih \[1-2\]' 1 1 || return 0
    answer 'Volume ID:' 1 "  $(uid 01)  " || return 0
    answer 'Pilih \[1-2\]' 2 2 || return 0
    answer 'Ketik jumlah volume' 1 1 || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_eq "satu ID interaktif + batch -> SUCCESS" "$(tsv 11 "$(uid 01)")" "SUCCESS"

    begin "interactive_invalid_id"
    run_tmux "" --id bukan-uuid
    answer 'Pilih \[1-2\]' 1 1 || return 0
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_eq "--id tidak valid -> SKIPPED" "$(tsv 11 bukan-uuid)/$(tsv 13 bukan-uuid)" "SKIPPED/invalid id"
    expect_match "muncul di tabel TIDAK dihapus" "$(screen_text)" '▸ Invalid id \(1\)'
}

# ============================================================
# Run
# ============================================================

for t in cli per_volume outcomes no_confirm_ok no_confirm_mismatch dry_run quit changed_after_confirm interrupt lock no_tmux interactive; do
    want "$t" && "test_$t"
done

echo
echo "========================================"
echo "Lulus: $PASS   Gagal: $FAIL"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
