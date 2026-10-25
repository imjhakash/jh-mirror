import Foundation
import CryptoKit
import Darwin

struct PhoneFile: Codable, Equatable {
    let path: String
    let name: String
    let directory: Bool
    let size: Int64
    let modified: Int64
    let kind: String
    var indexed: Bool? = nil
    /// MediaStore timestamps have second precision. Resolve indexed rows to exact filesystem metadata before an action.
    func matches(_ current: PhoneFile) -> Bool {
        current.indexed != true && path == current.path && name == current.name && directory == current.directory && size == current.size && kind == current.kind &&
            (indexed == true ? modified / 1000 == current.modified / 1000 : modified == current.modified)
    }
    var displayName: String { name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined() }
    static func transferName(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\0", with: "_")
        if value.isEmpty || value == "." || value == ".." { value = "File" }
        if value.utf8.count > 240 {
            let ext = (value as NSString).pathExtension
            let suffix = ext.utf8.count <= 24 && !ext.isEmpty ? "." + ext : ""
            var stem = (value as NSString).deletingPathExtension
            while stem.utf8.count + suffix.utf8.count > 240 { stem.removeLast() }
            value = stem + suffix
        }
        return value
    }
    static func validPath(_ value: String) -> Bool {
        !value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 8192 &&
            !value.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." } &&
            value != "Android/data" && !value.hasPrefix("Android/data/") && value != "Android/obb" && !value.hasPrefix("Android/obb/")
    }
    var valid: Bool { Self.validPath(path) && !name.isEmpty && name.utf8.count <= 1024 && !name.contains("/") && size >= 0 && (-62_135_596_800_000...253_402_300_799_999).contains(modified) && directory == (kind == "folder") && ["folder","photo","video","audio","file"].contains(kind) }
}
struct PhoneFileList: Decodable {
    let path: String
    let items: [PhoneFile]
    let truncated: Bool
    var valid: Bool { PhoneFile.validPath(path) && items.count <= 20000 && items.allSatisfy(\.valid) && Set(items.map(\.path)).count == items.count }
}
struct PhoneFilePeer: Codable, Equatable {
    let identity: String
    let user: Int
}
struct PhoneFileConnection: Equatable {
    let serial: String
    let peer: PhoneFilePeer
}
struct PhonePreviewData { let file: PhoneFile; let data: Data }
struct PhoneFileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
final class PhoneFileCancellation {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; let process = process; lock.unlock(); if process?.isRunning == true { process?.terminate() } }
    func attach(_ process: Process?) { lock.lock(); self.process = process; let stopped = stopped; lock.unlock(); if stopped && process?.isRunning == true { process?.terminate() } }
    func check() throws { if cancelled { throw PhoneFileError("Transfer paused. Resume to continue from the saved position.") } }
}
private final class FileProcessState {
    private let lock = NSLock()
    private var last = Date()
    private var failure: Error?
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    var idle: Double { lock.lock(); defer { lock.unlock() }; return -last.timeIntervalSinceNow }
    func fail(_ value: Error) { lock.lock(); if failure == nil { failure = value }; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
}

/// Bounded binary streaming over shell v2 (-T), which separates stdout/stderr and preserves exit status.
final class PhoneFileProcess {
    let adb: String
    let environment: [String: String]
    private static let noSigpipe: Void = { _ = signal(SIGPIPE, SIG_IGN) }()
    init(adb: String, environment: [String: String]) { self.adb = adb; self.environment = environment; _ = Self.noSigpipe }
    func run(_ args: [String], timeout: Double = 45, input: URL? = nil, output: URL? = nil,
             offset: Int64 = 0, size: Int64? = nil, cancel: PhoneFileCancellation = PhoneFileCancellation(),
             progress: @escaping (Int64) -> Void = { _ in }, limit: Int = 16 * 1024 * 1024,
             onLine: ((Data) -> Void)? = nil) throws -> Data {
        try cancel.check()
        guard offset >= 0, size.map({ $0 >= offset }) ?? true, limit >= 0 else { throw PhoneFileError("Invalid transfer byte range.") }
        let process = Process(), stdout = Pipe(), stderr = Pipe(), stdin = Pipe(), state = FileProcessState()
        process.executableURL = URL(fileURLWithPath: adb); process.arguments = args; process.environment = environment
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = stdout; process.standardError = stderr
        let errResult = FileProcessBuffer(), group = DispatchGroup()
        try process.run(); cancel.attach(process)
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close(); try? stdin.fileHandleForReading.close()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            if cancel.cancelled || state.idle > timeout {
                if !cancel.cancelled { state.fail(PhoneFileError("Connection stopped responding. Resume when the phone reconnects.")) }
                if process.isRunning { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
        }
        timer.resume()
        defer { timer.cancel(); cancel.attach(nil); try? stdin.fileHandleForWriting.close(); if process.isRunning { process.terminate() } }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave(); try? stderr.fileHandleForReading.close() }
            while let data = try? stderr.fileHandleForReading.read(upToCount: 32768), !data.isEmpty { errResult.append(data, limit: 32768) }
        }
        if let input {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? stdin.fileHandleForWriting.close(); group.leave() }
                do {
                    let file = try FileHandle(forReadingFrom: input); defer { try? file.close() }; try file.seek(toOffset: UInt64(offset))
                    var position = offset
                    while position < (size ?? Int64.max) {
                        try cancel.check()
                        let remaining = size.map { Int(min(262144, $0 - position)) } ?? 262144
                        guard let data = try file.read(upToCount: remaining), !data.isEmpty else { break }
                        try stdin.fileHandleForWriting.write(contentsOf: data); position += Int64(data.count); state.touch(); progress(position)
                    }
                    if let size, position != size { throw PhoneFileError("Source file changed during transfer.") }
                } catch { state.fail(error); if process.isRunning { process.terminate() } }
            }
        }
        let destination: FileHandle?
        if let output { destination = try FileHandle(forWritingTo: output); try destination?.seek(toOffset: UInt64(offset)) }
        else { destination = nil }
        defer { try? destination?.close(); try? stdout.fileHandleForReading.close() }
        var captured = Data(), lineBuffer = Data(), position = offset
        do {
            while true {
                // read(upToCount:) can coalesce pipe writes until EOF on macOS.
                // Use currently available bytes for progressive thumbnail lines.
                let data = onLine == nil ? (try stdout.fileHandleForReading.read(upToCount: 262144) ?? Data()) : stdout.fileHandleForReading.availableData
                if data.isEmpty { break }
                try cancel.check(); state.touch()
                if let destination {
                    guard let size, Int64(data.count) <= size - position else { throw PhoneFileError("Phone sent invalid file data.") }
                    try destination.write(contentsOf: data); position += Int64(data.count); progress(position)
                } else {
                    guard captured.count + data.count <= limit else { throw PhoneFileError("Phone response was too large.") }
                    captured.append(data)
                    if let onLine {
                        lineBuffer.append(data)
                        while let newline = lineBuffer.firstIndex(of: 10) {
                            onLine(Data(lineBuffer[..<newline])); lineBuffer.removeSubrange(...newline)
                        }
                    }
                }
            }
            try destination?.synchronize()
        } catch { state.fail(error); if process.isRunning { process.terminate() } }
        process.waitUntilExit(); _ = group.wait(timeout: .now() + 5)
        try cancel.check()
        if process.terminationStatus != 0 {
            let line = errResult.data.split(separator: 10).last(where: { $0.first == 123 }).map { Data($0) }
            if let line, let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let detail = object["error"] as? String { throw PhoneFileError(detail) }
        }
        if let error = state.error { throw error }
        guard process.terminationStatus == 0 else { throw PhoneFileError("Phone connection interrupted or Android denied access.") }
        if output != nil, position != size { throw PhoneFileError("Transfer interrupted. The partial copy is saved for Resume.") }
        return captured
    }
}
private final class FileProcessBuffer {
    private let lock = NSLock(); private var value = Data()
    func append(_ data: Data, limit: Int) { lock.lock(); defer { lock.unlock() }; value.append(data.prefix(max(0, limit - value.count))) }
    var data: Data { lock.lock(); defer { lock.unlock() }; return value }
}

