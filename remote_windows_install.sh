#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/root/.wininstall-state"
mkdir -p "$STATE_DIR"

TARGET_DISK="/dev/sda"
PART1="${TARGET_DISK}1"
PART2="${TARGET_DISK}2"

MNT_INSTALL="/mnt"
MNT_STORAGE="/root/windisk"

GRUB_INSTALL_TARGET="i386-pc"
DEFAULT_VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
DEFAULT_WINDOWS_EDITION="Windows 11 Pro"
DEFAULT_WINDOWS_GENERIC_KEY="VK7JG-NPHTM-C97JM-9MPGT-3V66T"
DEFAULT_WINDOWS_LOCALE="en-US"
DEFAULT_WINDOWS_TIMEZONE="UTC"
DEFAULT_WINDOWS_USERNAME="Administrator"
DEFAULT_WINDOWS_PASSWORD="ChangeMeNow!123"

RECREATE_DISK=0
CHECK_ONLY=0
FORCE_DOWNLOAD=0
NO_PROMPT=0
UNATTENDED=1
USE_ZRAM=0

WINDOWS_ISO_URL=""
VIRTIO_ISO_URL=""
UNATTENDED_CMD=""
WINDOWS_EDITION="$DEFAULT_WINDOWS_EDITION"
WINDOWS_GENERIC_KEY="$DEFAULT_WINDOWS_GENERIC_KEY"
WINDOWS_LOCALE="$DEFAULT_WINDOWS_LOCALE"
WINDOWS_TIMEZONE="$DEFAULT_WINDOWS_TIMEZONE"
WINDOWS_USERNAME="$DEFAULT_WINDOWS_USERNAME"
WINDOWS_PASSWORD="$DEFAULT_WINDOWS_PASSWORD"

WINDOWS_ISO=""
VIRTIO_ISO=""

checkpoint_done() { [ -f "$STATE_DIR/$1" ]; }
checkpoint_set() { touch "$STATE_DIR/$1"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

dump_checkpoint_state() {
    echo "=== checkpoint state ==="
    for cp in \
        partitions \
        downloads_completed \
        windows_extracted \
        virtio_extracted \
        install_image_inspected \
        autounattend_written \
        ei_cfg_written \
        bypass_ready \
        boot_wim_patched \
        grub_cfg \
        grub_installed \
        final_verified
    do
        if checkpoint_done "$cp"; then
            echo "$cp: set"
        else
            echo "$cp: missing"
        fi
    done
}

fail() {
    echo "ERROR: $*"
    dump_checkpoint_state || true
    exit 1
}

require_root() {
    [ "$(id -u)" -eq 0 ] || fail "Run as root."
}

package_for_command() {
    case "$1" in
        mkfs.ntfs) echo ntfs-3g ;;
        grub-install|grub-probe) echo grub-pc ;;
        curl) echo curl ;;
        rsync) echo rsync ;;
        pgrep) echo procps ;;
        fuser) echo psmisc ;;
        awk) echo gawk ;;
        grep) echo grep ;;
        sed) echo sed ;;
        find) echo findutils ;;
        mount|mountpoint|blockdev|partx|fdisk|lsblk|wipefs|swapon|swapoff) echo util-linux ;;
        partprobe|parted) echo parted ;;
        wimlib-imagex) echo wimtools ;;
        sort|mkdir|rm|touch|cat|mktemp|stat|df|head|tail|tr|cut|sha256sum|dd) echo coreutils ;;
        lsof) echo lsof ;;
        wget) echo wget ;;
        aria2c) echo aria2 ;;
        iconv) echo libc-bin ;;
        xmllint) echo libxml2-utils ;;
        modprobe) echo kmod ;;
        mkfs.ext4) echo e2fsprogs ;;
        free) echo procps ;;
        *) echo "" ;;
    esac
}

install_missing_dependencies() {
    if ! command_exists apt-get; then
        return 1
    fi

    declare -A seen_pkgs=()
    local missing_pkgs=()
    local cmd pkg

    for cmd in "$@"; do
        pkg=$(package_for_command "$cmd")
        if [ -n "$pkg" ] && [ -z "${seen_pkgs[$pkg]:-}" ]; then
            seen_pkgs[$pkg]=1
            missing_pkgs+=("$pkg")
        fi
    done

    [ "${#missing_pkgs[@]}" -eq 0 ] && return 0

    echo "Installing missing dependency packages: ${missing_pkgs[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_pkgs[@]}"
}

