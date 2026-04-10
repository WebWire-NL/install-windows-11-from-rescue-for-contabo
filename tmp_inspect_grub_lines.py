from pathlib import Path
text = Path('windows-install.sh').read_text()
for i, line in enumerate(text.splitlines(), 1):
    if 'grub.cfg' in line or "menuentry 'Windows Installer (BIOS)'" in line or 'grub-install --target' in line:
        print(i, line)
