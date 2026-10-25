from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='jh-grid-stress-') as directory:
    output=Path(directory)/'check'
    sources=['PhoneWindowFlow.swift','Clipboard.swift','FileTransferClient.swift','PhoneFiles.swift','PhoneFilesBrowser.swift','PhoneFileTransfers.swift','PhoneMediaActions.swift','PhonePreviewLoader.swift','PhoneThumbnailLoader.swift','PhoneMediaPreviewWindow.swift','PhoneFilesWindow.swift','tests/phone-files/support.swift','tests/phone-files/Mock.swift','tests/gallery-stress/main.swift']
    subprocess.run(['swiftc',*(str(ROOT/p) for p in sources),'-module-cache-path','/private/tmp/jh-mirror-swift-cache','-o',str(output),'-framework','AppKit','-framework','QuickLookUI'],check=True)
    subprocess.run([str(output)],check=True,timeout=35)
