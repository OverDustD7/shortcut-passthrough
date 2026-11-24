# Load the pairing code from this Windows user's DPAPI-protected local state.
function Get-PairingCodePath {
    $root = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $root) { throw 'Local application data is unavailable.' }
    return (Join-Path $root 'ShortcutPassthrough\pairing.dpapi')
}

function Read-PairingCode {
    $path = Get-PairingCodePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Pairing is required. Run setup-pairing.ps1 before starting the receiver.'
    }
    $protected = ConvertTo-SecureString (Get-Content -LiteralPath $path -Raw)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($protected)
    try {
        $code = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ($code -cnotmatch '\A[0-9a-f]{64}\z') { throw 'Invalid stored pairing code.' }
        return $code
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        $protected.Dispose()
    }
}
