#!/bin/bash

# Parse arguments
NO_PROMPT=0
ISO_URL=""
VIRTIO_ISO_URL=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --no-prompt)
            NO_PROMPT=1
            shift
            ;;
        --iso-url)
            ISO_URL="$2"
            shift 2
            ;;
        --virtio-url)
            VIRTIO_ISO_URL="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$ISO_URL" ]]; then
    if [[ "$NO_PROMPT" -eq 0 ]]; then
        read -p "Enter the URL for Windows.iso: " input_url
        ISO_URL="${input_url:-}"
    fi
fi

if [[ -z "$VIRTIO_ISO_URL" ]]; then
    if [[ "$NO_PROMPT" -eq 0 ]]; then
        read -p "Enter the URL for Virtio.iso (leave blank to use default): " input_virtio
        VIRTIO_ISO_URL="${input_virtio:-}"
    fi
fi

if [[ -z "$ISO_URL" ]]; then
    echo "ERROR: Windows ISO URL is required."
    exit 1
fi

if [[ -z "$VIRTIO_ISO_URL" ]]; then
    VIRTIO_ISO_URL="$DEFAULT_VIRTIO_ISO_URL"
fi

echo "Using Windows ISO URL: $ISO_URL"
echo "Using VirtIO ISO URL: $VIRTIO_ISO_URL"


# Enable strict mode for safer script execution
set -euo pipefail

package_for_command() {
    case "$1" in
        mkfs.ntfs) echo ntfs-3g ;;
        mkfs.ext4) echo e2fsprogs ;;
        grub-install|grub-probe) echo grub-pc ;;
        git) echo git ;;
        aria2c) echo aria2 ;;
        wget) echo wget ;;
        rsync) echo rsync ;;
        parted|partprobe) echo parted ;;
        gdisk) echo gdisk ;;
        curl) echo curl ;;
        *) echo "" ;;
    esac
}

install_packages_for_commands() {
    local cmd pkg
    local packages=()
    local pkg_seen=""

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "ERROR: apt-get is required to install missing packages."
        exit 1
    fi

    for cmd in "$@"; do
        pkg=$(package_for_command "$cmd")
        if [ -n "$pkg" ]; then
            if ! printf '%s\n' $pkg_seen | grep -Fxq "$pkg" 2>/dev/null; then
                pkg_seen="$pkg_seen $pkg"
                packages+=("$pkg")
            fi
        fi
    done

    if [ "${#packages[@]}" -eq 0 ]; then
        return 0
    fi

    echo "Installing missing packages: ${packages[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends "${packages[@]}"
}

ensure_required_tools() {
    local required=(curl awk grep rsync parted partprobe mkfs.ntfs mkfs.ext4 mount umount grub-install grub-probe git aria2c wget gdisk)
    local missing=()
    local cmd

    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        install_packages_for_commands "${missing[@]}"
        missing=()
        for cmd in "${required[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                missing+=("$cmd")
            fi
        done
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: Missing required commands after installation: ${missing[*]}"
        exit 1
    fi
}

ensure_required_tools

# Ensure all /dev/sda partitions are unmounted and swap is off before partitioning
echo "Deactivating swap and unmounting all /dev/sda partitions..."
swapoff -a
for part in $(lsblk -ln -o NAME | grep '^sda' | grep -v '^sda$'); do
    umount /dev/$part 2>/dev/null || true
done
echo "All /dev/sda partitions unmounted and swap deactivated."

# Default URL for Windows ISO
# Create a temporary swap file for low-memory environments
SWAPFILE="/swapfile"
if [ ! -f "$SWAPFILE" ]; then
    echo "Creating temporary swap file..."
    fallocate -l 1G "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    if ! swapon "$SWAPFILE"; then
        echo "WARNING: swapon failed; continuing without swap."
    else
        echo "Temporary swap file created and activated."
    fi
fi

# Optimize aria2 download settings for VPS resources
ARIA2_OPTS="--max-connection-per-server=16 --split=16 --min-split-size=1M --timeout=60 --retry-wait=30"
retry_download() {
    local url="$1"
    local output="$2"
    aria2c $ARIA2_OPTS -o "$output" "$url"
}

# Default VirtIO ISO URL
DEFAULT_VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
if [[ -z "$VIRTIO_ISO_URL" ]]; then
    if [[ "$NO_PROMPT" -eq 0 ]]; then
        read -p "Enter the URL for Virtio.iso (leave blank to use default): " virtio_url
        VIRTIO_ISO_URL="${virtio_url:-$DEFAULT_VIRTIO_ISO_URL}"
    else
        VIRTIO_ISO_URL="$DEFAULT_VIRTIO_ISO_URL"
    fi
fi

WINDOWS_ISO_URL="$ISO_URL"
VIRTIO_ISO_URL="$VIRTIO_ISO_URL"

