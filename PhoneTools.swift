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

/// One round icon button in the Phone Tools strip.
private final class ToolButton: NSButton {
    var onClick: (() -> Void)?
    var active = false { didSet { refreshTint() } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, tip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        isBordered = false
        imagePosition = .imageOnly
        setSymbol(symbol, tip: tip)
        target = self; action = #selector(clicked)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        refreshTint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    func setSymbol(_ symbol: String, tip: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        toolTip = tip
        setAccessibilityLabel(tip)
    }
    private func refreshTint() { contentTintColor = active ? .controlAccentColor : .labelColor }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        if hovering || active {
            (active ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
        }
        super.draw(dirtyRect)
    }
    @objc private func clicked() { onClick?() }
}

/// The strip's background: frosted capsule that also accepts Mac files to send to the phone.
private final class ToolStripView: NSVisualEffectView {
    var onDrop: (([URL]) -> Void)?
    private var highlighted = false { didSet { layer?.borderWidth = highlighted ? 2 : 0 } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow; blendingMode = .behindWindow; state = .active
        wantsLayer = true
        layer?.cornerRadius = 14; layer?.masksToBounds = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
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

/// A slim, icon-only tool strip that follows the phone window. Hover for names.
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
    var onDeviceCheck: (() -> Void)?
    var onHide: (() -> Void)?
    var onCopyFile: ((URL) -> Void)?
    var onSendToPhone: (([URL]) -> Void)?
    var onPhoneScreen: (() -> Void)?
    var onApps: (() -> Void)?
    var onFiles: (() -> Void)?
    var onMedia: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    private let windowButton = ToolButton(symbol: "macwindow", tip: "Show phone window")
    private let screenButton = ToolButton(symbol: "iphone", tip: "Phone screen on")
    private let audioButton = ToolButton(symbol: "speaker.wave.2", tip: "Phone audio on Mac")
    private let clipboardButton = ToolButton(symbol: "doc.on.clipboard", tip: "Copy phone clipboard to Mac")
    private let filesButton = ToolButton(symbol: "folder", tip: "Files · or drop Mac files here to send them to the phone")
    private let moreButton = ToolButton(symbol: "ellipsis", tip: "More phone tools")
    private let appsButton = ToolButton(symbol: "square.grid.2x2", tip: "Phone App Library · open or uninstall apps")
    private let mediaButton = ToolButton(symbol: "photo.on.rectangle", tip: "Phone Media Library · photos, videos and audio")
    private let spinner = NSProgressIndicator()
    private var recent: [URL] = []
    private var latestAvailable = false
    private var lastFrame: NSRect?
    private(set) var expanded = UserDefaults.standard.bool(forKey: "phoneToolsExpanded")

    init() {
        let buttons = 8, step: CGFloat = 40, pad: CGFloat = 6
        let size = NSSize(width: 48, height: pad * 2 + step * CGFloat(buttons) + 9)
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
        let strip = ToolStripView(frame: NSRect(origin: .zero, size: size))
        strip.onDrop = { [weak self] urls in self?.onSendToPhone?(urls) }
        contentView = strip
        var y = size.height - pad - 36
        for (index, button) in [windowButton, screenButton, audioButton, clipboardButton, filesButton, mediaButton, appsButton, moreButton].enumerated() {
            if index == 7 { // a hairline before "more"
                let line = NSBox(frame: NSRect(x: 12, y: y + 36 + 4, width: 24, height: 1)); line.boxType = .separator
                strip.addSubview(line); y -= 9
            }
            button.frame.origin = NSPoint(x: 6, y: y)
            strip.addSubview(button)
            y -= step
        }
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: 30, y: windowButton.frame.minY + 2, width: 12, height: 12)
        strip.addSubview(spinner)
        windowButton.onClick = { [weak self] in self?.onWindow?() }
        screenButton.onClick = { [weak self] in self?.onPhoneScreen?() }
        audioButton.onClick = { [weak self] in self?.onAudio?() }
        clipboardButton.onClick = { [weak self] in self?.onCopyPhoneClipboard?() }
        filesButton.onClick = { [weak self] in
            guard let self else { return }; if let onFiles = self.onFiles { onFiles() } else { self.showFilesMenu() }
        }
        mediaButton.onClick = { [weak self] in self?.onMedia?() }
        moreButton.onClick = { [weak self] in self?.showMoreMenu() }
        appsButton.onClick = { [weak self] in self?.onApps?() }
    }

    private func menuItem(_ title: String, symbol: String? = nil, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        item.isEnabled = enabled
        return item
    }

