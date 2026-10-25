import AppKit
import Foundation

/// Explicit, nonpersistent capture sessions. Video goes to CMIO (or an OBS FIFO); mic only to its selected loopback.
// Mutable session state is confined to the main thread; pipe/termination callbacks hop there.
final class PhoneCalls: @unchecked Sendable {
    var onChange: (() -> Void)?
    private(set) var camera: CallInputState = .off
    private(set) var microphone: CallInputState = .off
    private(set) var cameraBusy = false
    private(set) var message = "Select OBS Virtual Camera and BlackHole 2ch in your calling app."
    private(set) var facing = UserDefaults.standard.string(forKey: "callCameraFacing") == "back" ? "back" : "front"
    private(set) var rotation = ((UserDefaults.standard.integer(forKey: "callCameraRotation") / 90 % 4 + 4) % 4) * 90
    private(set) var mirrored = UserDefaults.standard.bool(forKey: "callCameraMirror")
    var previewVisible = false { didSet { writeCameraControls() } }
    var previewURL: URL? { directCameraSession ? directory?.appendingPathComponent("preview.bin") : nil }
    private var controlFD: Int32 = -1
    private let obs = OBSConnection()
    private var cameraTask: Task<Void, Never>?
    private var cameraWanted = false
    private var restartSerial: String?
    private var cameraProcess: Process?
    private var micProcess: Process?
    private var cameraOutput: Pipe?
    private var micOutput: Pipe?
    private var micLines = ""
    private var cameraLines = ""
    private var directCameraSession = false
    private var cameraLastFrame = Date.distantPast
    private var microphoneDeviceName = CallDevices.loopbackName
    private var directory: URL?
    private var scene: String?
    private var source: String?
    private var previousScene: String?
    private var ownsVirtualCamera = false
    private var healthTimer: Timer?
    private var cameraStarted = Date.distantPast
    private var micStarted = Date.distantPast
    private var shuttingDown = false
    private let hasOBS: () -> Bool
    private let password: () -> String
    private let prepareOBS: () async throws -> Bool
    private let useDirectCamera: () -> Bool
    private let hasDirectCamera: () -> Bool
    private let obsRunning: () -> Bool

    init(hasOBS: @escaping () -> Bool = { FileManager.default.isExecutableFile(atPath: "/Applications/OBS.app/Contents/MacOS/OBS") },
         password: @escaping () -> String = { CallCredential.read() },
         prepareOBS: @escaping () async throws -> Bool = { try await PhoneCalls.openOBS() },
         useDirectCamera: @escaping () -> Bool = { !CallCamera.usesOBSCompatibility },
         hasDirectCamera: @escaping () -> Bool = { CallCamera.available },
         obsRunning: @escaping () -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.obsproject.obs-studio").isEmpty }) {
        self.hasOBS = hasOBS
        self.password = password
        self.prepareOBS = prepareOBS
        self.useDirectCamera = useDirectCamera; self.hasDirectCamera = hasDirectCamera; self.obsRunning = obsRunning
        CallDevices.restoreMicrophone()
    }

    var obsInstalled: Bool { hasOBS() }
    var cameraSetupAvailable: Bool { useDirectCamera() ? hasDirectCamera() : obsInstalled }
    var microphoneSetupAvailable: Bool {
        CallDevices.loopback() != nil
    }
    var port: Int { let saved = UserDefaults.standard.integer(forKey: "obsWebSocketPort"); return saved == 0 ? 4455 : saved }

