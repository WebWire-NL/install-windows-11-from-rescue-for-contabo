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
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    local dir
    local base
    dir="$(dirname "$output")"
    base="$(basename "$output")"

    if command_exists aria2c; then
        if pgrep -f "aria2c .*--dir=$dir .*--out=$base" >/dev/null 2>&1; then
            echo "Stopping stale aria2c process for $output"
            pgrep -f "aria2c .*--dir=$dir .*--out=$base" | xargs -r kill
        fi

        echo "Downloading $output with aria2c (resume support)"
        set +e
        aria2c --continue=true --file-allocation=none --enable-http-keep-alive=true \
            --enable-http2=true --max-connection-per-server=64 --split=64 --min-split-size=4M \
            --max-tries=0 --retry-wait=15 --timeout=60 --retry-connrefused=true \
            --download-result=full --user-agent="$ua" \
            -d "$dir" -o "$base" --input-file="$session" "$url" >"$log" 2>&1
        local aria2_rc=$?
        set -e

        if [ "$aria2_rc" -ne 0 ]; then
            echo "WARNING: aria2c failed with exit code $aria2_rc. Falling back to curl."
            if command_exists curl; then
                curl --http2 --compressed --retry 5 --retry-delay 10 --retry-connrefused \
                    --location --continue-at - --user-agent "$ua" --output "$output" "$url"
            else
                echo "WARNING: curl not available. Falling back to wget."
                wget --tries=0 --waitretry=5 --retry-connrefused --continue --timeout=60 \
                    --user-agent="$ua" -O "$output" "$url"
            fi
        fi
    else
        echo "aria2c not available, downloading $output with wget"
        wget --tries=5 --waitretry=5 --retry-connrefused --continue --timeout=60 \
            --user-agent="$ua" -O "$output" "$url"
    fi
}

get_content_length() {
    local url="$1"
    curl -fsI "$url" | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r'
}

