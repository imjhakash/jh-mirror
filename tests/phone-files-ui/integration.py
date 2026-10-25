from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='jh-files-ui-') as directory:
    output=Path(directory)/'check'
    subprocess.run(['swiftc',*(str(ROOT/name) for name in ['PhoneWindowFlow.swift','Clipboard.swift','FileTransferClient.swift','PhoneFiles.swift','PhoneFilesBrowser.swift','PhoneFileTransfers.swift','PhoneMediaActions.swift','PhonePreviewLoader.swift','PhoneThumbnailLoader.swift','PhoneMediaPreviewWindow.swift','PhoneFilesWindow.swift','tests/phone-files/support.swift','tests/phone-files/Mock.swift','tests/phone-files-ui/main.swift']),'-module-cache-path','/private/tmp/jh-mirror-swift-cache','-o',str(output),'-framework','AppKit','-framework','QuickLookUI'],check=True)
    subprocess.run([str(output)],check=True,timeout=25)
