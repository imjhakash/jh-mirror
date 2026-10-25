# Phone camera and microphone

JH Mirror 4.5 puts camera controls in one window: **live preview, Front/Rear, rotate left/right 90°, Mirror, Start/Stop**. Click **Phone Camera** in the menu bar to open the window and start video. Rotation and mirroring update the outgoing frames without restarting capture; changing lenses briefly reconnects video. The angle and mirror setting are remembered. Minimize the window to keep a call running; closing it stops the camera.

The camera path is phone → authorized ADB → bundled scrcpy decoder → Core Media I/O → the installed, signed **OBS Virtual Camera** component. **The OBS app stays closed.** Normal use needs no OBS scenes, WebSocket setup or password, and no Apple Developer account. Keep OBS installed because it owns that camera component.

The preview shows the same transformed output sent to the virtual camera. It uses one private, mode-0600 shared pixel buffer in a mode-0700 temporary directory, refreshed at about 12 fps only while the window is visible. This is a transient preview, not a video recording. The files are removed on stop. Camera delivery continues at the selected 30 fps independently of preview updates.

## Setup and use

On this Mac, OBS Studio 32.2.2 and its activated camera extension are installed and available. The latest setup check also finds BlackHole 2ch in Core Audio. Device Check reports component readiness separately from a tested phone camera/microphone stream; the microphone still needs a real capture/call check.

For a new Mac, open **Help → Setup & Add-ons** for official downloads, instructions and refreshed status. **Help → Quick Start** contains the same steps offline. Both add-ons remain optional and outside the single JH Mirror installer.

For a new Mac:
1. Install [OBS Studio](https://obsproject.com/download) in Applications. Start Virtual Camera once and approve its camera extension in macOS. Then stop Virtual Camera and quit OBS.
2. For phone microphone support, install [BlackHole 2ch](https://existential.audio/blackhole/) and restart if requested. This background audio driver has no app window to keep open.
3. In JH Mirror, click **Phone Camera**. Preview and adjust the lens, angle and mirror setting.
4. In the calling app's camera menu, select **OBS Virtual Camera**. For phone audio, start **Phone Mic** in JH Mirror and choose **BlackHole 2ch** as the call's microphone. Keep the usual speakers/headphones as output.

macOS does not provide a universal supported control to force every call app to change cameras. Select OBS Virtual Camera in the calling app once; JH Mirror then controls its phone feed. Choose the Mac camera in the call to return to it. Apps that pin their microphone selection also need that selection in their own settings.

## Recovery and limits

- Camera requires Android 12+ and an available phone camera. Screen-off touch protection separately requires Android 14+.
- The sender selects the installed device by stable UID, validates its advertised format, converts frames with Core Image and fits the image without stretching. At most two frames queue; overloaded frames drop. Pixel-buffer allocation is bounded. A blocked queue, missing device acknowledgements, lost frame heartbeat or failed helper stops capture with an error.
- “Live” means the extension has acknowledged video frames. It does not guarantee a lens is uncovered or lit, or that the call app has selected this device. Check the preview first.
- If OBS is open in JH Mirror's own idle call collection, JH Mirror can stop that virtual output and close OBS before starting direct video, using the previously approved local credential. It refuses to close an active recording/stream or another user's scene. If OBS's control server is unavailable, quit OBS and click Start Camera. Opening OBS during direct capture stops the phone camera to avoid competing producers.
- Microphone audio goes only to the explicitly selected BlackHole output. A missing output refuses capture instead of falling back to speakers. Mac speaker output never changes. The prior microphone is restored by UID only while JH Mirror's selected input is still current; recovery is also checked after a crash.
- Closing the camera window, **Stop Phone Call Inputs**, quitting and Mac sleep stop capture. No call capture resumes after sleep, failure or relaunch. A stopped virtual device may show its component's placeholder or a calling app's last frame; select the Mac camera to return video to it.
- The old OBS FIFO/scene transport remains only for integration tests; it is no longer a selectable normal camera mode. Existing OBS settings and Keychain credentials have been preserved. The unsigned future prototype under `native/` is excluded from this app.

## Validation

Version 4.15.0 build 37 is installed and reopened in Applications, retaining the tested camera window and direct sender. The single installer is `release/JH Mirror.dmg`; the prior verified app is retained under `dist.noindex/` for rollback. The setup checks inspect component readiness without starting a phone input.

The user's Samsung Android 16 phone delivered a visible front-camera picture through the direct sender and acknowledged local virtual-camera output. Live quarter-turn and mirror controls were exercised while the same capture session kept running. The rear camera initially delivered a dark image; after the user lifted the phone, it delivered visible frames too.

Generated asymmetric test patterns independently verify rotation direction and mirrored pixels, conversion, letterboxing, queue limits and stalled output. Call lifecycle tests cover start/stop, lens reconnects, private controls and preview cleanup, helper failure, missing component and OBS conflicts. See [VALIDATION.md](VALIDATION.md) for the latest camera-window and installed-bundle checks.

A full call, phone microphone capture, Wi-Fi latency and long-call stability still require real-use verification; a short camera check and available drivers do not establish these.

## Repair history

Version 4.4's CLI disabled video when `--no-window` was set. Version 4.4.1 repaired that gate and added real-parser regression tests. OBS had also launched from App Translocation, which rejected camera-extension setup. Its verified Applications executable activated the extension successfully; JH Mirror uses that executable for one-time setup. No quarantine flag or global macOS security setting was changed.

The black OBS preview in the user's later screenshot came from the older FIFO/scene route. The helper was blocked writing that pipe. Version 4.5 removes this fragile route from normal use, sends directly to the existing camera component, and provides a matching live preview and camera controls in JH Mirror.

## Technical references

- [OBS 32.2.2 camera producer](https://github.com/obsproject/obs-studio/blob/32.2.2/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm) and [extension sink](https://github.com/obsproject/obs-studio/blob/32.2.2/plugins/mac-virtualcam/src/camera-extension/OBSCameraStreamSink.swift)
- [Apple Core Media I/O camera extensions](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o)
- [BlackHole official project](https://github.com/ExistentialAudio/BlackHole)
- [OBS WebSocket protocol](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md) (old transport tests and safe migration from JH Mirror's idle OBS scene)
