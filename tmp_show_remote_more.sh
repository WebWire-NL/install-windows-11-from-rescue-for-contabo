#!/usr/bin/env bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo
sed -n '260,390p' windows-install.sh
