# Importing this file only defines ownership checks; it does not inspect or stop processes.
# Keep ASCII-only for Windows PowerShell 5.1.

function ConvertFrom-ReceiverCommandLine([string]$CommandLine) {
    if (-not ('ShortcutPassthrough.CommandLine' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ShortcutPassthrough {
    public static class CommandLine {
        [DllImport("shell32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern IntPtr CommandLineToArgvW(string value, out int count);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr value);
        public static string[] Parse(string value) {
            int count;
            IntPtr buffer = CommandLineToArgvW(value, out count);
            if (buffer == IntPtr.Zero) throw new InvalidOperationException("Cannot parse process arguments.");
            try {
                string[] result = new string[count];
                for (int i = 0; i < count; i++)
                    result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(buffer, i * IntPtr.Size));
                return result;
            } finally { LocalFree(buffer); }
        }
    }
}
'@ -ErrorAction Stop
    }
    return ,([ShortcutPassthrough.CommandLine]::Parse($CommandLine))
}

function Test-ReceiverIdentity {
    param($Evidence, [string]$ReceiverPath, [int]$Port, [string]$OwnerSid, [int]$SessionId)
    try {
        if (-not $Evidence -or -not $Evidence.CommandLine -or -not $OwnerSid -or
            $Evidence.OwnerSid -ne $OwnerSid -or $Evidence.SessionId -ne $SessionId -or
            -not $Evidence.CreationUtcTicks -or -not $Evidence.KernelStartUtcTicks) { return $false }
        $trusted = @(
            (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'),
            (Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe')
        )
        $exe = [IO.Path]::GetFullPath([string]$Evidence.ExecutablePath)
        if ($trusted -notcontains $exe) { return $false }
        $tokens = ConvertFrom-ReceiverCommandLine $Evidence.CommandLine
        if ($tokens.Count -lt 3) { return $false }
        $fileIndex = -1
        for ($i = 1; $i -lt $tokens.Count; $i++) {
            $flag = $tokens[$i].ToLowerInvariant()
            if ($flag -eq '-file') { $fileIndex = $i; break }
            if ($flag -in @('-nologo', '-noprofile', '-noninteractive')) { continue }
            if ($flag -eq '-windowstyle') {
                $i++
                if ($i -ge $tokens.Count -or $tokens[$i] -notin @('Hidden','Normal','Minimized','Maximized')) { return $false }
                continue
            }
            if ($flag -eq '-executionpolicy') {
                $i++
                if ($i -ge $tokens.Count -or $tokens[$i] -notin @('Bypass','RemoteSigned','AllSigned','Restricted','Default','Unrestricted')) { return $false }
                continue
            }
            # Do not mistake -Command or an encoded command for -File.
            return $false
        }
        if ($fileIndex -lt 0 -or $fileIndex + 1 -ge $tokens.Count) { return $false }
        if ([IO.Path]::GetFullPath($tokens[$fileIndex + 1]) -ne [IO.Path]::GetFullPath($ReceiverPath)) { return $false }
        $rest = $tokens.Count - $fileIndex - 2
        $actualPort = 47823
        if ($rest -ne 0) {
            if ($rest -ne 2 -or $tokens[$fileIndex + 2] -ne '-Port' -or
                -not [int]::TryParse($tokens[$fileIndex + 3], [ref]$actualPort)) { return $false }
        }
        return ($actualPort -ge 1 -and $actualPort -le 65535 -and $actualPort -eq $Port)
    } catch { return $false }
}

function Get-ReceiverProcessEvidence([int]$ProcessId) {
    try {
        $record = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if (-not $record -or -not $record.CreationDate) { return $null }
        $owner = Invoke-CimMethod -InputObject $record -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.ReturnValue -ne 0 -or -not $owner.Sid) { return $null }
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        try {
            $null = $process.Handle
            $kernelTicks = $process.StartTime.ToUniversalTime().Ticks
            $cimTicks = $record.CreationDate.ToUniversalTime().Ticks
            # CIM datetimes have microsecond precision. Match that declared precision here;
            # retain the kernel's complete ticks for exact identity comparisons before a stop.
            if (($kernelTicks - ($kernelTicks % 10)) -ne ($cimTicks - ($cimTicks % 10))) { return $null }
            return [pscustomobject]@{
                ProcessId = [int]$record.ProcessId
                ExecutablePath = [string]$record.ExecutablePath
                CommandLine = [string]$record.CommandLine
                OwnerSid = [string]$owner.Sid
                SessionId = [int]$record.SessionId
                CreationUtcTicks = $cimTicks
                KernelStartUtcTicks = $kernelTicks
            }
        } finally { $process.Dispose() }
    } catch { return $null }
}

function Test-ReceiverStartupEntry([string]$Entry, [string]$ExpectedContent) {
    if (-not (Test-Path -LiteralPath $Entry)) { return $false }
    if (-not (Test-Path -LiteralPath $Entry -PathType Leaf) -or
        [IO.File]::ReadAllText($Entry) -cne $ExpectedContent) {
        throw 'An unrecognized Startup entry exists; it was preserved.'
    }
    return $true
}

function New-ReceiverStartupEntry([string]$Entry, [string]$ExpectedContent) {
    # Reusing identical content needs no overwrite. CreateNew preserves a file that
    # another installer or the user creates between our check and the actual open.
    if (Test-ReceiverStartupEntry $Entry $ExpectedContent) { return $false }
    $stream = [IO.File]::Open($Entry, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::ASCII.GetBytes($ExpectedContent)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } finally { $stream.Dispose() }
    return $true
}

function Get-ReceiverPortState([int]$Port, [string]$ReceiverPath) {
    $queryErrors = @()
    $endpoints = @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue -ErrorVariable queryErrors)
    if (@($queryErrors | Where-Object { $_.CategoryInfo.Category -ne 'ObjectNotFound' }).Count) {
        throw 'Cannot inspect the receiver port; no processes or Startup entry were changed.'
    }
    $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $owned = @(); $conflicts = @()
    foreach ($targetId in @($endpoints | Select-Object -ExpandProperty OwningProcess -Unique)) {
        $evidence = Get-ReceiverProcessEvidence ([int]$targetId)
        if (Test-ReceiverIdentity $evidence $ReceiverPath $Port $ownerSid $sessionId) {
            $owned += $evidence
        } else { $conflicts += [int]$targetId }
    }
    return [pscustomobject]@{ Owned = $owned; Conflicts = $conflicts }
}

function Stop-OwnedReceiver {
    param($Evidence, [string]$ReceiverPath, [int]$Port)
    $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $fresh = Get-ReceiverProcessEvidence $Evidence.ProcessId
    if (-not (Test-ReceiverIdentity $fresh $ReceiverPath $Port $ownerSid $sessionId) -or
        $fresh.CreationUtcTicks -ne $Evidence.CreationUtcTicks -or
        $fresh.KernelStartUtcTicks -ne $Evidence.KernelStartUtcTicks -or
        $fresh.CommandLine -cne $Evidence.CommandLine -or
        $fresh.ExecutablePath -cne $Evidence.ExecutablePath) {
        throw 'Receiver identity changed or could not be verified; it was not stopped.'
    }
    $process = Get-Process -Id $fresh.ProcessId -ErrorAction Stop
    try {
        # Pin the actual handle before comparing its start time and stopping it.
        $null = $process.Handle
        if ($process.StartTime.ToUniversalTime().Ticks -ne $fresh.KernelStartUtcTicks) {
            throw 'Receiver process start time changed; it was not stopped.'
        }
        Stop-Process -InputObject $process -Force -ErrorAction Stop
        if (-not $process.WaitForExit(5000)) { throw 'Receiver did not exit in time.' }
        Write-Host "stopped verified receiver pid $($fresh.ProcessId)"
    } finally { $process.Dispose() }
}
