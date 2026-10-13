# Validation — 2026-10-14

Android Wireless 3.3.0 build 13; companion 1.3 / protocol 4; scrcpy 5.0.1 built from included source.

- Full Mac/Android/client/server source build completed; macOS bundle signature verified.
- Live Samsung ADB transport deliberately disconnected once. TLS health and file endpoints remained available (200), a local phone test event reached Mac Notification Center, and ADB/mirror recovered automatically.
- After recovery: 185 seconds, 60/60 successful authenticated TLS health polls, one continuous mirror process, no missing mirror samples. This is a short test of this session, not a lifetime guarantee.
- Sidebar Window Off / On hid and restored the window while retaining the same mirror process. Audio Off and clipboard sync On were preserved.
- Connection tests passed live-endpoint preference over stale mDNS, cached endpoints without discovery, and bounded retry backoff.
- TLS tests accepted the pinned certificate, rejected an unknown certificate before sending the bearer token, and refused redirects.
- File tests passed interrupted-chunk resume, corrupt-file restart, idempotent acknowledgement, duplicate-name preservation, unsafe-name sanitization and zero-byte saves.

Screen mirroring/control/audio/clipboard require Wireless debugging. Direct notification/file sync works independently over the paired encrypted Wi-Fi channel. Mac banners remain suppressed during screen sharing according to the user's preference.
