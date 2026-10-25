import AppKit
import UniformTypeIdentifiers
import QuickLookUI

private final class PhoneMediaGrid: NSCollectionView {
    var onOpen: ((Int) -> Void)?
    var onMenu: (() -> NSMenu)?
    var onKey: ((NSEvent) -> Bool)?
    var onCopy: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let index = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            if !selectionIndexPaths.contains(index) { selectionIndexPaths = [index] }
            onOpen?(index.item); return
        }
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if let index = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            if !selectionIndexPaths.contains(index) { selectionIndexPaths = [index] }
        } else { selectionIndexPaths = [] }
        return onMenu?()
    }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    @objc func copy(_ sender: Any?) { onCopy?() }
}
private final class PhoneFilesTable: NSTableView {
    var onMenu: (() -> NSMenu)?
    var onKey: ((NSEvent) -> Bool)?
    var onCopy: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else if row < 0 { deselectAll(nil) }
        return onMenu?()
    }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    @objc func copy(_ sender: Any?) { onCopy?() }
}

private final class PhoneFileDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        if highlighted { NSColor.controlAccentColor.withAlphaComponent(0.10).setFill(); bounds.fill() }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        highlighted = !urls.isEmpty; return urls.isEmpty ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }; onDrop?(urls); return true
    }
}
private final class PhoneMediaImageView: NSImageView {
    var crop = true
    override func draw(_ dirtyRect:NSRect) {
        guard crop,let image,!image.isTemplate,image.size.width>0,image.size.height>0 else{super.draw(dirtyRect);return}
        let scale=max(bounds.width/image.size.width,bounds.height/image.size.height)
        let size=NSSize(width:image.size.width*scale,height:image.size.height*scale)
        NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:bounds).addClip()
        image.draw(in:NSRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
private final class PhoneMediaTile: NSCollectionViewItem {
    let image = PhoneMediaImageView(), label = NSTextField(wrappingLabelWithString: "")
    private let check = NSImageView()
    var path = ""
    var visualMedia = true
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: 140))
        image.frame = NSRect(x: 4, y: 4, width: 142, height: 132); image.imageScaling = .scaleProportionallyDown; image.autoresizingMask = [.width,.height]; image.wantsLayer=true;image.layer?.cornerRadius=8;image.layer?.masksToBounds=true;image.layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor;view.addSubview(image)
        label.frame = NSRect(x: 4, y: 3, width: 142, height: 32); label.maximumNumberOfLines = 2; label.alignment = .center
        label.font = .systemFont(ofSize: 11); label.autoresizingMask = [.width]; view.addSubview(label)
        view.wantsLayer = true; view.layer?.cornerRadius = 10
        check.frame = NSRect(x:122,y:110,width:22,height:22); check.autoresizingMask = [.minXMargin]; check.image = NSImage(systemSymbolName:"checkmark.circle.fill",accessibilityDescription:"Selected"); check.contentTintColor = .controlAccentColor; check.isHidden = !isSelected; view.addSubview(check)
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        image.frame=visualMedia ? view.bounds.insetBy(dx:4,dy:4):NSRect(x:24,y:42,width:view.bounds.width-48,height:view.bounds.height-66)
        label.isHidden=visualMedia;label.frame=NSRect(x:6,y:6,width:view.bounds.width-12,height:30)
        check.frame=NSRect(x:view.bounds.width-30,y:view.bounds.height-30,width:22,height:22)
    }
    override var isSelected: Bool { didSet { if isViewLoaded {
        view.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor; view.layer?.borderWidth = isSelected ? 2 : 0; check.isHidden = !isSelected
    } } }
}
private final class PhoneFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let item: PhoneFile
    let connection: PhoneFileConnection
    let transfers: PhoneFileTransfers
    init(item: PhoneFile, connection: PhoneFileConnection, transfers: PhoneFileTransfers) { self.item = item; self.connection = connection; self.transfers = transfers }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { PhoneFile.transferName(item.name) }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        transfers.download([item], connection: connection, into: url.deletingLastPathComponent(), exact: url, completion: completionHandler)
    }
}

