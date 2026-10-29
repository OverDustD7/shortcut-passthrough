# alttab-recv.ps1 -- host side of shortcut-passthrough.
# Listens on UDP <Port> and replays what the tablet sends:
#   ALT_TAB / ALT_TAB_REV      -> inject one Alt+Tab (or Shift+Alt+Tab)
#   KEY <androidKeyCode> <1|0> -> press/release the matching Windows key
#   RELEASE_ALL                -> release every key this script is holding
#   PING                       -> log only (reachability check)
#
# Why: on Android the system turns Alt+Tab into "recent apps" at
# PhoneWindowManager.interceptKeyBeforeDispatching, and Win combos never reach apps.
# The tablet app grabs them one step earlier (accessibility key filter) and sends them here.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads .ps1 without a BOM as ANSI,
# so non-ASCII text inside the embedded C# breaks Add-Type.
param(
    [int]$Port = 47823,
    [string]$Log = (Join-Path $PSScriptRoot 'alttab-recv.log')
)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public class AltTabInject
{
    [DllImport("user32.dll")] static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
    const byte VK_TAB = 0x09, VK_MENU = 0x12, VK_SHIFT = 0x10;
    const uint KEYUP = 0x2;
    static void D(byte v) { keybd_event(v, 0, 0, UIntPtr.Zero); }
    static void U(byte v) { keybd_event(v, 0, KEYUP, UIntPtr.Zero); }
    static bool Held(byte v) { return (GetAsyncKeyState(v) & 0x8000) != 0; }

    // The tablet forwards Alt itself, so the host usually already has Alt held:
    // then we only tap Tab, and "hold Alt, tap Tab to cycle" keeps working.
    public static string Fire(bool reverse)
    {
        Thread.Sleep(40);
        bool altHeld = Held(VK_MENU);
        bool shiftHeld = Held(VK_SHIFT);
        if (!altHeld) D(VK_MENU);
        if (reverse && !shiftHeld) D(VK_SHIFT);
        Thread.Sleep(10);
        D(VK_TAB); Thread.Sleep(15); U(VK_TAB);
        Thread.Sleep(10);
        if (reverse && !shiftHeld) U(VK_SHIFT);
        if (!altHeld) U(VK_MENU);
        return "altHeld=" + altHeld + " shiftHeld=" + shiftHeld + " reverse=" + reverse;
    }
}

public class KeyRelay
{
    [DllImport("user32.dll")] static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    const uint KEYUP = 0x2;
    static readonly HashSet<byte> down = new HashSet<byte>();
    static readonly object gate = new object();
    static DateTime last = DateTime.UtcNow;

    public static string Relay(int android, bool isDown)
    {
        int vk = Map(android);
        if (vk < 0) return "unmapped android key " + android;
        lock (gate)
        {
            last = DateTime.UtcNow;
            if (isDown)
            {
                if (!down.Contains((byte)vk)) { keybd_event((byte)vk, 0, 0, UIntPtr.Zero); down.Add((byte)vk); }
            }
            else
            {
                keybd_event((byte)vk, 0, KEYUP, UIntPtr.Zero);
                down.Remove((byte)vk);
            }
            return "vk=0x" + vk.ToString("X2") + (isDown ? " DOWN" : " up  ") + " (held=" + down.Count + ")";
        }
    }

    // Called when the tablet leaves the target app or turns the filter off:
    // release everything still held so the host cannot keep a stuck Win/Shift.
    public static string ReleaseAll()
    {
        lock (gate)
        {
            int n = down.Count;
            foreach (byte vk in down) keybd_event(vk, 0, KEYUP, UIntPtr.Zero);
            down.Clear();
            last = DateTime.UtcNow;
            return "released " + n + " held key(s)";
        }
    }

    // If the tablet disappears while holding keys, release them eventually.
    public static string Tick()
    {
        lock (gate)
        {
            if (down.Count > 0 && (DateTime.UtcNow - last).TotalSeconds > 8.0)
            {
                int n = down.Count;
                foreach (byte vk in down) keybd_event(vk, 0, KEYUP, UIntPtr.Zero);
                down.Clear();
                return "watchdog: released " + n + " stuck key(s)";
            }
        }
        return null;
    }

