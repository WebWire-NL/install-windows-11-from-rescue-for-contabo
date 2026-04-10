#!/usr/bin/env bash
set -ex
cd /root/install-windows-11-from-rescue-for-contabo
source windows-install.sh
declare -F | grep get_content_length || true
declare -F | grep setup_zram || true
