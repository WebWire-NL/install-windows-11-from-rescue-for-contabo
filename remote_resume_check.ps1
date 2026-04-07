$script = @'
#!/bin/bash
ps -ef | grep aria2c | grep -v grep || true
echo ---
stat -c "%s %n" /root/test-win11.iso /root/aria2-download.log 2>/dev/null || true
echo ---
grep -E "resume|Resuming|Continue|continue" /root/aria2-download.log | tail -n 20 || true
echo ---
tail -n 20 /root/aria2-download.log
'@
$script | Set-Content -Path "D:\projects\contabo-script\check_resume.sh" -NoNewline
scp -i "C:\Users\Daan\.ssh\id_ed25519_vps" "D:\projects\contabo-script\check_resume.sh" root@156.67.82.16:/root/check_resume.sh
ssh -i "C:\Users\Daan\.ssh\id_ed25519_vps" root@156.67.82.16 "bash /root/check_resume.sh"