    static int Map(int a)
    {
        if (a >= 29 && a <= 54) return 0x41 + (a - 29);       // A-Z
        if (a >= 7 && a <= 16) return 0x30 + (a - 7);         // 0-9
        if (a >= 131 && a <= 142) return 0x70 + (a - 131);    // F1-F12
        switch (a)
        {
            case 19: return 0x26;   // DPAD_UP
            case 20: return 0x28;   // DPAD_DOWN
            case 21: return 0x25;   // DPAD_LEFT
            case 22: return 0x27;   // DPAD_RIGHT
            case 55: return 0xBC;   // COMMA
            case 56: return 0xBE;   // PERIOD
            case 57: return 0xA4;   // ALT_LEFT
            case 58: return 0xA5;   // ALT_RIGHT
            case 59: return 0xA0;   // SHIFT_LEFT
            case 60: return 0xA1;   // SHIFT_RIGHT
            case 61: return 0x09;   // TAB
            case 62: return 0x20;   // SPACE
            case 66: return 0x0D;   // ENTER
            case 67: return 0x08;   // DEL = backspace
            case 68: return 0xC0;   // GRAVE
            case 69: return 0xBD;   // MINUS
            case 70: return 0xBB;   // EQUALS
            case 71: return 0xDB;   // [
            case 72: return 0xDD;   // ]
            case 73: return 0xDC;   // backslash
            case 74: return 0xBA;   // ;
            case 75: return 0xDE;   // '
            case 76: return 0xBF;   // /
            case 82: return 0x5D;   // MENU = apps key
            case 92: return 0x21;   // PAGE_UP
            case 93: return 0x22;   // PAGE_DOWN
            case 111: return 0x1B;  // ESCAPE
            case 112: return 0x2E;  // FORWARD_DEL
            case 113: return 0xA2;  // CTRL_LEFT
            case 114: return 0xA3;  // CTRL_RIGHT
            case 115: return 0x14;  // CAPS_LOCK
            case 117: return 0x5B;  // META_LEFT = Win
            case 118: return 0x5C;  // META_RIGHT
            case 120: return 0x2C;  // SYSRQ = print screen
            case 122: return 0x24;  // MOVE_HOME
            case 123: return 0x23;  // MOVE_END
            case 124: return 0x2D;  // INSERT
            case 143: return 0x90;  // NUM_LOCK
            default: return -1;
        }
    }
}
'@

function Write-Log($s) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + ' ' + $s
    Write-Host $line
    try { Add-Content -Path $Log -Value $line -Encoding UTF8 } catch { }
}

# dual-stack listener: the tablet may reach us over IPv6
# dual-stack listener: the tablet may reach us over IPv6.
# The previous instance may still hold the port for a moment, so retry the bind.
$sock = $null
for ($i = 1; $i -le 5 -and $null -eq $sock; $i++) {
    try {
        $s = New-Object System.Net.Sockets.Socket(
            [System.Net.Sockets.AddressFamily]::InterNetworkV6,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp)
        $s.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IPv6,
                           [System.Net.Sockets.SocketOptionName]::IPv6Only, 0)
        $s.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::IPv6Any, $Port)))
        $sock = $s
        Write-Log "listening [::]:$Port (IPv4+IPv6)"
    } catch {
        if ($s) { try { $s.Dispose() } catch { } }
        try {
            $s4 = New-Object System.Net.Sockets.Socket(
                [System.Net.Sockets.AddressFamily]::InterNetwork,
                [System.Net.Sockets.SocketType]::Dgram,
                [System.Net.Sockets.ProtocolType]::Udp)
            $s4.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)))
            $sock = $s4
            Write-Log "listening 0.0.0.0:$Port (IPv4 only)"
        } catch {
            if ($s4) { try { $s4.Dispose() } catch { } }
            Write-Log ("bind attempt " + $i + " failed: " + $_.Exception.Message)
            Start-Sleep -Milliseconds 700
        }
    }
}
if ($null -eq $sock) { throw "could not bind UDP $Port" }
$sock.ReceiveTimeout = 1000


Write-Log "--- host addresses (put one of these into the tablet app) ---"
Get-NetIPAddress -AddressFamily IPv4, IPv6 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '::1' -and $_.AddressState -eq 'Preferred' } |
    ForEach-Object { Write-Log ("    " + $_.IPAddress + "  (" + $_.InterfaceAlias + ")") }
Write-Log "ready"

$buf = New-Object byte[] 512
while ($true) {
    $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::IPv6Any, 0)
    try {
        $n = $sock.ReceiveFrom($buf, [ref]$remote)
        if ($n -le 0) { continue }
    } catch [System.Net.Sockets.SocketException] {
        $t = [KeyRelay]::Tick()
        if ($t) { Write-Log $t }
        continue
    } catch {
        Write-Log "receive error: $($_.Exception.Message)"
        continue
    }

    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n).Trim()
    if ($text -eq 'ALT_TAB' -or $text -eq 'ALT_TAB_REV') {
        $r = [AltTabInject]::Fire($text -eq 'ALT_TAB_REV')
        Write-Log ("ALT  $text from " + $remote.Address + " -> $r")
    } elseif ($text -match '^KEY (\d+) ([01])$') {
        $code = [int]$matches[1]
        $isDown = ($matches[2] -eq '1')
        $r = [KeyRelay]::Relay($code, $isDown)
        Write-Log ("KEY  a$code " + $(if ($isDown) { "down" } else { "up" }) + " from " + $remote.Address + " -> $r")
    } elseif ($text -eq 'RELEASE_ALL') {
        $r = [KeyRelay]::ReleaseAll()
        Write-Log ("REL  RELEASE_ALL from " + $remote.Address + " -> $r")
    } elseif ($text -eq 'PING') {
        Write-Log ("PING from " + $remote.Address + " (tablet can reach this host)")
    } else {
        Write-Log ("?    '" + $text + "' from " + $remote.Address)
    }
}
