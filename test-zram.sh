#!/usr/bin/env bash
set -euo pipefail

ZRAM_DEV="/dev/zram0"
MOUNT_POINT="/mnt/zram-test"
RESERVE_MB=512
ACTION="run"
KEEP_MOUNTED=0
DEFAULT_WINDOWS_ISO_URL="https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=9dd36437-8c53-4d86-80dc-29db90a63505&P1=1775719369&P2=601&P3=2&P4=fizoXRjVOXdAMg6a1PRgNIZMO8eeYkphp0nfA4VZxRwRnoitaEjdNb%2fu%2bEjZhVHU5khibrqnmy5ILZ8UhgR2B9MNohSfvcTBciTTZFNmwkV3%2bmcGjh9rti%2bdQv8d4XTZafuF1VBHfgn1tRGz8TTn%2foFRphlIU1rqnxpOMnbLGIqif%2bVMdnnXYLJkCx8bSKp3DevtHVE1rc%2fF5V3OXvXtZ0NWsUNW97OrTTXZQYyOFNpLtZoUKspcdJLktl4cu2axBhYFaWWh%2fYTCQy8IE%2fgFapNMea7KgfYIinsF338Xyy2iutI2bYa555qx1gzLXO30pV1dq7E%2bKlaPmh1YgCR7xQ%3d%3d"
DEFAULT_VIRTIO_ISO_URL="https://bit.ly/4d1g7Ht"
WINDOWS_ISO_URL="${DEFAULT_WINDOWS_ISO_URL}"
VIRTIO_ISO_URL="${DEFAULT_VIRTIO_ISO_URL}"
WINDOWS_ISO_PATH=""
VIRTIO_ISO_PATH=""

usage() {
    cat <<'EOF'
Usage: bash test-zram.sh [options]

Options:
  --windows-iso-url URL      Windows ISO URL to use for size estimation
                             (default: original Windows 11 URL)
  --virtio-iso-url URL       VirtIO ISO URL to use for size estimation
                             (default: https://bit.ly/4d1g7Ht)
  --windows-iso-path PATH    Local Windows ISO path to use for size estimation
  --virtio-iso-path PATH     Local VirtIO ISO path to use for size estimation
  --reserve-mb N             Reserve N MB of RAM for the system (default 512)
  --load-only                Only configure and mount zram, do not unload it
  --unload-only              Only unmount and reset zram
  --keep-mounted             Keep the zram filesystem mounted after a successful test
  --help                     Show this help message
EOF
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_cmd() {
    if ! command_exists "$1"; then
        echo "ERROR: required command '$1' is not available."
        exit 1
    fi
}

get_http_content_length() {
    local url="$1"
    if command_exists curl; then
        curl -fsSLI --max-redirs 10 "$url" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1
    elif command_exists wget; then
        wget --spider --max-redirect=10 "$url" 2>&1 | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1
    else
        echo ""
    fi
}

get_file_size() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo ""
        return 1
    fi
    if command_exists stat; then
        stat --format='%s' "$file"
    else
        wc -c <"$file" | tr -d ' '
    fi
}

prompt_input() {
    local prompt="$1"
    local value=""
    if [[ -t 0 ]]; then
        read -r -p "$prompt" value
    fi
    echo "$value"
}

set_iso_source() {
    local input="$1"
    if [[ -z "$input" ]]; then
        echo ""
        return
    fi
    if [[ "$input" =~ ^https?:// ]]; then
        echo "url:$input"
    else
        echo "path:$input"
    fi
}

iso_size_bytes() {
    local value="$1"
    if [[ "$value" =~ ^https?:// ]]; then
        local length
        length=$(get_http_content_length "$value")
        if [[ -z "$length" ]]; then
            echo "ERROR: Unable to determine content-length for $value" >&2
            exit 1
        fi
        echo "$length"
    else
        if [[ -n "$value" ]]; then
            local size
            size=$(get_file_size "$value")
            if [[ -z "$size" ]]; then
                echo "ERROR: File not found: $value" >&2
                exit 1
            fi
            echo "$size"
        else
            echo "0"
        fi
    fi
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --windows-iso-url)
                WINDOWS_ISO_URL="$2"
                shift 2
                ;;
            --virtio-iso-url)
                VIRTIO_ISO_URL="$2"
                shift 2
                ;;
            --windows-iso-path)
                WINDOWS_ISO_PATH="$2"
                shift 2
                ;;
            --virtio-iso-path)
                VIRTIO_ISO_PATH="$2"
                shift 2
                ;;
            --reserve-mb)
                RESERVE_MB="$2"
                shift 2
                ;;
            --load-only)
                ACTION="load-only"
                shift
                ;;
            --unload-only)
                ACTION="unload-only"
                shift
                ;;
            --keep-mounted)
                KEEP_MOUNTED=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "ERROR: Unknown argument: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
}

