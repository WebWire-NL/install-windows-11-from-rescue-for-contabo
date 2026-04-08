#!/usr/bin/env bash
set -euo pipefail

# Resume Windows install preparation after a partial run.
# This script detects completed checkpoints and skips steps already done.

SELF_UPDATE_URL="https://raw.githubusercontent.com/WebWire-NL/install-windows-11-from-rescue-for-contabo/master/windows-install.sh"

STATE_DIR="/root/.wininstall-state"
mkdir -p "$STATE_DIR"

checkpoint_done() {
    [ -f "$STATE_DIR/$1" ]
}

checkpoint_set() {
    touch "$STATE_DIR/$1"
}

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
        wimlib-imagex) echo wimtools ;;
        aria2c) echo aria2 ;;
        wget) echo wget ;;
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
        if [ -n "$pkg" ] && ! printf '%s\n' "${missing[@]:-}" | grep -xq "$pkg"; then
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

    if cmp -s "$0" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi

    if tr -d '\r' < "$0" | cmp -s - <(tr -d '\r' < "$tmp"); then
        rm -f "$tmp"
        return 0
    fi

    echo "A newer installer script version is available. Re-running the latest version."
    bash "$tmp" --no-self-update "$@"
    exit $?
}

RECREATE_DISK=0
CHECK_ONLY=0
FORCE_DOWNLOAD=0
USE_ZRAM=0
NO_PROMPT=0
WINDOWS_ISO_URL_ARG=""
VIRTIO_ISO_URL_ARG=""
ORIGINAL_ARGS=("$@")
PARSED_ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --recreate-disk)
            RECREATE_DISK=1
            shift
            ;;
        --check-only)
            CHECK_ONLY=1
            shift
            ;;
        --force-download)
            FORCE_DOWNLOAD=1
            shift
            ;;
        --no-prompt)
            NO_PROMPT=1
            shift
            ;;
        --windows-iso-url)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --windows-iso-url requires a value."
                exit 1
            fi
            shift
            WINDOWS_ISO_URL_ARG="$1"
            shift
            ;;
        --windows-iso-url=*)
            WINDOWS_ISO_URL_ARG="${1#*=}"
            shift
            ;;
        --virtio-iso-url)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --virtio-iso-url requires a value."
                exit 1
            fi
            shift
            VIRTIO_ISO_URL_ARG="$1"
            shift
            ;;
        --virtio-iso-url=*)
            VIRTIO_ISO_URL_ARG="${1#*=}"
            shift
            ;;
        *)
            PARSED_ARGS+=("$1")
            shift
            ;;
    esac
 done
set -- "${PARSED_ARGS[@]}"

self_update_script "${ORIGINAL_ARGS[@]}"

DEFAULT_WINDOWS_ISO_URL=""
DEFAULT_VIRTIO_ISO_URL="https://bit.ly/4d1g7Ht"
GRUB_INSTALL_TARGET="i386-pc"

prompt_url() {
    local default="$1"
    local prompt="$2"
    local value
    if [ ! -t 0 ]; then
        echo "$default"
        return
    fi
    read -r -p "$prompt" value
    echo "${value:-$default}"
}

get_content_length() {
    local url="$1"
    local size

    if command_exists curl; then
        size=$(curl -fsIL "$url" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1)
        if [ -n "$size" ]; then
            echo "$size"
            return
        fi
    fi

    if command_exists wget; then
        size=$(wget --spider --server-response --max-redirect=20 "$url" 2>&1 | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1)
        if [ -n "$size" ]; then
            echo "$size"
            return
        fi
    fi

    echo ""
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
        local aria2_args=(--continue=true --file-allocation=none --enable-http-keep-alive=true)
        if aria2c --help 2>/dev/null | grep -q -- '--enable-http2'; then
            aria2_args+=(--enable-http2=true)
        else
            echo "aria2c does not support --enable-http2; downloading without HTTP/2."
        fi
        aria2_args+=(--max-connection-per-server=64 --split=64 --min-split-size=4M)
        aria2_args+=(--max-tries=0 --retry-wait=15 --timeout=60 --retry-connrefused=true)
        aria2_args+=(--download-result=full --user-agent="$ua")
        set +e
        aria2c "${aria2_args[@]}" -d "$dir" -o "$base" --input-file="$session" "$url" >"$log" 2>&1
        local aria2_rc=$?
        set -e

        if [ "$aria2_rc" -ne 0 ]; then
            echo "WARNING: aria2c failed with exit code $aria2_rc. Falling back to curl."
            if command_exists curl; then
                curl --http2 --compressed --retry 5 --retry-delay 10 --retry-connrefused \
                    --location --continue-at - --user-agent "$ua" --output "$output" "$url"
            elif command_exists wget; then
                echo "WARNING: curl not available. Falling back to wget."
                wget --tries=0 --waitretry=5 --retry-connrefused --continue --timeout=60 \
                    --user-agent="$ua" -O "$output" "$url"
            else
                echo "WARNING: curl and wget not available. Installing wget."
                install_missing_dependencies wget
                if command_exists wget; then
                    wget --tries=0 --waitretry=5 --retry-connrefused --continue --timeout=60 \
                        --user-agent="$ua" -O "$output" "$url"
                else
                    echo "ERROR: wget installation failed. Cannot download $url"
                    exit 1
                fi
            fi
        fi
    else
        if command_exists wget; then
            echo "aria2c not available, downloading $output with wget"
            wget --tries=5 --waitretry=5 --retry-connrefused --continue --timeout=60 \
                --user-agent="$ua" -O "$output" "$url"
        else
            echo "aria2c not available and wget is missing. Installing wget."
            install_missing_dependencies wget
            if command_exists wget; then
                wget --tries=5 --waitretry=5 --retry-connrefused --continue --timeout=60 \
                    --user-agent="$ua" -O "$output" "$url"
            else
                echo "ERROR: wget installation failed. Cannot download $url"
                exit 1
            fi
        fi
    fi
}

