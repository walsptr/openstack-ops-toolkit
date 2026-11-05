#!/bin/bash
# shellcheck disable=SC2016  # pola regex berisi $ literal (hash crypt, $1)
# ============================================================
# Tes servers/create-vm.sh dengan stub openstack/curl/fzf (tanpa cloud).
#
#   bash tests/create-vm/run.sh            # semua tes
#   bash tests/create-vm/run.sh scope      # hanya tes yang namanya cocok
#   KEEP=1 bash tests/create-vm/run.sh     # simpan direktori kerja
#
# Butuh: bash, jq, tmux, openssl, ssh-keygen. Script dijalankan di tmux karena
# prompt membaca /dev/tty. Stub meniru OSC 7.1.2 (default) atau 5.5.2 (RHOSP
# 17.1; teks --help asli di fixtures/help/).
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/servers/create-vm.sh"
STUB="$HERE/stub"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cv-test.XXXXXX")"
TM=(tmux -L "cv-test-$$")
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()
CURRENT=""

P_ADMIN=a0000000000000000000000000000001
P_DEV=b0000000000000000000000000000002
P_NOROLE=c0000000000000000000000000000003
IMG_RHEL=11111111-0000-4000-8000-000000000001
IMG_RHEL8=11111111-0000-4000-8000-000000000007

for tool in jq tmux openssl ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || { echo "❌ $tool dibutuhkan untuk tes"; exit 1; }
done

