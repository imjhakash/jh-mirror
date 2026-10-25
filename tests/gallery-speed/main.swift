import AppKit
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let root=FileManager.default.temporaryDirectory.appendingPathComponent("jh-gallery-speed-"+UUID().uuidString)
let remote=FixtureFiles(root:root.appendingPathComponent("phone")), connection=PhoneFileConnection(serial:"paired",peer:PhoneFilePeer(identity:"PHONE",user:0))
for n in 0..<18 {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    try! bitmap.representation(using:.png,properties:[:])!.write(to:remote.url("\(n).png"))
}
let files=try! remote.list(connection,path:"",mode:"photo").items
func pause(_ seconds:Double=0.02) async {try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))}
func wait(_ condition:()->Bool) async {for _ in 0..<150{if condition(){return};await pause()};require(condition(),"thumbnail callbacks arrived")}
Task { @MainActor in
    let directory=root.appendingPathComponent("cache")
    var loader=PhoneThumbnailLoader(client:remote,directory:directory), received=Set<String>()
    remote.thumbnailDelay=0.12
    loader.load(Array(files.prefix(6)),connection:connection){file,_ in received.insert(file.path)}
    await wait{received.count>=1}
    require(received.count<6,"each thumbnail appears before the remaining batch finishes")
    await wait{received.count==6}
    let calls=remote.thumbnailCalls
    loader.load(Array(files.prefix(6)),connection:connection){_,_ in}
    require(remote.thumbnailCalls==calls,"warm memory does not request the phone")
    loader.cancel();loader=PhoneThumbnailLoader(client:remote,directory:directory);received=[]
    loader.load(Array(files.prefix(6)),connection:connection){file,_ in received.insert(file.path)}
    await wait{received.count==6}
    require(remote.thumbnailCalls==calls,"new loader reuses private disk thumbnails without phone decoding")
    let attrs=try! FileManager.default.attributesOfItem(atPath:directory.path)
    require((attrs[.posixPermissions] as? NSNumber)?.intValue==0o700,"thumbnail cache is private")
    let changed=PhoneFileConnection(serial:"paired",peer:PhoneFilePeer(identity:"OTHER",user:0))
    received=[];loader.load([files[0]],connection:changed){file,_ in received.insert(file.path)}
    await wait{received.count==1};require(remote.thumbnailCalls==calls+1,"other phones cannot reuse a cached image")
    remote.thumbnailDelay=0.3;received=[]
    loader.load(Array(files[6..<12]),connection:connection){file,_ in received.insert(file.path)}
    await pause(0.04)
    loader.load([files[17]],connection:connection){file,_ in received.insert(file.path)}
    await wait{received.contains(files[17].path)}
    require(received==[files[17].path],"obsolete offscreen work cannot replace the visible page")
    loader.cancel()
    let runner=PhoneFileProcess(adb:"/usr/bin/python3",environment:ProcessInfo.processInfo.environment)
    let start=Date();var first=0.0
    _=try! runner.run(["-c","import time;print('first',flush=True);time.sleep(.3);print('last',flush=True)"],onLine:{_ in if first==0 {first = -start.timeIntervalSinceNow}})
    require(first>0 && -start.timeIntervalSinceNow-first>0.2,"line streaming delivers the first frame before process exit")
    try? FileManager.default.removeItem(at:root)
    print("PASS: progressive thumbnails, memory/disk reuse, private per-phone keys, viewport cancellation and line streaming")
    exit(0)
}
app.run()
