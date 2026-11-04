#!/bin/bash
# shellcheck disable=SC2034  # variabel CL_* dibaca oleh script pemanggil
# ============================================================
# OpenStack Ops Toolkit - shared helper for RHOSP container log scripts
# ============================================================
#
# Di-source SETELAH lib/logging.sh dan lib/rhosp.sh oleh
# rhosp/view-container-logs.sh dan rhosp/search-container-logs.sh.
# Semua perintah remote lewat ssh_node / ssh_node_stdin (lib/rhosp.sh) dan
# hanya membaca (sudo -n find|tail|grep|zgrep).
#
#   cl_setup_workdir NAME     WORK dir (mktemp -d, umask 077) => CL_WORK,
#                             RHOSP_WORK_DIR; hapus dengan cl_cleanup
#   cl_discover IDX...        satu SSH per node (paralel), sekaligus pre-check:
#                             sudo -n find /var/log/containers -type f.
#                             Hasil per node di CL_STATE[i] (ok|fail),
#                             CL_REASON[i], $CL_WORK/disc/<i>.tsv
#   cl_ok_nodes               index node terpilih yang discovery-nya ok
#   cl_pick_files [EXTRA_LABEL]
#                             picker file aktif (fzf + preview, atau menu
#                             bernomor dengan filter). EXTRA_LABEL = entry
#                             khusus di atas daftar (CL_PICK_ALL=1 jika dipilih).
#                             Hasil: CL_FILES. Return 1 = batal.
#   cl_use_log_args PATH...   --log: validasi + cek keberadaan => CL_FILES
#   cl_report_missing         beri tahu file yang tidak ada di sebagian node
#   cl_node_files IDX         file CL_FILES yang dimiliki node (satu per baris)
#   cl_rotated_of IDX PATH    file rotasi milik PATH di node (satu per baris)
#   cl_show PLAIN [COLOR]     pager (${PAGER:-less -R}) jika stdout terminal,
#                             selain itu cetak PLAIN
#   cl_save SRC KIND          salin ke $CL_SAVE_DIR/container-logs-KIND-<ts>.log
#                             (600, noclobber, akhiran -2, -3 ...)
#   cl_preview_main DIR PATH  mode internal --_preview (dipanggil fzf; tanpa log)
#
# Path file selalu relatif terhadap /var/log/containers dan divalidasi
# (cl_valid_path) sebelum masuk perintah remote; tetap di-quote %q.
# File rotasi (.N, -YYYYMMDD[HH], .gz/.xz/.bz2/.zst) tidak tampil di picker;
# dipetakan ke file induknya.

[[ -n "${_OSOPS_CONTAINERLOGS_LOADED:-}" ]] && return 0
_OSOPS_CONTAINERLOGS_LOADED=1

CL_ROOT="/var/log/containers"
CL_SAVE_DIR="${OSOPS_CL_SAVE_DIR:-/tmp}"
CL_DISC_TIMEOUT="${OSOPS_CL_DISC_TIMEOUT:-120}"
CL_PREVIEW_LINES=30
CL_SELF=""          # path script pemanggil (untuk --_preview)
CL_WORK=""
CL_FILES=()
CL_PICK_ALL=0
declare -A CL_STATE=() CL_REASON=() CL_NACT=() CL_NROT=() CL_NBAD=()
declare -A CL_HAS=() CL_ROTS=() CL_RSIZE=() CL_RCOMP=()
CL_BG_PIDS=()

# Komponen path: huruf/angka dan @ _ + . , = - (tidak diawali "-"),
# tanpa "." / ".." sebagai komponen.
CL_PATH_RE='^[A-Za-z0-9@_+.,=][A-Za-z0-9@_+.,=-]*(/[A-Za-z0-9@_+.,=][A-Za-z0-9@_+.,=-]*)*$'

# Satu panggilan per node: penanda koneksi, find (NUL-separated), rc find
# shellcheck disable=SC2016  # dievaluasi di node
CL_DISCOVER_CMD='printf "__OSOPS_CL__\0"; sudo -n find /var/log/containers -type f -printf "%s\t%T@\t%P\0"; printf "__OSOPS_RC__=%s\0" "$?"'

