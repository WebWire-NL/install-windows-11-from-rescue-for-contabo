#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/root/.wininstall-state"
mkdir -p "$STATE_DIR"

TARGET_DISK="${TARGET_DISK:-/dev/sda}"
PART1="${PART1:-${TARGET_DISK}1}"
PART2="${PART2:-${TARGET_DISK}2}"

MNT_INSTALL="/mnt"
MNT_STORAGE="/root/windisk"

GRUB_INSTALL_TARGET="i386-pc"
DEFAULT_VIRTIO_ISO_URL="https://bit.ly/4d1g7Ht"

RECREATE_DISK=0
CHECK_ONLY=0
FORCE_DOWNLOAD=0
NO_PROMPT=0
UNATTENDED=1
WINDOWS_ISO_URL=""
VIRTIO_ISO_URL=""
UNATTENDED_CMD="${UNATTENDED_CMD:-}"

WINDOWS_EDITION="${WINDOWS_EDITION:-Windows 11 Pro}"
WINDOWS_GENERIC_KEY="${WINDOWS_GENERIC_KEY:-VK7JG-NPHTM-C97JM-9MPGT-3V66T}"
WINDOWS_LOCALE="${WINDOWS_LOCALE:-en-US}"
WINDOWS_TIMEZONE="${WINDOWS_TIMEZONE:-UTC}"
WINDOWS_USERNAME="${WINDOWS_USERNAME:-Administrator}"
WINDOWS_PASSWORD="${WINDOWS_PASSWORD:-ChangeMeNow!123}"

checkpoint_done() { [ -f "$STATE_DIR/$1" ]; }
checkpoint_set() { touch "$STATE_DIR/$1"; }
dump_checkpoint_state() {
    echo "=== checkpoint state ==="
    for cp in partitions downloads_completed windows_extracted virtio_extracted boot_wim_patched bypass_ready grub_cfg grub_installed; do
        if checkpoint_done "$cp"; then
            echo "$cp: set"
        else
            echo "$cp: missing"
        fi
    done
    echo "=== installer file state ==="
    for file in "$MNT_INSTALL/bootmgr" "$MNT_INSTALL/sources/boot.wim" "$MNT_INSTALL/sources/virtio/NetKVM/2k3/amd64/netkvm.sys"; do
        if [ -e "$file" ]; then
            echo "$file: present"
        else
            echo "$file: missing"
        fi
    done
}
command_exists() { command -v "$1" >/dev/null 2>&1; }

refresh_partition_table() {
    echo "Refreshing kernel partition table for $TARGET_DISK..."
    if command_exists partprobe; then
        partprobe "$TARGET_DISK" || true
    fi
    if command_exists blockdev; then
        blockdev --rereadpt "$TARGET_DISK" || true
    fi
    if command_exists partx; then
        partx -u "$TARGET_DISK" || true
    fi
    if command_exists udevadm; then
        udevadm settle --timeout=10 || true
    fi
    sleep 3
}

require_root() {
    [ "$(id -u)" -eq 0 ] || { echo "ERROR: Run as root."; exit 1; }
}

cleanup_mount() {
    local p="$1"
    if mountpoint -q "$p"; then
        if ! umount "$p"; then
            echo "WARNING: $p is busy, trying lazy unmount"
            umount -l "$p" || true
        fi
    fi
}

