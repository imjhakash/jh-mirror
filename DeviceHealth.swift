import Foundation

enum DeviceFeature: String, Codable, CaseIterable {
    case mirror, files, gallery, camera, microphone, audio, screenOff, notifications, apps
    var title: String {
        switch self {
        case .mirror: return "Screen mirroring"
        case .files: return "File transfer"
        case .gallery: return "Media library"
        case .camera: return "Phone camera for calls"
        case .microphone: return "Phone microphone for calls"
        case .audio: return "Phone audio on Mac"
        case .screenOff: return "Screen off & touch protection"
        case .notifications: return "Notifications"
        case .apps: return "App Library"
        }
    }
    var minimumSDK: Int {
        switch self { case .camera: return 31; case .microphone, .audio: return 30; case .screenOff: return 34; default: return 26 }
    }
    var minimumAndroid: String {
        switch minimumSDK { case 31: return "12"; case 30: return "11"; case 34: return "14"; default: return "8" }
    }
}

struct PhoneDeviceInfo: Codable, Equatable {
    let model: String
    let android: String
    let sdk: Int
    let hasCamera: Bool
    let hasMicrophone: Bool
    let notificationAccess: Bool
    let notificationEnabled: Bool
    let touchGuard: Bool
    var valid: Bool { (26...100).contains(sdk) && !model.isEmpty && model.count <= 160 && android.count <= 40 }
}

struct DeviceFeatureStatus: Codable, Equatable {
    let id: DeviceFeature
    let state: String
    let label: String
    let reason: String
    let nextStep: String
    var title: String { id.title }
}

/// Platform support and successful observations are separate: untested hardware is never green.
final class DeviceHealth {
    private(set) var info: PhoneDeviceInfo?
    private var observations: [DeviceFeature: DeviceFeatureStatus] = [:]
    private(set) var identity = ""
    var onChange: (() -> Void)?
    var connected = false
    var adbConnected = false
    var cameraInstalled = false
    var microphoneInstalled = false
    var mirrorLive = false
    var cameraLive = false
    var microphoneLive = false
    var audioLive = false
    var screenOffLive = false

    func usePhone(_ identity: String) {
        guard self.identity != identity else { return }
        self.identity = identity; info = nil; observations.removeAll(); connected = false
        mirrorLive = false; cameraLive = false; microphoneLive = false; audioLive = false; screenOffLive = false
        onChange?()
    }
    func update(_ device: PhoneDeviceInfo) {
        guard device.valid else { return }
        if let info, info.sdk != device.sdk || info.model != device.model { observations.removeAll() }
        info = device; onChange?()
    }
    func record(_ feature: DeviceFeature, success: Bool, reason: String, nextStep: String = "") {
        let value = DeviceFeatureStatus(id: feature, state: success ? "green" : "red",
            label: success ? "Checked" : "Failed", reason: String(reason.prefix(600)), nextStep: String(nextStep.prefix(300)))
        guard observations[feature] != value else { return }; observations[feature] = value
        onChange?()
    }
    func resetChecks() { observations.removeAll(); onChange?() }
    func connectionState(_ value: Bool) {
        if connected != value { observations.removeAll() }
        connected = value
    }
    func ready(_ feature: DeviceFeature, reason: String) {
        if observations[feature]?.state == "green" { return }
        let value = DeviceFeatureStatus(id: feature, state: "yellow", label: "Ready · transfer not tested", reason: reason,
            nextStep: "Send or save a file to verify a complete transfer. Originals are kept.")
        guard observations[feature] != value else { return }; observations[feature] = value; onChange?()
    }
    func unsupported(_ feature: DeviceFeature) -> Bool {
        guard let info else { return false }
        return info.sdk < feature.minimumSDK || (feature == .camera && !info.hasCamera) || (feature == .microphone && !info.hasMicrophone)
    }
    func status(_ feature: DeviceFeature) -> DeviceFeatureStatus {
        func row(_ state: String, _ label: String, _ reason: String, _ next: String = "") -> DeviceFeatureStatus {
            DeviceFeatureStatus(id: feature, state: state, label: label, reason: reason, nextStep: next)
        }
        guard let info else { return row("yellow", "Not checked", "Connect the paired phone to read its Android version and capabilities.", "Open Device Check and click Check again.") }
        if info.sdk < feature.minimumSDK {
            return row("red", "Unsupported", "This phone runs Android \(info.android). \(feature.title) requires Android \(feature.minimumAndroid) or newer.",
                       feature == .screenOff ? "Keep the phone display on while mirroring. Other supported features remain available." : "Use a supported phone or an official Android update, if one is available.")
        }
        if feature == .camera && !info.hasCamera { return row("red", "Unsupported", "Android reports no camera on this device.") }
        if feature == .microphone && !info.hasMicrophone { return row("red", "Unsupported", "Android reports no microphone on this device.") }
        guard connected else { return row("yellow", "Disconnected", "This feature has not been checked on the current connection.", "Reconnect the paired phone. Android 10 and earlier can use an authorized USB connection.") }
        if feature == .notifications {
            if !info.notificationAccess { return row("yellow", "Needs permission", "Notification access is off on the phone.", "Phone app → Settings → Notification access. Enable JH Mirror.") }
            if !info.notificationEnabled { return row("yellow", "Paused", "Send notifications to Mac is switched off.", "Turn it on in the phone app's Settings.") }
            return row("green", "Connected", "The notification listener and paired connection are available. Android may hide sensitive notifications.")
        }
        if !adbConnected && feature != .files {
            return row("yellow", "Needs ADB connection", "Notification sync is connected, but this feature also needs an authorized debugging connection.", info.sdk < 30 ? "Connect USB and approve this Mac on the phone. QR wireless pairing requires Android 11+." : "Enable Wireless debugging on the same Wi-Fi, then click Reconnect.")
        }
        let live: Bool
        switch feature {
        case .mirror: live = mirrorLive
        case .camera: live = cameraLive
        case .microphone: live = microphoneLive
        case .audio: live = audioLive
        case .screenOff: live = screenOffLive
        default: live = false
        }
        if live { return row("green", "Active", "This feature is active on the current connection.") }
        if let observed = observations[feature] { return observed }
        if feature == .camera && !cameraInstalled { return row("yellow", "Needs Mac setup", "The OBS virtual-camera component is not available on this Mac.", "Open Camera & Microphone Setup. The OBS app can stay closed after setup.") }
        if feature == .microphone && !microphoneInstalled { return row("yellow", "Needs Mac setup", "BlackHole 2ch is not available to Core Audio.", "Finish microphone setup and restart the Mac if the installer requested it.") }
        if feature == .screenOff && !info.touchGuard { return row("yellow", "Ready for setup", "Android supports touch protection; it is enabled only when you turn the phone screen off.", "Use Turn Phone Screen Off. A failed guard leaves the display on.") }
        if feature == .audio && info.sdk == 30 { return row("yellow", "Ready · unlock first", "Android 11 needs the phone unlocked when audio capture starts.", "Unlock once, then enable phone audio.") }
        return row("yellow", "Ready · not tested", "The Android requirements are met. A successful operation has not yet been observed.",
                   [.camera, .microphone].contains(feature) ? "Start this input to check it. Device Check never turns on a camera or microphone." : "Use this feature or click Check again for read-only file/media checks.")
    }
    var rows: [DeviceFeatureStatus] { DeviceFeature.allCases.map(status) }
    var report: Data? { try? JSONEncoder().encode(rows) }
}
