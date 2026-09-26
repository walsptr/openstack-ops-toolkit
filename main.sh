#!/bin/bash
source ~/overcloudrc
LIST_FILE="scripts.env"

# Cek apakah file list-script.txt ada
if [ ! -f "$LIST_FILE" ]; then
  echo "❌ File $LIST_FILE tidak ditemukan!"
  exit 1
fi

# Baca file baris per baris
declare -a names
declare -a paths

while IFS=',' read -r name path; do
  # Skip baris kosong atau tidak valid
  [[ -z "$name" || -z "$path" ]] && continue
  names+=("$name")
  paths+=("$path")
done < "$LIST_FILE"

# Jika tidak ada script yang terbaca
if [ ${#names[@]} -eq 0 ]; then
  echo "⚠️  Tidak ada script valid di $LIST_FILE!"
  exit 1
fi

# Tampilkan daftar script
echo "📜 Daftar script yang tersedia:"
for i in "${!names[@]}"; do
  echo "  $((i+1)). ${names[$i]}"
done

echo
read -p "➡️  Pilih nomor script untuk dijalankan: " choice

# Validasi input
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#names[@]} )); then
  echo "❌ Pilihan tidak valid!"
  exit 1
fi

selected_name="${names[$((choice-1))]}"
selected_script="${paths[$((choice-1))]}"

echo "✅ Script terpilih: $selected_name"
echo "📂 Lokasi: $selected_script"
echo

# Jalankan script (tidak perlu permission eksekusi, cukup bisa dibaca)
if [ -f "$selected_script" ]; then
  echo "🚀 Menjalankan $selected_name..."
  bash "$selected_script"
else
  echo "⚠️  Script tidak ditemukan: $selected_script"
fi

