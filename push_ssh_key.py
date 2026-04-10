#!/usr/bin/env python3
import os
import sys
import stat
import paramiko


def usage():
    print("Usage: push_ssh_key.py <host> <user> <password> <local_pubkey_path>")
    sys.exit(1)


def main():
    if len(sys.argv) != 5:
        usage()

    host = sys.argv[1]
    user = sys.argv[2]
    password = sys.argv[3]
    pubkey_path = sys.argv[4]

    if not os.path.isfile(pubkey_path):
        print(f"Public key file not found: {pubkey_path}")
        sys.exit(1)

    pubkey = open(pubkey_path, 'r', encoding='utf-8').read().strip()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        client.connect(hostname=host, username=user, password=password, look_for_keys=False, allow_agent=False)
    except Exception as exc:
        print(f"SSH connection failed: {exc}")
        sys.exit(1)

    try:
        sftp = client.open_sftp()
        ssh_dir = '/root/.ssh'
        auth_path = '/root/.ssh/authorized_keys'

        try:
            sftp.stat(ssh_dir)
        except IOError:
            sftp.mkdir(ssh_dir, mode=0o700)

        try:
            with sftp.open(auth_path, 'r') as f:
                data = f.read()
                if isinstance(data, bytes):
                    data = data.decode('utf-8')
                existing = data.splitlines()
        except IOError:
            existing = []

        if pubkey in existing:
            print('Public key already present in authorized_keys')
        else:
            existing.append(pubkey)
            with sftp.open(auth_path, 'w') as f:
                if isinstance(existing[0], bytes):
                    existing = [line.decode('utf-8') if isinstance(line, bytes) else line for line in existing]
                f.write('\n'.join(existing) + '\n')
            sftp.chmod(auth_path, 0o600)
            print('Added public key to authorized_keys')
    finally:
        client.close()


if __name__ == '__main__':
    main()
