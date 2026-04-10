# Convert windows-install.sh to Unix (LF) line endings using Python
with open('windows-install.sh', 'rb') as f:
    content = f.read()
# Replace CRLF (\r\n) with LF (\n)
content = content.replace(b'\r\n', b'\n')
with open('windows-install.sh', 'wb') as f:
    f.write(content)
print('windows-install.sh converted to LF line endings.')
