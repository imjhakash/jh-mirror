import Foundation
import Security
import CryptoKit
import Darwin

struct WifiPeer: Codable {
    let token: String
    let certificateHash: String
    let identity: String
    var endpoint: String

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Android Wireless", isDirectory: true)
    static let file = directory.appendingPathComponent("paired-wifi.json")
    static func load() -> WifiPeer? {
        guard let bytes = try? Data(contentsOf: file), let peer = try? JSONDecoder().decode(Self.self, from: bytes),
              peer.token.count == 64, peer.certificateHash.count == 64, peer.identity.hasPrefix("AW-"),
              wirelessEndpoint(peer.endpoint) != nil else { return nil }
        return peer
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
}

/// No redirects, cookies or implicit trust. LAN certificates must exactly match
/// the certificate learned from the already-paired ADB connection.
final class PairedHTTP: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var pin: String?
    func trust(_ hash: String?) { lock.lock(); pin = hash; lock.unlock() }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.lock(); let expected = pin; lock.unlock()
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let expected,
              SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map({ String(format: "%02x", $0) }).joined() == expected
        else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class WifiDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private let lock = NSLock()
    private var resolved: [String: [String]] = [:]
    private var timer: Timer?
    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_androidwireless._tcp.", inDomain: "local.")
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            for service in self?.services ?? [] { service.resolve(withTimeout: 5) }
        }
    }
    func endpoints(for identity: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return resolved.filter { $0.key == identity || $0.key.hasPrefix(identity + " (") }.flatMap(\.value)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        lock.lock(); resolved.removeValue(forKey: service.name); lock.unlock()
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        var addresses: [String] = []
        for data in sender.addresses ?? [] {
            data.withUnsafeBytes { buffer in
                guard buffer.count >= MemoryLayout<sockaddr_in>.size,
                      buffer.load(as: sockaddr.self).sa_family == sa_family_t(AF_INET) else { return }
                var address = buffer.load(as: sockaddr_in.self).sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil,
                   let endpoint = wirelessEndpoint(String(cString: text) + ":\(sender.port)") { addresses.append(endpoint) }
            }
        }
        lock.lock(); resolved[sender.name] = addresses; lock.unlock()
    }
    func stop() {
        timer?.invalidate(); browser.stop()
        for service in services { service.stop() }
    }
}

struct RetryGate {
    private(set) var failures = 0
    private(set) var next = Date.distantPast
    mutating func failed(now: Date = Date()) {
        failures += 1
        next = now.addingTimeInterval(min(30, pow(2, Double(min(failures, 5)))))
    }
    mutating func succeeded() { failures = 0; next = .distantPast }
    func ready(now: Date = Date()) -> Bool { now >= next }
}
