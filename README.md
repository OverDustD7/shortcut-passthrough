# shortcut-passthrough

English | [简体中文](README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/OverDustD7/shortcut-passthrough?style=flat)](https://github.com/OverDustD7/shortcut-passthrough/releases)
[![Android](https://img.shields.io/badge/Android-8%2B-3DDC84?style=flat)](#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D4?style=flat)](#requirements)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat)](LICENSE)
[![GitHub source](https://img.shields.io/badge/GitHub-source-24292e?style=flat)](https://github.com/OverDustD7/shortcut-passthrough)

Forward Alt+Tab and Win-key combinations from an Android tablet's physical keyboard to a Windows host, using an accessibility service and a UDP receiver. No root or remote-desktop client modification is required.

## Status and support

The release badge identifies the published APK. Paired transport is in the 1.7 source and requires a matching 1.7 APK and Windows host directory.

Alt+Tab can be consumed on the tablet. Win combinations may still act on the tablet as well as the host. The recorded device verification used Moonlight; other clients and vendor Android builds need their own checks.

## Requirements

- Android 8.0 / API 26 or later, a physical keyboard and permission to enable the accessibility service.
- Windows 10/11 with Windows PowerShell 5.1 for the receiver.
- A trusted network and a pairing code shared between the tablet and Windows host.
- For building: a preinstalled Android SDK with build-tools and an Android platform, plus a compatible JDK. JDK 17 was used in the recorded build; the minimum JDK version has not been revalidated.

## Installation

Build and install the 1.7 APK from this source, or use a matching [Release](https://github.com/OverDustD7/shortcut-passthrough/releases) when available. If Android blocks the sideloaded accessibility service, review the app's restricted-settings controls before enabling it.

For Windows, obtain the complete `host/` directory from the same source checkout. Keep the full directory in an ASCII-only path. Run the pairing setup as the Windows user who will run the receiver:

~~~powershell
.\host\setup-pairing.ps1
.\host\setup-pairing.ps1 -Show
.\host\install-autostart.ps1
~~~

This starts a hidden receiver and creates a current-user Startup entry. It does not install a Windows service or scheduled task. Success is reported only when the newly started process owns the selected UDP port.

The installer refuses an unrelated port owner or an unrecognized Startup entry. If Windows does not permit the necessary identity queries, it stops rather than guessing which process to terminate.

## Quick start

1. Open **Shortcut Passthrough** on the tablet.
2. Enter the Windows host address without a port or brackets, the UDP port (default `47823`), the host pairing code, and target package prefixes such as `com.limelight`. Tap **Verify host pairing** to check the connection.
3. Enable the accessibility service. An empty target list means no interception; `*` enables interception in every app.
4. Press Alt+Tab and the required Win combinations while the target app is foreground.

The app reports the service/filter state and packet counters. Check that the host receives the intended shortcut and that leaving the target app releases held keys. A packet counter alone does not prove successful host input.

## Configuration, data and permissions

The Android app uses accessibility/window information to identify the foreground app and filter shortcut events. It requests network and foreground-service permissions, notification permission and an optional battery-optimization exemption. Configuration and diagnostics stay in app storage or memory; Android backup is disabled in the manifest.

Shortcut events are sent to the configured host. The receiver logs packet types, key codes and remote addresses locally. Foreground-package information, addresses, logs and screenshots can reveal usage information; redact them before sharing.

The tablet and receiver verify the shared code before forwarding. Each command is encrypted with AES-256-CBC and authenticated with HMAC-SHA256 using separate keys. The receiver rejects legacy plaintext, wrong keys, invalid tags, repeated or out-of-order sequence numbers and frames from an earlier receiver run. Store the code privately. Windows stores it with current-user DPAPI, and Android stores it in the app’s private settings. Restrict the UDP port to the tablet on the local network.

The APK is debug-signed using the project's debug keystore. This is not a private production signing identity. A stronger distribution/signing policy remains a separate requirement.

## Upgrade and uninstall

Keep the complete host directory together when updating it. Before replacing a signing key, review Android's upgrade and data-retention requirements; this project does not rotate keys automatically.

To remove this checkout's Startup entry and receiver:

~~~powershell
.\host\install-autostart.ps1 -Uninstall
~~~

Use the same `-Port` value if you installed with a custom port. The ownership check requires the exact script, trusted PowerShell executable, current user/session, arguments and process creation identity. Unrecognized launches are preserved for manual review.

Host logs and source files are retained. Disable the accessibility service and uninstall the Android app to remove that side; app-local settings are removed by normal Android uninstall behavior.

## Limitations and troubleshooting

- Win shortcuts can still affect Android; suppressing all vendor system handling is outside this app's non-root design.
- The accessibility key filter adds a per-key round trip while active.
- UDP is best effort. Local send ordering and the host's eight-second stuck-key watchdog do not guarantee packet delivery.
- If the service is enabled but disconnected after reinstall, toggle the accessibility service and recheck its status.
- Keyboard only, one direction. This is not a mouse or general text-input transport.
- A conflicting port or unrecognized Startup entry is not overwritten or stopped. Review the owner manually or choose a separate port.
- Update both ends together. The 1.6 plaintext protocol is incompatible with 1.7 pairing. Production signing remains a separate release requirement.

## Development

Build from source with local SDK/JDK paths:

~~~powershell
$env:ANDROID_HOME = '{{ANDROID_SDK}}'
$env:JAVA_HOME = '{{JDK_DIR}}'
.\build.ps1
~~~

The build produces `build/shortcut-passthrough.apk` and may create `debug.keystore` at the repository root if it is absent. It uses installed tools and does not download build dependencies.

Run the receiver ownership regression in a fresh Windows PowerShell process:

~~~powershell
powershell.exe -NoLogo -NoProfile -File .\test\ReceiverIdentityTest.ps1
~~~

The test uses synthetic metadata plus a self-owned sleeping process. It does not start the keyboard receiver, open a UDP listener, install Startup entries or inject keys.

[Implementation notes and previous device verification](docs/IMPLEMENTATION.en.md) preserve the dispatcher/filter explanation, protocol, queue/release handling, recorded measurements and repository layout. Those device measurements are historical, not a new device acceptance run.

## Feedback and security

Use [Issues](https://github.com/OverDustD7/shortcut-passthrough/issues) for non-sensitive bugs. No private security-reporting channel is advertised. Do not post keystrokes, private addresses, accounts, full logs or unredacted screenshots publicly.

## License and third-party notices

MIT; see [LICENSE](LICENSE). Existing copyright notices remain in that file. Referenced remote-desktop clients are separate projects and are not bundled here.
