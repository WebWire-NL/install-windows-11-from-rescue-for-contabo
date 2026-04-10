#!/usr/bin/env bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo
sed -n '1,120p' windows-install.sh
echo '---'
sed -n '120,260p' windows-install.sh
