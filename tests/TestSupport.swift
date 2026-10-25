import Foundation
let phoneSerial = "TESTPHONE"
struct CommandResult { let code: Int32; let output: String }
func command(_ args: [String], timeout: Double = 8) -> CommandResult { CommandResult(code: 0, output: "") }
func findPhone() -> String? { nil }
func connectionLog(_ text: String) {}
