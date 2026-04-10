#!/usr/bin/env bash
set -e

url="https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=d6f83cc2-3c65-40c0-85ff-143a500abe4e&P1=1775830512&P2=601&P3=2&P4=XA71zxH6FtisWhOao7eelJjEAcT6SyLI74vehgTmdEAoyuhYQFHfakQ82aJuS%2bUpMi6kjtJu0wgu0jAZ%2fa7XSp%2bNAHUON0FaZb6MIbKbsqNafmgUlpBNJCKgpDcLSX7ACWBWv%2fan8gOQr%2b8yakjqweT1WLVVSrMB8VX9pqfvkLZ4FXZsAJGZ7Gff9UX48qnrLAL4zG3yVTalh3wFHqd2HnCfeYY6wfZVWr8cBxyfKrSlcmfVhamVs26M6eoLKuljxE6WBsfd0%2btNkmNX%2fjp25FlT67w3ZXuWacTSYEoCniiH2NHkjTJhdsvFzXT%2bJ7bfn206xRPCF8mOX4pGv1zsNA%3d%3d"

user_agents=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Mobile Safari/537.36"
)

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl not installed"
  exit 1
fi

for ua in "${user_agents[@]}"; do
  echo "Testing UA: $ua"
  status=$(curl -sSLI --max-redirs 10 -A "$ua" "$url" 2>/dev/null | awk 'tolower($1)=="http/1.1" || tolower($1)=="http/2" {print $0; exit}')
  length=$(curl -sSLI --max-redirs 10 -A "$ua" "$url" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1)
  echo "  Status: ${status:-<none>}"
  echo "  Content-Length: ${length:-<none>}"
  if [[ "$status" =~ ^HTTP ]] && [[ ! "$status" =~ 403 ]] && [[ ! "$status" =~ 404 ]] && [[ ! "$status" =~ 401 ]] && [[ ! "$status" =~ 500 ]]; then
    echo "SUCCESS with UA: $ua"
    exit 0
  fi
  echo "  failed, trying next UA..."
done

echo "All UAs failed"
exit 1
