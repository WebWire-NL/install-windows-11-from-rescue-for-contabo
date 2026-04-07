#!/bin/bash

# Ensure all /dev/sda partitions are unmounted and swap is off before partitioning
echo "Deactivating swap and unmounting all /dev/sda partitions..."
swapoff -a
for part in $(lsblk -ln -o NAME | grep '^sda' | grep -v '^sda$'); do
    umount /dev/$part 2>/dev/null || true
done
echo "All /dev/sda partitions unmounted and swap deactivated."

# Create the directory for the Windows ISO if it doesn't exist
mkdir -p /root/windisk

# Default URLs for ISOs
DEFAULT_WINDOWS_ISO_URL="https://bit.ly/3UGzNcB"
DEFAULT_VIRTIO_ISO_URL="https://bit.ly/4d1g7Ht"

# Prompt user for Windows ISO URL or use default
read -p "Enter the URL for Windows.iso (leave blank to use default): " windows_url
windows_url=${windows_url:-$DEFAULT_WINDOWS_ISO_URL}

# Replace retry_download with wget for downloading ISOs
# Download the ISO
WINDOWS_ISO="/root/windisk/Windows.iso"
echo "Downloading Windows ISO..."
wget -O "$WINDOWS_ISO" "$windows_url"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download Windows ISO. Exiting."
    exit 1
fi

# Verify the ISO file exists
if [ ! -f "$WINDOWS_ISO" ]; then
    echo "ERROR: Windows ISO not found after download. Exiting."
    exit 1
fi

# Prompt user for VirtIO ISO URL or use default
read -p "Enter the URL for Virtio.iso (leave blank to use default): " virtio_url
virtio_url=${virtio_url:-$DEFAULT_VIRTIO_ISO_URL}

# Download the VirtIO ISO
VIRTIO_ISO="/root/windisk/Virtio.iso"
echo "Downloading VirtIO ISO..."
wget -O "$VIRTIO_ISO" "$virtio_url"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download VirtIO ISO. Exiting."
    exit 1
fi

# Verify the ISO file exists
if [ ! -f "$VIRTIO_ISO" ]; then
    echo "ERROR: VirtIO ISO not found after download. Exiting."
    exit 1
fi

# Partitioning Logic
disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
disk_size_mb=$((disk_size_gb * 1024))
part_size_mb=$((disk_size_mb / 2))

echo "Creating GPT partition table and partitions..."
parted /dev/sda --script -- mklabel gpt
parted /dev/sda --script -- mkpart primary ntfs 1MB ${part_size_mb}MB
parted /dev/sda --script -- mkpart primary ntfs ${part_size_mb}MB 100%

partprobe /dev/sda
sleep 30

echo "Formatting partitions..."
mkfs.ntfs -f /dev/sda1
mkfs.ntfs -f /dev/sda2

# Mount partitions
mount /dev/sda1 /mnt
mkdir -p /root/windisk
mount /dev/sda2 /root/windisk

# Install GRUB
grub-install --root-directory=/mnt /dev/sda
cat <<EOF > /mnt/boot/grub/grub.cfg
menuentry "windows installer" {
    insmod ntfs
    search --set=root --file=/bootmgr
    ntldr /bootmgr
    boot
}
EOF

# Mount and copy VirtIO drivers
mount -o loop "$VIRTIO_ISO" /root/windisk/winfile
mkdir -p /mnt/sources/virtio
rsync -avz --progress /root/windisk/winfile/ /mnt/sources/virtio
umount /root/windisk/winfile

# Verify critical files
if [ ! -f "/mnt/bootmgr" ]; then
    echo "ERROR: /mnt/bootmgr not found; Windows may not boot."
    exit 1
fi
if [ ! -f "/mnt/sources/boot.wim" ]; then
    echo "ERROR: /mnt/sources/boot.wim not found."
    exit 1
fi

# Final checks and reboot prompt
read -p "Optionally unmount /mnt and /root/windisk before reboot? (Y/N): " umount_choice
if [[ "$umount_choice" == "Y" || "$umount_choice" == "y" ]]; then
    umount /root/windisk || echo "Could not unmount /root/windisk (maybe already unmounted)."
    umount /mnt || echo "Could not unmount /mnt (maybe busy, will be handled on reboot)."
fi

# Commented out reboot section for now
# read -p "Do you want to reboot the system now? (Y/N): " reboot_choice
# if [[ "$reboot_choice" == "Y" || "$reboot_choice" == "y" ]]; then
#     echo "*** Rebooting the system... ***"
#     reboot
# else
#     echo "Continuing without rebooting. You can run 'reboot' later to start the Windows installer."
# fi

# Ensure the script can handle URLs with special characters
parse_url() {
    local url="$1"
    if [[ "$url" =~ ^https?:// ]]; then
        echo "Valid URL: $url"
    else
        echo "Invalid URL: $url"
        exit 1
    fi
}

# Example usage
parse_url "$windows_url"
parse_url "$virtio_url"
