#!/usr/bin/env bash
set -e

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <windows-iso-url>"
  exit 1
fi
WINDOWS_ISO_URL="$1"
VIRTIO_ISO_URL="https://bit.ly/4d1g7Ht"

cd /root/install-windows-11-from-rescue-for-contabo

echo "Updating remote repo to origin/master..."
git fetch origin

git reset --hard origin/master

echo "Starting full install in background..."
nohup bash windows-install.sh --no-prompt --force-download \
  --iso-url "$WINDOWS_ISO_URL" \
  --virtio-url "$VIRTIO_ISO_URL" \
  > /root/install-windows-11.log 2>&1 &

PID=$!
echo "PID:$PID"
echo "LOG:/root/install-windows-11.log"
