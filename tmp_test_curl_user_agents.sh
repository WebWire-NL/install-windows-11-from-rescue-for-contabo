#!/usr/bin/env bash
set -e
cd /root/install-windows-11-from-rescue-for-contabo

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is not installed on the VPS"
  exit 1
fi

urls=(
  "https://software.download.prss.microsoft.com/dbazure/Win11_25H2_English_x64_v2.iso?t=9dd36437-8c53-4d86-80dc-29db90a63505&P1=1775719369&P2=601&P3=2&P4=fizoXRjVOXdAMg6a1PRgNIZMO8eeYkphp0nfA4VZxRwRnoitaEjdNb%2fu%2bEjZhVHU5khibrqnmy5ILZ8UhgR2B9MNohSfvcTBciTTZFNmwkV3%2bmcGjh9rti%2bdQv8d4XTZafuF1VBHfgn1tRGz8TTn%2foFRphlIU1rqnxpOMnbLGIqif%2bVMdnnXYyOFNpLtZoUKspcdJLktl4cu2axBhYFaWWh%2fYTCQy8IE%2fgFapNMea7KgfYIinsF338Xyy2iutI2bYa555qx1gzLXO30pV1dq7E%2bKlaPmh1YgCR7xQ%3d%3d"
  "https://bit.ly/4d1g7Ht"
)

user_agents=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Mobile Safari/537.36"
)

echo "curl version: $(curl --version | head -n 1)"

for ua in "${user_agents[@]}"; do
  echo
  echo "=== UA: $ua ==="
  for url in "${urls[@]}"; do
    echo "URL: $url"
    status=$(curl -sSLI --max-redirs 10 -A "$ua" "$url" 2>/dev/null | awk 'tolower($1) ~ /^http\// {st=$0} END{print st}')
    length=$(curl -sSLI --max-redirs 10 -A "$ua" "$url" 2>/dev/null | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1)
    echo "  Status: ${status:-<none>}"
    echo "  Content-Length: ${length:-<none>}"
  done
done
