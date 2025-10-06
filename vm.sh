#!/usr/bin/env bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager (Merged, full)
# =============================
VERSION="1.1-full"

# Function to display header (kepepet sama seperti style aslinya)
display_header() {
    clear
    cat << "EOF"
========================================================================
  _    _  ____  _____ _____ _   _  _____ ____   ______     ________
 | |  | |/ __ \|  __ \_   _| \ | |/ ____|  _ \ / __ \ \   / /___  /
 | |__| | |  | | |__) || | |  \| | |  __| |_) | |  | \ \_/ /   / /
 |  __  | |  | |  ___/ | | |   \ | | |_ |  _ <| |  | |\   /   / /
 | |  | | |__| | |    _| |_| |\  | |__| | |_) | |__| | | |   / /__
 |_|  |_|\____/|_|   |_____|_| \_|\_____|____/ \____/  |_|  /_____|
                                                                  
                    POWERED BY HOPINGBOYZ
========================================================================
EOF
    echo
}

# colored output
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

print_status() {
    local type="$1"
    local message="$2"
    case "$type" in
        INFO)    echo -e "${BLUE}[INFO]${RESET} $message" ;;
        WARN)    echo -e "${YELLOW}[WARN]${RESET} $message" ;;
        ERROR)   echo -e "${RED}[ERROR]${RESET} $message" ;;
        SUCCESS) echo -e "${GREEN}[SUCCESS]${RESET} $message" ;;
        INPUT)   echo -e "${BLUE}[INPUT]${RESET} $message" ;;
        *)       echo -e "[$type] $message" ;;
    esac
}

# Validate simple patterns
validate_input() {
    local type="$1"
    local value="$2"
    case "$type" in
        number) [[ "$value" =~ ^[0-9]+$ ]] || return 1 ;;
        size)   [[ "$value" =~ ^[0-9]+[GgMm]$ ]] || return 1 ;;
        port)   [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 23 ] && [ "$value" -le 65535 ] || return 1 ;;
        name)   [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1 ;;
        username) [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1 ;;
        *) return 1 ;;
    esac
    return 0
}

# Dependencies check (allow TCG fallback)
check_dependencies() {
    local deps=(wget qemu-img qemu-system-x86_64)
    local missing=()
    for d in "${deps[@]}"; do
        if ! command -v "$d" &>/dev/null; then
            missing+=("$d")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing[*]}"
        print_status "INFO" "On Debian/Ubuntu try: sudo apt update && sudo apt install -y qemu-system-x86 cloud-image-utils wget"
        exit 1
    fi

    if ! command -v cloud-localds &>/dev/null; then
        print_status "WARN" "cloud-localds not found; cloud-init seed creation may fallback to genisoimage/mkisofs if available."
    fi
}

# Cleanup placeholders (kept for parity)
cleanup() {
    : # no-op reserved
}
trap cleanup EXIT

# VM storage dir
VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

# Supported OS list
declare -A OS_OPTIONS=(
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
)

# Utility: list VM configs
get_vm_list() {
    find "$VM_DIR" -maxdepth 1 -name "*.conf" -printf "%f\n" 2>/dev/null | sed 's/\.conf$//' | sort
}

# Load VM config file
load_vm_config() {
    local vm_name="$1"
    local conf="$VM_DIR/$vm_name.conf"
    if [ -f "$conf" ]; then
        # unset previous variables to avoid carry-over
        unset VM_NAME OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD
        unset HOSTNAME USERNAME PASSWORD DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
        # shellcheck disable=SC1090
        source "$conf"
        return 0
    else
        return 1
    fi
}

# Save VM config
save_vm_config() {
    local conf="$VM_DIR/$VM_NAME.conf"
    cat > "$conf" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
DEFAULT_HOSTNAME="$DEFAULT_HOSTNAME"
DEFAULT_USERNAME="$DEFAULT_USERNAME"
DEFAULT_PASSWORD="$DEFAULT_PASSWORD"
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
    print_status "SUCCESS" "Configuration saved to $conf"
}

# Create cloud-init seed (tries cloud-localds then genisoimage/mkisofs)
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

