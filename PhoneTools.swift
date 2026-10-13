import AppKit
import QuickLookThumbnailing

/// A received file that can be dragged into any app (WhatsApp, Mail, Finder…) or clicked to copy.
final class RecentFileTile: NSView, NSDraggingSource {
    var url: URL? { didSet { refresh() } }
    var onClick: ((URL) -> Void)?
    private let image = NSImageView()
    private var downEvent: NSEvent?
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        image.frame = bounds.insetBy(dx: 3, dy: 3)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.unregisterDraggedTypes()
        addSubview(image)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) && url != nil ? self : nil }

    private func refresh() {
        generation += 1
        let current = generation
        isHidden = url == nil
        guard let url else { image.image = nil; toolTip = nil; return }
        toolTip = url.lastPathComponent + "\nDrag into any app, or click to copy for ⌘V"
        setAccessibilityLabel("Received file " + url.lastPathComponent)
        image.image = NSWorkspace.shared.icon(forFile: url.path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: bounds.size,
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let thumbnail else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.image.image = thumbnail.nsImage
            }
        }
    }

    override func mouseDown(with event: NSEvent) { downEvent = event }
    override func mouseDragged(with event: NSEvent) {
        guard let url, let start = downEvent else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 3 else { return }
        downEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image.image ?? NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        if downEvent != nil, let url { onClick?(url) }
        downEvent = nil
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

/// Drop Mac files here to copy them to the phone's Download folder.
final class PhoneDropZone: NSView {
    var onDrop: (([URL]) -> Void)?
    private let label = NSTextField(labelWithString: "Drop Mac files here\nto send to the phone")
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.frame = bounds.insetBy(dx: 6, dy: 9)
        addSubview(label)
        toolTip = "Copies to the phone's Download folder. You can also drop files onto the phone window."
        setAccessibilityLabel("Drop files to send to the phone")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        path.lineWidth = highlighted ? 2 : 1.5
        path.setLineDash([5, 4], count: 2, phase: 0)
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        if highlighted { NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); path.fill() }
        path.stroke()
    }
    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !urls(sender).isEmpty; highlighted = ok; return ok ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let dropped = urls(sender)
        guard !dropped.isEmpty else { return false }
        onDrop?(dropped); return true
    }
}

