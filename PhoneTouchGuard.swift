import Foundation

/// Main-thread lifecycle, serialized ADB operations. A dead Mac can leave touch blocked for at most 8 s.
final class PhoneTouchGuard {
    enum Preparation { case guarded, screenOn, unavailable }
    private let queue = DispatchQueue(label: "jhmirror.touch-guard")
    private var timer: Timer?
    private var generation = UUID()
    private var peer: String?
    private var lease: String?
    private var renewing = false
    private(set) var failureMessage = "Touch protection could not connect. Reconnect the paired phone and try again."
    var onReleased: ((Bool, String) -> Void)?

    private func request(_ operation: String, serial: String, token: String) -> String {
        var args = ["-s", serial, "shell", "am", "broadcast", "--user", "current",
            "-n", "com.johirulhoqakash.jhmirror/.SetupReceiver", "-a", "com.johirulhoqakash.jhmirror.TOUCH_GUARD",
            "--es", "operation", operation]
        if !token.isEmpty { args += ["--es", "lease", token] }
        let result = command(args, timeout: 3)
        guard result.code == 0 else { return "unavailable" }
        for value in ["guarded", "ready", "preparing", "unsupported", "permission-denied", "service-disconnected", "service-disabled", "filter-unavailable", "touch-exploration", "released", "black", "screen-on"] {
            if result.output.contains("data=\"\(value)\"") { return value }
        }
        return "unavailable"
    }

    private func awaitService(serial: String, token: String) -> String {
        var status = "service-disconnected"
        for _ in 0..<12 {
            status = request("status", serial: serial, token: token)
            if !["service-disconnected", "preparing"].contains(status) { return status }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return status
    }

    private func explanation(_ result: String) -> String {
        let reason: String
        switch result {
        case "unsupported": reason = "Touch protection requires Android 14 or later."
        case "permission-denied", "service-disabled": reason = "Android has disabled JH Mirror’s accessibility access. Unlock the phone, open Settings → Accessibility → Installed apps → JH Mirror touch guard and enable it."
        case "service-disconnected", "preparing": reason = "Android could not reconnect JH Mirror’s touch service after recovery. Unlock the phone and toggle JH Mirror touch guard in Accessibility settings, then retry."
        case "touch-exploration": reason = "Touch exploration is active on the phone, so Android cannot apply this touch filter. Keep your accessibility controls available and leave the display on."
        case "filter-unavailable": reason = "Android refused the physical-touch filter. Re-enable JH Mirror touch guard in Accessibility settings and retry."
        default: reason = "The touch-service connection did not answer. Reconnect the paired phone and try again."
        }
        return reason + " The phone display was left on."
    }

    func begin(serial: String, restoringIntent: Bool = false, completion: @escaping (Preparation) -> Void) {
        stop()
        let attempt = UUID(); generation = attempt
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        peer = serial; lease = token
        queue.async { [self] in
            if restoringIntent && self.request("state", serial: serial, token: token) == "screen-on" {
                DispatchQueue.main.async {
                    guard self.generation == attempt else { completion(.unavailable); return }
                    self.peer = nil; self.lease = nil; completion(.screenOn)
                }
                return
            }
            let prepared = self.request("prepare", serial: serial, token: token)
            var result = prepared
            if ["preparing", "service-disconnected"].contains(result) { result = self.awaitService(serial: serial, token: token) }
            if ["service-disconnected", "preparing"].contains(result) {
                connectionLog("Touch guard recovering an enabled service that did not bind")
                result = self.request("repair", serial: serial, token: token)
                if result == "preparing" { result = self.awaitService(serial: serial, token: token) }
            }
            if result == "ready" { result = self.request("begin", serial: serial, token: token) }
            let success = result == "guarded", failure = self.explanation(result)
            if !success { _ = self.request("stop", serial: serial, token: token) }
            connectionLog("Touch guard prepare=\(prepared) result=\(result)")
            DispatchQueue.main.async {
                guard self.generation == attempt else { completion(.unavailable); return }
                if success {
                    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.renew() }
                    RunLoop.main.add(timer, forMode: .common); self.timer = timer
                } else { self.peer = nil; self.lease = nil; self.failureMessage = failure }
                completion(success ? .guarded : .unavailable)
            }
        }
    }

    private func renew() {
        guard !renewing, let peer, let lease else { return }
        renewing = true
        let attempt = generation
        queue.async {
            let result = self.request("renew", serial: peer, token: lease)
            DispatchQueue.main.async {
                guard self.generation == attempt else { return }
                self.renewing = false
                if result != "guarded" {
                    connectionLog("Touch guard renewal ended: \(result)")
                    self.stop()
                    let screenOn = result == "screen-on"
                    self.onReleased?(screenOn, screenOn ? "Phone display turned on · touch restored"
                        : "Touch protection ended · phone display stays off. Use the power button to turn it on.")
                }
            }
        }
    }

    func stop() {
        generation = UUID(); timer?.invalidate(); timer = nil; renewing = false
        if let peer, let lease { queue.async { _ = self.request("stop", serial: peer, token: lease) } }
        peer = nil; lease = nil
    }
    func allowScreenOn(serial: String, completion: @escaping (Bool) -> Void = { _ in }) {
        stop()
        queue.async {
            let ready = self.request("screen-on", serial: serial, token: "") == "screen-on"
            DispatchQueue.main.async { completion(ready) }
        }
    }
}
