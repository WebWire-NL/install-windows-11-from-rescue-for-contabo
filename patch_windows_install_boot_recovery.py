from pathlib import Path

p = Path('windows-install.sh')
lines = p.read_text(encoding='utf-8').splitlines()
old = [
    '    if [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then',
    '        echo "WARNING: $MNT_INSTALL/sources/boot.wim not found. Attempting to recover installer media."',
    '        mount_existing_partitions',
    '        if [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then',
    '            prepare_windows_media',
    '        fi',
    '    fi',
    '',
    '    [ -f "$MNT_INSTALL/sources/boot.wim" ] || { echo "ERROR: boot.wim not found after recovery attempt."; exit 1; }'
]
idx = next(i for i in range(len(lines) - len(old) + 1) if lines[i:i+len(old)] == old)
new = [
    '    if [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then',
    '        echo "WARNING: $MNT_INSTALL/sources/boot.wim not found. Attempting to recover installer media."',
    '        dump_checkpoint_state',
    '        mount_existing_partitions',
    '        if [ ! -f "$MNT_INSTALL/sources/boot.wim" ]; then',
    '            prepare_windows_media',
    '        fi',
    '    fi',
    '',
    '    [ -f "$MNT_INSTALL/sources/boot.wim" ] || {',
    '        echo "ERROR: boot.wim not found after recovery attempt."',
    '        dump_checkpoint_state',
    '        ls -la "$MNT_INSTALL/sources" 2>/dev/null || true',
    '        exit 1',
    '    }'
]
lines[idx:idx+len(old)] = new
p.write_text("\n".join(lines) + "\n", encoding='utf-8')
print('boot recovery patched')
