#!/bin/bash
# ALTERNATE SCRIPT: alternate copy with auto-install dependency helper
set -euo pipefail

NO_PROMPT=0
FORCE_DOWNLOAD=0
CHECK_ONLY=0
ISO_URL=""
VIRTIO_ISO_URL=""
WINDOWS_ISO_MD5=""
VIRTIO_ISO_MD5=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --no-prompt)
            NO_PROMPT=1
            shift
            ;;
        --force-download)
            FORCE_DOWNLOAD=1
            shift
            ;;
        --check-only)
            CHECK_ONLY=1
            shift
            ;;
        --iso-url|--windows-iso-url)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --iso-url requires a value."
                exit 1
            fi
            ISO_URL="$2"
            shift 2
            ;;
        --iso-url=*|--windows-iso-url=*)
            ISO_URL="${1#*=}"
            shift
            ;;
        --virtio-url|--virtio-iso-url)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --virtio-url requires a value."
                exit 1
            fi
            VIRTIO_ISO_URL="$2"
            shift 2
            ;;
        --virtio-url=*|--virtio-iso-url=*)
            VIRTIO_ISO_URL="${1#*=}"
            shift
            ;;
        --windows-iso-md5|--iso-md5)
            WINDOWS_ISO_MD5="$2"
            shift 2
            ;;
        --virtio-iso-md5|--virtio-md5)
            VIRTIO_ISO_MD5="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            exit 1
            ;;
    esac
done

DEFAULT_VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

if [[ -z "$ISO_URL" ]]; then
    if [[ "$NO_PROMPT" -eq 0 ]]; then
        read -r -p "Enter the URL for Windows.iso: " input_url
        ISO_URL="${input_url:-}"
    fi
fi

if [[ -z "$VIRTIO_ISO_URL" ]]; then
    if [[ "$NO_PROMPT" -eq 0 ]]; then
        read -r -p "Enter the URL for Virtio.iso (leave blank to use default): " input_virtio
        VIRTIO_ISO_URL="${input_virtio:-$DEFAULT_VIRTIO_ISO_URL}"
    else
        VIRTIO_ISO_URL="$DEFAULT_VIRTIO_ISO_URL"
    fi
fi

if [[ -z "$ISO_URL" ]]; then
    echo "ERROR: Windows ISO URL is required."
    exit 1
fi

echo "Using Windows ISO URL: $ISO_URL"
echo "Using VirtIO ISO URL: $VIRTIO_ISO_URL"

package_for_command() {
    case "$1" in
        mkfs.ntfs) echo ntfs-3g ;;
        mkfs.ext4) echo e2fsprogs ;;
        grub-install|grub-probe) echo grub-pc ;;
        git) echo git ;;
        aria2c) echo aria2 ;;
        wget) echo wget ;;
        rsync) echo rsync ;;
        parted|partprobe) echo parted ;;
        gdisk) echo gdisk ;;
        curl) echo curl ;;
        md5sum) echo coreutils ;;
        awk) echo gawk ;;
        grep) echo grep ;;
        mount|umount) echo mount ;;
        *) echo "" ;;
    esac
}

download_tool_available() {
    command -v aria2c >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1
}

available_ram_mb() {
    if command -v free >/dev/null 2>&1; then
        free -m | awk '/^Mem:/ {print $7}'
    elif [[ -r /proc/meminfo ]]; then
        awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo
    else
        echo 0
    fi
}

cleanup_zram() {
    if mountpoint -q /mnt/zram0 2>/dev/null; then
        echo "Unmounting stale zram at /mnt/zram0..."
        umount /mnt/zram0 || true
    fi
    if [[ -e /dev/zram0 ]]; then
        swapoff /dev/zram0 2>/dev/null || true
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    fi
    rm -rf /mnt/zram0 2>/dev/null || true
}

free_memory() {
    echo "Attempting to free file cache memory..."
    sync
    if [[ -w /proc/sys/vm/drop_caches ]]; then
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    fi
}

