#!/usr/bin/env bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo
sed -n '390,460p' windows-install.sh