ensure_toolchain() {
    local required=(
        parted partprobe mkfs.ntfs mount umount rsync lsof sort mountpoint pgrep fuser mkdir rm touch cat mktemp
        grub-install grub-probe grep awk sed find wimlib-imagex iconv lsblk stat df head tail tr cut wipefs
        sha256sum xmllint modprobe mkfs.ext4 free swapon swapoff dd
    )
    local missing=()
    local cmd

    for cmd in "${required[@]}"; do
        command_exists "$cmd" || missing+=("$cmd")
    done

    if ! command_exists aria2c && ! command_exists curl && ! command_exists wget; then
        missing+=(aria2c curl wget)
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Missing required commands: ${missing[*]}"
        install_missing_dependencies "${missing[@]}" || true
    fi

    missing=()
    for cmd in "${required[@]}"; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if ! command_exists aria2c && ! command_exists curl && ! command_exists wget; then
        missing+=(aria2c curl wget)
    fi

    [ "${#missing[@]}" -eq 0 ] || fail "Missing required commands after install attempt: ${missing[*]}"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --recreate-disk) RECREATE_DISK=1 ;;
            --check-only) CHECK_ONLY=1 ;;
            --force-download) FORCE_DOWNLOAD=1 ;;
            --no-prompt) NO_PROMPT=1 ;;
            --unattended) UNATTENDED=1 ;;
            --windows-iso-url=*) WINDOWS_ISO_URL="${1#*=}" ;;
            --virtio-iso-url=*) VIRTIO_ISO_URL="${1#*=}" ;;
            --windows-edition=*) WINDOWS_EDITION="${1#*=}" ;;
            --windows-generic-key=*) WINDOWS_GENERIC_KEY="${1#*=}" ;;
            --windows-locale=*) WINDOWS_LOCALE="${1#*=}" ;;
            --windows-timezone=*) WINDOWS_TIMEZONE="${1#*=}" ;;
            --windows-username=*) WINDOWS_USERNAME="${1#*=}" ;;
            --windows-password=*) WINDOWS_PASSWORD="${1#*=}" ;;
            --unattended-cmd=*) UNATTENDED_CMD="${1#*=}" ;;
            --windows-iso-url) shift; WINDOWS_ISO_URL="${1:-}" ;;
            --virtio-iso-url) shift; VIRTIO_ISO_URL="${1:-}" ;;
            --windows-edition) shift; WINDOWS_EDITION="${1:-}" ;;
            --windows-generic-key) shift; WINDOWS_GENERIC_KEY="${1:-}" ;;
            --windows-locale) shift; WINDOWS_LOCALE="${1:-}" ;;
            --windows-timezone) shift; WINDOWS_TIMEZONE="${1:-}" ;;
            --windows-username) shift; WINDOWS_USERNAME="${1:-}" ;;
            --windows-password) shift; WINDOWS_PASSWORD="${1:-}" ;;
            --unattended-cmd) shift; UNATTENDED_CMD="${1:-}" ;;
            *) fail "Unknown argument: $1" ;;
        esac
        shift
    done
}

prompt_value() {
    local current="$1"
    local prompt="$2"
    if [ -n "$current" ]; then
        echo "$current"
        return
    fi
    if [ "$NO_PROMPT" -eq 1 ] || [ ! -t 0 ]; then
        echo ""
        return
    fi
    local v
    read -r -p "$prompt" v
    echo "$v"
}

refresh_partition_table() {
    echo "Refreshing kernel partition table for $TARGET_DISK..."
    partprobe "$TARGET_DISK" || true
    blockdev --rereadpt "$TARGET_DISK" || true
    partx -u "$TARGET_DISK" || true
    command_exists udevadm && udevadm settle --timeout=10 || true
    sleep 3
}

cleanup_mount() {
    local p="$1"
    if mountpoint -q "$p"; then
        umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null || true
    fi
}

ensure_mount_dir() {
    local p="$1"
    mkdir -p "$p" 2>/dev/null || true
}

kill_block_device_holders() {
    local dev="$1"
    local pids=""
    if command_exists lsof; then
        pids="$(lsof "$dev" "${dev}1" "${dev}2" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | tr '\n' ' ' || true)"
        if [ -n "$pids" ]; then
            echo "Killing processes holding $dev: $pids"
            kill -TERM $pids 2>/dev/null || true
            sleep 1
        fi
    fi
}

mount_existing_partitions() {
    ensure_mount_dir "$MNT_INSTALL"
    ensure_mount_dir "$MNT_STORAGE"
    [ -b "$PART2" ] && ! mountpoint -q "$MNT_INSTALL" && mount "$PART2" "$MNT_INSTALL" 2>/dev/null || true
    [ -b "$PART1" ] && ! mountpoint -q "$MNT_STORAGE" && mount "$PART1" "$MNT_STORAGE" 2>/dev/null || true
}

detect_firmware_mode() {
    if [ -d /sys/firmware/efi ]; then
        FIRMWARE_MODE="uefi"
    else
        FIRMWARE_MODE="bios"
    fi
}