safe_ram_mb() {
    local avail
    avail=$(available_ram_mb)
    if [[ "$avail" -gt "$ZRAM_MARGIN_MB" ]]; then
        echo $((avail - ZRAM_MARGIN_MB))
    else
        echo 0
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

download_to_zram_and_copy() {
    local name=$1
    local url=$2
    local dest=$3
    local target_mb=$4
    local temp_dir
    local temp_file

    if ! attempt_zram_setup "$target_mb"; then
        return 1
    fi

    temp_dir="/mnt/zram0/windisk"
    temp_file="$temp_dir/${name}.iso"
    mkdir -p "$temp_dir"

    echo "Downloading $name ISO to $temp_file..."
    if ! retry_download "$url" "$temp_file"; then
        cleanup_zram
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    echo "Copying $name ISO from zram to $dest..."
    cp -av "$temp_file" "$dest"
    cleanup_zram
    return 0
}

choose_disk_download_dir() {
    local required_bytes=$1
    local tmp_avail mnt_avail root_avail

    mkdir -p /tmp/windisk
    tmp_avail=$(df --output=avail /tmp 2>/dev/null | tail -n 1 || echo 0)
    if [[ $((tmp_avail * 1024)) -ge "$required_bytes" ]]; then
        echo "/tmp/windisk"
        return
    fi

    if ! mountpoint -q /mnt 2>/dev/null && [[ -b /dev/sda2 ]]; then
        echo "Attempting to mount /dev/sda2 at /mnt for disk fallback..."
        mkdir -p /mnt
        mount /dev/sda2 /mnt 2>/dev/null || true
    fi

    if mountpoint -q /mnt 2>/dev/null; then
        mnt_avail=$(df --output=avail /mnt 2>/dev/null | tail -n 1)
        if [[ $((mnt_avail * 1024)) -ge "$required_bytes" ]]; then
            echo "/mnt/windisk"
            return
        fi
    fi

    root_avail=$(df --output=avail / 2>/dev/null | tail -n 1 || echo 0)
    if [[ $((root_avail * 1024)) -ge "$required_bytes" ]]; then
        echo "/root/windisk"
        return
    fi

    echo ""
}

install_packages_for_commands() {
    local cmd pkg
    local packages=()
    local pkg_seen=""
    local apt_cache_dir="/mnt/apt"
    local apt_opts=(
        -o Dir::State::Lists=${apt_cache_dir}/lists
        -o Dir::Cache::Archives=${apt_cache_dir}/archives
        -o Dir::Cache::pkgcache=${apt_cache_dir}/pkgcache.bin
        -o Dir::Cache::srcpkgcache=${apt_cache_dir}/srcpkgcache.bin
    )

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "ERROR: apt-get is required to install missing packages."
        return 1
    fi

    mkdir -p "${apt_cache_dir}/lists" "${apt_cache_dir}/archives"

    for cmd in "$@"; do
        pkg=$(package_for_command "$cmd")
        if [[ -n "$pkg" ]]; then
            if ! printf '%s\n' "$pkg_seen" | grep -Fxq "$pkg" 2>/dev/null; then
                pkg_seen="$pkg_seen $pkg"
                packages+=("$pkg")
            fi
        fi
    done

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    echo "Installing missing packages: ${packages[*]}"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq "${apt_opts[@]}"; then
        echo "WARNING: apt-get update failed; continuing if packages can be satisfied from what is already installed."
    fi
    if ! apt-get install -y --no-install-recommends "${apt_opts[@]}" "${packages[@]}"; then
        echo "WARNING: apt-get install failed for ${packages[*]}."
        return 1
    fi
    return 0
}

ensure_required_tools() {
    local required=(awk grep rsync parted partprobe mkfs.ntfs mkfs.ext4 mount umount grub-install grub-probe git md5sum)
    local missing=()
    local cmd

    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    local download_tool_missing=1
    for cmd in aria2c wget curl; do
        if command -v "$cmd" >/dev/null 2>&1; then
            download_tool_missing=0
            break
        fi
    done
    if [[ "$download_tool_missing" -eq 1 ]]; then
        missing+=("aria2c wget curl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        if ! install_packages_for_commands "${missing[@]}"; then
            echo "WARNING: Could not automatically install missing packages."
        fi
        missing=()
        for cmd in "${required[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                missing+=("$cmd")
            fi
        done

        if [[ "$download_tool_missing" -eq 1 ]]; then
            local download_available=0
            for cmd in aria2c wget curl; do
                if command -v "$cmd" >/dev/null 2>&1; then
                    download_available=1
                    break
                fi
            done
            if [[ "$download_available" -eq 0 ]]; then
                missing+=("aria2c wget curl")
            fi
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required commands after installation: ${missing[*]}"
        exit 1
    fi

    if ! download_tool_available; then
        echo "ERROR: No download tool available (aria2c, wget, or curl)."
        exit 1
    fi
}

force_unmount_sda1() {
    local dev="/dev/sda1"
    if grep -q -E "^${dev} " /proc/mounts 2>/dev/null || mountpoint -q "$dev" 2>/dev/null; then
        echo "Force-unmounting $dev first..."
        umount "$dev" 2>/dev/null || true
        umount -l "$dev" 2>/dev/null || true
        sleep 1
    fi
}

verify_iso_md5() {
    local file="$1"
    local expected="$2"
    if [[ -z "$expected" ]]; then
        return 0
    fi
    if ! command -v md5sum >/dev/null 2>&1; then
        echo "WARNING: md5sum unavailable, skipping hash verification for $file"
        return 0
    fi
    local actual
    actual=$(md5sum "$file" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: MD5 mismatch for $file"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        return 1
    fi
    echo "MD5 verified for $file"
}

ensure_required_tools

echo "Deactivating swap and unmounting all /dev/sda partitions..."
swapoff -a || true
force_unmount_sda1
for part in $(lsblk -ln -o NAME | grep '^sda' | grep -v '^sda$' | grep -v '^sda1$'); do
    umount /dev/$part 2>/dev/null || true
    umount -l /dev/$part 2>/dev/null || true
done
force_unmount_sda1
echo "All /dev/sda partitions unmounted and swap deactivated."

SWAPFILE="/swapfile"
if [[ ! -f "$SWAPFILE" ]]; then
    echo "Creating temporary swap file..."
    fallocate -l 1G "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=1024
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    if swapon "$SWAPFILE"; then
        echo "Temporary swap file created and activated."
    else
        echo "WARNING: swapon failed; continuing without swap."
    fi
fi

ARIA2_OPTS=(
    --max-connection-per-server=16
    --split=16
    --min-split-size=1M
    --timeout=60
    --retry-wait=30
    --max-tries=5
    --always-resume=true
    --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
)

USER_AGENTS=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Mobile Safari/537.36"
)

get_content_length() {
    local url="$1"
    local size

    for ua in "${USER_AGENTS[@]}"; do
        size=$(curl -sSLI --max-redirs 10 -A "$ua" "$url" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1)
        if [[ -n "$size" ]]; then
            echo "$size"
            return 0
        fi
    done

    return 1
}

retry_download() {
    local url="$1"
    local output="$2"
    local dir
    local ua
    local rc=1

    dir=$(dirname "$output")
    if [[ -n "$dir" ]]; then
        mkdir -p "$dir" || {
            echo "ERROR: Failed to create download directory $dir"
            return 1
        }
    fi

    if command -v aria2c >/dev/null 2>&1; then
        aria2c "${ARIA2_OPTS[@]}" -o "$output" "$url"
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        for ua in "${USER_AGENTS[@]}"; do
            echo "Trying wget with UA: $ua"
            wget --user-agent="$ua" -O "$output" "$url" && return 0
            rc=$?
        done
    fi

    if command -v curl >/dev/null 2>&1; then
        for ua in "${USER_AGENTS[@]}"; do
            echo "Trying curl with UA: $ua"
            curl -L -A "$ua" -o "$output" "$url" && return 0
            rc=$?
        done
        return $rc
    fi

    echo "ERROR: No download tool available for $url"
    return 1
}

WINDOWS_ISO_URL="$ISO_URL"

TOTAL_ISO_SIZE_BYTES=0
WINDOWS_ISO_SIZE=$(get_content_length "$WINDOWS_ISO_URL")
if [[ -z "$WINDOWS_ISO_SIZE" ]]; then
    echo "ERROR: Unable to determine Windows ISO size from HTTP headers."
    exit 1
fi

VIRTIO_ISO_URL="$VIRTIO_ISO_URL"
VIRTIO_ISO_SIZE=$(get_content_length "$VIRTIO_ISO_URL")
if [[ -z "$VIRTIO_ISO_SIZE" ]]; then
    echo "ERROR: Unable to determine VirtIO ISO size from HTTP headers."
    exit 1
fi

TOTAL_ISO_SIZE_BYTES=$((WINDOWS_ISO_SIZE + VIRTIO_ISO_SIZE))
TOTAL_ISO_SIZE_MB=$(((TOTAL_ISO_SIZE_BYTES + 1024*1024 - 1) / 1024 / 1024))
ZRAM_MARGIN_MB=512
ZRAM_DISKSIZE_MB=$((TOTAL_ISO_SIZE_MB + 512))
REQUIRED_DISK_BYTES=$((TOTAL_ISO_SIZE_BYTES + TOTAL_ISO_SIZE_BYTES / 5))

WINDOWS_ISO_DEST="/root/windisk/Windows.iso"
VIRTIO_ISO_DEST="/root/windisk/VirtIO.iso"
WINDOWS_ISO_MB=$(((WINDOWS_ISO_SIZE + 1024*1024 - 1) / 1024 / 1024))
VIRTIO_ISO_MB=$(((VIRTIO_ISO_SIZE + 1024*1024 - 1) / 1024 / 1024))
WINDOWS_ZRAM_MB=$((WINDOWS_ISO_MB + 256))
VIRTIO_ZRAM_MB=$((VIRTIO_ISO_MB + 256))

if [[ "$FORCE_DOWNLOAD" -eq 1 ]]; then
    rm -f "$WINDOWS_ISO_DEST" "$VIRTIO_ISO_DEST"
fi

if mountpoint -q /mnt/zram0 2>/dev/null; then
    echo "Existing zram mount detected; resetting zram state before reuse."
    cleanup_zram
fi

echo "Evaluating whether zram-backed download is possible..."
AVAILABLE_RAM_MB=$(available_ram_mb)
SAFE_RAM_MB=$(safe_ram_mb)
if [[ "$SAFE_RAM_MB" -ge "$WINDOWS_ZRAM_MB" ]]; then
    echo "Detected $AVAILABLE_RAM_MB MB available RAM; allowing zram usage for Windows ISO (${WINDOWS_ZRAM_MB}MB)."
    if download_to_zram_and_copy "Windows" "$WINDOWS_ISO_URL" "$WINDOWS_ISO_DEST" "$WINDOWS_ZRAM_MB"; then
        echo "Windows ISO downloaded via zram and copied to $WINDOWS_ISO_DEST."
    else
        echo "WARNING: Unable to download Windows ISO via zram; falling back to disk for Windows ISO."
        cleanup_zram
        DOWNLOAD_DIR=""
    fi
else
    echo "Not enough safe RAM ($AVAILABLE_RAM_MB MB available, $SAFE_RAM_MB MB safe) to use zram for Windows ISO. Downloading Windows ISO to disk."
    DOWNLOAD_DIR=""
fi

if [[ ! -f "$WINDOWS_ISO_DEST" ]]; then
    echo "Using disk-based download for Windows ISO."
    DOWNLOAD_DIR=$(choose_disk_download_dir "$WINDOWS_ISO_SIZE")
    if [[ -z "$DOWNLOAD_DIR" ]]; then
        echo "ERROR: No disk location has enough space for the Windows ISO."
        exit 1
    fi
    mkdir -p "$DOWNLOAD_DIR"
    WINDOWS_ISO="$DOWNLOAD_DIR/Windows.iso"
    echo "Downloading Windows ISO to $WINDOWS_ISO..."
    if ! retry_download "$WINDOWS_ISO_URL" "$WINDOWS_ISO"; then
        echo "ERROR: Windows ISO download failed."
        exit 1
    fi
    WINDOWS_ISO_DEST="$WINDOWS_ISO"
fi

# Re-evaluate available RAM for VirtIO after Windows ISO is on disk.
AVAILABLE_RAM_MB=$(available_ram_mb)
SAFE_RAM_MB=$(safe_ram_mb)
if [[ "$SAFE_RAM_MB" -ge "$VIRTIO_ZRAM_MB" ]]; then
    echo "Detected $AVAILABLE_RAM_MB MB available RAM; allowing zram usage for VirtIO ISO (${VIRTIO_ZRAM_MB}MB)."
    if download_to_zram_and_copy "VirtIO" "$VIRTIO_ISO_URL" "$VIRTIO_ISO_DEST" "$VIRTIO_ZRAM_MB"; then
        echo "VirtIO ISO downloaded via zram and copied to $VIRTIO_ISO_DEST."
    else
        echo "WARNING: Unable to download VirtIO ISO via zram; falling back to disk for VirtIO ISO."
        cleanup_zram
        DOWNLOAD_DIR=""
    fi
else
    echo "Not enough safe RAM ($AVAILABLE_RAM_MB MB available, $SAFE_RAM_MB MB safe) to use zram for VirtIO ISO. Downloading VirtIO ISO to disk."
    DOWNLOAD_DIR=""
fi

if [[ ! -f "$VIRTIO_ISO_DEST" ]]; then
    echo "Using disk-based download for VirtIO ISO."
    DOWNLOAD_DIR=$(choose_disk_download_dir "$VIRTIO_ISO_SIZE")
    if [[ -z "$DOWNLOAD_DIR" ]]; then
        echo "ERROR: No disk location has enough space for the VirtIO ISO."
        exit 1
    fi
    mkdir -p "$DOWNLOAD_DIR"
    VIRTIO_ISO="$DOWNLOAD_DIR/VirtIO.iso"
    echo "Downloading VirtIO ISO to $VIRTIO_ISO..."
    if ! retry_download "$VIRTIO_ISO_URL" "$VIRTIO_ISO"; then
        echo "ERROR: VirtIO ISO download failed."
        exit 1
    fi
    VIRTIO_ISO_DEST="$VIRTIO_ISO"
fi

WINDOWS_ISO="$WINDOWS_ISO_DEST"
VIRTIO_ISO="$VIRTIO_ISO_DEST"

if [[ ! -f "$WINDOWS_ISO" || ! -f "$VIRTIO_ISO" ]]; then
    echo "ERROR: One or both ISO files are missing after download."
    exit 1
fi

verify_iso_md5 "$WINDOWS_ISO" "$WINDOWS_ISO_MD5"
verify_iso_md5 "$VIRTIO_ISO" "$VIRTIO_ISO_MD5"

echo "Windows ISO downloaded successfully to $WINDOWS_ISO."
echo "VirtIO ISO downloaded successfully to $VIRTIO_ISO."

