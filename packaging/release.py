#!/usr/bin/env python3
"""Publish one self-contained DMG; verify its contents and a relocated app first."""
from pathlib import Path
import argparse
import os
import plistlib
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    'Contents/MacOS/JHMirror', 'Contents/MacOS/adb',
    'Contents/Helpers/JH Mirror Screen.app/Contents/MacOS/JHMirrorScreen',
    'Contents/Resources/scrcpy-server', 'Contents/Resources/JH Mirror Companion.apk',
    'Contents/Resources/Quick Start.html', 'Contents/Resources/Install JH Mirror.txt',
    'Contents/Resources/adb-NOTICE.txt', 'Contents/Resources/scrcpy-LICENSE',
    'Contents/Resources/Third Party/Components.json',
)
MACHO = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}

def run(*command, **kwargs):
    return subprocess.run([str(x) for x in command], check=True, **kwargs)

def verify_bundle(app):
    app = app.resolve()
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.johirulhoqakash.jhmirror':
        raise ValueError('Unexpected app identity')
    for name in REQUIRED:
        file = app/name
        if not file.is_file() or file.stat().st_size == 0:
            raise ValueError(f'Missing core component: {name}')
    run('codesign', '--verify', '--deep', '--strict', app)
    binary_count = 0
    for file in app.rglob('*'):
        if file.is_symlink() and not file.resolve().is_relative_to(app):
            raise ValueError(f'External bundle symlink: {file.relative_to(app)}')
        if not file.is_file():
            continue
        with file.open('rb') as stream:
            if stream.read(4) not in MACHO:
                continue
        binary_count += 1
        linked = run('otool', '-L', file, capture_output=True, text=True).stdout
        for line in linked.splitlines():
            reference = line.strip().split(' (')[0]
            if reference.startswith('/') and ' (compatibility version ' in line:
                if not reference.startswith(('/System/Library/', '/usr/lib/')):
                    raise ValueError(f'External runtime dependency in {file.name}: {reference}')
        commands = run('otool', '-l', file, capture_output=True, text=True).stdout.splitlines()
        for index, line in enumerate(commands):
            if line.strip() == 'cmd LC_RPATH':
                path = commands[index + 2].strip().removeprefix('path ').split(' (offset ')[0]
                if path.startswith('/') and not path.startswith(('/System/', '/usr/lib/')):
                    raise ValueError(f'External runtime search path in {file.name}: {path}')
    if binary_count < 4:
        raise ValueError('Mirror runtime libraries are missing')
    # A clean environment and another directory exercise the paths used after
    # dragging from the image. These commands never connect to a phone or capture.
    environment = {'PATH': '/usr/bin:/bin', 'DYLD_PRINT_LIBRARIES': '1'}
    for relative, arguments in [(REQUIRED[0], ['--bundle-check']), (REQUIRED[1], ['version']), (REQUIRED[2], ['--version'])]:
        result = run(app/relative, *arguments, env=environment, cwd=app.parent,
                     capture_output=True, text=True, timeout=20)
        if any(marker in result.stderr for marker in ('/opt/homebrew/', '/usr/local/Cellar/', str(ROOT))):
            raise ValueError(f'Runtime loaded a build-machine dependency: {relative}')
    print(f"Verified JH Mirror {info['CFBundleShortVersionString']}: {binary_count} embedded binaries; no external runtime", flush=True)
    return info

def publish(app, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary_image = output.with_name('.JH-Mirror-building-' + uuid.uuid4().hex + '.dmg')
    try:
        with tempfile.TemporaryDirectory(prefix='jh-single-app-') as temporary:
            directory = Path(temporary)
            payload = directory/'Installer'; payload.mkdir()
            relocated = payload/'JH Mirror.app'
            run('ditto', app, relocated)
            verify_bundle(relocated)
            (payload/'Applications').symlink_to('/Applications')
            # Only the app and the Applications shortcut appear in the installer.
            run('hdiutil', 'create', '-volname', 'JH Mirror', '-srcfolder', payload,
                '-format', 'UDZO', temporary_image, stdout=subprocess.DEVNULL)
            run('hdiutil', 'verify', temporary_image, stdout=subprocess.DEVNULL)
            mount = directory/'Mounted installer'; mount.mkdir()
            attached = False
            try:
                run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, temporary_image,
                    stdout=subprocess.DEVNULL)
                attached = True
                visible = {file.name for file in mount.iterdir() if not file.name.startswith('.')}
                if visible != {'JH Mirror.app', 'Applications'}:
                    raise ValueError(f'Unexpected installer contents: {visible}')
                verify_bundle(mount/'JH Mirror.app')
            finally:
                if attached:
                    run('hdiutil', 'detach', mount, stdout=subprocess.DEVNULL)
        os.replace(temporary_image, output)
    finally:
        temporary_image.unlink(missing_ok=True)
    print('One file to install or share:', output, flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'release/JH Mirror.dmg')
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    if args.verify_only:
        verify_bundle(args.app)
    else:
        publish(args.app, args.output)
