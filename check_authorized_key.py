#!/usr/bin/env python3
import paramiko

host = '156.67.82.16'
user = 'root'
password = 'Appels99'
pubkey_path = r'C:\Users\Daan\.ssh\contabo_key.pub'

with open(pubkey_path, 'r', encoding='utf-8') as f:
    pubkey = f.read().strip()

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(hostname=host, username=user, password=password, look_for_keys=False, allow_agent=False, timeout=20)

try:
    sftp = client.open_sftp()
    try:
        attrs = sftp.stat('/root/.ssh/authorized_keys')
        print('authorized_keys exists')
        print('mode:', oct(attrs.st_mode & 0o777))
    except IOError as e:
        print('authorized_keys missing', e)
        raise SystemExit(0)

    with sftp.open('/root/.ssh/authorized_keys', 'r') as f:
        lines = [line.strip() for line in f if line.strip()]

    found = any(line == pubkey for line in lines)
    print('public key present:', found)
    if not found:
        print('authorized_keys contents:')
        for i, line in enumerate(lines[:20], 1):
            print(f'{i}: {line[:120]}')
finally:
    client.close()
