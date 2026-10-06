import Foundation
import Security

/// Room keys in the login keychain, so keyed rooms can be rejoined after a restart.
/// Stored by room fingerprint, not name: a different room that later takes the name never
/// gets the key.
enum RoomKeychain {
    private static let service = "Phosphor room key"

    private static func query(_ room: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: room]
    }

    static func key(for room: String) -> String? {
        var q = query(room)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String, for room: String) {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(room) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(room)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "Phosphor: key for room \(room)"
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func remove(for room: String) {
        SecItemDelete(query(room) as CFDictionary)
    }
}
