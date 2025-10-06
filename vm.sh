#!/usr/bin/env bash
set -euo pipefail

# Enhanced Multi-VM Manager (KVM-aware, TCG fallback)
VERSION="1.0-fixed"

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

# Validate simple patterns
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

# Dependencies check (but allow running with TCG if KVM not available)
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
    print_status "INFO" "On Debian/Ubuntu try: sudo apt update && sudo apt install -y qemu-system-x86 cloud-image-utils wget"
    exit 1
  fi

  # cloud-localds is provided by cloud-image-utils, but check presence
  if ! command -v cloud-localds &>/dev/null; then
    print_status "WARN" "cloud-localds not found. cloud-init seed creation may fail (cloud-image-utils required)."
  fi
}

# Cleanup seed files on exit
cleanup() {
  : # no-op for now (we leave files), but reserved
}
trap cleanup EXIT

# Helpers: VM storage dir
VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

# OS options
declare -A OS_OPTIONS=(
  ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
  ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
  ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
  ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
)

# Get VM list
get_vm_list() {
  find "$VM_DIR" -maxdepth 1 -name "*.conf" -printf "%f\n" 2>/dev/null | sed 's/\.conf$//' | sort
}

# Load config
load_vm_config() {
  local vm_name="$1"
  local conf="$VM_DIR/$vm_name.conf"
  if [ -f "$conf" ]; then
    # shellcheck disable=SC1090
    source "$conf"
    return 0
  else
    return 1
  fi
}

# Save config
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

# Create cloud-init seed (tries cloud-localds, falls back to genisoimage if available)
create_cloud_seed() {
  local seed="$1"
  local userdata="$2"
  local metadata="$3"
  if command -v cloud-localds &>/dev/null; then
    cloud-localds "$seed" "$userdata" "$metadata"
    return $?
  fi

  # fallback: try mkisofs/genisoimage or genisoimage from cdrkit
  if command -v genisoimage &>/dev/null; then
    genisoimage -output "$seed" -volid cidata -joliet -rock "$userdata" "$metadata"
    return $?
  elif command -v mkisofs &>/dev/null; then
    mkisofs -output "$seed" -volid cidata -joliet -rock "$userdata" "$metadata"
    return $?
  else
    return 1
  fi
}

# Setup VM image (download + resize + seed)
setup_vm_image() {
  print_status "INFO" "Preparing image for $VM_NAME..."
  mkdir -p "$VM_DIR"
  IMG_FILE="$VM_DIR/$VM_NAME.img"
  SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
  CREATED="$(date)"

  if [ ! -f "$IMG_FILE" ]; then
    print_status "INFO" "Downloading $IMG_URL ..."
    wget -q --show-progress -O "$IMG_FILE.tmp" "$IMG_URL" || { print_status "ERROR" "Download failed"; return 1; }
    mv -f "$IMG_FILE.tmp" "$IMG_FILE"
  else
    print_status "INFO" "Image already exists, skipping download"
  fi

  # Try resize (qemu-img supports)
  if ! qemu-img info "$IMG_FILE" &>/dev/null; then
    print_status "WARN" "Image file invalid or qemu-img can't read it"
  fi

  # Attempt to resize; ignore failure but warn
  if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
    print_status "WARN" "Resize failed; leaving image as-is or creating new qcow2 overlay"
    # create overlay instead
    tmp="$IMG_FILE.overlay"
    qemu-img create -f qcow2 -b "$IMG_FILE" "$tmp" "$DISK_SIZE" || true
    if [ -f "$tmp" ]; then mv -f "$tmp" "$IMG_FILE"; fi
  fi

  # cloud-init user-data/meta-data
  cat > "$VM_DIR/$VM_NAME-user-data" <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    passwd: $(openssl passwd -6 "$PASSWORD")
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

  if ! create_cloud_seed "$SEED_FILE" "$VM_DIR/$VM_NAME-user-data" "$VM_DIR/$VM_NAME-meta-data"; then
    print_status "ERROR" "Failed to create cloud-init seed. Install cloud-image-utils (provides cloud-localds) or genisoimage/mkisofs."
    return 1
  fi

  print_status "SUCCESS" "Image and cloud-init seed ready"
  return 0
}

