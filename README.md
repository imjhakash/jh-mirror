# Android Wireless 3.3

A personal Mac + Samsung companion built on scrcpy 5.0.1. Everything needed to edit this project is in this folder; see `SOURCE-MAP.md`. The current app is `Android Wireless.app`.

## Connection

Pair once using **Pair Phone**. Keep both devices on a reachable local Wi-Fi network and run Android Wireless on the Mac. Notification and selected-file sync use the companion's direct TLS connection, independent of ADB and the mirror window. The phone advertises its current address using Bonjour/Android NSD. A cached address is retained when discovery is temporarily absent.

The phone keeps its TLS private key in Android Keystore. Its certificate and random bearer token are provisioned through the already-authenticated ADB pairing. The Mac pins that certificate, rejects other certificates and refuses redirects. Pairing trust is stored privately in `~/Library/Application Support/Android Wireless/paired-wifi.json` (mode 600). Credentials are never put in this source folder. The original loopback ADB tunnel remains a fallback; plaintext ADB over port 5555 is not used.

A visible Android foreground service restores the encrypted channel after process restart or boot. This phone's Android Wireless package is exempted from battery optimization. While the paired Mac is actively polling, short CPU/Wi-Fi leases reduce sleep-related connection drops. Those leases expire after the Mac disconnects. This uses more battery while the Mac is connected. Force-stopping the phone app prevents Android from restarting it until it is opened again.

**Screen mirroring, control, audio and clipboard still require Android Wireless debugging to be enabled and reachable.** An app cannot guarantee that Android leaves debugging enabled after a reboot, a network change, revocation or a vendor power policy. Wi-Fi being on alone is enough for notification/file sync after this one-time setup; it is not sufficient for scrcpy if Android turns debugging off. Android's trusted-network feature may reconnect debugging automatically on supported system versions.

Live ADB endpoints take priority over old mDNS entries. The saved verified endpoint is retried even if mDNS is missing. Transient sync failures no longer immediately destroy a tunnel or restart the screen. Mirror retries wait 2, 4, 8, 16, then at most 30 seconds after failures. A working mirror is not restarted by notification timeouts. Actual network loss can still require a fresh scrcpy session. Position/size are retained during recovery. A small 50 ms video buffer absorbs Wi-Fi jitter.

## Controls and sharing

The small sidebar follows the phone window. Audio and clipboard auto-sync toggles restart only the mirror when their settings change. Manual clipboard buttons work in each direction. Window Off hides the mirror while keeping the session alive. The red/yellow dots close or minimize the phone window; drag an outer edge or Option-drag to move it. Experimental multi-finger input has been removed.

On the phone, select files/photos → Share → Android Wireless, or use **Choose files to send to Mac**. The Mac saves verified files in `~/Downloads/Android Wireless/`. Interrupted transfers resume, SHA-256 is checked, existing names are preserved, and only staged companion copies are removed after acknowledgement. Original phone files stay on the phone.

Notifications retain their source app images in the panel. Native Mac alerts follow System Settings. The user's setting to suppress banners during screen sharing is preserved.

## Build from all included source

Requirements on this Apple Silicon Mac: Xcode Command Line Tools (`swiftc`, `cc`, `codesign`), Python 3, Homebrew `meson`, `ninja`, `pkgconf`, `sdl3`, `ffmpeg`, `libusb`, `openjdk` and `android-platform-tools`. The Android SDK 36 is included in the hidden `.android-sdk` directory. Source files for both the scrcpy client and Android server are included; the server is built locally, not copied from Homebrew.

Quit Android Wireless before rebuilding, then run:

```sh
cd "/Users/jhakash/Downloads/Android Wireless Source"
python3 build_all.py
open "Android Wireless.app"
```

To update the already-paired phone APK, use its current **connection** endpoint (not the pairing popup port):

```sh
python3 build_all.py --deploy-phone --device 192.168.0.159:CURRENT_PORT
```

The build recreates the Mac bundle from `packaging/` metadata, compiles Swift and the modified scrcpy client, builds the full scrcpy server without Gradle, builds/signs the companion APK, and signs/verifies the Mac bundle. Homebrew runtime libraries remain dependencies on this machine; this folder is not a standalone distribution for another Mac.

`android/build/personal-signing.keystore` is the personal APK signing key needed for updates. Preserve it privately; exclude it when sharing source. `scrcpy-v5.0.1.tar.gz` is the original upstream archive. `patches/scrcpy-5.0.1.patch` records the client and server-build changes. Apache-2.0 licensing is retained under `scrcpy-5.0.1/LICENSE`.

## Validation and diagnostics

```sh
swiftc PhoneConnection.swift WifiConnection.swift PairPhone.swift tests/network/main.swift -o /tmp/android-wireless-network-tests
/tmp/android-wireless-network-tests
python3 tests/tls/integration.py
python3 tests/file-transfer/integration.py
```

Connection tests cover stale discovery, cached-address recovery and bounded backoff. TLS tests cover trusted/untrusted certificates and redirect refusal. Transfer tests cover interrupted chunks, corruption, acknowledgement retry, duplicate names, unsafe names and empty files. `tests/pairing/` and `tests/window-controls/` retain the pairing parser and Cocoa window checks.

The Mac writes bounded mirror lifecycle diagnostics, without notification content or credentials, to `~/Library/Application Support/Android Wireless/connection.log`. A short live test is evidence for this tested session, not a guarantee against all future router/Android/OS disconnections.
