#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG & STATE ---
STATE_DIR="/root/.wininstall-state"
MNT_INSTALL="/mnt/win_installer"   # INSTALLER partition (also holds VirtIO + Autounattend + info)
MNT_STORAGE="/mnt/win_storage"     # WINDOWS target partition (C:)
ISO_MOUNT="/tmp/iso_mount"

log() { echo -e "\e[32m[$(date +'%T')]\e[0m $*"; }
log_step() {
    local step=$1
    local total=7
    local percent=$(( step * 100 / total ))
    echo -e "\e[32m[$(date +'%T')] [STEP $step/$total - $percent% COMPLETE]\e[0m $2"
}

checkpoint_done() { [ -f "$STATE_DIR/$1" ]; }
checkpoint_set() { touch "$STATE_DIR/$1"; }
checkpoint_clear() { rm -f "$STATE_DIR/$1"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

install_missing_dependencies() {
    if ! command_exists apt-get; then
        return 1
    fi

    local pkg
    for cmd in "$@"; do
        case "$cmd" in
            wimlib-imagex) pkg="wimtools" ;;
            curl) pkg="curl" ;;
            rsync) pkg="rsync" ;;
            aria2c) pkg="aria2" ;;
            *) pkg="" ;;
        esac
        if [ -n "$pkg" ]; then
            dpkg -s "$pkg" >/dev/null 2>&1 || apt-get install -y --no-install-recommends "$pkg"
        fi
    done
}

