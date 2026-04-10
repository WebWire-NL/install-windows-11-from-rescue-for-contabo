from pathlib import Path
text = Path('windows-install.sh').read_text()
start = text.find('cleanup_on_exit() {')
if start == -1:
    print('NOT FOUND')
else:
    end = text.find('parse_args()', start)
    if end == -1:
        end = start + 200
    print(repr(text[start:end]))