# Download/prepare image + seed
setup_vm_image() {
    print_status "INFO" "Downloading and preparing image..."
    mkdir -p "$VM_DIR"
    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    if [ -f "$IMG_FILE" ]; then
        print_status "INFO" "Image file already exists. Skipping download."
    else
        print_status "INFO" "Downloading image from $IMG_URL..."
        if ! wget --progress=bar:force -O "$IMG_FILE.tmp" "$IMG_URL"; then
            print_status "ERROR" "Failed to download image from $IMG_URL"
            rm -f "$IMG_FILE.tmp" || true
            exit 1
        fi
        mv -f "$IMG_FILE.tmp" "$IMG_FILE"
    fi

    # Try resize, if fails create overlay (safer)
    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
        print_status "WARN" "Failed to resize disk image; creating overlay"
        local overlay="$IMG_FILE.overlay"
        qemu-img create -f qcow2 -b "$IMG_FILE" "$overlay" "$DISK_SIZE" || true
        if [ -f "$overlay" ]; then
            mv -f "$overlay" "$IMG_FILE"
        fi
    fi

    # cloud-init user-data + meta-data
    cat > "$VM_DIR/$VM_NAME-user-data" <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    passwd: $(openssl passwd -6 "$PASSWORD" 2>/dev/null || true)
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
        print_status "ERROR" "Failed to create cloud-init seed image. Install cloud-localds or genisoimage/mkisofs."
        return 1
    fi

    print_status "SUCCESS" "VM '$VM_NAME' image & cloud-init seed ready."
    return 0
}

