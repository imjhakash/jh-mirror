import AppKit

/// One place to start, frame and stop the phone camera. The preview matches call output.
final class CameraWindow: NSWindowController, NSWindowDelegate {
    var onStartStop: (() -> Void)?
    var onFacing: ((String) -> Void)?
    var onRotate: ((Bool) -> Void)?
    var onMirror: ((Bool) -> Void)?
    var onSetup: (() -> Void)?
    var onClose: (() -> Void)?
    private let calls: PhoneCalls
    private let preview = NSImageView()
    private let placeholder = NSTextField(labelWithString: "Starting phone camera…")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let facing = NSPopUpButton()
    private let angle = NSTextField(labelWithString: "0°")
    private let mirror = NSButton(checkboxWithTitle: "Mirror image", target: nil, action: nil)
    private let startStop = NSButton()
    private var timer: Timer?
    private var reader: PhonePreviewReader?
    private var readerURL: URL?

    init(calls: PhoneCalls) {
        self.calls = calls
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Phone Camera · JH Mirror"; window.center()
        super.init(window: window); window.delegate = self
        guard let view = window.contentView else { return }
        let heading = NSTextField(labelWithString: "Phone Camera")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.frame = NSRect(x: 20, y: 568, width: 300, height: 24); view.addSubview(heading)
        let box = NSView(frame: NSRect(x: 20, y: 156, width: 720, height: 405))
        box.wantsLayer = true; box.layer?.backgroundColor = NSColor.black.cgColor
        box.layer?.cornerRadius = 12; box.layer?.masksToBounds = true
        preview.frame = box.bounds; preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityLabel("Live phone camera output")
        box.addSubview(preview)
        placeholder.alignment = .center; placeholder.textColor = .lightGray
        placeholder.frame = NSRect(x: 20, y: 190, width: 680, height: 26)
        box.addSubview(placeholder); view.addSubview(box)
        facing.addItems(withTitles: ["Front Camera", "Rear Camera"])
        facing.frame = NSRect(x: 20, y: 108, width: 150, height: 32)
        facing.target = self; facing.action = #selector(changeFacing)
        facing.setAccessibilityLabel("Phone camera lens"); view.addSubview(facing)
        func rotateButton(_ title: String, symbol: String, x: CGFloat, clockwise: Bool) {
            let button = NSButton(title: title, target: self, action: clockwise ? #selector(rotateRight) : #selector(rotateLeft))
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageLeading; button.frame = NSRect(x: x, y: 108, width: 90, height: 32)
            button.toolTip = clockwise ? "Rotate clockwise 90 degrees" : "Rotate counterclockwise 90 degrees"
            view.addSubview(button)
        }
        rotateButton("90°", symbol: "rotate.left", x: 188, clockwise: false)
        rotateButton("90°", symbol: "rotate.right", x: 284, clockwise: true)
        angle.frame = NSRect(x: 390, y: 113, width: 54, height: 22); angle.alignment = .center; view.addSubview(angle)
        mirror.frame = NSRect(x: 460, y: 109, width: 155, height: 30)
        mirror.target = self; mirror.action = #selector(changeMirror); view.addSubview(mirror)
        let setup = NSButton(title: "Setup…", target: self, action: #selector(openSetup))
        setup.frame = NSRect(x: 638, y: 108, width: 102, height: 32); view.addSubview(setup)
        let instruction = NSTextField(labelWithString: "In your call’s camera menu, select OBS Virtual Camera.")
        instruction.font = .systemFont(ofSize: 12); instruction.frame = NSRect(x: 20, y: 77, width: 720, height: 22)
        view.addSubview(instruction)
        let note = NSTextField(labelWithString: "Minimize to keep the camera running. Closing this window stops it.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 20, y: 54, width: 720, height: 19); view.addSubview(note)
        status.font = .systemFont(ofSize: 12); status.frame = NSRect(x: 20, y: 10, width: 580, height: 40); view.addSubview(status)
        startStop.title = "Start Camera"; startStop.target = self; startStop.action = #selector(toggle)
        startStop.frame = NSRect(x: 628, y: 16, width: 112, height: 32); startStop.keyEquivalent = "\r"
        view.addSubview(startStop)
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    func open() {
        if let window { PhoneWindowFlow.present(window) }
        calls.previewVisible = true; render()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in self?.updatePreview() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func render() {
        facing.selectItem(at: calls.facing == "front" ? 0 : 1)
        facing.isEnabled = !calls.cameraBusy && calls.camera != .starting
        angle.stringValue = "\(calls.rotation)°"; mirror.state = calls.mirrored ? .on : .off
        startStop.title = calls.camera == .off && !calls.cameraBusy ? "Start Camera" : "Stop Camera"
        startStop.contentTintColor = calls.camera == .off ? .labelColor : .systemRed
        status.stringValue = calls.camera == .active
            ? "Live · \(calls.facing == "front" ? "Front" : "Rear") camera · \(calls.rotation)°\(calls.mirrored ? " · Mirrored" : "")"
            : calls.message
        status.textColor = calls.camera == .active ? .systemGreen : .secondaryLabelColor
        if calls.camera == .off {
            preview.image = nil; placeholder.stringValue = "Camera is off"; placeholder.isHidden = false
            reader?.close(); reader = nil; readerURL = nil
        } else if calls.camera == .starting {
            preview.image = nil; placeholder.stringValue = "Starting phone camera…"; placeholder.isHidden = false
        }
    }
    private func updatePreview() {
        let visible = window?.isVisible == true && window?.isMiniaturized == false
        calls.previewVisible = visible
        guard visible, calls.camera != .off, let url = calls.previewURL else { return }
        if readerURL != url { reader?.close(); reader = PhonePreviewReader(path: url); readerURL = url }
        guard let frame = reader?.nextImage() else { return }
        preview.image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        placeholder.isHidden = true
    }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil; calls.previewVisible = false
        reader?.close(); reader = nil; readerURL = nil; preview.image = nil; onClose?()
    }
    func windowDidMiniaturize(_ notification: Notification) { calls.previewVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { calls.previewVisible = true }
    @objc private func toggle() { onStartStop?() }
    @objc private func changeFacing() { onFacing?(facing.indexOfSelectedItem == 0 ? "front" : "back") }
    @objc private func rotateLeft() { onRotate?(false) }
    @objc private func rotateRight() { onRotate?(true) }
    @objc private func changeMirror() { onMirror?(mirror.state == .on) }
    @objc private func openSetup() { onSetup?() }
}
