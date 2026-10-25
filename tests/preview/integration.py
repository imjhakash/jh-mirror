import pathlib, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
SRC = ROOT/'scrcpy-5.0.1/app/src'
def pkg(*args): return subprocess.run(['/opt/homebrew/bin/pkg-config', *args, 'libavutil', 'sdl3'], capture_output=True, text=True, check=True).stdout.split()
with tempfile.TemporaryDirectory(prefix='aw-preview-') as temp:
    temp = pathlib.Path(temp)
    writer, reader, frame = temp/'writer', temp/'reader', temp/'preview.bin'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Werror', '-I', str(SRC), '-I', str(ROOT/'scrcpy-5.0.1/build/app'), *pkg('--cflags'),
                    str(HERE/'writer.c'), str(SRC/'aw_preview.c'), *pkg('--libs'), '-o', str(writer)], check=True)
    subprocess.run([str(writer), str(frame)], check=True)
    subprocess.run(['swiftc', str(ROOT/'MenuBarPopover.swift'), str(ROOT/'PhoneTools.swift'), str(HERE/'main.swift'),
                    '-module-cache-path', '/private/tmp/android-wireless-swift-cache', '-o', str(reader)], check=True)
    result = subprocess.run([str(reader), str(frame)], capture_output=True, text=True)
    if result.returncode: print(result.stdout, result.stderr); raise RuntimeError('preview test failed')
    print(result.stdout.strip())
