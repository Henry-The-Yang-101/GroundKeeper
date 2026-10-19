import Foundation
import Security
import LocalAuthentication
import GroundKeeperCore

/// Opt-in, device-local convenience unlock. The passphrase remains the recovery credential.
enum VaultKeychain {
    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppPreferences.isSetupPreview ? "com.groundkeeper.preview.\(ProcessInfo.processInfo.processIdentifier)" : "com.groundkeeper.macos.vault",
         kSecAttrAccount as String: "local-vault-passphrase",
         kSecUseDataProtectionKeychain as String: true]
    }
    static var isSupported: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String else { return false }
        return value.contains(".com.groundkeeper.")
    }
    static var isEnabled: Bool { AppPreferences.defaults.bool(forKey: "vaultConvenienceUnlock") }
    static func remove() throws {
        let code = SecItemDelete(identity as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw failure(code) }
        AppPreferences.defaults.set(false, forKey: "vaultConvenienceUnlock")
    }
    static func save(_ passphrase: String) throws {
        try remove()
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
            throw LedgerError.unavailable("This Mac could not create protected Keychain access. Use your passphrase to unlock.")
        }
        var item = identity
        item[kSecAttrAccessControl as String] = access
        item[kSecValueData as String] = Data(passphrase.utf8)
        item[kSecAttrLabel as String] = "GroundKeeper vault unlock"
        let code = SecItemAdd(item as CFDictionary, nil)
        guard code == errSecSuccess else { throw failure(code) }
        AppPreferences.defaults.set(true, forKey: "vaultConvenienceUnlock")
    }
    static func load() throws -> String {
        let context = LAContext()
        context.localizedReason = "Unlock your GroundKeeper transaction vault"
        var query = identity
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        guard code == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw failure(code) }
        return value
    }
    private static func failure(_ code: OSStatus) -> LedgerError {
        .unavailable(code == errSecUserCanceled ? "Unlock cancelled. You can use your vault passphrase." : "Keychain unlock is unavailable (\(code)). Use your vault passphrase.")
    }
}
