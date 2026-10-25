import AppKit
import QuickLookUI
let root=FileManager.default.temporaryDirectory.appendingPathComponent("jh-files-ui-"+UUID().uuidString),remote=FixtureFiles(root:root.appendingPathComponent("phone"))
try! FileManager.default.createDirectory(at:remote.url("DCIM"),withIntermediateDirectories:true)
try! FileManager.default.createDirectory(at:remote.url("Download"),withIntermediateDirectories:true)
try! FileManager.default.createDirectory(at:remote.url("Documents"),withIntermediateDirectories:true)
for (name,color) in [("Blue sample.png",NSColor.systemBlue),("Green sample.png",NSColor.systemGreen)] {
    let image=NSImage(size:NSSize(width:240,height:160),flipped:false) { bounds in color.setFill();bounds.fill();return true }
    try! NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:remote.url("DCIM/"+name))
}
try! Data("Generated document".utf8).write(to:remote.url("Download/Report.txt"))
try! Data("Generated document".utf8).write(to:remote.url("Documents/Document.txt"))
try! Data("Generated video placeholder".utf8).write(to:remote.url("Download/Video.mp4"))
var silentWave=Data()
func waveText(_ value:String){silentWave.append(Data(value.utf8))}
func wave16(_ value:UInt16){var value=value.littleEndian;withUnsafeBytes(of:&value){silentWave.append(contentsOf:$0)}}
func wave32(_ value:UInt32){var value=value.littleEndian;withUnsafeBytes(of:&value){silentWave.append(contentsOf:$0)}}
waveText("RIFF");wave32(1636);waveText("WAVEfmt ");wave32(16);wave16(1);wave16(1);wave32(8000);wave32(16000);wave16(2);wave16(16);waveText("data");wave32(1600);silentWave.append(Data(repeating:0,count:1600))
try! silentWave.write(to:remote.url("Download/Audio.wav"))
let transfers=PhoneFileTransfers(client:remote,directory:root.appendingPathComponent("queue"),provider:{("paired","PHONE")})
let application=NSApplication.shared;application.setActivationPolicy(.accessory)
let pasteboard=NSPasteboard(name:NSPasteboard.Name("jh-gallery-test-"+UUID().uuidString))
let panel=PhoneFilesWindow(client:remote,transfers:transfers,provider:{("paired","PHONE")},pasteboard:pasteboard,mediaDirectory:root.appendingPathComponent("previews"))
transfers.onChange={panel.showTransfers($0)}
func children(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap{children($0)}}
func pause(_ seconds:Double=0.3) async {try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))}
Task { @MainActor in
    panel.open();await pause(0.7)
    let all=children(panel.window!.contentView!),tables=all.compactMap{$0 as? NSTableView},segments=all.compactMap{$0 as? NSSegmentedControl}.first!,folders=all.compactMap{$0 as? NSPopUpButton}.first!
    let files=tables.first{$0.tableColumns.count==3}!
    require(files.numberOfRows==3,"shared-storage folder browser loads")
    folders.selectItem(at:2);folders.sendAction(folders.action!,to:folders.target);await pause(0.5)
    require(files.numberOfRows==2,"favorites navigate camera folder")
    let promise=panel.tableView(files,pasteboardWriterForRow:0) as! NSFilePromiseProvider
    require(promise.delegate?.filePromiseProvider(promise,fileNameForType:promise.fileType).hasSuffix(".png")==true,"drag-out offers real Finder file promise")
    segments.selectedSegment=1;segments.sendAction(segments.action!,to:segments.target);await pause(0.8)
    let gallery=children(panel.window!.contentView!).compactMap{$0 as? NSCollectionView}.first!
    require(gallery.numberOfItems(inSection:0)==2,"media library lists photos")
    let search=all.compactMap{$0 as? NSSearchField}.first!;search.stringValue="Blue";panel.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
    require(gallery.numberOfItems(inSection:0)==1,"media search filters results")
    search.stringValue="";panel.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));await pause()
    gallery.selectionIndexPaths=[IndexPath(item:0,section:0)]
    let selectedBeforeReopen=gallery.selectionIndexPaths
    search.stringValue="sample";panel.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));await pause()
    gallery.selectionIndexPaths=selectedBeforeReopen
    let callsBeforeReopen=remote.listCalls
    panel.open(media:true);await pause(0.1)
    require(search.stringValue=="sample" && gallery.selectionIndexPaths==selectedBeforeReopen && remote.listCalls==callsBeforeReopen,"repeated library click preserves search, selection and listing")
    search.stringValue="";panel.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));await pause()
    if let bitmap=panel.window!.contentView!.bitmapImageRepForCachingDisplay(in:panel.window!.contentView!.bounds) {
        panel.window!.contentView!.cacheDisplay(in:panel.window!.contentView!.bounds,to:bitmap)
        try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/jh-media-library-check.png"))
    }
    let destination=root.appendingPathComponent("Finder drop.png")
    var finished=false
    promise.delegate!.filePromiseProvider(promise,writePromiseTo:destination) {error in require(error==nil,"Finder drop succeeds");finished=true}
    for _ in 0..<60 {if finished {break};await pause(0.1)}
    require(finished && FileManager.default.fileExists(atPath:destination.path),"Finder promise fulfills requested destination")
    require(children(panel.window!.contentView!).contains {($0 as? NSTextField)?.stringValue=="All transfers complete"},"transfer completion appears in compact footer")
    let buttons=children(panel.window!.contentView!).compactMap{$0 as? NSButton}
    let queueTable=tables.first{$0.tableColumns.count==1}!
    require(queueTable.enclosingScrollView!.isHidden,"transfer history starts collapsed")
    buttons.first{$0.title=="Transfers"}!.performClick(nil)
    require(!queueTable.enclosingScrollView!.isHidden,"transfer history expands on demand")
    buttons.first{$0.title=="Hide Transfers"}!.performClick(nil)
    buttons.first{$0.title=="Select All"}!.performClick(nil)
    require(gallery.selectionIndexPaths.count==2,"Select All selects a photo batch")
    let firstView=gallery.item(at:IndexPath(item:0,section:0))!.view
    let expectedName=children(firstView).compactMap{$0 as? NSTextField}.first!.stringValue
    let first=firstView.frame
    let location=gallery.convert(NSPoint(x:first.midX,y:first.midY),to:nil)
    let contextEvent=NSEvent.mouseEvent(with:.rightMouseDown,location:location,modifierFlags:[],timestamp:0,windowNumber:panel.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
    let menu=gallery.menu(for:contextEvent)!
    require(gallery.selectionIndexPaths.count==2 && menu.items.contains{$0.title=="Delete 2 Photos…" && $0.isEnabled},"right-click preserves bulk selection and offers bulk deletion")
    require(menu.items.contains{$0.title=="Copy to Mac Clipboard" && $0.isEnabled},"context menu offers image copy")
    let doubleClick=NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:0,windowNumber:panel.window!.windowNumber,context:nil,eventNumber:2,clickCount:2,pressure:1)!
    remote.previewDelay=0.35
    let previewStart=Date();gallery.mouseDown(with:doubleClick)
    for _ in 0..<40 {if application.windows.contains(where:{$0.title==expectedName && $0.isVisible}) {break};await pause(0.1)}
    let preview=application.windows.first{$0.title==expectedName && $0.isVisible}
    require(preview != nil && -previewStart.timeIntervalSinceNow<0.3,"double-click opens viewer immediately before the phone preview finishes")
    let viewer=preview!.windowController as! PhoneMediaPreviewWindow
    require(children(preview!.contentView!).compactMap{$0 as? NSImageView}.contains{$0.image != nil},"cached thumbnail is visible immediately")
    require(remote.readOffsets.count==1,"fast preview does not download full originals")
    let previewFrame=preview!.frame
    gallery.mouseDown(with:doubleClick);await pause(0.05)
    require(application.windows.first{$0.title==expectedName && $0.isVisible} === preview && preview!.frame==previewFrame,"repeated photo open reuses the viewer without flicker or repositioning")
    viewer.step(1);await pause(0.65)
    require(viewer.index==1 && children(preview!.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue=="2 / 2"},"next navigation updates the image counter")
    let navigationStart=Date();viewer.step(-1);await pause(0.05)
    require(viewer.index==0 && -navigationStart.timeIntervalSinceNow<0.2,"cached previous photo appears without waiting for a transfer")
    children(preview!.contentView!).compactMap{$0 as? NSButton}.first{$0.title=="Open Original"}!.performClick(nil)
    for _ in 0..<40 {if application.windows.contains(where:{$0.isVisible && children($0.contentView!).contains{$0 is QLPreviewView}}) {break};await pause(0.1)}
    let original=application.windows.first{$0.isVisible && children($0.contentView!).contains{$0 is QLPreviewView}}
    require(original != nil,"Open Original retains verified native Quick Look")
    original?.close();viewer.close()
    buttons.first{$0.title=="Copy"}!.performClick(nil)
    for _ in 0..<40 {if pasteboard.pasteboardItems?.count==2 {break};await pause(0.1)}
    require(pasteboard.pasteboardItems?.count==2 && pasteboard.pasteboardItems!.allSatisfy{$0.data(forType:.png) != nil},"bulk photo copy supplies real image data without changing the user's clipboard")
    let clipboardURLs=pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as! [URL]
    buttons.first{$0.title=="Delete…"}!.performClick(nil);await pause()
    let sheet=panel.window!.attachedSheet!
    require(children(sheet.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue.contains("permanently deletes")},"delete confirmation explicitly describes permanent phone deletion")
    children(sheet.contentView!).compactMap{$0 as? NSButton}.first{$0.title=="Cancel"}!.performClick(nil);await pause()
    require(gallery.numberOfItems(inSection:0)==2 && FileManager.default.fileExists(atPath:remote.url("DCIM/Blue sample.png").path),"Cancel leaves the phone photos intact")
    buttons.first{$0.title=="Delete…"}!.performClick(nil);await pause()
    let confirmedSheet=panel.window!.attachedSheet!
    gallery.selectionIndexPaths=[IndexPath(item:0,section:0)]
    children(confirmedSheet.contentView!).compactMap{$0 as? NSButton}.first{$0.title=="Delete 2 Photos"}!.performClick(nil)
    for _ in 0..<40 {if gallery.numberOfItems(inSection:0)==0 {break};await pause(0.1)}
    require(gallery.numberOfItems(inSection:0)==0 && !FileManager.default.fileExists(atPath:remote.url("DCIM/Green sample.png").path),"confirmed bulk deletion uses the snapshotted selection and refreshes gallery")
    require(clipboardURLs.allSatisfy{FileManager.default.fileExists(atPath:$0.path)},"phone deletion keeps Mac clipboard originals usable")
    panel.window!.setContentSize(NSSize(width:720,height:540));await pause();require(gallery.bounds.width>400,"browser and gallery resize")
    segments.selectedSegment=2;segments.sendAction(segments.action!,to:segments.target);await pause(0.4)
    require(gallery.numberOfItems(inSection:0)==1,"Videos loads its video entries")
    gallery.selectionIndexPaths=[IndexPath(item:0,section:0)]
    panel.open(media:true);await pause(0.1)
    require(segments.selectedSegment==2 && gallery.selectionIndexPaths.count==1,"Media action keeps the current Videos tab and selection")
    panel.open(media:false);await pause(0.2)
    panel.open(media:true);await pause(0.2)
    require(segments.selectedSegment==2,"returning from Files remembers the last media tab")
    segments.selectedSegment=3;segments.sendAction(segments.action!,to:segments.target);await pause(0.4)
    require(gallery.numberOfItems(inSection:0)==1,"Music loads its audio entries")
    gallery.selectionIndexPaths=[IndexPath(item:0,section:0)]
    panel.collectionView(gallery,didSelectItemsAt:[IndexPath(item:0,section:0)])
    buttons.first{$0.title=="Preview"}!.performClick(nil)
    for _ in 0..<40 {if application.windows.contains(where:{$0.title=="Audio.wav" && $0.isVisible}){break};await pause(0.1)}
    let audioPreview=application.windows.first{$0.title=="Audio.wav" && $0.isVisible}
    require(audioPreview != nil && children(audioPreview!.contentView!).contains{$0 is QLPreviewView},"audio opens a verified native preview without autoplay")
    audioPreview?.close()
    segments.selectedSegment=0;segments.sendAction(segments.action!,to:segments.target);await pause(0.4)
    folders.selectItem(at:6);folders.sendAction(folders.action!,to:folders.target);await pause(0.4)
    require(files.numberOfRows==1,"Documents folder loads its document entries")
    panel.close();transfers.stop();pasteboard.releaseGlobally();await pause()
    panel.open(media:true);await pause(0.2)
    // The earlier deletion check may remove all photos; add one generated fixture.
    let tiny=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    try! tiny.representation(using:.png,properties:[:])!.write(to:remote.url("Download/Recovery.png"))
    let recovery=try! remote.info(PhoneFileConnection(serial:"paired",peer:PhoneFilePeer(identity:"PHONE",user:remote.currentUser)),path:"Download/Recovery.png")
    remote.initialMediaSnapshot=PhoneFileList(path:"",items:[recovery],truncated:true);remote.failFullMedia=true
    segments.selectedSegment=1;segments.sendAction(segments.action!,to:segments.target)
    buttons.first{$0.toolTip=="Refresh files"}!.performClick(nil);await pause(0.7)
    require(gallery.numberOfItems(inSection:0)==1,"a full-index failure keeps the already loaded first page visible")
    require(children(panel.window!.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue.contains("incomplete")},"partial library is clearly marked incomplete")
    remote.failFullMedia=false;remote.initialMediaSnapshot=nil
    buttons.first{$0.toolTip=="Refresh files"}!.performClick(nil);await pause(0.7)
    require(gallery.numberOfItems(inSection:0)>=1,"manual refresh recovers the full gallery after an interruption")
    panel.close();transfers.stop()
    try? FileManager.default.removeItem(at:root)
    print("PASS: all file/media categories, clean collapsible transfers, immediate thumbnail preview, next/previous and cached navigation, verified original Quick Look, Finder promises, bulk clipboard and confirmed deletion.")
    exit(0)
}
application.run()
