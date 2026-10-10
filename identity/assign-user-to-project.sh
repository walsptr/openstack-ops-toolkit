#!/bin/bash
# ============================================================
# @name:        Assign User to Project
# @description: Assign the member or admin role to a user on a project
# @mutates:     yes
# @requires:    admin
# @tags:        keystone, role, user, project
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
echo "     Assign User to OpenStack Project"
echo "========================================"
echo

# ============================================================
# Input User
# ============================================================

read -rp "User ID / Name    : " USER

if [[ -z "$USER" ]]; then
    echo "❌ User tidak boleh kosong."
    log_error -q "input tidak valid: user kosong"
    exit 1
fi

# ============================================================
# Input Project
# ============================================================

read -rp "Project ID / Name : " PROJECT

if [[ -z "$PROJECT" ]]; then
    echo "❌ Project tidak boleh kosong."
    log_error -q "input tidak valid: project kosong"
    exit 1
fi

# ============================================================
# Select Role
# ============================================================

echo
echo "Available roles:"
echo
echo "  1. member"
echo "  2. admin"
echo

read -rp "Select role [1-2]: " ROLE_CHOICE

case "$ROLE_CHOICE" in
    1)
        ROLE="member"
        ;;
    2)
        ROLE="admin"
        ;;
    *)
        echo "❌ Pilihan role tidak valid."
        log_error -q "input tidak valid: pilihan role '$ROLE_CHOICE'"
        exit 1
        ;;
esac

log_event INPUT "user=$USER" "project=$PROJECT" "role=$ROLE"

# ============================================================
# Confirmation
# ============================================================

echo
echo "========================================"
echo "Assignment Summary"
echo "========================================"
echo
echo "User    : $USER"
echo "Project : $PROJECT"
echo "Role    : $ROLE"
echo

read -rp "Continue? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Operation cancelled."
    log_result "resource=$USER" "project=$PROJECT" "role=$ROLE" action=assign-role result=DECLINED
    exit 0
fi

# ============================================================
# Assign Role
# ============================================================

echo
echo "🚀 Assigning role..."

if log_run openstack role add \
    --user "$USER" \
    --project "$PROJECT" \
    "$ROLE"; then

    log_result "resource=$USER" "project=$PROJECT" "role=$ROLE" action=assign-role result=SUCCESS

    echo
    echo "✅ Role successfully assigned."
    echo
    echo "User    : $USER"
    echo "Project : $PROJECT"
    echo "Role    : $ROLE"

else

    echo
    log_result "resource=$USER" "project=$PROJECT" "role=$ROLE" action=assign-role result=FAILED \
        "msg=$LOG_LAST_ERROR"

    echo "❌ Failed to assign role."
    exit 1

fi
