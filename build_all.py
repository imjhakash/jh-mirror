#!/usr/bin/env python3
"""Build the companion, scrcpy server/client and Mac app from this folder."""
from pathlib import Path
import argparse, os, plistlib, shutil, subprocess

ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--device', help='Current paired ADB connection endpoint for --deploy-phone')
parser.add_argument('--deploy-phone', action='store_true', help='Update the companion on the already-paired Samsung')
args = parser.parse_args()
env = dict(os.environ)
java = Path(env.get('JAVA_HOME', '/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home'))
env.update(ANDROID_HOME=str(ROOT/'.android-sdk'), JAVA_HOME=str(java))
env['PATH'] = str(java/'bin') + ':/opt/homebrew/bin:' + env.get('PATH', '')
def run(*command, cwd=ROOT):
    subprocess.run([str(x) for x in command], cwd=cwd, env=env, check=True)
run('python3', ROOT/'build_android.py')
server = ROOT/'scrcpy-5.0.1/server'
server_build = server/'build_manual'; server_build.mkdir(exist_ok=True)
server_env = dict(env, BUILD_DIR=str(server_build))
subprocess.run(['bash', str(server/'build_without_gradle.sh')], cwd=server, env=server_env, check=True)
build = ROOT/'scrcpy-5.0.1/build'
if (build/'build.ninja').exists():
    run('meson', 'setup', '--reconfigure', build, ROOT/'scrcpy-5.0.1', '-Dcompile_server=false',
        '-Dprebuilt_server='+str(server_build/'scrcpy-server'), '-Dbuildtype=release')
else:
    run('meson', 'setup', build, ROOT/'scrcpy-5.0.1', '-Dcompile_server=false',
        '-Dprebuilt_server='+str(server_build/'scrcpy-server'), '-Dbuildtype=release')
run('ninja', '-C', build)
sources = ['main.swift','BridgeClient.swift','FileTransferClient.swift','PhoneTools.swift','PairPhone.swift','WifiConnection.swift','PhoneConnection.swift']
run('swiftc', *(ROOT/name for name in sources), '-o', ROOT/'AndroidWireless-v2',
    '-module-cache-path', '/private/tmp/android-wireless-swift-cache', '-framework', 'AppKit', '-framework', 'UserNotifications', '-framework', 'Security')
app = ROOT/'Android Wireless.app'
resources = app/'Contents/Resources'; helper = app/'Contents/Helpers/Phone Screen.app'
for directory in [resources, app/'Contents/MacOS', helper/'Contents/MacOS', helper/'Contents/Resources']:
    directory.mkdir(parents=True, exist_ok=True)
shutil.copy2(ROOT/'packaging/PhoneScreen-Info.plist', helper/'Contents/Info.plist')
for source, destination in [(ROOT/'AppIcon.icns', resources/'AppIcon.icns'),
                            (ROOT/'AppIcon.icns', helper/'Contents/Resources/AppIcon.icns'),
                            (ROOT/'packaging/AppIcon64.png', resources/'AppIcon64.png'),
                            (ROOT/'scrcpy-5.0.1/LICENSE', resources/'scrcpy-LICENSE')]:
    shutil.copy2(source, destination)
for src, dst in [(ROOT/'AndroidWireless-v2', app/'Contents/MacOS/AndroidWireless'),
                 (build/'app/scrcpy', helper/'Contents/MacOS/PhoneScreen'),
                 (server_build/'scrcpy-server', resources/'scrcpy-server'),
                 (ROOT/'Android Wireless Companion.apk', resources/'Android Wireless Companion.apk')]:
    temporary = dst.with_suffix('.next'); shutil.copy2(src, temporary); os.replace(temporary, dst)
info = app/'Contents/Info.plist'
data = plistlib.loads((ROOT/'packaging/Info.plist').read_bytes())
data.update(CFBundleShortVersionString='3.3.0',CFBundleVersion='13',
            NSLocalNetworkUsageDescription='Connect securely to your paired Android phone for notifications and file sharing.',
            NSBonjourServices=['_androidwireless._tcp.','_adb-tls-connect._tcp.'])
info.write_bytes(plistlib.dumps(data))
run('codesign','--force','--deep','--sign','-',app)
run('codesign','--verify','--deep','--strict',app)
if args.deploy_phone:
    if not args.device: parser.error('--deploy-phone requires --device with the current connection endpoint')
    result = subprocess.run(['/opt/homebrew/bin/adb','-s',args.device,'shell','-n','getprop','ro.serialno'],capture_output=True,text=True,timeout=8,check=True)
    if result.stdout.strip() != 'R5CW515PYBR': raise RuntimeError('Selected device is not the paired Samsung')
    run('/opt/homebrew/bin/adb','-s',args.device,'install','--no-incremental','-r', ROOT/'Android Wireless Companion.apk')
print('Built and verified:', app)
