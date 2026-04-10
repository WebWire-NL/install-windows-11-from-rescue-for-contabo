#!/usr/bin/env bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo
echo 'REMOTE WC LINES:'
wc -l windows-install.sh
echo 'HEAD:'
head -20 windows-install.sh
echo 'TAIL:'
tail -20 windows-install.sh
