import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var engine = BuildEngine()
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
        .onChange(of: engine.credentials) { _ in engine.saveCredentials() }
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
            labeledField("Key ID", text: $engine.credentials.keyId)
            labeledField("Issuer ID", text: $engine.credentials.issuerId)
            HStack {
                Button(L10n.t("Choose .p8", "选择 .p8")) { engine.choosePrivateKey() }
                Spacer()
                statusDot(ok: engine.canUpload,
                          okText: L10n.t("Key ready", "密钥已就绪"),
                          badText: L10n.t("Key incomplete", "密钥未配齐"))
            }
            Text(engine.credentials.privateKeyPath.isEmpty
                 ? L10n.t("No private key selected.", "尚未选择私钥。")
                 : engine.credentials.privateKeyPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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
            HStack {
                Button(L10n.t("Choose…", "选择…")) { engine.chooseProject() }
                Button(L10n.t("Inspect", "识别工程")) { engine.runInspect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.projectPath.isEmpty || engine.busy)
                Spacer()
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    private var inspectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t("Signing", "签名"),
                         subtitle: L10n.t("Release scheme and App Store profile. ★ is the one set in Xcode.", "Release scheme 与 App Store 描述文件。★ 表示工程里已指定。"))
            if let ins = engine.inspect {
                labeledPicker(L10n.t("Scheme", "Scheme"), selection: $engine.scheme, options: ins.schemes)
                Picker(L10n.t("Profile", "描述文件"), selection: $engine.profile) {
                    ForEach(ins.profiles) { p in
                        Text(p.displayName).tag(p.value)
                    }
                }
                .labelsHidden()
                factRow(L10n.t("Bundle ID", "Bundle ID"), ins.bundleId)
                factRow("Team", ins.teamId)
                factRow(L10n.t("Style", "方式"), ins.signingStyle)
                certRow
                if !ins.warnings.isEmpty {
                    ForEach(ins.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle.fill")
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
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.t("Certificate", "证书"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text((engine.inspect?.distributionCerts.isEmpty == false)
                 ? L10n.t("Apple Distribution found", "已找到 Apple Distribution")
                 : L10n.t("Not found in Keychain", "钥匙串中没有"))
                .font(.caption)
                .foregroundStyle((engine.inspect?.distributionCerts.isEmpty == false) ? .green : .orange)
        }
    }

    private var actionsCard: some View {
        VStack(spacing: 8) {
            Button {
                engine.runExport(upload: true)
            } label: {
                Text(L10n.t("Archive, export & upload", "Archive、导出并上传"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!engine.ready || !engine.canUpload || engine.busy)

            HStack(spacing: 8) {
                Button(L10n.t("Export IPA", "导出 IPA")) { engine.runExport(upload: false) }
                    .disabled(!engine.ready || engine.busy)
                Button(L10n.t("Upload IPA", "上传 IPA")) { engine.runUpload() }
                    .disabled(engine.artifact.isEmpty || !engine.canUpload || engine.busy)
            }
            HStack(spacing: 8) {
                Button(L10n.t("Cancel", "取消"), role: .destructive) { engine.cancel() }
                    .disabled(!engine.busy)
                Button(L10n.t("Show in Finder", "在 Finder 中显示")) { engine.revealArtifact() }
                    .disabled(engine.artifact.isEmpty)
            }
        }
        .padding(12)
        .background(cardBackground)
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
            ScrollViewReader { proxy in
                ScrollView {
                    Text(engine.log.isEmpty ? L10n.t("Build log appears here.", "构建日志会显示在这里。") : engine.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(engine.log.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("log-end")
                }
                .onChange(of: engine.log) { _ in
                    proxy.scrollTo("log-end", anchor: .bottom)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: Color.black.opacity(0.06), radius: 2, y: 1)
    }

    private var statusColor: Color {
        if !engine.lastError.isEmpty { return .red }
        if engine.busy { return .blue }
        if engine.ready { return .green }
        return .secondary
    }

    private var statusTitle: String {
        if !engine.lastError.isEmpty { return L10n.t("Failed", "失败") }
        if engine.busy { return engine.stage.isEmpty ? L10n.t("Working…", "进行中…") : engine.stage }
        if !engine.artifact.isEmpty { return engine.stage.isEmpty ? L10n.t("IPA ready", "IPA 已就绪") : engine.stage }
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
                .frame(width: 72, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private func statusDot(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(ok ? okText : badText).font(.caption).foregroundStyle(.secondary)
        }
    }
}
