# Run in a fresh Windows PowerShell process. No keyboard receiver or UDP socket is started.
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Run this test with powershell.exe -NoProfile -File.' }
$helper = Join-Path (Split-Path $PSScriptRoot -Parent) 'host\receiver-identity.ps1'
. $helper
$script:passed = 0
function Assert-True([bool]$Value, [string]$Label) {
    if (-not $Value) { throw ('FAIL: ' + $Label) }
    $script:passed++
}
$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$receiver = Join-Path ([IO.Path]::GetTempPath()) 'shortcut fixture\alttab-recv.ps1'
$fixture = [pscustomobject]@{
    ProcessId = 424242
    ExecutablePath = $exe
    CommandLine = ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Port 47823' -f $exe,$receiver)
    OwnerSid = 'SYNTHETIC-OWNER'
    SessionId = 42
    CreationUtcTicks = [DateTime]::UtcNow.Ticks
    KernelStartUtcTicks = [DateTime]::UtcNow.Ticks
}
$fixture.CreationUtcTicks = $fixture.KernelStartUtcTicks - ($fixture.KernelStartUtcTicks % 10)
function Is-Owned($Value, [int]$ExpectedPort = 47823) {
    return (Test-ReceiverIdentity $Value $receiver $ExpectedPort 'SYNTHETIC-OWNER' 42)
}
Assert-True (Is-Owned $fixture) 'quoted path and managed arguments'
$copy = $fixture.PSObject.Copy(); $copy.OwnerSid = 'SOMEONE-ELSE'
Assert-True (-not (Is-Owned $copy)) 'other account'
$copy = $fixture.PSObject.Copy(); $copy.SessionId = 43
Assert-True (-not (Is-Owned $copy)) 'other logon session'
$copy = $fixture.PSObject.Copy(); $copy.ExecutablePath = Join-Path ([IO.Path]::GetTempPath()) 'powershell.exe'
Assert-True (-not (Is-Owned $copy)) 'untrusted executable with the same filename'
$copy = $fixture.PSObject.Copy(); $copy.CreationUtcTicks = 0
Assert-True (-not (Is-Owned $copy)) 'missing creation identity'
$copy = $fixture.PSObject.Copy(); $copy.CommandLine = ('"{0}" -NoProfile -File "{1}" -Port 47823' -f $exe,($receiver + '.other'))
Assert-True (-not (Is-Owned $copy)) 'other script on the same port'
$copy = $fixture.PSObject.Copy(); $copy.CommandLine = ('"{0}" -Command "-File {1} -Port 47823"' -f $exe,$receiver)
Assert-True (-not (Is-Owned $copy)) 'embedded -File in a command is not script ownership'
$copy = $fixture.PSObject.Copy(); $copy.CommandLine = ('"{0}" -EncodedCommand ZgBpAHgAdAB1AHIAZQA=' -f $exe)
Assert-True (-not (Is-Owned $copy)) 'encoded command'
Assert-True (-not (Is-Owned $fixture 47824)) 'different requested port'
$copy = $fixture.PSObject.Copy(); $copy.CommandLine = $copy.CommandLine.Replace('-Port 47823','-Port 0')
Assert-True (-not (Is-Owned $copy)) 'invalid port'
$copy = $fixture.PSObject.Copy(); $copy.CommandLine += ' -Port 47823'
Assert-True (-not (Is-Owned $copy)) 'duplicate port'
$copy = $fixture.PSObject.Copy(); $copy.CommandLine = ('"{0}" -NoProfile -File "{1}"' -f $exe,$receiver)
Assert-True (Is-Owned $copy) 'explicit script with its default port'
Assert-True (-not (Is-Owned $copy 47824)) 'default is not an arbitrary port'
$copy = $fixture.PSObject.Copy(); $copy.CommandLine = $copy.CommandLine.ToUpperInvariant()
Assert-True (Is-Owned $copy) 'Windows path and option case'
$copy = $fixture.PSObject.Copy(); $copy.CommandLine = ('"{0}" -NoExit -File "{1}"' -f $exe,$receiver)
Assert-True (-not (Is-Owned $copy)) 'unrecognized launch form fails closed'

