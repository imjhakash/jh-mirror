import AppKit
import UniformTypeIdentifiers

/// Supplies TIFF/PNG renderings lazily, only if the pasting app asks for them.
final class ImagePasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    let url: URL
    init(url: URL) { self.url = url }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let original = UTType(filenameExtension: url.pathExtension), type.rawValue == original.identifier {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) { item.setData(data, forType: type) }
            return
        }
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation else { return }
        if type == .tiff { item.setData(tiff, forType: .tiff) }
        else if type == .png, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
    }
}

/// Each selection stays one pasteboard item, with image data for editors and a file URL for Finder.
/// Originals and rendered formats are supplied on demand, avoiding decoding a whole photo selection at once.
@discardableResult func placeImagesOnPasteboard(_ urls: [URL], pasteboard: NSPasteboard = .general,
                                               providers: inout [ImagePasteboardProvider]) -> Bool {
    guard !urls.isEmpty else { return false }
    var retained: [ImagePasteboardProvider] = [], items: [NSPasteboardItem] = []
    for url in urls {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        let item = NSPasteboardItem(), provider = ImagePasteboardProvider(url: url)
        item.setDataProvider(provider, forTypes: Array(Set([NSPasteboard.PasteboardType(type.identifier), .tiff, .png])))
        item.setString(url.absoluteString, forType: .fileURL)
        retained.append(provider); items.append(item)
    }
    pasteboard.clearContents()
    guard pasteboard.writeObjects(items) else { return false }
    providers = retained; return true
}

/// Puts a received file on the Mac clipboard so ⌘V pastes it in WhatsApp, Notes, Mail, Finder and others.
/// Text files paste as text; images paste as images (with the file as a fallback); other files paste as files.
@discardableResult func placeOnPasteboard(_ url: URL, pasteboard: NSPasteboard = .general,
                                          providers: inout [ImagePasteboardProvider]) -> Bool {
    let type = UTType(filenameExtension: url.pathExtension)
    if type?.conforms(to: .plainText) == true,
       let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 8_000_000,
       let text = try? String(contentsOf: url, encoding: .utf8) {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
    let item = NSPasteboardItem()
    if let type, type.conforms(to: .image), let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
        let original = NSPasteboard.PasteboardType(type.identifier)
        item.setData(data, forType: original)
        let rendered = [NSPasteboard.PasteboardType.tiff, .png].filter { $0 != original }
        let provider = ImagePasteboardProvider(url: url)
        item.setDataProvider(provider, forTypes: rendered)
        providers = [provider] // Keep the provider alive while it is on the pasteboard.
    }
    item.setString(url.absoluteString, forType: .fileURL)
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
}
