from pathlib import Path
import subprocess, tempfile

ROOT = Path(__file__).resolve().parents[2]
JAVA = Path('/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home/bin')
with tempfile.TemporaryDirectory(prefix='jh-touch-lease-') as folder:
    subprocess.run([str(JAVA/'javac'), '-d', folder,
        str(ROOT/'android/src/com/johirulhoqakash/jhmirror/TouchGuardLease.java'),
        str(ROOT/'android/src/com/johirulhoqakash/jhmirror/TouchGuardConfig.java'), str(Path(__file__).with_name('TouchGuardConfigTest.java')), str(Path(__file__).with_name('TouchGuardLeaseTest.java'))], check=True)
    subprocess.run([str(JAVA/'java'), '-cp', folder, 'com.johirulhoqakash.jhmirror.TouchGuardLeaseTest'], check=True)

    subprocess.run([str(JAVA/'java'), '-cp', folder, 'com.johirulhoqakash.jhmirror.TouchGuardConfigTest'], check=True)
