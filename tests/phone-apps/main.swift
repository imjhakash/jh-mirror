import Foundation

let companionPackage = "com.johirulhoqakash.jhmirror"
struct CommandResult { let code: Int32; let output: String }
func command(_ args: [String], timeout: Double) -> CommandResult { fatalError("Tests must inject commands") }
func commandData(_ args: [String], timeout: Double, limit: Int) -> Data? { fatalError("Tests must inject reads") }
func phoneShellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func app(_ package: String = "org.example.app", system: Bool = false, protected: Bool = false,
         component: String = "org.example.app/.Main") -> PhoneApp {
    PhoneApp(package: package, name: "Example বাংলা", system: system, protected: protected, enabled: true, component: component, icon: nil)
}
func payload(_ value: PhoneApp, user: Int = 0) -> Data {
    let object: [String: Any] = ["user": user, "apps": [["package": value.package, "name": value.name, "system": value.system,
        "protected": value.protected, "enabled": value.enabled, "component": value.component]]]
    return Data("runtime preamble\nJH_APPS:".utf8) + (try! JSONSerialization.data(withJSONObject: object)) + Data([10])
}
func rejects(_ message: String, operation: () throws -> Void) {
    do { try operation(); require(false, message) } catch { }
}
let userApp = app()
require(userApp.canOpen && userApp.canUninstall && userApp.matches("বাংলা") && userApp.matches("EXAMPLE.APP"), "names, packages and Unicode search")
require(!app(system: true).canUninstall && !app(protected: true).canUninstall && !app(companionPackage).canUninstall, "system/active/self protections")
require(!app("org.example;reboot").canUninstall && !app(component: "other.app/.Main").canOpen && !app(component: "org.example.app/.Main;reboot").canOpen, "untrusted package and component arguments rejected")
require(try! PhoneAppsSnapshot.decode(payload(userApp)).apps == [userApp], "inventory ignores harmless runtime preamble")
rejects("malformed inventory rejected") { _ = try PhoneAppsSnapshot.decode(Data("JH_APPS:{}".utf8)) }
rejects("invalid phone user rejected") { _ = try PhoneAppsSnapshot.decode(payload(userApp, user: -1)) }

var requests: [[String]] = [], freshApp = userApp, currentUser = "0", reads = 0
let client = PhoneAppsClient(run: { args, _ in
    requests.append(args)
    if args.contains("get-current-user") { return (0, currentUser + "\n") }
    if args.contains("uninstall") { return (0, "Success\n") }
    return (0, "")
}, read: { _, _, _ in reads += 1; return payload(freshApp) })
require(try! client.list(serial: "paired").apps.count == 1, "inventory fetched")
try! client.open(userApp, serial: "paired", user: 0)
let open = requests.last!
require(open.contains("start") && open.contains("'org.example.app/.Main'") && !open.contains("--force-stop"), "open uses a fresh, quoted component without force stopping")
freshApp = app(system: true)
let before = requests.filter { $0.contains("uninstall") }.count
rejects("fresh system status prevents uninstall") { try client.uninstall(userApp, serial: "paired", user: 0) }
require(requests.filter { $0.contains("uninstall") }.count == before, "reclassification never executes removal")
freshApp = userApp; currentUser = "10"
rejects("profile switch refuses stale action") { try client.uninstall(userApp, serial: "paired", user: 0) }
require(requests.filter { $0.contains("uninstall") }.count == before, "stale profile never executes removal")
currentUser = "0"
try! client.uninstall(userApp, serial: "paired", user: 0)
let remove = requests.last!
require(remove.suffix(4) == ["uninstall", "--user", "0", "'org.example.app'"], "uninstall is confined to the confirmed current phone user")
require(!requests.contains { $0.contains("push") } && reads == 4, "read-only companion inventory revalidates each action without a shell helper")
print("PASS: app inventory/search/argument validation; protected apps and changed users refuse removal; fresh launch and current-user uninstall commands.")

let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("jh-inventory-cache-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: cacheDirectory) }
var date = Date(timeIntervalSince1970: 1_790_000_000)
let cache = PhoneAppsCache(directory: cacheDirectory, now: { date })
let snapshot = try! PhoneAppsSnapshot.decode(payload(userApp))
cache.save(snapshot, identity: "phone-one")
let stored = cache.load(identity: "phone-one", user: 0)!
require(cache.isFresh(stored), "today's inventory is fresh")
let reopenedCache = PhoneAppsCache(directory: cacheDirectory, now: { date })
require(reopenedCache.load(identity: "phone-one", user: 0)?.snapshot.apps == [userApp], "inventory persists across app launches")
require(reopenedCache.load(identity: "phone-two", user: 0) == nil && reopenedCache.load(identity: "phone-one", user: 10) == nil, "cache isolates physical phones and Android users")
let files = try! FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
require(files.count == 1, "cache leaves only its atomic inventory file")
let attrs = try! FileManager.default.attributesOfItem(atPath: files[0].path)
require((attrs[.posixPermissions] as! NSNumber).intValue & 0o777 == 0o600, "inventory file is private")
date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
require(!cache.isFresh(stored), "next local calendar day requires a new inventory")
cache.save(snapshot, identity: "phone-one")
let afterRefresh = PhoneAppsCache(directory: cacheDirectory, now: { date })
require(afterRefresh.isFresh(afterRefresh.load(identity: "phone-one", user: 0)!), "manual/daily refresh replaces the persisted timestamp")
print("PASS: persistent daily inventory cache, next-day expiry, atomic replacement, private permissions and per-phone/profile isolation.")
