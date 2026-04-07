#!/bin/bash
ps -ef | grep aria2c | grep -v grep || true
echo ---
stat -c "%s %n" /root/test-win11.iso /root/aria2-download.log 2>/dev/null || true
echo ---
grep -E "resume|Resuming|Continue|continue" /root/aria2-download.log | tail -n 20 || true
echo ---
tail -n 20 /root/aria2-download.log