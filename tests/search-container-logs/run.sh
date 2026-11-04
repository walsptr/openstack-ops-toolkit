#!/bin/bash
# ============================================================
# Tes rhosp/search-container-logs.sh dengan stub yang sama seperti
# tests/view-container-logs (stub ssh/sudo/ansible-inventory/fzf/less).
#
#   bash tests/search-container-logs/run.sh            # semua tes
#   bash tests/search-container-logs/run.sh inject     # hanya tes yang namanya cocok
#   KEEP=1 bash tests/search-container-logs/run.sh     # simpan direktori kerja
#
# Stub ssh menjalankan perintah "remote" sungguhan (find, nice, ionice,
# timeout, xargs, grep, zgrep) terhadap pohon /var/log/containers palsu.
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

TEST_NAME=search
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/rhosp/search-container-logs.sh"
# shellcheck source=../view-container-logs/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../view-container-logs/common.sh"

NOVA="$C0"

test_keyword_required() {
    local rc
    begin "keyword_required"
    run_plain "" --role Controller --log nova/nova-api.log --keyword ""
    expect_eq "kata kunci kosong => exit 1" "$PLAIN_RC" "1"
    expect_match "pesan kosong" "$PLAIN_OUT" 'Kata kunci tidak boleh kosong'
    run_plain "" --role Controller --log nova/nova-api.log --keyword $'req\nrm'
    expect_eq "kata kunci dengan newline => exit 1" "$PLAIN_RC" "1"
    expect_match "pesan newline" "$PLAIN_OUT" 'tidak boleh berisi newline'
    expect_eq "tidak ada ssh sebelum validasi" "$(calls | grep -c '^ssh' || true)" "0"
    run_plain "" --role Controller --log nova/nova-api.log
    expect_match "tanpa terminal: --keyword wajib" "$PLAIN_OUT" 'Tanpa terminal: --keyword wajib'
    run_plain "" --role Controller --keyword x
    expect_match "tanpa terminal: --log/--all-logs wajib" "$PLAIN_OUT" 'Tanpa terminal: --log atau --all-logs wajib'
    run_plain "" --role Controller --log nova/nova-api.log --keyword 'a(' --regex
    expect_match "regex tidak valid ditolak" "$PLAIN_OUT" 'Regex \(ERE\) tidak valid'

    begin "keyword_prompt"
    run_tmux "" --node overcloud-controller-0 --log nova/nova-api.log
    answer 'Kata kunci: ' 1 '' || return 0
    wait_for 'Kata kunci tidak boleh kosong' 1 || return 0
    answer 'Kata kunci: ' 2 'req-1.2' || return 0
    answer 'ignore-case\)\? \[y/N\]' 1 '' || return 0
    answer 'Ikut cari di 3 file rotasi' 1 '' || return 0
    wait_for 'Ringkasan pencarian:' 1 30 || return 0
    expect_match "kata kunci dari prompt dipakai" "$(pager_text)" 'Pencarian: "req-1.2" \(teks biasa\)'
    expect_match "log KEYWORD" "$(log_text)" 'KEYWORD keyword=req-1.2 regex=0 ignore_case=0'
    keys q Enter
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
}

test_fixed_vs_regex() {
    begin "fixed_vs_regex"
    run_plain "" --node overcloud-controller-0 --log nova/nova-api.log --keyword 'req-1.2'
    expect_match "fixed: cocok literal" "$PLAIN_OUT" '\[overcloud-controller-0 nova/nova-api.log:[0-9]+\] token req-1.2 literal'
    expect_no_match "fixed: req-1x2 tidak cocok" "$PLAIN_OUT" 'req-1x2 other'
    expect_match "perintah memakai -F" "$(calls | grep '^ssh' | tail -n 1)" 'grep -H -n -F '
    run_plain "" --node overcloud-controller-0 --log nova/nova-api.log --keyword 'req-1.2' --regex
    expect_match "regex: req-1x2 ikut cocok" "$PLAIN_OUT" '\] token req-1x2 other'
    expect_match "perintah memakai -E" "$(calls | grep '^ssh' | tail -n 1)" 'grep -H -n -E '
}

