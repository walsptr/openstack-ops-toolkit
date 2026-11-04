#!/bin/bash
# shellcheck disable=SC2034  # PLAIN_*, PASS, dll. dibaca oleh run.sh
# ============================================================
# Helper bersama tests/view-container-logs dan tests/search-container-logs
# (di-source oleh run.sh; bukan script toolkit, tidak punya @name).
#
# Pemanggil mengisi sebelum source: SCRIPT (script yang diuji), TEST_NAME.
# Butuh: bash, jq, tmux, setsid, ssh-keygen, gzip.
# ============================================================

CV_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CV_HERE/../.." && pwd)"
STUB="$CV_HERE/stub"
FIX="$CV_HERE/fixtures"
INV_FIX="$ROOT/tests/collect-sosreport/fixtures"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${TEST_NAME:-cl}-test.XXXXXX")"
TM=(tmux -L "cl-test-$$")
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()

C0=192.168.24.21 C1=192.168.24.22 C2=192.168.24.23
P0=192.168.24.24 P1=192.168.24.25 P2=192.168.24.26
ALL_IPS=("$C0" "$C1" "$C2" "$P0" "$P1" "$P2")
declare -A HOSTNAME_OF=(
    [$C0]=overcloud-controller-0 [$C1]=overcloud-controller-1 [$C2]=overcloud-controller-2
    [$P0]=overcloud-computeiha-0 [$P1]=overcloud-computeiha-1 [$P2]=overcloud-computeiha-2
)
REQ_SHARED="req-aaaaaaaa-1111-2222-3333-444444444444"

# Nilai palsu field sensitif di fixture inventory (tidak boleh bocor)
SECRET_TOKEN="FAKE-os-auth-token-9d1e7c"
SECRET_PW="FakeOvercloudAdminPw-4c7b2a"

for tool in jq tmux setsid ssh-keygen gzip pgrep; do
    command -v "$tool" >/dev/null 2>&1 || { echo "❌ $tool dibutuhkan untuk tes"; exit 1; }
done

cleanup() {
    "${TM[@]}" kill-server 2>/dev/null || true
    # Proses "remote" yang tersisa (seharusnya tidak ada) dihentikan agar
    # tidak mengganggu tes berikutnya
    pkill -f "$WORK/state/hosts" 2>/dev/null || true
    if [[ -n "${KEEP:-}" ]]; then
        echo "Direktori kerja disimpan: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$WORK/hostkey" >/dev/null
HOSTKEY_PUB="$(awk '{print $1 " " $2}' "$WORK/hostkey.pub")"

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
    if [[ ! "$2" =~ $3 ]]; then ok "$1"; else bad "$1" "pola tidak boleh muncul: '$3'"; fi
}

expect_true() {
    local desc="$1"
    shift
    if "$@"; then ok "$desc"; else bad "$desc"; fi
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

# Baris log contoh: unik per host/file/nomor baris
_gen_lines() {
    local host="$1" path="$2" n
    for (( n = 1; n <= 20; n++ )); do
        printf '2026-11-05 10:00:%02d.000 100 INFO %s [req-%s-%04d - - -] %s %s baris %d\n' \
            "$n" "${path%%/*}" "${host##*-}" "$n" "$host" "$path" "$n"
    done
}

# Pohon /var/log/containers palsu per host dari fixtures/tree-*.txt
build_tree() {
    local ip="$1" host="${HOSTNAME_OF[$1]}" list line path only d empty
    if [[ "$host" == *controller* ]]; then list="$FIX/tree-controller.txt"; else list="$FIX/tree-compute.txt"; fi
    d="$WORK/state/hosts/$ip/containers"
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        path="${line%% *}"
        empty=0
        [[ "$line" == *" !empty"* ]] && empty=1
        line="${line% !empty}"
        only=""
        [[ "$line" == *" @"* ]] && only="${line##* @}"
        [[ -n "$only" && "$only" != "$host" ]] && continue
        path="${path#+}"
        mkdir -p "$d/$(dirname "$path")"
        if (( empty )); then
            : > "$d/$path"
            continue
        fi
        case "$path" in
            *.gz)
                { _gen_lines "$host" "$path"; echo "ROTATED-GZ $REQ_SHARED $host"; } | gzip -c > "$d/$path" ;;
            *.xz|*.bz2|*.zst)
                echo "SHOULD-NOT-BE-READ $REQ_SHARED" > "$d/$path" ;;
            *.1|*.log-*)
                { _gen_lines "$host" "$path"; echo "ROTATED-PLAIN $REQ_SHARED $host"; } > "$d/$path" ;;
            *)
                _gen_lines "$host" "$path" > "$d/$path" ;;
        esac
    done < "$list"
    if [[ "$host" == *controller* ]]; then
        printf '2026-11-05 10:01:00.000 100 ERROR nova.api [%s - - -] shared request on %s\n' \
            "$REQ_SHARED" "$host" >> "$d/nova/nova-api.log"
        echo "BAD NAME" > "$d/nova/bad name.log"
    fi
    if [[ "$host" == overcloud-controller-0 ]]; then
        {
            echo "token req-1.2 literal"
            echo "token req-1x2 other"
            echo "CaseWord ERROR upper"
            echo "caseword error lower"
            for n in 1 2 3 4 5; do echo "MANYMATCH $n"; done
            echo "after-many"
        } >> "$d/nova/nova-api.log"
        printf '2026-11-05 10:02:00.000 100 INFO neutron.api [%s] neutron sees it\n' "$REQ_SHARED" \
            >> "$d/neutron/server.log"
    fi
}

