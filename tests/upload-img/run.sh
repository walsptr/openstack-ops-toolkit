#!/bin/bash
# ============================================================
# Tes images/upload-img.sh dengan stub OpenStack CLI dan stub qemu-img
# (tanpa cloud).
#
#   bash tests/upload-img/run.sh            # semua tes
#   bash tests/upload-img/run.sh dup        # hanya tes yang namanya cocok
#   KEEP=1 bash tests/upload-img/run.sh     # simpan direktori kerja
#
# Butuh: bash, jq, tmux, setsid, fzf (untuk satu tes picker). Script
# dijalankan di tmux karena semua prompt membaca dari /dev/tty.
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/images/upload-img.sh"
STUB="$HERE/stub/openstack"
QSTUB="$HERE/stub/qemu-img"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ui-test.XXXXXX")"
TM=(tmux -L "ui-test-$$")
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()

P_ADMIN="a0000000000000000000000000000001"
P_ALPHA="a0000000000000000000000000000002"
P_BETA="a0000000000000000000000000000003"
SECRET_PW="StubPassw0rd-Rahasia"

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
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "dapat: '$2'  harap: '$3'"; fi
}

expect_match() {
    if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "dapat: '${2:0:400}'  pola: '$3'"; fi
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
    rm -rf "$WORK/state" "$WORK/log" "$WORK/tmp"
    mkdir -p "$WORK/state/scen" "$WORK/state/images" "$WORK/log" "$WORK/tmp"
    : > "$WORK/state/calls.log"
    : > "$WORK/state/qemu.log"
}

scenario() {
    echo "$2" > "$WORK/state/scen/$1"
}

# mk_file NAMA [BYTES] — file image lokal (isi acak)
mk_file() {
    head -c "${2:-65536}" /dev/urandom > "$WORK/$1"
    printf '%s' "$WORK/$1"
}

# mk_image ID NAME OWNER [CREATED] [HIDDEN] — image yang sudah ada di Glance
mk_image() {
    jq -n --arg id "$1" --arg n "$2" --arg o "$3" --arg c "${4:-2026-09-01T10:00:00Z}" \
        --argjson h "${5:-false}" \
        '{id: $id, name: $n, status: "active", disk_format: "qcow2", container_format: "bare",
          visibility: "private", owner: $o, size: 1024, checksum: null, created_at: $c,
          tags: [], properties: {os_hidden: $h}}' > "$WORK/state/images/$1.json"
}

base_env() {
    printf '%s ' \
        "STUB_STATE=$(printf '%q' "$WORK/state")" \
        "OSOPS_OS_CMD=$(printf '%q' "$STUB")" \
        "OSOPS_QEMU_IMG=$(printf '%q' "$QSTUB")" \
        "OSOPS_LOG_DIR=$(printf '%q' "$WORK/log")" \
        "TMPDIR=$(printf '%q' "$WORK/tmp")" \
        OSOPS_NO_FZF=1 OS_REGION_NAME=RegionTest \
        OS_AUTH_URL=https://keystone.test:5000/v3 OS_PROJECT_NAME=admin \
        OS_PROJECT_DOMAIN_NAME=Default OS_USERNAME=admin "OS_PASSWORD=$SECRET_PW"
}

