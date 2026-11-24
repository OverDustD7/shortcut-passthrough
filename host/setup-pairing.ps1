# Run under the same Windows account as the receiver.
param([switch]$Show)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pairing-code.ps1')
if ($Show) {
    Read-PairingCode
    return
}

$path = Get-PairingCodePath
if (Test-Path -LiteralPath $path) { throw 'Pairing already exists. Use -Show to retrieve the current code.' }
[IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
$bytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$code = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
[Array]::Clear($bytes, 0, $bytes.Length)
$secure = ConvertTo-SecureString $code -AsPlainText -Force
try { $encrypted = ConvertFrom-SecureString $secure } finally { $secure.Dispose(); $code = $null }
$data = [Text.Encoding]::ASCII.GetBytes($encrypted)
$stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($data, 0, $data.Length) } finally { $stream.Dispose() }
Write-Host 'Pairing created. Run setup-pairing.ps1 -Show privately to copy the code to your tablet.'