get_disk_label() {
    parted "$TARGET_DISK" --script print 2>/dev/null | awk -F: '/^Partition Table/ {gsub(/[[:space:]]/, "", $2); print $2}'
}

verify_vps_compatibility() {
    [ -b "$TARGET_DISK" ] || fail "$TARGET_DISK not found."
    detect_firmware_mode
    echo "Detected firmware mode: $FIRMWARE_MODE"
    echo "Detected disk label: $(get_disk_label || echo unknown)"
    [ "$FIRMWARE_MODE" = "bios" ] || echo "WARNING: Script is optimized for BIOS rescue boot."
}

delete_all_partitions() {
    echo "Deleting existing partitions on $TARGET_DISK ..."
    parted "$TARGET_DISK" --script -- rm 1 || true
    parted "$TARGET_DISK" --script -- rm 2 || true
    parted "$TARGET_DISK" --script -- rm 3 || true
    parted "$TARGET_DISK" --script -- rm 4 || true
    wipefs -a "$TARGET_DISK" || true
}

recreate_partitions() {
    echo "Recreating partitions on $TARGET_DISK ..."
    cleanup_mount "$MNT_INSTALL"
    cleanup_mount "$MNT_STORAGE"
    kill_block_device_holders "$TARGET_DISK"
    swapoff -a 2>/dev/null || true
    delete_all_partitions
    refresh_partition_table

    parted "$TARGET_DISK" --script -- mklabel msdos
    parted "$TARGET_DISK" --script -- mkpart primary ntfs 1MiB 50%
    parted "$TARGET_DISK" --script -- mkpart primary ntfs 50% 100%
    parted "$TARGET_DISK" --script -- set 1 boot off
    parted "$TARGET_DISK" --script -- set 2 boot on
    refresh_partition_table

    [ -b "$PART1" ] || fail "$PART1 was not created"
    [ -b "$PART2" ] || fail "$PART2 was not created"

    mkfs.ntfs -f "$PART1"
    mkfs.ntfs -f "$PART2"

    ensure_mount_dir "$MNT_INSTALL"
    ensure_mount_dir "$MNT_STORAGE"
    mount "$PART2" "$MNT_INSTALL"
    mount "$PART1" "$MNT_STORAGE"

    checkpoint_set partitions
}

ensure_partitions_ready() {
    mount_existing_partitions
    if [ "$RECREATE_DISK" -eq 1 ] || ! mountpoint -q "$MNT_INSTALL" || ! mountpoint -q "$MNT_STORAGE"; then
        recreate_partitions
    fi
}

verify_partition_layout() {
    local part_info
    part_info="$(parted -s "$TARGET_DISK" unit MiB print || true)"
    echo "$part_info" | grep -q "Partition Table: msdos" || fail "Partition table is not msdos/MBR"
    echo "$part_info" | grep -Eq "^ 1" || fail "Partition 1 missing"
    echo "$part_info" | grep -Eq "^ 2" || fail "Partition 2 missing"

    lsblk -no FSTYPE "$PART1" | grep -qi "ntfs" || fail "$PART1 is not NTFS"
    lsblk -no FSTYPE "$PART2" | grep -qi "ntfs" || fail "$PART2 is not NTFS"

    mountpoint -q "$MNT_INSTALL" || fail "$MNT_INSTALL is not mounted"
    mountpoint -q "$MNT_STORAGE" || fail "$MNT_STORAGE is not mounted"
}

get_content_length() {
    local url="$1"
    local size=""
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    if command_exists curl; then
        size=$(curl -fsSLI -A "$ua" --compressed --max-redirs 10 "$url" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1 || true)
        [ -n "$size" ] && { echo "$size"; return 0; }

        size=$(curl -fsSL -A "$ua" --compressed --max-redirs 10 -r 0-0 -D - -o /dev/null "$url" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1 || true)
        [ -n "$size" ] && { echo "$size"; return 0; }
    fi

    if command_exists wget; then
        size=$(wget --spider --server-response --max-redirect=20 --header="User-Agent: $ua" "$url" 2>&1 | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1 || true)
        [ -n "$size" ] && { echo "$size"; return 0; }
    fi

    echo ""
}

setup_zram() {
    local size_mb="$1"
    local dev="/dev/zram0"

    modprobe zram || return 1
    [ -e /sys/block/zram0/disksize ] || return 1

    swapoff "$dev" 2>/dev/null || true
    echo 1 > /sys/block/zram0/reset || true
    echo lz4 > /sys/block/zram0/comp_algorithm || true
    echo "${size_mb}M" > /sys/block/zram0/disksize

    mkfs.ext4 -F "$dev" >/dev/null 2>&1 || return 1
    mkdir -p /mnt/zram0
    mount "$dev" /mnt/zram0 || return 1
    return 0
}