# Create new VM (interactive)
create_new_vm() {
    print_status "INFO" "Creating a new VM"

    # OS selection (display)
    print_status "INFO" "Select an OS to set up:"
    local os_options=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"
        os_options[$i]="$os"
        ((i++))
    done

    while true; do
        read -rp "$(print_status "INPUT" "Enter your choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_options[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        else
            print_status "ERROR" "Invalid selection. Try again."
        fi
    done

    # VM name
    while true; do
        read -rp "$(print_status "INPUT" "Enter VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        if validate_input "name" "$VM_NAME"; then
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM with name '$VM_NAME' already exists"
            else
                break
            fi
        fi
    done

    read -rp "$(print_status "INPUT" "Enter hostname (default: $VM_NAME): ")" HOSTNAME
    HOSTNAME="${HOSTNAME:-$VM_NAME}"

    while true; do
        read -rp "$(print_status "INPUT" "Enter username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        if validate_input "username" "$USERNAME"; then break; fi
    done

    while true; do
        read -rsp "$(print_status "INPUT" "Enter password (default provided if empty): ")" PASSWORD; echo
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        if [ -n "$PASSWORD" ]; then break; else print_status "ERROR" "Password cannot be empty"; fi
    done

    read -rp "$(print_status "INPUT" "Disk size (e.g., 20G) [20G]: ")" DISK_SIZE; DISK_SIZE="${DISK_SIZE:-20G}"
    read -rp "$(print_status "INPUT" "Memory MB [2048]: ")" MEMORY; MEMORY="${MEMORY:-2048}"
    read -rp "$(print_status "INPUT" "CPUs [2]: ")" CPUS; CPUS="${CPUS:-2}"
    read -rp "$(print_status "INPUT" "SSH port [2222]: ")" SSH_PORT; SSH_PORT="${SSH_PORT:-2222}"

    while true; do
        read -rp "$(print_status "INPUT" "Enable GUI mode? (y/N): ")" gui_input
        gui_input="${gui_input:-n}"
        if [[ "$gui_input" =~ ^[Yy]$ ]]; then GUI_MODE=true; break; elif [[ "$gui_input" =~ ^[Nn]$ ]]; then GUI_MODE=false; break; else print_status "ERROR" "Please answer y or n"; fi
    done

    read -rp "$(print_status "INPUT" "Extra port forwards (host:guest comma separated) or Enter: ")" PORT_FORWARDS

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    # Setup image + seed
    setup_vm_image || { print_status "ERROR" "setup_vm_image failed"; return 1; }

    # Save config
    save_vm_config
}

# Start VM
start_vm() {
    local vm_name="$1"
    if ! load_vm_config "$vm_name"; then
        print_status "ERROR" "Configuration for $vm_name not found"
        return 1
    fi

    print_status "INFO" "Starting VM: $vm_name"
    print_status "INFO" "SSH: ssh -p $SSH_PORT $USERNAME@localhost"
    print_status "INFO" "Password: $PASSWORD"

    # Ensure image exists
    if [[ ! -f "$IMG_FILE" ]]; then
        print_status "ERROR" "Image not found: $IMG_FILE"
        return 1
    fi

    # Ensure seed exists or try recreate
    if [[ ! -f "$SEED_FILE" ]]; then
        print_status "WARN" "Seed missing; recreating..."
        setup_vm_image || { print_status "ERROR" "Failed to recreate seed"; return 1; }
    fi

    local ACCEL_ARGS=()
    if [ -c /dev/kvm ] && [ -w /dev/kvm ]; then
        print_status "INFO" "KVM detected: using hardware acceleration"
        ACCEL_ARGS+=(-enable-kvm -cpu host)
    else
        print_status "WARN" "KVM not available: falling back to software emulation (TCG)"
        ACCEL_ARGS+=(-accel tcg)
    fi

    # Build qemu command
    local qemu_cmd=(qemu-system-x86_64 "${ACCEL_ARGS[@]}" -m "$MEMORY" -smp "$CPUS" -drive "file=$IMG_FILE,format=qcow2,if=virtio" -drive "file=$SEED_FILE,format=raw,if=virtio" -boot order=c)

    # network: base ssh forward
    local netid=0
    qemu_cmd+=(-device virtio-net-pci,netdev=n${netid} -netdev "user,id=n${netid},hostfwd=tcp::${SSH_PORT}-:22")
    netid=$((netid+1))

    # additional forwards
    if [[ -n "${PORT_FORWARDS:-}" ]]; then
        IFS=',' read -ra arr <<< "$PORT_FORWARDS"
        for f in "${arr[@]}"; do
            hostp="${f%%:*}"; guestp="${f##*:}"
            if [[ -n "$hostp" && -n "$guestp" ]]; then
                qemu_cmd+=(-device virtio-net-pci,netdev=n${netid} -netdev "user,id=n${netid},hostfwd=tcp::${hostp}-:${guestp}")
                netid=$((netid+1))
            fi
        done
    fi

    # GUI / headless
    if [[ "${GUI_MODE:-false}" == true ]]; then
        qemu_cmd+=(-vga virtio -display gtk,gl=on)
    else
        qemu_cmd+=(-nographic -serial mon:stdio)
    fi

    # extras
    qemu_cmd+=(-device virtio-balloon-pci -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0)

    print_status "INFO" "QEMU command: ${qemu_cmd[*]:0:8} ... (truncated)"
    # run qemu
    "${qemu_cmd[@]}" || print_status "WARN" "QEMU exited or failed"
    print_status "INFO" "VM $vm_name stopped"
}

# Stop VM (by IMG_FILE match)
is_vm_running() {
    local vm_name="$1"
    if load_vm_config "$vm_name"; then
        if pgrep -f "qemu-system-x86_64.*$(basename "$IMG_FILE")" >/dev/null; then
            return 0
        fi
    fi
    return 1
}

stop_vm() {
    local vm_name="$1"
    if ! load_vm_config "$vm_name"; then
        print_status "ERROR" "VM not found"
        return 1
    fi
    if is_vm_running "$vm_name"; then
        print_status "INFO" "Stopping VM: $vm_name"
        pkill -f "qemu-system-x86_64.*$(basename "$IMG_FILE")" || true
        sleep 1
        if is_vm_running "$vm_name"; then
            print_status "WARN" "Forcing kill..."
            pkill -9 -f "qemu-system-x86_64.*$(basename "$IMG_FILE")" || true
        fi
        print_status "SUCCESS" "VM $vm_name stopped"
    else
        print_status "INFO" "VM $vm_name is not running"
    fi
}

# Delete VM
delete_vm() {
    local vm_name="$1"
    if ! load_vm_config "$vm_name"; then
        print_status "ERROR" "VM not found"
        return 1
    fi
    print_status "WARN" "This will permanently delete VM '$vm_name' and its data!"
    read -rp "$(print_status "INPUT" "Are you sure? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        pkill -f "qemu-system-x86_64.*$(basename "$IMG_FILE")" >/dev/null 2>&1 || true
        rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf" "$VM_DIR/$vm_name-user-data" "$VM_DIR/$vm_name-meta-data"
        print_status "SUCCESS" "Deleted VM $vm_name"
    else
        print_status "INFO" "Deletion cancelled"
    fi
}

# Show VM info
show_vm_info() {
    local vm_name="$1"
    if ! load_vm_config "$vm_name"; then
        print_status "ERROR" "VM not found"
        return 1
    fi
    echo
    print_status "INFO" "VM Information: $vm_name"
    echo "=========================================="
    echo "OS:        $OS_TYPE ($CODENAME)"
    echo "Hostname:  $HOSTNAME"
    echo "Username:  $USERNAME"
    echo "Password:  $PASSWORD"
    echo "SSH Port:  $SSH_PORT"
    echo "Memory:    $MEMORY MB"
    echo "CPUs:      $CPUS"
    echo "Disk:      $DISK_SIZE"
    echo "GUI Mode:  $GUI_MODE"
    echo "Ports Fwd: ${PORT_FORWARDS:-None}"
    echo "Created:   $CREATED"
    echo "Image:     $IMG_FILE"
    echo "Seed:      $SEED_FILE"
    echo "=========================================="
    read -rp "$(print_status "INPUT" "Press Enter to continue...")"
}

# Edit VM config (interactive)
edit_vm_config() {
    local vm_name="$1"
    if ! load_vm_config "$vm_name"; then
        print_status "ERROR" "VM not found"
        return 1
    fi

    print_status "INFO" "Editing VM: $vm_name"
    while true; do
        echo " 1) Hostname"
        echo " 2) Username"
        echo " 3) Password"
        echo " 4) SSH Port"
        echo " 5) GUI Mode"
        echo " 6) Port Forwards"
        echo " 7) Memory (MB)"
        echo " 8) CPUs"
        echo " 9) Disk Size"
        echo " 0) Back"
        read -rp "$(print_status "INPUT" "Choice: ")" ch
        case "$ch" in
            1)
                read -rp "New hostname [$HOSTNAME]: " v; v="${v:-$HOSTNAME}"; HOSTNAME="$v";;
            2)
                read -rp "New username [$USERNAME]: " v; v="${v:-$USERNAME}"; USERNAME="$v";;
            3)
                read -rsp "New password (will hide input): " v; echo; v="${v:-$PASSWORD}"; PASSWORD="$v";;
            4)
                while true; do read -rp "New SSH port [$SSH_PORT]: " v; v="${v:-$SSH_PORT}"; if validate_input "port" "$v"; then SSH_PORT="$v"; break; else print_status "ERROR" "Invalid port"; fi; done;;
            5)
                read -rp "Enable GUI? (y/N) [${GUI_MODE:-false}]: " v; v="${v:-n}"; [[ "$v" =~ ^[Yy]$ ]] && GUI_MODE=true || GUI_MODE=false;;
            6)
                read -rp "New port forwards (host:guest comma separated) [${PORT_FORWARDS:-none}]: " v; PORT_FORWARDS="${v:-$PORT_FORWARDS}";;
            7)
                while true; do read -rp "Memory MB [$MEMORY]: " v; v="${v:-$MEMORY}"; if validate_input "number" "$v"; then MEMORY="$v"; break; else print_status "ERROR" "Invalid number"; fi; done;;
            8)
                while true; do read -rp "CPUs [$CPUS]: " v; v="${v:-$CPUS}"; if validate_input "number" "$v"; then CPUS="$v"; break; else print_status "ERROR" "Invalid number"; fi; done;;
            9)
                while true; do read -rp "Disk size (e.g., 50G) [$DISK_SIZE]: " v; v="${v:-$DISK_SIZE}"; if validate_input "size" "$v"; then DISK_SIZE="$v"; break; else print_status "ERROR" "Invalid size"; fi; done;;
            0) break ;;
            *) print_status "ERROR" "Invalid choice" ;;
        esac

        # If core identity changed, recreate seed
        if [[ "$ch" =~ ^[123]$ ]]; then
            print_status "INFO" "Recreating cloud-init seed with updated config..."
            setup_vm_image || print_status "WARN" "seed recreate failed"
        fi

        save_vm_config
        read -rp "$(print_status "INPUT" "Continue editing? (y/N): ")" cont; if [[ ! "$cont" =~ ^[Yy]$ ]]; then break; fi
    done
}

