import Foundation
import CryptoKit
import UniformTypeIdentifiers
import ImageIO

/// One line from the phone's clipboard watcher (see ClipboardWatcher.java in the scrcpy server).
enum PhoneClipEvent: Equatable {
    case ready
    case text(String)
    case uri(mime: String, uri: String)
    case skipped(String)
    case error(String)

    static func parse(_ line: String) -> PhoneClipEvent? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        func decode(_ value: String) -> String? {
            value.isEmpty ? "" : Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) }
        }
        switch parts.first {
        case "AW_CLIP_READY": return .ready
        case "AW_CLIP_TEXT":
            guard parts.count == 2, let text = decode(parts[1]), !text.isEmpty else { return nil }
            return .text(text)
        case "AW_CLIP_URI":
            guard parts.count == 3, let mime = decode(parts[1]), let uri = decode(parts[2]),
                  uri.hasPrefix("content://"), !uri.contains("\n") else { return nil }
            return .uri(mime: mime, uri: uri)
        case "AW_CLIP_SKIPPED": return .skipped(parts.count > 1 ? parts[1] : "")
        case "AW_CLIP_ERROR": return .error(parts.count > 1 ? decode(parts[1]) ?? "" : "")
        default: return nil
        }
    }
}

/// Picks a file extension for copied content from its MIME type, falling back to the file signature.
func clipboardFileExtension(mime: String, data: Data) -> String {
    if !mime.isEmpty, !mime.hasSuffix("/*"), let ext = UTType(mimeType: mime)?.preferredFilenameExtension { return ext }
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if bytes.starts(with: Array("GIF8".utf8)) { return "gif" }
    if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "webp" }
    if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) { return "heic" }
    if bytes.starts(with: Array("%PDF".utf8)) { return "pdf" }
    return "bin"
}

/// True when `data` is plausibly the copied item rather than a tool error message.
/// Images must decode; anything else just must not be the `content` tool's error output.
func isCopiedContent(_ data: Data, mime: String) -> Bool {
    guard !data.isEmpty else { return false }
    let head = String(decoding: data.prefix(64), as: UTF8.self)
    if head.hasPrefix("Error while accessing provider") || head.hasPrefix("java.") || head.hasPrefix("cat: ") { return false }
    if mime.hasPrefix("image/") {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
    return true
}

/// JH Mirror runs its own adb server on a private port, so other Android tools (Android Studio,
/// a terminal `adb kill-server`) cannot disturb its connection, and it cannot disturb theirs.
let adbServerPort = "5139"
func adbEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["ADB_MDNS_AUTO_CONNECT"] = "0"
    environment["ANDROID_ADB_SERVER_PORT"] = adbServerPort
    return environment
}

/// Quotes one argument for the phone's /system/bin/sh.
func phoneShellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Runs adb and returns raw stdout bytes (for `exec-out content read`), bounded in size and time.
func commandData(_ arguments: [String], timeout: Double, limit: Int) -> Data? {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: adbPath)
    process.arguments = arguments
    process.environment = adbEnvironment()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    output.fileHandleForWriting.closeFile()
    let deadline = Date().addingTimeInterval(timeout)
    var data = Data(), tooLarge = false
    let reader = output.fileHandleForReading
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > limit { tooLarge = true; process.terminate(); break }
        }
        done.signal()
    }
    if done.wait(timeout: .now() + max(1, deadline.timeIntervalSinceNow)) == .timedOut {
        process.terminate(); _ = done.wait(timeout: .now() + 2); return nil
    }
    process.waitUntilExit()
    return process.terminationStatus == 0 && !tooLarge ? data : nil
}

