# ----------------------------------------------------------
# 0.  Ensure KVM device is accessible & modules are loaded
# ----------------------------------------------------------
ensure_kvm_ready(){
    # 1. Load modules kalau belum
    for mod in kvm kvm_intel kvm_amd; do
        if lsmod | awk '$1==mod{exit 1}' mod="$mod"; then
            sudo modprobe "$mod" 2>/dev/null || true
        fi
    done

    # 2. Pastikan /dev/kvm ada
    if [[ ! -e /dev/kvm ]]; then
        print_status "ERROR" "/dev/kvm not found. Make sure KVM is enabled in BIOS."
        exit 1
    fi

    # 3. Pastikan user masuk grup kvm
    if ! groups | grep -qw kvm; then
        print_status "WARN" "Adding $USER to 'kvm' group (need sudo once)."
        sudo usermod -aG kvm "$USER"
        print_status "INFO" "Please re-login (or run 'newgrp kvm') then restart script."
        exit 1
    fi

    # 4. Pastikan /dev/kvm writable
    if [[ ! -w /dev/kvm ]]; then
        print_status "WARN" "Fixing /dev/kvm permissions (need sudo once)."
        sudo chmod 666 /dev/kvm
    fi
}

# ----------------------------------------------------------
# 1.  Auto-install missing runtime deps (Ubuntu/Debian)
# ----------------------------------------------------------
install_missing_deps(){
    local deps=("qemu-system-x86" "qemu-utils" "cloud-image-utils" "ovmf" "wget" "ss" "socat")
    local to_install=()

    for d in "${deps[@]}"; do
        # ss is part of iproute2
        if [[ $d == "ss" ]]; then
            d="iproute2"
        fi
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
# ---------- jaga-jaga apt untuk Ubuntu/Debian ----------
if command -v apt-get &>/dev/null; then
    install_missing_deps
fi

ensure_kvm_ready
check_dependencies           # tetap butuh validasi akhir
main_menu
