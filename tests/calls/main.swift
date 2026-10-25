import AppKit
import Foundation

let scrcpyPath = CommandLine.arguments[2]
let adbPath = "/usr/bin/true"
func adbEnvironment() -> [String: String] { ProcessInfo.processInfo.environment }

// Audio routing is tested separately on hardware; lifecycle tests never change the user's input.
enum CallDevices {
    static let loopbackName = "BlackHole 2ch"
    static func restoreMicrophone() { }
    static func loopback(name: String = loopbackName) -> UInt32? { nil }
    static func usePhoneMicrophone(name: String = loopbackName) throws { throw CallError("No test audio device") }
}
enum CallCamera {
    static let usesOBSCompatibility = true
    static let available = false
    static let deviceUID = "test-virtual-device"
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

Task { @MainActor in
    do {
        let port = Int(CommandLine.arguments[1])!
        let obs = OBSConnection()
        try await obs.connect(port: port, password: "test-password")
        let version = try await obs.request("GetVersion")
        require(version["obsVersion"] as? String == "test", "correlated OBS response, ignoring events")
        do { _ = try await obs.request("UnsupportedRequest"); require(false, "OBS rejection must throw") } catch is CallError { }
        await obs.close()
        do { try await obs.connect(port: 0, password: ""); require(false, "invalid port must throw") } catch is CallError { }
        let arguments = PhoneCalls.cameraArguments(serial: "paired", facing: "back", fifo: "/private/path with spaces/stream.mkv")
        require(arguments.contains("--no-audio") && arguments.contains("--no-control"), "camera is video-only without input injection")
        require(arguments.contains("--record=/private/path with spaces/stream.mkv"), "FIFO path remains one process argument")
        require(PhoneCalls.microphoneArguments(serial: "paired").contains("--audio-source=mic"), "capture mic rather than phone playback")
        require(PhoneCalls.cameraFailure("No video, no audio, no control: nothing to do", status: 1, direct: true).contains("disabled video"), "parser failure is explained")
        require(PhoneCalls.cameraFailure("ERROR_CAMERA_IN_USE", status: 1, direct: true).contains("in use"), "busy phone camera is explained")
        require(PhoneCalls.cameraFailure("device offline", status: 1, direct: true).contains("Reconnect"), "disconnected phone is explained")
        let directArguments = PhoneCalls.directCameraArguments(serial: "paired", facing: "front")
        require(directArguments.contains("--no-window") && directArguments.contains("--no-control") && directArguments.contains("--no-audio"), "direct camera has no window, touch or audio")
        require(!directArguments.contains(where: { $0.hasPrefix("--record") || $0 == "--no-playback" }), "direct camera decodes in memory without a recording or FIFO")
        UserDefaults.standard.set(port, forKey: "obsWebSocketPort")
        let calls = PhoneCalls(hasOBS: { true }, password: { "test-password" }, prepareOBS: { false }, useDirectCamera: { false })
        calls.toggleCamera(serial: "paired")
        let startup = Date().addingTimeInterval(10)
        while (calls.cameraBusy || calls.camera == .starting) && Date() < startup {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        require(calls.camera == .active, "camera starts, OBS receives media, virtual camera active: \(calls.message)")
        calls.stopCamera()
        while calls.cameraBusy { try await Task.sleep(nanoseconds: 100_000_000) }
        require(calls.camera == .off, "camera stops and cleanup finishes")
        // Cancel while OBS is processing startup. No capture may survive the cancelled request.
        calls.toggleCamera(serial: "paired")
        try await Task.sleep(nanoseconds: 20_000_000)
        calls.stopCamera()
        while calls.cameraBusy { try await Task.sleep(nanoseconds: 100_000_000) }
        require(calls.camera == .off, "cancelled startup leaves camera off")
        calls.toggleMicrophone(serial: "paired")
        require(calls.microphone == .off, "missing loopback never starts capture or falls back to speakers")
        let direct = PhoneCalls(hasOBS: { false }, password: { fatalError("Direct mode must not access credentials") },
            prepareOBS: { fatalError("Direct mode must not launch OBS") }, useDirectCamera: { true }, hasDirectCamera: { true }, obsRunning: { false })
        direct.previewVisible = true
        direct.toggleCamera(serial: "paired")
        let directDeadline = Date().addingTimeInterval(5)
        while direct.camera != .active && Date() < directDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        require(direct.camera == .active, "direct camera accepts frame heartbeat without OBS")
        let previewURL = direct.previewURL!
        let oldAngle = direct.rotation
        direct.rotateCamera(); direct.setMirrored(true)
        require(direct.rotation == (oldAngle + 90) % 360 && direct.previewURL == previewURL && direct.camera == .active, "rotation does not restart capture")
        let control = try Data(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("control.bin"))
        require(control.count == 8 && control[4] & 12 == 12 && Int(control[4] & 3) == direct.rotation / 90, "private live control flags contain preview, mirror and angle")
        direct.switchFacing(serial: "paired")
        while (direct.camera != .active || direct.cameraBusy) && Date() < directDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        require(direct.camera == .active, "facing change restarts only the direct camera")
        direct.switchFacing(serial: "paired")
        direct.stopCamera()
        while direct.cameraBusy { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        require(direct.camera == .off && direct.previewURL == nil, "closing during a lens switch cancels the pending restart")
        require(!FileManager.default.fileExists(atPath: previewURL.path), "stop deletes the private preview buffer")
        require(direct.camera == .off, "direct stop cleans up the helper")
        direct.toggleCamera(serial: "crash")
        try await Task.sleep(nanoseconds: 300_000_000)
        require(direct.camera == .off, "failed direct helper stops the camera")
        let blocked = PhoneCalls(password: { "test-password" }, useDirectCamera: { true }, hasDirectCamera: { true }, obsRunning: { true })
        blocked.toggleCamera(serial: "paired")
        while blocked.cameraBusy { try await Task.sleep(nanoseconds: 50_000_000) }
        require(blocked.camera == .off && blocked.message.contains("Close OBS"), "never takes the camera over from a running OBS app")
        let missing = PhoneCalls(useDirectCamera: { true }, hasDirectCamera: { false }, obsRunning: { false })
        missing.toggleCamera(serial: "paired")
        require(missing.camera == .off, "missing camera component refuses capture")
        UserDefaults.standard.removeObject(forKey: "obsWebSocketPort")
        print("PASS: OBS authentication and cleanup; direct camera lifecycle, facing, missing device, conflict and helper failure; missing mic refuses capture.")
        exit(0)
    } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
