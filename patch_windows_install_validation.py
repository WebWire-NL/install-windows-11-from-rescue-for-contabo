from pathlib import Path

p = Path('windows-install.sh')
lines = p.read_text(encoding='utf-8').splitlines()

# Patch copy_windows_media validation
old = [
    '    mount -o loop "$iso" "$loop_dir"',
    '    rsync -a --info=progress2 --human-readable --stats "$loop_dir"/ "$MNT_INSTALL"/',
    '    checkpoint_set windows_extracted',
    '}'
]
idx = next(i for i in range(len(lines) - len(old) + 1) if lines[i:i+len(old)] == old)
new = [
    '    mount -o loop "$iso" "$loop_dir"',
    '    rsync -a --info=progress2 --human-readable --stats "$loop_dir"/ "$MNT_INSTALL"/',
    '    if [ ! -f "$MNT_INSTALL/bootmgr" ] || [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then',
    '        echo "ERROR: Windows ISO extraction failed; $MNT_INSTALL/bootmgr or $MNT_INSTALL/sources/boot.wim is missing after rsync."',
    '        dump_checkpoint_state',
    '        exit 1',
    '    fi',
    '    checkpoint_set windows_extracted',
    '}'
]
lines[idx:idx+len(old)] = new

# Patch copy_virtio_media validation
old = [
    '    mkdir -p "$MNT_INSTALL/sources/virtio"',
    '    mount -o loop "$iso" "$loop_dir"',
    '    rsync -a --info=progress2 --human-readable --stats "$loop_dir"/ "$MNT_INSTALL/sources/virtio"/',
    '    checkpoint_set virtio_extracted',
    '}'
]
idx = next(i for i in range(len(lines) - len(old) + 1) if lines[i:i+len(old)] == old)
new = [
    '    mkdir -p "$MNT_INSTALL/sources/virtio"',
    '    mount -o loop "$iso" "$loop_dir"',
    '    rsync -a --info=progress2 --human-readable --stats "$loop_dir"/ "$MNT_INSTALL/sources/virtio"/',
    '    if [ -z "$(find \"$MNT_INSTALL/sources/virtio\" -type f 2>/dev/null | head -n 1)" ]; then',
    '        echo "ERROR: VirtIO extraction failed; no files found under $MNT_INSTALL/sources/virtio."',
    '        dump_checkpoint_state',
    '        exit 1',
    '    fi',
    '    checkpoint_set virtio_extracted',
    '}'
]
lines[idx:idx+len(old)] = new

p.write_text("\n".join(lines) + "\n", encoding='utf-8')
print('validation patched')
