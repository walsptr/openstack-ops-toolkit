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
    exit 1
fi

# ============================================================
# Input Project
# ============================================================

read -rp "Project ID / Name : " PROJECT

if [[ -z "$PROJECT" ]]; then
    echo "❌ Project tidak boleh kosong."
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
        exit 1
        ;;
esac

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
    exit 0
fi

# ============================================================
# Assign Role
# ============================================================

echo
echo "🚀 Assigning role..."

if openstack role add \
    --user "$USER" \
    --project "$PROJECT" \
    "$ROLE"; then

    echo
    echo "✅ Role successfully assigned."
    echo
    echo "User    : $USER"
    echo "Project : $PROJECT"
    echo "Role    : $ROLE"

else

    echo
    echo "❌ Failed to assign role."
    exit 1

fi
