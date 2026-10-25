import Foundation
let root = FileManager.default.temporaryDirectory.appendingPathComponent("jh-media-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at:root) }
let remote = FixtureFiles(root:root.appendingPathComponent("phone")), peer = PhoneFileConnection(serial:"paired",peer:PhoneFilePeer(identity:"PHONE",user:0))
let cache = root.appendingPathComponent("cache"), actions = PhoneMediaActions(client:remote,directory:cache)
let original = Data(repeating:123,count:700000)
for name in ["One.png","Two.png","Three.png"] { try! original.write(to:remote.url(name)) }
let files = try! ["One.png","Two.png","Three.png"].map { try remote.info(peer,path:$0) }
func fetch(_ values:[PhoneFile]) throws -> [URL] { try actions.fetch(values,connection:peer,cancel:PhoneFileCancellation()) { _,_,_,_ in } }
let urls = try! fetch(Array(files.prefix(2)))
var indexed = files[0]; indexed.indexed = true
indexed = PhoneFile(path:indexed.path,name:indexed.name,directory:false,size:indexed.size,modified:indexed.modified/1000*1000,kind:indexed.kind,indexed:true)
require((try! fetch([indexed]))[0] == urls[0],"indexed timestamp resolves to exact metadata before preview and reuses verified cache")
var changedIndex = indexed
changedIndex = PhoneFile(path:indexed.path,name:indexed.name,directory:false,size:indexed.size+1,modified:indexed.modified,kind:indexed.kind,indexed:true)
do { _ = try fetch([changedIndex]);require(false,"changed indexed size refused") } catch {}
require(urls.count == 2 && (try! Data(contentsOf:urls[0])) == original, "bulk preview copies verified originals")
require(FileManager.default.fileExists(atPath:remote.url("One.png").path), "preview and clipboard copies keep phone originals")
require((try! FileManager.default.attributesOfItem(atPath:urls[0].path)[.posixPermissions] as! NSNumber).intValue == 0o600,"preview files are private")
let reads = remote.readOffsets.count
require((try! fetch([files[0]]))[0] == urls[0] && remote.readOffsets.count == reads,"warm previews avoid repeated phone downloads")
try! Data("Corrupted cache".utf8).write(to:urls[0])
require((try! Data(contentsOf:fetch([files[0]])[0])) == original,"damaged cached photo downloads again")
remote.wrongHash = true
do { _ = try fetch([files[2]]); require(false,"bad checksum refused") } catch {}
remote.wrongHash = false
let parts = try! FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)
require(parts.count == 3,"failed preview is removed without publishing corrupt data")
remote.currentUser = 10
do { _ = try fetch([files[0]]); require(false,"wrong user refused") } catch {}
remote.currentUser = 0
try! FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(30)],ofItemAtPath:remote.url("Two.png").path)
do { _ = try actions.removePhotos(Array(files.prefix(2)),connection:peer); require(false,"stale bulk selection refused") } catch {}
require(FileManager.default.fileExists(atPath:remote.url("One.png").path),"whole-batch preflight prevents deleting first photo when another changed")
let fresh = try! ["One.png","Two.png","Three.png"].map { try remote.info(peer,path:$0) }
remote.failRemovePath = "Two.png"
let partial = try! actions.removePhotos(fresh,connection:peer)
require(partial.removed.count == 1 && partial.failure != nil && FileManager.default.fileExists(atPath:remote.url("Three.png").path),"partial deletion reports exactly what happened and stops on failure")
remote.failRemovePath = nil
let done = try! actions.removePhotos(Array(fresh.dropFirst()),connection:peer)
require(done.removed.count == 2 && done.failure == nil,"bulk deletion removes only the confirmed photos")
require(FileManager.default.fileExists(atPath:urls[1].path),"phone deletion preserves Mac clipboard copies")
print("PASS: verified full-size media copies, private cache, warm reuse, corrupt cache repair, checksum rejection, profile guards, stale batch preflight, precise partial deletion and bulk deletion.")
