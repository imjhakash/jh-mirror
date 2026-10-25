import Foundation
let adbPath = "/Applications/JH Mirror.app/Contents/MacOS/adb"
func adbEnvironment() -> [String:String] { var env=ProcessInfo.processInfo.environment;env["ANDROID_ADB_SERVER_PORT"]="5139";env["ADB_MDNS_AUTO_CONNECT"]="0";return env }
final class PairedHTTP: NSObject, URLSessionDelegate { func trust(_ value:String?) { } }
