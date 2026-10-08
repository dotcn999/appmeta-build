import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class BuildEngine: ObservableObject {
    static weak var active: BuildEngine?

    @Published var projectPath = ""
    @Published var inspect: InspectResult?
    @Published var scheme = ""
    @Published var profile = ""
    @Published var log = ""
    @Published var stage = ""
    @Published var busy = false
    @Published var artifact = ""
    @Published var logFile = ""
    @Published var lastError = ""
    @Published var wasCancelled = false
    @Published var credentials = Credentials()

    nonisolated let pipeline: XcodePipeline
    private let creds = CredentialsStore()
    private var logLines: [String] = []
    static let maxLogLines = 4000

    var ready: Bool { inspect?.ready == true }
    var canUpload: Bool { credentials.isComplete }
    var selectedProfileInfo: ProfileInfo? {
        inspect?.profiles.first { $0.value == profile }
    }
    var canUploadBuild: Bool { canUpload && (selectedProfileInfo?.isAppStore ?? false) }
    var facts: String {
        guard let ins = inspect else { return "" }
        var parts: [String] = []
        if !ins.configuration.isEmpty { parts.append(ins.configuration) }
        if !ins.bundleId.isEmpty { parts.append("Bundle ID \(ins.bundleId)") }
        if !ins.teamId.isEmpty { parts.append("Team \(ins.teamId)") }
        if !ins.signingStyle.isEmpty { parts.append("\(L10n.t("Signing", "签名")): \(ins.signingStyle)") }
        if ins.usesDevelopmentSigning {
            if !ins.developmentCerts.isEmpty {
                parts.append(L10n.t("Apple Development certificate found", "已找到 Apple Development 证书"))
            } else {
                parts.append(L10n.t("No Apple Development certificate in the keychain", "钥匙串里没有 Apple Development 证书"))
            }
        } else if !ins.distributionCerts.isEmpty {
            parts.append(L10n.t("Apple Distribution certificate found", "已找到 Apple Distribution 证书"))
        } else {
            parts.append(L10n.t("No Apple Distribution certificate in the keychain", "钥匙串里没有 Apple Distribution 证书"))
        }
        return parts.joined(separator: " · ")
    }

    init() {
        pipeline = XcodePipeline()
        credentials = creds.credentials
        Self.active = self
    }

    func saveCredentials() {
        creds.credentials = credentials
        creds.save()
        credentials = creds.credentials
    }

    func choosePrivateKey() {
        guard !busy else { return }
        creds.credentials = credentials
        creds.choosePrivateKey()
        credentials = creds.credentials
    }

    func chooseProject() {
        guard !busy else { return }
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

    func handleSchemeChange(_ newScheme: String) {
        guard inspect != nil, !busy else { return }
        guard !newScheme.isEmpty, newScheme != inspect?.suggestedScheme else { return }
        runInspect()
    }

    func runInspect() {
        let path = projectPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !busy else { return }
        let selectedScheme = scheme
        beginWork(clearLog: false, clearArtifact: false)
        let pipeline = self.pipeline
        pipeline.prepareForNewOperation()
        Task.detached {
            do {
                let result = try pipeline.inspect(projectPath: path, scheme: selectedScheme)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.inspect = result
                    self.scheme = result.suggestedScheme
                    self.profile = result.selectedProfile?.value ?? ""
                    self.busy = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.finish(error)
                }
            }
        }
    }

    func runExport(upload: Bool) {
        guard let ins = inspect, !busy else { return }
        if upload && !canUploadBuild {
            lastError = selectedProfileInfo?.isAppStore == false
                ? L10n.t("App Store Connect upload needs an App Store provisioning profile.", "上传到 App Store Connect 需要 App Store 描述文件。")
                : L10n.t("Save Key ID, Issuer ID and the .p8 key first.", "请先填写 Key ID、Issuer ID 并选择 .p8。")
            return
        }
        let request = ExportRequest(
            projectPath: projectPath,
            scheme: scheme,
            configuration: ins.configuration,
            teamId: ins.teamId,
            bundleId: ins.bundleId,
            profile: profile,
            profileKind: selectedProfileInfo?.kind ?? "",
            upload: upload,
            credentials: credentials
        )
        beginWork(clearLog: true, clearArtifact: true)
        let pipeline = self.pipeline
        let sink = makeSink()
        pipeline.prepareForNewOperation()
        Task.detached {
            do {
                let product = try pipeline.archiveAndExport(
                    project: request.projectPath,
                    scheme: request.scheme,
                    configuration: request.configuration,
                    teamId: request.teamId,
                    bundleId: request.bundleId,
                    profile: request.profile,
                    profileKind: request.profileKind,
                    onLog: sink.log,
                    onStage: sink.stage
                )
                await MainActor.run { [weak self] in
                    self?.artifact = product.ipaPath
                    self?.logFile = product.logPath
                }
                if request.upload {
                    try pipeline.upload(
                        ipa: product.ipaPath,
                        credentials: request.credentials,
                        logFile: URL(fileURLWithPath: product.logPath),
                        onLog: sink.log,
                        onStage: sink.stage
                    )
                } else {
                    sink.stage("", L10n.t("IPA exported.", "IPA 已导出。"))
                }
                await MainActor.run { [weak self] in
                    self?.busy = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.finish(error)
                }
            }
        }
    }

    func runUpload() {
        guard !artifact.isEmpty, !busy else { return }
        if !canUpload {
            lastError = L10n.t("Save Key ID, Issuer ID and the .p8 key first.", "请先填写 Key ID、Issuer ID 并选择 .p8。")
            return
        }
        let ipa = artifact
        let cred = credentials
        let existingLog = logFile
        beginWork(clearLog: false, clearArtifact: false)
        let pipeline = self.pipeline
        let sink = makeSink()
        pipeline.prepareForNewOperation()
        Task.detached {
            do {
                try pipeline.upload(
                    ipa: ipa,
                    credentials: cred,
                    logFile: existingLog.isEmpty ? nil : URL(fileURLWithPath: existingLog),
                    onLog: sink.log,
                    onStage: sink.stage
                )
                await MainActor.run { [weak self] in
                    self?.busy = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.finish(error)
                }
            }
        }
    }

    func cancel() {
        guard busy else { return }
        stage = L10n.t("Cancelling…", "正在取消…")
        pipeline.cancel()
    }

    func revealArtifact() {
        guard !artifact.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact)])
    }

    private func beginWork(clearLog: Bool, clearArtifact: Bool) {
        busy = true
        wasCancelled = false
        lastError = ""
        if clearLog { resetLog() }
        if clearArtifact {
            artifact = ""
            logFile = ""
        }
    }

    private func finish(_ error: Error) {
        busy = false
        if let build = error as? BuildError, build == .cancelled {
            wasCancelled = true
            lastError = ""
            stage = L10n.t("Cancelled.", "已取消。")
            return
        }
        wasCancelled = false
        lastError = LogDiagnostics.summarizeFailure(in: log) ?? error.localizedDescription
    }

    private func resetLog() {
        logLines.removeAll()
        log = ""
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
            log = logLines.joined(separator: "\n")
        } else if log.isEmpty {
            log = line
        } else {
            log += "\n" + line
        }
    }

    private func makeSink() -> EngineSink {
        EngineSink(
            log: { [self] line in
                DispatchQueue.main.async {
                    self.appendLog(line)
                }
            },
            stage: { [self] key, message in
                let text = key.isEmpty ? message : "\(key): \(message)"
                DispatchQueue.main.async {
                    self.stage = text
                }
            }
        )
    }
}

private struct ExportRequest: Sendable {
    var projectPath: String
    var scheme: String
    var configuration: String
    var teamId: String
    var bundleId: String
    var profile: String
    var profileKind: String
    var upload: Bool
    var credentials: Credentials
}

private struct EngineSink: @unchecked Sendable {
    var log: @Sendable (String) -> Void
    var stage: @Sendable (String, String) -> Void
}
