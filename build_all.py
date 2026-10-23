#!/usr/bin/env python3
"""Build JH Mirror: the phone companion, the scrcpy server/client and the Mac app.

JH Mirror by Johirul Hoq Akash. Everything the app needs at run time ships inside
"JH Mirror.app": adb, the scrcpy server, the phone companion, and the mirror's
video libraries (copied from Homebrew and relinked, so `brew upgrade` cannot break it).

  python3 build_all.py                      build + test into dist.noindex/
  python3 build_all.py --install --restart  also install to /Applications and (re)open it
  python3 build_all.py --dmg                also make dist/JH-Mirror-<version>.dmg to share
  python3 build_all.py --stage-only --release  one installer: release/JH Mirror.dmg
"""
from pathlib import Path
import argparse, json, os, plistlib, re, shutil, subprocess, sys, time

ROOT = Path(__file__).resolve().parent
VERSION, BUILD = '4.15.0', '37'
APP_NAME = 'JH Mirror'
BUNDLE_ID = 'com.johirulhoqakash.jhmirror'
LEGACY_BUNDLE_ID = 'local.jhakash.android-wireless'
COMPANION = 'com.johirulhoqakash.jhmirror'
parser = argparse.ArgumentParser()
parser.add_argument('--install', action='store_true', help='Copy the app to /Applications')
parser.add_argument('--restart', action='store_true', help='Quit the running app first, then open the new build')
parser.add_argument('--dmg', action='store_true', help='Create a shareable disk image in dist/')
parser.add_argument('--release', action='store_true', help='Create and verify the single installer in release/JH Mirror.dmg')
parser.add_argument('--skip-tests', action='store_true', help='Skip the Mac test suites')
parser.add_argument('--stage-only', action='store_true', help='Build a separate review bundle without quitting, installing, or launching the app')
parser.add_argument('--device', help='ADB connection endpoint for --deploy-phone')
parser.add_argument('--deploy-phone', action='store_true', help='Install the companion on that phone now')
args = parser.parse_args()
if args.stage_only and (args.install or args.restart or args.deploy_phone):
    parser.error('--stage-only cannot be combined with --install, --restart, or --deploy-phone')
env = dict(os.environ)
java = Path(env.get('JAVA_HOME', '/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home'))
env.update(ANDROID_HOME=str(ROOT/'.android-sdk'), JAVA_HOME=str(java))
env['PATH'] = str(java/'bin') + ':/opt/homebrew/bin:' + env.get('PATH', '')
CACHE = '/private/tmp/jh-mirror-swift-cache'
OUT = ROOT/'dist.noindex'  # ".noindex" keeps build copies out of Spotlight and Launchpad
OUT.mkdir(exist_ok=True)

def run(*command, cwd=ROOT, **kwargs):
    return subprocess.run([str(x) for x in command], cwd=cwd, env=env, check=True, **kwargs)

APP_PATTERNS = ['JH Mirror.app/Contents/MacOS/JHMirror', 'Android Wireless.app/Contents/MacOS/AndroidWireless']
def app_running():
    return any(subprocess.run(['pgrep', '-f', p], capture_output=True).returncode == 0 for p in APP_PATTERNS)

# Remembered now: with --restart the app is reopened even if it was quit while building.
running_at_start = app_running()

# ---- Tests (fast, no phone needed) -------------------------------------------------------
if not args.skip_tests:
    tmp = Path('/private/tmp/jh-mirror-tests'); tmp.mkdir(exist_ok=True)
    suites = {
        'network': ['PhoneConnection.swift', 'WifiConnection.swift', 'PairPhone.swift', 'tests/network/main.swift'],
        'pairing': ['PairPhone.swift', 'WifiConnection.swift', 'tests/pairing/main.swift'],
        'clipboard': ['Clipboard.swift', 'tests/clipboard/main.swift'],
    }
    for name, files in suites.items():
        run('swiftc', *(ROOT/f for f in files), '-module-cache-path', CACHE, '-o', tmp/name)
        run(tmp/name)
    for test in ['tls', 'file-transfer', 'auto-clipboard', 'touch-guard', 'phone-display', 'calls', 'call-devices', 'phone-apps', 'phone-files', 'phone-browser', 'phone-media', 'media-preview', 'device-health', 'mirror-activity', 'setup-ui', 'gallery-speed', 'app-instance']:
        run(sys.executable, '-I', ROOT/'tests'/test/'integration.py')

