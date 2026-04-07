#!/bin/bash
set -euo pipefail

echo "*** Update and Upgrade ***"
apt update -y && apt upgrade -y
echo "Update and Upgrade finish ***"

echo "*** Installing all required tools ***"

tools=(
    linux-image-amd64
    initramfs-tools
    grub2
    wimtools
    ntfs-3g
    gdisk
    parted
)

for tool in "${tools[@]}"; do
    echo "Installing $tool..."
    apt install -y "$tool"
    if dpkg -l | grep -q "$tool"; then
        echo "$tool installed successfully."
    else
        echo "Failed to install $tool."
        exit 1
    fi
done

echo "All required tools installed successfully."

echo "*** Get the disk size in GB and convert to MB ***"
disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
disk_size_mb=$((disk_size_gb * 1024))
echo "Disk size: ${disk_size_gb} GB (${disk_size_mb} MB)"

echo "*** Calculate partition size (50% of total size) ***"
part_size_mb=$((disk_size_mb / 2))
echo "First partition size: ${part_size_mb} MB"
echo "Calculate partition size finish ***"

echo "*** Create GPT partition table ***"
parted /dev/sda --script -- mklabel gpt
echo "Create GPT partition table finish ***"

echo "*** Create two NTFS partitions ***"
parted /dev/sda --script -- mkpart primary ntfs 1MB ${part_size_mb}MB
echo "Created first partition /dev/sda1"
parted /dev/sda --script -- mkpart primary ntfs ${part_size_mb}MB 100%
echo "Created second partition /dev/sda2"
echo "Create two partitions finish ***"

echo "*** Inform kernel of partition table changes ***"
partprobe /dev/sda
sleep 5
partprobe /dev/sda
sleep 5
partprobe /dev/sda
sleep 5
echo "Inform kernel of partition table changes finish ***"

echo "*** Check if partitions exist ***"
if lsblk /dev/sda1 && lsblk /dev/sda2; then
    echo "Partitions /dev/sda1 and /dev/sda2 created successfully"
else
    echo "ERROR: Partitions were not created successfully"
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

echo "*** Format the partitions as NTFS ***"
mkfs.ntfs -f /dev/sda1
echo "Formatted /dev/sda1"
mkfs.ntfs -f /dev/sda2
echo "Formatted /dev/sda2"
echo "Format partitions finish ***"

echo "*** Run gdisk to repair GPT/MBR if needed ***"
echo -e "r\ng\np\nw\nY\n" | gdisk /dev/sda
echo "gdisk repair (if needed) finish ***"

echo "*** Mount /dev/sda1 to /mnt ***"
mkdir -p /mnt
mount /dev/sda1 /mnt
echo "Mounted /dev/sda1 on /mnt"

echo "*** Prepare /root/windisk and mount /dev/sda2 there ***"
cd /root
mkdir -p windisk
mount /dev/sda2 windisk
echo "Mounted /dev/sda2 on /root/windisk"

echo "*** Install GRUB to /dev/sda ***"
grub-install --root-directory=/mnt /dev/sda
echo "Install GRUB finish ***"

echo "*** Write GRUB configuration ***"
mkdir -p /mnt/boot/grub
cat <<EOF > /mnt/boot/grub/grub.cfg
menuentry "windows installer" {
    insmod ntfs
    search --no-floppy --set=root --file=/bootmgr
    ntldr /bootmgr
    boot
}
EOF
echo "GRUB configuration written ***"

echo "*** Prepare directory for Windows ISO contents ***"
cd /root/windisk
mkdir -p winfile
echo "Prepare winfile directory finish ***"

###############################################################################
# WINDOWS INSTALLATION ISO
###############################################################################
echo "*** Windows installation ISO ***"

# Try to auto-detect existing Windows.iso
if [ -f "/root/windisk/Windows.iso" ]; then
    echo "Found existing /root/windisk/Windows.iso; using it."