# Lingkungan bersih: 6 host (host key dikenal), inventory, rhosp-release
reset_state() {
    local ip
    "${TM[@]}" kill-server 2>/dev/null || true
    pkill -f "$WORK/state/hosts" 2>/dev/null || true
    rm -rf "${WORK:?}/state" "${WORK:?}/log" "${WORK:?}/home" "${WORK:?}/stack" "${WORK:?}/save" "${WORK:?}/out"
    mkdir -p "$WORK/state/hosts" "$WORK/log" "$WORK/home/.ssh" "$WORK/stack" "$WORK/save" "$WORK/out"
    : > "$WORK/state/calls.log"
    : > "$WORK/home/.ssh/known_hosts"
    : > "$WORK/home/.ssh/id_rsa"
    for ip in "${ALL_IPS[@]}"; do
        mkdir -p "$WORK/state/hosts/$ip"
        : > "$WORK/state/hosts/$ip/env"
        printf '%s %s\n' "$ip" "$HOSTKEY_PUB" >> "$WORK/home/.ssh/known_hosts"
        build_tree "$ip"
    done
    cp "$INV_FIX/inventory.yaml" "$INV_FIX/inventory.yaml.json" "$WORK/stack/"
    echo "Red Hat OpenStack Platform release 17.1.4 (Wallaby)" > "$WORK/rhosp-release"
}

host_env() {
    local ip="$1"
    shift
    printf '%s\n' "$@" >> "$WORK/state/hosts/$ip/env"
}

_envs() {
    printf 'HOME=%q STUB_STATE=%q STUB_HOSTKEY_PUB=%q OSOPS_SSH=%q OSOPS_ANSIBLE_INVENTORY=%q OSOPS_FZF=%q OSOPS_RHOSP_RELEASE_FILE=%q OSOPS_STACK_HOME=%q OSOPS_LOG_DIR=%q OSOPS_CL_SAVE_DIR=%q PAGER=%q' \
        "$WORK/home" "$WORK/state" "$HOSTKEY_PUB" "$STUB/ssh" "$INV_FIX/../stub/ansible-inventory" \
        "$STUB/fzf" "$WORK/rhosp-release" "$WORK/stack" "$WORK/log" "$WORK/save" "$STUB/less"
}

# run_plain "ENV..." ARGS... — tanpa terminal (setsid: tidak ada /dev/tty).
# Output di $WORK/out/plain.txt, exit code di PLAIN_RC
run_plain() {
    local envs="$1"
    shift
    PLAIN_RC=0
    # shellcheck disable=SC2046
    eval "env $(_envs) $envs setsid bash $(printf '%q' "$SCRIPT") $(printf '%q ' "$@")" \
        < /dev/null > "$WORK/out/plain.txt" 2>&1 || PLAIN_RC=$?
    PLAIN_OUT="$(cat "$WORK/out/plain.txt")"
}