cleanup_zram() {
    cleanup_mount /mnt/zram0
    if [ -e /sys/block/zram0/reset ]; then
        echo 1 > /sys/block/zram0/reset || true
    fi
}

finalize_zram_downloads() {
    [ -d /mnt/zram0/windisk ] || return 1
    mkdir -p "$MNT_STORAGE"
    mountpoint -q "$MNT_STORAGE" || return 1

    rsync -a --info=progress2 /mnt/zram0/windisk/ "$MNT_STORAGE/" || return 1

    WINDOWS_ISO="$MNT_STORAGE/Windows.iso"
    VIRTIO_ISO="$MNT_STORAGE/VirtIO.iso"

    [ -f "$WINDOWS_ISO" ] || return 1
    [ -f "$VIRTIO_ISO" ] || return 1
    return 0
}

choose_download_dir() {
    if mountpoint -q "$MNT_STORAGE" 2>/dev/null; then
        echo "$MNT_STORAGE"
    else
        echo "/tmp"
    fi
}

download_file() {
    local url="$1"
    local output="$2"

    if [ -f "$output" ] && [ "$FORCE_DOWNLOAD" -eq 0 ]; then
        local existing_size
        existing_size=$(stat -c%s "$output" 2>/dev/null || echo 0)
        if [ "$existing_size" -gt $((10 * 1024 * 1024)) ]; then
            echo "Using existing file: $output"
            return
        fi
        rm -f "$output"
    fi

    echo "Downloading $(basename "$output") ..."
    if command_exists aria2c; then
        aria2c --max-connection-per-server=8 --split=8 --min-split-size=1M \
            --timeout=60 --retry-wait=5 --max-tries=5 --continue=true \
            -o "$(basename "$output")" -d "$(dirname "$output")" "$url"
    elif command_exists curl; then
        curl -fL --retry 5 --retry-delay 5 --continue-at - -o "$output" "$url"
    else
        wget -O "$output" "$url"
    fi

    [ -s "$output" ] || fail "Downloaded file is empty: $output"
}

copy_windows_media() {
    local iso="$1"
    local loop_dir
    loop_dir="$(mktemp -d)"
    trap 'mountpoint -q "'"$loop_dir"'" && umount "'"$loop_dir"'" || true; rmdir "'"$loop_dir"'" 2>/dev/null || true' RETURN

    mount -o loop "$iso" "$loop_dir"
    echo "STAGE: copying Windows ISO contents from $loop_dir to $MNT_INSTALL..."
    rsync -a --info=progress2 --human-readable --stats "$loop_dir"/ "$MNT_INSTALL"/

    [ -f "$MNT_INSTALL/bootmgr" ] || fail "Windows media copy failed: bootmgr missing"
    [ -f "$MNT_INSTALL/sources/boot.wim" ] || fail "Windows media copy failed: boot.wim missing"
    [ -f "$MNT_INSTALL/setup.exe" ] || echo "WARNING: setup.exe missing from copied media"
    [ -f "$MNT_INSTALL/sources/install.wim" ] || [ -f "$MNT_INSTALL/sources/install.esd" ] || fail "install.wim/install.esd missing"

    checkpoint_set windows_extracted
    trap - RETURN
}

copy_virtio_media() {
    local iso="$1"
    local loop_dir
    loop_dir="$(mktemp -d)"
    trap 'mountpoint -q "'"$loop_dir"'" && umount "'"$loop_dir"'" || true; rmdir "'"$loop_dir"'" 2>/dev/null || true' RETURN

    mkdir -p "$MNT_INSTALL/sources/virtio"
    mount -o loop "$iso" "$loop_dir"
    echo "STAGE: copying VirtIO contents from $loop_dir to $MNT_INSTALL/sources/virtio..."
    rsync -a --info=progress2 --human-readable --stats "$loop_dir"/ "$MNT_INSTALL/sources/virtio"/

    find "$MNT_INSTALL/sources/virtio" -type f -print -quit >/dev/null || fail "VirtIO copy failed"
    checkpoint_set virtio_extracted
    trap - RETURN
}

verify_virtio_layout() {
    local base="$MNT_INSTALL/sources/virtio"
    [ -d "$base" ] || fail "VirtIO directory missing"
    [ -f "$base/vioscsi/w11/amd64/vioscsi.inf" ] || [ -f "$base/amd64/w11/vioscsi.inf" ] || fail "Windows 11 VirtIO SCSI driver not found"
    [ -f "$base/NetKVM/w11/amd64/netkvm.inf" ] || [ -f "$base/NetKVM/w11/amd64/netkvm.sys" ] || echo "WARNING: NetKVM Windows 11 driver not found"
}

xml_escape() {
    sed -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e "s/'/\&apos;/g" \
        -e 's/"/\&quot;/g'
}

