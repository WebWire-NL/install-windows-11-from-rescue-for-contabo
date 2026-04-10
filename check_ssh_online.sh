#!/usr/bin/env bash
set -euo pipefail

HOST=""
KEY=""
INTERVAL=5
TIMEOUT=5

usage() {
    cat <<EOF
Usage: $0 -h host [-k keyfile] [-i interval] [-t timeout]

Options:
  -h host        SSH hostname or IP address to check.
  -k keyfile     Optional private key file to use for authentication.
  -i interval    Seconds between checks (default: 5).
  -t timeout     SSH connect timeout in seconds (default: 5).
  -q             Quiet mode: only print status changes.
  --help         Show this message.
EOF
}

QUIET=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--host)
            HOST="$2"
            shift 2
            ;;
        -k|--key)
            KEY="$2"
            shift 2
            ;;
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -q|--quiet)
            QUIET=1
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [ -z "$HOST" ]; then
    echo "Error: host is required." >&2
    usage
    exit 1
fi

SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout="$TIMEOUT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o PreferredAuthentications=publickey
    -o PubkeyAuthentication=yes
    -o IdentitiesOnly=yes
)

if [ -n "$KEY" ]; then
    SSH_OPTS+=( -i "$KEY" )
fi

prev_status=""
while true; do
    if ssh "${SSH_OPTS[@]}" root@"$HOST" 'exit' >/dev/null 2>&1; then
        status="online"
    else
        status="offline"
    fi

    if [ "$QUIET" -eq 1 ]; then
        if [ "$status" != "$prev_status" ]; then
            echo "SSH is $status"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - SSH is $status"
    fi

    if [ "$status" = "online" ]; then
        exit 0
    fi

    prev_status="$status"
    sleep "$INTERVAL"
done
