#!/bin/bash

apt update -y

apt install grub2 filezilla gparted wimtools -y

#Get the disk size in GB and convert to MB
disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
disk_size_mb=$((disk_size_gb * 1024))

#Calculate partition size (25% of total size)
part_size_mb=$((disk_size_mb / 4))

#Create GPT partition table
parted /dev/sda --script -- mklabel gpt

#Create two partitions
parted /dev/sda --script -- mkpart primary ntfs 1MB ${part_size_mb}MB
parted /dev/sda --script -- mkpart primary ntfs ${part_size_mb}MB $((2 * part_size_mb))MB

#Inform kernel of partition table changes
partprobe /dev/sda

sleep 30

partprobe /dev/sda

sleep 30

partprobe /dev/sda

sleep 30 

#Format the partitions
mkfs.ntfs -f /dev/sda1
mkfs.ntfs -f /dev/sda2

echo "NTFS partitions created"

echo -e "r\ng\np\nw\nY\n" | gdisk /dev/sda

mount /dev/sda1 /mnt

#Prepare directory for the Windows disk
cd ~
mkdir windisk

mount /dev/sda2 windisk

grub-install --root-directory=/mnt /dev/sda

#Edit GRUB configuration
cd /mnt/boot/grub
cat <<EOF > grub.cfg
menuentry "windows installer" {
	insmod ntfs
	search --set=root --file=/bootmgr
	ntldr /bootmgr
	boot
	disable tpm
	disable secureboot
}
EOF

cd /root/windisk

mkdir winfile

# Add an argument for the ISO URL
ISO_URL="$1"
if [ -z "$ISO_URL" ]; then
  echo "Usage: $0 <ISO_URL>"
  exit 1
fi

# Install aria2 for advanced downloading
apt install -y aria2

# Use aria2 to download the Windows ISO with progress output
aria2c -o win11.iso --summary-interval=1 "$ISO_URL"

# Mount the Windows 11 ISO
mount -o loop win11.iso winfile

# Ensure /mnt/sources and /mnt/sources/virtio directories exist
mkdir -p /mnt/sources/virtio

# Verify that the ISO is mounted correctly
if ! mountpoint -q /root/windisk/winfile; then
  echo "[ERROR] ISO is not mounted. Please check the mount command."
  exit 1
fi

# Verify that boot.wim exists before proceeding
if [ ! -f /mnt/boot.wim ]; then
  echo "[ERROR] boot.wim not found in /mnt. Please check the file paths."
  exit 1
fi

# Create a batch script to bypass TPM and Secure Boot checks
cat <<EOF > /mnt/sources/bypass-tpm-secureboot.bat
@echo off
REM Bypass TPM and Secure Boot checks during Windows setup
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f
EOF

# Ensure the batch script is copied to the installer
cp /mnt/sources/bypass-tpm-secureboot.bat /root/windisk/winfile/sources/

# Provide instructions for manual execution during setup
echo "[INFO] A batch script to bypass TPM and Secure Boot checks has been added."
echo "[INFO] If needed, you can manually execute it from the X: drive during setup."
echo "[INFO] The batch script now bypasses additional checks: RAM, CPU, and Storage."

# Proceed with the existing commands
rsync -avz --progress winfile/* /mnt/sources/virtio

cd /mnt/sources

touch cmd.txt
echo 'add virtio /virtio_drivers' >> cmd.txt

wimlib-imagex update boot.wim 2 < cmd.txt

reboot