# ---- Android companion and scrcpy ----------------------------------------------------------
run(sys.executable, ROOT/'build_android.py')
server = ROOT/'scrcpy-5.0.1/server'
server_build = server/'build_manual'; server_build.mkdir(exist_ok=True)
subprocess.run(['bash', str(server/'build_without_gradle.sh')], cwd=server, env=dict(env, BUILD_DIR=str(server_build)), check=True)
build = ROOT/'scrcpy-5.0.1/build'
meson_args = [ROOT/'scrcpy-5.0.1', '-Dcompile_server=false', '-Dprebuilt_server='+str(server_build/'scrcpy-server'), '-Dbuildtype=release']
if (build/'build.ninja').exists(): run('meson', 'setup', '--reconfigure', build, *meson_args)
else: run('meson', 'setup', build, *meson_args)
run('ninja', '-C', build)
if not args.skip_tests:
    run(sys.executable, '-I', ROOT/'tests/preview/integration.py')
    run(sys.executable, '-I', ROOT/'tests/camera-sink/integration.py')

# ---- Mac app ----------------------------------------------------------------------------------
sources = ['main.swift', 'AppInstanceLock.swift', 'PhoneWindowFlow.swift', 'DeviceHealth.swift', 'DeviceHealthWindow.swift', 'DeviceHealthLauncher.swift', 'Clipboard.swift', 'AutoClipboard.swift', 'MenuBarPopover.swift', 'BridgeClient.swift',
           'FileTransferClient.swift', 'PhoneFiles.swift', 'PhoneFilesBrowser.swift', 'PhoneFileTransfers.swift', 'PhoneMediaActions.swift', 'PhonePreviewLoader.swift', 'PhoneThumbnailLoader.swift', 'PhoneMediaPreviewWindow.swift', 'PhoneFilesWindow.swift', 'PhoneTools.swift', 'PairPhone.swift', 'WifiConnection.swift', 'PhoneConnection.swift',
           'PhoneTouchGuard.swift', 'OBSConnection.swift', 'CallDevices.swift', 'PhoneCalls.swift', 'CallSetup.swift', 'CallCamera.swift', 'CameraWindow.swift', 'PhoneApps.swift', 'PhoneAppTile.swift', 'PhoneAppsWindow.swift', 'IncomingCallBanner.swift']
run('swiftc', *(ROOT/name for name in sources), '-O', '-o', OUT/'JHMirror', '-module-cache-path', CACHE,
    '-framework', 'AppKit', '-framework', 'QuickLookUI', '-framework', 'UserNotifications', '-framework', 'Security', '-framework', 'CoreMediaIO')

# Assemble a fresh bundle beside the old one, then swap: no stale files survive rebuilds.
app = OUT/(f'{APP_NAME} {VERSION} Preview.app' if args.stage_only else f'{APP_NAME}.app')
staging = OUT/f'{APP_NAME}.app.building'
if staging.exists(): shutil.rmtree(staging)
contents = staging/'Contents'
resources = contents/'Resources'; macos = contents/'MacOS'
helper = contents/'Helpers/JH Mirror Screen.app'
frameworks = helper/'Contents/Frameworks'
for directory in [resources, macos, helper/'Contents/MacOS', helper/'Contents/Resources', frameworks]:
    directory.mkdir(parents=True, exist_ok=True)
shutil.copy2(ROOT/'packaging/MirrorScreen-Info.plist', helper/'Contents/Info.plist')
adb = Path(os.path.realpath('/opt/homebrew/bin/adb'))
for source, destination in [(ROOT/'AppIcon.icns', resources/'AppIcon.icns'),
                            (ROOT/'AppIcon.icns', helper/'Contents/Resources/AppIcon.icns'),
                            (ROOT/'packaging/AppIcon64.png', resources/'AppIcon64.png'),
                            (ROOT/'scrcpy-5.0.1/LICENSE', resources/'scrcpy-LICENSE'),
                            (ROOT/'packaging/Quick Start.html', resources/'Quick Start.html'),
                            (ROOT/'packaging/Install JH Mirror.txt', resources/'Install JH Mirror.txt'),
                            (adb.parent/'NOTICE.txt', resources/'adb-NOTICE.txt'),
                            (adb, macos/'adb'),  # Google-signed; kept as-is
                            (OUT/'JHMirror', macos/'JHMirror'),
                            (build/'app/scrcpy', helper/'Contents/MacOS/JHMirrorScreen'),
                            (server_build/'scrcpy-server', resources/'scrcpy-server'),
                            (ROOT/'JH Mirror Companion.apk', resources/'JH Mirror Companion.apk')]:
    shutil.copy2(source, destination)

