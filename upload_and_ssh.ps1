#!/usr/bin/env pwsh

# PowerShell script to upload scripts, create a public key, and run an SSH session

# Ensure the script is run in PowerShell
if (-not $PSVersionTable) {
    Write-Host "This script must be run in PowerShell. Exiting..."
    exit 1
}

# Define variables
$remoteHost = "156.67.82.16"
$remoteUser = "root"
$keyPath = "$HOME\.ssh\contabo_key"
$scriptToUpload = "path_to_your_script.sh"  # Replace with the path to your script
$remoteScriptPath = "/root/uploaded_script.sh"

# Generate SSH key pair if it doesn't exist
if (-Not (Test-Path "$keyPath")) {
    Write-Host "Generating SSH key pair..."
    ssh-keygen -t rsa -b 2048 -f $keyPath -N ""
    Write-Host "SSH key pair generated at $keyPath"
}
else {
    Write-Host "SSH key pair already exists at $keyPath"
}

# Upload the public key to the remote server
Write-Host "Uploading public key to the remote server..."
$publicKey = Get-Content "$keyPath.pub"
$sshCommand = "echo '$publicKey' >> ~/.ssh/authorized_keys"
ssh -i $keyPath $remoteUser@$remoteHost $sshCommand
Write-Host "Public key uploaded successfully."

# Upload the script to the remote server
Write-Host "Uploading script to the remote server..."
Start-Process -FilePath "scp" -ArgumentList "-i", "$keyPath", "$scriptToUpload", "${remoteUser}@${remoteHost}:${remoteScriptPath}" -NoNewWindow -Wait
Write-Host "Script uploaded successfully to $remoteScriptPath."

# Test the SSH connection and echo a message
Write-Host "Testing SSH connection with echo command..."
ssh -i $keyPath $remoteUser@$remoteHost "echo 'SSH connection successful!'"
Write-Host "SSH connection test completed."