#!/usr/bin/env bash
cd /root/install-windows-11-from-rescue-for-contabo
python3 - <<'PY'
from pathlib import Path
p = Path('windows-install.sh')
text = p.read_text()
print('contains_cr', '\r' in text)
print('first_200', repr(text[:200]))
PY
