import Foundation
import Security

/// Reads the Wi-Fi password macOS already saved for a network (System keychain, service "AirPort").
/// When this works NodePin stores no password itself (see `FallbackWiFiPassword`). The first read shows macOS's keychain prompt; choosing
/// "Always Allow" adds NodePin to the item's access list so later switches don't ask.
nonisolated enum SystemWiFiPassword {
    enum LookupError: Error, LocalizedError {
        case notSaved(String), denied, other(OSStatus)
        var errorDescription: String? {
            switch self {
            case .notSaved(let ssid): "macOS has no saved password for \(ssid). Join it once from the Wi-Fi menu."
            case .denied: "macOS didn't allow NodePin to read the Wi-Fi password it saved."
            case .other(let status): "Couldn't read the saved Wi-Fi password (\(status))."
            }
        }
    }

    /// Blocks while macOS's keychain prompt is up, so call it off the main thread.
    static func lookup(ssid: String) -> Result<String, LookupError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "AirPort",
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data, let pw = String(data: data, encoding: .utf8) else { return .failure(.other(status)) }
            return .success(pw)
        case errSecItemNotFound: return .failure(.notSaved(ssid))
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: return .failure(.denied)
        default: return .failure(.other(status))
        }
    }

    /// Removes the password copy earlier EeroPin builds kept in the login keychain (service "eeropin").
    static func deleteLegacyCopy() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: "eeropin"] as CFDictionary)
    }
}

/// Fallback for Macs where the System keychain can't be read (unlocking it needs an admin): a
/// password the user typed into NodePin, kept in their login keychain (service "NodePin"). NodePin
/// created the item, so reading it never prompts.
nonisolated enum FallbackWiFiPassword {
    private static let service = "NodePin"

    static func lookup(ssid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ password: String, ssid: String) -> Bool {
        forget(ssid: ssid)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid,
            kSecAttrLabel as String: "NodePin Wi-Fi password (\(ssid))",
            kSecValueData as String: Data(password.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func forget(ssid: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: ssid] as CFDictionary)
    }

    /// Networks with a saved fallback password, for Settings. Reads attributes only, never the secrets.
    static func savedSSIDs() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}
