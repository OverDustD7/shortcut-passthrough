# serve-apk.ps1 -- hand the APK to the tablet over HTTP from the host.
# Serves exactly one file (plus a one-line index page); everything else is 404.
#
#   .\serve-apk.ps1
#   .\serve-apk.ps1 -Port 8080
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads .ps1 without a BOM as ANSI,
# so non-ASCII text can break string literals.
param(
    [int]$Port = 47824,
    [string]$Apk = (Join-Path $PSScriptRoot "..\build\shortcut-passthrough.apk")
)

if (-not (Test-Path $Apk)) { throw "APK not found: $Apk" }
$bytes = [System.IO.File]::ReadAllBytes($Apk)
$name  = 'shortcut-passthrough.apk'

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::IPv6Any, $Port)
$listener.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IPv6,
                                 [System.Net.Sockets.SocketOptionName]::IPv6Only, 0)
$listener.Start()

$addrs = Get-NetIPAddress -AddressFamily IPv4, IPv6 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '::1' -and $_.AddressState -eq 'Preferred' }
Write-Host "file: $Apk  ($([math]::Round($bytes.Length/1KB,1)) KB)"
Write-Host "open one of these in the tablet browser (IPv6 needs brackets):"
foreach ($a in $addrs) {
    $h = if ($a.IPAddress -like '*:*') { "[" + ($a.IPAddress -split '%')[0] + "]" } else { $a.IPAddress }
    Write-Host ("  http://" + $h + ":" + $Port + "/")
}
Write-Host "Use an address the tablet can actually reach; virtual/tunnel adapters usually cannot."

while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 3000
        $buf = New-Object byte[] 4096
        $req = ""
        try {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -gt 0) { $req = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n) }
        } catch { }

        $path = "/"
        if ($req -match '^GET\s+(\S+)') { $path = $matches[1] }
        $clientIp = $client.Client.RemoteEndPoint.ToString()

        if ($path -eq "/" -or $path -eq "/index.html") {
            $html = "<html><meta charset=utf-8><body style='font-family:sans-serif;padding:24px'>" +
                    "<h2>Shortcut Passthrough</h2><p><a href=/$name>Download $name</a> " +
                    "($([math]::Round($bytes.Length/1KB,1)) KB)</p>" +
                    "<p style='color:#666'>Install, set the host address, then enable the accessibility service.</p></body></html>"
            $body = [System.Text.Encoding]::UTF8.GetBytes($html)
            $head = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
        } elseif ($path -eq "/$name") {
            $body = $bytes
            $head = "HTTP/1.1 200 OK`r`nContent-Type: application/vnd.android.package-archive`r`nContent-Disposition: attachment; filename=$name`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
        } else {
            $body = [System.Text.Encoding]::UTF8.GetBytes("404")
            $head = "HTTP/1.1 404 Not Found`r`nContent-Length: 3`r`nConnection: close`r`n`r`n"
        }

        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        $stream.Write($body, 0, $body.Length)
        $stream.Flush()
        Write-Host ("{0}  {1}  {2}  -> {3} bytes" -f (Get-Date -Format 'HH:mm:ss'), $clientIp, $path, $body.Length)
    } catch {
        Write-Host "conn error: $($_.Exception.Message)"
    } finally {
        $client.Close()
    }
}
