import AppKit

/// A phone-style app icon and label, with management actions kept in its context menu.
final class PhoneAppTile: NSCollectionViewItem {
    override func loadView() { view = PhoneAppCard(frame: NSRect(x: 0, y: 0, width: 78, height: 104)) }
    override var isSelected: Bool { didSet { if isViewLoaded { (view as? PhoneAppCard)?.selected = isSelected } } }
    func configure(app: PhoneApp, icon: NSImage?, available: Bool, select: @escaping () -> Void,
                   open: @escaping () -> Void, remove: @escaping () -> Void) {
        guard let card = view as? PhoneAppCard else { return }
        card.title.stringValue = app.displayName
        card.icon.image = icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
        card.available = available && app.canOpen; card.removable = available && app.canUninstall
        card.selected = isSelected; card.onSelect = select; card.onOpen = open; card.onRemove = remove
        card.toolTip = app.displayName
        card.setAccessibilityLabel(app.displayName)
        card.setAccessibilityEnabled(card.available)
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        guard let card = view as? PhoneAppCard else { return }
        card.onSelect = nil; card.onOpen = nil; card.onRemove = nil; card.icon.image = nil
    }
}

final class PhoneAppCard: NSView {
    let icon = NSImageView()
    let title = NSTextField(wrappingLabelWithString: "")
    var onSelect: (() -> Void)?
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    var available = false
    var removable = false
    var selected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown; addSubview(icon)
        title.alignment = .center; title.font = .systemFont(ofSize: 11, weight: .medium)
        title.maximumNumberOfLines = 2; title.lineBreakMode = .byTruncatingTail; addSubview(title)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 48) / 2, y: bounds.height - 56, width: 48, height: 48)
        title.frame = NSRect(x: 2, y: 8, width: bounds.width - 4, height: 31)
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovering {
            NSColor.labelColor.withAlphaComponent(selected ? 0.10 : 0.05).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { onSelect?(); if available && event.clickCount == 1 { onOpen?() } }
    override func accessibilityPerformPress() -> Bool {
        guard available else { return false }; onSelect?(); onOpen?(); return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect?()
        let menu = NSMenu(); menu.autoenablesItems = false
        let open = NSMenuItem(title: "Open", action: #selector(openApp), keyEquivalent: ""); open.target = self; open.isEnabled = available
        let remove = NSMenuItem(title: "Uninstall…", action: #selector(removeApp), keyEquivalent: ""); remove.target = self; remove.isEnabled = removable
        menu.addItem(open); menu.addItem(.separator()); menu.addItem(remove); return menu
    }
    @objc private func openApp() { if available { onSelect?(); onOpen?() } }
    @objc private func removeApp() { if removable { onSelect?(); onRemove?() } }
}