# Port discovery must distinguish the same-user script from an unrelated owner.
$script:portRecord = $fixture.PSObject.Copy()
$script:portRecord.OwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:portRecord.SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
$script:portMode = 'owned'
function Get-NetUDPEndpoint {
    [CmdletBinding()]param([int]$LocalPort)
    if ($script:portMode -eq 'denied') { Write-Error 'synthetic denial' -Category PermissionDenied; return }
    if ($script:portMode -eq 'empty') { return }
    return @([pscustomobject]@{OwningProcess=424242},[pscustomobject]@{OwningProcess=424242})
}
function Get-ReceiverProcessEvidence([int]$ProcessId) { return $script:portRecord }
$state = Get-ReceiverPortState 47823 $receiver
Assert-True ($state.Owned.Count -eq 1 -and $state.Conflicts.Count -eq 0) 'duplicate endpoints yield one verified owner'
$script:portRecord.CommandLine = ('"{0}" -File "unrelated.ps1" -Port 47823' -f $exe)
$state = Get-ReceiverPortState 47823 $receiver
Assert-True ($state.Owned.Count -eq 0 -and $state.Conflicts.Count -eq 1) 'same port is not ownership'
$script:portRecord = $null
$state = Get-ReceiverPortState 47823 $receiver
Assert-True ($state.Conflicts.Count -eq 1) 'unreadable identity remains a conflict'
$script:portMode = 'empty'; $state = Get-ReceiverPortState 47823 $receiver
Assert-True ($state.Owned.Count -eq 0 -and $state.Conflicts.Count -eq 0) 'empty port'
$script:portMode = 'denied'; $rejected = $false
try { $null = Get-ReceiverPortState 47823 $receiver } catch { $rejected = $true }
Assert-True $rejected 'port-query denial is not an empty port'
Remove-Item Function:Get-NetUDPEndpoint
. $helper

# Exercise the real stop function with process/CIM boundaries mocked: never stop an actual PID.
$script:stopCalls = @()
$script:proof = $fixture.PSObject.Copy()
$script:proof.OwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:proof.SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
$script:fresh = $script:proof.PSObject.Copy()
$script:fakeProcess = [pscustomobject]@{
    Id = 424242
    Handle = 1
    StartTime = [DateTime]::new($script:proof.KernelStartUtcTicks, [DateTimeKind]::Utc)
}
$script:fakeProcess | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $true }
$script:fakeProcess | Add-Member ScriptMethod Dispose { }
function Get-ReceiverProcessEvidence([int]$ProcessId) { return $script:fresh }
function Get-Process {
    [CmdletBinding()]param([int]$Id)
    return $script:fakeProcess
}
function Stop-Process {
    [CmdletBinding()]param($InputObject, [switch]$Force)
    $script:stopCalls += $InputObject.Id
}
Stop-OwnedReceiver $script:proof $receiver 47823
Assert-True ($script:stopCalls.Count -eq 1 -and $script:stopCalls[0] -eq 424242) 'only the verified process object is stopped'
$script:stopCalls = @()
$script:fresh = $script:proof.PSObject.Copy(); $script:fresh.CreationUtcTicks++
$rejected = $false
try { Stop-OwnedReceiver $script:proof $receiver 47823 } catch { $rejected = $true }
Assert-True ($rejected -and -not $script:stopCalls.Count) 'PID reuse or changed creation time'
$script:fresh = $script:proof.PSObject.Copy(); $script:fresh.KernelStartUtcTicks++
$rejected = $false
try { Stop-OwnedReceiver $script:proof $receiver 47823 } catch { $rejected = $true }
Assert-True ($rejected -and -not $script:stopCalls.Count) 'kernel identity differs even within one CIM microsecond'
$script:fresh = $null; $rejected = $false
try { Stop-OwnedReceiver $script:proof $receiver 47823 } catch { $rejected = $true }
Assert-True ($rejected -and -not $script:stopCalls.Count) 'unavailable process evidence'
$script:fresh = $script:proof.PSObject.Copy()
$script:fakeProcess.StartTime = $script:fakeProcess.StartTime.AddTicks(1)
$rejected = $false
try { Stop-OwnedReceiver $script:proof $receiver 47823 } catch { $rejected = $true }
Assert-True ($rejected -and -not $script:stopCalls.Count) 'pinned handle start time must match'
Remove-Item Function:Get-Process
Remove-Item Function:Stop-Process
. $helper

