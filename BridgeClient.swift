import Foundation
import Network
import Security
import CryptoKit

let companionPackage = "com.johirulhoqakash.jhmirror"
/// The companion's package before the JH Mirror name; replaced automatically.
let legacyCompanionPackage = "local.androidwireless.bridge"
/// Companion protocol required by this Mac build. Older companions are upgraded over ADB.
let requiredProtocol = 15

/// A button on a phone notification. `input` means it takes typed text (Reply).
struct PhoneAction: Decodable, Equatable {
    let title: String
    let input: Bool
}

struct PhoneEvent: Decodable {
    let type: String
    let key: String
    let app: String?
    let title: String?
    let body: String?
    let time: Double?
    let packageName: String?
    var icon: String?
    /// The phone's buttons by their index on the phone; nil entries cannot be shown on the Mac.
    var actions: [PhoneAction?]? = nil
    /// The notification opens something when tapped on the phone.
    var open: Bool? = nil
    enum CodingKeys: String, CodingKey {
        case type, key, app, title, body, time, icon, actions, open
        case packageName = "package"
    }
}

struct BridgeResponse: Decodable {
    let device: PhoneDeviceInfo?
    let protocolVersion: Int?
    let session: String
    let sequence: Int64
    let connected: Bool
    let enabled: Bool
    let events: [PhoneEvent]
    let icons: [String: String]?
    let lanCertificate: String?
    let lanIdentity: String?
    let lanPort: Int?
    /// Wireless debugging is on, and whether the companion may switch it on (protocol 6+).
    let adbWifi: Bool?
    let canEnableAdbWifi: Bool?
}

private final class ResponseBox {
    private let lock = NSLock()
    private var value: BridgeResponse?
    func put(_ response: BridgeResponse?) { lock.lock(); defer { lock.unlock() }; value = response }
    func get() -> BridgeResponse? { lock.lock(); defer { lock.unlock() }; return value }
}