query_for_missing_iso_inputs() {
    if [[ -z "$WINDOWS_ISO_URL" && -z "$WINDOWS_ISO_PATH" ]]; then
        local input
        input=$(prompt_input "Enter Windows ISO URL or local path: ")
        if [[ -n "$input" ]]; then
            local parsed
            parsed=$(set_iso_source "$input")
            if [[ "$parsed" == url:* ]]; then
                WINDOWS_ISO_URL="${parsed#url:}"
            else
                WINDOWS_ISO_PATH="${parsed#path:}"
            fi
        fi
    fi

    if [[ -z "$VIRTIO_ISO_URL" && -z "$VIRTIO_ISO_PATH" ]]; then
        local input
        input=$(prompt_input "Enter VirtIO ISO URL or local path: ")
        if [[ -n "$input" ]]; then
            local parsed
            parsed=$(set_iso_source "$input")
            if [[ "$parsed" == url:* ]]; then
                VIRTIO_ISO_URL="${parsed#url:}"
            else
                VIRTIO_ISO_PATH="${parsed#path:}"
            fi
        fi
    fi
}

print_header() {
    echo "=== zram test script ==="
    echo "ZRAM device: $ZRAM_DEV"
    echo "Mount point: $MOUNT_POINT"
    echo "Reserve RAM: ${RESERVE_MB}MB"
    echo "Action: $ACTION"
    echo ""
}

print_zram_state() {
    echo "zram state:"
    lsmod | grep -i zram || true
    if [[ -e "$ZRAM_DEV" ]]; then
        echo "  device: $ZRAM_DEV"
        echo "  disksize: $(cat /sys/block/zram0/disksize 2>/dev/null || echo N/A)"
        echo "  comp_algorithm: $(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo N/A)"
        echo "  state: $(cat /sys/block/zram0/state 2>/dev/null || echo N/A)"
    else
        echo "  device not present"
    fi
    echo ""
}

cleanup_zram() {
    if ! mountpoint -q "$MOUNT_POINT" && [[ ! -e "$ZRAM_DEV" ]]; then
        echo "No zram device or mountpoint detected; skipping unload."
        return 0
    fi

    if mountpoint -q "$MOUNT_POINT"; then
        echo "Unmounting $MOUNT_POINT"
        umount "$MOUNT_POINT" || true
    fi
    if [[ -e "$ZRAM_DEV" ]]; then
        echo "Resetting $ZRAM_DEV"
        swapoff "$ZRAM_DEV" >/dev/null 2>&1 || true
        echo 1 > /sys/block/zram0/reset || true
    fi
    if [[ -d "$MOUNT_POINT" ]]; then
        rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
}