else
    read -p "Windows.iso not found in /root/windisk. Download it automatically? (Y/N): " download_choice

    if [[ "$download_choice" == "Y" || "$download_choice" == "y" ]]; then
        read -p "Enter URL for Windows.iso (leave blank to use default): " windows_url
        if [ -z "$windows_url" ]; then
            windows_url="https://bit.ly/3UGzNcB"
        fi

        echo "Downloading Windows.iso from: $windows_url"
        if ! wget -O /root/windisk/Windows.iso --user-agent="Mozilla/5.0" "$windows_url"; then
            echo "ERROR: Failed to download Windows.iso"
            read -p "Press any key to exit..." -n1 -s
            exit 1
        fi
    else
        echo "Please upload your Windows installation ISO to /root/windisk and name it 'Windows.iso'."
        read -p "Press any key to continue after uploading..." -n1 -s
    fi
fi

echo "*** Check if the ISO of Windows exists ***"
if [ ! -f "/root/windisk/Windows.iso" ]; then
    echo "ERROR: Windows.iso still not found in /root/windisk"
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

echo "Mounting Windows.iso and copying files to /mnt..."
mount -o loop /root/windisk/Windows.iso /root/windisk/winfile
rsync -avz --progress /root/windisk/winfile/ /mnt
umount /root/windisk/winfile
echo "Windows ISO contents copied to /mnt"
echo "Check if the ISO of Windows finish ***"

###############################################################################
# VIRTIO DRIVERS ISO
###############################################################################
echo "*** Virtio drivers ISO ***"

# Ensure winfile exists for reuse
mkdir -p /root/windisk/winfile
cd /root/windisk

# Try to auto-detect Virtio.iso
if [ -f "/root/windisk/Virtio.iso" ]; then
    echo "Found existing /root/windisk/Virtio.iso; using it."
else
    read -p "Virtio.iso not found in /root/windisk. Download Virtio drivers ISO automatically? (Y/N): " download_choice

    if [[ "$download_choice" == "Y" || "$download_choice" == "y" ]]; then
        read -p "Enter URL for Virtio.iso (leave blank for Fedora virtio-win ISO): " virtio_url
        if [ -z "$virtio_url" ]; then
            virtio_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
        fi

        echo "Downloading Virtio.iso from: $virtio_url"
        if ! wget -O /root/windisk/Virtio.iso "$virtio_url"; then
            echo "ERROR: Failed to download Virtio.iso"
            read -p "Press any key to exit..." -n1 -s
            exit 1
        fi
    else
        echo "Please upload the Virtio drivers ISO to /root/windisk and name it 'Virtio.iso'."
        read -p "Press any key to continue after uploading..." -n1 -s
    fi
fi

echo "*** Check if the ISO of drivers exists ***"
if [ ! -f "/root/windisk/Virtio.iso" ]; then
    echo "ERROR: Virtio.iso still not found in /root/windisk"
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

echo "Mounting Virtio.iso and copying drivers into /mnt/sources/virtio..."
mount -o loop /root/windisk/Virtio.iso /root/windisk/winfile
mkdir -p /mnt/sources/virtio
rsync -avz --progress /root/windisk/winfile/ /mnt/sources/virtio
umount /root/windisk/winfile
echo "Virtio drivers copied to /mnt/sources/virtio"
echo "Check if the ISO of drivers finish ***"

###############################################################################
# INJECT VIRTIO DRIVERS INTO boot.wim
###############################################################################
echo "*** Prepare wimlib command file ***"
cd /mnt/sources

if [ ! -f "boot.wim" ]; then
    echo "ERROR: boot.wim not found in /mnt/sources; Windows ISO copy may have failed."
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

echo 'add virtio /virtio_drivers' > cmd.txt

echo "*** List images in boot.wim ***"
wimlib-imagex info boot.wim

echo "Please enter the image index corresponding to 'Microsoft Windows Setup (x64)' (boot index is usually 2):"
read image_index

if [ -z "$image_index" ]; then
    echo "ERROR: No image index provided."
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

echo "*** Injecting Virtio drivers into boot.wim (image index $image_index) ***"
wimlib-imagex update boot.wim "$image_index" < cmd.txt
echo "Virtio drivers injection into boot.wim finished ***"

###############################################################################
# REBOOT
###############################################################################
read -p "Do you want to reboot the system now into the Windows installer? (Y/N): " reboot_choice

if [[ "$reboot_choice" == "Y" || "$reboot_choice" == "y" ]]; then
    echo "*** Rebooting the system... ***"
    reboot
else
    echo "Setup completed. You can reboot later with 'reboot' to start the Windows installer."
fi
