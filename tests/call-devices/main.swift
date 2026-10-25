import Foundation
import CoreAudio

struct CallError: Error { init(_ message: String) {} }
func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
// Read-only checks. Never change the default input, start IO or capture a microphone.
guard let initial = CallDevices.defaultInput(), let uid = CallDevices.uid(initial) else {
    print("SKIP: no default audio input is available for a read-only UID check.")
    exit(0)
}
require(CallDevices.device(uid: uid) == initial, "Core Audio qualifier UID lookup resolves the existing input")
require(CallDevices.device(uid: "jhmirror-missing-" + UUID().uuidString) == nil, "missing UID does not select another device")
require(CallDevices.defaultInput() == initial, "read-only checks leave the user's microphone selection unchanged")
print("PASS: Core Audio device UID roundtrip and missing UID; default input unchanged, no audio captured.")