echo "*** Preparing system packages ***"
ROOT_AVAIL_KB=$(df --output=avail / | tail -n 1)
install_packages_to_tmp() {
    mkdir -p /tmp/apt-archives /tmp/apt-lists /tmp/apt-pkgcache /tmp/toolkit
    export TMPDIR=/tmp
    apt-get -y -o Dir::State::lists=/tmp/apt-lists \
        -o Dir::Cache::archives=/tmp/apt-archives \
        -o Dir::Cache::pkgcache=/tmp/apt-pkgcache/pkgcache.bin \
        -o Dir::Cache::srcpkgcache=/tmp/apt-pkgcache/srcpkgcache.bin \
        update
    apt-get -y -o Dir::State::lists=/tmp/apt-lists \
        -o Dir::Cache::archives=/tmp/apt-archives \
        -o Dir::Cache::pkgcache=/tmp/apt-pkgcache/pkgcache.bin \
        -o Dir::Cache::srcpkgcache=/tmp/apt-pkgcache/srcpkgcache.bin \
        --download-only --no-install-recommends install grub2 wimtools ntfs-3g gdisk rsync curl wget aria2 zram-tools
    for deb in /tmp/apt-archives/*.deb; do
        dpkg-deb -x "$deb" /tmp/toolkit
    done
    export PATH="/tmp/toolkit/usr/sbin:/tmp/toolkit/usr/bin:/tmp/toolkit/sbin:/tmp/toolkit/bin:$PATH"
    export LD_LIBRARY_PATH="/tmp/toolkit/lib:/tmp/toolkit/usr/lib:${LD_LIBRARY_PATH:-}"
}

if [ "$ROOT_AVAIL_KB" -lt 500000 ]; then
    echo "WARNING: low root filesystem space ($ROOT_AVAIL_KB KB). Attempting to provision required tools into /tmp instead of installing to root."
    install_packages_to_tmp
else
    mkdir -p /tmp/apt-archives /tmp/apt-lists /tmp/apt-pkgcache
    export TMPDIR=/tmp
    apt-get -y -o Dir::State::lists=/tmp/apt-lists \
        -o Dir::Cache::archives=/tmp/apt-archives \
        -o Dir::Cache::pkgcache=/tmp/apt-pkgcache/pkgcache.bin \
        -o Dir::Cache::srcpkgcache=/tmp/apt-pkgcache/srcpkgcache.bin \
        update
    apt-get -y -o Dir::State::lists=/tmp/apt-lists \
        -o Dir::Cache::archives=/tmp/apt-archives \
        -o Dir::Cache::pkgcache=/tmp/apt-pkgcache/pkgcache.bin \
        -o Dir::Cache::srcpkgcache=/tmp/apt-pkgcache/srcpkgcache.bin \
        --no-install-recommends install grub2 wimtools ntfs-3g gdisk rsync curl wget aria2 zram-tools
    apt-get -y -o Dir::State::lists=/tmp/apt-lists \
        -o Dir::Cache::archives=/tmp/apt-archives \
        -o Dir::Cache::pkgcache=/tmp/apt-pkgcache/pkgcache.bin \
        -o Dir::Cache::srcpkgcache=/tmp/apt-pkgcache/srcpkgcache.bin \
        clean
    rm -rf /tmp/apt-archives /tmp/apt-lists /tmp/apt-pkgcache
fi

# Verify required tools exist before continuing
required_cmds=(parted mkfs.ntfs mkfs.ext4 mount rsync wimlib-imagex grub-install curl grep awk pgrep xargs dpkg-deb modprobe)
for cmd in "${required_cmds[@]}"; do
    if ! command_exists "$cmd"; then
        echo "ERROR: required command '$cmd' is missing."
        echo "If the rescue environment is low on disk space, free space or provide the missing tool in the environment before rerunning the script."
        exit 1
    fi
 done

disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
disk_size_mb=$((disk_size_gb * 1024))
part_size_mb=$((disk_size_mb / 2))
echo "*** Creating disk partitions ***"
if command_exists sgdisk; then
    echo "Wiping existing partition table on /dev/sda..."
    sgdisk --zap-all /dev/sda || true
fi
if command_exists wipefs; then
    echo "Wiping filesystem signatures on /dev/sda..."
    wipefs -a /dev/sda || true
fi
parted /dev/sda --script -- mklabel gpt
parted /dev/sda --script -- mkpart primary ntfs 1MB ${part_size_mb}MB
parted /dev/sda --script -- mkpart primary ntfs ${part_size_mb}MB 100%
partprobe /dev/sda
sleep 30

mkfs.ntfs -f /dev/sda1
mkfs.ntfs -f /dev/sda2

echo "*** Refreshing partition table ***"
partprobe /dev/sda
sleep 5

echo "*** Mounting partitions ***"
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

echo "Detected available RAM: ${AVAILABLE_RAM_MB}MB"
echo "Reserving 512MB; safe RAM for zram: ${SAFE_RAM_MB}MB"
echo "Estimated ISO download size: ${TOTAL_ISO_SIZE_MB}MB"

if command_exists modprobe; then
    modprobe zram >/dev/null 2>&1 || true
fi

if [ ! -e /dev/zram0 ]; then
    echo "WARNING: zram device /dev/zram0 not present after loading module."
fi

USE_ZRAM=0
if [ "$TOTAL_ISO_SIZE_MB" -le "$SAFE_RAM_MB" ]; then
    echo "Creating zram of size ${TOTAL_ISO_SIZE_MB}MB..."
    echo lz4 > /sys/block/zram0/comp_algorithm
    echo "${TOTAL_ISO_SIZE_MB}M" > /sys/block/zram0/disksize
    zram_disksize=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
    if [ "$zram_disksize" -eq 0 ]; then
        echo "ERROR: zram disksize remained 0 after initialization."
        echo "Skipping zram and using disk fallback."
        ls -l /dev/zram0 /sys/block/zram0 2>/dev/null || true
        cat /sys/block/zram0/disksize 2>/dev/null || true
    elif mkfs.ext4 -q /dev/zram0 && mkdir -p /mnt/zram0 && mount /dev/zram0 /mnt/zram0; then
        USE_ZRAM=1
        echo "zram mounted at /mnt/zram0."
    else
        echo "WARNING: zram format or mount failed; checking zram state and using disk fallback."
        ls -l /dev/zram0 /sys/block/zram0 2>/dev/null || true
        cat /sys/block/zram0/disksize 2>/dev/null || true
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
    DOWNLOAD_DIR="/root/windisk"
    DOWNLOAD_AVAIL=$(df --output=avail "$DOWNLOAD_DIR" | tail -n 1)
    DOWNLOAD_AVAIL_BYTES=$((DOWNLOAD_AVAIL * 1024))
    if [ "$DOWNLOAD_AVAIL_BYTES" -lt "$REQUIRED_DISK_BYTES" ]; then
        echo "ERROR: Not enough disk space on $DOWNLOAD_DIR for ISO downloads."
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
wimlib-imagex info /mnt/sources/boot.wim > /tmp/bootwim_info.txt

echo "*** Selecting boot.wim image index automatically ***"
auto_image_index=$(awk '
    /Index:/ { idx=$2 }
    /Name:/ {
        if ($0 ~ /Windows Setup/ || $0 ~ /Microsoft Windows Setup/ || $0 ~ /Setup \(amd64\)/) {
            print idx
            exit
        }
        if ($0 ~ /Windows PE/ && fallback_idx == "") {
            fallback_idx = idx
        }
    }
    END {
        if (idx != "" && fallback_idx == "") {
            print idx
        } else if (fallback_idx != "") {
            print fallback_idx
        }
    }
' /tmp/bootwim_info.txt)

if [ -n "$auto_image_index" ]; then
    echo "Auto-selected boot.wim image index: $auto_image_index"
    image_index="$auto_image_index"
else
    read -r -p "Enter the image index you want to update with VirtIO drivers: " image_index
fi

if [ ! -d "/mnt/sources/virtio" ]; then
    echo "ERROR: VirtIO source directory /mnt/sources/virtio not found."
    exit 1
fi

echo "add /mnt/sources/virtio /virtio_drivers" > /tmp/wimcmd.txt
wimlib-imagex update /mnt/sources/boot.wim "$image_index" < /tmp/wimcmd.txt
rm -f /tmp/wimcmd.txt /tmp/bootwim_info.txt

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
