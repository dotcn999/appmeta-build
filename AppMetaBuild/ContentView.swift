import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var engine = BuildEngine()
    @ObservedObject private var credentialsStore = CredentialsStore.shared
    @ObservedObject private var builds = BuildGate.shared
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var pathCopied = false
    @State private var logCopied = false
    @State private var detailsExpanded = false
    @State private var successBounceToken = 0
    @State private var wasBusy = false

    var body: some View {
        HSplitView {
            leftPane
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
            logPane
                .frame(minWidth: 360)
        }
        .navigationTitle("AppMeta Build")
        .toolbar { toolbarItems }
        .onChange(of: credentialsStore.credentials) { _ in credentialsStore.save() }
        .onChange(of: engine.busy) { busy in
            if wasBusy && !busy && engine.lastError.isEmpty && !engine.wasCancelled {
                successBounceToken += 1
            }
            wasBusy = busy
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Picker(L10n.t("Language", "语言"), selection: $appearance.language) {
                Text(L10n.t("System", "系统")).tag(AppLanguage.system)
                Text("English").tag(AppLanguage.english)
                Text("中文").tag(AppLanguage.chinese)
            }
            .pickerStyle(.menu)
            .frame(minWidth: 88)

            Picker(L10n.t("Appearance", "外观"), selection: $appearance.colorMode) {
                Text(L10n.t("System", "系统")).tag(AppColorMode.system)
                Text(L10n.t("Light", "浅色")).tag(AppColorMode.light)
                Text(L10n.t("Dark", "深色")).tag(AppColorMode.dark)
            }
            .pickerStyle(.menu)
            .frame(minWidth: 88)
        }
    }

    private var leftPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stepRail
                credentialsCard
                projectCard
                if engine.inspect != nil {
                    inspectCard
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
                actionsCard
                statusCard
            }
            .padding(14)
            .animation(.easeOut(duration: 0.22), value: engine.inspect != nil)
        }
        .background(Theme.CanvasBackground(scheme: colorScheme))
    }

    // MARK: - Step rail

    private var stepRail: some View {
        HStack(spacing: 0) {
            ForEach(Array(pipelineSteps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Capsule()
                        .fill(step.completed || step.active ? Theme.accentSoft : Theme.railIdle(colorScheme))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 4)
                }
                stepNode(step)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(cardBackground)
    }

    private func stepNode(_ step: PipelineStep) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(stepFill(step))
                    .frame(width: 22, height: 22)
                if step.completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.id)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(step.active ? .white : Theme.secondaryLabel(colorScheme))
                }
            }
            Text(step.title)
                .font(.system(size: 10, weight: step.active ? .semibold : .medium))
                .foregroundStyle(step.active || step.completed ? Theme.label(colorScheme) : Theme.secondaryLabel(colorScheme))
                .lineLimit(1)
        }
        .frame(minWidth: 52)
    }

    private func stepFill(_ step: PipelineStep) -> Color {
        if step.completed { return Theme.success }
        if step.active { return Theme.accent }
        return Theme.railIdle(colorScheme)
    }

    private var pipelineSteps: [PipelineStep] {
        let keyDone = engine.canUpload
        let projectDone = engine.inspect != nil
        let signingDone = engine.ready
        let buildDone = !engine.artifact.isEmpty && !engine.busy

        let current: Int
        if engine.busy || buildDone {
            current = 4
        } else if !keyDone {
            current = 1
        } else if !projectDone {
            current = 2
        } else if !signingDone {
            current = 3
        } else {
            current = 4
        }

        return [
            PipelineStep(id: 1, title: "API", completed: keyDone, active: current == 1),
            PipelineStep(id: 2, title: L10n.t("Project", "工程"), completed: projectDone, active: current == 2),
            PipelineStep(id: 3, title: L10n.t("Signing", "签名"), completed: signingDone, active: current == 3),
            PipelineStep(id: 4, title: L10n.t("Build", "构建"), completed: buildDone, active: current == 4),
        ]
    }

    // MARK: - Cards

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.t("API Key", "API Key"),
                         subtitle: L10n.t("Stored only on this Mac.", "仅保存在这台 Mac 上。"))
            labeledField("Key ID", text: $credentialsStore.credentials.keyId)
                .disabled(engine.busy)
            labeledField("Issuer ID", text: $credentialsStore.credentials.issuerId)
                .disabled(engine.busy)
            if !credentialsStore.credentials.keyId.isEmpty && !Credentials.isValidKeyID(credentialsStore.credentials.keyId) {
                Text(L10n.t("Key ID must be 10 letters or digits.", "Key ID 必须是 10 位字母或数字。"))
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            if !credentialsStore.credentials.issuerId.isEmpty && !Credentials.isValidIssuerID(credentialsStore.credentials.issuerId) {
                Text(L10n.t("Issuer ID must be a UUID.", "Issuer ID 必须是 UUID。"))
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            HStack(spacing: 8) {
                if credentialsStore.credentials.hasPrivateKey {
                    keyChip
                    Button(L10n.t("Remove", "移除")) { engine.removePrivateKey() }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .disabled(engine.busy)
                } else {
                    Button {
                        engine.choosePrivateKey()
                    } label: {
                        Label(L10n.t("Choose .p8", "选择 .p8"), systemImage: "key.fill")
                    }
                    .buttonStyle(SecondaryActionStyle())
                    .disabled(engine.busy)
                }
                Spacer()
                statusDot(ok: engine.canUpload,
                          okText: L10n.t("Key ready", "密钥已就绪"),
                          badText: L10n.t("Key incomplete", "密钥未配齐"))
            }
            Text(credentialsStore.credentials.hasPrivateKey
                 ? L10n.t("Private key is in the login keychain.", "私钥已保存在登录钥匙串。")
                 : L10n.t("No private key saved.", "尚未保存私钥。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .background(cardBackground)
    }

    private var keyChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Theme.success)
                .font(.caption)
            Text(credentialsStore.credentials.keyId.isEmpty
                 ? L10n.t(".p8 in Keychain", ".p8 已在钥匙串")
                 : "AuthKey_\(credentialsStore.credentials.keyId)")
                .font(.caption.weight(.medium).monospaced())
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.success.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.t("Xcode project", "Xcode 工程"),
                         subtitle: L10n.t("Select a .xcodeproj, then inspect.", "选择 .xcodeproj，然后识别。"))
            HStack(spacing: 8) {
                TextField(L10n.t("Project path", "工程路径"), text: $engine.projectPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.fieldFill(colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.fieldStroke(colorScheme), lineWidth: 1)
                    )
                    .disabled(builds.isBusy)
                Button {
                    engine.chooseProject()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SecondaryActionStyle(compact: true))
                .disabled(builds.isBusy)
                .help(L10n.t("Choose…", "选择…"))
            }
            HStack {
                Button {
                    engine.runInspect()
                } label: {
                    Label(L10n.t("Inspect", "识别工程"), systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryActionStyle(compact: true))
                .disabled(engine.projectPath.isEmpty || builds.isBusy)
                Spacer()
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var inspectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.t("Signing", "签名"),
                         subtitle: L10n.t(
                            "Bundle ID follows the selected scheme. ★ is set in Xcode.",
                            "Bundle ID 随所选 Scheme 变化。★ 表示工程里已指定。"
                         ))
            if let ins = engine.inspect {
                labeledPicker(L10n.t("Scheme", "Scheme"), selection: $engine.scheme, options: ins.schemes)
                    .disabled(builds.isBusy)
                    .onChange(of: engine.scheme) { engine.handleSchemeChange($0) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Profile", "描述文件"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(L10n.t("Profile", "描述文件"), selection: $engine.profile) {
                        if ins.profiles.isEmpty {
                            Text(L10n.t("No matching profile on this Mac", "本机没有匹配的描述文件")).tag("")
                        }
                        ForEach(engine.profileGroups) { group in
                            Section(group.title) {
                                ForEach(group.profiles) { profile in
                                    Text(profile.displayName).tag(profile.value)
                                        .disabled(!profile.selectable)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .disabled(engine.busy)
                }

                signingChips(ins)

                DisclosureGroup(isExpanded: $detailsExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        factRow(L10n.t("Configuration", "配置"), ins.configuration)
                        if !ins.products.isEmpty {
                            ForEach(ins.products) { product in
                                factRow(
                                    product.isMain ? L10n.t("App", "主 App") : product.target,
                                    product.profileName.isEmpty
                                        ? product.bundleId
                                        : "\(product.bundleId) · \(product.profileName)"
                                )
                            }
                        } else {
                            factRow(L10n.t("Bundle ID", "Bundle ID"), ins.bundleId)
                        }
                        if !engine.marketingVersion.isEmpty || !engine.buildNumber.isEmpty {
                            factRow(L10n.t("Version", "版本"), "\(engine.marketingVersion) (\(engine.buildNumber))")
                        }
                        factRow("Team", ins.teamId)
                        factRow(L10n.t("Style", "方式"), ins.signingStyle)
                        certRow
                    }
                    .padding(.top, 6)
                } label: {
                    Text(L10n.t("Details", "详细信息"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if !engine.assessment.warnings.isEmpty {
                    ForEach(engine.assessment.warnings, id: \.self) { notice in
                        Label(notice.text, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private func signingChips(_ ins: InspectResult) -> some View {
        let signing = engine.assessment
        let certOK = signing.certificateFound
        let certLabel: String = {
            if certOK { return signing.identityName }
            return signing.expectsDevelopment
                ? L10n.t("No Dev cert", "无 Development 证书")
                : L10n.t("No Dist cert", "无 Distribution 证书")
        }()
        let versionLabel: String = {
            if engine.marketingVersion.isEmpty && engine.buildNumber.isEmpty { return "—" }
            return "\(engine.marketingVersion.isEmpty ? "—" : engine.marketingVersion) (\(engine.buildNumber.isEmpty ? "—" : engine.buildNumber))"
        }()

        return FlowChips(items: [
            ChipItem(title: L10n.t("Config", "配置"), value: ins.configuration.isEmpty ? "—" : ins.configuration),
            ChipItem(title: "Team", value: ins.teamId.isEmpty ? "—" : ins.teamId),
            ChipItem(title: L10n.t("Version", "版本"), value: versionLabel),
            ChipItem(title: L10n.t("Cert", "证书"), value: certLabel, tone: certOK ? .success : .warning),
        ])
    }

    private var certRow: some View {
        let signing = engine.assessment
        let found = signing.certificateFound
        let label: String
        if found {
            label = signing.identityName
        } else if signing.expectsDevelopment {
            label = L10n.t("No matching Apple Development certificate", "没有匹配的 Apple Development 证书")
        } else {
            label = L10n.t("No matching Apple Distribution certificate", "没有匹配的 Apple Distribution 证书")
        }
        return HStack(alignment: .firstTextBaseline) {
            Text(L10n.t("Certificate", "证书"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(label)
                .font(.caption)
                .foregroundStyle(found ? Theme.success : Theme.warning)
        }
    }

    // MARK: - Actions

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                engine.runExport(upload: true)
            } label: {
                HStack(spacing: 8) {
                    if engine.busy && (engine.stageKey == "archive" || engine.stageKey == "export" || engine.stageKey == "upload") {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    }
                    Text(primaryCTATitle)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(!engine.ready || !engine.canUploadBuild || builds.isBusy)

            HStack(spacing: 16) {
                Button(L10n.t("Export IPA", "导出 IPA")) {
                    engine.runExport(upload: false)
                }
                .buttonStyle(GhostLinkStyle())
                .disabled(!engine.ready || builds.isBusy)

                Button(L10n.t("Upload IPA", "上传 IPA")) {
                    engine.runUpload()
                }
                .buttonStyle(GhostLinkStyle())
                .disabled(engine.artifact.isEmpty || !engine.canUploadBuild || builds.isBusy)

                Spacer()

                if engine.busy {
                    Button(role: .destructive) {
                        engine.cancel()
                    } label: {
                        Label(L10n.t("Cancel", "取消"), systemImage: "xmark.circle.fill")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(GhostLinkStyle(tone: .danger))
                }

                Menu {
                    Button {
                        engine.incrementBuildNumber()
                    } label: {
                        Label(L10n.t("Build +1", "Build 号 +1"), systemImage: "plus.circle")
                    }
                    .disabled(builds.isBusy || engine.inspect == nil || Int(engine.buildNumber) == nil)

                    Button {
                        engine.revealArtifact()
                    } label: {
                        Label(L10n.t("Show in Finder", "在 Finder 中显示"), systemImage: "folder")
                    }
                    .disabled(engine.artifact.isEmpty)

                    if !engine.artifact.isEmpty {
                        Button {
                            copyArtifactPath()
                        } label: {
                            Label(L10n.t("Copy path", "复制路径"), systemImage: "doc.on.doc")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(L10n.t("More actions", "更多操作"))
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var primaryCTATitle: String {
        if engine.busy {
            switch engine.stageKey {
            case "archive": return L10n.t("Archiving…", "正在 Archive…")
            case "export": return L10n.t("Exporting…", "正在导出…")
            case "upload": return L10n.t("Uploading…", "正在上传…")
            case "cancelling": return L10n.t("Cancelling…", "正在取消…")
            default: return L10n.t("Working…", "进行中…")
            }
        }
        return L10n.t("Archive, export & upload", "Archive、导出并上传")
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BreathingStatusDot(
                    color: statusColor,
                    isBreathing: engine.busy,
                    bounceToken: successBounceToken
                )
                Text(statusTitle)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.22), value: engine.stageKey)
                    .animation(.easeInOut(duration: 0.22), value: engine.busy)
                Spacer()
            }

            if let progress = stageProgressModel {
                StageProgressBar(model: progress)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !engine.artifact.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text(engine.artifact)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        copyArtifactPath()
                    } label: {
                        Text(pathCopied
                             ? L10n.t("Copied", "已复制")
                             : L10n.t("Copy", "复制"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !engine.lastError.isEmpty {
                Text(engine.lastError)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(cardBackground)
        .animation(.easeOut(duration: 0.25), value: stageProgressModel?.currentIndex)
        .animation(.easeOut(duration: 0.25), value: stageProgressVisible)
    }

    private var stageProgressVisible: Bool {
        stageProgressModel != nil
    }

    private var stageProgressModel: StageProgressModel? {
        let labels: [String]
        switch engine.activity {
        case "exportUpload":
            labels = [
                L10n.t("Archive", "Archive"),
                L10n.t("Export", "导出"),
                L10n.t("Upload", "上传"),
            ]
        case "export":
            labels = [
                L10n.t("Archive", "Archive"),
                L10n.t("Export", "导出"),
            ]
        case "upload":
            labels = [L10n.t("Upload", "上传")]
        default:
            return nil
        }

        let key = engine.stageKey
        let pipelineKeys: Set<String> = [
            "archive", "export", "upload", "exported", "uploaded", "cancelling", "cancelled",
        ]
        guard engine.busy || pipelineKeys.contains(key) else { return nil }

        let currentIndex: Int
        let isComplete: Bool
        switch key {
        case "archive":
            currentIndex = 0
            isComplete = false
        case "export":
            currentIndex = min(1, labels.count - 1)
            isComplete = false
        case "upload", "cancelling":
            currentIndex = labels.count - 1
            isComplete = false
        case "exported", "uploaded":
            currentIndex = labels.count - 1
            isComplete = true
        case "cancelled":
            currentIndex = cancelledStageIndex(labelCount: labels.count)
            isComplete = false
        default:
            guard engine.busy else { return nil }
            currentIndex = 0
            isComplete = false
        }

        let failed = !engine.lastError.isEmpty || engine.wasCancelled
        return StageProgressModel(
            labels: labels,
            currentIndex: currentIndex,
            isComplete: isComplete && !failed,
            isFailed: failed,
            isActive: engine.busy
        )
    }

    private func cancelledStageIndex(labelCount: Int) -> Int {
        // activity is still set after cancel; stageKey is "cancelled" — use last known pipeline depth.
        switch engine.activity {
        case "upload": return labelCount - 1
        case "exportUpload": return labelCount - 1
        default: return min(1, labelCount - 1)
        }
    }

    private func copyArtifactPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.artifact, forType: .string)
        pathCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            pathCopied = false
        }
    }

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.t("Log", "日志"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Console.headerLabel)
                    .textCase(.uppercase)
                    .tracking(0.6)

                if let badge = logStageBadge {
                    Text(badge.title)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badge.color.opacity(0.18), in: Capsule())
                        .overlay(Capsule().strokeBorder(badge.color.opacity(0.35), lineWidth: 1))
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(engine.log, forType: .string)
                    logCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        logCopied = false
                    }
                } label: {
                    Label(
                        logCopied ? L10n.t("Copied", "已复制") : L10n.t("Copy", "复制"),
                        systemImage: logCopied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(logCopied ? Theme.success : Theme.Console.headerLabel)
                }
                .buttonStyle(.plain)
                .disabled(engine.log.isEmpty)
                .opacity(engine.log.isEmpty ? 0.35 : 1)
                .help(L10n.t("Copy log", "复制日志"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.Console.header)
            .animation(.easeOut(duration: 0.2), value: engine.stageKey)
            .animation(.easeOut(duration: 0.2), value: engine.busy)

            Rectangle()
                .fill(Theme.Console.divider)
                .frame(height: 1)

            LogTextView(
                text: engine.log,
                placeholder: L10n.t("Build log appears here.", "构建日志会显示在这里。")
            )
        }
        .background(Theme.Console.background)
    }

    private var logStageBadge: (title: String, color: Color)? {
        if engine.busy {
            switch engine.stageKey {
            case "archive":
                return (L10n.t("ARCHIVE", "ARCHIVE"), Theme.Console.archive)
            case "export":
                return (L10n.t("EXPORT", "EXPORT"), Theme.Console.export)
            case "upload":
                return (L10n.t("UPLOAD", "UPLOAD"), Theme.Console.upload)
            case "cancelling":
                return (L10n.t("CANCEL", "取消中"), Theme.warning)
            case "inspect":
                return (L10n.t("INSPECT", "识别中"), Theme.accent)
            default:
                if engine.activity == "inspect" {
                    return (L10n.t("INSPECT", "识别中"), Theme.accent)
                }
                return (L10n.t("RUNNING", "进行中"), Theme.accent)
            }
        }
        if engine.wasCancelled {
            return (L10n.t("CANCELLED", "已取消"), Theme.warning)
        }
        if !engine.lastError.isEmpty {
            return (L10n.t("FAILED", "失败"), Theme.Console.error)
        }
        switch engine.stageKey {
        case "uploaded":
            return (L10n.t("UPLOADED", "已上传"), Theme.success)
        case "exported":
            return (L10n.t("EXPORTED", "已导出"), Theme.success)
        default:
            return nil
        }
    }

    // MARK: - Shared chrome

    private var cardBackground: some View {
        Theme.CardChrome(scheme: colorScheme, cornerRadius: 12)
    }

    private var statusColor: Color {
        if engine.wasCancelled && !engine.busy { return Theme.warning }
        if !engine.lastError.isEmpty { return Theme.danger }
        if engine.busy { return Theme.accent }
        if engine.ready { return Theme.success }
        return Theme.secondaryLabel(colorScheme)
    }

    private var statusTitle: String {
        if engine.busy { return engine.stageText.isEmpty ? L10n.t("Working…", "进行中…") : engine.stageText }
        if engine.wasCancelled { return L10n.t("Cancelled.", "已取消。") }
        if !engine.lastError.isEmpty {
            if engine.failureKind == "upload" {
                return L10n.t("IPA is ready, but upload failed", "IPA 已就绪，上传失败")
            }
            if engine.failureKind == "archive" {
                return L10n.t("Archive failed", "Archive 失败")
            }
            return L10n.t("Failed", "失败")
        }
        if !engine.artifact.isEmpty { return engine.stageText.isEmpty ? L10n.t("IPA ready", "IPA 已就绪") : engine.stageText }
        if engine.ready { return L10n.t("Ready to archive", "可以开始 Archive") }
        return L10n.t("Idle", "空闲")
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func labeledField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.fieldFill(colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.fieldStroke(colorScheme), lineWidth: 1)
                )
        }
    }

    private func labeledPicker(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        }
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private struct LogTextView: NSViewRepresentable {
        var text: String
        var placeholder: String

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSTextView.scrollableTextView()
            guard let textView = scroll.documentView as? NSTextView else { return scroll }
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = true
            textView.usesFontPanel = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textContainerInset = NSSize(width: 10, height: 10)
            textView.drawsBackground = true
            textView.backgroundColor = NSColor(Theme.Console.background)
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.drawsBackground = true
            scroll.backgroundColor = NSColor(Theme.Console.background)
            scroll.borderType = .noBorder
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let textView = scroll.documentView as? NSTextView else { return }
            let isPlaceholder = text.isEmpty
            let shown = isPlaceholder ? placeholder : text
            if context.coordinator.lastText == shown { return }

            let clip = scroll.contentView
            let atBottom = context.coordinator.stickToBottom
                || clip.bounds.maxY >= max(textView.bounds.height - 32, 0)

            let attributed: NSAttributedString
            if isPlaceholder {
                attributed = NSAttributedString(
                    string: shown,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: NSColor(Theme.Console.placeholder),
                    ]
                )
            } else {
                attributed = LogConsoleColorizer.colorize(shown)
            }

            textView.textStorage?.setAttributedString(attributed)
            context.coordinator.lastText = shown

            if atBottom {
                textView.scrollToEndOfDocument(nil)
            }
            context.coordinator.stickToBottom = atBottom || isPlaceholder
        }

        final class Coordinator {
            var stickToBottom = true
            var lastText = ""
        }
    }

    private func statusDot(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Theme.success : Theme.warning).frame(width: 7, height: 7)
            Text(ok ? okText : badText).font(.caption).foregroundStyle(Theme.secondaryLabel(colorScheme))
        }
    }
}

// MARK: - Theme & components

private enum Theme {
    /// Brand primary — cool deep blue (shared with app tint).
    static let accent = Color(red: 0.11, green: 0.39, blue: 0.86)
    static let accentPressed = Color(red: 0.08, green: 0.32, blue: 0.74)
    static let accentSoft = Color(red: 0.11, green: 0.39, blue: 0.86).opacity(0.45)
    static let success = Color(red: 0.10, green: 0.60, blue: 0.44)
    static let warning = Color(red: 0.92, green: 0.55, blue: 0.12)
    static let danger = Color(red: 0.86, green: 0.28, blue: 0.30)

    enum Console {
        static let background = Color(red: 0.08, green: 0.09, blue: 0.12)
        static let header = Color(red: 0.10, green: 0.11, blue: 0.15)
        static let divider = Color.white.opacity(0.07)
        static let headerLabel = Color(red: 0.68, green: 0.73, blue: 0.82)
        static let body = Color(red: 0.76, green: 0.81, blue: 0.88)
        static let placeholder = Color(red: 0.40, green: 0.45, blue: 0.54)
        static let archive = Color(red: 0.42, green: 0.70, blue: 1.0)
        static let export = Color(red: 0.42, green: 0.82, blue: 0.70)
        static let upload = Color(red: 0.72, green: 0.60, blue: 1.0)
        static let error = Color(red: 1.0, green: 0.48, blue: 0.50)
        static let warning = Color(red: 1.0, green: 0.72, blue: 0.38)
        static let meta = Color(red: 0.48, green: 0.54, blue: 0.64)
    }

    struct CanvasBackground: View {
        let scheme: ColorScheme

        var body: some View {
            LinearGradient(
                colors: scheme == .dark
                    ? [
                        Color(red: 0.10, green: 0.11, blue: 0.14),
                        Color(red: 0.09, green: 0.10, blue: 0.13),
                        Color(red: 0.08, green: 0.10, blue: 0.14),
                    ]
                    : [
                        Color(red: 0.935, green: 0.948, blue: 0.972),
                        Color(red: 0.920, green: 0.935, blue: 0.962),
                        Color(red: 0.910, green: 0.928, blue: 0.958),
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topTrailing) {
                // Soft brand wash — keeps the pane from reading as flat system gray.
                RadialGradient(
                    colors: [
                        accent.opacity(scheme == .dark ? 0.10 : 0.07),
                        .clear,
                    ],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 280
                )
                .allowsHitTesting(false)
            }
        }
    }

    struct CardChrome: View {
        let scheme: ColorScheme
        var cornerRadius: CGFloat = 12

        var body: some View {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(card(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(cardStroke(scheme), lineWidth: 1)
                )
                .shadow(
                    color: scheme == .dark
                        ? Color.black.opacity(0.35)
                        : Color(red: 0.20, green: 0.28, blue: 0.42).opacity(0.07),
                    radius: scheme == .dark ? 8 : 10,
                    y: scheme == .dark ? 2 : 3
                )
        }

        private func cardStroke(_ scheme: ColorScheme) -> some ShapeStyle {
            if scheme == .dark {
                return AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.14),
                            Color.white.opacity(0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.95),
                        Color(red: 0.75, green: 0.80, blue: 0.90).opacity(0.55),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.15, green: 0.16, blue: 0.20)
            : Color.white.opacity(0.92)
    }

    static func stroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color(red: 0.55, green: 0.62, blue: 0.75).opacity(0.28)
    }

    static func fieldFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.055)
            : Color(red: 0.965, green: 0.972, blue: 0.985)
    }

    static func fieldStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color(red: 0.55, green: 0.62, blue: 0.75).opacity(0.32)
    }

    static func railIdle(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color(red: 0.55, green: 0.62, blue: 0.75).opacity(0.35)
    }

    static func label(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.95, green: 0.96, blue: 0.98) : Color(red: 0.12, green: 0.15, blue: 0.22)
    }

    static func secondaryLabel(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.62, green: 0.66, blue: 0.74)
            : Color(red: 0.40, green: 0.45, blue: 0.54)
    }

    static func disabledFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color(red: 0.78, green: 0.81, blue: 0.86)
    }

    static func disabledLabel(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.38)
            : Color(red: 0.52, green: 0.55, blue: 0.60)
    }
}

private struct PipelineStep: Identifiable {
    let id: Int
    let title: String
    let completed: Bool
    let active: Bool
}

private enum ChipTone {
    case neutral, success, warning
}

private struct ChipItem: Identifiable {
    var id: String { title }
    let title: String
    let value: String
    var tone: ChipTone = .neutral
}

private struct FlowChips: View {
    let items: [ChipItem]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // LazyVGrid keeps chip layout predictable in the narrow left pane.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(item.value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(valueColor(item.tone))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(chipFill(item.tone), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func valueColor(_ tone: ChipTone) -> Color {
        switch tone {
        case .neutral: return Theme.label(colorScheme)
        case .success: return Theme.success
        case .warning: return Theme.warning
        }
    }

    private func chipFill(_ tone: ChipTone) -> Color {
        switch tone {
        case .neutral:
            return colorScheme == .dark ? Color.white.opacity(0.06) : Theme.accent.opacity(0.05)
        case .success:
            return Theme.success.opacity(colorScheme == .dark ? 0.18 : 0.1)
        case .warning:
            return Theme.warning.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }
    }
}

private enum LogConsoleColorizer {
    static func colorize(_ text: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let string = String(line)
            let color = color(for: string)
            result.append(NSAttributedString(string: string, attributes: [
                .font: font,
                .foregroundColor: NSColor(color),
            ]))
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: font,
                    .foregroundColor: NSColor(Theme.Console.body),
                ]))
            }
        }
        return result
    }

    private static func color(for line: String) -> Color {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        if trimmed.isEmpty { return Theme.Console.meta }

        if lower.contains("error:")
            || lower.contains("error ")
            || lower.hasPrefix("error")
            || lower.contains("failed")
            || lower.contains("itms-")
            || lower.contains("archive failed")
            || lower.contains("export failed")
            || lower.contains("✗")
        {
            return Theme.Console.error
        }

        if lower.contains("warning:")
            || lower.hasPrefix("warning")
            || lower.contains("note:")
        {
            return Theme.Console.warning
        }

        if lower.contains("succeeded")
            || lower.contains("uploaded")
            || lower.contains("exported")
            || lower.contains("delivery succeeded")
            || lower.contains("投递成功")
            || lower.contains("已导出")
            || lower.contains("✔")
        {
            return Theme.success
        }

        if lower.contains("itmstransporter")
            || lower.contains("altool")
            || lower.contains("upload")
            || lower.contains("正在上传")
            || lower.contains("app store connect")
        {
            return Theme.Console.upload
        }

        if lower.contains("xcodebuild")
            || lower.contains("archive")
            || lower.contains("正在 archive")
            || lower.contains("archiving")
        {
            return Theme.Console.archive
        }

        if lower.contains("export")
            || lower.contains("正在导出")
            || lower.contains("exporting")
            || lower.contains(".ipa")
        {
            return Theme.Console.export
        }

        if lower.hasPrefix("===") || lower.hasPrefix("---") || lower.hasPrefix("**") {
            return Theme.Console.meta
        }

        return Theme.Console.body
    }
}

