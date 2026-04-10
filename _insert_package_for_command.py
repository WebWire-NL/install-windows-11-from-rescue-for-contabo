from pathlib import Path
path = Path('windows-install.sh')
text = path.read_text()
old = 'command_exists() { command -v "'$1'" >/dev/null 2>&1; }\n\nrequire_root() {\n'
# Because of quoting issues, just find the command_exists line and insert after it.
needle = 'command_exists() { command -v "'$1'" >/dev/null 2>&1; }'
idx = text.find(needle)
if idx == -1:
    raise SystemExit('needle not found')
insert = '''command_exists() { command -v "$1" >/dev/null 2>&1; }\n\npackage_for_command() {\n    case "$1" in\n        mkfs.ntfs) echo ntfs-3g ;;\n        mkfs.ext4) echo e2fsprogs ;;\n        grub-install) echo grub-pc ;;\n        grub-probe) echo grub-pc ;;\n        curl) echo curl ;;\n        rsync) echo rsync ;;\n        pgrep) echo procps ;;\n        awk) echo gawk ;;\n        xargs) echo findutils ;;\n        grep) echo grep ;;\n        mount|blockdev|partx|fdisk) echo util-linux ;;\n        dpkg-deb) echo dpkg ;;\n        modprobe) echo kmod ;;\n        partprobe|parted) echo parted ;;\n        wimlib-imagex) echo wimtools ;;\n        aria2c) echo aria2 ;;\n        wget) echo wget ;;\n        *) echo \"\" ;;\n    esac\n}\n\n'''
# Replace first occurrence of needle + newline with insert.
start = idx
end = idx + len(needle)
if text[end:end+2] == '\r\n':
    end += 2
elif text[end:end+1] == '\n':
    end += 1
text = text[:start] + insert + text[start:]
path.write_text(text)
print('inserted package_for_command')