/// Keeps the phone's clipboard watcher running over ADB while auto-copy is on.
/// Text goes straight to the Mac clipboard; images and files are fetched, saved and then placed on it.
final class PhoneClipboardSync {
    static let remoteJar = "/data/local/tmp/jh-mirror-clip.jar"
    static let maxBytes = 64 * 1024 * 1024
    var onStatus: ((String) -> Void)?
    var onText: ((String) -> Void)?
    var onFile: ((URL) -> Void)?
    private let queue = DispatchQueue(label: "com.johirulhoqakash.jhmirror.autoclipboard", qos: .userInitiated)
    private let lock = NSLock()
    private var enabledValue = false
    private var serialHint: String?
    private var process: Process?
    private var input: Pipe?
    private var launching = false
    private var activeValue = false
    /// True while the phone watcher is connected and reporting.
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return activeValue }
    private func setActive(_ value: Bool) { lock.lock(); activeValue = value; lock.unlock() }
    private var startedAt = Date.distantPast
    private var retry = RetryGate()
    private var timer: Timer?
    private var recentURIs: [String: Date] = [:]
    private var jarHash: String?
    private let folder: URL
    /// The scrcpy server jar that contains the watcher (bundled with the app).
    var helperJar = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil)

    init(folder: URL = FileTransferClient.receivedFolder) { self.folder = folder }

    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabledValue }
        set {
            lock.lock(); enabledValue = newValue; lock.unlock()
            if newValue { queue.async { self.retry.succeeded() }; supervise() } else { stopWatcher() }
        }
    }

    /// The most recent verified ADB endpoint, so no extra discovery is needed.
    func useSerial(_ serial: String) {
        lock.lock(); let changed = serialHint != serial; serialHint = serial; lock.unlock()
        if changed { queue.async { self.retry.succeeded() } }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.supervise() }
        supervise()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        lock.lock(); enabledValue = false; lock.unlock()
        stopWatcher()
    }

    private func status(_ text: String) { DispatchQueue.main.async { self.onStatus?(text) } }

    private func supervise() {
        queue.async {
            guard self.enabled, !self.launching, self.process?.isRunning != true, self.retry.ready() else { return }
            self.launching = true
            defer { self.launching = false }
            self.launch()
        }
    }

    private func stopWatcher() {
        queue.async {
            try? self.input?.fileHandleForWriting.close() // The watcher exits when stdin closes.
            if let process = self.process, process.isRunning { process.terminate() }
            self.process = nil; self.input = nil; self.setActive(false)
        }
    }

    private func localJar() -> (URL, String)? {
        guard let jar = helperJar else { return nil }
        if jarHash == nil, let data = try? Data(contentsOf: jar) {
            jarHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return jarHash.map { (jar, $0) }
    }

    private func launch() {
        lock.lock(); let hint = serialHint; lock.unlock()
        guard let serial = hint ?? findPhone() else {
            retry.failed(); status("Auto-copy waiting for Wireless debugging on the phone"); return
        }
        useSerial(serial)
        guard let (jar, hash) = localJar() else { status("Auto-copy unavailable: helper missing from the app."); return }
        let remote = command(["-s", serial, "shell", "sha256sum", Self.remoteJar], timeout: 5)
        if !remote.output.hasPrefix(hash) {
            let push = command(["-s", serial, "push", jar.path, Self.remoteJar], timeout: 30)
            guard push.code == 0 else {
                // The endpoint is gone (for example Wireless debugging restarted on a new port): rediscover.
                lock.lock(); if serialHint == serial { serialHint = nil }; lock.unlock()
                retry.failed(); connectionLog("Auto-copy waiting for the phone's new address"); return
            }
        }
        // Only one watcher: the bracket keeps pkill from matching its own shell command line.
        _ = command(["-s", serial, "shell", "pkill", "-f", "'[c]om.genymobile.scrcpy.ClipboardWatcher'"], timeout: 5)
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "shell", "-T",
                             "CLASSPATH=\(Self.remoteJar) app_process / com.genymobile.scrcpy.ClipboardWatcher"]
        process.environment = adbEnvironment()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            guard let self else { return }
            self.queue.async {
                guard self.process === ended else { return }
                self.process = nil; self.input = nil; self.setActive(false)
                guard self.enabled else { return }
                // A watcher that ran for a while had a working connection: retry promptly.
                if Date().timeIntervalSince(self.startedAt) > 60 { self.retry.succeeded() }
                self.retry.failed()
                connectionLog("Auto-copy watcher ended status=\(ended.terminationStatus)")
                self.status("Auto-copy reconnecting…")
            }
        }
        do { try process.run() } catch { retry.failed(); return }
        try? output.fileHandleForWriting.close()
        self.process = process; self.input = input; startedAt = Date()
        Thread.detachNewThread { [weak self] in
            let handle = output.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let event = PhoneClipEvent.parse(line) { self?.queue.async { self?.handle(event, serial: serial) } }
                }
                if buffer.count > 4_000_000 { buffer.removeAll() } // Malformed: never grow without bound.
            }
        }
    }

    private func handle(_ event: PhoneClipEvent, serial: String) {
        switch event {
        case .ready:
            setActive(true); noteADBVerified()
            connectionLog("Auto-copy watcher ready")
            status("Auto-copy on · copy on the phone, then ⌘V on the Mac")
        case .text(let text):
            DispatchQueue.main.async { self.onText?(text) }
        case .uri(let mime, let uri):
            let now = Date()
            recentURIs = recentURIs.filter { now.timeIntervalSince($0.value) < 10 }
            guard recentURIs[uri] == nil else { return } // Some apps announce one copy twice.
            recentURIs[uri] = now
            fetch(uri: uri, mime: mime, serial: serial)
        case .skipped(let reason):
            if reason == "sensitive" { status("Skipped a copy marked sensitive (such as a password)") }
        case .error(let message):
            connectionLog("Auto-copy watcher error: \(message.prefix(200))")
        }
    }

    private func fetch(uri: String, mime: String, serial: String) {
        status("Copying from phone…")
        guard let data = readCopiedContent(uri: uri, mime: mime, serial: serial) else {
            connectionLog("Auto-copy could not read a copied item (\(mime.isEmpty ? "unknown type" : mime))")
            status("Could not read that copy from the phone. Use Share → Copy to Mac instead.")
            return
        }
        let query = command(["-s", serial, "shell", "content", "query", "--uri", phoneShellQuote(uri),
                             "--projection", "_display_name"], timeout: 5).output
        var name = query.components(separatedBy: "_display_name=").dropFirst().first?
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let ext = clipboardFileExtension(mime: mime, data: data)
        if name.isEmpty || name == "NULL" {
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                .replacingOccurrences(of: ":", with: ".")
            name = "Phone copy \(stamp).\(ext)"
        } else if (name as NSString).pathExtension.isEmpty { name += "." + ext }
        do {
            let url = try save(data, as: FileTransferClient.safeName(name))
            DispatchQueue.main.async { self.onFile?(url) }
        } catch {
            status("Could not save the copied item: \(error.localizedDescription)")
        }
    }

    /// Reads a copied content URI. `adb exec-out` takes the remote command as one string: separate
    /// arguments would reach the phone with their quotes intact. Error text is never mistaken for content.
    private func readCopiedContent(uri: String, mime: String, serial: String) -> Data? {
        let direct = commandData(["-s", serial, "exec-out", "content read --uri " + phoneShellQuote(uri)],
                                 timeout: 90, limit: Self.maxBytes)
        if let direct, isCopiedContent(direct, mime: mime) { return direct }
        // MediaStore items can also be read from their file, which the shell user may access.
        let query = command(["-s", serial, "shell", "content", "query", "--uri", phoneShellQuote(uri),
                             "--projection", "_data"], timeout: 5).output
        guard let path = query.components(separatedBy: "_data=").dropFirst().first?
                .split(whereSeparator: \.isNewline).first.map(String.init),
              path.hasPrefix("/storage/") || path.hasPrefix("/sdcard/"), !path.contains("/../") else { return nil }
        let file = commandData(["-s", serial, "exec-out", "cat " + phoneShellQuote(path)], timeout: 90, limit: Self.maxBytes)
        if let file, isCopiedContent(file, mime: mime) { return file }
        return nil
    }

    /// Writes atomically under a unique name and marks the file as downloaded.
    private func save(_ data: Data, as name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let temporary = folder.appendingPathComponent(".incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = temporary.appendingPathComponent(UUID().uuidString + ".clip")
        try data.write(to: staged, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staged) }
        for number in 1...10000 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext))
            do {
                try FileManager.default.linkItem(at: staged, to: candidate)
                let quarantine = "0083;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";JH Mirror;"
                quarantine.withCString { value in
                    candidate.path.withCString { path in _ = setxattr(path, "com.apple.quarantine", value, strlen(value), 0, 0) }
                }
                return candidate
            } catch { if !FileManager.default.fileExists(atPath: candidate.path) { throw error } }
        }
        throw NSError(domain: "JHMirrorClipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "No free file name"])
    }
}
