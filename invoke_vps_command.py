#!/usr/bin/env python3
import argparse
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

DEFAULT_HOST = '156.67.82.16'
DEFAULT_KEY = Path.home() / '.ssh' / 'vps_deploy_rsa'
FALLBACK_KEYS = [
    Path.home() / '.ssh' / 'contabo_key',
    Path.home() / '.ssh' / 'id_ed25519',
    Path.home() / '.ssh' / 'id_rsa',
]

SSH_OPTIONS = [
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'PreferredAuthentications=publickey',
    '-o', 'PubkeyAuthentication=yes',
    '-o', 'IdentitiesOnly=yes',
]


def normalize_script_text(script_text: str) -> str:
    normalized = script_text.replace('\r\n', '\n').replace('\r', '\n')
    if not normalized.endswith('\n'):
        normalized += '\n'
    return normalized


def find_ssh_executable() -> str:
    ssh_path = shutil.which('ssh')
    if ssh_path:
        return ssh_path

    if os.name == 'nt':
        windows_paths = [
            Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32' / 'OpenSSH' / 'ssh.exe',
            Path(os.environ.get('ProgramFiles', r'C:\Program Files')) / 'Git' / 'usr' / 'bin' / 'ssh.exe',
        ]
        for candidate in windows_paths:
            if candidate.exists():
                return str(candidate)

    raise FileNotFoundError(
        'ssh command not found. Install OpenSSH client or use a shell that provides ssh.'
    )


def resolve_key_path(key_path: Optional[str]) -> Path:
    if key_path:
        candidate = Path(key_path).expanduser()
        if candidate.exists():
            return candidate
        raise FileNotFoundError(f'SSH key not found: {candidate}')

    if DEFAULT_KEY.exists():
        return DEFAULT_KEY

    for candidate in FALLBACK_KEYS:
        if candidate.exists():
            return candidate

    fallback_names = ', '.join(str(path) for path in [DEFAULT_KEY] + FALLBACK_KEYS)
    raise FileNotFoundError(
        f'No SSH key found. Expected one of: {fallback_names}.'
    )


def build_ssh_args(host: str, user: str, key: Path, port: int, remote_command: Optional[str], local_script: bool) -> List[str]:
    args = [find_ssh_executable()] + SSH_OPTIONS
    if port != 22:
        args += ['-p', str(port)]
    args += ['-i', str(key)]
    args += [f'{user}@{host}']

    if local_script:
        args += ['bash', '-s', '--']
    else:
        if remote_command is None:
            raise ValueError('remote_command is required for remote execution')
        args += ['bash', '-lc', '--', remote_command]
    return args


def run_remote_command(host: str, user: str, key: Path, port: int, remote_command: str, debug: bool = False) -> int:
    args = build_ssh_args(host, user, key, port, remote_command, local_script=False)
    if debug:
        print(f'Running remote command on {user}@{host}')
        print('SSH command:', ' '.join(shlex.quote(arg) for arg in args))
    completed = subprocess.run(args)
    return completed.returncode


def run_local_script(host: str, user: str, key: Path, port: int, local_script_path: str, debug: bool = False) -> int:
    script_path = Path(local_script_path).expanduser()
    if not script_path.is_file():
        raise FileNotFoundError(f'Local script not found: {script_path}')

    content = script_path.read_text(encoding='utf-8')
    content = normalize_script_text(content)

    args = build_ssh_args(host, user, key, port, remote_command=None, local_script=True)
    if debug:
        print(f'Running local script "{script_path}" on {user}@{host}')
        print('SSH command:', ' '.join(shlex.quote(arg) for arg in args))
    completed = subprocess.run(args, input=content.encode('utf-8'), text=False)
    return completed.returncode


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Run a remote command or local script on the VPS via SSH.'
    )
    parser.add_argument('--host', default=DEFAULT_HOST, help='Remote host or IP address.')
    parser.add_argument('--user', default='root', help='Remote SSH user.')
    parser.add_argument('--key', default=None, help='SSH private key path.')
    parser.add_argument('--port', type=int, default=22, help='SSH port.')

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--remote-command', help='Remote shell command to execute.')
    group.add_argument('--local-script', help='Local script file to pipe to remote bash.')

    parser.add_argument('--debug', action='store_true', help='Print resolved SSH command and arguments.')
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        key_path = resolve_key_path(args.key)
    except FileNotFoundError as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 2

    try:
        _ = find_ssh_executable()
    except FileNotFoundError as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 3

    try:
        if args.remote_command:
            rc = run_remote_command(args.host, args.user, key_path, args.port, args.remote_command, debug=args.debug)
        else:
            rc = run_local_script(args.host, args.user, key_path, args.port, args.local_script, debug=args.debug)
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 4

    if rc != 0:
        print(f'Remote SSH command exited with code {rc}', file=sys.stderr)
    return rc


if __name__ == '__main__':
    sys.exit(main())
