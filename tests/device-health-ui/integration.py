from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='jh-health-ui-') as directory:
    output=Path(directory)/'check'
    subprocess.run(['swiftc',*(str(ROOT/name) for name in ['DeviceHealth.swift','DeviceHealthWindow.swift','PhoneWindowFlow.swift','tests/device-health-ui/main.swift']),
                    '-module-cache-path','/private/tmp/jh-mirror-swift-cache','-o',str(output),'-framework','AppKit'],check=True)
    subprocess.run([str(output)],check=True,timeout=15)
