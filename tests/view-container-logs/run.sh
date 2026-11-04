#!/bin/bash
# ============================================================
# Tes rhosp/view-container-logs.sh dengan stub ssh/sudo/ansible-inventory/
# fzf/less (tanpa undercloud/overcloud sungguhan).
#
#   bash tests/view-container-logs/run.sh            # semua tes
#   bash tests/view-container-logs/run.sh follow     # hanya tes yang namanya cocok
#   KEEP=1 bash tests/view-container-logs/run.sh     # simpan direktori kerja
#
# Stub ssh menjalankan perintah "remote" sungguhan (find/tail) terhadap pohon
# /var/log/containers palsu per host ($WORK/state/hosts/<ip>/containers),
# sebagai proses terpisah yang menerima EOF di stdin saat stub ssh mati.
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

TEST_NAME=view
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/rhosp/view-container-logs.sh"
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ============================================================
# Tes
# ============================================================

test_role_picker() {
    local rc
    begin "role_picker"
    run_tmux "STUB_FZF_1='^role:Controller' STUB_FZF_2='^nova/nova-api.log	' STUB_FZF_PREVIEW=1" --mode tail --lines 3
    wait_for '\[m\]ode' 1 30 || return 0
    expect_match "entry [semua Controller] di picker node" "$(cat "$WORK/state/fzf1.in")" $'role:Controller\t\\[semua Controller\\] \\(3 node\\)'
    expect_match "entry [semua ComputeInstanceHA] di picker node" "$(cat "$WORK/state/fzf1.in")" 'semua ComputeInstanceHA\] \(3 node\)'
    expect_no_match "tidak ada entry undercloud" "$(cat "$WORK/state/fzf1.in")" 'Undercloud'
    expect_match "3 controller terpilih" "$(screen_text)" 'Node terpilih     : 3 \(overcloud-controller-0,overcloud-controller-1,overcloud-controller-2\)'
    expect_match "file gabungan: nova-api di 3/3" "$(cat "$WORK/state/fzf2.in")" $'nova/nova-api.log\tnova/nova-api.log +3/3'
    expect_match "file sebagian node: cinder-volume 1/3" "$(cat "$WORK/state/fzf2.in")" $'cinder/cinder-volume.log\tcinder/cinder-volume.log +1/3'
    expect_no_match "file rotasi tidak muncul di picker" "$(cut -f1 "$WORK/state/fzf2.in")" '\.log\.1|\.gz|\.xz|\.bz2|\.zst|-2026'
    expect_no_match "nama tidak valid tidak muncul" "$(cat "$WORK/state/fzf2.in")" 'bad name'
    expect_match "peringatan nama tidak valid" "$(screen_text)" '1 file dengan nama tidak biasa dilewati'
    expect_eq "picker file urut path" "$(cut -f1 "$WORK/state/fzf2.in" | head -n 3 | paste -sd, -)" \
        "5f633eb0-0000-4000-8000-000000000002.log,cinder/cinder-api.log,cinder/cinder-scheduler.log"
    expect_match "preview: 30 baris terakhir dari node pertama" "$(cat "$WORK/state/preview2.out" 2>/dev/null)" \
        'overcloud-controller-0: nova/nova-api.log \(30 baris terakhir\)'
    expect_match "preview berisi baris log" "$(cat "$WORK/state/preview2.out" 2>/dev/null)" 'after-many'
    expect_no_match "preview tanpa error" "$(cat "$WORK/state/preview2.out" 2>/dev/null)" 'gagal membaca|Bad port'
    expect_match "pager: header per node dan file" "$(pager_text)" '══════ overcloud-controller-2 │ nova/nova-api.log ══════'
    expect_eq "pager: 3 baris per file" "$(pager_text | grep -A4 '══════ overcloud-controller-1 │ nova/nova-api.log' | tail -n +2 | grep -c .)" "3"
    keys q Enter
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_match "log SELECT" "$(log_text)" 'SELECT selected=3 nodes=overcloud-controller-0,overcloud-controller-1,overcloud-controller-2'
    expect_match "log FILES" "$(log_text)" 'FILES count=1 files=nova/nova-api.log'
    expect_match "log_result lookup per node" "$(log_text)" 'RESULT resource=overcloud-controller-1 action=lookup mode=tail result=SUCCESS files=1'
    expect_match "log SUMMARY" "$(log_text)" 'SUMMARY mode=tail nodes=3 nodes_ok=3'
    expect_no_match "isi log tidak masuk log toolkit" "$(log_text)" 'after-many|MANYMATCH|baris 20'
    expect_no_match "preview tidak menulis log" "$(log_text)" '_preview'
    check_no_secrets
    check_allowlist 'find|tail' ''
}

