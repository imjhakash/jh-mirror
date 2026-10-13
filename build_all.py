#!/usr/bin/env python3
"""Build the companion, scrcpy server/client and Mac app from this folder.

The mirror helper's Homebrew libraries (ffmpeg, SDL3, libusb and their
dependencies) are copied into the bundle, so `brew upgrade` cannot break it.
"""
from pathlib import Path
import argparse, os, plistlib, shutil, subprocess, sys, time

ROOT = Path(__file__).resolve().parent
VERSION, BUILD = '3.4.0', '14'
PHONE_SERIAL = 'R5CW515PYBR'
BUNDLE_ID = 'local.jhakash.android-wireless'
parser = argparse.ArgumentParser()
parser.add_argument('--device', help='Current paired ADB connection endpoint for --deploy-phone')
parser.add_argument('--deploy-phone', action='store_true', help='Update the companion on the already-paired Samsung')
parser.add_argument('--restart', action='store_true', help='Quit the running app before installing the build, then reopen it')
parser.add_argument('--skip-tests', action='store_true', help='Skip the Mac test suites')
args = parser.parse_args()
env = dict(os.environ)
java = Path(env.get('JAVA_HOME', '/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home'))
env.update(ANDROID_HOME=str(ROOT/'.android-sdk'), JAVA_HOME=str(java))
env['PATH'] = str(java/'bin') + ':/opt/homebrew/bin:' + env.get('PATH', '')
CACHE = '/private/tmp/android-wireless-swift-cache'

def run(*command, cwd=ROOT, **kwargs):
    return subprocess.run([str(x) for x in command], cwd=cwd, env=env, check=True, **kwargs)

def app_running():
    return subprocess.run(['pgrep', '-f', 'Android Wireless.app/Contents/MacOS/AndroidWireless'],
                          capture_output=True).returncode == 0

# ---- Tests (fast, no phone needed) -------------------------------------------------------
if not args.skip_tests:
    tmp = Path('/private/tmp/android-wireless-tests'); tmp.mkdir(exist_ok=True)
    suites = {
        'network': ['PhoneConnection.swift', 'WifiConnection.swift', 'PairPhone.swift', 'tests/network/main.swift'],
        'pairing': ['PairPhone.swift', 'tests/pairing/main.swift'],
        'clipboard': ['Clipboard.swift', 'tests/clipboard/main.swift'],
    }
    for name, files in suites.items():
        run('swiftc', *(ROOT/f for f in files), '-module-cache-path', CACHE, '-o', tmp/name)
        run(tmp/name)
    run(sys.executable, '-I', ROOT/'tests/tls/integration.py')
    run(sys.executable, '-I', ROOT/'tests/file-transfer/integration.py')

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

# ---- Mac app ----------------------------------------------------------------------------------
sources = ['main.swift', 'Clipboard.swift', 'BridgeClient.swift', 'FileTransferClient.swift', 'PhoneTools.swift',
           'PairPhone.swift', 'WifiConnection.swift', 'PhoneConnection.swift']
run('swiftc', *(ROOT/name for name in sources), '-O', '-o', ROOT/'AndroidWireless-v2', '-module-cache-path', CACHE,
    '-framework', 'AppKit', '-framework', 'UserNotifications', '-framework', 'Security')

# Assemble a fresh bundle beside the old one, then swap: no stale files survive rebuilds.
app = ROOT/'Android Wireless.app'
staging = ROOT/'Android Wireless.app.building'
if staging.exists(): shutil.rmtree(staging)
resources = staging/'Contents/Resources'; helper = staging/'Contents/Helpers/Phone Screen.app'
frameworks = helper/'Contents/Frameworks'
for directory in [resources, staging/'Contents/MacOS', helper/'Contents/MacOS', helper/'Contents/Resources', frameworks]:
    directory.mkdir(parents=True, exist_ok=True)
shutil.copy2(ROOT/'packaging/PhoneScreen-Info.plist', helper/'Contents/Info.plist')
for source, destination in [(ROOT/'AppIcon.icns', resources/'AppIcon.icns'),
                            (ROOT/'AppIcon.icns', helper/'Contents/Resources/AppIcon.icns'),
                            (ROOT/'packaging/AppIcon64.png', resources/'AppIcon64.png'),
                            (ROOT/'scrcpy-5.0.1/LICENSE', resources/'scrcpy-LICENSE'),
                            (ROOT/'AndroidWireless-v2', staging/'Contents/MacOS/AndroidWireless'),
                            (build/'app/scrcpy', helper/'Contents/MacOS/PhoneScreen'),
                            (server_build/'scrcpy-server', resources/'scrcpy-server'),
                            (ROOT/'Android Wireless Companion.apk', resources/'Android Wireless Companion.apk')]:
    shutil.copy2(source, destination)

