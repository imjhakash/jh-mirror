import Foundation
struct CommandResult { let code: Int32; let output: String }
let lock=NSLock()
var operations:[String]=[], nextRenew="released", intent="screen-on", serviceReady=true, repairCalls=0, prepareReply="ready"
func connectionLog(_ value:String) { }
func command(_ args:[String],timeout:Double) -> CommandResult {
    let index=args.firstIndex(of:"operation")!;let operation=args[index+1]
    lock.lock();defer { lock.unlock() };operations.append(operation)
    let reply:String
    switch operation {
    case "state":reply=intent
    case "prepare":reply=prepareReply
    case "status":reply=serviceReady ? "ready" : "service-disconnected"
    case "repair":repairCalls += 1;serviceReady=true;reply="preparing"
    case "begin":intent="black";reply="guarded"
    case "renew":reply=nextRenew
    case "screen-on":intent="screen-on";reply="screen-on"
    default:reply="released"
    }
    return CommandResult(code:0,output:"Broadcast completed: result=0, data=\"\(reply)\"")
}
func require(_ condition:@autoclosure()->Bool,_ text:String) { if !condition() { fputs("FAIL: \(text)\n",stderr);exit(1) } }
func pause(_ seconds:Double=0.1) async { try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) }
let guarder=PhoneTouchGuard()
Task { @MainActor in
    var prepared:PhoneTouchGuard.Preparation?
    guarder.begin(serial:"paired",restoringIntent:true) { prepared=$0 }
    while prepared==nil { await pause() }
    require(prepared == .screenOn && !operations.contains("begin"),"external phone wake wins over an old saved black preference")
    prepared=nil;var released:Bool?
    guarder.onReleased={ on,_ in released=on }
    guarder.begin(serial:"paired") { prepared=$0 }
    while prepared==nil { await pause() };require(prepared == .guarded,"new explicit screen-off request acquires protection")
    let deadline=Date().addingTimeInterval(5)
    while released==nil && Date()<deadline { await pause() }
    require(released == false && !operations.contains("screen-on"),"lost protection never issues a screen-on command")
    guarder.allowScreenOn(serial:"paired");await pause(0.2)
    require(operations.contains("screen-on"),"explicit Screen On clears the phone-side intent")
    nextRenew="screen-on";prepared=nil;released=nil
    guarder.begin(serial:"paired") { prepared=$0 }
    while prepared==nil { await pause() }
    let wakeDeadline=Date().addingTimeInterval(5)
    while released==nil && Date()<wakeDeadline { await pause() }
    require(released == true,"phone power wake is reported distinctly from a guard failure")
    guarder.stop()
    serviceReady=false;prepareReply="service-disconnected";prepared=nil
    guarder.begin(serial:"paired") { prepared=$0 }
    while prepared==nil {await pause()}
    require(prepared == .guarded && repairCalls == 1,"an enabled but disconnected service is rebound once before the guard starts")
    guarder.stop();prepareReply="permission-denied";prepared=nil
    let before=operations.filter{$0 == "begin"}.count
    guarder.begin(serial:"paired") {prepared=$0}
    while prepared==nil {await pause()}
    require(prepared == .unavailable && guarder.failureMessage.contains("Accessibility") && operations.filter{$0 == "begin"}.count == before,"permission denial is explained and never blocks touch")
    guarder.stop();print("PASS: saved/external display intent, guarded off, failure without relighting, explicit on and external wake acknowledgement.");exit(0)
}
RunLoop.main.run()