private struct StageProgressModel: Equatable {
    var labels: [String]
    var currentIndex: Int
    var isComplete: Bool
    var isFailed: Bool
    var isActive: Bool
}

private struct StageProgressBar: View {
    let model: StageProgressModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(model.labels.enumerated()), id: \.offset) { index, _ in
                    Capsule()
                        .fill(segmentFill(index))
                        .frame(height: 4)
                        .frame(maxWidth: .infinity)
                        .opacity(segmentOpacity(index))
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(model.labels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.system(size: 10, weight: index == model.currentIndex && model.isActive ? .semibold : .medium))
                        .foregroundStyle(labelColor(index))
                        .frame(maxWidth: .infinity, alignment: alignment(for: index, total: model.labels.count))
                }
            }
        }
        .onAppear { syncPulse() }
        .onChange(of: model.isActive) { _ in syncPulse() }
        .onChange(of: model.currentIndex) { _ in syncPulse() }
    }

    private func syncPulse() {
        if model.isActive && !model.isComplete && !model.isFailed {
            pulse = false
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                pulse = false
            }
        }
    }

    private func segmentFill(_ index: Int) -> Color {
        if model.isFailed && index <= model.currentIndex {
            return index == model.currentIndex ? Theme.warning : Theme.accentSoft
        }
        if model.isComplete || index < model.currentIndex {
            return Theme.success
        }
        if index == model.currentIndex {
            return model.isActive ? Theme.accent : Theme.success
        }
        return Theme.railIdle(colorScheme)
    }

    private func segmentOpacity(_ index: Int) -> Double {
        guard model.isActive, index == model.currentIndex, !model.isComplete, !model.isFailed else { return 1 }
        return pulse ? 1 : 0.42
    }

    private func labelColor(_ index: Int) -> Color {
        if model.isComplete || index < model.currentIndex { return Theme.success }
        if index == model.currentIndex {
            if model.isFailed { return Theme.warning }
            return Theme.label(colorScheme)
        }
        return Theme.secondaryLabel(colorScheme)
    }

    private func alignment(for index: Int, total: Int) -> Alignment {
        if total == 1 { return .leading }
        if index == 0 { return .leading }
        if index == total - 1 { return .trailing }
        return .center
    }
}

