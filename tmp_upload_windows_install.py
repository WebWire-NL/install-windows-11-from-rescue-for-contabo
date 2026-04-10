from pathlib import Path
import subprocess
import invoke_vps_command as inv

host = '156.67.82.16'
user = 'root'
key = inv.resolve_key_path(None)
ssh = inv.find_ssh_executable()
args = [ssh] + inv.SSH_OPTIONS + ['-i', str(key), f'{user}@{host}', 'bash', '-lc', '--', 'cat > /root/install-windows-11-from-rescue-for-contabo/windows-install.sh && chmod +x /root/install-windows-11-from-rescue-for-contabo/windows-install.sh']
content = Path('windows-install.sh').read_text(encoding='utf-8').replace('\r\n', '\n').encode('utf-8')
print('Uploading', len(content), 'bytes')
completed = subprocess.run(args, input=content)
print('returncode', completed.returncode)
