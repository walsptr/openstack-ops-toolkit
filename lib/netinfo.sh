#!/bin/bash
# shellcheck disable=SC2034  # NETINFO_JQ dibaca oleh script pemanggil
# ============================================================
# OpenStack Ops Toolkit - shared helper: alamat IP, CIDR, label device port
# ============================================================
#
# Di-source oleh operational scripts SETELAH lib/logging.sh (tidak punya
# @name, lib/ tidak ikut discovery). Tidak memanggil OpenStack CLI.
#
#   ip_normalize IP          cetak bentuk kanonik (IPv4 apa adanya, IPv6 huruf
#                            kecil + kompresi RFC 5952); return 1 = tidak valid
#   ip4_valid IP             IPv4 dotted-quad, tanpa leading zero
#   ip4_in_cidr IP CIDR      IPv4 di dalam CIDR (alamat tanpa /n = /32)
#   device_label OWNER [SERVER_NAME]
#                            label device dari device_owner port (lihat
#                            device_type di NETINFO_JQ)
#
# NETINFO_JQ: definisi jq yang sama untuk dipakai di program jq script
# (prefix filter: jq "$NETINFO_JQ"'...'):
#   ip4_int, is_ip4, cidr4_contains($ip), in_pools($ip), device_type($owner; $name)
#
# Satu sumber kebenaran: fungsi bash device_label memanggil device_type di
# NETINFO_JQ, jadi label di terminal, CSV, dan script lain selalu sama.

[[ -n "${_OSOPS_NETINFO_LOADED:-}" ]] && return 0
_OSOPS_NETINFO_LOADED=1

