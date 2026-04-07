# Save this as raw_tcp_client.ps1
$server = "156.67.82.16"  # Server's IP address
$port = 6666              # Server's listening port

try {
    $client = New-Object System.Net.Sockets.TcpClient($server, $port)
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.AutoFlush = $true

    Write-Host "Connected to $server on port $port."

    while ($true) {
        $command = Read-Host "Enter command to send (type 'exit' to quit)"
        if ($command -eq "exit") {
            Write-Host "Exiting..."
            break
        }

        # Send the command with a newline character to ensure proper formatting
        $writer.WriteLine($command + "`r`n")

        # Read and display the server's response
        while ($stream.DataAvailable) {
            $response = $reader.ReadLine()
            if ($response -ne $null) {
                Write-Host "Server response: $response"
            }
        }
    }

    $client.Close()
} catch {
    Write-Host "Error: $_"
}