mount_existing_partitions() {
    mkdir -p "$MNT_INSTALL" "$MNT_STORAGE"
    if [ -b "$PART2" ] && ! mountpoint -q "$MNT_INSTALL"; then
        mount "$PART2" "$MNT_INSTALL" 2>/dev/null || true
    fi
    if [ -b "$PART1" ] && ! mountpoint -q "$MNT_STORAGE"; then
        mount "$PART1" "$MNT_STORAGE" 2>/dev/null || true
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --recreate-disk) RECREATE_DISK=1 ;;
            --check-only) CHECK_ONLY=1 ;;
            --force-download) FORCE_DOWNLOAD=1 ;;
            --no-prompt) NO_PROMPT=1 ;;
            --unattended) UNATTENDED=1 ;;
            --unattended-cmd=*) UNATTENDED_CMD="${1#*=}" ;;
            --windows-iso-url=*) WINDOWS_ISO_URL="${1#*=}" ;;
            --virtio-iso-url=*) VIRTIO_ISO_URL="${1#*=}" ;;
            --windows-edition=*) WINDOWS_EDITION="${1#*=}" ;;
            --windows-generic-key=*) WINDOWS_GENERIC_KEY="${1#*=}" ;;
            --windows-locale=*) WINDOWS_LOCALE="${1#*=}" ;;
            --windows-timezone=*) WINDOWS_TIMEZONE="${1#*=}" ;;
            --windows-username=*) WINDOWS_USERNAME="${1#*=}" ;;
            --windows-password=*) WINDOWS_PASSWORD="${1#*=}" ;;
            --unattended-cmd)
                shift; UNATTENDED_CMD="${1:-}" ;;
            --windows-iso-url)
                shift; WINDOWS_ISO_URL="${1:-}" ;;
            --virtio-iso-url)
                shift; VIRTIO_ISO_URL="${1:-}" ;;
            --windows-edition)
                shift; WINDOWS_EDITION="${1:-}" ;;
            --windows-generic-key)
                shift; WINDOWS_GENERIC_KEY="${1:-}" ;;
            --windows-locale)
                shift; WINDOWS_LOCALE="${1:-}" ;;
            --windows-timezone)
                shift; WINDOWS_TIMEZONE="${1:-}" ;;
            --windows-username)
                shift; WINDOWS_USERNAME="${1:-}" ;;
            --windows-password)
                shift; WINDOWS_PASSWORD="${1:-}" ;;
            *)
                echo "ERROR: Unknown argument: $1"
                exit 1 ;;
        esac
        shift
    done
}

ensure_toolchain() {
    local required=(
        parted partprobe mkfs.ntfs mount umount rsync
        grub-install grub-probe curl grep awk sed find wimlib-imagex iconv
    )
    local missing=()
    for cmd in "${required[@]}"; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: Missing required commands: ${missing[*]}"
        exit 1
    fi
}

detect_firmware_mode() {
    if [ -d /sys/firmware/efi ]; then
        FIRMWARE_MODE="uefi"
    else
        FIRMWARE_MODE="bios"
    fi
}

get_disk_label() {
    parted "$TARGET_DISK" --script print 2>/dev/null \
        | awk -F: '/^Partition Table/ {gsub(/[[:space:]]/, "", $2); print $2}'
}

verify_vps_compatibility() {
    [ -b "$TARGET_DISK" ] || { echo "ERROR: $TARGET_DISK not found."; exit 1; }
    detect_firmware_mode
    echo "Detected firmware mode: $FIRMWARE_MODE"

    local label
    label="$(get_disk_label || true)"
    echo "Detected disk label: ${label:-unknown}"

    if [ "$FIRMWARE_MODE" != "bios" ]; then
        echo "WARNING: This script is optimized for BIOS rescue boot."
    fi
}

