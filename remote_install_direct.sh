#!/bin/bash
set -euo pipefail
rm -f /root/run_vps_check.sh
cd /root/install-windows-11-from-rescue-for-contabo

git pull origin master

bash windows-install.sh --no-prompt --windows-iso-url 'https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=d6f83cc2-3c65-40c0-85ff-143a500abe4e&P1=1775830512&P2=601&P3=2&P4=XA71zxH6FtisWhOao7eelJjEAcT6SyLI74vehgTmdEAoyuhYQFHfakQ82aJuS%2bUpMi6kjtJu0wgu0jAZ%2fa7XSp%2bNAHUON0FaZb6MIbKbsqNafmgUlpBNJCKgpDcLSX7ACWBWv%2fan8gOQr%2b8yakjqweT1WLVVSrMB8VX9pqfvkLZ4FXZsAJGZ7Gff9UX48qnrLAL4zG3yVTalh3wFHqd2HnCfeYY6wfZVWr8cBxyfKrSlcmfVhamVs26M6eoLKuljxE6WBsfd0%2btNkmNX%2fjp25FlT67w3ZXuWacTSYEoCniiH2NHkjTJhdsvFzXT%2bJ7bfn206xRPCF8mOX4pGv1zsNA%3d%3d' --virtio-iso-url 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'
