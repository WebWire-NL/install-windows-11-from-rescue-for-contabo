#!/bin/bash
set -e
cd /mnt

URL="https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=9b44bc26-4bf0-474e-963f-1796cd6a8c33&P1=1775499486&P2=601&P3=2&P4=Gb73mWwBfDwJfQzPKXUjOLuE4sq%2bJWCcs71bMBaRbIdEynbv0jZL%2f0WC%2bg6Fjq9ex3wjTcSXYABnKlFiilffsHa3inuR9gD3o2hNQL2hfLUDBkE3OegAgu%2fJ9cMniiQheWUZvWYKvJt%2fCkAjB%2ftg57XIK1PhIIZ6hfvhlSj67VlIZbVFRMfiw4yCdQhG6WVfen2k0jIOIELD05rF%2b8MK5c8oAVk%2fbwgOJb17yBZ9V5qOaqYvOWu49%2f5JItaqFhfk%2f%2fhP%2fymQqjy2IdCELOVkxeatMjHVBIbzXkz%2ba1TFc6lPJFIxFfVcNICwJv4WxrLctsfkpcF1ehA8WaxA%2bCw%3d%3d"
ISO_FILE="/mnt/test-win11.iso"
ISO_BASE=$(basename "$ISO_FILE")
SESSION_FILE="${ISO_FILE}.aria2"
LOG="/mnt/aria2-resume.log"

if pgrep -f "aria2c .*--dir=/mnt .*--out=${ISO_BASE}" >/dev/null 2>&1; then
  echo "[WARN] Found existing aria2 process for $ISO_BASE; killing stale process."
  pgrep -f "aria2c .*--dir=/mnt .*--out=${ISO_BASE}" | xargs -r kill
  sleep 5
fi

touch "$SESSION_FILE" "$LOG"

aria2c --continue=true --file-allocation=none --enable-http-keep-alive=true \
  --max-connection-per-server=4 --split=8 --min-split-size=4M \
  --max-tries=10 --retry-wait=15 --timeout=60 \
  --summary-interval=10 --console-log-level=warn \
  --log="$LOG" --save-session="$SESSION_FILE" --save-session-interval=30 \
  --dir=/mnt --out="$ISO_BASE" "$URL"
