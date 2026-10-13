import Foundation

private let discoveryLock = NSLock()
private var failedEndpoints: [String: Date] = [:]
private var verifiedAt: [String: Date] = [:]

func connectionCandidates(devices: String, services: String, previous: String?) -> [String] {
    let connected = devices.split(separator: "\n").compactMap { line -> String? in
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        return fields.count >= 2 && fields[1] == "device" ? String(fields[0]) : nil
    }
    var advertised: [String] = []
    for line in services.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if fields.first?.hasPrefix("adb-\(phoneSerial)-") == true,
           let service = fields.firstIndex(of: "_adb-tls-connect._tcp"), service + 1 < fields.count,
           let address = wirelessEndpoint(fields[service + 1]) { advertised.append(address) }
    }
    // A verified live transport wins over stale mDNS advertisements. The saved
    // endpoint is retried even when discovery is temporarily unavailable.
    var ordered = [String]()
    if let previous, connected.contains(previous) { ordered.append(previous) }
    ordered += connected.filter { $0.hasPrefix("adb-\(phoneSerial)-") }
    ordered += connected.filter { wirelessEndpoint($0) != nil }
    ordered += advertised
    if let previous { ordered.append(previous) }
    var seen = Set<String>()
    return ordered.filter { seen.insert($0).inserted }
}

func findPhone() -> String? {
    discoveryLock.lock(); defer { discoveryLock.unlock() }
    _ = command(["start-server"], timeout: 3)
    let devices = command(["devices"], timeout: 3).output
    let previous = UserDefaults.standard.string(forKey: "verifiedPhoneEndpoint")
    // Try already-connected candidates before asking mDNS. This avoids waiting
    // for discovery or accidentally creating a duplicate TLS transport.
    let connected = connectionCandidates(devices: devices, services: "", previous: nil)
    var candidates = connected
    if let previous, let index = candidates.firstIndex(of: previous) {
        candidates.remove(at: index); candidates.insert(previous, at: 0)
    }
    func verify(_ serial: String, connected: Bool) -> Bool {
        if let retry = failedEndpoints[serial], retry > Date() { return false }
        if connected, let time = verifiedAt[serial], Date().timeIntervalSince(time) < 20 { return true }
        if !connected {
            let offline = devices.split(separator: "\n").contains { line in
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                return fields.count >= 2 && fields[0] == serial && fields[1] == "offline"
            }
            if offline { _ = command(["disconnect", serial], timeout: 2) }
            if command(["connect", serial], timeout: 3).code != 0 {
                failedEndpoints[serial] = Date().addingTimeInterval(20); return false
            }
        }
        let identity = command(["-s", serial, "shell", "getprop", "ro.serialno"], timeout: 4)
        if identity.code == 0 && identity.output.trimmingCharacters(in: .whitespacesAndNewlines) == phoneSerial {
            verifiedAt[serial] = Date(); failedEndpoints.removeValue(forKey: serial)
            UserDefaults.standard.set(serial, forKey: "verifiedPhoneEndpoint"); return true
        }
        failedEndpoints[serial] = Date().addingTimeInterval(20)
        return false // A failed probe never disconnects a live transport.
    }
    for serial in candidates.prefix(3) { if verify(serial, connected: true) { return serial } }
    let services = command(["mdns", "services"], timeout: 3).output
    for serial in connectionCandidates(devices: devices, services: services, previous: previous).filter({ !candidates.contains($0) }).prefix(3) {
        if verify(serial, connected: false) { return serial }
    }
    return nil
}
