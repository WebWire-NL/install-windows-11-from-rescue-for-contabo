#!/bin/bash
set -euo pipefail

echo "*** Update and Upgrade ***"
apt update -y
apt upgrade -y
echo "Update and Upgrade finish ***"

echo "*** Install linux-image-amd64 ***"
apt update -y
apt install -y linux-image-amd64
echo "Install linux-image-amd64 finish ***"

echo "*** Reinstall initramfs-tools ***"
apt update -y
apt install -y --reinstall initramfs-tools
echo "Reinstall initramfs-tools finish ***"

echo "*** Install grub2, wimtools, ntfs-3g ***"
apt update -y
apt install -y grub2 wimtools ntfs-3g
echo "Install grub2, wimtools, ntfs-3g finish ***"

echo "*** Get the disk size in GB and convert to MB ***"
disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
disk_size_mb=$((disk_size_gb * 1024))
echo "Disk size: ${disk_size_gb} GB (${disk_size_mb} MB)"
echo "Get the disk size in GB and convert to MB finish ***"

echo "*** Calculate partition size (50% of total size) ***"
part_size_mb=$((disk_size_mb / 2))
echo "First partition size: ${part_size_mb} MB"
echo "Calculate partition size (50% of total size) finish ***"

echo "*** Create GPT partition table ***"
parted /dev/sda --script -- mklabel gpt
echo "Create GPT partition table finish ***"

echo "*** Create two partitions ***"
parted /dev/sda --script -- mkpart primary ntfs 1MB ${part_size_mb}MB
echo "Create first partition"
parted /dev/sda --script -- mkpart primary ntfs ${part_size_mb}MB 100%
echo "Create second partition"
echo "Create two partitions finish ***"

echo "*** Inform kernel of partition table changes ***"
partprobe /dev/sda
sleep 5
partprobe /dev/sda
sleep 5
partprobe /dev/sda
sleep 5
echo "Inform kernel of partition table changes finish ***"

echo "*** Check if partitions are created successfully ***"
if lsblk /dev/sda1 && lsblk /dev/sda2; then
    echo "Check if partitions are created successfully finish ***"
else
    echo "Error: Partitions were not created successfully"
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

echo "*** Format the partitions ***"
mkfs.ntfs -f /dev/sda1
echo "Format the partition sda1"
mkfs.ntfs -f /dev/sda2
echo "Format the partition sda2"
echo "Format the partitions finish ***"

echo "*** Install gdisk ***"
apt update -y
apt install -y gdisk
echo "Install gdisk finish ***"

echo "*** Run gdisk commands ***"
echo -e "r\ng\np\nw\nY\n" | gdisk /dev/sda
echo "Run gdisk commands finish ***"

echo "*** Mount /dev/sda1 to /mnt ***"
mkdir -p /mnt
mount /dev/sda1 /mnt
echo "Mount /dev/sda1 to /mnt finish ***"

echo "*** Prepare directory for the Windows disk ***"
cd /root
mkdir -p windisk
echo "Prepare directory for the Windows disk finish ***"

echo "*** Mount /dev/sda2 to windisk ***"
mount /dev/sda2 /root/windisk
echo "Mount /dev/sda2 to windisk finish ***"

echo "*** Install GRUB ***"
grub-install --root-directory=/mnt /dev/sda
echo "Install GRUB finish ***"

echo "*** Edit GRUB configuration ***"
mkdir -p /mnt/boot/grub
cat <<EOF > /mnt/boot/grub/grub.cfg
menuentry "windows installer" {
insmod ntfs
search --no-floppy --set=root --file=/bootmgr
ntldr /bootmgr
boot
}
EOF
echo "Edit GRUB configuration finish ***"

echo "*** Prepare winfile directory ***"
cd /root/windisk
mkdir -p winfile
echo "Prepare winfile directory finish ***"

###############################################################################
# WINDOWS INSTALLATION ISO (no static link, always ask for URL)
###############################################################################
echo "*** Windows installation ISO ***"

WINDOWS_ISO="/root/windisk/Windows.iso"

while true; do
    read -p "Enter the URL for Windows.iso: " windows_url
    if [ -z "\$windows_url" ]; then
        echo "URL cannot be empty. Please provide a valid Windows ISO URL."
        continue
    fi
    echo "Downloading Windows.iso from: \$windows_url"
    if wget -O "\$WINDOWS_ISO" --user-agent="Mozilla/5.0" "\$windows_url"; then
        echo "Windows.iso download completed"
        break
    fi
    echo "ERROR: Failed to download Windows.iso from provided URL. Try again."
done

echo "*** Check if the ISO of Windows ***"
if [ -f "\$WINDOWS_ISO" ]; then
    mount -o loop "\$WINDOWS_ISO" /root/windisk/winfile
    rsync -avz --progress /root/windisk/winfile/ /mnt
    umount /root/windisk/winfile
    echo "Windows ISO contents copied to /mnt"
    echo "Check if the ISO of Windows finish ***"
else
    echo "Failed to find Windows.iso in /root/windisk after download"
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

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

cd /root/windisk
mkdir -p winfile

VIRTIO_ISO="/root/windisk/Virtio.iso"
default_virtio_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

while true; do
    echo "Current Virtio ISO URL: \$default_virtio_url"
    read -p "Press Enter to use this URL, or enter a different Virtio ISO URL: " user_virtio_url
    if [ -n "\$user_virtio_url" ]; then
        default_virtio_url="\$user_virtio_url"
    fi

    echo "Downloading Virtio.iso from: \$default_virtio_url"
    if wget -O "\$VIRTIO_ISO" "\$default_virtio_url"; then
        echo "Virtio.iso download completed"
        break
    fi
    echo "ERROR: Failed to download Virtio.iso. You can enter another URL next."
done

echo "*** Check if the ISO of drivers ***"
if [ -f "\$VIRTIO_ISO" ]; then
    mount -o loop "\$VIRTIO_ISO" /root/windisk/winfile
    mkdir -p /mnt/sources/virtio
    rsync -avz --progress /root/windisk/winfile/ /mnt/sources/virtio
    umount /root/windisk/winfile
    echo "Virtio drivers copied to /mnt/sources/virtio"
    echo "Check if the ISO of drivers finish ***"
else
    echo "Failed to find Virtio.iso in /root/windisk after download"
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

# Verify Virtio tree
if [ ! -d "/mnt/sources/virtio" ]; then
    echo "ERROR: /mnt/sources/virtio directory missing."
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

cd /mnt/sources

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
wimlib-imagex update boot.wim "\$image_index" < cmd.txt
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