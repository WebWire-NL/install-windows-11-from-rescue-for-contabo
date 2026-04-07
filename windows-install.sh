#!/usr/bin/env bash
set -euo pipefail

echo "Deactivating swap and unmounting existing /dev/sda partitions..."
swapoff -a
for part in $(lsblk -ln -o NAME | grep '^sda' | grep -v '^sda$'); do
    umount /dev/$part 2>/dev/null || true
done
echo "All /dev/sda partitions unmounted and swap deactivated."

echo "Removing existing zram device if present..."
if mountpoint -q /mnt/zram0 2>/dev/null; then
    umount /mnt/zram0 || true
fi
if [ -e /dev/zram0 ]; then
    swapoff /dev/zram0 2>/dev/null || true
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    echo 1 > /sys/class/zram-control/hot_remove 2>/dev/null || true
fi

DEFAULT_WINDOWS_ISO_URL="https://bit.ly/3UGzNcB"
DEFAULT_VIRTIO_ISO_URL="https://bit.ly/4d1g7Ht"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

prompt_url() {
    local default="$1"
    local prompt="$2"
    local value
    read -r -p "$prompt" value
    echo "${value:-$default}"
}

download_file() {
    local url="$1"
    local output="$2"
    local session="${output}.aria2"
    local log="${output}.aria2.log"

    if command_exists aria2c; then
        if pgrep -f "aria2c .*--dir=$(dirname \"$output\") .*--out=$(basename \"$output\")" >/dev/null 2>&1; then
            echo "Stopping stale aria2c process for $output"
            pgrep -f "aria2c .*--dir=$(dirname \"$output\") .*--out=$(basename \"$output\")" | xargs -r kill
        fi

        echo "Downloading $output with aria2c (resume support)"
        set +e
        aria2c --continue=true --file-allocation=none --enable-http-keep-alive=true \
            --max-connection-per-server=16 --split=16 --min-split-size=1M --timeout=60 --retry-wait=30 \
            -d "$(dirname "$output")" -o "$(basename "$output")" --input-file="$session" "$url" >"$log" 2>&1
        local aria2_rc=$?
        set -e

        if [ "$aria2_rc" -ne 0 ]; then
            echo "WARNING: aria2c failed with exit code $aria2_rc. Falling back to curl."
            curl --retry 5 --retry-delay 10 --location --output "$output" "$url"
            if [ $? -ne 0 ]; then
                echo "WARNING: curl failed. Falling back to wget."
                wget --tries=5 --timeout=60 -O "$output" "$url"
            fi
        fi
    else
        echo "aria2c not available, downloading $output with wget"
        wget --tries=5 --timeout=60 -O "$output" "$url"
    fi
}

get_content_length() {
    local url="$1"
    curl -fsI "$url" | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r'
}

echo "*** Preparing system packages ***"
apt-get update -y
mkdir -p /tmp/apt-archives
apt-get -y -o Dir::Cache::archives=/tmp/apt-archives --no-install-recommends install linux-image-amd64 initramfs-tools grub2 wimtools ntfs-3g gdisk rsync curl wget aria2 zram-tools
apt-get -y -o Dir::Cache::archives=/tmp/apt-archives clean
rm -rf /tmp/apt-archives

disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
disk_size_mb=$((disk_size_gb * 1024))
part_size_mb=$((disk_size_mb / 2))
echo "*** Creating disk partitions ***"
parted /dev/sda --script -- mklabel gpt
parted /dev/sda --script -- mkpart primary ntfs 1MB ${part_size_mb}MB
parted /dev/sda --script -- mkpart primary ntfs ${part_size_mb}MB 100%
partprobe /dev/sda
sleep 30

mkfs.ntfs -f /dev/sda1
mkfs.ntfs -f /dev/sda2

echo "*** Running gdisk recovery / fix commands ***"
echo -e "r\ng\np\nw\nY\n" | gdisk /dev/sda

mkdir -p /mnt
mount /dev/sda1 /mnt
mkdir -p /root/windisk
mount /dev/sda2 /root/windisk

echo "*** Preparing ISO download URLs ***"
windows_url=$(prompt_url "$DEFAULT_WINDOWS_ISO_URL" "Enter the URL for Windows.iso (leave blank to use default): ")
virtio_url=$(prompt_url "$DEFAULT_VIRTIO_ISO_URL" "Enter the URL for Virtio.iso (leave blank to use default): ")

WINDOWS_ISO_URL="$windows_url"
VIRTIO_ISO_URL="$virtio_url"

WINDOWS_ISO_SIZE=$(get_content_length "$WINDOWS_ISO_URL")
VIRTIO_ISO_SIZE=$(get_content_length "$VIRTIO_ISO_URL")

