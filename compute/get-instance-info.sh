#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# ============================================================
# OpenStack Instance Information
# ============================================================

read -rp "Instance ID: " INSTANCE_ID

if [[ -z "$INSTANCE_ID" ]]; then
    echo "❌ Instance ID tidak boleh kosong."
    exit 1
fi

# ============================================================
# Get instance information
# ============================================================

INSTANCE_NAME="$(openstack server show "$INSTANCE_ID" -f value -c name 2>/dev/null)" || {
    echo "❌ Gagal mendapatkan informasi instance."
    echo "   Instance ID: $INSTANCE_ID"
    exit 1
}

PROJECT_ID="$(openstack server show "$INSTANCE_ID" -f value -c project_id 2>/dev/null)" || {
    echo "❌ Gagal mendapatkan Project ID."
    exit 1
}

PROJECT_NAME="$(openstack project show "$PROJECT_ID" -f value -c name 2>/dev/null)" || {
    echo "❌ Gagal mendapatkan Project Name."
    exit 1
}

# ============================================================
# Display result
# ============================================================

echo
echo "========================================"
echo "       OpenStack Instance Info"
echo "========================================"
echo
echo "Instance ID   : $INSTANCE_ID"
echo "Instance Name : $INSTANCE_NAME"
echo "Project ID    : $PROJECT_ID"
echo "Project Name  : $PROJECT_NAME"
echo