# run_tmux "ENV..." ARGS... — di tmux (ada terminal)
run_tmux() {
    local envs="$1" cmd=""
    shift
    (( $# > 0 )) && printf -v cmd '%q ' "$@"
    "${TM[@]}" kill-server 2>/dev/null || true
    "${TM[@]}" new-session -d -s t -x 220 -y 60 \
        "env $(_envs) $envs bash $(printf '%q' "$SCRIPT") $cmd; echo __EXIT=\$?; sleep 3600"
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
    screen_text | tail -n 20 | sed 's/^/     | /'
    return 1
}

keys() {
    "${TM[@]}" send-keys -t t "$@"
}

answer() {
    wait_for "$1" "$2" && keys -l "$3" && keys Enter
}

tmux_exit() {
    wait_for '__EXIT=' 1 "${1:-60}" || { echo "?"; return 0; }
    screen_text | grep -o '__EXIT=[0-9]*' | tail -n 1 | cut -d= -f2
}

log_text() {
    cat "$WORK"/log/rhosp/*.log 2>/dev/null
}

calls() {
    cat "$WORK/state/calls.log"
}

pager_text() {
    cat "$WORK/state/pager.out" 2>/dev/null
}

# Proses "remote" (tail/grep) yang masih hidup untuk host palsu
remote_procs() {
    pgrep -af "$WORK/state/hosts" 2>/dev/null | grep -E ' (tail|grep|zgrep|cat|sleep)( |$)' || true
}

# Proses stub ssh yang masih hidup (bukan shell tmux yang memuat path stub di env)
stub_ssh_pids() {
    pgrep -f "^/bin/bash $STUB/ssh |^bash $STUB/ssh " 2>/dev/null || true
}

# Secret inventory tidak boleh muncul di log, output, layar, atau file hasil
check_no_secrets() {
    local where
    where="$(grep -rlE "$SECRET_TOKEN|$SECRET_PW" "$WORK/log" "$WORK/out" "$WORK/save" "$WORK/state/pager.out" 2>/dev/null || true)"
    expect_eq "secret inventory tidak muncul di log/output" "$where" ""
    expect_no_match "secret inventory tidak muncul di layar" "$(screen_text 2>/dev/null)" "$SECRET_TOKEN|$SECRET_PW"
}

# Allowlist perintah remote: sudo hanya untuk perintah baca ($1 = ERE perintah
# sudo yang diizinkan), string ssh tanpa perintah/redirect yang mengubah apa pun,
# dan tanpa kata di luar daftar $2 (ERE token tambahan yang diizinkan)
check_allowlist() {
    local sudo_ok="$1" extra="$2" bad_sudo bad_ssh
    bad_sudo="$(awk -F '\t' '$1 == "sudo" { split($3, a, " "); print a[1] }' "$WORK/state/calls.log" \
        | sort -u | grep -vE "^($sudo_ok)$" || true)"
    expect_eq "sudo hanya untuk perintah baca ($sudo_ok)" "$bad_sudo" ""
    bad_ssh="$(awk -F '\t' '$1 == "ssh" { print $4 }' "$WORK/state/calls.log" \
        | grep -E '(^|[^A-Za-z_-])(rm|mv|cp|kill|pkill|chmod|chown|touch|tee|dd|truncate|systemctl|podman|docker|pcs|reboot|shutdown|sed|perl|python3?)([^A-Za-z_-]|$)|>[^&/]|>/[^d]|>> ' || true)"
    expect_eq "string perintah ssh tanpa perintah/redirect yang mengubah" "$bad_ssh" ""
    bad_ssh="$(awk -F '\t' '$1 == "ssh" { print $4 }' "$WORK/state/calls.log" \
        | grep -oE '(^|[;&|] *|then |exec )[a-z][a-z0-9_-]*' | sed -E 's/^([;&|] *|then |exec )//' | sort -u \
        | grep -vE "^(printf|sudo|cat|if|IFS|exit|cd|fi|r|st|${extra})$" || true)"
    expect_eq "perintah di string ssh hanya dari allowlist" "$bad_ssh" ""
}

finish() {
    echo
    echo "========================================"
    echo "Lulus: $PASS   Gagal: $FAIL"
    if (( FAIL > 0 )); then
        printf '  - %s\n' "${FAILED_TESTS[@]}"
        exit 1
    fi
}
