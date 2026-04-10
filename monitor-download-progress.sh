#!/usr/bin/env bash
set -euo pipefail

INTERVAL=5
COUNT=0
HOST=""
USER="root"
KEY=""
PORT=""
REMOTE_SCRIPT="/root/install-windows-11-from-rescue-for-contabo/monitor-download-progress.sh"

usage() {
    cat <<EOF
Usage: $0 [options] [interval] [count]

Options:
  -h, --host HOST            Remote SSH host to monitor.
  -u, --user USER            SSH user name (default: root).
  -k, --key KEYFILE          SSH private key file.
  -p, --port PORT            SSH port (default: 22).
  --remote-script PATH       Remote monitoring script path.
  -i, --interval SECONDS     Status interval in seconds (default: 5).
  -c, --count N              Number of updates to print before exiting (default: infinite).
  --help                     Show this help text.

If --host is specified, this script runs the remote monitor over SSH.
Otherwise, it prints local download status directly.
EOF
}

log() {
    printf '%s %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

print_status() {
    log "--- download status ---"
    echo "Active download process:"
    ps -eo pid,etime,cmd | grep -E 'curl .*Windows\.iso|aria2c|wget|curl .*windisk/Windows.iso' | grep -v grep || true

    echo
    echo "Partial ISO file:"
    ls -lh /mnt/zram0/windisk/Windows.iso 2>/dev/null || echo "  not found"

    echo
    echo "Zram mount:"
    mount | grep '/mnt/zram0' || echo "  not mounted"

    echo
    echo "Disk usage:"
    df -h /mnt/zram0 /root/windisk /mnt 2>/dev/null || true

    echo
    echo "Recent installer log:" 
    tail -n 20 /root/install-windows-run.log 2>/dev/null || echo "  not available"
    echo
}

run_local() {
    if [ "$COUNT" -gt 0 ]; then
        for i in $(seq 1 "$COUNT"); do
            print_status
            if [ "$i" -lt "$COUNT" ]; then
                sleep "$INTERVAL"
            fi
        done
    else
        while true; do
            print_status
            sleep "$INTERVAL"
        done
    fi
}

run_remote() {
    local ssh_opts=()
    if [ -n "$PORT" ]; then
        ssh_opts+=( -p "$PORT" )
    fi
    if [ -n "$KEY" ]; then
        ssh_opts+=( -i "$KEY" )
    fi
    ssh_opts+=( -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes -o ConnectTimeout=10 )

    local remote_cmd
    remote_cmd="\"$REMOTE_SCRIPT\" $INTERVAL $COUNT"
    ssh "${ssh_opts[@]}" "$USER@$HOST" "bash -lc '$remote_cmd'"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--host)
            HOST="$2"
            shift 2
            ;;
        -u|--user)
            USER="$2"
            shift 2
            ;;
        -k|--key)
            KEY="$2"
            shift 2
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        --remote-script)
            REMOTE_SCRIPT="$2"
            shift 2
            ;;
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -c|--count)
            COUNT="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            if [ -z "$INTERVAL" ] || [ "$INTERVAL" = "5" ]; then
                INTERVAL="$1"
            elif [ "$COUNT" = "0" ]; then
                COUNT="$1"
            else
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -n "$HOST" ]; then
    run_remote
else
    run_local
fi
