from pathlib import Path
lines = Path('windows-install.sh').read_text().splitlines()
for i in range(270, 291):
    if i <= len(lines):
        print(i, lines[i-1])