protocol PhoneFilesAccess: AnyObject {
    func connect(serial: String, identity: String) throws -> PhoneFileConnection
    func connect(serial: String, identity: String, cancel: PhoneFileCancellation) throws -> PhoneFileConnection
    func validate(_ connection: PhoneFileConnection) throws
    func list(_ connection: PhoneFileConnection, path: String, mode: String, cancel: PhoneFileCancellation) throws -> PhoneFileList
    func initialMedia(_ connection: PhoneFileConnection, mode: String, cancel: PhoneFileCancellation) throws -> PhoneFileList?
    func info(_ connection: PhoneFileConnection, path: String) throws -> PhoneFile
    func hash(_ connection: PhoneFileConnection, file: PhoneFile, cancel: PhoneFileCancellation) throws -> String
    func thumbnail(_ connection: PhoneFileConnection, file: PhoneFile, cancel: PhoneFileCancellation) throws -> Data?
    func thumbnails(_ connection: PhoneFileConnection, files: [PhoneFile], cancel: PhoneFileCancellation, receive: @escaping (PhoneFile, Data) -> Void) throws
    func preview(_ connection: PhoneFileConnection, file: PhoneFile, cancel: PhoneFileCancellation) throws -> PhonePreviewData
    func removePhoto(_ connection: PhoneFileConnection, file: PhoneFile) throws
    func makeDirectory(_ connection: PhoneFileConnection, path: String, name: String?) throws -> PhoneFile
    func beginUpload(_ connection: PhoneFileConnection, folder: String, id: String, name: String, size: Int64, hash: String, cancel: PhoneFileCancellation) throws -> (Int64, PhoneFile?)
    func write(_ connection: PhoneFileConnection, folder: String, id: String, source: URL, offset: Int64, size: Int64, cancel: PhoneFileCancellation, progress: @escaping (Int64) -> Void) throws
    func commit(_ connection: PhoneFileConnection, folder: String, id: String, size: Int64, cancel: PhoneFileCancellation) throws -> PhoneFile
    func finish(_ connection: PhoneFileConnection, folder: String, id: String)
    func read(_ connection: PhoneFileConnection, file: PhoneFile, output: URL, offset: Int64, cancel: PhoneFileCancellation, progress: @escaping (Int64) -> Void) throws
}
extension PhoneFilesAccess {
    func connect(serial: String, identity: String, cancel: PhoneFileCancellation) throws -> PhoneFileConnection {
        try cancel.check(); let value = try connect(serial: serial, identity: identity); try cancel.check(); return value
    }
    func initialMedia(_ connection: PhoneFileConnection, mode: String, cancel: PhoneFileCancellation) throws -> PhoneFileList? { nil }
    func thumbnails(_ connection: PhoneFileConnection, files: [PhoneFile], cancel: PhoneFileCancellation, receive: @escaping (PhoneFile, Data) -> Void) throws {
        for file in files { try cancel.check(); if let data = try thumbnail(connection, file: file, cancel: cancel) { receive(file, data) } }
    }
    func list(_ connection: PhoneFileConnection, path: String, mode: String) throws -> PhoneFileList {
        try list(connection, path:path, mode:mode, cancel:PhoneFileCancellation())
    }
    func thumbnail(_ connection: PhoneFileConnection, file: PhoneFile) throws -> Data? {
        try thumbnail(connection,file:file,cancel:PhoneFileCancellation())
    }
}
final class PhoneFilesClient: PhoneFilesAccess {
    private let runner: PhoneFileProcess
    private let jar: URL
    private let deployment = NSLock()
    private var prepared = Set<String>()
    private lazy var remote: String = "/data/local/tmp/jh-files-" + ((try? FileTransferClient.hash(jar)) ?? "missing").prefix(16) + ".jar"
    init(adb: String = adbPath, environment: [String: String] = adbEnvironment(),
         jar: URL = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) ?? URL(fileURLWithPath: "/missing")) {
        runner = PhoneFileProcess(adb: adb, environment: environment); self.jar = jar
    }
    static func encoded(_ value: String) -> String { value.isEmpty ? "-" : Data(value.utf8).base64EncodedString() }
    private func prepare(_ serial: String, cancel: PhoneFileCancellation) throws {
        while !deployment.try() { try cancel.check(); Thread.sleep(forTimeInterval: 0.01) }
        defer { deployment.unlock() }; try cancel.check()
        if prepared.contains(serial) { return }
        guard FileManager.default.fileExists(atPath: jar.path) else { throw PhoneFileError("The bundled file browser is missing. Reinstall JH Mirror.") }
        _ = try runner.run(["-s", serial, "push", jar.path, remote], timeout: 20, cancel: cancel)
        _ = try runner.run(["-s", serial, "shell", "-T", "-n", "chmod 600 " + remote], timeout: 10, cancel: cancel)
        prepared.insert(serial)
    }
    private func args(_ connection: PhoneFileConnection, _ operation: String, _ path: String, _ extra: [String] = [], writing: Bool = false, cancel: PhoneFileCancellation = PhoneFileCancellation()) throws -> [String] {
        guard PhoneFile.validPath(path), (0...10000).contains(connection.peer.user), extra.allSatisfy({ !$0.isEmpty && $0.count <= 16384 && $0.range(of: "^[A-Za-z0-9+/=_-]+$", options: .regularExpression) != nil }) else { throw PhoneFileError("Invalid shared-storage path.") }
        try prepare(connection.serial, cancel: cancel)
        return ["-s", connection.serial, "shell", "-T"] + (writing ? [] : ["-n"]) +
            ["CLASSPATH=" + remote + " app_process / com.genymobile.scrcpy.JHFiles " + operation + " " + String(connection.peer.user) + " " + Self.encoded(path) + (extra.isEmpty ? "" : " " + extra.joined(separator: " "))]
    }
    func connect(serial: String, identity: String) throws -> PhoneFileConnection {
        try connect(serial: serial, identity: identity, cancel: PhoneFileCancellation())
    }
    func connect(serial: String, identity: String, cancel: PhoneFileCancellation) throws -> PhoneFileConnection {
        let value = try runner.run(["-s", serial, "shell", "-T", "-n", "getprop ro.serialno"], timeout: 8, cancel: cancel)
        guard String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == identity, !identity.isEmpty else { throw PhoneFileError("The connected phone does not match your paired phone.") }
        let bytes = try runner.run(["-s", serial, "shell", "-T", "-n", "am get-current-user"], timeout: 8, cancel: cancel)
        guard let user = Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), (0...10000).contains(user) else { throw PhoneFileError("Could not identify the active phone user.") }
        return PhoneFileConnection(serial: serial, peer: PhoneFilePeer(identity: identity, user: user))
    }
    func validate(_ connection: PhoneFileConnection) throws {
        guard try connect(serial: connection.serial, identity: connection.peer.identity).peer == connection.peer else { throw PhoneFileError("Phone user changed. Refresh before continuing transfers.") }
    }
    private func object(_ connection: PhoneFileConnection, _ operation: String, _ path: String, _ extra: [String] = [], timeout: Double = 45, cancel: PhoneFileCancellation = PhoneFileCancellation()) throws -> Data {
        try runner.run(args(connection, operation, path, extra, cancel: cancel), timeout: timeout, cancel: cancel)
    }
    func list(_ connection: PhoneFileConnection, path: String, mode: String = "list", cancel: PhoneFileCancellation = PhoneFileCancellation()) throws -> PhoneFileList {
        guard ["list", "tree", "photo", "video", "audio"].contains(mode) else { throw PhoneFileError("Unknown library view.") }
        let value = try JSONDecoder().decode(PhoneFileList.self, from: object(connection, mode, path, timeout: 90, cancel:cancel))
        try cancel.check()
        guard value.valid else { throw PhoneFileError("Phone returned an invalid file list.") }; return value
    }
    func initialMedia(_ connection: PhoneFileConnection, mode: String, cancel: PhoneFileCancellation) throws -> PhoneFileList? {
        guard ["photo", "video", "audio"].contains(mode) else { return nil }
        let value = try JSONDecoder().decode(PhoneFileList.self, from: object(connection, mode + "-first", "", timeout: 15, cancel: cancel))
        guard value.valid, !value.items.isEmpty else { return nil }; return value
    }
    func info(_ connection: PhoneFileConnection, path: String) throws -> PhoneFile {
        let value = try JSONDecoder().decode(PhoneFile.self, from: object(connection, "info", path))
        guard value.valid && value.path == path else { throw PhoneFileError("Invalid file metadata.") }; return value
    }
    func hash(_ connection: PhoneFileConnection, file: PhoneFile, cancel: PhoneFileCancellation) throws -> String {
        let result = try JSONSerialization.jsonObject(with: object(connection, "hash", file.path, [String(file.size),String(file.modified)], timeout: max(45, Double(file.size)/20_000_000+30), cancel: cancel)) as? [String: String]
        guard let hash = result?["sha256"], hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw PhoneFileError("Invalid file checksum.") }; return hash
    }
    func thumbnail(_ connection: PhoneFileConnection, file: PhoneFile, cancel: PhoneFileCancellation = PhoneFileCancellation()) throws -> Data? {
        let object = try JSONSerialization.jsonObject(with: self.object(connection, "thumb", file.path, timeout: 15, cancel:cancel)) as? [String: String]
        guard let encoded = object?["image"], encoded.count <= 350000 else { return nil }; return Data(base64Encoded: encoded)
    }
    func thumbnails(_ connection: PhoneFileConnection, files: [PhoneFile], cancel: PhoneFileCancellation, receive: @escaping (PhoneFile, Data) -> Void) throws {
        guard !files.isEmpty, files.count <= 6, files.allSatisfy({ $0.valid && !$0.directory && ["photo", "video"].contains($0.kind) }) else { return }
        let encoded = Self.encoded(String(decoding: try JSONEncoder().encode(files), as: UTF8.self))
        // Very long legal filenames use the same bounded protocol one at a time.
        if encoded.utf8.count > 16000 {
            for file in files { try cancel.check(); if let data = try thumbnail(connection, file: file, cancel: cancel) { receive(file, data) } }; return
        }
        _ = try runner.run(args(connection, "thumb-batch", "", [Self.encoded(connection.peer.identity), encoded], cancel: cancel),
            timeout: 20, cancel: cancel, limit: 3 * 1024 * 1024, onLine: { line in
                guard !cancel.cancelled, let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let index = object["index"] as? Int, files.indices.contains(index), let image = object["image"] as? String,
                      image.count <= 350000, let data = Data(base64Encoded: image) else { return }
                receive(files[index], data)
            })
    }
    private struct PreviewReply: Decodable { let file: PhoneFile; let image: String }
    func preview(_ connection: PhoneFileConnection, file: PhoneFile, cancel: PhoneFileCancellation) throws -> PhonePreviewData {
        guard file.valid, !file.directory, ["photo","video"].contains(file.kind) else { throw PhoneFileError("Select a photo or video to preview.") }
        let reply = try JSONDecoder().decode(PreviewReply.self, from:object(connection,"preview",file.path,
            [String(file.size),String(file.modified),file.indexed == true ? "1" : "0",Self.encoded(connection.peer.identity)],timeout:15,cancel:cancel))
        guard reply.file.valid, file.matches(reply.file), reply.image.count <= 4_200_000,
              let data = Data(base64Encoded:reply.image), !data.isEmpty else { throw PhoneFileError("Photo changed or its preview is unavailable. Refresh and try again.") }
        return PhonePreviewData(file:reply.file,data:data)
    }
    func removePhoto(_ connection: PhoneFileConnection, file: PhoneFile) throws {
        guard file.valid, !file.directory, file.kind == "photo", !file.path.isEmpty else { throw PhoneFileError("Only selected photos can be deleted here.") }
        try validate(connection)
        let reply = try JSONSerialization.jsonObject(with: object(connection, "delete-photo", file.path, [String(file.size),String(file.modified)])) as? [String: Any]
        guard reply?["deleted"] as? String == file.path else { throw PhoneFileError("Phone did not confirm deletion. Refresh the gallery.") }
    }
    func makeDirectory(_ connection: PhoneFileConnection, path: String, name: String?) throws -> PhoneFile {
        let value = try JSONDecoder().decode(PhoneFile.self, from: object(connection, name == nil ? "mkdir" : "newdir", path, name.map { [Self.encoded($0)] } ?? []))
        guard value.valid && value.directory else { throw PhoneFileError("Could not create folder.") }; return value
    }
    private struct UploadState: Decodable { let offset: Int64; let completed: PhoneFile? }
    func beginUpload(_ connection: PhoneFileConnection, folder: String, id: String, name: String, size: Int64, hash: String, cancel: PhoneFileCancellation) throws -> (Int64, PhoneFile?) {
        let value = try JSONDecoder().decode(UploadState.self, from: object(connection, "begin", folder, [id, Self.encoded(name), String(size), hash], cancel: cancel))
        guard (0...size).contains(value.offset), value.completed?.valid ?? true else { throw PhoneFileError("Invalid resume state.") }; return (value.offset, value.completed)
    }
    func write(_ connection: PhoneFileConnection, folder: String, id: String, source: URL, offset: Int64, size: Int64, cancel: PhoneFileCancellation, progress: @escaping (Int64) -> Void) throws {
        let result = try runner.run(args(connection, "write", folder, [id,String(offset)], writing: true, cancel: cancel), input: source, offset: offset, size: size, cancel: cancel, progress: progress)
        let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        guard (object?["offset"] as? NSNumber)?.int64Value == size else { throw PhoneFileError("Phone did not confirm all file data.") }
    }
    func commit(_ connection: PhoneFileConnection, folder: String, id: String, size: Int64, cancel: PhoneFileCancellation) throws -> PhoneFile {
        let value = try JSONDecoder().decode(PhoneFile.self, from: object(connection, "commit", folder, [id], timeout: max(45, Double(size)/20_000_000+30), cancel: cancel))
        guard value.valid && value.size == size else { throw PhoneFileError("Phone could not verify the saved file.") }; return value
    }
    func finish(_ connection: PhoneFileConnection, folder: String, id: String) {
        _ = try? object(connection, "finish", folder, [id])
    }
    func scan(_ connection: PhoneFileConnection, file: PhoneFile) {
        let path = "/storage/emulated/" + String(connection.peer.user) + "/" + file.path
        let quote = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        _ = try? runner.run(["-s", connection.serial, "shell", "-T", "-n", "am broadcast --user " + String(connection.peer.user) + " -n com.johirulhoqakash.jhmirror/.SetupReceiver -a com.johirulhoqakash.jhmirror.SCAN_FILE --es path " + quote], timeout: 8)
    }
    func read(_ connection: PhoneFileConnection, file: PhoneFile, output: URL, offset: Int64, cancel: PhoneFileCancellation, progress: @escaping (Int64) -> Void) throws {
        _ = try runner.run(args(connection, "read", file.path, [String(offset),String(file.size),String(file.modified)], cancel: cancel), output: output, offset: offset, size: file.size, cancel: cancel, progress: progress)
    }
}
