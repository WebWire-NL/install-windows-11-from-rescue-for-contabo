#!/usr/bin/env bash
set -euo pipefail

# Resume Windows install preparation after a partial run.
# This script detects completed checkpoints and skips steps already done.

SELF_UPDATE_URL="https://raw.githubusercontent.com/WebWire-NL/install-windows-11-from-rescue-for-contabo/master/windows-install.sh"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

package_for_command() {
    case "$1" in
        mkfs.ntfs) echo ntfs-3g ;;
        mkfs.ext4) echo e2fsprogs ;;
        grub-install) echo grub-pc ;;
        curl) echo curl ;;
        rsync) echo rsync ;;
        pgrep) echo procps ;;
        awk) echo gawk ;;
        xargs) echo findutils ;;
        grep) echo grep ;;
        mount|blockdev|partx|fdisk) echo util-linux ;;
        dpkg-deb) echo dpkg ;;
        modprobe) echo kmod ;;
        partprobe|parted) echo parted ;;
        *) echo "" ;;
    esac
}

install_missing_dependencies() {
    if ! command_exists apt-get; then
        return 1
    fi

    local missing=()
    for cmd in "$@"; do
        local pkg
        pkg=$(package_for_command "$cmd")
        if [ -n "$pkg" ] && ! printf '%s\n' "${missing[@]}" | grep -xq "$pkg"; then
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    echo "Installing missing dependency packages: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

self_update_script() {
    if [ "${1:-}" = "--no-self-update" ]; then
        return 0
    fi

    if [ ! -f "$0" ]; then
        return 0
    fi

    local tmp
    if command_exists curl; then
        tmp=$(mktemp)
        if ! curl -fsSL "$SELF_UPDATE_URL" > "$tmp"; then
            rm -f "$tmp"
            return 0
        fi
    elif command_exists wget; then
        tmp=$(mktemp)
        if ! wget -qO "$tmp" "$SELF_UPDATE_URL"; then
            rm -f "$tmp"
            return 0
        fi
    else
        return 0
    fi

    if ! cmp -s "$0" "$tmp"; then
        echo "A newer installer script version is available. Re-running the latest version."
        bash "$tmp" --no-self-update "$@"
        exit $?
    fi

    rm -f "$tmp"
}

self_update_script "$@"

DEFAULT_WINDOWS_ISO_URL="https://bit.ly/3UGzNcB"
DEFAULT_VIRTIO_ISO_URL="https://bit.ly/4d1g7Ht"

prompt_url() {
    local default="$1"
    local prompt="$2"
    local value
    read -r -p "$prompt" value
    echo "${value:-$default}"
}

get_content_length() {
    local url="$1"
    curl -fsI "$url" | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r'
}

download_file() {
    local url="$1"
    local output="$2"
    local session="${output}.aria2"
    local log="${output}.aria2.log"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    local dir
    local base
    dir="$(dirname "$output")"
    base="$(basename "$output")"

    if command_exists aria2c; then
        if pgrep -f "aria2c .*--dir=$dir .*--out=$base" >/dev/null 2>&1; then
            echo "Stopping stale aria2c process for $output"
            pgrep -f "aria2c .*--dir=$dir .*--out=$base" | xargs -r kill
        fi

        echo "Downloading $output with aria2c (resume support)"
        set +e
        aria2c --continue=true --file-allocation=none --enable-http-keep-alive=true \
            --enable-http2=true --max-connection-per-server=64 --split=64 --min-split-size=4M \
            --max-tries=0 --retry-wait=15 --timeout=60 --retry-connrefused=true \
            --download-result=full --user-agent="$ua" \
            -d "$dir" -o "$base" --input-file="$session" "$url" >"$log" 2>&1
        local aria2_rc=$?
        set -e

        if [ "$aria2_rc" -ne 0 ]; then
            echo "WARNING: aria2c failed with exit code $aria2_rc. Falling back to curl."
            if command_exists curl; then
                curl --http2 --compressed --retry 5 --retry-delay 10 --retry-connrefused \
                    --location --continue-at - --user-agent "$ua" --output "$output" "$url"
            else
                echo "WARNING: curl not available. Falling back to wget."
                wget --tries=0 --waitretry=5 --retry-connrefused --continue --timeout=60 \
                    --user-agent="$ua" -O "$output" "$url"
            fi
        fi
    else
        echo "aria2c not available, downloading $output with wget"
        wget --tries=5 --waitretry=5 --retry-connrefused --continue --timeout=60 \
            --user-agent="$ua" -O "$output" "$url"
    fi
}

ensure_toolchain() {
    local required=(parted mkfs.ntfs mkfs.ext4 mount rsync grub-install curl grep awk pgrep xargs dpkg-deb modprobe partprobe blockdev partx)
    local missing=()

    for cmd in "${required[@]}"; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Missing required commands: ${missing[*]}"
        if install_missing_dependencies "${missing[@]}"; then
            missing=()
            for cmd in "${required[@]}"; do
                if ! command_exists "$cmd"; then
                    missing+=("$cmd")
                fi
            done
        fi
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: required command(s) still missing: ${missing[*]}"
        exit 1
    fi
}

cleanup_partition_state() {
    echo "Cleaning up stale /dev/sda state..."
    umount /mnt 2>/dev/null || true
    umount /root/windisk 2>/dev/null || true
    if command_exists partprobe; then
        partprobe /dev/sda >/dev/null 2>&1 || true
    fi
    if command_exists blockdev; then
        blockdev --rereadpt /dev/sda >/dev/null 2>&1 || true
    fi
    if command_exists partx; then
        partx -u /dev/sda >/dev/null 2>&1 || true
    fi
    if command_exists kpartx; then
        kpartx -d /dev/sda >/dev/null 2>&1 || true
    fi
    sleep 2
}

has_bios_boot_partition() {
    if ! command_exists parted; then
        return 1
    fi
    local label
    label=$(parted /dev/sda --script print | awk -F: '/^Partition Table/ {print $2}' | tr -d '[:space:]')
    if [ "$label" != "gpt" ]; then
        return 1
    fi
    if parted /dev/sda --script print | grep -q "bios_grub"; then
        return 0
    fi
    return 1
}

setup_partitions_and_mounts() {
    mkdir -p /mnt /root/windisk

    if mountpoint -q /mnt; then
        echo "/mnt already mounted"
    else
        mount /dev/sda1 /mnt 2>/dev/null || true
    fi
    if mountpoint -q /root/windisk; then
        echo "/root/windisk already mounted"
    else
        mount /dev/sda2 /root/windisk 2>/dev/null || true
    fi

    if [ -f /mnt/bootmgr ] && [ -f /mnt/sources/boot.wim ]; then
        if has_bios_boot_partition; then
            echo "Existing Windows installer files detected on /mnt. Skipping partition recreation."
            return
        fi
        if parted /dev/sda --script print | awk -F: '/^Partition Table/ {print $2}' | tr -d '[:space:]' | grep -q '^gpt$'; then
            echo "ERROR: /dev/sda is GPT without a BIOS boot partition."
            echo "This disk layout is unreliable for BIOS GRUB install."
            echo "You may need to recreate the disk with MBR, add a BIOS boot partition, or boot in UEFI mode."
            exit 1
        fi
        echo "Existing Windows installer files detected on /mnt. Skipping partition recreation."
        return
    fi

    echo "Creating disk partitions..."
    if mountpoint -q /mnt; then
        umount /mnt || true
    fi
    if mountpoint -q /root/windisk; then
        umount /root/windisk || true
    fi

    if [ -e /dev/sda1 ] || [ -e /dev/sda2 ]; then
        cleanup_partition_state
    fi

    disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
    disk_size_mb=$((disk_size_gb * 1024))
    part_size_mb=$((disk_size_mb / 2))

    if command_exists sgdisk; then
        echo "Wiping existing partition table on /dev/sda..."
        sgdisk --zap-all /dev/sda || true
    fi
    if command_exists wipefs; then
        echo "Wiping filesystem signatures on /dev/sda..."
        wipefs -a /dev/sda || true
    fi
    cleanup_partition_state

    parted /dev/sda --script -- mklabel msdos
    parted /dev/sda --script -- mkpart primary ntfs 1MB ${part_size_mb}MB
    parted /dev/sda --script -- mkpart primary ntfs ${part_size_mb}MB 100%
    partprobe /dev/sda
    sleep 5

    mkfs.ntfs -f /dev/sda1
    mkfs.ntfs -f /dev/sda2

    partprobe /dev/sda
    sleep 3

    mount /dev/sda1 /mnt
    mount /dev/sda2 /root/windisk
}

find_existing_downloads() {
    if [ -f /mnt/zram0/windisk/Windows.iso ] || [ -f /mnt/zram0/windisk/VirtIO.iso ]; then
        USE_ZRAM=1
        WINDOWS_ISO="/mnt/zram0/windisk/Windows.iso"
        VIRTIO_ISO="/mnt/zram0/windisk/VirtIO.iso"
        if [ -f "$WINDOWS_ISO" ]; then
            WINDOWS_ISO_SIZE=$(stat -c%s "$WINDOWS_ISO")
        fi
        if [ -f "$VIRTIO_ISO" ]; then
            VIRTIO_ISO_SIZE=$(stat -c%s "$VIRTIO_ISO")
        fi
        return 0
    fi

    if [ -f /root/windisk/Windows.iso ] || [ -f /root/windisk/VirtIO.iso ]; then
        USE_ZRAM=0
        WINDOWS_ISO="/root/windisk/Windows.iso"
        VIRTIO_ISO="/root/windisk/VirtIO.iso"
        if [ -f "$WINDOWS_ISO" ]; then
            WINDOWS_ISO_SIZE=$(stat -c%s "$WINDOWS_ISO")
        fi
        if [ -f "$VIRTIO_ISO" ]; then
            VIRTIO_ISO_SIZE=$(stat -c%s "$VIRTIO_ISO")
        fi
        return 0
    fi

    return 1
}

skip_existing_extraction() {
    if [ -f /mnt/bootmgr ] && [ -f /mnt/sources/boot.wim ]; then
        SKIP_WINDOWS_DOWNLOAD=1
        echo "Existing Windows installer files detected in /mnt. Skipping Windows URL prompt and download."
    fi
    if [ -d /mnt/sources/virtio ] && [ -f /mnt/sources/virtio/NetKVM/2k3/amd64/netkvm.sys ]; then
        SKIP_VIRTIO_DOWNLOAD=1
        echo "Existing VirtIO drivers detected in /mnt/sources/virtio. Skipping VirtIO URL prompt and download."
    fi
    if [ "${SKIP_WINDOWS_DOWNLOAD:-0}" -eq 1 ] || [ "${SKIP_VIRTIO_DOWNLOAD:-0}" -eq 1 ]; then
        return 0
    fi
    return 1
}

print_current_state() {
    local installer_present=0
    local virtio_present=0
    local downloaded_windows_iso=0
    local downloaded_virtio_iso=0

    if [ -f /mnt/bootmgr ] && [ -f /mnt/sources/boot.wim ]; then
        installer_present=1
    fi
    if [ -d /mnt/sources/virtio ] && [ -f /mnt/sources/virtio/NetKVM/2k3/amd64/netkvm.sys ]; then
        virtio_present=1
    fi
    if [ -f /mnt/zram0/windisk/Windows.iso ] || [ -f /root/windisk/Windows.iso ]; then
        downloaded_windows_iso=1
    fi
    if [ -f /mnt/zram0/windisk/VirtIO.iso ] || [ -f /root/windisk/VirtIO.iso ]; then
        downloaded_virtio_iso=1
    fi

    echo "*** Current state summary ***"
    if [ "$installer_present" -eq 1 ]; then
        echo "- Windows installer files already present in /mnt"
    else
        echo "- Windows installer files are missing from /mnt"
    fi
    if [ "$virtio_present" -eq 1 ]; then
        echo "- VirtIO drivers already present in /mnt/sources/virtio"
    else
        echo "- VirtIO drivers are missing from /mnt/sources/virtio"
    fi
    if [ "$downloaded_windows_iso" -eq 1 ]; then
        echo "- Windows.iso is already downloaded"
    else
        echo "- Windows.iso is not downloaded"
    fi
    if [ "$downloaded_virtio_iso" -eq 1 ]; then
        echo "- VirtIO.iso is already downloaded"
    else
        echo "- VirtIO.iso is not downloaded"
    fi
    echo "*** End of state summary ***"
}

setup_download_environment() {
    print_current_state
    if find_existing_downloads; then
        echo "Existing downloaded ISOs detected. Skipping URL prompts."
        WINDOWS_ISO_URL=""
        VIRTIO_ISO_URL=""
        WINDOWS_ISO_SIZE=${WINDOWS_ISO_SIZE:-0}
        VIRTIO_ISO_SIZE=${VIRTIO_ISO_SIZE:-0}
        return
    else
        SKIP_WINDOWS_DOWNLOAD=0
        SKIP_VIRTIO_DOWNLOAD=0
        skip_existing_extraction || true
        if [ "${SKIP_WINDOWS_DOWNLOAD:-0}" -eq 0 ]; then
            WINDOWS_ISO_URL=$(prompt_url "$DEFAULT_WINDOWS_ISO_URL" "Enter the URL for Windows.iso (leave blank to use default): ")
            WINDOWS_ISO_SIZE=$(get_content_length "$WINDOWS_ISO_URL")
        else
            WINDOWS_ISO_URL=""
            WINDOWS_ISO_SIZE=0
        fi

        if [ "${SKIP_VIRTIO_DOWNLOAD:-0}" -eq 0 ]; then
            VIRTIO_ISO_URL=$(prompt_url "$DEFAULT_VIRTIO_ISO_URL" "Enter the URL for Virtio.iso (leave blank to use default): ")
            VIRTIO_ISO_SIZE=$(get_content_length "$VIRTIO_ISO_URL")
        else
            VIRTIO_ISO_URL=""
            VIRTIO_ISO_SIZE=0
        fi
    fi

    if [ -z "$WINDOWS_ISO_SIZE" ] || [ -z "$VIRTIO_ISO_SIZE" ]; then
        echo "ERROR: Unable to determine ISO sizes from HTTP headers."
        exit 1
    fi

    TOTAL_ISO_SIZE=$((WINDOWS_ISO_SIZE + VIRTIO_ISO_SIZE))
    ZRAM_SIZE_MARGIN_MB=1024
    TOTAL_ISO_SIZE_MB=$((TOTAL_ISO_SIZE / 1024 / 1024 + ZRAM_SIZE_MARGIN_MB))

    if [ -n "${WINDOWS_ISO:-}" ] && [ -n "${VIRTIO_ISO:-}" ]; then
        echo "Continuing with existing downloads: $WINDOWS_ISO and $VIRTIO_ISO"
        return
    fi

    if [ "${SKIP_WINDOWS_DOWNLOAD:-0}" -eq 1 ] && [ "${SKIP_VIRTIO_DOWNLOAD:-0}" -eq 1 ]; then
        echo "Both Windows and VirtIO media are already present in /mnt. Skipping download and zram setup."
        return
    fi

    AVAILABLE_RAM_MB=0
    if command_exists free; then
        AVAILABLE_RAM_MB=$(free -m | awk '/^Mem:/ {print $7}')
    fi
    SAFE_RAM_MB=$((AVAILABLE_RAM_MB - 512))
    if [ "$SAFE_RAM_MB" -lt 0 ]; then
        SAFE_RAM_MB=0
    fi

    echo "Detected available RAM: ${AVAILABLE_RAM_MB}MB"
    echo "Reserving 512MB; safe RAM for zram: ${SAFE_RAM_MB}MB"
    echo "Estimated ISO download size: $((TOTAL_ISO_SIZE / 1024 / 1024))MB"
    echo "Allocating zram with buffer: ${TOTAL_ISO_SIZE_MB}MB"

    if [ "$TOTAL_ISO_SIZE_MB" -le "$SAFE_RAM_MB" ]; then
        echo "Creating zram of size ${TOTAL_ISO_SIZE_MB}MB..."
        if mountpoint -q /mnt/zram0 2>/dev/null; then
            umount /mnt/zram0 || true
        fi
        if [ -e /dev/zram0 ]; then
            swapoff /dev/zram0 2>/dev/null || true
            echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        fi
        modprobe zram >/dev/null 2>&1 || true
        echo lz4 > /sys/block/zram0/comp_algorithm
        echo "${TOTAL_ISO_SIZE_MB}M" > /sys/block/zram0/disksize
        zram_disksize=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
        if [ "$zram_disksize" -eq 0 ]; then
            echo "WARNING: zram disksize remained 0 after initialization. Falling back to disk."
            USE_ZRAM=0
        elif mkfs.ext4 -q /dev/zram0 && mkdir -p /mnt/zram0 && mount /dev/zram0 /mnt/zram0; then
            USE_ZRAM=1
            echo "zram mounted at /mnt/zram0."
        else
            echo "WARNING: zram format or mount failed. Falling back to disk."
            USE_ZRAM=0
        fi
    else
        echo "WARNING: Insufficient RAM for zram; using disk fallback."
        USE_ZRAM=0
    fi
    if [ "$USE_ZRAM" -eq 1 ]; then
        mkdir -p /mnt/zram0/windisk
        WINDOWS_ISO="/mnt/zram0/windisk/Windows.iso"
        VIRTIO_ISO="/mnt/zram0/windisk/VirtIO.iso"
    else
        mkdir -p /root/windisk
        WINDOWS_ISO="/root/windisk/Windows.iso"
        VIRTIO_ISO="/root/windisk/VirtIO.iso"

        REQUIRED_DISK_BYTES=$((TOTAL_ISO_SIZE + TOTAL_ISO_SIZE / 5))
        DOWNLOAD_DIR="/root/windisk"
        DOWNLOAD_AVAIL=$(df --output=avail "$DOWNLOAD_DIR" | tail -n 1)
        DOWNLOAD_AVAIL_BYTES=$((DOWNLOAD_AVAIL * 1024))
        if [ "$DOWNLOAD_AVAIL_BYTES" -lt "$REQUIRED_DISK_BYTES" ]; then
            echo "ERROR: Not enough disk space on $DOWNLOAD_DIR for ISO downloads."
            exit 1
        fi
    fi
}

verify_file_size() {
    local path="$1"
    local expected="$2"
    if [ -f "$path" ]; then
        local actual
        actual=$(stat -c%s "$path")
        [ "$actual" -eq "$expected" ]
    else
        return 1
    fi
}

download_if_needed() {
    local url="$1"
    local path="$2"
    local expected="$3"

    if verify_file_size "$path" "$expected"; then
        echo "$path already exists and matches expected size. Skipping download."
        return
    fi

    if [ -z "${url:-}" ]; then
        echo "ERROR: No URL provided for $path and the file is missing or incomplete."
        exit 1
    fi

    echo "Downloading $path..."
    download_file "$url" "$path"

    if ! verify_file_size "$path" "$expected"; then
        echo "ERROR: Downloaded file size does not match expected size for $path"
        exit 1
    fi
}

copy_windows_media() {
    if [ -f /mnt/bootmgr ] && [ -f /mnt/sources/boot.wim ]; then
        echo "Windows installer files already present on /mnt. Skipping Windows ISO extraction."
        return
    fi
    echo "Extracting Windows ISO to /mnt..."
    WINFILE_MOUNT=$(mktemp -d)
    mount -o loop "$WINDOWS_ISO" "$WINFILE_MOUNT"
    rsync -avz --progress "$WINFILE_MOUNT"/* /mnt/
    umount "$WINFILE_MOUNT"
    rmdir "$WINFILE_MOUNT"
}

copy_virtio_media() {
    if [ -d /mnt/sources/virtio ] && [ -f /mnt/sources/virtio/NetKVM/2k3/amd64/netkvm.sys ]; then
        echo "VirtIO drivers already copied to /mnt/sources/virtio. Skipping VirtIO ISO extraction."
        return
    fi
    echo "Extracting VirtIO ISO to /mnt/sources/virtio..."
    ISO_MOUNT_DIR=$(mktemp -d)
    mount -o loop "$VIRTIO_ISO" "$ISO_MOUNT_DIR"
    mkdir -p /mnt/sources/virtio
    rsync -avz --progress "$ISO_MOUNT_DIR"/ /mnt/sources/virtio/
    umount "$ISO_MOUNT_DIR"
    rmdir "$ISO_MOUNT_DIR"
}

write_bypass_files() {
    if [ -f /mnt/sources/bypass.reg ] && [ -f /mnt/sources/bypass.cmd ]; then
        echo "Bypass files already exist. Skipping creation."
        return
    fi
    cat <<'EOF' > /mnt/sources/bypass.reg
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig]
"BypassTPMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
"BypassRAMCheck"=dword:00000001
"BypassCPUCheck"=dword:00000001
"BypassStorageCheck"=dword:00000001
EOF

    cat <<'EOF' > /mnt/sources/bypass.cmd
@echo off
regedit /s "%~dp0bypass.reg"
EOF
}

patch_boot_wim() {
    if [ -f /mnt/sources/boot.wim.virtio_patched ]; then
        echo "boot.wim already patched with VirtIO drivers. Skipping WIM update."
        return
    fi
    if [ ! -f /mnt/sources/boot.wim ]; then
        echo "ERROR: /mnt/sources/boot.wim not found."
        exit 1
    fi
    if ! command_exists wimlib-imagex; then
        echo "WARNING: wimlib-imagex not installed. Skipping boot.wim patch."
        echo "Warning: VirtIO drivers will still be copied to /mnt/sources/virtio, but boot.wim injection will not be applied."
        return
    fi
    echo "Inspecting boot.wim images..."
    wimlib-imagex info /mnt/sources/boot.wim > /tmp/bootwim_info.txt
    auto_image_index=$(awk '
        BEGIN { first_idx=""; fallback_idx=""; found=0 }
        /Index:/ { idx=$2; if (first_idx == "") first_idx = idx }
        /Name:/ {
            name = substr($0, index($0, $2))
            lname = tolower(name)
            if (lname ~ /windows setup/ || lname ~ /microsoft windows setup/ || lname ~ /setup \(amd64\)/) {
                print idx
                found=1
                exit
            }
            if (lname ~ /windows pe/ && fallback_idx == "") {
                fallback_idx = idx
            }
        }
        END {
            if (found) exit
            if (fallback_idx != "") {
                print fallback_idx
            } else if (first_idx != "") {
                print first_idx
            }
        }
    ' /tmp/bootwim_info.txt)
    rm -f /tmp/bootwim_info.txt

    if [ -z "$auto_image_index" ]; then
        echo "ERROR: Unable to determine boot.wim image index."
        exit 1
    fi

    echo "Auto-selected boot.wim image index: $auto_image_index"
    echo "add /mnt/sources/virtio /virtio_drivers" > /tmp/wimcmd.txt
    wimlib-imagex update /mnt/sources/boot.wim "$auto_image_index" < /tmp/wimcmd.txt
    rm -f /tmp/wimcmd.txt
    touch /mnt/sources/boot.wim.virtio_patched
}

install_grub_if_needed() {
    echo "Installing or updating GRUB on /dev/sda..."
    mkdir -p /mnt/boot/grub
    if ! grub-install --boot-directory=/mnt/boot /dev/sda; then
        echo "grub-install failed. Retrying with --force to allow blocklists on GPT."
        grub-install --boot-directory=/mnt/boot --force /dev/sda
    fi
    cat > /mnt/boot/grub/grub.cfg <<'EOF'
set default=0
set timeout=2
menuentry "windows installer" {
    insmod ntfs
    search --no-floppy --set=root --file=/bootmgr
    ntldr /bootmgr || chainloader +1
    boot
}
EOF
}

main() {
    ensure_toolchain
    setup_partitions_and_mounts
    setup_download_environment
    if [ -n "${WINDOWS_ISO_URL:-}" ] || [ -n "${WINDOWS_ISO:-}" ]; then
        download_if_needed "$WINDOWS_ISO_URL" "$WINDOWS_ISO" "$WINDOWS_ISO_SIZE"
    else
        echo "Skipping Windows ISO download because installer media already exists."
    fi
    if [ -n "${VIRTIO_ISO_URL:-}" ] || [ -n "${VIRTIO_ISO:-}" ]; then
        download_if_needed "$VIRTIO_ISO_URL" "$VIRTIO_ISO" "$VIRTIO_ISO_SIZE"
    else
        echo "Skipping VirtIO ISO download because driver media already exists."
    fi
    copy_windows_media
    copy_virtio_media
    write_bypass_files
    patch_boot_wim
    install_grub_if_needed

    echo "*** Final checks ***"
    ls -lh /mnt/bootmgr /mnt/sources/boot.wim || true
    ls -lh /mnt/sources/virtio || true
    echo "Resume script completed. You can reboot manually when ready."
}

main "$@"
