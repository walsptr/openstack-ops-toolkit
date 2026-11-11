#!/bin/bash
# shellcheck disable=SC2034  # variabel N_*/C_*/SEL dibaca oleh script pemanggil
# ============================================================
# OpenStack Ops Toolkit - shared helper for RHOSP (TripleO) scripts
# ============================================================
#
# Di-source oleh script RHOSP SETELAH lib/logging.sh (tidak punya @name,
# lib/ tidak ikut discovery). Dijalankan di undercloud sebagai user stack;
# node overcloud diakses lewat SSH dengan data dari inventory TripleO.
#
# Helper umum: die, warn, info, ask, has_tty, is_yes, trim, is_uint,
#   short_name, kill_tree, warna C_* (kosong jika stdout bukan terminal).
#
# Environment:
#   rhosp_check_env confirm|warn
#                       /etc/rhosp-release wajib (UC_RELEASE), versi bukan
#                       17.1 dan user bukan stack: "confirm" = tanya y/N
#                       (script yang mengubah sesuatu), "warn" = peringatan
#                       saja. Cek jq dan ansible-inventory.
#
# Inventory dan node:
#   rhosp_find_inventory  --inventory ($INVENTORY), $STACK_HOME/inventory.yaml,
#                         lalu $STACK_HOME/overcloud-deploy/*/tripleo-ansible-inventory.yaml
#   rhosp_load_nodes      ansible-inventory --list (JSON di RHOSP_WORK_DIR) =>
#                         array paralel N_NAME N_ROLE N_IP N_USER N_KEY N_PORT
#                         N_CANON N_PCMK N_PCMKR N_LOCAL N_SEL N_HK N_ALT N_ADDR
#                         + IDX_BY_NAME. N_IP = ansible_host (identitas node dan
#                         host key), N_ALT = alamat fallback dari segmen ctlplane
#                         (ctlplane_ip, ctlplane_hostname), N_ADDR = alamat yang
#                         benar-benar dipakai (kosong = belum ditentukan).
#                         Hanya field yang dibutuhkan yang keluar dari hostvars
#                         (hostvars berisi secret: tidak pernah dicetak/di-log utuh).
#                         RHOSP_WITH_UNDERCLOUD=1: undercloud ditambahkan sebagai
#                         node lokal (N_LOCAL=1, UC_IDX). Hook opsional
#                         rhosp_on_node_added IDX untuk array milik script.
#   rhosp_select_nodes    --node/--role (NODE_ARGS/ROLE_ARGS) atau picker
#                         (fzf multi-select dengan entry "[semua <Role>]", atau
#                         menu bernomor). Hasil di SEL. Tidak ada => exit 0.
#   rhosp_pick_nodes      hanya picker; return 1 jika batal/kosong
#   rhosp_reset_selection kosongkan SEL/N_SEL
#
# SSH (satu-satunya jalur ke node; BatchMode, ConnectTimeout,
# ServerAliveInterval, tanpa -t, timeout lokal):
#   check_host_keys LABEL IDX...   host belum dikenal: satu konfirmasi untuk
#                                  StrictHostKeyChecking=accept-new; tanpa
#                                  terminal => reject. Key BERUBAH tetap ditolak.
#   Fallback alamat: jika koneksi ke ansible_host gagal (connect timeout/
#   refused/no route/DNS; BUKAN auth atau host key), ssh_node dan scp_fetch
#   mencoba alamat ctlplane (N_ALT) dengan HostKeyAlias = ansible_host, jadi
#   host key tetap diverifikasi terhadap key node yang sama. Alamat yang
#   berhasil dipakai untuk semua koneksi berikutnya (juga dari subshell/worker,
#   lewat $RHOSP_WORK_DIR/addr/IDX). Perintah remote belum berjalan saat
#   koneksi gagal, jadi mengulang aman. ssh_node_stdin tidak mencoba ulang
#   (stdin sudah dipakai): ia memakai alamat yang sudah ditentukan oleh
#   koneksi sebelumnya (pre-check/discovery).
#   rhosp_report_fallbacks IDX...  tampilkan node yang memakai alamat ctlplane
#   ssh_node IDX TIMEOUT CMD       stdin dari /dev/null
#   ssh_node_stdin IDX TIMEOUT CMD stdin dari pemanggil (pola search, atau FIFO
#                                  yang ditahan terbuka untuk stream follow);
#                                  TIMEOUT 0 = tanpa timeout lokal; LogLevel=ERROR
#                                  (tanpa banner sshd di output)
#   scp_fetch IDX SRC DST TIMEOUT
#   ssh_fail_reason STDERR RC      alasan SKIPPED (host key mismatch, auth, ...)
#   RHOSP_SSH_EXTRA=(...)          opsi ssh tambahan (array, bisa di-local-kan)
#   log_accepted_key IDX           catat fingerprint host key yang baru diterima
#
# Variabel yang diisi script sebelum memanggil fungsi: INVENTORY, NODE_ARGS,
# ROLE_ARGS, INCLUDE_UC (hanya dengan RHOSP_WITH_UNDERCLOUD=1), RHOSP_WORK_DIR
# (direktori sementara milik script, umask 077, dihapus di LOG_EXIT_HOOK).
#
# Override (terutama untuk tes): OSOPS_SSH, OSOPS_SCP, OSOPS_ANSIBLE_INVENTORY,
# OSOPS_FZF, OSOPS_RHOSP_RELEASE_FILE, OSOPS_STACK_HOME.

