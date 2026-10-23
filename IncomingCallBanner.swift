import AppKit

/// Animated card that slides down from the top of the screen when an incoming call arrives on the phone.
final class IncomingCallBanner: NSPanel {
    var onAnswer: (() -> Void)?
    var onDecline: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let callerLabel = NSTextField(labelWithString: "Incoming Call")
    private let numberLabel = NSTextField(labelWithString: "")
    private var dismissTimer: Timer?
    private var shown = false
    private weak var iconBg: NSView?

    init() {
        let w: CGFloat = 348, h: CGFloat = 92
        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 17
        blur.layer?.masksToBounds = true
        // Border
        let border = CALayer()
        border.frame = blur.bounds
        border.cornerRadius = 17
        border.borderWidth = 1
        border.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        border.masksToBounds = true
        blur.layer?.addSublayer(border)
        contentView = blur

        // Icon background circle
        let bg = NSView(frame: NSRect(x: 16, y: h / 2 - 21, width: 42, height: 42))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.22).cgColor
        bg.layer?.cornerRadius = 21
        blur.addSubview(bg)
        iconBg = bg

        let phoneImg = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: "Incoming call")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        let iconView = NSImageView(frame: NSRect(x: 9, y: 9, width: 24, height: 24))
        iconView.image = phoneImg
        iconView.contentTintColor = .systemGreen
        bg.addSubview(iconView)

        // "Incoming Call" app label
        let appLabel = NSTextField(labelWithString: "Incoming Call")
        appLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        appLabel.textColor = .tertiaryLabelColor
        appLabel.frame = NSRect(x: 68, y: h / 2 + 18, width: w - 166, height: 14)
        blur.addSubview(appLabel)

        // Caller name
        callerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        callerLabel.textColor = .labelColor
        callerLabel.lineBreakMode = .byTruncatingTail
        callerLabel.frame = NSRect(x: 68, y: h / 2 - 1, width: w - 166, height: 19)
        blur.addSubview(callerLabel)

        // Number / secondary info
        numberLabel.font = .systemFont(ofSize: 11.5)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.lineBreakMode = .byTruncatingTail
        numberLabel.frame = NSRect(x: 68, y: h / 2 - 18, width: w - 166, height: 15)
        blur.addSubview(numberLabel)

        // Answer button (green)
        let answerBtn = callButton(symbol: "phone.fill", color: .systemGreen, tip: "Answer call")
        answerBtn.frame = NSRect(x: w - 92, y: h / 2 - 19, width: 38, height: 38)
        answerBtn.target = self; answerBtn.action = #selector(answerTapped)
        blur.addSubview(answerBtn)

        // Decline button (red)
        let declineBtn = callButton(symbol: "phone.down.fill", color: .systemRed, tip: "Decline call")
        declineBtn.frame = NSRect(x: w - 48, y: h / 2 - 19, width: 38, height: 38)
        declineBtn.target = self; declineBtn.action = #selector(declineTapped)
        blur.addSubview(declineBtn)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func callButton(symbol: String, color: NSColor, tip: String) -> NSButton {
        let btn = NSButton()
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = color.cgColor
        btn.layer?.cornerRadius = 19
        btn.contentTintColor = .white
        btn.toolTip = tip
        btn.imagePosition = .imageOnly
        return btn
    }

    // MARK: - Public API

    func show(callerName: String, callerNumber: String) {
        DispatchQueue.main.async { self.showOnMain(callerName: callerName, callerNumber: callerNumber) }
    }

    func dismiss(callEnded: Bool = false) {
        DispatchQueue.main.async { self.dismissOnMain(callEnded: callEnded) }
    }

    // MARK: - Private

    private func showOnMain(callerName: String, callerNumber: String) {
        callerLabel.stringValue = callerName.isEmpty ? "Unknown Caller" : callerName
        let number = callerNumber
        numberLabel.stringValue = number
        numberLabel.isHidden = number.isEmpty

        if shown {
            return
        }
        shown = true

        guard let screen = NSScreen.main else { return }
        let w = frame.width
        let x = (screen.frame.width - w) / 2
        let menuBarH = NSStatusBar.system.thickness
        let shownY = screen.frame.maxY - frame.height - menuBarH - 8
        let hiddenY = screen.frame.maxY + frame.height + 20

        setFrameOrigin(NSPoint(x: x, y: hiddenY))
        orderFrontRegardless()

        // Start pulse animation on the icon
        startPulse()

        // Slide down with a spring-like curve
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.44
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.17, 0.89, 0.32, 1.25)
            self.animator().setFrameOrigin(NSPoint(x: x, y: shownY))
        }

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.dismissOnMain(callEnded: true)
        }
    }

    private func startPulse() {
        guard let bg = iconBg else { return }
        bg.layer?.removeAllAnimations()
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.15
        pulse.duration = 0.65
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bg.layer?.add(pulse, forKey: "callPulse")
    }

    private func dismissOnMain(callEnded: Bool) {
        dismissTimer?.invalidate(); dismissTimer = nil
        guard shown else { return }
        shown = false
        iconBg?.layer?.removeAllAnimations()

        guard let screen = NSScreen.main else { orderOut(nil); return }
        let hiddenY = screen.frame.maxY + frame.height + 20

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().setFrameOrigin(NSPoint(x: self.frame.minX, y: hiddenY))
        }, completionHandler: {
            self.orderOut(nil)
            if callEnded { self.onDismiss?() }
        })
    }

    @objc private func answerTapped() { dismissOnMain(callEnded: false); onAnswer?() }
    @objc private func declineTapped() { dismissOnMain(callEnded: false); onDecline?() }
}
