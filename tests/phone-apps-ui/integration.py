from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='jh-apps-ui-') as directory:
    output=Path(directory)/'check'
    subprocess.run(['swiftc',*(str(ROOT/name) for name in ['PhoneApps.swift','PhoneAppTile.swift','PhoneAppsWindow.swift','PhoneTools.swift']),
        str(Path(__file__).with_name('main.swift')),'-module-cache-path','/private/tmp/jh-mirror-swift-cache','-o',str(output)],check=True)
    subprocess.run([str(output)],check=True,timeout=20)
