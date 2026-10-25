import Foundation
import CryptoKit

struct PhoneApp: Codable, Equatable {
    let package: String
    let name: String
    let system: Bool
    let protected: Bool
    let enabled: Bool
    let component: String
    let icon: String?

    static func validPackage(_ value: String) -> Bool {
        value.count <= 255 && value.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)*$", options: .regularExpression) != nil
    }
    var canOpen: Bool {
        enabled && component.hasPrefix(package + "/") && component.count <= 512
            && component.range(of: "^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$", options: .regularExpression) != nil
    }
    var canUninstall: Bool { !system && !protected && package != companionPackage && Self.validPackage(package) }
    var displayName: String {
        let clean = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(512))
        return clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? package : clean
    }
    func matches(_ search: String) -> Bool {
        search.isEmpty || displayName.localizedStandardContains(search) || package.localizedStandardContains(search)
    }
}

struct PhoneAppsSnapshot: Codable {
    let user: Int
    let apps: [PhoneApp]
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 24 * 1024 * 1024,
              let line = data.split(separator: 10).last(where: { $0.starts(with: Data("JH_APPS:".utf8)) }) else {
            throw PhoneAppsError("Could not read the phone app list. Reconnect and refresh.")
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(line.dropFirst(8)))
        guard value.isValid else { throw PhoneAppsError("The phone returned an invalid app list.") }
        return value
    }
    var isValid: Bool {
        (0...10000).contains(user) && apps.count <= 4096 &&
            Set(apps.map(\.package)).count == apps.count &&
            apps.allSatisfy({ PhoneApp.validPackage($0.package) && $0.name.count <= 512 && ($0.icon?.count ?? 0) <= 65536 })
    }
}

/// Only the inventory is cached. Launch and uninstall still validate the current phone user and fresh app metadata.
/// Called on the drawer's serial queue; identity is the paired physical phone, not its changing Wi-Fi endpoint.
final class PhoneAppsCache {
    struct Entry: Codable {
        let schema: Int
        let identity: String
        let fetchedAt: Date
        let snapshot: PhoneAppsSnapshot
    }
    private let directory: URL
    private let now: () -> Date
    private let calendar: Calendar
    private var memory: [String: Entry] = [:]
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JH Mirror/App Drawer", isDirectory: true),
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.directory = directory; self.now = now; self.calendar = calendar
    }
    private func key(_ identity: String, _ user: Int) -> String {
        SHA256.hash(data: Data((identity + ":" + String(user)).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func load(identity: String, user: Int) -> Entry? {
        guard !identity.isEmpty else { return nil }
        let key = key(identity, user)
        if let entry = memory[key] { return entry }
        let file = directory.appendingPathComponent(key + ".json")
        guard let attrs = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attrs.isRegularFile == true, (attrs.fileSize ?? Int.max) <= 24 * 1024 * 1024,
              let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.schema == 1, entry.identity == identity, entry.snapshot.user == user, entry.snapshot.isValid else { return nil }
        memory[key] = entry; return entry
    }
    func isFresh(_ entry: Entry) -> Bool {
        entry.fetchedAt <= now() && calendar.isDate(entry.fetchedAt, inSameDayAs: now())
    }
    func save(_ snapshot: PhoneAppsSnapshot, identity: String, fetchedAt: Date? = nil) {
        guard !identity.isEmpty, snapshot.isValid else { return }
        let entry = Entry(schema: 1, identity: identity, fetchedAt: fetchedAt ?? now(), snapshot: snapshot)
        memory[key(identity, snapshot.user)] = entry
        do {
            let data = try JSONEncoder().encode(entry)
            guard data.count <= 24 * 1024 * 1024 else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let file = directory.appendingPathComponent(key(identity, snapshot.user) + ".json")
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
            if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: file) }
        } catch { /* Keep this day's in-memory inventory even when local storage is unavailable. */ }
    }
    var nextDay: Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now())) ?? now().addingTimeInterval(86400)
    }
    var currentDate: Date { now() }
}

struct PhoneAppsError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Called on the library's serial worker queue. Commands use only the existing paired ADB connection.
final class PhoneAppsClient {
    private let run: ([String], Double) -> (code: Int32, output: String)
    private let read: ([String], Double, Int) -> Data?
    init(run: @escaping ([String], Double) -> (code: Int32, output: String) = { args, timeout in
             let value = command(args, timeout: timeout); return (value.code, value.output)
         }, read: @escaping ([String], Double, Int) -> Data? = { commandData($0, timeout: $1, limit: $2) }) {
        self.run = run; self.read = read
    }
    func currentUser(_ serial: String) throws -> Int {
        let result = run(["-s", serial, "shell", "am", "get-current-user"], 5)
        guard result.code == 0, let user = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...10000).contains(user) else { throw PhoneAppsError("Phone unavailable. Reconnect and refresh the app list.") }
        return user
    }
    private func fetch(_ serial: String, user: Int, package: String? = nil) throws -> PhoneAppsSnapshot {
        let path = package.map { "app/" + $0 } ?? "list"
        let args = ["-s", serial, "exec-out", "content", "read", "--user", String(user),
                    "--uri", "content://com.johirulhoqakash.jhmirror.apps/" + path]
        guard let data = read(args, 30, 24 * 1024 * 1024) else {
            throw PhoneAppsError("App list unavailable. Update the phone companion, reconnect and refresh.")
        }
        let snapshot = try PhoneAppsSnapshot.decode(data)
        guard snapshot.user == user else { throw PhoneAppsError("Phone user changed. Refresh before trying again.") }
        return snapshot
    }
    func list(serial: String) throws -> PhoneAppsSnapshot { try fetch(serial, user: currentUser(serial)) }
    func list(serial: String, user: Int) throws -> PhoneAppsSnapshot { try fetch(serial, user: user) }
    private func fresh(_ app: PhoneApp, serial: String, user: Int) throws -> PhoneApp {
        guard PhoneApp.validPackage(app.package), try currentUser(serial) == user else {
            throw PhoneAppsError("Phone user changed. Refresh before trying again.")
        }
        let snapshot = try fetch(serial, user: user, package: app.package)
        guard snapshot.apps.count == 1, let fresh = snapshot.apps.first, fresh.package == app.package else {
            throw PhoneAppsError("This app changed or was removed. Refresh the library.")
        }
        return fresh
    }
    func open(_ app: PhoneApp, serial: String, user: Int) throws {
        let app = try fresh(app, serial: serial, user: user)
        guard app.canOpen else { throw PhoneAppsError("This package has no available app window to open.") }
        let result = run(["-s", serial, "shell", "am", "start", "--user", String(user), "--display", "0", "-n", phoneShellQuote(app.component)], 12)
        guard result.code == 0, !result.output.contains("Error:"), !result.output.contains("Exception") else {
            throw PhoneAppsError("Android could not open this app. Unlock the phone if needed, then try again.")
        }
    }
    /// The UI must obtain explicit, app-specific confirmation before calling this method.
    func uninstall(_ app: PhoneApp, serial: String, user: Int) throws {
        guard app.canUninstall else { throw PhoneAppsError("System and protected apps cannot be removed here.") }
        let checked = try fresh(app, serial: serial, user: user)
        guard checked.canUninstall else { throw PhoneAppsError("This is now a system or protected app. It was not removed.") }
        let result = run(["-s", serial, "shell", "pm", "uninstall", "--user", String(user), phoneShellQuote(app.package)], 45)
        guard result.code == 0, result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Success" else {
            throw PhoneAppsError("Android refused to uninstall this app. It may be managed by your device or an administrator.")
        }
    }
}
