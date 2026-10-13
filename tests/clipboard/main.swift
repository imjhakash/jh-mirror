import AppKit

// Uses a private, uniquely named pasteboard: the user's real clipboard is never touched.
let pasteboard = NSPasteboard(name: NSPasteboard.Name("local.androidwireless.test." + UUID().uuidString))
defer { pasteboard.releaseGlobally() }
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aw-clipboard-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
var providers: [ImagePasteboardProvider] = []

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
for (name, type) in [("photo.jpg", NSBitmapImageRep.FileType.jpeg), ("screenshot.png", .png)] {
    let url = folder.appendingPathComponent(name)
    try! bitmap.representation(using: type, properties: [:])!.write(to: url)
    assert(placeOnPasteboard(url, pasteboard: pasteboard, providers: &providers), name)
    let types = Set(pasteboard.types ?? [])
    assert(types.contains(.fileURL), "\(name) must paste as a file in Finder/Mail")
    assert(types.contains(.tiff) && types.contains(.png), "\(name) must offer TIFF/PNG for image paste targets")
    assert(pasteboard.pasteboardItems?.count == 1, "one paste must insert one item")
    let tiff = pasteboard.data(forType: .tiff)
    assert(tiff != nil && NSImage(data: tiff!)?.size == NSSize(width: 4, height: 3), "\(name) lazy TIFF rendering")
    assert(pasteboard.data(forType: .png) != nil, "\(name) PNG rendering")
    assert(URL(string: pasteboard.string(forType: .fileURL) ?? "")?.lastPathComponent == name)
}
let text = folder.appendingPathComponent("Phone clipboard.txt")
try! "Hello from the phone · नमस्ते".write(to: text, atomically: true, encoding: .utf8)
assert(placeOnPasteboard(text, pasteboard: pasteboard, providers: &providers))
assert(pasteboard.string(forType: .string) == "Hello from the phone · नमस्ते", "copied text pastes as text")
let document = folder.appendingPathComponent("report.pdf")
try! Data("%PDF-1.4\n".utf8).write(to: document)
assert(placeOnPasteboard(document, pasteboard: pasteboard, providers: &providers))
assert(pasteboard.types?.contains(.fileURL) == true && pasteboard.types?.contains(.tiff) != true, "documents paste as files")
print("PASS: images paste as image data and file; text pastes as text; documents paste as files; one item per paste.")
