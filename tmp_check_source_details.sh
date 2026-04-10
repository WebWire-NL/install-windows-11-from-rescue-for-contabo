#!/usr/bin/env bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo
set -x
source windows-install.sh
echo 'AFTER_SOURCE'
type -t get_content_length || true
type -t setup_zram || true
