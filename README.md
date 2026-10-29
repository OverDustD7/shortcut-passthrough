# Shortcut Passthrough

Forward **Alt+Tab** and **every Win-key combination** from an Android tablet's physical
keyboard to your Windows host — while the tablet keeps showing the remote desktop, without
flipping to its own recents screen and killing the stream.

No root. No client modification. No ADB.

```
tablet keyboard ──► accessibility key filter ──► UDP ──► host script ──► keybd_event
```

## Why this is needed

Android's input dispatcher handles a key event in this order
(`InputDispatcher::publishKeyEvent`):

```
1. interceptKeyBeforeQueueing        power / volume / wake
2. filterInputEvent                  accessibility key filter   <-- this app sits here
3. enqueueInboundEventLocked
4. interceptKeyBeforeDispatching     PhoneWindowManager: Alt+Tab -> recents
```

`PhoneWindowManager` consumes Alt+Tab at step 4 and returns `true`. Its condition is
`metaStateHasModifiers(shiftless, META_ALT_ON)`, and that function ends with
`return metaState == modifiers;` — the state must be **exactly** Alt and nothing else.
So from step 4 onward the remote-desktop client never sees Alt+Tab: the tablet opens its
own recent-apps screen instead, the client loses focus, and the stream stops.

Win-key combinations never even get that far: they are handled at step 1, before any app.

Step 2 comes before both, and **any ordinary app can request it** (`FLAG_REQUEST_FILTER_KEY_EVENTS`).
This app consumes the keys there and ships them to the host, which replays them for real.

## Repository layout

```
AndroidManifest.xml          the tablet app, built without Gradle (aapt2/javac/d8)
build.ps1
res/                         strings + accessibility service config
src/top/overdustd7/alttabpipe/
    AltTabPipeService.java     accessibility service: filter on/off, foreground detection
    KeyPolicy.java             key ownership (pure Java, unit-testable)
    ReleaseSafeQueue.java      send queue with guaranteed-release recovery (pure Java)
    MainActivity.java          configuration and diagnostics
test/PipeCoreTest.java       pure-JVM tests, no device needed
host/
    alttab-recv.ps1            UDP listener + key injection
    install-autostart.ps1      start it detached, bring it back at every logon
```

## Requirements

- Android 8.0+ (API 26) on the tablet, a physical keyboard, a remote-desktop client that
  you want to keep (tested with Moonlight).
- Windows 10/11 on the host, PowerShell 5.1.
- To build: an Android SDK with `build-tools` and one `platforms/android-*`, plus a JDK 8+
  (17 tested). No Gradle, no network.

## Build

```powershell
$env:ANDROID_HOME = 'C:\Android\Sdk'      # or pass -Sdk
$env:JAVA_HOME    = 'C:\Program Files\Java\jdk-17'
.\build.ps1
# -> build\shortcut-passthrough.apk
```

The script picks the newest `build-tools` and `platform`, compiles resources with `aapt2`,
compiles with `javac`, dexes with `d8`, aligns, and signs with a local debug keystore
(created on first run). Nothing else is touched.

## Install and run

1. Install the APK on the tablet.
2. Open **Shortcut Passthrough** and fill in:
   - **host address** — one of the addresses printed by the host script (IPv4 or IPv6,
     no port, no brackets),
   - **port** — default `47823`,
   - **target packages** — package prefixes that should take over keys, default
     `com.limelight`. **Empty means "never intercept"**, which is the safe default;
     write `*` only if you really want to intercept in every app.
3. Enable the accessibility service: the in-app button opens the settings page.
   On Android 13+ a sideloaded app first needs *Allow restricted settings* in its app info.
4. On the host:

   ```powershell
   .\host\install-autostart.ps1        # start now + entry in the startup folder
   .\host\install-autostart.ps1 -Uninstall
   ```

5. Press Alt+Tab, Win, Win+D, Win+Shift+S, Win+E … on the keyboard.

## Protocol

| Packet | Meaning |
|---|---|
| `ALT_TAB` / `ALT_TAB_REV` | host injects Alt+Tab / Shift+Alt+Tab |
| `KEY <androidKeyCode> <1\|0>` | press / release the matching Windows key |
| `RELEASE_ALL` | release everything the host is holding |
| `PING` | log only, for reachability checks |

UDP is best-effort. What is guaranteed is the **local send order**; a lost packet is covered
by the host-side 8-second stuck-key watchdog, not by retransmission.

## Design notes

- **The filter is only requested while a target app is in the foreground.** Having a key
  filter on at all makes every physical key wait for a synchronous round trip into this app;
  keeping it off elsewhere means normal typing never touches it.
- The foreground app is read from `getRootInActiveWindow()` (fallback: application windows
  from `getWindows()`), never from the event's package name. Notifications, IMEs and system
  dialogs also emit window events; trusting their package name turned the filter off by
  accident.
- The callback does integer checks and one queue offer: no string building, no preferences,
  no DNS, no network.
- Key releases are decided by **ownership** — which keys this app actually swallowed — not by
  the current modifier state. Otherwise `Win↓ D↓ Win↑ D↑` would drop the final `D↑`.
- Sending happens on one worker thread with a single socket, so order is preserved and the
  input callback never blocks on the network.
- When the queue is full, a lost *critical* packet (a release) is replaced by a deferred
  `RELEASE_ALL`; a lost ordinary packet is just dropped.
- Leaving the target app, unbinding the service, or shutting down sends `RELEASE_ALL` so the
  host cannot keep a key pressed.

## Verified

Emulator (Android 15 / API 35) with real kernel key events via `sendevent`:

| Scenario | Result |
|---|---|
| target app not in the foreground | no callback, no packet |
| target app in the foreground, 30 plain characters | callback ≤ 27 µs warm (2.4 ms on a cold first key), zero packets sent |
| `Win↓ D↓ Win↑ D↑` | four packets, correct order, final release present |
| `Alt↓ Tab↓ Alt↑ Tab↑` | exactly one `ALT_TAB`, no leaked `Tab` up |
| notification posted, then Alt+Tab | still forwarded — the system window no longer disables the filter |
| leaving the target app | `filter=false` plus `RELEASE_ALL -> released 1 held key(s)` |
| host unreachable / DNS unresolvable | callback stays ≈0.1 ms, process never blocks |

Pure-JVM tests for the key policy and the queue: `pass=9 fail=0`.

## Limitations

- **Win combinations still act on the tablet as well.** The system handles Meta at step 1,
  before any app can intercept it. This app makes the host react; it cannot stop the device.
  Suppressing the device side needs root (e.g. an Xposed module that disables the vendor's
  Win hotkeys) or a keyboard that does not send those keys.
- While streaming the filter has to stay on, so the per-key round trip is unavoidable there;
  the goal is to keep it as short as possible.
- If the service shows as enabled but nothing works, toggle the accessibility service off and
  on — a reinstall can leave it enabled-but-unbound (the app shows this as
  "service instance: not connected").
- Only one direction, keyboard only; mouse and text input are untouched.

## License

MIT — see [LICENSE](LICENSE).
