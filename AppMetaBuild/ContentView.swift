import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var engine = BuildEngine()
    @ObservedObject private var credentialsStore = CredentialsStore.shared
    @ObservedObject private var builds = BuildGate.shared
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        HSplitView {
            leftPane
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            logPane
                .frame(minWidth: 360)
        }
        .navigationTitle("AppMeta Build")
        .toolbar { toolbarItems }
        .onChange(of: credentialsStore.credentials) { _ in credentialsStore.save() }
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
            VStack(alignment: .leading, spacing: 16) {
                credentialsCard
                projectCard
                if engine.inspect != nil {
                    inspectCard
                }
                actionsCard
                statusCard
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t("API Key", "API Key"),
                         subtitle: L10n.t("Stored only on this Mac.", "仅保存在这台 Mac 上。"))
            labeledField("Key ID", text: $credentialsStore.credentials.keyId)
                .disabled(engine.busy)
            labeledField("Issuer ID", text: $credentialsStore.credentials.issuerId)
                .disabled(engine.busy)
            if !credentialsStore.credentials.keyId.isEmpty && !Credentials.isValidKeyID(credentialsStore.credentials.keyId) {
                Text(L10n.t("Key ID must be 10 letters or digits.", "Key ID 必须是 10 位字母或数字。"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !credentialsStore.credentials.issuerId.isEmpty && !Credentials.isValidIssuerID(credentialsStore.credentials.issuerId) {
                Text(L10n.t("Issuer ID must be a UUID.", "Issuer ID 必须是 UUID。"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button(L10n.t("Choose .p8", "选择 .p8")) { engine.choosePrivateKey() }
                    .disabled(engine.busy)
                Button(L10n.t("Remove key", "移除密钥")) { engine.removePrivateKey() }
                    .disabled(engine.busy || !credentialsStore.credentials.hasPrivateKey)
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
        .padding(12)
        .background(cardBackground)
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t("Xcode project", "Xcode 工程"),
                         subtitle: L10n.t("Select a .xcodeproj, then inspect.", "选择 .xcodeproj，然后识别。"))
            TextField(L10n.t("Project path", "工程路径"), text: $engine.projectPath)
                .textFieldStyle(.roundedBorder)
                .disabled(builds.isBusy)
            HStack {
                Button(L10n.t("Choose…", "选择…")) { engine.chooseProject() }
                    .disabled(builds.isBusy)
                Button(L10n.t("Inspect", "识别工程")) { engine.runInspect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.projectPath.isEmpty || builds.isBusy)
                Spacer()
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    private var inspectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t("Signing", "签名"),
                         subtitle: L10n.t("Bundle ID follows the selected scheme. Profiles are installed on this Mac. ★ is set in Xcode.", "Bundle ID 随所选 Scheme 变化。描述文件来自本机已安装的 Provisioning Profile。★ 表示工程里已指定。"))
            if let ins = engine.inspect {
                labeledPicker(L10n.t("Scheme", "Scheme"), selection: $engine.scheme, options: ins.schemes)
                    .disabled(builds.isBusy)
                    .onChange(of: engine.scheme) { engine.handleSchemeChange($0) }
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
                if !engine.assessment.warnings.isEmpty {
                    ForEach(engine.assessment.warnings, id: \.self) { notice in
                        Label(notice.text, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .background(cardBackground)
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
                .foregroundStyle(found ? Color.green : Color.orange)
        }
    }

    private var actionsCard: some View {
        VStack(spacing: 10) {
            Button {
                engine.runExport(upload: true)
            } label: {
                Text(L10n.t("Archive, export & upload", "Archive、导出并上传"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!engine.ready || !engine.canUploadBuild || builds.isBusy)

            HStack(spacing: 8) {
                actionGridButton(L10n.t("Export IPA", "导出 IPA"), disabled: !engine.ready || builds.isBusy) {
                    engine.runExport(upload: false)
                }
                actionGridButton(L10n.t("Upload IPA", "上传 IPA"), disabled: engine.artifact.isEmpty || !engine.canUploadBuild || builds.isBusy) {
                    engine.runUpload()
                }
            }
            HStack(spacing: 8) {
                actionGridButton(
                    L10n.t("Build +1", "Build 号 +1"),
                    disabled: builds.isBusy || engine.inspect == nil || Int(engine.buildNumber) == nil
                ) {
                    engine.incrementBuildNumber()
                }
                actionGridButton(L10n.t("Cancel", "取消"), role: .destructive, disabled: !engine.busy) {
                    engine.cancel()
                }
                actionGridButton(L10n.t("Show in Finder", "在 Finder 中显示"), disabled: engine.artifact.isEmpty) {
                    engine.revealArtifact()
                }
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    private func actionGridButton(
        _ title: String,
        role: ButtonRole? = nil,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(disabled)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusTitle)
                    .font(.subheadline.weight(.semibold))
                if engine.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if !engine.artifact.isEmpty {
                Text(engine.artifact)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.t("Copy path", "复制路径")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(engine.artifact, forType: .string)
                }
                .controlSize(.small)
            }
            if !engine.lastError.isEmpty {
                Text(engine.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.t("Log", "日志"))
                    .font(.headline)
                Spacer()
                Button(L10n.t("Copy", "复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(engine.log, forType: .string)
                }
                .disabled(engine.log.isEmpty)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            LogTextView(
                text: engine.log,
                placeholder: L10n.t("Build log appears here.", "构建日志会显示在这里。")
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: Color.black.opacity(0.06), radius: 2, y: 1)
    }

    private var statusColor: Color {
        if engine.wasCancelled && !engine.busy { return .orange }
        if !engine.lastError.isEmpty { return .red }
        if engine.busy { return .blue }
        if engine.ready { return .green }
        return .secondary
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
            TextField(title, text: text).textFieldStyle(.roundedBorder)
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
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.drawsBackground = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let textView = scroll.documentView as? NSTextView else { return }
            let shown = text.isEmpty ? placeholder : text
            if textView.string == shown { return }
            let clip = scroll.contentView
            let atBottom = context.coordinator.stickToBottom
                || clip.bounds.maxY >= max(textView.bounds.height - 32, 0)
            textView.textColor = text.isEmpty ? .secondaryLabelColor : .labelColor
            textView.string = shown
            if atBottom {
                textView.scrollToEndOfDocument(nil)
            }
            context.coordinator.stickToBottom = atBottom || text.isEmpty
        }

        final class Coordinator {
            var stickToBottom = true
        }
    }

    private func statusDot(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(ok ? okText : badText).font(.caption).foregroundStyle(.secondary)
        }
    }
}
