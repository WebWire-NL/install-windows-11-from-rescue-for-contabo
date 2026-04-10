#!/bin/bash
set -e
cd /root
pwd
if git rev-parse --short HEAD >/dev/null 2>&1; then
  git rev-parse --short HEAD
else
  echo NO_GIT
fi
grep -n 'if \[\[ "\${BASH_SOURCE\[0\]}" == "\$0" \]\]' windows-install.sh || true
