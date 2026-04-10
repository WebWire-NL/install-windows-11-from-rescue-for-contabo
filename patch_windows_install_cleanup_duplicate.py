from pathlib import Path

p = Path('windows-install.sh')
lines = p.read_text(encoding='utf-8').splitlines()
pattern = [
    'dump_checkpoint_state() {',
    '    echo "=== checkpoint state ==="',
    '    for cp in partitions windows_extracted virtio_extracted boot_wim_patched bypass_ready grub_cfg grub_installed; do',
    '        if checkpoint_done "$cp"; then',
    '            echo "$cp: set"',
    '        else',
    '            echo "$cp: missing"',
    '        fi',
    '    done',
    '    echo "=== installer file state ==="',
    '    for file in "$MNT_INSTALL/bootmgr" "$MNT_INSTALL/sources/boot.wim" "$MNT_INSTALL/sources/virtio/NetKVM/2k3/amd64/netkvm.sys"; do',
    '        if [ -e "$file" ]; then',
    '            echo "$file: present"',
    '        else',
    '            echo "$file: missing"',
    '        fi',
    '    done',
    '}'
]
idxs = [i for i in range(len(lines)-len(pattern)+1) if lines[i:i+len(pattern)] == pattern]
if len(idxs) < 2:
    raise SystemExit('Duplicate helper block not found')
del lines[idxs[1]:idxs[1]+len(pattern)]
p.write_text("\n".join(lines)+"\n", encoding='utf-8')
print('duplicate helper removed')
