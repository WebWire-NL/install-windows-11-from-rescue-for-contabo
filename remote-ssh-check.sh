ls -la /root/.ssh 2>/dev/null
echo ---
cat /root/.ssh/authorized_keys 2>/dev/null
echo ---
if [ -f /root/.ssh/authorized_keys ]; then ssh-keygen -lf /root/.ssh/authorized_keys 2>/dev/null; fi
