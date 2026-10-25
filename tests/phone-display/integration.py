from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='jh-display-check-') as directory:
    output=Path(directory)/'check'
    subprocess.run(['swiftc',str(ROOT/'PhoneTouchGuard.swift'),str(Path(__file__).with_name('main.swift')),
        '-module-cache-path','/private/tmp/jh-mirror-swift-cache','-o',str(output)],check=True)
    subprocess.run([str(output)],check=True,timeout=15)