cleanup() {
    "${TM[@]}" kill-server 2>/dev/null || true
    if [[ -n "${KEEP:-}" ]]; then echo "Direktori kerja disimpan: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

ok() { PASS=$(( PASS + 1 )); echo "  ✅ $1"; }
bad() {
    FAIL=$(( FAIL + 1 ))
    FAILED_TESTS+=("$CURRENT: $1")
    echo "  ❌ $1"
    [[ -n "${2:-}" ]] && printf '     %s\n' "$2"
    return 0
}
expect_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "dapat: '$2'  harap: '$3'"; fi; }
expect_match() { if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "dapat: '${2:0:500}'  pola: '$3'"; fi; }
expect_no_match() { if [[ ! "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "pola tidak boleh muncul: '$3'"; fi; }
expect_true() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
want() { [[ -z "$FILTER" || "$1" == *"$FILTER"* ]]; }

reset_state() {
    "${TM[@]}" kill-server 2>/dev/null || true
    rm -rf "${WORK:?}/state" "${WORK:?}/log" "${WORK:?}/home" "${WORK:?}/creds"
    mkdir -p "$WORK/state/scen" "$WORK/log" "$WORK/home/.ssh" "$WORK/creds"
    ssh-keygen -q -t ed25519 -N '' -C 'ops@test' -f "$WORK/home/.ssh/id_ed25519"
    ssh-keygen -q -t rsa -b 2048 -N '' -C 'other@test' -f "$WORK/home/.ssh/id_rsa"
    echo "ini bukan public key" > "$WORK/home/bad.pub"
}

begin() {
    CURRENT="$1"
    echo
    echo "▶ $1"
    reset_state
}

scen() { echo "$2" > "$WORK/state/scen/$1"; }

# run_cv "ENV..." ARGS... — script di tmux dengan environment RC palsu
run_cv() {
    local envs="$1" cmd=""
    shift
    (( $# > 0 )) && printf -v cmd '%q ' "$@"
    "${TM[@]}" kill-server 2>/dev/null || true
    "${TM[@]}" new-session -d -s t -x 250 -y 100 \
        "env -u OS_CLOUD HOME=$(printf '%q' "$WORK/home") STUB_STATE=$(printf '%q' "$WORK/state") \
OSOPS_OS_CMD=$(printf '%q' "$STUB/openstack") OSOPS_CURL=$(printf '%q' "$STUB/curl") OSOPS_FZF=$(printf '%q' "$STUB/fzf") \
OSOPS_LOG_DIR=$(printf '%q' "$WORK/log") OSOPS_CREDS_DIR=$(printf '%q' "$WORK/creds") OSOPS_POLL_INTERVAL=1 \
OS_AUTH_URL=https://keystone.example.com:5000/v3 OS_REGION_NAME=regionOne OS_USERNAME=admin OS_PASSWORD=FakeRcPassword-55aa \
OS_PROJECT_NAME=admin OS_TENANT_NAME=admin OS_PROJECT_DOMAIN_NAME=Default OS_USER_DOMAIN_NAME=Default \
$envs bash $(printf '%q' "$SCRIPT") $cmd; echo __EXIT=\$?; sleep 3600"
}

screen_text() { "${TM[@]}" capture-pane -p -J -t t -S -3000 2>/dev/null; }
last_line() { screen_text | grep -v '^[[:space:]]*$' | tail -n 1; }
keys() { "${TM[@]}" send-keys -t t "$@"; }

# drive END_PATTERN "PROMPT_ERE=JAWABAN"... — jawab prompt sampai END_PATTERN
# muncul. Prompt [y/N]/[Y/n] lain dijawab Enter (default).
drive() {
    local end="$1" i line pair p a answered="" key
    shift
    for (( i = 0; i < 300; i++ )); do
        screen_text | grep -qE -- "$end" && return 0
        line="$(last_line)"
        key="$(screen_text | grep -vc '^[[:space:]]*$')|$line"
        if [[ -n "$line" && "$key" != "$answered" ]]; then
            for pair in "$@"; do
                p="${pair%%=>*}" a="${pair#*=>}"
                if [[ "$line" =~ $p ]]; then
                    keys -l "$a"
                    keys Enter
                    answered="$key"
                    sleep 0.3
                    continue 2
                fi
            done
            if [[ "$line" =~ \[(y/N|Y/n)\]:\ *$ ]]; then
                keys Enter
                answered="$key"
                sleep 0.3
                continue
            fi
        fi
        sleep 0.2
    done
    bad "timeout menunggu '$end'"
    screen_text | grep -v '^$' | tail -n 15 | sed 's/^/     | /'
    return 1
}

exit_code() {
    drive '__EXIT=' "$@" || { echo "?"; return 0; }
    screen_text | grep -o '__EXIT=[0-9]*' | tail -n 1 | cut -d= -f2
}

# argv dicatat dengan %q: hapus backslash agar mudah dicocokkan
calls() { sed 's/\\//g' "$WORK/state/calls.log" 2>/dev/null; }
log_text() { cat "$WORK"/log/servers/*.log 2>/dev/null; }

# Password yang ditampilkan di ringkasan akhir (urut VM)
shown_passwords() {
    screen_text | sed -nE 's/^  Password +([A-Za-z0-9]{20})$/\1/p'
}

# hash_matches PASSWORD HASH — hash SHA-512 crypt cocok dengan password?
hash_matches() {
    local salt
    salt="$(cut -d'$' -f3 <<< "$2")"
    [[ "$(printf '%s\n' "$1" | openssl passwd -6 -salt "$salt" -stdin)" == "$2" ]]
}

ud_hash() {
    sed -nE "s/^    passwd: '(.*)'$/\1/p" "$1"
}

CONFIRM='Buat [0-9]+ VM di project .*\[y/N\]: *$=>y'

# Opsi lengkap umum (pertanyaan host/floating IP dijawab default oleh drive)
BASE=(--name web --image "$IMG_RHEL" --flavor m1.small --network private --security-group default
      --volume-type ssd --volume-size 12 --boot volume)

# ============================================================
# Tes
# ============================================================

test_scope() {
    local rc
    begin "scope_switch"
    run_cv "" --project dev "${BASE[@]}" --no-key --dry-run
    rc="$(exit_code)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "project aktif dari RC ditampilkan" "$(screen_text)" "Project aktif    : admin \\($P_ADMIN\\), domain Default"
    expect_match "project tujuan dev" "$(screen_text)" "Project tujuan    : dev \\($P_DEV\\)"
    expect_match "token diverifikasi" "$(log_text)" "SCOPE_VERIFY project_id=$P_DEV project=dev .*result=OK"
    local after
    after="$(sed -n "/opt=$P_DEV/p" "$WORK/state/env.log")"
    expect_true "setelah ganti: opsi --os-project-id dipakai" test -n "$after"
    expect_no_match "OS_PROJECT_NAME/OS_TENANT_NAME dibersihkan" "$after" 'OS_PROJECT_NAME=admin|OS_TENANT_NAME=admin|OS_PROJECT_DOMAIN_NAME=Default'
    expect_match "OS_PROJECT_ID diset" "$after" "OS_PROJECT_ID=$P_DEV"
    expect_eq "semua panggilan setelah ganti ber-scope dev" "$(grep -c "scope=$P_ADMIN" <<< "$after" || true)" "0"

    begin "scope_norole"
    printf '%s\n' "$P_NOROLE" > "$WORK/state/scen/norole"
    run_cv "" --project norole "${BASE[@]}" --no-key --dry-run
    rc="$(exit_code)"
    expect_eq "tanpa role => exit 1" "$rc" "1"
    expect_match "pesan jelas + saran assign-user-to-project" "$(screen_text)" 'identity/assign-user-to-project.sh'
    expect_match "log SCOPE_VERIFY FAILED" "$(log_text)" "SCOPE_VERIFY project_id=$P_NOROLE result=FAILED"

    begin "scope_norole_interactive"
    printf '%s\n' "$P_NOROLE" > "$WORK/state/scen/norole"
    run_cv "STUB_FZF_1=^$P_NOROLE STUB_FZF_2=^$P_DEV" "${BASE[@]}" --no-key --dry-run
    rc="$(exit_code 'Pakai project lain.*=>y' 'SEMUA project.*=>y')"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "admin ditawari semua project" "$(screen_text)" 'Daftar semua project: Anda tetap harus punya role'
    expect_match "gagal => kembali ke project awal" "$(screen_text)" 'Kembali ke project admin'
    expect_match "lalu berhasil ke dev" "$(screen_text)" "Project tujuan    : dev \\($P_DEV\\)"
    expect_match "picker berisi project norole" "$(cat "$WORK/state/fzf1.in")" 'norole'

    begin "scope_dup"
    run_cv "" --project dup "${BASE[@]}" --no-key --dry-run
    rc="$(exit_code)"
    expect_eq "nama project ganda => exit 1" "$rc" "1"
    expect_match "minta ID / --project-domain" "$(screen_text)" 'beberapa domain. Pakai ID atau --project-domain'
}

test_images() {
    local rc lst
    begin "image_filter"
    run_cv "STUB_FZF_1=^$IMG_RHEL8" --project dev --name x --flavor m1.medium --network private \
        --security-group default --no-key --boot image --dry-run
    rc="$(exit_code)"
    expect_eq "exit code 0" "$rc" "0"
    lst="$(cat "$WORK/state/fzf1.in")"
    for n in RHEL-9.4-x86_64 ubuntu-22.04-server debian-12-genericcloud cirros-0.6.2 CentOS-Stream-9 app-golden 'Red Hat Enterprise Linux 8'; do
        expect_match "tampil: $n" "$lst" "$n"
    done
    for n in windows-2022 fedora-40 rhel-queued; do
        expect_no_match "tidak tampil: $n" "$lst" "$n"
    done
    expect_match "distro dari os_distro (app-golden => ubuntu)" "$lst" 'app-golden +ubuntu'
    expect_match "distro dari nama 'Red Hat' => rhel" "$lst" 'Red Hat Enterprise Linux 8 +rhel'
    expect_match "Glance API dipakai (token lewat stdin)" "$(calls)" 'curl http://glance.stub:9292/v2/images\?status=active.*token_in_stdin=yes'
    expect_match "user default rhel: cloud-user" "$(screen_text)" 'Username +cloud-user'

    begin "image_cli_fallback"
    scen api fail
    run_cv "" --project dev "${BASE[@]}" --image app-golden --no-key --dry-run
    rc="$(exit_code)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "fallback: image show per image" "$(calls)" 'image show 11111111-0000-4000-8000-000000000006 -f json'
    expect_match "os_distro dari properties (CLI)" "$(screen_text)" 'distro ubuntu'
    expect_match "user ubuntu" "$(screen_text)" 'Username +ubuntu'

    begin "image_none"
    jq '[ .[] | select(.name | test("windows|fedora")) ]' "$HERE/fixtures/images.json" > "$WORK/state/images.json"
    run_cv "" --project dev --no-key --dry-run
    rc="$(exit_code)"
    expect_eq "tidak ada image cocok => exit 0" "$rc" "0"
    expect_match "pesan jelas" "$(screen_text)" 'Tidak ada image active yang cocok'
}

test_flavor() {
    local rc
    begin "flavor_validation"
    run_cv "STUB_FZF_1=^f3" --project dev --name x --image "$IMG_RHEL8" --network private \
        --security-group default --no-key --boot image --dry-run
    rc="$(exit_code)"
    expect_eq "exit code 0" "$rc" "0"
    expect_no_match "m1.tiny disembunyikan (RAM < min_ram)" "$(cat "$WORK/state/fzf1.in")" 'm1.tiny'
    expect_no_match "m1.zero disembunyikan (disk 0 < min_disk, boot image)" "$(cat "$WORK/state/fzf1.in")" 'm1.zero'
    expect_match "info flavor disembunyikan" "$(screen_text)" '2 flavor disembunyikan'

    begin "flavor_reject"
    run_cv "" --project dev "${BASE[@]}" --image "$IMG_RHEL8" --flavor m1.tiny --no-key --dry-run
    rc="$(exit_code)"
    expect_eq "flavor tidak cocok => exit 1" "$rc" "1"
    expect_match "alasan min_ram" "$(screen_text)" 'RAM 512M < min_ram image 2048M'

    begin "flavor_zero_volume"
    run_cv "" --project dev "${BASE[@]}" --flavor m1.zero --no-key --dry-run
    rc="$(exit_code)"
    expect_eq "flavor disk 0 boleh untuk boot volume" "$rc" "0"
}

test_boot_path_a() {
    local rc sc
    begin "boot_path_a"
    run_cv "" --project dev "${BASE[@]}" --no-key --delete-volume-on-terminate
    rc="$(exit_code "$CONFIRM")"
    expect_eq "exit code 0" "$rc" "0"
    sc="$(calls | grep 'server create' | grep -v -- --help)"
    expect_match "jalur A: --block-device lengkap" "$sc" 'block-device uuid=11111111-0000-4000-8000-000000000001,source_type=image,destination_type=volume,boot_index=0,volume_size=12,delete_on_termination=true,volume_type=ssd'
    expect_no_match "jalur A tanpa --image/--volume" "$sc" '--image |--volume '
    expect_no_match "tidak memakai --boot-from-volume" "$sc" 'boot-from-volume'
    expect_match "volume diberi nama web-root" "$(calls)" 'volume set --name web-root'
    expect_eq "tidak ada volume create terpisah" "$(calls | grep -c 'volume create' || true)" "0"
    expect_match "log create-volume via block-device" "$(log_text)" 'action=create-volume result=SUCCESS name=web-root size=12 type=ssd via=block-device delete_on_terminate=1'
    expect_match "log create-server" "$(log_text)" 'action=create-server result=SUCCESS name=web'
    expect_no_match "adminPass dari server create tidak tampil/dicatat" "$(screen_text)$(log_text)" 'STUB-ADMIN-PASS'
}

test_boot_path_b() {
    local rc sid vid
    begin "boot_path_b_rhosp"
    scen osc 5.5.2
    run_cv "" --project dev "${BASE[@]}" --no-key --delete-volume-on-terminate
    rc="$(exit_code "$CONFIRM")"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "summary: jalur B" "$(screen_text)" 'jalur B'
    expect_match "volume create dulu" "$(calls)" 'volume create --image 11111111-0000-4000-8000-000000000001 --size 12 --bootable --type ssd -f json web-root'
    expect_match "server create --volume" "$(calls)" 'server create .*--volume [0-9a-f-]{36} -f json web'
    expect_match "delete on terminate lewat server volume update" "$(calls)" 'server volume update --delete-on-termination'
    expect_match "microversion >= 2.85 untuk update" "$(calls | grep 'server volume update --delete')" 'compute-api-version 2.85'
    expect_match "progres volume" "$(screen_text)" 'volume [0-9a-f]{8}: available'
    expect_match "alamat format lama (string) terbaca" "$(screen_text)" 'IP +private=10.0.0.5'

    begin "boot_path_b_dot_fail"
    scen osc 5.5.2
    scen voldot fail
    run_cv "" --project dev "${BASE[@]}" --no-key --delete-volume-on-terminate
    rc="$(exit_code "$CONFIRM")"
    expect_eq "exit code 0 (VM tetap dibuat)" "$rc" "0"
    expect_match "peringatan jelas" "$(screen_text)" 'TIDAK akan terhapus otomatis saat VM dihapus'
    expect_match "ringkasan akhir: volume tidak dihapus otomatis" "$(screen_text)" 'Root volume +[0-9a-f-]{36} \(TIDAK dihapus otomatis saat VM dihapus\)'
    expect_match "log menyebut volume tidak terhapus" "$(log_text)" 'VOLUME_DOT .*delete_on_termination=false result=FAILED msg="volume will NOT be deleted with the server'

    begin "boot_path_b_mv_low"
    scen osc 5.5.2
    scen mv 2.79
    run_cv "" --project dev "${BASE[@]}" --no-key --delete-volume-on-terminate --dry-run
    rc="$(exit_code)"
    expect_match "microversion diturunkan ke maks. cloud" "$(screen_text)" 'Max compute microversion cloud 2.79 < 2.85, memakai 2.79'
    expect_match "ringkasan: delete on terminate tidak bisa diatur" "$(screen_text)" 'volume TIDAK akan terhapus otomatis'

    begin "boot_path_b_create_fail_cleanup"
    scen osc 5.5.2
    scen server createfail
    run_cv "" --project dev "${BASE[@]}" --no-key
    rc="$(exit_code "$CONFIRM" 'Hapus resource yang dibuat script.*=>y')"
    expect_eq "gagal => exit 1" "$rc" "1"
    expect_match "pesan error create" "$(screen_text)" 'server create gagal: .*Quota exceeded'
    vid="$(calls | sed -nE 's/.*server create .*--volume ([0-9a-f-]{36}).*/\1/p' | head -n 1)"
    expect_match "volume yang dibuat ditawarkan dihapus" "$(screen_text)" "volume $vid"
    expect_match "volume dihapus" "$(calls)" "volume delete $vid"
    expect_true "volume benar-benar hilang" test ! -e "$WORK/state/volumes/$vid.json"
    expect_match "log cleanup" "$(log_text)" "RESULT resource=$vid action=cleanup kind=volume result=SUCCESS"
    sid=""
    : "$sid"

    begin "volume_size_min"
    run_cv "" --project dev "${BASE[@]}" --volume-size 5 --no-key --dry-run
    rc="$(exit_code)"
    expect_eq "--volume-size < min_disk => exit 1" "$rc" "1"
    expect_match "alasan" "$(screen_text)" '5G < min_disk image 10G'

    begin "volume_size_prompt"
    run_cv "" --project dev --name w --image "$IMG_RHEL" --flavor m1.small --network private --security-group default \
        --boot volume --no-key --dry-run --keep-volume
    drive 'Ukuran terlalu kecil' 'Ukuran root volume GB \[10\]: *$=>4' || return 0
    rc="$(exit_code 'Ukuran root volume GB \[10\]: *$=>')"
    expect_match "ukuran kecil ditolak interaktif" "$(screen_text)" 'Ukuran terlalu kecil: 4G < min_disk image 10G'
    expect_match "default ukuran 10" "$(screen_text)" 'Root volume      : 10 GB'
    expect_match "keep volume ditampilkan jelas" "$(screen_text)" 'TIDAK — volume TETAP ADA saat VM dihapus'
}

test_distros() {
    local rc
    for spec in "11111111-0000-4000-8000-000000000002:ubuntu" "11111111-0000-4000-8000-000000000003:debian" \
                "11111111-0000-4000-8000-000000000005:cloud-user"; do
        begin "username_${spec#*:}"
        run_cv "" --project dev "${BASE[@]}" --image "${spec%%:*}" --no-key
        rc="$(exit_code "$CONFIRM")"
        expect_eq "exit code 0" "$rc" "0"
        expect_match "cloud-init name: ${spec#*:}" "$(cat "$WORK"/state/userdata/web.yaml)" "  - name: ${spec#*:}"
        expect_match "user default image dipertahankan" "$(cat "$WORK"/state/userdata/web.yaml)" '  - default'
    done
    expect_match "catatan CentOS 7 (centos)" "$(screen_text)" "CentOS 7 lama memakai 'centos'"

    begin "username_override"
    run_cv "" --project dev "${BASE[@]}" --username ops --no-key
    rc="$(exit_code "$CONFIRM")"
    expect_match "--username dipakai" "$(cat "$WORK"/state/userdata/web.yaml)" '  - name: ops'

    begin "cirros"
    run_cv "" --project dev "${BASE[@]}" --image cirros-0.6.2 --flavor m1.tiny --volume-size 1 --no-key
    rc="$(exit_code "$CONFIRM")"
    expect_eq "exit code 0" "$rc" "0"
    expect_no_match "tanpa --user-data" "$(calls | grep 'server create' | grep -v -- --help)" 'user-data'
    expect_true "tidak ada user-data" test -z "$(ls "$WORK/state/userdata")"
    expect_match "kredensial bawaan CirrOS" "$(screen_text)" 'Password +gocubsgo \(bawaan image CirrOS'
    expect_match "ukuran cirros boleh < 10G" "$(screen_text)" 'VOLUME 1 GB'
}

test_password() {
    local rc pw hash ud f
    begin "password_hash"
    run_cv "" --project dev "${BASE[@]}" --public-key "$WORK/home/.ssh/id_ed25519.pub"
    rc="$(exit_code "$CONFIRM" 'Simpan kredensial.*=>n')"
    expect_eq "exit code 0" "$rc" "0"
    pw="$(shown_passwords | head -n 1)"
    ud="$WORK/state/userdata/web.yaml"
    hash="$(ud_hash "$ud")"
    expect_match "password 20 karakter tanpa karakter membingungkan" "$pw" '^[A-HJ-NP-Za-km-np-z2-9]{20}$'
    expect_match "user-data berisi hash SHA-512" "$hash" '^\$6\$[^$]+\$[./A-Za-z0-9]{86}$'
    expect_true "hash cocok dengan password yang ditampilkan" hash_matches "$pw" "$hash"
    expect_eq "file user-data permission 600" "$(cat "$WORK/state/userdata/web.perm")" "600"
    expect_no_match "password tidak ada di user-data" "$(cat "$ud")" "$pw"
    expect_no_match "password tidak ada di argumen CLI" "$(calls)" "$pw"
    expect_no_match "password tidak ada di log" "$(log_text)" "$pw"
    expect_no_match "hash tidak ada di log" "$(log_text)" '\$6\$'
    expect_no_match "user-data tidak ada di log" "$(log_text)" 'cloud-config|ssh_pwauth'
    expect_eq "password RC tidak ada di log" "$(grep -rl 'FakeRcPassword-55aa' "$WORK/log" || true)" ""
    expect_match "ssh_pwauth true" "$(cat "$ud")" 'ssh_pwauth: true'
    expect_match "chpasswd expire false" "$(cat "$ud")" 'expire: false'
    expect_match "key di ssh_authorized_keys" "$(cat "$ud")" "      - 'ssh-ed25519 AAAA.* ops@test'"
    expect_match "peringatan simpan password" "$(screen_text)" 'TIDAK bisa ditampilkan ulang'
    expect_eq "file kredensial tidak dibuat (default tidak)" "$(compgen -G "$WORK/creds/*" | wc -l)" "0"
    expect_true "direktori kerja (user-data) dihapus" test -z "$(compgen -G "${TMPDIR:-/tmp}/create-vm.*/user-data-0.yaml" | xargs -r grep -l "$hash" 2>/dev/null)"

    begin "password_creds_file"
    run_cv "" --project dev "${BASE[@]}" --no-key
    rc="$(exit_code "$CONFIRM" 'Simpan kredensial.*=>y')"
    pw="$(shown_passwords | head -n 1)"
    f="$(compgen -G "$WORK/creds/vm-credentials-*.txt" | head -n 1)"
    expect_eq "file kredensial 600" "$(stat -c %a "$f" 2>/dev/null)" "600"
    expect_match "file berisi password" "$(cat "$f" 2>/dev/null)" "password=$pw"
    expect_no_match "log hanya mencatat path file" "$(log_text)" "$pw"

    begin "no_password"
    run_cv "" --project dev "${BASE[@]}" --no-password --public-key "$WORK/home/.ssh/id_ed25519.pub"
    rc="$(exit_code "$CONFIRM")"
    ud="$WORK/state/userdata/web.yaml"
    expect_eq "tanpa passwd" "$(grep -c '^    passwd:' "$ud" || true)" "0"
    expect_match "lock_passwd true" "$(cat "$ud")" 'lock_passwd: true'
    expect_match "ssh_pwauth false" "$(cat "$ud")" 'ssh_pwauth: false'
    expect_eq "tidak ada password ditampilkan" "$(shown_passwords | wc -l)" "0"

    begin "no_access"
    run_cv "" --project dev "${BASE[@]}" --no-password --no-key --dry-run
    rc="$(exit_code)"
    expect_eq "tanpa key + tanpa password => exit 1" "$rc" "1"
    expect_match "pesan" "$(screen_text)" 'tidak bisa diakses'

    begin "count2"
    run_cv "" --project dev "${BASE[@]}" --count 2 --no-key
    rc="$(exit_code "$CONFIRM" 'Simpan kredensial.*=>n')"
    expect_eq "exit code 0" "$rc" "0"
    expect_eq "dua server create" "$(calls | grep 'server create' | grep -vc -- --help)" "2"
    expect_true "nama web-1 dan web-2" test -f "$WORK/state/userdata/web-1.yaml" -a -f "$WORK/state/userdata/web-2.yaml"
    local p1 p2
    p1="$(shown_passwords | sed -n 1p)" p2="$(shown_passwords | sed -n 2p)"
    expect_true "password berbeda" test -n "$p1" -a -n "$p2" -a "$p1" != "$p2"
    expect_true "hash web-1 cocok password 1" hash_matches "$p1" "$(ud_hash "$WORK/state/userdata/web-1.yaml")"
    expect_true "hash web-2 cocok password 2" hash_matches "$p2" "$(ud_hash "$WORK/state/userdata/web-2.yaml")"
    expect_match "volume per VM" "$(calls)" 'volume set --name web-2-root'
}

test_keypair() {
    local rc fp
    begin "keypair_reuse"
    fp="$(ssh-keygen -l -E md5 -f "$WORK/home/.ssh/id_ed25519.pub" | awk '{print $2}' | sed 's/^MD5://')"
    jq -n --arg fp "$fp" --arg k "$(cat "$WORK/home/.ssh/id_ed25519.pub")" '[{name:"existing-key", fingerprint:$fp, public_key:$k}]' > "$WORK/state/keypairs.json"
    run_cv "" --project dev "${BASE[@]}" --public-key "$WORK/home/.ssh/id_ed25519.pub"
    rc="$(exit_code "$CONFIRM" 'Simpan kredensial.*=>n')"
    expect_match "keypair dengan fingerprint sama dipakai" "$(screen_text)" 'existing-key \(sudah terdaftar, fingerprint sama'
    expect_eq "tidak ada keypair create" "$(calls | grep -c 'keypair create' || true)" "0"
    expect_match "server memakai keypair itu" "$(calls)" '--key-name existing-key'

    begin "keypair_new"
    run_cv "STUB_FZF_1=^file:.*id_rsa.pub" --project dev "${BASE[@]}"
    rc="$(exit_code 'Nama keypair baru.*=>my-rsa' "$CONFIRM" 'Simpan kredensial.*=>n')"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "picker berisi ~/.ssh/*.pub" "$(cat "$WORK/state/fzf1.in")" 'id_ed25519.pub'
    expect_match "picker berisi path manual dan tanpa key" "$(cat "$WORK/state/fzf1.in")" '\[path public key lain'
    expect_match "keypair baru dibuat" "$(calls)" "keypair create --public-key $WORK/home/.ssh/id_rsa.pub my-rsa"
    expect_match "log create-keypair" "$(log_text)" 'RESULT resource=my-rsa action=create-keypair result=SUCCESS fingerprint='

    begin "keypair_manual_invalid"
    run_cv "STUB_FZF_1=^manual" --project dev "${BASE[@]}" --dry-run
    rc="$(exit_code "Path public key: *\$=>$WORK/home/bad.pub" 'Nama keypair baru.*=>')"
    expect_match "file tidak valid ditolak" "$(screen_text)" 'Bukan public key SSH yang valid'
    keys -l "$WORK/home/.ssh/id_ed25519.pub"; keys Enter
    rc="$(exit_code 'Nama keypair baru.*=>')"
    expect_eq "lalu path valid diterima" "$rc" "0"
    expect_match "default nama keypair user-host-sha" "$(screen_text)" "$(id -un)-[^ ]+-[A-Za-z0-9]{8} \\(BARU"

    begin "keypair_option_invalid"
    run_cv "" --project dev "${BASE[@]}" --public-key "$WORK/home/bad.pub" --dry-run
    rc="$(exit_code)"
    expect_eq "--public-key tidak valid => exit 1" "$rc" "1"
}

test_host() {
    local rc
    begin "host_opt"
    run_cv "" --project dev "${BASE[@]}" --no-key --host compute-0
    rc="$(exit_code "$CONFIRM" 'Simpan kredensial.*=>n')"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "--host dipakai (microversion >= 2.74)" "$(calls | grep 'server create' | grep -v -- --help)" '--host compute-0.example.com --availability-zone nova'

    begin "host_az_fallback"
    scen mv 2.60
    run_cv "" --project dev "${BASE[@]}" --no-key --host compute-1.example.com
    rc="$(exit_code "$CONFIRM" 'Simpan kredensial.*=>n')"
    expect_match "fallback --availability-zone zone:host" "$(calls | grep 'server create' | grep -v -- --help)" '--availability-zone az2:compute-1.example.com'
    expect_no_match "tanpa --host" "$(calls | grep 'server create' | grep -v -- --help)" '--host '

    begin "host_picker"
    run_cv "STUB_FZF_1=^compute-0" --project dev "${BASE[@]}" --no-key --dry-run
    rc="$(exit_code 'Pilih compute host.*=>y')"
    expect_match "hanya enabled + up" "$(cut -f1 "$WORK/state/fzf1.in" | paste -sd, -)" '^compute-0.example.com,compute-1.example.com$'

    begin "host_forbidden"
    scen host forbidden
    run_cv "" --project dev "${BASE[@]}" --no-key --host compute-0
    rc="$(exit_code "$CONFIRM" 'Hapus resource.*=>n')"
    expect_eq "ditolak => exit 1" "$rc" "1"
    expect_match "pesan butuh admin" "$(screen_text)" 'Penempatan ke host tertentu butuh role admin'

    begin "host_nonadmin"
    scen admin 0
    run_cv "" --project dev "${BASE[@]}" --no-key --dry-run
    rc="$(exit_code 'Pilih compute host.*=>y')"
    expect_match "non-admin: daftar compute tidak bisa dibaca" "$(screen_text)" 'butuh role admin\). Host tidak dipilih'
}

test_quota_fip() {
    local rc
    begin "quota_short"
    jq '(.[] | select(.Name == "totalCoresUsed") | .Value) = 19' "$HERE/fixtures/limits.json" > "$WORK/state/scen/limits"
    run_cv "" --project dev "${BASE[@]}" --no-key --count 2
    rc="$(exit_code)"
    expect_eq "quota kurang => exit 1" "$rc" "1"
    expect_match "rincian vCPU" "$(screen_text)" 'vCPU +butuh +2, terpakai +19 / +20, sisa +1  ❌ TIDAK CUKUP'
    expect_eq "tidak ada resource dibuat" "$(calls | grep -cE 'server create [^-]|volume create|keypair create' || true)" "0"

    begin "fip"
    scen osc 5.5.2
    run_cv "" --project dev "${BASE[@]}" --no-key --floating-ip public
    rc="$(exit_code "$CONFIRM" 'Simpan kredensial.*=>n')"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "quota floating IP dicek (format lama)" "$(screen_text)" 'floating IP +butuh +1'
    expect_match "floating IP dibuat" "$(calls)" 'floating ip create -f json n1000000-0000-4000-8000-000000000003'
    expect_match "dipasang setelah ACTIVE" "$(calls)" 'server add floating ip [0-9a-f-]{36} 203.0.113.10'
    expect_match "ringkasan + contoh SSH" "$(screen_text)" 'ssh cloud-user@203.0.113.10'
    expect_match "log add-floating-ip" "$(log_text)" 'action=add-floating-ip result=SUCCESS ip=203.0.113.10'

    begin "fip_quota_short"
    scen fipquota 2
    scen fipused 2
    run_cv "" --project dev "${BASE[@]}" --no-key --floating-ip public
    rc="$(exit_code)"
    expect_eq "quota floating IP kurang => exit 1" "$rc" "1"
}

test_error_timeout() {
    local rc sid
    begin "server_error"
    scen server error
    run_cv "" --project dev "${BASE[@]}" --no-key --keep-volume
    rc="$(exit_code "$CONFIRM" 'Hapus resource yang dibuat script.*=>y')"
    expect_eq "ERROR => exit 1" "$rc" "1"
    expect_match "fault ditampilkan" "$(screen_text)" 'ERROR: No valid host was found'
    expect_match "tawaran cleanup termasuk volume (keep-volume)" "$(screen_text)" 'Hapus resource yang dibuat script untuk web: VM [0-9a-f-]{36} volume [0-9a-f-]{36}'
    sid="$(calls | sed -nE 's/.*server delete ([0-9a-f-]{36}).*/\1/p' | head -n 1)"
    expect_true "server dihapus" test -n "$sid" -a ! -e "$WORK/state/servers/$sid.json"
    expect_match "log create-server FAILED + fault" "$(log_text)" 'action=create-server result=FAILED name=web msg="fault: No valid host'
    expect_match "log cleanup" "$(log_text)" 'action=cleanup kind=server result=SUCCESS'

    begin "server_timeout"
    scen server timeout
    run_cv "OSOPS_TIMEOUT_SEC=3" --project dev "${BASE[@]}" --no-key
    rc="$(exit_code "$CONFIRM")"
    expect_eq "timeout => exit 1" "$rc" "1"
    expect_match "status terakhir + tidak dihapus" "$(screen_text)" 'timeout 3s \(status terakhir BUILD\); resource TIDAK dihapus'
    expect_eq "tidak ada delete" "$(calls | grep -cE 'server delete|volume delete' || true)" "0"
    expect_no_match "tidak ada tawaran cleanup" "$(screen_text)" 'Hapus resource yang dibuat'
}

test_dry_run() {
    local rc
    begin "dry_run"
    scen osc 5.5.2
    run_cv "" --project dev "${BASE[@]}" --public-key "$WORK/home/.ssh/id_rsa.pub" --floating-ip public --count 2 --dry-run
    rc="$(exit_code)"
    expect_eq "exit code 0" "$rc" "0"
    expect_eq "tidak ada perintah yang membuat resource" \
        "$(calls | grep -E 'keypair create|volume create|server create|floating ip create|server add|volume update|volume set' | grep -vc -- '--help' || true)" "0"
    expect_match "perintah volume ditampilkan" "$(screen_text)" 'openstack volume create --image .* web-1-root'
    expect_match "perintah keypair ditampilkan" "$(screen_text)" 'openstack keypair create --public-key'
    expect_match "cloud-init dengan hash disamarkan" "$(screen_text)" "passwd: '\\\$6\\\$\\*\\*\\*\\*\\*\\*\\*\\*'"
    expect_no_match "tidak ada hash asli di layar" "$(screen_text)" '\$6\$[^*]'
    expect_match "log dry_run=true" "$(log_text)" 'dry_run=true action=create-server resource=web-1'
}

ALL_TESTS=(scope images flavor boot_path_a boot_path_b distros password keypair host quota_fip error_timeout dry_run)
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
