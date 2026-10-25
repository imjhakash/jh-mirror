import AppKit
import ImageIO

final class PhonePreviewFrame {
    let file: PhoneFile
    let image: NSImage
    let cost: Int
    init(file: PhoneFile, image: NSImage, cost: Int) { self.file=file; self.image=image; self.cost=cost }
}
private final class PhonePreviewRequest: Operation, @unchecked Sendable {
    let cancellation: PhoneFileCancellation
    private let work: () -> Void
    init(cancellation: PhoneFileCancellation, work: @escaping () -> Void) { self.cancellation=cancellation; self.work=work; super.init() }
    override func cancel() { super.cancel(); cancellation.cancel() }
    override func main() { if !isCancelled { work() } }
}

/// Main-thread coordinator; decoding and phone requests run in a bounded queue.
final class PhonePreviewLoader {
    private struct Pending { let operation: PhonePreviewRequest; let cancellation: PhoneFileCancellation }
    private let client: PhoneFilesAccess
    private let queue = OperationQueue()
    private let cache = NSCache<NSString,PhonePreviewFrame>()
    private var pending: [String:Pending] = [:]
    private var current: String?
    private var completion: ((Result<PhonePreviewFrame,Error>) -> Void)?
    init(client: PhoneFilesAccess) {
        self.client=client; queue.maxConcurrentOperationCount=2; queue.qualityOfService = .userInitiated
        cache.countLimit=12; cache.totalCostLimit=64*1024*1024
    }
    private func key(_ file: PhoneFile, _ connection: PhoneFileConnection) -> String {
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        return String(decoding:try! encoder.encode(connection.peer),as:UTF8.self)+String(decoding:try! encoder.encode(file),as:UTF8.self)
    }
    func cached(_ file: PhoneFile, connection: PhoneFileConnection) -> NSImage? { cache.object(forKey:key(file,connection) as NSString)?.image }
    func warm(_ file: PhoneFile, connection: PhoneFileConnection) {
        guard current == nil else {return}
        let id=key(file,connection)
        for (other,job) in pending where other != id {job.operation.cancel();pending.removeValue(forKey:other)}
        request(file,connection:connection,foreground:false)
    }
    func focus(_ files: [PhoneFile], index: Int, connection: PhoneFileConnection, completion: @escaping (Result<PhonePreviewFrame,Error>) -> Void) {
        guard files.indices.contains(index) else { return }
        let neighbors=[index,index+1,index-1,index+2,index-2].filter { files.indices.contains($0) }
        let wanted=Set(neighbors.map { key(files[$0],connection) })
        for (id,job) in pending where !wanted.contains(id) { job.operation.cancel(); pending.removeValue(forKey:id) }
        let focusedID = key(files[index],connection)
        current=focusedID;self.completion=completion
        // A newly selected image must not wait for two in-flight neighbors,
        // even if those neighbors are still useful for subsequent navigation.
        if cache.object(forKey:focusedID as NSString) == nil, pending[focusedID]?.operation.isExecuting != true {
            let busy = pending.filter { $0.key != focusedID && $0.value.operation.isExecuting && !$0.value.operation.isCancelled }
            if busy.count >= 2, let victim = busy.min(by: { $0.value.operation.queuePriority.rawValue < $1.value.operation.queuePriority.rawValue }) {
                victim.value.operation.cancel(); pending.removeValue(forKey: victim.key)
            }
        }
        request(files[index],connection:connection,foreground:true)
        for neighbor in neighbors.dropFirst() { request(files[neighbor],connection:connection,foreground:false) }
    }
    func cancel() {
        current=nil;completion=nil
        for job in pending.values { job.operation.cancel() };pending.removeAll();queue.cancelAllOperations()
    }
    func invalidate() { cancel();cache.removeAllObjects() }
    private func request(_ file: PhoneFile, connection: PhoneFileConnection, foreground: Bool) {
        let id=key(file,connection)
        if let saved=cache.object(forKey:id as NSString) { if foreground { completion?(.success(saved)) };return }
        if let job=pending[id] { if foreground { job.operation.queuePriority = .veryHigh };return }
        let cancellation=PhoneFileCancellation(), client=client
        let operation=PhonePreviewRequest(cancellation:cancellation) { [weak self] in
            let result=Result { () -> PhonePreviewFrame in
                let reply=try client.preview(connection,file:file,cancel:cancellation);try cancellation.check()
                guard let source=CGImageSourceCreateWithData(reply.data as CFData,nil),
                      let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                        kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1600,kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
                else { throw PhoneFileError("This image could not be previewed. Open Original to try Quick Look.") }
                return PhonePreviewFrame(file:reply.file,image:NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height)),cost:image.bytesPerRow*image.height)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pending[id]?.cancellation === cancellation else { return }
                self.pending.removeValue(forKey:id)
                guard !cancellation.cancelled else { return }
                if case .success(let frame)=result { self.cache.setObject(frame,forKey:id as NSString,cost:frame.cost) }
                if self.current == id { self.completion?(result) }
            }
        }
        operation.queuePriority=foreground ? .veryHigh : .low
        pending[id]=Pending(operation:operation,cancellation:cancellation);queue.addOperation(operation)
    }
}
