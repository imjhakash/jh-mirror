import Foundation
import CoreAudio

enum CallDevices {
    static let loopbackName = "BlackHole 2ch"

    static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: AudioDeviceID = 0; var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value) == noErr, value != 0 else { return nil }
        return value
    }

    @discardableResult static func setDefaultInput(_ value: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = value
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout.size(ofValue: value)), &value) == noErr
    }

    static func loopback(name requested: String = loopbackName) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty, AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { device in
            var property = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard stringProperty(device, address: property) == requested else { return false }
            if requested == "JH Mirror Microphone", uid(device) != "com.johirulhoqakash.jhmirror.microphone" { return false }
            // Require both an input and output on this loopback device.
            return [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput].allSatisfy { scope in
                property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
                var bytes: UInt32 = 0
                return AudioObjectGetPropertyDataSize(device, &property, 0, nil, &bytes) == noErr && bytes > 0
            }
        }
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        let address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return stringProperty(device, address: address)
    }

    private static func stringProperty(_ device: AudioDeviceID, address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func device(uid: String) -> AudioDeviceID? {
        var name = uid as CFString
        var result: AudioDeviceID = 0
        return withUnsafeMutablePointer(to: &name) { input in
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), input, &size, &result)
            return status == noErr && result != 0 ? result : nil
        }
    }

    private static let recoveryKey = "callPreviousMicrophoneUID"
    private static let selectedKey = "callSelectedMicrophoneUID"
    static func usePhoneMicrophone(name: String = loopbackName) throws {
        guard let blackhole = loopback(name: name), let selectedUID = uid(blackhole) else { throw CallError("Install \(name) from Call Setup first.") }
        if let current = defaultInput(), current != blackhole, let previous = uid(current) {
            UserDefaults.standard.set(previous, forKey: recoveryKey)
            UserDefaults.standard.set(selectedUID, forKey: selectedKey)
            guard setDefaultInput(blackhole) else {
                UserDefaults.standard.removeObject(forKey: recoveryKey)
                UserDefaults.standard.removeObject(forKey: selectedKey)
                throw CallError("macOS could not switch the microphone to \(name).")
            }
        }
    }
    /// Also called at launch, so a crash never leaves a remembered phone microphone selected.
    static func restoreMicrophone() {
        guard let previous = UserDefaults.standard.string(forKey: recoveryKey) else { return }
        // Older releases only remembered BlackHole. Compare UIDs so a missing native
        // device cannot make a later manual switch to BlackHole look like our choice.
        let selectedUID = UserDefaults.standard.string(forKey: selectedKey) ?? loopback().flatMap { uid($0) }
        if let selectedUID, let current = defaultInput(), let currentUID = uid(current), currentUID == selectedUID,
           let device = device(uid: previous) {
            _ = setDefaultInput(device)
        }
        UserDefaults.standard.removeObject(forKey: recoveryKey)
        UserDefaults.standard.removeObject(forKey: selectedKey)
    }
}
