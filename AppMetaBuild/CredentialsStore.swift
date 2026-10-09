import Foundation
import AppKit
import UniformTypeIdentifiers
import Security

enum KeychainStore {
    static let service = "io.appmeta.build.api-key"

    /// Saves into the data-protection keychain so access is not re-ACL'd to each
    /// ad-hoc code signature. Rebuilding the app no longer prompts for the login password.
    static func save(keyId: String, pem: Data) throws {
        delete(account: keyId)
        var query = baseQuery(account: keyId, dataProtection: true)
        query[kSecValueData as String] = pem
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BuildError.message(L10n.t(
                "Could not save the private key to the login keychain (\(status)).",
                "无法把私钥写入登录钥匙串（\(status)）。"
            ))
        }
    }

    static func load(keyId: String) -> Data? {
        guard !keyId.isEmpty else { return nil }
        if let data = copyData(account: keyId, dataProtection: true) {
            return data
        }
        // One-shot migration from the legacy file-based login keychain item.
        guard let legacy = copyData(account: keyId, dataProtection: false) else { return nil }
        try? save(keyId: keyId, pem: legacy)
        return legacy
    }

    /// Presence check without returning the secret when possible.
    static func contains(keyId: String) -> Bool {
        guard !keyId.isEmpty else { return false }
        if hasItem(account: keyId, dataProtection: true) { return true }
        guard let legacy = copyData(account: keyId, dataProtection: false) else { return false }
        try? save(keyId: keyId, pem: legacy)
        return true
    }

    static func delete(account: String) {
        guard !account.isEmpty else { return }
        SecItemDelete(baseQuery(account: account, dataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
    }

    private static func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func hasItem(account: String, dataProtection: Bool) -> Bool {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func copyData(account: String, dataProtection: Bool) -> Data? {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}

final class CredentialsStore: ObservableObject {
    static let shared = CredentialsStore()

    @Published var credentials = Credentials()

    private var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppMeta Build", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var fileURL: URL { supportDirectory.appendingPathComponent("config.json") }
    private var legacyKeysDirectory: URL { supportDirectory.appendingPathComponent("private_keys", isDirectory: true) }

    private init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Credentials.self, from: data) else { return }
        credentials = decoded
        migrateLegacyKeyIfNeeded()
        if credentials.hasPrivateKey {
            // Avoid pulling the PEM on every launch; presence is enough for the UI flag.
            credentials.hasPrivateKey = KeychainStore.contains(keyId: credentials.storedKeyId)
        }
    }

    func save() {
        var next = credentials
        next.keyId = next.keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        next.issuerId = next.issuerId.trimmingCharacters(in: .whitespacesAndNewlines)
        next.legacyPrivateKeyPath = ""
        if next != credentials {
            credentials = next
        }
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // The next explicit save or key import can try again. The in-memory values stay.
        }
    }

    func choosePrivateKey() throws {
        let keyId = credentials.keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let issuerId = credentials.issuerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Credentials.isValidKeyID(keyId) else {
            throw BuildError.message(L10n.t(
                "Key ID must be 10 letters or digits before the private key can be saved.",
                "保存私钥前，Key ID 必须是 10 位字母或数字。"
            ))
        }
        guard Credentials.isValidIssuerID(issuerId) else {
            throw BuildError.message(L10n.t(
                "Issuer ID must be a UUID before the private key can be saved.",
                "保存私钥前，Issuer ID 必须是 UUID。"
            ))
        }
        let panel = NSOpenPanel()
        panel.title = L10n.t("Select AuthKey .p8", "选择 AuthKey .p8")
        if let ut = UTType(filenameExtension: "p8") {
            panel.allowedContentTypes = [ut]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let pem = try Data(contentsOf: src)
        try KeychainStore.save(keyId: keyId, pem: pem)
        credentials.keyId = keyId
        credentials.issuerId = issuerId
        credentials.storedKeyId = keyId
        credentials.hasPrivateKey = true
        credentials.legacyPrivateKeyPath = ""
        save()
        removeLegacyKeyFiles()
    }

    func removePrivateKey() {
        KeychainStore.delete(account: credentials.storedKeyId)
        KeychainStore.delete(account: credentials.keyId)
        credentials.hasPrivateKey = false
        credentials.storedKeyId = ""
        credentials.legacyPrivateKeyPath = ""
        save()
        removeLegacyKeyFiles()
    }

    private func migrateLegacyKeyIfNeeded() {
        let legacy = credentials.legacyPrivateKeyPath
        guard !legacy.isEmpty, FileManager.default.isReadableFile(atPath: legacy),
              Credentials.isValidKeyID(credentials.keyId),
              let pem = try? Data(contentsOf: URL(fileURLWithPath: legacy)) else { return }
        let keyId = credentials.keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.save(keyId: keyId, pem: pem)
            credentials.keyId = keyId
            credentials.storedKeyId = keyId
            credentials.hasPrivateKey = true
            credentials.legacyPrivateKeyPath = ""
            save()
            removeLegacyKeyFiles()
        } catch {
            credentials.hasPrivateKey = false
        }
    }

    private func removeLegacyKeyFiles() {
        try? FileManager.default.removeItem(at: legacyKeysDirectory)
    }
}
