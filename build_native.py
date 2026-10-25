#!/usr/bin/env python3
"""Build JH Mirror's own camera extension and Core Audio driver, without installing them.

Default: compile and ad-hoc sign inspection/test artifacts only. Activation requires an
Apple-signed build of the containing app; this tool never changes macOS security settings.
"""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, re, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parent
CAMERA_ID = 'com.johirulhoqakash.jhmirror.camera'
AUDIO_ID = 'com.johirulhoqakash.jhmirror.audio'
VERSION = '1.0.0'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=ROOT/'dist.noindex/native')
parser.add_argument('--identity', help='Apple signing identity; omit for noninstallable local artifacts')
parser.add_argument('--team-id')
parser.add_argument('--camera-profile', type=Path)
parser.add_argument('--installer-identity', help='Developer ID Installer identity for the microphone package')
parser.add_argument('--diagnose', action='store_true')
args = parser.parse_args()

def run(*command, **options):
    return subprocess.run([str(value) for value in command], check=True, **options)

if args.diagnose:
    run('security', 'find-identity', '-v', '-p', 'codesigning')
    print('Native camera activation needs an Apple-signed container and camera extension, matching Team IDs, profiles, and macOS approval.')
    print('No native component was installed or activated.')
    raise SystemExit(0)

signed = bool(args.identity)
if signed:
    if not args.team_id or not re.fullmatch(r'[A-Z0-9]{10}', args.team_id):
        parser.error('--identity requires a ten-character --team-id')
    if not args.camera_profile or not args.camera_profile.is_file():
        parser.error('--identity requires an existing --camera-profile')
    if not args.installer_identity:
        parser.error('--identity requires --installer-identity for the native microphone installer')
elif any([args.team_id, args.camera_profile, args.installer_identity]):
    parser.error('Signing settings require --identity; partial signing never produces an installable build')

output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
extension = output/(CAMERA_ID+'.systemextension')
audio = output/'JH Mirror Microphone.driver'
for bundle in [extension, audio]:
    if bundle.exists(): shutil.rmtree(bundle)
    (bundle/'Contents/MacOS').mkdir(parents=True)
    (bundle/'Contents/Resources').mkdir()

def plist(path, data): path.write_bytes(plistlib.dumps(data))

group = (args.team_id or 'UNSIGNED00') + '.com.johirulhoqakash.jhmirror'
plist(extension/'Contents/Info.plist', {
    'CFBundleIdentifier':CAMERA_ID, 'CFBundleName':'JH Mirror Camera', 'CFBundleDisplayName':'JH Mirror Camera',
    'CFBundleExecutable':'JHMirrorCamera', 'CFBundlePackageType':'SYSX',
    'CFBundleShortVersionString':VERSION, 'CFBundleVersion':'1', 'LSMinimumSystemVersion':'13.0',
    'CMIOExtension':{'CMIOExtensionMachServiceName':group+'.camera'},
    'NSSystemExtensionUsageDescription':'JH Mirror makes your Android phone available as JH Mirror Camera in video calls.',
    'JHMirrorTeamID':args.team_id or '',
})
factory = 'CB6E2D7B-B802-471C-A31D-6C1A30D9C202'
plist(audio/'Contents/Info.plist', {
    'CFBundleIdentifier':AUDIO_ID, 'CFBundleName':'JH Mirror Microphone', 'CFBundleExecutable':'JHMirrorAudio',
    'CFBundlePackageType':'BNDL', 'CFBundleShortVersionString':VERSION, 'CFBundleVersion':'1',
    'CFPlugInDynamicRegistration':False, 'CFPlugInFactories':{factory:'JHMirrorAudioFactory'},
    'CFPlugInTypes':{'443ABAB8-E7B3-491A-B985-BEB9187030DB':[factory]},
})
run('clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-O2', '-mmacosx-version-min=13.0',
    ROOT/'native/Camera/CameraExtension.m', '-framework','Foundation','-framework','CoreMediaIO',
    '-framework','CoreVideo','-framework','CoreMedia','-framework','Security', '-o',extension/'Contents/MacOS/JHMirrorCamera')
run('clang','-std=c11','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-O2','-mmacosx-version-min=13.0','-bundle',
    ROOT/'native/Audio/JHMirrorAudio.c','-framework','CoreAudio','-framework','CoreFoundation','-o',audio/'Contents/MacOS/JHMirrorAudio')

entitlements = output/'camera.entitlements'
plist(entitlements, {'com.apple.security.app-sandbox':True, 'com.apple.security.application-groups':[group]})
if signed: shutil.copy2(args.camera_profile, extension/'Contents/embedded.provisionprofile')
sign = ['codesign','--force','--sign',args.identity or '-']
if signed: sign += ['--options','runtime','--timestamp']
run(*sign, audio)
run(*sign, *(['--entitlements',entitlements] if signed else []), extension)
for bundle in [audio,extension]: run('codesign','--verify','--deep','--strict',bundle)

package = output/'JH Mirror Native Audio.pkg'
with tempfile.TemporaryDirectory(prefix='jh-native-audio-package-') as folder:
    folder = Path(folder); payload = folder/'root/Library/Audio/Plug-Ins/HAL'
    payload.mkdir(parents=True); shutil.copytree(audio,payload/audio.name)
    # The system daemon must never load a bundle writable by an unprivileged user.
    for path in (folder/'root').rglob('*'): path.chmod(0o755 if path.is_dir() or path.name=='JHMirrorAudio' else 0o644)
    component = folder/'audio.pkg'
    run('pkgbuild','--root',folder/'root','--identifier',AUDIO_ID+'.installer','--version',VERSION,
        '--install-location','/','--ownership','recommended',component,stdout=subprocess.DEVNULL)
    distribution = folder/'distribution.xml'
    distribution.write_text('''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
 <title>JH Mirror Native Microphone</title>
 <options customize="never" require-scripts="false"/>
 <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
 <choices-outline><line choice="audio"/></choices-outline>
 <choice id="audio" visible="false"><pkg-ref id="com.johirulhoqakash.jhmirror.audio.installer"/></choice>
 <pkg-ref id="com.johirulhoqakash.jhmirror.audio.installer" version="1.0.0" onConclusion="RequireRestart">audio.pkg</pkg-ref>
</installer-gui-script>
''')
    command=['productbuild','--distribution',distribution,'--package-path',folder]
    if signed: command += ['--sign',args.installer_identity]
    run(*command,package,stdout=subprocess.DEVNULL)

manifest={'version':VERSION,'apple_signed':signed,'team_id':args.team_id,
    'camera_identifier':CAMERA_ID,'audio_identifier':AUDIO_ID,
    'activation_ready':False,'activation_note':'Requires the signed/provisioned containing app and macOS approval; local artifacts are never activated.',
    'sha256':{str(path.relative_to(output)):hashlib.sha256(path.read_bytes()).hexdigest()
              for path in [extension/'Contents/MacOS/JHMirrorCamera',audio/'Contents/MacOS/JHMirrorAudio',package]}}
(output/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Built native components:',output)
print('Apple signed; embed in the matching signed app before activation.' if signed
      else 'LOCAL BUILD ONLY: no Apple identity/profile; nothing installed or activated.')
