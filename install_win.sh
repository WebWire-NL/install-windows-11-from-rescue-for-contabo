#!/bin/bash
set -euo pipefail

# Enable logging
exec > >(tee -i /var/log/install_script.log)
exec 2>&1

# Define total steps
TOTAL_STEPS=7
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
    umount /mnt/zram* 2>/dev/null || true
    rm -rf /mnt/zram* 2>/dev/null || true
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

# Step 2: Update package lists
show_progress "Updating package lists"
if [ ! -f /var/log/apt_update_done ]; then
    apt update -y && touch /var/log/apt_update_done
else
    echo "Package lists already updated. Skipping."
fi

# Step 3: Prompt for ISO URLs and fetch their sizes
show_progress "Prompting for ISO URLs and fetching their sizes"
if [ ! -f /var/log/iso_sizes_checked ]; then
    read -p "Enter the URL for the Windows ISO: " WINDOWS_ISO_URL
    read -p "Enter the URL for the VirtIO ISO: " VIRTIO_ISO_URL

    fetch_iso_size() {
        local url=$1
        local size=$(curl -sI "$url" | grep -i Content-Length | awk '{print $2}' | tr -d '\r')
        if [[ -z "$size" ]]; then
            echo "ERROR: Unable to fetch ISO size from URL: $url"
            exit 1
        fi
        echo $size
    }

    WINDOWS_ISO_SIZE_BYTES=$(fetch_iso_size "$WINDOWS_ISO_URL")
    VIRTIO_ISO_SIZE_BYTES=$(fetch_iso_size "$VIRTIO_ISO_URL")
    TOTAL_ISO_SIZE_BYTES=$((WINDOWS_ISO_SIZE_BYTES + VIRTIO_ISO_SIZE_BYTES))

    echo "$WINDOWS_ISO_URL" > /var/log/windows_iso_url
    echo "$VIRTIO_ISO_URL" > /var/log/virtio_iso_url
    echo "$WINDOWS_ISO_SIZE_BYTES" > /var/log/windows_iso_size
    echo "$VIRTIO_ISO_SIZE_BYTES" > /var/log/virtio_iso_size
    echo "$TOTAL_ISO_SIZE_BYTES" > /var/log/total_iso_size
else
    echo "ISO sizes already checked. Skipping."
    WINDOWS_ISO_URL=$(cat /var/log/windows_iso_url)
    VIRTIO_ISO_URL=$(cat /var/log/virtio_iso_url)
    WINDOWS_ISO_SIZE_BYTES=$(cat /var/log/windows_iso_size)
    VIRTIO_ISO_SIZE_BYTES=$(cat /var/log/virtio_iso_size)
    TOTAL_ISO_SIZE_BYTES=$(cat /var/log/total_iso_size)
fi

# Step 4: Configure zram if possible
show_progress "Configuring zram if sufficient memory is available"
if [ ! -f /var/log/zram_configured ]; then
    configure_zram_for_iso() {
        local iso_size_bytes=$1
        local zram_device=$2

        # Get total free memory in bytes
        local free_mem_bytes=$(grep MemAvailable /proc/meminfo | awk '{print $2 * 1024}')

        if (( free_mem_bytes > iso_size_bytes )); then
            echo "Sufficient memory available for zram. Setting up zram..."

            # Load zram module and configure
            modprobe zram
            echo lz4 > /sys/block/$zram_device/comp_algorithm
            echo $((iso_size_bytes / 1024 / 1024))M > /sys/block/$zram_device/disksize
            mke2fs -q -t ext4 /dev/$zram_device
            mkdir -p /mnt/zram_$zram_device
            mount /dev/$zram_device /mnt/zram_$zram_device

            # Verify zram device creation and mounting
            if mountpoint -q /mnt/zram_$zram_device; then
                echo "zram device $zram_device successfully created and mounted at /mnt/zram_$zram_device."
            else
                echo "ERROR: Failed to mount zram device $zram_device. Exiting."
                exit 1
            fi

            return 0
        else
            echo "Not enough free memory for zram. Falling back to disk storage."
            return 1
        fi
    }

    # Configure zram for Windows ISO
    if configure_zram_for_iso $WINDOWS_ISO_SIZE_BYTES zram0; then
        WINDOWS_ISO_PATH="/mnt/zram_zram0/Windows.iso"
    else
        WINDOWS_ISO_PATH="/root/windisk/Windows.iso"
    fi

    # Configure zram for VirtIO ISO
    if configure_zram_for_iso $VIRTIO_ISO_SIZE_BYTES zram1; then
        VIRTIO_ISO_PATH="/mnt/zram_zram1/VirtIO.iso"
    else
        VIRTIO_ISO_PATH="/root/windisk/VirtIO.iso"
    fi

    echo "zram" > /var/log/zram_configured
else
    echo "zram already configured. Skipping."
    WINDOWS_ISO_PATH="/mnt/zram_zram0/Windows.iso"
    VIRTIO_ISO_PATH="/mnt/zram_zram1/VirtIO.iso"
fi

# Step 5: Download the ISOs
show_progress "Downloading the ISOs using aria2"
if [ ! -f "$WINDOWS_ISO_PATH" ]; then
    aria2c --continue=true -x 16 -s 16 -o "$WINDOWS_ISO_PATH" "$WINDOWS_ISO_URL"
else
    echo "Windows ISO already downloaded. Skipping."
fi

if [ ! -f "$VIRTIO_ISO_PATH" ]; then
    aria2c --continue=true -x 16 -s 16 -o "$VIRTIO_ISO_PATH" "$VIRTIO_ISO_URL"
