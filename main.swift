import AppKit
import Foundation
import UserNotifications
import CryptoKit
import Darwin

func connectionLog(_ text: String) {
    let folder = WifiPeer.directory
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = folder.appendingPathComponent("connection.log")
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int, size > 1_000_000 { try? Data().write(to: url, options: .atomic) }
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data((ISO8601DateFormatter().string(from: Date()) + " " + text + "\n").utf8)) }
}

let phoneSerial = "R5CW515PYBR"
let adbPath = "/opt/homebrew/bin/adb"
let mirrorApp = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Phone Screen.app")
let mirrorExecutable = mirrorApp.appendingPathComponent("Contents/MacOS/PhoneScreen").path
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
    var adbEnvironment = ProcessInfo.processInfo.environment
    adbEnvironment["ADB_MDNS_AUTO_CONNECT"] = "0"
    process.environment = adbEnvironment
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


final class Launcher: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!
    var screenStatus: NSTextField!
    var syncStatus: NSTextField!
    var alertStatus: NSTextField!
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
    var currentSerial: String?
    var mirrorWanted = true
    var mirrorRetry: Timer?
    var mirrorBackoff = RetryGate()
    var mirrorStarted = Date.distantPast
    var mirrorFrame: NSRect?
    var awakeActivity: NSObjectProtocol?
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
    var connectionText = "Connecting notification sync…"
    let bridge = BridgeClient()
    let notifications = UNUserNotificationCenter.current()

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifications.delegate = self
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApplication.shared.applicationIconImage = NSImage(contentsOf: icon)
        }
        receiving = UserDefaults.standard.object(forKey: "receiving") as? Bool ?? true
        audioEnabled = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? true
        UserDefaults.standard.removeObject(forKey: "trackpadEnabled")
        clipboardEnabled = UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool ?? true
        awakeActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Android Wi-Fi connection")
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.mirrorBackoff.succeeded()
            self?.bridge.tick()
        }
        makeWindow()
        makeMenus()
        makePhoneTools()
        toolsTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.refreshPhoneTools() }
        refreshAlertStatus()
        bridge.onStatus = { [weak self] text in
            self?.connectionText = text
            self?.updateSyncStatus()
        }
        bridge.onPhone = { [weak self] serial in
            guard let self else { return }
            self.currentSerial = serial
            self.screenStatus.stringValue = self.mirror?.isRunning == true ? "Screen session running" : "Phone paired and available"
            if self.mirrorWanted && !self.connecting && self.mirrorBackoff.ready() && self.mirror?.isRunning != true { self.startMirror(serial) }
        }
        bridge.onEvents = { [weak self] events in self?.receive(events) }
        bridge.files.onStatus = { [weak self] text in self?.fileStatus.stringValue = text }
        bridge.files.onReceived = { [weak self] url in self?.receivedFile(url) }
        bridge.start()
        mirrorRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.mirrorWanted, !self.connecting, !self.pairingBusy, self.mirrorBackoff.ready(), self.mirror?.isRunning != true else { return }
            self.findAndOpenScreen()
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 636),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Android Wireless"
        window.isReleasedWhenClosed = false
        window.center()
        let title = label("Samsung on your Mac", frame: NSRect(x: 24, y: 468, width: 570, height: 30))
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        screenStatus = label("Finding your paired phone…", frame: NSRect(x: 24, y: 431, width: 302, height: 24))
        audioButton = NSButton(title: audioEnabled ? "Audio: On" : "Audio: Off", target: self, action: #selector(toggleAudio))
        audioButton.bezelStyle = .rounded
        audioButton.frame = NSRect(x: 338, y: 427, width: 118, height: 32)
        audioButton.toolTip = "Play phone audio on the Mac. Changing this restarts screen sharing; notifications continue."
        window.contentView!.addSubview(audioButton)
        button = NSButton(title: "Open Screen", target: self, action: #selector(connect))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 469, y: 427, width: 125, height: 32)
        window.contentView!.addSubview(button)
        spinner = NSProgressIndicator(frame: NSRect(x: 316, y: 434, width: 16, height: 16))
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        window.contentView!.addSubview(spinner)
        let heading = label("Phone notifications", frame: NSRect(x: 24, y: 391, width: 570, height: 24))
        heading.frame.size.width = 225
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let toolButton = NSButton(title: "Show Phone Tools", target: self, action: #selector(showPhoneTools))
        toolButton.bezelStyle = .rounded
        toolButton.frame = NSRect(x: 374, y: 386, width: 219, height: 32)
        window.contentView!.addSubview(toolButton)
        let pairPhone = NSButton(title: "Pair Phone", target: self, action: #selector(showPairPhone))
        pairPhone.bezelStyle = .rounded
        pairPhone.frame = NSRect(x: 260, y: 386, width: 110, height: 32)
        window.contentView!.addSubview(pairPhone)
        syncStatus = label("Connecting notification sync…", frame: NSRect(x: 24, y: 346, width: 570, height: 42))
        syncStatus.font = .systemFont(ofSize: 13)
        let setup = NSButton(title: "Phone Setup", target: self, action: #selector(phoneSetup))
        setup.bezelStyle = .rounded; setup.frame = NSRect(x: 20, y: 307, width: 122, height: 32)
        window.contentView!.addSubview(setup)
        let alerts = NSButton(title: "Enable Mac Alerts", target: self, action: #selector(enableAlerts))
        alerts.bezelStyle = .rounded; alerts.frame = NSRect(x: 144, y: 307, width: 153, height: 32)
        window.contentView!.addSubview(alerts)
        pauseButton = NSButton(title: receiving ? "Pause Sync" : "Resume Sync", target: self, action: #selector(toggleSync))
        pauseButton.bezelStyle = .rounded; pauseButton.frame = NSRect(x: 300, y: 307, width: 124, height: 32)
        window.contentView!.addSubview(pauseButton)
        let test = NSButton(title: "Test", target: self, action: #selector(testNotification))
        test.bezelStyle = .rounded; test.frame = NSRect(x: 428, y: 307, width: 70, height: 32)
        window.contentView!.addSubview(test)
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearNotifications))
        clear.bezelStyle = .rounded; clear.frame = NSRect(x: 501, y: 307, width: 92, height: 32)
        window.contentView!.addSubview(clear)
        alertStatus = label("", frame: NSRect(x: 24, y: 264, width: 570, height: 37))
        alertStatus.font = .systemFont(ofSize: 12)
        alertStatus.textColor = .secondaryLabelColor
        table = NSTableView(frame: NSRect(x: 0, y: 0, width: 565, height: 195))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notification"))
        column.title = "Recent notifications · kept in memory"
        column.width = 565
        table.addTableColumn(column)
        table.rowHeight = 64
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 48, width: 570, height: 204))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        window.contentView!.addSubview(scroll)
        let footer = label("Close this panel to keep sync running in the menu bar. Quit stops sync.", frame: NSRect(x: 24, y: 12, width: 570, height: 28))
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        for view in window.contentView!.subviews { view.frame.origin.y += 116 }
        let files = label("Files from your phone", frame: NSRect(x: 24, y: 88, width: 360, height: 24))
        files.font = .systemFont(ofSize: 16, weight: .semibold)
        fileStatus = label("Waiting for phone · Phone: Share → Android Wireless", frame: NSRect(x: 24, y: 37, width: 373, height: 45))
        fileStatus.font = .systemFont(ofSize: 12)
        let folder = NSButton(title: "Received Files", target: self, action: #selector(openReceivedFiles))
        folder.bezelStyle = .rounded; folder.frame = NSRect(x: 415, y: 57, width: 179, height: 32)
        window.contentView!.addSubview(folder)
        latestFileButton = NSButton(title: "Show Latest in Finder", target: self, action: #selector(showLatestFile))
        latestFileButton.bezelStyle = .rounded; latestFileButton.frame = NSRect(x: 415, y: 21, width: 179, height: 32)
        if let path = UserDefaults.standard.string(forKey: "latestReceivedFile") { latestFile = URL(fileURLWithPath: path) }
        latestFileButton.isEnabled = latestFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        window.contentView!.addSubview(latestFileButton)
        let location = label("Saved in Downloads / Android Wireless · originals stay on the phone", frame: NSRect(x: 24, y: 5, width: 570, height: 24))
        location.font = .systemFont(ofSize: 10); location.textColor = .secondaryLabelColor
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
        latestFile = url; latestFileButton.isEnabled = true
        UserDefaults.standard.set(url.path, forKey: "latestReceivedFile")
        guard alertsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = "File received from Samsung"
        content.body = url.lastPathComponent + " · saved in Downloads / Android Wireless"
        content.sound = .default
        content.userInfo = ["receivedFile": url.path]
        notifications.add(UNNotificationRequest(identifier: "file-" + UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["receivedFile"] as? String {
            let url = URL(fileURLWithPath: path)
            if url.deletingLastPathComponent().standardizedFileURL == FileTransferClient.receivedFolder.standardizedFileURL {
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        completionHandler()
    }

    func makeMenus() {
        let main = NSMenu()
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Android Wireless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu; main.addItem(item)
        NSApplication.shared.mainMenu = main
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuItem.button?.image = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right", accessibilityDescription: "Android Wireless")
        let tray = NSMenu()
        for (title, action) in [("Open Android Wireless", #selector(showPanel)), ("Open Phone Screen", #selector(connect)),
                                ("Show Phone Tools", #selector(showPhoneTools)),
                                ("Pair Phone", #selector(showPairPhone)),
                                ("Pause / Resume Notifications", #selector(toggleSync))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; tray.addItem(entry)
        }
        tray.addItem(.separator())
        tray.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menuItem.menu = tray
    }

    @objc func showPanel() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
                    self.discoveryGeneration += 1
                    self.connecting = false
                    self.spinner.stopAnimation(nil)
                }
            }
            pairing.onConnected = { [weak self] serial in
                guard let self else { return }
                self.currentSerial = serial
                self.mirrorWanted = true
                self.bridge.reconnect(serial)
                if let mirror = self.mirror, mirror.isRunning {
                    self.restartingForAudio = true
                    self.stopOwnedMirror(mirror)
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
                    self.alertStatus.stringValue = "Enable Android Wireless in System Settings → Notifications for Mac banners."
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
        syncStatus.stringValue = receiving ? connectionText
            : "Paused on this Mac. Click Resume Sync to receive notifications.\n" + connectionText
    }

    @objc func toggleAudio() {
        audioEnabled.toggle()
        UserDefaults.standard.set(audioEnabled, forKey: "audioEnabled")
        audioButton.title = audioEnabled ? "Audio: On" : "Audio: Off"
        guard let mirror, mirror.isRunning else { return }
        restartingForAudio = true
        audioButton.isEnabled = false
        button.isEnabled = false
        screenStatus.stringValue = "Changing audio…"
        stopOwnedMirror(mirror)
    }

    @objc func toggleClipboard() {
        clipboardEnabled.toggle()
        UserDefaults.standard.set(clipboardEnabled, forKey: "clipboardEnabled")
        guard let mirror, mirror.isRunning else { refreshPhoneTools(); return }
        restartingForAudio = true
        audioButton.isEnabled = false
        button.isEnabled = false
        screenStatus.stringValue = "Changing clipboard sync…"
        stopOwnedMirror(mirror)
    }

    func makePhoneTools() {
        tools = PhoneToolsPanel()
        tools.onWindow = { [weak self] in self?.toggleMirrorWindow() }
        tools.onAudio = { [weak self] in self?.toggleAudio() }
        tools.onClipboard = { [weak self] in self?.toggleClipboard() }
        tools.onGetClipboard = { [weak self] in self?.sendMirrorCommand("get-clipboard") }
        tools.onSetClipboard = { [weak self] in self?.sendMirrorCommand("set-clipboard") }
        tools.onPickFiles = { [weak self] in self?.choosePhoneFiles() }
        tools.onOpenFiles = { [weak self] in self?.openReceivedFiles() }
        tools.onLatestFile = { [weak self] in self?.showLatestFile() }
        tools.onOpenPanel = { [weak self] in self?.showPanel() }
        refreshPhoneTools()
    }

    func refreshPhoneTools() {
        tools?.update(running: mirror?.isRunning == true && sawVideo, hidden: mirrorWindowHidden || mirrorMinimized,
                      audio: audioEnabled, clipboard: clipboardEnabled,
                      busy: connecting || restartingForAudio || (mirror?.isRunning == true && !sawVideo),
                      restarting: restartingForAudio,
                      fileStatus: fileStatus.stringValue, latest: latestFileButton.isEnabled)
    }

    @objc func showPhoneTools() { refreshPhoneTools(); tools.showTools(focus: true) }

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
        mirrorFrame = NSRect(x: x, y: y, width: width, height: height)
        tools.follow(mirrorFrame!,
                     active: value["active"] as? Bool ?? false,
                     visible: value["visible"] as? Bool ?? false,
                     keepVisible: mirrorWindowHidden || mirrorMinimized || tools.isKeyWindow)
    }

    func stopOwnedMirror(_ process: Process) {
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        stop.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        do { try stop.run(); stop.waitUntilExit() } catch { }
        if process.isRunning { process.terminate() }
    }

    @objc func phoneSetup() {
        syncStatus.stringValue = "Opening setup on your phone…"
        bridge.phoneSetup(apk: Bundle.main.url(forResource: "Android Wireless Companion", withExtension: "apk")) { [weak self] text in
            self?.syncStatus.stringValue = text
        }
    }

    @objc func testNotification() {
        let icon = Bundle.main.url(forResource: "AppIcon64", withExtension: "png")
            .flatMap { try? Data(contentsOf: $0) }?.base64EncodedString()
        let event = PhoneEvent(type: "posted", key: "mac-test-" + UUID().uuidString,
            app: "Android Wireless", title: "Android Wireless test", body: "This notification test appears on your Mac.",
            time: Date().timeIntervalSince1970 * 1000, packageName: "local.androidwireless.bridge", icon: icon)
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
                continue
            }
            guard receiving, event.type == "posted" else { continue }
            let fingerprint = (event.app ?? "") + "\n" + (event.title ?? "") + "\n" + (event.body ?? "")
            guard fingerprints[event.key] != fingerprint || event.title == "Android Wireless test" else { continue }
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
                var iconURL: URL?
                if let data = iconData(event) {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AndroidWireless-\(UUID().uuidString).png")
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
                notifications.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                    if let temporaryIcon { try? FileManager.default.removeItem(at: temporaryIcon) }
                    if error != nil { DispatchQueue.main.async { self.alertStatus.stringValue = "Mac could not show a banner. Check System Settings → Notifications." } }
                    else if event.title == "Android Wireless test" {
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
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { history.count }
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
        let rowView = NSView(frame: NSRect(x: 0, y: 0, width: tableColumn?.width ?? 565, height: 64))
        let image = NSImageView(frame: NSRect(x: 8, y: 16, width: 32, height: 32))
        image.imageScaling = .scaleProportionallyUpOrDown
        if let data = iconData(event) { image.image = NSImage(data: data) }
        else { image.image = NSImage(systemSymbolName: "app", accessibilityDescription: event.app) }
        rowView.addSubview(image)
        let text = NSTextField(wrappingLabelWithString: "\(event.app ?? "Android") · \(event.title ?? "")\n\(event.body ?? "")")
        text.frame = NSRect(x: 48, y: 3, width: (tableColumn?.width ?? 565) - 56, height: 58)
        text.autoresizingMask = [.width]
        text.font = .systemFont(ofSize: 12)
        text.maximumNumberOfLines = 3
        rowView.addSubview(text)
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
            stopOwnedMirror(mirror)
            return
        }
        mirrorWanted = true
        mirrorBackoff.succeeded()
        findAndOpenScreen()
    }

    func findAndOpenScreen() {
        guard !connecting, !quitting, !pairingBusy else { return }
        let generation = discoveryGeneration
        connecting = true; button.isEnabled = false; spinner.startAnimation(nil)
        screenStatus.stringValue = "Finding your paired Samsung…"
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
        guard !quitting, mirrorWanted, mirror?.isRunning != true else { return }
        connectionLog("Mirror starting")
        let process = Process(); let pipe = Pipe(); let input = Pipe()
        process.executableURL = URL(fileURLWithPath: scrcpyPath)
        process.arguments = ["-s", serial, "--force-adb-forward", "--no-terminal-title", "--window-borderless", "--window-title", "Samsung · Wireless", "--max-size", "1600", "--max-fps", "60", "--video-bit-rate", "8M"]
        process.arguments?.append(contentsOf: ["--video-buffer", "50", "--audio-buffer", "80"])
        if let frame = mirrorFrame, let display = NSScreen.screens.first {
            process.arguments?.append(contentsOf: ["--window-x", String(Int(frame.minX)),
                "--window-y", String(Int(display.frame.maxY - frame.maxY)),
                "--window-width", String(Int(frame.width)), "--window-height", String(Int(frame.height))])
        }
        if !audioEnabled { process.arguments?.append("--no-audio") }
        if !clipboardEnabled { process.arguments?.append("--no-clipboard-autosync") }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["ADB"] = adbPath
        environment["ADB_MDNS_AUTO_CONNECT"] = "0"
        environment["AW_PHONE_TOOLS"] = "1"
        if let server = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) {
            environment["SCRCPY_SERVER_PATH"] = server.path
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = pipe; process.standardError = pipe
        mirror = process; mirrorOutput = pipe; mirrorInput = input
        sawVideo = false; recentLog = ""; mirrorLines = ""; mirrorStarted = Date()
        button.isEnabled = true
        button.title = "Close Screen"
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
                    if line == "AW_READY" {
                        self.sawVideo = true; self.screenStatus.stringValue = "Screen connected wirelessly"
                        if self.mirrorWindowHidden { self.sendMirrorCommand("hide") }
                    } else if line.hasPrefix("AW_FRAME:") {
                        self.handleMirrorFrame(String(line.dropFirst(9)))
                    } else {
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
                connectionLog("Mirror ended status=\(process.terminationStatus) video=\(self.sawVideo)\n\(self.recentLog)")
                pipe.fileHandleForReading.readabilityHandler = nil
                try? input.fileHandleForWriting.close()
                if !self.restartingForAudio && process.terminationStatus == 0 && self.sawVideo && !self.recentLog.contains("Device disconnected") { self.mirrorWanted = false }
                if self.mirrorWanted && !self.restartingForAudio {
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
                self.button.title = "Open Screen"
                self.screenStatus.stringValue = self.mirrorWanted ? "Screen connection lost · retrying automatically" : "Screen closed"
                self.refreshPhoneTools()
                self.tools.showTools()
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
                self.stopOwnedMirror(process)
                self.screenStatus.stringValue = "Screen startup interrupted · retrying after a short wait"
            }
        }
        catch { screenStatus.stringValue = "Could not launch scrcpy."; button.isEnabled = true }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        quitting = true; if let activity = awakeActivity { ProcessInfo.processInfo.endActivity(activity) }; mirrorRetry?.invalidate(); toolsTimer?.invalidate(); tools.orderOut(nil); bridge.stop()
        if let mirror, mirror.isRunning { stopOwnedMirror(mirror) }
    }
}

if CommandLine.arguments.contains("--check") {
    if let serial = findPhone() { print("Phone discovered: \(serial)"); exit(0) }
    fputs("Paired phone not found. Enable Wireless debugging on the same Wi-Fi.\n", stderr); exit(1)
}

let application = NSApplication.shared
let launcher = Launcher()
application.setActivationPolicy(.regular)
application.delegate = launcher
application.run()

