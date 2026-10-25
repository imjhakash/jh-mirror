import AppKit

final class DeviceHealthWindow: NSWindowController {
    var onCheck: (() -> Void)?
    var onDetails: ((DeviceFeature) -> Void)?
    private let heading = NSTextField(labelWithString: "Connect your phone")
    private let summary = NSTextField(labelWithString: "Green: checked / active · Yellow: setup / not checked · Red: unavailable / failed")
    private let stack = NSStackView()
    private let listDocument = DeviceHealthDocument()
    private var renderedRows: [DeviceFeatureStatus] = []
    private let check = NSButton(title: "Check again", target: nil, action: nil)
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 730),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Device Check · JH Mirror"; window.contentMinSize = NSSize(width: 570, height: 480)
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.center()
        super.init(window: window)
        let root = window.contentView!
        heading.font = .systemFont(ofSize: 18, weight: .semibold); heading.frame = NSRect(x: 22, y: 677, width: 470, height: 28); heading.autoresizingMask = [.width, .minYMargin]; root.addSubview(heading)
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor; summary.frame = NSRect(x: 22, y: 650, width: 616, height: 20); summary.autoresizingMask = [.width, .minYMargin]; root.addSubview(summary)
        check.frame = NSRect(x: 518, y: 678, width: 120, height: 28); check.autoresizingMask = [.minXMargin, .minYMargin]; check.bezelStyle = .rounded; check.target = self; check.action = #selector(checkClicked); root.addSubview(check)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 44, width: 620, height: 594)); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        let content = listDocument; content.translatesAutoresizingMaskIntoConstraints = false; content.frame = NSRect(x: 0, y: 0, width: 620, height: 811); scroll.documentView = content; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor), content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        root.addSubview(scroll)
        let note = NSTextField(labelWithString: "Checks read device details and shared-storage listings. Camera and microphone stay off.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.frame = NSRect(x: 22, y: 13, width: 616, height: 20); note.autoresizingMask = [.width]; root.addSubview(note)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func checkClicked() { onCheck?() }
    func render(_ health: DeviceHealth, checking: Bool = false) {
        heading.stringValue = health.info.map { "\($0.model) · Android \($0.android)" } ?? "Connect your phone"
        check.isEnabled = !checking; check.title = checking ? "Checking…" : "Check again"
        let rows = health.rows
        guard rows != renderedRows else { return }; renderedRows = rows
        listDocument.setFrameSize(NSSize(width: listDocument.frame.width, height: CGFloat(rows.count * 91 - 8)))
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for row in rows {
            let view = NSView(); view.wantsLayer = true; view.layer?.cornerRadius = 10; view.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
            view.translatesAutoresizingMaskIntoConstraints = false
            let title = NSTextField(labelWithString: row.title); title.font = .systemFont(ofSize: 13, weight: .semibold)
            let badge = NSTextField(labelWithString: "● " + row.label); badge.font = .systemFont(ofSize: 11, weight: .medium); badge.textColor = row.state == "green" ? .systemGreen : row.state == "red" ? .systemRed : .systemOrange
            let reason = NSTextField(wrappingLabelWithString: row.reason); reason.font = .systemFont(ofSize: 11); reason.textColor = .secondaryLabelColor; reason.maximumNumberOfLines = 2
            let details = DeviceDetailButton(title: "Details", feature: row.id) { [weak self] in self?.onDetails?($0) }
            for child in [title, badge, reason, details] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
            NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), title.topAnchor.constraint(equalTo: view.topAnchor, constant: 11), badge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14), badge.centerYAnchor.constraint(equalTo: title.centerYAnchor), title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -12), reason.leadingAnchor.constraint(equalTo: title.leadingAnchor), reason.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5), reason.trailingAnchor.constraint(equalTo: details.leadingAnchor, constant: -12), reason.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10), details.trailingAnchor.constraint(equalTo: badge.trailingAnchor), details.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8), details.widthAnchor.constraint(equalToConstant: 70), view.heightAnchor.constraint(equalToConstant: 83)])
            stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
    func open() { if let window { PhoneWindowFlow.present(window) } }
}

private final class DeviceHealthDocument: NSView { override var isFlipped: Bool { true } }

private final class DeviceDetailButton: NSButton {
    private let feature: DeviceFeature
    private let handler: (DeviceFeature) -> Void
    init(title: String, feature: DeviceFeature, handler: @escaping (DeviceFeature) -> Void) {
        self.feature = feature; self.handler = handler
        super.init(frame: .zero); self.title = title; bezelStyle = .rounded; controlSize = .small; target = self; action = #selector(clicked)
        setAccessibilityLabel("Details for " + feature.title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicked() { handler(feature) }
}
