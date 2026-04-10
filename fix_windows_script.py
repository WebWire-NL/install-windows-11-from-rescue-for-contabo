from pathlib import Path
p = Path("install-windows-11-from-rescue-for-contabo/windows-install.sh")
text = p.read_text(encoding="utf-8")
text = text.replace("\r\n", "\n").replace("\r", "\n")
marker = "# Enable strict mode for safer script execution"
insert = """# Parse arguments
NO_PROMPT=0
ISO_URL=""
VIRTIO_ISO_URL=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --no-prompt)
            NO_PROMPT=1
            shift
            ;;
        --iso-url)
            ISO_URL="$2"
            shift 2
            ;;
        --virtio-url)
            VIRTIO_ISO_URL="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$ISO_URL" ]]; then
    if [[ "$NO_PROMPT" -eq 0 ]]; then
        read -p "Enter the URL for Windows.iso: " input_url
        ISO_URL="${input_url:-}"
    fi
fi

if [[ -z "$VIRTIO_ISO_URL" ]]; then
    if [[ "$NO_PROMPT" -eq 0 ]]; then
        read -p "Enter the URL for Virtio.iso (leave blank to use default): " input_virtio
        VIRTIO_ISO_URL="${input_virtio:-}"
    fi
fi

if [[ -z "$ISO_URL" ]]; then
    echo "ERROR: Windows ISO URL is required."
    exit 1
fi

if [[ -z "$VIRTIO_ISO_URL" ]]; then
    VIRTIO_ISO_URL="$DEFAULT_VIRTIO_ISO_URL"
fi

echo "Using Windows ISO URL: $ISO_URL"
echo "Using VirtIO ISO URL: $VIRTIO_ISO_URL"
"""
if 'while [[ "$#" -gt 0 ]]; do' not in text:
    text = text.replace(marker, insert + "\n\n" + marker, 1)
    legacy = 'DEFAULT_WINDOWS_ISO_URL="https://example.com/windows.iso"\n\n# Prompt user for URL or use default\nread -p "Enter the URL for Windows.iso (leave blank to use default): " windows_url\nwindows_url=${windows_url:-$DEFAULT_WINDOWS_ISO_URL}\n\n# Create a temporary swap file for low-memory environments\n'
    if legacy in text:
        text = text.replace(legacy, '# Create a temporary swap file for low-memory environments\n')
    text = text.replace('WINDOWS_ISO_URL="$windows_url"\nVIRTIO_ISO_URL="$virtio_url"\n', 'WINDOWS_ISO_URL="$ISO_URL"\nVIRTIO_ISO_URL="$VIRTIO_ISO_URL"\n')
    p.write_text(text, encoding="utf-8", newline="\n")
    print("patched")
else:
    p.write_text(text, encoding="utf-8", newline="\n")
    print("normalized only")
