from pathlib import Path
text = Path('windows-install.sh').read_text()
start = text.index('if command_exists sgdisk; then')
print(repr(text[start:start+400]))