test_ignore_case_context_max() {
    begin "ignore_case_context_max"
    run_plain "" --node overcloud-controller-0 --log nova/nova-api.log --keyword 'caseword error'
    expect_match "case-sensitive: 1 kecocokan" "$PLAIN_OUT" 'overcloud-controller-0 +1 kecocokan'
    run_plain "" --node overcloud-controller-0 --log nova/nova-api.log --keyword 'caseword error' --ignore-case
    expect_match "ignore-case: 2 kecocokan" "$PLAIN_OUT" 'overcloud-controller-0 +2 kecocokan'
    expect_match "ignore-case: huruf besar cocok" "$PLAIN_OUT" '\] CaseWord ERROR upper'

    run_plain "" --node overcloud-controller-0 --log nova/nova-api.log --keyword 'req-1.2' --context 1
    expect_match "konteks sebelum (file-N)" "$PLAIN_OUT" '\[overcloud-controller-0 nova/nova-api.log-21\] .*shared request'
    expect_match "baris cocok (file:N)" "$PLAIN_OUT" '\[overcloud-controller-0 nova/nova-api.log:22\] token req-1.2 literal'
    expect_match "konteks sesudah" "$PLAIN_OUT" '\[overcloud-controller-0 nova/nova-api.log-23\] token req-1x2 other'
    run_plain "" --node overcloud-controller-0 --log nova/nova-api.log --keyword 'baris 1' --context 1 --max-per-file 3
    expect_match "pemisah antar blok konteks" "$PLAIN_OUT" $'baris 2\n  --\n\\[overcloud-controller-0 nova/nova-api.log-9\\]'

    run_plain "" --node overcloud-controller-0 --log nova/nova-api.log --keyword MANYMATCH --max-per-file 2
    expect_match "max-per-file: 2 kecocokan" "$PLAIN_OUT" 'nova/nova-api.log +2  TERPOTONG'
    expect_match "perintah memakai --max-count" "$(calls | grep '^ssh' | tail -n 1)" '--max-count=2'
    expect_match "log truncated=1" "$(log_text)" 'RESULT resource=overcloud-controller-0 action=lookup mode=search result=SUCCESS status=SELESAI files=1 matches=2 truncated=1'
    run_plain "" --node overcloud-controller-0 --log nova/nova-api.log --keyword MANYMATCH
    expect_no_match "tanpa batas tercapai: tidak TERPOTONG" "$PLAIN_OUT" 'TERPOTONG'
}

test_all_logs() {
    local rc
    begin "all_logs"
    run_plain "" --role Controller --all-logs --keyword "$REQ_SHARED"
    expect_eq "exit code 0" "$PLAIN_RC" "0"
    expect_match "peringatan semua file + total ukuran" "$PLAIN_OUT" 'Cakupan: SEMUA file log aktif'
    expect_match "total ukuran per node" "$PLAIN_OUT" 'overcloud-controller-0 +[0-9]+ file +[0-9.]+K'
    expect_match "total keseluruhan" "$PLAIN_OUT" 'Total: [0-9.]+K'
    expect_match "neutron ikut dicari" "$PLAIN_OUT" '\[overcloud-controller-0 neutron/server.log:21\]'
    expect_no_match "tanpa --include-rotated: rotasi tidak dicari" "$PLAIN_OUT" 'ROTATED'
    expect_match "log SCOPE all" "$(log_text)" 'SCOPE scope=all files=("")? include_rotated=0'

    begin "all_logs_picker"
    run_tmux "STUB_FZF_1='^__ALL__'" --role Controller --keyword "$REQ_SHARED"
    answer 'ignore-case\)\? \[y/N\]' 1 n || return 0
    wait_for 'Lanjut mencari di semua file log\? \[y/N\]' 1 || return 0
    expect_match "entry [semua file log] di atas picker" "$(head -n 1 "$WORK/state/fzf1.in")" $'^__ALL__\t\\[semua file log\\] \\([0-9]+ file aktif, total [0-9.]+K di 3 node\\)'
    expect_match "total ukuran sebelum konfirmasi" "$(screen_text)" 'Total: [0-9.]+K'
    keys y Enter
    answer 'Ikut cari di [0-9]+ file rotasi' 1 '' || return 0
    wait_for 'Ringkasan pencarian:' 1 30 || return 0
    expect_match "cakupan semua file" "$(pager_text)" 'Cakupan  : semua file log aktif'
    keys q Enter
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"

    begin "all_logs_picker_cancel"
    run_tmux "STUB_FZF_1='^__ALL__'" --role Controller --keyword x --ignore-case
    answer 'Lanjut mencari di semua file log\? \[y/N\]' 1 n || return 0
    rc="$(tmux_exit)"
    expect_eq "ditolak => exit 0" "$rc" "0"
    expect_no_match "tidak ada pencarian" "$(calls)" 'grep -H'
}

