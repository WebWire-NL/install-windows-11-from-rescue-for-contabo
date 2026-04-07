param(
    [string]$HostName = "156.67.82.16",
    [string]$UserName = "root"
)

Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host "NOTE: This script uses standard SSH to connect to your Linux VPS." -ForegroundColor Cyan
Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

# Define the remote commands to execute
$remoteCommands = @"
echo '================================================================================'
echo 'HOST / OS'
echo '================================================================================'
date
hostname
whoami
uname -a
cat /etc/os-release

echo '================================================================================'
echo 'CPU'
echo '================================================================================'
grep -E 'model name|cpu cores|siblings|processor' /proc/cpuinfo

echo '================================================================================'
echo 'MEMORY'
echo '================================================================================'
free -h

echo '================================================================================'
echo 'DISKS'
echo '================================================================================'
lsblk
df -h

echo '================================================================================'
echo 'NETWORK ADDRESSES (IPv4/IPv6)'
echo '================================================================================'
ip addr

echo '================================================================================'
echo 'ROUTES'
echo '================================================================================"
ip route
netstat -rn

echo '================================================================================'
echo 'DNS'
echo '================================================================================"
cat /etc/resolv.conf

echo '================================================================================'
echo 'INTERFACES'
echo '================================================================================"
ip link

echo '================================================================================'
echo 'NEIGHBORS / ARP'
echo '================================================================================"
ip neigh

echo '================================================================================'
echo 'MOUNTED FILESYSTEMS'
echo '================================================================================"
mount

echo '================================================================================'
echo 'UPTIME'
echo '================================================================================"
uptime
"@

Write-Host "Connecting via SSH to $UserName@$HostName..." -ForegroundColor Cyan
# We use the 'ssh' command. You will be prompted for the password in the terminal.
# -o PasswordAuthentication=yes ensures password auth is tried.
$result = ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$UserName@$HostName" "$remoteCommands"

if ($LASTEXITCODE -eq 0) {
    $result | Out-File -FilePath ".\specs.txt" -Encoding utf8
    Write-Host "System specifications saved to 'specs.txt' in the current directory." -ForegroundColor Green
} else {
    Write-Host "Failed to gather specifications. Ensure SSH is configured correctly or password is correct." -ForegroundColor Red
}
