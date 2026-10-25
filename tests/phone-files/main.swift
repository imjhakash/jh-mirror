import Foundation
let directory=FileManager.default.temporaryDirectory.appendingPathComponent("jh-files-engine-"+UUID().uuidString)
let remote=FixtureFiles(root:directory.appendingPathComponent("phone")),local=directory.appendingPathComponent("mac"),state=directory.appendingPathComponent("state")
try! FileManager.default.createDirectory(at:local,withIntermediateDirectories:true)
let data=Data((0..<(3*1024*1024)).map { UInt8($0%251) })
let source=local.appendingPathComponent("fixture.bin");try! data.write(to:source)
try! Data("Existing phone file".utf8).write(to:remote.url("fixture.bin"))
let peer=PhoneFileConnection(serial:"paired",peer:PhoneFilePeer(identity:"PHONE",user:0))
func engine(_ folder:URL)->PhoneFileTransfers { PhoneFileTransfers(client:remote,directory:folder,provider:{("paired","PHONE")}) }
func pause(_ seconds:Double=0.1) async { try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) }
func wait(_ condition:@escaping ()->Bool) async {
    for _ in 0..<150 { if condition() {return};await pause() };require(condition(),"background transfer completed")
}
var first=engine(state)
Task { @MainActor in
    require(!PhoneFile.validPath("../secret") && !PhoneFile.validPath("Android/data/private") && !PhoneFile.validPath("/data") && PhoneFile.validPath("Download/বাংলা ' data.bin"),"shared-storage path guard")
    require(PhoneFile.transferName(".hidden.txt")==".hidden.txt" && PhoneFile.transferName("../escape")==".._escape","file-manager names preserve dotfiles without path traversal")
    remote.interruptWrite=true;first.upload([source],folder:"")
    await wait {first.snapshot.contains {$0.state=="Paused"}}
    first.pause();await pause();require(remote.writeOffsets==[0],"first upload began at zero")
    first.resume();await wait {first.snapshot.contains {$0.state=="Done"}}
    require(remote.writeOffsets.count==2 && remote.writeOffsets[1]==1048576,"upload resumes at saved byte position")
    require(try! Data(contentsOf:remote.url("fixture.bin"))==Data("Existing phone file".utf8),"phone original never overwritten")
    let uploaded=first.snapshot.first!.result!
    require(try! Data(contentsOf:remote.url(uploaded))==data,"uploaded copy verified")
    let item=try! remote.info(peer,path:uploaded)
    let downloadDir=local.appendingPathComponent("downloads");try! FileManager.default.createDirectory(at:downloadDir,withIntermediateDirectories:true)
    try! Data("Existing Mac file".utf8).write(to:downloadDir.appendingPathComponent(item.name))
    remote.interruptRead=true;first.download([item],connection:peer,into:downloadDir)
    await wait {first.snapshot.contains {$0.state=="Paused" && !$0.upload}}
    first.pause();first.stop();await pause(0.3)
    let journalURL=state.appendingPathComponent("updates.jsonl")
    let journal=try! FileHandle(forWritingTo:journalURL);try! journal.seekToEnd();try! journal.write(contentsOf:Data("{incomplete record".utf8));try! journal.close()
    let restored=engine(state)
    require(restored.snapshot.contains {$0.state=="Paused" && !$0.upload},"pending transfers persist as paused across launch")
    restored.resume();await wait {restored.snapshot.filter {!$0.upload}.allSatisfy {$0.state=="Done"}}
    require(remote.readOffsets.count==2 && remote.readOffsets[1]==1048576,"download resumes from persisted partial after relaunch")
    require(try! Data(contentsOf:downloadDir.appendingPathComponent(item.name))==Data("Existing Mac file".utf8),"Mac existing file preserved")
    let saved=restored.snapshot.first {!$0.upload}!.result!
    require(try! Data(contentsOf:URL(fileURLWithPath:saved))==data,"download checksum verified")
    let exact=downloadDir.appendingPathComponent("promise.bin")
    var promised=false
    restored.download([item],connection:peer,into:downloadDir,exact:exact) { error in require(error==nil,"promise callback success");promised=true }
    await wait {promised};require(try! Data(contentsOf:exact)==data,"Finder promise writes supplied URL")
    var rejected=false
    restored.download([item],connection:peer,into:downloadDir,exact:exact) { error in rejected=error != nil }
    await wait {rejected};restored.pause()
    require(try! Data(contentsOf:exact)==data,"promise collision never replaces existing file")
    let integrity=engine(directory.appendingPathComponent("integrity-state"))
    let corruptDest=local.appendingPathComponent("integrity");try! FileManager.default.createDirectory(at:corruptDest,withIntermediateDirectories:true)
    remote.wrongHash=true;integrity.download([item],connection:peer,into:corruptDest)
    await wait {integrity.snapshot.contains {$0.state=="Paused"}}
    integrity.pause();await pause();require(!FileManager.default.fileExists(atPath:corruptDest.appendingPathComponent(item.name).path),"bad checksum is never published")
    remote.wrongHash=false;integrity.resume();await wait {integrity.snapshot.first?.state=="Done"}
    require(remote.readOffsets.last==0,"corrupt partial restarts safely")
    remote.currentUser=10
    let wrong=engine(directory.appendingPathComponent("wrong-profile"));var denied=false
    wrong.upload([source],folder:"",connection:peer) { denied=$0 != nil }
    await wait {denied};require(wrong.snapshot.isEmpty,"profile change refuses stale job before upload")
    remote.currentUser=0
    let empty=local.appendingPathComponent("empty.txt");FileManager.default.createFile(atPath:empty.path,contents:nil)
    integrity.upload([empty],folder:"");await wait {integrity.snapshot.contains {$0.upload && $0.state=="Done"}}
    let cancelled=PhoneFileCancellation();cancelled.cancel()
    do {_=try PhoneFileTransfers.hashFile(source,cancel:cancelled);require(false,"hash respects cancel")} catch {}
    let sourceChange=engine(directory.appendingPathComponent("source-changed"))
    remote.afterWrite = { try! FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(10)],ofItemAtPath:source.path) }
    sourceChange.upload([source],folder:"")
    await wait {sourceChange.snapshot.first?.state=="Paused"}
    sourceChange.pause();require(sourceChange.snapshot.first?.message.contains("Source changed")==true,"fresh file attributes detect changes after upload")
    sourceChange.stop()
    let folderSource=local.appendingPathComponent("Folder copy")
    try! FileManager.default.createDirectory(at:folderSource.appendingPathComponent("nested/empty"),withIntermediateDirectories:true)
    try! Data("Hidden child".utf8).write(to:folderSource.appendingPathComponent("nested/.hidden.txt"))
    let folders=engine(directory.appendingPathComponent("folders"))
    folders.upload([folderSource],folder:"")
    await wait {folders.snapshot.first?.state=="Done"}
    require(folders.snapshot.first?.file.name==".hidden.txt","folder copies preserve hidden-file names")
    let remoteFolder=try! remote.info(peer,path:"Folder copy")
    let destinationFolder=local.appendingPathComponent("folder-download")
    try! FileManager.default.createDirectory(at:destinationFolder,withIntermediateDirectories:true)
    folders.download([remoteFolder],connection:peer,into:destinationFolder)
    await wait {folders.snapshot.contains {!$0.upload && $0.state=="Done"}}
    require(try! Data(contentsOf:destinationFolder.appendingPathComponent("Folder copy/nested/.hidden.txt"))==Data("Hidden child".utf8),"recursive folder download preserves hierarchy and hidden files")
    require(FileManager.default.fileExists(atPath:destinationFolder.appendingPathComponent("Folder copy/nested/empty").path),"empty folders preserved")
    folders.stop()
    wrong.stop();restored.stop();integrity.stop();await pause(0.2)
    try? FileManager.default.removeItem(at:directory)
    print("PASS: bidirectional byte resume, persistent queue with torn-journal recovery, SHA-256 verification, corrupt partial restart, both filename collisions, exact Finder promise, current-user validation, zero-byte files, changed-source refusal and cancellable hashing.")
    exit(0)
}
RunLoop.main.run()
