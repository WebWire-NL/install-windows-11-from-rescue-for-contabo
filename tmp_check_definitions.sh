#!/usr/bin/env bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo
source windows-install.sh
printf 'has_get_content_length=%s\n' "$(type -t get_content_length || true)"
printf 'has_setup_zram=%s\n' "$(type -t setup_zram || true)"
