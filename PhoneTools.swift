import AppKit

final class PhoneToolsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onWindow: (() -> Void)?
    var onAudio: (() -> Void)?
    var onClipboard: (() -> Void)?
    var onGetClipboard: (() -> Void)?
    var onSetClipboard: (() -> Void)?
    var onPickFiles: (() -> Void)?
    var onOpenFiles: (() -> Void)?
    var onLatestFile: (() -> Void)?
    var onOpenPanel: (() -> Void)?
    var onHide: (() -> Void)?
    private let screenButton = NSButton()
    private let audioButton = NSButton()
    private let clipboardButton = NSButton()
    private let clipboardMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let fileMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let files = NSTextField(wrappingLabelWithString: "")
    private var lastFrame: NSRect?
    private var manuallyHidden = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 238, height: 420),
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
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 238, height: 420))
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        contentView = effect
        let heading = NSTextField(labelWithString: "Phone Tools")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        heading.frame = NSRect(x: 18, y: 371, width: 180, height: 25)
        effect.addSubview(heading)
        let close = NSButton(title: "×", target: self, action: #selector(hideTools))
        close.isBordered = false
        close.font = .systemFont(ofSize: 20)
        close.frame = NSRect(x: 199, y: 371, width: 26, height: 26)
        close.toolTip = "Hide tools. Reopen from Android Wireless in the menu bar."
        effect.addSubview(close)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 18, y: 337, width: 200, height: 30)
        effect.addSubview(status)
        for (button, y, action) in [(screenButton, 296.0, #selector(toggleWindow)),
                                    (audioButton, 254.0, #selector(toggleAudio)),
                                    (clipboardButton, 212.0, #selector(toggleClipboard))] {
            button.target = self; button.action = action
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 14, y: y, width: 210, height: 34)
            effect.addSubview(button)
        }
        screenButton.toolTip = "Hide/show the phone window. Audio, clipboard and file sync keep running."
        audioButton.toolTip = "Turn phone audio on/off on this Mac. Changing audio restarts the screen session."
        clipboardButton.toolTip = "Automatic text clipboard sync while the screen session runs. Changing this restarts the session."
        clipboardMenu.frame = NSRect(x: 14, y: 168, width: 210, height: 32)
        addMenu(clipboardMenu, [("Clipboard actions", nil),
                              ("Copy Mac text → Phone", #selector(setClipboard)),
                              ("Copy Phone text → Mac", #selector(getClipboard))])
        effect.addSubview(clipboardMenu)
        fileMenu.frame = NSRect(x: 14, y: 124, width: 210, height: 32)
        addMenu(fileMenu, [("File sharing", nil),
                         ("Choose files on phone…", #selector(pickFiles)),
                         ("Open received folder", #selector(openFiles)),
                         ("Show latest in Finder", #selector(latestFile))])
        effect.addSubview(fileMenu)
        files.font = .systemFont(ofSize: 11)
        files.textColor = .secondaryLabelColor
        files.maximumNumberOfLines = 3
        files.frame = NSRect(x: 18, y: 65, width: 200, height: 48)
        effect.addSubview(files)
        let panel = NSButton(title: "Notifications & setup", target: self, action: #selector(openPanel))
        panel.bezelStyle = .rounded
        panel.frame = NSRect(x: 14, y: 20, width: 210, height: 32)
        effect.addSubview(panel)
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
        clipboardMenu.isEnabled = running && !busy
        fileMenu.item(at: 3)?.isEnabled = latest
        status.stringValue = busy ? "Connecting phone session…"
            : running ? (hidden ? "Window hidden · sync continues" : "Normal scroll · wireless screen")
            : "Screen closed · other sync continues"
        files.stringValue = fileStatus
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
    @objc private func pickFiles() { onPickFiles?() }
    @objc private func openFiles() { onOpenFiles?() }
    @objc private func latestFile() { onLatestFile?() }
    @objc private func openPanel() { onOpenPanel?() }
}
