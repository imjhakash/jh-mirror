# Source map

All project source and build assets live in this folder. `Android Wireless.app` is the current app.

| Location | Edit here for |
|---|---|
| `main.swift` | Mac app, notifications, mirror lifecycle and launch options |
| `PhoneConnection.swift` | ADB discovery, phone identity checks and endpoint selection |
| `WifiConnection.swift` | Wi-Fi discovery, certificate pinning, paired trust and retry policy |
| `BridgeClient.swift` | Notification sync, Wi-Fi / ADB fallback with backoff, re-trust, companion upgrade, phone clipboard pull and Mac → phone sending |
| `Clipboard.swift` | Placing received images, text and files on the Mac clipboard |
| `FileTransferClient.swift` | Resumable downloads, SHA-256 verification and receipts |
| `PhoneTools.swift` | Sidebar buttons, draggable recent files, Mac → phone drop zone and window following |
| `PairPhone.swift` | Pairing dialog and endpoint validation |
| `android/src/local/androidwireless/bridge/` | Phone notification listener, TLS bridge, background service, file sharing, Copy to Mac (`ClipboardActivity`, `ClipboardTile`, share alias) and setup UI |
| `android/AndroidManifest.xml` and `android/res/` | Phone permissions, service declarations and resources |
| `scrcpy-5.0.1/app/src/` | Complete scrcpy client, including our window dots, edge dragging, clipboard commands and sidebar IPC |
| `scrcpy-5.0.1/server/src/` | Complete scrcpy Android server |
| `scrcpy-5.0.1/server/build_without_gradle.sh` | Server build, including paths with spaces and nested Java classes |
| `patches/scrcpy-5.0.1.patch` | Changes against the official 5.0.1 source archive |
| `packaging/`, `AppIcon.icns`, `make_icon.swift` | App metadata and icons needed to recreate the bundle |
| `build_all.py` and `build_android.py` | Repeatable builds, tests, library bundling and signing |
| `tests/` | Connection, TLS, pairing, transfer, clipboard and native window checks |
| `Legacy/` | Previous version backups, not the current app |

Modified scrcpy files:

- `app/meson.build`
- `app/src/events.h`
- `app/src/input_manager.c`
- `app/src/macos_window.h`
- `app/src/macos_window.m`
- `app/src/main.c`
- `app/src/screen.c`
- `server/build_without_gradle.sh`
