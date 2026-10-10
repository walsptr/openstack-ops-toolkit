#!/bin/bash
# ============================================================
# @name:        Floating IP Information
# @description: Look up a floating IP (or a list from a file, saved as CSV in /tmp) and show its project, domain, port, and server
# @mutates:     no
# @requires:    admin
# @tags:        neutron, floating-ip, port, server, project, domain, lookup, csv
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

echo "=========================================="
echo "       Get Floating IP Information"
echo "=========================================="
echo "1. Single Floating IP"
echo "2. Floating IP List (file -> CSV)"
echo "=========================================="

read -rp "Pilih mode [1-2]: " MODE

FLOATING_IPS=()
OUTPUT_FILE=""

case "$MODE" in

    1)
        read -rp "Masukkan Floating IP: " FLOATING_IP
        FLOATING_IP="$(echo "$FLOATING_IP" | xargs)"

        if [[ -z "$FLOATING_IP" ]]; then
            echo "Error: Floating IP tidak boleh kosong."
            exit 1
        fi

        FLOATING_IPS=("$FLOATING_IP")
        ;;

    2)
        read -rp "Masukkan path file list: " LIST_FILE

        if [[ ! -f "$LIST_FILE" || ! -r "$LIST_FILE" ]]; then
            echo "Error: File '$LIST_FILE' tidak ditemukan atau tidak bisa dibaca."
            exit 1
        fi

        while IFS= read -r FLOATING_IP || [[ -n "$FLOATING_IP" ]]; do

            # Remove leading/trailing whitespace (incl. CR from Windows files)
            FLOATING_IP="$(echo "${FLOATING_IP//$'\r'/}" | xargs)"

            # Skip empty lines and comments
            [[ -z "$FLOATING_IP" ]] && continue
            [[ "$FLOATING_IP" =~ ^# ]] && continue

            FLOATING_IPS+=("$FLOATING_IP")

        done < "$LIST_FILE"

        if [[ ${#FLOATING_IPS[@]} -eq 0 ]]; then
            echo "Error: Tidak ada Floating IP di dalam file."
            exit 1
        fi

        OUTPUT_FILE="/tmp/floating-ip-info-$(date +%Y%m%d-%H%M%S).csv"

        # Create the file without overwriting an existing one
        if ! ( set -o noclobber; : > "$OUTPUT_FILE" ) 2>/dev/null; then
            echo "Error: Gagal membuat output file: $OUTPUT_FILE"
            exit 1
        fi

        echo "Floating IP,Floating IP ID,Project ID,Project Name,Domain ID,Domain Name,Port ID,Server ID,Server Name" >> "$OUTPUT_FILE"
        echo "Output akan disimpan ke: $OUTPUT_FILE"
        ;;

    *)
        echo "Error: Pilihan tidak valid."
        exit 1
        ;;

esac


# ==========================================================
# Helpers
# ==========================================================

# Cache project/domain lookups so a long list does not repeat API calls
declare -A PROJECT_CACHE=()
declare -A DOMAIN_CACHE=()

# Quote a CSV field when it contains a comma, quote, or newline (RFC 4180)
csv_field() {
    local value="$1"

    if [[ "$value" == *[,\"$'\n']* ]]; then
        value="\"${value//\"/\"\"}\""
    fi

    printf '%s' "$value"
}

csv_row() {
    local first=1 field

    for field in "$@"; do
        [[ $first -eq 0 ]] && printf ','
        csv_field "$field"
        first=0
    done

    printf '\n'
    return 0
}

# Treat empty output and "None" as "-"
normalize() {
    local value="$1"

    if [[ -z "$value" || "$value" == "None" ]]; then
        value="-"
    fi

    printf '%s' "$value"
}


# ==========================================================
# Function: Get Floating IP Information
# Sets FLOATING_IP_ID, PROJECT_ID, PROJECT_NAME, DOMAIN_ID,
# DOMAIN_NAME, PORT_ID, SERVER_ID, SERVER_NAME
# ==========================================================

get_floating_ip_info() {

    local FLOATING_IP="$1"

    FLOATING_IP_ID="-"
    PROJECT_ID="-"
    PROJECT_NAME="-"
    DOMAIN_ID="-"
    DOMAIN_NAME="-"
    PORT_ID="-"
    SERVER_ID="-"
    SERVER_NAME="-"

    # Get Floating IP ID
    FLOATING_IP_ID=$(openstack floating ip list \
        --floating-ip-address "$FLOATING_IP" \
        -f value -c ID 2>/dev/null) || FLOATING_IP_ID=""

    if [[ -z "$FLOATING_IP_ID" ]]; then
        FLOATING_IP_ID="-"
        return 1
    fi

    # Get Project ID
    PROJECT_ID=$(openstack floating ip list \
        --floating-ip-address "$FLOATING_IP" \
        -f value -c Project 2>/dev/null) || PROJECT_ID=""
    PROJECT_ID="$(normalize "$PROJECT_ID")"

    # Get Project Name and Domain
    if [[ "$PROJECT_ID" != "-" ]]; then

        if [[ -z "${PROJECT_CACHE[$PROJECT_ID]+x}" ]]; then
            local name domain_id
            name=$(openstack project show "$PROJECT_ID" \
                -f value -c name 2>/dev/null) || name=""
            domain_id=$(openstack project show "$PROJECT_ID" \
                -f value -c domain_id 2>/dev/null) || domain_id=""
            PROJECT_CACHE[$PROJECT_ID]="$(normalize "$name")"$'\x1f'"$(normalize "$domain_id")"
        fi

        IFS=$'\x1f' read -r PROJECT_NAME DOMAIN_ID <<< "${PROJECT_CACHE[$PROJECT_ID]}"

        if [[ "$DOMAIN_ID" != "-" ]]; then

            if [[ -z "${DOMAIN_CACHE[$DOMAIN_ID]+x}" ]]; then
                local domain_name
                domain_name=$(openstack domain show "$DOMAIN_ID" \
                    -f value -c name 2>/dev/null) || domain_name=""
                DOMAIN_CACHE[$DOMAIN_ID]="$(normalize "$domain_name")"
            fi

            DOMAIN_NAME="${DOMAIN_CACHE[$DOMAIN_ID]}"
        fi
    fi

    # Get Port ID
    PORT_ID=$(openstack floating ip list \
        --floating-ip-address "$FLOATING_IP" \
        -f value -c Port 2>/dev/null) || PORT_ID=""
    PORT_ID="$(normalize "$PORT_ID")"

    # Get Server information
    if [[ "$PORT_ID" != "-" ]]; then

        SERVER_ID=$(openstack port show "$PORT_ID" \
            -f value -c device_id 2>/dev/null) || SERVER_ID=""
        SERVER_ID="$(normalize "$SERVER_ID")"

        if [[ "$SERVER_ID" != "-" ]]; then
            SERVER_NAME=$(openstack server show "$SERVER_ID" \
                -f value -c name 2>/dev/null) || SERVER_NAME=""
            SERVER_NAME="$(normalize "$SERVER_NAME")"
        fi
    fi

    return 0
}


# ==========================================================
# Process Floating IP
# ==========================================================

TOTAL=0
SUCCESS=0
FAILED=0

for FLOATING_IP in "${FLOATING_IPS[@]}"; do

    TOTAL=$((TOTAL + 1))

    echo
    echo "=========================================="
    echo "Processing: $FLOATING_IP"
    echo "=========================================="

    if ! get_floating_ip_info "$FLOATING_IP"; then

        echo "Error: Floating IP tidak ditemukan."

        if [[ -n "$OUTPUT_FILE" ]]; then
            csv_row "$FLOATING_IP" "NOT FOUND" "-" "-" "-" "-" "-" "-" "-" >> "$OUTPUT_FILE"
        fi

        FAILED=$((FAILED + 1))
        continue
    fi

    # Display to terminal
    echo
    echo "Floating IP      : $FLOATING_IP"
    echo "Floating IP ID   : $FLOATING_IP_ID"
    echo "Project ID       : $PROJECT_ID"
    echo "Project Name     : $PROJECT_NAME"
    echo "Domain ID        : $DOMAIN_ID"
    echo "Domain Name      : $DOMAIN_NAME"
    echo "Port ID          : $PORT_ID"
    echo "Server ID        : $SERVER_ID"
    echo "Server Name      : $SERVER_NAME"

    # Save to CSV
    if [[ -n "$OUTPUT_FILE" ]]; then
        csv_row "$FLOATING_IP" "$FLOATING_IP_ID" "$PROJECT_ID" "$PROJECT_NAME" \
            "$DOMAIN_ID" "$DOMAIN_NAME" "$PORT_ID" "$SERVER_ID" "$SERVER_NAME" >> "$OUTPUT_FILE"
    fi

    SUCCESS=$((SUCCESS + 1))

done


# ==========================================================
# Summary
# ==========================================================

echo
echo "=========================================="
echo "                  Summary"
echo "=========================================="
printf "%-16s : %s\n" "Total" "$TOTAL"
printf "%-16s : %s\n" "Success" "$SUCCESS"
printf "%-16s : %s\n" "Failed" "$FAILED"

if [[ -n "$OUTPUT_FILE" ]]; then
    printf "%-16s : %s\n" "Output File" "$OUTPUT_FILE"
fi

echo "=========================================="

# Single mode: non-zero exit when the lookup failed
if [[ -z "$OUTPUT_FILE" && $FAILED -gt 0 ]]; then
    exit 1
fi

exit 0