# An optional real identity check uses only our own sleeping fixture, never the keyboard receiver.
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('shortcut-identity-' + [Guid]::NewGuid().ToString('N'))
$child = $null
$integration = 'not-run'
$cleaned = $false
$createdRoot = $false
try {
    $null = New-Item -ItemType Directory -Path $tempRoot
    $createdRoot = $true
    $startupFixture = Join-Path $tempRoot 'fixture-startup.cmd'
    $expectedStartup = '@echo off' + [Environment]::NewLine + 'fixture-only'
    Assert-True (-not (Test-ReceiverStartupEntry $startupFixture $expectedStartup)) 'missing Startup entry'
    Assert-True (New-ReceiverStartupEntry $startupFixture $expectedStartup) 'creates a missing Startup fixture'
    Assert-True (Test-ReceiverStartupEntry $startupFixture $expectedStartup) 'recognized Startup entry'
    Assert-True (-not (New-ReceiverStartupEntry $startupFixture $expectedStartup)) 'identical Startup content is reused without overwrite'
    [IO.File]::WriteAllText($startupFixture, 'unrelated content')
    $rejected = $false
    try { $null = Test-ReceiverStartupEntry $startupFixture $expectedStartup } catch { $rejected = $true }
    Assert-True ($rejected -and [IO.File]::ReadAllText($startupFixture) -eq 'unrelated content') 'foreign Startup content is preserved'
    $rejected = $false
    try { $null = New-ReceiverStartupEntry $startupFixture $expectedStartup } catch { $rejected = $true }
    Assert-True ($rejected -and [IO.File]::ReadAllText($startupFixture) -eq 'unrelated content') 'creation rejects foreign Startup content'
    $originalStartupCheck = (Get-Command Test-ReceiverStartupEntry).ScriptBlock
    try {
        # Simulate a concurrent creation after the preflight reported no file.
        Set-Item Function:\Test-ReceiverStartupEntry -Value { param($Entry, $ExpectedContent); return $false }
        $rejected = $false
        try { $null = New-ReceiverStartupEntry $startupFixture $expectedStartup } catch { $rejected = $true }
        Assert-True ($rejected -and [IO.File]::ReadAllText($startupFixture) -eq 'unrelated content') 'CreateNew preserves a concurrent foreign Startup entry'
    } finally { Set-Item Function:\Test-ReceiverStartupEntry -Value $originalStartupCheck }
    $fixtureScript = Join-Path $tempRoot 'fixture.ps1'
    [IO.File]::WriteAllText($fixtureScript, 'param([int]$Port); [Console]::Out.WriteLine("FIXTURE_READY"); Start-Sleep -Seconds 30', [Text.Encoding]::ASCII)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = '-NoLogo -NoProfile -File "' + $fixtureScript + '" -Port 47823'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $child = [Diagnostics.Process]::Start($info)
    $line = $child.StandardOutput.ReadLineAsync()
    $errors = $child.StandardError.ReadToEndAsync()
    Assert-True ($line.Wait(10000) -and $line.Result -eq 'FIXTURE_READY') 'owned sleeping fixture ready'
    $evidence = Get-ReceiverProcessEvidence $child.Id
    if (-not $evidence) {
        $integration = 'unverified-cim-unavailable'
    } else {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
        Assert-True (Test-ReceiverIdentity $evidence $fixtureScript 47823 $sid $session) 'actual owned fixture identity'
        Stop-OwnedReceiver $evidence $fixtureScript 47823
        Assert-True ($child.WaitForExit(5000)) 'actual owned fixture exited'
        $integration = 'passed'
    }
} finally {
    if ($child) {
        if (-not $child.HasExited) { $child.Kill(); $null = $child.WaitForExit(5000) }
        $child.Dispose()
    }
    $full = [IO.Path]::GetFullPath($tempRoot)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $full.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $full -Leaf) -notmatch '^shortcut-identity-[a-f0-9]{32}$') { throw 'Unsafe cleanup target.' }
    if ($createdRoot -and (Test-Path -LiteralPath $full)) {
        if ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Fixture root became a reparse point; cleanup stopped.'
        }
        foreach ($leaf in @('fixture.ps1','fixture-startup.cmd')) {
            $ownedFile = Join-Path $full $leaf
            if (Test-Path -LiteralPath $ownedFile) { Remove-Item -LiteralPath $ownedFile -Force }
        }
        # Do not recursively remove unexpected content or a pre-existing fixture directory.
        [IO.Directory]::Delete($full, $false)
    }
    $cleaned = -not (Test-Path -LiteralPath $full)
}
[ordered]@{passed=$script:passed;failed=0;realIdentityCheck=$integration;noKeyboardReceiverStarted=$true;noUdpSocketOpened=$true;temporaryRootRemoved=$cleaned}|ConvertTo-Json -Compress
