from pathlib import Path

path = Path('/root/install-windows-11-from-rescue-for-contabo/windows-install.sh')
text = path.read_text()
needle = '    find "$MNT_INSTALL/sources/virtio" -type f | head -n 1 >/dev/null || fail "VirtIO copy failed"'
replacement = '    find "$MNT_INSTALL/sources/virtio" -type f -print -quit >/dev/null || fail "VirtIO copy failed"'
if needle not in text:
    raise SystemExit('needle not found')
path.write_text(text.replace(needle, replacement))
print('patched')
