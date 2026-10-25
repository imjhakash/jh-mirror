import Foundation
import Darwin

/// Shared by installed and review copies. Never unlink a live lock file: a second
/// inode could otherwise admit another owner while the first process still runs.
final class AppInstanceLock {
    private let descriptor: Int32
    init?(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(".instance.lock").path
        let file = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno; close(file)
            if failure == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        guard fchmod(file, 0o600) == 0 else {
            let failure = errno; close(file); throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        descriptor = file
    }
    deinit { close(descriptor) }
}
