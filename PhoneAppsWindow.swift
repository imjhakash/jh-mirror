import AppKit

private final class AppDrawerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
private final class AppDrawerCollection: NSCollectionView {
    var onOpen: (() -> Void)?
    var onDismiss: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() }
        else if event.keyCode == 36 || event.keyCode == 49 { onOpen?() }
        else { super.keyDown(with: event) }
    }
}

/// Four columns of icons beside the mirror. Inventory refreshes once per local calendar day.
final class PhoneAppsWindow: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    var onCheck: ((Error?) -> Void)?
    var onOpen: (() -> Void)?
    private let serial: () -> String?
    private let identity: () -> String?
    private let client: PhoneAppsClient
    private let cache: PhoneAppsCache
    private let queue = DispatchQueue(label: "jhmirror.apps", qos: .userInitiated)
    private let collection = AppDrawerCollection()
    private let scroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh apps")!, target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var items: [PhoneApp] = []
    private var shown: [PhoneApp] = []
    private var snapshotUser = 0
    private var snapshotSerial: String?
    private var snapshotIdentity: String?
    private var fetchedAt: Date?
    private var busy = false
    private var connected = false
    private var dailyTimer: Timer?
    private var icons: [String: NSImage] = [:]
    private let tileID = NSUserInterfaceItemIdentifier("PhoneAppTile")
    private(set) var requestedOpen = false

    init(serial: @escaping () -> String?, identity: @escaping () -> String?,
         client: PhoneAppsClient = PhoneAppsClient(), cache: PhoneAppsCache = PhoneAppsCache()) {
        self.serial = serial; self.identity = identity; self.client = client; self.cache = cache
        let window = AppDrawerPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 620),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Phone App Drawer · JH Mirror"; window.isReleasedWhenClosed = false
        window.isFloatingPanel = false; window.level = .normal; window.hasShadow = true
        window.isOpaque = false; window.backgroundColor = .clear; window.collectionBehavior = [.fullScreenAuxiliary]
        super.init(window: window); window.delegate = self
        let view = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 620))
        view.material = .popover; view.blendingMode = .behindWindow; view.state = .active
        view.wantsLayer = true; view.layer?.cornerRadius = 16; view.layer?.masksToBounds = true
        window.contentView = view
        refreshButton.isBordered = false; refreshButton.imagePosition = .imageOnly
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.frame = NSRect(x: 322, y: 586, width: 26, height: 26)
        refreshButton.autoresizingMask = [.minXMargin, .minYMargin]
        refreshButton.target = self; refreshButton.action = #selector(refreshClicked)
        refreshButton.toolTip = "Refresh apps · otherwise updates once daily"
        refreshButton.setAccessibilityLabel("Refresh phone apps"); view.addSubview(refreshButton)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: 327, y: 591, width: 16, height: 16); spinner.autoresizingMask = [.minXMargin, .minYMargin]; view.addSubview(spinner)
        scroll.frame = NSRect(x: 8, y: 10, width: 344, height: 568); scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let layout = NSCollectionViewFlowLayout(); layout.minimumInteritemSpacing = 4; layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 2, left: 4, bottom: 8, right: 4)
        collection.collectionViewLayout = layout; collection.isSelectable = true; collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]; collection.dataSource = self; collection.delegate = self
        collection.frame = scroll.contentView.bounds; collection.autoresizingMask = [.width]
        collection.register(PhoneAppTile.self, forItemWithIdentifier: tileID)
        collection.setAccessibilityLabel("Phone app drawer, four columns")
        collection.onOpen = { [weak self] in self?.openSelected() }
        collection.onDismiss = { [weak self] in self?.dismiss() }
        scroll.documentView = collection; view.addSubview(scroll)
        empty.alignment = .center; empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor
        empty.frame = NSRect(x: 28, y: 240, width: 304, height: 90); empty.autoresizingMask = [.width, .height]
        empty.isHidden = true; view.addSubview(empty)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { dailyTimer?.invalidate() }
    func open() {
        requestedOpen = true
        window?.makeKeyAndOrderFront(nil)
        refresh(force: false)
    }
    func dismiss() {
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        requestedOpen = false; dailyTimer?.invalidate(); dailyTimer = nil; window?.orderOut(nil)
    }
    func toggle() { if requestedOpen { dismiss() } else { open() } }
    override func close() { dismiss() }
    func windowWillClose(_ notification: Notification) { requestedOpen = false; dailyTimer?.invalidate(); dailyTimer = nil }
    func windowDidResize(_ notification: Notification) { collection.collectionViewLayout?.invalidateLayout() }
    static func drawerFrame(mirror: NSRect, available: NSRect, toolsVisible: Bool) -> NSRect {
        let width = min(360, available.width - 16), height = min(max(320, mirror.height), min(720, available.height - 16))
        let toolsOnRight = mirror.maxX + 56 <= available.maxX
        let right = mirror.maxX + (toolsVisible && toolsOnRight ? 64 : 8)
        let left = mirror.minX - width - (toolsVisible && !toolsOnRight ? 64 : 8)
        var x = right + width <= available.maxX - 4 ? right : left
        x = min(max(available.minX + 8, x), available.maxX - width - 8)
        let y = min(max(available.minY + 8, mirror.maxY - height), available.maxY - height - 8)
        return NSRect(x: x, y: y, width: width, height: height)
    }
    func follow(_ frame: NSRect, toolsVisible: Bool, visible: Bool, active: Bool) {
        guard let window else { return }
        let available = (NSScreen.screens.max { a, b in
            let x = a.frame.intersection(frame), y = b.frame.intersection(frame)
            return x.width * x.height < y.width * y.height
        } ?? NSScreen.main)?.visibleFrame ?? frame
        window.setFrame(Self.drawerFrame(mirror: frame, available: available, toolsVisible: toolsVisible), display: true)
        collection.collectionViewLayout?.invalidateLayout()
        guard requestedOpen && visible else { window.orderOut(nil); return }
        let wasVisible = window.isVisible
        if !wasVisible || active || window.isKeyWindow { window.orderFrontRegardless() }
        if !wasVisible { refresh(force: false) }
    }
    @objc private func refreshClicked() { refresh(force: true) }
    private func scheduleDailyRefresh() {
        dailyTimer?.invalidate(); dailyTimer = nil
        guard requestedOpen else { return }
        let timer = Timer(timeInterval: max(1, cache.nextDay.timeIntervalSince(cache.currentDate)), repeats: false) { [weak self] _ in
            guard let self else { return }; self.dailyTimer = nil
            if self.window?.isVisible == true { self.refresh(force: false) }
        }
        RunLoop.main.add(timer, forMode: .common); dailyTimer = timer
    }
    private func refresh(force: Bool) {
        guard !busy, window?.attachedSheet == nil else { return }
        guard let identity = identity(), !identity.isEmpty else { return }
        if snapshotIdentity != nil && snapshotIdentity != identity { items = []; shown = []; icons.removeAll(); collection.reloadData() }
        guard let serial = serial() else {
            connected = false; empty.stringValue = "Connect your phone to refresh apps."; empty.isHidden = !shown.isEmpty; updateAvailability(); return
        }
        busy = true; connected = false; empty.stringValue = "Loading apps…"; empty.isHidden = !shown.isEmpty
        spinner.startAnimation(nil); refreshButton.isHidden = true; updateAvailability()
        queue.async {
            var saved: PhoneAppsCache.Entry?
            let result = Result { () -> PhoneAppsCache.Entry in
                let user = try self.client.currentUser(serial)
                saved = self.cache.load(identity: identity, user: user)
                if let entry = saved {
                    DispatchQueue.main.async {
                        guard self.identity() == identity, self.serial() == serial else { return }
                        self.apply(entry, serial: serial, identity: identity)
                    }
                    if !force && self.cache.isFresh(entry) { return entry }
                }
                let snapshot = try self.client.list(serial: serial, user: user)
                self.cache.save(snapshot, identity: identity)
                return self.cache.load(identity: identity, user: user)!
            }
            let cached = saved
            DispatchQueue.main.async {
                self.busy = false; self.spinner.stopAnimation(nil); self.refreshButton.isHidden = false
                guard self.identity() == identity, self.serial() == serial else { self.connected = false; self.updateAvailability(); return }
                switch result {
                case .success(let entry):
                    self.onCheck?(nil)
                    self.connected = true; self.apply(entry, serial: serial, identity: identity)
                    self.refreshButton.toolTip = "Refresh apps · updates automatically once daily"
                case .failure(let error):
                    self.onCheck?(error)
                    self.connected = cached != nil
                    if let cached { self.apply(cached, serial: serial, identity: identity) }
                    else { self.items = []; self.shown = []; self.collection.reloadData() }
                    self.empty.stringValue = error.localizedDescription
                    self.empty.isHidden = !self.shown.isEmpty
                    self.refreshButton.toolTip = error.localizedDescription + "\nClick to retry."
                }
                self.updateAvailability(); self.scheduleDailyRefresh()
            }
        }
    }
    private var selected: PhoneApp? {
        guard let path = collection.selectionIndexPaths.first, shown.indices.contains(path.item) else { return nil }
        return shown[path.item]
    }
    private var actionsAvailable: Bool { connected && !busy && serial() == snapshotSerial && identity() == snapshotIdentity }
    private func apply(_ entry: PhoneAppsCache.Entry, serial: String, identity: String) {
        let old = selected?.package
        items = entry.snapshot.apps; snapshotUser = entry.snapshot.user; snapshotSerial = serial; snapshotIdentity = identity; fetchedAt = entry.fetchedAt
        shown = items.filter(\.canOpen).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        icons.removeAll(); collection.selectionIndexPaths = []; collection.reloadData()
        if let old, let row = shown.firstIndex(where: { $0.package == old }) { collection.selectionIndexPaths = [IndexPath(item: row, section: 0)] }
        empty.stringValue = "No apps to show.\nClick the refresh icon to try again."
        empty.isHidden = !shown.isEmpty || busy
    }
    private func updateAvailability() {
        refreshButton.isEnabled = !busy
        for item in collection.visibleItems() {
            if let path = collection.indexPath(for: item), let tile = item as? PhoneAppTile, shown.indices.contains(path.item) { configure(tile, at: path) }
        }
    }
    private func select(_ package: String) {
        guard let index = shown.firstIndex(where: { $0.package == package }) else { return }
        collection.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        window?.makeFirstResponder(collection)
    }
    private func configure(_ item: PhoneAppTile, at path: IndexPath) {
        let app = shown[path.item]
        if icons[app.package] == nil, let encoded = app.icon, let data = Data(base64Encoded: encoded), data.count <= 49152 { icons[app.package] = NSImage(data: data) }
        item.configure(app: app, icon: icons[app.package], available: actionsAvailable,
            select: { [weak self] in self?.select(app.package) },
            open: { [weak self] in self?.select(app.package); self?.openSelected() },
            remove: { [weak self] in self?.select(app.package); self?.confirmUninstall() })
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: tileID, for: indexPath) as! PhoneAppTile
        configure(item, at: indexPath); return item
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        NSSize(width: max(1, floor((scroll.contentView.bounds.width - 8 - 3 * 4) / 4)), height: 104)
    }
    @objc private func openSelected() {
        guard actionsAvailable, let app = selected, app.canOpen, let serial = snapshotSerial else { return }
        let user = snapshotUser
        perform({ try self.client.open(app, serial: serial, user: user) }) { self.onOpen?() }
    }
    @objc private func confirmUninstall() {
        guard actionsAvailable, let app = selected, app.canUninstall, let serial = snapshotSerial, let identity = snapshotIdentity, let window else { return }
        let user = snapshotUser, fetchedAt = self.fetchedAt
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Uninstall \(app.displayName)?"
        alert.informativeText = "This removes the app and its local data from your phone."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn, self.actionsAvailable else { return }
            self.perform({ try self.client.uninstall(app, serial: serial, user: user) }) {
                self.items.removeAll { $0.package == app.package }
                let snapshot = PhoneAppsSnapshot(user: user, apps: self.items)
                self.queue.async {
                    self.cache.save(snapshot, identity: identity, fetchedAt: fetchedAt)
                }
                let entry = PhoneAppsCache.Entry(schema: 1, identity: identity, fetchedAt: fetchedAt ?? self.cache.currentDate, snapshot: snapshot)
                self.apply(entry, serial: serial, identity: identity)
            }
        }
    }
    private func perform(_ operation: @escaping () throws -> Void, success: @escaping () -> Void) {
        busy = true; updateAvailability()
        queue.async {
            let result = Result { try operation() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success: success()
                case .failure(let error):
                    if let window = self.window {
                        let alert = NSAlert(); alert.messageText = "Could not complete the app action"; alert.informativeText = error.localizedDescription
                        alert.beginSheetModal(for: window)
                    }
                }
                self.updateAvailability()
            }
        }
    }
}