final class PhoneToolsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onWindow: (() -> Void)?
    var onAudio: (() -> Void)?
    var onClipboard: (() -> Void)?
    var onGetClipboard: (() -> Void)?
    var onSetClipboard: (() -> Void)?
    var onCopyPhoneClipboard: (() -> Void)?
    var onPickFiles: (() -> Void)?
    var onOpenFiles: (() -> Void)?
    var onLatestFile: (() -> Void)?
    var onOpenPanel: (() -> Void)?
    var onHide: (() -> Void)?
    var onCopyFile: ((URL) -> Void)?
    var onSendToPhone: (([URL]) -> Void)?
    private let screenButton = NSButton()
    private let audioButton = NSButton()
    private let clipboardButton = NSButton()
    private let clipboardMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let fileMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let files = NSTextField(wrappingLabelWithString: "")
    private let recentLabel = NSTextField(labelWithString: "From phone · drag out, or click to copy")
    private var tiles: [RecentFileTile] = []
    private let dropZone = PhoneDropZone(frame: NSRect(x: 14, y: 62, width: 210, height: 50))
    private var lastFrame: NSRect?
    private var manuallyHidden = false

    init() {
        let size = NSSize(width: 238, height: 560)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Phone Tools"
        isReleasedWhenClosed = false
        isFloatingPanel = false
        level = .normal
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = true
        collectionBehavior = [.fullScreenAuxiliary]
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        contentView = effect
        let heading = NSTextField(labelWithString: "Phone Tools")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        heading.frame = NSRect(x: 18, y: 511, width: 180, height: 25)
        effect.addSubview(heading)
        let close = NSButton(title: "×", target: self, action: #selector(hideTools))
        close.isBordered = false
        close.font = .systemFont(ofSize: 20)
        close.frame = NSRect(x: 199, y: 511, width: 26, height: 26)
        close.toolTip = "Hide tools. Reopen from Android Wireless in the menu bar."
        effect.addSubview(close)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 18, y: 477, width: 200, height: 30)
        effect.addSubview(status)
        for (button, y, action) in [(screenButton, 436.0, #selector(toggleWindow)),
                                    (audioButton, 394.0, #selector(toggleAudio)),
                                    (clipboardButton, 352.0, #selector(toggleClipboard))] {
            button.target = self; button.action = action
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 14, y: y, width: 210, height: 34)
            effect.addSubview(button)
        }
        screenButton.toolTip = "Hide/show the phone window. Audio, clipboard and file sync keep running."
        audioButton.toolTip = "Turn phone audio on/off on this Mac. Changing audio restarts the screen session."
        clipboardButton.toolTip = "Automatic text clipboard sync while the screen session runs. Changing this restarts the session."
        clipboardMenu.frame = NSRect(x: 14, y: 308, width: 210, height: 32)
        addMenu(clipboardMenu, [("Clipboard actions", nil),
                              ("Copy phone clipboard → Mac (images & text)", #selector(copyPhoneClipboard)),
                              ("Copy Mac text → Phone", #selector(setClipboard)),
                              ("Copy phone text → Mac (screen session)", #selector(getClipboard))])
        effect.addSubview(clipboardMenu)
        fileMenu.frame = NSRect(x: 14, y: 264, width: 210, height: 32)
        addMenu(fileMenu, [("File sharing", nil),
                         ("Choose files on phone…", #selector(pickFiles)),
                         ("Open received folder", #selector(openFiles)),
                         ("Show latest in Finder", #selector(latestFile))])
        effect.addSubview(fileMenu)
        files.font = .systemFont(ofSize: 11)
        files.textColor = .secondaryLabelColor
        files.maximumNumberOfLines = 3
        files.frame = NSRect(x: 18, y: 205, width: 200, height: 48)
        effect.addSubview(files)
        recentLabel.font = .systemFont(ofSize: 10)
        recentLabel.textColor = .secondaryLabelColor
        recentLabel.frame = NSRect(x: 16, y: 180, width: 210, height: 16)
        effect.addSubview(recentLabel)
        for index in 0..<4 {
            let tile = RecentFileTile(frame: NSRect(x: 14 + CGFloat(index) * 54, y: 124, width: 48, height: 48))
            tile.onClick = { [weak self] url in self?.onCopyFile?(url) }
            tiles.append(tile); effect.addSubview(tile)
        }
        dropZone.onDrop = { [weak self] urls in self?.onSendToPhone?(urls) }
        effect.addSubview(dropZone)
        let panel = NSButton(title: "Notifications & setup", target: self, action: #selector(openPanel))
        panel.bezelStyle = .rounded
        panel.frame = NSRect(x: 14, y: 20, width: 210, height: 32)
        effect.addSubview(panel)
        setRecentFiles([])
    }
    private func addMenu(_ popup: NSPopUpButton, _ items: [(String, Selector?)]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        popup.menu = menu
    }
    func update(running: Bool, hidden: Bool, audio: Bool, clipboard: Bool, busy: Bool, restarting: Bool,
                fileStatus: String, latest: Bool) {
        screenButton.title = running ? (hidden ? "Window: Off" : "Window: On") : "Open phone window"
        audioButton.title = audio ? "Audio: On" : "Audio: Off"
        clipboardButton.title = clipboard ? "Clipboard sync: On" : "Clipboard sync: Off"
        screenButton.isEnabled = !busy
        audioButton.isEnabled = !restarting
        clipboardButton.isEnabled = !restarting
        // The phone-clipboard pull works over ADB even without a screen session.
        clipboardMenu.isEnabled = true
        clipboardMenu.item(at: 2)?.isEnabled = running && !busy
        clipboardMenu.item(at: 3)?.isEnabled = running && !busy
        fileMenu.item(at: 3)?.isEnabled = latest
        status.stringValue = busy ? "Connecting phone session…"
            : running ? (hidden ? "Window hidden · sync continues" : "Normal scroll · wireless screen")
            : "Screen closed · other sync continues"
        if files.stringValue != fileStatus { files.stringValue = fileStatus }
    }
    /// Shows the newest received files first.
    func setRecentFiles(_ urls: [URL]) {
        for (index, tile) in tiles.enumerated() {
            let url = index < urls.count ? urls[index] : nil
            if tile.url != url { tile.url = url }
        }
        recentLabel.stringValue = urls.isEmpty ? "Files from the phone appear here" : "From phone · drag out, or click to copy"
    }
    func follow(_ frame: NSRect, active: Bool, visible: Bool, keepVisible: Bool) {
        lastFrame = frame
        let screen = NSScreen.screens.max { a, b in
            let x = a.frame.intersection(frame), y = b.frame.intersection(frame)
            return x.width * x.height < y.width * y.height
        } ?? NSScreen.main
        let available = screen?.visibleFrame ?? frame
        var x = frame.maxX + 10
        if x + self.frame.width > available.maxX { x = frame.minX - self.frame.width - 10 }
        x = min(max(available.minX + 4, x), available.maxX - self.frame.width - 4)
        let y = min(max(available.minY + 4, frame.maxY - self.frame.height), available.maxY - self.frame.height - 4)
        setFrameOrigin(NSPoint(x: x, y: y))
        guard !manuallyHidden else { return }
        if keepVisible || (active && visible) { orderFrontRegardless() }
        else if !visible { orderOut(nil) }
    }
    func showTools(focus: Bool = false) {
        manuallyHidden = false
        if lastFrame == nil { center() }
        if focus { makeKeyAndOrderFront(nil) }
        else { orderFrontRegardless() }
    }
    @objc private func hideTools() { manuallyHidden = true; orderOut(nil); onHide?() }
    @objc private func toggleWindow() { onWindow?() }
    @objc private func toggleAudio() { onAudio?() }
    @objc private func toggleClipboard() { onClipboard?() }
    @objc private func getClipboard() { onGetClipboard?() }
    @objc private func setClipboard() { onSetClipboard?() }
    @objc private func copyPhoneClipboard() { onCopyPhoneClipboard?() }
    @objc private func pickFiles() { onPickFiles?() }
    @objc private func openFiles() { onOpenFiles?() }
    @objc private func latestFile() { onLatestFile?() }
    @objc private func openPanel() { onOpenPanel?() }
}