def homebrew_refs(binary):
    out = subprocess.run(['otool', '-L', str(binary)], capture_output=True, text=True, check=True).stdout
    return [line.strip().split(' (')[0] for line in out.splitlines()[1:] if line.strip().startswith('/opt/homebrew/')]

# Copy every Homebrew library the mirror needs (transitively) and point references into the bundle.
executable = helper/'Contents/MacOS/JHMirrorScreen'
pending, bundled, components = [executable], {}, []
while pending:
    binary = pending.pop()
    for ref in homebrew_refs(binary):
        name = Path(ref).name
        target = frameworks/name
        if name not in bundled:
            origin = Path(os.path.realpath(ref))
            shutil.copy2(origin, target); target.chmod(0o755)
            bundled[name] = target
            # Keep the original notices and source locations with the runtime.
            cellar = next((parent for parent in origin.parents if parent.parent.parent.name == 'Cellar'), None)
            if cellar:
                notice_root = resources/'Third Party'/cellar.parent.name
                candidates = [file for file in cellar.iterdir() if file.is_file() and file.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE', 'PATENTS'))]
                license_folder = cellar/'share/licenses'
                if license_folder.exists(): candidates += [file for file in license_folder.rglob('*') if file.is_file()]
                for file in candidates:
                    destination = notice_root/file.relative_to(cellar)
                    destination.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(file, destination)
                formula = next((cellar/'.brew').glob('*.rb'), None)
                text = formula.read_text() if formula else ''
                source = re.search(r'^\s*url "([^"]+)"', text, re.M)
                homepage = re.search(r'^\s*homepage "([^"]+)"', text, re.M)
                components.append(dict(library=name, component=cellar.parent.name, version=cellar.name,
                    source=source.group(1) if source else '', homepage=homepage.group(1) if homepage else ''))
            run('install_name_tool', '-id', '@executable_path/../Frameworks/' + name, target, stderr=subprocess.DEVNULL)
            pending.append(target)
        run('install_name_tool', '-change', ref, '@executable_path/../Frameworks/' + name, binary, stderr=subprocess.DEVNULL)
for binary in [executable, *bundled.values()]:
    leftovers = homebrew_refs(binary)
    if leftovers: raise RuntimeError(f'{binary.name} still references Homebrew: {leftovers}')
    # Absolute build-machine search paths are unnecessary after relinking. Remove
    # them as well so the app never searches Homebrew for a bundled dependency.
    load_commands = subprocess.check_output(['otool', '-l', str(binary)], text=True).splitlines()
    for index, line in enumerate(load_commands):
        if line.strip() == 'cmd LC_RPATH':
            path = load_commands[index + 2].strip().removeprefix('path ').split(' (offset ')[0]
            if path.startswith('/') and not path.startswith(('/System/', '/usr/lib/')):
                run('install_name_tool', '-delete_rpath', path, binary, stderr=subprocess.DEVNULL)
print(f'Bundled {len(bundled)} mirror libraries into the app')
(resources/'Third Party').mkdir(exist_ok=True)
(resources/'Third Party/Components.json').write_text(json.dumps(components, indent=2) + '\n')

# The oldest macOS every bundled binary supports becomes the app's stated minimum.
def minimum_macos(binary):
    out = subprocess.run(['otool', '-l', str(binary)], capture_output=True, text=True).stdout.split()
    return tuple(int(x) for x in out[out.index('minos') + 1].split('.')) if 'minos' in out else (11, 0)
minimum = max(minimum_macos(b) for b in [executable, macos/'JHMirror', *bundled.values()])
minimum_text = '.'.join(map(str, minimum))
info = plistlib.loads((ROOT/'packaging/Info.plist').read_bytes())
info.update(CFBundleShortVersionString=VERSION, CFBundleVersion=BUILD, LSMinimumSystemVersion=minimum_text)
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
helper_info = plistlib.loads((helper/'Contents/Info.plist').read_bytes())
helper_info.update(LSMinimumSystemVersion=minimum_text)
(helper/'Contents/Info.plist').write_bytes(plistlib.dumps(helper_info))
print(f'Requires macOS {minimum_text} or later')

# Sign inside-out: libraries, helper app, then the main app (adb keeps Google's signature).
for library in sorted(bundled.values()): run('codesign', '--force', '--sign', '-', library)
run('codesign', '--force', '--sign', '-', helper)
run('codesign', '--force', '--sign', '-', staging)
run('codesign', '--verify', '--deep', '--strict', staging)
# The mirror must start using only bundled libraries (no phone needed for --version).
check = subprocess.run([str(executable), '--version'], capture_output=True, text=True, timeout=20,
                       env={'DYLD_PRINT_LIBRARIES': '1', 'PATH': '/usr/bin:/bin'})
if check.returncode != 0 or '/opt/homebrew/' in check.stderr:
    raise RuntimeError('Mirror helper failed to load bundled libraries:\n' + check.stderr[-2000:])
if subprocess.run([str(macos/'adb'), 'version'], capture_output=True).returncode != 0:
    raise RuntimeError('Bundled adb does not run')

def quit_running_app():
    for bundle_id in [BUNDLE_ID, LEGACY_BUNDLE_ID]:
        subprocess.run(['osascript', '-e', f'if application id "{bundle_id}" is running then tell application id "{bundle_id}" to quit'],
                       check=False, capture_output=True)
    for _ in range(50):
        if not app_running(): return
        time.sleep(0.2)
    raise SystemExit('JH Mirror did not quit; the new build is in dist.noindex/.')

# ---- Install the new bundle ---------------------------------------------------------------------
was_running = app_running() if not args.stage_only else False
if was_running:
    if not args.restart:
        raise SystemExit('JH Mirror is running. Quit it first, or pass --restart. The new build is in dist.noindex/.')
    quit_running_app()
previous = OUT/(app.name+'.previous')
if previous.exists(): shutil.rmtree(previous)
if app.exists(): app.rename(previous)
staging.rename(app)
if previous.exists(): shutil.rmtree(previous)
launch = app
if args.install:
    installed = Path('/Applications')/f'{APP_NAME}.app'
    temporary = Path('/Applications')/f'.{APP_NAME}.app.installing'
    if temporary.exists(): shutil.rmtree(temporary)
    run('ditto', app, temporary)
    if installed.exists(): shutil.rmtree(installed)
    temporary.rename(installed)
    launch = installed
    print('Installed:', installed)
    # The earlier "Android Wireless" build output is replaced by JH Mirror.
    for old in [ROOT/'Android Wireless.app', ROOT/'AndroidWireless-v2', ROOT/'Android Wireless Companion.apk',
                ROOT/'Android Wireless Companion.apk.idsig']:
        if old.exists():
            shutil.move(str(old), str(Path.home()/'.Trash'/(old.name + f' {int(time.time())}')))
            print('Moved to Trash:', old.name)

if args.dmg:
    dist = ROOT/'dist'; dist.mkdir(exist_ok=True)
    folder = OUT/'dmg'
    if folder.exists(): shutil.rmtree(folder)
    folder.mkdir()
    run('ditto', app, folder/f'{APP_NAME}.app')
    (folder/'Applications').symlink_to('/Applications')
    image = dist/f'JH-Mirror-{VERSION}.dmg'
    if image.exists(): image.unlink()
    run('hdiutil', 'create', '-volname', APP_NAME, '-srcfolder', folder, '-ov', '-format', 'UDZO', image,
        stdout=subprocess.DEVNULL)
    shutil.rmtree(folder)
    print('Disk image:', image)

if args.release:
    run(sys.executable, '-I', ROOT/'packaging/release.py', '--app', app)

if args.deploy_phone:
    if not args.device: parser.error('--deploy-phone requires --device with the current connection endpoint')
    run(app/'Contents/MacOS/adb', '-s', args.device, 'install', '--no-incremental', '-r', ROOT/'JH Mirror Companion.apk')
if args.restart and (was_running or running_at_start):
    subprocess.run(['open', str(launch)], check=False)
    for _ in range(40):
        if app_running(): break
        time.sleep(0.25)
    else: print('Warning: JH Mirror did not reopen; open it from Applications.', file=sys.stderr)
print('Built and verified:', app)