final class PhoneFilesWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSSearchFieldDelegate {
    var onBrowseResult: ((String, Error?) -> Void)?
    var onMediaFailure: ((Error) -> Void)?
    private let client: PhoneFilesAccess
    private let browser: PhoneFilesBrowser
    private let transfers: PhoneFileTransfers
    private let provider: () -> (serial: String, identity: String)?
    private let worker = DispatchQueue(label: "jhmirror.files.browser", qos: .userInitiated)
    private let thumbnailLoader: PhoneThumbnailLoader
    private var thumbnailUpdate: DispatchWorkItem?
    private var thumbnailScrollObserver: NSObjectProtocol?
    private let mediaActions: PhoneMediaActions
    private let previewLoader: PhonePreviewLoader
    private let pasteboard: NSPasteboard
    private var mediaCancellation: PhoneFileCancellation?
    private var mediaBusy = false
    private var mediaGeneration = UUID()
    private var clipboardProviders: [ImagePasteboardProvider] = []
    private var previewWindow: PhoneMediaPreviewWindow?
    private var originalPreviewWindow: NSWindow?
    private let mode = NSSegmentedControl(labels: ["Files", "Photos", "Videos", "Audio"], trackingMode: .selectOne, target: nil, action: nil)
    private let folders = NSPopUpButton()
    private let search = NSSearchField()
    private let pathLabel = NSTextField(labelWithString: "Shared storage")
    private let status = NSTextField(labelWithString: "Connect your phone to browse files.")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let up = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Parent folder")!, target: nil, action: nil)
    private let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!, target: nil, action: nil)
    private let loadingSpinner = NSProgressIndicator()
    private let upload = NSButton(title: "Send to Phone", target: nil, action: nil)
    private let download = NSButton(title: "Save to Mac", target: nil, action: nil)
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let selectButton = NSButton(title: "Select All", target: nil, action: nil)
    private let selectionLabel = NSTextField(labelWithString: "⌘ click or drag to select photos")
    private let newFolder = NSButton(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New folder")!, target: nil, action: nil)
    private let table = PhoneFilesTable(), scroll = NSScrollView(), grid = PhoneMediaGrid(), galleryScroll = NSScrollView()
    private let transferTable = NSTableView(), transferScroll = NSScrollView()
    private let transferToggle = NSButton(title:"Transfers",target:nil,action:nil)
    private let transferSeparator = NSBox()
    private var transfersExpanded = false
    private let progress = NSProgressIndicator()
    private let transferStatus = NSTextField(labelWithString: "Drag Mac files here to send. Drag phone files into Finder to save.")
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let resumeButton = NSButton(title: "Resume", target: nil, action: nil)
    private var connection: PhoneFileConnection?
    private var items: [PhoneFile] = [], shown: [PhoneFile] = []
    private var jobs: [PhoneFileTransfer] = []
    private var remoteChanged = false
    private var path = ""
    private var loading = false
    private var generation = UUID()
    private var displayedMode = -1
    private var displayedPath = ""
    private var lastMediaMode = 1
    private var hasPositioned = false
    private var requestedPhone: (serial: String, identity: String)?
    private var searchTask:DispatchWorkItem?
    private let roots = ["", "Download", "DCIM", "Pictures", "Movies", "Music", "Documents", "Recordings"]

    init(client: PhoneFilesAccess, transfers: PhoneFileTransfers, provider: @escaping () -> (serial: String, identity: String)?,
         pasteboard: NSPasteboard = .general, mediaDirectory: URL = PhoneMediaActions.defaultDirectory) {
        self.client = client; self.browser = PhoneFilesBrowser(client:client); self.transfers = transfers; self.provider = provider
        self.pasteboard = pasteboard; mediaActions = PhoneMediaActions(client: client, directory: mediaDirectory)
        previewLoader = PhonePreviewLoader(client:client)
        thumbnailLoader = PhoneThumbnailLoader(client: client, directory: mediaDirectory.appendingPathComponent("Grid Thumbnails", isDirectory: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Phone Files & Media · JH Mirror"; window.contentMinSize = NSSize(width: 720, height: 500); window.center(); window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window); window.delegate = self
        let view = PhoneFileDropView(frame: NSRect(x: 0, y: 0, width: 900, height: 700)); window.contentView = view
        view.onDrop = { [weak self] urls in self?.send(urls) }
        let clipboardURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        worker.async { [mediaActions] in mediaActions.prune(protecting: clipboardURLs) }
        grid.onMenu = { [weak self] in self?.selectionMenu() ?? NSMenu() }
        table.onMenu = { [weak self] in self?.selectionMenu() ?? NSMenu() }
        grid.onOpen = { [weak self] index in self?.preview(index: index) }
        grid.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        table.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        grid.onCopy = { [weak self] in self?.copySelected() }; table.onCopy = grid.onCopy
        mode.selectedSegment = 0; mode.frame = NSRect(x: 20, y: 647, width: 354, height: 30); mode.autoresizingMask = [.minYMargin]; mode.target = self; mode.action = #selector(modeChanged); view.addSubview(mode)
        search.placeholderString = "Search files"; search.delegate = self; search.frame = NSRect(x: 570, y: 649, width: 230, height: 28); search.autoresizingMask = [.minXMargin,.minYMargin]; view.addSubview(search)
        loadingSpinner.frame = NSRect(x:814,y:654,width:16,height:16); loadingSpinner.autoresizingMask = [.minXMargin,.minYMargin]; loadingSpinner.style = .spinning; loadingSpinner.controlSize = .small; loadingSpinner.isDisplayedWhenStopped = false; view.addSubview(loadingSpinner)
        refresh.frame = NSRect(x: 846, y: 647, width: 32, height: 30); refresh.autoresizingMask = [.minXMargin,.minYMargin]; refresh.bezelStyle = .rounded; refresh.target = self; refresh.action = #selector(refreshClicked); refresh.toolTip = "Refresh files"; view.addSubview(refresh)
        folders.addItems(withTitles: ["Shared storage", "Downloads", "Camera", "Pictures", "Videos", "Music", "Documents", "Recordings"])
        folders.frame = NSRect(x: 20, y: 601, width: 160, height: 30); folders.autoresizingMask = [.minYMargin]; folders.target = self; folders.action = #selector(folderChanged); view.addSubview(folders)
        up.frame = NSRect(x: 188, y: 601, width: 30, height: 30); up.autoresizingMask = [.minYMargin]; up.bezelStyle = .rounded; up.target = self; up.action = #selector(goUp); view.addSubview(up)
        pathLabel.frame = NSRect(x: 230, y: 606, width: 410, height: 22); pathLabel.autoresizingMask = [.width,.minYMargin]; pathLabel.font = .systemFont(ofSize: 12); pathLabel.lineBreakMode = .byTruncatingHead; view.addSubview(pathLabel)
        newFolder.frame = NSRect(x: 650, y: 601, width: 32, height: 30); newFolder.autoresizingMask = [.minXMargin,.minYMargin]; newFolder.bezelStyle = .rounded; newFolder.target = self; newFolder.action = #selector(createFolder); view.addSubview(newFolder)
        upload.frame = NSRect(x: 690, y: 601, width: 188, height: 30); upload.autoresizingMask = [.minXMargin,.minYMargin]; upload.bezelStyle = .rounded; upload.target = self; upload.action = #selector(chooseMacFiles); view.addSubview(upload)
        for (id,title,width) in [("name","Name",440.0),("size","Size",105.0),("date","Modified",240.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.rowHeight = 32; table.allowsMultipleSelection = true; table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openFolder)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle;table.usesAlternatingRowBackgroundColors=true
        table.tableColumns[1].width=92;table.tableColumns[2].width=170
        table.setDraggingSourceOperationMask(.copy, forLocal: false); table.registerForDraggedTypes([.fileURL]); table.draggingDestinationFeedbackStyle = .regular
        scroll.frame = NSRect(x: 20, y: 258, width: 858, height: 332); scroll.autoresizingMask = [.width,.height]; scroll.hasVerticalScroller = true; scroll.documentView = table; view.addSubview(scroll)
        let layout = NSCollectionViewFlowLayout(); layout.minimumInteritemSpacing = 8; layout.minimumLineSpacing = 10; layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        grid.collectionViewLayout = layout; grid.dataSource = self; grid.delegate = self; grid.isSelectable = true; grid.allowsMultipleSelection = true; grid.backgroundColors = [.clear]
        grid.register(PhoneMediaTile.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("Media")); grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        galleryScroll.frame = scroll.frame; galleryScroll.autoresizingMask = [.width,.height]; galleryScroll.hasVerticalScroller = true; grid.frame = galleryScroll.contentView.bounds; grid.autoresizingMask = [.width]; galleryScroll.documentView = grid; galleryScroll.isHidden = true; view.addSubview(galleryScroll)
        galleryScroll.contentView.postsBoundsChangedNotifications = true
        thumbnailScrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: galleryScroll.contentView, queue: .main) { [weak self] _ in self?.scheduleThumbnails() }
        emptyLabel.alignment = .center; emptyLabel.font = .systemFont(ofSize:13); emptyLabel.textColor = .secondaryLabelColor; emptyLabel.maximumNumberOfLines = 3; view.addSubview(emptyLabel)
        for (button,x,width,action) in [(previewButton,20.0,86.0,#selector(previewSelected)),(copyButton,110.0,80.0,#selector(copySelected)),(deleteButton,194.0,86.0,#selector(deleteSelected)),(selectButton,284.0,96.0,#selector(selectAllItems))] {
            button.frame = NSRect(x:x,y:224,width:width,height:28); button.bezelStyle = .rounded; button.target = self; button.action = action; view.addSubview(button)
        }
        previewButton.toolTip = "Preview · double-click a photo or press Space, then use ← → or swipe"
        copyButton.toolTip = "Copy original photos to the Mac clipboard · ⌘C"
        deleteButton.toolTip = "Delete selected photos from the phone after confirmation"
        selectionLabel.frame = NSRect(x:394,y:228,width:482,height:20); selectionLabel.autoresizingMask = [.width]; selectionLabel.font = .systemFont(ofSize:11); selectionLabel.textColor = .secondaryLabelColor; view.addSubview(selectionLabel)
        status.frame = NSRect(x: 22, y: 196, width: 610, height: 20); status.autoresizingMask = [.width]; status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail; view.addSubview(status)
        download.frame = NSRect(x: 690, y: 191, width: 188, height: 30); download.autoresizingMask = [.minXMargin]; download.bezelStyle = .rounded; download.target = self; download.action = #selector(saveSelected); view.addSubview(download)
        transferSeparator.boxType = .separator;view.addSubview(transferSeparator)
        transferStatus.frame = NSRect(x: 22, y: 151, width: 640, height: 22); transferStatus.autoresizingMask = [.width]; transferStatus.font = .systemFont(ofSize: 11); transferStatus.lineBreakMode = .byTruncatingTail; view.addSubview(transferStatus)
        progress.frame = NSRect(x: 22, y: 132, width: 640, height: 6); progress.autoresizingMask = [.width]; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 100; view.addSubview(progress)
        for (button,x,action) in [(pauseButton,690.0,#selector(pauseTransfers)),(resumeButton,784.0,#selector(resumeTransfers))] {
            button.frame = NSRect(x: x, y: 139, width: 94, height: 30); button.autoresizingMask = [.minXMargin]; button.bezelStyle = .rounded; button.target = self; button.action = action; view.addSubview(button)
        }
        let transferColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transfer")); transferColumn.width = 830; transferTable.addTableColumn(transferColumn)
        transferTable.headerView = nil; transferTable.rowHeight = 24; transferTable.dataSource = self; transferTable.delegate = self
        transferScroll.frame = NSRect(x: 20, y: 15, width: 858, height: 105); transferScroll.autoresizingMask = [.width]; transferScroll.hasVerticalScroller = true; transferScroll.documentView = transferTable; view.addSubview(transferScroll)
        transferToggle.target=self;transferToggle.action=#selector(toggleTransfers);transferToggle.bezelStyle = .rounded;view.addSubview(transferToggle)
        layoutContent()
        hasPositioned = window.setFrameUsingName("JHMirrorFilesWindow")
        window.setFrameAutosaveName("JHMirrorFilesWindow")
        updateAvailability(); showTransfers(transfers.snapshot)
    }
    required init?(coder: NSCoder) { fatalError() }
    func open(media: Bool = false, beside mirror: NSRect? = nil) {
        guard let window else { return }
        if !hasPositioned, let mirror, let screen = NSScreen.screens.max(by: {
            let a = $0.frame.intersection(mirror), b = $1.frame.intersection(mirror)
            return a.width * a.height < b.width * b.height
        })?.visibleFrame {
            let width = window.frame.width
            let y = max(screen.minY, min(screen.maxY-window.frame.height, mirror.maxY-window.frame.height))
            if mirror.maxX + width + 16 < screen.maxX { window.setFrameOrigin(NSPoint(x: mirror.maxX + 12, y: y)) }
            else if mirror.minX - width - 12 >= screen.minX { window.setFrameOrigin(NSPoint(x:mirror.minX-width-12,y:y)) }
        }
        hasPositioned = true
        let wasVisible = window.isVisible || window.isMiniaturized
        let targetMode = media ? (mode.selectedSegment > 0 ? mode.selectedSegment : lastMediaMode) : 0
        let changedMode = targetMode != mode.selectedSegment
        if changedMode { search.stringValue = ""; mode.selectedSegment = targetMode }
        let current = provider()
        let samePhone = current != nil && current?.serial == requestedPhone?.serial && current?.identity == requestedPhone?.identity
        PhoneWindowFlow.present(window)
        if changedMode || !wasVisible || !samePhone || displayedMode < 0 || (connection == nil && !loading) {
            load(preservingSelection: !changedMode && samePhone)
        }
    }
    func windowWillClose(_ notification: Notification) { generation = UUID();searchTask?.cancel(); browser.cancel(); loading = false; loadingSpinner.stopAnimation(nil); mediaGeneration = UUID(); mediaCancellation?.cancel(); thumbnailUpdate?.cancel(); thumbnailLoader.cancel(); previewWindow?.close(); previewWindow = nil;originalPreviewWindow?.close();originalPreviewWindow=nil;previewLoader.cancel() }
    deinit { if let thumbnailScrollObserver { NotificationCenter.default.removeObserver(thumbnailScrollObserver) } }
    func windowDidResize(_ notification: Notification) { layoutContent();grid.collectionViewLayout?.invalidateLayout(); updateEmptyState() }
    private func layoutContent() {
        guard let bounds=window?.contentView?.bounds else{return}
        let w=bounds.width,h=bounds.height,media=mode.selectedSegment != 0
        mode.frame=NSRect(x:20,y:h-48,width:340,height:28)
        search.frame=NSRect(x:w-282,y:h-47,width:208,height:26);refresh.frame=NSRect(x:w-52,y:h-48,width:32,height:28);loadingSpinner.frame=NSRect(x:w-70,y:h-40,width:14,height:14)
        folders.isHidden=media;up.isHidden=media;newFolder.isHidden=media
        folders.frame=NSRect(x:20,y:h-93,width:154,height:28);up.frame=NSRect(x:182,y:h-93,width:30,height:28)
        pathLabel.frame=NSRect(x:media ? 24:224,y:h-91,width:w-(media ? 210:460),height:24);pathLabel.font = .systemFont(ofSize:media ? 17:12,weight:media ? .semibold:.regular)
        newFolder.frame=NSRect(x:w-220,y:h-93,width:32,height:28);upload.frame=NSRect(x:w-178,y:h-93,width:158,height:28)
        let drawer:CGFloat=transfersExpanded ? 144:0,base:CGFloat=100+drawer
        scroll.frame=NSRect(x:20,y:base,width:w-40,height:max(100,h-base-108));galleryScroll.frame=scroll.frame
        for (button,x,width) in [(previewButton,20.0,82.0),(copyButton,106.0,70.0),(deleteButton,180.0,82.0),(selectButton,266.0,92.0)] {button.frame=NSRect(x:x,y:58+drawer,width:width,height:28)}
        selectionLabel.frame=NSRect(x:374,y:62+drawer,width:max(80,w-560),height:20)
        download.frame=NSRect(x:w-172,y:58+drawer,width:152,height:28)
        status.frame=NSRect(x:22,y:34+drawer,width:w-44,height:18)
        transferSeparator.frame=NSRect(x:20,y:29+drawer,width:w-40,height:1)
        transferToggle.frame=NSRect(x:w-150,y:0,width:130,height:26);transferToggle.title=transfersExpanded ? "Hide Transfers":"Transfers"
        transferStatus.frame=NSRect(x:22,y:4,width:w-190,height:18);progress.frame=NSRect(x:22,y:26,width:w-44,height:3)
        transferScroll.isHidden = !transfersExpanded;pauseButton.isHidden = !transfersExpanded;resumeButton.isHidden = !transfersExpanded
        transferScroll.frame=NSRect(x:20,y:38,width:w-40,height:102)
        pauseButton.frame=NSRect(x:w-202,y:144,width:86,height:26);resumeButton.frame=NSRect(x:w-112,y:144,width:92,height:26)
        grid.collectionViewLayout?.invalidateLayout();updateEmptyState()
    }
    @objc private func toggleTransfers(){transfersExpanded.toggle();layoutContent()}
    private func updateEmptyState() {
        let frame = scroll.frame
        emptyLabel.frame = NSRect(x:frame.midX-220,y:frame.midY-25,width:440,height:50)
        emptyLabel.isHidden = !shown.isEmpty
        if loading { emptyLabel.stringValue = "Loading \(["files","photos","videos","audio"][mode.selectedSegment])…" }
        else if connection == nil { emptyLabel.stringValue = status.stringValue }
        else { emptyLabel.stringValue = search.stringValue.isEmpty ? "No \(["files","photos","videos","audio files"][mode.selectedSegment]) found here." : "No matching items." }
    }
    private var selected: [PhoneFile] {
        let indexes = mode.selectedSegment == 0 ? table.selectedRowIndexes.map { $0 } : grid.selectionIndexPaths.map(\.item)
        return indexes.sorted().compactMap { shown.indices.contains($0) ? shown[$0] : nil }
    }
    private func updateAvailability() {
        let available = !loading && !mediaBusy
        mode.isEnabled = !mediaBusy; search.isEnabled = !mediaBusy
        up.isEnabled = available && mode.selectedSegment == 0 && !path.isEmpty
        folders.isEnabled = available && mode.selectedSegment == 0; newFolder.isEnabled = available && connection != nil && mode.selectedSegment == 0
        refresh.isEnabled = !mediaBusy; upload.isEnabled = connection != nil && available; download.isEnabled = !selected.isEmpty && available && connection != nil
        let ready = !loading && !mediaBusy && connection != nil, selection = selected
        previewButton.isEnabled = ready && selection.first.map { ["photo","video","audio"].contains($0.kind) } == true
        let photosReady = ready && !selection.isEmpty && selection.allSatisfy { $0.kind == "photo" && !$0.directory }
        copyButton.title=mediaCancellation == nil ? "Copy":"Cancel";copyButton.isEnabled = photosReady || mediaCancellation != nil
        copyButton.action=mediaCancellation == nil ? #selector(copySelected):#selector(cancelMedia)
        copyButton.toolTip=mediaCancellation == nil ? "Copy original photos to the Mac clipboard · ⌘C":"Cancel the current download"
        deleteButton.isEnabled = photosReady
        selectButton.isEnabled = !loading && !shown.isEmpty
        selectionLabel.stringValue = selection.isEmpty ? "" : "\(selection.count) selected"
    }
    @objc private func modeChanged() { search.stringValue = ""; load() }
    @objc private func folderChanged() { path = roots[folders.indexOfSelectedItem]; mode.selectedSegment = 0; load() }
    @objc private func refreshClicked() { thumbnailLoader.invalidate();previewLoader.invalidate();previewWindow?.close(); load(force:true) }
    @objc private func goUp() { path = (path as NSString).deletingLastPathComponent; load() }
    @objc private func openFolder() {
        guard mode.selectedSegment == 0, table.clickedRow >= 0, shown.indices.contains(table.clickedRow) else { return }
        let item = shown[table.clickedRow]
        if item.directory { path = item.path; load() } else if ["photo","video","audio"].contains(item.kind) { preview(index: table.clickedRow) } else { saveSelected() }
    }
    func controlTextDidChange(_ notification: Notification) {
        searchTask?.cancel()
        guard items.count>1000 else{filter();return}
        let task=DispatchWorkItem{ [weak self] in self?.filter() };searchTask=task
        DispatchQueue.main.asyncAfter(deadline:.now()+0.12,execute:task)
    }
    private func filter(preservingSelection: Bool = false) {
        let paths = preservingSelection ? Set(selected.map(\.path)) : []
        let filtered = items.filter { search.stringValue.isEmpty || $0.displayName.localizedStandardContains(search.stringValue) }
        if !preservingSelection || filtered != shown {
            let clip = mode.selectedSegment == 0 ? scroll.contentView : galleryScroll.contentView
            let position = clip.bounds.origin
            shown = filtered
            table.deselectAll(nil); grid.selectionIndexPaths = []
            if mode.selectedSegment == 0 {
                table.reloadData()
                table.selectRowIndexes(IndexSet(shown.indices.filter { paths.contains(shown[$0].path) }), byExtendingSelection: false)
            } else {
                grid.reloadData()
                scheduleThumbnails()
                grid.selectionIndexPaths = Set(shown.indices.filter { paths.contains(shown[$0].path) }.map { IndexPath(item: $0, section: 0) })
            }
            if preservingSelection { clip.scroll(to: position) }
        }
        updateAvailability(); updateEmptyState()
    }
    private func load(force: Bool = false, preservingSelection: Bool = false) {
        generation = UUID();searchTask?.cancel(); browser.cancel()
        if mode.selectedSegment > 0 { lastMediaMode = mode.selectedSegment }
        requestedPhone = provider()
        guard let current = requestedPhone else { status.stringValue = "Connect the paired phone to browse shared storage."; connection = nil; loading = false; items = []; filter(); loadingSpinner.stopAnimation(nil); return }
        loading = true
        if !preservingSelection { table.deselectAll(nil); grid.selectionIndexPaths = [] }
        let generation = generation, location = mode.selectedSegment == 0 ? path : "", selectedMode = mode.selectedSegment
        if displayedMode != selectedMode || displayedPath != location { items = []; filter() }
        displayedMode = selectedMode; displayedPath = location
        thumbnailUpdate?.cancel(); thumbnailLoader.cancel(); status.stringValue = selectedMode == 0 ? "Reading folder…" : "Loading media library…"; updateAvailability()
        updateEmptyState()
        loadingSpinner.startAnimation(nil)
        scroll.isHidden = selectedMode != 0; galleryScroll.isHidden = selectedMode == 0
        pathLabel.stringValue = selectedMode == 0 ? (location.isEmpty ? "Shared storage" : location) : ["","Photos","Videos","Audio"][selectedMode]
        layoutContent()
        var receivedPreview = false
        browser.load(serial:current.serial,identity:current.identity,path:location,mode:["list","photo","video","audio"][selectedMode],force:force, preview: { [weak self] connection, list in
            guard let self, self.generation == generation else { return }
            receivedPreview = true; self.connection = connection; self.items = list.items; self.loading = false
            self.status.stringValue = "\(list.items.count.formatted()) recent items · loading the rest…"
            self.filter(preservingSelection: true)
        }) { result in
                guard self.generation == generation else { return }; self.loading = false; self.loadingSpinner.stopAnimation(nil)
                switch result {
                case .success(let (connection,list)):
                    self.onBrowseResult?(["list","photo","video","audio"][selectedMode], nil)
                    self.connection = connection; self.items = list.items.sorted { a,b in selectedMode == 0 && a.directory != b.directory ? a.directory : selectedMode == 0 ? a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending : a.modified > b.modified }
                    self.status.stringValue = "\(list.items.count.formatted()) \(["items","photos","videos","audio files"][selectedMode])" + (list.truncated ? " · Browse a subfolder for more" : "")
                case .failure(let error):
                    self.connection = nil; self.thumbnailLoader.cancel(); self.previewLoader.cancel()
                    if receivedPreview {
                        self.status.stringValue = "Library incomplete · Refresh to load the rest. " + error.localizedDescription
                    } else { self.items = []; self.status.stringValue = error.localizedDescription }
                    self.onBrowseResult?(["list","photo","video","audio"][selectedMode], error)
                }
                self.filter(preservingSelection: preservingSelection || receivedPreview)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === table ? shown.count : min(60,jobs.count) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(); let text = NSTextField(labelWithString: ""); text.font = .systemFont(ofSize: 12); text.lineBreakMode = .byTruncatingTail
        if tableView === transferTable {
            let job = jobs[jobs.count-1-row]
            text.stringValue = "\(job.upload ? "↑" : "↓")  \(job.file.displayName)   ·   \(job.state)" + (job.message.isEmpty ? "" : " · " + job.message)
            text.frame = NSRect(x: 4, y: 3, width: tableView.bounds.width-12, height: 18); text.autoresizingMask = [.width]; cell.addSubview(text); return cell
        }
        let item = shown[row], column = tableColumn?.identifier.rawValue ?? "name"
        if column == "name" {
            let image = NSImageView(frame:NSRect(x:5,y:6,width:20,height:20)); image.image = NSImage(systemSymbolName: symbol(item), accessibilityDescription:nil); cell.addSubview(image); text.stringValue = item.displayName
            text.frame = NSRect(x:34,y:7,width:(tableColumn?.width ?? 400)-40,height:18)
        } else {
            text.stringValue = column == "size" ? (item.directory ? "—" : ByteCountFormatter.string(fromByteCount:item.size,countStyle:.file)) : Date(timeIntervalSince1970:Double(item.modified)/1000).formatted(date:.abbreviated,time:.shortened)
            text.textColor = .secondaryLabelColor; text.frame = NSRect(x:4,y:7,width:(tableColumn?.width ?? 150)-8,height:18)
        }
        text.autoresizingMask = [.width]; cell.addSubview(text); return cell
    }
    private func symbol(_ file: PhoneFile) -> String { ["folder":"folder.fill","photo":"photo","video":"video","audio":"music.note" ][file.kind] ?? "doc" }
    func tableViewSelectionDidChange(_ notification: Notification) { updateAvailability() }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { tableView === table ? promise(shown[row]) : nil }
    private func promise(_ file: PhoneFile) -> NSFilePromiseProvider? {
        guard let connection else { return nil }
        let delegate = PhoneFilePromise(item:file,connection:connection,transfers:transfers); _ = delegate
        let type = file.directory ? UTType.folder.identifier : (UTType(filenameExtension:(file.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier)
        let provider = NSFilePromiseProvider(fileType:type,delegate:delegate); provider.userInfo = delegate; return provider
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === table, connection != nil, mode.selectedSegment == 0 else { return [] }
        tableView.setDropRow(-1,dropOperation:.on); return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }; send(urls); return true
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(withIdentifier:NSUserInterfaceItemIdentifier("Media"),for:indexPath) as! PhoneMediaTile, item = shown[indexPath.item]
        tile.path = item.path;tile.visualMedia=item.kind != "audio";tile.image.crop=tile.visualMedia;tile.view.needsLayout=true
        tile.label.stringValue = item.displayName;tile.view.toolTip=item.displayName;tile.image.setAccessibilityLabel(item.displayName);tile.image.image = NSImage(systemSymbolName:symbol(item),accessibilityDescription:item.displayName)
        if let connection, let image = thumbnailLoader.cached(item, connection: connection) { tile.image.image = image }
        scheduleThumbnails()
        return tile
    }
    private func scheduleThumbnails() {
        thumbnailUpdate?.cancel()
        let update = DispatchWorkItem { [weak self] in self?.loadVisibleThumbnails() }; thumbnailUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: update)
    }
    private func loadVisibleThumbnails() {
        guard mode.selectedSegment > 0, window?.isVisible == true, let connection else { return }
        let visible = grid.indexPathsForVisibleItems().filter { shown.indices.contains($0.item) }.sorted { $0.item < $1.item }
        let generation = generation
        thumbnailLoader.load(visible.map { shown[$0.item] }, connection: connection) { [weak self] file, image in
            guard let self, self.generation == generation else { return }
            for index in self.grid.indexPathsForVisibleItems() where self.shown.indices.contains(index.item) && self.shown[index.item] == file {
                (self.grid.item(at: index) as? PhoneMediaTile)?.image.image = image
            }
        }
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let available = galleryScroll.contentView.bounds.width - 16, count = max(3,Int(available/176)),side=floor((available-CGFloat(count-1)*8)/CGFloat(count))
        return NSSize(width:side,height:mode.selectedSegment == 3 ? 150:side)
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateAvailability()
        if selected.count == 1,let file=selected.first,["photo","video"].contains(file.kind),let connection {previewLoader.warm(file,connection:connection)}
    }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateAvailability() }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? { promise(shown[indexPath.item]) }
    private func selectionMenu() -> NSMenu {
        updateAvailability()
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title,action,enabled) in [("Preview",#selector(previewSelected),previewButton.isEnabled),
                                       ("Copy to Mac Clipboard",#selector(copySelected),copyButton.isEnabled && mediaCancellation == nil),
                                       ("Save to Mac…",#selector(saveSelected),download.isEnabled)] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = NSMenuItem(title:"Select All",action:#selector(selectAllItems),keyEquivalent:""); all.target = self; all.isEnabled = selectButton.isEnabled; menu.addItem(all)
        menu.addItem(.separator())
        let remove = NSMenuItem(title:selected.count > 1 ? "Delete \(selected.count) Photos…" : "Delete Photo…",action:#selector(deleteSelected),keyEquivalent:"")
        remove.target = self; remove.isEnabled = deleteButton.isEnabled; menu.addItem(remove)
        return menu
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "c" { copySelected(); return true }
            if event.charactersIgnoringModifiers?.lowercased() == "a" { selectAllItems(); return true }
        } else if event.modifierFlags.intersection([.control,.option]).isEmpty {
            if event.keyCode == 49 { previewSelected(); return true }
            if event.keyCode == 51 || event.keyCode == 117 { deleteSelected(); return true }
        }
        return false
    }
    @objc private func selectAllItems() {
        guard !loading else { return }
        if mode.selectedSegment == 0 { table.selectAll(nil) }
        else { grid.selectionIndexPaths = Set(shown.indices.map { IndexPath(item:$0,section:0) }) }
        updateAvailability()
    }
    private func preview(index: Int) {
        guard shown.indices.contains(index) else { return }
        openPreview(shown[index])
    }
    @objc private func previewSelected() { if let file = selected.first { openPreview(file) } }
    private func openPreview(_ file:PhoneFile) {
        guard !loading,!mediaBusy,let connection else{return}
        if file.kind == "audio" {prepareMedia([file],clipboard:false);return}
        let candidates=shown.filter{["photo","video"].contains($0.kind) && !$0.directory}
        guard let index=candidates.firstIndex(where:{$0.path==file.path}) else{return}
        if previewWindow?.reopen(files:candidates,index:index,connection:connection) == true { return }
        previewWindow?.close()
        let preview=PhoneMediaPreviewWindow(files:candidates,index:index,connection:connection,loader:previewLoader,
            thumbnail:{ [weak self] file in guard let self, let connection = self.connection else{return nil};return self.thumbnailLoader.cached(file, connection: connection) },
            onOriginal:{ [weak self] file in self?.prepareMedia([file],clipboard:false) })
        preview.onFailure = { [weak self] error in self?.onMediaFailure?(error) }
        previewWindow=preview;preview.open()
    }
    @objc private func copySelected() {
        let files = selected
        guard !files.isEmpty, files.allSatisfy({ $0.kind == "photo" && !$0.directory }) else { return }
        prepareMedia(files,clipboard:true)
    }
    @objc private func cancelMedia(){status.stringValue="Cancelling…";mediaCancellation?.cancel()}
    private func prepareMedia(_ files: [PhoneFile], clipboard: Bool) {
        guard !loading, !mediaBusy, let connection, files.allSatisfy({ ["photo","video","audio"].contains($0.kind) && !$0.directory }) else { return }
        mediaBusy = true; mediaGeneration = UUID(); let token = mediaGeneration, cancellation = PhoneFileCancellation(); mediaCancellation = cancellation
        if !clipboard {previewWindow?.setOriginalBusy(true)}
        status.stringValue = clipboard ? "Preparing \(files.count) original photo(s) for the Mac clipboard…" : "Preparing original…"; updateAvailability()
        worker.async {
            var last = Date.distantPast
            let result = Result {
                try self.mediaActions.fetch(files,connection:connection,cancel:cancellation) { index,total,bytes,size in
                    guard -last.timeIntervalSinceNow > 0.2 else { return }; last = Date()
                    DispatchQueue.main.async {
                        guard self.mediaGeneration == token else { return }
                        self.status.stringValue = "\(clipboard ? "Copying" : "Preview") \(index)/\(total) · \(ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file)) / \(ByteCountFormatter.string(fromByteCount:size,countStyle:.file))"
                    }
                }
            }
            DispatchQueue.main.async {
                if self.mediaCancellation === cancellation { self.mediaCancellation = nil; self.mediaBusy = false; self.previewWindow?.setOriginalBusy(false);self.updateAvailability() }
                guard self.mediaGeneration == token, self.window?.isVisible == true else { return }
                guard self.provider()?.identity == connection.peer.identity else { self.status.stringValue = "Phone changed. Reconnect and try again."; return }
                switch result {
                case .success(let urls):
                    if clipboard {
                        self.status.stringValue = placeImagesOnPasteboard(urls,pasteboard:self.pasteboard,providers:&self.clipboardProviders) ? "\(urls.count) photo(s) copied · Paste on Mac with ⌘V" : "Could not copy these images to the Mac clipboard."
                    } else if let url = urls.first { self.showPreview(url, name:files[0].displayName); self.status.stringValue = "Original preview · Phone original kept" }
                case .failure(let error): self.status.stringValue = cancellation.cancelled ? "Cancelled":error.localizedDescription; if !cancellation.cancelled { self.onMediaFailure?(error) }
                }
            }
        }
    }
    private func showPreview(_ url: URL, name: String) {
        originalPreviewWindow?.close()
        let preview = NSWindow(contentRect:NSRect(x:0,y:0,width:860,height:640),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        preview.title = name; preview.isReleasedWhenClosed = false; preview.contentMinSize = NSSize(width:360,height:280)
        let view = QLPreviewView(frame:preview.contentView!.bounds,style:.normal)!
        view.autoresizingMask = [.width,.height]; view.autostarts = false; view.shouldCloseWithWindow = true; view.previewItem = url as NSURL
        preview.contentView?.addSubview(view); preview.center(); PhoneWindowFlow.present(preview); originalPreviewWindow = preview
    }
    @objc private func deleteSelected() {
        guard !loading, !mediaBusy, let connection else { return }
        let files = selected
        guard !files.isEmpty, files.allSatisfy({ $0.kind == "photo" && !$0.directory }) else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = files.count == 1 ? "Delete this photo from your phone?" : "Delete \(files.count) photos from your phone?"
        alert.informativeText = files.prefix(3).map(\.displayName).joined(separator:"\n") + (files.count > 3 ? "\n… and \(files.count-3) more" : "") + "\n\nThis permanently deletes the phone originals. This cannot be undone. Copies already saved on Mac are kept."
        alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:files.count == 1 ? "Delete Photo" : "Delete \(files.count) Photos")
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for:window!) { response in
            guard response == .alertSecondButtonReturn else { return }
            guard !self.mediaBusy, self.provider()?.identity == connection.peer.identity else { self.status.stringValue = "Phone changed. Refresh the gallery."; return }
            self.mediaBusy = true; self.status.stringValue = "Deleting \(files.count) selected photo(s)…"; self.updateAvailability()
            self.worker.async {
                let result = Result { try self.mediaActions.removePhotos(files,connection:connection) }
                DispatchQueue.main.async {
                    self.mediaBusy = false
                    switch result {
                    case .success(let report):
                        self.browser.invalidate()
                        if !report.removed.isEmpty {self.previewWindow?.close();self.previewLoader.invalidate()}
                        let removed = Set(report.removed.map(\.path)); self.items.removeAll { removed.contains($0.path) }; self.thumbnailLoader.invalidate(); self.filter()
                        self.status.stringValue = "Deleted \(removed.count) photo(s) from phone" + (report.failure.map { " · Stopped: " + $0 } ?? "")
                    case .failure(let error): self.status.stringValue = error.localizedDescription
                    }
                    self.updateAvailability()
                }
            }
        }
    }
    @objc private func chooseMacFiles() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for:window!) { response in if response == .OK { self.send(panel.urls) } }
    }
    private func send(_ urls: [URL]) {
        guard let connection else { status.stringValue = "Connect your phone first."; return }
        let folder = mode.selectedSegment == 0 ? path : "Download"
        status.stringValue = "Preparing \(urls.count) item(s)…"
        transfers.upload(urls,folder:folder,connection:connection) { [weak self] error in
            guard let self else { return }; self.status.stringValue = error?.localizedDescription ?? "Queued · copying to \(folder.isEmpty ? "shared storage" : folder)"
        }
    }
    @objc private func saveSelected() {
        guard let connection, !selected.isEmpty else { return }; let items = selected
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Save Here"
        panel.directoryURL = FileTransferClient.receivedFolder
        panel.beginSheetModal(for:window!) { response in
            guard response == .OK, let folder = panel.url else { return }
            self.transfers.download(items,connection:connection,into:folder) { error in if let error { DispatchQueue.main.async { self.status.stringValue = error.localizedDescription } } }
        }
    }
    @objc private func createFolder() {
        guard let connection else { return }
        let alert = NSAlert(); alert.messageText = "New phone folder"; alert.addButton(withTitle:"Create"); alert.addButton(withTitle:"Cancel")
        let field = NSTextField(frame:NSRect(x:0,y:0,width:280,height:26)); field.placeholderString = "Folder name"; alert.accessoryView = field
        alert.beginSheetModal(for:window!) { response in
            guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }; let parent = self.path, name = field.stringValue
            self.worker.async {
                do { try self.client.validate(connection); _ = try self.client.makeDirectory(connection,path:parent,name:name); DispatchQueue.main.async { self.load(force:true) } }
                catch { DispatchQueue.main.async { self.status.stringValue = error.localizedDescription } }
            }
        }
    }
    @objc private func pauseTransfers() { transfers.pause() }
    @objc private func resumeTransfers() { transfers.resume() }
    func showTransfers(_ values: [PhoneFileTransfer]) {
        let completedBefore = Set(jobs.filter { $0.state == "Done" }.map(\.id))
        if values.contains(where: { $0.upload && $0.state == "Done" && !completedBefore.contains($0.id) }) { remoteChanged = true; browser.invalidate() }
        jobs = values; transferTable.reloadData()
        if remoteChanged && !values.contains(where: { $0.pending && $0.state != "Paused" }) && window?.isVisible == true {
            remoteChanged = false; load(force:true)
        }
        let pending = values.filter(\.pending), active = pending.first { $0.state != "Paused" && $0.state != "Queued" }
        let done = values.filter { !$0.pending }.count
        progress.isHidden=pending.isEmpty
        if let job = active {
            let rate = job.speed > 0 ? " · " + ByteCountFormatter.string(fromByteCount:Int64(job.speed),countStyle:.file) + "/s" : ""
            transferStatus.stringValue = "\(job.upload ? "Sending" : "Receiving") \(job.file.displayName) · \(job.state)"+rate
            progress.doubleValue = Double(job.completed)*100/Double(max(1,job.file.size))
        } else if !pending.isEmpty { transferStatus.stringValue = "\(pending.count) transfers waiting · Open Transfers to resume"; progress.doubleValue = 0 }
        else {transferStatus.stringValue = done>0 ? "All transfers complete":"Drop files here to send to your phone";progress.doubleValue=100}
        pauseButton.isEnabled = pending.contains { $0.state != "Paused" }; resumeButton.isEnabled = pending.contains { $0.state == "Paused" }
    }
}
