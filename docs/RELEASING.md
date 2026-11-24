# Release preparation

## Identify the candidate

Record the full commit, working-tree changes, Android manifest version, intended channel and actual candidate hashes. Preserve uncommitted work. Do not assume a source snapshot matches the last APK.

## Host checks

Run the ownership regression in a fresh Windows PowerShell process:

~~~powershell
powershell.exe -NoLogo -NoProfile -File .\test\ReceiverIdentityTest.ps1
~~~

It checks quoted arguments, source/executable/user/session/port identity, PID reuse, exact kernel creation identity, unavailable metadata, port conflicts and Startup content. It creates and stops one owned sleeping fixture; it never starts the receiver, opens UDP, installs Startup entries or injects keys.

Parse changed PowerShell files and confirm ASCII compatibility. A provider/identity-query denial is a failed verification, not an empty port or permission to stop another process.

## Android and packaging

For Android changes, use the installed SDK and JDK with `build.ps1`. The build may create root `debug.keystore` as well as `build/` output. Inspect the actual APK manifest, certificate and archive contents. A successful build/signature does not prove privacy or business behavior.

Pure Java key-policy tests can use an explicitly chosen temporary classes directory:

~~~powershell
javac -encoding UTF-8 -d '{{TEMP_CLASSES}}' src/top/overdustd7/alttabpipe/KeyPolicy.java src/top/overdustd7/alttabpipe/ReleaseSafeQueue.java test/PipeCoreTest.java
java -cp '{{TEMP_CLASSES}}' PipeCoreTest
~~~

Replace the placeholder with a new owned directory. Do not connect a real tablet or run device input commands without authorization. Reuse unchanged historical device evidence only within its recorded scope.

Distribute the installer, `receiver-identity.ps1` and receiver together. A host-only change does not by itself require a new APK; identify the source component separately and do not invent an Android version.

## Privacy and remaining security

Check actual distribution bytes, public source/docs, applicable history, screenshots, metadata and logs. Account identifiers, private addresses, paths and keystrokes must not enter public reports. Include extensionless text and newly added files; do not scan only already-matched lines.

Run the paired UDP loopback test with the Java sender and Windows receiver parser. It checks the authenticated handshake, encrypted commands, wrong keys, tampering, replay and receiver restart. Version 1.7 requires both components to be updated together. Production signing and a real paired-device input test remain separate release checks.

## Execution and rollback

Publication, replacement of old assets, signing-key changes and installation are separate actions. Prepare a reviewable candidate and evidence first.

Restore only this change's files from their pre-change copies when prior edits exist. Do not reset the whole worktree. Reverting source does not stop an installed receiver or remove public/history copies; treat those as separate authorized operations.
