from pathlib import Path
p = Path('windows-install.sh')
text = p.read_text()
old1 = 'checkpoint_done() { [ -f "$STATE_DIR/$1" ]; }\ncheckpoint_set() { touch "$STATE_DIR/$1"; }\ncheckpoint_clear() { rm -f "$STATE_DIR/$1"; }\n\n# --- FORCE CLEAN ---\n'
new1 = 'checkpoint_done() { [ -f "$STATE_DIR/$1" ]; }\ncheckpoint_set() { touch "$STATE_DIR/$1"; }\ncheckpoint_clear() { rm -f "$STATE_DIR/$1"; }\n\ncommand_exists() { command -v "$1" >/dev/null 2>&1; }\n\ninstall_missing_dependencies() {\n    if ! command_exists apt-get; then\n        return 1\n    fi\n\n    local pkg\n    for cmd in "$@"; do\n        case "$cmd" in\n            wimlib-imagex) pkg="wimtools" ;;\n            curl) pkg="curl" ;;\n            rsync) pkg="rsync" ;;\n            aria2c) pkg="aria2" ;;\n            *) pkg="" ;;\n        esac\n        if [ -n "$pkg" ]; then\n            dpkg -s "$pkg" >/dev/null 2>&1 || apt-get install -y --no-install-recommends "$pkg"\n        fi\n    done\n}\n\nselect_boot_wim_image_index() {\n    if [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then\n        echo ""\n        return\n    fi\n\n    local index\n    index=$(wimlib-imagex info "$MNT_INSTALL/sources/boot.wim" | awk '\n        BEGIN { first = "" }\n        /Index:/ { if (first == "") first = $2 }\n        /Name:/ {\n            name = substr($0, index($0, $2))\n            lname = tolower(name)\n            if (lname ~ /windows pe/) {\n                print $2\n                exit\n            }\n        }\n        END { if (first != "") print first }\n    ' )\n\n    echo "$index"\n}\n\ncreate_unattended_startnet_cmd() {\n    local output_path="$1"\n\n    cat > "$output_path" <<'EOF'\n@echo off\nwpeinit\nif exist %SystemRoot%\\System32\\bypass.cmd (\n    echo Running embedded bypass\n    call %SystemRoot%\\System32\\bypass.cmd\n)\nfor %%D in (X D E F G H I J K L M N O P Q R S T U V W X Y Z) do (\n    if exist %%D:\\sources\\bypass.cmd (\n        echo Running bypass from %%D:\\sources\\bypass.cmd\n        call %%D:\\sources\\bypass.cmd\n        goto :driver_done\n    )\n)\nfor %%D in (X D E F G H I J K L M N O P Q R S T U V W X Y Z) do (\n    if exist %%D:\\sources\\virtio\\amd64\\w11\\vioscsi.inf (\n        drvload %%D:\\sources\\virtio\\amd64\\w11\\vioscsi.inf\n        goto :driver_done\n    )\n    if exist %%D:\\sources\\virtio\\amd64\\w11\\viostor.inf (\n        drvload %%D:\\sources\\virtio\\amd64\\w11\\viostor.inf\n        goto :driver_done\n    )\n    if exist %%D:\\sources\\virtio\\amd64\\w10\\vioscsi.inf (\n        drvload %%D:\\sources\\virtio\\amd64\\w10\\vioscsi.inf\n        goto :driver_done\n    )\n    if exist %%D:\\sources\\virtio\\amd64\\w10\\viostor.inf (\n        drvload %%D:\\sources\\virtio\\amd64\\w10\\viostor.inf\n        goto :driver_done\n    )\n)\n:driver_done\nX:\\setup.exe\nEOF\n}\n\ncreate_bypass_cmd() {\n    local output_path="$1"\n\n    cat > "$output_path" <<'EOF'\n@echo off\nreg add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f\nreg add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f\nreg add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f\nreg add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f\nexit /b 0\nEOF\n}\n\n# --- FORCE CLEAN ---\n'
old2 = '''if ! checkpoint_done boot_wim_patched; then
    if ! command_exists wimlib-imagex; then
        log "wimlib-imagex not installed. Attempting to install missing dependency."
        install_missing_dependencies wimlib-imagex || true
    fi

    if ! command_exists wimlib-imagex; then
        log "WARNING: wimlib-imagex not installed. Skipping boot.wim patch."
        log "VirtIO drivers will still be available on the installer media, but WinPE startup injection cannot be applied."
        exit 1
    fi

    boot_image_index=$(select_boot_wim_image_index)
    if [ -z "$boot_image_index" ]; then
        log "ERROR: Unable to determine correct boot.wim image index."
        exit 1
    fi

    create_unattended_startnet_cmd /tmp/startnet.cmd
    rm -rf /tmp/virtio
    mkdir -p /tmp/virtio
    cp -a "$MNT_INSTALL/sources/virtio" /tmp/virtio/

    printf 'add /tmp/virtio /sources/virtio\nadd /tmp/startnet.cmd /Windows/System32/startnet.cmd\n' > /tmp/wimcmd.txt
    wimlib-imagex update "$MNT_INSTALL/sources/boot.wim" "$boot_image_index" < /tmp/wimcmd.txt

    rm -rf /tmp/virtio /tmp/startnet.cmd /tmp/wimcmd.txt

    if ! wimlib-imagex list "$MNT_INSTALL/sources/boot.wim" "$boot_image_index" | grep -q -F "startnet.cmd"; then
        log "ERROR: boot.wim patch did not persist."
        exit 1
    fi

    checkpoint_set boot_wim_patched
else
    log "boot.wim already patched, skipping."
fi
'''
new2 = '''if ! checkpoint_done boot_wim_patched; then
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

    if ! wimlib-imagex list "$MNT_INSTALL/sources/boot.wim" "$boot_image_index" | grep -q -F "startnet.cmd"; then
        log "ERROR: boot.wim startnet injection did not persist."
        exit 1
    fi
    if ! wimlib-imagex list "$MNT_INSTALL/sources/boot.wim" "$boot_image_index" | grep -q -F "bypass.cmd"; then
        log "ERROR: wim.bim bypass injection did not persist."
        exit 1
    fi

    checkpoint_set boot_wim_patched
else
    log "boot.wim already patched, skipping."
fi
'''
if old1 not in text:
    raise SystemExit('first insertion marker not found')
text = text.replace(old1, new1, 1)
if old2 not in text:
    raise SystemExit('second replacement marker not found')
text = text.replace(old2, new2, 1)
p.write_text(text)
print('patched')
