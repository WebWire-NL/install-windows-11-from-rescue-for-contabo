from pathlib import Path
from pathlib import PurePosixPath

path = Path('windows-install.sh')
text = path.read_text()

old_prepare = '''prepare_windows_media() {
    local download_dir
    download_dir=$(choose_download_dir)
    mkdir -p "$download_dir"

    local windows_iso="$download_dir/Windows.iso"
    local virtio_iso="$download_dir/VirtIO.iso"

    WINDOWS_ISO_URL="$(prompt_value "$WINDOWS_ISO_URL" "Enter Windows ISO URL: ")"
    VIRTIO_ISO_URL="$(prompt_value "$VIRTIO_ISO_URL" "Enter VirtIO ISO URL [default]: ")"

    [ -n "$WINDOWS_ISO_URL" ] || fail "Windows ISO URL is required"
    [ -n "$VIRTIO_ISO_URL" ] || VIRTIO_ISO_URL="$DEFAULT_VIRTIO_ISO_URL"

    if [ "$FORCE_DOWNLOAD" -eq 1 ]; then
        rm -f "$STATE_DIR/downloads_completed" "$STATE_DIR/windows_extracted" "$STATE_DIR/virtio_extracted" \\
              "$STATE_DIR/install_image_inspected" "$STATE_DIR/boot_wim_patched"
    fi

    if ! checkpoint_done downloads_completed; then
        download_file "$WINDOWS_ISO_URL" "$windows_iso"
        download_file "$VIRTIO_ISO_URL" "$virtio_iso"
        checkpoint_set downloads_completed
    fi

    [ -f "$windows_iso" ] || fail "Windows ISO missing after download"
    [ -f "$virtio_iso" ] || fail "VirtIO ISO missing after download"

    if ! checkpoint_done windows_extracted; then
        copy_windows_media "$windows_iso"
    fi
    if ! checkpoint_done virtio_extracted; then
        copy_virtio_media "$virtio_iso"
    fi

    inspect_install_image
    write_ei_cfg
    write_autounattend_xml
}
'''

new_prepare = '''prepare_windows_media() {
    local download_dir
    local windows_iso
    local virtio_iso

    WINDOWS_ISO_URL="$(prompt_value "$WINDOWS_ISO_URL" "Enter Windows ISO URL: ")"
    VIRTIO_ISO_URL="$(prompt_value "$VIRTIO_ISO_URL" "Enter VirtIO ISO URL [default]: ")"

    [ -n "$WINDOWS_ISO_URL" ] || fail "Windows ISO URL is required"
    [ -n "$VIRTIO_ISO_URL" ] || VIRTIO_ISO_URL="$DEFAULT_VIRTIO_ISO_URL"

    if [ "$FORCE_DOWNLOAD" -eq 1 ]; then
        rm -f "$STATE_DIR/downloads_completed" "$STATE_DIR/windows_extracted" "$STATE_DIR/virtio_extracted" \\
              "$STATE_DIR/install_image_inspected" "$STATE_DIR/boot_wim_patched"
    fi

    WINDOWS_ISO_SIZE=$(get_content_length "$WINDOWS_ISO_URL" || echo 0)
    VIRTIO_ISO_SIZE=$(get_content_length "$VIRTIO_ISO_URL" || echo 0)

    local default_windows_iso_size=$((8 * 1024 * 1024 * 1024))
    local default_virtio_iso_size=$((700 * 1024 * 1024))

    if [ "${WINDOWS_ISO_SIZE:-0}" -le 0 ]; then
        echo "WARNING: Windows ISO size unknown; assuming ${default_windows_iso_size} bytes for zram decision."
        WINDOWS_ISO_SIZE=$default_windows_iso_size
    fi
    if [ "${VIRTIO_ISO_SIZE:-0}" -le 0 ]; then
        echo "WARNING: VirtIO ISO size unknown; assuming ${default_virtio_iso_size} bytes for zram decision."
        VIRTIO_ISO_SIZE=$default_virtio_iso_size
    fi

    TOTAL_ISO_SIZE=$((WINDOWS_ISO_SIZE + VIRTIO_ISO_SIZE))
    ZRAM_SIZE_MARGIN_MB=1024
    TOTAL_ISO_SIZE_MB=$((TOTAL_ISO_SIZE / 1024 / 1024 + ZRAM_SIZE_MARGIN_MB))

    local avail_ram_mb
    local safe_ram_mb
    avail_ram_mb=$(get_available_ram_mb)
    safe_ram_mb=$((avail_ram_mb > 512 ? avail_ram_mb - 512 : 0))

    echo "Windows ISO size: ${WINDOWS_ISO_SIZE} bytes"
    echo "VirtIO ISO size: ${VIRTIO_ISO_SIZE} bytes"
    echo "Total ISO size estimate: ${TOTAL_ISO_SIZE} bytes (${TOTAL_ISO_SIZE_MB}MB with margin)"
    echo "Detected available RAM: ${avail_ram_mb}MB, safe zram budget: ${safe_ram_mb}MB"

    if [ "$TOTAL_ISO_SIZE_MB" -gt 0 ] && [ "$TOTAL_ISO_SIZE_MB" -le "$safe_ram_mb" ]; then
        echo "Attempting to use zram for ISO downloads."
        if setup_zram "$TOTAL_ISO_SIZE_MB"; then
            USE_ZRAM=1
            download_dir="/mnt/zram0/windisk"
        else
            echo "WARNING: zram setup failed. Falling back to disk downloads."
            USE_ZRAM=0
            download_dir=$(choose_download_dir)
        fi
    else
        echo "Using disk-based downloads because zram is not feasible."
        USE_ZRAM=0
        download_dir=$(choose_download_dir)
    fi

    mkdir -p "$download_dir"

    windows_iso="$download_dir/Windows.iso"
    virtio_iso="$download_dir/VirtIO.iso"

    if ! checkpoint_done downloads_completed; then
        echo "Downloading Windows ISO to $windows_iso"
        if ! download_file "$WINDOWS_ISO_URL" "$windows_iso"; then
            if [ "${USE_ZRAM:-0}" -eq 1 ]; then
                echo "WARNING: zram download failed, switching to disk fallback."
                cleanup_zram
                USE_ZRAM=0
                download_dir=$(choose_download_dir)
                mkdir -p "$download_dir"
                windows_iso="$download_dir/Windows.iso"
                virtio_iso="$download_dir/VirtIO.iso"
            fi
        fi

        download_file "$WINDOWS_ISO_URL" "$windows_iso"
        download_file "$VIRTIO_ISO_URL" "$virtio_iso"
        checkpoint_set downloads_completed
    fi

    [ -f "$windows_iso" ] || fail "Windows ISO missing after download"
    [ -f "$virtio_iso" ] || fail "VirtIO ISO missing after download"

    WINDOWS_ISO="$windows_iso"
    VIRTIO_ISO="$virtio_iso"

    if [ "${USE_ZRAM:-0}" -eq 1 ]; then
        finalize_zram_downloads
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
'''

