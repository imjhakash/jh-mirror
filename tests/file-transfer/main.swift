import Foundation
let client = FileTransferClient(folder: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
let port = Int(CommandLine.arguments[1])!
let expected = Int(CommandLine.arguments[3])!
var received = [String]()
client.onReceived = { received.append($0.lastPathComponent); print("Received:", $0.lastPathComponent) }
client.onClipboard = { print("Clipboard:", $0.lastPathComponent) }
client.onStatus = { print($0) }
let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in client.tick(port: port, token: String(repeating: "a", count: 64)) }
RunLoop.main.run(until: Date().addingTimeInterval(12))
timer.invalidate(); client.stop()
if received.count != expected { fputs("Unexpected received count: \(received.count)\n", stderr); exit(1) }
