from pathlib import Path
text = Path('windows-install.sh').read_text()
old = '''    if command_exists sgdisk; then
        echo "Wiping existing partition table on ${TARGET_DISK}..."
        sgdisk --zap-all "${TARGET_DISK}" || true
    fi
    if command_exists wipefs; then
        echo "Wiping filesystem signatures on ${TARGET_DISK}..."
        wipefs -a "${TARGET_DISK}" || true
    fi
    cleanup_partition_state
'''
print(len(old))
print(text.count(old))
print('exists' if old in text else 'not exists')
