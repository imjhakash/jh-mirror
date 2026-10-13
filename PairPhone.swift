import AppKit

func wirelessEndpoint(_ raw: String) -> String? {
    let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let port = UInt16(parts[1]), port > 0 else { return nil }
    let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return nil }
    var address: [UInt8] = []
    for part in octets {
        guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }), let value = UInt8(part) else { return nil }
        address.append(value)
    }
    guard address[0] == 10 || (address[0] == 172 && (16...31).contains(address[1]))
        || (address[0] == 192 && address[1] == 168) || (address[0] == 169 && address[1] == 254) else { return nil }
    return address.map(String.init).joined(separator: ".") + ":\(port)"
}

func discoveredWirelessEndpoints(_ service: String) -> [String] {
    var addresses: [String] = []
    for line in command(["mdns", "services"], timeout: 4).output.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.first?.hasPrefix("adb-\(phoneSerial)-") == true,
              let index = fields.firstIndex(of: service), index + 1 < fields.count,
              let endpoint = wirelessEndpoint(fields[index + 1]), !addresses.contains(endpoint) else { continue }
        addresses.append(endpoint)
    }
    return addresses
}

final class PairPhoneWindow: NSWindowController, NSWindowDelegate {
    var onBusy: ((Bool) -> Void)?
    var onConnected: ((String) -> Void)?
    /// Called after a new ADB pairing succeeds, before connecting.
    var onPaired: (() -> Void)?
    private let pairingAddress = NSTextField()
    private let code = NSSecureTextField()
    private let connectAddress = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let pairButton = NSButton()
    private let connectButton = NSButton()
    private let detectButton = NSButton()
    private let worker = DispatchQueue(label: "local.androidwireless.pairing", qos: .userInitiated)
    private var working = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 430),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair Phone"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        label("Pair your Samsung", x: 24, y: 375, width: 415, height: 28, size: 22, bold: true)
        label("On your phone: Developer options → Wireless debugging → Pair device with pairing code. Keep that popup open.",
              x: 24, y: 313, width: 422, height: 56, size: 13)
        label("Pairing popup · IP address & port", x: 24, y: 281, width: 400, height: 22, size: 12)
        pairingAddress.placeholderString = "192.168.0.159:37283"
        pairingAddress.frame = NSRect(x: 24, y: 251, width: 302, height: 26)
        pairingAddress.setAccessibilityLabel("Pairing IP address and port")
        window.contentView!.addSubview(pairingAddress)
        detectButton.title = "Auto-detect"; detectButton.target = self; detectButton.action = #selector(detect)
        detectButton.bezelStyle = .rounded; detectButton.frame = NSRect(x: 335, y: 247, width: 111, height: 32)
        window.contentView!.addSubview(detectButton)
        label("Wi-Fi pairing code · 6 digits", x: 24, y: 219, width: 400, height: 22, size: 12)
        code.placeholderString = "6-digit code"
        code.frame = NSRect(x: 24, y: 189, width: 192, height: 26)
        code.setAccessibilityLabel("Wi-Fi pairing code")
        window.contentView!.addSubview(code)
        pairButton.title = "Pair Phone"; pairButton.target = self; pairButton.action = #selector(pair)
        pairButton.bezelStyle = .rounded; pairButton.frame = NSRect(x: 232, y: 185, width: 214, height: 32)
        window.contentView!.addSubview(pairButton)
        label("Main Wireless debugging screen · connection IP:port (optional)",
              x: 24, y: 151, width: 425, height: 24, size: 12)
        connectAddress.placeholderString = "For an already-paired phone, enter its connection IP:port"
        connectAddress.frame = NSRect(x: 24, y: 121, width: 302, height: 26)
        connectAddress.setAccessibilityLabel("Connection IP address and port")
        window.contentView!.addSubview(connectAddress)
        connectButton.title = "Connect"; connectButton.target = self; connectButton.action = #selector(connect)
        connectButton.bezelStyle = .rounded; connectButton.frame = NSRect(x: 335, y: 117, width: 111, height: 32)
        window.contentView!.addSubview(connectButton)
        status.font = .systemFont(ofSize: 12)
        status.frame = NSRect(x: 24, y: 25, width: 422, height: 74)
        status.stringValue = "Pair once. Later, keep Wireless debugging on; the app reconnects automatically. Pairing and connection ports are different."
        window.contentView!.addSubview(status)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, size: CGFloat, bold: Bool = false) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        label.frame = NSRect(x: x, y: y, width: width, height: height)
        window!.contentView!.addSubview(label)
    }
    func open() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        detect()
    }
    func windowWillClose(_ notification: Notification) { code.stringValue = "" }
    private func busy(_ value: Bool) {
        working = value
        pairButton.isEnabled = !value; connectButton.isEnabled = !value; detectButton.isEnabled = !value
        pairingAddress.isEnabled = !value; code.isEnabled = !value; connectAddress.isEnabled = !value
        window?.standardWindowButton(.closeButton)?.isEnabled = !value
        onBusy?(value)
    }
    @objc private func detect() {
        guard !working else { return }
        detectButton.isEnabled = false
        worker.async {
            let addresses = discoveredWirelessEndpoints("_adb-tls-pairing._tcp")
            DispatchQueue.main.async {
                guard !self.working else { return }
                self.detectButton.isEnabled = true
                if let address = addresses.first {
                    self.pairingAddress.stringValue = address
                    self.status.stringValue = "Pairing popup detected. Enter its current 6-digit code, then click Pair Phone."
                } else {
                    self.status.stringValue = "Open Pair device with pairing code on your phone, then Auto-detect. You can also enter the popup's IP:port manually."
                }
            }
        }
    }
    @objc private func pair() {
        guard let address = wirelessEndpoint(pairingAddress.stringValue) else {
            status.stringValue = "Enter the pairing popup's local IP:port, for example 192.168.0.159:37283."; return
        }
        let value = code.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 6, value.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            status.stringValue = "Enter the current 6-digit Wi-Fi pairing code. Keep the phone popup open."; return
        }
        let manual = connectAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard manual.isEmpty || wirelessEndpoint(manual) != nil else {
            status.stringValue = "The optional connection field also needs a local IP:port."; return
        }
        code.stringValue = ""; busy(true); status.stringValue = "Pairing with your phone…"
        worker.async {
            let result = command(["pair", address, value], timeout: 25)
            guard result.code == 0, result.output.contains("Successfully paired") else {
                DispatchQueue.main.async {
                    self.busy(false)
                    self.status.stringValue = "Pairing failed. Keep the pairing popup open and use its current code/IP:port. \(result.output.prefix(160))"
                }
                return
            }
            DispatchQueue.main.async { self.onPaired?() }
            let connected = self.connectPhone(manual.isEmpty ? nil : wirelessEndpoint(manual))
            DispatchQueue.main.async {
                self.busy(false)
                if let connected {
                    self.status.stringValue = "Paired and connected. Screen, notifications and file sync are starting."
                    self.onConnected?(connected)
                } else {
                    self.status.stringValue = "Paired successfully. Close the phone's pairing popup; reconnecting automatically. If needed, enter the main Wireless debugging IP:port and click Connect."
                }
            }
        }
    }
    @objc private func connect() {
        let raw = connectAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty || wirelessEndpoint(raw) != nil else {
            status.stringValue = "Use the main Wireless debugging screen's IP:port, not its pairing popup port."; return
        }
        busy(true); status.stringValue = "Connecting your paired phone…"
        worker.async {
            let serial = self.connectPhone(raw.isEmpty ? nil : wirelessEndpoint(raw))
            DispatchQueue.main.async {
                self.busy(false)
                if let serial { self.status.stringValue = "Phone connected."; self.onConnected?(serial) }
                else { self.status.stringValue = "Phone unavailable. Keep Wireless debugging on and both devices on the same Wi-Fi. Enter the main screen's current IP:port or try Auto-detect with its pairing popup." }
            }
        }
    }
    private func connectPhone(_ address: String?) -> String? {
        if let address {
            let state = command(["-s", address, "get-state"], timeout: 2)
            if state.output.contains("offline") { _ = command(["disconnect", address], timeout: 2) }
            guard command(["connect", address], timeout: 8).code == 0 else { return nil }
            let identity = command(["-s", address, "shell", "getprop", "ro.serialno"], timeout: 5)
            guard identity.code == 0, identity.output.trimmingCharacters(in: .whitespacesAndNewlines) == phoneSerial else { return nil }
            UserDefaults.standard.set(address, forKey: "verifiedPhoneEndpoint")
            return address
        }
        return findPhone()
    }
}