ensure_toolchain() {
    local required=(parted mkfs.ntfs mkfs.ext4 mount rsync grub-install curl grep awk pgrep xargs dpkg-deb modprobe partprobe blockdev partx wimlib-imagex aria2c)
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

verify_toolchain() {
    local required=(parted mkfs.ntfs mkfs.ext4 mount rsync grub-install curl grep awk pgrep xargs dpkg-deb modprobe partprobe blockdev partx wimlib-imagex aria2c)
    local missing=()

    for cmd in "${required[@]}"; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "WARNING: missing required commands: ${missing[*]}"
        echo "         Run the installer normally to install missing packages, or install them manually."
    else
        echo "All required commands are available."
    fi
}

verify_disk_layout() {
    local disk_label
    disk_label=$(get_disk_label)

    if [ "${FIRMWARE_MODE}" = "bios" ] && [ "${disk_label}" = "gpt" ] && ! has_bios_boot_partition; then
        echo "WARNING: BIOS firmware on GPT without bios_grub partition. GRUB requires blocklists and may be unreliable."
    fi

    if [ "${FIRMWARE_MODE}" = "uefi" ] && [ "${disk_label}" != "gpt" ]; then
        echo "WARNING: UEFI firmware detected but disk is not GPT. Windows install may fail."
    fi

    if [ "${disk_label}" = "unknown" ]; then
        if [ "$CHECK_ONLY" -eq 1 ]; then
            echo "WARNING: Unable to determine disk partition label. A blank disk is acceptable for fresh install."
        else
            echo "ERROR: Unable to determine disk partition label. Verify /dev/sda is accessible."
            exit 1
        fi
    fi
}

verify_installer_files() {
    local errors=0

    if [ ! -f /mnt/bootmgr ]; then
        if [ "$CHECK_ONLY" -eq 1 ]; then
            echo "WARNING: /mnt/bootmgr is missing. The Windows installer entry is not yet prepared."
        else
            echo "ERROR: /mnt/bootmgr is missing. The Windows installer entry cannot boot."
            errors=1
        fi
    fi
    if [ ! -f /mnt/sources/boot.wim ]; then
        if [ "$CHECK_ONLY" -eq 1 ]; then
            echo "WARNING: /mnt/sources/boot.wim is missing. The installer payload is not yet prepared."
        else
            echo "ERROR: /mnt/sources/boot.wim is missing. The installer payload is incomplete."
            errors=1
        fi
    fi
    if [ ! -d /mnt/sources/virtio ]; then
        echo "WARNING: /mnt/sources/virtio is missing. VirtIO drivers may not be available during install."
    fi

    if [ "$errors" -ne 0 ]; then
        exit 1
    fi
}

verify_grub_config() {
    local cfg_path="/mnt/boot/grub/grub.cfg"

    if [ ! -f "$cfg_path" ]; then
        echo "ERROR: GRUB config not found at $cfg_path"
        exit 1
    fi

    if ! grep -Ei 'menuentry[[:space:]]+.*windows.*installer' "$cfg_path" >/dev/null 2>&1; then
        echo "ERROR: Expected GRUB menuentry containing \"windows installer\" not found in $cfg_path"
        exit 1
    fi

    if ! grep -qi 'search --no-floppy --set=root --file=/bootmgr' "$cfg_path" >/dev/null 2>&1; then
        echo "WARNING: GRUB entry may not point to /bootmgr correctly."
    fi
    if ! grep -qi 'insmod ntfs' "$cfg_path" >/dev/null 2>&1; then
        echo "WARNING: GRUB entry may not load NTFS support."
    fi
}

check_grub_config_noexit() {
    local cfg_path="/mnt/boot/grub/grub.cfg"
    if [ ! -f "$cfg_path" ]; then
        echo "ERROR: GRUB config not found at $cfg_path"
        return 1
    fi

    local ok=0
    if ! grep -Ei 'menuentry[[:space:]]+.*windows.*installer' "$cfg_path" >/dev/null 2>&1; then
        echo "ERROR: Expected GRUB menuentry containing \"windows installer\" not found in $cfg_path"
        ok=1
    else
        echo "INFO: GRUB menuentry for Windows installer found."
    fi

    if ! grep -qi 'search --no-floppy --set=root --file=/bootmgr' "$cfg_path" >/dev/null 2>&1; then
        echo "WARNING: GRUB entry may not point to /bootmgr correctly."
    fi
    if ! grep -qi 'insmod ntfs' "$cfg_path" >/dev/null 2>&1; then
        echo "WARNING: GRUB entry may not load NTFS support."
    fi

    return "$ok"
}

manual_rescue_verification() {
    echo "*** Manual rescue verification ***"
    mount_existing_partitions

    local failed=0
    if mountpoint -q /mnt; then
        echo "- /mnt is mounted"
    else
        if [ "$CHECK_ONLY" -eq 1 ]; then
            echo "WARNING: /mnt is not mounted. This is expected for a fresh installer state."
        else
            echo "ERROR: /mnt is not mounted"
            failed=1
        fi
    fi
    if mountpoint -q /root/windisk; then
        echo "- /root/windisk is mounted"
    else
        echo "WARNING: /root/windisk is not mounted"
    fi

    if [ -f /mnt/bootmgr ]; then
        echo "- /mnt/bootmgr is present"
    else
        if [ "$CHECK_ONLY" -eq 1 ]; then
            echo "WARNING: /mnt/bootmgr is missing"
        else
            echo "ERROR: /mnt/bootmgr is missing"
            failed=1
        fi
    fi
    if [ -f /mnt/sources/boot.wim ]; then
        echo "- /mnt/sources/boot.wim is present"
    else
        if [ "$CHECK_ONLY" -eq 1 ]; then
            echo "WARNING: /mnt/sources/boot.wim is missing"
        else
            echo "ERROR: /mnt/sources/boot.wim is missing"
            failed=1
        fi
    fi
    if [ -d /mnt/sources/virtio ]; then
        echo "- /mnt/sources/virtio is present"
    else
        echo "WARNING: /mnt/sources/virtio is missing"
    fi

    if [ -f /mnt/boot/grub/grub.cfg ]; then
        echo "- /mnt/boot/grub/grub.cfg is present"
        if ! check_grub_config_noexit; then
            if [ "$CHECK_ONLY" -eq 1 ]; then
                echo "WARNING: GRUB config is invalid or incomplete, but this can be fixed during install preparation."
            else
                failed=1
            fi
        fi
    else
        if [ "$CHECK_ONLY" -eq 1 ]; then
            echo "WARNING: /mnt/boot/grub/grub.cfg is missing"
        else
            echo "ERROR: /mnt/boot/grub/grub.cfg is missing"
            failed=1
        fi
    fi

    if [ "$CHECK_ONLY" -eq 1 ]; then
        echo "WARNING: Skipping GRUB installation and probe validation in check-only mode for fresh disk."
    else
        if verify_grub_installation_noexit >/dev/null 2>&1; then
            echo "- GRUB installation artifacts appear valid"
        else
            echo "ERROR: GRUB installation artifacts are incomplete or invalid"
            failed=1
        fi

        if command_exists grub-probe; then
            if grub-probe --target=fs /mnt >/dev/null 2>&1 && grub-probe --target=device /mnt >/dev/null 2>&1; then
                echo "- grub-probe can resolve /mnt filesystem and device"
            else
                echo "ERROR: grub-probe failed to resolve /mnt"
                failed=1
            fi
        else
            echo "WARNING: grub-probe unavailable; skipping probe validation"
        fi
    fi

    if [ "$failed" -eq 0 ]; then
        echo "Manual rescue verification passed. The installer filesystem and GRUB entry appear ready."
    else
        echo "Manual rescue verification found issues. Review the output above before rebooting."
    fi
    echo "*** End manual rescue verification ***"
    return "$failed"
}

cleanup_zram() {
    if mountpoint -q /mnt/zram0 2>/dev/null; then
        echo "Unmounting stale zram at /mnt/zram0..."
        umount /mnt/zram0 || true
    fi
    if [ -e /dev/zram0 ]; then
        swapoff /dev/zram0 2>/dev/null || true
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    fi
    rm -rf /mnt/zram0 2>/dev/null || true
}

cleanup_partition_state() {
    echo "Cleaning up stale /dev/sda state..."
    cleanup_zram
    umount /mnt 2>/dev/null || true
    umount /root/windisk 2>/dev/null || true
    if command_exists fuser; then
        if mountpoint -q /mnt 2>/dev/null; then
            echo "Forcing umount of /mnt via fuser..."
            fuser -km /mnt >/dev/null 2>&1 || true
            umount -l /mnt >/dev/null 2>&1 || true
        fi
        if mountpoint -q /root/windisk 2>/dev/null; then
            echo "Forcing umount of /root/windisk via fuser..."
            fuser -km /root/windisk >/dev/null 2>&1 || true
            umount -l /root/windisk >/dev/null 2>&1 || true
        fi
        if mountpoint -q /mnt/zram0 2>/dev/null; then
            echo "Forcing umount of /mnt/zram0 via fuser..."
            fuser -km /mnt/zram0 >/dev/null 2>&1 || true
            umount -l /mnt/zram0 >/dev/null 2>&1 || true
        fi
    fi
    if mountpoint -q /mnt 2>/dev/null; then
        echo "Attempting lazy umount of /mnt..."
        umount -l /mnt >/dev/null 2>&1 || true
    fi
    if mountpoint -q /root/windisk 2>/dev/null; then
        echo "Attempting lazy umount of /root/windisk..."
        umount -l /root/windisk >/dev/null 2>&1 || true
    fi
    if mountpoint -q /mnt/zram0 2>/dev/null; then
        echo "Attempting lazy umount of /mnt/zram0..."
        umount -l /mnt/zram0 >/dev/null 2>&1 || true
    fi
    if command_exists pkill; then
        echo "Killing lingering NTFS mount processes..."
        pkill -f '/sbin/mount.ntfs .* /root/windisk' >/dev/null 2>&1 || true
        pkill -f '/sbin/mount.ntfs .* /mnt' >/dev/null 2>&1 || true
        pkill -f 'ntfs-3g .* /root/windisk' >/dev/null 2>&1 || true
        pkill -f 'ntfs-3g .* /mnt' >/dev/null 2>&1 || true
    fi
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

get_available_ram_mb() {
    if command_exists free; then
        free -m | awk '/^Mem:/ {print $7}'
    elif [ -r /proc/meminfo ]; then
        awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo
    else
        echo 0
    fi
}

get_available_root_space_mb() {
    if df --output=avail /root/windisk >/dev/null 2>&1; then
        df --output=avail /root/windisk 2>/dev/null | tail -n 1 | tr -d ' '
    else
        echo 0
    fi
}

get_disk_label() {
    if ! command_exists parted; then
        echo "unknown"
        return
    fi

    local disk_output
    if ! disk_output=$(parted /dev/sda --script print 2>/dev/null); then
        echo "unknown"
        return
    fi

    local label
    label=$(printf '%s\n' "$disk_output" | awk -F: '/^Partition Table/ {print $2}' | tr -d '[:space:]')

    if [ -z "$label" ]; then
        echo "unknown"
    else
        echo "$label"
    fi
}

report_rescue_state() {
    detect_firmware_mode
    local disk_label
    disk_label=$(get_disk_label)
    echo "*** Rescue system state ***"
    echo "Firmware mode: ${FIRMWARE_MODE}"
    echo "Disk label: ${disk_label}"
    if command_exists parted; then
        echo "Disk layout:"
        parted -s /dev/sda print 2>/dev/null || true
    fi

    echo "Mount status:"
    echo "  /mnt: $(mountpoint -q /mnt && echo mounted || echo not mounted)"
    echo "  /root/windisk: $(mountpoint -q /root/windisk && echo mounted || echo not mounted)"
    echo "  /mnt/zram0: $(mountpoint -q /mnt/zram0 && echo mounted || echo not mounted)"

    echo "Rescue media files:"
    echo "  /mnt/bootmgr: $( [ -f /mnt/bootmgr ] && echo yes || echo no )"
    echo "  /mnt/sources/boot.wim: $( [ -f /mnt/sources/boot.wim ] && echo yes || echo no )"
    echo "  /mnt/sources/virtio: $( [ -d /mnt/sources/virtio ] && echo yes || echo no )"
    echo "  /mnt/boot/grub/grub.cfg: $( [ -f /mnt/boot/grub/grub.cfg ] && echo yes || echo no )"
    echo "  /mnt/boot/grub/i386-pc/core.img: $( [ -f /mnt/boot/grub/i386-pc/core.img ] && echo yes || echo no )"
    echo "  /mnt/boot/grub/i386-pc/normal.mod: $( [ -f /mnt/boot/grub/i386-pc/normal.mod ] && echo yes || echo no )"

    echo "Downloaded ISO files:"
    echo "  /mnt/zram0/windisk/Windows.iso: $( [ -f /mnt/zram0/windisk/Windows.iso ] && echo yes || echo no )"
    echo "  /mnt/zram0/windisk/VirtIO.iso: $( [ -f /mnt/zram0/windisk/VirtIO.iso ] && echo yes || echo no )"
    echo "  /root/windisk/Windows.iso: $( [ -f /root/windisk/Windows.iso ] && echo yes || echo no )"
    echo "  /root/windisk/VirtIO.iso: $( [ -f /root/windisk/VirtIO.iso ] && echo yes || echo no )"
    echo "*** End rescue state ***"
}

assess_rescue_viability() {
    echo "*** Rescue viability assessment ***"
    local rescue_ok=1
    if [ ! -b /dev/sda ]; then
        echo "ERROR: /dev/sda is not available. Cannot repair disk layout."
        rescue_ok=0
    fi
    if ! command_exists apt-get; then
        echo "WARNING: apt-get is missing. The script may not be able to install required packages."
    fi
    if [ -f /mnt/bootmgr ] && [ -f /mnt/sources/boot.wim ] && [ -d /mnt/boot/grub ]; then
        echo "INFO: Installer media and GRUB files already exist. Rescue is likely possible without re-downloading."
    else
        echo "INFO: Installer media is not complete. Rescue will proceed by downloading or extracting missing files if disk space allows."
    fi
    if [ "$rescue_ok" -eq 1 ]; then
        echo "Rescue evaluation: current system is recoverable by this script."
    else
        echo "Rescue evaluation: current system is not recoverable in this environment."
    fi
    echo "*** End rescue viability assessment ***"
}

detect_firmware_mode() {
    if [ -d /sys/firmware/efi ]; then
        FIRMWARE_MODE="uefi"
    else
        FIRMWARE_MODE="bios"
    fi
}

detect_auto_repair_flags() {
    detect_firmware_mode
    local disk_label
    disk_label=$(get_disk_label)

    if [ "$RECREATE_DISK" -eq 0 ] && [ "$FIRMWARE_MODE" = "bios" ] && [ "$disk_label" = "gpt" ] && ! has_bios_boot_partition; then
        echo "Auto-detected unsafe BIOS+GPT without bios_grub. Enabling automatic recreate-disk."
        RECREATE_DISK=1
    fi

    if mountpoint -q /mnt/zram0 2>/dev/null; then
        if [ ! -f /mnt/zram0/windisk/Windows.iso ] && [ ! -f /mnt/zram0/windisk/VirtIO.iso ]; then
            echo "Auto-detected stale zram mount with no ISO files. Resetting zram state."
            cleanup_zram
            USE_ZRAM=0
        fi
    fi
}

verify_vps_compatibility() {
    echo "*** Step: compatibility check ***"

    if [ ! -b /dev/sda ]; then
        echo "ERROR: /dev/sda is not available. This VPS does not expose the primary disk as /dev/sda."
        exit 1
    fi

    detect_firmware_mode
    echo "Detected firmware mode: ${FIRMWARE_MODE}"

    local disk_label
    disk_label=$(get_disk_label)
    echo "Disk partition table: ${disk_label:-unknown}"

    if [ "${FIRMWARE_MODE}" = "bios" ] && [ "${disk_label}" = "gpt" ] && ! has_bios_boot_partition; then
        echo "WARNING: BIOS mode with GPT disk and no bios_grub partition detected."
        echo "         GRUB installation will require blocklists, which is less reliable."
        if [ "$CHECK_ONLY" -eq 0 ]; then
            if [ "$RECREATE_DISK" -eq 0 ]; then
                echo "ERROR: Unsafe BIOS+GPT layout detected. Re-run with --recreate-disk to convert /dev/sda to MBR and rebuild the installer layout."
                exit 1
            fi
            echo "INFO: --recreate-disk requested; the script will recreate /dev/sda as MBR."
        else
            echo "         Run the installer with --recreate-disk to fix this layout before rebooting."
        fi
    fi

    if [ "${FIRMWARE_MODE}" = "uefi" ] && [ "${disk_label}" != "gpt" ]; then
        echo "WARNING: UEFI mode detected but /dev/sda is not GPT."
        echo "         This disk layout may be incompatible with a standard UEFI Windows install."
    fi

    local available_ram
    available_ram=$(get_available_ram_mb)
    echo "Available RAM: ${available_ram}MB"
    if [ "${available_ram:-0}" -lt 2048 ]; then
        echo "WARNING: VPS RAM is under 2GB. zram and ISO extraction may fail or be very slow."
    fi

    local root_space
    root_space=$(get_available_root_space_mb)
    if [ -n "${root_space}" ] && [ "${root_space}" -gt 0 ]; then
        echo "Available space on /root/windisk: ${root_space}KB"
    else
        echo "WARNING: Unable to determine available space on /root/windisk."
    fi

    if [ "${disk_label}" = "unknown" ]; then
        echo "WARNING: Unable to detect disk label type. A blank disk or missing partition table is acceptable; continuing with a fresh installer layout."
    fi

    echo "Compatibility check complete."
}

has_bios_boot_partition() {
    if ! command_exists parted; then
        return 1
    fi
    local label
    label=$(get_disk_label)
    if [ "$label" != "gpt" ]; then
        return 1
    fi
    if parted -s /dev/sda print 2>/dev/null | grep -q "bios_grub"; then
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

    if [ "$RECREATE_DISK" -eq 0 ]; then
        if mount | grep -qE '^/dev/sda1 on /mnt ' && mount | grep -qE '^/dev/sda2 on /root/windisk '; then
            echo "Existing partitions are already mounted; skipping partition recreation."
            checkpoint_set "partitions"
            return
        fi

        local disk_label
        disk_label=$(get_disk_label)
        if [ "$disk_label" = "gpt" ] && ! has_bios_boot_partition; then
            echo "WARNING: /dev/sda is GPT without a BIOS boot partition."
            echo "         This layout is unsafe for BIOS GRUB boot. The script will recreate /dev/sda as MBR automatically."
            RECREATE_DISK=1
        fi
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

    local disk_size_output
    if ! disk_size_output=$(parted /dev/sda --script print 2>/dev/null | awk '/^Disk \/dev\/sda:/ {print int($3)}'); then
        echo "ERROR: Unable to read /dev/sda size. Ensure the disk is accessible."
        exit 1
    fi
    disk_size_gb=${disk_size_output:-0}
    if [ "$disk_size_gb" -eq 0 ]; then
        echo "ERROR: Invalid disk size detected for /dev/sda."
        exit 1
    fi
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
    if [ "$(parted /dev/sda --script print 2>/dev/null | awk -F: '/^Partition Table/ {print $2}' | tr -d '[:space:]')" != "msdos" ]; then
        echo "ERROR: Failed to set MBR partition table on /dev/sda."
        exit 1
    fi
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

    if ! lsblk /dev/sda1 >/dev/null 2>&1 || ! lsblk /dev/sda2 >/dev/null 2>&1; then
        echo "ERROR: partitions were not created or formatted successfully."
        exit 1
    fi

    checkpoint_set "partitions"
}

find_existing_downloads() {
    if [ "$FORCE_DOWNLOAD" -eq 1 ]; then
        echo "--force-download requested; ignoring existing downloaded ISOs."
        return 1
    fi
    if [ -f /mnt/zram0/windisk/Windows.iso ] && [ -f /mnt/zram0/windisk/VirtIO.iso ]; then
        USE_ZRAM=1
        WINDOWS_ISO="/mnt/zram0/windisk/Windows.iso"
        VIRTIO_ISO="/mnt/zram0/windisk/VirtIO.iso"
        WINDOWS_ISO_SIZE=$(stat -c%s "$WINDOWS_ISO")
        VIRTIO_ISO_SIZE=$(stat -c%s "$VIRTIO_ISO")
        return 0
    fi

    if mountpoint -q /mnt/zram0; then
        echo "Partial or stale zram detected without both ISOs. Clearing zram state."
        cleanup_zram
    fi

    if [ -f /root/windisk/Windows.iso ] && [ -f /root/windisk/VirtIO.iso ]; then
        USE_ZRAM=0
        WINDOWS_ISO="/root/windisk/Windows.iso"
        VIRTIO_ISO="/root/windisk/VirtIO.iso"
        WINDOWS_ISO_SIZE=$(stat -c%s "$WINDOWS_ISO")
        VIRTIO_ISO_SIZE=$(stat -c%s "$VIRTIO_ISO")
        return 0
    fi

    return 1
}

skip_existing_extraction() {
    if [ "$FORCE_DOWNLOAD" -eq 1 ]; then
        echo "--force-download requested; ignoring existing installer media in /mnt."
        return 1
    fi
    if [ -f /mnt/bootmgr ] && [ -f /mnt/sources/boot.wim ]; then
        SKIP_WINDOWS_DOWNLOAD=1
        echo "Existing Windows installer files detected in /mnt. Skipping Windows URL prompt and download."
    fi
    if [ -f /mnt/bootmgr ] && [ -d /mnt/sources/virtio ] && [ -f /mnt/sources/virtio/NetKVM/2k3/amd64/netkvm.sys ]; then
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

    WINDOWS_ISO_URL="$WINDOWS_ISO_URL_ARG"
    VIRTIO_ISO_URL="$VIRTIO_ISO_URL_ARG"

    if [ "$FORCE_DOWNLOAD" -eq 1 ]; then
        echo "--force-download requested; prompting for new ISO URLs and ignoring existing /mnt installer media."
        SKIP_WINDOWS_DOWNLOAD=0
        SKIP_VIRTIO_DOWNLOAD=0
    fi

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
            if [ "$NO_PROMPT" -eq 1 ] || [ ! -t 0 ]; then
                if [ -n "$WINDOWS_ISO_URL" ]; then
                    echo "Using Windows ISO URL from CLI option: $WINDOWS_ISO_URL"
                else
                    echo "ERROR: --windows-iso-url is required in non-interactive mode."
                    exit 1
                fi
            else
                WINDOWS_ISO_URL=$(prompt_url "${WINDOWS_ISO_URL:-$DEFAULT_WINDOWS_ISO_URL}" "Enter the URL for Windows.iso: ")
            fi
            if [ -z "${WINDOWS_ISO_URL:-}" ]; then
                echo "ERROR: Windows ISO URL is required. Provide --windows-iso-url or run interactively."
                exit 1
            fi
            WINDOWS_ISO_SIZE=$(get_content_length "$WINDOWS_ISO_URL")
        else
            WINDOWS_ISO_URL=""
            WINDOWS_ISO_SIZE=0
        fi

        if [ "${SKIP_VIRTIO_DOWNLOAD:-0}" -eq 0 ]; then
            if [ "$NO_PROMPT" -eq 1 ] || [ ! -t 0 ]; then
                if [ -n "$VIRTIO_ISO_URL" ]; then
                    echo "Using VirtIO ISO URL from CLI option: $VIRTIO_ISO_URL"
                else
                    VIRTIO_ISO_URL="$DEFAULT_VIRTIO_ISO_URL"
                    echo "Using default VirtIO ISO URL: $VIRTIO_ISO_URL"
                fi
            else
                VIRTIO_ISO_URL=$(prompt_url "${VIRTIO_ISO_URL:-$DEFAULT_VIRTIO_ISO_URL}" "Enter the URL for Virtio.iso (leave blank to use default): ")
            fi
            if [ -z "${VIRTIO_ISO_URL:-}" ]; then
                echo "ERROR: VirtIO ISO URL is required. Provide --virtio-iso-url or run interactively."
                exit 1
            fi
            VIRTIO_ISO_SIZE=$(get_content_length "$VIRTIO_ISO_URL")
        else
            VIRTIO_ISO_URL=""
            VIRTIO_ISO_SIZE=0
        fi
    fi

    local default_windows_iso_size=$((8 * 1024 * 1024 * 1024))
    local default_virtio_iso_size=$((700 * 1024 * 1024))

    if [ -z "${WINDOWS_ISO_SIZE:-}" ] || [ "${WINDOWS_ISO_SIZE:-0}" -le 0 ]; then
        if [ -n "${WINDOWS_ISO_URL:-}" ]; then
            echo "WARNING: Windows ISO size unknown. Estimating ${default_windows_iso_size} bytes for zram decision."
            WINDOWS_ISO_SIZE=$default_windows_iso_size
        else
            WINDOWS_ISO_SIZE=0
        fi
    fi
    if [ -z "${VIRTIO_ISO_SIZE:-}" ] || [ "${VIRTIO_ISO_SIZE:-0}" -le 0 ]; then
        if [ -n "${VIRTIO_ISO_URL:-}" ]; then
            echo "WARNING: VirtIO ISO size unknown. Estimating ${default_virtio_iso_size} bytes for zram decision."
            VIRTIO_ISO_SIZE=$default_virtio_iso_size
        else
            VIRTIO_ISO_SIZE=0
        fi
    fi

    if [ "${WINDOWS_ISO_SIZE:-0}" -le 0 ] || [ "${VIRTIO_ISO_SIZE:-0}" -le 0 ]; then
        echo "WARNING: Unable to determine both ISO sizes. Using disk fallback instead of zram."
        USE_ZRAM=0
        TOTAL_ISO_SIZE=0
        TOTAL_ISO_SIZE_MB=0
    else
        TOTAL_ISO_SIZE=$((WINDOWS_ISO_SIZE + VIRTIO_ISO_SIZE))
        ZRAM_SIZE_MARGIN_MB=1024
        TOTAL_ISO_SIZE_MB=$((TOTAL_ISO_SIZE / 1024 / 1024 + ZRAM_SIZE_MARGIN_MB))
    fi

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

    if [ "${USE_ZRAM:-0}" -eq 0 ] && [ "${WINDOWS_ISO_SIZE:-0}" -gt 0 ] && [ "${VIRTIO_ISO_SIZE:-0}" -gt 0 ] && [ "${TOTAL_ISO_SIZE:-0}" -gt 0 ] && [ "$TOTAL_ISO_SIZE_MB" -le "$SAFE_RAM_MB" ]; then
        echo "Memory is sufficient for both ISOs; enabling zram for downloads."
        USE_ZRAM=1
    else
        if [ "${USE_ZRAM:-0}" -eq 0 ]; then
            echo "Skipping zram because total ISO size is unknown or exceeds safe RAM."
        fi
    fi

    if [ "${TOTAL_ISO_SIZE:-0}" -le 0 ]; then
        echo "Unable to determine total ISO size; disabling zram fallback."
        USE_ZRAM=0
    fi

    if [ "${USE_ZRAM:-0}" -eq 1 ] && mountpoint -q /mnt/zram0; then
        local zram_avail_kb
        zram_avail_kb=$(df --output=avail /mnt/zram0 2>/dev/null | tail -n1 | tr -d ' ')
        zram_avail_mb=$((zram_avail_kb / 1024))
        if [ "$zram_avail_mb" -lt "$TOTAL_ISO_SIZE_MB" ]; then
            echo "Existing zram does not have enough free space (${zram_avail_mb}MB) for ${TOTAL_ISO_SIZE_MB}MB. Clearing zram state."
            cleanup_zram
            USE_ZRAM=0
        fi
    fi

    if [ "${USE_ZRAM:-0}" -eq 1 ]; then
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
            echo lz4 > /sys/block/zram0/comp_algorithm || true
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
    else
        echo "Using disk fallback for ISO downloads because ISO sizes are unknown or unavailable."
    fi

    if [ "${USE_ZRAM:-0}" -eq 1 ]; then
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

    if [ "${expected:-0}" -gt 0 ] && verify_file_size "$path" "$expected"; then
        echo "$path already exists and matches expected size. Skipping download."
        return
    fi

    if [ -z "${url:-}" ]; then
        if [ -f "$path" ]; then
            echo "No expected size but file $path exists. Using existing file."
            return
        fi
        echo "ERROR: No URL provided for $path and the file is missing or incomplete."
        exit 1
    fi

    echo "Downloading $path..."
    download_file "$url" "$path"

    if [ "${expected:-0}" -gt 0 ] && ! verify_file_size "$path" "$expected"; then
        echo "ERROR: Downloaded file size does not match expected size for $path"
        exit 1
    fi
}

copy_windows_media() {
    if [ -f /mnt/bootmgr ] && [ -f /mnt/sources/boot.wim ] && [ -z "${WINDOWS_ISO:-}" ]; then
        echo "Windows installer files already present on /mnt and no Windows ISO is available. Skipping Windows ISO extraction."
        checkpoint_set "windows_extracted"
        return
    fi

    if [ -f /mnt/bootmgr ] && [ -f /mnt/sources/boot.wim ]; then
        echo "Windows installer files already exist on /mnt. Re-extracting from the provided Windows ISO to ensure the desired media is installed."
    else
        echo "Extracting Windows ISO to /mnt..."
    fi

    WINFILE_MOUNT=$(mktemp -d)
    mount -o loop "$WINDOWS_ISO" "$WINFILE_MOUNT"
    rsync -a --info=progress2 "$WINFILE_MOUNT"/ /mnt/
    umount "$WINFILE_MOUNT"
    rmdir "$WINFILE_MOUNT"

    checkpoint_set "windows_extracted"
}

copy_virtio_media() {
    if [ -d /mnt/sources/virtio ] && [ -f /mnt/sources/virtio/NetKVM/2k3/amd64/netkvm.sys ] && [ -z "${VIRTIO_ISO:-}" ]; then
        echo "VirtIO drivers already present on /mnt/sources/virtio and no VirtIO ISO is available. Skipping VirtIO ISO extraction."
        checkpoint_set "virtio_extracted"
        return
    fi

    if [ -d /mnt/sources/virtio ] && [ -f /mnt/sources/virtio/NetKVM/2k3/amd64/netkvm.sys ]; then
        echo "VirtIO drivers already exist in /mnt/sources/virtio. Re-extracting from the provided VirtIO ISO."
    else
        echo "Extracting VirtIO ISO to /mnt/sources/virtio..."
    fi

    ISO_MOUNT_DIR=$(mktemp -d)
    mount -o loop "$VIRTIO_ISO" "$ISO_MOUNT_DIR"
    mkdir -p /mnt/sources/virtio
    rsync -a --info=progress2 "$ISO_MOUNT_DIR"/ /mnt/sources/virtio/
    umount "$ISO_MOUNT_DIR"
    rmdir "$ISO_MOUNT_DIR"

    checkpoint_set "virtio_extracted"
}

write_bypass_files() {
    if [ -f /mnt/sources/bypass.reg ] && [ -f /mnt/sources/bypass.cmd ]; then
        echo "Bypass files already exist. Skipping creation."
        checkpoint_set "bypass_files"
        return
    fi
    mkdir -p /mnt/sources
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

    checkpoint_set "bypass_files"
}

patch_boot_wim() {
    if checkpoint_done "boot_wim_patched"; then
        echo "boot.wim already patched (checkpoint)."
        return
    fi
    if [ -f /mnt/sources/boot.wim.virtio_patched ]; then
        echo "boot.wim already patched with VirtIO drivers. Skipping WIM update."
        checkpoint_set "boot_wim_patched"
        return
    fi
    if [ ! -f /mnt/sources/boot.wim ]; then
        echo "ERROR: /mnt/sources/boot.wim not found."
        exit 1
    fi
    if ! command_exists wimlib-imagex; then
        echo "WARNING: wimlib-imagex not installed. Skipping boot.wim patch."
        echo "VirtIO drivers will still be copied to /mnt/sources/virtio, but boot.wim injection will not be applied."
        return
    fi
    echo "Inspecting boot.wim images..."
    wimlib-imagex info /mnt/sources/boot.wim > /tmp/bootwim_info.txt
    local image_count
    image_count=$(grep -c '^Index:' /tmp/bootwim_info.txt || true)

    if [ "$image_count" -ge 2 ]; then
        auto_image_index=2
        echo "Using boot.wim image index 2 to match upstream behavior."
    else
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
    fi
    rm -f /tmp/bootwim_info.txt

    if [ -z "$auto_image_index" ]; then
        echo "ERROR: Unable to determine boot.wim image index."
        exit 1
    fi

    echo "Selected boot.wim image index: $auto_image_index"
    echo "add /mnt/sources/virtio /virtio_drivers" > /tmp/wimcmd.txt
    wimlib-imagex update /mnt/sources/boot.wim "$auto_image_index" < /tmp/wimcmd.txt
    rm -f /tmp/wimcmd.txt
    touch /mnt/sources/boot.wim.virtio_patched

    checkpoint_set "boot_wim_patched"
}

gpt_needs_blocklists() {
    if ! command_exists parted; then
        return 1
    fi
    local label
    label=$(get_disk_label)
    if [ "$label" != "gpt" ]; then
        return 1
    fi
    if parted -s /dev/sda print 2>/dev/null | grep -q "bios_grub"; then
        return 1
    fi
    return 0
}

find_uefi_loader_path() {
    if [ -f /mnt/efi/boot/bootx64.efi ]; then
        echo "/efi/boot/bootx64.efi"
    elif [ -f /mnt/EFI/BOOT/BOOTX64.EFI ]; then
        echo "/EFI/BOOT/BOOTX64.EFI"
    elif [ -f /mnt/efi/microsoft/boot/bootmgfw.efi ]; then
        echo "/efi/microsoft/boot/bootmgfw.efi"
    else
        return 1
    fi
}

verify_grub_entry() {
    local cfg_path="/mnt/boot/grub/grub.cfg"
    if [ ! -f "$cfg_path" ]; then
        echo "ERROR: GRUB config not found at $cfg_path"
        exit 1
    fi

    local bios_entry_found=0
    if grep -q 'menuentry "windows installer (BIOS)"' "$cfg_path"; then
        bios_entry_found=1
    elif grep -qi 'menuentry "windows installer"' "$cfg_path" && grep -q -E 'chainloader /bootmgr|ntldr /bootmgr' "$cfg_path"; then
        echo "INFO: Found existing BIOS Windows installer GRUB entry. Accepting existing entry."
        bios_entry_found=1
    fi

    if [ "$bios_entry_found" -eq 0 ]; then
        echo "ERROR: BIOS GRUB entry is missing in $cfg_path"
        echo "       Expected either menuentry \"windows installer (BIOS)\" or a Windows installer entry with chainloader /bootmgr or ntldr /bootmgr."
        exit 1
    fi

    if [ ! -f /mnt/bootmgr ]; then
        echo "ERROR: /mnt/bootmgr is missing; BIOS GRUB entry cannot boot Windows installer."
        exit 1
    fi

    if [ "${FIRMWARE_MODE}" = "uefi" ]; then
        if find_uefi_loader_path >/dev/null 2>&1; then
            if ! grep -q 'menuentry "windows installer (UEFI)"' "$cfg_path"; then
                echo "ERROR: UEFI GRUB entry is missing in $cfg_path"
                exit 1
            fi
            local uefi_path
            uefi_path=$(find_uefi_loader_path)
            if [ ! -f "/mnt${uefi_path}" ]; then
                echo "ERROR: UEFI loader file /mnt${uefi_path} not found"
                exit 1
            fi
        else
            echo "ERROR: UEFI loader path is missing; cannot verify UEFI boot entry in UEFI mode"
            exit 1
        fi
    else
        echo "INFO: BIOS firmware mode detected; UEFI GRUB entry is not required."
    fi

    echo "GRUB boot entry validation passed."
}

verify_grub_installation() {
    if ! verify_grub_installation_noexit; then
        exit 1
    fi
}

verify_grub_installation_noexit() {
    local grub_dir="/mnt/boot/grub"
    local core_img="${grub_dir}/i386-pc/core.img"
    local normal_mod="${grub_dir}/i386-pc/normal.mod"

    if [ ! -d "$grub_dir" ]; then
        echo "ERROR: GRUB directory $grub_dir does not exist"
        return 1
    fi

    if [ ! -f "$core_img" ]; then
        echo "ERROR: GRUB core image missing: $core_img"
        echo "       grub-install may have failed to install the BIOS core files."
        return 1
    fi

    if [ ! -f "$normal_mod" ]; then
        echo "ERROR: GRUB normal module missing: $normal_mod"
        echo "       GRUB may not be able to execute menu entries."
        return 1
    fi

    echo "GRUB installation artifacts verified: $core_img and $normal_mod"
    return 0
}

verify_grub_probe() {
    if ! command_exists grub-probe; then
        echo "WARNING: grub-probe unavailable; skipping GRUB probe validation."
        return 0
    fi

    if ! grub-probe --target=fs /mnt >/dev/null 2>&1; then
        echo "ERROR: grub-probe could not identify the filesystem mounted on /mnt."
        echo "       Please ensure /mnt is mounted with the Windows installer partition."
        exit 1
    fi

    if ! grub-probe --target=device /mnt >/dev/null 2>&1; then
        echo "ERROR: grub-probe could not identify the block device for /mnt."
        exit 1
    fi

    echo "GRUB probe validation passed."
}

mount_existing_partitions() {
    mkdir -p /mnt /root/windisk

    if ! mountpoint -q /mnt && [ -b /dev/sda1 ]; then
        echo "Mounting existing /dev/sda1 at /mnt for validation..."
        mount /dev/sda1 /mnt 2>/dev/null || true
    fi
    if ! mountpoint -q /root/windisk && [ -b /dev/sda2 ]; then
        echo "Mounting existing /dev/sda2 at /root/windisk for validation..."
        mount /dev/sda2 /root/windisk 2>/dev/null || true
    fi
}

run_preflight_checks() {
    echo "*** Step: preflight check-only validation ***"
    verify_vps_compatibility
    detect_auto_repair_flags
    ensure_toolchain
    verify_toolchain

    mount_existing_partitions
    report_rescue_state
    assess_rescue_viability

    if mountpoint -q /mnt; then
        echo "/mnt is mounted"
    else
        echo "/mnt is not mounted"
    fi
    if mountpoint -q /root/windisk; then
        echo "/root/windisk is mounted"
    else
        echo "/root/windisk is not mounted"
    fi

    if [ -f /mnt/boot/grub/grub.cfg ]; then
        echo "Found existing GRUB config at /mnt/boot/grub/grub.cfg"
        verify_grub_config
        verify_grub_entry
    else
        echo "No GRUB config found at /mnt/boot/grub/grub.cfg"
    fi

    verify_installer_files
    verify_disk_layout
    manual_rescue_verification

    if [ -f /mnt/bootmgr ]; then
        echo "Found /mnt/bootmgr"
    else
        echo "Missing /mnt/bootmgr"
    fi
    if [ -f /mnt/sources/boot.wim ]; then
        echo "Found /mnt/sources/boot.wim"
    else
        echo "Missing /mnt/sources/boot.wim"
    fi
    if [ -d /mnt/sources/virtio ]; then
        echo "Found /mnt/sources/virtio"
    else
        echo "Missing /mnt/sources/virtio"
    fi

    echo "Preflight check-only validation complete."
}

write_grub_config() {
    detect_firmware_mode
    mkdir -p /mnt/boot/grub

    if [ ! -f /mnt/bootmgr ]; then
        echo "WARNING: /mnt/bootmgr not found. GRUB boot entry may fail."
    fi

    local uefi_loader_path=""
    if find_uefi_loader_path >/dev/null 2>&1; then
        uefi_loader_path=$(find_uefi_loader_path)
    fi

    cat > /mnt/boot/grub/grub.cfg <<EOF
set timeout=5
set default=0

EOF

    if [ "${FIRMWARE_MODE}" = "uefi" ] && [ -n "${uefi_loader_path}" ]; then
        cat >> /mnt/boot/grub/grub.cfg <<EOF
menuentry "windows installer (UEFI)" {
    insmod ntfs
    search --no-floppy --set=root --file=${uefi_loader_path}
    chainloader ${uefi_loader_path}
    boot
}

EOF
    fi

    cat >> /mnt/boot/grub/grub.cfg <<EOF
menuentry "windows installer (BIOS)" {
    insmod ntfs
    search --no-floppy --set=root --file=/bootmgr
    ntldr /bootmgr
    boot
}
EOF

    if [ -n "${uefi_loader_path}" ] && [ "${FIRMWARE_MODE}" != "uefi" ]; then
        cat >> /mnt/boot/grub/grub.cfg <<EOF

menuentry "windows installer (UEFI)" {
    insmod ntfs
    search --no-floppy --set=root --file=${uefi_loader_path}
    chainloader ${uefi_loader_path}
    boot
}
EOF
    fi
}

install_grub_if_needed() {
    mount_existing_partitions

    if ! mountpoint -q /mnt; then
        echo "ERROR: /mnt is not mounted, cannot install GRUB."
        exit 1
    fi

    if ! command_exists grub-install; then
        echo "ERROR: grub-install is missing. Ensure grub-pc is installed before running this script."
        exit 1
    fi

    if checkpoint_done "grub_installed"; then
        echo "GRUB already installed (checkpoint). Verifying installation."
        if verify_grub_installation_noexit && verify_grub_probe >/dev/null 2>&1; then
            echo "Existing GRUB installation appears valid. Updating GRUB config."
            write_grub_config
            verify_grub_entry
            return
        fi
        echo "Existing GRUB installation is not valid. Reinstalling GRUB."
    fi

    echo "Installing or updating GRUB on /dev/sda..."
    mkdir -p /mnt/boot/grub

    local grub_args=(--root-directory=/mnt)
    if [ -n "${GRUB_INSTALL_TARGET}" ]; then
        grub_args+=(--target="${GRUB_INSTALL_TARGET}")
    fi

    if gpt_needs_blocklists; then
        echo "GPT without BIOS boot partition detected. Installing GRUB with --force blocklists."
        grub-install "${grub_args[@]}" --force /dev/sda
    elif ! grub-install "${grub_args[@]}" /dev/sda; then
        echo "grub-install failed. Retrying with --force to allow blocklists on GPT."
        grub-install "${grub_args[@]}" --force /dev/sda
    fi

    verify_grub_installation
    verify_grub_probe
    write_grub_config
    verify_grub_entry
    checkpoint_set "grub_installed"
}

main() {
    verify_vps_compatibility
    detect_auto_repair_flags

    if [ "$CHECK_ONLY" -eq 1 ]; then
        run_preflight_checks
        exit 0
    fi

    echo "*** Step: ensure_toolchain ***"
    ensure_toolchain

    echo "*** Step: inspect rescue state ***"
    mount_existing_partitions
    report_rescue_state

    echo "*** Step: partitions & mounts ***"
    setup_partitions_and_mounts

    echo "*** Step: download environment ***"
    setup_download_environment

    echo "*** Step: Windows ISO download ***"
    if [ -n "${WINDOWS_ISO_URL:-}" ] || [ -n "${WINDOWS_ISO:-}" ]; then
        download_if_needed "${WINDOWS_ISO_URL:-}" "${WINDOWS_ISO:-/root/windisk/Windows.iso}" "${WINDOWS_ISO_SIZE:-0}"
    else
        echo "Skipping Windows ISO download because installer media already exists."
    fi

    echo "*** Step: VirtIO ISO download ***"
    if [ -n "${VIRTIO_ISO_URL:-}" ] || [ -n "${VIRTIO_ISO:-}" ]; then
        download_if_needed "${VIRTIO_ISO_URL:-}" "${VIRTIO_ISO:-/root/windisk/VirtIO.iso}" "${VIRTIO_ISO_SIZE:-0}"
    else
        echo "Skipping VirtIO ISO download because driver media already exists."
    fi

    echo "*** Step: copy Windows media ***"
    copy_windows_media

    echo "*** Step: copy VirtIO media ***"
    copy_virtio_media

    echo "*** Step: write bypass files ***"
    write_bypass_files

    echo "*** Step: patch boot.wim ***"
    patch_boot_wim

    echo "*** Step: install GRUB ***"
    install_grub_if_needed

    echo "*** Step: final rescue verification ***"
    manual_rescue_verification || true

    echo "*** Final checks ***"
    ls -lh /mnt/bootmgr /mnt/sources/boot.wim || true
    ls -lh /mnt/sources/virtio || true
    echo "Resume script completed. You can reboot manually when ready."
}

main "$@"