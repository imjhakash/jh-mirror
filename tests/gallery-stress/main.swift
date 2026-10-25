import AppKit
let root=FileManager.default.temporaryDirectory.appendingPathComponent("jh-grid-stress-"+UUID().uuidString)
let remote=FixtureFiles(root:root.appendingPathComponent("phone"))
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:24,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
memset(bitmap.bitmapData,180,bitmap.bytesPerRow*bitmap.pixelsHigh)
let sample=remote.url("QA photo 0000.png");try! bitmap.representation(using:.png,properties:[:])!.write(to:sample)
for index in 1..<2000 { try! FileManager.default.linkItem(at:sample,to:remote.url(String(format:"QA photo %04d.png",index))) }
let transfers=PhoneFileTransfers(client:remote,directory:root.appendingPathComponent("queue"),provider:{("paired","PHONE")})
let application=NSApplication.shared;application.setActivationPolicy(.accessory)
let pasteboard=NSPasteboard(name:NSPasteboard.Name("jh-grid-stress-"+UUID().uuidString))
let panel=PhoneFilesWindow(client:remote,transfers:transfers,provider:{("paired","PHONE")},pasteboard:pasteboard,mediaDirectory:root.appendingPathComponent("media"))
func children(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(children)}
func pause(_ seconds:Double=0.02)async{try? await Task.sleep(nanoseconds:UInt64(seconds*1e9))}
func wait(_ message:String,_ condition:()->Bool)async{for _ in 0..<400{if condition(){return};await pause()};require(condition(),message)}
Task{@MainActor in
 panel.open(media:true)
 let views=children(panel.window!.contentView!),grid=views.compactMap{$0 as? NSCollectionView}.first!,search=views.compactMap{$0 as? NSSearchField}.first!
 await wait("large generated gallery loads"){grid.numberOfItems(inSection:0)==2000}
 panel.window!.contentView!.layoutSubtreeIfNeeded();await pause(0.4)
 require(remote.thumbnailCalls<120,"2,000-photo library requests thumbnails only for the visible viewport")
 remote.thumbnailDelay=0.1
 for index in [400,1000,1800] {grid.scrollToItems(at:[IndexPath(item:index,section:0)],scrollPosition:.top);await pause(0.05)}
 await wait("new viewport receives actual decoded images"){
  grid.indexPathsForVisibleItems().contains{index in
   guard let item=grid.item(at:index)else{return false}
   return children(item.view).compactMap{$0 as? NSImageView}.contains{$0.image != nil && $0.image?.isTemplate==false}
  }
 }
 require(remote.thumbnailCalls<240,"rapid scrolling cancels obsolete work instead of decoding the entire library")
 panel.window!.setContentSize(NSSize(width:720,height:500));await pause(0.2)
 let visible=grid.indexPathsForVisibleItems()
 require(!visible.isEmpty && visible.count<120,"minimum-size grid keeps a bounded visible set")
 for index in visible {
  if let item=grid.item(at:index){require(abs(item.view.bounds.width-item.view.bounds.height)<2,"photo tiles stay square after resize")}
 }
 for value in ["Q","QA","QA photo","QA photo 1999"] {search.stringValue=value;panel.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))}
 await wait("rapid large-library search resolves to the latest query"){grid.numberOfItems(inSection:0)==1}
 let calls=remote.listCalls
 for _ in 0..<4 {panel.close();await pause(0.05);panel.open(media:true);await pause(0.15)}
 require(search.stringValue=="QA photo 1999" && grid.numberOfItems(inSection:0)==1 && remote.listCalls==calls,"close/reopen preserves search and warm metadata without another phone listing")
 panel.close();transfers.stop();pasteboard.releaseGlobally();await pause(0.2)
 try? FileManager.default.removeItem(at:root)
 print("PASS: 2,000-photo viewport loading, rapid scroll cancellation, minimum-size square layout, debounced search and repeated reopen")
 exit(0)
}
application.run()
