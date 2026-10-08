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
    @Published var artifactMetadata: ExportMetadata?
    @Published var logFile = ""
    @Published var marketingVersion = ""
    @Published var buildNumber = ""
    @Published var lastError = ""
    @Published var wasCancelled = false
    @Published var credentials = Credentials()

    nonisolated let pipeline: XcodePipeline
    private let creds = CredentialsStore()
    private var logLines: [String] = []
    static let maxLogLines = 4000

    var assessment: SigningAssessment {
        guard let ins = inspect else { return SigningAssessment() }
        return XcodePipeline.assess(inspect: ins, profileValue: profile, currentPath: projectPath)
    }
    var profileGroups: [ProfileGroup] {
        guard let ins = inspect else { return [] }
        return XcodePipeline.profileGroups(in: ins.profiles, configuration: ins.configuration)
    }
    var ready: Bool {
        guard assessment.ready, let products = inspect?.products, !products.isEmpty else { return false }
        return products.filter { !$0.isMain }.allSatisfy { !$0.profileName.isEmpty }
    }
    var canUpload: Bool { credentials.isComplete }
    var selectedProfileInfo: ProfileInfo? {
        inspect?.profiles.first { $0.value == profile }
    }
    var canUploadBuild: Bool { canUpload && artifactMetadata?.method == "app-store-connect" }
    var facts: String {
        guard let ins = inspect else { return "" }
        var parts: [String] = []
        if !ins.configuration.isEmpty { parts.append(ins.configuration) }
        if !ins.bundleId.isEmpty { parts.append("Bundle ID \(ins.bundleId)") }
        if !ins.teamId.isEmpty { parts.append("Team \(ins.teamId)") }
        if !ins.signingStyle.isEmpty { parts.append("\(L10n.t("Signing", "签名")): \(ins.signingStyle)") }
        if assessment.certificateFound {
            parts.append(assessment.identityName)
        } else if assessment.expectsDevelopment {
            parts.append(L10n.t("No matching Apple Development certificate", "没有匹配的 Apple Development 证书"))
        } else {
            parts.append(L10n.t("No matching Apple Distribution certificate", "没有匹配的 Apple Distribution 证书"))
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
        do {
            try creds.choosePrivateKey()
            credentials = creds.credentials
            lastError = ""
        } catch {
            credentials = creds.credentials
            lastError = error.localizedDescription
        }
    }

    func removePrivateKey() {
        guard !busy else { return }
        creds.credentials = credentials
        creds.removePrivateKey()
        credentials = creds.credentials
    }

    func chooseProject() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.t("Select an Xcode project or workspace", "选择 Xcode 工程或 workspace")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        let types = ["xcodeproj", "xcworkspace"].compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
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
        inspect = nil
        artifact = ""
        artifactMetadata = nil
        logFile = ""
        marketingVersion = ""
        buildNumber = ""
        beginWork(clearLog: false, clearArtifact: false)
        let pipeline = self.pipeline
        pipeline.prepareForNewOperation()
        Task.detached {
            do {
                let result = try pipeline.inspect(projectPath: path, scheme: selectedScheme)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.projectPath = result.projectPath
                    self.inspect = result
                    self.scheme = result.suggestedScheme
                    self.profile = result.selectedProfile?.value ?? ""
                    self.marketingVersion = result.marketingVersion
                    self.buildNumber = result.buildNumber
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
        let signing = assessment
        guard signing.ready else {
            lastError = signing.warnings.first ?? L10n.t("Inspect the project again before exporting.", "请重新识别工程后再导出。")
            return
        }
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
            signingIdentity: signing.identityName,
            products: ins.products,
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
                    signingIdentity: request.signingIdentity,
                    products: request.products,
                    onLog: sink.log,
                    onStage: sink.stage
                )
                let metadata = Self.readMetadata(at: product.metadataPath)
                await MainActor.run { [weak self] in
                    self?.artifact = product.ipaPath
                    self?.logFile = product.logPath
                    self?.artifactMetadata = metadata
                    if !product.version.isEmpty { self?.marketingVersion = product.version }
                    if !product.build.isEmpty { self?.buildNumber = product.build }
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
            artifactMetadata = nil
            logFile = ""
        }
    }

    func incrementBuildNumber() {
        guard let ins = inspect, !busy else { return }
        let current = buildNumber
        guard !current.isEmpty else { return }
        do {
            let next = try XcodePipeline.incrementBuildNumber(containerPath: ins.projectPath, current: current)
            buildNumber = next
            wasCancelled = false
            lastError = ""
            stage = L10n.t("Build number changed from \(current) to \(next).", "Build 号已从 \(current) 改为 \(next)。")
            appendLog(stage)
        } catch {
            lastError = error.localizedDescription
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
        if let conflict = LogDiagnostics.versionConflictMessage(in: log) {
            lastError = conflict
            return
        }
        lastError = LogDiagnostics.summarizeFailure(in: log) ?? error.localizedDescription
    }

    nonisolated private static func readMetadata(at path: String) -> ExportMetadata? {
        guard !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(ExportMetadata.self, from: data)
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
    var signingIdentity: String
    var products: [SignedProduct]
    var upload: Bool
    var credentials: Credentials
}

private struct EngineSink: @unchecked Sendable {
    var log: @Sendable (String) -> Void
    var stage: @Sendable (String, String) -> Void
}
