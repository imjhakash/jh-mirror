import AppKit

enum CallInputState { case off, starting, active }

/// Reads the small BGRA preview the mirror helper writes (see aw_preview.c).
final class PhonePreviewReader {
    static let path: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.johirulhoqakash.jhmirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return caches.appendingPathComponent("preview.bin")
    }()
    private let fileURL: URL
    private var map: UnsafeMutableRawPointer?
    private var size = 0
    init(path: URL = PhonePreviewReader.path) { fileURL = path }
    private var inode: UInt64 = 0
    private(set) var lastSequence: UInt64 = 0

    deinit { close() }

    func close() {
        if let map { munmap(map, size) }
        map = nil; size = 0; inode = 0
    }

    private func open() -> Bool {
        let fd = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 64 + 4, info.st_uid == getuid() else { return false }
        if map != nil && UInt64(info.st_ino) == inode { return true }
        close()
        guard let mapped = mmap(nil, Int(info.st_size), PROT_READ, MAP_SHARED, fd, 0), mapped != MAP_FAILED else { return false }
        map = mapped; size = Int(info.st_size); inode = UInt64(info.st_ino)
        return true
    }

    /// Returns a new frame, or nil when nothing changed or a frame is being written.
    func nextImage() -> CGImage? {
        guard open(), let map else { return nil }
        guard map.load(as: UInt32.self) == 0x31505741 else { return nil } // "AWP1"
        let before = map.load(fromByteOffset: 8, as: UInt64.self)
        guard before & 1 == 0, before != lastSequence else { return nil }
        let width = Int(map.load(fromByteOffset: 16, as: UInt32.self))
        let height = Int(map.load(fromByteOffset: 20, as: UInt32.self))
        let stride = Int(map.load(fromByteOffset: 24, as: UInt32.self))
        guard width > 0, height > 0, stride >= width * 4, 64 + stride * height <= size else { return nil }
        let pixels = Data(bytes: map + 64, count: stride * height)
        // Discard a frame that changed while it was copied.
        guard map.load(fromByteOffset: 8, as: UInt64.self) == before else { return nil }
        lastSequence = before
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum PhoneLinkState: Equatable {
    case connected, syncOnly, offline, unpaired
    case working(String)
}

/// Something copied on the phone, newest first.
struct PhoneClip {
    let text: String?
    let file: URL?
    let date: Date
}

/// A clickable rounded card button with an SF Symbol above a short caption and hover/active feedback.
final class PopoverActionButton: NSButton {
    var activeColor: NSColor? { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(symbol: String, title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        self.imagePosition = .imageAbove
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.font = .systemFont(ofSize: 11, weight: .medium)
        self.target = target; self.action = action
        self.setButtonType(.momentaryChange)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        if let active = activeColor {
            active.withAlphaComponent(isHighlighted ? 0.28 : hovering ? 0.20 : 0.13).setFill()
            path.fill()
            active.withAlphaComponent(hovering ? 0.45 : 0.28).setStroke()
        } else {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : hovering ? 0.09 : 0.045).setFill()
            path.fill()
            NSColor.separatorColor.withAlphaComponent(hovering ? 0.65 : 0.35).setStroke()
        }
        path.lineWidth = 1
        path.stroke()
        super.draw(dirtyRect)
    }
}

/// Compact horizontal pill button for quick navigation (Files, Media, Apps) and header icons.
private final class PopoverPillButton: NSButton {
    var active = false { didSet { contentTintColor = active ? .controlAccentColor : .labelColor; needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(symbol: String, title: String = "", target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        let config = NSImage.SymbolConfiguration(pointSize: title.isEmpty ? 13 : 11.5, weight: .medium)
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? symbol : title)?
            .withSymbolConfiguration(config)
        self.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        self.isBordered = false
        self.font = .systemFont(ofSize: 11, weight: .medium)
        self.target = target; self.action = action
        self.setButtonType(.momentaryChange)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius: CGFloat = title.isEmpty ? 7 : 8
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if active {
            NSColor.controlAccentColor.withAlphaComponent(hovering ? 0.22 : 0.14).setFill()
            path.fill()
        } else if hovering || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.08).setFill()
            path.fill()
        } else if !title.isEmpty {
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }
}

/// Interactive preview container that shows a subtle hover prompt when a live frame is displayed.
private final class PreviewFrameView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

/// Menu-bar popover: live phone preview, Open Window, Clipboard and connection status / Reconnect.
final class PhonePopoverController: NSViewController {
    var onOpenWindow: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onDeviceCheck: (() -> Void)?
    var onCopyClip: ((PhoneClip) -> Void)?
    var onClearClips: (() -> Void)?
    var onToggleAutoCopy: (() -> Void)?
    var onGetPhoneClipboard: (() -> Void)?
    var onMore: (() -> Void)?
    var onPinChanged: ((Bool) -> Void)?
    var onCamera: (() -> Void)?
    var onMicrophone: (() -> Void)?
    var onCallSetup: (() -> Void)?
    var onFiles: (() -> Void)?
    var onMedia: (() -> Void)?
    var onApps: (() -> Void)?
    private var cameraButton: PopoverActionButton!
    private var microphoneButton: PopoverActionButton!
    private let callStatus = NSTextField(labelWithString: "Phone call inputs are off")
    private var pinButton: PopoverPillButton!
    /// Pinned: the popover stays open while you work in other apps.
    private(set) var isPinned = false
    private let preview = NSImageView()
    private let previewBox = PreviewFrameView()
    private let placeholderIcon = NSImageView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let previewHoverBadge = NSTextField(labelWithString: "  Open Phone Screen ↗  ")
    private let heading = NSTextField(labelWithString: "Your phone")
    private let statusDot = NSView()
    private let detail = NSTextField(labelWithString: "")
    private let clipboardPane = NSScrollView()
    private let clipStack = NSStackView()
    private let autoCopy = NSButton(checkboxWithTitle: "Auto-copy from phone", target: nil, action: nil)
    private var windowButton: PopoverActionButton!
    private var clipboardButton: PopoverActionButton!
    private var statusButton: PopoverActionButton!
    private(set) var showingClipboard = false
    private var clips: [PhoneClip] = []
    private var state: PhoneLinkState = .offline

    static let width: CGFloat = 300
    static let previewSize = NSSize(width: 196, height: 410)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 584))
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.frame = NSRect(x: 16, y: 550, width: Self.width - 96, height: 20)
        root.addSubview(heading)

        let more = PopoverPillButton(symbol: "ellipsis.circle", target: self, action: #selector(moreClicked))
        more.frame = NSRect(x: Self.width - 40, y: 546, width: 26, height: 26)
        more.toolTip = "Notifications, pairing, files and settings"
        root.addSubview(more)

        pinButton = PopoverPillButton(symbol: "pin", target: self, action: #selector(pinClicked))
        pinButton.frame = NSRect(x: Self.width - 70, y: 546, width: 26, height: 26)
        root.addSubview(pinButton)
        setPinned(false)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.frame = NSRect(x: 16, y: 536, width: 7, height: 7)
        root.addSubview(statusDot)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: 28, y: 532, width: Self.width - 44, height: 16)
        root.addSubview(detail)

        let area = NSRect(x: 0, y: 112, width: Self.width, height: 412)
        previewBox.frame = NSRect(x: (Self.width - Self.previewSize.width) / 2, y: area.minY + 1,
                                  width: Self.previewSize.width, height: Self.previewSize.height)
        previewBox.wantsLayer = true
        previewBox.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
        previewBox.layer?.cornerRadius = 18
        previewBox.layer?.borderWidth = 1
        previewBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        previewBox.layer?.masksToBounds = true
        preview.frame = previewBox.bounds
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityLabel("Live phone screen preview")
        previewBox.addSubview(preview)

        placeholderIcon.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .light))
        placeholderIcon.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        placeholderIcon.frame = NSRect(x: previewBox.bounds.midX - 18, y: previewBox.bounds.midY + 14, width: 36, height: 36)
        previewBox.addSubview(placeholderIcon)

        placeholder.alignment = .center
        placeholder.textColor = NSColor.white.withAlphaComponent(0.72)
        placeholder.font = .systemFont(ofSize: 12)
        placeholder.frame = NSRect(x: 14, y: previewBox.bounds.midY - 46, width: previewBox.bounds.width - 28, height: 54)
        previewBox.addSubview(placeholder)

        previewHoverBadge.font = .systemFont(ofSize: 11, weight: .medium)
        previewHoverBadge.textColor = .white
        previewHoverBadge.alignment = .center
        previewHoverBadge.wantsLayer = true
        previewHoverBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        previewHoverBadge.layer?.cornerRadius = 11
        previewHoverBadge.layer?.masksToBounds = true
        previewHoverBadge.frame = NSRect(x: (previewBox.bounds.width - 144) / 2, y: 12, width: 144, height: 22)
        previewHoverBadge.isHidden = true
        previewBox.addSubview(previewHoverBadge)
        previewBox.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            self.previewHoverBadge.isHidden = !hovering || self.preview.image == nil
        }

        let click = NSClickGestureRecognizer(target: self, action: #selector(openWindowClicked))
        previewBox.addGestureRecognizer(click)
        previewBox.toolTip = "Click to open the phone window"
        root.addSubview(previewBox)

        clipboardPane.frame = area.insetBy(dx: 12, dy: 0)
        clipboardPane.hasVerticalScroller = true
        clipboardPane.autohidesScrollers = true
        clipboardPane.drawsBackground = false
        clipStack.orientation = .vertical
        clipStack.alignment = .leading
        clipStack.spacing = 6
        clipStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: clipboardPane.contentSize.width, height: 10))
        document.addSubview(clipStack)
        clipboardPane.documentView = document
        clipboardPane.isHidden = true
        root.addSubview(clipboardPane)

        let filesPill = PopoverPillButton(symbol: "folder", title: "Files", target: self, action: #selector(filesClicked))
        filesPill.toolTip = "Browse phone files (⌘3)"
        let mediaPill = PopoverPillButton(symbol: "photo.on.rectangle", title: "Media", target: self, action: #selector(mediaClicked))
        mediaPill.toolTip = "Browse phone photos, videos and audio (⌘2)"
        let appsPill = PopoverPillButton(symbol: "square.grid.2x2", title: "Apps", target: self, action: #selector(appsClicked))
        appsPill.toolTip = "Open or manage phone apps"
        for (index, pill) in [filesPill, mediaPill, appsPill].enumerated() {
            pill.frame = NSRect(x: 12 + CGFloat(index) * 94, y: 76, width: 88, height: 28)
            root.addSubview(pill)
        }

        windowButton = PopoverActionButton(symbol: "macwindow", title: "Open Screen", target: self, action: #selector(openWindowClicked))
        clipboardButton = PopoverActionButton(symbol: "doc.on.clipboard", title: "Clipboard", target: self, action: #selector(clipboardClicked))
        statusButton = PopoverActionButton(symbol: "circle.fill", title: "Connecting", target: self, action: #selector(statusClicked))
        for (index, button) in [windowButton!, clipboardButton!, statusButton!].enumerated() {
            button.frame = NSRect(x: 12 + CGFloat(index) * 94, y: 14, width: 88, height: 54)
            root.addSubview(button)
        }
        windowButton.toolTip = "Show the phone window (⌘1)"
        clipboardButton.toolTip = "Things copied on the phone · click one to copy it again"
        statusButton.toolTip = "Connection status · click to reconnect"
        // Keep call controls visible while the preview or clipboard pane is selected.
        for child in root.subviews { child.frame.origin.y += 78 }
        root.frame.size.height += 78
        cameraButton = PopoverActionButton(symbol: "video", title: "Phone Camera", target: self, action: #selector(cameraClicked))
        microphoneButton = PopoverActionButton(symbol: "mic", title: "Phone Mic", target: self, action: #selector(microphoneClicked))
        let setup = PopoverActionButton(symbol: "slider.horizontal.3", title: "Setup", target: self, action: #selector(callSetupClicked))
        setup.toolTip = "Pair your phone, read Quick Start or set up optional call add-ons"
        for (index, button) in [cameraButton!, microphoneButton!, setup].enumerated() {
            button.frame = NSRect(x: 12 + CGFloat(index) * 94, y: 30, width: 88, height: 44)
            root.addSubview(button)
        }
        callStatus.font = .systemFont(ofSize: 10); callStatus.textColor = .secondaryLabelColor
        callStatus.lineBreakMode = .byTruncatingTail
        callStatus.frame = NSRect(x: 14, y: 8, width: Self.width - 28, height: 16); root.addSubview(callStatus)
        view = root
        setState(.offline)
        rebuildClips()
    }

    func setPreview(_ image: CGImage?) {
        guard let image, image.width > 0, image.height > 0 else { return }
        fitPreviewBox(aspect: CGFloat(image.width) / CGFloat(image.height))
        preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        placeholder.isHidden = true
        placeholderIcon.isHidden = true
    }

    /// Portrait or landscape: the rounded phone frame follows the phone's current orientation.
    private func fitPreviewBox(aspect: CGFloat) {
        let area = NSRect(x: 12, y: 191, width: Self.width - 24, height: Self.previewSize.height)
        var size = NSSize(width: area.height * aspect, height: area.height)
        if size.width > area.width { size = NSSize(width: area.width, height: area.width / aspect) }
        let frame = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                           width: size.width.rounded(), height: size.height.rounded())
        guard frame != previewBox.frame else { return }
        previewBox.frame = frame
        preview.frame = previewBox.bounds
        placeholderIcon.frame = NSRect(x: previewBox.bounds.midX - 18, y: previewBox.bounds.midY + 14, width: 36, height: 36)
        placeholder.frame = NSRect(x: 10, y: previewBox.bounds.midY - 46, width: previewBox.bounds.width - 20, height: 54)
        previewHoverBadge.frame = NSRect(x: (previewBox.bounds.width - 144) / 2, y: 12, width: 144, height: 22)
    }

    func setCalls(camera: CallInputState, microphone: CallInputState, message: String) {
        loadViewIfNeeded()
        cameraButton.title = camera == .off ? "Phone Camera" : camera == .starting ? "Starting…" : "Camera Live"
        microphoneButton.title = microphone == .off ? "Phone Mic" : microphone == .starting ? "Starting…" : "Stop Mic"
        cameraButton.contentTintColor = camera == .off ? .labelColor : .systemGreen
        microphoneButton.contentTintColor = microphone == .off ? .labelColor : .systemGreen
        cameraButton.activeColor = camera == .off ? nil : .systemGreen
        microphoneButton.activeColor = microphone == .off ? nil : .systemGreen
        callStatus.stringValue = message; callStatus.toolTip = message
        cameraButton.toolTip = "Open camera preview, choose front/rear, rotate or stop"
        microphoneButton.toolTip = "Start or stop phone audio through BlackHole 2ch"
    }
    @objc private func cameraClicked() { onCamera?() }
    @objc private func microphoneClicked() { onMicrophone?() }
    @objc private func callSetupClicked() { onCallSetup?() }
    @objc private func filesClicked() { onFiles?() }
    @objc private func mediaClicked() { onMedia?() }
    @objc private func appsClicked() { onApps?() }

    func clearPreview(message: String) {
        fitPreviewBox(aspect: Self.previewSize.width / Self.previewSize.height)
        preview.image = nil
        previewHoverBadge.isHidden = true
        placeholder.stringValue = message
        placeholder.isHidden = false
        placeholderIcon.isHidden = false
    }

    func setState(_ newState: PhoneLinkState) {
        state = newState
        guard isViewLoaded else { return }
        let (title, color, text): (String, NSColor, String) = {
            switch newState {
            case .connected: return ("Connected", .systemGreen, "Screen, auto-copy and sync connected")
            case .syncOnly: return ("Reconnect", .systemOrange, "Sync on · screen not connected")
            case .offline: return ("Reconnect", .systemRed, "Phone not reachable")
            case .unpaired: return ("Pair Phone", .systemGray, "No phone paired yet")
            case .working(let message): return ("Working…", .systemBlue, message)
            }
        }()
        statusButton.title = title
        statusButton.toolTip = newState == .connected || newState == .syncOnly ? "Device Check · feature status and compatibility" : "Connection status · click to reconnect"
        statusButton.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]).applying(.init(pointSize: 14, weight: .regular)))
        statusButton.isEnabled = { if case .working = newState { return false }; return true }()
        statusDot.layer?.backgroundColor = color.cgColor
        detail.stringValue = text
    }

    func setAutoCopy(_ on: Bool) { autoCopy.state = on ? .on : .off }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        guard let pinButton else { return }
        pinButton.active = pinned
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: pinned ? "Unpin" : "Pin")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        pinButton.toolTip = pinned ? "Pinned · click to unpin" : "Pin · keep this open while you work"
    }

    func setClips(_ newClips: [PhoneClip]) {
        clips = newClips
        if isViewLoaded {
            updateClipboardButtonLabel()
            if showingClipboard { rebuildClips() }
        }
    }

    private func updateClipboardButtonLabel() {
        guard !showingClipboard else { return }
        clipboardButton.title = clips.isEmpty ? "Clipboard" : "Clipboard (\(clips.count))"
        clipboardButton.activeColor = nil
    }

    func setPhoneName(_ name: String) { heading.stringValue = name }

    func showPreviewPane() {
        guard isViewLoaded else { return }
        showingClipboard = false
        clipboardPane.isHidden = true; previewBox.isHidden = false
        updateClipboardButtonLabel()
        clipboardButton.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
    }

    private func rebuildClips() {
        for view in clipStack.arrangedSubviews { clipStack.removeArrangedSubview(view); view.removeFromSuperview() }
        let width = clipboardPane.contentSize.width - 4
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        autoCopy.target = self; autoCopy.action = #selector(autoCopyClicked)
        autoCopy.font = .systemFont(ofSize: 11.5)
        let get = NSButton(title: "Get now", target: self, action: #selector(getPhoneClipboardClicked))
        get.bezelStyle = .rounded; get.controlSize = .small
        get.toolTip = "Copy what is on the phone clipboard right now"
        header.addArrangedSubview(autoCopy)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(get)
        if !clips.isEmpty {
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearClipsClicked))
            clear.bezelStyle = .rounded; clear.controlSize = .small
            clear.toolTip = "Clear clipboard history in this popover"
            header.addArrangedSubview(clear)
        }
        clipStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalToConstant: width).isActive = true
        if clips.isEmpty {
            let emptyBox = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 160))
            emptyBox.translatesAutoresizingMaskIntoConstraints = false
            emptyBox.widthAnchor.constraint(equalToConstant: width).isActive = true
            emptyBox.heightAnchor.constraint(equalToConstant: 160).isActive = true
            let icon = NSImageView(image: NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 24, weight: .light))!)
            icon.contentTintColor = .tertiaryLabelColor
            icon.frame = NSRect(x: (width - 28) / 2, y: 102, width: 28, height: 28)
            emptyBox.addSubview(icon)
            let empty = NSTextField(wrappingLabelWithString: "Copy text or a photo on your phone and it appears here, ready to paste with ⌘V.")
            empty.alignment = .center
            empty.textColor = .secondaryLabelColor; empty.font = .systemFont(ofSize: 12)
            empty.frame = NSRect(x: 16, y: 36, width: width - 32, height: 54)
            emptyBox.addSubview(empty)
            clipStack.addArrangedSubview(emptyBox)
        }
        for clip in clips { clipStack.addArrangedSubview(row(for: clip, width: width)) }
        let document = clipboardPane.documentView!
        clipStack.layoutSubtreeIfNeeded()
        let height = max(clipboardPane.contentSize.height, clipStack.fittingSize.height)
        document.frame = NSRect(x: 0, y: 0, width: width, height: height)
        clipStack.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    private func row(for clip: PhoneClip, width: CGFloat) -> NSView {
        let row = ClipRow(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let metaLabel = NSTextField(labelWithString: "")
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.font = .systemFont(ofSize: 10.5)
        metaLabel.textColor = .secondaryLabelColor
        let time = DateFormatter.localizedString(from: clip.date, dateStyle: .none, timeStyle: .short)
        let defaultMeta: String
        if let file = clip.file {
            let tile = RecentFileTile(frame: NSRect(x: 6, y: 7, width: 40, height: 40))
            tile.url = file
            tile.onClick = { [weak self, weak row] _ in
                row?.flashCopied(metaLabel: metaLabel, restoreText: "\(time) · drag or click to copy")
                self?.onCopyClip?(clip)
            }
            row.addSubview(tile)
            titleLabel.stringValue = file.lastPathComponent
            defaultMeta = "\(time) · drag or click to copy"
            titleLabel.frame = NSRect(x: 54, y: 27, width: width - 62, height: 18)
            metaLabel.frame = NSRect(x: 54, y: 9, width: width - 62, height: 15)
        } else {
            let icon = NSImageView(image: NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Text")!)
            icon.contentTintColor = .secondaryLabelColor
            icon.frame = NSRect(x: 12, y: 17, width: 20, height: 20)
            row.addSubview(icon)
            let text = (clip.text ?? "").replacingOccurrences(of: "\n", with: " ")
            titleLabel.stringValue = String(text.prefix(120))
            defaultMeta = "\(time) · click to copy for ⌘V"
            titleLabel.frame = NSRect(x: 42, y: 27, width: width - 50, height: 18)
            metaLabel.frame = NSRect(x: 42, y: 9, width: width - 50, height: 15)
        }
        metaLabel.stringValue = defaultMeta
        row.onClick = { [weak self, weak row] in
            row?.flashCopied(metaLabel: metaLabel, restoreText: defaultMeta)
            self?.onCopyClip?(clip)
        }
        row.addSubview(titleLabel)
        row.addSubview(metaLabel)
        row.toolTip = "Click to copy again for ⌘V"
        return row
    }

    @objc private func openWindowClicked() { onOpenWindow?() }
    @objc private func statusClicked() {
        if state == .connected || state == .syncOnly { onDeviceCheck?() } else { onReconnect?() }
    }
    @objc private func autoCopyClicked() { onToggleAutoCopy?() }
    @objc private func getPhoneClipboardClicked() { onGetPhoneClipboard?() }
    @objc private func clearClipsClicked() {
        clips.removeAll()
        updateClipboardButtonLabel()
        rebuildClips()
        onClearClips?()
    }
    @objc private func moreClicked() { onMore?() }
    @objc private func pinClicked() { setPinned(!isPinned); onPinChanged?(isPinned) }
    @objc private func clipboardClicked() {
        if showingClipboard { showPreviewPane(); return }
        showingClipboard = true
        rebuildClips()
        clipboardPane.isHidden = false; previewBox.isHidden = true
        clipboardButton.title = "Preview"
        clipboardButton.activeColor = .controlAccentColor
        clipboardButton.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Preview")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A clipboard history row: highlights on hover, flashes confirmation, and copies on click.
private final class ClipRow: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var copiedFlash = false { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { onClick?() }
    func flashCopied(metaLabel: NSTextField, restoreText: String) {
        copiedFlash = true
        metaLabel.stringValue = "✓ Copied to Mac clipboard"
        metaLabel.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self, weak metaLabel] in
            self?.copiedFlash = false
            metaLabel?.stringValue = restoreText
            metaLabel?.textColor = .secondaryLabelColor
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        if copiedFlash {
            NSColor.systemGreen.withAlphaComponent(0.14).setFill()
            path.fill()
            NSColor.systemGreen.withAlphaComponent(0.4).setStroke()
        } else {
            (hovering ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16) : NSColor.quaternaryLabelColor.withAlphaComponent(0.22)).setFill()
            path.fill()
            NSColor.separatorColor.withAlphaComponent(hovering ? 0.5 : 0.25).setStroke()
        }
        path.lineWidth = 1
        path.stroke()
    }
}