private struct BreathingStatusDot: View {
    let color: Color
    let isBreathing: Bool
    let bounceToken: Int

    @State private var pulse = false
    @State private var bounceScale: CGFloat = 1

    var body: some View {
        ZStack {
            if isBreathing {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 0.7)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .scaleEffect(bounceScale)
        }
        .frame(width: 14, height: 14)
        .onAppear { syncPulse() }
        .onChange(of: isBreathing) { _ in syncPulse() }
        .onChange(of: bounceToken) { _ in
            guard bounceToken > 0 else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) {
                bounceScale = 1.65
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                    bounceScale = 1
                }
            }
        }
    }

    private func syncPulse() {
        if isBreathing {
            pulse = false
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                pulse = false
            }
        }
    }
}

private struct PrimaryActionStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = {
            if !isEnabled { return Theme.disabledFill(colorScheme) }
            return configuration.isPressed ? Theme.accentPressed : Theme.accent
        }()
        return configuration.label
            .font(compact ? .callout.weight(.semibold) : .body.weight(.semibold))
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 7 : 10)
            .foregroundStyle(isEnabled ? Color.white : Theme.disabledLabel(colorScheme))
            .background(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(fill)
            )
    }
}

private struct SecondaryActionStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .body.weight(.medium) : .callout.weight(.medium))
            .padding(.horizontal, compact ? 0 : 12)
            .padding(.vertical, compact ? 0 : 7)
            .foregroundStyle(isEnabled ? Theme.label(colorScheme) : Theme.disabledLabel(colorScheme))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.fieldFill(colorScheme).opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.fieldStroke(colorScheme), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.85)
    }
}

private enum GhostLinkTone {
    case accent, danger
}

private struct GhostLinkStyle: ButtonStyle {
    var tone: GhostLinkTone = .accent
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let base: Color = {
            switch tone {
            case .accent: return Theme.accent
            case .danger: return Theme.danger
            }
        }()
        return configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? base : Theme.disabledLabel(colorScheme))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