inspect_install_image() {
    local install_src=""
    [ -f "$MNT_INSTALL/sources/install.wim" ] && install_src="$MNT_INSTALL/sources/install.wim"
    [ -z "$install_src" ] && [ -f "$MNT_INSTALL/sources/install.esd" ] && install_src="$MNT_INSTALL/sources/install.esd"
    [ -n "$install_src" ] || fail "No install.wim or install.esd found"

    wimlib-imagex info "$install_src" > "$STATE_DIR/install-image-info.txt"
    grep -Fq "$WINDOWS_EDITION" "$STATE_DIR/install-image-info.txt" || {
        echo "Available image names:"
        grep '^Name:' "$STATE_DIR/install-image-info.txt" || true
        fail "Requested edition '$WINDOWS_EDITION' not found in install image"
    }
    checkpoint_set install_image_inspected
}

write_ei_cfg() {
    mkdir -p "$MNT_INSTALL/sources"
    cat > "$MNT_INSTALL/sources/ei.cfg" <<EOF
[EditionID]
Professional
[Channel]
Retail
[VL]
0
EOF
    checkpoint_set ei_cfg_written
}

write_bypass_script() {
    local oem_dir="$MNT_INSTALL/sources/\$OEM\$/\$\$/Setup/Scripts"
    mkdir -p "$oem_dir"

    cat > "$oem_dir/SetupComplete.cmd" <<'EOF'
@echo off
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f
exit /b 0
EOF

    cat > "$MNT_INSTALL/sources/bypass.cmd" <<'EOF'
@echo off
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f
reg add "HKLM\Software\Microsoft\Windows\CurrentVersion\OOBE" /v HideOnlineAccountScreens /t REG_DWORD /d 1 /f
exit /b 0
EOF

    [ -f "$MNT_INSTALL/sources/bypass.cmd" ] || fail "Failed to write bypass.cmd"
    [ -f "$oem_dir/SetupComplete.cmd" ] || fail "Failed to write SetupComplete.cmd"
    checkpoint_set bypass_ready
}

write_autounattend_xml() {
    local output_path="$MNT_INSTALL/Autounattend.xml"
    local esc_user esc_pass esc_key esc_locale esc_tz esc_edition

    esc_user=$(printf '%s' "$WINDOWS_USERNAME" | xml_escape)
    esc_pass=$(printf '%s' "$WINDOWS_PASSWORD" | xml_escape)
    esc_key=$(printf '%s' "$WINDOWS_GENERIC_KEY" | xml_escape)
    esc_locale=$(printf '%s' "$WINDOWS_LOCALE" | xml_escape)
    esc_tz=$(printf '%s' "$WINDOWS_TIMEZONE" | xml_escape)
    esc_edition=$(printf '%s' "$WINDOWS_EDITION" | xml_escape)

    cat > "$output_path" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>$esc_locale</UILanguage>
      </SetupUILanguage>
      <InputLocale>$esc_locale</InputLocale>
      <SystemLocale>$esc_locale</SystemLocale>
      <UILanguage>$esc_locale</UILanguage>
      <UserLocale>$esc_locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>$esc_user</FullName>
        <Organization>Contabo</Organization>
        <ProductKey>
          <Key>$esc_key</Key>
          <WillShowUI>Never</WillShowUI>
        </ProductKey>
      </UserData>
      <DiskConfiguration>
        <Disk>
          <DiskID>0</DiskID>
          <WillWipeDisk>false</WillWipeDisk>
          <ModifyPartitions>
            <ModifyPartition>
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>Windows</Label>
              <Format>NTFS</Format>
              <Type>Primary</Type>
              <Active>true</Active>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>1</PartitionID>
          </InstallTo>
          <InstallToAvailablePartition>false</InstallToAvailablePartition>
          <WillShowUI>OnError</WillShowUI>
          <InstallFrom>
            <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <Key>/IMAGE/NAME</Key>
              <Value>$esc_edition</Value>
            </MetaData>
          </InstallFrom>
        </OSImage>
      </ImageInstall>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>*</ComputerName>
      <TimeZone>$esc_tz</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$esc_locale</InputLocale>
      <SystemLocale>$esc_locale</SystemLocale>
      <UILanguage>$esc_locale</UILanguage>
      <UserLocale>$esc_locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$esc_user</Username>
        <Password>
          <Value>$esc_pass</Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>false</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <RegisteredOwner>$esc_user</RegisteredOwner>
      <RegisteredOrganization>Contabo</RegisteredOrganization>
      <TimeZone>$esc_tz</TimeZone>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Name>$esc_user</Name>
            <DisplayName>$esc_user</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>$esc_pass</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
</unattend>
EOF

    [ -f "$output_path" ] || fail "Autounattend.xml was not created"
    xmllint --noout "$output_path" || fail "Autounattend.xml is not valid XML"
    grep -q "<DiskID>0</DiskID>" "$output_path" || fail "Autounattend.xml missing DiskID 0"
    grep -q "<PartitionID>1</PartitionID>" "$output_path" || fail "Autounattend.xml missing PartitionID 1"
    grep -q "<InstallToAvailablePartition>false</InstallToAvailablePartition>" "$output_path" || fail "Autounattend.xml missing fixed install target"
    grep -q "<HideOnlineAccountScreens>true</HideOnlineAccountScreens>" "$output_path" || fail "Autounattend.xml missing OOBE suppression"
    checkpoint_set autounattend_written
}

