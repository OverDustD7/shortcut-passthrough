# serve-apk.ps1 -- 把 APK 直接送到平板：主机上起一个单文件的 HTTP 下载页。
# 只服务 build\alttabpipe.apk 这一个文件，别的一概 404。Ctrl+C 结束。
param(
    [int]$Port = 47824,
    [string]$Apk = "$PSScriptRoot\alttabpipe\build\alttabpipe.apk"
)

if (-not (Test-Path $Apk)) { throw "APK 不存在: $Apk" }
$bytes = [System.IO.File]::ReadAllBytes($Apk)
$name = "alttabpipe.apk"

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::IPv6Any, $Port)
$listener.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IPv6,
                                 [System.Net.Sockets.SocketOptionName]::IPv6Only, 0)
$listener.Start()

$addrs = Get-NetIPAddress -AddressFamily IPv4, IPv6 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '::1' -and $_.AddressState -eq 'Preferred' }
Write-Host "服务: $Apk  ($([math]::Round($bytes.Length/1KB,1)) KB)" -ForegroundColor Cyan
Write-Host "在平板浏览器里打开下面任意一条（IPv6 要用方括号）：" -ForegroundColor Cyan
foreach ($a in $addrs) {
    $host_ = if ($a.IPAddress -like '*:*') { "[" + ($a.IPAddress -split '%')[0] + "]" } else { $a.IPAddress }
    Write-Host ("  http://" + $host_ + ":" + $Port + "/") -ForegroundColor Green
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
                    "<h2>AltTab 直通</h2><p><a href=/$name>下载 $name</a>（$([math]::Round($bytes.Length/1KB,1)) KB）</p>" +
                    "<p style='color:#666'>装完打开应用 → 填主机地址 → 打开无障碍并开启「AltTab 直通」</p></body></html>"
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
