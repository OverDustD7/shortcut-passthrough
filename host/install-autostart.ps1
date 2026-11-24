# Run this installation's receiver independently and restore it at logon.
# Keep ASCII-only for Windows PowerShell 5.1.
param(
    [ValidateRange(1,65535)][int]$Port = 47823,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$recv = Join-Path $here 'alttab-recv.ps1'
$startup = [Environment]::GetFolderPath('Startup')
$entry = Join-Path $startup 'ShortcutPassthrough-receiver.cmd'
. (Join-Path $here 'receiver-identity.ps1')
$cmd = '@echo off' + [Environment]::NewLine +
    ('start "" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Port {1}' -f $recv, $Port) +
    [Environment]::NewLine

$mutex = New-Object Threading.Mutex($false, ('Local\ShortcutPassthroughInstaller-' + $Port))
$held = $false
try {
    try { $held = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another installer owns this port; no changes were made.' }

    $entryExisted = Test-ReceiverStartupEntry $entry $cmd
    $state = Get-ReceiverPortState $Port $recv
    if ($state.Conflicts.Count) {
        throw 'The port has an unverified owner; no processes or Startup entry were changed.'
    }
    if (-not $Uninstall) {
        if (-not (Test-Path -LiteralPath $recv)) { throw 'The receiver script is missing.' }
        if (-not (Test-Path -LiteralPath (Join-Path $here 'PairedUdpReceiver.cs') -PathType Leaf)) {
            throw 'The receiver protocol source is missing. Copy the complete host directory.'
        }
        . (Join-Path $here 'pairing-code.ps1')
        $null = Read-PairingCode
        if ($recv -match '[^\x00-\x7F]') {
            throw 'The ASCII Startup launcher requires an ASCII-only host directory path.'
        }
    }
    foreach ($evidence in $state.Owned) { Stop-OwnedReceiver $evidence $recv $Port }

    # Check again before changing a known filename; preserve a concurrent or unrelated edit.
    $entryNow = Test-ReceiverStartupEntry $entry $cmd
    if ($entryExisted -and -not $entryNow) {
        throw 'The Startup entry disappeared; it was not recreated.'
    }
    if ($Uninstall) {
        if ($entryNow) { Remove-Item -LiteralPath $entry -Force }
        Write-Host 'uninstalled the verified receiver and Startup entry'
        return
    }

    $createdEntry = New-ReceiverStartupEntry $entry $cmd
    $spawned = $null
    $savedModulePath = $env:PSModulePath
    try {
        # A Windows PowerShell 5.1 child must not inherit a PowerShell 7 module path:
        # it then fails to autoload Microsoft.PowerShell.Security and cannot read the
        # DPAPI-protected pairing code. Spawn it with the machine/user default instead.
        $env:PSModulePath = (@(
            [Environment]::GetEnvironmentVariable('PSModulePath','User'),
            [Environment]::GetEnvironmentVariable('PSModulePath','Machine')
        ) | Where-Object { $_ }) -join ';'
        $launch = @{
            FilePath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
            ArgumentList = @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"' + $recv + '"'),'-Port',$Port)
            WorkingDirectory = $here
            WindowStyle = 'Hidden'
            PassThru = $true
        }
        $spawned = Start-Process @launch
        $env:PSModulePath = $savedModulePath
        $endpoint = @()
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            Start-Sleep -Milliseconds 500
            if ($spawned.HasExited) { break }
            $endpoint = @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue |
                Where-Object OwningProcess -eq $spawned.Id)
            if ($endpoint.Count) { break }
        }
        if ($spawned.HasExited -or -not $endpoint.Count) {
            throw 'The spawned receiver did not bind its port; installation was not verified.'
        }
        Write-Host "listening on UDP $Port, verified spawned pid=$($spawned.Id)"
    } catch {
        $env:PSModulePath = $savedModulePath
        # Only the process object created above may be stopped here.
        if ($spawned -and -not $spawned.HasExited) {
            $spawned.Kill()
            $null = $spawned.WaitForExit(5000)
        }
        if ($createdEntry -and (Test-Path -LiteralPath $entry)) {
            if ([IO.File]::ReadAllText($entry) -ceq $cmd) { Remove-Item -LiteralPath $entry -Force }
        }
        throw
    } finally { if ($spawned) { $spawned.Dispose() } }
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
