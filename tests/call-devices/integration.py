"""Validate Core Audio device lookup without opening audio or changing device settings."""
from pathlib import Path
import subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='jh-audio-device-check-') as directory:
    output=Path(directory)/'device-check'
    subprocess.run(['swiftc',str(ROOT/'CallDevices.swift'),str(ROOT/'tests/call-devices/main.swift'),
        '-module-cache-path','/private/tmp/jh-mirror-swift-cache','-o',str(output)],check=True)
    subprocess.run([str(output)],check=True,timeout=15)
