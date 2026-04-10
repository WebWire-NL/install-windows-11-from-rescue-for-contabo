param(
    [Parameter(Mandatory=$true)]
    [string]$TargetHost,

    [Parameter(Mandatory=$false)]
    [string]$Key = "$env:USERPROFILE\.ssh\contabo_key",

    [Parameter(Mandatory=$false)]
    [int]$Interval = 5,

    [Parameter(Mandatory=$false)]
    [int]$Timeout = 5,

    [Parameter(Mandatory=$false)]
    [int]$Attempts = 24
)

Write-Host "Checking SSH connectivity to $TargetHost using key $Key"
for ($i = 1; $i -le $Attempts; $i++) {
    try {
        $process = Start-Process -FilePath ssh -ArgumentList @(
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'PreferredAuthentications=publickey',
            '-o', 'PubkeyAuthentication=yes',
            '-o', 'IdentitiesOnly=yes',
            '-i', $Key,
            "root@$TargetHost",
            'exit'
        ) -NoNewWindow -PassThru -Wait -ErrorAction Stop -RedirectStandardError ([System.IO.StreamWriter]::Null) -RedirectStandardOutput ([System.IO.StreamWriter]::Null)
        if ($process.ExitCode -eq 0) {
            Write-Host "[$i] SSH is online"
            exit 0
        }
    } catch {
        Write-Host "[$i] SSH offline"
    }
    Start-Sleep -Seconds $Interval
}
Write-Host "SSH check timed out after $($Interval * $Attempts) seconds."
exit 1
