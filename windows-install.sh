#!/bin/bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<EOF
Usage: $0 [ISO_URL] [ISO_FILE] [EXPECTED_SHA256]

  ISO_URL         Optional Windows ISO download URL.
  ISO_FILE        Optional target ISO path (default: /mnt/win11.iso).
  EXPECTED_SHA256 Optional SHA256 checksum for ISO validation.

Example:
  $0 "https://example.com/Windows.iso" /mnt/win11.iso abc123...def456
EOF
  exit 0
fi

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] This script must be run as root." >&2
  exit 1
fi

swap_active() {
  swapon --show --noheadings | grep -q .
}

create_temp_swap() {
  local swapfile=/mnt/windows-swapfile
  local min_kb=$((4 * 1024 * 1024))
  local avail_kb

  avail_kb=$(df --output=avail -k /mnt | tail -n 1 | tr -d '[:space:]')
  if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$min_kb" ]; then
    echo "[WARN] Not enough free space on /mnt to create temporary swap. Available: ${avail_kb}K." >&2
    return 1
  fi

  rm -f "$swapfile"
  dd if=/dev/zero of="$swapfile" bs=1M count=4096 conv=fdatasync status=none
  chmod 600 "$swapfile"
  mkswap "$swapfile"
  swapon "$swapfile"
  echo "[INFO] Temporary swap enabled on $swapfile."
}

if ! swap_active; then
  echo "[INFO] No swap active; attempting to create temporary swap on /mnt."
  if ! create_temp_swap; then
    echo "[WARN] Could not create temporary swap. Apt may fail on low-memory systems." >&2
  fi
fi

apt update -y
apt install -y grub2 filezilla gparted wimtools aria2 gdisk

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

# Use aria2 for resumable downloads with a session file
if [ -n "${2:-}" ]; then
  ISO_FILE="$2"
elif [ -f /mnt/test-win11.iso ]; then
  ISO_FILE="/mnt/test-win11.iso"
else
  ISO_FILE="/mnt/win11.iso"
fi
EXPECTED_SHA256="${3:-}"
ISO_BASE=$(basename "$ISO_FILE")
SESSION_FILE="${ISO_FILE}.aria2"
LOG="/mnt/aria2-download.log"

mkdir -p "$(dirname "$ISO_FILE")"
mkdir -p "$(dirname "$LOG")"

echo "[INFO] Download target: $ISO_FILE"
echo "[INFO] Session file: $SESSION_FILE"

touch "$SESSION_FILE" "$LOG"

if pgrep -f "aria2c .*--dir=$(dirname "$ISO_FILE") .*--out=${ISO_BASE}" >/dev/null 2>&1; then
  echo "[WARN] Found existing aria2 download process for $ISO_BASE. Stopping stale process."
  pgrep -f "aria2c .*--dir=$(dirname "$ISO_FILE") .*--out=${ISO_BASE}" | xargs -r kill
  sleep 5
fi

aria2_exit_code=0
if command -v aria2c >/dev/null 2>&1; then
  set +e
  aria2c --continue=true --file-allocation=none --enable-http-keep-alive=true \
    --user-agent="Mozilla/5.0" --header="Accept: */*" --header="Referer: https://www.microsoft.com/" --header="Accept-Language: en-US,en;q=0.9" \
    --max-connection-per-server=4 --split=8 --min-split-size=4M \
    --max-tries=10 --retry-wait=15 --timeout=60 \
    --summary-interval=5 --console-log-level=warn \
    --log="$LOG" --input-file="$SESSION_FILE" --save-session="$SESSION_FILE" --save-session-interval=30 \
    --dir="$(dirname "$ISO_FILE")" --out="$ISO_BASE" "$ISO_URL"
  aria2_exit_code=$?
  set -e
else
  aria2_exit_code=127
fi

echo "[INFO] aria2 download completed with exit code $aria2_exit_code"