    static func cameraArguments(serial: String, facing: String, fifo: String) -> [String] {
        ["-s", serial, "--force-adb-forward", "--no-terminal-title", "--video-source=camera",
         "--camera-facing=\(facing)", "--camera-ar=16:9", "--max-size=1280", "--camera-fps=30",
         "--video-codec=h264", "--video-bit-rate=4M", "--no-audio", "--no-playback", "--no-control",
         "--record=\(fifo)", "--record-format=mkv"]
    }
    static func microphoneArguments(serial: String) -> [String] {
        ["-s", serial, "--force-adb-forward", "--no-terminal-title", "--no-video", "--no-control",
         "--audio-source=mic", "--audio-codec=raw", "--audio-buffer=80", "--require-audio"]
    }
    static func directCameraArguments(serial: String, facing: String) -> [String] {
        ["-s", serial, "--force-adb-forward", "--no-terminal-title", "--video-source=camera",
         "--camera-facing=\(facing)", "--camera-ar=16:9", "--max-size=1280", "--camera-fps=30",
         "--video-codec=h264", "--video-bit-rate=4M", "--no-audio", "--no-window", "--no-control"]
    }

    private func helper(arguments: [String], extras: [String: String], output: Pipe) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpyPath); process.arguments = arguments
        var environment = adbEnvironment()
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"; environment["ADB"] = adbPath
        environment["SDL_MAC_BACKGROUND_APP"] = "1"
        if let server = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) { environment["SCRCPY_SERVER_PATH"] = server.path }
        environment.merge(extras) { _, new in new }; process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
        return process
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }

    func toggleCamera(serial: String?) {
        if camera != .off || cameraBusy { stopCamera(); return }
        guard let serial else { message = "Connect your paired phone before starting the camera."; onChange?(); return }
        guard cameraSetupAvailable else { message = useDirectCamera() ? "Enable OBS Virtual Camera once in macOS, then close OBS. Open Call Setup."
            : "Install OBS Studio and enable its virtual camera in Call Setup."; onChange?(); return }
        directCameraSession = useDirectCamera()
        cameraWanted = true; camera = .starting; cameraBusy = true; cameraStarted = Date()
        message = "Starting phone camera…"; onChange?()
        cameraTask = Task { @MainActor in
            do {
                if self.directCameraSession {
                    if self.obsRunning() { try await self.releaseOBSForDirectCamera() }
                    try self.startDirectCamera(serial: serial)
                }
                else { try await self.startCamera(serial: serial) }
            }
            catch {
                let cancelled = !self.cameraWanted || self.shuttingDown
                let direct = self.directCameraSession
                await self.cleanupCamera()
                if !cancelled { self.message = (error as? CallError)?.message ?? (direct
                    ? "Could not start the direct camera. Check Call Setup and the phone connection."
                    : "Cannot connect to OBS. Open OBS, enable WebSocket Server, and check Call Setup.") }
                self.camera = .off; self.cameraWanted = false
            }
            self.cameraBusy = false; self.onChange?()
            if let serial = self.restartSerial, !self.shuttingDown {
                self.restartSerial = nil; self.toggleCamera(serial: serial)
            }
        }
        startHealthChecks()
    }

    private func checkWanted() throws {
        if !cameraWanted || shuttingDown { throw CancellationError() }
    }

    private func startDirectCamera(serial: String) throws {
        try checkWanted()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jhmirror-camera-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = root
        let control = root.appendingPathComponent("control.bin")
        controlFD = open(control.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard controlFD >= 0 else { throw CallError("Could not create private camera controls.") }
        var header: [UInt8] = [74, 72, 67, 49, 0, 0, 0, 0]
        guard write(controlFD, &header, header.count) == header.count else { throw CallError("Could not initialize camera controls.") }
        writeCameraControls()
        let preview = root.appendingPathComponent("preview.bin")
        let fd = open(preview.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CallError("Could not create private camera preview.") }
        let sized = ftruncate(fd, 64 + 640 * 360 * 4) == 0; close(fd)
        guard sized else { throw CallError("Could not size the camera preview.") }
        let output = Pipe()
        let process = helper(arguments: Self.directCameraArguments(serial: serial, facing: facing),
            extras: ["JH_CAMERA_DEVICE_UID": CallCamera.deviceUID,
                     "JH_CAMERA_CONTROL_PATH": control.path, "JH_CAMERA_PREVIEW_PATH": preview.path], output: output)
        cameraProcess = process; cameraOutput = output; cameraLines = ""
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.cameraProcess === process else { return }
                self.cameraLines = String((self.cameraLines + text).suffix(4096))
                if self.cameraWanted && self.cameraLines.contains("AW_CAMERA_FRAME") {
                    self.cameraLastFrame = Date(); self.cameraLines = ""
                    self.camera = .active
                    self.message = "Phone camera live · select OBS Virtual Camera in your call. OBS can stay closed."
                    self.onChange?()
                }
            }
        }
        process.terminationHandler = { [weak self] stopped in DispatchQueue.main.async {
            guard let self, self.cameraProcess === stopped, !self.shuttingDown else { return }
            self.message = Self.cameraFailure(self.cameraLines, status: stopped.terminationStatus, direct: true)
            self.stopCamera(announce: false)
        } }
        try process.run(); output.fileHandleForWriting.closeFile()
    }

    private func releaseOBSForDirectCamera() async throws {
        message = "Preparing phone camera…"; onChange?()
        do { try await obs.connect(port: port, password: password()) }
        catch { throw CallError("Close OBS, then click Start Camera. Its local control server is unavailable.") }
        // Errors are closed by cleanupCamera(). Do not schedule a deferred close
        // that could run after a later session connects with the same client.
        let streaming = try await obs.request("GetStreamStatus"); try checkWanted()
        let recording = try await obs.request("GetRecordStatus"); try checkWanted()
        guard streaming["outputActive"] as? Bool != true, recording["outputActive"] as? Bool != true else {
            throw CallError("OBS is recording or streaming. Stop that output before starting Phone Camera.")
        }
        let current = try await obs.request("GetCurrentProgramScene")["currentProgramSceneName"] as? String ?? ""
        guard current.hasPrefix("JH Mirror Call ") || current == "Phone Calls Ready" else {
            throw CallError("Close OBS before starting Phone Camera. Your other OBS scene has been left unchanged.")
        }
        let virtual = try await obs.request("GetVirtualCamStatus")
        if virtual["outputActive"] as? Bool == true { _ = try await obs.request("StopVirtualCam") }
        await obs.close(); try checkWanted()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.obsproject.obs-studio") { _ = app.terminate() }
        for _ in 0..<40 {
            if !obsRunning() { return }
            try await Task.sleep(nanoseconds: 100_000_000); try checkWanted()
        }
        throw CallError("OBS is still closing. Quit OBS, then click Start Camera again.")
    }

    private func writeCameraControls() {
        guard controlFD >= 0 else { return }
        var flags = UInt8(rotation / 90) | (mirrored ? 4 : 0) | (previewVisible ? 8 : 0)
        _ = pwrite(controlFD, &flags, 1, 4)
    }

    func rotateCamera(clockwise: Bool = true) {
        rotation = (rotation + (clockwise ? 90 : 270)) % 360
        UserDefaults.standard.set(rotation, forKey: "callCameraRotation")
        writeCameraControls(); onChange?()
    }

    func setMirrored(_ value: Bool) {
        mirrored = value; UserDefaults.standard.set(value, forKey: "callCameraMirror")
        writeCameraControls(); onChange?()
    }

    private func startCamera(serial: String) async throws {
        let launched = try await prepareOBS(); try checkWanted()
        let credential = password()
        for attempt in 0..<(launched ? 12 : 1) {
            do { try await obs.connect(port: port, password: credential); break }
            catch {
                try checkWanted()
                if !launched || attempt == 11 { throw error }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        try checkWanted()
        let streaming = try await obs.request("GetStreamStatus"); try checkWanted()
        let recording = try await obs.request("GetRecordStatus"); try checkWanted()
        let virtual = try await obs.request("GetVirtualCamStatus"); try checkWanted()
        guard streaming["outputActive"] as? Bool != true, recording["outputActive"] as? Bool != true,
              virtual["outputActive"] as? Bool != true else {
            throw CallError("OBS already has an active output. Stop it before letting JH Mirror start a phone camera session.")
        }
        previousScene = try await obs.request("GetCurrentProgramScene")["currentProgramSceneName"] as? String
        try checkWanted()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jhmirror-call-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = root
        let fifo = root.appendingPathComponent("camera.mkv")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw CallError("Could not create a private camera stream.") }
        let suffix = String(UUID().uuidString.prefix(8))
        let sceneName = "JH Mirror Call " + suffix
        let inputName = "JH Mirror Phone Camera " + suffix
        scene = sceneName
        _ = try await obs.request("CreateScene", ["sceneName": sceneName]); try checkWanted()
        source = inputName
        _ = try await obs.request("CreateInput", ["sceneName": sceneName, "inputName": inputName,
            "inputKind": "ffmpeg_source", "sceneItemEnabled": true,
            "inputSettings": ["is_local_file": false, "input": fifo.path, "input_format": "matroska",
                "buffering_mb": 0, "reconnect_delay_sec": 1, "clear_on_media_end": true, "close_when_inactive": true]])
        try checkWanted()
        // This source is video-only. Never send call audio to the Mac speakers through OBS.
        _ = try await obs.request("SetInputMute", ["inputName": inputName, "inputMuted": true]); try checkWanted()
        let item = try await obs.request("GetSceneItemId", ["sceneName": sceneName, "sourceName": inputName]); try checkWanted()
        let video = try await obs.request("GetVideoSettings"); try checkWanted()
        if let id = item["sceneItemId"] as? Int, let width = video["baseWidth"] as? Int, let height = video["baseHeight"] as? Int {
            _ = try await obs.request("SetSceneItemTransform", ["sceneName": sceneName, "sceneItemId": id,
                "sceneItemTransform": ["boundsType": "OBS_BOUNDS_SCALE_INNER", "boundsWidth": width, "boundsHeight": height,
                    "positionX": 0, "positionY": 0, "boundsAlignment": 0, "alignment": 5]])
            try checkWanted()
        }
        let output = Pipe()
        let process = helper(arguments: Self.cameraArguments(serial: serial, facing: facing, fifo: fifo.path), extras: ["AW_CALL_STREAM": "1"], output: output)
        cameraProcess = process; cameraOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.cameraProcess === process else { return }
                self.cameraLines = String((self.cameraLines + text).suffix(4096))
            }
        }
        process.terminationHandler = { [weak self] stopped in DispatchQueue.main.async {
            guard let self, self.cameraProcess === stopped, !self.shuttingDown else { return }
            self.message = Self.cameraFailure(self.cameraLines, status: stopped.terminationStatus, direct: false)
            self.stopCamera(announce: false)
        } }
        try process.run(); output.fileHandleForWriting.closeFile()
        _ = try await obs.request("SetCurrentProgramScene", ["sceneName": sceneName]); try checkWanted()
        ownsVirtualCamera = true
        _ = try await obs.request("StartVirtualCam"); try checkWanted()
        message = "Connecting phone camera to OBS Virtual Camera…"
    }

    static func cameraFailure(_ diagnostics: String, status: Int32, direct: Bool) -> String {
        let text = diagnostics.lowercased()
        if text.contains("no video, no audio") || text.contains("nothing to do") {
            return "Camera helper disabled video. Reinstall the latest JH Mirror update."
        }
        if text.contains("camera_in_use") || text.contains("camera in use") || text.contains("max_cameras_in_use") {
            return "The phone camera is in use. Close its Camera app or other video call, then retry."
        }
        if text.contains("unauthorized") || text.contains("device offline") || text.contains("device not found") {
            return "The paired phone is unavailable. Reconnect it in JH Mirror before starting the camera."
        }
        if text.contains("virtual camera") {
            return "The camera component could not accept video. Close OBS and check Camera & Microphone Setup."
        }
        return "Phone camera stopped (helper status \(status)). Check the phone connection and camera access."
            + (direct ? " Keep OBS closed in direct mode." : " Check OBS Virtual Camera in Call Setup.")
    }

    static func openOBS() async throws -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.obsproject.obs-studio")
        if let app = running.first {
            guard app.bundleURL?.standardizedFileURL.path == "/Applications/OBS.app" else {
                throw CallError("Quit the temporary copy of OBS, then open OBS from JH Mirror Setup. Its camera extension requires the Applications copy.")
            }
            return false
        }
        let url = URL(fileURLWithPath: "/Applications/OBS.app", isDirectory: true)
        let executable = url.appendingPathComponent("Contents/MacOS/OBS")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              Bundle(url: url)?.bundleIdentifier == "com.obsproject.obs-studio" else {
            throw CallError("Install OBS Studio from Call Setup first.")
        }
        // The signed Applications executable avoids Launch Services reopening a
        // downloaded/translocated copy, which macOS rejects as an extension owner.
        let process = Process(); process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let collection = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obs-studio/basic/scenes/JH_Mirror_Calls.json")
        if FileManager.default.fileExists(atPath: collection.path) { process.arguments = ["--collection", "JH Mirror Calls"] }
        try process.run()
        return true
    }

    func switchFacing(serial: String?) {
        setFacing(facing == "front" ? "back" : "front", serial: serial)
    }

    func setFacing(_ value: String, serial: String?) {
        guard !cameraBusy else { return }
        guard ["front", "back"].contains(value), value != facing else { return }
        facing = value
        UserDefaults.standard.set(facing, forKey: "callCameraFacing")
        if camera != .off, let serial { restartSerial = serial; stopCamera(announce: false) }
        onChange?()
    }

    func stopCamera(announce: Bool = true) {
        // Closing the panel or pressing Stop also cancels a pending lens restart.
        if announce { restartSerial = nil }
        cameraWanted = false; terminate(cameraProcess)
        if announce { message = "Phone camera stopped." }
        if cameraBusy { onChange?(); return }
        cameraBusy = true
        cameraTask = Task { @MainActor in
            await self.cleanupCamera()
            self.camera = .off; self.cameraBusy = false; self.onChange?()
            if let serial = self.restartSerial, !self.shuttingDown {
                self.restartSerial = nil; self.toggleCamera(serial: serial)
            }
        }
        onChange?()
    }

    private func cleanupCamera() async {
        let process = cameraProcess; cameraProcess = nil; terminate(process)
        cameraOutput?.fileHandleForReading.readabilityHandler = nil
        cameraOutput = nil
        // Let the old producer release its CMIO stream before switching lenses.
        // terminate() escalates this helper alone after two seconds if necessary.
        for _ in 0..<60 {
            guard process?.isRunning == true else { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Restore only state that we still own. A user's later scene selection wins.
        if let scene {
            if ownsVirtualCamera { _ = try? await obs.request("StopVirtualCam") }
            if let previousScene, let current = try? await obs.request("GetCurrentProgramScene"),
               current["currentProgramSceneName"] as? String == scene {
                _ = try? await obs.request("SetCurrentProgramScene", ["sceneName": previousScene])
            }
            if let source { _ = try? await obs.request("RemoveInput", ["inputName": source]) }
            _ = try? await obs.request("RemoveScene", ["sceneName": scene])
        }
        await obs.close()
        if controlFD >= 0 { close(controlFD); controlFD = -1 }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; scene = nil; source = nil; previousScene = nil; ownsVirtualCamera = false
        cameraLines = ""; directCameraSession = false; cameraLastFrame = .distantPast
    }

    func toggleMicrophone(serial: String?) {
        if microphone != .off { stopMicrophone(); return }
        guard let serial else { message = "Connect your paired phone before starting its microphone."; onChange?(); return }
        microphoneDeviceName = CallDevices.loopbackName
        guard CallDevices.loopback(name: microphoneDeviceName) != nil else { message = "Install \(microphoneDeviceName) from Call Setup first."; onChange?(); return }
        let output = Pipe()
        let process = helper(arguments: Self.microphoneArguments(serial: serial), extras: ["AW_AUDIO_OUTPUT_DEVICE": microphoneDeviceName], output: output)
        micProcess = process; micOutput = output; micLines = ""; microphone = .starting; micStarted = Date()
        message = "Starting phone microphone…"
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.micProcess === process else { return }
                self.micLines = String((self.micLines + text).suffix(8192))
                if self.microphone == .starting && self.micLines.contains("AW_MIC_READY") {
                    do {
                        try CallDevices.usePhoneMicrophone(name: self.microphoneDeviceName); self.microphone = .active
                        self.message = "Phone mic live · select \(self.microphoneDeviceName) in your call."
                    } catch { self.stopMicrophone(); self.message = error.localizedDescription }
                    self.onChange?()
                }
            }
        }
        process.terminationHandler = { [weak self] stopped in DispatchQueue.main.async {
            guard let self, self.micProcess === stopped else { return }
            self.stopMicrophone()
            self.message = "Phone microphone stopped · previous Mac input restored. Check Wi-Fi and phone mic access."
            self.onChange?()
        } }
        do { try process.run(); output.fileHandleForWriting.closeFile(); startHealthChecks() }
        catch { stopMicrophone(); message = "Could not start the phone microphone." }
        onChange?()
    }

    func stopMicrophone() {
        let process = micProcess; micProcess = nil; terminate(process)
        micOutput?.fileHandleForReading.readabilityHandler = nil; micOutput = nil; micLines = ""
        microphone = .off; CallDevices.restoreMicrophone()
        message = "Phone microphone stopped · previous Mac input restored."; onChange?()
    }

    private func startHealthChecks() {
        guard healthTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkHealth() }
        RunLoop.main.add(timer, forMode: .common); healthTimer = timer
    }

    private func checkHealth() {
        if microphone == .starting && Date().timeIntervalSince(micStarted) > 25 || microphone != .off && CallDevices.loopback(name: microphoneDeviceName) == nil {
            stopMicrophone(); message = "Phone microphone unavailable · previous Mac input restored."; onChange?()
        }
        if directCameraSession {
            if cameraWanted && camera == .starting && Date().timeIntervalSince(cameraStarted) > 25 {
                stopCamera(); message = "Direct camera did not start. Close OBS and check the phone connection and Call Setup."; onChange?()
            } else if cameraWanted && camera == .active && (Date().timeIntervalSince(cameraLastFrame) > 8 || !hasDirectCamera() || obsRunning()) {
                stopCamera(); message = "Direct camera disconnected or stalled. Check Wi-Fi and keep OBS closed, then start again."; onChange?()
            }
            return
        }
        guard cameraWanted, !cameraBusy, let source else { return }
        cameraBusy = true
        cameraTask = Task { @MainActor in
            do {
                let virtual = try await self.obs.request("GetVirtualCamStatus")
                let media = try await self.obs.request("GetMediaInputStatus", ["inputName": source])
                try self.checkWanted()
                guard virtual["outputActive"] as? Bool == true else { throw CallError("OBS Virtual Camera stopped.") }
                if media["mediaState"] as? String == "OBS_MEDIA_STATE_PLAYING" {
                    self.camera = .active; self.message = "Phone camera live · select OBS Virtual Camera in your call."
                } else if Date().timeIntervalSince(self.cameraStarted) > 30 { throw CallError("Phone camera did not start. Check Android 12+, Wi-Fi, and camera availability.") }
                self.cameraBusy = false
                if !self.cameraWanted { self.stopCamera(announce: false) }
                self.onChange?()
            } catch {
                let wasWanted = self.cameraWanted
                self.cameraWanted = false; await self.cleanupCamera(); self.camera = .off; self.cameraBusy = false
                if wasWanted { self.message = (error as? CallError)?.message ?? "OBS disconnected · phone camera stopped." }
                self.onChange?()
            }
        }
    }

    func stopAll() { restartSerial = nil; stopMicrophone(); stopCamera() }

    /// Called before app termination; waits asynchronously for OBS restoration before the app exits.
    func shutdown(completion: @escaping () -> Void) {
        shuttingDown = true; healthTimer?.invalidate(); healthTimer = nil; restartSerial = nil
        cameraWanted = false; stopMicrophone(); terminate(cameraProcess)
        Task { @MainActor in
            if let cameraTask = self.cameraTask { await cameraTask.value }
            await self.cleanupCamera(); completion()
        }
    }
}
