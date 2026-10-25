import AppKit
import CoreImage

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

/// Endpoints adb's mDNS sees for `service`. Before a phone is paired any phone qualifies;
/// afterwards only the paired one. `named` narrows to one exact service instance (QR pairing).
func discoveredWirelessEndpoints(_ service: String, named: String? = nil) -> [String] {
    var addresses: [String] = []
    let prefix = phoneSerial.isEmpty ? "adb-" : "adb-\(phoneSerial)-"
    for line in command(["mdns", "services"], timeout: 4).output.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let name = fields.first, named.map({ name == $0 }) ?? name.hasPrefix(prefix),
              let index = fields.firstIndex(of: service), index + 1 < fields.count,
              let endpoint = wirelessEndpoint(fields[index + 1]), !addresses.contains(endpoint) else { continue }
        addresses.append(endpoint)
    }
    return addresses
}

/// The phone's serial from `adb pair` output: "Successfully paired to … [guid=adb-SERIAL-xxxxxx]".
func pairedSerial(from output: String) -> String? {
    guard output.contains("Successfully paired"), let range = output.range(of: "guid=adb-") else { return nil }
    let guid = output[range.upperBound...].prefix { $0 != "]" && !$0.isWhitespace }
    guard let dash = guid.lastIndex(of: "-"), dash > guid.startIndex else { return nil }
    let serial = String(guid[..<dash])
    return serial.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) ? serial : nil
}

/// The text Android's "Pair device with QR code" scanner expects (same format Android Studio uses).
func adbPairingQRText(name: String, password: String) -> String { "WIFI:T:ADB;S:\(name);P:\(password);;" }

func authorizedUSBDevices(_ output: String) -> [String] {
    output.split(separator: "\n").compactMap { line in
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2, parts[1] == "device" else { return nil }
        let serial = String(parts[0])
        guard serial.count <= 128, !serial.hasPrefix("adb-"), !serial.hasPrefix("emulator-"),
              serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        return serial
    }
}

/// Remembers which phone JH Mirror is paired with.
func setPairedPhone(_ serial: String) { UserDefaults.standard.set(serial, forKey: "pairedPhoneSerial") }

func randomToken(_ length: Int) -> String {
    let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
}

