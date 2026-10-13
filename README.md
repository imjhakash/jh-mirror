# Android Wireless 3.4

A personal Mac + Samsung companion built on scrcpy 5.0.1. Everything needed to edit this project is in this folder; see `SOURCE-MAP.md`. The current app is `Android Wireless.app`.

## Connection

Pair once using **Pair Phone**. Keep both devices on a reachable local Wi-Fi network and run Android Wireless on the Mac. Notification and selected-file sync use the companion's direct TLS connection, independent of ADB and the mirror window. The phone advertises its current address using Bonjour/Android NSD. A cached address is retained when discovery is temporarily absent.

The phone keeps its TLS private key in Android Keystore. Its certificate and random bearer token are provisioned through the already-authenticated ADB pairing. The Mac pins that certificate, rejects other certificates and refuses redirects. Pairing trust is stored privately in `~/Library/Application Support/Android Wireless/paired-wifi.json` (mode 600). Credentials are never put in this source folder. The original loopback ADB tunnel remains a fallback; plaintext ADB over port 5555 is not used.

A visible Android foreground service restores the encrypted channel after process restart or boot. This phone's Android Wireless package is exempted from battery optimization. While the paired Mac is actively polling, short CPU/Wi-Fi leases reduce sleep-related connection drops. Those leases expire after the Mac disconnects. This uses more battery while the Mac is connected. Force-stopping the phone app prevents Android from restarting it until it is opened again.

**Screen mirroring, control, audio and clipboard still require Android Wireless debugging to be enabled and reachable.** An app cannot guarantee that Android leaves debugging enabled after a reboot, a network change, revocation or a vendor power policy. Wi-Fi being on alone is enough for notification/file sync after this one-time setup; it is not sufficient for scrcpy if Android turns debugging off. Android's trusted-network feature may reconnect debugging automatically on supported system versions.

When the encrypted Wi-Fi channel fails, sync moves to the ADB tunnel immediately and Wi-Fi is re-probed with backoff (2 s up to 30 s) instead of delaying every poll. A network change on the Mac retries both channels at once. If the companion is reinstalled or its data cleared, the Mac re-learns its new certificate automatically over the authenticated ADB connection; **Pair Phone** also resets Wi-Fi trust. The phone's encrypted listener closes unauthenticated clients after 6 seconds, limits each network address to 3 connections, and uses a separate worker pool from the ADB fallback, so another device on the Wi-Fi cannot stall sync. The companion keeps its battery-optimization exemption: the Mac re-applies it on every connection and after updates.

The mirror stays closed only when you close it (red dot, ⌘Q in the phone window, or Close Screen). Any other exit, even a clean one, reconnects automatically with backoff. Each stop is logged with its reason in `connection.log`.

Live ADB endpoints take priority over old mDNS entries. The saved verified endpoint is retried even if mDNS is missing. Transient sync failures no longer immediately destroy a tunnel or restart the screen. Mirror retries wait 2, 4, 8, 16, then at most 30 seconds after failures. A working mirror is not restarted by notification timeouts. Actual network loss can still require a fresh scrcpy session. Position/size are retained during recovery. A small 50 ms video buffer absorbs Wi-Fi jitter.

## Copy on the phone, paste on the Mac

Anything copied to the Mac this way pastes with ⌘V in WhatsApp, Notes, Mail, Messages, Finder and other apps. Images paste as images (with the file as a fallback), copied text pastes as text, and other files paste as files. Each item is also saved in `~/Downloads/Android Wireless/`.

- **Share sheet:** select a photo, file or text → Share → **Copy to Mac**.
- **Anything already copied:** copy on the phone, then tap **Copy to Mac** in the Android Wireless notification, or add the **Copy to Mac** Quick Settings tile (edit tiles in the notification shade) and tap it.
- **From the Mac:** menu bar → **Copy Phone Clipboard to Mac**, or Phone Tools → Clipboard actions. The phone must be unlocked: Android lets only the focused app read the clipboard, so a brief transparent screen reads it once.

Delivery takes about a second on a working connection.

## Drag and drop

- **Phone → any Mac app:** the Phone Tools sidebar shows the latest four files from the phone. Drag one into WhatsApp, Mail, Finder or any app; click one to copy it for ⌘V.
- **Mac → phone:** drop files or folders on the sidebar's drop zone, or on the phone window. They are copied to the phone's Download folder without overwriting existing names. This uses Wireless debugging.

