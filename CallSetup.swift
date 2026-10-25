import AppKit

enum SetupLinks {
    static let obsDownload = URL(string: "https://obsproject.com/download")!
    static let obsHelp = URL(string: "https://obsproject.com/kb/virtual-camera-troubleshooting")!
    static let blackHoleDownload = URL(string: "https://existential.audio/blackhole/")!
    static let blackHoleHelp = URL(string: "https://github.com/ExistentialAudio/BlackHole#installation-instructions")!
}

struct CallSetupState {
    var cameraReady: Bool
    var obsInstalled: Bool
    var microphoneReady: Bool
    var audioDriverInstalled: Bool

    static func current() -> CallSetupState {
        CallSetupState(cameraReady: CallCamera.available,
            obsInstalled: FileManager.default.isExecutableFile(atPath: "/Applications/OBS.app/Contents/MacOS/OBS"),
            microphoneReady: CallDevices.loopback() != nil,
            audioDriverInstalled: FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"))
    }
}

/// Setup never starts phone capture, downloads or system installation by itself.
final class CallSetupWindow: NSWindowController {
    var onSaved: (() -> Void)?
    var onOpenCamera: (() -> Void)?
    var onPairPhone: (() -> Void)?
    var onQuickStart: (() -> Void)?
    private let probe: () -> CallSetupState
    private let openURL: (URL) -> Void
    private var activationObserver: NSObjectProtocol?
    private let cameraState = NSTextField(labelWithString: "")
    private let microphoneState = NSTextField(labelWithString: "")
    private let cameraDescription = NSTextField(wrappingLabelWithString: "")
    private let microphoneDescription = NSTextField(wrappingLabelWithString: "")
    private let cameraAction = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")

