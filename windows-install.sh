#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/root/.wininstall-state"
mkdir -p "$STATE_DIR"

TARGET_DISK="${TARGET_DISK:-/dev/sda}"
PART1="${PART1:-${TARGET_DISK}1}"
PART2="${PART2:-${TARGET_DISK}2}"

MNT_INSTALL="/mnt"
MNT_STORAGE="/root/windisk"

GRUB_INSTALL_TARGET="i386-pc"
DEFAULT_VIRTIO_ISO_URL="https://bit.ly/4d1g7Ht"

RECREATE_DISK=0
CHECK_ONLY=0
FORCE_DOWNLOAD=0
NO_PROMPT=0
WINDOWS_ISO_URL=""
VIRTIO_ISO_URL=""

checkpoint_done() { [ -f "$STATE_DIR/$1" ]; }
checkpoint_set() { touch "$STATE_DIR/$1"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || { echo "ERROR: Run as root."; exit 1; }
}

cleanup_mount() {
    local p="$1"
    mountpoint -q "$p" && umount "$p" || true
}

mount_existing_partitions() {
    mkdir -p "$MNT_INSTALL" "$MNT_STORAGE"
    if [ -b "$PART2" ] && ! mountpoint -q "$MNT_INSTALL"; then
        mount "$PART2" "$MNT_INSTALL" 2>/dev/null || true
    fi
    if [ -b "$PART1" ] && ! mountpoint -q "$MNT_STORAGE"; then
        mount "$PART1" "$MNT_STORAGE" 2>/dev/null || true
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --recreate-disk) RECREATE_DISK=1 ;;
            --check-only) CHECK_ONLY=1 ;;
            --force-download) FORCE_DOWNLOAD=1 ;;
            --no-prompt) NO_PROMPT=1 ;;
            --windows-iso-url=*) WINDOWS_ISO_URL="${1#*=}" ;;
            --virtio-iso-url=*) VIRTIO_ISO_URL="${1#*=}" ;;
            --windows-iso-url)
                shift
                WINDOWS_ISO_URL="${1:-}"
                ;;
            --virtio-iso-url)
                shift
                VIRTIO_ISO_URL="${1:-}"
                ;;
            *)
                echo "ERROR: Unknown argument: $1"
                exit 1
                ;;
        esac
        shift
    done
}

ensure_toolchain() {
    local required=(
        parted partprobe mkfs.ntfs mount umount rsync
        grub-install grub-probe curl grep awk sed find
    )
    local missing=()
    for cmd in "${required[@]}"; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: Missing required commands: ${missing[*]}"
        echo "Install them first in rescue mode."
        exit 1
    fi
}

detect_firmware_mode() {
    if [ -d /sys/firmware/efi ]; then
        FIRMWARE_MODE="uefi"
    else
        FIRMWARE_MODE="bios"
    fi
}

get_disk_label() {
    parted "$TARGET_DISK" --script print 2>/dev/null \
        | awk -F: '/^Partition Table/ {gsub(/[[:space:]]/, "", $2); print $2}'
}

verify_vps_compatibility() {
    [ -b "$TARGET_DISK" ] || { echo "ERROR: $TARGET_DISK not found."; exit 1; }
    detect_firmware_mode
    echo "Detected firmware mode: $FIRMWARE_MODE"

    local label
    label="$(get_disk_label || true)"
    echo "Detected disk label: ${label:-unknown}"

    if [ "$FIRMWARE_MODE" != "bios" ]; then
        echo "WARNING: This script is optimized for BIOS rescue boot."
    fi
}

recreate_partitions() {
    echo "Recreating partitions on $TARGET_DISK ..."
    cleanup_mount "$MNT_INSTALL"
    cleanup_mount "$MNT_STORAGE"

    parted "$TARGET_DISK" --script -- mklabel msdos
    parted "$TARGET_DISK" --script -- mkpart primary ntfs 1MiB 50%
    parted "$TARGET_DISK" --script -- mkpart primary ntfs 50% 100%
    partprobe "$TARGET_DISK"
    sleep 3

    mkfs.ntfs -f "$PART1"
    mkfs.ntfs -f "$PART2"

    mkdir -p "$MNT_INSTALL" "$MNT_STORAGE"
    mount "$PART2" "$MNT_INSTALL"
    mount "$PART1" "$MNT_STORAGE"

    checkpoint_set partitions
}

ensure_partitions_ready() {
    mount_existing_partitions
    if [ "$RECREATE_DISK" -eq 1 ] || ! mountpoint -q "$MNT_INSTALL" || ! mountpoint -q "$MNT_STORAGE"; then
        recreate_partitions
    fi
}

prompt_value() {
    local current="$1"
    local prompt="$2"
    if [ -n "$current" ]; then
        echo "$current"
        return
    fi
    if [ "$NO_PROMPT" -eq 1 ] || [ ! -t 0 ]; then
        echo ""
        return
    fi
    local v
    read -r -p "$prompt" v
    echo "$v"
}