[[ -n "${_OSOPS_RHOSP_LOADED:-}" ]] && return 0
_OSOPS_RHOSP_LOADED=1

RHOSP_RELEASE_FILE="${OSOPS_RHOSP_RELEASE_FILE:-/etc/rhosp-release}"
STACK_HOME="${OSOPS_STACK_HOME:-/home/stack}"
RHOSP_WITH_UNDERCLOUD="${RHOSP_WITH_UNDERCLOUD:-0}"
RHOSP_WORK_DIR="${RHOSP_WORK_DIR:-}"

read -ra SSH_CMD <<< "${OSOPS_SSH:-ssh}"
read -ra SCP_CMD <<< "${OSOPS_SCP:-scp}"
read -ra ANSIBLE_INV_CMD <<< "${OSOPS_ANSIBLE_INVENTORY:-ansible-inventory}"
read -ra FZF_CMD <<< "${OSOPS_FZF:-fzf}"

US=$'\x1f'

if [[ -t 1 ]]; then
    C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m' C_RESET=$'\e[0m'
else
    C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_RESET=""
fi

INVENTORY="${INVENTORY:-}"
NODE_ARGS=()
ROLE_ARGS=()
INCLUDE_UC=0

N_NAME=() N_ROLE=() N_IP=() N_USER=() N_KEY=() N_PORT=() N_CANON=()
N_PCMK=() N_PCMKR=() N_LOCAL=() N_SEL=() N_HK=() N_ALT=() N_ADDR=()
declare -A IDX_BY_NAME=()
declare -A _RHOSP_FB_SHOWN=()
_RHOSP_ADDR=
UC_IDX=-1
UC_NAME=""
UC_RELEASE=""
INV_SOURCE=""
INV_JSON=""
SEL=()
P_KEY=() P_LABEL=()

# ============================================================
# Helpers umum
# ============================================================

die() {
    echo "${C_RED}❌ $1${C_RESET}"
    log_error -q "$1"
    exit "${2:-1}"
}

warn() {
    echo "${C_YELLOW}⚠️  $1${C_RESET}"
    log_warn -q "$1"
}

info() {
    echo "${C_CYAN}ℹ️  $1${C_RESET}"
}

has_tty() {
    ( : < /dev/tty ) 2>/dev/null
}

# ask VAR PROMPT — prompt dari /dev/tty (nama lokal unik untuk printf -v)
ask() {
    local __ask_reply=""
    printf '%s' "$2" > /dev/tty
    IFS= read -r __ask_reply < /dev/tty || __ask_reply=""
    printf -v "$1" '%s' "$__ask_reply"
}

is_yes() {
    [[ "${1,,}" == "y" || "${1,,}" == "yes" ]]
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

short_name() {
    local s="${1,,}"
    printf '%s' "${s%%.*}"
}

# kill_tree PID — hentikan proses dan seluruh turunannya (worker background
# bash mengabaikan SIGINT)
kill_tree() {
    local pid="$1" child
    if command -v pgrep >/dev/null 2>&1; then
        for child in $(pgrep -P "$pid" 2>/dev/null); do
            kill_tree "$child"
        done
    fi
    kill -TERM "$pid" 2>/dev/null || true
}

# ============================================================
# Environment
# ============================================================

# rhosp_check_env confirm|warn
rhosp_check_env() {
    local mode="${1:-confirm}" answer user

    if [[ ! -f "$RHOSP_RELEASE_FILE" ]]; then
        die "Script ini hanya untuk undercloud RHOSP: $RHOSP_RELEASE_FILE tidak ditemukan."
    fi

    UC_RELEASE="$(head -n 1 "$RHOSP_RELEASE_FILE" 2>/dev/null)" || UC_RELEASE=""
    UC_RELEASE="$(trim "$UC_RELEASE")"
    echo "🏷️  RHOSP undercloud : ${UC_RELEASE:-(kosong)}"
    log_event ENV "rhosp_release=$UC_RELEASE" "release_file=$RHOSP_RELEASE_FILE"

    if [[ ! "$UC_RELEASE" =~ release[[:space:]]+17\.1([^0-9]|$) ]]; then
        if [[ "$mode" == "warn" ]]; then
            warn "Script ini dirancang untuk RHOSP 17.1. Pada versi lain struktur inventory dan log container bisa berbeda."
        else
            warn "Script ini dirancang untuk RHOSP 17.1. Pada versi lain struktur inventory dan perilaku pcs bisa berbeda."
            ask answer "Tetap lanjut di versi ini? [y/N]: "
            if ! is_yes "$answer"; then
                log_event DECISION release_mismatch=cancel
                echo "❌ Dibatalkan."
                exit 0
            fi
            log_event DECISION release_mismatch=continue
        fi
    fi

    user="$(id -un)"
    if [[ "$user" != "stack" ]]; then
        warn "Script dijalankan sebagai '$user', bukan 'stack'. Key SSH (~/.ssh/id_rsa) dan known_hosts yang dipakai milik user ini."
        if [[ "$mode" != "warn" ]]; then
            ask answer "Tetap lanjut sebagai $user? [y/N]: "
            if ! is_yes "$answer"; then
                log_event DECISION user_mismatch=cancel "user=$user"
                echo "❌ Dibatalkan."
                exit 0
            fi
            log_event DECISION user_mismatch=continue "user=$user"
        fi
    fi

    command -v jq >/dev/null 2>&1 || die "jq tidak ditemukan. Install jq (dnf install jq)."
    command -v "${ANSIBLE_INV_CMD[0]}" >/dev/null 2>&1 || \
        die "ansible-inventory tidak ditemukan (${ANSIBLE_INV_CMD[0]}). Jalankan di undercloud."
    return 0
}

# ============================================================
# Inventory
# ============================================================

rhosp_find_inventory() {
    local default="$STACK_HOME/inventory.yaml"
    local pattern="$STACK_HOME/overcloud-deploy/*/tripleo-ansible-inventory.yaml"
    local -a stacks=()
    local i choice

    if [[ -n "$INVENTORY" ]]; then
        [[ -f "$INVENTORY" && -r "$INVENTORY" ]] || die "Inventory tidak ditemukan atau tidak bisa dibaca: $INVENTORY"
        INV_SOURCE="option"
    elif [[ -f "$default" && -r "$default" ]]; then
        INVENTORY="$default"
        INV_SOURCE="default"
    else
        mapfile -t stacks < <(compgen -G "$pattern" | LC_ALL=C sort)

        if (( ${#stacks[@]} == 0 )); then
            echo "${C_RED}❌ Inventory tidak ditemukan. Path yang sudah dicek:${C_RESET}"
            echo "   - $default"
            echo "   - $pattern"
            echo "   Gunakan --inventory <path>."
            log_error -q "inventory tidak ditemukan: $default, $pattern"
            exit 1
        fi

        if (( ${#stacks[@]} == 1 )); then
            INVENTORY="${stacks[0]}"
        else
            has_tty || die "Ditemukan beberapa stack di $STACK_HOME/overcloud-deploy dan tidak ada terminal untuk memilih. Gunakan --inventory <path>."
            echo "📚 Ditemukan beberapa stack di $STACK_HOME/overcloud-deploy:"
            for i in "${!stacks[@]}"; do
                printf '  %d) %s\n' $(( i + 1 )) "$(basename "$(dirname "${stacks[$i]}")")"
            done
            while true; do
                ask choice "Pilih stack [1-${#stacks[@]}]: "
                if is_uint "$choice" && (( choice >= 1 && choice <= ${#stacks[@]} )); then
                    break
                fi
                echo "${C_RED}❌ Pilihan tidak valid.${C_RESET}"
            done
            INVENTORY="${stacks[$(( choice - 1 ))]}"
        fi
        INV_SOURCE="stack"
    fi

    echo "📒 Inventory        : $INVENTORY"
    log_event INPUT "inventory=$INVENTORY" "source=$INV_SOURCE"
}

# Program jq: hanya field yang dibutuhkan yang keluar dari hostvars
# (aturan data sensitif: hostvars tidak pernah dicetak/di-log utuh).
# Baris "U<US>nama" untuk undercloud, "N<US>..." untuk node overcloud.
# Group vars grup Undercloud tidak berlaku untuk node overcloud (hanya
# hostvars per host yang dibaca).
# shellcheck disable=SC2016  # variabel jq, bukan shell
JQ_NODES='
def members($g): ((.[$g].hosts // []) + ([(.[$g].children // [])[] as $c | members($c)] | add // []));
def uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
def clean: if . == null then "" else tostring | gsub("[\u001f\t\r\n]"; " ") end;
. as $root
| ((members("Undercloud") + members("undercloud")) | uniq) as $uc
| ((if has("allovercloud") then members("allovercloud")
    else ((._meta.hostvars // {} | keys) + members("all")) end)
   | uniq | map(. as $h | select($uc | any(.[]; . == $h) | not))) as $oc
| (if has("allovercloud") then (.allovercloud.children // [])
   elif has("overcloud") then (.overcloud.children // [])
   else [] end) as $rg
| [ $rg[] as $c | {g: $c, m: members($c)} ] as $rgm
| members("pacemaker") as $pm
| members("pacemaker_remote") as $pmr
| ( $uc[] | "U\u001f" + clean ),
  ( $oc[] as $h
    | ($root._meta.hostvars[$h] // {}) as $hv
    | [ "N", $h,
        ($hv.tripleo_role_name // ([ $rgm[] | select(.m | any(.[]; . == $h)) | .g ][0]) // "unknown"),
        ($hv.ansible_host // $h),
        ($hv.ansible_ssh_user // $hv.ansible_user // "tripleo-admin"),
        ($hv.ansible_ssh_private_key_file // $hv.ansible_private_key_file // ""),
        ($hv.ansible_port // $hv.ansible_ssh_port // ""),
        ($hv.canonical_hostname // ""),
        (if $pm | any(.[]; . == $h) then "1" else "0" end),
        (if $pmr | any(.[]; . == $h) then "1" else "0" end),
        ($hv.ctlplane_ip // ""),
        ($hv.ctlplane_hostname // "")
      ] | map(clean) | join("\u001f") )
'

# Hostname/IP yang aman dipakai sebagai argumen ssh (tidak diawali '-')
_rhosp_valid_addr() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]
}

rhosp_add_node() {
    local i=${#N_NAME[@]}
    N_NAME+=("$1") N_ROLE+=("$2") N_IP+=("$3") N_USER+=("$4") N_KEY+=("$5")
    N_PORT+=("$6") N_CANON+=("$7") N_PCMK+=("$8") N_PCMKR+=("$9") N_LOCAL+=("${10}")
    N_SEL+=(0) N_HK+=("") N_ALT+=("${11:-}") N_ADDR+=("")
    IDX_BY_NAME["${1,,}"]=$i
    if declare -F rhosp_on_node_added >/dev/null; then
        rhosp_on_node_added "$i"
    fi
    return 0
}

rhosp_load_nodes() {
    local -a lines=()
    local line kind name role ip user key port canon pm pmr ctl_ip ctl_host alts a n_ctrl=0 n_comp=0 n_bad=0 n_oc
    local rc=0 errfile="$RHOSP_WORK_DIR/ansible-inventory.err"

    [[ -n "$RHOSP_WORK_DIR" && -d "$RHOSP_WORK_DIR" ]] || die "RHOSP_WORK_DIR belum diset (bug script)."

    INV_JSON="$RHOSP_WORK_DIR/inventory.json"
    "${ANSIBLE_INV_CMD[@]}" -i "$INVENTORY" --list > "$INV_JSON" 2> "$errfile" || rc=$?
    if (( rc != 0 )); then
        echo "${C_RED}❌ ansible-inventory gagal (rc=$rc):${C_RESET}"
        tail -n 5 "$errfile" | sed 's/^/   /'
        log_error -q "ansible-inventory gagal rc=$rc inventory=$INVENTORY"
        exit 1
    fi

    if ! jq -r "$JQ_NODES" "$INV_JSON" > "$RHOSP_WORK_DIR/nodes.lst" 2> "$errfile"; then
        die "Output ansible-inventory --list tidak bisa diproses jq: $(head -c 300 "$errfile")"
    fi
    mapfile -t lines < "$RHOSP_WORK_DIR/nodes.lst"

    for line in "${lines[@]}"; do
        IFS="$US" read -r kind name role ip user key port canon pm pmr ctl_ip ctl_host <<< "$line"
        if [[ "$kind" == "U" ]]; then
            [[ -z "$UC_NAME" ]] && UC_NAME="$name"
            continue
        fi

        # Validasi sebelum dipakai di argumen ssh (cegah opsi/karakter aneh)
        if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || ! _rhosp_valid_addr "$ip" \
              || [[ ! "$user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ || ( -n "$port" && ! "$port" =~ ^[0-9]+$ ) ]]; then
            n_bad=$(( n_bad + 1 ))
            warn "Host inventory dengan hostname/IP/user/port tidak valid dilewati: ${name//[^A-Za-z0-9._-]/?}"
            continue
        fi
        [[ -n "${IDX_BY_NAME[${name,,}]+x}" ]] && continue

        key="${key/#\~/$HOME}"
        [[ -z "$key" ]] && key="$HOME/.ssh/id_rsa"

        # Alamat fallback dari segmen ctlplane: valid dan berbeda dari ansible_host
        alts=""
        for a in "$ctl_ip" "$ctl_host"; do
            [[ -z "$a" || "${a,,}" == "${ip,,}" || " ${alts,,} " == *" ${a,,} "* ]] && continue
            if ! _rhosp_valid_addr "$a"; then
                log_warn -q "alamat ctlplane tidak valid diabaikan: host=$name"
                continue
            fi
            alts+="${alts:+ }$a"
        done

        rhosp_add_node "$name" "$role" "$ip" "$user" "$key" "$port" "$canon" "${pm:-0}" "${pmr:-0}" 0 "$alts"
        [[ "$pm" == 1 ]] && n_ctrl=$(( n_ctrl + 1 ))
        [[ "$pmr" == 1 ]] && n_comp=$(( n_comp + 1 ))
    done

    (( ${#N_NAME[@]} > 0 )) || die "Tidak ada node overcloud di inventory: $INVENTORY"
    n_oc=${#N_NAME[@]}

    # Undercloud (lokal), tidak lewat SSH
    if (( RHOSP_WITH_UNDERCLOUD )); then
        UC_IDX=${#N_NAME[@]}
        rhosp_add_node "${UC_NAME:-undercloud}" "Undercloud" "localhost" "$(id -un)" "" "" "" 0 0 1
    fi

    echo "🖥️  Node overcloud   : $n_oc (pacemaker: $n_ctrl, pacemaker_remote: $n_comp)"
    log_event INVENTORY "file=$INVENTORY" "nodes=$n_oc" "pacemaker=$n_ctrl" \
        "pacemaker_remote=$n_comp" "invalid=$n_bad" "undercloud=${UC_NAME:--}"
    local i fb
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        fb="${N_ALT[$i]:--}"
        log_event NODE "host=${N_NAME[$i]}" "role=${N_ROLE[$i]}" "ip=${N_IP[$i]}" "user=${N_USER[$i]}" \
            "key=${N_KEY[$i]}" "port=${N_PORT[$i]:--}" "pacemaker=${N_PCMK[$i]}" "pacemaker_remote=${N_PCMKR[$i]}" \
            "fallback=${fb// /,}"
    done
    return 0
}

# ============================================================
# Pilih node
# ============================================================

select_idx() {
    if (( N_SEL[$1] == 0 )); then
        N_SEL[$1]=1
        SEL+=("$1")
    fi
}

select_role() {
    local role="${1,,}" i found=1
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        if [[ "${N_ROLE[$i],,}" == "$role" ]]; then
            select_idx "$i"
            found=0
        fi
    done
    return "$found"
}

# Role unik sesuai urutan inventory
list_roles() {
    local i
    local -A seen=()
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        [[ -n "${seen[${N_ROLE[$i]}]+x}" ]] && continue
        seen["${N_ROLE[$i]}"]=1
        printf '%s\n' "${N_ROLE[$i]}"
    done
    return 0
}

role_count() {
    local i n=0
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        [[ "${N_ROLE[$i]}" == "$1" ]] && n=$(( n + 1 ))
    done
    printf '%d' "$n"
}

# Terapkan pilihan dari picker: role:<Role> | uc | node:<idx>
apply_pick() {
    case "$1" in
        role:*) select_role "${1#role:}" || true ;;
        uc)     select_idx "$UC_IDX" ;;
        node:*) select_idx "${1#node:}" ;;
    esac
}

picker_entries() {
    local role i
    P_KEY=() P_LABEL=()
    while IFS= read -r role; do
        P_KEY+=("role:$role")
        P_LABEL+=("[semua $role] ($(role_count "$role") node)")
    done < <(list_roles)
    if (( RHOSP_WITH_UNDERCLOUD )); then
        P_KEY+=("uc")
        P_LABEL+=("Undercloud (lokal)")
    fi
    for i in "${!N_NAME[@]}"; do
        (( N_LOCAL[i] )) && continue
        P_KEY+=("node:$i")
        P_LABEL+=("$(printf '%-28s %-20s %s' "${N_NAME[$i]}" "${N_ROLE[$i]}" "${N_IP[$i]}")")
    done
    return 0
}

pick_fzf() {
    local out rc=0 line i
    local -a picked=()

    out="$(
        for i in "${!P_KEY[@]}"; do
            printf '%s\t%s\n' "${P_KEY[$i]}" "${P_LABEL[$i]}"
        done | "${FZF_CMD[@]}" --multi --layout=reverse --border --info=inline \
            --delimiter=$'\t' --with-nth=2.. \
            --prompt='🖥️  node> ' \
            --header=$'Tab: pilih/batal pilih (multi), Enter: selesai, Esc: batal\nHOSTNAME                     ROLE                 IP'
    )" || rc=$?

    (( rc == 0 )) || return 1
    mapfile -t picked <<< "$out"
    for line in "${picked[@]}"; do
        [[ -n "$line" ]] && apply_pick "${line%%$'\t'*}"
    done
    return 0
}

pick_menu() {
    local input tok a b k i ok
    local -a toks=()

    echo
    echo "${C_BOLD}Pilih node:${C_RESET}"
    for i in "${!P_KEY[@]}"; do
        printf '  %2d) %s\n' $(( i + 1 )) "${P_LABEL[$i]}"
    done

    while true; do
        ask input "Nomor (mis. 1 4 5, 3-6, a = semua node overcloud, kosong = batal): "
        input="$(trim "$input")"
        [[ -z "$input" ]] && return 1

        read -ra toks <<< "${input//,/ }"
        ok=1
        for tok in "${toks[@]}"; do
            if [[ "${tok,,}" == "a" ]]; then
                continue
            elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
                (( a >= 1 && b <= ${#P_KEY[@]} && a <= b )) || ok=0
            elif is_uint "$tok"; then
                (( tok >= 1 && tok <= ${#P_KEY[@]} )) || ok=0
            else
                ok=0
            fi
        done
        (( ok )) && break
        echo "${C_RED}❌ Input tidak valid: $input${C_RESET}"
    done

    for tok in "${toks[@]}"; do
        if [[ "${tok,,}" == "a" ]]; then
            for i in "${!N_NAME[@]}"; do
                (( N_LOCAL[i] )) || select_idx "$i"
            done
        elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for (( k = BASH_REMATCH[1]; k <= BASH_REMATCH[2]; k++ )); do
                apply_pick "${P_KEY[$(( k - 1 ))]}"
            done
        else
            apply_pick "${P_KEY[$(( tok - 1 ))]}"
        fi
    done
    return 0
}

# Picker saja (fzf, atau menu bernomor). Return 1 jika batal/tidak ada pilihan.
rhosp_pick_nodes() {
    has_tty || return 1
    picker_entries
    if command -v "${FZF_CMD[0]}" >/dev/null 2>&1; then
        pick_fzf || true
    else
        pick_menu || true
    fi
    (( ${#SEL[@]} > 0 ))
}

rhosp_reset_selection() {
    local i
    for i in "${!N_SEL[@]}"; do
        N_SEL[i]=0
    done
    SEL=()
}

rhosp_selected_names() {
    local i names=""
    for i in "${SEL[@]}"; do
        names+="${names:+,}${N_NAME[$i]}"
    done
    printf '%s' "$names"
}

rhosp_select_nodes() {
    local n r i found names

    if (( ${#NODE_ARGS[@]} > 0 || ${#ROLE_ARGS[@]} > 0 )); then
        for n in "${NODE_ARGS[@]}"; do
            found="${IDX_BY_NAME[${n,,}]:-}"
            [[ -n "$found" ]] && (( N_LOCAL[found] )) && found=""
            if [[ -z "$found" ]]; then
                # Juga cocokkan short name dari canonical_hostname
                for i in "${!N_NAME[@]}"; do
                    (( N_LOCAL[i] )) && continue
                    if [[ -n "${N_CANON[$i]}" && ( "${N_CANON[$i],,}" == "${n,,}" || "$(short_name "${N_CANON[$i]}")" == "${n,,}" ) ]]; then
                        found="$i"
                        break
                    fi
                done
            fi
            if [[ -n "$found" ]]; then
                select_idx "$found"
            else
                warn "Node tidak dikenal di inventory, dilewati: $n"
            fi
        done
        for r in "${ROLE_ARGS[@]}"; do
            if ! select_role "$r"; then
                warn "Role tidak dikenal di inventory, dilewati: $r (role yang ada: $(list_roles | paste -sd, -))"
            fi
        done
        (( RHOSP_WITH_UNDERCLOUD && INCLUDE_UC )) && select_idx "$UC_IDX"
    else
        (( RHOSP_WITH_UNDERCLOUD && INCLUDE_UC )) && select_idx "$UC_IDX"
        picker_entries
        if command -v "${FZF_CMD[0]}" >/dev/null 2>&1; then
            pick_fzf || true
        else
            pick_menu || true
        fi
    fi

    if (( ${#SEL[@]} == 0 )); then
        echo "Tidak ada node yang dipilih."
        log_event SELECT selected=0
        exit 0
    fi

    names="$(rhosp_selected_names)"
    echo "✅ Node terpilih     : ${#SEL[@]} (${names})"
    log_event SELECT "selected=${#SEL[@]}" "nodes=$names"
}

# ============================================================
# SSH / SCP wrapper (satu-satunya jalur ke node)
# ============================================================

SSH_OPTS=()
RHOSP_SSH_EXTRA=()

# Identitas host key node IDX di known_hosts: ansible_host (dengan [..]:port
# untuk port selain 22), juga saat koneksi lewat alamat fallback
_rhosp_hk_id() {
    local h="${N_IP[$1]}"
    [[ -n "${N_PORT[$1]:-}" && "${N_PORT[$1]}" != 22 ]] && h="[$h]:${N_PORT[$1]}"
    printf '%s' "$h"
}

# build_ssh_opts IDX PORT_FLAG [ADDR] — ADDR selain ansible_host: HostKeyAlias
# supaya key diverifikasi (dan accept-new disimpan) atas nama ansible_host
build_ssh_opts() {
    local i="$1" port_flag="$2" addr="${3:-${N_IP[$1]}}"

    SSH_OPTS=(
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o ServerAliveInterval=15
        -o "StrictHostKeyChecking=${N_HK[$i]:-yes}"
    )
    [[ "$addr" != "${N_IP[$i]}" ]] && SSH_OPTS+=(-o "HostKeyAlias=$(_rhosp_hk_id "$i")")
    [[ -n "${N_KEY[$i]}" && -r "${N_KEY[$i]}" ]] && SSH_OPTS+=(-i "${N_KEY[$i]}")
    [[ -n "${N_PORT[$i]}" ]] && SSH_OPTS+=("$port_flag" "${N_PORT[$i]}")
    # Opsi tambahan dari pemanggil (mis. koneksi baru tanpa multiplexing:
    # local RHOSP_SSH_EXTRA=(-o ControlMaster=no -o ControlPath=none))
    if (( ${#RHOSP_SSH_EXTRA[@]} > 0 )); then SSH_OPTS+=("${RHOSP_SSH_EXTRA[@]}"); fi
    return 0
}

# ------------------------------------------------------------
# Fallback alamat (ansible_host => ctlplane_ip => ctlplane_hostname)
# ------------------------------------------------------------

# Ambil alamat yang sudah ditentukan oleh proses lain (subshell/worker)
_rhosp_addr_sync() {
    local i="$1" f a=""
    [[ -n "${N_ADDR[$i]:-}" || -z "$RHOSP_WORK_DIR" ]] && return 0
    f="$RHOSP_WORK_DIR/addr/$i"
    [[ -r "$f" ]] || return 0
    IFS= read -r a < "$f" || true
    _rhosp_valid_addr "$a" && N_ADDR[i]="$a"
    return 0
}

_rhosp_addr_set() {
    local i="$1" a="$2" d="$RHOSP_WORK_DIR/addr" tmp
    N_ADDR[i]="$a"
    [[ -n "$RHOSP_WORK_DIR" && -d "$RHOSP_WORK_DIR" ]] || return 0
    mkdir -p "$d" 2>/dev/null || return 0
    tmp="$(mktemp "$d/.$i.XXXXXX" 2>/dev/null)" || return 0
    if ! { printf '%s\n' "$a" > "$tmp" && mv -f "$tmp" "$d/$i"; } 2>/dev/null; then
        rm -f "$tmp"
    fi
    return 0
}

# Alamat koneksi aktif node IDX
rhosp_node_addr() {
    _rhosp_addr_sync "$1"
    printf '%s' "${N_ADDR[$1]:-${N_IP[$1]}}"
}

# Koneksi gagal sebelum perintah remote berjalan (aman untuk dicoba ulang).
# Auth gagal dan host key berubah TIDAK termasuk (host yang sama).
_rhosp_conn_error() {
    grep -qE 'ssh: connect to host |Could not resolve hostname|Name or service not known|Temporary failure in name resolution|Network is unreachable|No route to host' "$1" 2>/dev/null
}

# Hostname yang hanya resolve ke alamat yang sudah dicoba tidak perlu dicoba
# lagi (mencegah dua kali ConnectTimeout untuk node yang mati). Tanpa getent
# atau resolve gagal: tetap dicoba.
_rhosp_same_as_tried() {
    local a="$1" r
    local -a res=()
    shift
    [[ "$a" =~ ^[0-9.]+$ || "$a" == *:* ]] && return 1
    command -v getent >/dev/null 2>&1 || return 1
    mapfile -t res < <(timeout 5 getent ahosts "$a" 2>/dev/null | awk '{print $1}' | sort -u)
    (( ${#res[@]} > 0 )) || return 1
    for r in "${res[@]}"; do
        [[ " ${*,,} " == *" ${r,,} "* ]] || return 1
    done
    return 0
}

# _rhosp_fb IDX CONN_RC FUNC ARGS... — jalankan FUNC (alamat di _RHOSP_ADDR);
# jika koneksi gagal (rc == CONN_RC, 0 = rc apa pun selain 0) dan alamat belum
# ditentukan, coba alamat fallback. stderr percobaan yang gagal hanya
# diteruskan jika semua alamat gagal.
_rhosp_fb() {
    local i="$1" crc="$2" a rc=0 errf errall n=0 failed=1
    local -a cands=() tried=()
    shift 2

    _rhosp_addr_sync "$i"
    if [[ -n "${N_ADDR[$i]:-}" || -z "${N_ALT[$i]:-}" || -z "$RHOSP_WORK_DIR" || ! -d "$RHOSP_WORK_DIR" ]]; then
        _RHOSP_ADDR="${N_ADDR[$i]:-${N_IP[$i]}}"
        "$@"
        return
    fi

    read -ra cands <<< "${N_IP[$i]} ${N_ALT[$i]}"
    errf="$(mktemp "$RHOSP_WORK_DIR/.fb-err.XXXXXX")" || { _RHOSP_ADDR="${N_IP[$i]}"; "$@"; return; }
    errall="$errf.all"
    : > "$errall"

    for a in "${cands[@]}"; do
        n=$(( n + 1 ))
        if (( n > 1 )) && _rhosp_same_as_tried "$a" "${tried[@]}"; then
            log_event SSH_FALLBACK "host=${N_NAME[$i]}" "addr=$a" result=SKIPPED "reason=resolves to tried address"
            continue
        fi
        tried+=("$a")
        _RHOSP_ADDR="$a"
        rc=0
        "$@" 2> "$errf" || rc=$?
        if (( rc != 0 )) && (( crc == 0 || rc == crc )) && _rhosp_conn_error "$errf"; then
            cat "$errf" >> "$errall"
            log_event SSH_FALLBACK "host=${N_NAME[$i]}" "addr=$a" result=FAILED \
                "error=$(grep -v '^[[:space:]]*$' "$errf" | tail -n 1 | cut -c1-200)"
            continue
        fi
        failed=0
        _rhosp_addr_set "$i" "$a"
        [[ "$a" != "${N_IP[$i]}" ]] && log_event SSH_FALLBACK "host=${N_NAME[$i]}" \
            "ansible_host=${N_IP[$i]}" "addr=$a" result=SUCCESS
        break
    done

    if (( failed )); then
        cat "$errall" >&2
    else
        cat "$errf" >&2
    fi
    rm -f "$errf" "$errall"
    return "$rc"
}

# rhosp_report_fallbacks IDX... — beri tahu operator (sekali per node) node
# yang dihubungi lewat alamat ctlplane, bukan ansible_host
rhosp_report_fallbacks() {
    local i
    for i in "$@"; do
        (( N_LOCAL[i] )) && continue
        _rhosp_addr_sync "$i"
        [[ -n "${N_ADDR[$i]:-}" && "${N_ADDR[$i]}" != "${N_IP[$i]}" ]] || continue
        [[ -n "${_RHOSP_FB_SHOWN[$i]+x}" ]] && continue
        _RHOSP_FB_SHOWN[$i]=1
        info "${N_NAME[$i]}: ansible_host ${N_IP[$i]} tidak bisa dihubungi, memakai alamat ctlplane ${N_ADDR[$i]}"
    done
    return 0
}

_rhosp_ssh_once() {
    local i="$1" t="$2" cmd="$3"
    build_ssh_opts "$i" -p "$_RHOSP_ADDR"
    timeout --kill-after=10 "$t" \
        "${SSH_CMD[@]}" "${SSH_OPTS[@]}" -- "${N_USER[$i]}@$_RHOSP_ADDR" "$cmd" < /dev/null
}

# ssh_node IDX TIMEOUT_DETIK REMOTE_CMD — stdout/stderr perintah remote apa adanya.
# Tanpa -t, stdin dari /dev/null; timeout lokal sebagai pengaman. Fallback
# alamat ctlplane jika ansible_host tidak bisa dihubungi.
ssh_node() {
    _rhosp_fb "$1" 255 _rhosp_ssh_once "$@"
}

# ssh_node_stdin IDX TIMEOUT_DETIK REMOTE_CMD — seperti ssh_node, tetapi stdin
# dari pemanggil. Dipakai untuk data yang tidak boleh masuk string perintah
# (pola pencarian, daftar file) dan untuk stream follow (stdin = FIFO yang
# ditahan terbuka: saat ssh berhenti, perintah remote menerima EOF).
# TIMEOUT 0 = tanpa timeout lokal (ssh tetap di process group pemanggil).
# LogLevel=ERROR: banner sshd dan "Permanently added" tidak masuk stream
# (error koneksi/auth/host key tetap tampil). Tanpa percobaan ulang: memakai
# alamat yang sudah ditentukan koneksi sebelumnya.
ssh_node_stdin() {
    local i="$1" t="$2" cmd="$3" addr
    addr="$(rhosp_node_addr "$i")"
    build_ssh_opts "$i" -p "$addr"
    SSH_OPTS+=(-o LogLevel=ERROR)
    if (( t > 0 )); then
        timeout --kill-after=10 "$t" \
            "${SSH_CMD[@]}" "${SSH_OPTS[@]}" -- "${N_USER[$i]}@$addr" "$cmd"
    else
        "${SSH_CMD[@]}" "${SSH_OPTS[@]}" -- "${N_USER[$i]}@$addr" "$cmd"
    fi
}

_rhosp_scp_once() {
    local i="$1" src="$2" dst="$3" t="$4" host="$_RHOSP_ADDR"
    [[ "$host" == *:* ]] && host="[$host]"
    build_ssh_opts "$i" -P "$_RHOSP_ADDR"
    timeout --kill-after=10 "$t" \
        "${SCP_CMD[@]}" -q "${SSH_OPTS[@]}" -- "${N_USER[$i]}@$host:$src" "$dst" < /dev/null
}

# scp_fetch IDX REMOTE_PATH LOCAL_PATH TIMEOUT_DETIK
scp_fetch() {
    _rhosp_fb "$1" 0 _rhosp_scp_once "$@"
}

# Klasifikasi kegagalan SSH dari stderr => alasan SKIPPED
ssh_fail_reason() {
    local err="$1" rc="$2"
    if [[ "$err" == *"REMOTE HOST IDENTIFICATION HAS CHANGED"* || "$err" == *"Host key verification failed"* ]]; then
        printf 'host key mismatch'
    elif [[ "$err" == *"Permission denied"* ]]; then
        printf 'ssh auth failed'
    elif (( rc == 124 || rc == 137 )); then
        printf 'unreachable (timeout)'
    else
        printf 'unreachable'
    fi
}

# ============================================================
# Host key SSH
# ============================================================

host_key_known() {
    local host f
    host="$(_rhosp_hk_id "$1")"
    for f in "$HOME/.ssh/known_hosts" /etc/ssh/ssh_known_hosts; do
        [[ -r "$f" ]] || continue
        ssh-keygen -F "$host" -f "$f" >/dev/null 2>&1 && return 0
    done
    return 1
}

# check_host_keys LABEL IDX... — host yang belum dikenal: satu konfirmasi
# untuk StrictHostKeyChecking=accept-new; yang dikenal: yes; ditolak: reject.
# Tanpa terminal (mode non-interaktif) host yang belum dikenal => reject.
check_host_keys() {
    local label="$1" i answer names=""
    local -a unknown=()
    shift

    for i in "$@"; do
        (( N_LOCAL[i] )) && continue
        [[ -n "${N_HK[$i]}" ]] && continue
        if command -v ssh-keygen >/dev/null 2>&1 && host_key_known "$i"; then
            N_HK[i]="yes"
        else
            unknown+=("$i")
        fi
    done

    (( ${#unknown[@]} == 0 )) && return 0

    echo
    warn "Host key SSH belum dikenal di known_hosts ($label):"
    for i in "${unknown[@]}"; do
        printf '     %-28s %s\n' "${N_NAME[$i]}" "${N_IP[$i]}"
        names+="${names:+,}${N_NAME[$i]}"
    done
    if has_tty; then
        echo "   Jika diterima, key disimpan ke ~/.ssh/known_hosts saat koneksi pertama"
        echo "   (StrictHostKeyChecking=accept-new). Key yang BERUBAH tetap ditolak."
        ask answer "Terima host key baru untuk ${#unknown[@]} host ini? [y/N]: "
    else
        answer=""
        echo "   Tidak ada terminal untuk konfirmasi: host ini dilewati."
    fi

    if is_yes "$answer"; then
        for i in "${unknown[@]}"; do
            N_HK[i]="accept-new"
        done
        log_event DECISION hostkeys=accept-new "hosts=$names"
    else
        for i in "${unknown[@]}"; do
            N_HK[i]="reject"
        done
        log_event DECISION hostkeys=reject "hosts=$names"
    fi
    return 0
}

# Catat fingerprint host key yang baru diterima (setelah koneksi pertama)
log_accepted_key() {
    local i="$1" host fp
    [[ "${N_HK[$i]}" == "accept-new" ]] || return 0
    host="$(_rhosp_hk_id "$i")"
    fp="$(ssh-keygen -l -F "$host" -f "$HOME/.ssh/known_hosts" 2>/dev/null | awk '!/^#/ {print $3 "/" $2; exit}')" || fp=""
    log_event HOSTKEY_ACCEPTED "host=${N_NAME[$i]}" "ip=${N_IP[$i]}" "fingerprint=${fp:--}" "addr=$(rhosp_node_addr "$i")"
}
