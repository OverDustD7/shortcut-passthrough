# install-autostart.ps1 -- run the key receiver as a long-lived, independent process
# that survives DSH sessions and comes back at every logon.
#
# No admin needed: the entry goes into the current user's Startup folder, and the
# process is created through WMI so it is not a child of whichever shell ran this.
#
#   .\install-autostart.ps1              install + start now
#   .\install-autostart.ps1 -Uninstall   remove the Startup entry and stop it
#
# Keep this file ASCII-only (see alttab-recv.ps1 for the reason).
param(
    [int]$Port = 47823,
    [switch]$Uninstall
)

$here    = $PSScriptRoot
$recv    = Join-Path $here 'alttab-recv.ps1'
$startup = [Environment]::GetFolderPath('Startup')
$entry   = Join-Path $startup 'ShortcutPassthrough-receiver.cmd'

function Stop-Receivers {
    $eps = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
    foreach ($e in $eps) {
        $p = Get-Process -Id $e.OwningProcess -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'powershell') {
            Stop-Process -Id $p.Id -Force
            Write-Host "stopped receiver pid $($p.Id)"
        }
    }
}

if ($Uninstall) {
    if (Test-Path -LiteralPath $entry) { Remove-Item -LiteralPath $entry -Force; Write-Host "removed $entry" }
    Stop-Receivers
    Write-Host "uninstalled"
    return
}

if (-not (Test-Path -LiteralPath $recv)) { throw "receiver not found: $recv" }

$cmd = "@echo off`r`nstart `"`" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$recv`" -Port $Port`r`n"
[System.IO.File]::WriteAllText($entry, $cmd, (New-Object System.Text.ASCIIEncoding))
Write-Host "startup entry: $entry"

Stop-Receivers
Start-Sleep -Milliseconds 1500

# Start-Process survives the calling shell exiting (verified on this host);
# WMI Win32_Process.Create is silently blocked here, do not use it.
$p = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$recv`"", '-Port', $Port `
        -WindowStyle Hidden -PassThru
Write-Host "spawn pid=$($p.Id)"

$ep = $null
for ($i = 0; $i -lt 20 -and -not $ep; $i++) {
    Start-Sleep -Milliseconds 500
    $ep = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
}
if ($ep) {
    $p = Get-Process -Id $ep.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "listening on UDP $Port, pid=$($ep.OwningProcess) name=$($p.ProcessName) started=$($p.StartTime)"
} else {
    Write-Host "not listening - check $(Join-Path $here 'alttab-recv.log')"
}
