#!/bin/bash
set -euo pipefail

command -v curl >/dev/null 2>&1 && echo "CURL=installed"
command -v wget >/dev/null 2>&1 && echo "WGET=installed"

ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
url1='https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=d6f83cc2-3c65-40c0-85ff-143a500abe4e&P1=1775830512&P2=601&P3=2&P4=XA71zxH6FtisWhOao7eelJjEAcT6SyLI74vehgTmdEAoyuhYQFHfakQ82aJuS%2bUpMi6kjtJu0wgu0jAZ%2fa7XSp%2bNAHUON0FaZb6MIbKbsqNafmgUlpBNJCKgpDcLSX7ACWBWv%2fan8gOQr%2b8yakjqweT1WLVVSrMB8VX9pqfvkLZ4FXZsAJGZ7Gff9UX48qnrLAL4zG3yVTalh3wFHqd2HnCfeYY6wfZVWr8cBxyfKrSlcmfVhamVs26M6eoLKuljxE6WBsfd0%2btNkmNX%2fjp25FlT67w3ZXuWacTSYEoCniiH2NHkjTJhdsvFzXT%2bJ7bfn206xRPCF8mOX4pGv1zsNA%3d%3d'
url2='https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'

echo direct1=

curl -fsSLI -A "$ua" --compressed --max-redirs 10 "$url1" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1

echo direct2=

curl -fsSLI -A "$ua" --compressed --max-redirs 10 "$url2" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1

echo now awk command
awk 'tolower($1)=="content-length:" {print $2}' <<< 'Content-Length: 12345' | tr -d '\r' | tail -n1
