import Foundation
let root=FileManager.default.temporaryDirectory.appendingPathComponent("jh-browser-"+UUID().uuidString)
let remote=FixtureFiles(root:root), browser=PhoneFilesBrowser(client:remote)
try! Data("Generated photo".utf8).write(to:remote.url("Photo.png"))
func pause(_ delay:Double=0.02) async { try? await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000)) }
func wait(_ predicate:@escaping ()->Bool) async { for _ in 0..<100 {if predicate(){return};await pause()};require(predicate(),"browser completion arrived") }
func load(_ mode:String="list",path:String="",force:Bool=false) async -> Result<(PhoneFileConnection,PhoneFileList),Error> {
    var result:Result<(PhoneFileConnection,PhoneFileList),Error>?
    browser.load(serial:"paired",identity:"PHONE",path:path,mode:mode,force:force){result=$0}
    await wait {result != nil};return result!
}
Task { @MainActor in
    let sample=try! remote.info(PhoneFileConnection(serial:"paired",peer:PhoneFilePeer(identity:"PHONE",user:0)),path:"Photo.png")
    remote.initialMediaSnapshot=PhoneFileList(path:"",items:[sample],truncated:true);remote.slowMedia=true
    var early=false, complete=false
    browser.load(serial:"paired",identity:"PHONE",path:"",mode:"photo",preview:{_,list in early=list.items.count==1}){_ in complete=true}
    await wait{early};require(!complete,"first gallery page displays while the full library is still loading")
    browser.cancel();remote.initialMediaSnapshot=nil;remote.mediaStarted=false;remote.mediaCancelled=false
    remote.slowMedia=true
    var staleResult=false
    browser.load(serial:"paired",identity:"PHONE",path:"",mode:"photo"){_ in staleResult=true}
    await wait {remote.mediaStarted}
    let start=Date(), files=try! await load().get().1
    require(files.items.count==1 && -start.timeIntervalSinceNow<0.8,"file navigation bypasses the obsolete media scan")
    await wait {remote.mediaCancelled}
    require(!staleResult,"cancelled media request cannot overwrite the selected tab")
    remote.slowMedia=false
    let calls=remote.listCalls
    _=try! await load().get()
    require(remote.listCalls==calls,"warm folder listing reuses cache")
    _=try! await load(force:true).get()
    require(remote.listCalls==calls+1,"manual refresh fetches the phone again")
    browser.invalidate();_=try! await load().get()
    require(remote.listCalls==calls+2,"file changes invalidate the listing cache")
    remote.currentUser=10
    let changed=try! await load().get().0
    require(changed.peer.user==10 && remote.listCalls==calls+3,"cached listings are isolated by Android user")
    if case .success = await load(path:"Missing") { require(false,"failed folder read must be reported") }
    let recovered=try! await load().get().1
    require(recovered.items.count==1,"browser recovers after a failed request")
    remote.slowMedia=true;remote.mediaStarted=false
    browser.load(serial:"paired",identity:"PHONE",path:"",mode:"video"){_ in staleResult=true}
    await wait {remote.mediaStarted};browser.cancel();await pause(0.15)
    require(!staleResult,"closing browser cancels late completion")
    remote.slowMedia=false
    let probes=PhoneFilesBrowser(client:remote), baseline=remote.probeCounts.0
    probes.load(serial:"slow-probe-one",identity:"PHONE",path:"",mode:"list"){_ in}
    await wait{remote.probeCounts.0>baseline}
    probes.load(serial:"slow-probe-two",identity:"PHONE",path:"",mode:"list"){_ in}
    await wait{remote.probeCounts.0>baseline+1}
    var fast=false;let probeStart=Date()
    probes.load(serial:"paired",identity:"PHONE",path:"",mode:"list"){if case .success=$0{fast=true}}
    await wait{fast}
    require(-probeStart.timeIntervalSinceNow<0.6 && remote.probeCounts.1>=2,"obsolete connection probes cancel so both worker slots cannot block fresh navigation")
    try? FileManager.default.removeItem(at:root)
    print("PASS: obsolete scan cancellation, responsive file navigation, latest-only completion, warm cache, forced refresh, mutation invalidation, user isolation, error recovery and close cancellation.")
    exit(0)
}
RunLoop.main.run()
