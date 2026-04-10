import io 
path='windows-install.sh' 
text=open(path,'rb').read() 
old=b'command_exists() {\r\n    command -v \\" "\ \r\n}\r\n\r\npackage_for_command() {\r\n' 
new=b'command_exists() {\r\n    command -v \\ \r\n}\r\n\r\nrefresh_partition_table() {\r\n    echo \Refreshing" kernel partition table for  "...\\r\n    if command_exists partprobe; then\r\n        partprobe \\ ; true\r\n    fi\r\n    if command_exists blockdev; then\r\n        blockdev --rereadpt \\ ; true\r\n    fi\r\n    if command_exists partx; then\r\n        partx -u \\ ; true\r\n    fi\r\n    if command_exists udevadm; then\r\n        udevadm settle --timeout=10 ; true\r\n    fi\r\n    sleep 3\r\n}\r\n\r\npackage_for_command() {\r\n' ; echo if old not in text: ; echo     raise SystemExit('pattern not found') ; echo text=text.replace(old,new,1) ; echo open(path,'wb').write(text) ; echo print('patched') ; python patch.py ; del patch.py
