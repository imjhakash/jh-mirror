from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='jh-window-flow-') as directory:
    output = Path(directory) / 'check'
    subprocess.run(['swiftc', str(ROOT / 'PhoneWindowFlow.swift'),
                    str(Path(__file__).with_name('main.swift')),
                    '-module-cache-path', '/private/tmp/jh-mirror-swift-cache',
                    '-o', str(output), '-framework', 'AppKit'], check=True)
    subprocess.run([str(output)], check=True, timeout=15)
