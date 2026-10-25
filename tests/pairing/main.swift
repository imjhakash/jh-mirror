import Foundation
let phoneSerial = "R5CW515PYBR"
func connectionLog(_ text: String) {}
struct CommandResult { let code: Int32; let output: String }
func command(_ args: [String], timeout: Double = 8) -> CommandResult {
    CommandResult(code: 0, output: "List of discovered mdns services\nadb-R5CW515PYBR-XUicth (2)\t_adb-tls-pairing._tcp\t192.168.0.159:37283\nadb-R5CW515PYBR-XUicth\t_adb-tls-pairing._tcp\t192.168.0.159:37283\nadb-OTHER-X\t_adb-tls-pairing._tcp\t192.168.0.160:40000\n")
}
func findPhone() -> String? { nil }
assert(wirelessEndpoint(" 192.168.0.159:37283\n") == "192.168.0.159:37283")
assert(wirelessEndpoint("10.0.0.1:65535") != nil)
assert(wirelessEndpoint("172.16.2.3:1") != nil)
for value in ["272628", "192.168.0.159:879444", "192.168.0.256:1234", "192.168.0.159:0", "192.168.0.159:65536", "1.1.1.1:1234", "192.168.0.159:1234; echo hello"] {
    assert(wirelessEndpoint(value) == nil, value)
}
assert(discoveredWirelessEndpoints("_adb-tls-pairing._tcp") == ["192.168.0.159:37283"])
assert(pairedSerial(from: "Successfully paired to 192.168.0.159:37283 [guid=adb-R5CW515PYBR-XUicth]") == "R5CW515PYBR")
assert(pairedSerial(from: "Failed: Unable to start pairing client.") == nil)
assert(pairedSerial(from: "Successfully paired to 10.0.0.2:4000 [guid=adb-bad serial;rm-x]") == nil, "unsafe serials rejected")
assert(adbPairingQRText(name: "jhmirror-abc123", password: "p4ss") == "WIFI:T:ADB;S:jhmirror-abc123;P:p4ss;;")
assert(randomToken(12).count == 12 && randomToken(12) != randomToken(12))
print("PASS: QR pairing text, serial parsed from pairing reply; pairing endpoint validation, code/port confusion, duplicate-name discovery and filtering to the Samsung.")
