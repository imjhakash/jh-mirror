# Source map

JH Mirror by Johirul Hoq Akash. All source and build assets live in this folder; `python3 build_all.py` builds `dist.noindex/JH Mirror.app` (and installs it to `/Applications` with `--install`).

| Location | Edit here for |
|---|---|
| `AppInstanceLock.swift` | Shared private single-process ownership across installed/review copies, before starting ADB or queues |
| `main.swift` | Mac app, interactive notifications, first run and migration, mirror lifecycle, menus |
| `PhoneConnection.swift` | ADB discovery, phone identity checks and endpoint selection |
| `WifiConnection.swift` | Wi-Fi discovery, certificate pinning, paired trust and retry policy |
| `BridgeClient.swift` | Phone app install and permission grants, notification commands (open/reply/dismiss), notification sync, Wi-Fi / ADB fallback with backoff, re-trust, companion upgrade, phone clipboard pull and Mac → phone sending |
| `Clipboard.swift` | Placing received images, text and files on the Mac clipboard |
| `MenuBarPopover.swift` | Menu-bar popover: live preview reader, Open Window / Clipboard / Reconnect |
| `AutoClipboard.swift` | Automatic phone → Mac clipboard: watcher supervision, image fetch, dedupe |
| `PhoneFiles.swift`, `PhoneFilesBrowser.swift`, `PhoneFileTransfers.swift`, `PhoneMediaActions.swift`, `PhoneFilesWindow.swift` | Shared-storage file/media browser, cancellable navigation and listing cache, Finder promises, verified transfers, Quick Look, bulk clipboard and confirmed photo deletion |
| `PhoneThumbnailLoader.swift` | Visible-tile batched streaming, background decoding, cancellation and private persistent grid cache |
| `PhonePreviewLoader.swift`, `PhoneMediaPreviewWindow.swift` | Bounded decoded preview cache, nearby-image prefetch, latest-only rendering, immediate thumbnails and animated keyboard/trackpad photo navigation |
| `DeviceHealth.swift`, `DeviceHealthLauncher.swift`, `DeviceHealthWindow.swift` | Per-feature platform/runtime signals, read-only checks, guarded actions, actionable errors and phone status reports |
| `PhoneWindowFlow.swift` | Resume the last content window or mirror, restore minimized work, exclude utility panels and keep the dashboard explicit |
| `FileTransferClient.swift` | Resumable downloads, SHA-256 verification and receipts |
| `PhoneTools.swift` | Sidebar buttons, draggable recent files, Mac → phone drop zone and window following |
| `PhoneTouchGuard.swift` | ADB touch-guard preparation, lease renewal, release and fail-safe lifecycle |
| `PhoneCalls.swift`, `CallDevices.swift` | Phone camera/mic sessions, direct frame delivery, compatibility-mode FIFO/OBS ownership and Mac microphone recovery |
| `CallCamera.swift` | Stable camera-device identity and read-only device discovery |
| `CameraWindow.swift` | Live camera preview, front/rear selection, rotation, mirror and start/stop controls |
| `PhoneApps.swift`, `PhoneAppsWindow.swift`, `PhoneAppTile.swift` | Daily persistent per-phone/user inventory cache, four-column icon drawer beside the mirror, fresh launch checks and confirmed current-user uninstall |
| `android/src/com/johirulhoqakash/jhmirror/AppLibrary*.java` | Read-only installed-app metadata and icons, streamed through a DUMP-protected content provider |
| `OBSConnection.swift`, `CallSetup.swift`, `CALLS.md` | Loopback OBS WebSocket v5, Keychain authentication, call-device setup and limits |
| `PairPhone.swift` | QR-code and pairing-code pairing, endpoint validation |
| `android/src/com/johirulhoqakash/jhmirror/` | Phone notification listener with Mac actions (open, reply, dismiss), Wireless debugging restore, TLS bridge, background service, file sharing, Copy to Mac (`ClipboardActivity`, `ClipboardTile`, share alias) and setup UI |
| `android/AndroidManifest.xml` and `android/res/` | Phone permissions, service declarations and resources |
| `scrcpy-5.0.1/app/src/` | Complete scrcpy client, including our window dots, edge dragging, clipboard commands, sidebar IPC and the menu-bar preview sink (`aw_preview.c`) and direct Core Media I/O camera sender (`aw_camera_sink.m`) |
| `scrcpy-5.0.1/server/src/` | Complete scrcpy Android server, plus our `ClipboardWatcher.java` |
| `scrcpy-5.0.1/server/build_without_gradle.sh` | Server build, including paths with spaces and nested Java classes |
| `patches/scrcpy-5.0.1.patch` | Changes against the official 5.0.1 source archive |
| `packaging/`, `AppIcon.icns`, `make_icon.swift` | App metadata, the disk-image install guide, and the icon (drawn in code) |
| `build_all.py` and `build_android.py` | Repeatable builds, tests, library bundling and signing |
| `packaging/release.py` | One-file installer at `release/JH Mirror.dmg`; signature, external-runtime, relocation and mounted-image verification |
| `packaging/Quick Start.html`, `CallSetup.swift` | Embedded offline guide, optional OBS/BlackHole official links, passive setup status and manual actions |
| `tests/` | Connection, TLS, pairing, transfer, clipboard and native window checks |
| `Legacy/` | Backups of the original "Android Wireless" launcher, not the current app |

Modified scrcpy files:

- `app/meson.build`
- `app/src/cli.c` (keeps headless camera output enabled)
- `app/src/events.h`
- `app/src/input_manager.c`
- `app/src/control_msg.c`, `app/src/control_msg.h` (one-byte session activity and no-wake display-intent controls)
- `app/src/macos_window.h`
- `app/src/macos_window.m`
- `app/src/aw_camera_sink.m`, `app/src/aw_camera_sink.h` (new)
- `app/src/aw_preview.c`, `app/src/aw_preview.h` (new)
- `app/src/main.c`
- `app/src/scrcpy.c`
- `app/src/server.c`, `app/src/server.h` (opt-in persistent dark-display behavior)
- `app/src/screen.c`
- `app/src/audio_player.c`, `app/src/audio_player.h`
- `app/src/recorder.c`
- `server/build_without_gradle.sh`
- `server/src/main/java/com/genymobile/scrcpy/ClipboardWatcher.java` (new)
- `server/src/main/java/com/genymobile/scrcpy/JHFiles.java` (new; one-shot ADB file operations and bounded media thumbnails)
- `server/src/main/java/com/genymobile/scrcpy/Options.java`, `CleanUp.java` (JH-only dark intent and exit behavior)
- `server/src/main/java/com/genymobile/scrcpy/control/ControlMessage.java`, `ControlMessageReader.java`, `Controller.java` (activity pulse, live display control and no-wake intent acknowledgement)

`native/` and `build_native.py` contain an uninstalled future camera/audio prototype. They are excluded from the shipping app; see `native/README.md`.

The phone UI uses `MainActivity.java`, `PhoneUi.java` and `DeviceStatus.java`; `PickFilesActivity.java` is the transient picker and `ShareActivity.java` closes successful quiet shares. `JHMediaQuery.java` selects version-compatible MediaStore columns. Generated Android UI/quiet-share checks are isolated under `tests/phone-ui/` and excluded from the shipping app.
