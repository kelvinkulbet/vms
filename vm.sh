#!/usr/bin/env bash
set -euo pipefail

# Enhanced Multi-VM Manager (KVM-aware, TCG fallback)
VERSION="1.1-noopenssl"

# Helper colors
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

print_status() {
  local type="$1"; local msg="$2"
  case "$type" in
    INFO)  echo -e "${BLUE}[INFO]${RESET} $msg" ;;
    WARN)  echo -e "${YELLOW}[WARN]${RESET} $msg" ;;
    ERROR) echo -e "${RED}[ERROR]${RESET} $msg" ;;
    SUCCESS) echo -e "${GREEN}[SUCCESS]${RESET} $msg" ;;
    INPUT) echo -e "${BLUE}[INPUT]${RESET} $msg" ;;
    *) echo -e "[${type}] $msg" ;;
  esac
}

validate_input() {
  local type="$1"; local value="$2"
  case "$type" in
    number) [[ "$value" =~ ^[0-9]+$ ]] || return 1 ;;
    size) [[ "$value" =~ ^[0-9]+[GgMm]$ ]] || return 1 ;;
    port) [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 23 ] && [ "$value" -le 65535 ] || return 1 ;;
    name) [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1 ;;
    username) [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1 ;;
  esac
  return 0
}

