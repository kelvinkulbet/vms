#!/bin/bash set -euo pipefail
# =============================
# Enhanced Multi-VM Manager
# =============================

# Function to display header
display_header() {
  clear
  cat << "EOF"
========================================================================
 _    _ ____ _____ _____ _   _ _____ ____  ______ ________
| |  | |/ __ \|  __ \_   _| \ | |/ ____|  _ \ / __ \ \ / /___ /
| |__| | |  | | |__) || | |  \| | (…logo art…) POWERED BY HOPINGBOYZ
========================================================================
EOF
  echo
}

# Function to display colored output
print_status() {
  local type=$1
  local message=$2
  case $type in
    "INFO")    echo -e "\033[1;34m[INFO]\033[0m $message" ;;
    "WARN")    echo -e "\033[1;33m[WARN]\033[0m $message" ;;
    "ERROR")   echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
    "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
    "INPUT")   echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
    *)         echo "[$type] $message" ;;
  esac
}

# Function to validate input
validate_input() {
  local type=$1
  local value=$2
  case $type in
    "number")
      if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        print_status "ERROR" "Must be a number"
        return 1
      fi
      ;;
    "size")
      if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
        print_status "ERROR" "Must be a size with unit (e.g., 100G, 512M)"
        return 1
      fi
      ;;
    "port")
      if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
        print_status "ERROR" "Must be a valid port number (23-65535)"
        return 1
      fi
      ;;
    "name")
      if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        print_status "ERROR" "VM name can only contain letters, numbers, hyphens, and underscores"
        return 1
      fi
      ;;
    "username")
      if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        print_status "ERROR" "Username must start with a letter or underscore, and contain only letters, numbers, hyphens, and underscores"
        return 1
      fi
      ;;
  esac
  return 0
}

# Function to check KVM availability
check_kvm() {
  print_status "INFO" "Checking KVM availability..."
  if ! lsmod | grep -q kvm; then
    print_status "ERROR" "KVM kernel module is not loaded"
    print_status "INFO" "Try: sudo modprobe kvm"
    return 1
  fi
  if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    print_status "ERROR" "User does not have read/write access to /dev/kvm"
    print_status "INFO" "Try: sudo usermod -aG kvm $(whoami) && newgrp kvm"
    return 1
  fi
  if ! grep -E 'vmx|svm' /proc/cpuinfo > /dev/null; then
    print_status "ERROR" "Virtualization is not enabled in CPU or not supported"
    print_status "INFO" "Enable virtualization in BIOS"
    return 1
  fi
  print_status "SUCCESS" "KVM is available and accessible"
  return 0
}