# Start VM (auto-detect KVM)
start_vm() {
  local vm="$1"
  if ! load_vm_config "$vm"; then
    print_status "ERROR" "VM config not found: $vm"
    return 1
  fi

  print_status "INFO" "Starting VM $vm (memory=${MEMORY}MB cpus=${CPUS})"

  # prepare files
  IMG_FILE="$IMG_FILE"   # already set in config
  SEED_FILE="$SEED_FILE"
  if [ ! -f "$IMG_FILE" ]; then
    print_status "ERROR" "Image missing: $IMG_FILE"
    return 1
  fi
  if [ ! -f "$SEED_FILE" ]; then
    print_status "WARN" "Seed missing: $SEED_FILE; attempting recreate..."
    setup_vm_image || return 1
  fi

  # check KVM
  ACCEL_OPTS=()
  if [ -c /dev/kvm ] && [ -w /dev/kvm ]; then
    print_status "INFO" "KVM detected: using hardware acceleration"
    ACCEL_OPTS+=(-enable-kvm -cpu host)
  else
    print_status "WARN" "KVM not available: falling back to software emulation (TCG)"
    # ensure we don't pass -enable-kvm
    ACCEL_OPTS+=(-accel tcg)
  fi

  # build qemu command
  net_counter=0
  qemu_cmd=(qemu-system-x86_64 "${ACCEL_OPTS[@]}" -m "$MEMORY" -smp "$CPUS" \
    -drive "file=$IMG_FILE,if=virtio,format=qcow2" \
    -drive "file=$SEED_FILE,if=virtio,format=raw" \
    -boot order=c)

  # base netdev for ssh
  qemu_cmd+=(-device virtio-net-pci,netdev=n${net_counter} -netdev "user,id=n${net_counter},hostfwd=tcp::${SSH_PORT}-:22")
  net_counter=$((net_counter+1))

  # extra port forwards
  if [ -n "${PORT_FORWARDS:-}" ]; then
    IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
    for f in "${forwards[@]}"; do
      hostp="${f%%:*}"; guestp="${f##*:}"
      qemu_cmd+=(-device virtio-net-pci,netdev=n${net_counter} -netdev "user,id=n${net_counter},hostfwd=tcp::${hostp}-:${guestp}")
      net_counter=$((net_counter+1))
    done
  fi

  # GUI or headless
  if [ "${GUI_MODE:-false}" = true ]; then
    qemu_cmd+=(-vga virtio -display gtk,gl=on)
  else
    qemu_cmd+=(-nographic -serial mon:stdio)
  fi

  # extras
  qemu_cmd+=(-device virtio-balloon-pci -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0)

  print_status "INFO" "QEMU command: ${qemu_cmd[*]:0:6} ... (truncated for display)"
  # run
  "${qemu_cmd[@]}"
  print_status "INFO" "QEMU process exited"
}

# Delete VM
delete_vm() {
  local vm="$1"
  if ! load_vm_config "$vm"; then
    print_status "ERROR" "VM config not found: $vm"; return 1
  fi
  rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm.conf" "$VM_DIR/$vm-user-data" "$VM_DIR/$vm-meta-data"
  print_status "SUCCESS" "Deleted VM $vm and its files"
}

# Simple menu (trimmed for brevity)
main_menu() {
  while true; do
    echo
    echo "=== Multi-VM Manager (fixed) ==="
    echo "VM dir: $VM_DIR"
    echo "1) Create VM"
    echo "2) Start VM"
    echo "3) Delete VM"
    echo "4) List VMs"
    echo "0) Exit"
    read -rp "Choice: " ch
    case "$ch" in
      1)
        echo "Select OS:"
        i=1
        keys=()
        for k in "${!OS_OPTIONS[@]}"; do
          echo " $i) $k"; keys[$i]="$k"; i=$((i+1))
        done
        read -rp "OS choice number: " oc
        OS_NAME="${keys[$oc]}"
        IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$OS_NAME]}"
        read -rp "VM name (default: $DEFAULT_HOSTNAME): " VM_NAME; VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        read -rp "Hostname (default: $VM_NAME): " HOSTNAME; HOSTNAME="${HOSTNAME:-$VM_NAME}"
        read -rp "Username (default: $DEFAULT_USERNAME): " USERNAME; USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        read -rsp "Password (default provided if empty): " PASSWORD; echo
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        read -rp "Disk size (e.g., 20G) [20G]: " DISK_SIZE; DISK_SIZE="${DISK_SIZE:-20G}"
        read -rp "Memory MB [2048]: " MEMORY; MEMORY="${MEMORY:-2048}"
        read -rp "CPUs [2]: " CPUS; CPUS="${CPUS:-2}"
        read -rp "SSH port [2222]: " SSH_PORT; SSH_PORT="${SSH_PORT:-2222}"
        read -rp "Enable GUI? (y/N): " gui; GUI_MODE=false
        if [[ "$gui" =~ ^[Yy]$ ]]; then GUI_MODE=true; fi
        read -rp "Extra port forwards (host:guest,comma separated) or empty: " PORT_FORWARDS
        IMG_FILE="$VM_DIR/$VM_NAME.img"; SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"; CREATED="$(date)"
        setup_vm_image
        save_vm_config
        ;;
      2)
        echo "Available VMs:"
        mapfile -t vlist < <(get_vm_list)
        if [ ${#vlist[@]} -eq 0 ]; then print_status "INFO" "No VMs found"; continue; fi
        for idx in "${!vlist[@]}"; do echo " $((idx+1))) ${vlist[$idx]}"; done
        read -rp "Pick number to start: " n; n=$((n-1))
        start_vm "${vlist[$n]}"
        ;;
      3)
        echo "Available VMs:"
        mapfile -t vlist < <(get_vm_list)
        for idx in "${!vlist[@]}"; do echo " $((idx+1))) ${vlist[$idx]}"; done
        read -rp "Pick number to delete: " n; n=$((n-1))
        delete_vm "${vlist[$n]}"
        ;;
      4)
        mapfile -t vlist < <(get_vm_list)
        if [ ${#vlist[@]} -eq 0 ]; then echo "No VMs"; else for v in "${vlist[@]}"; do echo "- $v"; done; fi
        ;;
      0) exit 0 ;;
      *) echo "Invalid" ;;
    esac
  done
}

# Start
check_dependencies
main_menu