test_multi_node() {
    begin "multi_node"
    run_plain "" --node overcloud-controller-0 --node overcloud-computeiha-1.example.com \
        --log nova/nova-api.log --log nova/nova-compute.log --lines 2
    expect_eq "exit code 0" "$PLAIN_RC" "0"
    expect_match "2 node (termasuk canonical hostname)" "$PLAIN_OUT" 'Node terpilih     : 2 \(overcloud-controller-0,overcloud-computeiha-1\)'
    expect_match "file tidak ada di sebagian node diberitahukan" "$PLAIN_OUT" 'nova/nova-compute.log tidak ada di: overcloud-controller-0'
    expect_match "controller: nova-api" "$PLAIN_OUT" '══════ overcloud-controller-0 │ nova/nova-api.log ══════'
    expect_match "compute: nova-compute" "$PLAIN_OUT" '══════ overcloud-computeiha-1 │ nova/nova-compute.log ══════'
    expect_no_match "compute tidak diminta nova-api" "$(calls | grep "^ssh	$P1" | grep tail)" 'nova-api'
    expect_match "tanpa terminal: tanpa pager" "$PLAIN_OUT" 'baris 20'
    expect_eq "pager tidak dipanggil" "$(pager_text)" ""
    expect_no_match "tanpa warna" "$PLAIN_OUT" $'\e\\['
    check_no_secrets
}

test_unreachable() {
    begin "unreachable"
    host_env "$C1" UNREACHABLE=1
    host_env "$C2" AUTH_FAIL=1 BANNER=1
    run_plain "" --role Controller --log nova/nova-api.log --lines 1
    expect_eq "exit code 0" "$PLAIN_RC" "0"
    expect_match "controller-1 dilewati (unreachable)" "$PLAIN_OUT" 'overcloud-controller-1 +DILEWATI \(unreachable\)'
    expect_match "controller-2 dilewati (auth)" "$PLAIN_OUT" 'overcloud-controller-2 +DILEWATI \(ssh auth failed\)'
    expect_match "controller-0 tetap dibaca" "$PLAIN_OUT" '══════ overcloud-controller-0 │ nova/nova-api.log'
    expect_match "log DISCOVERY SKIPPED" "$(log_text)" 'DISCOVERY host=overcloud-controller-1 .*result=SKIPPED reason=unreachable'

    begin "unreachable_all"
    host_env "$C0" UNREACHABLE=1
    host_env "$C1" UNREACHABLE=1
    host_env "$C2" SUDO_FAIL=1
    run_plain "" --role Controller --log nova/nova-api.log
    expect_eq "exit code 1" "$PLAIN_RC" "1"
    expect_match "sudo gagal dikenali" "$PLAIN_OUT" 'overcloud-controller-2 +DILEWATI \(sudo failed\)'
    expect_match "semua gagal => keluar" "$PLAIN_OUT" 'Tidak ada node terpilih yang bisa dijangkau'
}

test_hostkey() {
    begin "hostkey_unknown_no_tty"
    grep -v "^$C1 " "$WORK/home/.ssh/known_hosts" > "$WORK/kh" && mv "$WORK/kh" "$WORK/home/.ssh/known_hosts"
    run_plain "" --role Controller --log nova/nova-api.log --lines 1
    expect_match "tanpa terminal: host key baru ditolak" "$PLAIN_OUT" 'overcloud-controller-1 +DILEWATI \(host key unknown\)'
    expect_no_match "tidak ada ssh ke host itu" "$(calls)" "ssh	$C1	"

    begin "hostkey_accept"
    grep -v "^$C1 " "$WORK/home/.ssh/known_hosts" > "$WORK/kh" && mv "$WORK/kh" "$WORK/home/.ssh/known_hosts"
    run_tmux "" --node overcloud-controller-1 --log nova/nova-api.log --mode tail
    answer 'Terima host key baru untuk 1 host ini' 1 y || return 0
    wait_for '\[m\]ode' 1 30 || return 0
    expect_match "accept-new dipakai" "$(calls)" "ssh	$C1	accept-new	"
    expect_match "fingerprint dicatat" "$(log_text)" 'HOSTKEY_ACCEPTED host=overcloud-controller-1'
    keys q Enter
    tmux_exit > /dev/null
}

