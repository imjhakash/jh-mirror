import Foundation
import CryptoKit

struct SharedFile: Decodable {
    let id: String
    let name: String
    let size: Int64
    let sha256: String
    /// "clipboard" when the phone asked for this item to be pasted on the Mac.
    let purpose: String?
    var isClipboard: Bool { purpose == "clipboard" }
}
private struct FileManifest: Decodable { let files: [SharedFile] }
private struct FileReceipt: Codable { let path: String; let sha256: String; let size: Int64 }
private struct FileConnection { let baseURL: String; let token: String; let pin: String? }
private final class FileHTTPResult {
    let lock = NSLock()
    var data: Data?
    func store(_ value: Data?) { lock.lock(); defer { lock.unlock() }; data = value }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}

final class FileTransferClient {
    static let receivedFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Android Wireless", isDirectory: true)
    var onStatus: ((String) -> Void)?
    var onReceived: ((URL) -> Void)?
    /// Called on the main queue after a clipboard item is saved and verified.
    var onClipboard: ((URL) -> Void)?
    private let queue = DispatchQueue(label: "local.androidwireless.files", qos: .utility)
    private let lock = NSLock()
    private var connection: FileConnection?
    private var busy = false
    private var stopped = false
    private var hasReceived = false
    private let folder: URL
    private let session: URLSession
    private let delegate = PairedHTTP()

