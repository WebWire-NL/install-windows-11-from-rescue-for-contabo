#!/bin/bash

apt update -y
apt install grub2 filezilla gparted wimtools -y

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

cd /root/windisk
mkdir winfile

# Download the official Windows 11 evaluation ISO (English, x64)
wget -O win11.iso https://software-download.microsoft.com/download/pr/Windows11_InsiderPreviewEnterprise_Eval_x64_en-us_26100.iso
mount -o loop win11.iso winfile
rsync -avz --progress winfile/* /mnt
umount winfile

wget -O virtio.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso
mount -o loop virtio.iso winfile
mkdir /mnt/sources/virtio
rsync -avz --progress winfile/* /mnt/sources/virtio
cd /mnt/sources
touch cmd.txt
echo 'add virtio /virtio_drivers' >> cmd.txt
wimlib-imagex update boot.wim 2 < cmd.txt

# Create registry file to bypass Windows 11 checks
cat <<EOT > bypass.reg
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SYSTEM\\Setup\\LabConfig]
"BypassTPMCheck"=dword:00000001
"BypassRAMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
EOT

# Create a batch file to import the registry file during setup
cat <<EOT > bypass.cmd
@echo off
regedit /s %~dp0bypass.reg
EOT

# Copy both files into the Windows installation media (sources folder)
cp bypass.reg /mnt/sources/
cp bypass.cmd /mnt/sources/

reboot