# run_tmux "ENV..." ARGS... — jalankan script di tmux. TMUX diset agar tidak
# ada peringatan tmux/screen, kecuali NO_TMUX=1 (TMUX dan STY dihapus).
run_tmux() {
    local envs="$1" cmd="" session="-u STY TMUX=ui-test"
    shift
    (( $# > 0 )) && printf -v cmd '%q ' "$@"
    [[ -n "${NO_TMUX:-}" ]] && session="-u TMUX -u STY"
    "${TM[@]}" kill-server 2>/dev/null || true
    "${TM[@]}" new-session -d -s t -x 230 -y 60 \
        "env $session $(base_env) $envs bash $(printf '%q' "$SCRIPT") $cmd; echo __EXIT=\$?; sleep 3600"
}

# run_direct [ENV=...]... -- ARGS... — tanpa tty; output di $OUT, exit code di $RC
run_direct() {
    local -a envs=()
    while (( $# > 0 )) && [[ "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    [[ "${1:-}" == "--" ]] && shift
    RC=0
    # setsid: tanpa controlling terminal (/dev/tty tidak tersedia)
    OUT="$(eval "env $(base_env)" '"${envs[@]}"' setsid -w bash '"$SCRIPT"' '"$@"' < /dev/null 2>&1)" || RC=$?
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

log_text() {
    cat "$WORK"/log/images/upload-img-*.log 2>/dev/null || true
}

calls() {
    cat "$WORK/state/calls.log"
}

create_call() {
    grep '^image create ' "$WORK/state/calls.log" | tail -n 1 || true
}

created_id() {
    create_call | sed -n 's/.*--id \([0-9a-f-]*\).*/\1/p'
}

no_create_called() {
    ! grep -qE '^image (create|import [^i])' "$WORK/state/calls.log"
}

no_convert_called() {
    ! grep -q '^convert' "$WORK/state/qemu.log"
}

tmp_empty() {
    [[ -z "$(ls -A "$WORK/tmp")" ]]
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

# Argumen standar untuk upload file tanpa prompt selain konfirmasi
std_args() {
    printf '%s\n' --file "$1" --name "${2:-img-test}" --disk-format qcow2 --visibility public
}

# ============================================================
# Tes
# ============================================================

test_cli() {
    local f
    begin "cli"
    run_direct -- --help
    expect_eq "--help exit 0" "$RC" "0"
    expect_match "--help isi" "$OUT" 'Usage: upload-img.sh .*--file PATH \| --url URL'
    expect_true "--help tidak membuat log" bash -c "! ls '$WORK'/log/images/*.log >/dev/null 2>&1"

    run_direct -- --bogus
    expect_match "parameter tidak dikenal" "$RC $OUT" '^1 .*Parameter tidak dikenal: --bogus'

    run_direct -- --file /etc/hostname --url https://x.test/a.img
    expect_match "--file dan --url eksklusif" "$RC $OUT" '^1 .*tidak bisa dipakai bersamaan'

    run_direct -- --file "$WORK/nope.img" --name x --disk-format raw --visibility public
    expect_match "file tidak ada" "$RC $OUT" '^1 .*File tidak ditemukan'

    : > "$WORK/empty.img"
    run_direct -- --file "$WORK/empty.img" --name x --disk-format raw --visibility public
    expect_match "file kosong" "$RC $OUT" '^1 .*File kosong \(0 bytes\)'

    run_direct -- --url ftp://x.test/a.img --name x --disk-format raw --visibility public
    expect_match "skema URL divalidasi" "$RC $OUT" '^1 .*URL harus diawali http:// atau https://'

    run_direct -- --url https://x.test/a.img --checksum sha999:abc
    expect_match "--checksum divalidasi" "$RC $OUT" '^1 .*--checksum harus berformat'

    run_direct -- --visibility secret
    expect_match "--visibility divalidasi" "$RC $OUT" '^1 .*--visibility harus'

    f="$(mk_file a.img)"
    run_direct -- --file "$f" --name x --disk-format raw --visibility public --convert-raw --dry-run
    expect_match "--convert-raw ditolak untuk raw" "$RC $OUT" '^1 .*--convert-raw tidak bisa dipakai: format raw'

    run_direct -- --file "$f" --name x --disk-format iso --visibility public --convert-raw --dry-run
    expect_match "--convert-raw ditolak untuk iso" "$RC $OUT" '^1 .*--convert-raw tidak bisa dipakai: format iso'

    run_direct -- --file "$f" --name x --disk-format qcow2 --visibility public
    expect_match "upload tanpa tty ditolak" "$RC $OUT" '^1 .*Butuh terminal interaktif'
    expect_true "tidak ada image create" no_create_called

    # shellcheck disable=SC2016  # backtick literal di pola
    expect_match "muncul di --list dengan metadata" "$(bash "$ROOT/main.sh" --workdir "$ROOT" --list)" \
        '\| Upload Image \| images \| `images/upload-img.sh` \| yes \|'
    expect_true "tests/ tidak ikut discovery" bash -c "! bash '$ROOT/main.sh' --discover '$ROOT' | grep -q tests/"
}

test_capabilities() {
    local f
    begin "capabilities"
    f="$(mk_file a.img)"
    mapfile -t args < <(std_args "$f")

    run_direct -- "${args[@]}" --dry-run
    expect_eq "dry-run exit 0" "$RC" "0"
    expect_match "region + auth host" "$OUT" 'Region  : RegionTest \(auth: keystone.test:5000\)'
    expect_match "API 2.17, os_hidden didukung" "$OUT" 'API v2.17 \(os_hidden: didukung\)'
    expect_match "web-download terdeteksi" "$OUT" 'web-download: ya'
    expect_true "duplikat hidden ikut dicari" grep -q -- '^image list --name img-test --long --hidden' "$WORK/state/calls.log"
    expect_match "CAPABILITIES di log" "$(log_text | grep CAPABILITIES)" \
        'region=RegionTest auth_host=keystone.test:5000 glance_max=2.17 os_hidden=1 import_methods=glance-direct,web-download,copy-image web_download=1'
    expect_true "versions show memakai region aktif" grep -q -- '^versions show --service image --region-name RegionTest' "$WORK/state/calls.log"

    begin "capabilities_old"
    scenario versions 2.5
    scenario importinfo noweb
    run_direct -- "${args[@]}" --dry-run
    expect_eq "exit 0" "$RC" "0"
    expect_match "os_hidden tidak didukung" "$OUT" 'API v2.5 \(os_hidden: tidak didukung'
    expect_match "web-download tidak ada" "$OUT" 'web-download: tidak'
    expect_true "tanpa list --hidden" bash -c "! grep -q -- '--hidden' '$WORK/state/calls.log'"

    run_direct -- --url https://x.test/a.img --name x --disk-format qcow2 --visibility public --dry-run
    expect_match "URL ditolak tanpa web-download" "$RC $OUT" '^1 .*butuh import method web-download, tidak tersedia di region RegionTest'

    begin "capabilities_fail"
    scenario versions fail
    scenario importinfo fail
    run_direct -- "${args[@]}" --dry-run
    expect_eq "deteksi gagal tidak menggagalkan script" "$RC" "0"
    expect_match "versi tidak diketahui" "$OUT" 'versi API tidak diketahui'
    expect_match "import tidak diketahui" "$OUT" 'Import  : tidak diketahui'
}

test_dry_run() {
    local f
    begin "dry_run"
    f="$(mk_file a.img)"

    run_direct -- --file "$f" --name dry --disk-format qcow2 --visibility shared --project proj-alpha \
        --convert-raw --tmp-dir "$WORK/tmp" --property os_distro=ubuntu --tag golden --dry-run
    expect_eq "exit 0" "$RC" "0"
    expect_match "perintah konversi ditampilkan" "$OUT" 'qemu-img convert -p -f qcow2 -O raw'
    expect_match "perintah create ditampilkan" "$OUT" "image create --id \\\\<uuid-baru\\\\> --disk-format raw --container-format bare --shared --min-disk 2 --property os_distro=ubuntu --tag golden --file .*upload-img-XXXXXXXX.raw --progress -f value -c id dry"
    expect_match "add project ditampilkan" "$OUT" "image add project .*$P_ALPHA"
    expect_true "tidak ada image create/import" no_create_called
    expect_true "tidak ada qemu-img convert" no_convert_called
    expect_true "tidak ada add project" bash -c "! grep -q '^image add project' '$WORK/state/calls.log'"
    expect_match "PLAN dry_run=true di log" "$(log_text)" 'INFO .*PLAN dry_run=true'
    expect_no_match "tanpa RESULT" "$(log_text)" ' RESULT '

    begin "dry_run_url"
    run_direct -- --url 'https://u:pw@x.test/a.qcow2?token=t0k' --name dry --disk-format qcow2 --visibility public --dry-run
    expect_eq "exit 0" "$RC" "0"
    expect_match "import ditampilkan (tersamar)" "$OUT" 'image import .*--method web-download --uri https://\*\*\*@x\.test/a\.qcow2\\\?token=\*\*\*'
    expect_true "tidak ada image create/import" no_create_called
    expect_no_match "kredensial tidak tampil" "$OUT" ':pw@|t0k'
    expect_no_match "kredensial tidak ada di log" "$(log_text)" ':pw@|t0k'
    expect_match "PLAN import di log (tersamar)" "$(log_text | grep 'PLAN dry_run=true CMD .*image import')" '--uri https://\*\*\*@x\.test/a\.qcow2'
}

test_format() {
    local f rc
    begin "format_picker"
    f="$(mk_file a.img)"
    run_tmux "" --file "$f" --name pick --visibility public
    answer 'Pilih \[1-8\]' 1 2 || return 0
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit 0" "$rc" "0"
    expect_match "qcow2 dari picker" "$(create_call)" '--disk-format qcow2 --container-format bare'
    expect_match "picker dicatat" "$(log_text | grep 'disk_format=qcow2 via=picker')" 'INPUT'

    begin "format_fzf"
    if command -v fzf >/dev/null 2>&1; then
        f="$(mk_file a.img)"
        run_tmux "OSOPS_NO_FZF=0" --file "$f" --name pick --visibility public
        wait_for 'Disk format \(sesuai isi file' 1 || return 0
        keys vhdx
        sleep 0.5
        keys Enter
        answer 'Upload image ini' 1 y || return 0
        rc="$(tmux_exit)"
        expect_eq "exit 0" "$rc" "0"
        expect_match "vhdx dari fzf" "$(create_call)" '--disk-format vhdx '
        expect_true "qemu-img memakai nama format pilihan user" grep -q '^info -f vhdx --output=json' "$WORK/state/qemu.log"
    else
        echo "  ⏭️  fzf tidak ada, tes fzf dilewati"
    fi

    begin "format_option"
    f="$(mk_file a.img)"
    run_tmux "" --file "$f" --name opt --disk-format foo-bar --visibility public
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    expect_match "--disk-format diteruskan apa adanya" "$(create_call)" '--disk-format foo-bar '
    expect_true "tidak ada picker" bash -c "! grep -q 'Pilih \\[1-8\\]' <<< \"\$(tmux -L ui-test-$$ capture-pane -p -t t -S -500)\""

    begin "format_reject"
    scenario create reject
    run_tmux "" --file "$f" --name opt --disk-format foo-bar --visibility public
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit 1" "$rc" "1"
    expect_match "error API + region" "$(screen_text)" "Upload gagal di region RegionTest: BadRequestException: .*Invalid value 'foo-bar' for parameter 'disk_format'"

    begin "format_never_auto"
    run_direct -- --file "$f" --name x --visibility public --dry-run
    expect_match "tanpa --disk-format dan tanpa tty: berhenti, tidak ada default" "$RC $OUT" '^1 .*Butuh terminal interaktif .*Disk format'
    expect_true "qemu-img tidak dipanggil sebelum format dipilih" bash -c "[[ ! -s '$WORK/state/qemu.log' ]]"

    f="$WORK/disk.qcow2"
    head -c 4096 /dev/urandom > "$f"
    run_tmux "" --file "$f" --name ext --visibility public --dry-run
    wait_for 'Pilih \[1-8\]' 1 || return 0
    expect_no_match "ekstensi .qcow2 tidak memilih format" "$(screen_text)" 'Format  :'
    keys 1 Enter
    rc="$(tmux_exit)"
    expect_match "format sesuai pilihan (raw)" "$(screen_text)" 'Format  : raw'
}

test_qemu() {
    local f
    begin "qemu_missing"
    f="$(mk_file a.img)"
    mapfile -t args < <(std_args "$f")
    run_direct OSOPS_QEMU_IMG=/nonexistent/qemu-img -- "${args[@]}" --dry-run
    expect_eq "exit 0" "$RC" "0"
    expect_match "pemberitahuan singkat" "$OUT" 'qemu-img: tidak tersedia \(virtual size / default min-disk dan konversi raw dilewati\)'
    expect_no_match "tanpa default --min-disk" "$OUT" '--min-disk'

    begin "qemu_ok"
    run_direct -- "${args[@]}" --dry-run
    expect_match "virtual size dibaca" "$OUT" 'Virtual : 1.5 GiB \(qemu-img -f qcow2\) → default min-disk 2 GB'
    expect_match "--min-disk dibulatkan ke atas" "$OUT" '--min-disk 2 '
    expect_true "qemu-img info memakai -f pilihan user" grep -q "^info -f qcow2 --output=json $f\$" "$WORK/state/qemu.log"
    expect_match "QEMU_INFO di log" "$(log_text | grep QEMU_INFO)" 'format=qcow2 virtual_size=1610612736 min_disk_default=2'

    begin "qemu_vhd_mapping"
    run_direct -- --file "$f" --name x --disk-format vhd --visibility public --dry-run
    expect_true "vhd → vpc untuk qemu-img" grep -q '^info -f vpc ' "$WORK/state/qemu.log"
    expect_match "disk_format Glance tetap vhd" "$OUT" '--disk-format vhd '

    begin "qemu_iso"
    run_direct -- --file "$f" --name x --disk-format iso --visibility public --dry-run
    expect_true "iso: qemu-img info tidak dipanggil" bash -c "[[ ! -s '$WORK/state/qemu.log' ]]"

    begin "qemu_fail"
    scenario qemu_info fail
    run_direct -- "${args[@]}" --dry-run
    expect_eq "hanya peringatan, alur lanjut" "$RC" "0"
    expect_match "peringatan + pesan error" "$OUT" "qemu-img tidak bisa membaca file sebagai 'qcow2' — file mungkin tidak sesuai dengan format yang dipilih: qemu-img: Could not open"
    expect_match "ringkasan tetap tampil" "$OUT" 'Ringkasan Upload Image'
    expect_no_match "tanpa default --min-disk" "$OUT" '--min-disk'
}

test_upload_ok() {
    local f rc id s
    begin "upload_ok"
    f="$(mk_file a.img 200000)"
    run_tmux "" --file "$f" --name ok-img --disk-format qcow2 --visibility public --min-ram 512 \
        --preset linux --property hw_disk_bus=scsi --tag base --interval 1
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    id="$(created_id)"
    s="$(screen_text)"

    expect_eq "exit 0" "$rc" "0"
    expect_match "--progress diteruskan untuk file lokal" "$(create_call)" "--file $f --progress -f value -c id ok-img\$"
    expect_eq "stdout image create adalah TTY (tidak ditangkap)" "$(cut -d' ' -f1-2 "$WORK/state/create_tty")" "tty=1 progress=1"
    expect_match "bar progres tampil di terminal" "$s" '\[=+>\] 100%'
    expect_match "ID dipesan dengan --id (UUID)" "$id" '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    expect_match "preset + --property menimpa" "$(create_call)" '--property hw_qemu_guest_agent=yes --property hw_disk_bus=scsi --tag base'
    expect_match "--min-ram diteruskan" "$(create_call)" '--min-disk 2 --min-ram 512'
    expect_match "polling sampai active" "$s" 'Image active'
    expect_match "verifikasi size" "$s" 'size : cocok \(200000 bytes\)'
    expect_match "verifikasi hash" "$s" 'hash : cocok \(sha512\)'
    expect_match "ringkasan akhir" "$s" "Image ID +: $id"
    expect_match "ringkasan: log" "$s" 'Log +: .*/images/upload-img-[0-9]{8}\.log'
    expect_match "RESULT upload-image lengkap" "$(log_text | grep 'action=upload-image')" \
        "resource=$id action=upload-image result=SUCCESS name=ok-img region=RegionTest disk_format=qcow2 visibility=public owner=$P_ADMIN size=200000 hash=sha512:[0-9a-f]{128} duration=[0-9]+"
    expect_match "waktu mulai/selesai upload di log" "$(log_text | grep -E 'UPLOAD_(START|END)' | awk '{print $5}' | tr '\n' ' ')" '^UPLOAD_START UPLOAD_END $'
    expect_no_match "bar progres tidak masuk log" "$(log_text)" '100%'
    expect_match "CMD create di log" "$(log_text | grep ' CMD ')" 'image create --id'
    expect_true "log di \$LOG_DIR/images/" bash -c "ls '$WORK'/log/images/upload-img-*.log >/dev/null"
    expect_true "password tidak ada di log" bash -c "! grep -rq '$SECRET_PW' '$WORK/log'"
}

test_visibility() {
    local f rc s
    begin "visibility_private"
    f="$(mk_file a.img)"
    run_tmux "" --file "$f" --name priv --disk-format raw --visibility private --interval 1
    answer 'Pilih \[1-4\]' 1 2 || return 0          # proj-alpha (urut nama)
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit 0" "$rc" "0"
    expect_match "picker project dengan domain" "$(screen_text)" 'proj-gamma +\[dom-two\]'
    expect_match "private dengan --project owner" "$(create_call)" "--private --project $P_ALPHA "
    expect_match "owner di ringkasan" "$(screen_text)" "Owner +: proj-alpha \($P_ALPHA\)"

    begin "visibility_shared"
    run_tmux "" --file "$f" --name shr --disk-format raw --visibility shared --interval 1
    answer 'Pilih nomor' 1 "2, 3" || return 0
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    s="$(screen_text)"
    expect_eq "exit 0" "$rc" "0"
    expect_match "shared tanpa --project (owner = credentials)" "$(create_call)" '--shared --min-disk'
    expect_no_match "shared: create tanpa --project" "$(create_call)" '--project'
    expect_eq "add project untuk setiap penerima" "$(grep -c '^image add project' "$WORK/state/calls.log")" "2"
    expect_true "add project alpha" grep -q "^image add project .* $P_ALPHA -f json" "$WORK/state/calls.log"
    expect_true "add project beta" grep -q "^image add project .* $P_BETA -f json" "$WORK/state/calls.log"
    expect_match "instruksi accept" "$s" 'openstack image set --accept [0-9a-f-]{36}'
    expect_match "status member di ringkasan" "$s" "proj-alpha \($P_ALPHA\): pending"
    expect_true "tidak pernah image set --accept --project (mengubah owner)" \
        bash -c "! grep -q -- '--accept' '$WORK/state/calls.log'"
    expect_eq "RESULT share-image per project" "$(log_text | grep -c 'action=share-image result=SUCCESS')" "2"
    expect_match "MEMBER_PENDING di log" "$(log_text | grep MEMBER_PENDING)" 'instruction='

    begin "visibility_shared_args"
    run_tmux "" --file "$f" --name shr --disk-format raw --visibility shared --project proj-alpha \
        --project "$P_BETA" --project admin --interval 1
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "nama dan ID diterima, owner dilewati" "$(grep -c '^image add project' "$WORK/state/calls.log")" "2"

    begin "visibility_community"
    run_tmux "" --file "$f" --name com --disk-format raw --visibility community --interval 1
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    expect_match "penjelasan community" "$(screen_text)" 'Community: image bisa dipakai oleh SEMUA project'
    expect_match "--community" "$(create_call)" '--community '

    begin "visibility_picker"
    run_tmux "" --file "$f" --name pub --disk-format raw --interval 1
    answer 'Pilih \[1-4\]' 1 1 || return 0
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    expect_match "public dari picker" "$(create_call)" '--public '

    run_direct -- --file "$f" --name x --disk-format raw --visibility public --project proj-alpha --dry-run
    expect_match "--project ditolak untuk public" "$RC $OUT" '^1 .*--project hanya untuk visibility private'
}

test_duplicates() {
    local f rc s old1="d1000000-0000-4000-8000-000000000001" old2="d1000000-0000-4000-8000-000000000002"
    f="$(mk_file a.img)"

    begin "dup_abort"
    mk_image "$old1" dup-img "$P_ADMIN" 2026-09-01T10:00:00Z
    run_tmux "" --file "$f" --name dup-img --disk-format raw --visibility public
    answer 'Pilih \[a/c/r\]' 1 a || return 0
    rc="$(tmux_exit)"
    expect_eq "exit 0" "$rc" "0"
    expect_match "daftar duplikat (ID, owner, visibility, created_at)" "$(screen_text)" "$old1 +admin +private +active +2026-09-01T10:00:00Z"
    expect_true "batal: tidak ada create" no_create_called
    expect_match "DECLINED di log" "$(log_text | grep RESULT)" 'result=DECLINED .*nama duplikat'

    begin "dup_continue"
    mk_image "$old1" dup-img "$P_ADMIN" 2026-09-01T10:00:00Z
    run_tmux "" --file "$f" --name dup-img --disk-format raw --visibility public --interval 1
    answer 'Pilih \[a/c/r\]' 1 c || return 0
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    s="$(screen_text)"
    expect_eq "exit 0" "$rc" "0"
    expect_match "info nama ganda: ID upload" "$s" "Image yang Anda upload : $(created_id)"
    expect_match "info nama ganda: ID lain" "$s" "Nama sama +: $old1 \(owner admin, private\)"
    expect_true "tanpa rotasi" bash -c "! grep -q '^image set' '$WORK/state/calls.log'"

    begin "dup_rotate"
    mk_image "$old1" dup-img "$P_ADMIN" 2026-09-01T10:00:00Z
    mk_image "$old2" dup-img "$P_ALPHA" 2026-08-01T10:00:00Z
    mk_image "d1000000-0000-4000-8000-000000000003" dup-img-20260901 "$P_ADMIN"
    run_tmux "" --file "$f" --name dup-img --disk-format raw --visibility public --interval 1
    answer 'Pilih \[a/c/r\]' 1 r || return 0
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    s="$(screen_text)"
    expect_eq "exit 0" "$rc" "0"
    expect_match "rotasi setelah create" "$(grep -nE '^image (create|set)' "$WORK/state/calls.log" | cut -d: -f1 | tr '\n' ' ')" '^[0-9]+ [0-9]+ $'
    expect_true "nama rotasi unik + hidden" grep -q "^image set --name dup-img-20260901-2 --hidden $old1\$" "$WORK/state/calls.log"
    expect_true "image project lain tidak dirotasi" bash -c "! grep -q 'image set .*$old2' '$WORK/state/calls.log'"
    expect_match "RESULT rotate-image" "$(log_text | grep 'action=rotate-image')" "resource=$old1 action=rotate-image result=SUCCESS new_name=dup-img-20260901-2 hidden=1"
    expect_match "info nama ganda untuk yang tidak dirotasi" "$s" "Nama sama +: $old2"

    begin "dup_rotate_no_hidden"
    scenario versions 2.5
    mk_image "$old1" dup-img "$P_ADMIN" 2026-09-01T10:00:00Z
    run_tmux "" --file "$f" --name dup-img --disk-format raw --visibility public --interval 1
    answer 'Pilih \[a/c/r\]' 1 r || return 0
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    expect_true "tanpa os_hidden: rename saja" grep -q "^image set --name dup-img-20260901 $old1\$" "$WORK/state/calls.log"

    begin "dup_rotate_upload_fail"
    scenario create fail
    mk_image "$old1" dup-img "$P_ADMIN" 2026-09-01T10:00:00Z
    run_tmux "" --file "$f" --name dup-img --disk-format raw --visibility public --interval 1
    answer 'Pilih \[a/c/r\]' 1 r || return 0
    answer 'Upload image ini' 1 y || return 0
    answer 'Hapus image' 1 n || return 0
    rc="$(tmux_exit)"
    expect_eq "exit 1" "$rc" "1"
    expect_true "rotasi tidak jalan jika upload gagal" bash -c "! grep -q '^image set' '$WORK/state/calls.log'"

    begin "dup_rejected_by_osc"
    scenario create dupfail
    mk_image "$old1" dup-img "$P_ADMIN"
    mk_image "$old2" dup-img "$P_ALPHA"
    run_tmux "" --file "$f" --name dup-img --disk-format raw --visibility public --interval 1
    answer 'Pilih \[a/c/r\]' 1 c || return 0
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    s="$(screen_text)"
    expect_eq "exit 1" "$rc" "1"
    expect_match "catatan OSC saat >1 duplikat" "$s" 'More than one Image exists'
    expect_match "fallback: ID yang disiapkan" "$s" "Image ID yang disiapkan untuk upload ini : $(created_id) \(tidak dibuat\)"
    expect_match "fallback: ID image lain" "$s" "- $old2 \(owner proj-alpha, private\)"
    expect_match "tidak ada image tertinggal" "$s" 'Tidak ada image yang tertinggal'
}

test_convert() {
    local f rc s id
    f="$(mk_file a.img 100000)"

    begin "convert_ok"
    run_tmux "" --file "$f" --name conv --disk-format qcow2 --visibility public --convert-raw \
        --tmp-dir "$WORK/tmp" --interval 1
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    s="$(screen_text)"
    id="$(created_id)"
    expect_eq "exit 0" "$rc" "0"
    expect_true "qemu-img convert dengan -f pilihan user" grep -q "^convert -p -f qcow2 -O raw $f $WORK/tmp/upload-img-.*\.raw\$" "$WORK/state/qemu.log"
    expect_match "upload sebagai raw dari file sementara" "$(create_call)" "--disk-format raw .*--file $WORK/tmp/upload-img-[^ ]+\.raw --progress"
    expect_match "progres qemu-img tampil" "$s" '\(100.00/100%\)'
    expect_match "hash file hasil konversi cocok" "$s" 'hash : cocok \(sha512\)'
    expect_true "file sementara dihapus setelah selesai" tmp_empty
    expect_match "CONVERT di log" "$(log_text | grep ' CONVERT ')" 'result=ok duration=[0-9]+ size_before=100000 size_after=100004'
    expect_match "RESULT disk_format raw" "$(log_text | grep 'action=upload-image')" "resource=$id .*result=SUCCESS .*disk_format=raw"

    begin "convert_fail"
    scenario qemu_convert fail
    run_tmux "" --file "$f" --name conv --disk-format qcow2 --visibility public --convert-raw --tmp-dir "$WORK/tmp"
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit 1" "$rc" "1"
    expect_true "file sementara dihapus saat konversi gagal" tmp_empty
    expect_true "tidak ada upload" no_create_called
    expect_match "RESULT FAILED" "$(log_text | grep RESULT)" 'action=upload-image result=FAILED .*konversi qemu-img gagal'

    begin "convert_upload_fail"
    scenario create fail
    run_tmux "" --file "$f" --name conv --disk-format qcow2 --visibility public --convert-raw --tmp-dir "$WORK/tmp"
    answer 'Upload image ini' 1 y || return 0
    answer 'Hapus image' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit 1" "$rc" "1"
    expect_true "file sementara dihapus saat upload gagal" tmp_empty

    begin "convert_space"
    scenario qemu_info "ok 1000000000000000000"
    run_direct -- --file "$f" --name conv --disk-format qcow2 --visibility public --convert-raw --tmp-dir "$WORK/tmp" --dry-run
    expect_match "ruang tidak cukup → batal" "$RC $OUT" '^1 .*Ruang kosong di .* tidak cukup untuk konversi'
    expect_true "tidak ada konversi" no_convert_called

    begin "convert_interactive"
    run_tmux ""
    answer 'Pilih \[1-2\]' 1 1 || return 0                       # sumber file
    answer 'Path file image' 1 "$f" || return 0
    answer 'Nama image' 1 "" || return 0                        # default dari nama file
    answer 'Pilih \[1-8\]' 1 2 || return 0                      # qcow2
    answer 'Konversi qcow2 → raw' 1 y || return 0
    answer 'Min disk \(GB\) \[default 2\]' 1 "" || return 0
    answer 'Min RAM' 1 "" || return 0
    answer 'Pilih \[1-4\]' 1 1 || return 0                      # public
    answer 'Pilih \[1-4\]' 2 2 || return 0                      # preset linux
    answer 'os_distro' 1 ubuntu || return 0
    answer 'os_version' 1 "" || return 0
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    s="$(screen_text)"
    expect_eq "exit 0" "$rc" "0"
    expect_match "penjelasan Ceph RBD" "$s" 'Raw direkomendasikan untuk backend Ceph RBD'
    expect_match "ringkasan menampilkan konversi" "$s" 'Disk format +: qcow2 → raw'
    expect_match "nama default dari file" "$(create_call)" ' a$'
    expect_match "os_distro dari prompt" "$(create_call)" '--property os_distro=ubuntu'
    expect_true "file sementara dihapus" tmp_empty

    begin "convert_not_offered_raw"
    run_tmux ""
    answer 'Pilih \[1-2\]' 1 1 || return 0
    answer 'Path file image' 1 "$f" || return 0
    answer 'Nama image' 1 rawimg || return 0
    answer 'Pilih \[1-8\]' 1 1 || return 0                      # raw
    answer 'Min disk' 1 "" || return 0
    answer 'Min RAM' 1 "" || return 0
    answer 'Pilih \[1-4\]' 1 1 || return 0
    answer 'Pilih \[1-4\]' 2 1 || return 0
    answer 'Upload image ini' 1 n || return 0
    rc="$(tmux_exit)"
    expect_no_match "konversi tidak ditawarkan untuk raw" "$(screen_text)" 'Konversi .*→ raw'
    expect_match "batal → DECLINED" "$(log_text | grep RESULT)" 'result=DECLINED .*dibatalkan operator'
}

test_checksum() {
    local f rc s id
    f="$(mk_file a.img)"

    begin "checksum_mismatch"
    scenario hash mismatch
    run_tmux "" --file "$f" --name cs --disk-format raw --visibility public --interval 1
    answer 'Upload image ini' 1 y || return 0
    answer 'Hapus image .*status active' 1 y || return 0
    rc="$(tmux_exit)"
    id="$(created_id)"
    expect_eq "exit 1" "$rc" "1"
    expect_match "FAILED (checksum mismatch)" "$(screen_text)" 'FAILED \(checksum mismatch\)'
    expect_true "image dihapus setelah konfirmasi" grep -q "^image delete $id\$" "$WORK/state/calls.log"
    expect_match "RESULT upload FAILED" "$(log_text | grep 'action=upload-image')" 'result=FAILED .*msg="checksum mismatch"'
    expect_match "RESULT cleanup" "$(log_text | grep 'action=cleanup-image')" "resource=$id action=cleanup-image result=SUCCESS status=active"

    begin "checksum_format_changed"
    scenario hash convert
    run_tmux "" --file "$f" --name cs --disk-format qcow2 --visibility public --interval 1
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    s="$(screen_text)"
    expect_eq "format diubah Glance → bukan kegagalan" "$rc" "0"
    expect_match "warning konversi Glance" "$s" 'Glance mengubah disk_format qcow2 → raw'
    expect_match "WARN di log" "$(log_text | grep ' WARN ')" 'Glance mengubah disk_format'
    expect_match "RESULT SUCCESS + catatan" "$(log_text | grep 'action=upload-image')" 'result=SUCCESS .*disk_format diubah Glance qcow2 → raw'

    begin "checksum_local_option"
    run_direct -- --file "$f" --name cs --disk-format raw --visibility public --checksum "sha256:$(printf x | sha256sum | cut -d' ' -f1)" --dry-run
    expect_match "--checksum file lokal tidak cocok → batal sebelum upload" "$RC $OUT" '^1 .*Checksum file lokal tidak cocok'
    run_direct -- --file "$f" --name cs --disk-format raw --visibility public --checksum "sha256:$(sha256sum "$f" | cut -d' ' -f1)" --dry-run
    expect_match "--checksum file lokal cocok" "$RC $OUT" '^0 .*Checksum file lokal cocok \(sha256\)'
}

test_upload_fail() {
    local rc f id
    begin "upload_fail_cleanup"
    scenario create fail
    f="$(mk_file a.img)"
    run_tmux "" --file "$f" --name fail --disk-format raw --visibility public
    answer 'Upload image ini' 1 y || return 0
    answer 'Hapus image .*status queued' 1 y || return 0
    rc="$(tmux_exit)"
    id="$(created_id)"
    expect_eq "exit 1" "$rc" "1"
    expect_match "pesan gagal + region" "$(screen_text)" 'Upload gagal di region RegionTest: Image creation failed'
    expect_true "image tertinggal dihapus" grep -q "^image delete $id\$" "$WORK/state/calls.log"
    expect_match "keputusan cleanup dicatat" "$(log_text | grep DECISION | tail -n 1)" 'cleanup=yes'
    expect_match "RESULT upload FAILED" "$(log_text | grep 'action=upload-image')" "resource=$id .*result=FAILED"
    expect_match "RESULT cleanup SUCCESS" "$(log_text | grep 'action=cleanup-image')" 'result=SUCCESS status=queued'

    begin "upload_fail_keep"
    scenario create fail
    run_tmux "" --file "$f" --name fail --disk-format raw --visibility public
    answer 'Upload image ini' 1 y || return 0
    answer 'Hapus image' 1 n || return 0
    rc="$(tmux_exit)"
    expect_true "tidak dihapus" bash -c "! grep -q '^image delete' '$WORK/state/calls.log'"
    expect_match "cleanup DECLINED" "$(log_text | grep 'action=cleanup-image')" 'result=DECLINED'

    begin "upload_interrupt"
    scenario create hang
    run_tmux "" --file "$f" --name ctrlc --disk-format raw --visibility public
    answer 'Upload image ini' 1 y || return 0
    wait_for 'Upload ke Glance' 1 || return 0
    sleep 1
    keys C-c
    answer 'Hapus image .*status queued' 1 y || return 0
    rc="$(tmux_exit)"
    id="$(created_id)"
    expect_eq "exit 130" "$rc" "130"
    expect_true "image tertinggal dihapus" grep -q "^image delete $id\$" "$WORK/state/calls.log"
    expect_match "RESULT ABORTED" "$(log_text | grep 'action=upload-image')" 'result=ABORTED'
    expect_match "END signal=INT" "$(log_text | grep ' END ')" 'signal=INT'
}

test_url() {
    local rc s id url='https://alice:Pa55word@mirror.test/images/disk.qcow2?token=Tok3nValue&v=2'
    begin "url_ok"
    run_tmux "" --url "$url" --name url-img --disk-format qcow2 --visibility public --interval 1 \
        --checksum sha512:5f6e2a9c0d1b3e4f
    answer 'Upload image ini' 1 y || return 0
    rc="$(tmux_exit)"
    s="$(screen_text)"
    id="$(created_id)"
    expect_eq "exit 0" "$rc" "0"
    expect_match "create tanpa --file/--progress" "$(create_call)" '--disk-format qcow2 --container-format bare --public -f value -c id url-img$'
    expect_true "import web-download dengan URL asli" grep -qF "image import $id --method web-download --uri $url" "$WORK/state/calls.log"
    expect_match "checksum URL cocok" "$s" 'hash : cocok dengan --checksum \(sha512\)'
    expect_no_match "kredensial tidak tampil di layar" "$s" 'Pa55word|Tok3nValue'
    expect_match "URL tersamar di layar" "$s" 'https://\*\*\*@mirror.test/images/disk.qcow2\?token=\*\*\*&v=2'
    expect_no_match "kredensial tidak ada di log" "$(log_text)" 'Pa55word|Tok3nValue|alice'
    expect_match "URL tersamar di log" "$(log_text | grep 'source=url')" 'url="?https://\*\*\*@mirror.test/images/disk.qcow2\?token=\*\*\*&v=2'

    begin "url_import_error_masked"
    scenario import fail
    run_tmux "" --url "$url" --name url-img --disk-format qcow2 --visibility public --interval 1
    answer 'Upload image ini' 1 y || return 0
    answer 'Hapus image' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit 1" "$rc" "1"
    expect_no_match "error API tersamar di layar" "$(screen_text)" 'Pa55word|Tok3nValue'
    expect_no_match "error API tersamar di log" "$(log_text)" 'Pa55word|Tok3nValue'
    expect_match "pesan import gagal" "$(screen_text)" 'Image import gagal di region RegionTest'

    begin "url_failed_import"
    scenario import failed
    run_tmux "" --url "https://mirror.test/x.qcow2" --name url-img --disk-format qcow2 --visibility public --interval 1
    answer 'Upload image ini' 1 y || return 0
    answer 'Hapus image' 1 y || return 0
    rc="$(tmux_exit)"
    expect_eq "exit 1" "$rc" "1"
    expect_match "os_glance_failed_import terdeteksi" "$(screen_text)" 'import gagal \(os_glance_failed_import=file1\)'

    begin "url_checksum_mismatch"
    run_tmux "" --url "https://mirror.test/x.qcow2" --name url-img --disk-format qcow2 --visibility public --interval 1 \
        --checksum sha512:0000
    answer 'Upload image ini' 1 y || return 0
    answer 'Hapus image .*status active' 1 n || return 0
    rc="$(tmux_exit)"
    expect_eq "exit 1" "$rc" "1"
    expect_match "mismatch dengan --checksum" "$(screen_text)" 'BERBEDA dari --checksum'
}

test_large_no_tmux() {
    local f rc
    begin "large_no_tmux"
    f="$WORK/big.img"
    truncate -s 6G "$f"
    NO_TMUX=1 run_tmux "" --file "$f" --name big --disk-format raw --visibility public
    answer 'Upload image ini' 1 n || return 0
    rc="$(tmux_exit)"
    expect_match "peringatan SSH untuk file besar" "$(screen_text)" 'Tidak berjalan di dalam tmux/screen dan file besar \(6.0 GiB\)'
    rm -f "$f"
}

# ============================================================
# Run
# ============================================================

for t in cli capabilities dry_run format qemu upload_ok visibility duplicates convert checksum upload_fail url large_no_tmux; do
    want "$t" && "test_$t"
done

echo
echo "========================================"
echo "Lulus: $PASS   Gagal: $FAIL"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