check_dependencies() {
  local deps=(wget qemu-img qemu-system-x86_64)
  local miss=()
  for d in "${deps[@]}"; do
    if ! command -v "$d" &>/dev/null; then
      miss+=("$d")
    fi
  done

  if [ ${#miss[@]} -ne 0 ]; then
    print_status "ERROR" "Missing dependencies: ${miss[*]}"
    print_status "INFO" "On Debian/Ubuntu try: sudo apt install -y qemu-system-x86 cloud-image-utils wget"
    exit 1
  fi

  if ! command -v cloud-localds &>/dev/null; then
    print_status "WARN" "cloud-localds not found. cloud-init seed creation may fail."
  fi
}

cleanup() { :; }
trap cleanup EXIT

VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

declare -A OS_OPTIONS=(
  ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
  ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
  ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
  ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
)

get_vm_list() {
  find "$VM_DIR" -maxdepth 1 -name "*.conf" -printf "%f\n" 2>/dev/null | sed 's/\.conf$//' | sort
}

load_vm_config() {
  local vm_name="$1"
  local conf="$VM_DIR/$vm_name.conf"
  [ -f "$conf" ] && source "$conf" && return 0 || return 1
}

save_vm_config() {
  local conf="$VM_DIR/$VM_NAME.conf"
  cat > "$conf" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
PORT_FORWARDS="$PORT_FORWARDS"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
EOF
  print_status "SUCCESS" "Saved config: $conf"
}

create_cloud_seed() {
  local seed="$1"; local userdata="$2"; local metadata="$3"
  if command -v cloud-localds &>/dev/null; then
    cloud-localds "$seed" "$userdata" "$metadata" && return 0
  fi
  if command -v genisoimage &>/dev/null; then
    genisoimage -output "$seed" -volid cidata -joliet -rock "$userdata" "$metadata" && return 0
  elif command -v mkisofs &>/dev/null; then
    mkisofs -output "$seed" -volid cidata -joliet -rock "$userdata" "$metadata" && return 0
  fi
  return 1
}

setup_vm_image() {
  print_status "INFO" "Preparing image for $VM_NAME..."
  IMG_FILE="$VM_DIR/$VM_NAME.img"
  SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
  CREATED="$(date)"

  if [ ! -f "$IMG_FILE" ]; then
    print_status "INFO" "Downloading $IMG_URL ..."
    wget -q --show-progress -O "$IMG_FILE.tmp" "$IMG_URL"
    mv -f "$IMG_FILE.tmp" "$IMG_FILE"
  else
    print_status "INFO" "Image exists, skipping download"
  fi

  qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null || print_status "WARN" "Resize failed"

  cat > "$VM_DIR/$VM_NAME-user-data" <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    password: $PASSWORD
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
EOF

  cat > "$VM_DIR/$VM_NAME-meta-data" <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

  create_cloud_seed "$SEED_FILE" "$VM_DIR/$VM_NAME-user-data" "$VM_DIR/$VM_NAME-meta-data"
  print_status "SUCCESS" "Image and cloud-init seed ready"
}

start_vm() {
  local vm="$1"
  load_vm_config "$vm" || { print_status "ERROR" "VM config not found"; return 1; }
  print_status "INFO" "Starting VM $vm (memory=${MEMORY}MB cpus=${CPUS})"

  local ACCEL_OPTS=()
  if [ -c /dev/kvm ] && [ -w /dev/kvm ]; then
    print_status "INFO" "KVM detected: using hardware acceleration"
    ACCEL_OPTS+=(-enable-kvm -cpu host)
  else
    print_status "WARN" "KVM not available: using software (TCG)"
    ACCEL_OPTS+=(-accel tcg)
  fi

  qemu-system-x86_64 "${ACCEL_OPTS[@]}" \
    -m "$MEMORY" -smp "$CPUS" \
    -drive "file=$IMG_FILE,if=virtio,format=qcow2" \
    -drive "file=$SEED_FILE,if=virtio,format=raw" \
    -device virtio-net-pci,netdev=n0 \
    -netdev "user,id=n0,hostfwd=tcp::${SSH_PORT}-:22" \
    -nographic -serial mon:stdio
}

delete_vm() {
  local vm="$1"
  load_vm_config "$vm" || { print_status "ERROR" "VM config not found"; return 1; }
  rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm.conf"
  print_status "SUCCESS" "Deleted VM $vm"
}

check_vm_specs() {
  echo "Available VMs:"
  mapfile -t vlist < <(get_vm_list)
  [ ${#vlist[@]} -eq 0 ] && { print_status "INFO" "No VMs found"; return; }

  for idx in "${!vlist[@]}"; do echo " $((idx+1))) ${vlist[$idx]}"; done
  read -rp "Select VM to inspect: " n
  n=$((n-1))
  local vm="${vlist[$n]}"
  load_vm_config "$vm" || { print_status "ERROR" "VM config not found"; return; }

  echo -e "${BLUE}========== VM SPECIFICATIONS ==========${RESET}"
  echo -e "${GREEN}Name:        ${RESET}${VM_NAME}"
  echo -e "${GREEN}OS Type:     ${RESET}${OS_TYPE^} (${CODENAME})"
  echo -e "${GREEN}CPUs:        ${RESET}${CPUS}"
  echo -e "${GREEN}Memory:      ${RESET}${MEMORY} MB"
  echo -e "${GREEN}Disk:        ${RESET}${DISK_SIZE}"
  echo -e "${GREEN}SSH Port:    ${RESET}${SSH_PORT}"
  echo -e "${GREEN}GUI Mode:    ${RESET}${GUI_MODE}"
  echo -e "${GREEN}Ports Fwd:   ${RESET}${PORT_FORWARDS:-None}"
  echo -e "${GREEN}Image Path:  ${RESET}${IMG_FILE}"
  echo -e "${GREEN}Seed Path:   ${RESET}${SEED_FILE}"
  echo -e "${GREEN}Created:     ${RESET}${CREATED}"
  echo -e "${BLUE}=======================================${RESET}"
}

test_vm_performance() {
  print_status "INFO" "Testing QEMU acceleration capability..."
  if [ -c /dev/kvm ] && [ -w /dev/kvm ]; then
    print_status "SUCCESS" "KVM available ✅"
  else
    print_status "WARN" "KVM not detected ❌"
  fi

  print_status "INFO" "Running quick disk benchmark..."
  start=$(date +%s)
  dd if=/dev/zero of=/tmp/testspeed.img bs=1M count=100 oflag=dsync 2> /tmp/speed.log || true
  end=$(date +%s)
  runtime=$((end - start))
  speed=$(grep -o '[0-9.]* MB/s' /tmp/speed.log | tail -1)

  echo -e "${BLUE}========== PERFORMANCE REPORT ==========${RESET}"
  echo -e "${GREEN}Runtime:     ${RESET}${runtime}s"
  echo -e "${GREEN}Disk Speed:  ${RESET}${speed:-N/A}"
  if [ -c /dev/kvm ]; then
    echo -e "${GREEN}Mode:        ${RESET}Hardware (KVM)"
    echo -e "${GREEN}Performance: ${RESET}⚡ High"
  else
    echo -e "${YELLOW}Mode:        ${RESET}Software (TCG)"
    echo -e "${YELLOW}Performance: ${RESET}⚠️ Moderate"
  fi
  echo -e "${BLUE}========================================${RESET}"
  rm -f /tmp/testspeed.img /tmp/speed.log
}

main_menu() {
  while true; do
    echo
    echo "=== Multi-VM Manager v${VERSION} ==="
    echo "1) Create VM"
    echo "2) Start VM"
    echo "3) Delete VM"
    echo "4) List VMs"
    echo "5) Check VM Specs"
    echo "6) Test Performance"
    echo "0) Exit"
    read -rp "Choice: " ch
    case "$ch" in
      1)
        echo "Select OS:"
        i=1; keys=()
        for k in "${!OS_OPTIONS[@]}"; do echo " $i) $k"; keys[$i]="$k"; i=$((i+1)); done
        read -rp "OS number: " oc
        OS_NAME="${keys[$oc]}"
        IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$OS_NAME]}"
        read -rp "VM name [$DEFAULT_HOSTNAME]: " VM_NAME; VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        read -rp "Hostname [$VM_NAME]: " HOSTNAME; HOSTNAME="${HOSTNAME:-$VM_NAME}"
        read -rp "Username [$DEFAULT_USERNAME]: " USERNAME; USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        read -rsp "Password [default]: " PASSWORD; echo; PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        read -rp "Disk size [20G]: " DISK_SIZE; DISK_SIZE="${DISK_SIZE:-20G}"
        read -rp "Memory MB [2048]: " MEMORY; MEMORY="${MEMORY:-2048}"
        read -rp "CPUs [2]: " CPUS; CPUS="${CPUS:-2}"
        read -rp "SSH port [2222]: " SSH_PORT; SSH_PORT="${SSH_PORT:-2222}"
        read -rp "Enable GUI? (y/N): " gui; GUI_MODE=false; [[ "$gui" =~ ^[Yy]$ ]] && GUI_MODE=true
        read -rp "Extra port forwards (host:guest,comma): " PORT_FORWARDS
        setup_vm_image
        save_vm_config
        ;;
      2)
        mapfile -t vlist < <(get_vm_list)
        [ ${#vlist[@]} -eq 0 ] && { print_status "INFO" "No VMs found"; continue; }
        for i in "${!vlist[@]}"; do echo " $((i+1))) ${vlist[$i]}"; done
        read -rp "Pick to start: " n; n=$((n-1))
        start_vm "${vlist[$n]}"
        ;;
      3)
        mapfile -t vlist < <(get_vm_list)
        for i in "${!vlist[@]}"; do echo " $((i+1))) ${vlist[$i]}"; done
        read -rp "Pick to delete: " n; n=$((n-1))
        delete_vm "${vlist[$n]}"
        ;;
      4) mapfile -t vlist < <(get_vm_list); for v in "${vlist[@]}"; do echo "- $v"; done ;;
      5) check_vm_specs ;;
      6) test_vm_performance ;;
      0) exit 0 ;;
      *) echo "Invalid" ;;
    esac
  done
}

check_dependencies
main_menu