    init(probe: @escaping () -> CallSetupState = CallSetupState.current,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.probe = probe; self.openURL = openURL
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isFloatingPanel = false
        window.title = "Setup & Add-ons · JH Mirror"; window.center()
        super.init(window: window)
        guard let view = window.contentView else { return }
        func label(_ text: String, x: CGFloat = 28, y: CGFloat, width: CGFloat = 584,
                   height: CGFloat = 36, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.frame = NSRect(x: x, y: y, width: width, height: height)
            field.font = .systemFont(ofSize: size, weight: weight); view.addSubview(field); return field
        }
        func button(_ title: String, _ action: Selector, x: CGFloat, y: CGFloat, width: CGFloat) {
            let button = NSButton(title: title, target: self, action: action)
            button.frame = NSRect(x: x, y: y, width: width, height: 32); view.addSubview(button)
        }
        func card(y: CGFloat, height: CGFloat) {
            let box = NSBox(frame: NSRect(x: 24, y: y, width: 592, height: height))
            box.boxType = .custom; box.fillColor = .controlBackgroundColor
            box.borderColor = .separatorColor; box.cornerRadius = 12; box.borderWidth = 0.5
            view.addSubview(box)
        }
        _ = label("Everything in one app", y: 648, height: 30, size: 23, weight: .semibold)
        let subtitle = label("Your phone companion and all core tools are included in JH Mirror.", y: 615, height: 25, size: 13)
        subtitle.textColor = .secondaryLabelColor

        card(y: 465, height: 143)
        _ = label("JH Mirror", x: 42, y: 570, height: 22, size: 15, weight: .semibold)
        let included = label("Included", x: 500, y: 570, width: 96, height: 22, size: 12, weight: .medium)
        included.textColor = .systemGreen; included.alignment = .right
        _ = label("Move JH Mirror to Applications, then pair your phone. Mirroring, files, media, apps, clipboard and notifications work from this app. The phone companion installs during pairing.",
                  x: 42, y: 510, width: 548, height: 53)
        button("Pair Phone…", #selector(pairPhone), x: 38, y: 474, width: 133)
        button("Quick Start", #selector(quickStart), x: 177, y: 474, width: 120)

        _ = label("Optional call add-ons", y: 424, height: 23, size: 16, weight: .semibold)
        let optional = label("Install once if you want to use the phone camera or microphone in Mac calls.", y: 396, height: 23)
        optional.textColor = .secondaryLabelColor

        card(y: 230, height: 158)
        _ = label("Phone camera · OBS Studio", x: 42, y: 351, width: 355, height: 23, size: 14, weight: .semibold)
        cameraState.frame = NSRect(x: 410, y: 352, width: 186, height: 21)
        cameraState.alignment = .right; cameraState.font = .systemFont(ofSize: 12, weight: .medium)
        view.addSubview(cameraState)
        cameraDescription.frame = NSRect(x: 42, y: 280, width: 548, height: 64)
        cameraDescription.font = .systemFont(ofSize: 12); view.addSubview(cameraDescription)
        cameraAction.target = self; cameraAction.action = #selector(cameraSetup)
        cameraAction.frame = NSRect(x: 38, y: 241, width: 200, height: 32); view.addSubview(cameraAction)
        button("Download ↗", #selector(downloadOBS), x: 246, y: 241, width: 121)
        button("Setup help ↗", #selector(cameraHelp), x: 375, y: 241, width: 124)

        card(y: 83, height: 137)
        _ = label("Phone microphone · BlackHole 2ch", x: 42, y: 184, width: 360, height: 23, size: 14, weight: .semibold)
        microphoneState.frame = NSRect(x: 410, y: 185, width: 186, height: 21)
        microphoneState.alignment = .right; microphoneState.font = .systemFont(ofSize: 12, weight: .medium)
        view.addSubview(microphoneState)
        microphoneDescription.frame = NSRect(x: 42, y: 130, width: 548, height: 46)
        microphoneDescription.font = .systemFont(ofSize: 12); view.addSubview(microphoneDescription)
        button("Download BlackHole 2ch ↗", #selector(downloadBlackHole), x: 38, y: 93, width: 226)
        button("Setup help ↗", #selector(microphoneHelp), x: 272, y: 93, width: 124)

        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 28, y: 48, width: 584, height: 29); view.addSubview(status)
        button("Refresh Status", #selector(refreshClicked), x: 24, y: 10, width: 138)
        button("Done", #selector(done), x: 526, y: 10, width: 90)
        refreshStatus()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard self?.window?.isVisible == true else { return }
                self?.refreshStatus()
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }

    func refreshStatus() {
        let state = probe()
        cameraState.stringValue = state.cameraReady ? "● Ready" : state.obsInstalled ? "● Enable extension" : "○ Not installed"
        cameraState.textColor = state.cameraReady ? .systemGreen : .secondaryLabelColor
        cameraAction.title = state.cameraReady ? "Open Phone Camera" : state.obsInstalled ? "Open OBS for Setup" : "Get OBS Studio"
        cameraDescription.stringValue = state.cameraReady
            ? "The camera component is ready. Keep OBS installed and closed. Open Phone Camera to choose a lens, rotate and preview. In your call, select OBS Virtual Camera. Requires Android 12+."
            : "1. Download OBS for Apple silicon and move it to Applications.\n2. Open OBS, start Virtual Camera and approve its extension when asked.\n3. Stop Virtual Camera, quit OBS, then open Phone Camera here. Android 12+."
        microphoneState.stringValue = state.microphoneReady ? "● Ready" : state.audioDriverInstalled ? "● Restart needed" : "○ Not installed"
        microphoneState.textColor = state.microphoneReady ? .systemGreen : .secondaryLabelColor
        microphoneDescription.stringValue = state.microphoneReady
            ? "Turn on Phone Mic in JH Mirror, then select BlackHole 2ch in your call. Keep your usual speakers or headphones. Requires Android 11+."
            : state.audioDriverInstalled
                ? "BlackHole is installed but not available to macOS yet. Restart your Mac when convenient, then refresh here. You can keep using the Mac microphone."
                : "Download and install the 2ch version, then restart if requested. Turn on Phone Mic in JH Mirror and select BlackHole 2ch in your call. Requires Android 11+."
        status.stringValue = "Downloads open official websites. macOS handles installation and any approvals."
        onSaved?()
    }
    @objc private func refreshClicked() { refreshStatus() }
    @objc private func done() { close() }
    @objc private func pairPhone() { onPairPhone?() }
    @objc private func quickStart() { onQuickStart?() }
    @objc private func downloadOBS() { openURL(SetupLinks.obsDownload) }
    @objc private func cameraHelp() { openURL(SetupLinks.obsHelp) }
    @objc private func downloadBlackHole() { openURL(SetupLinks.blackHoleDownload) }
    @objc private func microphoneHelp() { openURL(SetupLinks.blackHoleHelp) }
    @objc private func cameraSetup() {
        let state = probe()
        if state.cameraReady { close(); onOpenCamera?(); return }
        guard state.obsInstalled else { downloadOBS(); return }
        cameraAction.isEnabled = false
        Task { @MainActor in
            defer { self.cameraAction.isEnabled = true }
            do {
                _ = try await PhoneCalls.openOBS()
                self.status.stringValue = "Start Virtual Camera in OBS and approve the extension. Stop it and quit OBS, then Refresh Status."
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }
}