# Resize VM disk (interactive)
resize_vm_disk() {
    local vm_name="$1"
    if ! load_vm_config "$vm_name"; then print_status "ERROR" "VM not found"; return 1; fi
    print_status "INFO" "Current disk size: $DISK_SIZE"
    while true; do
        read -rp "$(print_status "INPUT" "Enter new disk size (e.g., 50G): ")" newsize
        if validate_input "size" "$newsize"; then
            # compare roughly
            current_num=${DISK_SIZE%[GgMm]}; new_num=${newsize%[GgMm]}
            current_unit=${DISK_SIZE: -1}; new_unit=${newsize: -1}
            # convert to MB
            if [[ "$current_unit" =~ [Gg] ]]; then current_mb=$((current_num*1024)); else current_mb=$current_num; fi
            if [[ "$new_unit" =~ [Gg] ]]; then new_mb=$((new_num*1024)); else new_mb=$new_num; fi
            if (( new_mb < current_mb )); then
                print_status "WARN" "Shrinking may cause data loss!"
                read -rp "Are you sure? (y/N): " yn; if [[ ! "$yn" =~ ^[Yy]$ ]]; then print_status "INFO" "Cancelled"; return 0; fi
            fi
            if qemu-img resize "$IMG_FILE" "$newsize"; then
                DISK_SIZE="$newsize"; save_vm_config; print_status "SUCCESS" "Resized to $newsize"; return 0
            else
                print_status "ERROR" "qemu-img resize failed"; return 1
            fi
        else
            print_status "ERROR" "Invalid size format"
        fi
    done
}

