import Foundation
import CoreMediaIO

/// Uses the installed, signed OBS camera device through Core Media I/O. No OBS process or WebSocket.
enum CallCamera {
    static let deviceUID = "7626645E-4425-469E-9D8B-97E0FA59AC75"
    // The camera panel always uses the verified direct path. Legacy OBS transport
    // remains available to explicit test/integration callers, not normal camera UI.
    static let usesOBSCompatibility = false

    static var available: Bool {
        var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyDevices),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0, size <= 4096, size % 4 == 0 else { return false }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &size, &devices) == noErr else { return false }
        for device in devices {
            var uid: Unmanaged<CFString>?; var bytes = UInt32(MemoryLayout.size(ofValue: uid))
            address.mSelector = UInt32(kCMIODevicePropertyDeviceUID)
            if CMIOObjectGetPropertyData(device, &address, 0, nil, bytes, &bytes, &uid) == noErr,
               let uid, uid.takeRetainedValue() as String == deviceUID { return true }
        }
        return false
    }
}