# Determine the sizes of both ISOs before creating zram
WINDOWS_ISO_SIZE=$(curl -sI "$WINDOWS_ISO_URL" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')
VIRTIO_ISO_SIZE=$(curl -sI "$VIRTIO_ISO_URL" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')

if [ -z "$WINDOWS_ISO_SIZE" ] || [ -z "$VIRTIO_ISO_SIZE" ]; then
    echo "ERROR: Unable to determine ISO sizes from HTTP headers. Exiting."
    exit 1
fi

TOTAL_ISO_SIZE=$((WINDOWS_ISO_SIZE + VIRTIO_ISO_SIZE))
TOTAL_ISO_SIZE_MB=$((TOTAL_ISO_SIZE / 1024 / 1024 + 512))

# Remove any existing zram mount/device
if mountpoint -q /mnt/zram0; then
    echo "Unmounting existing zram..."
    umount /mnt/zram0 || true
fi
if [ -e /dev/zram0 ]; then
    swapoff /dev/zram0 2>/dev/null || true
    echo 1 > /sys/block/zram0/reset || true
fi

modprobe zram >/dev/null 2>&1 || true

AVAILABLE_RAM_MB=$(free -m | awk '/^Mem:/{print $7}')
SAFE_RAM_MB=$((AVAILABLE_RAM_MB - 512))
if [ "$SAFE_RAM_MB" -lt 0 ]; then
    SAFE_RAM_MB=0
fi

USE_ZRAM=0
if [ "$TOTAL_ISO_SIZE_MB" -le "$SAFE_RAM_MB" ]; then
    echo "Creating zram of size ${TOTAL_ISO_SIZE_MB}MB..."
    echo lz4 > /sys/block/zram0/comp_algorithm
    echo "${TOTAL_ISO_SIZE_MB}M" > /sys/block/zram0/disksize
    if mkfs.ext4 -q /dev/zram0 && mkdir -p /mnt/zram0 && mount /dev/zram0 /mnt/zram0; then
        USE_ZRAM=1
        echo "zram mounted at /mnt/zram0."
    else
        echo "WARNING: Failed to format or mount zram; using disk fallback."
    fi
else
    echo "WARNING: Insufficient RAM for zram; using disk fallback."
fi

if [ "$USE_ZRAM" -eq 1 ]; then
    mkdir -p /mnt/zram0/windisk
    WINDOWS_ISO="/mnt/zram0/windisk/Windows.iso"
    VIRTIO_ISO="/mnt/zram0/windisk/VirtIO.iso"
else
    mkdir -p /root/windisk
    WINDOWS_ISO="/root/windisk/Windows.iso"
    VIRTIO_ISO="/root/windisk/VirtIO.iso"

    REQUIRED_DISK_BYTES=$((TOTAL_ISO_SIZE + TOTAL_ISO_SIZE / 5))
    ROOT_AVAIL=$(df --output=avail / | tail -n 1)
    ROOT_AVAIL_BYTES=$((ROOT_AVAIL * 1024))
    if [ "$ROOT_AVAIL_BYTES" -lt "$REQUIRED_DISK_BYTES" ]; then
        if mountpoint -q /mnt 2>/dev/null; then
            MNT_AVAIL=$(df --output=avail /mnt | tail -n 1)
            MNT_AVAIL_BYTES=$((MNT_AVAIL * 1024))
            if [ "$MNT_AVAIL_BYTES" -ge "$REQUIRED_DISK_BYTES" ]; then
                echo "Using /mnt for ISO downloads because / has insufficient space."
                mkdir -p /mnt/windisk
                WINDOWS_ISO="/mnt/windisk/Windows.iso"
                VIRTIO_ISO="/mnt/windisk/VirtIO.iso"
            else
                echo "ERROR: Not enough disk space on / or /mnt for ISO downloads ($ROOT_AVAIL_BYTES bytes on /, $MNT_AVAIL_BYTES bytes on /mnt; $REQUIRED_DISK_BYTES needed)."
                exit 1
            fi
        else
            echo "ERROR: Not enough disk space on / for ISO downloads ($ROOT_AVAIL_BYTES bytes available, $REQUIRED_DISK_BYTES needed) and /mnt is not mounted."
            exit 1
        fi
    fi
fi

echo "Downloading Windows ISO to $WINDOWS_ISO..."
retry_download "$WINDOWS_ISO_URL" "$WINDOWS_ISO"
echo "Downloading VirtIO ISO to $VIRTIO_ISO..."
retry_download "$VIRTIO_ISO_URL" "$VIRTIO_ISO"

if [ ! -f "$WINDOWS_ISO" ] || [ ! -f "$VIRTIO_ISO" ]; then
    echo "ERROR: Failed to download one or both ISOs. Exiting."
    exit 1
fi

echo "Windows ISO downloaded successfully to $WINDOWS_ISO."
echo "VirtIO ISO downloaded successfully to $VIRTIO_ISO."


# Check available space and decide clone location
CLONE_DIR="/root/install-windows-11-from-rescue-for-contabo"
if mountpoint -q /mnt/zram0; then
    ZRAM_AVAIL=$(df --output=avail /mnt/zram0 | tail -n 1)
    if [ "$ZRAM_AVAIL" -gt 100000 ]; then
        echo "Using /mnt/zram0 for cloning because it is mounted and has available space."
        CLONE_DIR="/mnt/zram0/install-windows-11-from-rescue-for-contabo"
    fi
fi
    if [ -f "$output" ] && [ "$FORCE_DOWNLOAD" -eq 0 ]; then
        local existing_size
        existing_size=$(stat -c%s "$output" 2>/dev/null || echo 0)
        if [ "$existing_size" -gt 0 ] && [ "$existing_size" -lt $((10 * 1024 * 1024)) ]; then
            echo "Existing file $output is too small ($existing_size bytes); removing and redownloading."
            rm -f "$output"
        fi
        if [ -f "$output" ]; then
            echo "Using existing file: $output"
            return
        fi
    fi

# Clone the repository
if ! command -v git &> /dev/null; then
    echo "Installing git..."
    apt update && apt install -y git
fi

echo "Cloning repository to $CLONE_DIR..."
rm -rf "$CLONE_DIR"
git clone --depth 1 https://github.com/WebWire-NL/install-windows-11-from-rescue-for-contabo "$CLONE_DIR"

if [ ! -d "$CLONE_DIR" ]; then
    echo "ERROR: Failed to clone repository. Exiting."
    exit 1
fi

# Retry checkout if it fails
cd "$CLONE_DIR"
if [ ! -f windows-install.sh ]; then
    echo "Retrying checkout..."
    git restore --source=HEAD :/
fi

echo "Repository cloned successfully to $CLONE_DIR."

# Additional partitioning and GRUB setup from 'main'
disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
disk_size_mb=$((disk_size_gb * 1024))
part_size_mb=$((disk_size_mb / 4))

parted /dev/sda --script -- mklabel gpt
parted /dev/sda --script -- mkpart primary ntfs 1MB ${part_size_mb}MB
parted /dev/sda --script -- mkpart primary ntfs ${part_size_mb}MB $((2 * part_size_mb))MB

partprobe /dev/sda
sleep 30
partprobe /dev/sda
sleep 30
    local download_dir="$MNT_STORAGE"
    if mountpoint -q "$MNT_STORAGE" 2>/dev/null; then
        download_dir="${MNT_STORAGE}-download"
    fi
    mkdir -p "$download_dir"

    local windows_iso="$download_dir/Windows.iso"
    local virtio_iso="$download_dir/VirtIO.iso"
mkfs.ntfs -f /dev/sda1
mkfs.ntfs -f /dev/sda2
echo "NTFS partitions created"
echo -e "r\ng\np\nw\nY\n" | gdisk /dev/sda

mount /dev/sda1 /mnt

# Copy VirtIO drivers and bypass settings into the mounted Windows install source tree
local ISO_MOUNT_DIR
ISO_MOUNT_DIR=$(mktemp -d)
trap 'if mountpoint -q "$ISO_MOUNT_DIR"; then umount "$ISO_MOUNT_DIR" || true; fi; rmdir "$ISO_MOUNT_DIR" 2>/dev/null || true' EXIT
mount -o loop "$VIRTIO_ISO" "$ISO_MOUNT_DIR"
mkdir -p /mnt/sources/virtio
rsync -avz --progress "$ISO_MOUNT_DIR"/ /mnt/sources/virtio/
# cleanup happens automatically on function/exit return

cat <<'EOF' > /mnt/sources/bypass.bat
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
EOF

if [ ! -d "/mnt/sources/virtio" ]; then
    echo "ERROR: /mnt/sources/virtio directory missing."
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

cd ~
mkdir windisk
mount /dev/sda2 windisk
grub-install --root-directory=/mnt /dev/sda
cd /mnt/boot/grub
cat <<EOF > grub.cfg
menuentry "windows installer" {
    insmod ntfs
    search --no-floppy --set=root --file=/bootmgr
    chainloader /bootmgr
    boot
}
EOF

# Final checks and reboot prompt
echo "*** Final checks ***"
ls -lh /mnt/bootmgr /mnt/sources/boot.wim
ls -lh /mnt/sources/virtio || true

read -p "Optionally unmount /mnt and /root/windisk before reboot? (Y/N): " umount_choice
if [[ "$umount_choice" == "Y" || "$umount_choice" == "y" ]]; then
    umount /root/windisk || echo "Could not unmount /root/windisk (maybe already unmounted)."
    umount /mnt || echo "Could not unmount /mnt (maybe busy, will be handled on reboot)."
fi

read -p "Do you want to reboot the system now? (Y/N): " reboot_choice
if [[ "$reboot_choice" == "Y" || "$reboot_choice" == "y" ]]; then
    echo "*** Rebooting the system... ***"
    reboot
else
    echo "Continuing without rebooting. You can run 'reboot' later to start the Windows installer."
fi