final class PairPhoneWindow: NSWindowController, NSWindowDelegate {
    var onBusy: ((Bool) -> Void)?
    var onConnected: ((String) -> Void)?
    /// Called after a new ADB pairing succeeds, before connecting.
    var onPaired: (() -> Void)?
    private let qrImage = NSImageView()
    private let qrStatus = NSTextField(wrappingLabelWithString: "")
    private let pairingAddress = NSTextField()
    private let code = NSSecureTextField()
    private let connectAddress = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let pairButton = NSButton()
    private let connectButton = NSButton()
    private let detectButton = NSButton()
    private let usbButton = NSButton()
    private let worker = DispatchQueue(label: "com.johirulhoqakash.jhmirror.pairing", qos: .userInitiated)
    private let pairingBrowser = WifiDiscovery(type: "_adb-tls-pairing._tcp.")
    private var browsing = false
    private var qrName = ""
    private var qrPassword = ""
    private var qrTimer: Timer?
    private var qrSearching = false
    private var working = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 690),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair your phone · JH Mirror"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        label("Pair your phone", x: 28, y: 636, width: 460, height: 30, size: 24, bold: true)
        label("Wireless pairing: Android 11+. USB: Android 8+. Device Check explains which features this phone supports.",
              x: 28, y: 590, width: 464, height: 40, size: 13, secondary: true)
        label("1  On the phone open Settings → Developer options → Wireless debugging and turn it on.\n2  Tap “Pair device with QR code” and scan this code.",
              x: 28, y: 538, width: 464, height: 46, size: 13)
        qrImage.frame = NSRect(x: 155, y: 322, width: 210, height: 210)
        qrImage.imageScaling = .scaleProportionallyUpOrDown
        qrImage.wantsLayer = true
        qrImage.layer?.backgroundColor = NSColor.white.cgColor
        qrImage.layer?.cornerRadius = 12
        qrImage.setAccessibilityLabel("Pairing QR code for Android Wireless debugging")
        window.contentView!.addSubview(qrImage)
        qrStatus.alignment = .center
        qrStatus.font = .systemFont(ofSize: 12)
        qrStatus.textColor = .secondaryLabelColor
        qrStatus.frame = NSRect(x: 28, y: 280, width: 464, height: 34)
        window.contentView!.addSubview(qrStatus)
        label("No Developer options? Settings → About phone → Software information → tap Build number 7 times.",
              x: 28, y: 248, width: 464, height: 30, size: 11, secondary: true)
        let separator = NSBox(frame: NSRect(x: 28, y: 238, width: 464, height: 1)); separator.boxType = .separator
        window.contentView!.addSubview(separator)
        label("Or pair with a code: tap “Pair device with pairing code” on the phone.", x: 28, y: 206, width: 464, height: 22, size: 12)
        pairingAddress.placeholderString = "Pairing IP:port, e.g. 192.168.0.159:37283"
        pairingAddress.frame = NSRect(x: 28, y: 176, width: 300, height: 26)
        pairingAddress.setAccessibilityLabel("Pairing IP address and port")
        window.contentView!.addSubview(pairingAddress)
        detectButton.title = "Auto-detect"; detectButton.target = self; detectButton.action = #selector(detect)
        detectButton.bezelStyle = .rounded; detectButton.frame = NSRect(x: 336, y: 172, width: 156, height: 32)
        window.contentView!.addSubview(detectButton)
        code.placeholderString = "6-digit code"
        code.frame = NSRect(x: 28, y: 140, width: 300, height: 26)
        code.setAccessibilityLabel("Wi-Fi pairing code")
        window.contentView!.addSubview(code)
        pairButton.title = "Pair with code"; pairButton.target = self; pairButton.action = #selector(pair)
        pairButton.bezelStyle = .rounded; pairButton.frame = NSRect(x: 336, y: 136, width: 156, height: 32)
        window.contentView!.addSubview(pairButton)
        connectAddress.placeholderString = "Advanced: already paired phone's IP:port"
        connectAddress.frame = NSRect(x: 28, y: 100, width: 300, height: 26)
        connectAddress.setAccessibilityLabel("Connection IP address and port")
        window.contentView!.addSubview(connectAddress)
        connectButton.title = "Connect"; connectButton.target = self; connectButton.action = #selector(connect)
        connectButton.bezelStyle = .rounded; connectButton.frame = NSRect(x: 336, y: 96, width: 156, height: 32)
        window.contentView!.addSubview(connectButton)
        status.font = .systemFont(ofSize: 12)
        status.frame = NSRect(x: 28, y: 20, width: 464, height: 66)
        status.stringValue = "The pairing and connection ports differ; JH Mirror finds both automatically."
        window.contentView!.addSubview(status)
        window.setContentSize(NSSize(width: 520, height: 760))
        for view in window.contentView!.subviews { view.frame.origin.y += 70 }
        usbButton.title = "Use USB-connected phone"; usbButton.bezelStyle = .rounded; usbButton.target = self; usbButton.action = #selector(connectUSB)
        usbButton.frame = NSRect(x: 28, y: 20, width: 464, height: 32); window.contentView!.addSubview(usbButton)
        label("Older Android? Connect USB, enable USB debugging and approve this Mac on the phone.", x: 28, y: 54, width: 464, height: 28, size: 11, secondary: true)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, size: CGFloat,
                       bold: Bool = false, secondary: Bool = false) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if secondary { label.textColor = .secondaryLabelColor }
        label.frame = NSRect(x: x, y: y, width: width, height: height)
        window!.contentView!.addSubview(label)
    }
    func open() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !browsing { pairingBrowser.start(); browsing = true }
        newQRCode()
        qrTimer?.invalidate()
        qrTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.lookForQRScan() }
    }
    func windowWillClose(_ notification: Notification) {
        code.stringValue = ""
        qrTimer?.invalidate(); qrTimer = nil
        qrName = ""; qrPassword = "" // a fresh code next time
    }

    // MARK: QR pairing

    private func newQRCode() {
        qrName = "jhmirror-" + randomToken(6)
        qrPassword = randomToken(12)
        qrImage.image = qrCodeImage(adbPairingQRText(name: qrName, password: qrPassword))
        qrStatus.stringValue = "Waiting for your phone to scan…"
    }

    private func qrCodeImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.samplingNearest() else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let padded = scaled.transformed(by: CGAffineTransform(translationX: 32, y: 32))
            .composited(over: CIImage(color: .white).cropped(to: scaled.extent.insetBy(dx: -32, dy: -32).offsetBy(dx: 32, dy: 32)))
        let rep = NSCIImageRep(ciImage: padded)
        let image = NSImage(size: rep.size); image.addRepresentation(rep)
        return image
    }

    /// After the phone scans the code it advertises a pairing service named after it; pair with it.
    private func lookForQRScan() {
        guard !working, !qrSearching, !qrName.isEmpty else { return }
        qrSearching = true
        let name = qrName, password = qrPassword
        let viaBonjour = pairingBrowser.endpoints(prefix: name)
        worker.async {
            let found = viaBonjour.first ?? discoveredWirelessEndpoints("_adb-tls-pairing._tcp", named: name).first
            DispatchQueue.main.async {
                self.qrSearching = false
                guard let found, !self.working, name == self.qrName else { return }
                self.qrStatus.stringValue = "Phone found · pairing…"
                self.runPairing(address: found, password: password, manual: nil)
            }
        }
    }

    // MARK: Shared pairing flow

    private func busy(_ value: Bool) {
        working = value
        pairButton.isEnabled = !value; connectButton.isEnabled = !value; detectButton.isEnabled = !value
        usbButton.isEnabled = !value
        pairingAddress.isEnabled = !value; code.isEnabled = !value; connectAddress.isEnabled = !value
        window?.standardWindowButton(.closeButton)?.isEnabled = !value
        onBusy?(value)
    }

    @objc private func connectUSB() {
        guard !working else { return }; busy(true); status.stringValue = "Checking authorized USB phones…"
        worker.async {
            let devices = command(["devices"], timeout: 5)
            let candidates = authorizedUSBDevices(devices.output)
            guard candidates.count == 1, let endpoint = candidates.first else {
                DispatchQueue.main.async {
                    self.busy(false); self.status.stringValue = candidates.count > 1
                        ? "More than one USB phone is connected. Leave only the phone you want to pair connected, then try again."
                        : "No authorized USB phone found. Connect the cable, enable USB debugging, unlock the phone and approve this Mac."
                }; return
            }
            let result = command(["-s", endpoint, "shell", "getprop", "ro.serialno"], timeout: 5)
            let identity = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.busy(false)
                guard result.code == 0, !identity.isEmpty, identity.count < 128,
                      identity.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
                    self.status.stringValue = "Could not verify the USB phone identity. Unlock it and try again."; return
                }
                setPairedPhone(identity); UserDefaults.standard.set(endpoint, forKey: "verifiedPhoneEndpoint")
                self.onPaired?(); self.onConnected?(endpoint); self.close()
            }
        }
    }

    private func runPairing(address: String, password: String, manual: String?) {
        busy(true); status.stringValue = "Pairing with your phone…"
        worker.async {
            let result = command(["pair", address, password], timeout: 25)
            guard result.code == 0, result.output.contains("Successfully paired") else {
                DispatchQueue.main.async {
                    self.busy(false)
                    self.qrStatus.stringValue = "Waiting for your phone to scan…"
                    if self.qrName.isEmpty == false { self.newQRCode() }
                    self.status.stringValue = "Pairing did not finish. Scan the new code, or use the phone's current pairing code. \(result.output.prefix(140))"
                }
                return
            }
            if let serial = pairedSerial(from: result.output) { setPairedPhone(serial) }
            connectionLog("Phone paired")
            DispatchQueue.main.async { self.status.stringValue = "Paired. Connecting…"; self.onPaired?() }
            var connected: String?
            for attempt in 0..<8 where connected == nil {
                if attempt > 0 { Thread.sleep(forTimeInterval: 2) } // the phone advertises its connection port shortly
                connected = self.connectPhone(manual)
            }
            DispatchQueue.main.async {
                self.busy(false)
                if let connected {
                    self.qrStatus.stringValue = "Paired ✓"
                    self.status.stringValue = "Connected. JH Mirror is setting up your phone — screen, notifications, files and clipboard start in a moment."
                    self.onConnected?(connected)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.close() }
                } else {
                    self.status.stringValue = "Paired. Keep Wireless debugging on; JH Mirror connects automatically. If it does not, enter the main Wireless debugging screen's IP:port and click Connect."
                }
            }
        }
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
                    self.status.stringValue = "Pairing popup detected. Enter its 6-digit code, then click Pair with code."
                } else {
                    self.status.stringValue = "Open “Pair device with pairing code” on your phone, then Auto-detect. You can also type the popup's IP:port."
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
        code.stringValue = ""
        runPairing(address: address, password: value, manual: manual.isEmpty ? nil : wirelessEndpoint(manual))
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
                else { self.status.stringValue = "Phone unavailable. Keep Wireless debugging on and both devices on the same Wi-Fi, or pair again with the QR code." }
            }
        }
    }
    /// Connects to the paired phone. A typed address is accepted only if it is the paired phone
    /// (or, before any phone is paired, it becomes the paired phone).
    private func connectPhone(_ address: String?) -> String? {
        if let address {
            let state = command(["-s", address, "get-state"], timeout: 2)
            if state.output.contains("offline") { _ = command(["disconnect", address], timeout: 2) }
            guard command(["connect", address], timeout: 8).code == 0 else { return nil }
            let identity = command(["-s", address, "shell", "getprop", "ro.serialno"], timeout: 5)
            let serial = identity.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard identity.code == 0, !serial.isEmpty, serial.count < 64, !serial.contains(" ") else { return nil }
            if phoneSerial.isEmpty { setPairedPhone(serial) }
            guard serial == phoneSerial else { return nil }
            UserDefaults.standard.set(address, forKey: "verifiedPhoneEndpoint")
            return address
        }
        return findPhone()
    }
}
