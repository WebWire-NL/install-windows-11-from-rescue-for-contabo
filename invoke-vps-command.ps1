<#
.SYNOPSIS
Runs a command or local script on a remote VPS over SSH using a safe PowerShell wrapper.

.DESCRIPTION
This script builds a minimal, non-interactive SSH command line and avoids quoting issues by
either piping a local script to the remote shell or escaping a one-line remote command safely.

.PARAMETER Host
Remote host or IP address.

.PARAMETER User
Remote user name. Defaults to root.

.PARAMETER Key
Path to the SSH private key file.

.PARAMETER Port
SSH port. Defaults to 22.

.PARAMETER RemoteCommand
A one-line shell command to execute remotely.

.PARAMETER LocalScript
A local script file whose contents will be piped to the remote shell.

.EXAMPLE
.\invoke-vps-command.ps1 -Host 156.67.82.16 -Key "$env:USERPROFILE\.ssh\contabo_key" -RemoteCommand 'uname -a && df -h'

.EXAMPLE
.\invoke-vps-command.ps1 -Host 156.67.82.16 -Key "$env:USERPROFILE\.ssh\contabo_key" -LocalScript '.\remote-setup.sh'
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$TargetHost = '156.67.82.16',

    [Parameter(Mandatory = $false)]
    [string]$User = 'root',

    [Parameter(Mandatory = $false)]
    [string]$Key = (Join-Path $env:USERPROFILE '.ssh\vps_deploy_rsa'),

    [Parameter(Mandatory = $false)]
    [int]$Port = 22,

    [Parameter(Mandatory = $false)]
    [string]$RemoteCommand,

    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$LocalScript
)

Set-StrictMode -Version Latest

if ($RemoteCommand -and $LocalScript) {
    Write-Error 'Specify only one of -RemoteCommand or -LocalScript.'
    exit 1
}

if (-not $RemoteCommand -and -not $LocalScript) {
    Write-Error 'Specify either -RemoteCommand or -LocalScript.'
    exit 1
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command python3 -ErrorAction SilentlyContinue
}

if (-not $python) {
    Write-Error 'Python is required to run invoke_vps_command.py. Install Python 3 and ensure it is on PATH.'
    exit 1
}

$scriptPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'invoke_vps_command.py'
if (-not (Test-Path $scriptPath)) {
    Write-Error "Cannot find helper script: $scriptPath"
    exit 1
}

$invokeArgs = @(
    '--host', $TargetHost,
    '--user', $User,
    '--key', $Key,
    '--port', $Port
)

if ($LocalScript) {
    $invokeArgs += '--local-script'
    $invokeArgs += $LocalScript
}
else {
    $invokeArgs += '--remote-command'
    $invokeArgs += $RemoteCommand
}

Write-Host "Invoking Python SSH helper against $TargetHost"
& $python.Path $scriptPath @invokeArgs
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Error "invoke_vps_command.py exited with code $exitCode"
}

exit $exitCode
