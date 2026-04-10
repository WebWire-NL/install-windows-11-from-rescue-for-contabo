#!/bin/bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo
source windows-install.sh
export NO_PROMPT=1
export FORCE_DOWNLOAD=1
WINDOWS_ISO_URL="https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=9dd36437-8c53-4d86-80dc-29db90a63505&P1=1775719369&P2=601&P3=2&P4=fizoXRjVOXdAMg6a1PRgNIZMO8eeYkphp0nfA4VZxRwRnoitaEjdNb%2fu%2bEjZhVHU5khibrqnmy5ILZ8UhgR2B9MNohSfvcTBciTTZFNmwkV3%2bmcGjh9rti%2bdQv8d4XTZafuF1VBHfgn1tRGz8TTn%2foFRphlIU1rqnxpOMnbLGIqif%2bVMdnnXYyOFNpLtZoUKspcdJLktl4cu2axBhYFaWWh%2fYTCQy8IE%2fgFapNMea7KgfYIinsF338Xyy2iutI2bYa555qx1gzLXO30pV1dq7E%2bKlaPmh1YgCR7xQ%3d%3d"
VIRTIO_ISO_URL="https://bit.ly/4d1g7Ht"
export WINDOWS_ISO_URL VIRTIO_ISO_URL

echo "=== Starting ensure_partitions_ready ==="
ensure_partitions_ready

echo "=== Starting prepare_windows_media ==="
prepare_windows_media

echo "=== Completed prepare_windows_media ==="

echo "=== Mount status ==="
mount | grep -E '/mnt|/root/windisk|/mnt/zram0' || true

echo "=== Files ==="
ls -l /root/windisk 2>/dev/null || true
ls -l /mnt/zram0/windisk 2>/dev/null || true