else
    echo "VirtIO ISO already downloaded. Skipping."
fi

# Step 6: Verify downloaded ISOs by file size
show_progress "Verifying downloaded ISOs by file size"
verify_file_size() {
    local file_path=$1
    local expected_size=$2

    actual_size=$(stat --format=%s "$file_path")
    if [[ "$actual_size" -eq "$expected_size" ]]; then
        echo "Verification successful for $file_path. File size matches."
    else
        echo "ERROR: Verification failed for $file_path. Expected size: $expected_size, Actual size: $actual_size."
        exit 1
    fi
}

verify_file_size "$WINDOWS_ISO_PATH" "$WINDOWS_ISO_SIZE_BYTES"
verify_file_size "$VIRTIO_ISO_PATH" "$VIRTIO_ISO_SIZE_BYTES"

# Final Step: Summary
show_progress "Finalizing installation"
echo "Installation script completed successfully!"
echo "Windows ISO downloaded to: $WINDOWS_ISO_PATH"
echo "VirtIO ISO downloaded to: $VIRTIO_ISO_PATH"

# Dry-run mode (optional)
if [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo "Dry-run mode: No changes were made."
    exit 0
fi

# Use default or provided URL for VirtIO ISO
virtio_url=${VIRTIO_ISO_URL:-$DEFAULT_VIRTIO_ISO_URL}
echo "Using VirtIO ISO URL: $virtio_url"
retry_download "$virtio_url" /root/windisk/Virtio.iso

# Default reboot choice
reboot_choice=${REBOOT_CHOICE:-$DEFAULT_REBOOT_CHOICE}
if [[ "$reboot_choice" == "Y" || "$reboot_choice" == "y" ]]; then
    echo "Rebooting the system..."
    reboot
else
    echo "Setup completed. Reboot manually to start the Windows installer."
fi

# Function to create bypass.bat
create_bypass_bat() {
    local output_file=$1
    cat <<EOF > "$output_file"
REG ADD "HKEY_LOCAL_MACHINE\\OFFLINE_SYSTEM\\Setup\\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f
REG ADD "HKEY_LOCAL_MACHINE\\OFFLINE_SYSTEM\\Setup\\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
REG ADD "HKEY_LOCAL_MACHINE\\OFFLINE_SYSTEM\\Setup\\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f
REG ADD "HKEY_LOCAL_MACHINE\\OFFLINE_SYSTEM\\Setup\\LabConfig" /v BypassStorageCheck /t REG_DWORD /d 1 /f
REG ADD "HKEY_LOCAL_MACHINE\\OFFLINE_SYSTEM\\Setup\\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f
EOF
    echo "bypass.bat created at $output_file"
}

# Function to calculate disk size in GB and MB
calculate_disk_size() {
    local disk=$1
    local disk_size_gb=$(parted "$disk" --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
    local disk_size_mb=$((disk_size_gb * 1024))
    echo "$disk_size_gb $disk_size_mb"
}

# Function to download ISO with retries
retry_download() {
    local url=$1
    local output=$2
    local retries=3
    local wait_time=5

    for ((i=1; i<=retries; i++)); do
        echo "Attempt $i: Downloading $url"
        if wget -O "$output" --user-agent="Mozilla/5.0" "$url"; then
            echo "Download successful: $output"
            return 0
        fi
        echo "Download failed. Retrying in $wait_time seconds..."
        sleep $wait_time
    done

    echo "ERROR: Failed to download $url after $retries attempts."
    return 1
}

# Function to configure GRUB
configure_grub() {
    local root_dir=$1
    mkdir -p "$root_dir/boot/grub"
    cat <<EOF > "$root_dir/boot/grub/grub.cfg"
menuentry "windows installer" {
    insmod ntfs
    search --no-floppy --set=root --file=/bootmgr
    ntldr /bootmgr
    boot
}
EOF
    echo "GRUB configuration written to $root_dir/boot/grub/grub.cfg"
}

# Example usage
configure_grub /mnt

# Consolidated apt update
if [ ! -f /var/lib/apt/periodic/update-success-stamp ] || \
   find /var/lib/apt/periodic/update-success-stamp -mtime +1 | grep -q .; then
    echo "*** Updating package lists ***"
    apt update -y
fi

# Set non-interactive mode to avoid prompts
export DEBIAN_FRONTEND=noninteractive

# Install all required tools
apt install -y --no-install-recommends linux-image-amd64 initramfs-tools grub2 wimtools ntfs-3g gdisk parted

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
configure_grub /mnt
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
        retry_download "$windows_url" "/root/windisk/Windows.iso"
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

# Define the path to the VirtIO ISO extraction root
virtio_root="/mnt/virtio"

# Ensure the directory exists
if [ ! -d "$virtio_root" ]; then
    echo "VirtIO root directory does not exist: $virtio_root"
    exit 1
fi

# Create the bypass.bat file
bypass_file="$virtio_root/bypass.bat"
echo "Creating bypass.bat at $bypass_file..."
create_bypass_bat "$bypass_file"

# Verify the file was created
if [ -f "$bypass_file" ]; then
    echo "bypass.bat created successfully at $bypass_file."
else
    echo "Failed to create bypass.bat."
    exit 1
fi

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
        retry_download "$virtio_url" "/root/windisk/Virtio.iso"
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

# Automate wimlib-imagex image index selection
image_index=2  # Default to Microsoft Windows Setup (x64)
echo "Using default image index: $image_index"

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