test_rotated() {
    local rc
    begin "rotated"
    run_plain "" --role Controller --log nova/nova-api.log --keyword "$REQ_SHARED" --include-rotated
    expect_match "rotasi tanpa kompresi ikut" "$PLAIN_OUT" '\[overcloud-controller-1 nova/nova-api.log.1:21\] ROTATED-PLAIN'
    expect_match "rotasi .gz ikut (zgrep)" "$PLAIN_OUT" '\[overcloud-controller-2 nova/nova-api.log.2.gz:21\] ROTATED-GZ'
    expect_no_match ".xz/.bz2/.zst tidak dibaca" "$PLAIN_OUT" 'SHOULD-NOT-BE-READ'
    expect_match "catatan file kompresi lain dilewati" "$PLAIN_OUT" 'File terkompresi dilewati \(bukan .gz'
    expect_match "daftar file yang dilewati" "$PLAIN_OUT" 'overcloud-controller-0: 3 file \(.*nova-api.log-20261101.xz'
    expect_no_match "rotasi file lain tidak ikut" "$PLAIN_OUT" 'neutron/server.log.1'
    expect_match "zgrep hanya untuk .gz" "$(calls | grep "^sudo	$C0	zgrep")" 'nova/nova-api.log.2.gz$'
    expect_no_match "xz tidak diberikan ke grep" "$(calls | grep '^sudo' | grep -E 'grep')" '\.xz|\.bz2|\.zst'

    # File aktif 0 byte setelah rotasi (seperti di environment nyata): isi ada di .1
    printf 'SCHED-ONLY-IN-ROTATED\n' >> "$WORK/state/hosts/$C0/containers/nova/nova-scheduler.log.1"
    run_plain "" --node overcloud-controller-0 --log nova/nova-scheduler.log --keyword SCHED-ONLY-IN-ROTATED
    expect_match "file aktif 0 byte: tidak ada kecocokan tanpa rotasi" "$PLAIN_OUT" 'TIDAK ADA KECOCOKAN'
    run_plain "" --node overcloud-controller-0 --log nova/nova-scheduler.log --keyword SCHED-ONLY-IN-ROTATED --include-rotated
    expect_match "file aktif 0 byte: ketemu di .1" "$PLAIN_OUT" 'nova/nova-scheduler.log.1:[0-9]+\] SCHED-ONLY-IN-ROTATED'
    run_plain "" --node overcloud-controller-0 --log httpd/keystone/error_log --keyword "$REQ_SHARED" --include-rotated
    expect_match "error_log tanpa .log: rotasi .2.gz dikenali" "$PLAIN_OUT" 'httpd/keystone/error_log.2.gz:[0-9]+\] ROTATED-GZ'

    begin "rotated_prompt"
    run_tmux "STUB_FZF_1='^nova/nova-api.log	'" --role Controller --keyword "$REQ_SHARED" --ignore-case
    wait_for 'Ikut cari di 9 file rotasi \(total [0-9.]+K\); 9 file .xz/.bz2/.zst dilewati\? \[y/N\]' 1 30 || return 0
    keys Enter
    wait_for 'Ringkasan pencarian:' 1 30 || return 0
    expect_no_match "default tidak: rotasi tidak dicari" "$(pager_text)" 'ROTATED'
    keys q Enter
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
}

test_long_file_list() {
    local d i long
    begin "long_file_list"
    d="$WORK/state/hosts/$NOVA/containers/many/$(printf 'x%.0s' {1..120})"
    mkdir -p "$d"
    long="$(printf 'f%.0s' {1..120})"
    for (( i = 0; i < 9000; i++ )); do
        : > "$d/$long-$i.log"
    done
    echo "NEEDLE-IN-MANY" > "$d/$long-8999.log"
    run_plain "" --node overcloud-controller-0 --all-logs --keyword NEEDLE-IN-MANY --timeout 120
    expect_eq "exit code 0" "$PLAIN_RC" "0"
    expect_match "file terakhir dari 9000+ ikut dicari" "$PLAIN_OUT" "$long-8999.log:1\\] NEEDLE-IN-MANY"
    expect_no_match "tidak ada 'Argument list too long'" "$PLAIN_OUT" 'Argument list too long'
    expect_true "daftar file > ARG_MAX dibagi xargs (>1 panggilan grep)" \
        test "$(calls | grep -c "^sudo	$NOVA	grep")" -gt 1
    expect_true "string perintah ssh tetap pendek (< 2000 karakter)" \
        test "$(calls | grep '^ssh' | tail -n 1 | wc -c)" -lt 2000
}