def homebrew_refs(binary):
    out = subprocess.run(['otool', '-L', str(binary)], capture_output=True, text=True, check=True).stdout
    return [line.strip().split(' (')[0] for line in out.splitlines()[1:] if line.strip().startswith('/opt/homebrew/')]

# Copy every Homebrew library the mirror needs (transitively) and point references into the bundle.
executable = helper/'Contents/MacOS/PhoneScreen'
pending, bundled = [executable], {}
while pending:
    binary = pending.pop()
    for ref in homebrew_refs(binary):
        name = Path(ref).name
        target = frameworks/name
        if name not in bundled:
            shutil.copy2(os.path.realpath(ref), target); target.chmod(0o755)
            bundled[name] = target
            run('install_name_tool', '-id', '@executable_path/../Frameworks/' + name, target, stderr=subprocess.DEVNULL)
            pending.append(target)
        run('install_name_tool', '-change', ref, '@executable_path/../Frameworks/' + name, binary, stderr=subprocess.DEVNULL)
for binary in [executable, *bundled.values()]:
    leftovers = homebrew_refs(binary)
    if leftovers: raise RuntimeError(f'{binary.name} still references Homebrew: {leftovers}')
print(f'Bundled {len(bundled)} mirror libraries into the app')

info = plistlib.loads((ROOT/'packaging/Info.plist').read_bytes())
info.update(CFBundleShortVersionString=VERSION, CFBundleVersion=BUILD)
(staging/'Contents/Info.plist').write_bytes(plistlib.dumps(info))

# Sign inside-out: libraries, helper app, then the main app.
for library in sorted(bundled.values()): run('codesign', '--force', '--sign', '-', library)
run('codesign', '--force', '--sign', '-', helper)
run('codesign', '--force', '--sign', '-', staging)
run('codesign', '--verify', '--deep', '--strict', staging)
# The mirror must start using only bundled libraries (no phone needed for --version).
check = subprocess.run([str(executable), '--version'], capture_output=True, text=True, timeout=20,
                       env={'DYLD_PRINT_LIBRARIES': '1', 'PATH': '/usr/bin:/bin'})
if check.returncode != 0 or '/opt/homebrew/' in check.stderr:
    raise RuntimeError('Mirror helper failed to load bundled libraries:\n' + check.stderr[-2000:])

# ---- Install the new bundle ---------------------------------------------------------------------
was_running = app_running()
if was_running:
    if not args.restart:
        raise SystemExit('Android Wireless is running. Quit it first, or pass --restart. The new build is in "Android Wireless.app.building".')
    subprocess.run(['osascript', '-e', f'tell application id "{BUNDLE_ID}" to quit'], check=False)
    for _ in range(50):
        if not app_running(): break
        time.sleep(0.2)
    else: raise SystemExit('Android Wireless did not quit; the new build is in "Android Wireless.app.building".')
previous = ROOT/'Android Wireless.app.previous'
if previous.exists(): shutil.rmtree(previous)
if app.exists(): app.rename(previous)
staging.rename(app)
if previous.exists(): shutil.rmtree(previous)

if args.deploy_phone:
    if not args.device: parser.error('--deploy-phone requires --device with the current connection endpoint')
    adb = '/opt/homebrew/bin/adb'
    result = subprocess.run([adb, '-s', args.device, 'shell', '-n', 'getprop', 'ro.serialno'], capture_output=True, text=True, timeout=8, check=True)
    if result.stdout.strip() != PHONE_SERIAL: raise RuntimeError('Selected device is not the paired Samsung')
    run(adb, '-s', args.device, 'install', '--no-incremental', '-r', ROOT/'Android Wireless Companion.apk')
    run(adb, '-s', args.device, 'shell', '-n', 'dumpsys', 'deviceidle', 'whitelist', '+local.androidwireless.bridge')
if was_running: subprocess.run(['open', str(app)], check=False)
print('Built and verified:', app)
