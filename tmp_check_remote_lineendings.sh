#!/bin/bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo
echo "PWD=$(pwd)"
head -5 windows-install.sh | cat -A
python3 - <<'PY'
from pathlib import Path
import sys
p=Path('windows-install.sh')
with p.open('rb') as f:
    data=f.read(100)
print(data)
print('CR' in data)
print('LF' in data)
print('\r\n' in data)
PY
