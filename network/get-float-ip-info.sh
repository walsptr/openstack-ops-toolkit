#!/bin/bash

echo "=========================================="
echo "       Get Floating IP Information"
echo "=========================================="
echo "1. Single Floating IP"
echo "2. Floating IP List"
echo "=========================================="

read -rp "Pilih mode [1-2]: " MODE

case "$MODE" in

    1)
        read -rp "Masukkan Floating IP: " FLOATING_IP

        if [[ -z "$FLOATING_IP" ]]; then
            echo "Error: Floating IP tidak boleh kosong."
            exit 1
        fi

        FLOATING_IPS=("$FLOATING_IP")
        OUTPUT_FILE=""
        ;;

    2)
        read -rp "Masukkan path file list: " LIST_FILE

        if [[ ! -f "$LIST_FILE" ]]; then
            echo "Error: File '$LIST_FILE' tidak ditemukan."
            exit 1
        fi

        FLOATING_IPS=()

        while IFS= read -r FLOATING_IP || [[ -n "$FLOATING_IP" ]]; do

            # Remove leading/trailing whitespace
            FLOATING_IP=$(echo "$FLOATING_IP" | xargs)

            # Skip empty line
            [[ -z "$FLOATING_IP" ]] && continue

            # Skip comment
            [[ "$FLOATING_IP" =~ ^# ]] && continue

            FLOATING_IPS+=("$FLOATING_IP")

        done < "$LIST_FILE"

        if [[ ${#FLOATING_IPS[@]} -eq 0 ]]; then
            echo "Error: Tidak ada Floating IP di dalam file."
            exit 1
        fi

        echo
        read -rp "Simpan output ke file? [y/N]: " SAVE_OUTPUT

        if [[ "$SAVE_OUTPUT" =~ ^[Yy]$ ]]; then

            read -rp "Masukkan nama/path output file: " OUTPUT_FILE

            if [[ -z "$OUTPUT_FILE" ]]; then
                echo "Error: Output file tidak boleh kosong."
                exit 1
            fi

            # Create / truncate output file
            > "$OUTPUT_FILE"

            echo "Output akan disimpan ke: $OUTPUT_FILE"
        fi
        ;;

    *)
        echo "Error: Pilihan tidak valid."
        exit 1
        ;;

esac


# ==========================================================
# Function: Get Floating IP Information
# ==========================================================

get_floating_ip_info() {

    local FLOATING_IP="$1"

    # Get Floating IP ID
    FLOATING_IP_ID=$(openstack floating ip list \
        --floating-ip-address "$FLOATING_IP" \
        -f value -c ID 2>/dev/null)

    if [[ -z "$FLOATING_IP_ID" ]]; then
        return 1
    fi

    # Get Project ID
    PROJECT_ID=$(openstack floating ip list \
        --floating-ip-address "$FLOATING_IP" \
        -f value -c Project 2>/dev/null)

    # Get Project Name
    PROJECT_NAME=$(openstack project show "$PROJECT_ID" \
        -f value -c name 2>/dev/null)

    PROJECT_NAME=${PROJECT_NAME:-"-"}

    # Get Port ID
    PORT_ID=$(openstack floating ip list \
        --floating-ip-address "$FLOATING_IP" \
        -f value -c Port 2>/dev/null)

    SERVER_ID="-"
    SERVER_NAME="-"

    # Get Server information
    if [[ -n "$PORT_ID" && "$PORT_ID" != "None" ]]; then

        SERVER_ID=$(openstack port show "$PORT_ID" \
            -f value -c device_id 2>/dev/null)

        if [[ -n "$SERVER_ID" && "$SERVER_ID" != "None" ]]; then

            SERVER_NAME=$(openstack server show "$SERVER_ID" \
                -f value -c name 2>/dev/null)

            SERVER_NAME=${SERVER_NAME:-"-"}

        else
            SERVER_ID="-"
        fi

    else
        PORT_ID="-"
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

    ((TOTAL++))

    echo
    echo "=========================================="
    echo "Processing: $FLOATING_IP"
    echo "=========================================="

    if ! get_floating_ip_info "$FLOATING_IP"; then

        echo "Error: Floating IP tidak ditemukan."

        if [[ -n "$OUTPUT_FILE" ]]; then
            {
                echo "=========================================="
                echo "Floating IP      : $FLOATING_IP"
                echo "Status            : NOT FOUND"
                echo "=========================================="
                echo
            } >> "$OUTPUT_FILE"
        fi

        ((FAILED++))
        continue
    fi


    # ======================================================
    # Prepare Output
    # ======================================================

    RESULT=$(cat <<EOF
Floating IP      : $FLOATING_IP
Floating IP ID   : $FLOATING_IP_ID
Project ID       : $PROJECT_ID
Project Name     : $PROJECT_NAME
Port ID          : $PORT_ID
Server ID        : $SERVER_ID
Server Name      : $SERVER_NAME
EOF
)


    # Display to terminal
    echo
    echo "$RESULT"


    # Save to output file
    if [[ -n "$OUTPUT_FILE" ]]; then

        {
            echo "=========================================="
            echo "$RESULT"
            echo "=========================================="
            echo
        } >> "$OUTPUT_FILE"

    fi

    ((SUCCESS++))

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
