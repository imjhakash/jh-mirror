import AppKit
import Foundation
import UserNotifications
import CryptoKit
import Darwin
import ServiceManagement

func connectionLog(_ text: String) {
    let folder = WifiPeer.directory
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = folder.appendingPathComponent("connection.log")
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int, size > 1_000_000 { try? Data().write(to: url, options: .atomic) }
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data((ISO8601DateFormatter().string(from: Date()) + " " + text + "\n").utf8)) }
}

/// The phone paired in JH Mirror (its `ro.serialno`); empty until a phone is paired.
var phoneSerial: String { UserDefaults.standard.string(forKey: "pairedPhoneSerial") ?? "" }
/// adb ships inside the app; Homebrew's copy is only a fallback for development builds.
let adbPath: String = {
    if let bundled = Bundle.main.url(forAuxiliaryExecutable: "adb")?.path,
       FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
    return "/opt/homebrew/bin/adb"
}()
let mirrorApp = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/JH Mirror Screen.app")
let mirrorExecutable = mirrorApp.appendingPathComponent("Contents/MacOS/JHMirrorScreen").path
let scrcpyPath = FileManager.default.isExecutableFile(atPath: mirrorExecutable) ? mirrorExecutable : "/opt/homebrew/bin/scrcpy"

struct CommandResult {
    let code: Int32
    let output: String
}

private final class CommandOutput {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; data.append(chunk) }
    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

func command(_ arguments: [String], timeout: Double = 8) -> CommandResult {
    let process = Process()
    let output = Pipe()
    let captured = CommandOutput()
    var arguments = arguments
    // GUI-launched adb shell must never wait on inherited terminal input.
    if let shell = arguments.firstIndex(of: "shell") { arguments.insert("-n", at: shell + 1) }
    process.executableURL = URL(fileURLWithPath: adbPath)
    process.arguments = arguments
    process.environment = adbEnvironment()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    let completed = DispatchSemaphore(value: 0)
    let drained = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completed.signal() }
    do { try process.run() } catch {
        return CommandResult(code: -1, output: error.localizedDescription)
    }
    output.fileHandleForWriting.closeFile()
    DispatchQueue.global(qos: .utility).async {
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            captured.append(chunk)
        }
        drained.signal()
    }
    if completed.wait(timeout: .now() + timeout) == .timedOut {
        if process.isRunning { process.terminate() }
        if completed.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = drained.wait(timeout: .now() + 1)
        return CommandResult(code: -1, output: "Connection timed out.")
    }
    _ = drained.wait(timeout: .now() + 1)
    return CommandResult(code: process.terminationStatus, output: captured.text())
}


final class DashboardCardRow: NSView {
    var onDismiss: (() -> Void)?
    private let dismissButton = NSButton()
    private let timeLabel: NSTextField
    private var hovering = false { didSet {
        dismissButton.isHidden = !hovering
        timeLabel.isHidden = hovering
        needsDisplay = true
    } }