if [ -z "$WINDOWS_ISO_SIZE" ] || [ -z "$VIRTIO_ISO_SIZE" ]; then
    echo "ERROR: Unable to determine ISO sizes from HTTP headers."
    exit 1
fi

TOTAL_ISO_SIZE=$((WINDOWS_ISO_SIZE + VIRTIO_ISO_SIZE))
TOTAL_ISO_SIZE_MB=$((TOTAL_ISO_SIZE / 1024 / 1024 + 512))

if command_exists mountpoint && mountpoint -q /mnt/zram0; then
    echo "Unmounting existing zram mount..."
    umount /mnt/zram0 || true
fi

if [ -e /dev/zram0 ]; then
    swapoff /dev/zram0 2>/dev/null || true
    echo 1 > /sys/block/zram0/reset || true
fi

if command_exists modprobe; then
    modprobe zram >/dev/null 2>&1 || true
fi

AVAILABLE_RAM_MB=0
if command_exists free; then
    AVAILABLE_RAM_MB=$(free -m | awk '/^Mem:/ {print $7}')
fi
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
        echo "WARNING: zram format or mount failed; using disk fallback."
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
        echo "ERROR: Not enough disk space on / for ISO downloads."
        exit 1
    fi
fi

echo "Downloading Windows ISO to $WINDOWS_ISO..."
download_file "$WINDOWS_ISO_URL" "$WINDOWS_ISO"
echo "Downloading VirtIO ISO to $VIRTIO_ISO..."
download_file "$VIRTIO_ISO_URL" "$VIRTIO_ISO"

if [ ! -f "$WINDOWS_ISO" ] || [ ! -f "$VIRTIO_ISO" ]; then
    echo "ERROR: Failed to download one or both ISO files."
    exit 1
fi

echo "Windows ISO downloaded successfully to $WINDOWS_ISO."
echo "VirtIO ISO downloaded successfully to $VIRTIO_ISO."

WINFILE_MOUNT=$(mktemp -d)
mount -o loop "$WINDOWS_ISO" "$WINFILE_MOUNT"
rsync -avz --progress "$WINFILE_MOUNT"/* /mnt/
umount "$WINFILE_MOUNT"
rmdir "$WINFILE_MOUNT"

ISO_MOUNT_DIR=$(mktemp -d)
mount -o loop "$VIRTIO_ISO" "$ISO_MOUNT_DIR"
mkdir -p /mnt/sources/virtio
rsync -avz --progress "$ISO_MOUNT_DIR"/ /mnt/sources/virtio/
umount "$ISO_MOUNT_DIR"
rmdir "$ISO_MOUNT_DIR"

cat <<'EOF' > /mnt/sources/bypass.reg
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig]
"BypassTPMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
"BypassRAMCheck"=dword:00000001
"BypassCPUCheck"=dword:00000001
"BypassStorageCheck"=dword:00000001
EOF

cat <<'EOF' > /mnt/sources/bypass.cmd
@echo off
regedit /s "%~dp0bypass.reg"
EOF

if [ ! -d "/mnt/sources/virtio" ]; then
    echo "ERROR: /mnt/sources/virtio directory missing."
    exit 1
fi

if [ ! -f "/mnt/sources/boot.wim" ]; then
    echo "ERROR: /mnt/sources/boot.wim not found."
    exit 1
fi

echo "*** Inspecting boot.wim images ***"
wimlib-imagex info /mnt/sources/boot.wim
read -r -p "Enter the image index you want to update with VirtIO drivers: " image_index

echo "add virtio /virtio_drivers" > /tmp/wimcmd.txt
wimlib-imagex update /mnt/sources/boot.wim "$image_index" < /tmp/wimcmd.txt
rm -f /tmp/wimcmd.txt

echo "*** Installing GRUB ***"
grub-install --root-directory=/mnt /dev/sda
cd /mnt/boot/grub
cat <<EOF > grub.cfg
menuentry "windows installer" {
    insmod ntfs
    search --set=root --file=/bootmgr
    ntldr /bootmgr
    boot
}
EOF

echo "*** Final checks ***"
ls -lh /mnt/bootmgr /mnt/sources/boot.wim || true
ls -lh /mnt/sources/virtio || true

read -r -p "Optionally unmount /mnt and /root/windisk before reboot? (Y/N): " umount_choice
if [[ "$umount_choice" =~ ^[Yy]$ ]]; then
    umount /root/windisk || true
    umount /mnt || true
fi

read -r -p "Do you want to reboot the system now? (Y/N): " reboot_choice
if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
    echo "*** Rebooting the system... ***"
    reboot
else
    echo "Continuing without rebooting. You can run 'reboot' later to start the Windows installer."
fi
