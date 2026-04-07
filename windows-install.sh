#!/bin/bash
set -euo pipefail

# Default URL for Windows ISO
DEFAULT_WINDOWS_ISO_URL="https://example.com/windows.iso"

# Prompt user for URL or use default
read -p "Enter the URL for Windows.iso (leave blank to use default): " windows_url
windows_url=${windows_url:-$DEFAULT_WINDOWS_ISO_URL}

# Download the ISO
WINDOWS_ISO="/root/windisk/Windows.iso"
retry_download "$windows_url" "$WINDOWS_ISO"

# Basic verification of Windows files
if [ ! -f "/mnt/bootmgr" ]; then
    echo "ERROR: /mnt/bootmgr not found; Windows may not boot."
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi
if [ ! -f "/mnt/sources/boot.wim" ]; then
    echo "ERROR: /mnt/sources/boot.wim not found."
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

###############################################################################
# VIRTIO DRIVERS ISO (keeps a default, but you can change it)
###############################################################################
echo "*** Virtio drivers ISO ***"

# Default URL for VirtIO ISO
DEFAULT_VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

# Prompt user for URL or use default
read -p "Enter the URL for Virtio.iso (leave blank to use default): " virtio_url
virtio_url=${virtio_url:-$DEFAULT_VIRTIO_ISO_URL}

# Download the ISO
VIRTIO_ISO="/root/windisk/Virtio.iso"
retry_download "$virtio_url" "$VIRTIO_ISO"

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

cd /mnt/sources

# Automate wimlib-imagex image index selection
image_index=2  # Default to Microsoft Windows Setup (x64)
echo "Using default image index: $image_index"

echo "*** Prepare cmd.txt for wimlib ***"
echo 'add virtio /virtio_drivers' > cmd.txt

echo "*** List images in boot.wim ***"
wimlib-imagex info boot.wim

echo "Please enter a valid image index from the list above (usually '2' = Microsoft Windows Setup (x64)):"
read image_index
echo "Selected image index: \$image_index"

if [ -z "\$image_index" ]; then
    echo "ERROR: No image index provided."
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

echo "*** Updating boot.wim with Virtio drivers ***"
before_size=$(stat -c%s boot.wim)
wimlib-imagex update boot.wim "$image_index" < cmd.txt
after_size=$(stat -c%s boot.wim)
echo "boot.wim size before: \$before_size bytes"
echo "boot.wim size after : \$after_size bytes"
echo "Update boot.wim finish ***"

echo "*** Final checks ***"
ls -lh /mnt/bootmgr /mnt/sources/boot.wim
ls -lh /mnt/sources/virtio || true

read -p "Optionally unmount /mnt and /root/windisk before reboot? (Y/N): " umount_choice
if [[ "\$umount_choice" == "Y" || "\$umount_choice" == "y" ]]; then
    umount /root/windisk || echo "Could not unmount /root/windisk (maybe already unmounted)."
    umount /mnt || echo "Could not unmount /mnt (maybe busy, will be handled on reboot)."
fi

echo "*** Reboot prompt ***"
read -p "Do you want to reboot the system now? (Y/N): " reboot_choice

if [[ "\$reboot_choice" == "Y" || "\$reboot_choice" == "y" ]]; then
    echo "*** Rebooting the system... ***"
    reboot
else
    echo "Continuing without rebooting. You can run 'reboot' later to start the Windows installer."
fi