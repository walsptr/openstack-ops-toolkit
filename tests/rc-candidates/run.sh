#!/bin/bash
# ============================================================
# Tes pencarian kandidat RC file di main.sh (main.sh --rc-candidates) dan
# konteks RC berbasis clouds.yaml (OS_CLOUD, seperti stackrc RHOSP 17.1).
#
#   bash tests/rc-candidates/run.sh
#   KEEP=1 bash tests/rc-candidates/run.sh     # simpan direktori kerja
#
# Butuh: bash, tmux. Stub openstack di tests/rc-candidates/stub.
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rc-test.XXXXXX")"
TM=(tmux -L "rc-test-$$")
PASS=0
FAIL=0
FAILED=()

command -v tmux >/dev/null 2>&1 || { echo "❌ tmux dibutuhkan untuk tes"; exit 1; }

cleanup() {
    "${TM[@]}" kill-server 2>/dev/null || true
    if [[ -n "${KEEP:-}" ]]; then echo "Direktori kerja disimpan: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

ok() { PASS=$(( PASS + 1 )); echo "  ✅ $1"; }
bad() { FAIL=$(( FAIL + 1 )); FAILED+=("$1"); echo "  ❌ $1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; return 0; }
expect_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "dapat: '$2'  harap: '$3'"; fi; }
expect_match() { if [[ "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "dapat: '${2:0:400}'  pola: '$3'"; fi; }
expect_no_match() { if [[ ! "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "pola tidak boleh muncul: '$3'"; fi; }

H="$WORK/home"
W="$WORK/wd"
mkdir -p "$H/overcloud-deploy/overcloud" "$H/a/b/c" "$H/.config/openstack" "$H/proj/.git" "$W/rhosp" "$W/tests"

# Seperti undercloud RHOSP 17.1
printf '# Clear any old environment\nexport OS_CLOUD=undercloud\n' > "$H/stackrc"
printf 'export OS_AUTH_TYPE=password\nexport OS_AUTH_URL=https://overcloud.example.com:13000\nexport OS_USERNAME=admin\nexport OS_PASSWORD=FakeRcPw-1\nexport OS_PROJECT_NAME=admin\nexport OS_CLOUD=overcloud\n' > "$H/overcloudrc"
cp "$H/overcloudrc" "$H/overcloud-deploy/overcloud/overcloudrc"
printf '    export   OS_AUTH_URL=https://x.example.com:5000/v3\n' > "$H/a/adminrc"
# Pola lama: tetap tampil tanpa cek isi
echo '# kosong' > "$H/admin-openrc.sh"
echo '# kosong' > "$H/a/proj-rc"
echo '# kosong' > "$H/a/b/env-rc.sh"
# Bukan RC OpenStack
echo 'alias ll="ls -l"' > "$H/.bashrc"
echo 'set number' > "$H/vimrc"
echo '# export OS_CLOUD=commented' > "$H/commentedrc"
echo 'OS_CLOUD=noexport' > "$H/noexportrc"
printf 'export OS_CLOUD=hidden\n' > "$H/.config/openstack/hiddenrc"
printf 'export OS_CLOUD=git\n' > "$H/proj/.git/gitrc"
printf 'export OS_CLOUD=deep\n' > "$H/a/b/c/toodeeprc"
{ printf 'export OS_CLOUD=big\n'; head -c 70000 /dev/zero | tr '\0' 'x'; } > "$H/bigrc"
# Di workdir
printf 'export OS_AUTH_URL=https://w.example.com:5000\n' > "$W/regionrc"

echo
echo "▶ rc_candidates"
out="$(HOME="$H" OOT_WORKDIR="$W" bash "$ROOT/main.sh" --rc-candidates)"
rel="${out//$WORK\//}"
for f in home/stackrc home/overcloudrc home/overcloud-deploy/overcloud/overcloudrc home/a/adminrc wd/regionrc \
         home/admin-openrc.sh home/a/proj-rc home/a/b/env-rc.sh; do
    expect_match "terdeteksi: $f" "$rel" "(^|$(printf '\n'))$f($(printf '\n')|$)"
done
for f in .bashrc vimrc commentedrc noexportrc hiddenrc gitrc toodeeprc bigrc; do
    expect_no_match "tidak terdeteksi: $f" "$rel" "/$f$|^$f$|/$f($(printf '\n'))"
done
expect_eq "yang dangkal lebih dulu" "$(head -n 4 <<< "$rel" | paste -sd, -)" \
    "home/admin-openrc.sh,home/overcloudrc,home/stackrc,wd/regionrc"
expect_eq "tanpa duplikat" "$(sort <<< "$rel" | uniq -d)" ""

echo
echo "▶ konteks clouds.yaml (stackrc: hanya OS_CLOUD)"
mkdir -p "$WORK/log"
"${TM[@]}" new-session -d -s t -x 200 -y 50 \
    "env HOME=$(printf '%q' "$H") OSOPS_LOG_DIR=$(printf '%q' "$WORK/log") PATH=$(printf '%q' "$HERE/stub:$PATH") bash $(printf '%q' "$ROOT/main.sh") --workdir $(printf '%q' "$ROOT") --rc $(printf '%q' "$H/stackrc") --no-fzf; echo __EXIT=\$?; sleep 3600"
for (( i = 0; i < 100; i++ )); do
    "${TM[@]}" capture-pane -p -t t | grep -q 'Context:' && break
    sleep 0.2
done
screen="$("${TM[@]}" capture-pane -p -J -t t -S -200)"
expect_match "kredensial OS_CLOUD diterima" "$screen" 'Context: stackrc'
expect_match "nama cloud ditampilkan" "$screen" '☁️  undercloud'
"${TM[@]}" send-keys -t t q Enter
sleep 1
expect_match "toolkit.log mencatat os_cloud" "$(cat "$WORK/log/toolkit.log" 2>/dev/null)" 'os_cloud=undercloud'
expect_no_match "password RC tidak ada di log" "$(cat "$WORK"/log/*.log 2>/dev/null)" 'FakeRcPw-1'

echo
echo "========================================"
echo "Lulus: $PASS   Gagal: $FAIL"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