test_timeout_fail_nomatch() {
    begin "timeout_fail"
    host_env "$C1" SLOW_GREP=30
    host_env "$C2" SUDO_FAIL_GREP=1 BANNER=1
    run_plain "OSOPS_CL_PROGRESS_INTERVAL=1" --role Controller --log nova/nova-api.log --keyword "$REQ_SHARED" --timeout 2
    expect_eq "exit code 0" "$PLAIN_RC" "0"
    expect_match "progres: mencari" "$PLAIN_OUT" '🔎 overcloud-controller-1: mencari \(1 file'
    expect_match "progres: selesai" "$PLAIN_OUT" '✅ overcloud-controller-0: selesai \(1 kecocokan'
    expect_match "progres: timeout" "$PLAIN_OUT" 'overcloud-controller-1: timeout setelah 2s'
    expect_match "progres: gagal" "$PLAIN_OUT" '❌ overcloud-controller-2: gagal \(sudo failed'
    expect_match "ringkasan: TIMEOUT" "$PLAIN_OUT" 'overcloud-controller-1 +TIMEOUT +timeout setelah 2s'
    expect_match "ringkasan: GAGAL + alasan" "$PLAIN_OUT" 'overcloud-controller-2 +GAGAL +sudo failed'
    expect_no_match "banner sshd tidak masuk pesan gagal" "$PLAIN_OUT" 'GAGAL .*\*\*\*|gagal \(.*\*\*\*'
    expect_match "perintah memakai timeout remote" "$(calls | grep '^ssh' | tail -n 1)" 'timeout -k 10 2 sh -c'
    expect_match "log status timeout" "$(log_text)" 'RESULT resource=overcloud-controller-1 action=lookup mode=search result=FAILED status=TIMEOUT'
    expect_match "log status gagal" "$(log_text)" 'RESULT resource=overcloud-controller-2 action=lookup mode=search result=FAILED status=GAGAL'
    sleep 1
    expect_eq "tidak ada grep tertinggal setelah timeout" "$(remote_procs | grep -cE ' (grep|sleep) ' || true)" "0"

    begin "all_failed"
    host_env "$C0" SUDO_FAIL_GREP=1 BANNER=1
    host_env "$C1" SUDO_FAIL_GREP=1
    host_env "$C2" SUDO_FAIL_GREP=1
    run_plain "" --role Controller --log nova/nova-api.log --keyword "$REQ_SHARED"
    expect_match "semua gagal: bukan 'tidak ada kecocokan'" "$PLAIN_OUT" 'PENCARIAN TIDAK SELESAI di node mana pun'
    expect_no_match "tidak menyatakan TIDAK ADA KECOCOKAN" "$PLAIN_OUT" 'TIDAK ADA KECOCOKAN'

    begin "no_match"
    run_plain "" --role Controller --log nova/nova-api.log --keyword 'no-such-request-id'
    expect_match "tidak ada kecocokan dinyatakan jelas" "$PLAIN_OUT" 'TIDAK ADA KECOCOKAN untuk "no-such-request-id" di 1 file \(nova/nova-api.log\) pada 3 node'
    expect_match "status tetap SUCCESS" "$(log_text)" 'RESULT resource=overcloud-controller-0 .*result=SUCCESS status=SELESAI files=1 matches=0'
}

test_injection() {
    local kw i m
    local -a kws=()
    begin "injection"
    kws=(
        "it's \"quoted\" a b"
        "\$(touch $WORK/PWN1)"
        "; touch $WORK/PWN2;"
        "\`touch $WORK/PWN3\`"
        "-e x --version"
        "\$HOME \${PATH} | cat > $WORK/PWN4 &"
    )
    for i in "${!kws[@]}"; do
        printf 'INJ-%d %s END\n' "$i" "${kws[$i]}" >> "$WORK/state/hosts/$NOVA/containers/nova/nova-api.log"
    done
    for i in "${!kws[@]}"; do
        kw="${kws[$i]}"
        run_plain "" --node overcloud-controller-0 --log nova/nova-api.log --keyword "$kw"
        m="$(grep -c "\\] INJ-$i " "$WORK/out/plain.txt" || true)"
        expect_eq "pola $i cocok literal: $kw" "$m" "1"
    done
    expect_eq "tidak ada file penanda (tanpa injeksi)" "$(compgen -G "$WORK/PWN*" | wc -l)" "0"
    expect_no_match "kata kunci tidak masuk string perintah ssh" "$(calls | grep '^ssh')" 'PWN|quoted'
    expect_no_match "tanpa akses root log tanpa sudo (cd)" "$(calls | grep '^ssh')" 'cd /var/log/containers'
    # shellcheck disable=SC2016  # literal $1 di string perintah remote
    expect_match "-e sebelum pola" "$(calls | grep '^ssh' | tail -n 1)" ' -e "\$1" --'
    run_plain "" --node overcloud-controller-0 --log nova/nova-api.log --keyword '.*' --regex --max-per-file 1
    expect_match "regex .* aman (cocok baris pertama)" "$PLAIN_OUT" 'nova/nova-api.log:1\]'
}