    private func showFilesMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(menuItem("Choose Files on Phone…", symbol: "iphone.and.arrow.forward") { [weak self] in self?.onPickFiles?() })
        menu.addItem(menuItem("Open Received Files", symbol: "folder") { [weak self] in self?.onOpenFiles?() })
        menu.addItem(menuItem("Show Latest in Finder", symbol: "magnifyingglass", enabled: latestAvailable) { [weak self] in self?.onLatestFile?() })
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Copy a recent file", action: nil, keyEquivalent: ""); header.isEnabled = false
            menu.addItem(header)
            for url in recent.prefix(5) {
                let item = menuItem(url.lastPathComponent) { [weak self] in self?.onCopyFile?(url) }
                item.image = NSWorkspace.shared.icon(forFile: url.path); item.image?.size = NSSize(width: 16, height: 16)
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: filesButton.frame.maxX + 6, y: filesButton.frame.maxY), in: contentView)
    }

    private func showMoreMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(menuItem("Choose Files on Phone…", symbol: "iphone.and.arrow.forward") { [weak self] in self?.onPickFiles?() })
        menu.addItem(menuItem("Open Received Files", symbol: "folder") { [weak self] in self?.onOpenFiles?() })
        menu.addItem(menuItem("Copy Mac Text to Phone", symbol: "arrow.up.doc.on.clipboard") { [weak self] in self?.onSetClipboard?() })
        menu.addItem(menuItem("Clipboard Sync On/Off", symbol: "arrow.left.arrow.right") { [weak self] in self?.onClipboard?() })
        menu.addItem(.separator())
        menu.addItem(menuItem("Dashboard…", symbol: "rectangle.grid.1x2") { [weak self] in self?.onOpenPanel?() })
        menu.addItem(menuItem("Device Check…", symbol: "checklist") { [weak self] in self?.onDeviceCheck?() })
        menu.addItem(menuItem("Hide Tools", symbol: "xmark") { [weak self] in self?.hideTools() })
        menu.popUp(positioning: nil, at: NSPoint(x: moreButton.frame.maxX + 6, y: moreButton.frame.maxY), in: contentView)
    }

    func update(running: Bool, hidden: Bool, audio: Bool, clipboard: Bool, busy: Bool, restarting: Bool,
                fileStatus: String, latest: Bool, phoneScreenOff: Bool = false) {
        windowButton.setSymbol(running ? "macwindow" : "play.rectangle",
                               tip: running ? (hidden ? "Show phone window" : "Hide phone window") : "Open phone screen")
        windowButton.active = running && !hidden
        screenButton.setSymbol(phoneScreenOff ? "iphone.slash" : "iphone",
                               tip: phoneScreenOff ? "Phone screen is off · click to turn it on" : "Turn the phone screen off while mirroring")
        screenButton.active = phoneScreenOff
        audioButton.setSymbol(audio ? "speaker.wave.2" : "speaker.slash", tip: audio ? "Phone audio on Mac · click to mute" : "Phone audio is off · click to play on Mac")
        audioButton.active = audio
        windowButton.isEnabled = !busy
        audioButton.isEnabled = !restarting
        screenButton.isEnabled = !restarting
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        latestAvailable = latest
        filesButton.toolTip = fileStatus.isEmpty ? "Files" : fileStatus + "\nDrop Mac files here to send them to the phone"
    }

    /// Newest received files first (offered in the Files menu).
    func setRecentFiles(_ urls: [URL]) { recent = urls }

    func follow(_ frame: NSRect, active: Bool, visible: Bool, keepVisible: Bool) {
        lastFrame = frame
        let screen = NSScreen.screens.max { a, b in
            let x = a.frame.intersection(frame), y = b.frame.intersection(frame)
            return x.width * x.height < y.width * y.height
        } ?? NSScreen.main
        let available = screen?.visibleFrame ?? frame
        var x = frame.maxX + 8
        if x + self.frame.width > available.maxX { x = frame.minX - self.frame.width - 8 }
        x = min(max(available.minX + 4, x), available.maxX - self.frame.width - 4)
        let y = min(max(available.minY + 4, frame.maxY - self.frame.height), available.maxY - self.frame.height - 4)
        setFrameOrigin(NSPoint(x: x, y: y))
        guard expanded else { orderOut(nil); return }
        if keepVisible || (active && visible) { orderFrontRegardless() }
        else if !visible { orderOut(nil) }
    }
    func showTools(focus: Bool = false) {
        expanded = true; UserDefaults.standard.set(true, forKey: "phoneToolsExpanded")
        onVisibilityChanged?(true)
        if lastFrame == nil { center() }
        if focus { makeKeyAndOrderFront(nil) }
        else { orderFrontRegardless() }
    }
    func hideTools() {
        expanded = false; UserDefaults.standard.set(false, forKey: "phoneToolsExpanded")
        orderOut(nil); onVisibilityChanged?(false); onHide?()
    }
    func toggleTools() { if expanded { hideTools() } else { showTools() } }
}

/// NSMenuItem that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}
