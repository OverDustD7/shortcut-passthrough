# Cross-runtime loopback test with synthetic key and no input injection.
param(
    [Parameter(Mandatory=$true)][string]$Java,
    [Parameter(Mandatory=$true)][string]$Classes
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $root 'host\PairedUdpReceiver.cs')
$key = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
$receiver = New-Object PairedUdpReceiver $key
$fresh = New-Object PairedUdpReceiver $key
$listener = New-Object Net.Sockets.UdpClient (New-Object Net.IPEndPoint ([Net.IPAddress]::Loopback), 0)
$listener.Client.ReceiveTimeout = 2500
$process = $null
try {
    $port = $listener.Client.LocalEndPoint.Port
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Java
    $info.Arguments = '-cp "' + $Classes + '" top.overdustd7.alttabpipe.PairedUdpTest ' + $port
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    $commands = @('KEY 117 1', 'RELEASE_ALL')
    $index = 0
    $challenges = 0
    $rejectedHellos = 0
    for ($packet = 0; $packet -lt 5; $packet++) {
        $remote = New-Object Net.IPEndPoint ([Net.IPAddress]::Any), 0
        $wire = [Text.Encoding]::ASCII.GetString($listener.Receive([ref]$remote))
        if ($wire.StartsWith('ATP1 H ')) {
            $reply = $receiver.Challenge($wire)
            if ($reply) {
                $challenges++
                $bytes = [Text.Encoding]::ASCII.GetBytes($reply)
                [void]$listener.Send($bytes, $bytes.Length, $remote)
            } else {
                $rejectedHellos++
                # An untrusted host can see the nonce but cannot authenticate its reply.
                $forged = 'ATP1 C ' + $wire.Substring(7, 32) + ' ' + ('0' * 32) + ' ' + ('0' * 64)
                $bytes = [Text.Encoding]::ASCII.GetBytes($forged)
                [void]$listener.Send($bytes, $bytes.Length, $remote)
            }
            continue
        }
        if ($index -ge $commands.Length -or $wire.Contains($commands[$index])) { throw 'Unexpected or plaintext command' }
        $last = if ($wire.EndsWith('0')) { '1' } else { '0' }
        $tampered = $wire.Substring(0, $wire.Length - 1) + $last
        if ($receiver.Open($tampered)) { throw 'Accepted tampered packet' }
        if ($fresh.Open($wire)) { throw 'Accepted prior-epoch packet' }
        if ($receiver.Open($wire) -cne $commands[$index]) { throw 'Could not decrypt Java packet' }
        if ($receiver.Open($wire)) { throw 'Accepted replay' }
        $index++
    }
    if ($receiver.Open('ALT_TAB')) { throw 'Accepted legacy plaintext' }
    if ($index -ne 2 -or $challenges -ne 2 -or $rejectedHellos -ne 1) { throw 'Unexpected handshake outcomes' }
    if (-not $process.WaitForExit(2500) -or $process.ExitCode -ne 0) { throw 'Java fixture did not succeed' }
    Write-Output 'PASS: Java/Windows pairing, renewal, encrypted commands, wrong key, forged host, tampering, replay, prior epoch and plaintext rejection'
} finally {
    $listener.Dispose()
    if ($process) { $process.Dispose() }
}
