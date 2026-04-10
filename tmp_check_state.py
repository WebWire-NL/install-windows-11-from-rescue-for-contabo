import subprocess

ssh = r"C:\Windows\System32\OpenSSH\ssh.exe"
key = r"C:\Users\Daan\.ssh\vps_deploy_rsa"
host = "root@156.67.82.16"
script = '''set -e
echo --- state dir ---
ls -1 /root/install-windows-11-from-rescue-for-contabo/state 2>/dev/null || true
echo --- has wimlib? ---
command -v wimlib-imagex >/dev/null 2>&1 && echo YES || echo NO
'''
cmd = [ssh, '-i', key, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', host, 'bash', '-s']
proc = subprocess.run(cmd, input=script.encode('utf-8'), capture_output=True)
print(proc.returncode)
print(proc.stdout.decode('utf-8', errors='replace'))
print(proc.stderr.decode('utf-8', errors='replace'))
