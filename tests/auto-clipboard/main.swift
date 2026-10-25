import Foundation

// Stand-ins for the app's ADB helpers; `command` runs the fake adb given on the command line.
let adbPath = CommandLine.arguments[1]
let phoneSerial = "TESTPHONE"
struct CommandResult { let code: Int32; let output: String }
func command(_ args: [String], timeout: Double = 8) -> CommandResult {
    var args = args
    if let shell = args.firstIndex(of: "shell") { args.insert("-n", at: shell + 1) }
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: adbPath); process.arguments = args
    process.standardOutput = pipe; process.standardError = pipe
    try! process.run(); process.waitUntilExit()
    return CommandResult(code: process.terminationStatus, output: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}
func findPhone() -> String? { nil }
func connectionLog(_ text: String) { print("LOG:", text) }
func noteADBVerified() {}

// Parser and extension checks.
assert(PhoneClipEvent.parse("AW_CLIP_READY") == .ready)
assert(PhoneClipEvent.parse("AW_CLIP_TEXT " + Data("héllo".utf8).base64EncodedString()) == .text("héllo"))
assert(PhoneClipEvent.parse("AW_CLIP_URI  " + Data("content://x/1".utf8).base64EncodedString()) == .uri(mime: "", uri: "content://x/1"))
assert(PhoneClipEvent.parse("AW_CLIP_URI " + Data("image/png".utf8).base64EncodedString() + " " + Data("file:///etc/passwd".utf8).base64EncodedString()) == nil, "only content URIs")
assert(PhoneClipEvent.parse("AW_CLIP_TEXT !!!") == nil && PhoneClipEvent.parse("garbage") == nil)
assert(clipboardFileExtension(mime: "image/jpeg", data: Data()) == "jpeg" || clipboardFileExtension(mime: "image/jpeg", data: Data()) == "jpg")
assert(clipboardFileExtension(mime: "", data: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])) == "png")
assert(clipboardFileExtension(mime: "image/*", data: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
assert(phoneShellQuote("a 'b' c") == "'a '\\''b'\\'' c'")

// End to end against the fake phone.
let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let sync = PhoneClipboardSync(folder: folder)
sync.helperJar = URL(fileURLWithPath: CommandLine.arguments[3])
var texts: [String] = [], files: [URL] = [], statuses: [String] = []
sync.onText = { texts.append($0) }
sync.onFile = { files.append($0) }
sync.onStatus = { statuses.append($0) }
sync.useSerial("TESTSERIAL")
sync.enabled = true
sync.start()
RunLoop.main.run(until: Date().addingTimeInterval(8))
sync.stop()
RunLoop.main.run(until: Date().addingTimeInterval(1))
let fixtures = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
assert(texts == ["hello from phone"], "text: \(texts)")
assert(files.map(\.lastPathComponent) == ["cat photo.png", "fallback photo.png"], "files: \(files)")
assert((try? Data(contentsOf: files[0])) == (try? Data(contentsOf: fixtures.appendingPathComponent("direct.png"))), "direct read intact")
assert((try? Data(contentsOf: files[1])) == (try? Data(contentsOf: fixtures.appendingPathComponent("fallback.png"))), "file fallback intact")
assert(statuses.contains { $0.contains("sensitive") }, "sensitive copies are reported as skipped")
assert(statuses.contains { $0.hasPrefix("Auto-copy on") }, "ready status")
assert(statuses.contains { $0.hasPrefix("Could not read that copy") }, "unreadable copy reported, not saved")
assert(!isCopiedContent(Data("Error while accessing provider:media\njava.lang.Exception".utf8), mime: "image/jpeg"))
assert(!isCopiedContent(Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]), mime: "image/jpeg"), "images must decode")
assert(isCopiedContent(Data("%PDF-1.4".utf8), mime: "application/pdf"))
print("PASS: watcher events parsed; text delivered; images fetched intact with names (direct and file fallback); duplicate ignored; error output never saved; sensitive skipped; unsafe URIs rejected.")
