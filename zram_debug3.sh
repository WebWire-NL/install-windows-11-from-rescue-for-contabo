#!/bin/bash
set -euo pipefail

USER_AGENTS=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Mobile Safari/537.36"
)

get_content_length() {
    local url="$1"
    local size

    for ua in "${USER_AGENTS[@]}"; do
        echo "trying UA: $ua"
        size=$(curl -sSLI --max-redirs 10 -A "$ua" "$url" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1)
        echo " -> size=$size"
        if [[ -n "$size" ]]; then
            echo "$size"
            return 0
        fi
    done
    return 1
}

url1='https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=d6f83cc2-3c65-40c0-85ff-143a500abe4e&P1=1775830512&P2=601&P3=2&P4=XA71zxH6FtisWhOao7eelJjEAcT6SyLI74vehgTmdEAoyuhYQFHfakQ82aJuS%2bUpMi6kjtJu0wgu0jAZ%2fa7XSp%2bNAHUON0FaZb6MIbKbsqNafmgUlpBNJCKgpDcLSX7ACWBWv%2fan8gOQr%2b8yakjqweT1WLVVSrMB8VX9pqfvkLZ4FXZsAJGZ7Gff9UX48qnrLAL4zG3yVTalh3wFHqd2HnCfeYY6wfZVWr8cBxyfKrSlcmfVhamVs26M6eoLKuljxE6WBsfd0%2btNkmNX%2fjp25FlT67w3ZXuWacTSYEoCniiH2NHkjTJhdsvFzXT%2bJ7bfn206xRPCF8mOX4pGv1zsNA%3d%3d'
url2='https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'

echo "WINDOWS_SIZE=$(get_content_length "$url1")"
echo "VIRTIO_SIZE=$(get_content_length "$url2")"
