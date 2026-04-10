#!/usr/bin/env bash
set -e

echo "=== mountpoints ==="
mount | grep -E '/mnt|/root/windisk|/boot' || true

echo "=== ls /mnt ==="
ls -lah /mnt || true

echo "=== ls /mnt/boot ==="
ls -lah /mnt/boot || true

echo "=== ls /mnt/boot/grub ==="
ls -lah /mnt/boot/grub || true

echo "=== grub.cfg ==="
sed -n '1,200p' /mnt/boot/grub/grub.cfg || true

echo "=== /mnt sources ==="
ls -lah /mnt/sources || true

echo "=== /root/windisk ==="
ls -lah /root/windisk || true

echo "=== /dev/sda* partitions ==="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT /dev/sda || true

echo "=== blkid /dev/sda1 /dev/sda2 ==="
blkid /dev/sda1 /dev/sda2 || true

echo "=== grub-install check ==="
command -v grub-install && grub-install --version || true

echo "=== /mnt/bootmgr exists ==="
ls -l /mnt/bootmgr || true
