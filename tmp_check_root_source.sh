findmnt -n -o SOURCE / || df --output=source / 2>/dev/null | tail -n1