# Function to check dependencies
check_dependencies() {
  local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img" "openssl")
  local missing_deps=()
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      missing_deps+=("$dep")
    fi
  done
  if [ ${#missing_deps[@]} -ne 0 ]; then
    print_status "ERROR" "Missing dependencies: ${missing_deps[*]}"
    print_status "INFO" "On Ubuntu/Debian, try: sudo apt install qemu-system qemu-utils cloud-image-utils wget openssl"
    exit 1
  fi
  if ! check_kvm; then
    print_status "ERROR" "KVM is not available.
Please fix the issues above and try again."
    exit 1
  fi
}

# Function to cleanup temporary files
cleanup() {
  if [ -f "user-data" ]; then rm -f "user-data"; fi
  if [ -f "meta-data" ]; then rm -f "meta-data"; fi
}

# Function to get all VM configurations
get_vm_list() {
  find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

# Function to load VM configuration
load_vm_config() {
  local vm_name=$1
  local config_file="$VM_DIR/$vm_name.conf"
  if [[ -f "$config_file" ]]; then
    unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
    unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
    source "$config_file"
    return 0
  else
    print_status "ERROR" "Configuration for VM '$vm_name' not found"
    return 1
  fi
}

# Function to save VM configuration
save_vm_config() {
  local config_file="$VM_DIR/$VM_NAME.conf"
  cat > "$config_file" <<EOF
VM_NAME=$VM_NAME
OS_TYPE=$OS_TYPE
CODENAME=$CODENAME
IMG_URL=$IMG_URL
HOSTNAME=$HOSTNAME
USERNAME=$USERNAME
PASSWORD=$PASSWORD
DISK_SIZE=$DISK_SIZE
MEMORY=$MEMORY
CPUS=$CPUS
SSH_PORT=$SSH_PORT
GUI_MODE=$GUI_MODE
PORT_FORWARDS=$PORT_FORWARDS
CREATED=$CREATED
EOF
}

# Function to setup VM image
setup_vm_image() {
  print_status "INFO" "Downloading and preparing image..."
  mkdir -p "$VM_DIR"
  if [[ -f "$IMG_FILE" ]]; then
    print_status "INFO" "Image file already exists.
Skipping download."
  else
    print_status "INFO" "Downloading image from $IMG_URL..."
    if ! wget --progress=bar:force "$IMG_URL" -O "$IMG_FILE.tmp"; then
      print_status "ERROR" "Failed to download image from $IMG_URL"
      exit 1
    fi
    mv "$IMG_FILE.tmp" "$IMG_FILE"
  fi

  local current_size
  current_size=$(qemu-img info "$IMG_FILE" | grep "virtual size" | awk '{print $3}' | tr -d ',')
  print_status "INFO" "Current disk size: $current_size"

  if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
    print_status "WARN" "Failed to resize disk image.
Creating new image with specified size..."
    rm -f "$IMG_FILE"
    qemu-img create -f qcow2 "$IMG_FILE" "$DISK_SIZE" || {
      print_status "ERROR" "Failed to create disk image"
      exit 1
    }
  fi

  local new_size
  new_size=$(qemu-img info "$IMG_FILE" | grep "virtual size" | awk '{print $3}' | tr -d ',')
  print_status "INFO" "New disk size: $new_size"

  cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: "$PASSWORD"
EOF

  cat > meta-data <<EOF
instance-id: $VM_NAME
local-hostname: $HOSTNAME
EOF

  return 0
}

# Function to stop a running VM
stop_vm() {
  local vm_name=$1
  if load_vm_config "$vm_name"; then
    if is_vm_running "$vm_name"; then
      print_status "INFO" "Stopping VM: $vm_name"
      pkill -f "qemu-system-x86_64.*$IMG_FILE"
      sleep 2
      if is_vm_running "$vm_name"; then
        print_status "WARN" "VM did not stop gracefully, forcing termination..."
        pkill -9 -f "qemu-system-x86_64.*$IMG_FILE"
      fi
      print_status "SUCCESS" "VM $vm_name stopped"
    else
      print_status "INFO" "VM $vm_name is not running"
    fi
  fi
}

# Function to edit VM configuration
edit_vm_config() {
  local vm_name=$1
  if load_vm_config "$vm_name"; then
    print_status "INFO" "Editing VM: $vm_name"
    while true; do
      echo "What would you like to edit?"
      echo " 1) Hostname"
      echo " 2) Username"
      echo " 3) Password"
      echo " 4) SSH Port"
      echo " 5) GUI Mode"
      echo " 6) Port Forwards"
      echo " 7) Memory (RAM)"
      echo " 8) CPU Count"
      echo " 9) Disk Size"
      echo " 0) Back to main menu"
      read -p "$(print_status "INPUT" "Enter your choice: ")" edit_choice

      case $edit_choice in
        1) # change hostname logic
           ;;
        2) # username logic
           ;;
        3) # password logic
           ;;
        4) # ssh port logic
           ;;
        5) # gui mode logic
           ;;
        6) # port forwards
           ;;
        7) # memory
           ;;
        8) # cpu count
           ;;
        9) # disk size
           ;;
        0) return 0 ;;
        *) print_status "ERROR" "Invalid selection"; continue ;;
      esac

      # If hostname/username/password changed, update cloud-init
      if [[ "$edit_choice" -eq 1 || "$edit_choice" -eq 2 || "$edit_choice" -eq 3 ]]; then
        print_status "INFO" "Updating cloud-init configuration..."
        setup_vm_image
      fi

      save_vm_config
      read -p "$(print_status "INPUT"
