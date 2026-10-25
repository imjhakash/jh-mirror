# JH Mirror 4.15

**Your Android phone on your Mac — screen, notifications, files and clipboard in one app.**
Developed by **Johirul Hoq Akash**.

JH Mirror is a single Mac app (`JH Mirror.app`) with a small companion app on the phone that it installs and sets up by itself. Screen mirroring is built on scrcpy 5.0.1 (Apache 2.0).

**Download:** [JH Mirror 4.15.0 for Mac](https://github.com/imjhakash/jh-mirror/releases/download/v4.15.0/JH-Mirror-4.15.0.dmg) (Apple silicon, macOS 26). Source and the website are in this repository. The same installer is built locally as `release/JH Mirror.dmg`. It contains JH Mirror and an Applications shortcut. All core runtime tools, video libraries, the Android companion and an offline Quick Start guide are inside the app. No Homebrew, Python, Java, Android SDK or separate companion download is needed at runtime. Build outputs and earlier versions remain in the source workspace; they are not part of the installer.

## Install and pair (anyone)

1. Open `release/JH Mirror.dmg` and drag **JH Mirror** to **Applications**. Open it.
   - The app is not from the App Store, so the first time macOS may refuse to open it: **System Settings → Privacy & Security → Open Anyway**.
   - Allow notifications and local network access when asked.
2. On the phone (Android 11+, same Wi-Fi): **Settings → Developer options → Wireless debugging → on**, then **Pair device with QR code** and scan the code JH Mirror shows.
   - No Developer options? **Settings → About phone → Software information → tap Build number 7 times.**
   - A 6-digit pairing code works too.
   - Android 8–10: connect USB, enable USB debugging, approve this Mac and click **Use USB-connected phone**. Older insecure Wi-Fi debugging is never enabled automatically.
3. That's all. JH Mirror then, on its own:
   - installs **JH Mirror** on the phone
   - grants it notification access, battery exemption and the other permissions listed below (over the authorized ADB connection — no phone settings to visit)
   - sets up the encrypted Wi-Fi channel and opens the phone screen.

Only one app appears on the Mac (the phone window belongs to JH Mirror) and one on the phone. Open **Help → Quick Start** for the offline guide or **Help → Setup & Add-ons** for pairing, official download links and refreshed installation status.

OBS Studio and BlackHole are optional, separate installs for calls only. [Download OBS Studio](https://obsproject.com/download) for its camera component ([setup help](https://obsproject.com/kb/virtual-camera-troubleshooting)). [Download BlackHole 2ch](https://existential.audio/blackhole/) for the phone microphone ([installation guide](https://github.com/ExistentialAudio/BlackHole#installation-instructions)). Keep OBS installed and closed during normal JH Mirror calls; BlackHole runs as a background audio driver. Mirroring, files, media, apps, notifications and clipboard do not require either add-on.

## What it does

- **Phone app**: Home, Device check and Settings use native cards with system/light/dark appearance, file and clipboard quick actions, transfer queue, notification controls, debugging and battery help. **Return to my app after sharing** is on by default: preparation and errors remain visible, then a successful queue returns to the previous app. The Mac file-picker action uses a transient picker rather than opening the phone dashboard.
- **Device Check**: click the connected status in the menu-bar preview, **Device Check…** in the menu/tools, or Device check in the phone app. Nine independent signals cover screen mirroring, transfer, gallery, camera, microphone, phone audio, protected screen-off, notifications and App Library. Green means an observed check or active stream; yellow means disconnected, setup, paused or untested; red means unsupported or a failed operation. Each feature explains its requirement, failure and next step. Read-only checks inspect shared-storage and photo/video/audio listings; they never start camera/microphone capture. Recent results reach the phone over the existing authenticated connection and expire there after one minute.
- **One active copy**: opening another downloaded or review copy focuses the running app. A shared private process lock prevents duplicate connection servers, notifications and transfer queues.
- **Stay in your flow**: paired launches open the phone screen without the dashboard. Clicking the Dock resumes the last gallery, preview or other content window, including a minimized one. The dashboard opens from **Dashboard…** or **⌘,**. **⌘1** opens the phone screen, **⌘2** the media library and **⌘3** phone files. Reopening the library keeps its active media tab, search, selection and scroll; repeated photo opens reuse the viewer. The file/media window remembers its size and position.
- **Simple by design**: the window shows your phone and its status, one **Open Phone Screen** button, notifications and files. Every option is in **⚙︎** (the same menu appears when you right-click the menu bar icon or click ⋯ in its dropdown).
- **Menu bar**: click the phone icon for a live preview, **Open Window**, **Clipboard** history and connection **Status / Reconnect**.
  - The icon is **pinned**: it stays in the menu bar, keeps the place you ⌘-drag it to, and cannot be dragged out by accident. It starts near the clock so a full menu bar does not hide it behind the camera notch; JH Mirror tells you if macOS still hides it. **Keep Icon in Menu Bar** (⚙︎) off shows it only while the phone is connected.
  - The **pin** button in the dropdown keeps the live preview open while you work in other apps.
- **Phone Tools**: click the small white arrow at the mirror's top-right to expand/collapse the side tools. There is no colored dot, border or animation. The strip has window, phone screen, audio, clipboard, files, **App Library** and more. Hover for names; drop Mac files on it to send them to the phone.
- **Phone App Library**: a simple drawer beside the mirror shows four columns of app icons and names. Click an icon to open it; right-click for **Uninstall…**, with confirmation. System apps, JH Mirror and the active launcher/keyboard are protected. The drawer follows the mirror and hides with it; click App Library again or press Escape to close it. It caches the list and icons privately on this Mac, separately for each paired phone and Android user. Inventory refreshes on the first drawer opening each local calendar day (or at midnight if left visible); the small refresh icon fetches immediately. Reopening, refocusing and relaunching reuse that day's saved list. Each app action still rechecks current phone user and app metadata. A failed refresh retains the last list.
- **Files & Media**: open the folder or photo icon in Phone Tools (also in the menu bar). Browse phone shared storage and common folders; switch between Files, Photos, Videos and Audio, with search and on-demand thumbnails. Drop Mac files/folders into the current folder, or use **Send to Phone**. In media views, uploads go to Downloads. Select items and **Save to Mac**, or drag them into Finder using real file promises. New Folder creates a uniquely named folder. Transfers keep originals and never replace existing names.
- **Fast media viewer**: double-click a photo/video or press Space. The cached gallery image appears immediately while a sharper screen preview loads. Use **← / →**, the on-screen arrows or a horizontal trackpad swipe to browse the current gallery/search results. A newly selected photo takes a worker slot immediately rather than waiting behind two neighboring prefetches. Nearby photos preload; decoded previews use a bounded 64 MiB memory cache. Portrait EXIF rotation is applied on the phone, and stale requests cannot replace the current image. **Open Original** downloads the verified full-quality file into native Quick Look; **Play Video** opens the verified original for playback. Audio opens in a native preview without autoplay. Saving and clipboard copy always use the original file.
- **Clean media panel**: consistent square photo/video tiles, filenames on hover and search, audio tiles with names, folder navigation only in Files, and a compact selection bar. Transfer history stays behind **Transfers**, with a small live progress footer. Large-library search waits briefly for typing to pause.
- **Gallery actions**: ⌘ click, drag a selection or **Select All** to choose multiple photos. Right-click for Preview, **Copy to Mac Clipboard** (also ⌘C), Save, Select All and **Delete…**. Copied photos paste as image data into Mac apps and as original files into Finder; each photo remains a separate pasteboard item. Deletion requires a Cancel-first confirmation, permanently removes only the selected phone photos and keeps Mac copies. The app rechecks the phone/user and every source's metadata, stops on a deletion failure, and reports partial completion. Clipboard/original downloads use a private Mac cache, SHA-256 verification and warm reuse. **Cancel** stops an unfinished download; closing the browser also cancels it. Unused original-cache batches older than seven days are cleaned on the next browser creation, preserving files referenced by the current Mac clipboard.
- **Faster gallery grid**: the newest 120 indexed photos appear while the full library loads in the background. Only visible tiles request thumbnails; a bounded batch of up to six streams each image as it is ready through one Android process. Offscreen batches cancel. Decoding happens away from the UI thread. Private thumbnails are reused across app restarts, keyed by phone/user and file metadata; the cache trims old/least-recent entries after seven days or beyond its 128 MiB target. Refresh clears grid thumbnails as well as the listing cache. Full-quality previews and originals keep their existing validation.
- **Responsive library loading**: navigation cancels obsolete listings and thumbnail requests. A slow media request cannot hold Files or Documents behind it, and only the current tab can update the panel. Android user 0 media views read the system media index; unsupported providers and other users fall back to a shared-storage scan. Indexed entries resolve to exact, canonical filesystem metadata before preview, transfer or deletion. Folder listings cache for 30 seconds and media listings for five minutes, separately for phone/user/path/type; Refresh fetches again, and app-made file changes invalidate the cache. Loading and empty/error states appear in the panel. Obsolete connection probes and helper deployment cancel with navigation, and an interrupted full-library fetch keeps its first page visible, marks the library incomplete and disables actions until Refresh reconnects.
- **Reliable transfers**: one bounded binary stream at a time over the paired ADB connection, independent of notification polling, with byte progress, measured speed and SHA-256 verification. Partial copies and the private queue survive an interrupted connection or app restart. **Pause** retains progress; **Resume** continues at the saved byte position. A brief disconnect retries up to three times; a restored queue waits for Resume. Source changes and phone/user mismatches refuse stale transfers. Uploaded media is scanned for the phone gallery after verification. The browser transfer path uses 64-bit sizes without the old Share queue's 2 GiB cap. Speed depends on Wi-Fi/USB and storage; verification adds a read of the file. File/media views are bounded to 20,000 entries; browse subfolders for larger libraries. Android-protected app data and other users' private storage are outside the browser. No new all-files permission or LAN server is added.
- **Phone window**: mouse, keyboard, scroll, audio and clipboard, borderless with close/minimize dots. ⌘W or ⌘Q closes the phone window only.
- **Keep the phone usable while mirroring**: Android receives an activity pulse every four seconds while a normal mirror is visible, and throughout a deliberately dark mirror even when hidden/minimized. This prevents idle sleep without changing the phone timeout, storing an unlock credential or dismissing the lock screen. Closing, Mac sleep or disconnection stops the pulses. An already-locked phone still needs one normal unlock; manual locks and device security policy are respected.
- **Phone screen off + touch guard (Android 14+)**: toggle the phone icon in Phone Tools or **Turn Phone Screen Off** in ⚙︎. Screen changes happen live without restarting video. The physical panel stays dark when hiding/minimizing and when closing the mirror; closing releases touch and lets Android sleep. Use **Turn Phone Screen On** or the phone's power button to light it again. A saved dark session reopens with automatic waking disabled. An enabled service that Android has marked crashed or failed to bind is reconnected once before acquiring protection, preserving all other accessibility services. Permission, connection, touch-exploration and filter failures have separate explanations; failure leaves the display on. The eight-second renewable accessibility lease never reads screen content; lease loss restores touch and stops the dark mirror without relighting it. A physical phone wake overrides the saved dark intent. The original timeout and security settings stay unchanged.
- **Phone camera and microphone for Mac calls**: click **Phone Camera** in the menu bar to start a live preview with **Front/Rear**, **90° rotation**, **Mirror** and **Start/Stop**. Rotation and mirroring apply live to the call output. Minimize to keep video running; closing the window stops it. The installed [OBS camera component](https://obsproject.com/kb/virtual-camera-guide) delivers video while the OBS app stays closed, with no scene or password setup. Select **OBS Virtual Camera** in the call once. **Phone Mic** uses the small [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) background driver; select it as the call microphone after its required installation/restart. Camera requires Android 12+. Video is not recorded; the private preview buffer is deleted on stop. The previous Mac microphone is restored on stop, failure, sleep or next launch after a crash, provided the user has not manually chosen another input. Capture starts only on a camera/mic action. See [CALLS.md](CALLS.md).
- **Notifications off on the phone?** The window shows **Turn On** when the phone app's "Send notifications to Mac" switch is off.
- **Interactive notifications**: phone notifications appear as Mac notifications with the phone's own buttons.
  - **Click** a notification → it opens on the phone (as if tapped there) and the phone window comes up. A locked phone is woken; unlock it in the window.
  - **Reply** / **Mark as read** and other buttons work from the Mac; Reply has a text field.
  - **Dismiss** on the Mac → dismissed on the phone. Double-click a row in the panel to open it on the phone.
  - Notifications Android marks as sensitive are respected; macOS Focus modes still apply.
- **Clipboard**: copy text or an image on the phone and press ⌘V on the Mac (auto-copy; passwords marked sensitive are skipped). Manual options: Share → **Copy to Mac**, the notification's **Copy to Mac** button, or the Quick Settings tile.
- **Files**: Share → **JH Mirror** on the phone, or **Choose files**. Files land in `~/Downloads/JH Mirror/` (verified, resumable, never overwriting). Drag recent files from the Phone Tools sidebar into any app; drop Mac files on the sidebar or the phone window to send them to the phone's Download folder.
- **Reconnects by itself**: after Wi-Fi changes or a phone restart (Android turns Wireless debugging off on reboot; JH Mirror asks the phone to turn it back on over its encrypted channel — about 20 seconds). **Reconnect** in the menu bar forces it. **Open at Login** is in the menu.

## Permissions JH Mirror grants on the phone (once, over ADB)

| Permission | Why |
|---|---|
| Notification access | forward notifications; act on them from the Mac |
| Post notifications | its status notification with **Copy to Mac** |
| Display over other apps (app-op) | lets a Mac click open the notification's app on the phone |
| `WRITE_SECURE_SETTINGS` | switch Wireless debugging back on after a phone restart, only when the paired Mac asks |
| Touch-guard accessibility service (screen-off mode only, Android 14+) | filter physical touchscreen/stylus input during a short renewable lease; never reads screen content |
| Battery-optimization exemption | stay connected in Doze |
| Installed-package visibility (normal manifest permission) | App Library names, launcher entries and icons; streamed only over the DUMP-protected authorized ADB channel |

Everything the Mac and phone exchange travels over the authorized ADB connection or a certificate-pinned TLS channel with a random 256-bit token. Withdraw access by unpairing the Mac in Wireless debugging and uninstalling JH Mirror from the phone.

## Requirements and limits

- Mac with Apple silicon. The bundled video libraries come from Homebrew on this Mac, so the app currently requires **macOS 26** (the build prints and records the exact minimum). Building those libraries from source with scrcpy's `app/deps` scripts would lower it.
- Android 8 or newer over an authorized USB connection. Wireless QR/code pairing requires Android 11+ on the same local network. Feature requirements differ; see Device Check.
- The app is ad-hoc signed, not notarized: others must use **Open Anyway** once. A paid Apple Developer ID would remove that step.
- Screen mirroring, auto-copy and the phone-restart recovery need Wireless debugging; notifications and files also work over the encrypted Wi-Fi channel alone.

## Feature requirements

| Feature | Requirement / check |
|---|---|
| Screen mirroring and companion | Android 8+ in this bundle; authorized USB or supported wireless debugging |
| Wireless QR/code pairing | Android 11+; older phones use USB |
| Phone camera for calls | Android 12+, camera hardware and the Mac virtual-camera component |
| Phone microphone / audio | Android 11+; call microphone also needs the Mac audio driver |
| Screen off with touch protection | Android 14+ and the touch-guard service; older phones keep the display on |
| Files and media | Shared-storage and media-provider access checked on the actual device; each file is validated before use |
| Notifications | Phone notification access, Send notifications enabled and a paired connection |
| App Library | Companion provider and current Android user checked; protected packages cannot be uninstalled |

An A10's installed Android release determines support. Unsupported camera/audio/touch features do not prevent mirroring, files or notifications. Media queries only use columns present on that Android release; older devices no longer fall back to a full storage scan solely because newer columns are missing.

## Upgrading from Android Wireless

JH Mirror replaces the earlier "Android Wireless" app: it imports its settings, keeps the paired phone when reachable (otherwise scan the QR code once), installs the new phone app and removes the old one. Old received files stay in `~/Downloads/Android Wireless/`. macOS may still list "Android Wireless" in Notification settings; it can be ignored.

## Build from source

Requirements on an Apple silicon Mac: Xcode Command Line Tools, Python 3, Homebrew `meson`, `ninja`, `pkgconf`, `sdl3`, `ffmpeg`, `libusb`, `openjdk` and `android-platform-tools`. The Android SDK 36 is in `.android-sdk`.

```sh
python3 build_all.py --stage-only --release
```

- runs every test, builds the phone app, the scrcpy server and client, and the Mac app into `dist.noindex/` (kept out of Spotlight)
- bundles adb (Google-signed), the scrcpy server, the phone app and the mirror's libraries; signs and verifies the bundle
- `--stage-only` builds a separate review bundle without quitting, installing or opening the app.
- `--release` publishes exactly one installer, `release/JH Mirror.dmg`, atomically after signature, embedded-runtime, relocation, disk-image checksum and mounted-image checks. No loose companion APK, helper, SDK or setup document is distributed beside it. The installer shows just JH Mirror and an Applications shortcut.
- Packaging alone: `python3 -I packaging/release.py --app "dist.noindex/JH Mirror 4.15.0 Preview.app"`. The verification launches only read-only checks; it never pairs a phone or starts camera/microphone capture.
- `--install` copies it to `/Applications`, `--restart` quits and reopens the running app, `--dmg` writes `dist/JH-Mirror-<version>.dmg`.

`android/build/personal-signing.keystore` signs the phone app; **back it up outside this folder** (it is excluded from git). `patches/scrcpy-5.0.1.patch` records all changes to scrcpy. `make_icon.swift` draws the icon.

## Tests

`python3 build_all.py` runs them all: connection selection and backoff, QR/code pairing parsing, pinned TLS, resumable file transfer, Mac clipboard placement, auto-copy, the live-preview pipeline (C writer → Swift reader), touch-guard lease recovery/replay protection, direct camera conversion/queue limits, camera lifecycle against a fake helper, and OBS compatibility authentication/session cleanup against a local WebSocket simulator. The optional `python3 -I tests/camera-sink/integration.py --virtual-device` verifies generated frames are acknowledged by an idle, installed OBS camera extension with OBS closed; it never opens a physical camera, phone or microphone. `VALIDATION.md` distinguishes automated checks from real-device checks. Diagnostics (no notification content or credentials) go to `~/Library/Application Support/JH Mirror/connection.log`.

The build also checks app-library argument/protection/profile boundaries and the C → Java activity-pulse protocol. Optional AppKit checks are `python3 -I tests/phone-apps-ui/integration.py` and `python3 -I tests/window-controls/integration.py`: these use generated windows and fixtures, with no phone apps removed.

Additional native acceptance checks: `python3 -I tests/phone-files-ui/integration.py`, `tests/phone-apps-ui/integration.py`, `tests/device-health-ui/integration.py`, `tests/window-flow/integration.py`, `tests/gallery-stress/integration.py` and `tests/window-controls/integration.py`. These use generated fixtures, simulated phones and private clipboards. Live generated-file QA is described in VALIDATION.md.
