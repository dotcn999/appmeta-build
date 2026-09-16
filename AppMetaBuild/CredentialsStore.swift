import Foundation
import AppKit
import UniformTypeIdentifiers

final class CredentialsStore: ObservableObject {
    @Published var credentials = Credentials()

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppMeta Build", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    private var keysDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppMeta Build/private_keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Credentials.self, from: data) else { return }
        credentials = decoded
    }

    func save() {
        credentials.keyId = credentials.keyId.trimmingCharacters(in: .whitespaces)
        credentials.issuerId = credentials.issuerId.trimmingCharacters(in: .whitespaces)
        if let data = try? JSONEncoder().encode(credentials) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("Select AuthKey .p8", "选择 AuthKey .p8")
        if let ut = UTType(filenameExtension: "p8") {
            panel.allowedContentTypes = [ut]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let keyId = credentials.keyId.trimmingCharacters(in: .whitespaces)
        let name = keyId.isEmpty ? src.lastPathComponent : "AuthKey_\(keyId).p8"
        let dest = keysDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            credentials.privateKeyPath = dest.path
            save()
        } catch {
            credentials.privateKeyPath = src.path
            save()
        }
    }
}
