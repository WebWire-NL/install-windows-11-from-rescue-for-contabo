#!/usr/bin/env bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo
grep -n '^get_content_length' windows-install.sh
grep -n '^setup_zram' windows-install.sh
