import Foundation
import CryptoKit
import Darwin

struct PhoneFileTransfer: Codable, Identifiable {
    let id: String
    let peer: PhoneFilePeer
    let upload: Bool
    let source: String
    let destination: String
    let file: PhoneFile
    var state: String = "Queued"
    var completed: Int64 = 0
    var speed: Double = 0
    var message: String = ""
    var result: String?
    var exactDestination = false
    var sourceHash: String?
    var attempts = 0
    var autoRetry = false
    var pending: Bool { state != "Done" }
}

private struct PhoneTransferSnapshot: Codable { let generation: String; let jobs: [PhoneFileTransfer] }
private struct PhoneTransferUpdate: Codable { let generation: String; let job: PhoneFileTransfer }

/// One bounded stream at a time, independent of notification/clipboard polling and the mirror.
final class PhoneFileTransfers {
    var onChange: (([PhoneFileTransfer]) -> Void)?
    var onSaved: ((URL) -> Void)?
    private let client: PhoneFilesAccess
    private let provider: () -> (serial: String, identity: String)?
    private let work = DispatchQueue(label: "jhmirror.file-transfer", qos: .userInitiated)
    private let planning = DispatchQueue(label: "jhmirror.file-planning", qos: .userInitiated)
    private let lock = NSLock()
    private let storageLock = NSLock()
    private var jobs: [PhoneFileTransfer] = []
    private var running = false
    private var cancellation: PhoneFileCancellation?
    private var stopped = false
    private var resumeAfterPause = false
    private var storageGeneration = "legacy"
    private var callbacks: [String: (Error?) -> Void] = [:]
    private let directory: URL
    private var retryTimer: Timer?
    private var lastPublish = Date.distantPast
    init(client: PhoneFilesAccess, directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JH Mirror/Transfers", isDirectory: true),
         provider: @escaping () -> (serial: String, identity: String)?) {
        self.client = client; self.directory = directory; self.provider = provider
        let manifest = directory.appendingPathComponent("queue.json")
        if let attrs = try? manifest.resourceValues(forKeys: [.fileSizeKey]), (attrs.fileSize ?? Int.max) < 16*1024*1024,
           let data = try? Data(contentsOf: manifest) {
            if let saved = try? JSONDecoder().decode(PhoneTransferSnapshot.self, from: data), saved.jobs.count <= 10000 {
                storageGeneration = saved.generation; jobs = saved.jobs
            } else if let legacy = try? JSONDecoder().decode([PhoneFileTransfer].self, from: data), legacy.count <= 10000 { jobs = legacy }
        }
        var loadedIDs = Set<String>()
        jobs = jobs.filter { loadedIDs.insert($0.id).inserted }
        let journal = directory.appendingPathComponent("updates.jsonl")
        if let attrs = try? journal.resourceValues(forKeys: [.fileSizeKey]), (attrs.fileSize ?? Int.max) <= 16*1024*1024,
           let data = try? Data(contentsOf: journal) {
            let indexes = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($0.element.id, $0.offset) })
            for line in data.split(separator: 10) {
                if let update = try? JSONDecoder().decode(PhoneTransferUpdate.self, from: Data(line)), update.generation == storageGeneration,
                   let index = indexes[update.job.id] { jobs[index] = update.job }
            }
        }
        jobs = jobs.filter { $0.id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil && $0.file.valid && !$0.peer.identity.isEmpty && (0...10000).contains($0.peer.user) && ($0.upload ? $0.source.hasPrefix("/") : $0.destination.hasPrefix("/")) && PhoneFile.validPath($0.upload ? $0.destination : $0.source) }
            .map { job in var value = job; if value.pending { value.state = "Paused"; value.autoRetry = false; value.message = "Resume to continue the saved transfer." }; return value }
        let timer = Timer(timeInterval: 6, repeats: true) { [weak self] _ in self?.retryWaiting() }
        RunLoop.main.add(timer, forMode: .common); retryTimer = timer
    }
    deinit { retryTimer?.invalidate() }
    var snapshot: [PhoneFileTransfer] { lock.lock(); defer { lock.unlock() }; return jobs }
    private func privateDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func save(_ id: String? = nil) {
        storageLock.lock(); defer { storageLock.unlock() }
        do {
            try privateDirectory()
            let journal = directory.appendingPathComponent("updates.jsonl")
            let journalSize = ((try? FileManager.default.attributesOfItem(atPath: journal.path)[.size]) as? NSNumber)?.intValue ?? 0
            if let id, journalSize < 4*1024*1024, let job = snapshot.first(where: { $0.id == id }) {
                var data = Data([10]); data.append(try JSONEncoder().encode(PhoneTransferUpdate(generation: storageGeneration, job: job))); data.append(10)
                if !FileManager.default.fileExists(atPath: journal.path) { FileManager.default.createFile(atPath: journal.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let file = try FileHandle(forWritingTo: journal); defer { try? file.close() }
                try file.seekToEnd(); try file.write(contentsOf: data); try file.synchronize()
            } else {
                let generation = UUID().uuidString
                let data = try JSONEncoder().encode(PhoneTransferSnapshot(generation: generation, jobs: snapshot))
                let path = directory.appendingPathComponent("queue.json")
                try data.write(to: path, options: .atomic)
                storageGeneration = generation
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                // Older journal records carry another generation, so a crash during compaction cannot replay stale states.
                if FileManager.default.fileExists(atPath: journal.path) {
                    let file = try FileHandle(forWritingTo: journal); try file.truncate(atOffset: 0); try file.synchronize(); try file.close()
                }
            }
        } catch { /* Existing copies and partial files remain intact. */ }
    }
    private func publish(force: Bool = false) {
        let now = Date()
        lock.lock(); let should = force || now.timeIntervalSince(lastPublish) >= 0.25
        if should { lastPublish = now }; let values = jobs; lock.unlock()
        if should { DispatchQueue.main.async { [weak self] in self?.onChange?(values) } }
    }
    private func update(_ id: String, persist: Bool = true, _ body: (inout PhoneFileTransfer) -> Void) {
        lock.lock(); if let index = jobs.firstIndex(where: { $0.id == id }) { body(&jobs[index]) }; lock.unlock()
        if persist { save(id) }; publish(force: persist)
    }
    private func connection(_ peer: PhoneFilePeer? = nil, cancel: PhoneFileCancellation = PhoneFileCancellation()) throws -> PhoneFileConnection {
        var current: (serial: String, identity: String)?
        if Thread.isMainThread { current = provider() } else { DispatchQueue.main.sync { current = self.provider() } }
        guard let current else { throw PhoneFileError("Phone disconnected. Transfers can resume when it reconnects.") }
        let value = try client.connect(serial: current.serial, identity: current.identity, cancel: cancel)
        guard peer == nil || value.peer == peer else { throw PhoneFileError("This transfer belongs to another phone or Android user.") }; return value
    }
    private func append(_ values: [PhoneFileTransfer], completion: ((Error?) -> Void)? = nil) throws {
        lock.lock()
        guard !stopped, jobs.filter(\.pending).count + values.count <= 10000 else { lock.unlock(); throw PhoneFileError("Transfer queue is full. Finish or pause this batch first.") }
        jobs = jobs.filter(\.pending) + Array(jobs.filter { !$0.pending }.suffix(100)) + values
        if let completion, values.count == 1 { callbacks[values[0].id] = completion }
        lock.unlock(); save(); publish(force: true); start()
        if values.isEmpty { completion?(nil) }
    }
    private func identifier() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    func upload(_ urls: [URL], folder: String, connection: PhoneFileConnection? = nil, completion: @escaping (Error?) -> Void = { _ in }) {
        planning.async {
            do {
                let peer = try connection ?? self.connection(); try self.client.validate(peer)
                _ = try self.client.makeDirectory(peer, path: folder, name: nil)
                var values: [PhoneFileTransfer] = []
                func add(_ url: URL, parent: String) throws {
                    guard values.count < 10000 else { throw PhoneFileError("Choose fewer than 10,000 files per batch.") }
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else { throw PhoneFileError("Symbolic links are not copied. Select their original files.") }
                    if attrs[.type] as? FileAttributeType == .typeDirectory {
                        let target = try self.client.makeDirectory(peer, path: parent, name: PhoneFile.transferName(url.lastPathComponent))
                        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) where child.lastPathComponent != ".DS_Store" { try add(child, parent: target.path) }
                    } else {
                        guard attrs[.type] as? FileAttributeType == .typeRegular, let size = (attrs[.size] as? NSNumber)?.int64Value, let modified = attrs[.modificationDate] as? Date else { throw PhoneFileError("Select regular files or folders.") }
                        let item = PhoneFile(path: "", name: PhoneFile.transferName(url.lastPathComponent), directory: false, size: Int64(size), modified: Int64(modified.timeIntervalSince1970*1000), kind: "file")
                        values.append(PhoneFileTransfer(id: self.identifier(), peer: peer.peer, upload: true, source: url.path, destination: parent, file: item))
                    }
                }
                for url in urls { try add(url, parent: folder) }
                try self.append(values); DispatchQueue.main.async { completion(nil) }
            } catch { DispatchQueue.main.async { completion(error) } }
        }
    }
    private func uniqueFolder(_ parent: URL, name: String, exact: Bool = false) throws -> URL {
        for number in 1...10000 {
            let target = exact ? parent : parent.appendingPathComponent(name + (number == 1 ? "" : " (\(number))"), isDirectory: true)
            if mkdir(target.path, 0o755) == 0 { return target }
            if errno != EEXIST || exact { throw PhoneFileError("Could not create the destination folder without replacing an existing item.") }
        }
        throw PhoneFileError("Could not choose a free folder name.")
    }
    func download(_ items: [PhoneFile], connection: PhoneFileConnection, into folder: URL, exact: URL? = nil, completion: ((Error?) -> Void)? = nil) {
        planning.async {
            do {
                try self.client.validate(connection)
                var values: [PhoneFileTransfer] = []
                for original in items {
                    var item = original
                    if item.indexed == true {
                        let current = try self.client.info(connection,path:item.path)
                        guard item.matches(current) else { throw PhoneFileError("Phone file changed. Refresh and start a new copy.") }; item = current
                    }
                    if item.directory {
                        let target = try self.uniqueFolder(exact ?? folder, name: PhoneFile.transferName(item.name), exact: exact != nil)
                        let tree = try self.client.list(connection, path: item.path, mode: "tree")
                        guard !tree.truncated else { throw PhoneFileError("This folder exceeds 20,000 items. Copy its subfolders separately.") }
                        for child in tree.items {
                            guard child.path.hasPrefix(item.path + "/") else { throw PhoneFileError("Invalid folder contents.") }
                            let suffix = String(child.path.dropFirst(item.path.count + 1))
                            let local = suffix.split(separator: "/").reduce(target) { $0.appendingPathComponent(PhoneFile.transferName(String($1))) }
                            if child.directory { try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true) }
                            else {
                                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                                values.append(PhoneFileTransfer(id: self.identifier(), peer: connection.peer, upload: false, source: child.path, destination: local.path, file: child))
                            }
                        }
                    } else {
                        let target = exact ?? folder.appendingPathComponent(PhoneFile.transferName(item.name))
                        var job = PhoneFileTransfer(id: self.identifier(), peer: connection.peer, upload: false, source: item.path, destination: target.path, file: item)
                        job.exactDestination = exact != nil; values.append(job)
                    }
                }
                if let completion, values.count > 1 {
                    let group = TransferBatch(count: values.count, completion: completion)
                    self.lock.lock(); for value in values { self.callbacks[value.id] = { group.complete($0) } }; self.lock.unlock()
                }
                try self.append(values, completion: completion)
            } catch { DispatchQueue.main.async { completion?(error) } }
        }
    }
    func pause() {
        lock.lock(); let current = cancellation
        for i in jobs.indices where jobs[i].pending { if jobs[i].state != "Paused" { jobs[i].state = "Paused"; jobs[i].message = "Paused · partial data saved" }; jobs[i].autoRetry = false }
        lock.unlock(); current?.cancel(); work.async { self.save(); self.publish(force: true) }
    }
    func resume() {
        lock.lock()
        if running && cancellation?.cancelled == true { resumeAfterPause = true; lock.unlock(); return }
        for i in jobs.indices where jobs[i].state == "Paused" { jobs[i].state = "Queued"; jobs[i].message = ""; jobs[i].attempts = 0; jobs[i].autoRetry = false }; lock.unlock()
        save(); publish(force: true); start()
    }
    private func retryWaiting() {
        lock.lock(); for i in jobs.indices where jobs[i].state == "Paused" && jobs[i].autoRetry && jobs[i].attempts < 3 { jobs[i].state = "Queued" }; lock.unlock(); start()
    }
    func stop() { lock.lock(); stopped = true; lock.unlock(); pause(); retryTimer?.invalidate(); retryTimer = nil }
    private func start() {
        lock.lock(); guard !running, !stopped, jobs.contains(where: { $0.state == "Queued" }) else { lock.unlock(); return }; running = true; lock.unlock()
        work.async {
            while true {
                self.lock.lock()
                guard !self.stopped, let job = self.jobs.first(where: { $0.state == "Queued" }) else { self.running = false; self.cancellation = nil; self.lock.unlock(); break }
                let cancel = PhoneFileCancellation(); self.cancellation = cancel; self.lock.unlock()
                do {
                    self.update(job.id) { $0.state = "Connecting"; $0.attempts += 1 }
                    let connection = try self.connection(job.peer, cancel: cancel); try cancel.check()
                    try self.transfer(job, connection: connection, cancel: cancel)
                    self.update(job.id) { $0.state = "Done"; $0.completed = $0.file.size; $0.speed = 0; $0.message = "Verified"; $0.autoRetry = false }
                    self.lock.lock(); let callback = self.callbacks.removeValue(forKey: job.id); self.lock.unlock(); callback?(nil)
                } catch {
                    self.update(job.id) { $0.state = "Paused"; $0.speed = 0; $0.message = error.localizedDescription; $0.autoRetry = !cancel.cancelled && $0.attempts < 3 }
                    self.lock.lock(); let callback = self.callbacks.removeValue(forKey: job.id)
                    if self.resumeAfterPause && !self.stopped {
                        self.resumeAfterPause = false
                        for i in self.jobs.indices where self.jobs[i].state == "Paused" { self.jobs[i].state = "Queued"; self.jobs[i].attempts = 0; self.jobs[i].autoRetry = false }
                    }
                    self.lock.unlock(); callback?(error)
                }
            }
        }
    }
    static func hashFile(_ url: URL, cancel: PhoneFileCancellation) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var value = SHA256()
        while let bytes = try handle.read(upToCount: 1048576), !bytes.isEmpty { try cancel.check(); value.update(data: bytes) }
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func localUnchanged(_ job: PhoneFileTransfer, url: URL) throws {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)
        guard value[.type] as? FileAttributeType == .typeRegular, (value[.size] as? NSNumber)?.int64Value == job.file.size,
              Int64(((value[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)*1000) == job.file.modified else { throw PhoneFileError("Source changed. Start a new copy of this file.") }
    }
    private func transfer(_ job: PhoneFileTransfer, connection: PhoneFileConnection, cancel: PhoneFileCancellation) throws {
        var started = Date(); var first: Int64?
        let progress: (Int64) -> Void = { count in
            if first == nil { first = count; started = Date() }
            let speed = Double(max(0, count - (first ?? 0))) / max(0.1, -started.timeIntervalSinceNow)
            self.update(job.id, persist: false) { $0.state = "Copying"; $0.completed = count; $0.speed = speed; $0.message = "" }
        }
        if job.upload {
            let source = URL(fileURLWithPath: job.source); try localUnchanged(job, url: source)
            update(job.id) { $0.state = "Verifying source" }
            let sha = try Self.hashFile(source, cancel: cancel); try cancel.check(); try localUnchanged(job, url: source)
            let (offset, done) = try client.beginUpload(connection, folder: job.destination, id: job.id, name: job.file.name, size: job.file.size, hash: sha, cancel: cancel)
            update(job.id) { $0.sourceHash = sha; $0.completed = offset; $0.state = "Copying" }
            progress(offset)
            var result = done
            if result == nil {
                if offset < job.file.size { try client.write(connection, folder: job.destination, id: job.id, source: source, offset: offset, size: job.file.size, cancel: cancel, progress: progress) }
                try localUnchanged(job, url: source); try cancel.check()
                update(job.id) { $0.state = "Verifying"; $0.speed = 0 }
                result = try client.commit(connection, folder: job.destination, id: job.id, size: job.file.size, cancel: cancel)
            }
            update(job.id) { $0.result = result?.path }
            if let result, let concrete = client as? PhoneFilesClient { concrete.scan(connection, file: result) }
            client.finish(connection, folder: job.destination, id: job.id)
        } else {
            let source = try client.info(connection, path: job.source)
            guard source == job.file else { throw PhoneFileError("Phone file changed. Refresh and start a new copy.") }
            try privateDirectory()
            let destination = URL(fileURLWithPath: job.destination)
            let partial = destination.deletingLastPathComponent().appendingPathComponent(".jhmirror-" + job.id + ".partial")
            if !FileManager.default.fileExists(atPath: partial.path) {
                guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PhoneFileError("Cannot create partial copy.") }
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: partial.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw PhoneFileError("Invalid partial file.") }
            let offset = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard offset <= source.size else { throw PhoneFileError("Invalid saved resume offset.") }
            let free = try FileManager.default.attributesOfFileSystem(forPath: destination.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber
            guard (free?.int64Value ?? 0) >= 32*1024*1024, source.size - offset <= (free?.int64Value ?? 0) - 32*1024*1024 else { throw PhoneFileError("Not enough free space on Mac.") }
            progress(offset)
            if offset < source.size { try client.read(connection, file: source, output: partial, offset: offset, cancel: cancel, progress: progress) }
            update(job.id) { $0.state = "Verifying"; $0.speed = 0 }
            let expected = try client.hash(connection, file: source, cancel: cancel)
            guard try Self.hashFile(partial, cancel: cancel) == expected else {
                try? FileManager.default.removeItem(at: partial); throw PhoneFileError("Checksum mismatch. Resume to restart this file safely.")
            }
            guard try client.info(connection, path: source.path) == source else { throw PhoneFileError("Source changed while copying.") }
            try cancel.check()
            let saved = try self.publishFile(partial, destination: destination, exact: job.exactDestination)
            update(job.id) { $0.result = saved.path }
            try? FileManager.default.removeItem(at: partial)
            DispatchQueue.main.async { self.onSaved?(saved) }
        }
    }
    private func publishFile(_ partial: URL, destination: URL, exact: Bool) throws -> URL {
        let folder = destination.deletingLastPathComponent()
        let ext = destination.pathExtension, stem = destination.deletingPathExtension().lastPathComponent
        for number in 1...(exact ? 1 : 10000) {
            let target = number == 1 ? destination : folder.appendingPathComponent(stem + " (\(number))" + (ext.isEmpty ? "" : "."+ext))
            // Same-volume atomic rename with exclusive destination: works for Finder promises too.
            if renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                let quarantine = "0083;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";JH Mirror;"
                quarantine.withCString { value in target.path.withCString { path in _ = setxattr(path,"com.apple.quarantine",value,strlen(value),0,0) } }
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
                return target
            }
            if errno == EEXIST { continue }
            throw PhoneFileError("Could not publish the verified copy here: " + String(cString: strerror(errno)))
        }
        throw PhoneFileError("Destination already exists. Choose another filename.")
    }

}
private final class TransferBatch {
    private let lock = NSLock(); private var remaining: Int; private var firstError: Error?
    private let completion: (Error?) -> Void
    init(count: Int, completion: @escaping (Error?) -> Void) { remaining = count; self.completion = completion }
    func complete(_ error: Error?) { lock.lock(); if firstError == nil { firstError = error }; remaining -= 1; let done = remaining == 0, failure = firstError; lock.unlock(); if done { completion(failure) } }
}
