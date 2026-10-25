import Foundation

struct PhoneMediaDeletion {
    let removed: [PhoneFile]
    let failure: String?
}

/// Used only on the browser's serial worker. Originals are verified before Quick Look or clipboard access.
final class PhoneMediaActions {
    static var defaultDirectory: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("JH Mirror/Media Previews", isDirectory: true) }
    private let client: PhoneFilesAccess
    let directory: URL
    private var cached: [String: (url: URL, hash: String)] = [:]
    init(client: PhoneFilesAccess, directory: URL = PhoneMediaActions.defaultDirectory) {
        self.client = client; self.directory = directory
    }
    func prune(protecting urls: [URL]) {
        let protected = urls.map { $0.standardizedFileURL.path }
        for folder in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard folder.lastPathComponent.hasPrefix("preview-"),
                  !protected.contains(where: { $0.hasPrefix(folder.standardizedFileURL.path + "/") }),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: folder.path), attrs[.type] as? FileAttributeType == .typeDirectory,
                  let date = attrs[.modificationDate] as? Date, date < Date().addingTimeInterval(-7*86400) else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
    private func unchanged(_ connection: PhoneFileConnection, _ file: PhoneFile) throws -> PhoneFile {
        try client.validate(connection)
        let current = try client.info(connection, path:file.path)
        guard file.matches(current) else { throw PhoneFileError("Photo changed. Refresh the gallery and try again.") }; return current
    }
    func fetch(_ files: [PhoneFile], connection: PhoneFileConnection, cancel: PhoneFileCancellation,
               progress: @escaping (Int, Int, Int64, Int64) -> Void) throws -> [URL] {
        guard !files.isEmpty, files.allSatisfy({ $0.valid && !$0.directory && ["photo","video","audio"].contains($0.kind) }) else { throw PhoneFileError("Select media to preview.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var result: [URL] = []
        for (index, snapshot) in files.enumerated() {
            try cancel.check(); let file = try unchanged(connection, snapshot)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let key = String(decoding:try encoder.encode(connection.peer),as:UTF8.self) + String(decoding:try encoder.encode(file),as:UTF8.self)
            if let entry = cached[key], FileManager.default.fileExists(atPath: entry.url.path),
               try PhoneFileTransfers.hashFile(entry.url, cancel: cancel) == entry.hash { result.append(entry.url); continue }
            let free = (try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            guard free >= 32*1024*1024, file.size <= free - 32*1024*1024 else { throw PhoneFileError("Not enough free Mac space for the selected original.") }
            let batch = directory.appendingPathComponent("preview-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let url = batch.appendingPathComponent(PhoneFile.transferName(file.name))
            do {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PhoneFileError("Could not prepare the Mac preview.") }
                try client.read(connection, file: file, output: url, offset: 0, cancel: cancel) { progress(index+1, files.count, $0, file.size) }
                try cancel.check()
                let expected = try client.hash(connection, file: file, cancel: cancel)
                guard try PhoneFileTransfers.hashFile(url, cancel: cancel) == expected else { throw PhoneFileError("Photo verification failed. Try again after reconnecting.") }
                _ = try unchanged(connection, file); try cancel.check()
                cached[key] = (url,expected); result.append(url)
            } catch { try? FileManager.default.removeItem(at: batch); throw error }
        }
        return result
    }
    func removePhotos(_ files: [PhoneFile], connection: PhoneFileConnection) throws -> PhoneMediaDeletion {
        guard !files.isEmpty, Set(files.map(\.path)).count == files.count,
              files.allSatisfy({ $0.valid && !$0.directory && $0.kind == "photo" && !$0.path.isEmpty }) else { throw PhoneFileError("Select photos to delete.") }
        // Check the whole confirmed selection before removing its first item.
        let resolved = try files.map { try unchanged(connection, $0) }
        var removed: [PhoneFile] = []
        for file in resolved {
            do { _ = try unchanged(connection, file); try client.removePhoto(connection, file: file); removed.append(file) }
            catch { return PhoneMediaDeletion(removed: removed, failure: error.localizedDescription) }
        }
        return PhoneMediaDeletion(removed: removed, failure: nil)
    }
}
