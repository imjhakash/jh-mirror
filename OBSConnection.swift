import Foundation
import CryptoKit
import Security

struct CallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum OBSAuthentication {
    static func response(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }
}

enum CallCredential {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.johirulhoqakash.jhmirror.obs", kSecAttrAccount as String: "localhost"]
    static func read() -> String {
        var request = query; request[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ password: String) throws {
        if password.isEmpty { SecItemDelete(query as CFDictionary); return }
        let attributes = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var record = query; record.merge(attributes) { _, new in new }
            record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(record as CFDictionary, nil) == errSecSuccess else { throw CallError("Could not save the OBS password in Keychain.") }
        } else if status != errSecSuccess { throw CallError("Could not update the OBS password in Keychain.") }
    }
}

enum OBSLocalSetup {
    /// Import the current local OBS credential without exposing it to logs, clipboard or command arguments.
    static func importSettings() throws -> Int {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")
        let info = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (info[.size] as? Int ?? Int.max) < 65_536,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              object["server_enabled"] as? Bool == true, object["auth_required"] as? Bool == true,
              let password = object["server_password"] as? String, !password.isEmpty,
              let port = object["server_port"] as? Int, (1024...65535).contains(port) else {
            throw CallError("In OBS, enable WebSocket Server with authentication first, then import its settings.")
        }
        try CallCredential.save(password)
        UserDefaults.standard.set(port, forKey: "obsWebSocketPort")
        return port
    }
}

/// OBS WebSocket v5, loopback only. A single owner serializes request/reply exchanges.
actor OBSConnection {
    private var socket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)

    func connect(port: Int, password: String) async throws {
        close()
        guard (1024...65535).contains(port), let url = URL(string: "ws://127.0.0.1:\(port)") else { throw CallError("Enter a valid OBS WebSocket port.") }
        let ws = session.webSocketTask(with: url); socket = ws; ws.resume()
        let hello = try await receive()
        guard hello["op"] as? Int == 0, let data = hello["d"] as? [String: Any], (data["rpcVersion"] as? Int ?? 0) >= 1 else {
            throw CallError("OBS WebSocket 5 or newer is required.")
        }
        var identify: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": 0]
        if let auth = data["authentication"] as? [String: String], let salt = auth["salt"], let challenge = auth["challenge"] {
            identify["authentication"] = OBSAuthentication.response(password: password, salt: salt, challenge: challenge)
        }
        try await send(["op": 1, "d": identify])
        guard try await receive()["op"] as? Int == 2 else { throw CallError("OBS authentication failed. Check the password in Call Setup.") }
    }

    func close() { socket?.cancel(with: .goingAway, reason: nil); socket = nil }

    private func receive() async throws -> [String: Any] {
        guard let socket else { throw CallError("OBS is disconnected.") }
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000); socket.cancel(with: .goingAway, reason: nil) } catch { }
        }
        defer { timeout.cancel() }
        let message = try await socket.receive()
        let data: Data
        switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: throw CallError("Invalid OBS response.") }
        guard data.count < 1_000_000, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CallError("Invalid OBS response.") }
        return result
    }

    private func send(_ value: [String: Any]) async throws {
        guard let socket else { throw CallError("OBS is disconnected.") }
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func request(_ type: String, _ data: [String: Any] = [:]) async throws -> [String: Any] {
        let id = UUID().uuidString
        try await send(["op": 6, "d": ["requestType": type, "requestId": id, "requestData": data]])
        for _ in 0..<32 {
            let message = try await receive()
            guard message["op"] as? Int == 7, let reply = message["d"] as? [String: Any], reply["requestId"] as? String == id else { continue }
            guard let status = reply["requestStatus"] as? [String: Any], status["result"] as? Bool == true else {
                throw CallError("OBS could not complete \(type). Check that its virtual camera is installed and enabled.")
            }
            return reply["responseData"] as? [String: Any] ?? [:]
        }
        throw CallError("OBS did not reply to \(type).")
    }
}
