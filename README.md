# shortcut-passthrough

[![GitHub](https://img.shields.io/badge/GitHub-OverDustD7%2Fshortcut--passthrough-24292e)](https://github.com/OverDustD7/shortcut-passthrough)

English | [简体中文](README.zh-CN.md)

Forward Alt+Tab and every Win-key combination from an Android tablet's physical keyboard to a Windows host, without root and without touching the remote-desktop client. The tablet keeps showing the stream instead of jumping to its own recents screen.

The Android input dispatcher consumes Alt+Tab at `interceptKeyBeforeDispatching` and Win combinations even earlier, at `interceptKeyBeforeQueueing`, so a remote-desktop client never receives them. This app sits on the accessibility key filter, which runs between those two stages: it swallows the keys there, sends them over UDP, and a host script replays them with `keybd_event`.

## Requirements

- Tablet: Android 8.0 (API 26) or newer, a physical keyboard, and the remote-desktop client you want to keep (verified with Moonlight).
- Host: Windows 10/11 with Windows PowerShell 5.1.
- Building from source: an Android SDK with `build-tools` and one `platforms/android-*`, plus JDK 8 or newer (17 tested). No Gradle and no network access are needed.

## Installation

### From the release APK (recommended)

Download `shortcut-passthrough.apk` from the [latest release](https://github.com/OverDustD7/shortcut-passthrough/releases/latest) and install it on the tablet. On Android 13 and newer, a sideloaded app first needs *Allow restricted settings* in its app info before the accessibility service can be enabled.

### From source

```powershell
$env:ANDROID_HOME = 'C:\Android\Sdk'          # or pass -Sdk
$env:JAVA_HOME    = 'C:\Program Files\Java\jdk-17'
.\build.ps1
# -> build\shortcut-passthrough.apk
```

The script picks the newest `build-tools` and `platform`, compiles resources with `aapt2`, compiles with `javac`, dexes with `d8`, aligns, and signs with a local debug keystore created on first run. Nothing outside `build/` is written.

### Host side

```powershell
.\host\install-autostart.ps1              # start now, plus an entry in the Startup folder
.\host\install-autostart.ps1 -Uninstall   # remove the entry and stop the listener
```

The listener runs as an ordinary hidden PowerShell process under your own account. No administrator rights, scheduled task, or service is involved.

## Usage

1. Open **Shortcut Passthrough** on the tablet and fill in:
   - **host address** — one of the addresses printed by the host script, IPv4 or IPv6, without a port and without brackets;
   - **port** — default `47823`;
   - **target packages** — package prefixes that may take over keys, default `com.limelight`. Empty means *never intercept*, which is the safe default; write `*` only if you want interception in every app.
2. Enable the accessibility service. The in-app button opens the settings page directly.
3. Press Alt+Tab, Win, Win+D, Win+Shift+S, Win+E on the keyboard.

The app's home screen shows the filter state, the current foreground package, a history of recently seen packages, callback timing, packet counters, and a self-check button. All of it stays on the device.

## How it works

```
tablet keyboard -> accessibility key filter -> UDP -> host script -> keybd_event
```

- The key filter is only requested while a target package is in the foreground. Having a filter on at all makes every physical key wait for a synchronous round trip into the app, so outside the target app it is switched off and ordinary typing never touches it.
- The foreground package is read from `getRootInActiveWindow()`, falling back to application windows from `getWindows()`, and never from the event's package name. Notifications, input methods, and system dialogs also emit window events; trusting their package name switched the filter off by accident and made interception intermittent.
- The key callback does integer checks and one queue offer: no string building, no preferences, no DNS, no network.
- Releases are decided by ownership, meaning which keys this app actually swallowed, not by the current modifier state. Otherwise `Win down, D down, Win up, D up` would drop the final `D up`.
- Sending happens on one worker thread with one socket, so order is preserved and the input callback never blocks on the network.
- When the queue is full, a lost critical packet (a release) becomes a deferred `RELEASE_ALL`; a lost ordinary packet is dropped.
- Leaving the target app, unbinding the service, or shutting down sends `RELEASE_ALL`, so the host cannot keep a key pressed.

## Protocol

| Packet | Meaning |
|---|---|
| `ALT_TAB` / `ALT_TAB_REV` | host injects Alt+Tab / Shift+Alt+Tab |
| `KEY <androidKeyCode> <1\|0>` | press or release the matching Windows key |
| `RELEASE_ALL` | release everything the host is holding |
| `PING` | log only, for reachability checks |

UDP is best effort. What is guaranteed is the local send order; a lost packet is covered by the host's 8-second stuck-key watchdog, not by retransmission.

## Verification

Emulator running Android 15 (API 35), driven with real kernel key events through `sendevent`:

| Scenario | Result |
|---|---|
| target app not in the foreground | no callback, no packet |
| target app in the foreground, 30 plain characters | callback at most 27 microseconds warm (2.4 milliseconds on the first cold key), nothing sent |
| `Win down, D down, Win up, D up` | four packets, correct order, final release present |
| `Alt down, Tab down, Alt up, Tab up` | exactly one `ALT_TAB`, no leaked `Tab` up |
| system notification posted, then Alt+Tab | still forwarded; a system window no longer disables the filter |
| leaving the target app | `filter=false` and `RELEASE_ALL -> released 1 held key(s)` |
| host unreachable or DNS unresolvable | callback stays around 0.1 milliseconds, the process never blocks |

`KeyPolicy` and `ReleaseSafeQueue` are plain Java and covered by `test/PipeCoreTest.java`, which runs on the JVM without a device: `pass=9 fail=0`.

## Limitations

- **Win combinations still act on the tablet as well.** The system handles Meta before any app can intercept it. This app makes the host react; it cannot stop the device. Suppressing the device side needs root, for example an Xposed module that disables the vendor's Win hotkeys, or a keyboard that does not send those keys.
- While streaming the filter must stay on, so that per-key round trip cannot be removed, only kept short.
- If the service reads as enabled but nothing happens, toggle the accessibility service off and on. A reinstall can leave it enabled but unbound, which the app reports as *service instance: not connected*.
- Keyboard only, one direction. Mouse and text input are not touched.

## Repository layout

```
AndroidManifest.xml           tablet app, built without Gradle
build.ps1
res/                          strings and accessibility service config
src/top/overdustd7/alttabpipe/
    AltTabPipeService.java      accessibility service, filter and foreground handling
    KeyPolicy.java              key ownership, pure Java
    ReleaseSafeQueue.java       send queue with release recovery, pure Java
    MainActivity.java           configuration and diagnostics
test/PipeCoreTest.java        JVM tests, no device needed
host/
    alttab-recv.ps1             UDP listener and key injection
    serve-apk.ps1               one-file HTTP page for getting the APK onto the tablet
    install-autostart.ps1       detached start plus logon autostart
```

## License

MIT, see [LICENSE](LICENSE).