    init(folder: URL = FileTransferClient.receivedFolder) {
        self.folder = folder
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.urlCache = nil; config.httpCookieStorage = nil
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    private func status(_ value: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(value) }
    }
    func tick(port: Int, token: String) { tick(baseURL: "http://127.0.0.1:\(port)", token: token, pin: nil) }
    func tick(baseURL: String, token: String, pin: String?) {
        lock.lock()
        // The pin travels with its connection so a transport switch can never
        // pair an HTTPS endpoint with a missing or different certificate pin.
        connection = FileConnection(baseURL: baseURL, token: token, pin: pin)
        guard !busy, !stopped else { lock.unlock(); return }
        busy = true; lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            do {
                let data = try self.request("/files", limit: 1_000_000)
                let manifest = try JSONDecoder().decode(FileManifest.self, from: data)
                guard manifest.files.count <= 100 else { throw self.error("Too many files in queue.") }
                if manifest.files.isEmpty {
                    if !self.hasReceived { self.status("Ready · Phone: Share → Android Wireless") }
                    return
                }
                try self.prepareFolder()
                for (index, file) in manifest.files.enumerated() {
                    try self.receive(file, index: index + 1, total: manifest.files.count)
                }
            } catch {
                self.status("Transfer waiting · \(error.localizedDescription) Retrying when connected.")
            }
        }
    }
    func disconnected() {
        lock.lock(); connection = nil; lock.unlock()
        status("Waiting for phone · queued files resume when connected")
    }
    func updateRequired() { status("Companion update needed · click Phone Setup") }
    func stop() {
        lock.lock(); stopped = true; connection = nil; lock.unlock()
        session.invalidateAndCancel()
    }
    private func error(_ message: String) -> NSError {
        NSError(domain: "AndroidWirelessFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func request(_ path: String, method: String = "GET", limit: Int) throws -> Data {
        lock.lock(); let current = connection; let isStopped = stopped; lock.unlock()
        guard !isStopped, let current else { throw error("Phone disconnected.") }
        delegate.trust(current.pin) // Requests are serial on `queue`, so this pin applies to this request.
        var request = URLRequest(url: URL(string: current.baseURL + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(current.token)", forHTTPHeaderField: "Authorization")
        let result = FileHTTPResult(); let complete = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, failure in
            if failure == nil, let response = response as? HTTPURLResponse, response.statusCode == 200,
               let data, data.count <= limit { result.store(data) }
            complete.signal()
        }
        task.resume()
        if complete.wait(timeout: .now() + 13) == .timedOut { task.cancel() }
        guard let data = result.get() else { throw error("Connection interrupted.") }
        return data
    }
    private func prepareFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let incoming = folder.appendingPathComponent(".incoming", isDirectory: true)
        if FileManager.default.fileExists(atPath: incoming.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: incoming.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw error("Transfer folder is unavailable.") }
        } else {
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
    }
    static func safeName(_ raw: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var name = raw.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Shared file" }
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let suffix = ext.utf8.count <= 20 && !ext.isEmpty ? "." + ext : ""
            var stem = (name as NSString).deletingPathExtension
            while stem.utf8.count > 180 { stem.removeLast() }
            name = stem + suffix
        }
        return name
    }
    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func receive(_ file: SharedFile, index: Int, total: Int) throws {
        guard file.id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil,
              file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              file.size >= 0, file.size <= 2_147_483_648 else { throw error("Invalid file metadata.") }
        let incoming = folder.appendingPathComponent(".incoming", isDirectory: true)
        let receiptURL = incoming.appendingPathComponent(file.id + ".receipt.json")
        if let data = try? Data(contentsOf: receiptURL),
           let receipt = try? JSONDecoder().decode(FileReceipt.self, from: data),
           receipt.sha256 == file.sha256, receipt.size == file.size {
            let saved = URL(fileURLWithPath: receipt.path)
            if saved.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
               FileManager.default.fileExists(atPath: saved.path), try Self.hash(saved) == file.sha256 {
                _ = try request("/files/\(file.id)/ack?sha256=\(file.sha256)", method: "POST", limit: 1024)
                return
            }
        }
        let name = Self.safeName(file.name)
        let partial = incoming.appendingPathComponent(file.id + ".partial")
        if FileManager.default.fileExists(atPath: partial.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: partial.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw error("Partial file is unavailable.") }
        } else { guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw error("Could not create file.") } }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var offset = Int64(try handle.seekToEnd())
        if offset > file.size { try handle.truncate(atOffset: 0); offset = 0 }
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free >= file.size - offset + 32 * 1024 * 1024 else { throw error("Not enough free space on Mac.") }
        while offset < file.size {
            let count = Int(min(1_048_576, file.size - offset))
            let data = try request("/files/\(file.id)?offset=\(offset)&length=\(count)", limit: count)
            guard data.count == count else { throw error("Incomplete file chunk.") }
            try handle.write(contentsOf: data); offset += Int64(data.count)
            status("Receiving \(index)/\(total) · \(name) · \(offset * 100 / max(1, file.size))%")
        }
        try handle.synchronize(); try handle.close()
        status("Verifying · \(name)")
        guard try Self.hash(partial) == file.sha256 else {
            try FileManager.default.removeItem(at: partial)
            throw error("File verification failed; restarting transfer.")
        }
        // A hard link creates the final name atomically and fails if it already exists.
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var saved: URL?
        for number in 1...10000 {
            let candidateName = number == 1 ? name : stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext)
            let candidate = folder.appendingPathComponent(candidateName)
            do { try FileManager.default.linkItem(at: partial, to: candidate); saved = candidate; break }
            catch { if !FileManager.default.fileExists(atPath: candidate.path) { throw error } }
        }
        guard let saved else { throw error("Could not choose a unique file name.") }
        // Mark downloads so Finder treats incoming executables as received files.
        let quarantine = "0083;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";Android Wireless;"
        quarantine.withCString { value in
            saved.path.withCString { path in _ = setxattr(path, "com.apple.quarantine", value, strlen(value), 0, 0) }
        }
        let receipt = FileReceipt(path: saved.path, sha256: file.sha256, size: file.size)
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        try FileManager.default.removeItem(at: partial)
        hasReceived = true
        status("Saved · \(saved.lastPathComponent)")
        let clipboard = file.isClipboard
        DispatchQueue.main.async { [weak self] in
            self?.onReceived?(saved)
            if clipboard { self?.onClipboard?(saved) }
        }
        _ = try request("/files/\(file.id)/ack?sha256=\(file.sha256)", method: "POST", limit: 1024)
    }
}
