#!/bin/bash
set -euo pipefail

# Enable logging
exec > >(tee -i /var/log/install_script.log)
exec 2>&1

# Define total steps
TOTAL_STEPS=10
CURRENT_STEP=0

# Function to display progress
show_progress() {
    local step_message=$1
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo "[Step ${CURRENT_STEP}/${TOTAL_STEPS}] ${step_message}"
}

# Function to handle errors
handle_error() {
    echo "Error occurred during step ${CURRENT_STEP}. Exiting."
    exit 1
}
trap handle_error ERR

# Function to clean up temporary files
cleanup() {
    echo "Cleaning up..."
    umount /mnt/iso_test 2>/dev/null || true
    rm -rf /mnt/iso_test 2>/dev/null || true
}
trap cleanup EXIT

# Step 1: Ensure required packages are installed
show_progress "Ensuring required packages are installed"
required_packages=(
    zram-tools
    aria2
    curl
    wget
    git
    grub2
    wimtools
    ntfs-3g
    gdisk
)

missing_packages=()
for package in "${required_packages[@]}"; do
    if ! dpkg -l | grep -q "^ii  $package"; then
        missing_packages+=("$package")
    fi
done

if [ ${#missing_packages[@]} -gt 0 ]; then
    echo "Installing missing packages: ${missing_packages[*]}"
    apt update -y
    apt install -y "${missing_packages[@]}"
else
    echo "All required packages are already installed."
fi

# Step 2: Partition the disk
show_progress "Partitioning the disk"
disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
disk_size_mb=$((disk_size_gb * 1024))
part_size_mb=$((disk_size_mb / 2))

parted /dev/sda --script -- mklabel gpt
parted /dev/sda --script -- mkpart primary ntfs 1MB ${part_size_mb}MB
parted /dev/sda --script -- mkpart primary ntfs ${part_size_mb}MB 100%
partprobe /dev/sda
sleep 5

mkfs.ntfs -f /dev/sda1
mkfs.ntfs -f /dev/sda2

# Step 3: Install GRUB
show_progress "Installing GRUB"
mount /dev/sda1 /mnt
grub-install --root-directory=/mnt /dev/sda
mkdir -p /mnt/boot/grub
cat <<EOF > /mnt/boot/grub/grub.cfg
menuentry "windows installer" {
    insmod ntfs
    search --no-floppy --set=root --file=/bootmgr
    ntldr /bootmgr
    boot
}
EOF

# Step 4: Handle Virtio drivers
show_progress "Handling Virtio drivers"
virtio_iso="/root/windisk/Virtio.iso"
if [ ! -f "$virtio_iso" ]; then
    read -p "Enter the URL for Virtio.iso (leave blank to use default): " virtio_url
    virtio_url=${virtio_url:-"https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"}
    wget -O "$virtio_iso" "$virtio_url"
fi

mount -o loop "$virtio_iso" /root/windisk/winfile
mkdir -p /mnt/sources/virtio
rsync -avz --progress /root/windisk/winfile/ /mnt/sources/virtio
umount /root/windisk/winfile

# Step 5: Verify Virtio drivers
if [ ! -d "/mnt/sources/virtio" ]; then
    echo "ERROR: Virtio drivers not found. Exiting."
    exit 1
fi

# Step 6: Configure zram
show_progress "Configuring zram if sufficient memory is available"
if [ ! -f /var/log/zram_configured ]; then
    configure_zram_for_iso() {
        local iso_size_bytes=$1
        local zram_device=$2

        free_mem_bytes=$(grep MemAvailable /proc/meminfo | awk '{print $2 * 1024}')
        if (( free_mem_bytes > iso_size_bytes )); then
            modprobe zram
            echo lz4 > /sys/block/$zram_device/comp_algorithm
            echo $((iso_size_bytes / 1024 / 1024))M > /sys/block/$zram_device/disksize
            mke2fs -q -t ext4 /dev/$zram_device
            mkdir -p /mnt/zram_$zram_device
            mount /dev/$zram_device /mnt/zram_$zram_device
            return 0
        else
            return 1
        fi
    }

    if configure_zram_for_iso 1073741824 zram0; then
        echo "zram configured successfully."
    else
        echo "zram configuration skipped due to insufficient memory."
    fi
fi

# Step 7: Final checks
show_progress "Performing final checks"
if [ ! -f "/mnt/bootmgr" ]; then
    echo "ERROR: /mnt/bootmgr not found. Exiting."
    exit 1
fi
if [ ! -f "/mnt/sources/boot.wim" ]; then
    echo "ERROR: /mnt/sources/boot.wim not found. Exiting."
    exit 1
fi

# Step 8: Handle WIM file updates
show_progress "Updating WIM file with VirtIO drivers"
cd /mnt/sources

touch cmd.txt
echo 'add virtio /virtio_drivers' >> cmd.txt

# List images in boot.wim
wimlib-imagex info boot.wim

# Prompt user to enter a valid image index
echo "Please enter a valid image index from the list above:"
read image_index

# Check if boot.wim exists before updating
if [ -f boot.wim ]; then
    wimlib-imagex update boot.wim $image_index < cmd.txt
    echo "WIM file updated successfully."
else
    echo "ERROR: boot.wim not found. Exiting."
    exit 1
fi

# Step 9: Prompt for reboot
show_progress "Prompting for reboot"
read -p "Do you want to reboot the system now into the Windows installer? (Y/N): " reboot_choice
if [[ "$reboot_choice" == "Y" || "$reboot_choice" == "y" ]]; then
    echo "Rebooting the system..."
    reboot
else
    echo "Setup completed. You can reboot later with 'reboot' to start the Windows installer."
fi

show_progress "Script completed successfully!"
