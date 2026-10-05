#!/bin/bash

LIST_FILE="scripts.env"

# Input OpenStack RC
read -rp "🔐 Masukkan path OpenStack RC file: " RC_FILE

# Expand ~ jika digunakan
RC_FILE="${RC_FILE/#\~/$HOME}"

# Validasi RC file
if [[ ! -f "$RC_FILE" ]]; then
    echo "❌ RC file tidak ditemukan: $RC_FILE"
    exit 1
fi

echo "🔑 Loading OpenStack RC: $RC_FILE"
source "$RC_FILE"

# Cek apakah credential berhasil digunakan
if ! openstack token issue >/dev/null 2>&1; then
    echo "❌ Gagal melakukan autentikasi OpenStack."
    echo "   Periksa isi RC file atau credential OpenStack."
    exit 1
fi

echo "✅ OpenStack authentication berhasil."
echo

# Cek scripts.env
if [[ ! -f "$LIST_FILE" ]]; then
    echo "❌ File $LIST_FILE tidak ditemukan!"
    exit 1
fi

declare -a names
declare -a paths

while IFS=',' read -r name path; do
    # Skip baris kosong
    [[ -z "$name" || -z "$path" ]] && continue

    # Trim whitespace
    name="$(echo "$name" | xargs)"
    path="$(echo "$path" | xargs)"

    names+=("$name")
    paths+=("$path")
done < "$LIST_FILE"

if [[ ${#names[@]} -eq 0 ]]; then
    echo "⚠️  Tidak ada script valid di $LIST_FILE!"
    exit 1
fi

echo "📜 Daftar script yang tersedia:"
echo

for i in "${!names[@]}"; do
    echo "  $((i+1)). ${names[$i]}"
done

echo
read -rp "➡️  Pilih nomor script untuk dijalankan: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || \
   (( choice < 1 || choice > ${#names[@]} )); then
    echo "❌ Pilihan tidak valid!"
    exit 1
fi

selected_name="${names[$((choice-1))]}"
selected_script="${paths[$((choice-1))]}"

echo
echo "✅ Script terpilih : $selected_name"
echo "📂 Lokasi          : $selected_script"
echo

if [[ -f "$selected_script" ]]; then
    echo "🚀 Menjalankan $selected_name..."
    echo

    bash "$selected_script"
else
    echo "⚠️  Script tidak ditemukan: $selected_script"
    exit 1
fi