download_file() {
    local url="$1"
    local output="$2"

    if [ -f "$output" ] && [ "$FORCE_DOWNLOAD" -eq 0 ]; then
        echo "Using existing file: $output"
        return
    fi

    echo "Downloading $(basename "$output") ..."
    curl -fL --retry 5 --retry-delay 5 --continue-at - -o "$output" "$url"
}

copy_windows_media() {
    local iso="$1"
    local loop_dir
    loop_dir="$(mktemp -d)"

    cleanup() {
        mountpoint -q "$loop_dir" && umount "$loop_dir" || true
        rmdir "$loop_dir" 2>/dev/null || true
    }
    trap cleanup RETURN

    mount -o loop "$iso" "$loop_dir"
    rsync -a "$loop_dir"/ "$MNT_INSTALL"/
    checkpoint_set windows_extracted
}

copy_virtio_media() {
    local iso="$1"
    local loop_dir
    loop_dir="$(mktemp -d)"

    cleanup() {
        mountpoint -q "$loop_dir" && umount "$loop_dir" || true
        rmdir "$loop_dir" 2>/dev/null || true
    }
    trap cleanup RETURN

    mkdir -p "$MNT_INSTALL/sources/virtio"
    mount -o loop "$iso" "$loop_dir"
    rsync -a "$loop_dir"/ "$MNT_INSTALL/sources/virtio"/
    checkpoint_set virtio_extracted
}

prepare_windows_media() {
    local windows_iso="$MNT_STORAGE/Windows.iso"
    local virtio_iso="$MNT_STORAGE/VirtIO.iso"

    WINDOWS_ISO_URL="$(prompt_value "$WINDOWS_ISO_URL" "Enter Windows ISO URL: ")"
    VIRTIO_ISO_URL="$(prompt_value "$VIRTIO_ISO_URL" "Enter VirtIO ISO URL [default]: ")"

    [ -n "$WINDOWS_ISO_URL" ] || { echo "ERROR: Windows ISO URL is required."; exit 1; }
    [ -n "$VIRTIO_ISO_URL" ] || VIRTIO_ISO_URL="$DEFAULT_VIRTIO_ISO_URL"

    download_file "$WINDOWS_ISO_URL" "$windows_iso"
    download_file "$VIRTIO_ISO_URL" "$virtio_iso"

    if ! checkpoint_done windows_extracted; then
        copy_windows_media "$windows_iso"
    fi
    if ! checkpoint_done virtio_extracted; then
        copy_virtio_media "$virtio_iso"
    fi
}

write_bypass_script() {
    local oem_dir="$MNT_INSTALL/sources/\$OEM\$/\$\$/Setup/Scripts"
    mkdir -p "$oem_dir"
    cat > "$oem_dir/SetupComplete.cmd" <<'EOF'
@echo off
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f
exit /b 0
EOF
    checkpoint_set bypass_ready
}

write_grub_config() {
    mkdir -p "$MNT_INSTALL/boot/grub"

    cat > "$MNT_INSTALL/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

menuentry "windows installer (BIOS)" {
    insmod ntfs
    search --no-floppy --set=root --file=/bootmgr
    chainloader /bootmgr
    boot
}
EOF

    checkpoint_set grub_cfg
}

install_grub() {
    echo "Installing GRUB to $TARGET_DISK ..."
    grub-install --target="$GRUB_INSTALL_TARGET" --boot-directory="$MNT_INSTALL/boot" --recheck "$TARGET_DISK"
    grub-probe --target=fs "$MNT_INSTALL" >/dev/null
    grub-probe --target=device "$MNT_INSTALL" >/dev/null
    checkpoint_set grub_installed
}

verify_grub_artifacts() {
    local gdir="$MNT_INSTALL/boot/grub/i386-pc"
    [ -f "$gdir/core.img" ] || { echo "ERROR: GRUB core.img missing in $gdir"; exit 1; }
    [ -f "$gdir/normal.mod" ] || { echo "ERROR: GRUB normal.mod missing in $gdir"; exit 1; }
}

verify_ready() {
    [ -f "$MNT_INSTALL/bootmgr" ] || { echo "ERROR: Missing $MNT_INSTALL/bootmgr"; exit 1; }
    [ -f "$MNT_INSTALL/sources/boot.wim" ] || { echo "ERROR: Missing boot.wim"; exit 1; }
    [ -d "$MNT_INSTALL/sources/virtio" ] || { echo "ERROR: Missing VirtIO drivers"; exit 1; }
    [ -f "$MNT_INSTALL/boot/grub/grub.cfg" ] || { echo "ERROR: Missing grub.cfg"; exit 1; }

    verify_grub_artifacts

    grep -q 'chainloader /bootmgr' "$MNT_INSTALL/boot/grub/grub.cfg" \
        || { echo "ERROR: GRUB is not configured to chainload /bootmgr"; exit 1; }

    echo "All required installer files are present."
    echo "Reboot the VPS and select: windows installer (BIOS)"
}

main() {
    require_root
    parse_args "$@"
    ensure_toolchain
    verify_vps_compatibility
    ensure_partitions_ready

    if [ "$CHECK_ONLY" -eq 1 ]; then
        verify_ready
        exit 0
    fi

    prepare_windows_media
    write_bypass_script
    write_grub_config
    install_grub
    verify_ready
}

main "$@"