if [ "$aria2_exit_code" -ne 0 ]; then
  echo "[WARN] aria2c failed with exit code $aria2_exit_code; falling back to curl."
  current_size=$(stat -c %s "$ISO_FILE" 2>/dev/null || echo 0)
  expected_size=$(curl -I -L -A 'Mozilla/5.0' --header 'Accept: */*' --header 'Referer: https://www.microsoft.com/' --header 'Accept-Language: en-US,en;q=0.9' "$ISO_URL" 2>/dev/null | awk '/^Content-Length:/ {print $2}' | tr -d '\r')
  if [ -n "$expected_size" ] && [ "$current_size" -gt "$expected_size" ]; then
    echo "[WARN] Existing file is larger than expected ($current_size > $expected_size), truncating."
    truncate -s "$expected_size" "$ISO_FILE"
    current_size="$expected_size"
  fi
  echo "[INFO] Resuming curl from ${current_size} bytes."
  curl -C "$current_size" --location --user-agent "Mozilla/5.0" \
    --header "Accept: */*" --header "Referer: https://www.microsoft.com/" --header "Accept-Language: en-US,en;q=0.9" \
    --retry 10 --retry-delay 15 --retry-connrefused --max-time 600 --show-error --compressed \
    --output "$ISO_FILE" "$ISO_URL"
fi

echo "[INFO] Finished download. Verifying ISO file."
expected_size=$(curl -I -L -A 'Mozilla/5.0' --header 'Accept: */*' --header 'Referer: https://www.microsoft.com/' --header 'Accept-Language: en-US,en;q=0.9' "$ISO_URL" 2>/dev/null | awk '/^Content-Length:/ {print $2}' | tr -d '\r')
actual_size=$(stat -c %s "$ISO_FILE" 2>/dev/null || echo 0)
if [ -n "$expected_size" ]; then
  if [ "$actual_size" -ne "$expected_size" ]; then
    echo "[ERROR] ISO size mismatch: actual=$actual_size expected=$expected_size"
    exit 1
  fi
  echo "[INFO] ISO size matches expected Content-Length: $actual_size bytes."
else
  echo "[WARN] Could not determine expected Content-Length from remote URL; skipping size verification."
fi

if [ -n "$EXPECTED_SHA256" ]; then
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "[ERROR] sha256sum is required for checksum verification but is not installed."
    exit 1
  fi
  echo "[INFO] Verifying SHA256 checksum."
  actual_sha256=$(sha256sum "$ISO_FILE" | awk '{print $1}')
  if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
    echo "[ERROR] SHA256 mismatch. actual=$actual_sha256"
    echo "[ERROR] expected=$EXPECTED_SHA256"
    exit 1
  fi
  echo "[INFO] SHA256 checksum is correct."
else
  echo "[WARN] No expected SHA256 checksum provided; skipping checksum verification."
fi

# Mount the Windows 11 ISO in a stable native path
if mountpoint -q /tmp/winfile 2>/dev/null; then
  current_src=$(findmnt -n -o SOURCE --target /tmp/winfile 2>/dev/null || true)
  if [ "$current_src" = "$ISO_FILE" ]; then
    echo "[INFO] ISO already mounted at /tmp/winfile from $ISO_FILE."
  else
    echo "[WARN] /tmp/winfile is mounted from $current_src, not $ISO_FILE. Unmounting."
    umount /tmp/winfile
    mount -o loop "$ISO_FILE" /tmp/winfile
  fi
else
  mount -o loop "$ISO_FILE" /tmp/winfile
fi

mkdir -p /mnt/sources/virtio

# Verify that the ISO is mounted correctly
if ! mountpoint -q /tmp/winfile; then
  echo "[ERROR] ISO is not mounted. Please check the mount command."
  exit 1
fi

# Verify that boot.wim exists before proceeding
if [ ! -f /tmp/winfile/sources/boot.wim ]; then
  echo "[ERROR] boot.wim not found in /tmp/winfile/sources. Please check the mount path."
  exit 1
fi

# Copy installer files and inject the bypass batch script
rsync -avz --progress /tmp/winfile/ /mnt/sources/virtio/
mkdir -p /mnt/sources/virtio/sources
cat <<EOF > /mnt/sources/virtio/sources/bypass-tpm-secureboot.bat
@echo off
REM Bypass TPM and Secure Boot checks during Windows setup
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f
EOF

echo "[INFO] A batch script to bypass TPM, Secure Boot, RAM, CPU, and Storage checks has been added."

cat <<EOF > /mnt/sources/virtio/cmd.txt
add virtio /virtio_drivers
EOF

wimlib-imagex update /mnt/sources/virtio/sources/boot.wim 2 < /mnt/sources/virtio/cmd.txt

echo "[INFO] Script execution completed. Skipping the final reboot step."


