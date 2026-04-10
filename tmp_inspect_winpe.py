import subprocess

ssh = r"C:\Windows\System32\OpenSSH\ssh.exe"
key = r"C:\Users\Daan\.ssh\vps_deploy_rsa"
host = "root@156.67.82.16"
script = '''set -e
mount /dev/sda2 /mnt
 echo --- /mnt ---
 ls -la /mnt 2>/dev/null || true
 echo --- /mnt/sources ---
 ls -la /mnt/sources 2>/dev/null || true
 echo --- /mnt/sources/virtio ---
 ls -la /mnt/sources/virtio 2>/dev/null || true
 echo --- file check ---
 for f in /mnt/bootmgr /mnt/sources/boot.wim /mnt/sources/virtio /mnt/Autounattend.xml; do if [ -e "$f" ]; then echo FOUND:$f; else echo MISSING:$f; fi; done
 echo --- startnet in wim? ---
 if command -v wimlib-imagex >/dev/null 2>&1; then
   wimlib-imagex info /mnt/sources/boot.wim | head -n 40
 else
   echo NO_WIMLIB
 fi
 umount /mnt
'''
cmd = [ssh, '-i', key, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', host, 'bash', '-s']
proc = subprocess.run(cmd, input=script.encode('utf-8'), capture_output=True)
print('RC', proc.returncode)
print(proc.stdout.decode('utf-8', errors='replace'))
print(proc.stderr.decode('utf-8', errors='replace'))
