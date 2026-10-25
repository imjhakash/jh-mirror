from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='jh-preview-tests-') as directory:
    output=Path(directory)/'check'
    subprocess.run(['swiftc',*(str(ROOT/name) for name in ['FileTransferClient.swift','PhoneFiles.swift','PhonePreviewLoader.swift','tests/phone-files/support.swift','tests/phone-files/Mock.swift','tests/media-preview/main.swift']),'-module-cache-path','/private/tmp/jh-mirror-swift-cache','-o',str(output),'-framework','AppKit'],check=True)
    subprocess.run([str(output)],check=True,timeout=15)
