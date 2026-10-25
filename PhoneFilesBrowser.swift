import Foundation

/// Only the newest navigation request may update the browser. Media scans never block file navigation.
final class PhoneFilesBrowser {
    private struct Key: Hashable { let identity: String; let user: Int; let path: String; let mode: String }
    private struct Entry { let list: PhoneFileList; let date: Date }
    private let client: PhoneFilesAccess
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var active: PhoneFileCancellation?
    private var cache: [Key: Entry] = [:]
    init(client: PhoneFilesAccess) { self.client = client; queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated }
    func cancel() {
        lock.lock(); let previous = active; active = nil; lock.unlock()
        previous?.cancel(); queue.cancelAllOperations()
    }
    func invalidate() { lock.lock(); cache.removeAll(); lock.unlock() }
    func load(serial: String, identity: String, path: String, mode: String, force: Bool = false,
              preview: ((PhoneFileConnection, PhoneFileList) -> Void)? = nil,
              completion: @escaping (Result<(PhoneFileConnection, PhoneFileList), Error>) -> Void) {
        cancel()
        let cancellation = PhoneFileCancellation()
        lock.lock(); active = cancellation; lock.unlock()
        queue.addOperation { [weak self] in
            guard let self else { return }
            let result = Result { () -> (PhoneFileConnection, PhoneFileList) in
                try cancellation.check()
                let connection = try self.client.connect(serial:serial,identity:identity,cancel:cancellation)
                try cancellation.check()
                let key = Key(identity:connection.peer.identity,user:connection.peer.user,path:path,mode:mode)
                self.lock.lock()
                if force { self.cache.removeAll() }
                let saved = self.cache[key]; self.lock.unlock()
                if let saved, -saved.date.timeIntervalSinceNow < (mode == "list" ? 30 : 300) { return (connection,saved.list) }
                if path.isEmpty, let preview, let first = try? self.client.initialMedia(connection, mode: mode, cancel: cancellation) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.lock.lock(); let current = self.active === cancellation; self.lock.unlock()
                        if current && !cancellation.cancelled { preview(connection, first) }
                    }
                }
                let list = try self.client.list(connection,path:path,mode:mode,cancel:cancellation)
                try cancellation.check()
                self.lock.lock(); self.cache[key] = Entry(list:list,date:Date())
                if self.cache.count > 16, let oldest = self.cache.min(by: { $0.value.date < $1.value.date })?.key { self.cache.removeValue(forKey:oldest) }
                self.lock.unlock()
                return (connection,list)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let current = self.active === cancellation; self.lock.unlock()
                guard current, !cancellation.cancelled else { return }; completion(result)
            }
        }
    }
}
