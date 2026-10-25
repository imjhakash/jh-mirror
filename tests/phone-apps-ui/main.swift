import AppKit

let companionPackage = "com.johirulhoqakash.jhmirror"
struct CommandResult { let code: Int32; let output: String }
func command(_ args: [String], timeout: Double) -> CommandResult { fatalError("No hardware commands in UI checks") }
func commandData(_ args: [String], timeout: Double, limit: Int) -> Data? { fatalError("No hardware reads in UI checks") }
func phoneShellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
func pause(_ seconds: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds*1_000_000_000)) }
func settle(_ condition: @escaping () -> Bool) async {
    for _ in 0..<30 { if condition() { return }; await pause(0.1) }
    require(condition(), "asynchronous drawer operation finishes")
}
let directory=FileManager.default.temporaryDirectory.appendingPathComponent("jh-drawer-cache-"+UUID().uuidString)
var now=Date(timeIntervalSince1970:1_790_000_000)
var deleted=false, launches=0, removals=0, lists=0, failReads=false
let names=["Calendar","Camera","Files","Maps","Music","Notes"]
let symbols=["calendar","camera.fill","folder.fill","map.fill","music.note","note.text"]
let colors:[NSColor]=[.systemRed,.systemBlue,.systemOrange,.systemGreen,.systemPurple,.systemTeal]
func fixtureIcon(_ i:Int)->String {
    let image=NSImage(size:NSSize(width:128,height:128),flipped:false) { rect in
        colors[i].setFill();NSBezierPath(roundedRect:rect.insetBy(dx:4,dy:4),xRadius:26,yRadius:26).fill()
        let symbol=NSImage(systemSymbolName:symbols[i],accessibilityDescription:nil)!.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:52,weight:.medium))!
        NSColor.white.set();symbol.draw(in:rect.insetBy(dx:30,dy:30),from:.zero,operation:.sourceOver,fraction:1)
        return true
    }
    return NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!.base64EncodedString()
}
let fixtures=(0..<6).map { i -> [String:Any] in
    ["package":"example.app\(i)","name":names[i],"system":i==1,"protected":i==1,"enabled":true,"component":"example.app\(i)/.Main","icon":fixtureIcon(i)]
}
let fake=PhoneAppsClient(run: { args,_ in
    if args.contains("get-current-user") { return (0,"0\n") }
    if args.contains("start") { launches += 1 }
    if args.contains("uninstall") { removals += 1; deleted=true; return (0,"Success\n") }
    return (0,"")
}, read: { args,_,_ in
    let list=args.last!.hasSuffix("/list")
    if list { lists += 1 }
    if failReads { return nil }
    let values=fixtures.filter { !deleted || $0["package"] as! String != "example.app0" }
        .filter { list || args.last!.hasSuffix("/"+($0["package"] as! String)) }
    return Data("JH_APPS:".utf8)+(try! JSONSerialization.data(withJSONObject:["user":0,"apps":values]))
})
func makePanel()->PhoneAppsWindow {
    PhoneAppsWindow(serial:{"paired:1234"},identity:{"physical-phone"},client:fake,cache:PhoneAppsCache(directory:directory,now:{now}))
}
let application=NSApplication.shared;application.setActivationPolicy(.accessory)
let panel=makePanel()
Task { @MainActor in
    defer { try? FileManager.default.removeItem(at:directory) }
    panel.open();await pause(0.6)
    let grid=descendants(panel.window!.contentView!).compactMap { $0 as? NSCollectionView }.first!
    await settle { grid.numberOfItems(inSection:0)==6 }
    require(lists==1,"first drawer open fetches once")
    require(descendants(panel.window!.contentView!).compactMap { $0 as? NSButton }.count==1,"drawer has only one chrome button: refresh")
    require(!panel.window!.styleMask.contains(.titled),"drawer has no separate title bar")
    for width in [304.0,360.0,420.0] {
        panel.window!.setContentSize(NSSize(width:width,height:620));await pause(0.2)
        grid.collectionViewLayout!.invalidateLayout();await pause()
        let frames=(0..<5).map { grid.collectionViewLayout!.layoutAttributesForItem(at:IndexPath(item:$0,section:0))!.frame }
        if !frames.prefix(4).allSatisfy({ abs($0.minY-frames[0].minY)<1 }) || frames[4].minY<=frames[0].minY {
            print("Grid bounds",grid.bounds,"scroll",grid.enclosingScrollView!.contentView.bounds,"frames",frames)
        }
        require(frames.prefix(4).allSatisfy { abs($0.minY-frames[0].minY)<1 } && frames[4].minY>frames[0].minY,"four drawer columns at width \(width)")
    }
    panel.window!.setContentSize(NSSize(width:360,height:620));await pause()
    grid.collectionViewLayout!.invalidateLayout();await pause()
    let actual=(0..<5).map { grid.item(at:IndexPath(item:$0,section:0))!.view.frame }
    require(actual.prefix(4).allSatisfy { abs($0.minY-actual[0].minY)<1 } && actual[4].minY>actual[0].minY,"rendered app views also keep four columns")
    if let bitmap=panel.window!.contentView!.bitmapImageRepForCachingDisplay(in:panel.window!.contentView!.bounds) {
        panel.window!.contentView!.cacheDisplay(in:panel.window!.contentView!.bounds,to:bitmap)
        try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/jh-app-drawer-check.png"))
    }
    panel.dismiss();panel.open();await pause(0.3);require(lists==1,"reopen does not refetch today's inventory")
    panel.close()
    let second=makePanel();second.open();await pause(0.4)
    let grid2=descendants(second.window!.contentView!).compactMap { $0 as? NSCollectionView }.first!
    await settle { grid2.numberOfItems(inSection:0)==6 }
    require(lists==1,"new controller loads today's persistent cache without a list fetch")
    now=Calendar.current.date(byAdding:.day,value:1,to:now)!
    second.dismiss();second.open();await pause(0.4);require(lists==2,"next calendar day fetches exactly once")
    second.dismiss();second.open();await pause(0.3);require(lists==2,"same new day is cached too")
    let refresh=descendants(second.window!.contentView!).compactMap { $0 as? NSButton }.first!
    refresh.performClick(nil);await pause(0.4);require(lists==3,"manual refresh bypasses today's cache")
    let available=NSRect(x:0,y:0,width:1440,height:900)
    let right=PhoneAppsWindow.drawerFrame(mirror:NSRect(x:350,y:100,width:360,height:650),available:available,toolsVisible:true)
    require(right.minX==774 && right.maxY==750,"drawer aligns beside mirror and clears tools")
    let left=PhoneAppsWindow.drawerFrame(mirror:NSRect(x:1000,y:100,width:360,height:650),available:available,toolsVisible:true)
    require(left.maxX==992,"drawer flips to the available side")
    second.follow(NSRect(x:350,y:100,width:360,height:650),toolsVisible:true,visible:false,active:false)
    require(!second.window!.isVisible && second.requestedOpen,"drawer hides with minimized/hidden mirror")
    second.follow(NSRect(x:350,y:100,width:360,height:650),toolsVisible:true,visible:true,active:true)
    await pause(0.3);require(second.window!.isVisible && lists==3,"drawer restores with mirror without refetching")
    let card=grid2.item(at:IndexPath(item:0,section:0))!.view as! PhoneAppCard
    require(card.accessibilityPerformPress(),"app icon supports accessible open");await pause(0.3)
    require(launches==1,"icon press opens the selected app")
    let event=NSEvent.mouseEvent(with:.rightMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:second.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
    let protected=grid2.item(at:IndexPath(item:1,section:0))!.view as! PhoneAppCard
    require(!protected.menu(for:event)!.items.last!.isEnabled,"protected app has disabled uninstall")
    @MainActor func uninstallMenu() { let menu=card.menu(for:event)!;let item=menu.items.last!;NSApp.sendAction(item.action!,to:item.target,from:item) }
    uninstallMenu();await pause()
    descendants(second.window!.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title=="Cancel" }!.performClick(nil)
    await pause();require(removals==0,"cancel never removes an app")
    uninstallMenu();await pause()
    descendants(second.window!.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title=="Uninstall" }!.performClick(nil)
    await pause(0.5);require(removals==1 && grid2.numberOfItems(inSection:0)==5 && lists==3,"confirmed simulated uninstall updates cache without full refetch")
    failReads=true;refresh.performClick(nil);await pause(0.4)
    require(grid2.numberOfItems(inSection:0)==5,"failed manual refresh retains cached icons")
    second.close()
    let saved=UserDefaults.standard.object(forKey:"phoneToolsExpanded")
    UserDefaults.standard.set(false,forKey:"phoneToolsExpanded")
    let tools=PhoneToolsPanel();var visibility:[Bool]=[];tools.onVisibilityChanged={visibility.append($0)}
    tools.follow(NSRect(x:400,y:150,width:360,height:600),active:true,visible:true,keepVisible:false)
    tools.toggleTools();require(tools.expanded && tools.isVisible,"arrow toggle reveals tools")
    tools.toggleTools();require(!tools.expanded && !tools.isVisible && visibility==[true,false],"arrow toggle hides tools")
    UserDefaults.standard.set(saved,forKey:"phoneToolsExpanded")
    print("PASS: four-column icon drawer; side positioning/hide/restore; one daily inventory across reopen/relaunch; next-day/manual refresh; cached fallback; icon Open and protected/confirmed simulated uninstall.")
    try? FileManager.default.removeItem(at:directory)
    exit(0)
}
application.run()
