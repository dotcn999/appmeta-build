import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class BuildGate: ObservableObject {
    static let shared = BuildGate()
    @Published private(set) var owner: UUID?
    var isBusy: Bool { owner != nil }

    func begin(_ id: UUID) -> Bool {
        if let owner, owner != id { return false }
        self.owner = id
        return true
    }

    func end(_ id: UUID) {
        if owner == id { owner = nil }
    }
}

@MainActor
final class BuildEngine: ObservableObject {
    static weak var running: BuildEngine?
    let sessionID = UUID()

    @Published var projectPath = ""
    @Published var inspect: InspectResult?
    @Published var scheme = ""
    @Published var profile = ""
    @Published var log = ""
    @Published var stageKey = ""
    @Published var stageArgs: [String] = []
    @Published var failureKind = ""
    @Published var busy = false
    @Published var artifact = ""
    @Published var artifactMetadata: ExportMetadata?
    @Published var logFile = ""
    @Published var marketingVersion = ""
    @Published var buildNumber = ""
    @Published var lastError = ""
    @Published var wasCancelled = false

    nonisolated let pipeline: XcodePipeline
    private var logLines: [String] = []
    private var activity = ""
    static let maxLogLines = 4000

    var credentials: Credentials { CredentialsStore.shared.credentials }

    var stageText: String {
        switch stageKey {
        case "archive":
            let config = stageArgs.first ?? ""
            return L10n.t("Archiving \(config). This can take several minutes.", "正在 Archive \(config)，可能需要几分钟。")
        case "export":
            return L10n.t("Exporting a manually signed IPA.", "正在导出手动签名 IPA。")
        case "upload":
            return L10n.t("Uploading IPA to App Store Connect.", "正在上传 IPA 到 App Store Connect。")
        case "uploaded":
            return L10n.t(
                "Delivery succeeded. Apple still needs to process the build before it appears in App Store Connect.",
                "投递成功。Apple 还要处理构建，之后才会出现在 App Store Connect。"
            )
        case "exported":
            return L10n.t("IPA exported.", "IPA 已导出。")
        case "cancelling":
            return L10n.t("Cancelling…", "正在取消…")
        case "cancelled":
            return L10n.t("Cancelled.", "已取消。")
        case "build":
            let current = stageArgs.first ?? ""
            let next = stageArgs.dropFirst().first ?? ""
            return L10n.t("Build number changed from \(current) to \(next).", "Build 号已从 \(current) 改为 \(next)。")
        default:
            return ""
        }
    }

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
    }

    func choosePrivateKey() {
        guard !busy else { return }
        do {
            try CredentialsStore.shared.choosePrivateKey()
            lastError = ""
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removePrivateKey() {
        guard !busy else { return }
        CredentialsStore.shared.removePrivateKey()
    }

    func chooseProject() {
        guard !BuildGate.shared.isBusy else { return }
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
        guard inspect != nil, !BuildGate.shared.isBusy else { return }
        guard !newScheme.isEmpty, newScheme != inspect?.suggestedScheme else { return }
        runInspect()
    }

    func runInspect() {
        let path = projectPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !busy else { return }
        let selectedScheme = scheme
        guard beginWork(clearLog: false, clearArtifact: false, activity: "inspect") else { return }
        inspect = nil
        artifact = ""
        artifactMetadata = nil
        logFile = ""
        marketingVersion = ""
        buildNumber = ""
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
                    self.endWork()
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
            lastError = signing.warnings.first?.text ?? L10n.t("Inspect the project again before exporting.", "请重新识别工程后再导出。")
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
        guard beginWork(clearLog: true, clearArtifact: true, activity: "export") else { return }
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
                    sink.stage("exported", "")
                }
                await MainActor.run { [weak self] in
                    self?.endWork()
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
        guard beginWork(clearLog: false, clearArtifact: false, activity: "upload") else { return }
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
                    self?.endWork()
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
        stageKey = "cancelling"
        stageArgs = []
        pipeline.cancel()
    }

    func revealArtifact() {
        guard !artifact.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact)])
    }

    private func beginWork(clearLog: Bool, clearArtifact: Bool, activity: String) -> Bool {
        guard BuildGate.shared.begin(sessionID) else {
            lastError = L10n.t("Another window is already building.", "另一个窗口正在构建。")
            failureKind = ""
            return false
        }
        Self.running = self
        self.activity = activity
        busy = true
        wasCancelled = false
        lastError = ""
        failureKind = ""
        if clearLog { resetLog() }
        if clearArtifact {
            artifact = ""
            artifactMetadata = nil
            logFile = ""
        }
        return true
    }

    private func endWork() {
        busy = false
        BuildGate.shared.end(sessionID)
        if Self.running === self { Self.running = nil }
    }

    func incrementBuildNumber() {
        guard let ins = inspect, !BuildGate.shared.isBusy else { return }
        let current = buildNumber
        guard !current.isEmpty else { return }
        do {
            let next = try XcodePipeline.incrementBuildNumber(containerPath: ins.projectPath, current: current)
            buildNumber = next
            wasCancelled = false
            lastError = ""
            stageKey = "build"
            stageArgs = [current, next]
            appendLog(stageText)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func finish(_ error: Error) {
        let kind = activity
        endWork()
        if let build = error as? BuildError, build == .cancelled {
            wasCancelled = true
            lastError = ""
            failureKind = ""
            stageKey = "cancelled"
            stageArgs = []
            return
        }
        wasCancelled = false
        if !artifact.isEmpty {
            failureKind = "upload"
        } else if kind == "export" {
            failureKind = "archive"
        } else {
            failureKind = "failed"
        }
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
                DispatchQueue.main.async {
                    self.stageKey = key
                    self.stageArgs = message.isEmpty ? [] : [message]
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
