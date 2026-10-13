# Validation — 2026-10-14 (3.4)

Android Wireless 3.4.0 build 14; companion 1.4 / protocol 5; scrcpy 5.0.1 built from included source.

Automated (run by `build_all.py`):
- Connection: live endpoint beats stale mDNS, cached endpoint without discovery, bounded backoff.
- TLS: pinned certificate accepted, unknown certificate rejected before the token is sent, redirects refused.
- File transfer: interrupted-chunk resume, corrupt-file restart, idempotent ACK, duplicate names preserved, unsafe names sanitized, zero-byte files, clipboard items flagged.
- Clipboard (private pasteboard): images paste as image data plus file, text as text, documents as files, one item per paste.
- Pairing endpoint validation.
- Mirror helper starts with only bundled libraries (17 copied from Homebrew); bundle signature verifies.

Live on the Samsung (Android 16):
- Running Mac app quit and replaced; the old mirror exited cleanly (status 0); the new mirror connected.
- Companion upgraded automatically from 1.3 to 1.4 over ADB; same Wi-Fi certificate kept; battery-optimization exemption present.
- Encrypted listener: unauthenticated request → 401; a client trickling bytes was closed after 6.0 s; a 4th simultaneous connection from one address was refused; service healthy afterwards.
- Share → Copy to Mac (text) reached the Mac clipboard in about 1 second. The user's clipboard was saved and restored around the test.
- Mirror close tracking: a session closed from the phone window (red dot or ⌘Q) logged `userClosed=true` and stayed closed; the app no longer treats other clean exits as a user close.
- Phone shell quoting for Mac → phone names with spaces, parentheses and apostrophes.

Not exercised live (needs the user's own content or hands): reading a real copied image through the notification/tile, dragging a sidebar file into WhatsApp, and dropping a Mac file on the sidebar. Their building blocks are covered above.
