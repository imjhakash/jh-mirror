import base64, pathlib, struct, subprocess, tempfile, zlib
ROOT = pathlib.Path(__file__).resolve().parents[2]
EXE = pathlib.Path('/private/tmp/android-wireless-autoclip-tests')
subprocess.run(['swiftc', *(str(ROOT/f) for f in ['AutoClipboard.swift', 'FileTransferClient.swift', 'WifiConnection.swift', 'PairPhone.swift']),
                str(pathlib.Path(__file__).with_name('main.swift')), '-module-cache-path', '/private/tmp/android-wireless-swift-cache', '-o', str(EXE)], check=True)

def png(rgb):
    def chunk(kind, data): return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    raw = b''.join(b'\x00' + bytes(rgb) * 2 for _ in range(2))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')

b64 = lambda s: base64.b64encode(s.encode()).decode()
direct, fallback, broken = ('content://media/external/images/media/42', 'content://com.example.provider/item/7',
                            'content://com.example.provider/missing/9')
error = "Error while accessing provider:media\njava.lang.UnsupportedOperationException: Unknown or unsupported URL\n"
watcher = '\n'.join(['AW_CLIP_READY', 'AW_CLIP_TEXT ' + b64('hello from phone'), 'AW_CLIP_SKIPPED sensitive',
                     f'AW_CLIP_URI {b64("image/png")} {b64(direct)}', f'AW_CLIP_URI {b64("image/png")} {b64(direct)}',
                     f'AW_CLIP_URI {b64("image/png")} {b64(fallback)}', f'AW_CLIP_URI {b64("image/jpeg")} {b64(broken)}',
                     'not a protocol line']) + '\n'
with tempfile.TemporaryDirectory(prefix='aw-autoclip-') as temp:
    temp = pathlib.Path(temp); (temp/'received').mkdir()
    jar = temp/'helper.jar'; jar.write_bytes(b'fake helper')
    (temp/'direct.png').write_bytes(png((255, 0, 0))); (temp/'fallback.png').write_bytes(png((0, 0, 255)))
    (temp/'error.txt').write_text(error)
    calls = temp/'calls.log'; adb = temp/'adb'
    # Like real adb: exec-out passes its argument words through unparsed (quotes stay literal) and exits 0
    # even when the phone command fails, printing the error on stdout.
    adb.write_text(f"""#!/bin/bash
echo "$*" >> "{calls}"
shift 2
case "$1" in
  push) exit 0 ;;
  exec-out)
    if [ "$#" -ne 2 ]; then cat "{temp}/error.txt"; exit 0; fi
    case "$2" in
      "content read --uri '{direct}'") cat "{temp}/direct.png" ;;
      "cat '/storage/emulated/0/Pictures/fallback photo.png'") cat "{temp}/fallback.png" ;;
      *) cat "{temp}/error.txt" ;;
    esac
    exit 0 ;;
  shell)
    if [ "$2" = "-T" ]; then printf '%s' "{watcher}"; cat >/dev/null; exit 0; fi
    case "$*" in
      *sha256sum*) echo "0000  /data/local/tmp/android-wireless-clip.jar" ;;
      *pkill*) exit 1 ;;
      *"{fallback}"*_data*) echo "Row: 0 _data=/storage/emulated/0/Pictures/fallback photo.png" ;;
      *"{fallback}"*_display_name*) echo "Row: 0 _display_name=fallback photo.png" ;;
      *"{direct}"*_display_name*) echo "Row: 0 _display_name=cat photo.png" ;;
      *_data*) echo "Row: 0 _data=NULL" ;;
    esac ;;
esac
""")
    adb.chmod(0o755)
    result = subprocess.run([str(EXE), str(adb), str(temp/'received'), str(jar), str(temp)], capture_output=True, text=True, timeout=40)
    if result.returncode: print(result.stdout); print(result.stderr); raise RuntimeError('auto-clipboard test failed')
    log = calls.read_text()
    assert 'push' in log, 'helper is pushed when the phone copy differs'
    assert "pkill -f '[c]om.genymobile.scrcpy.ClipboardWatcher'" in log, 'old watchers are stopped first'
    assert log.count(f"content read --uri '{direct}'") == 1, 'duplicate announcement fetched once'
    assert not any(p.read_bytes().startswith(b'Error') for p in (temp/'received').iterdir() if p.is_file()), 'error text is never saved'
    print(result.stdout.strip().splitlines()[-1])