recreate_partitions() {
    echo "Recreating partitions on $TARGET_DISK ..."
    cleanup_mount "$MNT_INSTALL"
    cleanup_mount "$MNT_STORAGE"

    parted "$TARGET_DISK" --script -- mklabel msdos
    parted "$TARGET_DISK" --script -- mkpart primary ntfs 1MiB 50%
    parted "$TARGET_DISK" --script -- mkpart primary ntfs 50% 100%
    refresh_partition_table

    mkfs.ntfs -f "$PART1"
    mkfs.ntfs -f "$PART2"

    mkdir -p "$MNT_INSTALL" "$MNT_STORAGE"
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

download_file() {
    local url="$1"
    local output="$2"

    if [ -f "$output" ] && [ "$FORCE_DOWNLOAD" -eq 0 ]; then
        local existing_size
        existing_size=$(stat -c%s "$output" 2>/dev/null || echo 0)
        if [ "$existing_size" -gt 0 ] && [ "$existing_size" -lt $((10 * 1024 * 1024)) ]; then
            rm -f "$output"
        fi
        if [ -f "$output" ]; then
            echo "Using existing file: $output"
            return
        fi
    fi

    echo "Downloading $(basename "$output") ..."
    curl -fL --retry 5 --retry-delay 5 --continue-at - -o "$output" "$url"
}

copy_windows_media() {
    local iso="$1"
    local loop_dir
    loop_dir="$(mktemp -d)"

    cleanup() {
        mountpoint -q "$loop_dir" && umount "$loop_dir" || true
        rmdir "$loop_dir" 2>/dev/null || true
    }
    trap cleanup RETURN

    mount -o loop "$iso" "$loop_dir"
    rsync -a --info=progress2 --human-readable --stats "$loop_dir"/ "$MNT_INSTALL"/
    if [ ! -f "$MNT_INSTALL/bootmgr" ] || [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then
        echo "ERROR: Windows ISO extraction failed; $MNT_INSTALL/bootmgr or $MNT_INSTALL/sources/boot.wim is missing after rsync."
        dump_checkpoint_state
        exit 1
    fi
    checkpoint_set windows_extracted
    trap - RETURN
}

copy_virtio_media() {
    local iso="$1"
    local loop_dir
    loop_dir="$(mktemp -d)"

    cleanup() {
        mountpoint -q "$loop_dir" && umount "$loop_dir" || true
        rmdir "$loop_dir" 2>/dev/null || true
    }
    trap cleanup RETURN

    mkdir -p "$MNT_INSTALL/sources/virtio"
    mount -o loop "$iso" "$loop_dir"
    rsync -a --info=progress2 --human-readable --stats "$loop_dir"/ "$MNT_INSTALL/sources/virtio"/
    if [ -z "$(find "$MNT_INSTALL/sources/virtio" -type f 2>/dev/null | head -n 1)" ]; then
        echo "ERROR: VirtIO extraction failed; no files found under $MNT_INSTALL/sources/virtio."
        dump_checkpoint_state
        exit 1
    fi
    checkpoint_set virtio_extracted
    trap - RETURN
}

xml_escape() {
    sed -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e "s/'/\&apos;/g" \
        -e 's/"/\&quot;/g'
}

choose_download_dir() {
    # Prefer the mounted installer storage partition if available.
    if [ -n "$MNT_STORAGE" ] && mountpoint -q "$MNT_STORAGE" 2>/dev/null; then
        echo "$MNT_STORAGE"
        return
    fi
    echo "/tmp"
}

prepare_windows_media() {
    local download_dir
    download_dir=$(choose_download_dir)
    if [ -z "$download_dir" ]; then
        echo "ERROR: could not determine a download directory."
        exit 1
    fi
    if [ "$download_dir" = "$MNT_STORAGE" ] || [ "$download_dir" = "/root/windisk" ]; then
        if ! mountpoint -q "$download_dir" 2>/dev/null; then
            echo "ERROR: $download_dir is not mounted."
            exit 1
        fi
    fi
    echo "Using download directory: $download_dir"
    mkdir -p "$download_dir"
    local windows_iso="$download_dir/Windows.iso"
    local virtio_iso="$download_dir/VirtIO.iso"
    WINDOWS_ISO_URL="$(prompt_value "$WINDOWS_ISO_URL" "Enter Windows ISO URL: ")"
    VIRTIO_ISO_URL="$(prompt_value "$VIRTIO_ISO_URL" "Enter VirtIO ISO URL [default]: ")"

    [ -n "$WINDOWS_ISO_URL" ] || { echo "ERROR: Windows ISO URL is required."; exit 1; }
    [ -n "$VIRTIO_ISO_URL" ] || VIRTIO_ISO_URL="$DEFAULT_VIRTIO_ISO_URL"

    if [ "$FORCE_DOWNLOAD" -eq 1 ]; then
        rm -f "$STATE_DIR/downloads_completed"
    fi

    if checkpoint_done downloads_completed; then
        if [ -f "$windows_iso" ] && [ -f "$virtio_iso" ]; then
            echo "Using existing downloaded ISOs."
        else
            echo "WARNING: downloads_completed checkpoint is stale; redownloading ISOs."
            rm -f "$STATE_DIR/downloads_completed"
        fi
    fi

    if ! checkpoint_done downloads_completed; then
        download_file "$WINDOWS_ISO_URL" "$windows_iso"
        download_file "$VIRTIO_ISO_URL" "$virtio_iso"
        checkpoint_set downloads_completed
    fi

    if checkpoint_done windows_extracted; then
        if [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then
            echo "WARNING: windows_extracted checkpoint is stale; re-extracting Windows media."
            rm -f "$STATE_DIR/windows_extracted"
        else
            echo "Using existing Windows media copy."
        fi
    fi
    if ! checkpoint_done windows_extracted; then
        copy_windows_media "$windows_iso"
    fi

    if checkpoint_done virtio_extracted; then
        if [ ! -d "$MNT_INSTALL/sources/virtio" ] || [ -z "$(find "$MNT_INSTALL/sources/virtio" -type f 2>/dev/null | head -n 1)" ]; then
            echo "WARNING: virtio_extracted checkpoint is stale; re-extracting VirtIO drivers."
            rm -f "$STATE_DIR/virtio_extracted"
        else
            echo "Using existing VirtIO driver copy."
        fi
    fi
    if ! checkpoint_done virtio_extracted; then
        copy_virtio_media "$virtio_iso"
    fi

    if checkpoint_done boot_wim_patched; then
        if [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then
            echo "WARNING: boot_wim_patched checkpoint is stale; clearing patch checkpoint."
            rm -f "$STATE_DIR/boot_wim_patched"
        fi
    fi

    write_ei_cfg
    write_autounattend_xml
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
    if [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then
        echo "WARNING: $MNT_INSTALL/sources/boot.wim not found. Attempting to recover installer media."
        dump_checkpoint_state
        mount_existing_partitions
        if [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then
            prepare_windows_media
        fi
    fi

    [ -f "$MNT_INSTALL/sources/boot.wim" ] || {
        echo "ERROR: boot.wim not found after recovery attempt."
        dump_checkpoint_state
        ls -la "$MNT_INSTALL/sources" 2>/dev/null || true
        exit 1
    }

    echo "Inspecting boot.wim images..."
    wimlib-imagex info "$MNT_INSTALL/sources/boot.wim" > /tmp/bootwim_info.txt

    local image_count auto_image_index
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

    [ -n "$auto_image_index" ] || { echo "ERROR: Could not determine boot.wim image index."; exit 1; }

    create_bypass_cmd /tmp/bypass.cmd
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
set timeout=5
set default=0

menuentry "windows installer (BIOS)" {
    insmod ntfs
    search --no-floppy --set=root --file=/bootmgr
    chainloader /bootmgr
    boot
}
EOF
    checkpoint_set grub_cfg
}

install_grub() {
    echo "Installing GRUB to $TARGET_DISK ..."
    grub-install --target="$GRUB_INSTALL_TARGET" --boot-directory="$MNT_INSTALL/boot" --recheck "$TARGET_DISK"
    grub-probe --target=fs "$MNT_INSTALL" >/dev/null
    grub-probe --target=device "$MNT_INSTALL" >/dev/null
    checkpoint_set grub_installed
}

verify_ready() {
    [ -f "$MNT_INSTALL/bootmgr" ] || { echo "ERROR: Missing $MNT_INSTALL/bootmgr"; exit 1; }
    [ -f "$MNT_INSTALL/sources/boot.wim" ] || { echo "ERROR: Missing $MNT_INSTALL/sources/boot.wim"; exit 1; }
    [ -d "$MNT_INSTALL/sources/virtio" ] || { echo "ERROR: Missing $MNT_INSTALL/sources/virtio"; exit 1; }
    [ -f "$MNT_INSTALL/boot/grub/grub.cfg" ] || { echo "ERROR: Missing grub.cfg"; exit 1; }

    grep -q 'chainloader /bootmgr' "$MNT_INSTALL/boot/grub/grub.cfg" \
        || { echo "ERROR: GRUB is not configured to chainload /bootmgr"; exit 1; }

    echo "All required installer files are present."
    echo "Reboot the VPS and select: windows installer (BIOS)"
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
    prepare_windows_media
    write_bypass_script
    patch_boot_wim
    write_grub_config
    install_grub
    verify_ready
}

main "$@"
