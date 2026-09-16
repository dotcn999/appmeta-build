import Foundation
import AppKit
import UniformTypeIdentifiers

final class BuildEngine: ObservableObject {
    @Published var projectPath = ""
    @Published var inspect: InspectResult?
    @Published var scheme = ""
    @Published var profile = ""
    @Published var log = ""
    @Published var stage = ""
    @Published var busy = false
    @Published var artifact = ""
    @Published var lastError = ""
    @Published var credentials = Credentials()

    private let pipeline = XcodePipeline()
    private let creds = CredentialsStore()
    private let queue = DispatchQueue(label: "io.appmeta.build.engine")

    var ready: Bool { inspect?.ready == true }
    var canUpload: Bool { credentials.isComplete }
    var facts: String {
        guard let ins = inspect else { return "" }
        var parts: [String] = []
        if !ins.bundleId.isEmpty { parts.append("Bundle ID \(ins.bundleId)") }
        if !ins.teamId.isEmpty { parts.append("Team \(ins.teamId)") }
        if !ins.signingStyle.isEmpty { parts.append("\(L10n.t("Signing", "签名")): \(ins.signingStyle)") }
        if !ins.distributionCerts.isEmpty {
            parts.append(L10n.t("Apple Distribution certificate found", "已找到 Apple Distribution 证书"))
        } else {
            parts.append(L10n.t("No Apple Distribution certificate in the keychain", "钥匙串里没有 Apple Distribution 证书"))
        }
        return parts.joined(separator: " · ")
    }

    init() {
        credentials = creds.credentials
    }

    func saveCredentials() {
        creds.credentials = credentials
        creds.save()
        credentials = creds.credentials
    }

    func choosePrivateKey() {
        creds.credentials = credentials
        creds.choosePrivateKey()
        credentials = creds.credentials
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("Select an .xcodeproj", "选择 .xcodeproj")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if let ut = UTType(filenameExtension: "xcodeproj") {
            panel.allowedContentTypes = [ut]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectPath = url.path
        runInspect()
    }

    func runInspect() {
        let path = projectPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        busy = true
        lastError = ""
        let selectedScheme = scheme
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.pipeline.inspect(projectPath: path, scheme: selectedScheme)
                DispatchQueue.main.async {
                    self.inspect = result
                    self.scheme = result.suggestedScheme
                    self.profile = result.selectedProfile?.value ?? ""
                    self.busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.busy = false
                }
            }
        }
    }

    func runExport(upload: Bool) {
        guard let ins = inspect else { return }
        if upload && !canUpload {
            lastError = L10n.t("Save Key ID, Issuer ID and the .p8 key first.", "请先填写 Key ID、Issuer ID 并选择 .p8。")
            return
        }
        busy = true
        lastError = ""
        log = ""
        artifact = ""
        let cred = credentials
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let ipa = try self.pipeline.archiveAndExport(
                    project: self.projectPath,
                    scheme: self.scheme,
                    teamId: ins.teamId,
                    bundleId: ins.bundleId,
                    profile: self.profile,
                    onLog: { line in DispatchQueue.main.async { self.appendLog(line) } },
                    onStage: { s, m in DispatchQueue.main.async { self.stage = "\(s): \(m)" } }
                )
                DispatchQueue.main.async { self.artifact = ipa }
                if upload {
                    try self.pipeline.upload(
                        ipa: ipa,
                        credentials: cred,
                        onLog: { line in DispatchQueue.main.async { self.appendLog(line) } },
                        onStage: { s, m in DispatchQueue.main.async { self.stage = "\(s): \(m)" } }
                    )
                } else {
                    DispatchQueue.main.async {
                        self.stage = L10n.t("IPA exported.", "IPA 已导出。")
                    }
                }
                DispatchQueue.main.async { self.busy = false }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.busy = false
                }
            }
        }
    }

    func runUpload() {
        guard !artifact.isEmpty else { return }
        if !canUpload {
            lastError = L10n.t("Save Key ID, Issuer ID and the .p8 key first.", "请先填写 Key ID、Issuer ID 并选择 .p8。")
            return
        }
        busy = true
        lastError = ""
        let ipa = artifact
        let cred = credentials
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.pipeline.upload(
                    ipa: ipa,
                    credentials: cred,
                    onLog: { line in DispatchQueue.main.async { self.appendLog(line) } },
                    onStage: { s, m in DispatchQueue.main.async { self.stage = "\(s): \(m)" } }
                )
                DispatchQueue.main.async { self.busy = false }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.busy = false
                }
            }
        }
    }

    func cancel() { pipeline.cancel() }

    func revealArtifact() {
        guard !artifact.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact)])
    }

    private func appendLog(_ line: String) {
        log += (log.isEmpty ? "" : "\n") + line
    }
}
