#!/usr/bin/env python3
import paramiko

host = '156.67.82.16'
user = 'root'
password = 'Appels99'

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(hostname=host, username=user, password=password, look_for_keys=False, allow_agent=False, timeout=20)
try:
    sftp = client.open_sftp()
    with sftp.open('/root/.ssh/authorized_keys', 'rb') as f:
        data = f.read()
    print('raw bytes length:', len(data))
    print(repr(data[:512]))
    print('---- end ----')
finally:
    client.close()