configure_zram() {
    local total_mb="$1"
    echo "Configuring zram for ${total_mb}MB..."
    require_cmd modprobe
    require_cmd mkfs.ext4
    require_cmd mount
    require_cmd umount

    modprobe zram >/dev/null 2>&1 || true
    if [[ ! -e "$ZRAM_DEV" ]]; then
        echo "ERROR: $ZRAM_DEV is not present after modprobe." >&2
        return 1
    fi

    swapoff "$ZRAM_DEV" >/dev/null 2>&1 || true
    echo 1 > /sys/block/zram0/reset || true

    local comp="zstd"
    if ! echo "$comp" > /sys/block/zram0/comp_algorithm 2>/dev/null; then
        echo "zstd not supported, falling back to lz4"
        comp="lz4"
        echo "$comp" > /sys/block/zram0/comp_algorithm 2>/dev/null
    fi
    echo "Using zram compression: $comp"

    echo "${total_mb}M" > /sys/block/zram0/disksize
    echo "zram disksize set to ${total_mb}M"

    mkfs.ext4 -q "$ZRAM_DEV"
    mkdir -p "$MOUNT_POINT"
    mount "$ZRAM_DEV" "$MOUNT_POINT"

    echo "Mounted zram at $MOUNT_POINT"
    df -h "$MOUNT_POINT" || true
    touch "$MOUNT_POINT/.zram-test" || true
    echo "Created test file in $MOUNT_POINT"
}

main() {
    parse_args "$@"
    query_for_missing_iso_inputs
    print_header
    print_zram_state

    if [[ "$ACTION" == "unload-only" ]]; then
        cleanup_zram
        print_zram_state
        exit 0
    fi

    if [[ -z "$WINDOWS_ISO_URL" && -z "$WINDOWS_ISO_PATH" && -z "$VIRTIO_ISO_URL" && -z "$VIRTIO_ISO_PATH" ]]; then
        echo "ERROR: At least one ISO URL or path must be provided for load testing." >&2
        usage
        exit 1
    fi

    local windows_bytes=0
    local virtio_bytes=0

    if [[ -n "$WINDOWS_ISO_URL" ]]; then
        windows_bytes=$(iso_size_bytes "$WINDOWS_ISO_URL")
    elif [[ -n "$WINDOWS_ISO_PATH" ]]; then
        windows_bytes=$(iso_size_bytes "$WINDOWS_ISO_PATH")
    fi
    if [[ -n "$VIRTIO_ISO_URL" ]]; then
        virtio_bytes=$(iso_size_bytes "$VIRTIO_ISO_URL")
    elif [[ -n "$VIRTIO_ISO_PATH" ]]; then
        virtio_bytes=$(iso_size_bytes "$VIRTIO_ISO_PATH")
    fi

    local total_bytes=$((windows_bytes + virtio_bytes))
    local total_mb=$(((total_bytes + 1024*1024 - 1) / 1024 / 1024))
    local avail_mb
    avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
    local safe_mb=$((avail_mb - RESERVE_MB))
    if [[ "$safe_mb" -lt 0 ]]; then
        safe_mb=0
    fi

    echo "Windows ISO size: ${windows_bytes} bytes"
    echo "VirtIO ISO size: ${virtio_bytes} bytes"
    echo "Total ISO size: ${total_mb} MB"
    echo "Available RAM: ${avail_mb} MB"
    echo "Safe RAM after reserve: ${safe_mb} MB"
    echo ""

    if [[ "$total_mb" -gt "$safe_mb" ]]; then
        echo "ERROR: Not enough safe RAM to load both ISOs into zram."
        echo "       Required: ${total_mb} MB, available: ${safe_mb} MB"
        exit 1
    fi

    echo "RAM and ISO size check passed. Proceeding with zram configuration."
    configure_zram "$total_mb"

    if [[ "$ACTION" == "load-only" || "$KEEP_MOUNTED" -eq 1 ]]; then
        echo "Zram load successful. Leaving mount active."
        exit 0
    fi

    echo "Cleaning up zram after test..."
    cleanup_zram
    print_zram_state
}

main "$@"