# shellcheck disable=SC2016  # program jq, bukan ekspansi shell
NETINFO_JQ='
def is_ip4: type == "string" and test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$");
def ip4_int: split(".") | map(tonumber) | ((.[0] * 256 + .[1]) * 256 + .[2]) * 256 + .[3];
# . = "a.b.c.d/n" atau "a.b.c.d"; hanya IPv4 (IPv6 → false)
def cidr4_contains($ip):
  (split("/")) as $p
  | if ($p[0] | is_ip4) and ($ip | is_ip4) then
      ((if ($p | length) > 1 then ($p[1] | tonumber? // -1) else 32 end)) as $len
      | if $len < 0 or $len > 32 then false
        else pow(2; 32 - $len) as $size
             | ((($p[0] | ip4_int) / $size) | floor) == ((($ip | ip4_int) / $size) | floor)
        end
    else false end;
# . = allocation_pools: [{start, end}] (API / OSC -f json) atau "a-b,c-d" (string)
def in_pools($ip):
  (if type == "string" then
     [ split(",")[] | select(length > 0) | split("-") | { start: .[0], end: .[1] } ]
   else (. // []) end) as $pools
  | ($ip | is_ip4) and any($pools[]; ((.start // "") | is_ip4) and ((.end // "") | is_ip4)
        and (.start | ip4_int) <= ($ip | ip4_int) and ($ip | ip4_int) <= (.end | ip4_int));
# Label device dari device_owner (compute:<az> dicocokkan dengan prefix)
def device_type($owner; $name):
  if $owner == "" then "Unattached port"
  elif ($owner | startswith("compute:")) then
    (if ($name | startswith("amphora-")) then "Load balancer amphora" else "Instance" end)
  elif $owner == "network:router_gateway" then "Router gateway"
  elif ($owner | IN("network:router_interface", "network:router_interface_distributed",
                    "network:ha_router_replicated_interface")) then "Router interface"
  elif $owner == "network:dhcp" then "DHCP"
  elif $owner == "network:floatingip_agent_gateway" then "DVR FIP gateway"
  elif $owner == "Octavia" then "Load balancer VIP"
  elif $owner == "network:distributed" then "Distributed (metadata)"
  else $owner end;
'

ip4_valid() {
    local o='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    [[ "$1" =~ ^$o\.$o\.$o\.$o$ ]]
}

# _ip6_groups TEXT ARRAYNAME — pisah grup hex (1-4 digit); return 1 = tidak valid
_ip6_groups() {
    local -n _out="$2"
    local _grp
    _out=()
    [[ -z "$1" ]] && return 0
    local -a parts=()
    IFS=: read -ra parts <<< "$1"
    # read membuang field kosong di akhir: "1:" harus tetap ditolak
    [[ "$1" == *: ]] && return 1
    for _grp in "${parts[@]}"; do
        [[ "$_grp" =~ ^[0-9a-f]{1,4}$ ]] || return 1
        _out+=("$(( 16#$_grp ))")
    done
    return 0
}

ip6_canonical() {
    local s="${1,,}" v4 head tail i n best_i=-1 best_n=0 run_i=-1 run_n=0 out=""
    local -a hg=() tg=() g=() o=()

    # Embedded IPv4 di akhir (::ffff:1.2.3.4) → dua grup hex
    if [[ "$s" == *.* ]]; then
        v4="${s##*:}"
        ip4_valid "$v4" || return 1
        IFS=. read -ra o <<< "$v4"
        s="${s%:*}:$(printf '%x:%x' $(( o[0] * 256 + o[1] )) $(( o[2] * 256 + o[3] )))"
    fi

    [[ "$s" =~ ^[0-9a-f:]+$ ]] || return 1
    [[ "$s" == *::*::* || "$s" == *:::* ]] && return 1
    [[ "$s" == :* && "$s" != ::* ]] && return 1
    [[ "$s" == *: && "$s" != *:: ]] && return 1

    if [[ "$s" == *::* ]]; then
        head="${s%%::*}"
        tail="${s#*::}"
        _ip6_groups "$head" hg || return 1
        _ip6_groups "$tail" tg || return 1
        n=$(( 8 - ${#hg[@]} - ${#tg[@]} ))
        (( n >= 1 )) || return 1
        g=("${hg[@]}")
        for (( i = 0; i < n; i++ )); do g+=(0); done
        g+=("${tg[@]}")
    else
        _ip6_groups "$s" g || return 1
        (( ${#g[@]} == 8 )) || return 1
    fi

    # Run nol terpanjang (>= 2 grup, paling kiri) dikompresi menjadi ::
    for (( i = 0; i <= 8; i++ )); do
        if (( i < 8 && g[i] == 0 )); then
            (( run_i < 0 )) && { run_i=$i; run_n=0; }
            run_n=$(( run_n + 1 ))
        else
            if (( run_i >= 0 && run_n > best_n )); then best_i=$run_i; best_n=$run_n; fi
            run_i=-1
        fi
    done
    (( best_n < 2 )) && best_i=-1

    for (( i = 0; i < 8; i++ )); do
        if (( i == best_i )); then
            out+="::"
            i=$(( i + best_n - 1 ))
            continue
        fi
        [[ -n "$out" && "$out" != *: ]] && out+=":"
        out+="$(printf '%x' "${g[$i]}")"
    done
    printf '%s' "$out"
}

ip_normalize() {
    if ip4_valid "$1"; then
        printf '%s' "$1"
    elif [[ "$1" == *:* ]]; then
        ip6_canonical "$1"
    else
        return 1
    fi
}

ip4_in_cidr() {
    local ip="$1" net="${2%%/*}" len=32 a b c d mask x y
    [[ "$2" == */* ]] && len="${2#*/}"
    ip4_valid "$ip" && ip4_valid "$net" && [[ "$len" =~ ^[0-9]+$ ]] && (( len <= 32 )) || return 1
    IFS=. read -r a b c d <<< "$ip"
    x=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    IFS=. read -r a b c d <<< "$net"
    y=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    mask=$(( len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
    (( (x & mask) == (y & mask) ))
}

device_label() {
    jq -nr --arg o "$1" --arg n "${2:-}" "$NETINFO_JQ"' device_type($o; $n)'
}
