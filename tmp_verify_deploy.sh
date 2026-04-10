#!/bin/bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo
pwd
ls -la windows-install.sh
grep -n 'if \[\[ "\${BASH_SOURCE\[0\]}" == "\$0" \]\]' windows-install.sh || true
