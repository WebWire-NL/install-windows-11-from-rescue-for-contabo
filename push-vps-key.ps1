param(
    [Parameter(Mandatory = $false)]
    [string]$TargetHost = '156.67.82.16',

    [Parameter(Mandatory = $false)]
    [string]$User = 'root',

    [Parameter(Mandatory = $false)]
    [string]$PubKeyPath = "$env:USERPROFILE\.ssh\vps_deploy_rsa.pub"
)

if (-not (Test-Path $PubKeyPath)) {
    Write-Error "Public key file not found: $PubKeyPath"
    exit 1
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Error 'Python is required to run push_ssh_key.py.'
    exit 1
}

$securePassword = Read-Host 'Enter root password for the VPS' -AsSecureString
$password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword))

Write-Host "Pushing public key $PubKeyPath to $User@$TargetHost..."
python .\push_ssh_key.py $TargetHost $User $password $PubKeyPath
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Error "push_ssh_key.py failed with exit code $exitCode"
}
exit $exitCode
