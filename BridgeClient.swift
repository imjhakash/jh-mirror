import Foundation
import Network
import Security
import CryptoKit

let companionPackage = "local.androidwireless.bridge"
/// Companion protocol required by this Mac build. Older companions are upgraded over ADB.
let requiredProtocol = 5

struct PhoneEvent: Decodable {
    let type: String
    let key: String
    let app: String?
    let title: String?
    let body: String?
    let time: Double?
    let packageName: String?
    var icon: String?
    enum CodingKeys: String, CodingKey {
        case type, key, app, title, body, time, icon
        case packageName = "package"
    }
}

struct BridgeResponse: Decodable {
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
}

private final class ResponseBox {
    private let lock = NSLock()
    private var value: BridgeResponse?
    func put(_ response: BridgeResponse?) { lock.lock(); defer { lock.unlock() }; value = response }
    func get() -> BridgeResponse? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Quotes one argument for the phone's /system/bin/sh.
func phoneShellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

final class BridgeClient {
    var pairingPaused = false
    let files = FileTransferClient()
    var onStatus: ((String) -> Void)?
    var onEvents: (([PhoneEvent]) -> Void)?
    var onPhone: ((String) -> Void)?
    private let worker = DispatchQueue(label: "local.androidwireless.notifications")
    /// Mac → phone transfers can take minutes; they must not stall notification polling.
    private let pushQueue = DispatchQueue(label: "local.androidwireless.push", qos: .utility)
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

    func start() {
        discovery.start()
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
        files.tick(baseURL: base, token: token, pin: pin)
        let isNewSession = phoneSession != result.session
        phoneSession = result.session
        cursor = result.sequence
        if let icons = result.icons { self.icons.merge(icons) { _, new in new } }
        status(!result.connected ? "Enable Notification access for Android Wireless on your phone."
            : !result.enabled ? "Notification sharing is paused on the phone."
            : base.hasPrefix("https:") ? "Encrypted Wi-Fi connected · notifications and files independent of mirror"
            : "Phone sync connected over ADB · Wi-Fi channel retries automatically")
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
              let apk = Bundle.main.url(forResource: "Android Wireless Companion", withExtension: "apk"),
              let serial = serial ?? findPhone() else { return false }
        attemptedUpgrade = true; self.serial = serial
        status("Updating the phone companion…")
        let install = command(["-s", serial, "install", "--no-incremental", "-r", apk.path], timeout: 90)
        guard install.code == 0 && install.output.contains("Success") else {
            connectionLog("Companion upgrade failed: \(install.output.suffix(200))"); return false
        }
        connectionLog("Companion upgraded to protocol \(requiredProtocol)")
        exemptFromBatteryOptimization(serial)
        // The package restart drops the old listeners; bring them back with the same trust.
        _ = command(["-s", serial, "shell", "am", "broadcast", "-n", "\(companionPackage)/.SetupReceiver",
                     "-a", "\(companionPackage).CONFIGURE", "--es", "token", token])
        if let port { _ = command(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 2) }
        port = nil; phoneSession = nil
        return true
    }

    /// Keeps Android from suspending the companion's network access in Doze.
    private func exemptFromBatteryOptimization(_ serial: String) {
        _ = command(["-s", serial, "shell", "dumpsys", "deviceidle", "whitelist", "+\(companionPackage)"], timeout: 5)
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
                    self.status("Wi-Fi briefly interrupted · keeping the session and retrying")
                    return
                }
            }
            if self.port == nil {
                guard self.adbRetry.ready() else { return }
                if !self.attemptedConnection { self.status("Finding your paired Samsung…") }
                self.attemptedConnection = true
                guard let serial = findPhone() else {
                    self.adbRetry.failed(); self.files.disconnected()
                    self.status("Waiting for the phone on Wi-Fi · reconnecting automatically")
                    return
                }
                self.serial = serial
                let installed = command(["-s", serial, "shell", "pm", "path", companionPackage])
                guard installed.code == 0 else { self.adbRetry.failed(); return }
                guard installed.output.contains("package:") else {
                    self.adbRetry.failed(); self.status("Companion app missing. Click Phone Setup to install it."); return
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
                self.exemptFromBatteryOptimization(serial)
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
                self.status("Sync temporarily interrupted · retrying without restarting the screen")
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
            guard let apk else {
                DispatchQueue.main.async { completion("Companion APK is missing from the Mac app.") }; return
            }
            let install = command(["-s", serial, "install", "--no-incremental", "-r", apk.path], timeout: 90)
            guard install.code == 0, install.output.contains("Success") else {
                DispatchQueue.main.async { completion("Could not install companion: \(install.output.suffix(300))") }; return
            }
            self.exemptFromBatteryOptimization(serial)
            // Reinstalling restarts the companion; reconnect with fresh listeners.
            if let port = self.port { _ = command(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 2) }
            self.port = nil; self.phoneSession = nil
            _ = command(["-s", serial, "shell", "am", "start", "--display", "0", "-n", "\(companionPackage)/.MainActivity"])
            DispatchQueue.main.async { completion("On your phone, tap Enable notification access, then allow Android Wireless.") }
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
                                  "-n", "\(companionPackage)/.MainActivity"])
            DispatchQueue.main.async {
                completion(result.code == 0 ? "Choose files on your phone · then tap Open" : "Could not open phone file picker. Check Wireless debugging.")
            }
        }
    }

    /// Asks the companion to send the phone's current clipboard (image, file or text) to the Mac clipboard.
    func copyPhoneClipboard(completion: @escaping (String) -> Void) {
        worker.async {
            guard let serial = self.serial ?? findPhone() else {
                DispatchQueue.main.async { completion("Phone offline. On the phone, tap Copy to Mac in the Android Wireless notification.") }
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
