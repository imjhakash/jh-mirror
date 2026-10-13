import Foundation

let http = PairedHTTP()
http.trust(CommandLine.arguments[2])
let config = URLSessionConfiguration.ephemeral
config.timeoutIntervalForRequest = 3
let session = URLSession(configuration: config, delegate: http, delegateQueue: nil)
var request = URLRequest(url: URL(string: CommandLine.arguments[1])!)
request.setValue("Bearer test-only-credential", forHTTPHeaderField: "Authorization")
let complete = DispatchSemaphore(value: 0)
let expected = CommandLine.arguments[3]
var passed = false
session.dataTask(with: request) { data, response, error in
    if expected == "accept" { passed = error == nil && (response as? HTTPURLResponse)?.statusCode == 200 }
    else if expected == "redirect" { passed = (response as? HTTPURLResponse)?.statusCode == 302 }
    else { passed = error != nil }
    complete.signal()
}.resume()
_ = complete.wait(timeout: .now() + 5)
session.invalidateAndCancel()
assert(passed, "TLS test failed: " + expected)
print("PASS:", expected)
