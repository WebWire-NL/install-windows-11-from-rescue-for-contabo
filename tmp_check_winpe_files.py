import subprocess

ssh = r"C:\Windows\System32\OpenSSH\ssh.exe"
key = r"C:\Users\Daan\.ssh\vps_deploy_rsa"
host = "root@156.67.82.16"
script = '''set -e
for p in /mnt/bootmgr /mnt/sources/boot.wim /mnt/sources/virtio /mnt/Autounattend.xml /mnt/sources/virtio/vioscsi/w11/amd64/vioscsi.inf /mnt/sources/virtio/viostor/w11/amd64/viostor.inf; do
  if [ -e "$p" ]; then echo FOUND:$p; else echo MISSING:$p; fi
done
if [ -f /mnt/Autounattend.xml ]; then echo AUTOUNATTEND_OK; fi
if command -v wimlib-imagex >/dev/null 2>&1; then
  wimlib-imagex info /mnt/sources/boot.wim | grep -E '^[[:space:]]*(Image|Index|Name|Description|Size)' | head -n 20
else
  echo NO_WIMLIB
fi
'''
cmd = [ssh, '-i', key, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', host, 'bash', '-s']
proc = subprocess.run(cmd, input=script.encode('utf-8'), capture_output=True)
print(proc.returncode)
print(proc.stdout.decode('utf-8', errors='replace'))
print(proc.stderr.decode('utf-8', errors='replace'))
