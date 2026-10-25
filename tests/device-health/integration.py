from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
JAVA = Path('/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home/bin')
with tempfile.TemporaryDirectory(prefix='jh-device-health-') as directory:
    output = Path(directory) / 'check'
    subprocess.run(['swiftc', str(ROOT/'DeviceHealth.swift'), str(HERE/'main.swift'),
                    '-module-cache-path', '/private/tmp/jh-mirror-swift-cache', '-o', str(output)], check=True)
    subprocess.run([str(output)], check=True, timeout=10)
    subprocess.run([str(JAVA/'javac'), '-d', directory,
                    str(ROOT/'scrcpy-5.0.1/server/src/main/java/com/genymobile/scrcpy/JHMediaQuery.java'), str(HERE/'MediaQueryCheck.java')], check=True)
    subprocess.run([str(JAVA/'java'), '-cp', directory, 'MediaQueryCheck'], check=True, timeout=10)
