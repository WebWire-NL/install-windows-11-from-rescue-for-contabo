param(
    [Parameter(Mandatory = $false)]
    [string]$TargetHost = '156.67.82.16',

    [Parameter(Mandatory = $false)]
    [string]$User = 'root',

    [Parameter(Mandatory = $false)]
    [string]$Key = "$env:USERPROFILE\.ssh\vps_deploy_rsa",

    [Parameter(Mandatory = $false)]
    [string]$WindowsIsoUrl,

    [Parameter(Mandatory = $false)]
    [string]$VirtioIsoUrl = 'https://bit.ly/4d1g7Ht',

    [Parameter(Mandatory = $false)]
    [switch]$CheckOnly
)

if (-not (Get-Command pwsh -ErrorAction SilentlyContinue) -and -not (Get-Command powershell -ErrorAction SilentlyContinue)) {
    Write-Error 'PowerShell is required to run this script.'
    exit 1
}

if (-not $WindowsIsoUrl) {
    $WindowsIsoUrl = Read-Host 'Enter the Windows ISO URL'
}

if (-not $WindowsIsoUrl) {
    Write-Error 'Windows ISO URL is required.'
    exit 1
}

$remotePath = '/root/install-windows-11-from-rescue-for-contabo'
$remoteScript = 'windows-install.sh'

$flags = @()
$flags += "--windows-iso-url=$WindowsIsoUrl"
$flags += "--virtio-iso-url=$VirtioIsoUrl"
if ($CheckOnly) {
    $flags += '--check-only'
}

$remoteCommand = "cd $remotePath && bash $remoteScript $($flags -join ' ')"

Write-Host "Running remote installer on $User@$TargetHost"
Write-Host "Windows ISO: $WindowsIsoUrl"
Write-Host "VirtIO ISO: $VirtioIsoUrl"
if ($CheckOnly) {
    Write-Host 'Check-only mode enabled.'
}

& .\invoke-vps-command.ps1 -TargetHost $TargetHost -User $User -Key $Key -RemoteCommand $remoteCommand
