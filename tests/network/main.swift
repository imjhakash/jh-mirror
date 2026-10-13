import Foundation

let phoneSerial = "TESTPHONE"
struct CommandResult { let code: Int32; let output: String }
func command(_ args: [String], timeout: Double = 8) -> CommandResult { CommandResult(code: 0, output: "") }

let devices = "List of devices attached\n192.168.0.159:45543 device\n"
let stale = "adb-TESTPHONE-id _adb-tls-connect._tcp 192.168.0.159:34841\nadb-TESTPHONE-id (2) _adb-tls-connect._tcp 192.168.0.159:45543\nadb-OTHER-id _adb-tls-connect._tcp 192.168.0.160:11111\n"
assert(connectionCandidates(devices: devices, services: stale, previous: "192.168.0.159:45543") == ["192.168.0.159:45543", "192.168.0.159:34841"])
assert(connectionCandidates(devices: "", services: "", previous: "192.168.0.159:45543") == ["192.168.0.159:45543"])
var retry = RetryGate()
let now = Date()
retry.failed(now: now)
assert(!retry.ready(now: now.addingTimeInterval(1)))
assert(retry.ready(now: now.addingTimeInterval(2)))
for _ in 0..<10 { retry.failed(now: now) }
assert(retry.next.timeIntervalSince(now) == 30)
retry.succeeded(); assert(retry.ready(now: now))
print("PASS: live endpoint wins over stale mDNS; cached endpoint survives discovery loss; retry backoff is bounded and resets on recovery.")
