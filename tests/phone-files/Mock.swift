import Foundation
final class FixtureFiles: PhoneFilesAccess {
    let root: URL
    var currentUser = 0
    var interruptWrite = false, interruptRead = false, wrongHash = false
    var writeOffsets: [Int64] = [], readOffsets: [Int64] = []
    var afterWrite: (() -> Void)?
    var expected: [String:String] = [:], names: [String:String] = [:]
    let lock = NSLock()
    init(root: URL) { self.root = root; try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:true) }
    func url(_ path: String) -> URL { path.isEmpty ? root : root.appendingPathComponent(path) }
    func relative(_ file: URL) -> String { String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private var probeStarted = 0, probeCancelled = 0
    var probeCounts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (probeStarted, probeCancelled) }
    func connect(serial: String, identity: String) throws -> PhoneFileConnection { try connect(serial: serial, identity: identity, cancel: PhoneFileCancellation()) }
    func connect(serial: String, identity: String, cancel: PhoneFileCancellation) throws -> PhoneFileConnection {
        if serial.hasPrefix("slow-probe") {
            lock.lock(); probeStarted += 1; lock.unlock()
            do { for _ in 0..<150 { try cancel.check(); Thread.sleep(forTimeInterval: 0.01) } }
            catch { lock.lock(); probeCancelled += 1; lock.unlock(); throw error }
        }
        try cancel.check(); return PhoneFileConnection(serial:serial,peer:PhoneFilePeer(identity:identity,user:currentUser))
    }
    func validate(_ connection: PhoneFileConnection) throws { if connection.peer.user != currentUser { throw PhoneFileError("Wrong user") } }
    func info(_ connection: PhoneFileConnection, path: String) throws -> PhoneFile {
        let value = try url(path).resourceValues(forKeys:[.isDirectoryKey,.fileSizeKey,.contentModificationDateKey])
        let directory = value.isDirectory == true
        let kind = ["png":"photo","jpg":"photo","mp4":"video","wav":"audio"][url(path).pathExtension.lowercased()] ?? "file"
        return PhoneFile(path:path,name:url(path).lastPathComponent,directory:directory,size:directory ? 0 : Int64(value.fileSize ?? 0),modified:Int64((value.contentModificationDate?.timeIntervalSince1970 ?? 0)*1000),kind:directory ? "folder" : kind)
    }
    var slowMedia = false
    var mediaStarted = false, mediaCancelled = false
    var initialMediaSnapshot: PhoneFileList?
    var failFullMedia = false
    func initialMedia(_ connection: PhoneFileConnection, mode: String, cancel: PhoneFileCancellation) throws -> PhoneFileList? { try cancel.check(); return mode == "list" ? nil : initialMediaSnapshot }
    private var listCount = 0
    var listCalls: Int { lock.lock(); defer { lock.unlock() }; return listCount }
    func list(_ connection: PhoneFileConnection, path: String, mode: String, cancel: PhoneFileCancellation) throws -> PhoneFileList {
        try cancel.check()
        lock.lock(); listCount += 1; lock.unlock()
        if slowMedia && mode != "list" && mode != "tree" {
            mediaStarted = true
            do { for _ in 0..<100 { try cancel.check(); Thread.sleep(forTimeInterval:0.02) } }
            catch { mediaCancelled = true; throw error }
        }
        if failFullMedia && mode == "photo" { throw PhoneFileError("Generated full-index interruption") }
        let files: [URL]
        if mode == "list" { files = try FileManager.default.contentsOfDirectory(at:url(path),includingPropertiesForKeys:nil).filter { !$0.lastPathComponent.hasPrefix(".") } }
        else { files = (FileManager.default.enumerator(at:url(path),includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []).filter { mode == "tree" || (try? info(connection,path:relative($0)).kind) == mode } }
        let result = try files.map { try info(connection,path:relative($0)) }
        return PhoneFileList(path:path,items:result,truncated:false)
    }
    func hash(_ connection: PhoneFileConnection, file: PhoneFile, cancel: PhoneFileCancellation) throws -> String { wrongHash ? String(repeating:"0",count:64) : try FileTransferClient.hash(url(file.path)) }
    var thumbnailDelay = 0.0
    private var thumbnailCount = 0
    var thumbnailCalls: Int { lock.lock(); defer { lock.unlock() }; return thumbnailCount }
    func thumbnail(_ connection: PhoneFileConnection, file: PhoneFile, cancel: PhoneFileCancellation) throws -> Data? {
        lock.lock(); thumbnailCount += 1; lock.unlock()
        let until = Date().addingTimeInterval(thumbnailDelay)
        while Date() < until { try cancel.check(); Thread.sleep(forTimeInterval: 0.01) }
        try cancel.check(); return try? Data(contentsOf:url(file.path))
    }
    var previewDelay = 0.0
    private var previewCount = 0
    private var previewNames: [String] = []
    private var previewDelays: [String: Double] = [:]
    var previewCalls: Int { lock.lock(); defer { lock.unlock() }; return previewCount }
    var startedPreviews: [String] { lock.lock(); defer { lock.unlock() }; return previewNames }
    func delayPreview(_ name: String, by seconds: Double) { lock.lock(); previewDelays[name] = seconds; lock.unlock() }
    func preview(_ connection: PhoneFileConnection, file: PhoneFile, cancel: PhoneFileCancellation) throws -> PhonePreviewData {
        lock.lock(); previewCount += 1; previewNames.append(file.name); let delay = previewDelays[file.name] ?? previewDelay; lock.unlock()
        let until = Date().addingTimeInterval(delay)
        while Date() < until { try cancel.check(); Thread.sleep(forTimeInterval:0.01) }
        try cancel.check(); try validate(connection)
        let current = try info(connection,path:file.path)
        guard file.matches(current) else { throw PhoneFileError("Photo changed") }
        return PhonePreviewData(file:current,data:try Data(contentsOf:url(file.path)))
    }
    var failRemovePath: String?
    func removePhoto(_ connection: PhoneFileConnection, file: PhoneFile) throws {
        try validate(connection)
        guard file.kind == "photo", !file.directory, try info(connection,path:file.path) == file else { throw PhoneFileError("Photo changed") }
        if file.path == failRemovePath { throw PhoneFileError("Injected delete failure") }
        try FileManager.default.removeItem(at:url(file.path))
    }
    func makeDirectory(_ connection: PhoneFileConnection, path: String, name: String?) throws -> PhoneFile {
        var location = url(path)
        if let name {
            location = location.appendingPathComponent(name)
            var n=2;while FileManager.default.fileExists(atPath:location.path) { location = url(path).appendingPathComponent(name+" (\(n))");n+=1 }
        }
        try FileManager.default.createDirectory(at:location,withIntermediateDirectories:true)
        return try info(connection,path:relative(location))
    }
    func part(_ id:String) -> URL { root.appendingPathComponent(".part-"+id) }
    func beginUpload(_ connection: PhoneFileConnection, folder: String, id: String, name: String, size: Int64, hash: String, cancel: PhoneFileCancellation) throws -> (Int64, PhoneFile?) {
        expected[id]=hash;names[id]=name
        if !FileManager.default.fileExists(atPath:part(id).path) { FileManager.default.createFile(atPath:part(id).path,contents:nil) }
        return (Int64(try part(id).resourceValues(forKeys:[.fileSizeKey]).fileSize!),nil)
    }
    func copy(_ source:URL,_ destination:URL,_ offset:Int64,_ size:Int64,_ cancel:PhoneFileCancellation,_ progress:(Int64)->Void,_ interrupt:Bool) throws {
        let input=try FileHandle(forReadingFrom:source),output=try FileHandle(forWritingTo:destination);defer {try? input.close();try? output.close()}
        try input.seek(toOffset:UInt64(offset));try output.seek(toOffset:UInt64(offset));var position=offset
        while position<size {
            try cancel.check();let bytes=try input.read(upToCount:Int(min(262144,size-position)))!;try output.write(contentsOf:bytes);position+=Int64(bytes.count);progress(position)
            if interrupt && position>=1048576 { throw PhoneFileError("Injected disconnect") }
        }
    }
    func write(_ connection: PhoneFileConnection, folder: String, id: String, source: URL, offset: Int64, size: Int64, cancel: PhoneFileCancellation, progress: @escaping (Int64)->Void) throws {
        writeOffsets.append(offset);let interrupt=interruptWrite;interruptWrite=false
        try copy(source,part(id),offset,size,cancel,progress,interrupt)
        afterWrite?(); afterWrite = nil
    }
    func commit(_ connection: PhoneFileConnection, folder: String, id: String, size: Int64, cancel: PhoneFileCancellation) throws -> PhoneFile {
        guard try FileTransferClient.hash(part(id))==expected[id] else { throw PhoneFileError("Bad upload hash") }
        let name=names[id]!,ext=(name as NSString).pathExtension,stem=(name as NSString).deletingPathExtension
        var target=url(folder).appendingPathComponent(name),n=2
        while FileManager.default.fileExists(atPath:target.path) {target=url(folder).appendingPathComponent(stem+" (\(n))"+(ext.isEmpty ? "" : "."+ext));n+=1}
        try FileManager.default.moveItem(at:part(id),to:target)
        return try info(connection,path:relative(target))
    }
    func finish(_ connection: PhoneFileConnection, folder: String, id: String) { }
    func read(_ connection: PhoneFileConnection, file: PhoneFile, output: URL, offset: Int64, cancel: PhoneFileCancellation, progress: @escaping (Int64)->Void) throws {
        readOffsets.append(offset);let interrupt=interruptRead;interruptRead=false
        try copy(url(file.path),output,offset,file.size,cancel,progress,interrupt)
    }
}
func require(_ condition: @autoclosure ()->Bool,_ text:String) { if !condition() { fputs("FAIL: \(text)\n",stderr);exit(1) } }
