#!/bin/bash
# ============================================================
# @name:        Import Volume from NetApp
# @description: Bring an existing NetApp volume under Cinder management (cinder manage)
# @mutates:     yes
# @requires:    admin, cinder
# @tags:        cinder, volume, netapp, manage, import
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

echo "========================================"
echo "       Cinder Manage Volume"
echo "========================================"
echo

# ============================================================
# Get Volume Types
# ============================================================

echo "Loading volume types..."

mapfile -t VOLUME_TYPES < <(
    openstack volume type list -f value -c Name
)

if [[ ${#VOLUME_TYPES[@]} -eq 0 ]]; then
    echo "❌ Tidak ada volume type yang ditemukan."
    log_error -q "tidak ada volume type yang ditemukan"
    exit 1
fi

echo
echo "Available Volume Types:"
echo

for i in "${!VOLUME_TYPES[@]}"; do
    echo "  $((i + 1)). ${VOLUME_TYPES[$i]}"
done

echo

read -rp "Pilih Volume Type [1-${#VOLUME_TYPES[@]}]: " TYPE_CHOICE

if ! [[ "$TYPE_CHOICE" =~ ^[0-9]+$ ]] || \
   (( TYPE_CHOICE < 1 || TYPE_CHOICE > ${#VOLUME_TYPES[@]} )); then
    echo "❌ Pilihan volume type tidak valid."
    log_error -q "input tidak valid: pilihan volume type '$TYPE_CHOICE'"
    exit 1
fi

VOLUME_TYPE="${VOLUME_TYPES[$((TYPE_CHOICE - 1))]}"

# ============================================================
# Get Cinder Pools
# ============================================================

echo
echo "Loading Cinder pools..."

mapfile -t CINDER_POOLS < <(
    cinder get-pools 2>/dev/null |
    awk -F'|' '
        /^\| name[[:space:]]+\|/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $3)
            if ($3 != "") print $3
        }
    '
)

if [[ ${#CINDER_POOLS[@]} -eq 0 ]]; then
    echo "❌ Tidak ada Cinder pool yang ditemukan."
    log_error -q "tidak ada Cinder pool yang ditemukan"
    exit 1
fi

echo
echo "Available Cinder Pools:"
echo

for i in "${!CINDER_POOLS[@]}"; do
    echo "  $((i + 1)). ${CINDER_POOLS[$i]}"
done

echo

read -rp "Pilih Cinder Pool [1-${#CINDER_POOLS[@]}]: " POOL_CHOICE

if ! [[ "$POOL_CHOICE" =~ ^[0-9]+$ ]] || \
   (( POOL_CHOICE < 1 || POOL_CHOICE > ${#CINDER_POOLS[@]} )); then
    echo "❌ Pilihan Cinder pool tidak valid."
    log_error -q "input tidak valid: pilihan Cinder pool '$POOL_CHOICE'"
    exit 1
fi

CINDER_POOL="${CINDER_POOLS[$((POOL_CHOICE - 1))]}"

# ============================================================
# Input NetApp Path
# ============================================================

echo
read -rp "NetApp source path: " SOURCE_PATH

if [[ -z "$SOURCE_PATH" ]]; then
    echo "❌ NetApp source path tidak boleh kosong."
    log_error -q "input tidak valid: NetApp source path kosong"
    exit 1
fi

log_event INPUT "volume_type=$VOLUME_TYPE" "pool=$CINDER_POOL" id_type=source-name "source_path=$SOURCE_PATH"

# ============================================================
# Confirmation
# ============================================================

echo
echo "========================================"
echo "Cinder Manage Summary"
echo "========================================"
echo
echo "Volume Type : $VOLUME_TYPE"
echo "Cinder Pool : $CINDER_POOL"
echo "ID Type     : source-name"
echo "Source Path : $SOURCE_PATH"
echo

read -rp "Continue? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Operation cancelled."
    log_result "resource=$SOURCE_PATH" "pool=$CINDER_POOL" "volume_type=$VOLUME_TYPE" \
        action=cinder-manage result=DECLINED
    exit 0
fi

# ============================================================
# Execute
# ============================================================

echo
echo "🚀 Running cinder manage..."

if log_run cinder manage \
    --volume-type "$VOLUME_TYPE" \
    --id-type source-name \
    "$CINDER_POOL" \
    "$SOURCE_PATH"; then

    log_result "resource=$SOURCE_PATH" "pool=$CINDER_POOL" "volume_type=$VOLUME_TYPE" \
        action=cinder-manage result=SUCCESS

else

    RC=$?
    log_result "resource=$SOURCE_PATH" "pool=$CINDER_POOL" "volume_type=$VOLUME_TYPE" \
        action=cinder-manage result=FAILED "msg=$LOG_LAST_ERROR"
    exit "$RC"

fi

echo
echo "✅ Cinder manage completed."
