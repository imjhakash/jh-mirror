from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='jh-browser-tests-') as directory:
    output=Path(directory)/'check'
    subprocess.run(['swiftc',*(str(ROOT/name) for name in ['FileTransferClient.swift','PhoneFiles.swift','PhoneFilesBrowser.swift','tests/phone-files/support.swift','tests/phone-files/Mock.swift','tests/phone-browser/main.swift']),'-module-cache-path','/private/tmp/jh-mirror-swift-cache','-o',str(output)],check=True)
    subprocess.run([str(output)],check=True,timeout=15)