create_bypass_cmd() {
    local output_path="$1"
    cat > "$output_path" <<'EOF'
@echo off
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f
reg add "HKLM\Software\Microsoft\Windows\CurrentVersion\OOBE" /v HideOnlineAccountScreens /t REG_DWORD /d 1 /f
exit /b 0
EOF
}

create_unattended_startnet_cmd() {
    local output_path="$1"

    if [ -n "$UNATTENDED_CMD" ]; then
        {
            echo "@echo off"
            echo "wpeinit"
            echo "$UNATTENDED_CMD"
        } > "$output_path"
        return
    fi

    cat > "$output_path" <<'EOF'
@echo off
wpeinit
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist %%D:\virtio\vioscsi\w11\amd64\vioscsi.inf (
        drvload %%D:\virtio\vioscsi\w11\amd64\vioscsi.inf
        goto :driver_done
    )
    if exist %%D:\virtio\viostor\w11\amd64\viostor.inf (
        drvload %%D:\virtio\viostor\w11\amd64\viostor.inf
        goto :driver_done
    )
    if exist %%D:\virtio\amd64\w11\vioscsi.inf (
        drvload %%D:\virtio\amd64\w11\vioscsi.inf
        goto :driver_done
    )
)
:driver_done
if exist %SystemRoot%\System32\bypass.cmd (
    call %SystemRoot%\System32\bypass.cmd
)
EOF
}