select_boot_wim_image_index() {
    if [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then
        echo ""
        return
    fi

    local index
    index=$(wimlib-imagex info "$MNT_INSTALL/sources/boot.wim" | awk '
        BEGIN { first = "" }
        /Index:/ { if (first == "") first = $2 }
        /Name:/ {
            name = substr($0, index($0, $2))
            lname = tolower(name)
            if (lname ~ /windows pe/) {
                print $2
                exit
            }
        }
        END { if (first != "") print first }
    ')

    echo "$index"
}

create_unattended_startnet_cmd() {
    local output_path="$1"

    cat > "$output_path" <<'EOF'
@echo off
wpeinit
if exist %SystemRoot%\System32\bypass.cmd (
    echo Running embedded bypass
    call %SystemRoot%\System32\bypass.cmd
)
for %%D in (X D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist %%D:\sources\bypass.cmd (
        echo Running bypass from %%D:\sources\bypass.cmd
        call %%D:\sources\bypass.cmd
        goto :driver_done
    )
)
for %%D in (X D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist %%D:\sources\virtio\amd64\w11\vioscsi.inf (
        drvload %%D:\sources\virtio\amd64\w11\vioscsi.inf
        goto :driver_done
    )
    if exist %%D:\sources\virtio\amd64\w11\viostor.inf (
        drvload %%D:\sources\virtio\amd64\w11\viostor.inf
        goto :driver_done
    )
    if exist %%D:\sources\virtio\amd64\w10\vioscsi.inf (
        drvload %%D:\sources\virtio\amd64\w10\vioscsi.inf
        goto :driver_done
    )
    if exist %%D:\sources\virtio\amd64\w10\viostor.inf (
        drvload %%D:\sources\virtio\amd64\w10\viostor.inf
        goto :driver_done
    )
)
:driver_done
X:\setup.exe
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
exit /b 0
EOF
}

# --- FORCE CLEAN ---
force_clean() {
    log "Performing full system clean and memory flush (PID $$)..."
    pkill -9 aria2c || true
    for pid in $(pgrep -f "windows-install.sh" || true); do
        if [ "$pid" != "$$" ]; then
            kill -9 "$pid" || true
        fi
    done
    umount -l "$MNT_INSTALL" 2>/dev/null || true
    umount -l "$MNT_STORAGE" 2>/dev/null || true
    umount -l "$ISO_MOUNT" 2>/dev/null || true
    rm -rf "$STATE_DIR" /mnt/win_installer/* /mnt/win_storage/* /tmp/*.log "$ISO_MOUNT"/* 2>/dev/null || true
    mkdir -p "$STATE_DIR" "$MNT_INSTALL" "$MNT_STORAGE" "$ISO_MOUNT"
    sync || true
    echo 3 > /proc/sys/vm/drop_caches || true
    log "Memory caches dropped and state cleared."
}

# --- ARGUMENTS ---
FORCE_DOWNLOAD=0
if [[ "${1:-}" == "--force-clean" ]]; then
    force_clean
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-download) FORCE_DOWNLOAD=1; shift ;;
        *) break ;;
    esac
done

if [ $# -lt 1 ]; then
    echo "Usage: $0 [--force-clean] [--force-download] <WINDOWS_ISO_URL>"
    exit 1
fi
WINDOWS_ISO_URL="$1"

mkdir -p "$STATE_DIR" "$MNT_INSTALL" "$MNT_STORAGE" "$ISO_MOUNT"

# --- USER PREFERENCES ---
USE_DHCP="false"
WINDOWS_USERNAME="Administrator"
DOWNLOAD_THREADS="2"

VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
WINDOWS_EDITION="Windows 11 Pro N"
WINDOWS_GENERIC_KEY="MH37W-N47XK-V7XM9-C7227-GCQG9"

# --- PASSWORD MANAGEMENT ---
if [ -f "$STATE_DIR/password" ]; then
    WINDOWS_PASSWORD=$(cat "$STATE_DIR/password")
else
    WINDOWS_PASSWORD=$(openssl rand -base64 12 | tr -d '/+' | head -c 16)
    WINDOWS_PASSWORD="${WINDOWS_PASSWORD}1!"
    echo "$WINDOWS_PASSWORD" > "$STATE_DIR/password"
fi

# --- STEP 1: SYSTEM & NETWORK INFO ---
log_step 1 "Initializing system and network information..."
TARGET_DISK=$(lsblk -dnpo NAME | grep -E '/dev/(sda|vda|nvme[0-9]n[0-9]|xvda)$' | head -n1 || echo "/dev/sda")
FIRMWARE="bios"; [ -d /sys/firmware/efi ] && FIRMWARE="uefi"
VPS_HOSTNAME=$(hostname | tr -d ' ' | cut -c1-15)
VPS_TIMEZONE_RAW=$(cat /etc/timezone 2>/dev/null || echo "UTC")
VPS_LOCALE=$(echo ${LANG:-en_US.UTF-8} | cut -d. -f1 | tr '_' '-')

case "$VPS_TIMEZONE_RAW" in
    "Etc/UTC"|"UTC") WINDOWS_TIMEZONE="UTC" ;;
    "Europe/London") WINDOWS_TIMEZONE="GMT Standard Time" ;;
    "America/New_York") WINDOWS_TIMEZONE="Eastern Standard Time" ;;
    *) WINDOWS_TIMEZONE="UTC" ;;
esac

if [ "$USE_DHCP" = "true" ]; then
    XML_NETWORK="<Ipv4Settings><DhcpEnabled>true</DhcpEnabled></Ipv4Settings>"
else
    iface=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    IP_ADDR=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    NETMASK=$(ip -4 addr show "$iface" | grep "$IP_ADDR" | awk '{print $2}' | cut -d/ -f2)
    GATEWAY=$(ip route show default | awk '/default/ {print $3}' | head -n1)
    DNS_LIST=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | grep -E '^[0-9.]+$' | xargs)
    DNS_ENTRIES=""
    idx=1
    for dns in $DNS_LIST; do
        DNS_ENTRIES+="<IpAddress wcm:action=\"add\" wcm:keyValue=\"$idx\">$dns</IpAddress>"
        idx=$((idx+1))
    done
    XML_NETWORK="<DNSServerSearchOrder>$DNS_ENTRIES</DNSServerSearchOrder><Ipv4Settings><DhcpEnabled>false</DhcpEnabled></Ipv4Settings><UnicastIpAddresses><IpAddress wcm:action=\"add\" wcm:keyValue=\"1\">$IP_ADDR/$NETMASK</IpAddress></UnicastIpAddresses><Routes><Route wcm:action=\"add\"><Identifier>1</Identifier><Prefix>0.0.0.0/0</Prefix><NextHopAddress>$GATEWAY</NextHopAddress></Route></Routes>"
fi

# --- STEP 2: TOOLS ---
log_step 2 "Installing system tools..."
if ! checkpoint_done tools_installed; then
    apt-get update -qq
    apt-get install -y ntfs-3g grub-pc grub-efi-amd64-bin wimtools aria2 rsync parted psmisc curl >/dev/null 2>&1
    checkpoint_set tools_installed
else
    log "Tools already installed, skipping."
fi

# --- STEP 3: PARTITIONS & FORMAT ---
log_step 3 "Ensuring partition layout (Disk 0 / Partition 1 = Windows)..."

P_PREFIX=""; [[ $TARGET_DISK == *"nvme"* ]] && P_PREFIX="p"

if ! checkpoint_done partitions; then
    umount "${TARGET_DISK}"* 2>/dev/null || true
    fuser -mvk "$TARGET_DISK" 2>/dev/null || true

    if [ "$FIRMWARE" = "uefi" ]; then
        # GPT: 1 = EFI, 2 = Windows (target), 3 = installer
        parted "$TARGET_DISK" --script mklabel gpt
        parted "$TARGET_DISK" --script mkpart EFI fat32 1MiB 512MiB
        parted "$TARGET_DISK" --script set 1 esp on
        parted "$TARGET_DISK" --script mkpart WINDOWS ntfs 512MiB 40GiB
        parted "$TARGET_DISK" --script mkpart INSTALLER ntfs 40GiB 100%
        PART_EFI="${TARGET_DISK}${P_PREFIX}1"
        PART_WIN="${TARGET_DISK}${P_PREFIX}2"
        PART_INS="${TARGET_DISK}${P_PREFIX}3"
        mkfs.fat -F32 -n "EFI" "$PART_EFI"
    else
        # MBR: 1 = Windows (target, active), 2 = installer
        parted "$TARGET_DISK" --script mklabel msdos
        parted "$TARGET_DISK" --script mkpart primary ntfs 1MiB 40GiB
        parted "$TARGET_DISK" --script mkpart primary ntfs 40GiB 100%
        parted "$TARGET_DISK" --script set 1 boot on
        PART_WIN="${TARGET_DISK}${P_PREFIX}1"
        PART_INS="${TARGET_DISK}${P_PREFIX}2"
    fi

    mkfs.ntfs -f -L "WINDOWS" "$PART_WIN"
    mkfs.ntfs -f -L "INSTALLER" "$PART_INS"

    checkpoint_set partitions
else
    log "Partitions already created, reusing."
    if [ "$FIRMWARE" = "uefi" ]; then
        PART_EFI="${TARGET_DISK}${P_PREFIX}1"
        PART_WIN="${TARGET_DISK}${P_PREFIX}2"
        PART_INS="${TARGET_DISK}${P_PREFIX}3"
    else
        PART_WIN="${TARGET_DISK}${P_PREFIX}1"
        PART_INS="${TARGET_DISK}${P_PREFIX}2"
    fi
fi

mount -L "INSTALLER" "$MNT_INSTALL" || true
mount -L "WINDOWS" "$MNT_STORAGE" || true

# --- STEP 4: SUMMARY (on INSTALLER partition) ---
log_step 4 "Writing configuration summary to installer partition..."
if ! checkpoint_done summary_written; then
    cat > "$MNT_INSTALL/INSTALL_INFO.txt" <<EOF
Hostname: $VPS_HOSTNAME
User: $WINDOWS_USERNAME
Pass: $WINDOWS_PASSWORD
Disk: $TARGET_DISK
Firmware: $FIRMWARE
WINDOWS_EDITION: $WINDOWS_EDITION
Target: Disk 0, Partition 1
EOF
    cp "$MNT_INSTALL/INSTALL_INFO.txt" /root/INSTALL_INFO.txt
    checkpoint_set summary_written
else
    log "Summary already written, skipping."
fi

# --- DOWNLOAD UTILITY ---
resilient_download() {
    local url="$1"
    local out="$2"
    while true; do
        curl -L -C - --retry 5 --retry-delay 5 "$url" -o "$out" && break
        sleep 2
    done
}

validate_iso() {
    local iso="$1"
    local min_bytes="$2"
    local label="$3"

    if [ ! -f "$iso" ]; then
        log "$label ISO not found: $iso"
        return 1
    fi

    local size
    size=$(stat -c%s "$iso" 2>/dev/null || echo 0)
    if [ "$size" -lt "$min_bytes" ]; then
        log "$label ISO too small ($size bytes), expected at least $min_bytes"
        return 1
    fi

    local tmpmnt
    tmpmnt="$(mktemp -d)"
    if ! mount -o loop "$iso" "$tmpmnt" 2>/dev/null; then
        log "$label ISO mount failed, treating as invalid"
        rmdir "$tmpmnt"
        return 1
    fi

    if [ "$label" = "Windows" ]; then
        if [ ! -f "$tmpmnt/sources/boot.wim" ] || [ ! -f "$tmpmnt/bootmgr" ]; then
            log "$label ISO missing boot.wim or bootmgr, invalid"
            umount "$tmpmnt" || true
            rmdir "$tmpmnt"
            return 1
        fi
    fi

    umount "$tmpmnt" || true
    rmdir "$tmpmnt"
    log "$label ISO validated successfully."
    return 0
}

# --- STEP 5: DOWNLOAD & EXTRACT ---
log_step 5 "Downloading and validating ISOs (≈8.5GB total)..."

WIN_ISO="$MNT_STORAGE/Win.iso"
VIR_ISO="$MNT_STORAGE/Vir.iso"

umount "$ISO_MOUNT" 2>/dev/null || true

if [ "$FORCE_DOWNLOAD" -eq 1 ]; then
    checkpoint_clear downloads_completed
    rm -f "$WIN_ISO" "$VIR_ISO" 2>/dev/null || true
fi

if ! checkpoint_done downloads_completed; then
    if validate_iso "$WIN_ISO" $((500*1024*1024)) "Windows" && \
       validate_iso "$VIR_ISO" $((50*1024*1024)) "VirtIO"; then
        log "Existing ISOs are valid; marking downloads as completed."
        checkpoint_set downloads_completed
    else
        log "Downloading ISOs (either missing or invalid)..."
        resilient_download "$WINDOWS_ISO_URL" "$WIN_ISO"
        resilient_download "$VIRTIO_ISO_URL" "$VIR_ISO"
        validate_iso "$WIN_ISO" $((500*1024*1024)) "Windows" || exit 1
        validate_iso "$VIR_ISO" $((50*1024*1024)) "VirtIO" || exit 1
        checkpoint_set downloads_completed
    fi
else
    log "Downloads already completed, skipping."
fi

if ! checkpoint_done windows_extracted; then
    umount "$ISO_MOUNT" 2>/dev/null || true
    mount -o loop "$WIN_ISO" "$ISO_MOUNT"
    rsync -ah --info=progress2 "$ISO_MOUNT/" "$MNT_INSTALL/"
    umount "$ISO_MOUNT"
    checkpoint_set windows_extracted
else
    log "Windows ISO already extracted, skipping."
fi

if ! checkpoint_done virtio_extracted; then
    mkdir -p "$MNT_INSTALL/sources/virtio"
    umount "$ISO_MOUNT" 2>/dev/null || true
    mount -o loop "$VIR_ISO" "$ISO_MOUNT"
    rsync -ah "$ISO_MOUNT/" "$MNT_INSTALL/sources/virtio/"
    umount "$ISO_MOUNT"
    checkpoint_set virtio_extracted
else
    log "VirtIO ISO already extracted, skipping."
fi

# --- STEP 6A: startnet.cmd (on installer partition) ---
log_step 6 "Patching installation media (startnet + Autounattend)..."

if ! checkpoint_done boot_wim_patched; then
    if ! command_exists wimlib-imagex; then
        log "wimlib-imagex not installed. Attempting to install missing dependency."
        install_missing_dependencies wimlib-imagex || true
    fi

    if ! command_exists wimlib-imagex; then
        log "ERROR: wimlib-imagex not installed. Cannot patch boot.wim."
        exit 1
    fi

    if [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then
        log "ERROR: boot.wim not found at $MNT_INSTALL/sources/boot.wim"
        exit 1
    fi

    if [ ! -d "$MNT_INSTALL/sources/virtio" ]; then
        mkdir -p "$MNT_INSTALL/sources/virtio"
        umount "$ISO_MOUNT" 2>/dev/null || true
        mount -o loop "$VIR_ISO" "$ISO_MOUNT"
        rsync -ah "$ISO_MOUNT/" "$MNT_INSTALL/sources/virtio/"
        umount "$ISO_MOUNT"
    fi

    create_bypass_cmd "$MNT_INSTALL/sources/bypass.cmd"

    boot_image_index=$(select_boot_wim_image_index)
    if [ -z "$boot_image_index" ]; then
        log "ERROR: Unable to determine correct boot.wim image index."
        exit 1
    fi

    create_unattended_startnet_cmd /tmp/startnet.cmd
    create_bypass_cmd /tmp/bypass.cmd
    rm -rf /tmp/virtio
    mkdir -p /tmp/virtio
    cp -a "$MNT_INSTALL/sources/virtio" /tmp/virtio/

    printf 'add /tmp/virtio /sources/virtio\nadd /tmp/startnet.cmd /Windows/System32/startnet.cmd\nadd /tmp/bypass.cmd /Windows/System32/bypass.cmd\n' > /tmp/wimcmd.txt
    wimlib-imagex update "$MNT_INSTALL/sources/boot.wim" "$boot_image_index" < /tmp/wimcmd.txt

    rm -rf /tmp/virtio /tmp/startnet.cmd /tmp/bypass.cmd /tmp/wimcmd.txt

    if ! wimlib-imagex list "$MNT_INSTALL/sources/boot.wim" "$boot_image_index" | grep -q -F "sources/virtio"; then
        log "ERROR: boot.wim virtio driver tree injection did not persist."
        exit 1
    fi
    if ! wimlib-imagex list "$MNT_INSTALL/sources/boot.wim" "$boot_image_index" | grep -q -F "startnet.cmd"; then
        log "ERROR: boot.wim startnet injection did not persist."
        exit 1
    fi
    if ! wimlib-imagex list "$MNT_INSTALL/sources/boot.wim" "$boot_image_index" | grep -q -F "bypass.cmd"; then
        log "ERROR: boot.wim bypass injection did not persist."
        exit 1
    fi

    log "boot.wim patch verified: virtio, startnet.cmd, bypass.cmd present."
    checkpoint_set boot_wim_patched
else
    log "boot.wim already patched, skipping."
fi

# --- STEP 6B: Autounattend.xml (on installer partition, Disk 0 / Partition 1) ---
if ! checkpoint_done autounattend_written; then
    AUTOUNATTEND="$MNT_INSTALL/Autounattend.xml"
    cat > "$AUTOUNATTEND" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>${VPS_LOCALE}</UILanguage>
      </SetupUILanguage>
      <InputLocale>${VPS_LOCALE}</InputLocale>
      <SystemLocale>${VPS_LOCALE}</SystemLocale>
      <UILanguage>${VPS_LOCALE}</UILanguage>
      <UserLocale>${VPS_LOCALE}</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>${WINDOWS_USERNAME}</FullName>
        <Organization>${VPS_HOSTNAME}</Organization>
        <ProductKey>
          <Key>${WINDOWS_GENERIC_KEY}</Key>
          <WillShowUI>Never</WillShowUI>
        </ProductKey>
      </UserData>
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>false</WillWipeDisk>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>Windows</Label>
              <Format>NTFS</Format>
              <Type>Primary</Type>
              <Active>true</Active>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
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
              <Value>${WINDOWS_EDITION}</Value>
            </MetaData>
          </InstallFrom>
        </OSImage>
      </ImageInstall>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>${VPS_HOSTNAME}</ComputerName>
      <TimeZone>${WINDOWS_TIMEZONE}</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>${VPS_LOCALE}</InputLocale>
      <SystemLocale>${VPS_LOCALE}</SystemLocale>
      <UILanguage>${VPS_LOCALE}</UILanguage>
      <UserLocale>${VPS_LOCALE}</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>${WINDOWS_USERNAME}</Username>
        <Password>
          <Value>${WINDOWS_PASSWORD}</Value>
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
      <RegisteredOwner>${WINDOWS_USERNAME}</RegisteredOwner>
      <RegisteredOrganization>${VPS_HOSTNAME}</RegisteredOrganization>
      <TimeZone>${WINDOWS_TIMEZONE}</TimeZone>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Name>${WINDOWS_USERNAME}</Name>
            <DisplayName>${WINDOWS_USERNAME}</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>${WINDOWS_PASSWORD}</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
</unattend>
EOF
    checkpoint_set autounattend_written
else
    log "Autounattend.xml already present on installer partition, skipping."
fi

# --- STEP 7: BOOTLOADER ---
log_step 7 "Installing bootloader and finalizing..."

if ! checkpoint_done grub_installed; then
    mkdir -p "$MNT_INSTALL/boot/grub"
    if [ "$FIRMWARE" = "uefi" ]; then
        EFI_DIR="$MNT_INSTALL/EFI/Boot"
        mkdir -p "$EFI_DIR"
        entry="menuentry 'Windows Installer (UEFI)' {
        insmod part_gpt
        insmod fat
        set root=(hd0,gpt3)
        chainloader /efi/boot/bootx64.efi
    }"
        grub-install --target="x86_64-efi" --boot-directory="$MNT_INSTALL/boot" --removable "$TARGET_DISK"
        cat > "$MNT_INSTALL/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0
$entry
EOF
    else
        cat > "$MNT_INSTALL/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0

menuentry 'Windows Installer (BIOS) - ntldr fallback' {
    insmod part_msdos
    insmod ntfs
    insmod ntldr
    set root=(hd0,msdos2)
    ntldr /bootmgr
}

menuentry 'Windows 11 (installed)' {
    insmod part_msdos
    insmod ntfs
    insmod ntldr
    set root=(hd0,msdos1)
    makeactive
    chainloader +1
    boot
}
EOF
        grub-install --target="i386-pc" --boot-directory="$MNT_INSTALL/boot" "$TARGET_DISK"
    fi
    checkpoint_set grub_installed
else
    log "GRUB already installed, skipping."
fi

echo "--------------------------------------------------------"
echo "INSTALLATION BOOT MEDIA READY."
echo "Reboot and choose 'Windows Installer' to start setup."
echo "After install, choose 'Windows 11 (installed)' in BIOS mode."
echo "--------------------------------------------------------"
