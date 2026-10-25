import Foundation

func info(_ sdk: Int, camera: Bool = true, mic: Bool = true, access: Bool = true, enabled: Bool = true) -> PhoneDeviceInfo {
    PhoneDeviceInfo(model: "Generated Galaxy A10", android: sdk == 28 ? "9" : sdk == 29 ? "10" : sdk == 30 ? "11" : sdk == 31 ? "12" : "14",
        sdk: sdk, hasCamera: camera, hasMicrophone: mic, notificationAccess: access, notificationEnabled: enabled, touchGuard: false)
}
func require(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
let health = DeviceHealth()
require(health.rows.count == 9 && health.rows.allSatisfy { $0.state == "yellow" }, "unknown device cannot claim working features")
for (sdk, unsupported) in [(26,4), (28,4), (29,4), (30,2), (31,1), (33,1), (34,0), (36,0)] {
    health.usePhone("generated-\(sdk)"); health.update(info(sdk)); health.connectionState(true); health.adbConnected = true
    health.cameraInstalled = true; health.microphoneInstalled = true
    require(health.rows.filter { $0.label == "Unsupported" }.count == unsupported, "correct Android feature requirements for API \(sdk)")
    require(health.status(.files).state == "yellow" && health.status(.gallery).state == "yellow", "untested storage is not green")
    health.record(.camera, success: true, reason: "Injected historical success")
    if sdk < 31 { require(health.status(.camera).state == "red" && health.status(.camera).reason.contains("Android 12"), "an observation cannot bypass Android requirements") }
}
health.usePhone("current"); health.update(info(34)); health.connectionState(true); health.adbConnected = true
health.mirrorLive = true; require(health.status(.mirror).state == "green", "live mirror is green")
health.ready(.files, reason: "Shared storage checked")
require(health.status(.files).state == "yellow", "readable storage does not claim a completed transfer")
health.record(.files, success: true, reason: "SHA-256 verified")
health.ready(.files, reason: "Folder reopened")
require(health.status(.files).state == "green", "a later folder open does not erase a verified transfer")
health.record(.gallery, success: false, reason: "Read permission denied", nextStep: "Unlock and approve the Mac")
require(health.status(.gallery).state == "red" && health.status(.gallery).reason.contains("permission"), "runtime failure includes its reason")
health.connectionState(false); require(health.status(.files).state == "yellow", "disconnect invalidates past green checks")
health.connectionState(true); require(health.status(.gallery).state == "yellow", "reconnect clears stale errors until checked")
health.update(info(34, access: false)); require(health.status(.notifications).label == "Needs permission", "permission differs from unsupported hardware")
health.update(info(34, enabled: false)); require(health.status(.notifications).label == "Paused", "notification pause has its own explanation")
health.update(info(34, camera: false)); require(health.status(.camera).label == "Unsupported", "missing camera hardware is detected")
health.update(info(34)); health.cameraInstalled = false; require(health.status(.camera).label == "Needs Mac setup", "Mac setup is distinct from phone support")
health.adbConnected = false; require(health.status(.gallery).label == "Needs ADB connection", "sync-only connection does not claim gallery readiness")
let report = try! JSONDecoder().decode([DeviceFeatureStatus].self, from: health.report!)
require(report.count == 9 && Set(report.map(\.id)).count == 9, "report has one bounded row per feature")
health.usePhone("another-phone"); require(health.info == nil && health.rows.allSatisfy { $0.state == "yellow" }, "device change cannot retain old capabilities")
print("PASS: Android 8–16 requirement matrix, truthful untested states, runtime failures, permissions, Mac setup, connection and phone isolation, bounded report")
