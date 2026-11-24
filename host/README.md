# Windows receiver

Keep `install-autostart.ps1`, `receiver-identity.ps1` and `alttab-recv.ps1` together in this directory. Use Windows PowerShell 5.1 on Windows 10/11.

Use the paired 1.7 Android APK with this host directory. Run `setup-pairing.ps1` to create a Windows current-user DPAPI-protected code, then run `setup-pairing.ps1 -Show` privately to copy it into the Android app. The receiver requires the code before it binds and accepts only authenticated, encrypted traffic from a paired client. Keep the full host directory together.

To install and start this copy deliberately:

```powershell
.\install-autostart.ps1
```

To remove its verified receiver and matching current-user Startup entry:

```powershell
.\install-autostart.ps1 -Uninstall
```

The installer verifies source path, trusted executable, owner, session, port and process creation identity. An unknown port owner or Startup entry causes failure and is preserved. Review the root project README for the Android installation, privacy and remaining signing/protocol limitations. Merely unpacking this candidate does not start a receiver or install anything.