if old_prepare not in text:
    raise SystemExit('prepare_windows_media block not found')
text = text.replace(old_prepare, new_prepare, 1)

import re

old_copy_win = re.compile(r"copy_windows_media\(\) \{.*?checkpoint_set windows_extracted\n    trap - RETURN\n\}", re.DOTALL)
new_copy_win = '''copy_windows_media() {
    local iso_path="${1:-$WINDOWS_ISO}"
    local loop_dir
    loop_dir="$(mktemp -d)"
    trap 'mountpoint -q "'""$loop_dir""'" && umount "'""$loop_dir""'" || true; rmdir "'""$loop_dir""'" 2>/dev/null || true' RETURN

    mount -o loop "$iso_path" "$loop_dir"
    rsync -a --info=progress2 --human-readable --stats "$loop_dir"/ "$MNT_INSTALL"/

    [ -f "$MNT_INSTALL/bootmgr" ] || fail "Windows media copy failed: bootmgr missing"
    [ -f "$MNT_INSTALL/sources/boot.wim" ] || fail "Windows media copy failed: boot.wim missing"
    [ -f "$MNT_INSTALL/setup.exe" ] || echo "WARNING: setup.exe missing from copied media"
    [ -f "$MNT_INSTALL/sources/install.wim" ] || [ -f "$MNT_INSTALL/sources/install.esd" ] || fail "install.wim/install.esd missing"

    checkpoint_set windows_extracted
    trap - RETURN
}
'''
if not old_copy_win.search(text):
    raise SystemExit('copy_windows_media block not found')
text = old_copy_win.sub(new_copy_win, text, count=1)

old_copy_virtio = re.compile(r"copy_virtio_media\(\) \{.*?checkpoint_set virtio_extracted\n    trap - RETURN\n\}", re.DOTALL)
new_copy_virtio = '''copy_virtio_media() {
    local iso_path="${1:-$VIRTIO_ISO}"
    local loop_dir
    loop_dir="$(mktemp -d)"
    trap 'mountpoint -q "'""$loop_dir""'" && umount "'""$loop_dir""'" || true; rmdir "'""$loop_dir""'" 2>/dev/null || true' RETURN

    mkdir -p "$MNT_INSTALL/sources/virtio"
    mount -o loop "$iso_path" "$loop_dir"
    rsync -a --info=progress2 --human-readable --stats "$loop_dir"/ "$MNT_INSTALL/sources/virtio"/

    find "$MNT_INSTALL/sources/virtio" -type f | head -n 1 >/dev/null || fail "VirtIO copy failed"
    checkpoint_set virtio_extracted
    trap - RETURN
}
'''
if not old_copy_virtio.search(text):
    raise SystemExit('copy_virtio_media block not found')
text = old_copy_virtio.sub(new_copy_virtio, text, count=1)

path.write_text(text)
print('patched prepare_windows_media and copy functions')