patch_boot_wim() {
    [ -f "$MNT_INSTALL/sources/boot.wim" ] || fail "boot.wim not found"
    create_bypass_cmd /tmp/bypass.cmd

    local image_count auto_image_index
    wimlib-imagex info "$MNT_INSTALL/sources/boot.wim" > /tmp/bootwim_info.txt
    image_count=$(grep -c '^Index:' /tmp/bootwim_info.txt || true)
    if [ "$image_count" -ge 2 ]; then
        auto_image_index=2
    else
        auto_image_index=$(awk '
            BEGIN { first_idx=""; fallback_idx=""; found=0 }
            /^Index:/ { idx=$2; if (first_idx == "") first_idx = idx }
            /^Name:/ {
                name = substr($0, index($0, $2))
                lname = tolower(name)
                if (lname ~ /windows setup/ || lname ~ /microsoft windows setup/) {
                    print idx
                    found=1
                    exit
                }
                if (lname ~ /windows pe/ && fallback_idx == "") fallback_idx = idx
            }
            END {
                if (found) exit
                if (fallback_idx != "") print fallback_idx
                else if (first_idx != "") print first_idx
            }
        ' /tmp/bootwim_info.txt)
    fi
    rm -f /tmp/bootwim_info.txt

    [ -n "$auto_image_index" ] || fail "Could not determine boot.wim image index"

    cat > /tmp/wimcmd.txt <<EOF
add $MNT_INSTALL/sources/virtio /virtio
add /tmp/bypass.cmd /Windows/System32/bypass.cmd
EOF
    wimlib-imagex update "$MNT_INSTALL/sources/boot.wim" "$auto_image_index" < /tmp/wimcmd.txt
    rm -f /tmp/wimcmd.txt

    if [ "$UNATTENDED" -eq 1 ]; then
        create_unattended_startnet_cmd /tmp/startnet.cmd
        echo "add /tmp/startnet.cmd /Windows/System32/startnet.cmd" > /tmp/wimcmd.txt
        wimlib-imagex update "$MNT_INSTALL/sources/boot.wim" "$auto_image_index" < /tmp/wimcmd.txt
        rm -f /tmp/wimcmd.txt /tmp/startnet.cmd
    fi

    touch "$MNT_INSTALL/sources/boot.wim.virtio_patched"
    checkpoint_set boot_wim_patched
}

write_grub_config() {
    mkdir -p "$MNT_INSTALL/boot/grub"
    cat > "$MNT_INSTALL/boot/grub/grub.cfg" <<'EOF'
set timeout=10
set default=0

menuentry "Windows Installer (BIOS) - boot sector" {
    insmod part_msdos
    insmod ntfs
    set root=(hd0,msdos2)
    chainloader +1
    boot
}

menuentry "Windows Installer (BIOS) - bootmgr direct" {
    insmod part_msdos
    insmod ntfs
    set root=(hd0,msdos2)
    chainloader /bootmgr
    boot
}

menuentry "Windows Installer (BIOS) - bootmgr search" {
    insmod part_msdos
    insmod ntfs
    search --no-floppy --set=root --file /bootmgr
    chainloader /bootmgr
    boot
}

menuentry "Windows Installer (BIOS) - ntldr fallback" {
    insmod part_msdos
    insmod ntfs
    insmod ntldr
    set root=(hd0,msdos2)
    ntldr /bootmgr
}

menuentry "Windows 11 (installed) - boot sector" {
    insmod part_msdos
    insmod ntfs
    set root=(hd0,msdos1)
    makeactive
    chainloader +1
    boot
}

menuentry "Windows 11 (installed) - bootmgr direct" {
    insmod part_msdos
    insmod ntfs
    set root=(hd0,msdos1)
    makeactive
    chainloader /bootmgr
    boot
}

menuentry "Windows 11 (installed) - bootmgr search" {
    insmod part_msdos
    insmod ntfs
    search --no-floppy --set=root --file /bootmgr
    makeactive
    chainloader /bootmgr
    boot
}

menuentry "Windows 11 (installed) - ntldr fallback" {
    insmod part_msdos
    insmod ntfs
    insmod ntldr
    set root=(hd0,msdos1)
    makeactive
    ntldr /bootmgr
}
EOF
    grep -q 'chainloader +1' "$MNT_INSTALL/boot/grub/grub.cfg" || fail "grub.cfg missing chainloader +1 stanza"
    checkpoint_set grub_cfg
}

install_grub() {
    echo "Installing GRUB to $TARGET_DISK ..."
    grub-install --target="$GRUB_INSTALL_TARGET" --boot-directory="$MNT_INSTALL/boot" --recheck "$TARGET_DISK"
    grub-probe --target=fs "$MNT_INSTALL" >/dev/null
    grub-probe --target=device "$MNT_INSTALL" >/dev/null
    checkpoint_set grub_installed
}

verify_windows_media_layout() {
    [ -f "$MNT_INSTALL/bootmgr" ] || fail "Missing bootmgr"
    [ -f "$MNT_INSTALL/sources/boot.wim" ] || fail "Missing boot.wim"
    [ -f "$MNT_INSTALL/sources/install.wim" ] || [ -f "$MNT_INSTALL/sources/install.esd" ] || fail "Missing install.wim/install.esd"
    [ -f "$MNT_INSTALL/Autounattend.xml" ] || fail "Missing Autounattend.xml"
    [ -d "$MNT_INSTALL/sources/virtio" ] || fail "Missing VirtIO directory"
}

verify_ready() {
    verify_partition_layout
    verify_windows_media_layout
    verify_virtio_layout

    [ -f "$MNT_INSTALL/sources/boot.wim.virtio_patched" ] || fail "boot.wim was not patched"
    [ -f "$MNT_INSTALL/boot/grub/grub.cfg" ] || fail "Missing grub.cfg"

    checkpoint_set final_verified

    echo "All required installer files and checks are present."
    echo "Disk: $TARGET_DISK"
    echo "Target Windows partition: $PART1"
    echo "Installer partition: $PART2"
    echo "Edition: $WINDOWS_EDITION"
    echo "Reboot the VPS and select: windows installer (BIOS)"
    echo "After setup completes, reboot again and select: Windows 11 (installed)"
    echo "If you want Windows to fully own the MBR afterward, run bootrec /fixmbr and bootrec /fixboot from Windows recovery."
}

prepare_windows_media() {
    local download_dir
    local windows_iso
    local virtio_iso
    local windows_size
    local virtio_size
    local total_size
    local total_zram_mb
    local avail_ram_mb
    local safe_ram_mb
    local default_windows_iso_size=$((8 * 1024 * 1024 * 1024))
    local default_virtio_iso_size=$((700 * 1024 * 1024))

    WINDOWS_ISO_URL="$(prompt_value "$WINDOWS_ISO_URL" "Enter Windows ISO URL: ")"
    VIRTIO_ISO_URL="$(prompt_value "$VIRTIO_ISO_URL" "Enter VirtIO ISO URL [default]: ")"

    [ -n "$WINDOWS_ISO_URL" ] || fail "Windows ISO URL is required"
    [ -n "$VIRTIO_ISO_URL" ] || VIRTIO_ISO_URL="$DEFAULT_VIRTIO_ISO_URL"

    if [ "$FORCE_DOWNLOAD" -eq 1 ]; then
        rm -f "$STATE_DIR/downloads_completed" "$STATE_DIR/windows_extracted" "$STATE_DIR/virtio_extracted" \
              "$STATE_DIR/install_image_inspected" "$STATE_DIR/boot_wim_patched"
    fi

    windows_size=$(get_content_length "$WINDOWS_ISO_URL" 2>/dev/null | tr -cd '0-9')
    virtio_size=$(get_content_length "$VIRTIO_ISO_URL" 2>/dev/null | tr -cd '0-9')

    if [ -z "${windows_size:-}" ] || [ "${windows_size:-0}" -le 0 ]; then
        echo "WARNING: Windows ISO size unknown. Estimating ${default_windows_iso_size} bytes for zram decision."
        windows_size=$default_windows_iso_size
    fi
    if [ -z "${virtio_size:-}" ] || [ "${virtio_size:-0}" -le 0 ]; then
        echo "WARNING: VirtIO ISO size unknown. Estimating ${default_virtio_iso_size} bytes for zram decision."
        virtio_size=$default_virtio_iso_size
    fi

    total_size=$((windows_size + virtio_size))
    total_zram_mb=$((total_size / 1024 / 1024 + 1024))

    avail_ram_mb=0
    if command_exists free; then
        avail_ram_mb=$(free -m | awk '/^Mem:/ {print $7}')
    fi
    if [ "$avail_ram_mb" -gt 512 ]; then
        safe_ram_mb=$((avail_ram_mb - 512))
    else
        safe_ram_mb=0
    fi

    echo "Detected available RAM: ${avail_ram_mb}MB; reserving 512MB for system; safe zram budget: ${safe_ram_mb}MB"
    echo "ISO size estimate: $((total_size / 1024 / 1024))MB; target zram size with buffer: ${total_zram_mb}MB"

    if [ "$total_zram_mb" -gt 0 ] && [ "$total_zram_mb" -le "$safe_ram_mb" ]; then
        echo "Attempting zram download with lz4 compression."
        if setup_zram "$total_zram_mb"; then
            USE_ZRAM=1
            mkdir -p /mnt/zram0/windisk
            download_dir="/mnt/zram0/windisk"
        else
            echo "WARNING: zram setup failed; falling back to disk downloads."
            USE_ZRAM=0
            download_dir=$(choose_download_dir)
        fi
    else
        echo "Not enough RAM for zram download; using disk fallback."
        USE_ZRAM=0
        download_dir=$(choose_download_dir)
    fi

    mkdir -p "$download_dir"
    windows_iso="$download_dir/Windows.iso"
    virtio_iso="$download_dir/VirtIO.iso"

    if ! checkpoint_done downloads_completed; then
        if ! download_file "$WINDOWS_ISO_URL" "$windows_iso" || ! download_file "$VIRTIO_ISO_URL" "$virtio_iso"; then
            if [ "${USE_ZRAM:-0}" -eq 1 ]; then
                echo "WARNING: zram download failed; cleaning up zram and retrying on disk."
                cleanup_zram
                USE_ZRAM=0
                download_dir=$(choose_download_dir)
                mkdir -p "$download_dir"
                windows_iso="$download_dir/Windows.iso"
                virtio_iso="$download_dir/VirtIO.iso"
                download_file "$WINDOWS_ISO_URL" "$windows_iso"
                download_file "$VIRTIO_ISO_URL" "$virtio_iso"
            else
                fail "Download failed for Windows or VirtIO ISO."
            fi
        fi
        checkpoint_set downloads_completed
    fi

    [ -f "$windows_iso" ] || fail "Windows ISO missing after download"
    [ -f "$virtio_iso" ] || fail "VirtIO ISO missing after download"

    WINDOWS_ISO="$windows_iso"
    VIRTIO_ISO="$virtio_iso"

    if [ "${USE_ZRAM:-0}" -eq 1 ]; then
        if ! finalize_zram_downloads; then
            echo "WARNING: Could not persist zram ISOs to /root/windisk. Keeping zram mount for extraction if available."
        fi
    fi

    if ! checkpoint_done windows_extracted; then
        copy_windows_media "$WINDOWS_ISO"
    fi
    if ! checkpoint_done virtio_extracted; then
        copy_virtio_media "$VIRTIO_ISO"
    fi

    inspect_install_image
    write_ei_cfg
    write_autounattend_xml
}

main() {
    require_root
    parse_args "$@"
    ensure_toolchain
    verify_vps_compatibility

    if [ "$CHECK_ONLY" -eq 1 ]; then
        echo "Check-only mode complete."
        exit 0
    fi

    ensure_partitions_ready
    verify_partition_layout
    prepare_windows_media
    write_bypass_script
    patch_boot_wim
    write_grub_config
    install_grub
    verify_ready
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi