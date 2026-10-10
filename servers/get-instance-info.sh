#!/bin/bash
# ============================================================
# @name:        Instances Information
# @description: Show instance name, project, and domain for an instance ID (or a list from a file, saved as CSV in /tmp)
# @mutates:     no
# @requires:    admin
# @tags:        nova, server, instance, project, domain, lookup, csv
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

# Logging terpusat (lib/logging.sh)
# shellcheck source=../lib/logging.sh
if ! source "${OSOPS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/logging.sh" 2>/dev/null; then
    echo "❌ lib/logging.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi
log_init

echo "=========================================="
echo "       OpenStack Instance Info"
echo "=========================================="
echo "1. Single Instance ID"
echo "2. Instance ID List (file -> CSV)"
echo "=========================================="

read -rp "Pilih mode [1-2]: " MODE

INSTANCE_IDS=()
OUTPUT_FILE=""

case "$MODE" in

    1)
        read -rp "Instance ID: " INSTANCE_ID
        INSTANCE_ID="$(echo "$INSTANCE_ID" | xargs)"

        if [[ -z "$INSTANCE_ID" ]]; then
            echo "❌ Instance ID tidak boleh kosong."
            log_error -q "input tidak valid: Instance ID kosong"
            exit 1
        fi

        INSTANCE_IDS=("$INSTANCE_ID")
        log_event INPUT mode=single "instance_id=$INSTANCE_ID"
        ;;

    2)
        read -rp "Masukkan path file list: " LIST_FILE

        if [[ ! -f "$LIST_FILE" || ! -r "$LIST_FILE" ]]; then
            echo "❌ File '$LIST_FILE' tidak ditemukan atau tidak bisa dibaca."
            log_error -q "input file tidak ditemukan atau tidak bisa dibaca: $LIST_FILE"
            exit 1
        fi

        while IFS= read -r INSTANCE_ID || [[ -n "$INSTANCE_ID" ]]; do

            # Remove leading/trailing whitespace (incl. CR from Windows files)
            INSTANCE_ID="$(echo "${INSTANCE_ID//$'\r'/}" | xargs)"

            # Skip empty lines and comments
            [[ -z "$INSTANCE_ID" ]] && continue
            [[ "$INSTANCE_ID" =~ ^# ]] && continue

            INSTANCE_IDS+=("$INSTANCE_ID")

        done < "$LIST_FILE"

        if [[ ${#INSTANCE_IDS[@]} -eq 0 ]]; then
            echo "❌ Tidak ada Instance ID di dalam file."
            log_error -q "tidak ada Instance ID di dalam file: $LIST_FILE"
            exit 1
        fi

        OUTPUT_FILE="/tmp/instance-info-$(date +%Y%m%d-%H%M%S).csv"

        # Create the file without overwriting an existing one
        if ! ( set -o noclobber; : > "$OUTPUT_FILE" ) 2>/dev/null; then
            echo "❌ Gagal membuat output file: $OUTPUT_FILE"
            log_error -q "gagal membuat output file: $OUTPUT_FILE"
            exit 1
        fi

        echo "Instance ID,Instance Name,Project ID,Project Name,Domain ID,Domain Name" >> "$OUTPUT_FILE"
        echo "Output akan disimpan ke: $OUTPUT_FILE"
        log_event INPUT mode=list "input_file=$LIST_FILE" "count=${#INSTANCE_IDS[@]}" "output_file=$OUTPUT_FILE"
        ;;

    *)
        echo "❌ Pilihan tidak valid."
        log_error -q "input tidak valid: mode '$MODE'"
        exit 1
        ;;

esac

# ============================================================
# Helpers
# ============================================================

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

# Sets INSTANCE_NAME, PROJECT_ID, PROJECT_NAME, DOMAIN_ID, DOMAIN_NAME
get_instance_info() {
    local instance_id="$1"

    INSTANCE_NAME="-"
    PROJECT_ID="-"
    PROJECT_NAME="-"
    DOMAIN_ID="-"
    DOMAIN_NAME="-"

    INSTANCE_NAME="$(openstack server show "$instance_id" -f value -c name 2>/dev/null)" || return 1
    PROJECT_ID="$(openstack server show "$instance_id" -f value -c project_id 2>/dev/null)" || return 1

    INSTANCE_NAME="${INSTANCE_NAME:--}"
    PROJECT_ID="${PROJECT_ID:--}"
    [[ "$PROJECT_ID" == "-" ]] && return 0

    if [[ -z "${PROJECT_CACHE[$PROJECT_ID]+x}" ]]; then
        local name domain_id
        name="$(openstack project show "$PROJECT_ID" -f value -c name 2>/dev/null)" || name="-"
        domain_id="$(openstack project show "$PROJECT_ID" -f value -c domain_id 2>/dev/null)" || domain_id="-"
        PROJECT_CACHE[$PROJECT_ID]="${name:--}"$'\x1f'"${domain_id:--}"
    fi

    IFS=$'\x1f' read -r PROJECT_NAME DOMAIN_ID <<< "${PROJECT_CACHE[$PROJECT_ID]}"
    [[ "$DOMAIN_ID" == "-" ]] && return 0

    if [[ -z "${DOMAIN_CACHE[$DOMAIN_ID]+x}" ]]; then
        local domain_name
        domain_name="$(openstack domain show "$DOMAIN_ID" -f value -c name 2>/dev/null)" || domain_name="-"
        DOMAIN_CACHE[$DOMAIN_ID]="${domain_name:--}"
    fi

    DOMAIN_NAME="${DOMAIN_CACHE[$DOMAIN_ID]}"
    return 0
}

# ============================================================
# Process instances
# ============================================================

TOTAL=0
SUCCESS=0
FAILED=0

for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do

    TOTAL=$((TOTAL + 1))

    echo
    echo "=========================================="
    echo "Processing: $INSTANCE_ID"
    echo "=========================================="

    if ! get_instance_info "$INSTANCE_ID"; then

        echo "❌ Gagal mendapatkan informasi instance (tidak ditemukan atau tidak ada akses)."
        log_result "resource=$INSTANCE_ID" action=lookup result=FAILED msg="tidak ditemukan atau tidak ada akses"

        if [[ -n "$OUTPUT_FILE" ]]; then
            csv_row "$INSTANCE_ID" "NOT FOUND" "-" "-" "-" "-" >> "$OUTPUT_FILE"
        fi

        FAILED=$((FAILED + 1))
        continue
    fi

    echo "Instance ID   : $INSTANCE_ID"
    echo "Instance Name : $INSTANCE_NAME"
    echo "Project ID    : $PROJECT_ID"
    echo "Project Name  : $PROJECT_NAME"
    echo "Domain ID     : $DOMAIN_ID"
    echo "Domain Name   : $DOMAIN_NAME"

    if [[ -n "$OUTPUT_FILE" ]]; then
        csv_row "$INSTANCE_ID" "$INSTANCE_NAME" "$PROJECT_ID" "$PROJECT_NAME" "$DOMAIN_ID" "$DOMAIN_NAME" >> "$OUTPUT_FILE"
    fi

    log_result "resource=$INSTANCE_ID" action=lookup result=SUCCESS \
        "project_id=$PROJECT_ID" "domain_id=$DOMAIN_ID"

    SUCCESS=$((SUCCESS + 1))

done

# ============================================================
# Summary
# ============================================================

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

log_event SUMMARY "total=$TOTAL" "success=$SUCCESS" "failed=$FAILED" "output_file=${OUTPUT_FILE:--}"

# Single mode keeps the old behavior: non-zero exit when the lookup failed
if [[ -z "$OUTPUT_FILE" && $FAILED -gt 0 ]]; then
    exit 1
fi

exit 0