test_tail_menu_save() {
    local f rc
    begin "tail_menu_save"
    run_tmux "STUB_FZF_1='^nova/nova-api.log	' STUB_FZF_2='^(nova/nova-api.log|keystone/keystone.log)	' STUB_FZF_3='^role:ComputeInstanceHA' STUB_FZF_5='^(nova/nova-api.log|keystone/keystone.log)	'" \
        --role Controller --mode tail --lines 4
    wait_for '\[m\]ode' 1 30 || return 0
    keys s Enter
    wait_for 'Hasil disimpan' 1 || return 0
    f="$(compgen -G "$WORK/save/container-logs-view-*.log" | head -n 1)"
    expect_true "file simpanan ada" test -n "$f"
    expect_eq "permission 600" "$(stat -c %a "$f" 2>/dev/null)" "600"
    expect_match "isi polos (tanpa warna)" "$(cat "$f")" '══════ overcloud-controller-0 │ nova/nova-api.log ══════'
    expect_no_match "tanpa kode warna" "$(cat "$f")" $'\e\\['
    keys s Enter
    wait_for 'Hasil disimpan' 2 || return 0
    expect_eq "simpan kedua tidak menimpa (akhiran -2 atau detik berbeda)" "$(compgen -G "$WORK/save/*" | wc -l)" "2"
    expect_match "log SAVE" "$(log_text)" 'SAVE file=.*container-logs-view-.*kind=view'

    # [f]ile: ganti file, node tetap
    keys f Enter
    wait_for 'Ringkasan tail:' 2 30 || return 0
    expect_match "ganti file: keystone ikut" "$(pager_text)" '══════ overcloud-controller-2 │ keystone/keystone.log'
    # [m]ode: ganti jumlah baris
    keys m Enter
    answer 'Mode: \[t\]ail' 1 t || return 0
    answer 'Jumlah baris' 1 1 || return 0
    wait_for 'Ringkasan tail:' 3 30 || return 0
    expect_match "ganti mode/baris: 1 baris" "$(pager_text | tail -n 30)" 'Tail 1 baris terakhir'
    # [n]ode: ganti ke compute; file lama tidak ada => pilih ulang; picker
    # file dibatalkan (fzf ke-4 tanpa pola = Esc) => node dan file lama kembali
    keys n Enter
    wait_for 'File sebelumnya tidak ada di node baru' 1 30 || return 0
    expect_match "discovery node baru" "$(screen_text)" 'overcloud-computeiha-2 +OK'
    wait_for 'Pilihan node dan file tidak diubah \(overcloud-controller-0,overcloud-controller-1,overcloud-controller-2\)' 1 30 || return 0
    keys f Enter
    wait_for 'Ringkasan tail:' 4 30 || return 0
    expect_match "setelah batal: tail tetap di controller + file lama" "$(pager_text | tail -n 40)" '══════ overcloud-controller-2 │ keystone/keystone.log'
    keys q Enter
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
}

test_follow() {
    local rc i n
    begin "follow"
    host_env "$C0" BANNER=1
    host_env "$C1" BANNER=1
    run_tmux "STUB_FZF_1='^(nova/nova-api.log|neutron/server.log)	'" --role Controller --mode follow
    wait_for 'Tekan Ctrl-C untuk berhenti' 1 30 || return 0
    wait_for '\[overcloud-controller-2 nova/nova-api.log\] .*shared request' 1 20 || return 0
    expect_match "10 baris awal per file" "$(screen_text)" '\[overcloud-controller-1 nova/nova-api.log\] .*baris 12'
    expect_no_match "tidak lebih dari 10 baris awal" "$(screen_text)" '\[overcloud-controller-1 nova/nova-api.log\] .*baris 11$'
    expect_match "prefix per node dan file" "$(screen_text)" '\[overcloud-controller-0 neutron/server.log\] .*neutron sees it'
    expect_no_match "banner sshd tidak masuk stream follow" "$(screen_text)" 'authorized users only'
    expect_eq "satu ssh per node (bukan per file)" "$(calls | grep '^ssh' | grep -c 'tail -F')" "3"
    expect_match "tail --pid + EOF stdin" "$(calls | grep 'tail -F' | head -n 1)" 'sudo -n tail -F -v -n 10 --pid=\$\$ -- /var/log/containers/neutron/server.log /var/log/containers/nova/nova-api.log & cat >/dev/null'
    echo "LIVE-LINE-FROM-C1" >> "$WORK/state/hosts/$C1/containers/neutron/server.log"
    wait_for '\[overcloud-controller-1 neutron/server.log\] LIVE-LINE-FROM-C1' 1 15 || return 0
    expect_true "remote tail berjalan" test -n "$(remote_procs | grep ' tail ')"
    keys C-c
    rc="$(tmux_exit 30)"
    expect_eq "Ctrl-C => exit 130" "$rc" "130"
    expect_match "pesan berhenti" "$(screen_text)" 'Follow dihentikan; semua koneksi SSH ditutup'
    n=0
    for (( i = 0; i < 25; i++ )); do
        n="$(remote_procs | grep -c ' tail ' || true)"
        (( n == 0 )) && break
        sleep 0.2
    done
    expect_eq "tidak ada tail tertinggal di node" "$n" "0"
    expect_eq "tidak ada ssh stub tertinggal" "$(stub_ssh_pids | wc -l)" "0"
    expect_match "log_result follow per node" "$(log_text)" 'RESULT resource=overcloud-controller-2 action=lookup mode=follow result=SUCCESS files=2 msg="stopped by operator \(INT\)"'
    expect_no_match "isi log tidak masuk log toolkit" "$(log_text)" 'LIVE-LINE'
    check_allowlist 'find|tail' ''
}

# Mekanisme di sisi "node": ssh dibunuh paksa (kill -9, mis. koneksi
# undercloud putus) => tail remote tetap berhenti lewat EOF stdin + --pid
test_follow_kill9() {
    local i n pids
    begin "follow_kill9"
    run_tmux "" --node overcloud-controller-0 --log nova/nova-api.log --mode follow
    wait_for '\[overcloud-controller-0 nova/nova-api.log\] after-many' 1 30 || return 0
    pids="$(stub_ssh_pids)"
    expect_true "ssh stub berjalan" test -n "$pids"
    # shellcheck disable=SC2086
    kill -9 $pids
    n=1
    for (( i = 0; i < 25; i++ )); do
        n="$(remote_procs | grep -c ' tail ' || true)"
        (( n == 0 )) && break
        sleep 0.2
    done
    expect_eq "tail remote berhenti setelah ssh di-kill -9" "$n" "0"
    wait_for 'Semua stream follow berakhir' 1 15 || return 0
    expect_eq "script keluar normal" "$(tmux_exit)" "0"
}

test_options() {
    begin "options"
    run_plain "" --role Controller --log nova/nova-api.log --mode follow --save
    expect_eq "follow + --save ditolak" "$PLAIN_RC" "1"
    expect_match "pesan follow tidak disimpan" "$PLAIN_OUT" '--save tidak berlaku untuk mode follow'
    for o in --keyword --pattern --ignore-case --include-rotated --regex --all-logs; do
        run_plain "" --role Controller --log nova/nova-api.log "$o" x
        expect_eq "$o ditolak" "$PLAIN_RC" "1"
        expect_match "$o: arahkan ke search" "$PLAIN_OUT" 'search-container-logs.sh'
    done
    run_plain "" --role Controller --log nova/nova-api.log --mode grep
    expect_match "--mode grep ditolak" "$PLAIN_OUT" '--mode harus tail atau follow'
    run_plain "" --role Controller --log nova/nova-api.log --lines 0
    expect_match "--lines 0 ditolak" "$PLAIN_OUT" '--lines harus bilangan bulat'
    # shellcheck disable=SC2016  # $(id) harus literal (tidak boleh dieksekusi)
    run_plain "" --role Controller --log ../../etc/shadow --log /etc/passwd --log 'nova/$(id).log'
    expect_eq "path tidak valid => exit 1" "$PLAIN_RC" "1"
    expect_match "../ ditolak" "$PLAIN_OUT" '--log tidak valid .*\.\./\.\./etc/shadow'
    expect_match "path absolut di luar root ditolak" "$PLAIN_OUT" '--log tidak valid .*/etc/passwd'
    expect_no_match "tidak ada tail dengan path tidak valid" "$(calls)" 'shadow|passwd|\$\(id\)'
    run_plain "" --role Controller --log nova/nova-api.log.1
    expect_match "file rotasi lewat --log ditolak" "$PLAIN_OUT" 'tidak ditemukan di node mana pun \(atau file rotasi\): nova/nova-api.log.1'
    run_plain "" --log nova/nova-api.log
    expect_match "tanpa terminal: --node/--role wajib" "$PLAIN_OUT" 'Tanpa terminal: --node/--role wajib'
    run_plain "" --role Controller --log nova/nova-api.log --log /var/log/containers/keystone/keystone.log --lines 1 --save
    expect_eq "--save (tail) exit 0" "$PLAIN_RC" "0"
    expect_eq "--save: permission 600" "$(stat -c %a "$WORK"/save/container-logs-view-*.log 2>/dev/null | head -n 1)" "600"
    expect_match "path absolut di bawah root diterima" "$PLAIN_OUT" '│ keystone/keystone.log'
    run_plain "" --role Foo --log nova/nova-api.log
    expect_match "role tidak dikenal" "$PLAIN_OUT" 'Role tidak dikenal di inventory, dilewati: Foo'
}

