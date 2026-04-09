#!/bin/bash
if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <windows-iso-url>"
    exit 1
fi
WINDOWS_ISO_URL="$1"
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

pkill -f windows-install.sh || true
cd /root/install-windows-11-from-rescue-for-contabo
rm -rf /root/windisk-download /root/install-windows-run.log
nohup bash -x windows-install.sh --no-prompt --force-download \
  --iso-url "$WINDOWS_ISO_URL" \
  --virtio-url "$VIRTIO_ISO_URL" \
  > /root/install-windows-run.log 2>&1 < /dev/null &
echo RUNNING
