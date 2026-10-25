import Foundation
if CommandLine.arguments.count == 3 {
    let lock = try AppInstanceLock(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(lock == nil ? 73 : 0)
}
func require(_ value: @autoclosure () -> Bool, _ text: String) { if !value() { fatalError(text) } }
let directory=FileManager.default.temporaryDirectory.appendingPathComponent("jh-instance-"+UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
func child() -> Int32 {
    let process=Process(); process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);process.arguments=["--probe",directory.path]
    try! process.run();process.waitUntilExit();return process.terminationStatus
}
var owner: AppInstanceLock? = try AppInstanceLock(directory: directory)
require(owner != nil && child()==73,"a separate process cannot become the second app owner")
let second=try AppInstanceLock(directory:directory)
require(second==nil,"two copies in one process also respect ownership")
let attributes=try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent(".instance.lock").path)
require((attributes[.posixPermissions] as? NSNumber)?.intValue==0o600,"ownership file stays private")
owner=nil;require(child()==0,"a new app can launch after the old one closes")
let file=directory.appendingPathComponent("untouched.txt");try Data("generated marker".utf8).write(to:file)
try FileManager.default.removeItem(at:directory.appendingPathComponent(".instance.lock"))
try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent(".instance.lock"),withDestinationURL:file)
do { _=try AppInstanceLock(directory:directory);fatalError("lock must refuse a symlink") } catch { }
require(try! String(contentsOf:file,encoding:.utf8)=="generated marker","symlink target is preserved")
print("PASS: cross-process single ownership, private lock, release/relaunch and symlink refusal")
