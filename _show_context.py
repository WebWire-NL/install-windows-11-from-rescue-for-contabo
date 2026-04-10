from pathlib import Path
lines = Path('windows-install.sh').read_text().splitlines()
for i in range(10,25):
    print(f'{i+1}: {lines[i]}')
