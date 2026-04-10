#!/usr/bin/env bash
set -e

echo "=== ensure mount points ==="
mkdir -p /mnt /root/windisk

if mountpoint -q /mnt; then
    echo "/mnt already mounted"
else
    echo "Mounting /dev/sda1 -> /mnt"
    mount /dev/sda1 /mnt 2>/dev/null || echo "FAILED: mount /dev/sda1 -> /mnt"
fi

if mountpoint -q /root/windisk; then
    echo "/root/windisk already mounted"
else
    echo "Mounting /dev/sda2 -> /root/windisk"
    mount /dev/sda2 /root/windisk 2>/dev/null || echo "FAILED: mount /dev/sda2 -> /root/windisk"
fi

echo "=== mountpoints ==="
mount | grep -E '/mnt|/root/windisk|/boot' || true

echo "=== /mnt listing ==="
ls -lah /mnt || true

echo "=== /mnt boot listing ==="
ls -lah /mnt/boot || true

echo "=== /mnt boot/grub listing ==="
ls -lah /mnt/boot/grub || true

echo "=== /mnt/boot/grub/grub.cfg ==="
if [ -f /mnt/boot/grub/grub.cfg ]; then
    sed -n '1,200p' /mnt/boot/grub/grub.cfg
else
    echo "missing /mnt/boot/grub/grub.cfg"
fi

echo "=== /mnt bootmgr & installer files ==="
for f in /mnt/bootmgr /mnt/sources/boot.wim /mnt/sources/virtio; do
    if [ -e "$f" ]; then
        ls -lah "$f" || true
    else
        echo "missing $f"
    fi
done

echo "=== /root/windisk listing ==="
ls -lah /root/windisk || true

echo "=== partition info ==="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT /dev/sda || true
blkid /dev/sda1 /dev/sda2 || true

echo "=== grub install present ==="
if command -v grub-install >/dev/null 2>&1; then
    grub-install --version || true
else
    echo "grub-install not installed"
fi