test_no_fzf_menu() {
    local rc
    begin "no_fzf_menu"
    run_tmux "OSOPS_FZF=/nonexistent/fzf" --mode tail --lines 2
    answer 'Nomor \(mis. 1 4 5' 1 2 || return 0
    answer 'Nomor \(mis. 1 3 5-7\) / kata kunci filter' 1 'nova api' || return 0
    wait_for 'filter: "nova api"' 1 || return 0
    expect_match "filter menyaring ke nova-api" "$(screen_text | grep -v '^$' | tail -n 4)" '3\) nova/nova-api.log'
    expect_no_match "filter: keystone tidak tampil" "$(screen_text | grep -v '^$' | tail -n 4)" 'keystone'
    answer 'Nomor \(mis. 1 3 5-7\) / kata kunci filter' 2 3 || return 0
    wait_for '\[m\]ode' 1 30 || return 0
    expect_match "tail jalan dari menu" "$(pager_text)" '══════ overcloud-controller-0 │ nova/nova-api.log'
    keys q Enter
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
}

test_platform() {
    begin "platform"
    rm -f "$WORK/rhosp-release"
    run_plain "" --role Controller --log nova/nova-api.log
    expect_eq "tanpa rhosp-release => exit 1" "$PLAIN_RC" "1"
    expect_match "pesan hanya untuk undercloud" "$PLAIN_OUT" 'hanya untuk undercloud RHOSP'
    echo "Red Hat OpenStack Platform release 16.2.6 (Train)" > "$WORK/rhosp-release"
    run_plain "" --role Controller --log nova/nova-api.log --lines 1
    expect_eq "versi lain: peringatan saja (exit 0)" "$PLAIN_RC" "0"
    expect_match "peringatan versi" "$PLAIN_OUT" 'dirancang untuk RHOSP 17.1'
}

# Struktur grup inventory seperti /home/stack/inventory.yaml RHOSP 17.1.13
# (child berprefiks nama stack)
test_inventory_nested() {
    begin "inventory_nested"
    cp "$FIX/inventory-nested.yaml" "$FIX/inventory-nested.yaml.json" "$WORK/stack/"
    run_plain "" --inventory "$WORK/stack/inventory-nested.yaml" --role Controller --role ComputeInstanceHA \
        --log nova/nova-api.log --lines 1
    expect_eq "exit code 0" "$PLAIN_RC" "0"
    expect_match "node + grup pacemaker dari child bersarang" "$PLAIN_OUT" 'Node overcloud   : 6 \(pacemaker: 3, pacemaker_remote: 3\)'
    expect_match "role dari tripleo_role_name" "$PLAIN_OUT" 'Node terpilih     : 6 '
    expect_no_match "undercloud tidak jadi node overcloud" "$PLAIN_OUT" 'Node terpilih     : 7'
    check_no_secrets
}

ALL_TESTS=(inventory_nested role_picker multi_node unreachable hostkey tail_menu_save follow follow_kill9 options no_fzf_menu platform)
for t in "${ALL_TESTS[@]}"; do
    want "$t" && "test_$t"
done
finish
