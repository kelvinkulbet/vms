# ------------------------------------------------------------------
# 0.  Make sure standard tools are reachable (minimal PATH)
# ------------------------------------------------------------------
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"

# ------------------------------------------------------------------
# 1.  Auto-install missing runtime deps (Ubuntu/Debian family)
# ------------------------------------------------------------------
install_missing_deps(){
    local deps=(qemu-system-x86 qemu-utils cloud-image-utils kmod wget iproute2)
    local to_install=()

    for d in "${deps[@]}"; do
        if ! dpkg -l | grep -q "^ii.*${d} "; then
            to_install+=("$d")
        fi
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        print_status "WARN" "Missing packages: ${to_install[*]}"
        print_status "INFO" "Attempting auto-install (requires sudo)…"
        sudo apt-get update -qq
        sudo apt-get install -y "${to_install[@]}"
    fi
}

# ------------------------------------------------------------------
# 2.  Ensure KVM device & modules are ready
# ------------------------------------------------------------------
ensure_kvm_ready(){
    # --- load modules jika belum ---
    for mod in kvm kvm_intel kvm_amd; do
        if ! lsmod | awk -v m="$mod" '$1==m{ok=1} END{exit !ok}'; then
            sudo modprobe "$mod" 2>/dev/null || true
        fi
    done

    # --- /dev/kvm harus ada ---
    if [[ ! -e /dev/kvm ]]; then
        print_status "ERROR" "/dev/kvm not found. Enable VT-x/AMD-V in BIOS."
        exit 1
    fi

    # --- user harus kvm group ---
    if ! groups | grep -qw kvm; then
        print_status "WARN" "Adding $USER to 'kvm' group (needs sudo once)."
        sudo usermod -aG kvm "$USER"
        print_status "INFO" "Re-login (or run 'newgrp kvm') then restart script."
        exit 1
    fi

    # --- permission ---
    if [[ ! -w /dev/kvm ]]; then
        print_status "WARN" "Fixing /dev/kvm permission (needs sudo once)."
        sudo chmod 666 /dev/kvm
    fi
}

# ------------------------------------------------------------------
# 3.  Cleanup handler
# ------------------------------------------------------------------
trap cleanup EXIT

# ------------------------------------------------------------------
# 4.  Initialize directories
# ------------------------------------------------------------------
VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

# ------------------------------------------------------------------
# 5.  Auto-fix deps + KVM (hanya untuk Ubuntu/Debian)
# ------------------------------------------------------------------
if command -v apt-get &>/dev/null; then
    install_missing_deps
fi
ensure_kvm_ready

# ------------------------------------------------------------------
# 6.  Final dependency check (untuk semua distro)
# ------------------------------------------------------------------
check_dependencies

# ------------------------------------------------------------------
# 7.  Start the menu
# ------------------------------------------------------------------
main_menu