test_nice_allowlist() {
    begin "nice_allowlist"
    run_plain "" --role Controller --role ComputeInstanceHA --all-logs --include-rotated --keyword "$REQ_SHARED"
    expect_match "nice -n 19 + ionice -c3 + timeout" "$(calls | grep '^ssh' | tail -n 1)" 'exec nice -n 19 ionice -c3 timeout -k 10 300 sh -c'
    expect_eq "satu ssh pencarian per node" "$(calls | grep '^ssh' | grep -c 'ionice')" "6"
    check_allowlist 'find|grep|zgrep' 'nice|ionice|timeout|sh|xargs|read|then|exit|if|st|exec|pl|gz'
    check_no_secrets
    expect_no_match "isi log tidak masuk log toolkit" "$(log_text)" 'ROTATED-|shared request on|neutron sees'
    expect_match "log DISCOVERY per node" "$(log_text)" 'DISCOVERY host=overcloud-computeiha-2 ip=192.168.24.26 result=OK active=6 rotated=1'
    expect_match "log SUMMARY" "$(log_text)" 'SUMMARY mode=search nodes=6 nodes_ok=6 matches=[0-9]+ scope=all'
}

test_menu_save() {
    local rc f
    begin "menu_save"
    run_tmux "STUB_FZF_SELECT='^nova/nova-api.log	'" --role Controller --keyword 'req-1.2' --ignore-case
    answer 'Ikut cari di' 1 n || return 0
    wait_for 'Ringkasan pencarian:' 1 30 || return 0
    keys s Enter
    wait_for 'Hasil disimpan' 1 || return 0
    f="$(compgen -G "$WORK/save/container-logs-search-*.log" | head -n 1)"
    expect_eq "permission 600" "$(stat -c %a "$f" 2>/dev/null)" "600"
    expect_no_match "file simpanan polos" "$(cat "$f")" $'\e\\['
    expect_match "pager: kata kunci disorot" "$(pager_text)" $'token \e\\[1;31mreq-1.2\e\\[0m literal'
    keys k Enter
    answer 'Kata kunci: ' 1 'MANYMATCH' || return 0
    wait_for 'Ringkasan pencarian:' 2 30 || return 0
    expect_match "[k]: node tetap" "$(pager_text | grep -A3 'Pencarian: "MANYMATCH"')" 'Node     : overcloud-controller-0,overcloud-controller-1,overcloud-controller-2'
    expect_match "[k]: cakupan tetap" "$(pager_text | grep -A2 'Pencarian: "MANYMATCH"')" 'Cakupan  : 1 file \(nova/nova-api.log\)'
    keys c Enter
    wait_for 'Ikut cari di' 2 30 || return 0
    keys n Enter
    wait_for 'Ringkasan pencarian:' 3 30 || return 0
    # [n]ode dibatalkan (picker tanpa pilihan) => node dan cakupan lama tetap
    keys n Enter
    wait_for 'Pilihan node dan cakupan tidak diubah \(overcloud-controller-0,overcloud-controller-1,overcloud-controller-2\)' 1 30 || return 0
    keys k Enter
    answer 'Kata kunci: ' 2 'after-many' || return 0
    wait_for 'Ringkasan pencarian:' 4 30 || return 0
    expect_match "setelah batal [n]: cakupan lama dipakai" "$(pager_text | grep -A2 'Pencarian: "after-many"')" 'Cakupan  : 1 file \(nova/nova-api.log\)'
    keys q Enter
    rc="$(tmux_exit)"
    expect_eq "exit code 0" "$rc" "0"
    expect_eq "fzf: file, [c]akupan, [n]ode" "$(cat "$WORK/state/fzf.count")" "3"
}

ALL_TESTS=(keyword_required fixed_vs_regex ignore_case_context_max all_logs rotated long_file_list
    timeout_fail_nomatch injection nice_allowlist menu_save)
for t in "${ALL_TESTS[@]}"; do
    want "$t" && "test_$t"
done
finish
