import Foundation
import Security

/// Reads the Wi-Fi password macOS already saved for a network (System keychain, service "AirPort").
/// NodePin never stores a password itself. The first read shows macOS's keychain prompt; choosing
/// "Always Allow" adds NodePin to the item's access list so later switches don't ask.
nonisolated enum SystemWiFiPassword {
    enum LookupError: Error, LocalizedError {
        case notSaved(String), denied, other(OSStatus)
        var errorDescription: String? {
            switch self {
            case .notSaved(let ssid): "macOS has no saved password for \(ssid). Join it once from the Wi-Fi menu."
            case .denied: "Keychain access was denied. Switch again and choose Always Allow."
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
