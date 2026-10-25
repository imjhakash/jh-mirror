# Future native device prototype — not shipped

These are initial, locally compiled camera-extension and Core Audio AudioServerPlugIn sources from the native-device investigation. They are not embedded in JH Mirror 4.4, installed, activated, or validated for real calls. Version 4.4 instead uses the existing signed OBS camera component directly and the established BlackHole driver.

`python3 build_native.py` builds ad-hoc inspection artifacts in `dist.noindex/native/`; it installs nothing. Do not install that prototype package as a replacement for the working devices. `--diagnose` reads signing availability. A complete native release still needs matching Apple signing/provisioning for the containing app and camera extension, appropriate entitlements, release notarization, installation/recovery testing and real call validation. This Mac currently has no Apple Developer account or signing identity. No system security bypass is used.

The camera prototype fixes output at BGRA 1280×720/30 and restricts its producer to a matching Apple-signed JH Mirror helper. The audio prototype uses a bounded float-stereo 48 kHz loopback ring. Compilation alone does not establish HAL timing correctness or compatibility with calling apps. Keep the working open-source devices until an independent native release passes those checks.