final class BridgeClient {
    var onDevice: ((PhoneDeviceInfo) -> Void)?
    var pairingPaused = false
    let files = FileTransferClient()
    var onStatus: ((String) -> Void)?
    var onEvents: (([PhoneEvent]) -> Void)?
    var onPhone: ((String) -> Void)?
    private let worker = DispatchQueue(label: "com.johirulhoqakash.jhmirror.notifications")
    /// Mac → phone transfers can take minutes; they must not stall notification polling.
    private let pushQueue = DispatchQueue(label: "com.johirulhoqakash.jhmirror.push", qos: .utility)
    private let session: URLSession
    private var timer: Timer?
    private var busy = false
    private var stopped = false
    private var serial: String?
    private var port: Int?
    private var token = ""
    private var cursor: Int64 = 0
    private var phoneSession: String?
    private var failures = 0
    private var icons: [String: String] = [:]
    private var attemptedConnection = false
    private let discovery = WifiDiscovery()
    private let adbDiscovery = WifiDiscovery(type: "_adb-tls-connect._tcp.")
    private let stateLock = NSLock()
    private var lastSync = Date.distantPast
    /// The channel that last worked (encrypted Wi-Fi or the ADB tunnel), for notification commands.
    private var activeBase: String?
    private let commandQueue = DispatchQueue(label: "com.johirulhoqakash.jhmirror.commands", qos: .userInitiated)
    private var adbWantedValue = true
    private var lastEnableRequest = Date.distantPast
    private var grantedThisSession = false
    private var consecutiveADBFailures = 0
    private var lastServerRestart = Date.distantPast
    private let http = PairedHTTP()
    private var peer = WifiPeer.load()
    private var adbRetry = RetryGate()
    /// While the Wi-Fi channel is failing it is probed with backoff; ADB carries sync meanwhile.
    private var lanRetry = RetryGate()
    private var lanFailures = 0
    private var attemptedUpgrade = false
    private let pathMonitor = NWPathMonitor()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: http, delegateQueue: nil)
        http.trust(peer?.certificateHash)
    }

    /// True while notifications/files synced within the last few seconds (Wi-Fi or ADB).
    var syncHealthy: Bool { stateLock.lock(); defer { stateLock.unlock() }; return Date().timeIntervalSince(lastSync) < 8 }
    /// Called on the main queue with the phone app's "Send notifications to Mac" switch.
    var onPhoneNotificationsEnabled: ((Bool) -> Void)?
    /// Whether anything currently needs ADB (screen, auto-copy). Only then is Wireless debugging switched on.
    var adbWanted: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return adbWantedValue }
        set { stateLock.lock(); adbWantedValue = newValue; stateLock.unlock() }
    }

    func start() {
        discovery.start()
        adbDiscovery.start()
        let adbBrowser = adbDiscovery
        bonjourADBEndpoints = { adbBrowser.endpoints(prefix: "adb-\(phoneSerial)-") }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            // A new network may make either channel reachable again: retry both now.
            self.worker.async { self.lanRetry.succeeded(); self.adbRetry.succeeded(); self.lanFailures = 0 }
            DispatchQueue.main.async { self.tick() }
        }
        pathMonitor.start(queue: worker)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func status(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(text) }
    }

    private func fetch(_ base: String, path: String) -> BridgeResponse? {
        var request = URLRequest(url: URL(string: base + path)!)
        request.timeoutInterval = 3
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let complete = DispatchSemaphore(value: 0), result = ResponseBox()
        let task = session.dataTask(with: request) { data, response, error in
            if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data, data.count < 4_000_000 { result.put(try? JSONDecoder().decode(BridgeResponse.self, from: data)) }
            complete.signal()
        }
        task.resume()
        if complete.wait(timeout: .now() + 4) == .timedOut { task.cancel() }
        return result.get()
    }

    private func consume(_ result: BridgeResponse, base: String, pin: String?) {
        stateLock.lock(); lastSync = Date(); activeBase = base; stateLock.unlock()
        files.tick(baseURL: base, token: token, pin: pin)
        if base.hasPrefix("https:") { restoreWirelessDebuggingIfNeeded(result, base: base) }
        let isNewSession = phoneSession != result.session
        phoneSession = result.session
        cursor = result.sequence
        if let icons = result.icons { self.icons.merge(icons) { _, new in new } }
        let enabled = result.enabled
        if let device = result.device, device.valid { DispatchQueue.main.async { self.onDevice?(device) } }
        DispatchQueue.main.async { self.onPhoneNotificationsEnabled?(enabled) }
        status(!result.connected ? "Notification access off · phone app → Settings → Notification access"
            : !result.enabled ? "Notifications are off in the phone app"
            : base.hasPrefix("https:") ? "Connected" : "Connected (via Wireless debugging)")
        if !isNewSession && result.connected && result.enabled && !result.events.isEmpty {
            var events = result.events
            for index in events.indices {
                if let app = events[index].packageName { events[index].icon = self.icons[app] }
            }
            DispatchQueue.main.async { self.onEvents?(events) }
        }
    }

    /// Installs the bundled companion when the phone runs an older protocol.
    /// Returns true when an install happened and the bridge must reconnect.
    private func upgradeIfNeeded(_ result: BridgeResponse) -> Bool {
        guard (result.protocolVersion ?? 1) < requiredProtocol, !attemptedUpgrade,
              let apk = Bundle.main.url(forResource: "JH Mirror Companion", withExtension: "apk"),
              let serial = serial ?? findPhone() else { return false }
        attemptedUpgrade = true; self.serial = serial
        _ = apk
        status("Updating the phone app…")
        guard installCompanion(serial) else { return false }
        connectionLog("Companion upgraded to protocol \(requiredProtocol)")
        // The new companion may be a different package with a new Wi-Fi certificate:
        // the ADB path below provisions it and relearns that certificate.
        if let port { _ = command(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 2) }
        port = nil; phoneSession = nil; peer = nil
        return true
    }

    /// Installs (or updates) the bundled companion, retires the old "Android Wireless" companion,
    /// and grants everything over ADB so nobody has to visit phone settings.
    @discardableResult func installCompanion(_ serial: String) -> Bool {
        guard let apk = Bundle.main.url(forResource: "JH Mirror Companion", withExtension: "apk") else {
            status("The phone app is missing from JH Mirror. Reinstall JH Mirror."); return false
        }
        status("Installing JH Mirror on your phone…")
        let install = command(["-s", serial, "install", "--user", "current", "--no-incremental", "-r", apk.path], timeout: 120)
        guard install.code == 0 && install.output.contains("Success") else {
            connectionLog("Companion install failed: \(install.output.suffix(200))")
            status("Phone app install failed · unlock the phone, then ⚙︎ → Reinstall Phone App")
            return false
        }
        connectionLog("Companion installed")
        prepareCompanion(serial)
        return true
    }

    /// One-time phone permissions, all granted by the authorized ADB shell:
    /// notification access, posting its own status notification, switching Wireless debugging back on
    /// after a restart, opening apps when a Mac notification is clicked, and staying awake in Doze.
    private func prepareCompanion(_ serial: String) {
        let legacy = command(["-s", serial, "shell", "pm", "path", "--user", "current", legacyCompanionPackage], timeout: 5)
        if legacy.output.contains("package:") {
            // Same ports and role as the new companion: it must go before the new one starts.
            _ = command(["-s", serial, "shell", "pm", "uninstall", "--user", "current", legacyCompanionPackage], timeout: 30)
            connectionLog("Replaced the old Android Wireless companion")
        }
        let shell = { (arguments: [String]) in _ = command(["-s", serial, "shell"] + arguments, timeout: 6) }
        shell(["cmd", "notification", "allow_listener", "\(companionPackage)/\(companionPackage).NotificationBridge"])
        shell(["pm", "grant", companionPackage, "android.permission.POST_NOTIFICATIONS"])
        shell(["pm", "grant", companionPackage, "android.permission.WRITE_SECURE_SETTINGS"])
        shell(["pm", "grant", companionPackage, "android.permission.READ_PHONE_STATE"])
        shell(["appops", "set", companionPackage, "SYSTEM_ALERT_WINDOW", "allow"])
        shell(["dumpsys", "deviceidle", "whitelist", "+\(companionPackage)"])
        grantedThisSession = true
    }


    /// Turns the phone app's "Send notifications to Mac" switch on or off.
    func setPhoneNotifications(_ on: Bool, completion: @escaping (Bool) -> Void) {
        commandQueue.async {
            self.stateLock.lock(); let base = self.activeBase; self.stateLock.unlock()
            guard let base else { DispatchQueue.main.async { completion(false) }; return }
            var request = URLRequest(url: URL(string: base + "/settings/notifications?on=\(on ? 1 : 0)")!)
            request.httpMethod = "POST"; request.timeoutInterval = 6
            request.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
            let done = DispatchSemaphore(value: 0)
            var ok = false
            self.session.dataTask(with: request) { _, response, error in
                ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 8)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Sends a notification command to the phone: "open" (same as tapping it), "action" (a button;
    /// `text` fills a Reply field) or "dismiss". Calls back on the main queue with the phone's result.
    func notificationCommand(_ kind: String, key: String, package: String? = nil, index: Int? = nil, text: String? = nil,
                             completion: @escaping (String) -> Void) {
        commandQueue.async {
            self.stateLock.lock(); let base = self.activeBase; self.stateLock.unlock()
            guard let base else { DispatchQueue.main.async { completion("offline") }; return }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
            var query = "key=" + encode(key)
            if let package { query += "&package=" + encode(package) }
            if let index { query += "&index=\(index)" }
            var request = URLRequest(url: URL(string: base + "/notifications/\(kind)?" + query)!)
            request.httpMethod = "POST"; request.timeoutInterval = 6
            request.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
            request.httpBody = Data((text ?? "").utf8)
            let done = DispatchSemaphore(value: 0)
            var result = "offline"
            self.session.dataTask(with: request) { data, response, error in
                if error == nil, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    result = json["result"] as? String ?? "error"
                }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 8)
            connectionLog("Notification \(kind) → \(result)")
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func post(_ base: String, path: String) -> Bool {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = 4
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let complete = DispatchSemaphore(value: 0)
        var ok = false
        session.dataTask(with: request) { _, response, error in
            ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            complete.signal()
        }.resume()
        _ = complete.wait(timeout: .now() + 5)
        return ok
    }

    func sendDeviceReport(_ data: Data) {
        guard data.count <= 20000 else { return }
        worker.async {
            self.stateLock.lock(); let base = self.activeBase; self.stateLock.unlock()
            guard !self.stopped, let base, self.token.count == 64 else { return }
            var request = URLRequest(url: URL(string: base + "/device/status")!)
            request.httpMethod = "POST"; request.timeoutInterval = 3; request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
            self.session.dataTask(with: request).resume()
        }
    }

    /// After a phone restart Android turns Wireless debugging off, but the companion's encrypted
    /// channel comes back by itself. If the screen or auto-copy needs ADB, ask the phone to turn it on.
    private func restoreWirelessDebuggingIfNeeded(_ result: BridgeResponse, base: String) {
        if result.canEnableAdbWifi == false, !grantedThisSession, adbVerified(within: 60), let serial = serial ?? findPhone() {
            prepareCompanion(serial) // one-time permission grant while ADB is up
        }
        // Only acts when the phone itself reports debugging is off, so a short wait is safe.
        guard result.adbWifi == false, result.canEnableAdbWifi == true, adbWanted, !adbVerified(within: 8),
              Date().timeIntervalSince(lastEnableRequest) > 90 else { return }
        lastEnableRequest = Date()
        if post(base, path: "/adb/wifi") {
            connectionLog("Asked the phone to turn Wireless debugging back on")
            status("Turning on Wireless debugging…")
            adbRetry.succeeded(); clearDiscoveryBackoff()
            DispatchQueue.main.async { self.adbDiscovery.refresh() }
        }
    }

    /// One-click reconnect (menu-bar Reconnect): wakes Wireless debugging over the encrypted
    /// channel if needed, rediscovers the phone (adb mDNS, Bonjour, saved address) and, as a last
    /// resort when nothing is connected, restarts adb's discovery. Calls back with the endpoint or nil.
    func reconnectNow(progress: @escaping (String) -> Void, completion: @escaping (String?) -> Void) {
        let say = { (text: String) in DispatchQueue.main.async { progress(text) } }
        DispatchQueue.main.async { self.adbDiscovery.refresh(); self.discovery.refresh() }
        worker.async {
            self.adbRetry.succeeded(); self.lanRetry.succeeded(); self.lanFailures = 0
            self.failures = 0; self.lastEnableRequest = .distantPast
            clearDiscoveryBackoff()
            connectionLog("Reconnect requested")
            if let peer = self.peer {
                self.token = peer.token; self.http.trust(peer.certificateHash)
                var endpoints = self.discovery.endpoints(for: peer.identity)
                if !endpoints.contains(peer.endpoint) { endpoints.append(peer.endpoint) }
                for endpoint in endpoints.prefix(3) {
                    let base = "https://" + endpoint
                    guard let health = self.fetch(base, path: "/health") else { continue }
                    if health.adbWifi == false {
                        if health.canEnableAdbWifi == true, self.post(base, path: "/adb/wifi") {
                            say("Turning on Wireless debugging on the phone…")
                            connectionLog("Reconnect: asked the phone to turn Wireless debugging on")
                            Thread.sleep(forTimeInterval: 3) // adbd starts and advertises its new port
                        } else {
                            say("On the phone: Settings → Developer options → turn on Wireless debugging")
                        }
                    }
                    break
                }
            }
            say("Looking for your phone…")
            var found = findPhone()
            for _ in 0..<4 where found == nil {
                Thread.sleep(forTimeInterval: 1.5)
                DispatchQueue.main.async { self.adbDiscovery.refresh() }
                clearDiscoveryBackoff(); found = findPhone()
            }
            if found == nil, !command(["devices"], timeout: 3).output.contains("\tdevice") {
                // adb's discovery state can go stale; restarting it is safe when nothing is connected.
                say("Restarting phone discovery…")
                connectionLog("Reconnect: restarting adb server")
                _ = command(["kill-server"], timeout: 5)
                _ = command(["start-server"], timeout: 10)
                Thread.sleep(forTimeInterval: 2.5)
                clearDiscoveryBackoff(); found = findPhone()
            }
            if let found {
                self.serial = found
                connectionLog("Reconnect: phone connected")
                DispatchQueue.main.async { self.onPhone?(found) }
            } else {
                connectionLog("Reconnect: phone not reachable over ADB")
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    /// Learns (or re-learns) the phone's Wi-Fi certificate. Accepted only over the
    /// authenticated ADB tunnel, so a LAN impostor can never introduce itself.
    private func learnWifiIdentity(_ result: BridgeResponse) {
        guard let cert = result.lanCertificate.flatMap({ Data(base64Encoded: $0) }), !cert.isEmpty,
              let identity = result.lanIdentity, identity.hasPrefix("AW-"), let lanPort = result.lanPort,
              let serial = self.serial, token.count == 64 else { return }
        let hash = SHA256.hash(data: cert).map { String(format: "%02x", $0) }.joined()
        if let peer, peer.certificateHash == hash, peer.identity == identity, peer.token == token { return }
        let host = serial.split(separator: ":").first.map(String.init) ?? ""
        guard let endpoint = wirelessEndpoint(host + ":\(lanPort)") ?? discovery.endpoints(for: identity).first ?? peer?.endpoint
        else { return }
        let updated = WifiPeer(token: token, certificateHash: hash, identity: identity, endpoint: endpoint)
        do {
            try updated.save()
            connectionLog(peer == nil ? "Wi-Fi channel paired" : "Wi-Fi channel re-paired after phone identity change")
            peer = updated; http.trust(hash)
            lanRetry.succeeded(); lanFailures = 0
        } catch { status("Could not save paired Wi-Fi connection.") }
    }

    func tick() {
        guard !busy, !stopped, !pairingPaused else { return }
        busy = true
        worker.async {
            defer { DispatchQueue.main.async { self.busy = false } }
            let path = self.phoneSession == nil ? "/health" : "/events?after=\(self.cursor)"
            // Prefer the companion's encrypted LAN channel. No ADB command is
            // needed here, so a missing debugging transport cannot stop sync.
            if var peer = self.peer, self.lanRetry.ready() {
                self.token = peer.token
                self.http.trust(peer.certificateHash)
                var endpoints = self.discovery.endpoints(for: peer.identity)
                if !endpoints.contains(peer.endpoint) { endpoints.append(peer.endpoint) }
                for endpoint in endpoints.prefix(3) {
                    let base = "https://" + endpoint
                    if let result = self.fetch(base, path: path) {
                        if self.lanFailures >= 3 { connectionLog("Wi-Fi channel recovered") }
                        self.lanFailures = 0; self.lanRetry.succeeded()
                        if peer.endpoint != endpoint {
                            peer.endpoint = endpoint; try? peer.save(); self.peer = peer
                        }
                        if self.upgradeIfNeeded(result) { return }
                        self.consume(result, base: base, pin: peer.certificateHash)
                        return
                    }
                }
                self.lanFailures += 1
                if self.lanFailures == 3 { connectionLog("Wi-Fi channel unavailable · using ADB with backoff") }
                if self.lanFailures >= 3 { self.lanRetry.failed() }
                // Ride out brief blips without starting ADB work, unless ADB is already up.
                if self.lanFailures < 3 && self.port == nil {
                    self.status("Reconnecting…")
                    return
                }
            }
            if self.port == nil {
                guard self.adbRetry.ready() else { return }
                if !self.attemptedConnection { self.status("Finding your phone…") }
                self.attemptedConnection = true
                guard let serial = findPhone() else {
                    self.adbRetry.failed(); self.files.disconnected()
                    self.restartADBServerIfStuck()
                    self.status("Offline · reconnects automatically")
                    return
                }
                self.serial = serial; self.consecutiveADBFailures = 0
                // Exit 1 with no output just means "not installed"; adb's own failures say "error:".
                let installed = command(["-s", serial, "shell", "pm", "path", "--user", "current", companionPackage])
                guard installed.code != -1, !installed.output.lowercased().contains("error:") else { self.adbRetry.failed(); return }
                if !installed.output.contains("package:") {
                    guard self.installCompanion(serial) else { self.adbRetry.failed(); return }
                } else if !self.grantedThisSession {
                    self.prepareCompanion(serial)
                }
                if self.token.isEmpty {
                    var bytes = [UInt8](repeating: 0, count: 32)
                    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
                    self.token = bytes.map { String(format: "%02x", $0) }.joined()
                }
                let setup = command(["-s", serial, "shell", "am", "broadcast", "-n",
                    "\(companionPackage)/.SetupReceiver", "-a", "\(companionPackage).CONFIGURE",
                    "--es", "token", self.token])
                guard setup.code == 0, setup.output.contains("result=0") else {
                    connectionLog("Companion setup did not confirm a listener: \(setup.output.suffix(120))")
                    self.adbRetry.failed(); return
                }
                let forward = command(["-s", serial, "forward", "tcp:0", "tcp:38475"])
                guard forward.code == 0, let port = Int(forward.output.trimmingCharacters(in: .whitespacesAndNewlines)),
                      port > 0 && port < 65536 else { self.adbRetry.failed(); return }
                self.port = port
                self.adbRetry.succeeded()
                DispatchQueue.main.async { self.onPhone?(serial) }
            }
            guard let port = self.port else { return }
            let base = "http://127.0.0.1:\(port)"
            guard let result = self.fetch(base, path: path) else {
                self.failures += 1
                self.status("Reconnecting…")
                // Give jitter and short Wi-Fi interruptions time to recover.
                // Removing our own forward never disconnects the ADB transport.
                if self.failures >= 6 {
                    if let serial = self.serial { _ = command(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 2) }
                    self.port = nil; self.failures = 0; self.adbRetry.failed()
                    self.files.disconnected()
                }
                return
            }
            self.failures = 0
            if self.upgradeIfNeeded(result) { return }
            self.learnWifiIdentity(result)
            self.consume(result, base: base, pin: nil)
        }
    }

    /// After repeated failures with nothing connected, restart JH Mirror's private adb server
    /// (its discovery or network access can go stale). At most every two minutes.
    private func restartADBServerIfStuck() {
        consecutiveADBFailures += 1
        guard consecutiveADBFailures >= 5, Date().timeIntervalSince(lastServerRestart) > 120,
              !command(["devices"], timeout: 3).output.contains("\tdevice") else { return }
        consecutiveADBFailures = 0; lastServerRestart = Date()
        connectionLog("Restarting the adb server after repeated connection failures")
        _ = command(["kill-server"], timeout: 5)
        DispatchQueue.main.async { self.adbDiscovery.refresh() }
    }

    /// Forgets the Wi-Fi trust so the next ADB connection provisions a fresh token and certificate pin.
    func resetWifiTrust() {
        worker.async {
            try? FileManager.default.removeItem(at: WifiPeer.file)
            self.peer = nil; self.token = ""; self.http.trust(nil)
            self.lanRetry.succeeded(); self.lanFailures = 0
            if let serial = self.serial, let port = self.port {
                _ = command(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 2)
            }
            self.port = nil; self.phoneSession = nil
            connectionLog("Wi-Fi trust reset for re-pairing")
        }
    }

    func phoneSetup(apk: URL?, completion: @escaping (String) -> Void) {
        worker.async {
            guard let serial = self.serial ?? findPhone() else {
                DispatchQueue.main.async { completion("Phone is offline. Turn on Wireless debugging first.") }; return
            }
            _ = apk
            guard self.installCompanion(serial) else {
                DispatchQueue.main.async { completion("Could not install JH Mirror on the phone. Keep it unlocked and try again.") }; return
            }
            // Reinstalling restarts the companion; reconnect with fresh listeners.
            if let port = self.port { _ = command(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 2) }
            self.port = nil; self.phoneSession = nil
            _ = command(["-s", serial, "shell", "am", "start", "--display", "0", "-n", "\(companionPackage)/.MainActivity"])
            DispatchQueue.main.async { completion("JH Mirror is set up on your phone. Notifications, files and clipboard connect automatically.") }
        }
    }

    func choosePhoneFiles(completion: @escaping (String) -> Void) {
        worker.async {
            guard let serial = self.serial ?? findPhone() else {
                DispatchQueue.main.async { completion("Phone offline. Files can be chosen when it reconnects.") }
                return
            }
            let result = command(["-s", serial, "shell", "am", "start", "--display", "0",
                                  "-a", "\(companionPackage).PICK_FILES",
                                  "-n", "\(companionPackage)/.PickFilesActivity"])
            DispatchQueue.main.async {
                completion(result.code == 0 ? "Choose files on your phone · then tap Open" : "Could not open phone file picker. Check Wireless debugging.")
            }
        }
    }

    /// Asks the companion to send the phone's current clipboard (image, file or text) to the Mac clipboard.
    func copyPhoneClipboard(completion: @escaping (String) -> Void) {
        worker.async {
            guard let serial = self.serial ?? findPhone() else {
                DispatchQueue.main.async { completion("Phone offline. On the phone, tap Copy to Mac in the JH Mirror notification.") }
                return
            }
            let result = command(["-s", serial, "shell", "am", "start", "--display", "0",
                                  "-n", "\(companionPackage)/.ClipboardActivity"])
            let ok = result.code == 0 && !result.output.contains("Error")
            DispatchQueue.main.async {
                completion(ok ? "Reading the phone clipboard · it lands on the Mac clipboard in a moment"
                    : "Unlock the phone, then try again (or tap Copy to Mac on the phone).")
            }
        }
    }

    /// Copies Mac files or folders to the phone's Download folder over ADB without overwriting existing names.
    func sendToPhone(_ urls: [URL], progress: @escaping (String) -> Void) {
        pushQueue.async {
            guard let serial = self.serial ?? findPhone() else {
                DispatchQueue.main.async { progress("Phone offline. Turn on Wireless debugging to send files.") }; return
            }
            var sent = 0, failed = 0
            for (index, url) in urls.enumerated() {
                let name = FileTransferClient.safeName(url.lastPathComponent)
                let ext = (name as NSString).pathExtension
                let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
                var target = "/sdcard/Download/" + name
                for number in 2...1000 {
                    let exists = command(["-s", serial, "shell", "test", "-e", phoneShellQuote(target), "&&", "echo", "EXISTS"], timeout: 5)
                    guard exists.output.contains("EXISTS") else { break }
                    target = "/sdcard/Download/" + stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext)
                }
                DispatchQueue.main.async { progress("Sending \(index + 1)/\(urls.count) to phone · \(name)") }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                // Allow roughly 2 MB/s plus a margin; folders get a generous fixed limit.
                let timeout = max(60, Double(size) / 2_000_000 + 30)
                let push = command(["-s", serial, "push", url.path, target], timeout: url.hasDirectoryPath ? 1800 : timeout)
                if push.code == 0 { sent += 1 } else { failed += 1; connectionLog("Push failed: \(push.output.suffix(160))") }
            }
            DispatchQueue.main.async {
                progress(failed == 0 ? "Sent \(sent) item(s) to phone · Download folder"
                    : "Sent \(sent), failed \(failed). Check Wireless debugging and phone storage.")
            }
        }
    }

    func reconnect(_ endpoint: String) {
        worker.async {
            if let serial = self.serial, let port = self.port {
                _ = command(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 2)
            }
            self.serial = endpoint; self.port = nil; self.failures = 0
            self.attemptedConnection = false; self.adbRetry.succeeded()
        }
    }

    func stop() {
        pathMonitor.cancel()
        discovery.stop()
        adbDiscovery.stop()
        files.stop()
        stopped = true
        timer?.invalidate()
        worker.async {
            if let serial = self.serial, let port = self.port {
                _ = command(["-s", serial, "forward", "--remove", "tcp:\(port)"])
            }
            self.session.invalidateAndCancel()
        }
    }
}
