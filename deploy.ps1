# Get the ISO URL from the first argument
$isoUrl = $args[0]
if (-not $isoUrl) {
    Write-Host "Usage: .\deploy.ps1 <ISO_URL>" -ForegroundColor Red
    exit
}

$server = "root@156.67.82.16"
$scriptPath = "D:\projects\contabo-script\install_win.sh"
$remotePath = "/tmp/install_win.sh"

Write-Host "Transferring script to $server..."
# Use curly braces to protect the variable/path combination
scp $scriptPath "${server}:${remotePath}"

Write-Host "Executing script on $server..."
# Use curly braces to protect the variable/path combination
ssh $server "chmod +x $remotePath && $remotePath '$isoUrl'"

Write-Host "Deployment command sent."
