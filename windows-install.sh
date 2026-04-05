#!/bin/bash

apt update -y

apt install grub2 filezilla gparted wimtools -y

#Get the disk size in GB and convert to MB
disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
disk_size_mb=$((disk_size_gb * 1024))

#Calculate partition size (25% of total size)
part_size_mb=$((disk_size_mb / 4))

#Clear existing partitions on /dev/sda before creating new ones
parted /dev/sda --script -- mklabel gpt || true
parted /dev/sda --script -- rm 1 || true
parted /dev/sda --script -- rm 2 || true

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

mkdir -p /tmp/winfile

# Allow a custom ISO URL to be supplied, otherwise use the default Windows 11 ISO URL
DEFAULT_ISO_URL="https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=9b44bc26-4bf0-474e-963f-1796cd6a8c33&P1=1775499486&P2=601&P3=2&P4=Gb73mWwBfDwJfQzPKXUjOLuE4sq%2bJWCcs71bMBaRbIdEynbv0jZL%2f0WC%2bg6Fjq9ex3wjTcSXYABnKlFiilffsHa3inuR9EJ9gD3o2hNQL2hfLUDBkE3OegAgu%2fJ9cMniiQheWUZvWYKvJt%2fCkAjB%2ftg57XIK1PhIIZ6hfvhlSj67VlIZbVFRMfiw4yCdQhG6WVfen2k0jIOIELD05rF%2b8MK5c8oAVk%2fbwgOJb17yBZ9V5qOaqYvOWu49%2f5JItaqFhfk%2f%2fhP%2fymQqjy2IdCELOVkxeatMjHVBIbzXkz%2ba1TFc6lPJFIxFfVcNICwJv4WxrLctsfkpcF1ehA8WaxA%2bCw%3d%3d"
ISO_URL="${1:-$DEFAULT_ISO_URL}"
if [ $# -gt 0 ]; then
  echo "[INFO] Using supplied ISO URL: $ISO_URL"
else
  echo "[INFO] No URL supplied; using default Windows 11 ISO URL."
fi

# Use aria2 for resumable downloads with custom progress summary
apt install -y aria2
LOG="/root/aria2-download.log"
rm -f "$LOG"

# Start aria2 download in the background and write log for our summary
aria2c --continue=true --file-allocation=none --max-connection-per-server=4 --split=4 --summary-interval=1 --console-log-level=warn --log="$LOG" --dir=/root --out=win11.iso "$ISO_URL" &
ARIA2_PID=$!

echo "[INFO] Started aria2 download with PID $ARIA2_PID"

# Custom progress summary while aria2 is running
while kill -0 "$ARIA2_PID" 2>/dev/null; do
    sleep 5
    echo "[INFO] Download progress summary:"
    tail -n 12 "$LOG" | grep -E '^\[|^\*\*\*' || true
    echo "---"
done

wait "$ARIA2_PID"
echo "[INFO] aria2 download process completed with exit code $?"

# Mount the Windows 11 ISO in a stable native path
umount /tmp/winfile 2>/dev/null || true
mount -o loop /root/win11.iso /tmp/winfile

# Ensure /mnt/sources and /mnt/sources/virtio directories exist
mkdir -p /mnt/sources/virtio

# Verify that the ISO is mounted correctly
if ! mountpoint -q /tmp/winfile; then
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

# Ensure the batch script is copied to the installer target
mkdir -p /mnt/sources/virtio/sources
cp /mnt/sources/bypass-tpm-secureboot.bat /mnt/sources/virtio/sources/

# Provide instructions for manual execution during setup
echo "[INFO] A batch script to bypass TPM and Secure Boot checks has been added."
echo "[INFO] If needed, you can manually execute it from the X: drive during setup."
echo "[INFO] The batch script now bypasses additional checks: RAM, CPU, and Storage."

# Proceed with the existing commands
rsync -avz --progress /tmp/winfile/* /mnt/sources/virtio

cd /mnt/sources

touch cmd.txt
echo 'add virtio /virtio_drivers' >> cmd.txt

wimlib-imagex update boot.wim 2 < cmd.txt

echo "[INFO] Script execution completed. Skipping the final reboot step."