    init(frame: NSRect, timeText: String) {
        timeLabel = NSTextField(labelWithString: timeText)
        super.init(frame: frame)
        timeLabel.font = .systemFont(ofSize: 10.5)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right
        timeLabel.frame = NSRect(x: frame.width - 78, y: 40, width: 66, height: 15)
        addSubview(timeLabel)

        dismissButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss notification")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        dismissButton.isBordered = false
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.toolTip = "Dismiss notification"
        dismissButton.frame = NSRect(x: frame.width - 32, y: 37, width: 22, height: 22)
        dismissButton.isHidden = true
        addSubview(dismissButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    @objc private func dismissClicked() { onDismiss?() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        (hovering ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.14) : NSColor.quaternaryLabelColor.withAlphaComponent(0.18)).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(hovering ? 0.55 : 0.25).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class Launcher: NSObject, NSPopoverDelegate, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!
    var screenStatus: NSTextField!
    var syncDot: NSView!
    var syncStatus: NSTextField!
    var alertStatus: NSTextField!
    var notificationsHeading: NSTextField!
    var clearNotificationsButton: NSButton!
    var emptyNotificationsBox: NSView!
    var button: NSButton!
    var audioButton: NSButton!
    var fileStatus: NSTextField!
    var latestFileButton: NSButton!
    var latestFile: URL?
    var pauseButton: NSButton!
    var spinner: NSProgressIndicator!
    var table: NSTableView!
    var menuItem: NSStatusItem!
    var mirror: Process?
    var mirrorOutput: Pipe?
    var connecting = false
    var quitting = false
    var sawVideo = false
    var recentLog = ""
    var currentSerial: String? { didSet {
        deviceHealth.usePhone(phoneSerial)
        if oldValue != currentSerial {
            healthCheckGeneration = UUID(); healthCheckCancellation?.cancel(); healthChecking = false; checkedHealthSerial = nil
            deviceHealth.resetChecks()
        }
        if let currentSerial { autoClipboard.useSerial(currentSerial); loadPhoneName(currentSerial) }
    } }
    var phoneNameLoaded = false
    var mirrorWanted = true
    var mirrorRetry: Timer?
    var mirrorBackoff = RetryGate()
    var mirrorStarted = Date.distantPast
    var mirrorUserClosed = false
    var mirrorFrame: NSRect?
    var awakeActivity: NSObjectProtocol?
    var systemSleeping = false
    var lastMirrorActivity = Date.distantPast
    var appsWindow: PhoneAppsWindow?
    let phoneFilesClient = PhoneFilesClient()
    var fileTransfers: PhoneFileTransfers!
    var phoneFilesWindow: PhoneFilesWindow?
    var receiving = true
    var alertsAllowed = false
    var audioEnabled = true
    var restartingForAudio = false
    var clipboardEnabled = true
    var mirrorWindowHidden = false
    var mirrorMinimized = false
    var mirrorInput: Pipe?
    var mirrorLines = ""
    var tools: PhoneToolsPanel!
    var toolsTimer: Timer?
    var pairingWindow: PairPhoneWindow?
    var pairingBusy = false
    var discoveryGeneration = 0
    var history: [PhoneEvent] = []
    var fingerprints: [String: String] = [:]
    var deliveredIDs: [String: String] = [:]
    var notificationCategories: [String: UNNotificationCategory] = [:]
    var emptyNotifications: NSTextField!
    var turnOnNotificationsButton: NSButton!
    var connectionText = "Connecting…"
    var recentFiles: [URL] = []
    var pasteboardProviders: [ImagePasteboardProvider] = []
    let autoClipboard = PhoneClipboardSync()
    let popover = NSPopover()
    let popoverController = PhonePopoverController()
    let previewReader = PhonePreviewReader()
    var previewTimer: Timer?
    var linkTimer: Timer?
    var reconnectMessage: String?
    var phoneClips: [PhoneClip] = []
    /// The screen session was started only to feed the menu-bar preview (window never shown).
    var previewOnlySession = false
    var previewStop: DispatchWorkItem?
    var autoCopyButton: NSButton!
    var autoCopyEnabled = true
    /// Mirroring with the phone's own display turned off (remembered).
    var phoneScreenOff = false
    var screenOffGuardActive = false
    var screenOffRequestPending = false
    let touchGuard = PhoneTouchGuard()
    var preparingTouchGuard = false
    let calls = PhoneCalls()
    var callSetupWindow: CallSetupWindow?
    var cameraWindow: CameraWindow?
    let windowFlow = PhoneWindowFlow()
    let deviceHealth = DeviceHealth()
    var deviceHealthWindow: DeviceHealthWindow?
    var healthChecking = false
    var healthCheckGeneration = UUID()
    var healthCheckCancellation: PhoneFileCancellation?
    var deviceProbeBusy = false
    var lastHealthReport: Data?
    var lastHealthReportTime = Date.distantPast
    var checkedHealthSerial: String?
    var lastCallHealthMessage = ""
    var requestingCamera = false
    var requestingMicrophone = false
    var observedTransferStates: [String: String] = [:]
    var terminatingCalls = false
    /// Keep the phone icon in the menu bar at all times (otherwise only while the phone is connected).
    var iconPinned = true
    let bridge = BridgeClient()
    let notifications = UNUserNotificationCenter.current()
    struct CallInfo { let key: String; let package: String?; let actions: [PhoneAction?]? }
    var incomingCallBanner: IncomingCallBanner?
    var pendingCall: CallInfo?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // JH Mirror's private adb server must belong to this app instance: macOS grants local-network
        // access per app, and a server left by an earlier instance or another tool may not reach the phone.
        _ = command(["kill-server"], timeout: 3)
        migrateFromAndroidWireless()
        notifications.delegate = self
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApplication.shared.applicationIconImage = NSImage(contentsOf: icon)
        }
        receiving = UserDefaults.standard.object(forKey: "receiving") as? Bool ?? true
        audioEnabled = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? true
        UserDefaults.standard.removeObject(forKey: "trackpadEnabled")
        clipboardEnabled = UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool ?? true
        autoCopyEnabled = UserDefaults.standard.object(forKey: "autoCopyFromPhone") as? Bool ?? true
        phoneScreenOff = UserDefaults.standard.bool(forKey: "phoneScreenOff")
        iconPinned = UserDefaults.standard.object(forKey: "menuBarIconPinned") as? Bool ?? true
        awakeActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "JH Mirror phone connection")
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleeping = false
            self?.mirrorBackoff.succeeded()
            self?.bridge.tick()
        }
        recentFiles = (UserDefaults.standard.stringArray(forKey: "recentReceivedFiles") ?? [])
            .map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        makeWindow()
        makeMenus()
        fileTransfers = PhoneFileTransfers(client: phoneFilesClient, provider: { [weak self] in
            guard let serial = self?.currentSerial, !phoneSerial.isEmpty else { return nil }
            return (serial, phoneSerial)
        })
        observedTransferStates = Dictionary(uniqueKeysWithValues: fileTransfers.snapshot.map { ($0.id, $0.state) })
        fileTransfers.onChange = { [weak self] jobs in
            guard let self else { return }
            self.phoneFilesWindow?.showTransfers(jobs)
            for job in jobs where self.observedTransferStates[job.id] != job.state {
                self.observedTransferStates[job.id] = job.state
                if job.state == "Done" { self.deviceHealth.record(.files, success: true, reason: "A complete file transfer passed SHA-256 verification on this connection.") }
                else if job.state == "Paused", job.autoRetry { self.featureFailed(.files, job.message) }
            }
            if let active = jobs.first(where: { $0.state == "Copying" || $0.state == "Verifying" }) {
                self.fileStatus.stringValue = "\(active.upload ? "Sending" : "Receiving") \(active.file.displayName) · \(active.completed*100/max(1,active.file.size))%"
            }
        }
        makePhoneTools()
        configureDeviceHealth()
        touchGuard.onReleased = { [weak self] screenOn, message in
            guard let self else { return }
            self.screenOffGuardActive = false
            if !screenOn { self.featureFailed(.screenOff, message) }
            if screenOn {
                self.phoneScreenOff = false
                UserDefaults.standard.set(false, forKey: "phoneScreenOff")
                self.sendMirrorCommand("screen-on-ack")
            } else if self.phoneScreenOff {
                self.mirrorWanted = false
                if let mirror = self.mirror { self.stopOwnedMirror(mirror, reason: "touch protection ended") }
            }
            self.alertStatus.stringValue = message
            self.refreshPhoneTools()
        }
        calls.onChange = { [weak self] in self?.refreshCallControls() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleeping = true
            if let self, let mirror = self.mirror { self.stopOwnedMirror(mirror, reason: "Mac sleeping") }
            self?.fileTransfers?.pause()
            self?.calls.stopAll()
            self?.touchGuard.stop()
            self?.refreshPhoneTools()
        }
        let toolUpdates = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.refreshPhoneTools() }
        RunLoop.main.add(toolUpdates, forMode: .common); toolsTimer = toolUpdates
        refreshAlertStatus()
        bridge.onStatus = { [weak self] text in
            self?.connectionText = text
            self?.updateSyncStatus()
        }
        bridge.onPhone = { [weak self] serial in
            guard let self else { return }
            self.currentSerial = serial
            self.deviceHealth.usePhone(phoneSerial)
            if self.checkedHealthSerial != serial { self.checkDeviceHealth() }
            self.screenStatus.stringValue = self.mirror?.isRunning == true ? "Screen session running" : "Phone paired and available"
            if self.mirrorWanted && !self.connecting && self.mirrorBackoff.ready() && self.mirror?.isRunning != true { self.startMirror(serial) }
        }
        bridge.onEvents = { [weak self] events in self?.receive(events) }
        bridge.onPhoneNotificationsEnabled = { [weak self] on in
            self?.turnOnNotificationsButton.isHidden = on
            self?.updateSyncStatus()
        }
        bridge.files.onStatus = { [weak self] text in self?.fileStatus.stringValue = text }
        bridge.files.onReceived = { [weak self] url in self?.receivedFile(url) }
        bridge.files.onClipboard = { [weak self] url in self?.copiedFromPhone(url) }
        bridge.start()
        autoClipboard.onStatus = { [weak self] text in self?.fileStatus.stringValue = text }
        autoClipboard.onText = { [weak self] text in self?.copiedTextFromPhone(text) }
        autoClipboard.onFile = { [weak self] url in
            self?.rememberReceived(url)
            self?.copiedFromPhone(url, announce: false)
        }
        autoClipboard.enabled = autoCopyEnabled
        autoClipboard.start()
        mirrorRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !phoneSerial.isEmpty, self.mirrorWanted, !self.connecting, !self.pairingBusy, self.mirrorBackoff.ready(), self.mirror?.isRunning != true else { return }
            self.findAndOpenScreen()
        }
        notifications.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            DispatchQueue.main.async { self.enableAlerts() } // ask once, on first launch
        }
        if phoneSerial.isEmpty {
            if let endpoint = UserDefaults.standard.string(forKey: "verifiedPhoneEndpoint") { adoptPreviouslyPairedPhone(endpoint) }
            else { showPairPhone() }
        }
    }

    func makeWindow() {
        // Minimal layout: who/status, one primary action, quick tools, notifications, files. Everything else is in ⚙︎.
        let size = NSSize(width: 448, height: 644)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "JH Mirror"
        window.isRestorable = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .windowBackground; background.blendingMode = .behindWindow; background.state = .active
        window.contentView = background
        window.center()
        let content = background

        let icon = NSImageView(frame: NSRect(x: 22, y: 556, width: 44, height: 44))
        icon.image = NSApplication.shared.applicationIconImage
        content.addSubview(icon)
        let title = NSTextField(labelWithString: "JH Mirror")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.frame = NSRect(x: 76, y: 578, width: 280, height: 24)
        content.addSubview(title)

        syncDot = NSView(frame: NSRect(x: 77, y: 562, width: 7, height: 7))
        syncDot.wantsLayer = true
        syncDot.layer?.cornerRadius = 3.5
        syncDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        content.addSubview(syncDot)

        syncStatus = NSTextField(labelWithString: "Connecting…")
        syncStatus.font = .systemFont(ofSize: 12)
        syncStatus.textColor = .secondaryLabelColor
        syncStatus.lineBreakMode = .byTruncatingTail
        syncStatus.frame = NSRect(x: 90, y: 558, width: 294, height: 16)
        content.addSubview(syncStatus)
        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))!,
                            target: self, action: #selector(showSettingsMenu(_:)))
        gear.bezelStyle = .texturedRounded; gear.isBordered = false
        gear.frame = NSRect(x: 396, y: 566, width: 30, height: 30)
        gear.toolTip = "Settings"
        content.addSubview(gear)
        turnOnNotificationsButton = NSButton(title: "Turn On", target: self, action: #selector(turnOnPhoneNotifications))
        turnOnNotificationsButton.controlSize = .small; turnOnNotificationsButton.bezelStyle = .rounded
        turnOnNotificationsButton.frame = NSRect(x: 318, y: 555, width: 70, height: 22)
        turnOnNotificationsButton.isHidden = true
        content.addSubview(turnOnNotificationsButton)

        button = NSButton(title: "Open Phone Screen", target: self, action: #selector(connect))
        button.bezelStyle = .rounded; button.controlSize = .large
        button.keyEquivalent = "\r"
        button.frame = NSRect(x: 22, y: 498, width: 404, height: 40)
        content.addSubview(button)

        spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 477, width: 14, height: 14))
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)
        screenStatus = NSTextField(labelWithString: "")
        screenStatus.font = .systemFont(ofSize: 11)
        screenStatus.textColor = .secondaryLabelColor
        screenStatus.alignment = .center
        screenStatus.lineBreakMode = .byTruncatingTail
        screenStatus.frame = NSRect(x: 42, y: 476, width: 364, height: 16)
        content.addSubview(screenStatus)

        let quickItems: [(String, String, Selector, String)] = [
            ("folder", "Files", #selector(showPhoneFiles), "Browse phone files (⌘3)"),
            ("photo.on.rectangle", "Media", #selector(showPhoneMedia), "Browse phone photos, videos and audio (⌘2)"),
            ("square.grid.2x2", "Apps", #selector(showPhoneApps), "Open or manage phone apps"),
            ("checklist", "Check", #selector(showDeviceHealth), "Device Check · feature status and compatibility")
        ]
        for (index, item) in quickItems.enumerated() {
            let quick = PopoverActionButton(symbol: item.0, title: item.1, target: self, action: item.2)
            quick.frame = NSRect(x: 22 + CGFloat(index) * 103, y: 424, width: 95, height: 44)
            quick.toolTip = item.3
            content.addSubview(quick)
        }

        notificationsHeading = NSTextField(labelWithString: "Notifications")
        notificationsHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        notificationsHeading.frame = NSRect(x: 24, y: 394, width: 240, height: 18)
        content.addSubview(notificationsHeading)
        clearNotificationsButton = NSButton(title: "Clear", target: self, action: #selector(clearNotifications))
        clearNotificationsButton.isBordered = false; clearNotificationsButton.contentTintColor = .controlAccentColor
        clearNotificationsButton.font = .systemFont(ofSize: 12, weight: .medium)
        clearNotificationsButton.frame = NSRect(x: 370, y: 392, width: 56, height: 20)
        clearNotificationsButton.isHidden = true
        content.addSubview(clearNotificationsButton)

        table = NSTableView(frame: NSRect(x: 0, y: 0, width: 404, height: 246))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notification"))
        column.width = 392
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(notificationRowDoubleClicked) // one click opens it on the phone
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 140, width: 408, height: 246))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        content.addSubview(scroll)

        emptyNotificationsBox = NSView(frame: NSRect(x: 24, y: 214, width: 400, height: 96))
        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "bell.badge", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 24, weight: .light))!)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.frame = NSRect(x: 184, y: 58, width: 32, height: 32)
        emptyNotificationsBox.addSubview(emptyIcon)
        emptyNotifications = NSTextField(labelWithString: "Phone notifications appear here.\nClick one to open it on the phone.")
        emptyNotifications.alignment = .center
        emptyNotifications.maximumNumberOfLines = 2
        emptyNotifications.textColor = .tertiaryLabelColor
        emptyNotifications.font = .systemFont(ofSize: 12)
        emptyNotifications.frame = NSRect(x: 0, y: 12, width: 400, height: 36)
        emptyNotificationsBox.addSubview(emptyNotifications)
        content.addSubview(emptyNotificationsBox)

        alertStatus = NSTextField(labelWithString: "")
        alertStatus.font = .systemFont(ofSize: 11)
        alertStatus.textColor = .secondaryLabelColor
        alertStatus.lineBreakMode = .byTruncatingTail
        alertStatus.frame = NSRect(x: 24, y: 114, width: 400, height: 16)
        content.addSubview(alertStatus)

        let filesCard = NSBox(frame: NSRect(x: 22, y: 42, width: 404, height: 60))
        filesCard.boxType = .custom
        filesCard.fillColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.14)
        filesCard.borderColor = NSColor.separatorColor.withAlphaComponent(0.35)
        filesCard.borderWidth = 1
        filesCard.cornerRadius = 10
        content.addSubview(filesCard)

        let folderIcon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Files")!
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))!)
        folderIcon.contentTintColor = .controlAccentColor
        folderIcon.frame = NSRect(x: 36, y: 61, width: 22, height: 22)
        content.addSubview(folderIcon)

        let filesTitle = NSTextField(labelWithString: "Received Files")
        filesTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        filesTitle.frame = NSRect(x: 66, y: 74, width: 180, height: 16)
        content.addSubview(filesTitle)

        fileStatus = NSTextField(labelWithString: "Files from the phone save to Downloads › JH Mirror")
        fileStatus.font = .systemFont(ofSize: 11)
        fileStatus.textColor = .secondaryLabelColor
        fileStatus.lineBreakMode = .byTruncatingTail
        fileStatus.frame = NSRect(x: 66, y: 54, width: 218, height: 15)
        content.addSubview(fileStatus)

        latestFileButton = NSButton(title: "Latest", target: self, action: #selector(showLatestFile))
        latestFileButton.bezelStyle = .rounded; latestFileButton.controlSize = .small
        latestFileButton.toolTip = "Reveal the most recently received file in Finder"
        latestFileButton.frame = NSRect(x: 290, y: 60, width: 58, height: 24)
        if let path = UserDefaults.standard.string(forKey: "latestReceivedFile") { latestFile = URL(fileURLWithPath: path) }
        latestFileButton.isEnabled = latestFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        content.addSubview(latestFileButton)

        let folder = NSButton(title: "Folder", target: self, action: #selector(openReceivedFiles))
        folder.bezelStyle = .rounded; folder.controlSize = .small
        folder.toolTip = "Open Downloads › JH Mirror in Finder"
        folder.frame = NSRect(x: 352, y: 60, width: 62, height: 24)
        content.addSubview(folder)

        let footer = NSTextField(labelWithString: "Developed by Johirul Hoq Akash")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center
        footer.frame = NSRect(x: 24, y: 14, width: 400, height: 14)
        content.addSubview(footer)

        // Kept for their state; their actions live in the ⚙︎ menu, not on screen.
        audioButton = NSButton(title: "", target: self, action: #selector(toggleAudio))
        pauseButton = NSButton(title: "", target: self, action: #selector(toggleSync))
        autoCopyButton = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleAutoCopy))
        autoCopyButton.state = autoCopyEnabled ? .on : .off
    }

    @discardableResult func label(_ text: String, frame: NSRect) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.frame = frame
        window.contentView!.addSubview(field)
        return field
    }

    @objc func openReceivedFiles() {
        do {
            try FileManager.default.createDirectory(at: FileTransferClient.receivedFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(FileTransferClient.receivedFolder)
        } catch { fileStatus.stringValue = "Cannot open received folder: \(error.localizedDescription)" }
    }
    @objc func showLatestFile() {
        guard let latestFile, FileManager.default.fileExists(atPath: latestFile.path) else {
            latestFileButton.isEnabled = false; return
        }
        NSWorkspace.shared.activateFileViewerSelecting([latestFile])
    }
    func receivedFile(_ url: URL) {
        deviceHealth.record(.files, success: true, reason: "A file from this phone was received and verified on the Mac.")
        rememberReceived(url)
        guard alertsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = "File received from " + (UserDefaults.standard.string(forKey: "phoneName") ?? "your phone")
        content.body = url.lastPathComponent + " · saved in Downloads / JH Mirror"
        content.sound = .default
        content.userInfo = ["receivedFile": url.path]
        notifications.add(UNNotificationRequest(identifier: "file-" + UUID().uuidString, content: content, trigger: nil))
    }

    func rememberReceived(_ url: URL) {
        latestFile = url; latestFileButton.isEnabled = true
        UserDefaults.standard.set(url.path, forKey: "latestReceivedFile")
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        recentFiles = Array(recentFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(8))
        UserDefaults.standard.set(recentFiles.map(\.path), forKey: "recentReceivedFiles")
        tools?.setRecentFiles(recentFiles)
    }

    /// A phone item sent with Copy to Mac: put it on the Mac clipboard.
    /// Text copied on the phone (auto-copy). Identical text is ignored, so Mac → phone copies do not bounce back.
    func copiedTextFromPhone(_ text: String) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: .string) != text else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        fileStatus.stringValue = "Copied text from phone · press ⌘V to paste"
        rememberClip(PhoneClip(text: text, file: nil, date: Date()))
    }

    @objc func toggleAutoCopy() {
        autoCopyEnabled.toggle()
        UserDefaults.standard.set(autoCopyEnabled, forKey: "autoCopyFromPhone")
        autoCopyButton.state = autoCopyEnabled ? .on : .off
        autoClipboard.enabled = autoCopyEnabled
        fileStatus.stringValue = autoCopyEnabled ? "Auto-copy on · connecting to the phone…"
            : "Auto-copy off · use Copy to Mac on the phone when you need it"
    }

    func copiedFromPhone(_ url: URL, announce: Bool = true) {
        guard placeOnPasteboard(url, providers: &pasteboardProviders) else {
            fileStatus.stringValue = "Received \(url.lastPathComponent) but could not place it on the clipboard."; return
        }
        fileStatus.stringValue = "Copied from phone · press ⌘V to paste · \(url.lastPathComponent)"
        rememberClip(PhoneClip(text: nil, file: url, date: Date()))
        connectionLog("Phone clipboard item placed on Mac clipboard")
        guard announce, alertsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = "Copied from your phone"
        content.body = "Press ⌘V to paste " + url.lastPathComponent
        content.userInfo = ["receivedFile": url.path]
        notifications.add(UNNotificationRequest(identifier: "clipboard-" + UUID().uuidString, content: content, trigger: nil))
    }

    /// Sidebar click on a recent file: copy it for ⌘V.
    func copyReceivedFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            recentFiles.removeAll { $0 == url }; tools.setRecentFiles(recentFiles); return
        }
        fileStatus.stringValue = placeOnPasteboard(url, providers: &pasteboardProviders)
            ? "Copied \(url.lastPathComponent) · press ⌘V in any app to paste"
            : "Could not copy \(url.lastPathComponent)."
    }

    func sendFilesToPhone(_ urls: [URL]) {
        fileStatus.stringValue = "Preparing to send \(urls.count) item(s) to the phone…"
        fileTransfers.upload(urls, folder: "Download") { [weak self] error in
            self?.fileStatus.stringValue = error?.localizedDescription ?? "Queued for phone Downloads · open Files for progress"
        }
    }

    @objc func copyPhoneClipboard() {
        fileStatus.stringValue = "Asking the phone for its clipboard…"
        bridge.copyPhoneClipboard { [weak self] text in self?.fileStatus.stringValue = text }
    }

    @objc func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            alertStatus.stringValue = "Could not change Open at Login: \(error.localizedDescription). Use System Settings → General → Login Items."
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let path = info["receivedFile"] as? String {
            let url = URL(fileURLWithPath: path)
            if url.deletingLastPathComponent().standardizedFileURL == FileTransferClient.receivedFolder.standardizedFileURL {
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        if let key = info["phoneKey"] as? String, !key.hasPrefix("mac-test-") {
            let package = (info["phonePackage"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let identifier = response.actionIdentifier
            let text = (response as? UNTextInputNotificationResponse)?.userText
            DispatchQueue.main.async {
                switch identifier {
                case UNNotificationDefaultActionIdentifier:
                    self.openOnPhone(key: key, package: package)
                case UNNotificationDismissActionIdentifier:
                    self.bridge.notificationCommand("dismiss", key: key) { _ in }
                case let id where id.hasPrefix("action-"):
                    guard let index = Int(id.dropFirst("action-".count)) else { return }
                    self.bridge.notificationCommand("action", key: key, index: index, text: text) { result in
                        self.alertStatus.stringValue = result == "done"
                            ? (text == nil ? "Done on your phone." : "Reply sent from your phone.")
                            : result == "offline" ? "Phone not connected. Click Reconnect in the menu bar."
                            : "That notification is no longer on the phone."
                    }
                default: break
                }
            }
        }
        completionHandler()
    }

    func makeMenus() {
        let main = NSMenu()
        let item = NSMenuItem()
        let menu = NSMenu()
        let about = NSMenuItem(title: "About JH Mirror", action: #selector(showAbout), keyEquivalent: ""); about.target = self
        menu.addItem(about)
        let dashboard = NSMenuItem(title: "Dashboard…", action: #selector(showPanel), keyEquivalent: ","); dashboard.target = self
        menu.addItem(dashboard)
        menu.addItem(.separator())
        let pairItem = NSMenuItem(title: "Pair Phone…", action: #selector(showPairPhone), keyEquivalent: ""); pairItem.target = self
        menu.addItem(pairItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide JH Mirror", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Quit JH Mirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu; main.addItem(item)
        // Standard editing so ⌘C/⌘V work in text fields (pairing code, addresses).
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)
        let windowItem = NSMenuItem(); let windowMenu = NSMenu(title: "Window")
        for (title, action, key) in [("Phone Screen", #selector(openPhoneScreen), "1"),
                                     ("Media Library", #selector(showPhoneMedia), "2"),
                                     ("Phone Files", #selector(showPhoneFiles), "3")] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self
            windowMenu.addItem(entry)
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu; main.addItem(windowItem)
        let helpItem = NSMenuItem(); let help = NSMenu(title: "Help")
        for (title, action) in [("Quick Start…", #selector(showQuickStart)),
                                ("Setup & Add-ons…", #selector(showCallSetup))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self
            help.addItem(entry)
        }
        helpItem.submenu = help; main.addItem(helpItem); NSApplication.shared.helpMenu = help
        NSApplication.shared.mainMenu = main
        let autosave = "com.johirulhoqakash.jhmirror.statusitem"
        let positionKey = "NSStatusItem Preferred Position \(autosave)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            // New icons start at the far left, where a full menu bar hides them behind the camera notch.
            UserDefaults.standard.set(220.0, forKey: positionKey)
        }
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Remembers where you ⌘-drag it, and cannot be dragged out of the menu bar by accident.
        menuItem.autosaveName = autosave
        menuItem.behavior = []
        menuItem.isVisible = true
        menuItem.button?.image = NSImage(systemSymbolName: "smartphone", accessibilityDescription: "JH Mirror")
            ?? NSImage(systemSymbolName: "iphone", accessibilityDescription: "JH Mirror")
        menuItem.button?.target = self
        menuItem.button?.action = #selector(statusItemClicked)
        menuItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menuItem.button?.toolTip = "JH Mirror · click for phone preview · right-click for menu"
        makePopover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.checkMenuBarIcon() }
    }

    /// Warns when macOS hides the icon (full menu bar behind the notch, or switched off in Menu Bar settings).
    func checkMenuBarIcon() {
        guard iconPinned, let window = menuItem.button?.window, let screen = window.screen ?? NSScreen.main else {
            if iconPinned { alertStatus.stringValue = "The menu bar icon is hidden by macOS. System Settings → Menu Bar → allow JH Mirror." }
            return
        }
        let frame = window.frame
        let left = screen.auxiliaryTopLeftArea ?? .zero, right = screen.auxiliaryTopRightArea ?? .zero
        let behindNotch = !left.isEmpty && !right.isEmpty && frame.midX > left.maxX && frame.midX < right.minX
        let offScreen = !screen.frame.intersects(frame) || !window.isVisible
        connectionLog("Menu bar icon at x=\(Int(frame.minX)) visible=\(!(behindNotch || offScreen))")
        if behindNotch || offScreen {
            alertStatus.stringValue = "Menu bar full: hold ⌘ and drag the JH Mirror icon next to the clock, or hide other icons."
        }
    }

    // MARK: Settings menu (⚙︎, right-click on the menu bar icon, and ⋯ in the popover)

    /// Built fresh each time so every checkmark shows the current state.
    func buildSettingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, on: Bool? = nil, symbol: String? = nil, enabled: Bool = true) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; entry.isEnabled = enabled
            if let on { entry.state = on ? .on : .off }
            if let symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(entry)
        }
        let name = UserDefaults.standard.string(forKey: "phoneName") ?? (phoneSerial.isEmpty ? "No phone paired" : "Your phone")
        let header = NSMenuItem(title: name, action: nil, keyEquivalent: ""); header.isEnabled = false
        menu.addItem(header)
        item(mirror?.isRunning == true ? "Close Phone Screen" : "Open Phone Screen", #selector(connect), symbol: "iphone")
        item("Phone Tools", #selector(showPhoneTools), symbol: "sidebar.right")
        item("Phone Files…", #selector(showPhoneFiles), symbol: "folder")
        item("Phone Media Library…", #selector(showPhoneMedia), symbol: "photo.on.rectangle")
        item("Phone App Library…", #selector(showPhoneApps), symbol: "square.grid.2x2")
        item("Dashboard…", #selector(showPanel), symbol: "rectangle.grid.1x2")
        item("Device Check…", #selector(showDeviceHealth), symbol: "checklist")
        item("Received Files", #selector(openReceivedFiles), symbol: "folder")
        menu.addItem(.separator())
        item("Use Phone Camera & Microphone", #selector(startCallInputs), symbol: "video.badge.waveform")
        item(calls.camera == .off ? "Open Phone Camera…" : "Phone Camera · Live…", #selector(showCameraPanel),
             on: calls.camera != .off, symbol: "video")
        item(calls.microphone == .off ? "Use Phone Microphone for Calls" : "Stop Phone Microphone", #selector(toggleCallMicrophone),
             on: calls.microphone != .off, symbol: "mic")
        item("Camera: \(calls.facing == "front" ? "Front" : "Rear") · Switch", #selector(switchCallCamera), symbol: "arrow.triangle.2.circlepath.camera", enabled: !calls.cameraBusy)
        item("Stop Phone Call Inputs", #selector(stopCallInputs), enabled: calls.camera != .off || calls.microphone != .off)
        item("Setup & Add-ons…", #selector(showCallSetup), symbol: "slider.horizontal.3")
        menu.addItem(.separator())
        item("Phone Audio on Mac", #selector(toggleAudio), on: audioEnabled && !deviceHealth.unsupported(.audio))
        item("Clipboard Sync", #selector(toggleClipboard), on: clipboardEnabled)
        item("Auto-copy from Phone", #selector(toggleAutoCopy), on: autoCopyEnabled)
        item(phoneScreenOff ? "Turn Phone Screen On" : "Turn Phone Screen Off", #selector(togglePhoneScreen), on: phoneScreenOff)
        item("Pause Notifications", #selector(toggleSync), on: !receiving)
        menu.addItem(.separator())
        item("Keep Icon in Menu Bar", #selector(toggleIconPinned), on: iconPinned)
        item("Open at Login", #selector(toggleLoginItem), on: SMAppService.mainApp.status == .enabled)
        if !alertsAllowed { item("Allow Mac Notifications…", #selector(enableAlerts)) }
        item("Send Test Notification", #selector(testNotification))
        menu.addItem(.separator())
        item("Pair Phone…", #selector(showPairPhone))
        item("Reinstall Phone App", #selector(phoneSetup))
        item("About JH Mirror", #selector(showAbout))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit JH Mirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc func showSettingsMenu(_ sender: NSButton) {
        buildSettingsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    // MARK: Menu-bar popover

    func makePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = popoverController
        popoverController.setPhoneName(UserDefaults.standard.string(forKey: "phoneName") ?? "Your phone")
        popover.delegate = self
        popoverController.onOpenWindow = { [weak self] in self?.openPhoneWindow() }
        popoverController.onReconnect = { [weak self] in self?.reconnectPhone() }
        popoverController.onDeviceCheck = { [weak self] in self?.showDeviceHealth() }
        popoverController.onCopyClip = { [weak self] clip in self?.copyClipAgain(clip) }
        popoverController.onClearClips = { [weak self] in self?.phoneClips.removeAll() }
        popoverController.onToggleAutoCopy = { [weak self] in self?.toggleAutoCopy() }
        popoverController.onGetPhoneClipboard = { [weak self] in self?.copyPhoneClipboard() }
        popoverController.onCamera = { [weak self] in self?.showCameraPanel() }
        popoverController.onMicrophone = { [weak self] in self?.toggleCallMicrophone() }
        popoverController.onCallSetup = { [weak self] in self?.showCallSetup() }
        popoverController.onFiles = { [weak self] in self?.showPhoneFiles() }
        popoverController.onMedia = { [weak self] in self?.showPhoneMedia() }
        popoverController.onApps = { [weak self] in self?.showPhoneApps() }
        refreshCallControls()
        popoverController.onPinChanged = { [weak self] pinned in
            // Pinned: stays open over other apps until unpinned or the menu bar icon is clicked.
            self?.popover.behavior = pinned ? .applicationDefined : .transient
        }
        popoverController.onMore = { [weak self] in
            guard let self, let button = self.menuItem.button else { return }
            self.popover.performClose(nil)
            self.buildSettingsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
        }
        linkTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshLinkState() }
    }

    @objc func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            if let button = menuItem.button { buildSettingsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button) }
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        guard let button = menuItem.button else { return }
        popoverController.setAutoCopy(autoCopyEnabled)
        popoverController.setClips(phoneClips)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        popoverOpened()
    }

    func popoverOpened() {
        previewStop?.cancel(); previewStop = nil
        refreshLinkState()
        popoverController.showPreviewPane()
        if mirror?.isRunning == true && sawVideo {
            sendMirrorCommand("preview-on")
            popoverController.clearPreview(message: "Loading preview…")
        } else if mirror?.isRunning == true || connecting {
            popoverController.clearPreview(message: "Connecting to the phone screen…")
        } else {
            // Start the screen session hidden just for the preview; Open Window shows it.
            popoverController.clearPreview(message: "Connecting to the phone screen…")
            previewOnlySession = true
            mirrorWindowHidden = true
            mirrorWanted = true
            mirrorBackoff.succeeded()
            findAndOpenScreen()
        }
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            guard let self, let image = self.previewReader.nextImage() else { return }
            self.popoverController.setPreview(image)
        }
    }

    func popoverClosed() {
        popoverController.setPinned(false); popover.behavior = .transient
        previewTimer?.invalidate(); previewTimer = nil
        sendMirrorCommand("preview-off")
        previewReader.close()
        guard previewOnlySession else { return }
        // A session opened only for the preview stops a minute after the popover closes (saves phone battery).
        let stop = DispatchWorkItem { [weak self] in
            guard let self, self.previewOnlySession, !self.popover.isShown else { return }
            self.previewOnlySession = false
            self.mirrorWanted = false // also stops retries if the hidden session had dropped
            if let mirror = self.mirror, mirror.isRunning { self.stopOwnedMirror(mirror, reason: "preview closed") }
        }
        previewStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: stop)
    }

    /// Actions inside the popover close it, unless it is pinned.
    func closePopoverUnlessPinned() { if !popoverController.isPinned { popover.performClose(nil) } }

    @objc func openPhoneScreen() { openPhoneWindow() }

    func openPhoneWindow() {
        closePopoverUnlessPinned()
        previewOnlySession = false
        mirrorWindowHidden = false; mirrorMinimized = false
        if let mirror, mirror.isRunning {
            sendMirrorCommand("show")
            refreshPhoneTools()
        } else {
            mirrorWanted = true
            mirrorBackoff.succeeded()
            if !connecting { findAndOpenScreen() }
        }
    }

    func reconnectPhone() {
        guard !phoneSerial.isEmpty else { popover.performClose(nil); showPairPhone(); return }
        guard reconnectMessage == nil else { return }
        reconnectMessage = "Reconnecting…"
        refreshLinkState()
        mirrorBackoff.succeeded()
        bridge.reconnectNow(progress: { [weak self] text in
            self?.reconnectMessage = text; self?.refreshLinkState()
        }, completion: { [weak self] serial in
            guard let self else { return }
            self.reconnectMessage = nil
            if let serial {
                self.currentSerial = serial
                if self.mirror?.isRunning != true {
                    self.mirrorWanted = true
                    if self.popover.isShown && self.mirrorWindowHidden { self.previewOnlySession = true }
                    if !self.connecting { self.startMirror(serial) }
                }
            } else {
                self.screenStatus.stringValue = "Phone not reachable. Turn on Wireless debugging on the phone, same Wi-Fi."
            }
            self.refreshLinkState()
        })
    }

    /// The name chosen on the phone (Settings → About phone), e.g. "Jh's S23 Ultra"; falls back to the model.
    func loadPhoneName(_ serial: String) {
        guard !phoneNameLoaded else { return }
        phoneNameLoaded = true
        DispatchQueue.global(qos: .utility).async {
            var name = command(["-s", serial, "shell", "settings", "get", "global", "device_name"], timeout: 4).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name == "null" || name.contains("rror") {
                name = command(["-s", serial, "shell", "getprop", "ro.product.model"], timeout: 4).output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !name.isEmpty, name.count < 60, !name.contains("\n") else { return }
            DispatchQueue.main.async {
                UserDefaults.standard.set(name, forKey: "phoneName")
                self.popoverController.setPhoneName(name)
            }
        }
    }

    func copyClipAgain(_ clip: PhoneClip) {
        if let file = clip.file { copyReceivedFile(file) }
        else if let text = clip.text {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            fileStatus.stringValue = "Copied · press ⌘V to paste"
        }
        closePopoverUnlessPinned()
    }

    func rememberClip(_ clip: PhoneClip) {
        if let text = clip.text { phoneClips.removeAll { $0.text == text } }
        if let file = clip.file { phoneClips.removeAll { $0.file == file } }
        phoneClips.insert(clip, at: 0)
        phoneClips = Array(phoneClips.prefix(15))
        popoverController.setClips(phoneClips)
    }

    /// Connection summary for the menu-bar icon and popover, refreshed every second.
    func refreshLinkState() {
        refreshDeviceHealth()
        let screenUp = mirror?.isRunning == true && sawVideo
        if screenUp { noteADBVerified() }
        bridge.adbWanted = mirrorWanted || autoCopyEnabled || popover.isShown
        let adbUp = screenUp || autoClipboard.isActive || adbVerified(within: 30)
        let state: PhoneLinkState = phoneSerial.isEmpty ? .unpaired : reconnectMessage.map { .working($0) }
            ?? (adbUp ? .connected : bridge.syncHealthy ? .syncOnly : .offline)
        menuItem.button?.appearsDisabled = state == .offline
        // Unpinned: the icon only shows while the phone is connected (or the popover is open).
        let iconVisible = iconPinned || popover.isShown || state == .connected || state == .syncOnly
        if menuItem.isVisible != iconVisible { menuItem.isVisible = iconVisible }
        guard popover.isShown else { return }
        popoverController.setState(state)
        popoverController.setAutoCopy(autoCopyEnabled)
        if !screenUp && reconnectMessage == nil && mirror?.isRunning != true && !connecting {
            popoverController.clearPreview(message: state == .unpaired ? "Pair your phone to see it here.\nClick Pair Phone."
                : state == .offline ? "Phone not reachable.\nClick Reconnect."
                : "Screen not connected.\nClick Reconnect or Open Window.")
        }
    }

    @objc func showPanel() {
        popover.performClose(nil)
        PhoneWindowFlow.present(window)
        refreshAlertStatus()
    }
    @objc func showPairPhone() {
        if pairingWindow == nil {
            let pairing = PairPhoneWindow()
            pairing.onBusy = { [weak self] busy in
                guard let self else { return }
                self.pairingBusy = busy
                self.bridge.pairingPaused = busy
                if busy {
                    self.calls.stopAll()
                    self.touchGuard.stop()
                    self.discoveryGeneration += 1
                    self.connecting = false
                    self.spinner.stopAnimation(nil)
                }
            }
            pairing.onPaired = { [weak self] in self?.bridge.resetWifiTrust() }
            pairing.onConnected = { [weak self] serial in
                guard let self else { return }
                self.currentSerial = serial
                self.mirrorWanted = true
                self.bridge.reconnect(serial)
                if let mirror = self.mirror, mirror.isRunning {
                    self.restartingForAudio = true
                    self.stopOwnedMirror(mirror, reason: "re-paired phone")
                } else { self.startMirror(serial) }
            }
            pairingWindow = pairing
        }
        pairingWindow?.open()
    }

    func refreshAlertStatus() {
        notifications.getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.alertsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                self.alertStatus.stringValue = self.alertsAllowed
                    ? "Mac alerts enabled. New notifications also appear below."
                    : "Mac alerts are off. Enable Mac Alerts to receive banners; notification access is enabled separately on the phone."
            }
        }
    }

    @objc func enableAlerts() {
        notifications.requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            DispatchQueue.main.async {
                self.alertsAllowed = allowed
                self.refreshAlertStatus()
                if !allowed {
                    self.alertStatus.stringValue = "Enable JH Mirror in System Settings → Notifications for Mac banners."
                }
            }
        }
    }

    @objc func toggleSync() {
        receiving.toggle()
        UserDefaults.standard.set(receiving, forKey: "receiving")
        pauseButton.title = receiving ? "Pause Sync" : "Resume Sync"
        updateSyncStatus()
        alertStatus.stringValue = receiving ? "Notification delivery resumed." : "Notification delivery paused on this Mac."
    }

    func updateSyncStatus() {
        let name = UserDefaults.standard.string(forKey: "phoneName") ?? (phoneSerial.isEmpty ? "No phone paired" : "Your phone")
        syncStatus.stringValue = name + " · " + (receiving ? connectionText : "Notifications paused on this Mac")
        syncStatus.toolTip = connectionText == "Connected"
            ? "Notifications, files and clipboard sync over encrypted Wi-Fi, independent of the phone screen." : connectionText
        let maxW: CGFloat = turnOnNotificationsButton?.isHidden == false ? 222 : 294
        if syncStatus.frame.width != maxW {
            syncStatus.frame.size.width = maxW
        }
        let dotColor: NSColor = phoneSerial.isEmpty ? .systemGray
            : !receiving ? .systemOrange
            : connectionText == "Connected" ? .systemGreen
            : connectionText.lowercased().contains("not ") || connectionText.lowercased().contains("offline") ? .systemRed : .systemOrange
        syncDot?.layer?.backgroundColor = dotColor.cgColor
    }

    @objc func turnOnPhoneNotifications() {
        turnOnNotificationsButton.isEnabled = false
        bridge.setPhoneNotifications(true) { [weak self] ok in
            guard let self else { return }
            self.turnOnNotificationsButton.isEnabled = true
            if ok {
                self.turnOnNotificationsButton.isHidden = true
                self.updateSyncStatus()
            }
            self.alertStatus.stringValue = ok ? "Phone notifications are on." : "Phone not reachable. Try again when it is connected."
        }
    }

    // MARK: - Incoming call banner

    func showIncomingCall(_ event: PhoneEvent) {
        pendingCall = CallInfo(key: event.key, package: event.packageName, actions: event.actions)
        if incomingCallBanner == nil {
            let banner = IncomingCallBanner()
            banner.onAnswer = { [weak self] in self?.answerIncomingCall() }
            banner.onDecline = { [weak self] in self?.declineIncomingCall() }
            banner.onDismiss = { [weak self] in self?.pendingCall = nil }
            incomingCallBanner = banner
        }
        let callerName = event.title ?? ""
        let callerNumber = event.body ?? ""
        incomingCallBanner?.show(callerName: callerName, callerNumber: callerNumber)
    }

    func dismissIncomingCall() {
        incomingCallBanner?.dismiss(callEnded: true)
        pendingCall = nil
    }

    func answerIncomingCall() {
        guard let call = pendingCall else { return }
        pendingCall = nil
        // Find the "answer" action index
        var answerIndex: Int? = nil
        if let actions = call.actions {
            for (i, action) in actions.enumerated() {
                if let title = action?.title.lowercased(),
                   title.contains("answer") || title.contains("accept") {
                    answerIndex = i; break
                }
            }
        }
        if let idx = answerIndex {
            bridge.notificationCommand("action", key: call.key, package: call.package, index: idx) { _ in }
        } else {
            // Fallback: open the notification (brings up the dialer)
            bridge.notificationCommand("open", key: call.key, package: call.package) { _ in }
        }
        enableSpeakerphoneAfterAnswer()
    }

    func declineIncomingCall() {
        guard let call = pendingCall else { return }
        pendingCall = nil
        // Find the "decline/reject" action index
        var declineIndex: Int? = nil
        if let actions = call.actions {
            for (i, action) in actions.enumerated() {
                if let title = action?.title.lowercased(),
                   title.contains("declin") || title.contains("reject") || title.contains("hang") || title.contains("end") {
                    declineIndex = i; break
                }
            }
        }
        if let idx = declineIndex {
            bridge.notificationCommand("action", key: call.key, package: call.package, index: idx) { _ in }
        } else {
            bridge.notificationCommand("dismiss", key: call.key, package: call.package) { _ in }
        }
    }

    private func enableSpeakerphoneAfterAnswer() {
        let serial = adbVerified(within: 120) ? currentSerial : nil
        guard let serial else { return }
        // Wait for the call to be answered before toggling speakerphone
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) {
            _ = command(["-s", serial, "shell", "input", "keyevent", "168"], timeout: 5)
        }
    }

    func refreshCallControls() {
        let cameraWasLive = deviceHealth.cameraLive, microphoneWasLive = deviceHealth.microphoneLive
        refreshDeviceHealth()
        if calls.camera == .active { deviceHealth.record(.camera, success: true, reason: "Phone camera frames were acknowledged by the Mac virtual-camera component."); requestingCamera = false }
        if calls.microphone == .active { deviceHealth.record(.microphone, success: true, reason: "The phone microphone stream is running through BlackHole."); requestingMicrophone = false }
        if calls.message != lastCallHealthMessage {
            lastCallHealthMessage = calls.message
            let failed = ["fail", "unavailable", "unsupported", "not start", "did not", "disconnected", "in use", "requires", "not installed", "missing"].contains { calls.message.lowercased().contains($0) }
            if failed && (requestingCamera || cameraWasLive) && calls.camera == .off { let show = requestingCamera; requestingCamera = false; featureFailed(.camera, calls.message, show: show) }
            if failed && (requestingMicrophone || microphoneWasLive) && calls.microphone == .off { let show = requestingMicrophone; requestingMicrophone = false; featureFailed(.microphone, calls.message, show: show) }
        }
        popoverController.setCalls(camera: calls.camera, microphone: calls.microphone, message: calls.message)
        cameraWindow?.render()
        if calls.camera != .off || calls.microphone != .off {
            menuItem.button?.toolTip = "JH Mirror · phone call input active"
        } else { menuItem.button?.toolTip = "JH Mirror" }
    }

    @objc func toggleCallCamera() {
        if calls.camera == .off && !calls.cameraBusy {
            withDeviceFeature(.camera) { [weak self] in self?.startCameraInput() }; return
        }
        requestingCamera = false
        calls.toggleCamera(serial: adbVerified(within: 120) ? currentSerial : nil)
        refreshCallControls()
    }
    func startCameraInput() {
        requestingCamera = true
        calls.toggleCamera(serial: adbVerified(within: 120) ? currentSerial : nil)
        refreshCallControls()
        if !calls.cameraSetupAvailable && calls.camera == .off { requestingCamera = false; showCallSetup() }
    }
    @objc func showCameraPanel() {
        withDeviceFeature(.camera) { [weak self] in self?.openCameraPanel() }
    }
    func openCameraPanel() {
        popover.performClose(nil)
        if cameraWindow == nil {
            let panel = CameraWindow(calls: calls)
            panel.onStartStop = { [weak self] in self?.toggleCallCamera() }
            panel.onFacing = { [weak self] value in
                guard let self else { return }; self.calls.setFacing(value, serial: self.currentSerial)
            }
            panel.onRotate = { [weak self] clockwise in self?.calls.rotateCamera(clockwise: clockwise) }
            panel.onMirror = { [weak self] value in self?.calls.setMirrored(value) }
            panel.onSetup = { [weak self] in self?.showCallSetup() }
            panel.onClose = { [weak self] in self?.calls.stopCamera() }
            cameraWindow = panel
        }
        cameraWindow?.open()
        if calls.camera == .off && !calls.cameraBusy { toggleCallCamera() }
    }
    @objc func toggleCallMicrophone() {
        if calls.microphone == .off {
            withDeviceFeature(.microphone) { [weak self] in self?.startMicrophoneInput() }; return
        }
        requestingMicrophone = false
        calls.toggleMicrophone(serial: adbVerified(within: 120) ? currentSerial : nil)
        refreshCallControls()
    }
    func startMicrophoneInput() {
        requestingMicrophone = true
        calls.toggleMicrophone(serial: adbVerified(within: 120) ? currentSerial : nil)
        refreshCallControls()
        if !calls.microphoneSetupAvailable && calls.microphone == .off { requestingMicrophone = false; showCallSetup() }
    }
    @objc func switchCallCamera() { calls.switchFacing(serial: currentSerial) }
    @objc func startCallInputs() {
        let cameraReady = calls.cameraSetupAvailable, microphoneReady = calls.microphoneSetupAvailable
        guard cameraReady || microphoneReady else { showCallSetup(); return }
        if cameraReady { showCameraPanel() }
        if microphoneReady && calls.microphone == .off { toggleCallMicrophone() }
        if !cameraReady { showCallSetup() }
    }
    @objc func stopCallInputs() { calls.stopAll() }
    @objc func showQuickStart() {
        popover.performClose(nil)
        guard let guide = Bundle.main.url(forResource: "Quick Start", withExtension: "html"),
              NSWorkspace.shared.open(guide) else {
            let alert = NSAlert(); alert.messageText = "Quick Start could not open"
            alert.informativeText = "Open Help → Setup & Add-ons for pairing and optional call setup."
            alert.runModal(); return
        }
    }
    @objc func showCallSetup() {
        popover.performClose(nil)
        if let setup = callSetupWindow, let window = setup.window, window.isVisible || window.isMiniaturized {
            setup.refreshStatus(); PhoneWindowFlow.present(window); return
        }
        let setup = CallSetupWindow()
        setup.onSaved = { [weak self] in self?.refreshCallControls() }
        setup.onOpenCamera = { [weak self] in self?.showCameraPanel() }
        setup.onPairPhone = { [weak self] in self?.showPairPhone() }
        setup.onQuickStart = { [weak self] in self?.showQuickStart() }
        callSetupWindow = setup
        if let window = setup.window { PhoneWindowFlow.present(window) }
    }

    @objc func toggleAudio() {
        withDeviceFeature(.audio) { [weak self] in self?.changeAudio() }
    }
    func changeAudio() {
        audioEnabled.toggle()
        UserDefaults.standard.set(audioEnabled, forKey: "audioEnabled")
        audioButton.title = audioEnabled ? "Audio: On" : "Audio: Off"
        guard let mirror, mirror.isRunning else { return }
        restartingForAudio = true
        audioButton.isEnabled = false
        button.isEnabled = false
        screenStatus.stringValue = "Changing audio…"
        stopOwnedMirror(mirror, reason: "audio setting")
    }

    @objc func toggleClipboard() {
        clipboardEnabled.toggle()
        UserDefaults.standard.set(clipboardEnabled, forKey: "clipboardEnabled")
        guard let mirror, mirror.isRunning else { refreshPhoneTools(); return }
        restartingForAudio = true
        audioButton.isEnabled = false
        button.isEnabled = false
        screenStatus.stringValue = "Changing clipboard sync…"
        stopOwnedMirror(mirror, reason: "clipboard setting")
    }

    func makePhoneTools() {
        tools = PhoneToolsPanel()
        tools.onWindow = { [weak self] in self?.toggleMirrorWindow() }
        tools.onAudio = { [weak self] in self?.toggleAudio() }
        tools.onClipboard = { [weak self] in self?.toggleClipboard() }
        tools.onPhoneScreen = { [weak self] in self?.togglePhoneScreen() }
        tools.onGetClipboard = { [weak self] in self?.sendMirrorCommand("get-clipboard") }
        tools.onSetClipboard = { [weak self] in self?.sendMirrorCommand("set-clipboard") }
        tools.onPickFiles = { [weak self] in self?.choosePhoneFiles() }
        tools.onOpenFiles = { [weak self] in self?.openReceivedFiles() }
        tools.onLatestFile = { [weak self] in self?.showLatestFile() }
        tools.onOpenPanel = { [weak self] in self?.showPanel() }
        tools.onDeviceCheck = { [weak self] in self?.showDeviceHealth() }
        tools.onCopyPhoneClipboard = { [weak self] in self?.copyPhoneClipboard() }
        tools.onCopyFile = { [weak self] url in self?.copyReceivedFile(url) }
        tools.onSendToPhone = { [weak self] urls in self?.sendFilesToPhone(urls) }
        tools.onFiles = { [weak self] in self?.showPhoneFiles() }
        tools.onMedia = { [weak self] in self?.showPhoneMedia() }
        tools.onApps = { [weak self] in self?.showPhoneApps() }
        tools.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.sendMirrorCommand(visible ? "tools-visible" : "tools-hidden")
            if !visible { self.appsWindow?.dismiss() }
            if let frame = self.mirrorFrame {
                self.appsWindow?.follow(frame, toolsVisible: visible, visible: self.mirror?.isRunning == true && !self.mirrorWindowHidden && !self.mirrorMinimized, active: false)
            }
        }
        tools.setRecentFiles(recentFiles)
        refreshPhoneTools()
    }

    func refreshPhoneTools() {
        if mirror?.isRunning == true && sawVideo && !quitting && !systemSleeping
            && (phoneScreenOff || (!mirrorWindowHidden && !mirrorMinimized && !previewOnlySession))
            && Date().timeIntervalSince(lastMirrorActivity) >= 4 {
            lastMirrorActivity = Date(); sendMirrorCommand("keep-active")
        }
        tools?.update(running: mirror?.isRunning == true && sawVideo, hidden: mirrorWindowHidden || mirrorMinimized,
                      audio: audioEnabled && !deviceHealth.unsupported(.audio), clipboard: clipboardEnabled,
                      busy: connecting || preparingTouchGuard || restartingForAudio || (mirror?.isRunning == true && !sawVideo),
                      restarting: restartingForAudio || preparingTouchGuard,
                      fileStatus: fileStatus.stringValue, latest: latestFileButton.isEnabled, phoneScreenOff: phoneScreenOff)
    }

    @objc func showPhoneTools() { refreshPhoneTools(); tools.showTools(focus: true) }

    @objc func showPhoneFiles() { openPhoneFiles(media: false) }
    @objc func showPhoneMedia() { openPhoneFiles(media: true) }
    func openPhoneFiles(media: Bool) {
        popover.performClose(nil)
        if phoneFilesWindow == nil {
            phoneFilesWindow = PhoneFilesWindow(client: phoneFilesClient, transfers: fileTransfers, provider: { [weak self] in
                guard let serial = self?.currentSerial, !phoneSerial.isEmpty else { return nil }; return (serial, phoneSerial)
            })
            phoneFilesWindow?.onBrowseResult = { [weak self] mode, error in
                guard let self else { return }
                let feature: DeviceFeature = mode == "list" ? .files : .gallery
                if let error { self.featureFailed(feature, error.localizedDescription, show: true) }
                else if feature == .files { self.deviceHealth.ready(.files, reason: "The shared-storage folder loaded. A complete transfer is verified when you send or save a file.") }
                else { self.deviceHealth.record(.gallery, success: true, reason: "The \(mode) media listing loaded on this connection. Preview and original reads are validated separately.") }
            }
            phoneFilesWindow?.onMediaFailure = { [weak self] error in self?.featureFailed(.gallery, error.localizedDescription, show: true) }
        }
        phoneFilesWindow?.open(media: media, beside: mirrorFrame)
    }

    @objc func showPhoneApps() {
        popover.performClose(nil)
        if appsWindow == nil {
            let library = PhoneAppsWindow(serial: { [weak self] in
                guard adbVerified(within: 120) else { return nil }; return self?.currentSerial
            }, identity: { phoneSerial.isEmpty ? nil : phoneSerial })
            library.onOpen = { [weak self] in self?.openPhoneWindow() }
            library.onCheck = { [weak self] error in
                if let error { self?.featureFailed(.apps, error.localizedDescription, show: true) }
                else { self?.deviceHealth.record(.apps, success: true, reason: "The App Library provider and current Android user were checked. Icons may use today's saved inventory.") }
            }
            appsWindow = library
        }
        if appsWindow?.requestedOpen == true { appsWindow?.dismiss(); return }
        openPhoneWindow()
        appsWindow?.open()
        if let frame = mirrorFrame {
            appsWindow?.follow(frame, toolsVisible: tools.expanded, visible: mirror?.isRunning == true && !mirrorWindowHidden && !mirrorMinimized, active: true)
        }
    }

    func toggleMirrorWindow() {
        guard let mirror, mirror.isRunning else { connect(); return }
        if mirrorMinimized { mirrorWindowHidden = false; mirrorMinimized = false }
        else { mirrorWindowHidden.toggle() }
        sendMirrorCommand(mirrorWindowHidden ? "hide" : "show")
        refreshPhoneTools()
        tools.showTools()
    }

    func sendMirrorCommand(_ action: String) {
        guard let mirror, mirror.isRunning, let input = mirrorInput else { return }
        do { try input.fileHandleForWriting.write(contentsOf: Data(("AW_COMMAND:" + action + "\n").utf8)) }
        catch { screenStatus.stringValue = "Screen connection interrupted. Reopen the phone window." }
    }

    func choosePhoneFiles() {
        if mirror?.isRunning == true {
            mirrorWindowHidden = false
            sendMirrorCommand("show")
        } else if !connecting { mirrorWanted = true; findAndOpenScreen() }
        fileStatus.stringValue = "Opening file picker on phone…"
        bridge.choosePhoneFiles { [weak self] text in self?.fileStatus.stringValue = text }
    }

    func handleMirrorFrame(_ line: String) {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = value["x"] as? Double, let y = value["y"] as? Double,
              let width = value["width"] as? Double, let height = value["height"] as? Double,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        if value["visible"] as? Bool == true && !sawVideo {
            sawVideo = true; screenStatus.stringValue = "Screen connected wirelessly"
            if mirrorWindowHidden { sendMirrorCommand("hide") }
        }
        mirrorMinimized = value["minimized"] as? Bool ?? false
        windowFlow.mirrorFocusChanged(value["active"] as? Bool ?? false)
        mirrorFrame = NSRect(x: x, y: y, width: width, height: height)
        tools.follow(mirrorFrame!,
                     active: value["active"] as? Bool ?? false,
                     visible: value["visible"] as? Bool ?? false,
                     keepVisible: !previewOnlySession && (mirrorWindowHidden || mirrorMinimized || tools.isKeyWindow))
        appsWindow?.follow(mirrorFrame!, toolsVisible: tools.expanded,
                           visible: (value["visible"] as? Bool ?? false) && !mirrorWindowHidden && !mirrorMinimized,
                           active: value["active"] as? Bool ?? false)
    }

    func stopOwnedMirror(_ process: Process, reason: String) {
        screenOffGuardActive = false; deviceHealth.audioLive = false
        appsWindow?.dismiss()
        touchGuard.stop()
        guard process.isRunning else { return }
        connectionLog("Mirror stop requested: " + reason)
        // scrcpy turns SIGTERM into a clean quit and stops its own adb helpers.
        // Escalate only if it has not exited after a grace period.
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            guard process.isRunning else { return }
            connectionLog("Mirror did not stop after SIGTERM; forcing")
            let children = Process()
            children.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            children.arguments = ["-KILL", "-P", String(pid)]
            try? children.run(); children.waitUntilExit()
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    @objc func phoneSetup() {
        syncStatus.stringValue = "Opening setup on your phone…"
        bridge.phoneSetup(apk: Bundle.main.url(forResource: "JH Mirror Companion", withExtension: "apk")) { [weak self] text in
            self?.syncStatus.stringValue = text
        }
    }

    @objc func testNotification() {
        let icon = Bundle.main.url(forResource: "AppIcon64", withExtension: "png")
            .flatMap { try? Data(contentsOf: $0) }?.base64EncodedString()
        let event = PhoneEvent(type: "posted", key: "mac-test-" + UUID().uuidString,
            app: "JH Mirror", title: "JH Mirror test", body: "This notification test appears on your Mac.",
            time: Date().timeIntervalSince1970 * 1000, packageName: companionPackage, icon: icon)
        if !receiving {
            alertStatus.stringValue = "Resume Sync first, then click Test for a Mac notification."
            return
        }
        receive([event])
    }

    @objc func clearNotifications() {
        history.removeAll()
        fingerprints.removeAll()
        deliveredIDs.removeAll()
        table.reloadData()
        notifications.removeAllDeliveredNotifications()
        notifications.removeAllPendingNotificationRequests()
    }

    func notificationID(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func receive(_ events: [PhoneEvent]) {
        for event in events {
            let keyID = notificationID(event.key)
            if event.type == "removed" {
                if let lastID = deliveredIDs.removeValue(forKey: event.key) {
                    notifications.removeDeliveredNotifications(withIdentifiers: [lastID])
                    notifications.removePendingNotificationRequests(withIdentifiers: [lastID])
                }
                notifications.getDeliveredNotifications { items in
                    let ids = items.filter { $0.request.identifier == keyID || $0.request.identifier.hasPrefix(keyID + ".") }.map { $0.request.identifier }
                    self.notifications.removeDeliveredNotifications(withIdentifiers: ids)
                }
                history.removeAll { $0.key == event.key }
                fingerprints.removeValue(forKey: event.key)
                if event.key == pendingCall?.key { dismissIncomingCall() }
                continue
            }
            if event.type == "call_ringing" {
                showIncomingCall(event)
                continue
            }
            guard receiving, event.type == "posted" else { continue }
            let fingerprint = (event.app ?? "") + "\n" + (event.title ?? "") + "\n" + (event.body ?? "")
            guard fingerprints[event.key] != fingerprint || event.title == "JH Mirror test" else { continue }
            fingerprints[event.key] = fingerprint
            history.removeAll { $0.key == event.key }
            history.insert(event, at: 0)
            if history.count > 50 {
                let dropped = history.removeLast()
                fingerprints.removeValue(forKey: dropped.key)
            }
            if alertsAllowed {
                // A new request ID makes each new message alert independently.
                // Remove the prior alert for this phone notification to avoid duplicates.
                if let previous = deliveredIDs[event.key] {
                    notifications.removeDeliveredNotifications(withIdentifiers: [previous])
                }
                let id = keyID + "." + UUID().uuidString
                deliveredIDs[event.key] = id
                let content = UNMutableNotificationContent()
                content.title = event.app ?? "Android"
                content.subtitle = event.title ?? ""
                content.body = event.body ?? ""
                content.sound = .default
                content.threadIdentifier = "android-phone"
                // Interactive: the phone's own buttons, and click/dismiss act on the phone notification.
                content.userInfo = ["phoneKey": event.key, "phonePackage": event.packageName ?? ""]
                let (category, isNewCategory) = notificationCategory(for: event.actions)
                content.categoryIdentifier = category
                var iconURL: URL?
                if let data = iconData(event) {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("JHMirror-\(UUID().uuidString).png")
                    if (try? data.write(to: url)) != nil {
                        iconURL = url
                        if let attachment = try? UNNotificationAttachment(identifier: "phone-app-icon", url: url,
                            options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png",
                                      UNNotificationAttachmentOptionsThumbnailHiddenKey: false]) {
                            content.attachments = [attachment]
                        }
                    }
                }
                let temporaryIcon = iconURL
                let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
                // A just-registered category needs a moment before macOS shows its buttons.
                DispatchQueue.main.asyncAfter(deadline: .now() + (isNewCategory ? 0.3 : 0)) {
                self.notifications.add(request) { error in
                    if let temporaryIcon { try? FileManager.default.removeItem(at: temporaryIcon) }
                    if error != nil { DispatchQueue.main.async { self.alertStatus.stringValue = "Mac could not show a banner. Check System Settings → Notifications." } }
                    else if event.title == "JH Mirror test" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.notifications.getDeliveredNotifications { items in
                                let delivered = items.contains { $0.request.identifier == id }
                                DispatchQueue.main.async {
                                    self.alertStatus.stringValue = delivered
                                        ? "Verified: test notification delivered to Mac Notification Center."
                                        : "Test reached the panel. Check Mac notification settings for banners."
                                }
                            }
                        }
                    }
                }
                }
            }
        }
        table.reloadData()
    }

    // MARK: Interactive notifications

    /// One macOS category per distinct set of phone buttons ("action-<phone index>").
    /// Every category asks for dismiss callbacks so clearing on the Mac clears the phone too.
    func notificationCategory(for actions: [PhoneAction?]?) -> (String, Bool) {
        let buttons = (actions ?? []).enumerated().compactMap { index, action in action.map { (index, $0) } }
        let signature = buttons.map { "\($0.0)|\($0.1.input)|\($0.1.title)" }.joined(separator: "\n")
        let id = "phone-" + SHA256.hash(data: Data(signature.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        if notificationCategories[id] != nil { return (id, false) }
        let macActions: [UNNotificationAction] = buttons.map { index, action in
            action.input
                ? UNTextInputNotificationAction(identifier: "action-\(index)", title: action.title, options: [],
                                                textInputButtonTitle: "Send", textInputPlaceholder: action.title)
                : UNNotificationAction(identifier: "action-\(index)", title: action.title, options: [])
        }
        if notificationCategories.count > 80 { notificationCategories.removeAll() } // bounded; recreated on demand
        notificationCategories[id] = UNNotificationCategory(identifier: id, actions: macActions, intentIdentifiers: [],
                                                            options: [.customDismissAction])
        notifications.setNotificationCategories(Set(notificationCategories.values))
        return (id, true)
    }

    /// Same as tapping the notification on the phone: the phone opens it, and the phone window comes up here.
    func openOnPhone(key: String, package: String?) {
        wakePhone()
        bridge.notificationCommand("open", key: key, package: package) { [weak self] result in
            guard let self else { return }
            switch result {
            case "opened", "app": self.alertStatus.stringValue = "Opened on your phone. If it is locked, unlock it in the phone window."
            case "offline": self.alertStatus.stringValue = "Phone not connected. Click Reconnect in the menu bar."
            default: self.alertStatus.stringValue = "That notification is no longer on the phone."
            }
        }
        openPhoneWindow()
    }

    /// Turns the phone's screen on so an opened app is visible in the phone window.
    func wakePhone() {
        guard !phoneScreenOff else { return } // Opening an app must not relight a deliberately dark phone.
        guard let serial = currentSerial, adbVerified(within: 120) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = command(["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"], timeout: 4)
        }
    }

    /// The phone's own display off (or back on) while you keep using it from the Mac.
    @objc func togglePhoneScreen() {
        if !phoneScreenOff { withDeviceFeature(.screenOff) { [weak self] in self?.changePhoneScreen() }; return }
        changePhoneScreen()
    }
    func changePhoneScreen() {
        guard !preparingTouchGuard else { return }
        if phoneScreenOff {
            screenOffGuardActive = false
            guard let serial = currentSerial else { alertStatus.stringValue = "Phone disconnected. Use its power button to turn it on."; return }
            preparingTouchGuard = true
            touchGuard.allowScreenOn(serial: serial) { [weak self] ready in
                guard let self else { return }; self.preparingTouchGuard = false
                guard !self.quitting else { return }
                if ready {
                    self.phoneScreenOff = false; self.screenOffRequestPending = false
                    UserDefaults.standard.set(false, forKey: "phoneScreenOff")
                    if self.mirror?.isRunning == true { self.sendMirrorCommand("display-on") } else { self.wakePhone() }
                    self.alertStatus.stringValue = "Phone screen is on again."
                } else {
                    self.mirrorWanted = false
                    if let mirror = self.mirror { self.stopOwnedMirror(mirror, reason: "screen-on request disconnected") }
                    self.alertStatus.stringValue = "Phone disconnected. Use its power button to turn it on."
                }
                self.refreshPhoneTools()
            }
        } else if let mirror, mirror.isRunning, let serial = currentSerial {
            preparingTouchGuard = true; screenStatus.stringValue = "Preparing phone touch protection…"
            touchGuard.begin(serial: serial) { [weak self] result in
                guard let self else { return }; self.preparingTouchGuard = false
                guard self.mirror === mirror, mirror.isRunning, !self.quitting else { self.touchGuard.stop(); return }
                if result == .guarded {
                    self.screenOffGuardActive = true
                    self.phoneScreenOff = true; UserDefaults.standard.set(true, forKey: "phoneScreenOff")
                    self.sendMirrorCommand("display-off")
                    self.alertStatus.stringValue = "Phone stays black when hidden, minimized or closed. Turn it on here or with its power button."
                } else { self.alertStatus.stringValue = "Touch protection unavailable. Phone screen was left on."; self.featureFailed(.screenOff, self.touchGuard.failureMessage, show: true) }
                self.refreshPhoneTools()
            }
        } else if mirror?.isRunning == true {
            alertStatus.stringValue = "Reconnect the phone before changing its screen."
        } else {
            phoneScreenOff = true; screenOffRequestPending = true
            UserDefaults.standard.set(true, forKey: "phoneScreenOff")
            mirrorWanted = true; findAndOpenScreen()
        }
        refreshLinkState(); refreshPhoneTools()
    }

    @objc func toggleIconPinned() {
        iconPinned.toggle()
        UserDefaults.standard.set(iconPinned, forKey: "menuBarIconPinned")
        refreshLinkState()
    }

    @objc func notificationRowDoubleClicked() {
        let row = table.clickedRow
        guard history.indices.contains(row) else { return }
        defer { table.deselectAll(nil) }
        let event = history[row]
        if event.packageName == companionPackage && event.key.hasPrefix("mac-test-") { return }
        openOnPhone(key: event.key, package: event.packageName)
    }

    func dismissNotification(key: String) {
        let keyID = notificationID(key)
        if let lastID = deliveredIDs.removeValue(forKey: key) {
            notifications.removeDeliveredNotifications(withIdentifiers: [lastID])
            notifications.removePendingNotificationRequests(withIdentifiers: [lastID])
        }
        notifications.getDeliveredNotifications { items in
            let ids = items.filter { $0.request.identifier == keyID || $0.request.identifier.hasPrefix(keyID + ".") }.map { $0.request.identifier }
            self.notifications.removeDeliveredNotifications(withIdentifiers: ids)
        }
        history.removeAll { $0.key == key }
        fingerprints.removeValue(forKey: key)
        table.reloadData()
        if !key.hasPrefix("mac-test-") {
            bridge.notificationCommand("dismiss", key: key) { _ in }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        emptyNotificationsBox?.isHidden = !history.isEmpty
        clearNotificationsButton?.isHidden = history.isEmpty
        notificationsHeading?.stringValue = history.isEmpty ? "Notifications" : "Notifications (\(history.count))"
        return history.count
    }
    func iconData(_ event: PhoneEvent) -> Data? {
        guard let icon = event.icon, icon.count < 60000,
              let data = Data(base64Encoded: icon), data.count >= 32, data.count < 45000,
              Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else { return nil }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return width == 64 && height == 64 ? data : nil
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard history.indices.contains(row) else { return nil }
        let event = history[row]
        let width = tableColumn?.width ?? 392
        let timeText: String = {
            guard let ms = event.time, ms > 0 else { return "" }
            let date = Date(timeIntervalSince1970: ms / 1000.0)
            return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        }()
        let rowView = DashboardCardRow(frame: NSRect(x: 0, y: 0, width: width, height: 64), timeText: timeText)
        let key = event.key
        rowView.onDismiss = { [weak self] in self?.dismissNotification(key: key) }

        let image = NSImageView(frame: NSRect(x: 12, y: 17, width: 30, height: 30))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 7
        image.layer?.masksToBounds = true
        if let data = iconData(event) { image.image = NSImage(data: data) }
        else { image.image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: event.app) }
        rowView.addSubview(image)

        let heading = NSTextField(labelWithString: [event.app, event.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.frame = NSRect(x: 50, y: 39, width: width - 130, height: 16)
        rowView.addSubview(heading)

        let body = NSTextField(wrappingLabelWithString: event.body ?? "")
        body.font = .systemFont(ofSize: 11.5)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 2
        body.lineBreakMode = .byTruncatingTail
        body.frame = NSRect(x: 50, y: 7, width: width - 64, height: 30)
        rowView.addSubview(body)
        rowView.toolTip = "Click to open on your phone"
        return rowView
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    @objc func connect() {
        guard !connecting else { return }
        if let mirror, mirror.isRunning {
            mirrorWanted = false
            stopOwnedMirror(mirror, reason: "Close Screen")
            return
        }
        mirrorWanted = true
        mirrorBackoff.succeeded()
        findAndOpenScreen()
    }

    func findAndOpenScreen() {
        guard !connecting, !quitting, !pairingBusy else { return }
        guard !phoneSerial.isEmpty else { screenStatus.stringValue = "Pair your phone to start · JH Mirror menu → Pair Phone"; return }
        let generation = discoveryGeneration
        connecting = true; button.isEnabled = false; spinner.startAnimation(nil)
        screenStatus.stringValue = "Finding your phone…"
        DispatchQueue.global(qos: .userInitiated).async {
            let serial = findPhone()
            DispatchQueue.main.async {
                guard self.discoveryGeneration == generation else { return }
                self.connecting = false; self.spinner.stopAnimation(nil)
                if let serial { self.currentSerial = serial; self.startMirror(serial) }
                else { self.mirrorBackoff.failed(); self.screenStatus.stringValue = "Waiting for Wi-Fi / Wireless debugging · retrying automatically"; self.button.isEnabled = true }
            }
        }
    }

    func startMirror(_ serial: String) {
        guard !preparingTouchGuard, !quitting, !systemSleeping, mirrorWanted, mirror?.isRunning != true else { return }
        guard phoneScreenOff else { launchMirror(serial); return }
        if deviceHealth.info == nil {
            guard !deviceProbeBusy else { return }; deviceProbeBusy = true
            readDeviceInfo(serial) { [weak self] ok in
                guard let self else { return }; self.deviceProbeBusy = false
                if ok { self.startMirror(serial) }
                else { self.screenStatus.stringValue = "Could not check Android support for the saved screen-off mode. Reconnect the phone." }
            }; return
        }
        if deviceHealth.unsupported(.screenOff) {
            phoneScreenOff = false; screenOffRequestPending = false; UserDefaults.standard.set(false, forKey: "phoneScreenOff")
            launchMirror(serial); return
        }
        preparingTouchGuard = true
        let generation = discoveryGeneration
        screenStatus.stringValue = "Preparing phone touch protection…"
        let restoring = !screenOffRequestPending; screenOffRequestPending = false
        touchGuard.begin(serial: serial, restoringIntent: restoring) { [weak self] result in
            guard let self else { return }
            self.preparingTouchGuard = false
            guard !self.quitting, !self.pairingBusy, self.mirrorWanted, self.discoveryGeneration == generation else { self.touchGuard.stop(); return }
            if result == .screenOn {
                self.screenOffGuardActive = false
                self.phoneScreenOff = false
                UserDefaults.standard.set(false, forKey: "phoneScreenOff")
            } else if result != .guarded {
                self.touchGuard.stop(); self.mirrorWanted = false
                self.screenStatus.stringValue = "Touch protection unavailable. Phone display stays as it is; turn it on manually or retry."
                self.refreshPhoneTools(); return
            }
            if !self.phoneScreenOff { self.touchGuard.stop() }
            if result == .guarded { self.screenOffGuardActive = true }
            self.launchMirror(serial)
        }
    }

    func launchMirror(_ serial: String) {
        guard !quitting, !systemSleeping, mirrorWanted, mirror?.isRunning != true else { return }
        connectionLog("Mirror starting")
        let process = Process(); let pipe = Pipe(); let input = Pipe()
        process.executableURL = URL(fileURLWithPath: scrcpyPath)
        let windowTitle = (UserDefaults.standard.string(forKey: "phoneName") ?? "Phone") + " · JH Mirror"
        process.arguments = ["-s", serial, "--force-adb-forward", "--no-terminal-title", "--window-borderless", "--window-title", windowTitle, "--max-size", "1600", "--max-fps", "60", "--video-bit-rate", "8M"]
        process.arguments?.append(contentsOf: ["--video-buffer", "50", "--audio-buffer", "80"])
        if let frame = mirrorFrame, let display = NSScreen.screens.first {
            process.arguments?.append(contentsOf: ["--window-x", String(Int(frame.minX)),
                "--window-y", String(Int(display.frame.maxY - frame.maxY)),
                "--window-width", String(Int(frame.width)), "--window-height", String(Int(frame.height))])
        }
        deviceHealth.audioLive = false
        if !audioEnabled || deviceHealth.unsupported(.audio) { process.arguments?.append("--no-audio") }
        if !clipboardEnabled { process.arguments?.append("--no-clipboard-autosync") }
        if phoneScreenOff {
            // Activity pulses keep Android awake; the hardware panel alone goes dark.
            process.arguments?.append(contentsOf: ["--turn-screen-off", "--no-power-on"])
        }
        var environment = adbEnvironment()
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["ADB"] = adbPath
        environment["AW_PHONE_TOOLS"] = "1"
        environment["AW_PERSIST_SCREEN_OFF"] = "1"
        if tools.expanded { environment["AW_TOOLS_VISIBLE"] = "1" } else { environment.removeValue(forKey: "AW_TOOLS_VISIBLE") }
        environment["SDL_MAC_BACKGROUND_APP"] = "1" // one app in the Dock: the phone window belongs to JH Mirror
        environment["AW_PREVIEW_PATH"] = PhonePreviewReader.path.path
        if mirrorWindowHidden { environment["AW_START_HIDDEN"] = "1" } else { environment.removeValue(forKey: "AW_START_HIDDEN") }
        if let server = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) {
            environment["SCRCPY_SERVER_PATH"] = server.path
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = pipe; process.standardError = pipe
        mirror = process; mirrorOutput = pipe; mirrorInput = input
        sawVideo = false; recentLog = ""; mirrorLines = ""; mirrorStarted = Date(); mirrorUserClosed = false
        button.isEnabled = true
        button.title = "Close Phone Screen"
        let readOutput = {
            // Drain helper output continuously so geometry and first-frame
            // messages do not wait for process exit or terminal buffering.
            Thread.detachNewThread {
                let handle = pipe.fileHandleForReading
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    let text = String(decoding: buffer.prefix(count), as: UTF8.self)
            DispatchQueue.main.async {
                guard self.mirror === process else { return }
                self.mirrorLines += text
                while let newline = self.mirrorLines.firstIndex(of: "\n") {
                    let line = String(self.mirrorLines[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.mirrorLines.removeSubrange(...newline)
                    if line == "AW_CLOSE_REQUESTED" {
                        self.mirrorUserClosed = true
                    } else if line == "AW_READY" {
                        self.sawVideo = true; self.screenStatus.stringValue = "Screen connected wirelessly"
                        noteADBVerified()
                        if self.mirrorWindowHidden { self.sendMirrorCommand("hide") }
                        if self.popover.isShown { self.sendMirrorCommand("preview-on") }
                    } else if line == "AW_TOOLS_TOGGLE" {
                        self.tools.toggleTools()
                    } else if line == "AW_AUDIO_READY" {
                        self.deviceHealth.audioLive = true
                        self.deviceHealth.record(.audio, success: true, reason: "Decoded phone audio reached the Mac playback buffer.")
                    } else if line.hasPrefix("AW_FRAME:") {
                        self.handleMirrorFrame(String(line.dropFirst(9)))
                    } else {
                        if line.lowercased().contains("audio") && ["failed", "error", "not supported", "disabled"].contains(where: { line.lowercased().contains($0) }) {
                            self.deviceHealth.audioLive = false; self.featureFailed(.audio, line)
                        }
                        self.recentLog = String((self.recentLog + "\n" + line).suffix(1500))
                        if line.contains("Texture") {
                            self.sawVideo = true; self.screenStatus.stringValue = "Screen connected wirelessly"
                            if self.mirrorWindowHidden { self.sendMirrorCommand("hide") }
                        }
                    }
                }
                if self.mirrorLines.count > 16384 { self.mirrorLines = String(self.mirrorLines.suffix(16384)) }
                self.refreshPhoneTools()
            }
                }
                try? handle.close()
            }
        }
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                guard !self.quitting, self.mirror === process else { return }
                self.appsWindow?.dismiss()
                self.touchGuard.stop()
                self.screenOffGuardActive = false; self.deviceHealth.audioLive = false
                connectionLog("Mirror ended status=\(process.terminationStatus) video=\(self.sawVideo) userClosed=\(self.mirrorUserClosed) wanted=\(self.mirrorWanted)\n\(self.recentLog)")
                pipe.fileHandleForReading.readabilityHandler = nil
                try? input.fileHandleForWriting.close()
                if !self.restartingForAudio && self.mirrorUserClosed { self.mirrorWanted = false }
                if self.mirrorWanted && !self.restartingForAudio {
                    let failure = self.recentLog.split(separator: "\n").filter { $0.contains("ERROR") }.suffix(2).joined(separator: "\n")
                    self.featureFailed(.mirror, failure.isEmpty ? "The screen connection ended. JH Mirror will retry when the phone is reachable." : failure)
                    if self.sawVideo && Date().timeIntervalSince(self.mirrorStarted) > 60 { self.mirrorBackoff.succeeded() }
                    self.mirrorBackoff.failed()
                }
                if self.restartingForAudio, let serial = self.currentSerial {
                    self.restartingForAudio = false
                    self.audioButton.isEnabled = true
                    self.startMirror(serial)
                    return
                }
                self.button.isEnabled = true
                self.button.title = "Open Phone Screen"
                self.screenStatus.stringValue = self.mirrorWanted ? "Screen connection lost · retrying automatically" : "Screen closed"
                self.refreshPhoneTools()
                if !self.previewOnlySession && self.tools.expanded { self.tools.showTools() }
            }
        }
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            readOutput()
            screenStatus.stringValue = "Opening your phone screen…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                guard self.mirror === process, process.isRunning, !self.sawVideo else { return }
                self.stopOwnedMirror(process, reason: "no video within 60 s")
                self.screenStatus.stringValue = "Screen startup interrupted · retrying after a short wait"
            }
        }
        catch { touchGuard.stop(); screenStatus.stringValue = "Could not launch scrcpy."; button.isEnabled = true }
    }

    func popoverDidClose(_ notification: Notification) { popoverClosed() }

    /// Handle reopening ourselves so AppKit cannot also resurrect the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let target = windowFlow.windowToResume(in: sender.orderedWindows + sender.windows,
                                                 mirrorAvailable: mirror?.isRunning == true && sawVideo) {
            PhoneWindowFlow.present(target)
        } else if phoneSerial.isEmpty { showPairPhone() }
        else { openPhoneWindow() }
        return false
    }

    @objc func showAbout() {
        let credits = NSMutableAttributedString(string: "Developed by Johirul Hoq Akash\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: "Your Android phone on your Mac: screen, notifications, files and clipboard.\nScreen mirroring uses scrcpy (Apache 2.0) by Genymobile.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "JH Mirror", .credits: credits])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Settings saved by the earlier "Android Wireless" version of this app.
    func migrateFromAndroidWireless() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedLegacySettings") else { return }
        defaults.set(true, forKey: "migratedLegacySettings")
        guard let old = defaults.persistentDomain(forName: "local.jhakash.android-wireless") else { return }
        for key in ["receiving", "audioEnabled", "clipboardEnabled", "autoCopyFromPhone", "verifiedPhoneEndpoint", "phoneName"]
            where defaults.object(forKey: key) == nil {
            if let value = old[key] { defaults.set(value, forKey: key) }
        }
        connectionLog("Imported settings from Android Wireless")
    }

    /// A phone paired with the earlier version: adopt it without pairing again when it answers.
    func adoptPreviouslyPairedPhone(_ endpoint: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = command(["connect", endpoint], timeout: 8)
            let identity = command(["-s", endpoint, "shell", "getprop", "ro.serialno"], timeout: 6)
            let serial = identity.output.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard identity.code == 0, !serial.isEmpty, serial.count < 64, !serial.contains(" ") else { self.showPairPhone(); return }
                setPairedPhone(serial)
                connectionLog("Kept the phone paired with Android Wireless")
                self.currentSerial = endpoint
                self.bridge.reconnect(endpoint)
                self.mirrorBackoff.succeeded()
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminatingCalls else { return .terminateLater }
        terminatingCalls = true
        quitting = true
        mirrorRetry?.invalidate()
        touchGuard.stop()
        if let mirror, mirror.isRunning { stopOwnedMirror(mirror, reason: "app quitting") }
        calls.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        fileTransfers?.stop()
        touchGuard.stop()
        autoClipboard.stop(); linkTimer?.invalidate(); previewTimer?.invalidate()
        quitting = true; if let activity = awakeActivity { ProcessInfo.processInfo.endActivity(activity) }; mirrorRetry?.invalidate(); toolsTimer?.invalidate(); tools.orderOut(nil); bridge.stop()
        if let mirror, mirror.isRunning {
            stopOwnedMirror(mirror, reason: "app quitting")
            let deadline = Date().addingTimeInterval(2.5)
            while mirror.isRunning && Date() < deadline { usleep(50_000) }
            if mirror.isRunning { kill(mirror.processIdentifier, SIGKILL) }
        }
    }
}

// Read-only bundle check works before pairing and starts no services or capture sessions.
if CommandLine.arguments.contains("--bundle-check") {
    let paths = ["Contents/MacOS/adb", "Contents/Helpers/JH Mirror Screen.app/Contents/MacOS/JHMirrorScreen",
                 "Contents/Resources/scrcpy-server", "Contents/Resources/JH Mirror Companion.apk",
                 "Contents/Resources/Quick Start.html"]
    let missing = paths.filter { !FileManager.default.isReadableFile(atPath: Bundle.main.bundleURL.appendingPathComponent($0).path) }
    guard missing.isEmpty else { fputs("Incomplete JH Mirror bundle: \(missing.joined(separator: ", "))\n", stderr); exit(1) }
    print("JH Mirror \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "") · all core components included")
    exit(0)
}

// Read-only diagnostics exit before creating the launcher, adb server or capture sessions.
if CommandLine.arguments.contains("--diagnose-call-devices") {
    print("Direct camera component: \(CallCamera.available ? "available" : "not available")")
    print("BlackHole 2ch: \(CallDevices.loopback() != nil ? "available" : "not available")")
    print("Camera mode: \(CallCamera.usesOBSCompatibility ? "OBS compatibility" : "direct (OBS stays closed)")")
    exit(0)
}

if CommandLine.arguments.contains("--import-obs-setup") {
    do { let port = try OBSLocalSetup.importSettings(); print("Local OBS settings saved securely (port \(port))."); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--check") {
    if let serial = findPhone() { print("Phone discovered: \(serial)"); exit(0) }
    fputs("Paired phone not found. Enable Wireless debugging on the same Wi-Fi.\n", stderr); exit(1)
}

let application = NSApplication.shared
let instanceLock: AppInstanceLock?
do { instanceLock = try AppInstanceLock(directory: WifiPeer.directory) }
catch {
    let alert = NSAlert(); alert.messageText = "JH Mirror could not start"
    alert.informativeText = "Its private application folder could not be opened. " + error.localizedDescription
    alert.runModal(); exit(1)
}
guard instanceLock != nil else {
    // A second downloaded/review copy must not restart the active app's private
    // ADB server, duplicate notifications or interrupt an in-progress transfer.
    if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.johirulhoqakash.jhmirror")
        .first(where: { $0.processIdentifier != getpid() }), let url = existing.bundleURL {
        NSWorkspace.shared.open(url)
    }
    exit(0)
}
let launcher = Launcher()
application.setActivationPolicy(.regular)
application.delegate = launcher
withExtendedLifetime(instanceLock) { application.run() }

