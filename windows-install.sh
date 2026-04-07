#!/bin/bash

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
