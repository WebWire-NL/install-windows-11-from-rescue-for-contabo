import paramiko

host = '156.67.82.16'
user = 'root'
key = r'C:\Users\Daan\.ssh\contabo_key'
cmd = '''cd /root/install-windows-11-from-rescue-for-contabo
bash -n windows-install.sh && echo SYNTAX_OK
if [ -d /sys/firmware/efi ]; then echo FIRMWARE:uefi; else echo FIRMWARE:bios; fi
disk_label=$(parted /dev/sda --script print | awk -F: '/^Partition Table/ {print $2}' | tr -d '[:space:]')
echo DISK_LABEL:$disk_label
if [ "$disk_label" = "gpt" ] && parted /dev/sda --script print | grep -q bios_grub; then echo BIOS_GRUB:found; else echo BIOS_GRUB:missing; fi
'''

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect(hostname=host, username=user, key_filename=key)
stdin, stdout, stderr = ssh.exec_command(cmd)
print('STDOUT---')
print(stdout.read().decode('utf-8', errors='replace'))
print('STDERR---')
print(stderr.read().decode('utf-8', errors='replace'))
ssh.close()
