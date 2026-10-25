"""Compile/test the camera sender using generated images; physical devices are never used."""
from pathlib import Path
import shlex, subprocess, sys, tempfile
ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='jh-camera-sink-') as directory:
    output=Path(directory)/'camera-sink-tests'
    flags=shlex.split(subprocess.check_output(['/opt/homebrew/bin/pkg-config','--cflags','--libs','sdl3','libavcodec','libavutil'],text=True))
    subprocess.run(['clang','-fobjc-arc','-Wall','-Wextra','-Werror','-mmacosx-version-min=13.0',
        '-I'+str(ROOT/'scrcpy-5.0.1/app/src'),'-I'+str(ROOT/'scrcpy-5.0.1/build/app'),str(HERE/'main.m'),
        *flags,'-framework','AppKit','-framework','CoreMediaIO','-framework','CoreVideo','-framework','CoreMedia','-framework','CoreImage','-o',str(output)],check=True)
    cli=Path(directory)/'camera-cli-tests'
    support=['cli.c','options.c','util/net.c','util/str.c','util/strbuf.c','util/term.c']
    subprocess.run(['clang','-Wall','-Wextra','-Werror','-I'+str(ROOT/'scrcpy-5.0.1/app/src'),
        '-I'+str(ROOT/'scrcpy-5.0.1/build/app'),str(HERE/'cli.c'),
        *(str(ROOT/'scrcpy-5.0.1/app/src'/name) for name in support),*flags,'-o',str(cli)],check=True)
    for case in ['direct','no-device','empty-device','display']:
        subprocess.run([str(cli),case],check=True,timeout=10)
    print('PASS: real CLI parser keeps headless camera video enabled; rejects missing/empty device and display capture.',flush=True)
    subprocess.run([str(output), *sys.argv[1:]],check=True,timeout=20)
