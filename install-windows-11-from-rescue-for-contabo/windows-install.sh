#!/bin/bash

# Enable strict mode for safer script execution
set -euo pipefail

# Ensure all /dev/sda partitions are unmounted and swap is off before partitioning
echo "Deactivating swap and unmounting all /dev/sda partitions..."
swapoff -a
for part in $(lsblk -ln -o NAME | grep '^sda' | grep -v '^sda$'); do
    umount /dev/$part 2>/dev/null || true
done
echo "All /dev/sda partitions unmounted and swap deactivated."

# Default URL for Windows ISO
DEFAULT_WINDOWS_ISO_URL="https://example.com/windows.iso"

# Prompt user for URL or use default
read -p "Enter the URL for Windows.iso (leave blank to use default): " windows_url
windows_url=${windows_url:-$DEFAULT_WINDOWS_ISO_URL}

# Create a temporary swap file for low-memory environments
SWAPFILE="/swapfile"
if [ ! -f "$SWAPFILE" ]; then
    echo "Creating temporary swap file..."
    fallocate -l 1G "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"
    echo "Temporary swap file created and activated."
fi

# Optimize aria2 download settings for VPS resources
ARIA2_OPTS="--max-connection-per-server=16 --split=16 --min-split-size=1M --timeout=60 --retry-wait=30"
retry_download() {
    local url="$1"
    local output="$2"
    aria2c $ARIA2_OPTS -o "$output" "$url"
}

# Add bypass for TPM and Secure Boot checks
cat <<EOF > /mnt/bypass.bat
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
EOF

# Ensure bypass.bat is copied to the correct location
cp /mnt/bypass.bat /mnt/sources/

# Check and unload zram if needed
if mount | grep -q "/mnt/zram0"; then
    echo "Unmounting zram..."
    umount /mnt/zram0 || true
    echo "Removing zram device..."
    swapoff /dev/zram0 || true
    echo 1 > /sys/class/zram-control/hot_remove
    echo "zram unloaded."
fi

# Determine the sizes of both ISOs before creating zram
WINDOWS_ISO_URL="$windows_url"
VIRTIO_ISO_URL="$DEFAULT_VIRTIO_ISO_URL"

WINDOWS_ISO_SIZE=$(curl -sI "$WINDOWS_ISO_URL" | grep -i Content-Length | awk '{print $2}' | tr -d '\r')
VIRTIO_ISO_SIZE=$(curl -sI "$VIRTIO_ISO_URL" | grep -i Content-Length | awk '{print $2}' | tr -d '\r')

if [ -z "$WINDOWS_ISO_SIZE" ] || [ -z "$VIRTIO_ISO_SIZE" ]; then
    echo "ERROR: Unable to determine ISO sizes. Exiting."
    exit 1
fi

TOTAL_ISO_SIZE=$((WINDOWS_ISO_SIZE + VIRTIO_ISO_SIZE))
TOTAL_ISO_SIZE_GB=$((TOTAL_ISO_SIZE / 1024 / 1024 / 1024 + 1))

# Remove existing zram if present
if mount | grep -q "/mnt/zram0"; then
    echo "Unmounting existing zram..."
    umount /mnt/zram0 || true
    swapoff /dev/zram0 || true
    echo 1 > /sys/class/zram-control/hot_remove
    echo "Existing zram removed."
fi

# Create a new zram with appropriate size
ZRAM_SIZE_MB=$((TOTAL_ISO_SIZE_GB * 1024 + 512)) # Add 512 MB buffer
AVAILABLE_RAM_MB=$(free -m | awk '/^Mem:/{print $7}')

if [ "$ZRAM_SIZE_MB" -le "$AVAILABLE_RAM_MB" ]; then
    echo "Creating zram of size ${ZRAM_SIZE_MB}MB..."
    echo lz4 > /sys/block/zram0/comp_algorithm
    echo "${ZRAM_SIZE_MB}M" > /sys/block/zram0/disksize
    if mkswap /dev/zram0 && swapon /dev/zram0; then
        mkdir -p /mnt/zram0/windisk
        WINDOWS_ISO="/mnt/zram0/windisk/Windows.iso"
        VIRTIO_ISO="/mnt/zram0/windisk/VirtIO.iso"
        echo "zram created and mounted at /mnt/zram0."
    else
        echo "ERROR: Failed to initialize zram. Falling back to local storage."
        WINDOWS_ISO="/root/windisk/Windows.iso"
        VIRTIO_ISO="/root/windisk/VirtIO.iso"
    fi
else
    echo "WARNING: Insufficient RAM to create zram of size ${ZRAM_SIZE_MB}MB. Falling back to local storage."
    WINDOWS_ISO="/root/windisk/Windows.iso"
    VIRTIO_ISO="/root/windisk/VirtIO.iso"
fi

# Log zram size for debugging
if [ -e /sys/block/zram0/disksize ]; then
    echo "zram size: $(cat /sys/block/zram0/disksize)"
else
    echo "zram not created."
fi

# Download the ISOs
retry_download "$WINDOWS_ISO_URL" "$WINDOWS_ISO"
retry_download "$VIRTIO_ISO_URL" "$VIRTIO_ISO"

# Verify download success
if [ ! -f "$WINDOWS_ISO" ] || [ ! -f "$VIRTIO_ISO" ]; then
    echo "ERROR: Failed to download one or both ISOs. Exiting."
    exit 1
fi

echo "Windows ISO downloaded successfully to $WINDOWS_ISO."
echo "VirtIO ISO downloaded successfully to $VIRTIO_ISO."

# Default URL for VirtIO ISO
DEFAULT_VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

# Prompt user for URL or use default
read -p "Enter the URL for Virtio.iso (leave blank to use default): " virtio_url
virtio_url=${virtio_url:-$DEFAULT_VIRTIO_ISO_URL}

# Mount and copy drivers
mount -o loop "$VIRTIO_ISO" /root/windisk/winfile
mkdir -p /mnt/sources/virtio
rsync -avz --progress /root/windisk/winfile/ /mnt/sources/virtio
umount /root/windisk/winfile

# Verify Virtio tree
if [ ! -d "/mnt/sources/virtio" ]; then
    echo "ERROR: /mnt/sources/virtio directory missing."
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

# Check available space and decide clone location
CLONE_DIR="/root/install-windows-11-from-rescue-for-contabo"
if [ $(df --output=avail / | tail -1) -lt 100000 ]; then
    echo "Low disk space detected. Using /mnt/zram0 for cloning."
    CLONE_DIR="/mnt/zram0/install-windows-11-from-rescue-for-contabo"
    mkdir -p /mnt/zram0
fi

# Free up space if necessary
echo "Freeing up space..."
rm -rf /root/install-windows-11-from-rescue-for-contabo || true
rm -rf /root/windisk || true

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
partprobe /dev/sda
sleep 30

mkfs.ntfs -f /dev/sda1
mkfs.ntfs -f /dev/sda2
echo "NTFS partitions created"
echo -e "r\ng\np\nw\nY\n" | gdisk /dev/sda

mount /dev/sda1 /mnt
cd ~
mkdir windisk
mount /dev/sda2 windisk
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
