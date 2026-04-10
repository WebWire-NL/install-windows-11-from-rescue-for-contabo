#!/bin/bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo
source windows-install.sh
export NO_PROMPT=1
export FORCE_DOWNLOAD=1
export WINDOWS_ISO_URL="${WINDOWS_ISO_URL:-$DEFAULT_WINDOWS_ISO_URL}"
export VIRTIO_ISO_URL="${VIRTIO_ISO_URL:-$DEFAULT_VIRTIO_ISO_URL}"
echo "DEFAULT_WINDOWS_ISO_URL=$DEFAULT_WINDOWS_ISO_URL"
echo "WINDOWS_ISO_URL=$WINDOWS_ISO_URL"
echo "VIRTIO_ISO_URL=$VIRTIO_ISO_URL"
echo "PROMPT_WINDOWS=$(prompt_value \"$WINDOWS_ISO_URL\" \"Enter Windows ISO URL:\")"
echo "PROMPT_VIRTIO=$(prompt_value \"$VIRTIO_ISO_URL\" \"Enter VirtIO ISO URL [default]: \")"