# Show VM performance (live metrics or config if stopped)
show_vm_performance() {
    local vm_name="$1"
    if ! load_vm_config "$vm_name"; then print_status "ERROR" "VM not found"; return 1; fi

    if is_vm_running "$vm_name"; then
        print_status "INFO" "Performance metrics for $vm_name"
        local qpid
        qpid=$(pgrep -f "qemu-system-x86_64.*$(basename "$IMG_FILE")" | head -n1) || qpid=""
        if [ -n "$qpid" ]; then
            ps -p "$qpid" -o pid,%cpu,%mem,sz,rss,vsz,cmd --no-headers
            echo
            free -h
            echo
            df -h "$IMG_FILE" 2>/dev/null || du -h "$IMG_FILE"
        else
            print_status "ERROR" "Could not find qemu process"
        fi
    else
        print_status "INFO" "VM is not running. Configuration:"
        echo "  Memory: $MEMORY MB"
        echo "  CPUs:   $CPUS"
        echo "  Disk:   $DISK_SIZE"
    fi
    read -rp "$(print_status "INPUT" "Press Enter to continue...")"
}

# Check VM specs (option 7 style)
check_vm_specs() {
    echo "Available VMs:"
    mapfile -t vlist < <(get_vm_list)
    if [ ${#vlist[@]} -eq 0 ]; then print_status "INFO" "No VMs found"; return 0; fi
    for i in "${!vlist[@]}"; do echo " $((i+1))) ${vlist[$i]}"; done
    read -rp "Select VM to inspect: " sel; sel=$((sel-1))
    local vm="${vlist[$sel]}"
    if ! load_vm_config "$vm"; then print_status "ERROR" "VM config not found"; return 1; fi

    echo -e "${BLUE}========== VM SPECIFICATIONS ==========${RESET}"
    echo -e "${GREEN}Name:       ${RESET}${VM_NAME}"
    echo -e "${GREEN}OS Type:    ${RESET}${OS_TYPE} (${CODENAME})"
    echo -e "${GREEN}CPUs:       ${RESET}${CPUS}"
    echo -e "${GREEN}Memory:     ${RESET}${MEMORY} MB"
    echo -e "${GREEN}Disk:       ${RESET}${DISK_SIZE}"
    echo -e "${GREEN}SSH Port:   ${RESET}${SSH_PORT}"
    echo -e "${GREEN}GUI Mode:   ${RESET}${GUI_MODE}"
    echo -e "${GREEN}Port Forwds:${RESET}${PORT_FORWARDS:-None}"
    echo -e "${GREEN}Image Path: ${RESET}${IMG_FILE}"
    echo -e "${GREEN}Seed Path:  ${RESET}${SEED_FILE}"
    echo -e "${GREEN}Created:    ${RESET}${CREATED}"
    echo -e "${BLUE}=======================================${RESET}"
    read -rp "$(print_status "INPUT" "Press Enter to continue...")"
}

# Quick disk perf & KVM check (option 8 style)
test_vm_performance() {
    print_status "INFO" "Testing QEMU acceleration capability..."
    if [ -c /dev/kvm ] && [ -w /dev/kvm ]; then
        print_status "SUCCESS" "KVM available ✅"
    else
        print_status "WARN" "KVM not detected - software TCG will be used ❌"
    fi

    print_status "INFO" "Running quick local disk benchmark (100MB sync write)..."
    local tstart tend runtime speed
    tstart=$(date +%s)
    dd if=/dev/zero of=/tmp/vm_mgr_test_speed.img bs=1M count=100 oflag=dsync 2> /tmp/vm_mgr_speed.log || true
    tend=$(date +%s)
    runtime=$((tend - tstart))
    speed=$(grep -o '[0-9.]* MB/s' /tmp/vm_mgr_speed.log | tail -1 || true)

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
    rm -f /tmp/vm_mgr_test_speed.img /tmp/vm_mgr_speed.log || true
    read -rp "$(print_status "INPUT" "Press Enter to continue...")"
}

# Main menu (full)
main_menu() {
    while true; do
        display_header
        mapfile -t vms < <(get_vm_list)
        local vm_count=${#vms[@]}
        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "Found $vm_count existing VM(s):"
            for i in "${!vms[@]}"; do
                local status="Stopped"
                if is_vm_running "${vms[$i]}"; then status="Running"; fi
                printf "  %2d) %s (%s)\n" $((i+1)) "${vms[$i]}" "$status"
            done
            echo
        fi

        echo "Main Menu:"
        echo "  1) Create a new VM"
        if [ $vm_count -gt 0 ]; then
            echo "  2) Start a VM"
            echo "  3) Stop a VM"
            echo "  4) Show VM info"
            echo "  5) Edit VM configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM disk"
            echo "  8) Show VM performance"
            echo "  9) Check VM specifications (list + inspect)"
            echo " 10) Quick host perf & KVM test"
        fi
        echo "  0) Exit"
        echo

        read -rp "$(print_status "INPUT" "Enter your choice: ")" choice

        case "$choice" in
            1) create_new_vm ;;
            2)
                if [ $vm_count -gt 0 ]; then
                    read -rp "$(print_status "INPUT" "Enter VM number to start: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        start_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            3)
                if [ $vm_count -gt 0 ]; then
                    read -rp "$(print_status "INPUT" "Enter VM number to stop: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        stop_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            4)
                if [ $vm_count -gt 0 ]; then
                    read -rp "$(print_status "INPUT" "Enter VM number to show info: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_info "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            5)
                if [ $vm_count -gt 0 ]; then
                    read -rp "$(print_status "INPUT" "Enter VM number to edit: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        edit_vm_config "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            6)
                if [ $vm_count -gt 0 ]; then
                    read -rp "$(print_status "INPUT" "Enter VM number to delete: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        delete_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            7)
                if [ $vm_count -gt 0 ]; then
                    read -rp "$(print_status "INPUT" "Enter VM number to resize disk: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        resize_vm_disk "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            8)
                if [ $vm_count -gt 0 ]; then
                    read -rp "$(print_status "INPUT" "Enter VM number to show performance: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_performance "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            9)
                check_vm_specs
                ;;
            10)
                test_vm_performance
                ;;
            0)
                print_status "INFO" "Goodbye!"
                exit 0
                ;;
            *)
                print_status "ERROR" "Invalid option"
                ;;
        esac

        read -rp "$(print_status "INPUT" "Press Enter to continue...")"
    done
}

# run
check_dependencies
main_menu
