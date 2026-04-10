param(
    [Parameter(Mandatory=$true)]
    [string]$Host,

    [string]$User = 'root',
    [string]$Key,
    [int]$Port = 22,
    [int]$Interval = 5,
    [int]$Count = 0,
    [string]$RemoteScript = '/root/install-windows-11-from-rescue-for-contabo/monitor-download-progress.sh'
)

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Error 'ssh command not found. Install OpenSSH client or use Git Bash/WSL.'
    exit 1
}

$sshArgs = @(
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'PreferredAuthentications=publickey',
    '-o', 'PubkeyAuthentication=yes',
    '-o', "ConnectTimeout=10"
)

if ($Key) {
    $sshArgs += '-i'
    $sshArgs += $Key
}

if ($Port -ne 22) {
    $sshArgs += '-p'
    $sshArgs += $Port.ToString()
}

$sshArgs += "${User}@${Host}"
$remoteCmd = "bash -lc '$RemoteScript $Interval $Count'"
$sshArgs += $remoteCmd

Write-Host "Running remote monitor on ${User}@${Host}..."
& ssh @sshArgs
