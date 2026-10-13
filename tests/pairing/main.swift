import Foundation
let phoneSerial = "R5CW515PYBR"
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
print("PASS: pairing endpoint validation, code/port confusion, duplicate-name discovery and filtering to the Samsung.")
