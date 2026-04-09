#!/bin/bash
set -e

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <windows-iso-url>"
    exit 1
fi
WINDOWS_ISO_URL="$1"
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

umount /mnt 2>/dev/null || true
umount /mnt/zram0 2>/dev/null || true
swapoff /dev/zram0 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true
rm -rf /mnt/zram0 2>/dev/null || true
mkdir -p /mnt
mount -t ntfs-3g /dev/sda2 /mnt
if mountpoint -q /mnt; then
    echo "Mounted /dev/sda2 at /mnt"
    df -h /mnt
else
    echo "Failed to mount /mnt"
    exit 1
fi
nohup bash /root/install-windows-11-from-rescue-for-contabo/windows-install.sh --no-prompt --force-download \
  --iso-url "$WINDOWS_ISO_URL" \
  --virtio-url "$VIRTIO_ISO_URL" \
  > /root/install-windows-run.log 2>&1 < /dev/null &
echo $!
