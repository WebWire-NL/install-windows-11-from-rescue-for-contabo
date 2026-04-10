#!/bin/bash
set -euo pipefail

get_content_length() {
    local url="$1"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
    local size

    if command -v curl >/dev/null 2>&1; then
        size=$(curl -fsSLI -A "$ua" --compressed --max-redirs 10 "$url" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1)
        if [[ -n "$size" ]]; then
            echo "$size"
            return 0
        fi

        size=$(curl -fsSL -A "$ua" --compressed --max-redirs 10 -r 0-0 -D - -o /dev/null "$url" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1)
        if [[ -n "$size" ]]; then
            echo "$size"
            return 0
        fi
    fi

    if command -v wget >/dev/null 2>&1; then
        size=$(wget --spider --server-response --max-redirect=20 --header="User-Agent: $ua" "$url" 2>&1 | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1)
        if [[ -n "$size" ]]; then
            echo "$size"
            return 0
        fi
    fi

    return 1
}

cleanup_zram() {
    if mountpoint -q /mnt/zram0 2>/dev/null; then
        umount /mnt/zram0 || true
    fi
    if [[ -e /dev/zram0 ]]; then
        swapoff /dev/zram0 2>/dev/null || true
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    fi
    rm -rf /mnt/zram0 2>/dev/null || true
}

free_memory() {
    sync
    if [[ -w /proc/sys/vm/drop_caches ]]; then
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    fi
}

attempt_zram_setup() {
    local target_mb=$1
    cleanup_zram
    free_memory

    if ! modprobe zram >/dev/null 2>&1; then
        return 1
    fi
    echo lz4 > /sys/block/zram0/comp_algorithm || true
    echo "${target_mb}M" > /sys/block/zram0/disksize
    if [[ $(cat /sys/block/zram0/disksize 2>/dev/null || echo 0) -eq 0 ]]; then
        return 1
    fi
    if ! mkfs.ext4 -q -m 0 /dev/zram0; then
        return 1
    fi
    mkdir -p /mnt/zram0
    if ! mount /dev/zram0 /mnt/zram0; then
        return 1
    fi

    local zram_avail_kb zram_avail_mb
    zram_avail_kb=$(df --output=avail /mnt/zram0 2>/dev/null | tail -n 1 | tr -d ' ')
    zram_avail_mb=$((zram_avail_kb / 1024))
    if [[ "$zram_avail_mb" -lt $((target_mb - 128)) ]]; then
        cleanup_zram
        return 1
    fi

    return 0
}

WINDOWS_ISO_URL='https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=d6f83cc2-3c65-40c0-85ff-143a500abe4e&P1=1775830512&P2=601&P3=2&P4=XA71zxH6FtisWhOao7eelJjEAcT6SyLI74vehgTmdEAoyuhYQFHfakQ82aJuS%2bUpMi6kjtJu0wgu0jAZ%2fa7XSp%2bNAHUON0FaZb6MIbKbsqNafmgUlpBNJCKgpDcLSX7ACWBWv%2fan8gOQr%2b8yakjqweT1WLVVSrMB8VX9pqfvkLZ4FXZsAJGZ7Gff9UX48qnrLAL4zG3yVTalh3wFHqd2HnCfeYY6wfZVWr8cBxyfKrSlcmfVhamVs26M6eoLKuljxE6WBsfd0%2btNkmNX%2fjp25FlT67w3ZXuWacTSYEoCniiH2NHkjTJhdsvFzXT%2bJ7bfn206xRPCF8mOX4pGv1zsNA%3d%3d'
VIRTIO_ISO_URL='https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'

echo "WINDOWS_SIZE=$(get_content_length \"$WINDOWS_ISO_URL\")"
echo "VIRTIO_SIZE=$(get_content_length \"$VIRTIO_ISO_URL\")"

ZRAM_MARGIN_MB=128
if attempt_zram_setup 1024; then
    echo "ZRAM_SETUP=OK"
    df --output=source,fstype,size,avail,target /mnt/zram0 || true
    cat /sys/block/zram0/disksize 2>/dev/null || true
    cleanup_zram
else
    echo "ZRAM_SETUP=FAILED"
    cat /sys/block/zram0/disksize 2>/dev/null || true
fi
