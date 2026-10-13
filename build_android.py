#!/usr/bin/env python3
"""Build a small SDK-only Java APK without Gradle or external dependencies."""
from pathlib import Path
import os
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent
SDK = ROOT / '.android-sdk'
TOOLS = SDK / 'build-tools' / '36.0.0'
JAVA = Path(os.environ.get('JAVA_HOME', '/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home'))
ENV = dict(os.environ, JAVA_HOME=str(JAVA))
BUILD = ROOT / 'android' / 'build'
BUILD.mkdir(exist_ok=True)
(BUILD / 'classes').mkdir(exist_ok=True)
(BUILD / 'dex').mkdir(exist_ok=True)
JAR = SDK / 'platforms' / 'android-36' / 'android.jar'

def run(*args):
    subprocess.run([str(arg) for arg in args], env=ENV, check=True)

sources = sorted((ROOT / 'android' / 'src').rglob('*.java'))
run(JAVA / 'bin/javac', '--release', '8', '-classpath', JAR, '-d', BUILD / 'classes', *sources)
classes = sorted((BUILD / 'classes').rglob('*.class'))
run(TOOLS / 'd8', '--min-api', '26', '--lib', JAR, '--output', BUILD / 'dex', *classes)
unsigned = BUILD / 'unsigned.apk'
run(TOOLS / 'aapt2', 'compile', '--dir', ROOT / 'android/res', '-o', BUILD / 'resources.zip')
run(TOOLS / 'aapt2', 'link', '-o', unsigned, '-I', JAR, '--manifest', ROOT / 'android/AndroidManifest.xml', BUILD / 'resources.zip')
with zipfile.ZipFile(unsigned, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
    archive.write(BUILD / 'dex/classes.dex', 'classes.dex')
run(TOOLS / 'zipalign', '-f', '4', unsigned, BUILD / 'aligned.apk')
key = BUILD / 'personal-signing.keystore'
if not key.exists():
    run(JAVA / 'bin/keytool', '-genkeypair', '-keystore', key, '-storepass', 'android', '-keypass', 'android',
        '-alias', 'androidwireless', '-keyalg', 'RSA', '-keysize', '3072', '-validity', '10000',
        '-dname', 'CN=Android Wireless Personal Build', '-noprompt')
    key.chmod(0o600)
apk = ROOT / 'Android Wireless Companion.apk'
run(TOOLS / 'apksigner', 'sign', '--ks', key, '--ks-key-alias', 'androidwireless', '--ks-pass', 'pass:android',
    '--key-pass', 'pass:android', '--out', apk, BUILD / 'aligned.apk')
run(TOOLS / 'apksigner', 'verify', apk)
print('Built and verified:', apk)
