#!/bin/bash
set -euo pipefail
set +e
label=$(parted /dev/sda --script print 2>/dev/null | awk -F: '/^Partition Table/ {print $2}' | tr -d '[:space:]')
status=$?
echo EXIT:$status
echo LABEL:$label
