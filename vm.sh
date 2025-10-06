#!/bin/bash
# 🖥️ QEMU VM Manager (Simulation Mode for Google IDX)
# Versi: 1.1 (Simulasi dengan penyimpanan JSON)
# Semua aksi QEMU hanya disimulasikan.

VERSION="1.1"
VM_DATA_FILE="vms.json"

# Warna terminal
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

# Banner tampilan
banner() {
  clear
  echo -e "${BLUE}"
  echo "=========================================="
  echo "   🖥️  QEMU VM Manager - Simulation Mode   "
  echo "=========================================="
  echo -e "${RESET}"
  echo "Version: $VERSION"
  echo
}

# Fungsi membuat file data jika belum ada
init_data_file() {
  if [ ! -f "$VM_DATA_FILE" ]; then
    echo "[]" > "$VM_DATA_FILE"
  fi
}

# Fungsi loading simulasi
simulate_action() {
  local action="$1"
  echo -ne "${YELLOW}[INFO]${RESET} $action"
  for i in {1..3}; do
    echo -n "."
    sleep 0.4
  done
  echo -e " ${GREEN}Done!${RESET}"
  sleep 0.4
}

# Fungsi menambah data VM ke JSON
add_vm() {
  local name="$1"
  local id
  id=$(date +%s)
  local new_entry="{\"id\": $id, \"name\": \"$name\", \"status\": \"stopped\"}"
  local updated
  updated=$(jq ". + [$new_entry]" "$VM_DATA_FILE")
  echo "$updated" > "$VM_DATA_FILE"
}

# Fungsi menghapus VM
delete_vm() {
  local name="$1"
  local updated
  updated=$(jq "map(select(.name != \"$name\"))" "$VM_DATA_FILE")
  echo "$updated" > "$VM_DATA_FILE"
}

# Fungsi ubah status VM
update_vm_status() {
  local name="$1"
  local new_status="$2"
  local updated
  updated=$(jq "map(if .name == \"$name\" then .status = \"$new_status\" else . end)" "$VM_DATA_FILE")
  echo "$updated" > "$VM_DATA_FILE"
}

# Fungsi lihat daftar VM
list_vms() {
  banner
  if [ "$(jq length "$VM_DATA_FILE")" -eq 0 ]; then
    echo "Belum ada VM terdaftar."
  else
    jq -r '.[] | "• \(.name) [status: \(.status)]"' "$VM_DATA_FILE"
  fi
  echo
  read -rp "Tekan Enter untuk kembali ke menu..." _
}

# Menu utama
menu() {
  banner
  echo "Pilih opsi:"
  echo "1) Buat VM baru"
  echo "2) Jalankan VM"
  echo "3) Hentikan VM"
  echo "4) Hapus VM"
  echo "5) Lihat daftar VM"
  echo "6) Info sistem"
  echo "0) Keluar"
  echo
  read -rp "Pilih: " choice

  case $choice in
    1)
      read -rp "Masukkan nama VM: " vmname
      simulate_action "Membuat VM '$vmname'"
      add_vm "$vmname"
      echo "[SIMULATION] VM '$vmname' dibuat dan tersimpan."
      ;;
    2)
      read -rp "Masukkan nama VM: " vmname
      simulate_action "Menjalankan VM '$vmname' (mode TCG)"
      update_vm_status "$vmname" "running"
      echo "[SIMULATION] VM '$vmname' sedang berjalan."
      ;;
    3)
      read -rp "Masukkan nama VM: " vmname
      simulate_action "Menghentikan VM '$vmname'"
      update_vm_status "$vmname" "stopped"
      echo "[SIMULATION] VM '$vmname' dihentikan."
      ;;
    4)
      read -rp "Masukkan nama VM yang ingin dihapus: " vmname
      simulate_action "Menghapus VM '$vmname'"
      delete_vm "$vmname"
      echo "[SIMULATION] VM '$vmname' dihapus dari data."
      ;;
    5)
      list_vms
      ;;
    6)
      simulate_action "Mengambil info sistem"
      echo "Environment: Google IDX (sandbox)"
      echo "KVM Support: ❌ Tidak tersedia"
      echo "Virtualisasi: Emulasi software (simulasi)"
      echo "Data file: $VM_DATA_FILE"
      ;;
    0)
      echo "Keluar..."
      exit 0
      ;;
    *)
      echo -e "${RED}Pilihan tidak valid.${RESET}"
      ;;
  esac

  echo
  read -rp "Tekan Enter untuk kembali ke menu..." _
  menu
}

# Inisialisasi dan jalankan
init_data_file
menu
