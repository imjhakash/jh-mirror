import AppKit
let root=FileManager.default.temporaryDirectory.appendingPathComponent("jh-fast-preview-"+UUID().uuidString)
let remote=FixtureFiles(root:root),peer=PhoneFileConnection(serial:"paired",peer:PhoneFilePeer(identity:"PHONE",user:0)),loader=PhonePreviewLoader(client:remote)
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:800,pixelsHigh:600,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
memset(bitmap.bitmapData,180,bitmap.bytesPerRow*bitmap.pixelsHigh)
let data=bitmap.representation(using:.png,properties:[:])!
for name in ["A.png","B.png","C.png","D.png","E.png"] {try! data.write(to:remote.url(name))}
let files=try! ["A.png","B.png","C.png"].map{try remote.info(peer,path:$0)}
func pause(_ seconds:Double=0.02)async{try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))}
func wait(_ predicate:@escaping ()->Bool)async{for _ in 0..<150{if predicate(){return};await pause()};require(predicate(),"preview request finishes")}
Task{@MainActor in
    remote.previewDelay=0.25
    var shown=""
    loader.focus(files,index:0,connection:peer){if case .success(let frame)=$0{shown=frame.file.name}}
    await wait{shown=="A.png" && loader.cached(files[1],connection:peer) != nil}
    require(remote.readOffsets.isEmpty,"screen preview never uses the original transfer path")
    let calls=remote.previewCalls,start=Date()
    loader.focus(files,index:1,connection:peer){if case .success(let frame)=$0{shown=frame.file.name}}
    require(shown=="B.png" && -start.timeIntervalSinceNow<0.03,"prefetched next image is synchronous")
    await wait{loader.cached(files[2],connection:peer) != nil}
    let completeCalls=remote.previewCalls
    loader.focus(files,index:0,connection:peer){if case .success(let frame)=$0{shown=frame.file.name}}
    require(shown=="A.png" && remote.previewCalls==completeCalls && calls<=3,"cached previous image makes no phone request")
    loader.invalidate();shown=""
    loader.focus(files,index:0,connection:peer){if case .success(let frame)=$0{shown=frame.file.name}}
    loader.focus(files,index:2,connection:peer){if case .success(let frame)=$0{shown=frame.file.name}}
    await wait{shown=="C.png"};await pause(0.3)
    require(shown=="C.png","rapid navigation cannot display an obsolete response")
    loader.invalidate();var failure=false
    try! FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(30)],ofItemAtPath:remote.url("A.png").path)
    loader.focus(files,index:0,connection:peer){if case .failure=$0{failure=true}}
    await wait{failure}
    loader.invalidate();remote.currentUser=10;failure=false
    loader.focus(files,index:2,connection:peer){if case .failure=$0{failure=true}}
    await wait{failure}
    loader.cancel()
    let urgentRemote=FixtureFiles(root:root), urgent=PhonePreviewLoader(client:urgentRemote)
    let urgentFiles=try! ["A.png","B.png","C.png","D.png","E.png"].map{try urgentRemote.info(peer,path:$0)}
    urgentRemote.previewDelay=1.0
    urgent.focus(urgentFiles,index:2,connection:peer){_ in}
    await wait{urgentRemote.startedPreviews.count>=2}
    let busy=Set(urgentRemote.startedPreviews.prefix(2))
    let target=urgentFiles.indices.first { index in
        !busy.contains(urgentFiles[index].name) && busy.isSubset(of:Set([index,index+1,index-1,index+2,index-2].filter{urgentFiles.indices.contains($0)}.map{urgentFiles[$0].name}))
    }!
    urgentRemote.delayPreview(urgentFiles[target].name,by:0.02)
    var delivered=false;let urgentStart=Date()
    urgent.focus(urgentFiles,index:target,connection:peer){if case .success=$0{delivered=true}}
    await wait{delivered}
    require(-urgentStart.timeIntervalSinceNow<0.4,"foreground navigation does not wait behind two slow neighboring prefetches")
    urgent.cancel();try? FileManager.default.removeItem(at:root)
    print("PASS: no original transfer for previews, adjacent prefetch, immediate cache navigation, deduplicated requests, latest-only display, changed-source and wrong-profile refusal.")
    exit(0)
}
RunLoop.main.run()