# cl_err_tail FILE [N] — N baris terakhir stderr ssh dalam satu baris, tanpa
# banner sshd (baris "*** ... ***") dan tanpa "Warning: Permanently added"
cl_err_tail() {
    grep -vE '^Warning: Permanently added|^[[:space:]]*\*.*\*[[:space:]]*$|^[[:space:]]*\*+[[:space:]]*$|^[[:space:]]*$' "$1" 2>/dev/null \
        | tail -n "${2:-3}" | tr '\n' ' ' | cut -c1-300
    return 0
}

cl_valid_path() {
    [[ "$1" =~ $CL_PATH_RE ]] || return 1
    [[ "/$1/" != */./* && "/$1/" != */../* ]]
}

# Ukuran ringkas dari byte
cl_human() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1073741824) printf "%.1fG", b / 1073741824
        else if (b >= 1048576) printf "%.1fM", b / 1048576
        else if (b >= 1024) printf "%.1fK", b / 1024
        else printf "%dB", b }'
}

# cl_quote_paths PATH... — path absolut ter-quote untuk string perintah remote
cl_quote_paths() {
    local p q out=""
    for p in "$@"; do
        printf -v q '%q' "$CL_ROOT/$p"
        out+=" $q"
    done
    printf '%s' "${out# }"
}

cl_setup_workdir() {
    CL_WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX")" || die "Gagal membuat direktori sementara."
    RHOSP_WORK_DIR="$CL_WORK"
    mkdir -p "$CL_WORK/disc" "$CL_WORK/preview"
}

cl_kill_bg() {
    local pid
    for pid in "${CL_BG_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && kill_tree "$pid"
    done
    CL_BG_PIDS=()
    return 0
}

cl_cleanup() {
    cl_kill_bg
    [[ -n "$CL_WORK" && -d "$CL_WORK" ]] && rm -rf -- "$CL_WORK"
    return 0
}

# ============================================================
# Discovery
# ============================================================

# Output find mentah (NUL) => TSV:
#   A <path> <size> <mtime>
#   R <path> <size> <mtime> <parent> <comp>
#   # bad=<n> rc=<n> marker=<0|1>
_cl_parse_find() {
    tr '\n\0' '?\n' < "$1" | awk -F '\t' -v re="$CL_PATH_RE" '
        $0 == "__OSOPS_CL__" { marker = 1; next }
        /^__OSOPS_RC__=/ { rc = substr($0, 14); next }
        NF != 3 { bad++; next }
        {
            size = $1; mt = int($2); p = $3
            if (p !~ re || ("/" p "/") ~ /\/\.\.?\//) { bad++; next }
            comp = ""; base = p
            if (match(p, /\.(gz|xz|bz2|zst)$/)) {
                comp = substr(p, RSTART + 1); base = substr(p, 1, RSTART - 1)
            }
            if (match(base, /(\.[0-9]+|-(19|20)[0-9][0-9][0-9][0-9][0-9][0-9]([0-9][0-9])?)$/) && RSTART > 1) {
                printf "R\t%s\t%s\t%d\t%s\t%s\n", p, size, mt, substr(base, 1, RSTART - 1), comp
            } else if (comp != "") {
                printf "R\t%s\t%s\t%d\t%s\t%s\n", p, size, mt, base, comp
            } else {
                printf "A\t%s\t%s\t%d\n", p, size, mt
            }
        }
        END { printf "# bad=%d rc=%s marker=%d\n", bad, (rc == "" ? "-" : rc), marker }
    '
}

# Muat TSV node ke array asosiatif (CL_HAS, CL_ROTS, CL_RSIZE, CL_RCOMP)
_cl_load_node() {
    local i="$1" kind p size mt parent comp
    CL_NACT[$i]=0
    CL_NROT[$i]=0
    while IFS=$'\t' read -r kind p size mt parent comp; do
        case "$kind" in
            A)
                CL_HAS["$i|$p"]="$size"
                CL_NACT[$i]=$(( CL_NACT[$i] + 1 ))
                ;;
            R)
                CL_ROTS["$i|$parent"]+="${CL_ROTS["$i|$parent"]:+ }$p"
                CL_RSIZE["$i|$p"]="$size"
                CL_RCOMP["$i|$p"]="$comp"
                CL_NROT[$i]=$(( CL_NROT[$i] + 1 ))
                ;;
        esac
    done < "$CL_WORK/disc/$i.tsv"
    return 0
}

# cl_discover IDX... — node yang sudah ok tidak diulang
cl_discover() {
    local i rc err reason meta bad frc marker
    local -a todo=()

    for i in "$@"; do
        [[ "${CL_STATE[$i]:-}" == "ok" ]] && continue
        if [[ "${N_HK[$i]}" == "reject" ]]; then
            CL_STATE[$i]="fail"
            CL_REASON[$i]="host key unknown"
            continue
        fi
        todo+=("$i")
    done

    if (( ${#todo[@]} > 0 )); then
        echo
        echo "${C_BOLD}🔍 Mencari file log di ${#todo[@]} node...${C_RESET}"
        for i in "${todo[@]}"; do
            (
                rc=0
                ssh_node "$i" "$CL_DISC_TIMEOUT" "$CL_DISCOVER_CMD" \
                    > "$CL_WORK/disc/$i.raw" 2> "$CL_WORK/disc/$i.err" || rc=$?
                echo "$rc" > "$CL_WORK/disc/$i.rc"
            ) &
            CL_BG_PIDS+=("$!")
        done
        wait "${CL_BG_PIDS[@]}" 2>/dev/null || true
        CL_BG_PIDS=()
    fi

    for i in "${todo[@]}"; do
        rc="$(cat "$CL_WORK/disc/$i.rc" 2>/dev/null)" || rc=""
        _cl_parse_find "$CL_WORK/disc/$i.raw" > "$CL_WORK/disc/$i.tsv"
        rm -f "$CL_WORK/disc/$i.raw"
        meta="$(tail -n 1 "$CL_WORK/disc/$i.tsv")"
        bad="${meta#*bad=}" bad="${bad%% *}"
        frc="${meta#*rc=}" frc="${frc%% *}"
        marker="${meta##*marker=}"
        err="$(cl_err_tail "$CL_WORK/disc/$i.err")"
        CL_NBAD[$i]="$bad"

        if [[ "$marker" != 1 ]]; then
            reason="$(ssh_fail_reason "$err" "${rc:-255}")"
        elif [[ "$err" == *"sudo:"* ]]; then
            reason="sudo failed"
        elif ! grep -q '^A' "$CL_WORK/disc/$i.tsv" && [[ "$frc" != 0 ]]; then
            reason="find failed: ${err:-rc=$frc}"
        else
            reason=""
        fi

        if [[ -n "$reason" ]]; then
            CL_STATE[$i]="fail"
            CL_REASON[$i]="$reason"
            log_event DISCOVERY "host=${N_NAME[$i]}" "ip=${N_IP[$i]}" result=SKIPPED "reason=$reason" \
                "rc=${rc:--}" "error=${err:--}"
            continue
        fi

        CL_STATE[$i]="ok"
        CL_REASON[$i]=""
        log_accepted_key "$i"
        _cl_load_node "$i"
        log_event DISCOVERY "host=${N_NAME[$i]}" "ip=${N_IP[$i]}" result=OK "active=${CL_NACT[$i]}" \
            "rotated=${CL_NROT[$i]}" "invalid_path=$bad" "find_rc=$frc"
    done

    for i in "$@"; do
        if [[ "${CL_STATE[$i]}" == "ok" ]]; then
            printf '  %-28s %s\n' "${N_NAME[$i]}" \
                "${C_GREEN}OK${C_RESET} (${CL_NACT[$i]} file aktif, ${CL_NROT[$i]} file rotasi)"
            (( ${CL_NBAD[$i]:-0} > 0 )) && \
                warn "${N_NAME[$i]}: ${CL_NBAD[$i]} file dengan nama tidak biasa dilewati (karakter di luar huruf/angka/@_+.,=-)."
        else
            printf '  %-28s %s\n' "${N_NAME[$i]}" "${C_YELLOW}DILEWATI (${CL_REASON[$i]})${C_RESET}"
        fi
    done
    return 0
}

cl_ok_nodes() {
    local i
    for i in "${SEL[@]}"; do
        [[ "${CL_STATE[$i]:-}" == "ok" ]] && printf '%s\n' "$i"
    done
    return 0
}

# ============================================================
# Daftar file gabungan + picker
# ============================================================

# Index gabungan node ok terpilih: path<TAB>jumlah node<TAB>size max<TAB>mtime max<TAB>idx pertama
cl_build_index() {
    local i
    local -a files=()
    for i in $(cl_ok_nodes); do
        files+=("$CL_WORK/disc/$i.tsv")
    done
    (( ${#files[@]} > 0 )) || { : > "$CL_WORK/index.tsv"; return 0; }
    awk -F '\t' '
        FNR == 1 { node = FILENAME; sub(/.*\//, "", node); sub(/\.tsv$/, "", node) }
        $1 == "A" {
            p = $2; n[p]++
            if (!(p in sz) || $3 + 0 > sz[p]) sz[p] = $3 + 0
            if (!(p in mt) || $4 + 0 > mt[p]) mt[p] = $4 + 0
            if (!(p in first)) first[p] = node
        }
        END { for (p in n) printf "%s\t%d\t%d\t%d\t%s\n", p, n[p], sz[p], mt[p], first[p] }
    ' "${files[@]}" | LC_ALL=C sort -t $'\t' -k1,1 > "$CL_WORK/index.tsv"

    # Data untuk --_preview: node (tanpa secret) dan owner per path. Pemisah
    # \x1f (bukan tab): read dengan IFS=tab menggabungkan field kosong (port)
    for i in $(cl_ok_nodes); do
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$i" "${N_NAME[$i]}" "${N_USER[$i]}" "${N_IP[$i]}" \
            "${N_KEY[$i]}" "${N_PORT[$i]}" "${N_HK[$i]/accept-new/yes}"
    done > "$CL_WORK/nodes.tsv"
    return 0
}

# Baris picker: key<TAB>label
_cl_picker_lines() {
    local extra="$1" total p n sz mt
    total="$(cl_ok_nodes | wc -l)"
    [[ -n "$extra" ]] && printf '__ALL__\t%s\n' "$extra"
    while IFS=$'\t' read -r p n sz mt _; do
        printf '%s\t%-60s %5s %8s  %(%Y-%m-%d %H:%M)T\n' "$p" "$p" "$n/$total" "$(cl_human "$sz")" "$mt"
    done < "$CL_WORK/index.tsv"
}

cl_preview_cmd() {
    printf 'bash %q --_preview %q {1}' "$CL_SELF" "$CL_WORK"
}

_cl_pick_fzf() {
    local extra="$1" out rc=0 line
    local -a picked=()

    out="$(
        _cl_picker_lines "$extra" | "${FZF_CMD[@]}" --multi --layout=reverse --border --info=inline \
            --delimiter=$'\t' --with-nth=2.. \
            --prompt='📄 log> ' \
            --header=$'Ketik untuk mencari (mis. "nova api"). Tab: pilih (multi), Enter: selesai, Esc: batal\nPATH (/var/log/containers)                                    NODE   UKURAN  DIUBAH' \
            --preview="$(cl_preview_cmd)" --preview-window='down:45%:wrap'
    )" || rc=$?

    (( rc == 0 )) || return 1
    mapfile -t picked <<< "$out"
    for line in "${picked[@]}"; do
        [[ -z "$line" ]] && continue
        line="${line%%$'\t'*}"
        if [[ "$line" == "__ALL__" ]]; then
            CL_PICK_ALL=1
        else
            CL_FILES+=("$line")
        fi
    done
    return 0
}

_cl_pick_menu() {
    local extra="$1" filter="" input tok a b k ok key label
    local -a keys=() labels=() shown=() toks=() words=()

    while IFS=$'\t' read -r key label; do
        keys+=("$key")
        labels+=("$label")
    done < <(_cl_picker_lines "$extra")

    while true; do
        shown=()
        echo
        echo "${C_BOLD}Pilih file log${filter:+ (filter: \"$filter\")}:${C_RESET}"
        read -ra words <<< "${filter,,}"
        for k in "${!keys[@]}"; do
            ok=1
            for tok in "${words[@]}"; do
                [[ "${labels[$k],,}" == *"$tok"* ]] || ok=0
            done
            (( ok )) || continue
            shown+=("$k")
            printf '  %3d) %s\n' "${#shown[@]}" "${labels[$k]}"
        done
        (( ${#shown[@]} == 0 )) && echo "  ${C_DIM}(tidak ada yang cocok)${C_RESET}"

        ask input "Nomor (mis. 1 3 5-7) / kata kunci filter / kosong = hapus filter / q = batal: "
        input="$(trim "$input")"
        case "$input" in
            q|Q) return 1 ;;
            "")  filter=""; continue ;;
        esac

        read -ra toks <<< "${input//,/ }"
        ok=1
        for tok in "${toks[@]}"; do
            if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
                (( a >= 1 && a <= b && b <= ${#shown[@]} )) || ok=0
            elif is_uint "$tok"; then
                (( tok >= 1 && tok <= ${#shown[@]} )) || ok=0
            else
                ok=2
            fi
        done
        if (( ok == 2 )); then
            filter="$input"
            continue
        elif (( ok == 0 )); then
            echo "${C_RED}❌ Nomor tidak valid: $input${C_RESET}"
            continue
        fi

        for tok in "${toks[@]}"; do
            if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                for (( k = BASH_REMATCH[1]; k <= BASH_REMATCH[2]; k++ )); do
                    _cl_menu_take "${keys[${shown[$(( k - 1 ))]}]}"
                done
            else
                _cl_menu_take "${keys[${shown[$(( tok - 1 ))]}]}"
            fi
        done
        return 0
    done
}

_cl_menu_take() {
    local f
    if [[ "$1" == "__ALL__" ]]; then
        CL_PICK_ALL=1
        return 0
    fi
    for f in "${CL_FILES[@]}"; do
        [[ "$f" == "$1" ]] && return 0
    done
    CL_FILES+=("$1")
}

# cl_pick_files [EXTRA_LABEL]
cl_pick_files() {
    local extra="${1:-}"
    CL_FILES=()
    CL_PICK_ALL=0
    cl_build_index
    if [[ ! -s "$CL_WORK/index.tsv" ]]; then
        warn "Tidak ada file log aktif di $CL_ROOT pada node terpilih."
        return 1
    fi
    has_tty || return 1
    if command -v "${FZF_CMD[0]}" >/dev/null 2>&1; then
        _cl_pick_fzf "$extra" || return 1
    else
        _cl_pick_menu "$extra" || return 1
    fi
    (( CL_PICK_ALL || ${#CL_FILES[@]} > 0 ))
}

# cl_use_log_args PATH... — file dari --log (relatif terhadap /var/log/containers)
cl_use_log_args() {
    local p i found
    CL_FILES=()
    CL_PICK_ALL=0
    cl_build_index
    for p in "$@"; do
        p="${p#"$CL_ROOT"/}"
        if ! cl_valid_path "$p"; then
            warn "--log tidak valid (harus path relatif dari $CL_ROOT, tanpa .. dan karakter khusus): $p"
            continue
        fi
        found=0
        for i in $(cl_ok_nodes); do
            [[ -n "${CL_HAS["$i|$p"]+x}" ]] && found=1
        done
        if (( ! found )); then
            warn "File log tidak ditemukan di node mana pun (atau file rotasi): $p"
            continue
        fi
        _cl_menu_take "$p"
    done
    (( ${#CL_FILES[@]} > 0 ))
}

cl_node_files() {
    local f
    for f in "${CL_FILES[@]}"; do
        [[ -n "${CL_HAS["$1|$f"]+x}" ]] && printf '%s\n' "$f"
    done
    return 0
}

# Semua file aktif node (urut path)
cl_node_all_files() {
    awk -F '\t' '$1 == "A" { print $2 }' "$CL_WORK/disc/$1.tsv" | LC_ALL=C sort
}

cl_rotated_of() {
    local r
    for r in ${CL_ROTS["$1|$2"]:-}; do
        printf '%s\n' "$r"
    done
    return 0
}

# Beri tahu file yang tidak ada di sebagian node (dilanjutkan untuk yang punya)
cl_report_missing() {
    local f i miss
    for f in "${CL_FILES[@]}"; do
        miss=""
        for i in $(cl_ok_nodes); do
            [[ -n "${CL_HAS["$i|$f"]+x}" ]] || miss+="${miss:+, }${N_NAME[$i]}"
        done
        if [[ -n "$miss" ]]; then
            info "$f tidak ada di: $miss — dilanjutkan untuk node yang memilikinya."
            log_event MISSING "file=$f" "nodes=$miss"
        fi
    done
    return 0
}

# ============================================================
# Tampilan dan penyimpanan
# ============================================================

# cl_show PLAIN [COLOR] — pager hanya jika stdout terminal
cl_show() {
    local plain="$1" color="${2:-$1}"
    local -a pager=()
    if [[ -t 1 ]]; then
        read -ra pager <<< "${PAGER:-less -R}"
        (( ${#pager[@]} > 0 )) || pager=(less -R)
        "${pager[@]}" < "$color" || true
    else
        cat -- "$plain"
    fi
    return 0
}

# cl_save SRC KIND — output: path file tersimpan (stdout); return 1 jika gagal
cl_save() {
    local src="$1" kind="$2" base dest n=1
    base="$CL_SAVE_DIR/container-logs-$kind-$(date +%Y%m%d-%H%M%S)"
    dest="$base.log"
    while ! ( umask 077; set -o noclobber; cat -- "$src" > "$dest" ) 2>/dev/null; do
        if [[ ! -e "$dest" ]]; then
            log_error -q "gagal menyimpan hasil ke $dest"
            return 1
        fi
        n=$(( n + 1 ))
        dest="$base-$n.log"
        (( n > 100 )) && return 1
    done
    log_event SAVE "file=$dest" "bytes=$(wc -c < "$dest")" "kind=$kind"
    printf '%s' "$dest"
}

# ============================================================
# Mode internal --_preview (dipanggil fzf; tidak menulis log)
# ============================================================

cl_preview_main() {
    local dir="$1" path="$2" idx name user ip key port hk owner cache rc=0
    path="${path#\'}"
    path="${path%\'}"
    [[ -d "$dir" && -r "$dir/index.tsv" ]] || { echo "(preview tidak tersedia)"; return 0; }
    if [[ "$path" == "__ALL__" ]]; then
        echo "Semua file log aktif di node terpilih."
        return 0
    fi
    cl_valid_path "$path" || { echo "(path tidak valid)"; return 0; }

    owner="$(awk -F '\t' -v p="$path" '$1 == p { print $5; exit }' "$dir/index.tsv")"
    [[ -n "$owner" ]] || { echo "(tidak ada data node)"; return 0; }

    while IFS="$US" read -r idx name user ip key port hk; do
        [[ "$idx" == "$owner" ]] || continue
        N_NAME[idx]="$name" N_USER[idx]="$user" N_IP[idx]="$ip"
        N_KEY[idx]="$key" N_PORT[idx]="$port" N_HK[idx]="$hk"
    done < "$dir/nodes.tsv"
    [[ -n "${N_NAME[$owner]:-}" ]] || { echo "(tidak ada data node)"; return 0; }

    echo "── ${N_NAME[$owner]}: $path ($CL_PREVIEW_LINES baris terakhir) ──"
    cache="$dir/preview/$(printf '%s' "$path" | cksum | cut -d' ' -f1)"
    if [[ ! -e "$cache" ]]; then
        (
            umask 077
            ssh_node "$owner" 30 "sudo -n tail -n $CL_PREVIEW_LINES -- $(cl_quote_paths "$path")" \
                > "$cache.tmp" 2> "$cache.err" || rc=$?
            if (( rc == 0 )); then
                mv -f "$cache.tmp" "$cache"
            else
                echo "(gagal membaca: $(cl_err_tail "$cache.err" 2))"
                rm -f "$cache.tmp"
            fi
            rm -f "$cache.err"
        )
    fi
    [[ -f "$cache" ]] && cat "$cache"
    return 0
}