## Controls and sharing

The small sidebar follows the phone window. Audio and clipboard auto-sync toggles restart only the mirror when their settings change. Manual clipboard buttons work in each direction. Window Off hides the mirror while keeping the session alive. The red/yellow dots close or minimize the phone window; drag an outer edge or Option-drag to move it. Experimental multi-finger input has been removed.

On the phone, select files/photos → Share → Android Wireless, or use **Choose files to send to Mac**. The Mac saves verified files in `~/Downloads/Android Wireless/`. Interrupted transfers resume, SHA-256 is checked, existing names are preserved, and only staged companion copies are removed after acknowledgement. Original phone files stay on the phone.

Notifications retain their source app images in the panel. Native Mac alerts follow System Settings. The user's setting to suppress banners during screen sharing is preserved.

## Build from all included source

**Open at Login** in the menu-bar menu starts the app automatically after a restart.

Requirements on this Apple Silicon Mac: Xcode Command Line Tools (`swiftc`, `cc`, `codesign`), Python 3, Homebrew `meson`, `ninja`, `pkgconf`, `sdl3`, `ffmpeg`, `libusb`, `openjdk` and `android-platform-tools`. The Android SDK 36 is included in the hidden `.android-sdk` directory. Source files for both the scrcpy client and Android server are included; the server is built locally, not copied from Homebrew.

Quit Android Wireless before rebuilding, then run:

```sh
cd "/Users/jhakash/Downloads/Android Wireless Source"
python3 build_all.py --restart
```

`--restart` quits the running app, installs the new bundle and reopens it; without it the build refuses to replace a running app. The build runs every Mac test first (`--skip-tests` skips them). An older phone companion is upgraded automatically the next time the Mac app connects.

To update the already-paired phone APK, use its current **connection** endpoint (not the pairing popup port):

```sh
python3 build_all.py --deploy-phone --device 192.168.0.159:CURRENT_PORT
```

The build assembles a fresh Mac bundle from `packaging/` metadata (no stale files survive), compiles Swift and the modified scrcpy client, builds the full scrcpy server without Gradle, and builds/signs the companion APK. The mirror's Homebrew libraries (ffmpeg, SDL3, libusb and dependencies) are copied into `Phone Screen.app/Contents/Frameworks` and relinked, so `brew upgrade` cannot break the mirror; the build verifies the helper loads only bundled libraries. `adb` itself is still used from Homebrew (`android-platform-tools`).

The source is under git. `.gitignore` excludes build outputs, the SDK and the signing keystore.

`android/build/personal-signing.keystore` is the personal APK signing key needed for updates. **Back it up outside this folder** (for example an encrypted disk image or password manager); without it, updating the companion requires uninstalling it, which also removes notification access. It is excluded from git. `scrcpy-v5.0.1.tar.gz` is the original upstream archive. `patches/scrcpy-5.0.1.patch` records the client and server-build changes. Apache-2.0 licensing is retained under `scrcpy-5.0.1/LICENSE`.

## Validation and diagnostics

`python3 build_all.py` runs all of these. Individually:

```sh
swiftc PhoneConnection.swift WifiConnection.swift PairPhone.swift tests/network/main.swift -o /tmp/android-wireless-network-tests
/tmp/android-wireless-network-tests
swiftc Clipboard.swift tests/clipboard/main.swift -o /tmp/android-wireless-clipboard-tests
/tmp/android-wireless-clipboard-tests
python3 tests/tls/integration.py
python3 tests/file-transfer/integration.py
```

The clipboard test uses a private pasteboard and never touches the user's clipboard.

Connection tests cover stale discovery, cached-address recovery and bounded backoff. TLS tests cover trusted/untrusted certificates and redirect refusal. Transfer tests cover interrupted chunks, corruption, acknowledgement retry, duplicate names, unsafe names and empty files. `tests/pairing/` and `tests/window-controls/` retain the pairing parser and Cocoa window checks.

The Mac writes bounded mirror lifecycle diagnostics, without notification content or credentials, to `~/Library/Application Support/Android Wireless/connection.log`. A short live test is evidence for this tested session, not a guarantee against all future router/Android/OS disconnections.
