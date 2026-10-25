import AppKit
import CryptoKit
import ImageIO

private final class ThumbnailBatch: Operation, @unchecked Sendable {
    let cancellation = PhoneFileCancellation()
    var work: ((PhoneFileCancellation) -> Void)?
    override func cancel() { super.cancel(); cancellation.cancel() }
    override func main() { if !isCancelled { work?(cancellation) } }
}

/// Main-thread coordinator. Only visible tiles are requested; each bounded phone
/// batch streams images individually. Private disk thumbnails survive app restarts.
final class PhoneThumbnailLoader {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.johirulhoqakash.jhmirror/Thumbnails", isDirectory: true)
    }
    private struct Batch { let keys: Set<String>; let operation: ThumbnailBatch }
    private let client: PhoneFilesAccess
    private let directory: URL
    private let queue = OperationQueue()
    private let cache = NSCache<NSString, NSImage>()
    private var batches: [UUID: Batch] = [:]
    private var wanted = Set<String>()
    private var completedBatches = 0
    private var receiver: ((PhoneFile, NSImage) -> Void)?
    init(client: PhoneFilesAccess, directory: URL = PhoneThumbnailLoader.defaultDirectory) {
        self.client = client; self.directory = directory
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated
        cache.countLimit = 240; cache.totalCostLimit = 32 * 1024 * 1024
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        DispatchQueue.global(qos: .utility).async { Self.prune(directory) }
    }
    static func key(_ file: PhoneFile, _ connection: PhoneFileConnection) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var data = try! encoder.encode(connection.peer); data.append(try! encoder.encode(file))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func cached(_ file: PhoneFile, connection: PhoneFileConnection) -> NSImage? {
        cache.object(forKey: Self.key(file, connection) as NSString)
    }
    func cancel() {
        wanted.removeAll(); receiver = nil
        for batch in batches.values { batch.operation.cancel() }; batches.removeAll(); queue.cancelAllOperations()
    }
    func invalidate() {
        cancel(); cache.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func load(_ files: [PhoneFile], connection: PhoneFileConnection, receive: @escaping (PhoneFile, NSImage) -> Void) {
        let files = Array(files.filter { ["photo", "video"].contains($0.kind) }.prefix(120))
        wanted = Set(files.map { Self.key($0, connection) }); receiver = receive
        for (id, batch) in batches where batch.keys.isDisjoint(with: wanted) {
            batch.operation.cancel(); batches.removeValue(forKey: id)
        }
        let pending = batches.values.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        var missing: [PhoneFile] = []
        for file in files {
            let key = Self.key(file, connection)
            if let image = cache.object(forKey: key as NSString) { receive(file, image) }
            else if !pending.contains(key) { missing.append(file) }
        }
        for start in stride(from: 0, to: missing.count, by: 6) {
            let files = Array(missing[start..<min(start + 6, missing.count)]), id = UUID()
            let operation = ThumbnailBatch(), client = client, directory = directory
            operation.work = { [weak self] cancellation in
                var remote: [PhoneFile] = []
                func emit(_ file: PhoneFile, _ data: Data, persist: Bool) {
                    guard !cancellation.cancelled, let image = Self.decode(data) else { return }
                    let key = Self.key(file, connection), path = directory.appendingPathComponent(key + ".thumb")
                    if persist {
                        try? data.write(to: path, options: [.atomic])
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                    } else { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !cancellation.cancelled else { return }
                        self.cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
                        if self.wanted.contains(key) { self.receiver?(file, image) }
                    }
                }
                for file in files {
                    if cancellation.cancelled { break }
                    let path = directory.appendingPathComponent(Self.key(file, connection) + ".thumb")
                    if let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 262144,
                       let data = try? Data(contentsOf: path), Self.decode(data) != nil { emit(file, data, persist: false) }
                    else { remote.append(file) }
                }
                try? client.thumbnails(connection, files: remote, cancel: cancellation) { file, data in emit(file, data, persist: true) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.batches.removeValue(forKey: id); self.completedBatches += 1
                    if self.completedBatches % 8 == 0 { DispatchQueue.global(qos: .utility).async { Self.prune(directory) } }
                }
            }
            batches[id] = Batch(keys: Set(files.map { Self.key($0, connection) }), operation: operation)
            queue.addOperation(operation)
        }
    }
    private static func decode(_ data: Data) -> NSImage? {
        guard data.count <= 262144, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 384,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    private static func prune(_ directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let values = files.filter { $0.pathExtension == "thumb" }.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var total = 0
        for (file, size, date) in values {
            total += size
            if total > 128 * 1024 * 1024 || date < Date().addingTimeInterval(-7 * 86400) { try? FileManager.default.removeItem(at: file) }
        }
    }
}
