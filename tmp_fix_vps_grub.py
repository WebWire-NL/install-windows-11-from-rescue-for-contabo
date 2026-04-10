import subprocess
import sys

ssh = r"C:\Windows\System32\OpenSSH\ssh.exe"
key = r"C:\Users\Daan\.ssh\vps_deploy_rsa"
host = "root@156.67.82.16"

script = r"""set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y grub-pc
mkdir -p /mnt
umount /mnt 2>/dev/null || true
mount /dev/sda2 /mnt
mkdir -p /mnt/boot/grub
cat > /mnt/boot/grub/grub.cfg <<'EOF'
set timeout=10
set default=0
menuentry "Windows Installer (BIOS)" {
  insmod part_msdos
  insmod ntfs
  set root=(hd0,msdos2)
  ntldr /bootmgr
}
EOF
grub-install --target=i386-pc --boot-directory=/mnt/boot /dev/sda
echo GRUB_INSTALL_OK
umount /mnt
"""

cmd = [ssh, '-i', key, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', host, 'bash', '-s']
print('Running:', ' '.join(cmd), file=sys.stderr)
proc = subprocess.run(cmd, input=script, text=True, capture_output=True)
print('RC', proc.returncode)
print(proc.stdout)
print(proc.stderr, file=sys.stderr)
if proc.returncode != 0:
    print("Error: GRUB installation failed.", file=sys.stderr)
    raise SystemExit(proc.returncode)
